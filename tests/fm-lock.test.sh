#!/usr/bin/env bash
# Behavior tests for the per-home session lock, bin/fm-lock.sh.
#
# The contract under test is not "a file gets written". It is that a session
# only ever reports fleet authority it can prove it holds, and that every way
# of failing to prove it is refused rather than rounded down to "free":
#
#   - an unreadable lock, a lock that is not a regular file, a state directory
#     that cannot be created or written, and a claim that cannot be serialised
#     are each their own refusal with its own text, because an operator who
#     cannot tell them apart cannot clear any of them;
#   - the read-then-write is serialised on a claim lock, so two sessions racing
#     a free lock cannot both come away believing they hold it;
#   - a session re-acquiring its OWN lock is answered without the claim, because
#     that decision is already made and queuing it would stall session start;
#   - what the lock file holds afterwards is read back and checked, so a write
#     that reported success and left something else behind is caught here rather
#     than by whoever reads the lock next;
#   - the record names the PID TABLE its holder pid came from, and a session
#     reading a record from a table it cannot see into is refused rather than
#     told the holder is dead - the case a seat inside a container hits, staged
#     here in a real pid namespace rather than reasoned about;
#   - ownership can be PASSED, through a ticket the outgoing holder issues while
#     it is still the recorded holder, so the record never names nobody and
#     never names two.
#
# One negative case is deliberately absent and is named rather than implied:
# the read-back's own failure branch - a write that succeeds and leaves content
# that is not this session's pid - has no portable fixture, because making a
# write land differently from what was written needs privileges this suite does
# not take. The positive half of that branch is asserted (the pid that ends up
# in the file is the one the session resolved), and the negative half is
# unmeasured here.
#
# Fixtures are synthetic: a fake `ps` on PATH supplies the ancestry walk, and a
# real background process supplies a pid that is genuinely alive, because the
# holder test is `kill -0` and a made-up number would answer it wrongly.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-harness-pid-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-harness-pid-lib.sh"

LOCK_SH="$ROOT/bin/fm-lock.sh"
fm_test_tmproot TMP_ROOT fm-lock

BG_PIDS=()
cleanup_bg() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_bg EXIT

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# live_pid <output-var>: start a real process and assign its pid to <output-var>,
# registering it for cleanup. The holder checks in bin/fm-harness-pid-lib.sh
# start with `kill -0`, so a fabricated pid would be reported dead however
# convincingly `ps` is faked. Assignment rather than stdout, because a command
# substitution would run this in a subshell and lose the cleanup registration -
# the same reason fm_test_tmproot in tests/lib.sh takes an output variable.
live_pid() {
  sleep 300 &
  local p=$!
  BG_PIDS+=("$p")
  printf -v "$1" '%s' "$p"
}

# lock_pid <lock-file>: the holder pid the record names, which is line one. The
# fields below it are read with lock_field, never by matching the whole file:
# an assertion that compares the file's entire contents to a pid is asserting
# the record's SHAPE, and would have to be rewritten for every field added.
lock_pid() {
  sed -n '1p' "$1"
}

# lock_field <lock-file> <name>: the value of a key=value field, empty if absent.
lock_field() {
  sed -n "s/^$2=//p" "$1"
}

# my_pidns: this process's own pid-table token, resolved by the one owner of it.
my_pidns() {
  fm_pid_namespace_token
}

# write_record <lock-file> <pid> [pidns] [ticket]: compose a record by hand, the
# way a holding session would have left it. A pidns of "-" means a record from
# before this fork named pid tables at all.
write_record() {
  local lock=$1 pid=$2 ns=${3:--} ticket=${4:-}
  {
    printf '%s\n' "$pid"
    [ "$ns" = "-" ] || printf 'pidns=%s\n' "$ns"
    [ -z "$ticket" ] || printf 'handover=%s\n' "$ticket"
  } > "$lock"
}

# fixture <name>: a home with an empty state directory, path on stdout.
fixture() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# make_fake_ps_holder <fakebin> <ancestor-pid> [more-harness-pids...]: every
# pid's parent is <ancestor-pid>, so the ancestry walk in
# bin/fm-harness-pid-lib.sh resolves to exactly that pid from any process, which
# is what lets a test know in advance what the lock must contain. Every pid
# named reports as a live `claude`; everything else is a plain shell. The extra
# pids exist because a holder written into the lock has to pass the SAME harness
# test the walk uses - a live process that does not look like a harness is not a
# holder at all, which is the fork's own rule and not this fixture's.
# Mirrors the fake in tests/fm-sessionstart-nudge.test.sh.
make_fake_ps_holder() {
  local fakebin=$1 ancestor=$2 harness_pids
  shift 2
  harness_pids="$ancestor${*:+ $*}"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
is_harness=0
for h in $harness_pids; do
  [ "\$pid" = "\$h" ] && is_harness=1
done
case "\$*" in
  *"comm="*)
    if [ "\$is_harness" = 1 ]; then printf '/usr/local/bin/claude\n'; else printf '/bin/bash\n'; fi
    exit 0 ;;
  *"args="*)
    if [ "\$is_harness" = 1 ]; then printf 'claude\n'; else printf 'bash\n'; fi
    exit 0 ;;
  *"ppid="*) printf '%s\n' "$ancestor"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# run_lock <root> <fakebin> [args...]: drive the real script against a fixture
