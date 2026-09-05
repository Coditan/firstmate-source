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
  local home=$1 name=$2 waited=0
  while [ ! -f "$home/state/.deferred/$name/done" ] && [ "$waited" -lt 200 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
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
  assert_contains "$queue" "$home/state/.deferred/slow/out" "the wake should name where the full output lives"
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
  dir="$home/state/.deferred/missing"
  mkdir -p "$dir"
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
  dir="$home/state/.deferred/orphan"
  mkdir -p "$dir"
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
test_a_nonzero_inline_result_reports_failure
test_a_missing_output_is_reported_as_failure
test_a_launch_failure_is_not_pending
test_start_does_not_hold_the_callers_stdout
test_a_result_left_by_a_killed_runner_is_picked_up_by_the_next_start
test_a_second_start_never_runs_two_copies_of_the_same_check
test_collect_of_a_check_that_never_started_is_failure_not_pending
test_an_unsafe_check_name_is_refused
test_a_finished_run_is_delivered_once_under_a_racing_collect
