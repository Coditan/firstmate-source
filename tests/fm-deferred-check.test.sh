#!/usr/bin/env bash
# Behavior tests for bin/fm-deferred-check.sh, the mechanism that takes a
# session-start check off the critical path.
#
# The property under test is not speed but honesty: a deferred check must reach
# the session exactly once, whether it beats the digest or outlives it, and a
# clean result must arrive just as loudly as a finding - a check whose silence
# is indistinguishable from an all-clear is the defect this exists against.
# Network-free throughout: every deferred command here is a local script.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-deferred-check-tests

DEFER="$ROOT/bin/fm-deferred-check.sh"

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Wait, in real time, for a runner to finish. Bounded so a wedged runner fails
# the case instead of hanging the suite.
wait_for_done() {  # <home> <name>
  local home=$1 name=$2 waited=0 dir
  while [ "$waited" -lt 200 ]; do
    dir=$(current_generation "$home" "$name")
    [ -z "$dir" ] || [ ! -f "$dir/done" ] || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
}

current_generation() {  # <home> <name>
  local home=$1 name=$2 generation
  generation=$(cat "$home/state/.deferred/$name/current" 2>/dev/null || true)
  [ -z "$generation" ] || printf '%s\n' "$home/state/.deferred/$name/$generation"
}