# state directory, with the ambient home stripped so a developer's own live
# firstmate home can never be the thing under test.
run_lock() {
  local root=$1 fakebin=$2
  shift 2
  env -u FM_HOME -u FM_ROOT_OVERRIDE PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$root/state" "$LOCK_SH" "$@" 2>&1
}

# prepare <name>: a fixture plus a fake `ps` whose ancestry resolves to one live
# harness pid, published as PREP_ROOT, PREP_FAKEBIN and PREP_HARNESS. Assignment
# rather than stdout for the same reason live_pid takes an output variable.
PREP_ROOT=
PREP_FAKEBIN=
PREP_HARNESS=
prepare() {
  PREP_ROOT=$(fixture "$1")
  PREP_FAKEBIN=$(fm_fakebin "$PREP_ROOT")
  live_pid PREP_HARNESS
  make_fake_ps_holder "$PREP_FAKEBIN" "$PREP_HARNESS"
}

test_the_shared_predicate_refuses_every_claimed_nonregular_lock_path() {
  local root target
  root=$(fixture shared-nonregular)

  mkdir "$root/state/.lock"
  fm_session_lock_held_by_other "$root/state/.lock" "" \
    || fail "the shared predicate must refuse a directory at the lock path"
  rmdir "$root/state/.lock"

  target="$root/elsewhere"
  : > "$target"
  ln -s "$target" "$root/state/.lock"
  fm_session_lock_held_by_other "$root/state/.lock" "" \
    || fail "the shared predicate must refuse a symlink at the lock path"
  rm "$root/state/.lock"

  ln -s "$root/never-created" "$root/state/.lock"
  fm_session_lock_held_by_other "$root/state/.lock" "" \
    || fail "the shared predicate must refuse a dangling symlink at the lock path"
}

test_a_free_lock_is_acquired_and_the_pid_is_published() {
  local root fakebin harness out
  prepare free-lock
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS

  out=$(run_lock "$root" "$fakebin") || fail "acquiring a free lock must succeed"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "acquisition must report the harness pid it published"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the lock file must hold the resolved harness pid, not the tool call's own"
  [ "$(lock_field "$root/state/.lock" pidns)" = "$(my_pidns)" ] \
    || fail "the record must name the pid table its holder pid came from"
  [ ! -e "$root/state/.lock.acquire" ] \
    || fail "the claim lock must be released once the session lock is published"
  [ -z "$(find "$root/state" -maxdepth 1 -name '.lock-write.*' -print -quit)" ] \
    || fail "the write probe must not survive the acquisition that used it"
}

test_a_live_holder_refuses_the_second_session() {
  local root fakebin harness other out status=0
  prepare live-holder
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  live_pid other
  make_fake_ps_holder "$fakebin" "$harness" "$other"
  printf '%s\n' "$other" > "$root/state/.lock"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a lock held by another live session must not be acquired"
  assert_contains "$out" "another live firstmate session holds the lock (pid $other)" \
    "the refusal must name the holder an operator has to go and look at"
  [ "$(lock_pid "$root/state/.lock")" = "$other" ] \
    || fail "a refused acquisition must leave the holder's own record intact"
}

test_a_session_reacquiring_its_own_lock_is_answered_without_the_claim() {
  local root fakebin harness out
  prepare reacquire
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  write_record "$root/state/.lock" "$harness" "$(my_pidns)"

  # Hold the claim lock from a live process. A session that had to take the
  # claim would now block and time out; the one that owns the lock already must
  # not, and that difference is the whole assertion.
  hold_claim_lock "$root"

  out=$(FM_LOCK_WAIT_TIMEOUT=1 run_lock "$root" "$fakebin") \
    || fail "a session re-acquiring its own lock must succeed"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "re-acquisition must report the same holder rather than a new one"
  drop_claim_lock "$root"
}

test_reacquisition_falls_through_when_ownership_changes_during_verification() {
  local root fakebin harness out status=0 marker real_cat
  prepare reacquire-changed
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  # A full record, not a bare pid: a record naming no pid table falls through
  # for its own reason, and this test is about the fast path's re-read.
  write_record "$root/state/.lock" "$harness" "$(my_pidns)"
  marker="$root/cat-swapped"
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = "$root/state/.lock" ] && [ ! -e "$marker" ]; then
  "$real_cat" "\$1"
  printf '%s\n' '99999999' > "\$1"
  : > "$marker"
  exit 0
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"
  hold_claim_lock "$root"

  out=$(FM_LOCK_WAIT_TIMEOUT=1 run_lock "$root" "$fakebin") || status=$?
  drop_claim_lock "$root"
  expect_code 1 "$status" "changed ownership must fall through the optimistic fast path"
  assert_contains "$out" "cannot serialise session-lock acquisition" \
    "a changed own-lock record must enter ordinary claim acquisition"
  [ "$(lock_pid "$root/state/.lock")" = "99999999" ] \
    || fail "a failed fall-through must not report or republish the old ownership"
}

