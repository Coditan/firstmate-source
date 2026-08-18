#!/usr/bin/env bash
# Behavior tests for the memory alarm.
#
# Every case feeds a fixture reading rather than the host, so the suite measures
# what the alarm DECIDES rather than how much memory the machine running the
# tests happens to have. The live end of it - that a real runaway makes it fire -
# is tests/fm-memory-alarm-crossing-e2e.test.sh, which drives an actual
# fast-growing process, because an alarm proven only against fixtures has been
# shown to be consistent, not to work.
#
# The properties under test are the ones that would let the alarm lie:
#   an instrument that could not read must never come back as an all-clear;
#   a continuing shortage must be reported once, not on every poll;
#   a recovery must be earned rather than reached by not looking;
#   and nothing here may limit, throttle, or kill.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_MEMORY_ALARM_DISABLE=0

fm_test_tmproot TMP_ROOT fm-memory-alarm-tests

ALARM="$ROOT/bin/fm-memory-alarm.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# --- fixture reading --------------------------------------------------------
#
# A stand-in for bin/fm-memory-reading.sh that emits whatever the case needs.
# It takes its answer from a file so a single test can change the machine
# between two polls, which is the only way to exercise a transition.

FAKE="$TMP_ROOT/fake-reading.sh"
ANSWER="$TMP_ROOT/answer.json"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
cat "$FM_TEST_ANSWER"
exit "${FM_TEST_READING_EXIT:-0}"
EOF
chmod +x "$FAKE"

# reading <available_mib> <complete> [<growth_kb_per_min> <protected> <kind> <detail>]
reading() {
  local avail_mib=$1 complete=$2 growth=${3:-0} protected=${4:-false} kind=${5:-task} detail=${6:-'alpha (ship, alpha-project)'}
  local procs='[]' unmeasured='[]' growth_obj='{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null}'
  if [ "$growth" != 0 ]; then
    procs=$(printf '[{"pid":4242,"account":"coditan","rss_kb":900000,"growth_kb_per_min":%s,"attribution":{"kind":"%s","detail":"%s","route":"cwd"},"protected":%s,"command":"python3 balloon.py"}]' \
      "$growth" "$kind" "$detail" "$protected")
  fi
  [ "$complete" = false ] && unmeasured='[{"input":"process-table","reason":"the process table could not be read"}]'
  printf '{"schema":"fm-memory-reading.v1","complete":%s,"unmeasured":%s,"headroom":{"total_kb":24019908,"available_kb":%s},"growth":%s,"processes":%s}\n' \
    "$complete" "$unmeasured" "$((avail_mib * 1024))" "$growth_obj" "$procs" >"$ANSWER"
}

# A reading whose growth the instrument could not compare at all.
reading_growth_scoped() {
  printf '{"schema":"fm-memory-reading.v1","complete":true,"unmeasured":[],"headroom":{"total_kb":24019908,"available_kb":%s},"growth":{"interval_seconds":0,"scope_reason":"no stored sample yet","unmeasured_reason":null},"processes":[]}\n' \
    "$(( $1 * 1024 ))" >"$ANSWER"
}

alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      "$ALARM" "$@"
}

reset_home() {
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
}

log_lines() {
  [ -f "$HOME_DIR/data/memory-alarm.log" ] || { echo 0; return; }
  wc -l <"$HOME_DIR/data/memory-alarm.log"
}

# --- cases ------------------------------------------------------------------

test_a_healthy_machine_says_nothing() {
  reset_home
  reading 16000 true 0
  local out
  out=$(alarm) ; assert_contains "|$out|" "||" "a healthy machine must produce no line at all"
  out=$(alarm) ; assert_contains "|$out|" "||" "and must still produce none on the next poll"
  [ "$(log_lines)" -eq 0 ] || fail "a healthy machine must leave no durable record"
  pass "a healthy machine produces no line and no record"
}