wait_for_wake() {  # <home>
  local home=$1 waited=0
  while [ ! -s "$home/state/.wake-queue" ] && [ "$waited" -lt 200 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}

test_a_finished_run_is_collected_into_the_digest() {
  local home out rc=0
  home=$(new_home finished-inline)
  FM_HOME="$home" "$DEFER" start quick -- printf 'QUICK: a finding\n' >/dev/null
  wait_for_done "$home" quick
  out=$(FM_HOME="$home" "$DEFER" collect quick) || rc=$?
  [ "$rc" -eq 0 ] || fail "collect of a finished run should exit 0, got $rc"
  assert_contains "$out" 'QUICK: a finding' "collect should print the run's own output verbatim"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a result the digest took must not also be queued as a wake: $(cat "$home/state/.wake-queue")"
  pass "a run that beats the digest is printed in the digest and wakes nobody"
}

test_a_pending_run_reports_pending_and_delivers_by_wake() {
  local home out rc=0 queue
  home=$(new_home pending-then-wake)
  FM_HOME="$home" "$DEFER" start slow -- \
    bash -c 'sleep 2; printf "SLOW: a finding nobody may lose\n"' >/dev/null
  out=$(FM_HOME="$home" "$DEFER" collect slow) || rc=$?
  [ "$rc" -eq 3 ] || fail "collect of an unfinished run should exit 3 (pending), got $rc"
  [ -z "$out" ] || fail "a pending collect must print nothing, so the caller owns the wording: $out"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'check	slow' "the late result should arrive as a check wake keyed by the check name"
  assert_contains "$queue" 'SLOW: a finding nobody may lose' "the wake payload should carry the finding"
  assert_contains "$queue" "$home/state/.deferred/slow/run-" "the wake should name the result generation"
  pass "a run that outlives the digest reports pending and then delivers its finding as a wake"
}

test_a_clean_late_result_still_wakes() {
  local home queue rc=0
  home=$(new_home clean-late)
  FM_HOME="$home" "$DEFER" start clean -- bash -c 'sleep 2; exit 0' >/dev/null
  FM_HOME="$home" "$DEFER" collect clean >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "expected pending, got $rc"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'completed with nothing to report' \
    "a clean result must be stated, because an unanswered pending line reads as an all-clear nobody checked"
  pass "a clean run that outlives the digest still says so"
}

test_a_nonzero_late_result_reports_failure() {
  local home queue rc=0
  home=$(new_home failed-late)
  FM_HOME="$home" "$DEFER" start failed -- bash -c 'sleep 2; exit 23' >/dev/null
  FM_HOME="$home" "$DEFER" collect failed >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "expected pending, got $rc"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'DEFERRED_CHECK_FAILED: failed: command exited with status 23' \
    "a nonzero command with no output must report its exit status"
  assert_not_contains "$queue" 'completed with nothing to report' \
    "a nonzero command must not be reported as clean"
  pass "a nonzero late result reports failure rather than clean completion"
}

test_a_long_nonzero_result_keeps_failure_visible() {
  local home dir queue out rc=0
  home=$(new_home long-failed-late)
  FM_DEFERRED_CHECK_PAYLOAD_MAX=100 FM_HOME="$home" "$DEFER" start failed -- \
    bash -c 'sleep 2; head -c 1000 /dev/zero | tr "\\0" x; exit 27' >/dev/null
  dir=$(current_generation "$home" failed)
  FM_HOME="$home" "$DEFER" collect failed >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "expected pending, got $rc"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  out=$(cat "$dir/out" 2>/dev/null || true)
  assert_contains "$queue" 'DEFERRED_CHECK_FAILED: failed: command exited with status 27' \
    "truncation must not hide failure metadata from the wake"
  assert_contains "$out" 'DEFERRED_CHECK_FAILED: failed: command exited with status 27' \
    "the durable result must preserve failure metadata"
  pass "a long failed result keeps failure metadata in its wake and durable output"
}

test_a_nonzero_inline_result_reports_failure() {
  local home out rc=0
  home=$(new_home failed-inline)
  FM_HOME="$home" "$DEFER" start failed -- bash -c 'exit 19' >/dev/null
  wait_for_done "$home" failed
  out=$(FM_HOME="$home" "$DEFER" collect failed) || rc=$?
  [ "$rc" -eq 0 ] || fail "collect of a finished failed run should exit 0, got $rc"
  assert_contains "$out" 'DEFERRED_CHECK_FAILED: failed: command exited with status 19' \
    "inline collection must report a nonzero exit status"
  pass "a nonzero result collected inline reports failure"
}

test_a_missing_output_is_reported_as_failure() {
  local home dir out rc=0
  home=$(new_home missing-output)
  mkdir -p "$home/state/.deferred/missing/run-manual"
  printf 'run-manual\n' > "$home/state/.deferred/missing/current"
  dir="$home/state/.deferred/missing/run-manual"
  printf '0\n' > "$dir/status"
  : > "$dir/done"
  out=$(FM_HOME="$home" "$DEFER" collect missing) || rc=$?
  [ "$rc" -eq 0 ] || fail "collect of a recorded result should exit 0, got $rc"
  assert_contains "$out" 'DEFERRED_CHECK_FAILED: missing: recorded output is unreadable or missing' \
    "a missing result file must be explicit"
  pass "a missing recorded output is reported as failure"
}

test_a_launch_failure_is_not_pending() {
  local home rc=0 collect_rc=0
  home="$TMP_ROOT/launch-failure/state-file"
  mkdir -p "$(dirname "$home")"
  : > "$home"
  FM_STATE_OVERRIDE="$home" "$DEFER" start failed -- true >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a launch whose state cannot be created should exit 1, got $rc"
  FM_STATE_OVERRIDE="$home" "$DEFER" collect failed >/dev/null 2>&1 || collect_rc=$?
  [ "$collect_rc" -eq 1 ] || fail "a collector with no runner should report failure (1), not pending; got $collect_rc"
  pass "a launch failure is distinguishable from a genuinely running check"
}

test_a_dead_unfinished_generation_is_reported() {
  local home dir out
  home=$(new_home dead-generation)
  dir="$home/state/.deferred/dead/run-abandoned"
  mkdir -p "$dir"
  printf 'run-abandoned\n' > "$home/state/.deferred/dead/current"
  printf '99999999\n' > "$dir/pid"
  out=$(FM_HOME="$home" "$DEFER" start dead -- printf 'fresh result\n')
  assert_contains "$out" 'DEFERRED_CHECK_FAILED: dead: previous runner exited before publishing a result' \
    "an abandoned current generation must be reported before replacement"
  pass "a dead unfinished generation receives an explicit terminal result"
}

test_a_reused_pid_is_reported_as_abandoned() {
  local home dir out sleeper
  home=$(new_home reused-pid)
  dir="$home/state/.deferred/reused/run-abandoned"
  mkdir -p "$dir"
  sleep 10 &
  sleeper=$!
  printf 'run-abandoned\n' > "$home/state/.deferred/reused/current"
  printf '%s\n' "$sleeper" > "$dir/pid"
  printf 'linux-starttime=0\n' > "$dir/pid-identity"
  out=$(FM_HOME="$home" "$DEFER" start reused -- printf 'fresh result\n')
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  assert_contains "$out" 'DEFERRED_CHECK_FAILED: reused: previous runner exited before publishing a result' \
    "a live reused pid with the wrong incarnation must take the abandoned path"
  pass "a mismatched runner incarnation is not reported as pending"
}

test_pid_publication_failure_leaves_no_runner() {
  local home fake_bin marker queue rc=0
  home=$(new_home pid-publication-failure)
  fake_bin="$home/fake-bin"
  marker="$home/command-ran"
  mkdir -p "$fake_bin"
  # shellcheck disable=SC2016 # The fake script must expand these expressions when it runs.
  printf '#!/usr/bin/env bash\n/bin/mv "$@" || exit\ncase "${!#}" in */current) generation=$(cat "${!#}"); mkdir "$(dirname "${!#}")/$generation/pid" ;; esac\n' > "$fake_bin/mv"
  chmod +x "$fake_bin/mv"
  # shellcheck disable=SC2016 # The inner shell must expand its positional argument.
  PATH="$fake_bin:$PATH" FM_HOME="$home" "$DEFER" start handshake -- \
    bash -c 'printf ran > "$1"' _ "$marker" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a failed pid publication should report launch failure, got $rc"
  sleep 1
  [ ! -e "$marker" ] || fail "the command ran after pid publication failed"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -z "$queue" ] || fail "a failed launch left a runner able to wake: $queue"
  pass "pid publication failure terminates the unready runner"
}

