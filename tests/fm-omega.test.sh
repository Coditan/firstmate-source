#!/usr/bin/env bash
# Durable omega-window marker behavior tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-omega-tests
RUNNER="$ROOT/bin/fm-omega.sh"

new_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

run_omega() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$RUNNER" "$@" 2>&1
}

test_open_refuses_without_away_mode() {
  local home out rc
  home=$(new_home no-away)
  set +e
  out=$(run_omega "$home" open --task 'finish repair' --record decision-1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "open succeeded without an away entry"
  assert_contains "$out" 'away mode is not active' "open refusal did not name the missing away entry"
  [ ! -e "$home/state/.omega" ] || fail "refused open left a marker"
  pass "omega open refuses without away mode"
}

test_open_refuses_second_marker() {
  local home out rc before
  home=$(new_home duplicate)
  printf '1700000001\n' > "$home/state/.afk"
  run_omega "$home" open --task 'first task' --record decision-1 >/dev/null
  before=$(cat "$home/state/.omega")
  set +e
  out=$(run_omega "$home" open --task 'second task' --record decision-2)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "second open succeeded"
  assert_contains "$out" 'marker already exists' "second open refusal did not name the existing marker"
  [ "$(cat "$home/state/.omega")" = "$before" ] || fail "second open replaced the first marker"
  pass "omega open preserves and refuses an existing marker"
}

test_status_reports_matching_window_in_force() {
  local home out
  home=$(new_home matching)
  printf '1700000002\n' > "$home/state/.afk"
  run_omega "$home" open --task 'matching task' --record decision-2 >/dev/null
  out=$(run_omega "$home" status) || fail "matching marker did not report in force: $out"
  assert_contains "$out" 'OMEGA: IN FORCE' "matching marker did not report the positive in-force state"
  assert_contains "$out" 'away-entry=1700000002' "in-force reading omitted its bound away identity"
  pass "omega status reports a matching away entry in force"
}

test_status_reports_removed_away_entry_stale() {
  local home out rc
  home=$(new_home removed)
  printf '1700000003\n' > "$home/state/.afk"
  run_omega "$home" open --task 'removed task' --record decision-3 >/dev/null
  # Closest-to-passing break: preserve the valid marker and remove only the
  # current away entry that completes its binding.
  rm "$home/state/.afk"
  set +e
  out=$(run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "removed away entry was not the distinct stale state (rc=$rc): $out"
  assert_contains "$out" 'OMEGA: STALE' "removed away entry did not report stale"
  assert_contains "$out" 'expected away-entry 1700000003, found no active away entry' "stale reading did not contrast expected and missing identities"
  pass "omega status reports a valid marker stale when only its away entry is removed"
}

test_status_reports_changed_away_entry_stale() {
  local home out rc
  home=$(new_home changed)
  printf '1700000004\n' > "$home/state/.afk"
  run_omega "$home" open --task 'changed task' --record decision-4 >/dev/null
  # Closest-to-passing break: keep both records valid and change only the one
  # identity byte that makes the new away entry differ from the bound entry.
  printf '1700000005\n' > "$home/state/.afk"
  set +e
  out=$(run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "changed away entry was not the distinct stale state (rc=$rc): $out"
  assert_contains "$out" 'OMEGA: STALE' "changed away entry did not report stale"
  assert_contains "$out" 'expected away-entry 1700000004, found 1700000005' "stale reading did not contrast the two identities"
  pass "omega status reports valid but mismatched away entries stale"
}

test_close_records_window_and_absent_close_is_quiet() {
  local home out log
  home=$(new_home close)
  printf '1700000006\n' > "$home/state/.afk"
  run_omega "$home" open --task 'record close' --record decision-6 >/dev/null
  out=$(run_omega "$home" close) || fail "close failed: $out"
  [ -z "$out" ] || fail "close printed unexpected output: $out"
  [ ! -e "$home/state/.omega" ] || fail "close left the live marker"
  log=$(cat "$home/state/omega-window.log")
  assert_contains "$log" $'closed\topened=' "close log omitted the opened epoch"
  assert_contains "$log" $'\tclosed=' "close log omitted the closed epoch"
  assert_contains "$log" $'\ttask=record close\trecord=decision-6' "close log omitted the task or decision record"
  out=$(run_omega "$home" close) || fail "absent close failed: $out"
  [ -z "$out" ] || fail "absent close was not quiet: $out"
  [ "$(wc -l < "$home/state/omega-window.log" | tr -d ' ')" -eq 1 ] || fail "absent close appended another end record"
  pass "omega close writes one durable end record and absent close is quiet"
}

test_open_refuses_without_away_mode
test_open_refuses_second_marker
test_status_reports_matching_window_in_force
test_status_reports_removed_away_entry_stale
test_status_reports_changed_away_entry_stale
test_close_records_window_and_absent_close_is_quiet