test_atomic_publication_never_writes_through_a_swapped_lock_symlink() {
  local root fakebin harness out target real_mv
  prepare atomic-publication
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  target="$root/symlink-target"
  printf '%s\n' 'untouched' > "$target"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
set -u
dest=
for arg in "\$@"; do dest=\$arg; done
if [ "\$dest" = "$root/state/.lock" ]; then
  rm -f "\$dest"
  ln -s "$target" "\$dest"
fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"

  out=$(run_lock "$root" "$fakebin") \
    || fail "atomic publication must replace a swapped symlink without following it"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "atomic publication must still prove the published holder"
  [ "$(cat "$target")" = "untouched" ] \
    || fail "publication must not write through a symlink swapped onto the lock path"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the atomic rename must replace the symlink with this session's lock"
  [ -z "$(find "$root/state" -maxdepth 1 -name '.lock-publish.*' -print -quit)" ] \
    || fail "atomic publication must not leave its temporary file behind"
}

# hold_claim_lock <root>: take state/.lock.acquire from a live background process
# using bin/fm-wake-lib.sh, the primitive that owns it, and publish that
# process's pid as CLAIM_HOLDER_PID. Returns only once the claim is actually
# held, so no test races its own fixture.
CLAIM_HOLDER_PID=
hold_claim_lock() {
  local root=$1 ready="$1/claim-held" waited=0
  (
    export FM_STATE_OVERRIDE="$root/state"
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$root/state/.lock.acquire" || exit 1
    : > "$ready"
    sleep 300
  ) &
  CLAIM_HOLDER_PID=$!
  BG_PIDS+=("$CLAIM_HOLDER_PID")
  while [ ! -e "$ready" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the claim-lock fixture never took the claim"
  done
}

# drop_claim_lock: end the fixture holder and remove the claim it left behind.
# Removed rather than waited out, because a lock whose owner has just died is
# only stolen after a freshness window and a test must not race it.
drop_claim_lock() {
  kill "$CLAIM_HOLDER_PID" 2>/dev/null
  rm -rf "$1/state/.lock.acquire"
  CLAIM_HOLDER_PID=
}

test_acquisition_serialises_on_the_claim_lock() {
  local root fakebin harness out status=0
  prepare serialise
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  hold_claim_lock "$root"

  out=$(FM_LOCK_WAIT_TIMEOUT=1 run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "an acquisition that cannot take the claim must not report success"
  assert_contains "$out" "cannot serialise session-lock acquisition" \
    "the refusal must name serialisation rather than a holder that does not exist"
  [ ! -e "$root/state/.lock" ] \
    || fail "a session that never took the claim must not have written the lock"

  drop_claim_lock "$root"
  out=$(run_lock "$root" "$fakebin") || fail "acquisition must succeed once the claim is free"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "the same fixture must acquire normally once the claim is released"
}

test_an_unreadable_lock_is_never_treated_as_free() {
  local root fakebin harness out status=0
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so mode bits do not block a read"
    return 0
  fi
  prepare unreadable
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  printf '%s\n' "99999999" > "$root/state/.lock"
  chmod 000 "$root/state/.lock"

  out=$(run_lock "$root" "$fakebin") || status=$?
  chmod 600 "$root/state/.lock"
  expect_code 1 "$status" "a lock nobody can read must not be acquired"
  assert_contains "$out" "the session lock is unreadable" \
    "the refusal must say the lock could not be read, not that someone holds it"
  [ "$(lock_pid "$root/state/.lock")" = "99999999" ] \
    || fail "a refused acquisition must not have overwritten the unreadable lock"
}

test_status_never_reports_an_unreadable_lock_as_free() {
  local root fakebin harness out target
  prepare status-reads
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS

  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: free" "an absent lock is free"

  printf '%s\n' "$harness" > "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: held by live harness pid $harness" \
    "a live holder must be reported as held"

  printf '%s\n' "99999999" > "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: stale" "a dead holder must be reported as stale"

  rm "$root/state/.lock"
  mkdir "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (not a regular file)" \
    "a directory at the lock path must be reported as unavailable"
  rmdir "$root/state/.lock"

  target="$root/status-target"
  : > "$target"
  ln -s "$target" "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (not a regular file)" \
    "a symlink at the lock path must be reported as unavailable"
  rm "$root/state/.lock" "$target"

  ln -s "$root/status-missing" "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (not a regular file)" \
    "a dangling symlink at the lock path must be reported as unavailable"
  rm "$root/state/.lock"

  printf '%s\n' "99999999" > "$root/state/.lock"

  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so the unreadable status case cannot be built"
    return 0
  fi
  chmod 000 "$root/state/.lock"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  chmod 600 "$root/state/.lock"
  assert_contains "$out" "lock: unreadable" \
    "a lock that cannot be read must be its own state and never free"
}

test_status_reports_an_unreachable_state_without_trying_to_create_it() {
  local root fakebin out status=0
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so mode bits do not block state access"
    return 0
  fi

  prepare status-uncreatable
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  mkdir -p "$root/sealed"
  chmod 500 "$root/sealed"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$root/sealed/state" "$LOCK_SH" status 2>&1) || status=$?
  chmod 700 "$root/sealed"
  expect_code 0 "$status" "status must succeed when the state directory cannot be created"
  assert_contains "$out" "lock: unavailable (state directory absent)" \
    "status must not call an unreachable absent state directory free"
  [ ! -e "$root/sealed/state" ] \
    || fail "status must not create the state directory it inspects"

  prepare status-unreadable-state
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  chmod 000 "$root/state"
  status=0
  out=$(run_lock "$root" "$fakebin" status) || status=$?
  chmod 700 "$root/state"
  expect_code 0 "$status" "status must succeed when the state directory cannot be read"
  assert_contains "$out" "lock: unavailable (state directory unreadable)" \
    "status must distinguish an unreadable state directory from a free lock"
}

test_a_symlink_to_a_usable_state_directory_is_used_consistently() {
  local root fakebin harness out
  prepare symlinked-state-directory
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  rmdir "$root/state"
  mkdir "$root/real-state"
  ln -s "$root/real-state" "$root/state"

  out=$(run_lock "$root" "$fakebin") \
    || fail "acquisition must accept a state path resolving to a usable directory"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "acquisition through a state-directory symlink must publish authority"
  [ "$(lock_pid "$root/real-state/.lock")" = "$harness" ] \
    || fail "the lock must land in the resolved state directory"

  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: held by live harness pid $harness" \
    "status must inspect the same resolved state directory acquisition uses"
}

test_a_searchable_unlistable_state_directory_is_used_consistently() {
  local root fakebin harness out status=0
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so mode bits do not block directory listing"
    return 0
  fi

  prepare searchable-unlistable-state
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  chmod 300 "$root/state"
  out=$(run_lock "$root" "$fakebin") || status=$?
  chmod 700 "$root/state"
  expect_code 0 "$status" "acquisition must accept a searchable writable state directory"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "acquisition must not require directory-listing permission"

  chmod 300 "$root/state"
  status=0
  out=$(run_lock "$root" "$fakebin" status) || status=$?
  chmod 700 "$root/state"
  expect_code 0 "$status" "status must accept a searchable state directory"
  assert_contains "$out" "lock: held by live harness pid $harness" \
    "status must inspect the known lock path without listing its directory"
}

test_unusable_state_paths_are_refused_and_reported_unavailable() {
  local root fakebin out status

  prepare dangling-state-path
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  rmdir "$root/state"
  ln -s "$root/missing-state" "$root/state"
  status=0
  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "acquisition must refuse a dangling state-directory symlink"
  assert_contains "$out" "cannot create session-lock state directory" \
    "a dangling state-directory symlink must retain the creation refusal"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (state path is not a directory)" \
    "status must report a dangling state-directory symlink as unusable"

  prepare state-symlink-to-file
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  rmdir "$root/state"
  : > "$root/state-file"
  ln -s "$root/state-file" "$root/state"
  status=0
  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "acquisition must refuse a state path resolving to a file"
  assert_contains "$out" "cannot create session-lock state directory" \
    "a state symlink to a file must retain the creation refusal"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (state path is not a directory)" \
    "status must report a state symlink to a file as unusable"

  prepare regular-file-state-path
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  rmdir "$root/state"
  : > "$root/state"
  status=0
  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "acquisition must refuse a regular file at the state path"
  assert_contains "$out" "cannot create session-lock state directory" \
    "a regular file at the state path must retain the creation refusal"
  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "lock: unavailable (state path is not a directory)" \
    "status must report a regular file at the state path as unusable"
}

test_a_lock_that_is_not_a_regular_file_is_refused_and_not_written_through() {
  local root fakebin harness out status=0 target
  prepare symlinked
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  target="$root/elsewhere"
  : > "$target"
  ln -s "$target" "$root/state/.lock"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a symlinked lock must not be acquired"
  assert_contains "$out" "the session lock is not a regular file" \
    "the refusal must name what is wrong with the lock path"
  [ ! -s "$target" ] \
    || fail "the refusal must not have written this session's pid through the link"
}

test_a_dangling_lock_symlink_is_refused_rather_than_created() {
  local root fakebin harness out status=0 target
  prepare dangling
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  target="$root/never-created"
  ln -s "$target" "$root/state/.lock"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a dangling lock symlink must not be acquired"
  assert_contains "$out" "the session lock is not a regular file" \
    "the refusal must name what is wrong with the lock path"
  [ ! -e "$target" ] \
    || fail "the refusal must not have created the file the link pointed at"
}

test_a_state_directory_that_cannot_be_written_refuses_before_claiming() {
  local root fakebin harness out status=0
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so mode bits do not block a write"
    return 0
  fi
  prepare unwritable-state
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  chmod 500 "$root/state"

  out=$(run_lock "$root" "$fakebin") || status=$?
  chmod 700 "$root/state"
  expect_code 1 "$status" "an unwritable state directory must not yield an acquired lock"
  assert_contains "$out" "cannot write session lock" \
    "the refusal must name the write it could not make"
  [ ! -e "$root/state/.lock" ] || fail "no lock may exist after a refused acquisition"
}

test_a_state_directory_that_cannot_be_created_refuses() {
  local root fakebin harness out status=0
  if [ "$IS_ROOT" -eq 1 ]; then
    echo "skip: running as root, so mode bits do not block a directory creation"
    return 0
  fi
  prepare uncreatable-state
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  mkdir -p "$root/sealed"
  chmod 500 "$root/sealed"

  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$root/sealed/state" "$LOCK_SH" 2>&1) || status=$?
  chmod 700 "$root/sealed"
  expect_code 1 "$status" "a state directory that cannot be created must not yield a lock"
  assert_contains "$out" "cannot create session-lock state directory" \
    "the refusal must name the directory it could not create"
}

test_a_session_that_cannot_identify_itself_acquires_nothing() {
  local root fakebin out status=0
  root=$(fixture no-harness)
  fakebin=$(fm_fakebin "$root")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/bin/bash\n'; exit 0 ;;
  *"args="*) printf 'bash\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a session with no harness ancestor must not take the lock"
  assert_contains "$out" "cannot locate harness process in ancestry" \
    "the refusal must name the identification failure"
  [ ! -e "$root/state/.lock" ] || fail "no lock may exist after a refused acquisition"
}

# --- the pid table the holder pid came from --------------------------------

# ns_available: whether this machine will hand an unprivileged process a real
# pid namespace. Skipped rather than failed where it will not, and the skip says
# what went unproven - a suite that quietly drops its own central case reads
# afterwards exactly like one that ran it.
NS_AVAILABLE=
ns_available() {
  if [ -z "$NS_AVAILABLE" ]; then
    if unshare --user --pid --fork /bin/true 2>/dev/null; then
      NS_AVAILABLE=yes
    else
      NS_AVAILABLE=no
    fi
  fi
  [ "$NS_AVAILABLE" = yes ]
}

# run_lock_in_new_pid_ns <root> <fakebin> [args...]: the same script, in a real
# pid namespace of its own. Not a simulation of a container and not a fake `ps`
# standing in for one: the pid table really is a different one, which is the
# whole point - the defect being tested is invisible to any fixture that only
# pretends.
run_lock_in_new_pid_ns() {
  local root=$1 fakebin=$2
  shift 2
  unshare --user --pid --fork \
    env -u FM_HOME -u FM_ROOT_OVERRIDE PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$root/state" "$LOCK_SH" "$@" 2>&1
}

make_namespace_identity_unreadable() {  # <fakebin>
  local fakebin=$1 real_readlink
  real_readlink=$(command -v readlink)
  cat > "$fakebin/readlink" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = /proc/self/ns/pid ]; then
  exit 1
fi
exec "$real_readlink" "\$@"
SH
  chmod +x "$fakebin/readlink"
}