test_generations_isolate_previous_handoffs() {
  local home old_dir out queue rc=0
  home=$(new_home generation-handoffs)
  FM_DEFERRED_CHECK_HANDOFF_TIMEOUT=10 FM_HOME="$home" "$DEFER" start same -- printf 'OLD RESULT\n' >/dev/null
  wait_for_done "$home" same
  old_dir=$(current_generation "$home" same)
  out=$(FM_HOME="$home" "$DEFER" start same -- bash -c 'sleep 2; printf "NEW RESULT\\n"')
  assert_contains "$out" 'OLD RESULT' "the next start should carry the prior undelivered result"
  FM_HOME="$home" "$DEFER" collect same >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "the new generation should be pending, got $rc"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'NEW RESULT' "the new generation should deliver its own result"
  assert_not_contains "$queue" 'OLD RESULT' "the old runner must not cross into the new handoff"
  [ -d "$old_dir/delivered" ] || fail "the old generation should retain its own delivery claim"
  pass "each generation owns an isolated handoff"
}

test_publication_failure_still_wakes() {
  local home fake_bin queue rc=0
  home=$(new_home publication-failure)
  fake_bin="$home/fake-bin"
  mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\ncase "$*" in *out.part*out*) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$fake_bin/mv"
  chmod +x "$fake_bin/mv"
  PATH="$fake_bin:$PATH" FM_HOME="$home" "$DEFER" start broken -- bash -c 'sleep 2; printf "COMMAND RAN\\n"' >/dev/null
  PATH="$fake_bin:$PATH" FM_HOME="$home" "$DEFER" collect broken >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "the running check should initially report pending, got $rc"
  wait_for_wake "$home"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'DEFERRED_CHECK_FAILED: broken: runner could not publish its result' \
    "a publication failure must resolve the pending result by wake"
  pass "a runner publication failure still delivers a terminal answer"
}

test_start_does_not_hold_the_callers_stdout() {
  local home started finished
  home=$(new_home detached-stdout)
  started=$(date +%s)
  # Command substitution is exactly how bin/fm-session-start.sh reads bootstrap:
  # it does not return until every holder of the pipe closes it. A runner that
  # inherited stdout would make this take as long as the run itself, and the
  # deferral would silently be no deferral at all.
  : "$(FM_HOME="$home" "$DEFER" start held -- bash -c 'sleep 5; echo late')"
  finished=$(date +%s)
  [ "$((finished - started))" -lt 4 ] \
    || fail "start held the caller's stdout for $((finished - started))s; the runner is not detached"
  pass "start returns immediately even when its caller is reading through a pipe"
}