test_the_headroom_floor_crosses_and_names_what_it_found() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 1800 true 0
  local out
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" "a crossing must be announced"
  assert_contains "$out" "1800 MiB" "the crossing must state the headroom it measured"
  assert_contains "$out" "below the 2400 MiB floor" "the crossing must name the threshold it crossed"
  assert_contains "$out" "Nothing has been limited or killed" \
    "the crossing must say plainly that nothing was acted against"
  pass "the headroom floor crosses and states both the reading and the threshold"
}

test_the_horizon_crosses_on_aggregate_growth_and_names_the_offender() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  # 16000 MiB against 1200 MiB/min is 13.3 minutes, inside the 15 minute horizon.
  reading 16000 true $((1200 * 1024)) false task 'alpha (ship, alpha-project)'
  local out
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" "growth fast enough to exhaust the machine must be announced"
  assert_contains "$out" "python3 balloon.py (pid 4242)" "the alarm must name the process"
  assert_contains "$out" "account coditan" "the alarm must name the account"
  assert_contains "$out" "serving task alpha (ship, alpha-project)" "the alarm must name the work it serves"
  pass "the horizon crosses on growth and names the process, its account, and its work"
}

test_a_continuing_shortage_is_reported_once() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 1800 true 0
  local first second third
  first=$(alarm)
  second=$(alarm)
  third=$(alarm)
  assert_contains "$first" "MEMORY_ALARM:" "the first poll of a shortage must speak"
  assert_contains "|$second|" "||" "the second poll of the SAME shortage must be silent"
  assert_contains "|$third|" "||" "and so must the third"
  [ "$(log_lines)" -eq 1 ] || fail "a continuing shortage must leave one record, not one per poll"
  pass "a continuing shortage is reported once, not on every poll"
}

test_crossing_and_recovery_both_leave_a_durable_record() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 1800 true 0
  alarm >/dev/null
  reading 16000 true 0
  local out
  out=$(alarm)
  assert_contains "$out" "recovered" "leaving the shortage must be announced"
  [ "$(log_lines)" -eq 2 ] || fail "crossing and recovery must each leave a record"
  assert_grep 'ok -> crossed' "$HOME_DIR/data/memory-alarm.log" "the crossing must be recorded as a transition"
  assert_grep 'crossed -> ok' "$HOME_DIR/data/memory-alarm.log" "the recovery must be recorded as a transition"
  assert_grep '1800 MiB RAM headroom available' "$HOME_DIR/data/memory-alarm.log" \
    "the record must carry the evidence the decision was made on"
  pass "crossing and recovery both leave a durable record carrying their evidence"
}

test_a_machine_hovering_at_the_line_does_not_flap() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 1800 true 0
  alarm >/dev/null
  # Back over the floor, but not clear of it by the recovery margin (2400 x 1.25
  # = 3000). Recovery must not be declared on this.
  reading 2500 true 0
  local out
  out=$(alarm)
  assert_contains "|$out|" "||" "a reading inside the recovery margin must not declare recovery"
  [ "$(log_lines)" -eq 1 ] || fail "hovering at the line must not write a recovery record"
  pass "a machine hovering at the line reports once rather than flapping"
}

test_an_instrument_that_could_not_read_is_never_an_all_clear() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 16000 false 0
  local out status=0
  out=$(alarm)
  assert_contains "$out" "gone blind" "an incomplete reading must be announced as blindness"
  assert_contains "$out" "not an all-clear" "and must say in words that it is not an all-clear"
  assert_contains "$out" "process-table" "and must name the input it could not read"

  out=$(alarm --status) || status=$?
  expect_code 3 "$status" "--status on an incomplete reading"
  assert_contains "$out" "UNMEASURED" "--status must report an incomplete reading as unmeasured"
  assert_not_contains "$out" "memory-alarm: ok" "--status must never call an incomplete reading ok"
  pass "an instrument that could not read is reported as blind, never as an all-clear"
}