make_nonlinux_uname() {  # <fakebin>
  local fakebin=$1 real_uname
  real_uname=$(command -v uname)
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf 'FreeBSD\n' ;;
  -n) printf 'fixture-host\n' ;;
  *) exec "$real_uname" "\$@" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

make_machine_identity() {  # <fakebin> <value|empty|unreadable>
  local fakebin=$1 mode=$2 real_cat
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = /etc/machine-id ]; then
  case "$mode" in
    empty) exit 0 ;;
    unreadable) exit 1 ;;
    *) printf '%s\n' "$mode"; exit 0 ;;
  esac
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"
}

test_linux_refuses_when_its_pid_namespace_identity_is_unreadable() {
  local root fakebin out status=0
  prepare unreadable-linux-pidns
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN
  make_namespace_identity_unreadable "$fakebin"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "Linux must refuse when its pid namespace identity cannot be read"
  assert_contains "$out" "cannot identify this session's process namespace" \
    "the refusal must name the missing process namespace identity"
  [ ! -e "$root/state/.lock" ] \
    || fail "an unidentifiable Linux pid table must never publish a lock record"
}

test_linux_refuses_when_its_machine_identity_is_unusable() {
  local mode root fakebin out status
  for mode in unreadable empty; do
    prepare "${mode}-linux-machine-id"
    root=$PREP_ROOT fakebin=$PREP_FAKEBIN status=0
    make_machine_identity "$fakebin" "$mode"

    out=$(run_lock "$root" "$fakebin") || status=$?
    expect_code 1 "$status" "Linux must refuse when machine-id is $mode"
    assert_contains "$out" "readable /etc/machine-id" \
      "the refusal must name the missing Linux machine identity"
    [ ! -e "$root/state/.lock" ] \
      || fail "an unidentifiable Linux machine must never publish a lock record"
  done
}

