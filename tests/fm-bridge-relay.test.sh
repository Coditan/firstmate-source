#!/usr/bin/env bash
# Behavior tests for the guarded envelope-only Bridge relay dispatcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAY="$ROOT/bin/fm-bridge-relay.sh"
fm_test_tmproot TMP_ROOT fm-bridge-relay-tests
fm_git_identity fmtest fmtest@example.invalid

make_bridge() {
  local name=$1 home seed origin bridge origin_abs script
  home="$TMP_ROOT/$name/home"
  seed="$TMP_ROOT/$name/seed"
  origin="$TMP_ROOT/$name/origin.git"
  bridge="$home/projects/coditan-bridge"
  mkdir -p "$seed/bin" "$home/projects" "$home/config"
  # Every fixture home is a vessel, because a sender-bearing call from a home
  # with no identity is refused before it reaches anything these tests measure.
  # Tests about the identity guard itself overwrite this with set_home_vessel.
  printf 'tugboat\n' > "$home/config/bridge-vessel"

  cat > "$seed/bin/bridge-stub.sh" <<'SH'
#!/usr/bin/env bash
{
  printf 'script=%s\n' "$(basename "$0")"
  printf 'cwd=%s\n' "$PWD"
  printf 'argc=%s\n' "$#"
  index=0
  for arg in "$@"; do
    printf 'arg%s=<%s>\n' "$index" "$arg"
    index=$(( index + 1 ))
  done
  # What the checkout's working tree actually holds when the script runs: a read
  # answers from this, so a clone left behind origin sees nothing here.
  for envelope in inbox/*/new/*.json; do
    [ -e "$envelope" ] || continue
    printf 'seen=%s\n' "$envelope"
  done
} > "${BRIDGE_RELAY_CAPTURE:?}"
SH
  for script in send inbox status broadcast; do
    cp "$seed/bin/bridge-stub.sh" "$seed/bin/bridge-$script.sh"
    chmod +x "$seed/bin/bridge-$script.sh"
  done
  rm "$seed/bin/bridge-stub.sh"

  git -C "$seed" init -q -b main
  git -C "$seed" add bin
  git -C "$seed" commit -qm initial
  git clone -q --bare "$seed" "$origin"
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  origin_abs=$(cd "$origin" && pwd -P)
  git clone -q "file://$origin_abs" "$bridge"
  printf '%s\n' "$home"
}

# set_home_vessel <home> [record-text]: replace the fixture's Bridge identity
# record with exactly <record-text>, or remove the record entirely when no text is
# given. The text is written verbatim, so a caller can hand it an empty record or
# one naming several vessels.
set_home_vessel() {
  local home=$1
  if [ "$#" -lt 2 ]; then
    rm -f "$home/config/bridge-vessel"
    return 0
  fi
  printf '%s' "$2" > "$home/config/bridge-vessel"
}

# Publish one envelope straight to origin, leaving the clone one commit behind.
# This is the reported failure's exact shape: the mail exists at origin while
# the checkout's working tree still holds an empty mailbox.
publish_envelope_at_origin() {
  local name=$1 vessel=$2 origin work
  origin=$(cd "$TMP_ROOT/$name/origin.git" && pwd -P)
  work="$TMP_ROOT/$name/publisher"
  git clone -q "file://$origin" "$work"
  mkdir -p "$work/inbox/$vessel/new"
  printf '{"priority":"high"}\n' > "$work/inbox/$vessel/new/2026-08-01T00-56-11Z-envelope.json"
  git -C "$work" add -A
  git -C "$work" commit -qm "envelope for $vessel"
  git -C "$work" push -q origin main
}

# Point the clone's default branch at a SECOND remote that sits exactly where the
# clone does. The fleet sync only ever fetches origin and only ever judges
# against origin/<default>, so after this the branch's own '@{upstream}' is a ref
# nothing in the refresh path touches - and a distance measured against it says
# nothing about the mail waiting at origin.
add_level_mirror_upstream() {
  local name=$1 bridge mirror mirror_abs
  bridge="$TMP_ROOT/$name/home/projects/coditan-bridge"
  mirror="$TMP_ROOT/$name/mirror.git"
  git clone -q --bare "$bridge" "$mirror"
  mirror_abs=$(cd "$mirror" && pwd -P)
  git -C "$bridge" remote add mirror "file://$mirror_abs"
  git -C "$bridge" fetch -q mirror
  git -C "$bridge" branch --quiet --set-upstream-to=mirror/main main >/dev/null 2>&1
}

# Let the clone learn it is behind, then make origin unreachable so the guarded
# refresh cannot complete.
strand_clone() {
  local name=$1
  git -C "$TMP_ROOT/$name/home/projects/coditan-bridge" fetch -q origin main
  mv "$TMP_ROOT/$name/origin.git" "$TMP_ROOT/$name/origin-gone.git"
}

# run_relay <home> [args...]: run the relay against a fixture home with stderr
# merged into stdout. Four knobs a caller may set for the duration of its own
# calls: RELAY_PATH_PREFIX prepends a fakebin dir to PATH,
# RELAY_FLEET_SYNC_RETRIES overrides fleet-sync's packed-refs lock retry count so
# a simulated lock race does not sit through its real retry waits, RELAY_BIN
# runs a different copy of the relay (see stub_fleet_sync), and
# RELAY_ROOT_OVERRIDE points $FM_ROOT at a fixture directory. That last one
# matters only to the sender-identity tests: the relay falls back to
# $FM_ROOT/config/bridge-vessel, and a test asserting that a home has no identity
# must not quietly pass or fail on whether the real firstmate root the suite runs
# from happens to carry that gitignored file.
run_relay() {
  local home=$1
  shift
  PATH="${RELAY_PATH_PREFIX:+$RELAY_PATH_PREFIX:}$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES="${RELAY_FLEET_SYNC_RETRIES:-3}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="${RELAY_ROOT_OVERRIDE:-$ROOT}" \
    BRIDGE_RELAY_CAPTURE="$home/capture" \
    "${RELAY_BIN:-$RELAY}" "$@" 2>&1
}

# Stand the real relay up beside a stubbed fm-fleet-sync.sh that prints <line>
# and exits 0. The relay resolves its sibling scripts from its own directory, so
# a symlink into a fixture bin runs the unmodified script against a fleet sync
# whose outcome vocabulary this relay does not recognise. Echoes the relay path
# for RELAY_BIN.
stub_fleet_sync() {
  local home=$1 line=$2 bin
  bin="$home/bin"
  mkdir -p "$bin"
  ln -sf "$ROOT/bin/fm-bridge-relay.sh" "$bin/fm-bridge-relay.sh"
  ln -sf "$ROOT/bin/fm-tangle-lib.sh" "$bin/fm-tangle-lib.sh"
  cat > "$bin/fm-fleet-sync.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$line"
exit 0
SH
  chmod +x "$bin/fm-fleet-sync.sh"
  printf '%s\n' "$bin/fm-bridge-relay.sh"
}

# Shim git so every fetch loses a race for a lock the way a concurrent
# whole-fleet sync (bin/fm-bootstrap.sh) makes it lose one, while every other
# git call stays real. Echoes the fakebin dir to prepend to PATH.
shim_git_fetch_lock_contention() {
  local home=$1 lock=$2 fakebin real
  real=$(command -v git)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    printf "fatal: Unable to create '%s': File exists.\\n" "$lock" >&2
    exit 128
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# The other half of the same race, and the one that takes .git/index.lock: the
# concurrent sync wins the fast-forward merge - so the clone really does end up
# level with origin - while this one's merge fails on the lock it already holds.
# The shim reproduces that end state by letting the real merge happen and then
# reporting the loser's failure. Echoes the fakebin dir to prepend to PATH.
shim_git_merge_lock_contention() {
  local home=$1 lock=$2 fakebin real
  real=$(command -v git)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = merge ]; then
    "$real" "\$@" >/dev/null 2>&1 || true
    printf "fatal: Unable to create '%s': File exists.\\n" "$lock" >&2
    exit 128
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# Put the fixture home in the state fm-guard.sh alarms on: work in flight with no
# live watcher. fm-fleet-sync.sh runs that guard, so this is what a Bridge call
# meets whenever supervision is down.
strand_watcher() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
}

# relay_own_output <text>: drop the bin/fm-guard.sh alarm lines the relay
# deliberately relays out of fleet-sync's stderr, leaving only what the relay
# itself produced. Those alarms describe the firstmate root the suite runs from,
# never the fixture: a crewmate or developer runs this suite from a worktree on a
# named branch, which is exactly the state fm-guard.sh's worktree-tangle banner
# fires on, so every relay call there carries a banner the relay is required to
# pass through. A silence assertion is about the relay's own output and must not
# depend on that root being healthy. test_guard_alarm_reaches_the_caller
# deliberately does NOT use this and asserts the alarms do reach the caller.
relay_own_output() {
  printf '%s\n' "$1" | grep -v \
    -e '^●' \
    -e '^WARNING: watcher still down' \
    -e '^WARNING: wake delivery listener ' \
    -e '^WARNING: queued wakes pending' || true
}

# Shim sed so fm-fleet-sync.sh dies mid-run instead of reporting a per-project
# outcome: it composes its skip reason through sed, so the crash lands the relay
# on the genuine no-outcome path, where fleet-sync's stderr is the only
# diagnosis the operator has. Echoes the fakebin dir to prepend to PATH.
shim_broken_sed() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/sed" <<'SH'
#!/usr/bin/env bash
echo "sed: simulated tool failure" >&2
exit 1
SH
  chmod +x "$fakebin/sed"
  printf '%s\n' "$fakebin"
}

test_unknown_subcommand_is_rejected() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/missing" FM_ROOT_OVERRIDE="$ROOT" "$RELAY" fetch 2>&1); rc=$?
  expect_code 1 "$rc" "unknown subcommand"
  assert_contains "$out" "unknown subcommand 'fetch'" "unknown subcommand was not identified"
  assert_contains "$out" 'usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]' \
    "unknown subcommand did not print usage"
  pass "Bridge relay rejects every unlisted subcommand before checkout inspection"
}

test_dirty_checkout_is_rejected() {
  local home bridge out rc
  home=$(make_bridge dirty)
  bridge="$home/projects/coditan-bridge"
  printf 'uncommitted\n' > "$bridge/dirty.txt"

  out=$(run_relay "$home" send vessel payload --from tugboat); rc=$?
  expect_code 1 "$rc" "dirty checkout"
  assert_contains "$out" 'has uncommitted changes' "dirty checkout refusal was unclear"
  assert_absent "$home/capture" "dirty checkout still invoked the Bridge script"
  pass "Bridge relay refuses a dirty target checkout without dispatching"
}

test_non_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge off-default)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" checkout -qb feature

  out=$(run_relay "$home" status vessel busy); rc=$?
  expect_code 1 "$rc" "non-default branch"
  assert_contains "$out" "must be on default branch 'main' (found 'feature')" \
    "non-default branch refusal was unclear"
  assert_absent "$home/capture" "non-default branch still invoked the Bridge script"
  pass "Bridge relay refuses a checkout that is not on its default branch"
}

test_untracked_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge no-upstream)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" branch --unset-upstream

  out=$(run_relay "$home" inbox list); rc=$?
  expect_code 1 "$rc" "untracked default branch"
  assert_contains "$out" "default branch 'main' is not tracking an upstream" \
    "missing-upstream refusal was unclear"
  assert_absent "$home/capture" "untracked default branch still invoked the Bridge script"
  pass "Bridge relay refuses a default branch without an upstream"
}

test_valid_calls_dispatch_verbatim() {
  local home bridge subcommand capture out
  local -a args
  home=$(make_bridge valid)
  bridge="$home/projects/coditan-bridge"

  for subcommand in send inbox status broadcast; do
    capture="$home/capture"
    rm -f "$capture"
    # The two sender-bearing commands must name this home's vessel to run at all,
    # so they carry it here; the flag is forwarded like every other argument and
    # is never supplied, reordered, or rewritten by the relay.
    args=('argument with spaces' '--literal=*' '')
    case "$subcommand" in
      send | broadcast) args+=(--from tugboat) ;;
    esac
    out=$(relay_own_output "$(run_relay "$home" "$subcommand" "${args[@]}")")
    [ -z "$out" ] || fail "$subcommand dispatch produced unexpected output: $out"
    assert_grep "script=bridge-$subcommand.sh" "$capture" \
      "$subcommand did not select its matching Bridge script"
    assert_grep "cwd=$bridge" "$capture" "$subcommand did not run inside the Bridge checkout"
    assert_grep "argc=${#args[@]}" "$capture" "$subcommand did not preserve the argument count"
    assert_grep 'arg0=<argument with spaces>' "$capture" "$subcommand changed a spaced argument"
    assert_grep 'arg1=<--literal=*>' "$capture" "$subcommand expanded a literal argument"
    assert_grep 'arg2=<>' "$capture" "$subcommand dropped an empty argument"
  done
  pass "Bridge relay maps all four commands and forwards arguments verbatim from the checkout"
}

test_behind_checkout_is_refreshed_before_a_read() {
  local home out own rc
  home=$(make_bridge behind)
  publish_envelope_at_origin behind tugboat

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read against a behind checkout"
  own=$(relay_own_output "$out")
  [ -z "$own" ] || fail "read against a behind checkout produced unexpected output: $own"
  assert_grep 'seen=inbox/tugboat/new/2026-08-01T00-56-11Z-envelope.json' "$home/capture" \
    "the read still answered from a checkout that was behind origin"
  pass "Bridge relay brings the checkout current before a read, so mail at origin is visible"
}

test_stranded_checkout_refuses_a_read() {
  local home out rc
  home=$(make_bridge stranded)
  publish_envelope_at_origin stranded tugboat
  strand_clone stranded

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read against a checkout that cannot be refreshed"
  assert_contains "$out" 'STALE CHECKOUT' "stale refusal was not identified as such"
  assert_contains "$out" 'NOTHING WAS READ' \
    "stale refusal could be mistaken for an empty mailbox"
  assert_contains "$out" 'unread mail may be waiting at origin' \
    "stale refusal did not warn about mail left unread"
  # The refresh DID run here and reported a fetch failure, so the refusal must
  # report that outcome rather than claim the refresh never completed.
  assert_contains "$out" 'the refresh ran and was blocked by the outcome it reports below' \
    "stale refusal gave no reason"
  assert_contains "$out" 'skipped: fetch failed' "stale refusal did not quote the refresh outcome"
  assert_not_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that ran and reported a fetch failure was described as not having completed"
  assert_absent "$home/capture" "stale checkout still invoked the Bridge script"
  pass "Bridge relay refuses a read it cannot prove current, instead of answering empty"
}

test_no_outcome_refusal_surfaces_the_refresh_error() {
  local home out rc RELAY_PATH_PREFIX
  home=$(make_bridge no-outcome)
  publish_envelope_at_origin no-outcome tugboat
  strand_clone no-outcome
  # Supervision is down too, so fm-guard.sh's banner shares the captured stderr:
  # the diagnosis must be fleet-sync's error, never the guard's rule line.
  strand_watcher "$home"
  RELAY_PATH_PREFIX=$(shim_broken_sed "$home")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read after a refresh that reported no outcome"
  assert_contains "$out" 'STALE CHECKOUT' "no-outcome refusal was not identified as stale"
  assert_contains "$out" 'NOTHING WAS READ' \
    "no-outcome refusal could be mistaken for an empty mailbox"
  assert_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that reported nothing was not described as incomplete"
  assert_contains "$out" 'sed: simulated tool failure' \
    "the no-outcome refusal threw away the only diagnosis fleet-sync produced"
  assert_not_contains "$out" 'fm-fleet-sync.sh stderr: ●' \
    "the guard's banner rule line was mistaken for fleet-sync's error text"
  assert_absent "$home/capture" "a refresh that reported nothing still invoked the Bridge script"
  pass "Bridge relay surfaces fleet-sync's stderr when the refresh reported no outcome at all"
}

test_blocked_refusal_surfaces_the_refresh_error() {
  local home bridge out rc RELAY_PATH_PREFIX RELAY_FLEET_SYNC_RETRIES=1
  home=$(make_bridge blocked-diagnosis)
  bridge="$home/projects/coditan-bridge"
  publish_envelope_at_origin blocked-diagnosis tugboat
  git -C "$bridge" fetch -q origin main
  RELAY_PATH_PREFIX=$(shim_git_fetch_lock_contention "$home" "$bridge/.git/packed-refs.lock")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read blocked by a fetch failure on a behind clone"
  assert_contains "$out" 'STALE CHECKOUT' "blocked refusal was not identified as stale"
  assert_contains "$out" 'skipped: fetch failed' "blocked refusal did not quote the refresh outcome"
  # The one-line outcome omits what fleet-sync only says on stderr: how hard it
  # tried for the lock, and whether it could clear it.
  assert_contains "$out" 'fm-fleet-sync.sh stderr: coditan-bridge: fetch blocked by packed-refs lock' \
    "the blocked refusal dropped the lock context fleet-sync reported on stderr"
  assert_absent "$home/capture" "a blocked refusal still invoked the Bridge script"
  pass "Bridge relay surfaces fleet-sync's stderr on a blocked refusal, not only a no-outcome one"
}

test_write_warning_surfaces_the_refresh_error() {
  local home bridge out rc RELAY_PATH_PREFIX RELAY_FLEET_SYNC_RETRIES=1
  home=$(make_bridge write-diagnosis)
  bridge="$home/projects/coditan-bridge"
  publish_envelope_at_origin write-diagnosis tugboat
  git -C "$bridge" fetch -q origin main
  RELAY_PATH_PREFIX=$(shim_git_fetch_lock_contention "$home" "$bridge/.git/packed-refs.lock")

  out=$(run_relay "$home" send hlr status subject --from tugboat); rc=$?
  expect_code 0 "$rc" "write against a checkout the refresh could not prove current"
  assert_contains "$out" 'not proven current' "the write dispatched with no warning at all"
  assert_contains "$out" 'skipped: fetch failed' "the write warning did not quote the refresh outcome"
  # The verdict without its context is the half the operator cannot act on.
  assert_contains "$out" 'fm-fleet-sync.sh stderr: coditan-bridge: fetch blocked by packed-refs lock' \
    "the write warning dropped the lock context fleet-sync reported on stderr"
  assert_grep 'script=bridge-send.sh' "$home/capture" "the warned write never reached the Bridge script"
  pass "Bridge relay hands the write-shaped warning the same fleet-sync diagnosis the refusal gets"
}

test_recovered_refresh_is_never_silent() {
  local home out rc RELAY_BIN
  home=$(make_bridge recovered)
  # fleet-sync reports its lock recovery on stdout, ahead of the outcome line,
  # and the clone it recovered is current, so nothing else here would speak.
  RELAY_BIN=$(stub_fleet_sync "$home" "coditan-bridge: recovered: removed a stale packed-refs lock (no live holder)
coditan-bridge: already current")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read after a refresh that removed a stale lock"
  assert_contains "$out" 'the refresh repaired the Bridge checkout: removed a stale packed-refs lock' \
    "a relay call deleted a lock file inside the Bridge clone's .git without saying so"
  assert_grep 'script=bridge-inbox.sh' "$home/capture" \
    "the recovered read never reached the Bridge script"
  pass "Bridge relay reports a refresh that repaired the Bridge checkout, on the dispatching path too"
}

test_unrecognised_outcome_vocabulary_refuses_a_read() {
  local home out rc RELAY_BIN
  home=$(make_bridge vocab-drift)
  # A clone that is perfectly current, refreshed by a fleet sync that succeeded
  # and said so in wording classify_refresh_line does not know.
  RELAY_BIN=$(stub_fleet_sync "$home" "coditan-bridge: up to date")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read after a refresh whose outcome wording is unrecognised"
  assert_contains "$out" 'STALE CHECKOUT' "vocabulary-drift refusal was not identified as stale"
  assert_contains "$out" 'NOTHING WAS READ' \
    "vocabulary-drift refusal could be mistaken for an empty mailbox"
  assert_contains "$out" 'exited 0 but printed no outcome' \
    "a refresh that succeeded was not named as a vocabulary mismatch"
  assert_contains "$out" 'reconcile classify_refresh_line' \
    "vocabulary-drift refusal did not point at reconciling the two vocabularies"
  assert_not_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that exited 0 was described as not having completed"
  assert_absent "$home/capture" "vocabulary-drift refusal still invoked the Bridge script"
  pass "Bridge relay names a drifted fleet-sync outcome vocabulary instead of looping on the fleet sync"
}

test_guard_alarm_reaches_the_caller() {
  local home out rc
  home=$(make_bridge guarded)
  strand_watcher "$home"

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read on a current clone while supervision is down"
  assert_contains "$out" 'WATCHER DAEMON DOWN - SUPERVISION IS OFF' \
    "the guard's once-per-episode alarm was swallowed by the relay's stderr capture"
  assert_grep 'script=bridge-inbox.sh' "$home/capture" \
    "the guarded read never reached the Bridge script"

  # The full banner is spent for this episode; the reminder that replaces it must
  # reach the caller too, on the refusal path as well as the dispatching one.
  rm -f "$home/capture"
  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "second read while supervision is down"
  assert_contains "$out" 'WARNING: watcher still down' \
    "the guard's episode reminder was swallowed by the relay's stderr capture"

  publish_envelope_at_origin guarded tugboat
  strand_clone guarded
  rm -f "$home/capture"
  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "refused read while supervision is down"
  assert_contains "$out" 'STALE CHECKOUT' "the refusal was lost while supervision was down"
  assert_contains "$out" 'WARNING: watcher still down' \
    "a refusing call swallowed the guard's episode reminder"

  # The guard's other two alarms are independent of the stale-episode dedup and
  # are meant to be seen on every fleet action, so they must be relayed too, and
  # never re-attributed to fleet-sync.
  fm_test_record_supervision_healthy "$home"
  rm -rf "$home/state/.delivery.lock"
  printf 'wake\n' > "$home/state/.wake-queue"
  rm -f "$home/capture"
  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read while the wake stub is missing and wakes are queued"
  assert_contains "$out" 'WARNING: wake delivery listener down:' \
    "the guard's down-listener alarm was swallowed by the relay's stderr capture"
  assert_contains "$out" 'WARNING: queued wakes pending' \
    "the guard's queued-wakes alarm was swallowed by the relay's stderr capture"
  assert_not_contains "$out" 'fm-fleet-sync.sh stderr: WARNING: queued wakes pending' \
    "a guard alarm was re-attributed to fleet-sync's error text"
  pass "Bridge relay passes fm-guard.sh's supervision alarms through to its own stderr"
}

test_diverged_checkout_refuses_a_read() {
  local home bridge out rc
  home=$(make_bridge diverged)
  bridge="$home/projects/coditan-bridge"
  publish_envelope_at_origin diverged tugboat
  printf 'local\n' > "$bridge/local.txt"
  git -C "$bridge" add local.txt
  git -C "$bridge" commit -qm "local-only commit"

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read against a diverged checkout"
  assert_contains "$out" 'STALE CHECKOUT' "diverged refusal was not identified as stale"
  assert_contains "$out" 'STUCK: on diverged main' "diverged refusal did not relay the refresh outcome"
  assert_contains "$out" 'reported the clone stuck' "diverged refusal misstated why it refused"
  # A refusal names the distance it actually measured. This clone is genuinely
  # behind as well as ahead, and saying so is what keeps the refusal from
  # contradicting a count of 0 the way it did when it just asserted staleness.
  assert_contains "$out" "is 1 commit(s) behind origin/main" \
    "diverged refusal did not say how far behind the clone actually is"
  assert_not_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that ran and proved the clone stuck was described as not having completed"
  # The remedy must not be the command that just produced the STUCK line: fleet
  # sync never forces, resets, or pushes, so re-running it can never clear this.
  assert_contains "$out" "reconcile $bridge with " "diverged refusal did not ask for manual reconciliation"
  assert_not_contains "$out" 'bin/fm-fleet-sync.sh coditan-bridge' \
    "diverged refusal sent the operator back to the command that just reported STUCK"
  assert_absent "$home/capture" "diverged checkout still invoked the Bridge script"
  pass "Bridge relay refuses a read when the checkout cannot be fast-forwarded"
}

test_ahead_only_checkout_still_answers_a_read() {
  local home bridge out rc
  home=$(make_bridge ahead-only)
  bridge="$home/projects/coditan-bridge"
  # The window a Bridge publish leaves open between its commit and its push, and
  # the state a publish that failed after committing leaves behind: the clone is
  # ahead of origin and holds everything origin holds, so a read is answerable.
  # fleet-sync reports that as STUCK on a diverged default branch all the same.
  printf 'outbound\n' > "$bridge/outbound.txt"
  git -C "$bridge" add outbound.txt
  git -C "$bridge" commit -qm "publish committed but not yet pushed"

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read against a clone that is only ahead of origin"
  assert_not_contains "$out" 'STALE CHECKOUT' "a clone that is only ahead of origin was called stale"
  assert_contains "$out" 'STUCK: on diverged main' \
    "the read proceeded without naming the blocked outcome it proceeded through"
  assert_contains "$out" 'holds everything that fetch brought back' \
    "the relaxed read never said why it proceeded through a blocked refresh"
  assert_grep 'script=bridge-inbox.sh' "$home/capture" \
    "a read on a clone that is level with everything origin holds was refused"
  pass "Bridge relay reads a clone that is only ahead of origin instead of calling it stale"
}

test_upstream_that_is_not_the_fetched_ref_refuses_a_read() {
  local home bridge out rc
  home=$(make_bridge mirror-upstream)
  bridge="$home/projects/coditan-bridge"
  # Mail waits at origin, the clone holds a commit of its own, and its branch
  # tracks a mirror that sits exactly at HEAD. The fleet sync fetches origin and
  # reports the clone stuck on a diverged default branch; a distance taken
  # against the mirror would read 0 and answer the read from a stale mailbox,
  # which is the original defect this whole guard exists to prevent.
  publish_envelope_at_origin mirror-upstream tugboat
  printf 'local\n' > "$bridge/local.txt"
  git -C "$bridge" add local.txt
  git -C "$bridge" commit -qm "local-only commit"
  add_level_mirror_upstream mirror-upstream

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read against a clone tracking a ref the refresh never fetched"
  assert_contains "$out" 'STALE CHECKOUT' "a level mirror was accepted as proof of currency"
  assert_contains "$out" 'NOTHING WAS READ' \
    "the mirror-tracked refusal could be mistaken for an empty mailbox"
  assert_contains "$out" "is 1 commit(s) behind origin/main" \
    "the refusal did not measure the clone against the ref the refresh actually fetched"
  assert_not_contains "$out" 'holds everything that fetch brought back' \
    "the relay claimed the clone held everything origin holds while mail waited at origin"
  assert_absent "$home/capture" \
    "a read measured against an unfetched ref still invoked the Bridge script"
  pass "Bridge relay measures currency against the ref the refresh fetched, not whatever the branch tracks"
}

test_unproven_fetch_still_refuses_a_level_read() {
  local home out rc RELAY_BIN outcome
  home=$(make_bridge unproven-fetch)
  # Level with origin, but each of these outcomes was reported at a step that
  # proves nothing about the fetch, so @{upstream} may be stale and the count
  # means nothing. The last two are the shape a pre-fetch skip added to
  # fm-fleet-sync.sh later would take: an outcome this relay has never seen must
  # never be read as proof that origin was reached, however close its wording
  # comes to a form that is.
  for outcome in "skipped: no origin remote" "skipped: data/projects.md does not exist" \
      "skipped: cannot read data/projects.md"; do
    RELAY_BIN=$(stub_fleet_sync "$home" "coditan-bridge: $outcome")
    rm -f "$home/capture"
    out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
    expect_code 1 "$rc" "read after the refresh reported '$outcome'"
    assert_contains "$out" 'STALE CHECKOUT' "'$outcome' was accepted as proof of a fetch"
    assert_contains "$out" 'never proved it updated' \
      "the refusal for '$outcome' did not say the count of 0 rests on an unproven ref"
    assert_absent "$home/capture" "'$outcome' still invoked the Bridge script"
  done
  pass "Bridge relay takes a level count as proof only for outcomes that prove the fetch ran"
}

test_post_fetch_block_on_a_level_clone_reads() {
  local home out rc RELAY_BIN outcome
  home=$(make_bridge post-fetch-block)
  # The other side of the same whitelist: every outcome fleet-sync can only
  # reach past a successful fetch does prove the fetch, so a clone holding
  # everything that fetch brought back still answers a read.
  for outcome in "skipped: local main does not exist" "skipped: origin/main does not exist" \
      "skipped: cannot read local main" "skipped: cannot read origin/main" \
      "skipped: cannot determine default branch" \
      "skipped: fast-forward failed: fatal: refusing to merge unrelated histories"; do
    RELAY_BIN=$(stub_fleet_sync "$home" "coditan-bridge: $outcome")
    rm -f "$home/capture"
    out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
    expect_code 0 "$rc" "read after the refresh reported '$outcome' on a level clone"
    assert_contains "$out" 'holds everything that fetch brought back' \
      "'$outcome' was not recognised as an outcome that proves the fetch ran"
    assert_grep 'script=bridge-inbox.sh' "$home/capture" \
      "'$outcome' on a level clone never reached the Bridge script"
  done
  pass "Bridge relay still reads a level clone through every block that proves its fetch ran"
}

test_unrecognized_status_form_refuses_a_read() {
  local home out rc form
  home=$(make_bridge status-forms)
  publish_envelope_at_origin status-forms tugboat
  strand_clone status-forms

  # Anything not positively recognised as a write is a read: an unrecognised
  # status spelling must refuse, never answer from a clone proven not current.
  for form in "status" "status --vessel tugboat" "status --show=tugboat" "status --list"; do
    rm -f "$home/capture"
    # shellcheck disable=SC2086
    out=$(run_relay "$home" $form); rc=$?
    expect_code 1 "$rc" "unrecognised status form '$form' against a stranded checkout"
    assert_contains "$out" 'STALE CHECKOUT' "status form '$form' did not refuse as a read"
    assert_absent "$home/capture" "status form '$form' still invoked the Bridge script"
  done
  pass "Bridge relay treats every status form it cannot recognise as a write as a read that refuses"
}

test_lock_contention_proceeds_only_while_level() {
  local home bridge out rc RELAY_PATH_PREFIX RELAY_FLEET_SYNC_RETRIES=0
  home=$(make_bridge contended)
  bridge="$home/projects/coditan-bridge"
  RELAY_PATH_PREFIX=$(shim_git_fetch_lock_contention "$home" "$bridge/.git/packed-refs.lock")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read while the refresh lost a lock race on a level clone"
  assert_contains "$out" 'lost a race for a git lock' \
    "the relaxed read never said it proceeded on a contended refresh"
  assert_grep 'script=bridge-inbox.sh' "$home/capture" \
    "a read on a provably level clone was refused over mere lock contention"

  # Same contention, but the clone is provably behind: nothing is proven now, so
  # the read must still refuse.
  publish_envelope_at_origin contended tugboat
  git -C "$bridge" fetch -q origin main
  rm -f "$home/capture"
  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read while the refresh lost a lock race on a behind clone"
  assert_contains "$out" 'STALE CHECKOUT' "contended refresh on a behind clone did not refuse"
  assert_absent "$home/capture" "contended refresh on a behind clone still invoked the Bridge script"
  pass "Bridge relay proceeds through lock contention only while the clone is provably level"
}

test_fast_forward_lock_contention_proceeds_when_level() {
  local home bridge out rc RELAY_PATH_PREFIX
  home=$(make_bridge contended-ff)
  bridge="$home/projects/coditan-bridge"
  publish_envelope_at_origin contended-ff tugboat
  # The fetch succeeds and the fast-forward is the step that loses the race, on
  # .git/index.lock rather than .git/packed-refs.lock - the likelier collision
  # with the session-start whole-fleet sync, and the one that leaves the clone
  # level because the winner moved it.
  RELAY_PATH_PREFIX=$(shim_git_merge_lock_contention "$home" "$bridge/.git/index.lock")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read after the fast-forward lost a lock race on a clone left level"
  assert_contains "$out" 'lost a race for a git lock' \
    "the relaxed read never said it proceeded on a contended fast-forward"
  assert_grep 'seen=inbox/tugboat/new/2026-08-01T00-56-11Z-envelope.json' "$home/capture" \
    "a read on a clone the winning sync had already moved level was refused"
  pass "Bridge relay treats a fast-forward that lost .git/index.lock as contention, not staleness"
}

test_only_read_shaped_calls_refuse() {
  local home out rc capture
  home=$(make_bridge shapes)
  publish_envelope_at_origin shapes tugboat
  strand_clone shapes
  capture="$home/capture"

  rm -f "$capture"
  out=$(run_relay "$home" status --show tugboat); rc=$?
  expect_code 1 "$rc" "status --show against a stranded checkout"
  assert_contains "$out" 'STALE CHECKOUT' "status --show did not refuse as a read"
  assert_absent "$capture" "status --show still invoked the Bridge script"

  # A publishing call still dispatches: its own publish path reconciles with
  # origin, and refusing it would strand outbound traffic rather than protect it.
  for args in "send hlr status subject --from tugboat" "broadcast status subject --from tugboat" \
      "status --push --vessel tugboat" "inbox --gc --vessel tugboat"; do
    rm -f "$capture"
    # shellcheck disable=SC2086
    out=$(run_relay "$home" $args); rc=$?
    expect_code 0 "$rc" "publishing call '$args' against a stranded checkout"
    assert_contains "$out" 'not proven current' "publishing call '$args' dispatched with no warning"
    assert_grep 'script=bridge-' "$capture" "publishing call '$args' never reached the Bridge script"
  done
  pass "Bridge relay refuses only the read-shaped calls and warns on the publishing ones"
}

# --- sender identity ---------------------------------------------------------
# MEASURED 2026-08-20: a worker of a home whose config/bridge-vessel reads `hlr`
# sent a Bridge envelope with `--from tugboat`. It was published correctly and
# attributed to a vessel that did not send it, so a reply addressed to its sender
# would have reached the wrong seat. Nothing on this path read this home's own
# identity, so nothing could disagree with the claim the caller wrote.

test_a_sender_that_is_not_this_home_is_refused() {
  local home out rc
  home=$(make_bridge wrong-sender)
  set_home_vessel "$home" 'hlr'
  # Stranded on purpose: a sender-bearing call against a checkout the refresh
  # cannot prove current normally warns and dispatches, so a refusal here also
  # shows the identity check runs before the refresh rather than after it.
  publish_envelope_at_origin wrong-sender coditan
  strand_clone wrong-sender

  out=$(run_relay "$home" send coditan research 'Firstmate PR handover' --from tugboat); rc=$?
  expect_code 1 "$rc" "send as a vessel this home is not"
  assert_contains "$out" 'SENDER IDENTITY MISMATCH' "the wrong-sender refusal was unclear"
  assert_contains "$out" "requested sender: 'tugboat'" "the refusal did not name the requested sender"
  assert_contains "$out" "this home's Bridge identity: 'hlr'" \
    "the refusal did not name the vessel this home actually is"
  assert_contains "$out" 'NOTHING WAS SENT' "the refusal did not say the send never happened"
  assert_not_contains "$out" 'not proven current' \
    "the identity check ran after the refresh instead of before it"
  assert_absent "$home/capture" "the misattributed send still reached the Bridge script"
  pass "Bridge relay refuses a send whose sender is not the vessel this home is"
}

test_the_sender_that_is_this_home_dispatches() {
  local home out
  home=$(make_bridge right-sender)
  set_home_vessel "$home" 'hlr'

  # The trailing pair sits after `--`, where the Bridge parsers read it as
  # positional text rather than as a second sender, and this guard reads it the
  # same way.
  out=$(relay_own_output "$(run_relay "$home" send coditan research subject --from hlr -- --from tugboat)")
  [ -z "$out" ] || fail "a correctly attributed send produced unexpected output: $out"
  assert_grep 'script=bridge-send.sh' "$home/capture" "a correctly attributed send never dispatched"
  assert_grep 'arg3=<--from>' "$home/capture" "the sender flag was not forwarded"
  assert_grep 'arg4=<hlr>' "$home/capture" "the sender value was not forwarded"
  assert_grep 'argc=8' "$home/capture" "the relay did not forward the arguments unchanged"
  pass "Bridge relay dispatches a send that names this home, forwarding it unchanged"
}

test_a_send_with_no_sender_names_this_home() {
  local home out rc
  home=$(make_bridge no-sender)
  set_home_vessel "$home" 'hlr'

  out=$(run_relay "$home" send coditan research subject); rc=$?
  expect_code 1 "$rc" "send with no sender"
  assert_contains "$out" "refusing to run 'send' without --from" "the missing-sender refusal was unclear"
  assert_contains "$out" "this home's Bridge identity is 'hlr'" \
    "the missing-sender refusal did not name the vessel the caller should have written"
  assert_contains "$out" 'never supplies a sender the caller did not write' \
    "the missing-sender refusal did not say the relay will not fill the value in"
  assert_absent "$home/capture" "the senderless send still reached the Bridge script"
  pass "Bridge relay refuses a send with no sender and names the vessel this home is"
}

test_an_identity_it_cannot_resolve_refuses_the_send() {
  local home out rc empty_root
  home=$(make_bridge unresolved)
  empty_root="$TMP_ROOT/unresolved/empty-root"
  mkdir -p "$empty_root"

  # No record at all.
  set_home_vessel "$home"
  out=$(RELAY_ROOT_OVERRIDE="$empty_root" run_relay "$home" send coditan research subject --from hlr); rc=$?
  expect_code 1 "$rc" "send from a home with no identity record"
  assert_contains "$out" 'SENDER IDENTITY UNRESOLVED' "the missing-record refusal was unclear"
  assert_contains "$out" 'has no Bridge identity record' "the refusal did not say the record is missing"
  assert_absent "$home/capture" "a send from a home with no identity still dispatched"

  # A record that holds only whitespace.
  set_home_vessel "$home" '   '
  out=$(RELAY_ROOT_OVERRIDE="$empty_root" run_relay "$home" send coditan research subject --from hlr); rc=$?
  expect_code 1 "$rc" "send from a home whose identity record is empty"
  assert_contains "$out" 'identity record is empty' "the empty-record refusal was unclear"
  assert_absent "$home/capture" "a send from an empty identity record still dispatched"

  # A record naming several vessels: that is a list of inboxes to watch, and the
  # relay refuses it rather than resolving it to its first word, because picking
  # one would be a guess and the guess is the defect.
  set_home_vessel "$home" 'hlr tugboat'
  out=$(RELAY_ROOT_OVERRIDE="$empty_root" run_relay "$home" send coditan research subject --from hlr); rc=$?
  expect_code 1 "$rc" "send from a home whose identity record names several vessels"
  assert_contains "$out" 'names 2 vessels (hlr tugboat)' "the multi-vessel refusal did not quote the record"
  assert_absent "$home/capture" "a send from a multi-vessel identity record still dispatched"
  pass "Bridge relay refuses a send whenever it cannot resolve this home to exactly one vessel"
}

test_a_second_sender_spelling_cannot_slip_past() {
  local home out rc
  home=$(make_bridge two-senders)
  set_home_vessel "$home" 'hlr'

  # The Bridge parsers keep the LAST --from, so a guard that approved on the
  # first would let the second carry another vessel's name onto the envelope.
  out=$(run_relay "$home" send coditan research subject --from hlr --from tugboat); rc=$?
  expect_code 1 "$rc" "send whose second sender flag names another vessel"
  assert_contains "$out" "requested sender: 'tugboat'" "the refusal read the wrong sender flag"
  assert_absent "$home/capture" "a send with a trailing wrong sender still dispatched"

  rm -f "$home/capture"
  out=$(run_relay "$home" send coditan research subject --from tugboat --from hlr); rc=$?
  expect_code 1 "$rc" "send whose first sender flag names another vessel"
  assert_contains "$out" "requested sender: 'tugboat'" "the refusal missed the leading sender flag"
  assert_absent "$home/capture" "a send with a leading wrong sender still dispatched"
  pass "Bridge relay checks every sender spelling in the call, not just one of them"
}

test_a_broadcast_is_guarded_like_a_send() {
  local home out rc
  home=$(make_bridge wrong-broadcast)
  set_home_vessel "$home" 'hlr'

  out=$(run_relay "$home" broadcast directive subject --from tugboat); rc=$?
  expect_code 1 "$rc" "broadcast as a vessel this home is not"
  assert_contains "$out" 'SENDER IDENTITY MISMATCH' "the wrong-sender broadcast refusal was unclear"
  assert_contains "$out" "refusing to run 'broadcast'" "the refusal did not name the broadcast"
  assert_absent "$home/capture" "the misattributed broadcast still reached the Bridge script"
  pass "Bridge relay guards a broadcast's sender exactly as it guards a send's"
}

test_reads_and_help_are_not_sender_guarded() {
  local home out rc empty_root
  home=$(make_bridge unguarded)
  empty_root="$TMP_ROOT/unguarded/empty-root"
  mkdir -p "$empty_root"
  # A home with no identity at all: a read still answers and a help request still
  # prints, because neither composes an envelope and neither can misattribute one.
  set_home_vessel "$home"

  local call
  for call in "inbox --vessel tugboat" "status --show tugboat" "send --help" "broadcast -h"; do
    rm -f "$home/capture"
    # shellcheck disable=SC2086
    out=$(relay_own_output "$(RELAY_ROOT_OVERRIDE="$empty_root" run_relay "$home" $call)"); rc=$?
    expect_code 0 "$rc" "'$call' from a home with no identity record"
    [ -z "$out" ] || fail "'$call' produced unexpected output: $out"
    assert_grep 'script=bridge-' "$home/capture" "'$call' was refused for an identity it never needed"
  done
  pass "Bridge relay guards only the calls that carry a sender, never a read or a help request"
}

test_unknown_subcommand_is_rejected
test_dirty_checkout_is_rejected
test_non_default_branch_is_rejected
test_untracked_default_branch_is_rejected
test_valid_calls_dispatch_verbatim
test_behind_checkout_is_refreshed_before_a_read
test_stranded_checkout_refuses_a_read
test_no_outcome_refusal_surfaces_the_refresh_error
test_blocked_refusal_surfaces_the_refresh_error
test_write_warning_surfaces_the_refresh_error
test_recovered_refresh_is_never_silent
test_unrecognised_outcome_vocabulary_refuses_a_read
test_guard_alarm_reaches_the_caller
test_diverged_checkout_refuses_a_read
test_ahead_only_checkout_still_answers_a_read
test_upstream_that_is_not_the_fetched_ref_refuses_a_read
test_unproven_fetch_still_refuses_a_level_read
test_post_fetch_block_on_a_level_clone_reads
test_unrecognized_status_form_refuses_a_read
test_lock_contention_proceeds_only_while_level
test_fast_forward_lock_contention_proceeds_when_level
test_only_read_shaped_calls_refuse
test_a_sender_that_is_not_this_home_is_refused
test_the_sender_that_is_this_home_dispatches
test_a_send_with_no_sender_names_this_home
test_an_identity_it_cannot_resolve_refuses_the_send
test_a_second_sender_spelling_cannot_slip_past
test_a_broadcast_is_guarded_like_a_send
test_reads_and_help_are_not_sender_guarded
