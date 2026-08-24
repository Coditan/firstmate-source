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
#     than by whoever reads the lock next.
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
  [ "$(cat "$root/state/.lock")" = "$harness" ] \
    || fail "the lock file must hold the resolved harness pid, not the tool call's own"
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
  [ "$(cat "$root/state/.lock")" = "$other" ] \
    || fail "a refused acquisition must leave the holder's own record intact"
}

test_a_session_reacquiring_its_own_lock_is_answered_without_the_claim() {
  local root fakebin harness out
  prepare reacquire
  root=$PREP_ROOT fakebin=$PREP_FAKEBIN harness=$PREP_HARNESS
  printf '%s\n' "$harness" > "$root/state/.lock"

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
  [ "$(cat "$root/state/.lock")" = "99999999" ] \
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

test_a_free_lock_is_acquired_and_the_pid_is_published
test_the_shared_predicate_refuses_every_claimed_nonregular_lock_path
test_a_live_holder_refuses_the_second_session
test_a_session_reacquiring_its_own_lock_is_answered_without_the_claim
test_acquisition_serialises_on_the_claim_lock
test_an_unreadable_lock_is_never_treated_as_free
test_status_never_reports_an_unreadable_lock_as_free
test_status_reports_an_unreachable_state_without_trying_to_create_it
test_a_lock_that_is_not_a_regular_file_is_refused_and_not_written_through
test_a_dangling_lock_symlink_is_refused_rather_than_created
test_a_state_directory_that_cannot_be_written_refuses_before_claiming
test_a_state_directory_that_cannot_be_created_refuses
test_a_session_that_cannot_identify_itself_acquires_nothing

pass "session lock: authority is published only when it can be proved, and every way of failing to prove it is its own refusal"