test_the_same_namespace_inode_on_another_machine_is_foreign() {
  local root fakebin harness otherbin other out status=0
  prepare machine-scoped-pidns
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  make_machine_identity "$fakebin" machine-a
  run_lock "$root" "$fakebin" >/dev/null || fail "the first machine must acquire the lock"
  assert_contains "$(lock_field "$root/state/.lock" pidns)" "linux:machine-a:pid:[" \
    "the first record must combine machine identity with namespace inode"

  kill "$harness" 2>/dev/null || true
  wait "$harness" 2>/dev/null || true
  otherbin=$(fm_fakebin "$root/other-machine")
  live_pid other
  make_fake_ps_holder "$otherbin" "$other"
  make_machine_identity "$otherbin" machine-b

  out=$(run_lock "$root" "$otherbin") || status=$?
  expect_code 1 "$status" "the same namespace inode on another machine must remain foreign"
  assert_contains "$out" "liveness is unmeasurable" \
    "the second machine must refuse rather than probe the first machine's dead-looking pid"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the second machine must leave the first machine's record intact"
}

test_a_kernel_without_pid_namespaces_uses_a_machine_scoped_token() {
  local root fakebin harness out status=0
  prepare nonlinux-pid-table
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  make_namespace_identity_unreadable "$fakebin"
  make_nonlinux_uname "$fakebin"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 0 "$status" "a kernel without pid namespaces must identify its machine-scoped pid table"
  assert_contains "$out" "lock acquired: harness pid $harness" \
    "the machine-scoped token must permit a provable acquisition"
  [ "$(lock_field "$root/state/.lock" pidns)" = "nons:FreeBSD:fixture-host" ] \
    || fail "the published lock must carry the staged machine-scoped pid-table token"
}