test_a_result_left_by_a_killed_runner_is_picked_up_by_the_next_start() {
  local home dir out
  home=$(new_home orphaned-result)
  mkdir -p "$home/state/.deferred/orphan/run-orphan"
  printf 'run-orphan\n' > "$home/state/.deferred/orphan/current"
  dir="$home/state/.deferred/orphan/run-orphan"
  # A runner that wrote its result and was killed before it could queue its
  # wake: a complete answer with no messenger.
  printf 'ORPHAN: a finding from a run nobody collected\n' > "$dir/out"
  : > "$dir/done"
  out=$(FM_HOME="$home" "$DEFER" start orphan -- printf 'fresh\n')
  assert_contains "$out" 'ORPHAN: a finding from a run nobody collected' \
    "the next start should print the result the previous run never delivered"
  pass "a finished result nobody took is carried into the next session start"
}

test_a_second_start_never_runs_two_copies_of_the_same_check() {
  local home rc=0
  home=$(new_home no-double-start)
  FM_HOME="$home" "$DEFER" start busy -- bash -c 'sleep 5' >/dev/null
  FM_HOME="$home" "$DEFER" start busy -- bash -c 'sleep 5' >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || fail "a start over a live runner should decline with 3, got $rc"
  pass "a check already running is not started a second time"
}

test_collect_of_a_check_that_never_started_is_failure_not_pending() {
  local home rc=0
  home=$(new_home never-started)
  FM_HOME="$home" "$DEFER" collect absent >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "collect with no run should report failure (1), never pending or clean; got $rc"
  pass "a check that never started reports failure rather than pending"
}

test_an_unsafe_check_name_is_refused() {
  local home rc=0
  home=$(new_home unsafe-name)
  FM_HOME="$home" "$DEFER" collect ../escape >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a name that could escape the state directory must be refused, got $rc"
  pass "a check name that is not a slug is refused rather than sanitized"
}

test_a_finished_run_is_delivered_once_under_a_racing_collect() {
  local home out rc=0 queue
  home=$(new_home delivered-once)
  FM_HOME="$home" "$DEFER" start once -- printf 'ONCE: a finding\n' >/dev/null
  wait_for_done "$home" once
  out=$(FM_HOME="$home" "$DEFER" collect once) || rc=$?
  [ "$rc" -eq 0 ] || fail "first collect should take delivery, got $rc"
  assert_contains "$out" 'ONCE: a finding' "the first collect owns the result"
  rc=0
  out=$(FM_HOME="$home" "$DEFER" collect once) || rc=$?
  [ "$rc" -eq 4 ] || fail "a second collect should report the result already delivered (4), got $rc"
  [ -z "$out" ] || fail "a second collect must not print the result twice: $out"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  [ -z "$queue" ] || fail "the runner must not also wake for a result the digest took: $queue"
  pass "one finished result is delivered exactly once"
}

test_a_finished_run_is_collected_into_the_digest
test_a_pending_run_reports_pending_and_delivers_by_wake
test_a_clean_late_result_still_wakes
test_a_nonzero_late_result_reports_failure
test_a_long_nonzero_result_keeps_failure_visible
test_a_nonzero_inline_result_reports_failure
test_a_missing_output_is_reported_as_failure
test_a_launch_failure_is_not_pending
test_a_dead_unfinished_generation_is_reported
test_a_reused_pid_is_reported_as_abandoned
test_pid_publication_failure_leaves_no_runner
test_generations_isolate_previous_handoffs
test_publication_failure_still_wakes
test_start_does_not_hold_the_callers_stdout
test_a_result_left_by_a_killed_runner_is_picked_up_by_the_next_start
test_a_second_start_never_runs_two_copies_of_the_same_check
test_collect_of_a_check_that_never_started_is_failure_not_pending
test_an_unsafe_check_name_is_refused
test_a_finished_run_is_delivered_once_under_a_racing_collect
