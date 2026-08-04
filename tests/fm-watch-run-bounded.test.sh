#!/usr/bin/env bash
# tests/fm-watch-run-bounded.test.sh - run_bounded's exit-status contract
# (bin/fm-watch.sh). Regression for the 2026-08-04 certsync-health defect:
# run_bounded used to collapse every outcome of the wrapped command to success
# (`... 2>/dev/null || true`), so a caller capturing its output via command
# substitution had no way to tell "the command failed" from "the command
# succeeded and printed nothing". certsync_health_reason (this file's sibling,
# tests/fm-watch-triage.test.sh) is the caller that needed the real exit status
# back; the other caller (the Bridge fetch in fm-watch.sh's main loop) never
# reads run_bounded's exit status at all, so it is provably unaffected by this
# change - the second test below pins that.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP fm-watch-run-bounded

STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# The watcher's own source guard (bin/fm-watch.sh) returns before the singleton
# lock and blocking loop when sourced, so this loads only the functions.
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

test_run_bounded_preserves_a_failing_exit_code() {
  local out rc
  out=$(run_bounded bash -c 'printf out; printf err >&2; exit 7')
  rc=$?
  [ "$rc" -eq 7 ] \
    || fail "run_bounded discarded the wrapped command's real exit code (got rc=$rc, wanted 7) - this is the exact defect that let a cannot-run certsync status read as healthy"
  [ "$out" = out ] || fail "run_bounded did not capture stdout: got [$out]"
  pass "run_bounded returns the wrapped command's real exit status instead of always reporting success"
}

test_run_bounded_preserves_a_succeeding_exit_code() {
  local out rc
  out=$(run_bounded bash -c 'printf ok; exit 0')
  rc=$?
  [ "$rc" -eq 0 ] || fail "run_bounded reported failure for a command that succeeded (rc=$rc)"
  [ "$out" = ok ] || fail "run_bounded did not capture stdout on success: got [$out]"
  pass "run_bounded still reports success for a command that actually succeeds"
}

test_run_bounded_still_discards_stderr() {
  local err
  err=$(run_bounded bash -c 'printf secret >&2; exit 1' 2>&1 1>/dev/null)
  [ -z "$err" ] || fail "run_bounded leaked the wrapped command's stderr: [$err]"
  pass "run_bounded still discards the wrapped command's stderr (only its exit status changed)"
}

# The Bridge fetch call site (fm-watch.sh main loop) invokes run_bounded as a
# bare statement and never reads $? - it re-derives what it needs from
# bridge_check_interval() afterward. Under `set -u` (this script's own mode, and
# fm-watch.sh's) a nonzero, no-longer-swallowed exit status from a bare
# statement does not abort the script and is simply discarded, exactly as
# before this change. This proves the shared helper's new behavior cannot alter
# that caller.
test_run_bounded_bare_statement_caller_is_unaffected_by_failure() {
  local marker="$TMP/reached-after-failure"
  rm -f "$marker"
  (
    set -u
    run_bounded bash -c 'exit 1'
    touch "$marker"
  )
  [ -e "$marker" ] \
    || fail "a bare (unchecked) run_bounded call now aborts its caller on failure - this would change the Bridge fetch call site's behavior"
  pass "a caller that never reads run_bounded's exit status (the Bridge fetch call site's shape) is unaffected by the real exit code now propagating"
}

test_run_bounded_preserves_a_failing_exit_code
test_run_bounded_preserves_a_succeeding_exit_code
test_run_bounded_still_discards_stderr
test_run_bounded_bare_statement_caller_is_unaffected_by_failure

echo "# fm-watch-run-bounded.test.sh: all assertions passed"