test_a_holder_in_another_pid_table_is_refused_even_when_it_looks_dead() {
  local root fakebin harness out status=0
  prepare foreign-table
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  # A pid that is definitively dead in THIS table, recorded against another one.
  # That combination is the entire argument: the liveness test answers "dead",
  # and answering "dead" is exactly what this session is not entitled to do
  # about a table it cannot see into.
  write_record "$root/state/.lock" 99999999 "pid:[4026533181]"

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a holder in an unreadable pid table must not be taken over"
  assert_contains "$out" "process namespace pid:[4026533181], which this session cannot see into" \
    "the refusal must say the table cannot be seen into, not that the holder is gone"
  assert_contains "$out" "handover" \
    "the refusal must name the way ownership is meant to move instead"
  [ "$(lock_pid "$root/state/.lock")" = "99999999" ] \
    || fail "a refused acquisition must leave the foreign record untouched"
}

test_status_calls_a_holder_in_another_pid_table_unmeasurable_not_stale() {
  local root fakebin harness out
  prepare foreign-status
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  write_record "$root/state/.lock" 99999999 "pid:[4026533181]"

  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "liveness is unmeasurable from here" \
    "status must report what it cannot measure rather than guessing at it"
  assert_not_contains "$out" "lock: stale" \
    "a holder in another pid table must never be reported stale"
  assert_not_contains "$out" "lock: held by live harness" \
    "a holder this session cannot probe must not be reported live either"
}

test_a_real_pid_namespace_cannot_take_a_lock_held_on_this_host() {
  local root fakebin harness insidebin out status=0 probe
  prepare real-namespace
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  if ! ns_available; then
    echo "skip: this machine refuses an unprivileged pid namespace, so the cross-boundary refusal is UNPROVEN here"
    return 0
  fi
  # The host seat takes the lock for real, so the record's table token is this
  # host's own rather than one the test made up.
  out=$(run_lock "$root" "$fakebin") || fail "the host seat must acquire first"
  assert_contains "$out" "lock acquired: harness pid $harness" "host acquisition failed"

  # The danger is asserted before the fix is: inside its own pid table the live
  # host holder does not answer, so a liveness test alone WOULD call it dead.
  probe=$(unshare --user --pid --fork /bin/bash -c \
    "if kill -0 $harness 2>/dev/null; then echo visible; else echo invisible; fi" 2>&1)
  [ "$probe" = invisible ] \
    || fail "this fixture proves nothing unless the host holder is invisible inside the namespace (got: $probe)"

  insidebin=$(fm_fakebin "$root/inside")
  make_fake_ps_holder "$insidebin" 424242
  status=0
  out=$(run_lock_in_new_pid_ns "$root" "$insidebin") || status=$?
  expect_code 1 "$status" \
    "a seat in another pid namespace must not take a lock the host seat holds"
  assert_contains "$out" "which this session cannot see into" \
    "the inside seat must refuse because it cannot see, not because it found a holder"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the host seat's ownership must survive the refused takeover"
  [ -z "$(lock_field "$root/state/.lock" handover)" ] \
    || fail "a refused takeover must not leave a handover offer behind"
}

test_a_second_session_on_this_host_is_still_refused() {
  local root fakebin harness other otherbin out status=0
  prepare second-host-session
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  out=$(run_lock "$root" "$fakebin") || fail "the first session must acquire"

  # A genuinely different live harness on the SAME host, resolved through its own
  # ancestry: the ordinary single-seat case, which naming pid tables must not
  # have loosened.
  live_pid other
  otherbin=$(fm_fakebin "$root/second")
  make_fake_ps_holder "$otherbin" "$other" "$harness"
  status=0
  out=$(run_lock "$root" "$otherbin") || status=$?
  expect_code 1 "$status" "a second session on this host must still be refused"
  assert_contains "$out" "another live firstmate session holds the lock (pid $harness)" \
    "the same-host refusal must still name the holder"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the refused second session must not have republished the lock"
}

# --- passing ownership rather than dropping it -----------------------------

test_help_describes_the_irrevocable_handover_interface() {
  local out first last
  out=$("$LOCK_SH" --help) || fail "session-lock help must be readable"
  first=$(printf '%s\n' "$out" | sed -n '1p')
  last=$(printf '%s\n' "$out" | tail -n 1)
  [ "$first" = "Acquire, inspect or hand over the per-home firstmate session lock." ] \
    || fail "help must begin with the script header"
  [ "$last" = "       fm-lock.sh handover              stand down and print the successor's ticket" ] \
    || fail "help must end with the final supported usage line"
  assert_contains "$out" "The offer is final" \
    "help must state that a handover offer is irrevocable"
  assert_not_contains "$out" "--cancel" \
    "help must not advertise a withdrawal operation"
}