test_a_reading_that_produced_nothing_is_blindness_not_health() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  : >"$ANSWER"                       # the reading returned nothing at all
  local out
  out=$(alarm)
  assert_contains "$out" "gone blind" "an empty reading must be reported as blindness"
  assert_not_contains "$out" "recovered" "an empty reading must never read as a recovery"
  pass "a reading that produced nothing is blindness rather than health"
}

test_recovery_is_not_declared_on_growth_nobody_could_compare() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 16000 true $((1200 * 1024))
  alarm >/dev/null                   # crossed on growth
  reading_growth_scoped 16000        # headroom fine, growth uncomparable
  local out
  out=$(alarm)
  assert_not_contains "$out" "recovered" \
    "a shortage must not be declared over by a run that never re-evaluated the condition that raised it"
  assert_contains "$out" "not re-evaluated" "the alarm must say why it cannot call the shortage over"
  pass "recovery is never declared on the strength of growth nobody could compare"
}

test_scoped_growth_on_a_calm_machine_is_not_a_growth_all_clear() {
  reset_home
  reading_growth_scoped 16000
  local out
  out=$(alarm --status)
  assert_contains "$out" "not comparable" "an uncomparable growth reading must say so"
  assert_contains "$out" "only headroom was judged" "and must say which condition it actually judged"
  assert_not_contains "$out" "growth 0 MiB/min" \
    "growth that could not be compared must never be printed as a measured zero"
  pass "growth that could not be compared is stated, never rendered as a measured zero"
}

test_status_labels_horizon_as_ram_headroom_not_swap_exhaustion() {
  reset_home
  reading 16000 true $((100 * 1024))
  local out
  out=$(alarm --status)
  assert_contains "$out" "RAM headroom available" \
    "the alarm must name the quantity its horizon divides by"
  assert_contains "$out" "minutes of RAM headroom left" \
    "the status projection must not read like a RAM-plus-swap kill countdown"
  assert_not_contains "$out" "minutes of memory left" \
    "the old projection label hid that MemAvailable excludes free swap"
  pass "the status horizon is labelled as RAM headroom rather than swap exhaustion"
}

test_the_wake_delivery_listener_keeps_its_label() {
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 16000 true $((1200 * 1024)) true infrastructure 'wake delivery for coditan-firstmate'
  local out
  out=$(alarm)
  assert_contains "$out" "wake-delivery listener, which nothing may act against" \
    "the protected label must travel with the name so nothing downstream loses it"
  pass "the wake-delivery listener keeps its protected label wherever it is named"
}

test_the_alarm_limits_nothing_and_kills_nothing() {
  reset_home
  sleep 30 &
  local offender=$! before after out
  before=$(cat "/proc/$offender/cgroup")
  reading 1800 true 102400 false task "alpha (ship, alpha-project)"
  sed -i "s/\"pid\":4242/\"pid\":$offender/" "$ANSWER"
  out=$(alarm)
  kill -0 "$offender" 2>/dev/null || fail "the alarm must leave the offending process running"
  after=$(cat "/proc/$offender/cgroup")
  [ "$before" = "$after" ] || fail "the alarm must not move the offender into a limiting cgroup"
  assert_contains "$out" "Nothing has been limited or killed" \
    "the runtime result must state the no-action boundary"
  kill "$offender" 2>/dev/null || true
  wait "$offender" 2>/dev/null || true
  pass "the alarm limits nothing, throttles nothing, and kills nothing"
}

test_persistence_failures_replace_transition_claims_with_diagnostics() {
  reset_home
  reading 1800 true 0
  rm -rf "$HOME_DIR/data"
  printf 'not a directory\n' >"$HOME_DIR/data"
  local out status=0
  out=$(alarm) || status=$?
  expect_code 0 "$status" "the watcher-facing persistence diagnostic"
  assert_contains "$out" "could not record the ok to crossed transition" \
    "a failed durable record must be reported instead of claiming the crossing completed"
  assert_not_contains "$out" "this machine is running out of RAM headroom" \
    "a transition whose record failed must not be reported as completed"

  rm -f "$HOME_DIR/data"
  mkdir -p "$HOME_DIR/data"
  rm -rf "$HOME_DIR/state"
  printf 'not a directory\n' >"$HOME_DIR/state"
  out=$(alarm) || status=$?
  expect_code 0 "$status" "the watcher-facing state persistence diagnostic"
  assert_contains "$out" "could not persist its new state" \
    "a failed state write must be reported instead of claiming the crossing completed"
  assert_not_contains "$out" "this machine is running out of RAM headroom" \
    "a transition whose state failed must not be reported as completed"
  pass "persistence failures are watcher diagnostics, never completed transition claims"
}

