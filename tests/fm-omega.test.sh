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

test_status_reports_recreated_same_content_stale() {
  local home out rc
  home=$(new_home recreated)
  printf '1700000004\n' > "$home/state/.afk"
  run_omega "$home" open --task 'recreated task' --record decision-recreated >/dev/null
  rm "$home/state/.afk"
  printf '1700000004\n' > "$home/state/.afk"
  set +e
  out=$(run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "recreated same-content away entry was not stale (rc=$rc): $out"
  assert_contains "$out" 'OMEGA: STALE' "recreated same-content away entry did not report stale"
  pass "omega status binds identical content to one filesystem entry"
}

test_status_fails_closed_without_subsecond_fingerprint() {
  local home tools out rc real_stat
  home=$(new_home coarse-fingerprint)
  printf '1700000005\n' > "$home/state/.afk"
  run_omega "$home" open --task 'coarse task' --record decision-coarse >/dev/null
  tools="$home/tools"
  mkdir "$tools"
  real_stat=$(command -v stat)
  printf '#!/usr/bin/env bash\nexec %q "$@" | sed "s/\\.[0-9][0-9]*/.000000000/"\n' "$real_stat" > "$tools/stat"
  chmod +x "$tools/stat"
  set +e
  out=$(PATH="$tools:$PATH" run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "coarse fingerprint was not stale (rc=$rc): $out"
  assert_contains "$out" 'OMEGA: STALE' "coarse fingerprint did not report stale"
  assert_contains "$out" 'zero-filled sub-second timestamp' "coarse fingerprint did not name its zero-filled representation"
  assert_contains "$out" 'exact current away-entry identity cannot be established' "coarse fingerprint did not fail loudly"
  pass "omega status fails closed when sub-second identity is unavailable"
}

test_status_refuses_dangling_marker() {
  local home out rc
  home=$(new_home dangling-marker)
  ln -s "$home/state/missing-marker-target" "$home/state/.omega"
  set +e
  out=$(run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "dangling marker did not use unreadable-state exit (rc=$rc): $out"
  assert_contains "$out" 'unreadable marker: not a regular file' "dangling marker did not fail loudly"
  assert_not_contains "$out" 'NOT IN FORCE' "dangling marker was misclassified as absent"
  pass "omega status refuses a dangling marker as unreadable state"
}

test_status_refuses_non_regular_away_entry() {
  local home out rc
  home=$(new_home invalid-away)
  printf '1700000006\n' > "$home/state/.afk"
  run_omega "$home" open --task 'invalid away' --record decision-invalid-away >/dev/null
  rm "$home/state/.afk"
  mkdir "$home/state/.afk"
  set +e
  out=$(run_omega "$home" status)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "non-regular away entry did not use unreadable-state exit (rc=$rc): $out"
  assert_contains "$out" 'away-entry state is not a regular file' "non-regular away entry did not fail loudly"
  assert_not_contains "$out" 'OMEGA: STALE' "non-regular away entry was misclassified as stale"
  pass "omega status refuses non-regular away-entry state"
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
  assert_contains "$log" $'closed\twindow-id=' "close log omitted the window identity"
  assert_contains "$log" $'\topened=' "close log omitted the opened epoch"
  assert_contains "$log" $'\tclosed=' "close log omitted the closed epoch"
  assert_contains "$log" $'\ttask=record close\trecord=decision-6' "close log omitted the task or decision record"
  out=$(run_omega "$home" close) || fail "absent close failed: $out"
  [ -z "$out" ] || fail "absent close was not quiet: $out"
  [ "$(wc -l < "$home/state/omega-window.log" | tr -d ' ')" -eq 1 ] || fail "absent close appended another end record"
  pass "omega close writes one durable end record and absent close is quiet"
}


test_close_retry_does_not_duplicate_log() {
  local home tools out rc real_rm
  home=$(new_home close-retry)
  printf '1700000007\n' > "$home/state/.afk"
  run_omega "$home" open --task 'retry close' --record decision-7 >/dev/null
  tools="$home/tools"
  mkdir "$tools"
  real_rm=$(command -v rm)
  # shellcheck disable=SC2016 # The generated shim expands its own arguments.
  printf '#!/usr/bin/env bash\ncase "${*: -1}" in */.omega) exit 1;; esac\nexec %q "$@"\n' "$real_rm" > "$tools/rm"
  chmod +x "$tools/rm"
  set +e
  out=$(PATH="$tools:$PATH" run_omega "$home" close)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "injected marker-removal failure unexpectedly succeeded"
  [ -e "$home/state/.omega" ] || fail "failed close did not preserve the marker for retry"
  run_omega "$home" close >/dev/null || fail "close retry failed"
  [ "$(wc -l < "$home/state/omega-window.log" | tr -d ' ')" -eq 1 ] || fail "close retry duplicated the end record"
  pass "omega close retry reuses its durable window identity"
}

test_concurrent_close_writes_one_log_record() {
  local home tools real_date pid failures=0
  home=$(new_home concurrent-close)
  printf '1700000008\n' > "$home/state/.afk"
  run_omega "$home" open --task 'concurrent close' --record decision-8 >/dev/null
  tools="$home/tools"
  mkdir "$tools"
  real_date=$(command -v date)
  printf '#!/usr/bin/env bash\nsleep 0.2\nexec %q "$@"\n' "$real_date" > "$tools/date"
  chmod +x "$tools/date"
  for _ in 1 2 3 4 5 6 7 8; do
    PATH="$tools:$PATH" run_omega "$home" close >/dev/null &
  done
  for pid in $(jobs -p); do
    wait "$pid" || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures concurrent close calls failed"
  [ ! -e "$home/state/.omega" ] || fail "concurrent close left the marker"
  [ "$(wc -l < "$home/state/omega-window.log" | tr -d ' ')" -eq 1 ] || fail "concurrent close duplicated the end record"
  pass "omega serializes concurrent close transactions"
}

test_open_refuses_without_away_mode
test_open_refuses_second_marker
test_status_reports_matching_window_in_force
test_status_reports_removed_away_entry_stale
test_status_reports_changed_away_entry_stale
test_status_reports_recreated_same_content_stale
test_status_fails_closed_without_subsecond_fingerprint
test_status_refuses_dangling_marker
test_status_refuses_non_regular_away_entry
test_close_records_window_and_absent_close_is_quiet
test_close_retry_does_not_duplicate_log
test_concurrent_close_writes_one_log_record