test_an_irrevocable_offer_keeps_the_home_owned_for_one_successor() {
  local root fakebin harness other otherbin out ticket status=0
  prepare handover-offer
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  run_lock "$root" "$fakebin" >/dev/null || fail "the outgoing seat must hold the lock first"

  out=$(run_lock "$root" "$fakebin" handover) || fail "the holder must be able to offer ownership"
  ticket=$(printf '%s\n' "$out" | sed -n 's/^ticket: //p')
  [ "${#ticket}" -eq 32 ] || fail "the offer must print a ticket a successor can present (got: $ticket)"

  # The chosen cost, asserted rather than described: the record still names the
  # outgoing holder, so at no point does it name nobody.
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "an offer must leave the outgoing seat recorded, so the home is never unowned"
  [ "$(lock_field "$root/state/.lock" handover)" = "$ticket" ] \
    || fail "the record must name the one successor the ticket was issued to"

  out=$(run_lock "$root" "$fakebin" status) || fail "status must always exit 0"
  assert_contains "$out" "handover offered" "status must show that an offer stands"

  # And the other half of the cost: the seat that stood down cannot quietly
  # resume, which is what keeps two seats from acting at once.
  status=0
  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "a seat that offered its ownership away must not resume by re-acquiring"
  assert_contains "$out" "the offer cannot be withdrawn" \
    "the refusal must state that the offer is final"
  assert_not_contains "$out" "--cancel" \
    "the refusal must not name a withdrawal command"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "a refused re-acquire must leave the outgoing holder recorded"
  [ "$(lock_field "$root/state/.lock" handover)" = "$ticket" ] \
    || fail "a refused re-acquire must leave the successor's ticket intact"

  status=0
  out=$(run_lock "$root" "$fakebin" handover --cancel) || status=$?
  expect_code 2 "$status" "the handover interface must provide no withdrawal operation"
  assert_contains "$out" "unknown option --cancel" \
    "a withdrawal attempt must be rejected as unsupported"
  [ "$(lock_field "$root/state/.lock" handover)" = "$ticket" ] \
    || fail "an unsupported withdrawal must leave the final offer intact"

  status=0
  out=$(run_lock "$root" "$fakebin" acquire --handover "${ticket}deadbeef") || status=$?
  expect_code 1 "$status" "a ticket that does not match the standing offer must be refused"
  assert_contains "$out" "does not match the offer" "the refusal must say the ticket did not match"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "a mismatched ticket must leave ownership where it was"

  otherbin=$(fm_fakebin "$root/successor")
  live_pid other
  make_fake_ps_holder "$otherbin" "$other" "$harness"
  status=0
  out=$(run_lock "$root" "$otherbin" acquire --handover "$ticket") || status=$?
  expect_code 0 "$status" "the named successor must still redeem an irrevocable offer"
  assert_contains "$out" "lock acquired by handover: harness pid $other (from pid $harness)" \
    "the successor must report the ownership transfer"
  [ "$(lock_pid "$root/state/.lock")" = "$other" ] \
    || fail "redemption must publish the named successor as holder"
  [ -z "$(lock_field "$root/state/.lock" handover)" ] \
    || fail "redemption must consume the final offer"
}

test_a_ticket_is_refused_when_no_offer_stands() {
  local root fakebin harness out status=0
  prepare handover-unoffered
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  run_lock "$root" "$fakebin" >/dev/null || fail "the seat must hold the lock first"

  out=$(run_lock "$root" "$fakebin" acquire --handover 0123456789abcdef0123456789abcdef) || status=$?
  expect_code 1 "$status" "a ticket must not take a lock nobody offered"
  assert_contains "$out" "no offer stands on this lock" \
    "the refusal must say there was nothing to claim"
}

test_a_seat_that_holds_nothing_cannot_offer_ownership() {
  local root fakebin harness out status=0
  prepare handover-nonholder
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS

  out=$(run_lock "$root" "$fakebin" handover) || status=$?
  expect_code 1 "$status" "a seat with no ownership must not be able to offer it"
  assert_contains "$out" "does not hold the lock" "the refusal must say why"
  [ ! -e "$root/state/.lock" ] || fail "a refused offer must not have created a record"
}