test_arming_registers_a_check_and_is_idempotent() {
  # How the alarm reaches the fleet at all. An alarm nothing arms is not
  # watching, and a home that has to remember to arm it is a home that will not.
  reset_home
  local out
  out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
            FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
            "$ALARM" --armed)
  assert_contains "$out" "nothing is watching this machine" \
    "an unarmed home must say so rather than stay quiet"

  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      "$ALARM" --arm >/dev/null || fail "arming must succeed on a writable home"
  assert_present "$HOME_DIR/state/memory-alarm.check.sh" "arming must write the watcher check"
  assert_present "$HOME_DIR/state/memory-alarm.check-trust" \
    "arming must bind the check to its own bytes, or the watcher will refuse to run it"
  [ -x "$HOME_DIR/state/memory-alarm.check.sh" ] || fail "the armed check must be executable"

  local before after
  before=$(cat "$HOME_DIR/state/memory-alarm.check.sh")
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      "$ALARM" --arm >/dev/null || fail "arming twice must succeed"
  after=$(cat "$HOME_DIR/state/memory-alarm.check.sh")
  [ "$before" = "$after" ] || fail "arming must be idempotent so bootstrap can run it every session"
  pass "arming registers a bound watcher check and converges rather than churning"
}

test_an_alarm_that_stopped_running_is_reported() {
  # Armed once is not running now. This is the reading that separates a quiet
  # machine from an alarm nobody has been executing.
  reset_home
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      "$ALARM" --arm >/dev/null
  reading 16000 true 0
  alarm >/dev/null

  local out
  out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
            FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
            "$ALARM" --armed)
  assert_contains "|$out|" "||" "an alarm that just read the machine must not be called stopped"

  out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
            FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
            FM_MEMORY_ALARM_NOW=$(( $(date +%s) + 7200 )) "$ALARM" --armed)
  assert_contains "$out" "has stopped running" "an alarm that stopped reading must be reported"
  assert_contains "$out" "nothing is watching it now" "and must say what that costs"
  pass "an alarm that stopped running is reported rather than mistaken for a calm machine"
}

test_usage_errors_exit_two() {
  local status=0
  "$ALARM" --nonsense >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown argument"
  status=0
  "$ALARM" --status --arm >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "two modes at once"
  status=0
  "$ALARM" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "--help"
  pass "usage errors exit 2 and --help exits 0"
}

test_a_healthy_machine_says_nothing
test_the_headroom_floor_crosses_and_names_what_it_found
test_the_horizon_crosses_on_aggregate_growth_and_names_the_offender
test_a_continuing_shortage_is_reported_once
test_crossing_and_recovery_both_leave_a_durable_record
test_a_machine_hovering_at_the_line_does_not_flap
test_an_instrument_that_could_not_read_is_never_an_all_clear
test_a_reading_that_produced_nothing_is_blindness_not_health
test_recovery_is_not_declared_on_growth_nobody_could_compare
test_scoped_growth_on_a_calm_machine_is_not_a_growth_all_clear
test_status_labels_horizon_as_ram_headroom_not_swap_exhaustion
test_the_wake_delivery_listener_keeps_its_label
test_the_alarm_limits_nothing_and_kills_nothing
test_persistence_failures_replace_transition_claims_with_diagnostics
test_arming_registers_a_check_and_is_idempotent
test_an_alarm_that_stopped_running_is_reported
test_usage_errors_exit_two