test_ownership_passes_into_a_real_pid_namespace_by_handover() {
  local root fakebin harness insidebin out ticket inside_ns status=0
  prepare handover-across
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  if ! ns_available; then
    echo "skip: this machine refuses an unprivileged pid namespace, so the cross-boundary handover is UNPROVEN here"
    return 0
  fi
  run_lock "$root" "$fakebin" >/dev/null || fail "the host seat must hold the lock first"
  out=$(run_lock "$root" "$fakebin" handover) || fail "the host seat must be able to offer"
  ticket=$(printf '%s\n' "$out" | sed -n 's/^ticket: //p')
  [ "${#ticket}" -eq 32 ] || fail "the offer must print a ticket"
  [ "$(lock_pid "$root/state/.lock")" = "$harness" ] \
    || fail "the home must stay owned while the successor is still starting"

  insidebin=$(fm_fakebin "$root/inside")
  make_fake_ps_holder "$insidebin" 424242
  status=0
  out=$(run_lock_in_new_pid_ns "$root" "$insidebin" acquire --handover "$ticket") || status=$?
  expect_code 0 "$status" "a presented ticket must move ownership across the boundary refusal blocks"
  assert_contains "$out" "lock acquired by handover: harness pid 424242 (from pid $harness)" \
    "the successor must report that it took ownership by handover, and from whom"
  [ "$(lock_pid "$root/state/.lock")" = "424242" ] \
    || fail "the record must now name the seat inside the namespace"
  inside_ns=$(lock_field "$root/state/.lock" pidns)
  [ -n "$inside_ns" ] && [ "$inside_ns" != "$(my_pidns)" ] \
    || fail "the record must name the successor's own pid table, not the host's (got: $inside_ns)"
  [ -z "$(lock_field "$root/state/.lock" handover)" ] \
    || fail "a claimed ticket must not stay claimable"

  # And the boundary now holds the other way round, which is the proof that the
  # refusal is about tables and not about which side of one you happen to be on.
  status=0
  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "the host seat must not take back a lock now held inside the namespace"
  assert_contains "$out" "which this session cannot see into" \
    "the host seat must refuse for the same measured reason the inside seat did"
}

# --- records written before this fork named pid tables ---------------------

test_a_record_naming_no_pid_table_is_upgraded_and_the_gap_is_said_out_loud() {
  local root fakebin harness out status=0
  prepare legacy-upgrade
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  write_record "$root/state/.lock" 99999999 -

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 0 "$status" "a record naming no pid table whose holder is gone must still be takeable"
  assert_contains "$out" "named no process namespace" \
    "taking such a record must say what could not be proved about the holder it replaced"
  [ "$(lock_field "$root/state/.lock" pidns)" = "$(my_pidns)" ] \
    || fail "the upgrade must be a one-shot: what it wrote must name a table"

  # Second time round there is nothing left to warn about, which is what makes
  # it a one-shot rather than a standing noise source.
  out=$(run_lock "$root" "$fakebin") || fail "re-acquisition must succeed"
  assert_not_contains "$out" "named no process namespace" \
    "the warning must not repeat once the record names a table"
}

test_a_record_naming_no_pid_table_still_refuses_a_live_holder() {
  local root fakebin harness other out status=0
  prepare legacy-live-holder
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  live_pid other
  make_fake_ps_holder "$fakebin" "$harness" "$other"
  write_record "$root/state/.lock" "$other" -

  out=$(run_lock "$root" "$fakebin") || status=$?
  expect_code 1 "$status" "the transitional reading must not have loosened the ordinary refusal"
  assert_contains "$out" "another live firstmate session holds the lock (pid $other)" \
    "a live holder in a record naming no table must still be named as the holder"
}

test_a_free_lock_is_acquired_and_the_pid_is_published
test_the_shared_predicate_refuses_every_claimed_nonregular_lock_path
test_a_live_holder_refuses_the_second_session
test_a_session_reacquiring_its_own_lock_is_answered_without_the_claim
test_reacquisition_falls_through_when_ownership_changes_during_verification
test_atomic_publication_never_writes_through_a_swapped_lock_symlink
test_acquisition_serialises_on_the_claim_lock
test_an_unreadable_lock_is_never_treated_as_free
test_status_never_reports_an_unreadable_lock_as_free
test_status_reports_an_unreachable_state_without_trying_to_create_it
test_a_symlink_to_a_usable_state_directory_is_used_consistently
test_a_searchable_unlistable_state_directory_is_used_consistently
test_unusable_state_paths_are_refused_and_reported_unavailable
test_a_lock_that_is_not_a_regular_file_is_refused_and_not_written_through
test_a_dangling_lock_symlink_is_refused_rather_than_created
test_a_state_directory_that_cannot_be_written_refuses_before_claiming
test_a_state_directory_that_cannot_be_created_refuses
test_a_session_that_cannot_identify_itself_acquires_nothing
test_linux_refuses_when_its_pid_namespace_identity_is_unreadable
test_linux_refuses_when_its_machine_identity_is_unusable
test_the_same_namespace_inode_on_another_machine_is_foreign
test_a_kernel_without_pid_namespaces_uses_a_machine_scoped_token
test_a_holder_in_another_pid_table_is_refused_even_when_it_looks_dead
test_status_calls_a_holder_in_another_pid_table_unmeasurable_not_stale
test_a_real_pid_namespace_cannot_take_a_lock_held_on_this_host
test_a_second_session_on_this_host_is_still_refused
test_help_describes_the_irrevocable_handover_interface
test_an_irrevocable_offer_keeps_the_home_owned_for_one_successor
test_a_ticket_is_refused_when_no_offer_stands
test_a_seat_that_holds_nothing_cannot_offer_ownership
test_ownership_passes_into_a_real_pid_namespace_by_handover
test_a_record_naming_no_pid_table_is_upgraded_and_the_gap_is_said_out_loud
test_a_record_naming_no_pid_table_still_refuses_a_live_holder

pass "session lock: authority is published only when it can be proved, every way of failing to prove it is its own refusal, a holder in a pid table this session cannot see into is refused rather than judged dead, and ownership can be passed without the home ever naming nobody or naming two"
