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

# Every fixture carries a stall reading, because every real reading does: the
# reader marks a missing pressure file unmeasured, so a complete reading without
# a stall average is a shape the machine cannot produce. FM_TEST_STALL sets it.
FM_TEST_STALL=0.00

# The shape of the machine the fixture describes. The defaults are this fleet's
# calibration host - 23,456 MiB with 32 GiB of swap - so every case written
# before the alarm read shape at all still describes the machine it was written
# against. `null` for the swap total is a machine whose swap could not be read,
# which is not the same reading as a machine with none.
FM_TEST_TOTAL_KB=24019908
FM_TEST_SWAP_TOTAL_KB=33554428

# reading <available_mib> <complete> [<growth_kb_per_min> <protected> <kind> <detail>]
reading() {
  local avail_mib=$1 complete=$2 growth=${3:-0} protected=${4:-false} kind=${5:-task} detail=${6:-'alpha (ship, alpha-project)'}
  local procs='[]' unmeasured='[]' growth_obj='{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null}'
  if [ "$growth" != 0 ]; then
    procs=$(printf '[{"pid":4242,"account":"coditan","rss_kb":900000,"growth_kb_per_min":%s,"attribution":{"kind":"%s","detail":"%s","route":"cwd"},"protected":%s,"command":"python3 balloon.py"}]' \
      "$growth" "$kind" "$detail" "$protected")
  fi
  # The real reader exits 3 for every incomplete reading, so a fixture that
  # claims incompleteness has to exit 3 too, or the suite proves nothing about
  # the status the alarm actually receives.
  export FM_TEST_READING_EXIT=0
  if [ "$complete" = false ]; then
    unmeasured='[{"input":"account-slices","reason":"no account'"'"'s total, limit, or stall was read at all"}]'
    export FM_TEST_READING_EXIT=3
  fi
  local swap_free=$FM_TEST_SWAP_TOTAL_KB
  printf '{"schema":"fm-memory-reading.v1","complete":%s,"unmeasured":%s,"headroom":{"total_kb":%s,"available_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s},"stall":%s,"growth":%s,"processes":%s}\n' \
    "$complete" "$unmeasured" "$FM_TEST_TOTAL_KB" "$((avail_mib * 1024))" \
    "$FM_TEST_SWAP_TOTAL_KB" "$swap_free" "$(stall_obj "$FM_TEST_STALL")" "$growth_obj" "$procs" >"$ANSWER"
}

# stall_obj <full> [<some>]  -  "none" makes the reading carry no stall average
# at all. `some` defaults above `full`, which is the only ordering the kernel can
# produce: every task stalled implies at least one task stalled. Both windows are
# set to the same value; the alarm decides on avg60 and reports some_avg60.
stall_obj() {
  local full=$1 some=${2:-}
  if [ "$full" = none ]; then
    printf '{"some_avg10":null,"some_avg60":null,"full_avg10":null,"full_avg60":null}'
    return
  fi
  [ -n "$some" ] || some=$(awk -v f="$full" 'BEGIN { printf "%.2f", f * 1.1 }')
  printf '{"some_avg10":%s,"some_avg60":%s,"full_avg10":%s,"full_avg60":%s}' "$some" "$some" "$full" "$full"
}

# A machine already drowning: headroom and growth both look fine, and the only
# thing that says otherwise is how long work spent waiting on memory. This is
# the 2026-08-27 shape, and neither of the two original conditions can see it.
# reading_thrashing <available_mib> <full_stall> [<swap_used_mib>] [<rss_mib>] [<some_stall>]
reading_thrashing() {
  local avail_mib=$1 stall=$2 swap_used=${3:-4245} rss_mib=${4:-2900} some=${5:-}
  local swap_total=33554428
  export FM_TEST_READING_EXIT=0
  printf '{"schema":"fm-memory-reading.v1","complete":true,"unmeasured":[],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s},"stall":%s,"growth":{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null},"processes":[{"pid":9001,"account":"coditan","rss_kb":%s,"growth_kb_per_min":0,"attribution":{"kind":"task","detail":"beta (ship, beta-project)","route":"cwd"},"protected":false,"command":"chrome --headless"},{"pid":9002,"account":"coditan","rss_kb":40000,"growth_kb_per_min":0,"attribution":{"kind":"task","detail":"gamma (ship, gamma-project)","route":"cwd"},"protected":false,"command":"node small.js"}]}\n' \
    "$((avail_mib * 1024))" "$swap_total" "$((swap_total - swap_used * 1024))" \
    "$(stall_obj "$stall" "$some")" "$((rss_mib * 1024))" >"$ANSWER"
}

# A reading that read everything except the host stall account. This is the WSL
# and fresh-kernel shape: headroom and growth are both there and both perfectly
# judgeable, and only the one condition whose own input is missing is blind.
reading_stall_unmeasured() {  # <available_mib>
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"stall","reason":"the memory pressure account has recorded exactly zero since boot beside a live io account"}],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null},"processes":[]}\n' \
    "$(( $1 * 1024 ))" "$(stall_obj none)" >"$ANSWER"
}

# A reading that could not measure RAM headroom itself. Both other conditions
# divide by it, so nothing here can be judged at all.
reading_headroom_unmeasured() {
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"headroom","reason":"/proc/meminfo carries no usable MemTotal/MemAvailable pair"}],"headroom":{"total_kb":null,"available_kb":null,"swap_total_kb":null,"swap_free_kb":null},"stall":%s,"growth":{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null},"processes":[]}\n' \
    "$(stall_obj 0.00)" >"$ANSWER"
}

# A reading whose stored growth sample has aged past the window a rate means
# anything over. The reading marks it unmeasured rather than scoped, but it is
# still the SAMPLE and not the process table, so the next poll that stores one
# repairs it.
reading_growth_sample_stale() {  # <available_mib>
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"growth-sample","reason":"the stored sample is 1400s old, past the 1260s window a growth rate means anything over"}],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":0,"scope_reason":null,"unmeasured_reason":"the stored sample is 1400s old, past the 1260s window a growth rate means anything over"},"processes":[]}\n' \
    "$(( $1 * 1024 ))" "$(stall_obj "$FM_TEST_STALL")" >"$ANSWER"
}

# A reading whose PROCESS TABLE could not be read at all. That is the horizon's
# own instrument failing, not a sample this run happened not to have.
reading_process_table_unreadable() {  # <available_mib>
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"processes","reason":"ps failed, so the process table could not be read at all"}],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":0,"scope_reason":null,"unmeasured_reason":"the process table could not be read, so nothing could be compared"},"processes":[]}\n' \
    "$(( $1 * 1024 ))" "$(stall_obj "$FM_TEST_STALL")" >"$ANSWER"
}

# A reading whose stored sample PATH is not a regular file. Storing writes aside
# and moves into place, and a move onto a directory lands inside it, so no later
# poll can ever replace this prior: it is the one growth failure a fresh sample
# cannot repair, and the reading names it under its own input rather than
# leaving it to be told apart from a merely aged one by its wording.
reading_growth_sample_path_unusable() {  # <available_mib>
  local why="the stored sample path exists but is not a regular file, so nothing can be read from it or written over it"
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"growth-sample-path","reason":"%s"}],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":0,"scope_reason":null,"unmeasured_reason":"%s"},"processes":[]}\n' \
    "$why" "$(( $1 * 1024 ))" "$(stall_obj "$FM_TEST_STALL")" "$why" >"$ANSWER"
}

# A reading whose growth prior was unusable and whose own replacement sample
# could not be stored. Scope is earned by the NEXT poll being better placed than
# this one, and a store that never lands earns nothing: the reading settles that
# verdict as blindness under its own input rather than as an ordinary absence.
reading_growth_sample_store_failed() {  # <available_mib>
  local why="the stored sample is 1400s old, past the 1260s window a growth rate means anything over, and this run's own sample could not be stored, so the next run has nothing more to compare against than this one did"
  export FM_TEST_READING_EXIT=3
  printf '{"schema":"fm-memory-reading.v1","complete":false,"unmeasured":[{"input":"sample-storage","reason":"the sample could not be replaced"},{"input":"growth-sample-store","reason":"%s"}],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":0,"scope_reason":null,"unmeasured_reason":"%s"},"processes":[]}\n' \
    "$why" "$(( $1 * 1024 ))" "$(stall_obj "$FM_TEST_STALL")" "$why" >"$ANSWER"
}

# A reading whose growth the instrument could not compare at all.
reading_growth_scoped() {
  export FM_TEST_READING_EXIT=0
  printf '{"schema":"fm-memory-reading.v1","complete":true,"unmeasured":[],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":{"interval_seconds":0,"scope_reason":"no stored sample yet","unmeasured_reason":null},"processes":[]}\n' \
    "$(( $1 * 1024 ))" "$(stall_obj "$FM_TEST_STALL")" >"$ANSWER"
}

alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL=1.00 FM_MEMORY_ALARM_STALL_WINDOW="${FM_TEST_STALL_WINDOW:-5400}" \
      "$ALARM" "$@"
}

# The alarm as it SHIPS with respect to the floor: no FM_MEMORY_ALARM_FLOOR_MIB
# at all, so the floor is whatever the alarm derives from the machine the fixture
# describes. Every other helper here pins 2400, which is what lets the cases
# written before the floor was derived keep measuring what they were written to
# measure.
derived_floor_alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL=1.00 FM_MEMORY_ALARM_STALL_WINDOW="${FM_TEST_STALL_WINDOW:-5400}" \
      ${FM_TEST_FLOOR+FM_MEMORY_ALARM_FLOOR_MIB="$FM_TEST_FLOOR"} \
      "$ALARM"
}

# The alarm with the stall condition deliberately switched OFF. This is NOT how
# it ships: FM_MEMORY_ALARM_STALL unset defaults to the shipped 1.00 gate and the
# armed shim exports nothing that would empty it, so the condition ships ON. Only
# an explicitly empty value reaches this state.
unconfigured_alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_NOW="${FM_TEST_AT:-$BASE_NOW}" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL='' \
      "$ALARM" "$@"
}

# The alarm as a home gets it when somebody has fat-fingered the gate. Unlike an
# empty one, this is a typo rather than a choice, so the condition stays on.
malformed_gate_alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL='not a number' \
      "$ALARM" "$@"
}

# The alarm as a home gets it when the gate or the window has been configured to
# zero. Both are unusable: no reading falls below a zero gate, and every run
# outlasts a zero window.
# FM_TEST_AT carries the moment rather than an exported override in a subshell,
# so a case can play a run forward without the shell losing the value it set.
zero_configured_alarm() {  # <gate> <window> [args...]
  local gate=$1 window=$2; shift 2
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_NOW="${FM_TEST_AT:-$BASE_NOW}" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL="$gate" FM_MEMORY_ALARM_STALL_WINDOW="$window" \
      "$ALARM" "$@"
}

# Drive the alarm at a chosen moment, so a run of consecutive polls can be
# played out in a test without waiting for one in real time.
alarm_at() {  # <epoch-offset-seconds> [args...]
  local at=$1; shift
  # A subshell with an exported override, not `env`: `env` runs a program and
  # cannot invoke a shell function, and a silently failed call produces no
  # output - which every "must stay silent" assertion here would have passed.
  ( export FM_MEMORY_ALARM_NOW="$((BASE_NOW + at))"; alarm "$@" )
}

reset_home() {
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  export FM_TEST_READING_EXIT=0
  FM_TEST_STALL=0.00
  FM_TEST_AT=
  FM_TEST_STALL_WINDOW=5400
  FM_TEST_TOTAL_KB=24019908
  FM_TEST_SWAP_TOTAL_KB=33554428
  BASE_NOW=$(date +%s)
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
  # Headroom is the one input nothing here can proceed without: both other
  # conditions divide by it. Without it NO condition can be judged, and that is
  # the only shape that still produces a bare "cannot see" verdict.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading_headroom_unmeasured
  local out status=0
  out=$(alarm)
  assert_contains "$out" "gone blind" "a reading with no headroom must be announced as blindness"
  assert_contains "$out" "not an all-clear" "and must say in words that it is not an all-clear"
  assert_contains "$out" "headroom" "and must name the input it could not read"

  out=$(alarm --status) || status=$?
  expect_code 3 "$status" "--status when no condition could be judged"
  assert_contains "$out" "UNMEASURED" "--status must report a reading it could not judge as unmeasured"
  assert_not_contains "$out" "memory-alarm: ok" "--status must never call such a reading ok"
  pass "an instrument that could not read is reported as blind, never as an all-clear"
}

test_one_unreadable_input_does_not_silence_the_conditions_that_were_read() {
  # A kernel that has simply never accounted memory stall makes the reading
  # incomplete. Before, that returned before any condition was tested, so a
  # machine actually running out of RAM headroom went unreported on exactly the
  # hosts where the stall account is flat. Headroom and horizon keep their
  # behaviour whatever the stall account does.
  reset_home
  reading 16000 true 0
  alarm >/dev/null

  local out status=0
  reading_stall_unmeasured 16000
  out=$(alarm --status) || status=$?
  expect_code 0 "$status" "--status when only the stall account was unreadable"
  assert_contains "$out" "16000 MiB RAM headroom" \
    "the headroom condition must still be judged when its own input was read"
  assert_contains "$out" "not a full all-clear" \
    "a verdict from an incomplete reading must say it is not a full all-clear"
  assert_contains "$out" "stall" "and must name the input it could not read"
  assert_not_contains "$out" "UNMEASURED" \
    "one unreadable input must not be reported as though nothing could be judged"

  # And the headroom condition still FIRES, which is the whole point.
  reading_stall_unmeasured 1800
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" "a headroom crossing must be announced on an incomplete reading"
  assert_contains "$out" "below the 2400 MiB floor" "and must name the threshold it crossed"
  assert_contains "$out" "Unmeasured:" "and must still name what it could not read"
  pass "one unreadable input leaves the conditions whose own inputs were read still judged"
}

test_a_recovery_is_never_declared_from_a_reading_that_missed_an_input() {
  # Firing gets no harder on an incomplete reading; leaving must get no easier -
  # but only for the condition that RAISED the alarm. Here the horizon crossed
  # and growth is what the next poll cannot compare, so the shortage may not be
  # called over however healthy headroom looks.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading 16000 true $((1200 * 1024)) false task 'alpha (ship, alpha-project)'
  local out
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" "the horizon crossing must be announced"

  reading_process_table_unreadable 16000
  out=$(alarm)
  assert_not_contains "$out" "recovered" \
    "a shortage must not be declared over by a poll that could not re-read the condition that raised it"
  assert_contains "$out" "gone blind" "the alarm must say instead that it cannot tell"
  assert_contains "$out" "crossed on growth" \
    "and must name the condition it could not re-evaluate"
  pass "a crossing is never left on the strength of the condition that raised it going unread"
}

test_an_input_no_condition_uses_does_not_hold_back_a_recovery() {
  # A container with no cgroup tree, a host whose swap has no usable SwapFree, a
  # home whose installation records cannot be read: each makes the reading
  # incomplete forever while leaving all three conditions perfectly readable.
  # Blocking recovery on that announces every genuine recovery as a blindness,
  # and then announces a restoration of sight that never happened.
  reset_home
  reading 1800 false 0
  local out
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" "the headroom crossing must still be announced"
  assert_contains "$out" "below the 2400 MiB floor" "and must name the threshold it crossed"

  reading 16000 false 0
  out=$(alarm)
  assert_contains "$out" "recovered" \
    "a recovery judged by all three conditions is a recovery, whatever else the reading missed"
  assert_not_contains "$out" "gone blind" \
    "a readable condition must never be reported as one the alarm could not re-evaluate"
  assert_contains "$out" "account-slices" "and the input it could not read is still named"

  out=$(alarm)
  assert_contains "|$out|" "||" \
    "and no restoration of sight may follow, because nothing was ever lost"
  [ "$(log_lines)" -eq 2 ] || fail "exactly the crossing and the recovery belong in the record"
  pass "an unmeasured input no condition uses never turns a recovery into a blindness"
}

test_a_recovery_states_how_long_the_shortage_actually_lasted() {
  # The duration is read back out of state/memory-alarm.state, which is this
  # alarm's own record and carries three fields. A reader that takes only two
  # hands the epoch field the rest of the line, fails the numeric guard, and
  # silently substitutes now - so every recovery the fleet ever sees would
  # report a shortage that lasted 0s.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  reading 1800 true 0
  alarm_at 300 >/dev/null
  reading 16000 true 0
  local out
  out=$(alarm_at 900)
  assert_contains "$out" "recovered" "the end of the shortage must be announced"
  assert_contains "$out" "The shortage lasted 10m0s" \
    "the recovery must state the real elapsed shortage, not the moment it was read"
  pass "a recovery states how long the shortage actually lasted"
}

test_sight_is_never_claimed_regained_while_a_condition_is_still_unreadable() {
  # The WSL shape: the memory-stall account can never be read. Every verdict
  # this alarm settles on must keep saying the machine is only partly watched,
  # because nothing about that host ever changes back.
  reset_home
  reading 16000 true 0
  alarm >/dev/null

  local out
  reading_stall_unmeasured 16000
  out=$(alarm)
  assert_contains "$out" "cannot judge stall" "the lost condition must be spoken once"

  reading_stall_unmeasured 1800
  out=$(alarm)
  assert_contains "$out" "running out of RAM headroom" \
    "headroom must still fire on a host whose stall account is unreadable"

  reading_stall_unmeasured 16000
  out=$(alarm)
  assert_not_contains "$out" "can see this machine again" \
    "sight must never be claimed regained while stall is still unreadable"

  out=$(alarm)
  assert_not_contains "$out" "can see this machine again" \
    "and must not be claimed on the poll after it either"
  assert_not_contains "$out" "back under watch on this machine" \
    "nor may all three conditions be claimed watched while one is not"
  case "$out" in
    ''|*"only partly watched"*) ;;
    *) fail "a calm verdict on a partly watched machine must say so: |$out|" ;;
  esac
  pass "sight is never reported as regained while a condition is still unreadable"
}

test_a_growth_sample_that_merely_aged_out_is_not_a_lost_instrument() {
  # A sample past its window is data this run did not have, and the next poll
  # that stores one repairs it. Counting it would cost the fleet two watcher
  # wakes and two durable records for a machine that was never in trouble, on
  # nothing worse than a single watcher gap.
  reset_home
  reading 16000 true 0
  alarm >/dev/null

  local out
  reading_growth_sample_stale 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "a sample that merely aged out must not be spoken as a lost instrument"
  reading 16000 true 0
  out=$(alarm)
  assert_contains "|$out|" "||" "and its repair must not be announced as sight regained"
  [ "$(log_lines)" -eq 0 ] || fail "a self-clearing sample absence must leave no durable record"

  # The process table itself is a different matter: that is the horizon's own
  # instrument, and losing it is spoken.
  reading_process_table_unreadable 16000
  out=$(alarm)
  assert_contains "$out" "cannot judge horizon" \
    "a process table nobody could read is the horizon's instrument failing, and must be spoken"
  pass "a growth sample that merely aged out is scope, not a lost instrument"
}

# The watch field of the durable state record: "<state> <epoch> <watch> <crossed>".
watch_field() {
  awk '{print $3}' "$HOME_DIR/state/memory-alarm.state" 2>/dev/null
}

test_a_growth_sample_no_poll_can_replace_is_a_lost_instrument() {
  # The sibling of the case above, and its opposite. A sample path that is not a
  # regular file cannot be written over, so no storing poll repairs it and the
  # absence never clears by itself. Reported as scope it would leave the horizon
  # - the condition that gives warning rather than confirmation - permanently
  # dead with nothing ever said on the watcher channel.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  [ "$(watch_field)" = - ] || fail "a healthy poll must be watching all three conditions"

  local out
  reading_growth_sample_path_unusable 16000
  out=$(alarm)
  assert_contains "$out" "cannot judge horizon" \
    "a growth sample no poll can ever replace must be spoken as a lost instrument"
  assert_contains "$out" "only partly watched" \
    "and the poll must say this machine is only partly watched"
  [ "$(watch_field)" = horizon ] ||
    fail "the horizon must enter the durable watch set, not read as scope (watch=$(watch_field))"

  # Spoken once, on the change, like every other condition.
  reading_growth_sample_path_unusable 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "an unchanged watch set must not be spoken again"

  # And the repairable kind, on the same machine, is still scope: it neither
  # enters the watch set nor says anything.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading_growth_sample_stale 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "a sample a later poll repairs must stay silent"
  [ "$(watch_field)" = - ] ||
    fail "a sample a later poll repairs must not enter the watch set (watch=$(watch_field))"
  pass "a growth sample no poll can replace is a lost instrument, and one that repairs is not"
}

test_a_growth_sample_that_could_not_be_stored_is_a_lost_instrument() {
  # The sibling route to the same defect the case above closes. An unusable
  # prior is scope only because this run replaces it; on a host where the store
  # keeps failing nothing replaces it, the absence never clears, and reporting
  # it as scope leaves the horizon dead with nothing said on the watcher
  # channel for as long as the fault lasts.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  [ "$(watch_field)" = - ] || fail "a healthy poll must be watching all three conditions"

  local out
  reading_growth_sample_store_failed 16000
  out=$(alarm)
  assert_contains "$out" "cannot judge horizon" \
    "a growth prior whose replacement never landed must be spoken as a lost instrument"
  assert_contains "$out" "only partly watched" \
    "and the poll must say this machine is only partly watched"
  [ "$(watch_field)" = horizon ] ||
    fail "the horizon must enter the durable watch set, not read as scope (watch=$(watch_field))"

  # Spoken once, on the change, like every other condition.
  reading_growth_sample_store_failed 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "an unchanged watch set must not be spoken again"

  # A run whose store DID land is ordinary scope: nothing enters the watch set
  # and the poll stays silent.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  reading_growth_scoped 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "a growth absence the next poll repairs must stay silent"
  [ "$(watch_field)" = - ] ||
    fail "a growth absence the next poll repairs must not enter the watch set (watch=$(watch_field))"
  pass "a growth sample that could not be stored is a lost instrument, and one that was is not"
}

test_a_raiser_that_only_dipped_under_its_threshold_is_not_released() {
  # The recovery margin is what clearing means. A horizon crossing that comes
  # back to just past the threshold - the `elevated` damping band, which is the
  # ordinary way out of a horizon crossing - has cleared nothing, so the raiser
  # stays on the books. Releasing it there let a later poll that could not
  # compare growth at all declare the shortage over.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # 16000 MiB against 1600 MiB/min is 10 minutes: inside the 15-minute horizon.
  local out
  reading 16000 true $((1600 * 1024)) false task 'alpha (ship, alpha-project)'
  out=$(alarm_at 300)
  assert_contains "$out" "running out of RAM headroom" "the horizon crossing must be announced"

  # 16000 MiB against 1000 MiB/min is 16 minutes: past the threshold, but short
  # of the 18.75 the 1.25 margin demands, so this is the elevated band.
  reading 16000 true $((1000 * 1024)) false task 'alpha (ship, alpha-project)'
  out=$(alarm_at 600)
  assert_contains "|$out|" "||" "a machine hovering at the line reports nothing"

  # Now growth cannot be compared at all. The raiser is still held, so this poll
  # may not call the shortage over.
  reading_process_table_unreadable 16000
  out=$(alarm_at 900)
  assert_not_contains "$out" "recovered" \
    "a poll that could not compare growth must not end a horizon shortage"
  assert_contains "$out" "gone blind" "it must say instead that it cannot tell"
  assert_contains "$out" "crossed on growth" "and must name the raiser still holding it"

  # Growth comes back clear of the margin: 16000 against 500 is 32 minutes.
  reading 16000 true $((500 * 1024)) false task 'alpha (ship, alpha-project)'
  out=$(alarm_at 1200)
  assert_contains "$out" "recovered" "clearing the margin is what ends it"
  assert_contains "$out" "The shortage lasted 15m0s" \
    "and the duration must run from the original crossing"
  pass "a raiser that only dipped under its threshold is not released"
}

test_a_raiser_survives_the_poll_that_could_not_read_its_own_input() {
  # Headroom is the one input the alarm cannot proceed without, so the poll that
  # cannot read it judges nothing. That is precisely not a poll that re-read the
  # headroom condition, and the raiser must survive it - otherwise the shortage's
  # end is never reported as a recovery and its duration is lost.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  reading 1800 true 0
  local out
  out=$(alarm_at 300)
  assert_contains "$out" "running out of RAM headroom" "the headroom crossing must be announced"

  reading_headroom_unmeasured
  out=$(alarm_at 600)
  assert_not_contains "$out" "recovered" "a poll that judged nothing must not end the shortage"

  reading 16000 true 0
  out=$(alarm_at 900)
  assert_contains "$out" "recovered" "the shortage's end must be reported as a recovery"
  assert_contains "$out" "The shortage lasted 10m0s" \
    "and must carry the duration measured from the crossing"
  assert_not_contains "$out" "can see this machine again" \
    "a shortage that ended is a recovery, not merely a regained instrument"
  pass "a raiser survives the poll that could not read its own input"
}

test_switching_the_stall_gate_off_releases_a_stall_raiser_it_would_otherwise_pin() {
  # A stall raiser cannot be re-read once the gate is empty, so holding it would
  # leave this home in "cannot tell" for ever and swallow every later recovery.
  # The fleet has chosen to stop watching that condition, so the raiser is
  # released - and the condition still reports itself unwatched, so nothing
  # about it passes for calm.
  reset_home
  FM_TEST_STALL_WINDOW=600
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  for t in 300 600 900; do
    reading_thrashing 3577 38.0
    out=$(alarm_at "$t")
  done
  assert_contains "$out" "stalling on memory" "the stall crossing must be announced"

  # The operator uses the documented off switch on a now-calm machine.
  reading_thrashing 16000 0.00
  FM_TEST_AT=$((BASE_NOW + 1200)) out=$(unconfigured_alarm)
  assert_not_contains "$out" "gone blind" \
    "a condition the fleet switched off must not pin the alarm in cannot-tell"
  assert_contains "$out" "recovered" "the shortage must be reported as over"
  assert_contains "$out" "no stall gate is configured" \
    "and the unwatched condition must still say so rather than pass for calm"

  FM_TEST_AT=$((BASE_NOW + 1500)) out=$(unconfigured_alarm)
  assert_contains "|$out|" "||" "and the next poll is silent rather than pinned"
  pass "switching the stall gate off releases a stall raiser it would otherwise pin"
}

test_a_crossing_is_held_for_every_poll_that_could_not_re_read_its_raiser() {
  # The guard must key on the crossing still on the books, not on the previous
  # poll's verdict. Keyed on the verdict it holds for exactly ONE poll: the
  # second consecutive blind poll finds the previous verdict was `unmeasured`
  # rather than `crossed`, skips the block, and tells a machine still in
  # shortage that the shortage ended.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  reading 16000 true $((1200 * 1024)) false task 'alpha (ship, alpha-project)'
  local out t
  out=$(alarm_at 300)
  assert_contains "$out" "MEMORY_ALARM:" "the horizon crossing must be announced"

  # Three consecutive polls that cannot compare growth at all.
  for t in 600 900 1200; do
    reading_process_table_unreadable 16000
    out=$(alarm_at "$t")
    assert_not_contains "$out" "recovered" \
      "no poll that could not re-read the raiser may declare the shortage over"
    assert_not_contains "$out" "can see this machine again" \
      "nor may any of them claim sight was regained"
  done

  # The raiser becomes readable and reads clear: now, and only now, it is over.
  reading 16000 true 0
  out=$(alarm_at 1500)
  assert_contains "$out" "recovered" \
    "the shortage ends on the first poll that re-read the raiser and found it clear"
  assert_contains "$out" "The shortage lasted 20m0s" \
    "and the duration must be measured from the original crossing"
  pass "a crossing is held for every poll that could not re-read its raiser"
}

test_a_second_raiser_that_went_blind_still_holds_the_shortage() {
  # Two conditions cross on the same poll. Clearing one of them does not end a
  # shortage the other is still holding, so the record has to carry the set
  # rather than whichever one came first by priority.
  reset_home
  FM_TEST_STALL_WINDOW=600
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # The stall run builds while headroom is still fine.
  local out t
  for t in 300 600; do
    reading_thrashing 16000 38.0
    out=$(alarm_at "$t")
  done
  # Now headroom drops too, so headroom and stall cross on the same poll.
  reading_thrashing 1800 38.0
  out=$(alarm_at 900)
  assert_contains "$out" "MEMORY_ALARM:" "the double crossing must be announced"

  # Headroom is restored, but the stall account goes unreadable, so the stall
  # crossing was never cleared.
  reading_stall_unmeasured 16000
  out=$(alarm_at 1200)
  assert_not_contains "$out" "recovered" \
    "a shortage must not be called over while a second raiser could not be re-read"
  assert_contains "$out" "memory stall could not be read" \
    "and the alarm must name the raiser it could not re-evaluate"
  pass "a second raiser that went blind still holds the shortage"
}

test_a_crossing_after_a_blind_stretch_is_timed_from_the_crossing() {
  # The clock is carried across a crossed to unmeasured lapse on purpose, but a
  # crossing that is NEW on this poll must not inherit the epoch at which some
  # unrelated input went blind.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # Headroom itself becomes unreadable, so nothing can be judged, for an hour.
  local out t
  for t in 300 3900; do
    reading_headroom_unmeasured
    alarm_at "$t" >/dev/null
  done

  # Headroom returns and this machine is genuinely short.
  reading 1800 true 0
  out=$(alarm_at 4200)
  assert_contains "$out" "running out of RAM headroom" "the crossing must be announced"
  reading 16000 true 0
  out=$(alarm_at 4500)
  assert_contains "$out" "The shortage lasted 5m0s" \
    "a fresh crossing must be timed from itself, not from the onset of blindness"
  pass "a crossing after a blind stretch is timed from the crossing"
}

test_a_shortage_ends_even_where_another_condition_can_never_be_read() {
  # The WSL shape this branch exists to detect: the memory-stall account can
  # never be read. A headroom shortage on such a host must still be reported as
  # ended, with the duration it lasted - a condition that is blind but never
  # crossed says nothing about whether the shortage is over, and blocking on it
  # would announce every genuine recovery there as a blindness instead.
  reset_home
  reading_stall_unmeasured 16000
  alarm_at 0 >/dev/null

  local out
  reading_stall_unmeasured 1800
  out=$(alarm_at 300)
  assert_contains "$out" "running out of RAM headroom" "the headroom crossing must be announced"

  reading_stall_unmeasured 16000
  out=$(alarm_at 900)
  assert_contains "$out" "recovered" \
    "a headroom shortage must end even where the stall account can never be read"
  assert_contains "$out" "The shortage lasted 10m0s" \
    "and must carry the duration it really lasted"
  assert_not_contains "$out" "gone blind" \
    "a condition that never crossed must not turn a recovery into a blindness"
  pass "a shortage ends and states its duration even where another condition can never be read"
}

test_a_shortage_the_crossed_condition_could_not_re_read_keeps_its_clock() {
  # The other half: when the condition that RAISED the alarm is the one that
  # cannot be re-read, the shortage is genuinely unjudgeable and must not be
  # called over. It did not end there, though, so the clock keeps running and
  # the recovery that finally comes still says how long it lasted.
  reset_home
  FM_TEST_STALL_WINDOW=600
  reading 16000 true 0
  alarm_at 0 >/dev/null

  local out t
  for t in 300 600 900; do
    reading_thrashing 3577 38.0
    out=$(alarm_at "$t")
  done
  assert_contains "$out" "stalling on memory" "the stall crossing must be announced"

  # The account goes unreadable while the stall crossing is held.
  reading_stall_unmeasured 16000
  out=$(alarm_at 1200)
  assert_contains "$out" "gone blind" \
    "a crossing whose own condition cannot be re-read must not be called over"
  assert_contains "$out" "crossed on memory stall" "and must name the condition that raised it"

  # It comes back, and reads clear.
  reading_thrashing 16000 0.00
  out=$(alarm_at 1500)
  assert_contains "$out" "recovered" "the shortage must be reported as ended once it can be judged"
  # The crossing was declared at t=900 and the shortage ends at t=1500. A clock
  # restarted by the blind poll at t=1200 would report 5m0s instead.
  assert_contains "$out" "The shortage lasted 10m0s" \
    "and the clock must have survived the poll that could not judge it"
  pass "a shortage nobody could re-judge keeps its clock and still reports its duration"
}

test_a_watch_change_on_a_crossed_machine_says_it_is_still_crossed() {
  # This is the only line the poll emits, so a reader must not be able to take
  # it as a monitoring notice for a machine that is currently out of memory.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  reading 1800 true 0
  alarm_at 300 >/dev/null

  local out
  reading_stall_unmeasured 1800
  out=$(alarm_at 600)
  assert_contains "$out" "still running out of RAM headroom" \
    "a watch change on a crossed machine must name the shortage it is holding"
  assert_contains "$out" "cannot judge stall" "and must still report what it lost"
  pass "a watch change on a crossed machine names the shortage it is still holding"
}

test_a_watch_change_past_no_threshold_does_not_claim_a_live_shortage() {
  # `crossed` outlives the reading: the elevated damping band holds whatever the
  # previous state was, so a poll that measured 16000 MiB of headroom still
  # reads as crossed. The held-shortage clause must follow what THIS reading
  # measured, not the state label, or the line tells the fleet a machine with
  # 16000 MiB free is running out of RAM headroom. The shortage is still on the
  # books, and the line says that instead.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # Crossed on headroom, with a memory stall running underneath it.
  local out t
  reading_thrashing 1800 38.0
  out=$(alarm_at 300)
  assert_contains "$out" "running out of RAM headroom" "the headroom crossing must be announced"
  # Polls close enough together to keep the run continuous, so that by t=5100 it
  # stands at 4800s: short of the 5400s window, so the stall condition has not
  # crossed, but 4800 * 1.25 is past it, so it has not cleared the margin either.
  for t in 1500 2700 3900; do
    reading_thrashing 1800 38.0
    out=$(alarm_at "$t")
    assert_contains "|$out|" "||" "a continuing shortage stays silent"
  done

  # Headroom comes back clear of the margin, which releases the only raiser,
  # while the process table goes unreadable, which changes the watch set and so
  # makes this poll speak.
  FM_TEST_STALL=38.0
  reading_process_table_unreadable 16000
  out=$(alarm_at 5100)
  assert_not_contains "$out" "still running out of RAM headroom" \
    "a poll holding no raiser must not claim a shortage it released"
  assert_not_contains "$out" "still stalling on memory" \
    "nor one no condition ever raised"
  assert_contains "$out" "cannot judge horizon" "it must still report the instrument it lost"
  assert_contains "$out" "16000 MiB RAM headroom available" \
    "and must state the headroom it actually measured"
  assert_contains "$out" "has not declared the earlier shortage over" \
    "but it must still say the shortage it recorded has not been declared over"
  pass "a watch change past no threshold does not claim a live shortage"
}

test_a_shortage_survives_a_damped_poll_and_is_still_reported_as_ended() {
  # The whole poll outcome is one decision, so a raiser can leave the durable
  # record only on the poll that announces the recovery. Four polls, and the
  # third is the one that used to lose the shortage: the machine is readable
  # again and headroom is clear by the margin, but a stall run sitting inside
  # the margin band damps the verdict to `elevated`, which announces nothing.
  # A raiser released there leaves the fourth poll with nothing to recognise,
  # so a real ten-minute shortage ends with no recovery, no duration, and a
  # claim that sight was restored where nothing had been lost.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # The run starts at t=300 and is credited every 300s, so by t=5400 it stands
  # at 5100s: short of the 5400s window, so nothing crosses on stall, but past
  # 5400/1.25, so the stall condition is not clear by the margin either.
  local out t
  for t in 300 600 900 1200 1500 1800 2100 2400 2700 3000 3300 3600 3900 4200 4500; do
    reading_thrashing 16000 38.0
    out=$(alarm_at "$t")
    assert_contains "|$out|" "||" "a calm machine with a run under way says nothing"
  done

  reading_thrashing 1800 38.0
  out=$(alarm_at 4800)
  assert_contains "$out" "running out of RAM headroom" "the headroom crossing must be announced"

  reading_headroom_unmeasured
  out=$(alarm_at 5100)
  assert_contains "$out" "gone blind" "a poll that could not read headroom judges nothing"
  assert_not_contains "$out" "recovered" "and must not end the shortage"

  # Sight returns and headroom is clear by the margin, but the stall run damps
  # the verdict, so this poll announces neither a crossing nor a recovery.
  reading_thrashing 16000 38.0
  out=$(alarm_at 5400)
  assert_not_contains "$out" "recovered" \
    "a damped poll must not end a shortage it never announced the end of"
  assert_not_contains "$out" "can see this machine again" \
    "nor claim a restoration on a poll whose state did not move"
  assert_contains "$out" "back under watch on this machine" \
    "it must still report the instruments it got back"
  assert_contains "$out" "has not declared the earlier shortage over" \
    "and must say the shortage it recorded is still on the books"

  reading_thrashing 16000 0.00
  out=$(alarm_at 5700)
  assert_contains "$out" "recovered" "the shortage must be reported as ended once it can be"
  # The crossing was declared at t=4800 and ends at t=5700. A clock restarted by
  # either of the two intervening polls would report 10m0s or 5m0s instead.
  assert_contains "$out" "The shortage lasted 15m0s" \
    "and the duration must run from the original crossing"
  assert_not_contains "$out" "can see this machine again" \
    "a shortage that ended is a recovery, not a regained instrument"

  local log="$HOME_DIR/data/memory-alarm.log"
  [ "$(grep -c 'recovered' "$log")" -eq 1 ] \
    || fail "the durable record must carry the recovery exactly once"
  [ "$(grep -c 'The shortage lasted 15m0s' "$log")" -eq 1 ] \
    || fail "the durable record must carry the duration measured from the crossing"
  [ "$(grep -c 'can see this machine again' "$log")" -eq 0 ] \
    || fail "no poll in this sequence regained sight it had not lost"
  pass "a shortage survives a damped poll and is still reported as ended"
}

test_sight_is_reported_regained_once_for_one_loss() {
  # `elevated` damps the state label into whatever the previous poll decided, so
  # a poll that watched all three conditions and merely found the machine
  # hovering still carries the label `unmeasured`. A restoration keyed on that
  # label is announced a second time on the next poll, where nothing had been
  # blind at all, and the durable log then shows one blind period ending twice.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  local out
  reading_headroom_unmeasured
  out=$(alarm_at 300)
  assert_contains "$out" "gone blind" "a poll that could not read headroom judges nothing"

  # 2800 MiB is above the 2400 MiB floor but short of the 3000 the 1.25 margin
  # demands, so this poll judges every condition and lands in the elevated band.
  reading 2800 true 0
  out=$(alarm_at 600)
  assert_contains "$out" "back under watch on this machine" \
    "the poll that got the instruments back must say so"

  reading 16000 true 0
  out=$(alarm_at 900)
  assert_not_contains "$out" "can see this machine again" \
    "a poll whose predecessor was not blind must not announce a restoration"
  assert_not_contains "$out" "back under watch on this machine" \
    "nor announce the same restoration a second time"

  local log="$HOME_DIR/data/memory-alarm.log"
  [ "$(grep -c 'back under watch on this machine' "$log")" -eq 1 ] \
    || fail "one loss of sight must leave exactly one restoration in the record"
  [ "$(grep -c 'can see this machine again' "$log")" -eq 0 ] \
    || fail "the restoration was already spoken, so it must not be spoken again"
  pass "sight is reported regained once for one loss"
}

test_an_unconfigured_gate_is_not_reported_as_a_condition_the_alarm_lost() {
  # A home that never configured the gate must still be told the condition is
  # unwatched - that is the standing rule - but it was never judged, so it was
  # never lost either.
  reset_home
  reading_thrashing 16000 0.00
  local out
  out=$(unconfigured_alarm)
  assert_contains "$out" "only partly watched" \
    "an unconfigured condition must still be reported rather than passed off as calm"
  assert_not_contains "$out" "no longer judge" \
    "a gate nobody configured was never judged, so it cannot have been lost"
  assert_contains "$out" "no stall gate is configured" "and the reading must say why"
  pass "an unconfigured gate is reported as unwatched without claiming the alarm lost it"
}

test_a_condition_that_becomes_unjudgeable_is_spoken_once() {
  # The standing rule is that an instrument this alarm cannot read is never
  # relayed as calm. A machine only PARTLY watched is not a watched machine, so
  # the set of conditions it cannot judge is a state: a change in it is spoken
  # once, and an unchanged set stays silent rather than nagging every poll.
  reset_home
  reading 16000 true 0
  alarm >/dev/null

  local out
  reading_stall_unmeasured 16000
  out=$(alarm)
  assert_contains "$out" "MEMORY_ALARM:" \
    "a condition that became unjudgeable must be spoken on the watcher's channel"
  assert_contains "$out" "cannot judge stall" "and must name the condition it lost"
  assert_contains "$out" "not an all-clear" "and must not read as an all-clear"
  assert_not_contains "$out" "CROSSED" "and must never call a judged machine crossed"

  # Still unjudgeable: the same silence a continuing shortage gets.
  reading_stall_unmeasured 16000
  out=$(alarm)
  assert_contains "|$out|" "||" "an unchanged watch must not be repeated on every poll"

  # The account comes back.
  reading 16000 true 0
  out=$(alarm)
  assert_contains "$out" "back under watch on this machine" "regaining a condition must be spoken once too"
  out=$(alarm)
  assert_contains "|$out|" "||" "and then must go quiet again"

  [ "$(log_lines)" -eq 2 ] || fail "each change of watch belongs in the durable record exactly once"
  assert_grep 'watch=unjudged stall' "$HOME_DIR/data/memory-alarm.log" \
    "the record must carry which conditions the poll was not watching"
  assert_grep 'watch=all' "$HOME_DIR/data/memory-alarm.log" \
    "and must say so when it could judge every one of them"
  pass "a change in what the alarm can judge is spoken exactly once and recorded"
}

test_a_blind_stall_poll_neither_erases_the_run_nor_credits_it() {
  # A poll that could not read the account is not a poll that saw a calm
  # machine. It must not be treated more harshly than a poll that never
  # happened, which the continuity limit forgives up to 1260s.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  reading_thrashing 3577 38.0
  alarm_at 300 >/dev/null

  # One unreadable poll in the middle of a genuine run.
  reading_stall_unmeasured 3577
  alarm_at 600 >/dev/null

  # The run is still the one that began at 300, neither reset nor advanced by
  # the poll that could not see.
  local out
  reading_thrashing 3577 38.0
  out=$(alarm_at 900 --status)
  assert_contains "$out" "stalling for 10m0s" \
    "a blind poll must neither reset the clock nor credit itself to the run"

  # Blindness that lasts expires the run by the same rule a silent watcher does.
  reading_stall_unmeasured 3577
  alarm_at 1200 >/dev/null
  reading_thrashing 3577 38.0
  out=$(alarm_at 2600 --status)
  assert_contains "$out" "stalling for 0s" \
    "a run must expire by the continuity limit when the blindness outlasts it"
  pass "a blind stall poll leaves the run exactly as it stands and lets continuity decide"
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
  assert_contains "$out" "re-read and found clear" "the alarm must say why it cannot call the shortage over"
  pass "recovery is never declared on the strength of growth nobody could compare"
}

test_scoped_growth_on_a_calm_machine_is_not_a_growth_all_clear() {
  reset_home
  reading_growth_scoped 16000
  local out
  out=$(alarm --status)
  assert_contains "$out" "not comparable" "an uncomparable growth reading must say so"
  assert_contains "$out" "not judged" "and must say that the condition was not judged"
  assert_contains "$out" "memory stall 0.00% with nothing able to run" \
    "and must state the conditions it DID judge, so a reader can tell them apart"
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

test_a_machine_already_drowning_in_swap_is_seen() {
  # The 2026-08-27 shape: RAM headroom comfortably above the floor, nothing
  # growing, and a machine nobody can use. Both original conditions read clear
  # here, which is why this one exists. It takes a RUN of consecutive polls to
  # cross, because duration is the discriminator, so play one out.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  # tugboat's incident figures: 38.0% with nothing able to run, 42.0% with at
  # least one task waiting, headroom 3577 MiB, and 4245 MiB already in swap.
  for t in $(seq 300 300 5400); do
    reading_thrashing 3577 38.0 4245 2900 42.0
    out=$(alarm_at "$t")
    assert_contains "|$out|" "||" "at ${t}s the run is still short of the window and must stay silent"
  done
  reading_thrashing 3577 38.0 4245 2900 42.0
  out=$(alarm_at 5700)
  assert_contains "$out" "MEMORY_ALARM:" "a stall that outlasts the window must be announced"
  assert_contains "$out" "stalling on memory" \
    "the line must not open by calling this a RAM-headroom shortage, which is the one thing it is not"
  assert_not_contains "$out" "running out of RAM headroom" \
    "headroom is healthy in this shape and saying otherwise sends the reader after the wrong cause"
  assert_contains "$out" "continuously for 1h30m" \
    "the crossing must lead with the duration, because the duration is the finding"
  assert_contains "$out" "run at all for 38.0% of the last 60 seconds" \
    "and must still state the level it measured"
  assert_contains "$out" "3577 MiB of RAM headroom still looks available" \
    "and must state the healthy headroom reading alongside it"
  assert_contains "$out" "Swap in use: 4245 MiB" "and must state how much has already gone to swap"
  assert_contains "$out" "Nothing has been limited or killed" \
    "the crossing must say plainly that nothing was acted against"
  pass "a machine still stalling after the whole window is seen, and named as stalling rather than short of headroom"
}

test_the_two_original_conditions_stay_silent_on_that_same_reading() {
  # The load-bearing claim of this whole change, asserted rather than argued:
  # with the stall condition switched off, the exact incident reading produces
  # nothing at all. Headroom is above the floor and nothing is growing.
  reset_home
  reading 16000 true 0
  unconfigured_alarm >/dev/null
  reading_thrashing 3577 38.0 4245 2900 42.0
  local out
  out=$(unconfigured_alarm)
  assert_contains "|$out|" "||" \
    "headroom and growth alone must be shown to say nothing here, which is why this condition exists"
  pass "the headroom and horizon conditions are silent on the incident reading, as measured"
}

test_the_stall_crossing_names_the_largest_resident_process_not_a_grower() {
  # Nothing is growing in this shape - the memory was taken hours earlier - so a
  # growth ranking would name nobody at exactly the moment somebody needs naming.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  for t in $(seq 300 300 5700); do
    reading_thrashing 3577 38.0
    out=$(alarm_at "$t")
  done
  assert_contains "$out" "Largest resident process:" \
    "a stall crossing must name by residency, because nothing is growing in this shape"
  assert_contains "$out" "chrome --headless (pid 9001)" "the alarm must name the process"
  assert_contains "$out" "account coditan" "the alarm must name the account"
  assert_contains "$out" "serving task beta (ship, beta-project)" "the alarm must name the work it serves"
  assert_contains "$out" "holding 2900 MiB resident" "and must state the measurement it named it on"
  assert_not_contains "$out" "Largest grower" \
    "naming a grower here would report the absence of the wrong measurement"
  assert_grep 'memory stall for' "$HOME_DIR/data/memory-alarm.log" \
    "the durable record must carry the run it decided on"
  assert_grep 'chrome --headless' "$HOME_DIR/data/memory-alarm.log" \
    "and must carry the process it named"
  pass "a stall crossing names the largest resident process, with its account and its work"
}

test_the_stall_condition_keeps_the_protected_label() {
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  for t in $(seq 300 300 5700); do
    printf '{"schema":"fm-memory-reading.v1","complete":true,"unmeasured":[],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":29200000},"stall":{"some_avg10":42.0,"some_avg60":42.0,"full_avg10":38.0,"full_avg60":38.0},"growth":{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null},"processes":[{"pid":9003,"account":"coditan","rss_kb":2969600,"growth_kb_per_min":0,"attribution":{"kind":"infrastructure","detail":"wake delivery for coditan-firstmate","route":"cwd"},"protected":true,"command":"fm-delivery"}]}\n' \
      "$(( 3577 * 1024 ))" >"$ANSWER"
    out=$(alarm_at "$t")
  done
  assert_contains "$out" "wake-delivery listener, which nothing may act against" \
    "the protected label must travel with the name on this condition too, not only on growth"
  pass "the stall condition carries the protected label wherever it names a process"
}

test_the_measured_quiet_band_does_not_even_start_a_run() {
  # yacht measured windowed full memory stall across five vantages on
  # 2026-08-28: every one read 0.00 except tugboat's post-recovery avg300 at
  # 0.02. The gate sits above that band, so a quiet machine starts no clock.
  local out level
  for level in 0.00 0.02 0.37; do
    reset_home
    reading_thrashing 16000 "$level"
    out=$(alarm_at 0 --status)
    assert_contains "$out" "memory-alarm: ok" "a stall of $level is inside the measured quiet band"
    assert_not_contains "$out" "stalling for" \
      "a reading inside the measured quiet band must not start a run at all"
  done
  pass "the gate sits above the whole measured quiet band, so a calm machine starts no clock"
}

test_ordinary_heavy_work_goes_over_the_gate_and_never_crosses() {
  # The measurement this design rests on. On coditan-vessel on 2026-08-28 this
  # repository's own tooling drove full avg60 to 29.30 on a healthy seat - higher
  # than plenty of real trouble - and then STOPPED, because work that finishes
  # stops stalling. Level cannot tell those apart; duration can.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  for t in 300 600 900 1200; do
    reading_thrashing 16000 29.30
    out=$(alarm_at "$t")
    assert_contains "|$out|" "||" "ordinary heavy work at ${t}s must not fire, however high the level goes"
  done
  # The job finishes. The clock must go back to zero, not carry on.
  reading_thrashing 16000 0.00
  out=$(alarm_at 1500)
  assert_contains "|$out|" "||" "the end of a busy stretch is not an event"
  # A second, longer stretch must be timed from its own start: if the run were
  # not reset it would inherit 1200s and cross far too early.
  for t in $(seq 1800 300 6600); do
    reading_thrashing 16000 29.30
    out=$(alarm_at "$t")
    assert_contains "|$out|" "||" "a fresh busy stretch at ${t}s must be timed from its own start"
  done
  [ "$(log_lines)" -eq 0 ] || fail "ordinary heavy work must leave no durable record at all"
  pass "ordinary heavy work goes far over the gate, ends, and never reaches the window"
}

test_a_run_is_only_a_run_if_the_polls_actually_happened() {
  # A gap in polling means nobody was watching, and a stretch nobody watched is
  # not a run that was seen. Without this, a watcher that stopped for an hour
  # would come back and credit itself the whole hour.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  reading_thrashing 16000 29.30
  alarm_at 300 >/dev/null
  # Nothing polls for well past the continuity limit, then one poll arrives at a
  # moment that would be past the window if the unwatched gap were credited.
  reading_thrashing 16000 29.30
  local out
  out=$(alarm_at 6000)
  assert_contains "|$out|" "||" \
    "a gap in polling must restart the run rather than hand it the time nobody watched"
  pass "a run of consecutive polls is credited only for the polls that happened"
}

test_a_calm_machine_says_how_far_a_run_has_got() {
  # A run under way is the clock this condition decides on. A reader who cannot
  # see it cannot tell an ordinary busy stretch from the start of something that
  # will not stop.
  reset_home
  reading_thrashing 16000 29.30
  alarm_at 0 >/dev/null
  reading_thrashing 16000 29.30
  local out
  out=$(alarm_at 900 --status)
  assert_contains "$out" "memory-alarm: ok" "a short run must not be a crossing"
  assert_contains "$out" "stalling for 15m0s of the 1h30m it would take to count" \
    "a calm verdict must show how far the run has got and what it would take"
  pass "a calm machine states the run under way and the window it would have to outlast"
}

test_status_does_not_advance_the_run_it_reports() {
  # The same rule the growth sample has: somebody asking what the alarm sees
  # right now must not be feeding the clock they are reading.
  reset_home
  reading_thrashing 16000 29.30
  alarm_at 0 >/dev/null
  local before after
  before=$(cat "$HOME_DIR/state/memory-alarm.stall")
  alarm_at 300 --status >/dev/null
  after=$(cat "$HOME_DIR/state/memory-alarm.stall")
  [ "$before" = "$after" ] || fail "--status advanced the run it was only supposed to report"
  pass "--status reports the run without extending it"
}

test_a_stall_reading_the_alarm_could_not_take_is_never_an_all_clear() {
  # The reader marks a missing pressure file unmeasured, so this shape should
  # never reach the alarm. If it ever does, the answer is "could not see",
  # because a stall condition that reports absence as quiet is the exact failure
  # this alarm exists to remove.
  reset_home
  reading 16000 true 0
  alarm >/dev/null
  FM_TEST_STALL=none
  reading 16000 true 0
  local out status=0
  out=$(alarm --status) || status=$?
  expect_code 0 "$status" "--status with headroom and growth still readable"
  assert_contains "$out" "memory stall could not be read" \
    "a stall the alarm could not read must say so in its own voice"
  assert_contains "$out" "not judged" "and must say that the condition went unjudged"
  assert_not_contains "$out" "memory stall 0.00%" \
    "a stall that could not be read must never be printed as a measured zero"
  pass "a stall reading the alarm could not take is reported as unjudged, never as quiet"
}

test_recovery_is_not_declared_on_a_stall_nobody_could_read() {
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local t
  for t in $(seq 300 300 5700); do
    reading_thrashing 3577 38.0
    alarm_at "$t" >/dev/null          # crossed on a run past the window
  done
  FM_TEST_STALL=none
  reading 16000 true 0                # headroom and growth fine, stall unreadable
  local out
  out=$(alarm_at 6000)
  assert_not_contains "$out" "recovered" \
    "a shortage must not be declared over by a run that could not re-read the condition that raised it"
  assert_contains "$out" "re-read and found clear" "the alarm must say why it cannot call the shortage over"
  pass "recovery is never declared on the strength of a stall nobody could read"
}

test_leaving_a_stall_crossing_is_earned_by_the_run_ending() {
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  local out t
  for t in $(seq 300 300 5700); do
    reading_thrashing 3577 38.0
    out=$(alarm_at "$t")
  done
  assert_contains "$out" "MEMORY_ALARM:" "the crossing must have happened by the end of the window"
  # Still stalling: silent, and still crossed.
  reading_thrashing 3577 38.0
  out=$(alarm_at 6000)
  assert_contains "|$out|" "||" "a continuing stall must be reported once, not on every poll"
  # The stall ends, so the run resets and the recovery is announced.
  reading_thrashing 16000 0.00
  out=$(alarm_at 6300)
  assert_contains "$out" "recovered" "the end of the stall must be announced"
  [ "$(log_lines)" -eq 2 ] || fail "crossing and recovery must each leave exactly one record"
  assert_grep 'memory stall for' "$HOME_DIR/data/memory-alarm.log" \
    "the durable record must carry the run the decision was made on"
  pass "a stall crossing is left when the run ends, and reported once at each end"
}

test_a_malformed_stall_gate_falls_back_to_the_shipped_default_and_says_so() {
  # An unparsable threshold would compare as zero in awk and hold this condition
  # crossed on every reading forever, which is the loudest possible way to go
  # blind. It falls back to the shipped default instead, the way every sibling
  # threshold does - a typo is not a decision to stop watching this machine -
  # and says on the same reading that the configured value was unusable, so the
  # substitution can never be mistaken for a home that chose 1.00 deliberately.
  reset_home
  reading_thrashing 16000 0.00
  local out
  out=$(malformed_gate_alarm --status)
  assert_contains "$out" "memory-alarm: ok" "a malformed threshold must not hold a calm machine crossed"
  assert_contains "$out" "memory stall 0.00%" \
    "a malformed gate must leave the condition judged on the default, not switched off"
  assert_contains "$out" "FM_MEMORY_ALARM_STALL" \
    "the reading must name the setting whose configured value it could not use"
  assert_contains "$out" "default gate of 1.00%" "and must state the gate it fell back to"
  assert_not_contains "$out" "no stall gate is configured" \
    "a malformed gate is a substitution, not an unconfigured condition"

  # And the substituted gate is really in force: a machine over it starts the
  # clock, which an unwatched condition would never report at all.
  reading_thrashing 3577 38.0
  out=$(malformed_gate_alarm --status)
  assert_contains "$out" "stalling for" \
    "the fallback gate must actually gate, so a stalling machine starts a run against it"
  pass "a malformed stall gate falls back to the shipped default, keeps watching, and says the configured value was unusable"
}

test_a_stall_run_that_cannot_be_persisted_is_reported_rather_than_read_as_calm() {
  # The run of consecutive polls is the only thing this condition decides on. A
  # run that cannot be written is never credited, so the alarm would report calm
  # forever on exactly the shape it was built for - going quiet when its own
  # instrument breaks, which is the failure this whole programme removes.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null
  # A directory where the run file goes: nothing can write it, whoever runs this.
  mkdir -p "$HOME_DIR/state/memory-alarm.stall"
  reading_thrashing 3577 38.0
  local out
  out=$(alarm_at 300)
  assert_contains "$out" "MEMORY_ALARM:" \
    "a stall run that could not be persisted must not leave the poll silent"
  assert_contains "$out" "could not persist the memory-stall run" \
    "the alarm must say the run was not durably recorded"
  assert_contains "$out" "memory-alarm.stall" "and must name the file it could not write"
  pass "a stall run that cannot be persisted is reported rather than passed off as a calm machine"
}

test_a_zero_stall_gate_falls_back_rather_than_pinning_the_alarm_crossed() {
  # 0 is the value an operator reaches for to mean "off" - the documented off
  # switch is the empty string. Taken literally it is a gate no reading can ever
  # fall below, so an idle machine reads as stalling on every poll, the run never
  # resets, and past the window the alarm is pinned crossed with nothing wrong
  # and no way back. It falls back the same way a malformed gate does.
  reset_home
  reading_thrashing 16000 0.00
  local out status=0
  out=$(zero_configured_alarm 0 7200 --status) || status=$?
  expect_code 0 "$status" "an idle machine with the gate configured to zero"
  assert_contains "$out" "memory-alarm: ok" "a zero gate must not hold an idle machine crossed"
  assert_not_contains "$out" "stalling for" "an idle machine must start no run against a zero gate"
  assert_contains "$out" "was zero" "the reading must say the configured value was not usable"
  assert_contains "$out" "default gate of 1.00%" "and must state the gate it fell back to"

  # 0.00 is the same value wearing a percentage, and must fall back too.
  status=0
  out=$(zero_configured_alarm 0.00 7200 --status) || status=$?
  expect_code 0 "$status" "an idle machine with the gate configured to 0.00"
  assert_contains "$out" "default gate of 1.00%" "a zero written as a percentage must fall back as well"

  # Driven forward: a machine that is genuinely idle stays silent for longer
  # than the window a zero gate would have crossed inside.
  reset_home
  local t
  for t in $(seq 0 300 7500); do
    reading_thrashing 16000 0.00
    FM_TEST_AT=$((BASE_NOW + t)) out=$(zero_configured_alarm 0 7200)
    assert_contains "|$out|" "||" "an idle machine with a zero gate must never fire"
  done
  pass "a stall gate configured to zero falls back to the shipped default and says so"
}

test_a_zero_stall_window_falls_back_rather_than_crossing_on_the_first_poll() {
  # The run test is `>=`, so a zero window is outlasted by a run of zero
  # seconds: it would cross on the first poll of a machine that has not stalled
  # for a single second.
  reset_home
  reading_thrashing 16000 0.00
  local out status=0
  out=$(zero_configured_alarm 1.00 0 --status) || status=$?
  expect_code 0 "$status" "a calm machine with the window configured to zero"
  assert_contains "$out" "memory-alarm: ok" "a zero window must not cross on the first poll"
  assert_contains "$out" "WINDOW configured for this home was zero" \
    "the reading must say the configured window was not usable"
  assert_contains "$out" "7200 seconds" "and must state the window it fell back to"

  # Even a machine over the gate must not cross straight away: the fallback
  # window is what it now has to outlast.
  reset_home
  reading_thrashing 3577 38.0
  out=$(zero_configured_alarm 1.00 0)
  assert_contains "|$out|" "||" "a stalling machine must not cross a zero window on its first poll"
  pass "a stall window configured to zero falls back to the shipped default and says so"
}

test_a_run_that_could_not_be_cleared_is_not_credited_across_the_calm_poll() {
  # rm needs a writable DIRECTORY, so a clear can fail while the run file itself
  # is still writable. If the stale start survives, the next stalling poll reads
  # it back and credits the run straight across the calm poll that should have
  # reset it, crossing the window on a machine that was never stalling
  # continuously.
  reset_home
  reading 16000 true 0
  alarm_at 0 >/dev/null

  # A run begins well before the window would be reached.
  reading_thrashing 3577 38.0
  alarm_at 300 >/dev/null
  [ -s "$HOME_DIR/state/memory-alarm.stall" ] || fail "the first stalling poll did not record a run"

  # The directory loses write permission, so the file can be truncated but not
  # unlinked, and the machine goes calm.
  chmod 500 "$HOME_DIR/state"
  local out
  reading_thrashing 16000 0.00
  out=$(alarm_at 600)
  chmod 700 "$HOME_DIR/state"
  assert_contains "|$out|" "||" "a clear that fell back to truncation is not an instrument failure"

  # The machine stalls again. The clock must start from here, not from the run
  # the calm poll was supposed to end.
  reading_thrashing 3577 38.0
  out=$(alarm_at 900 --status)
  assert_not_contains "$out" "CROSSED" "a reset run must not be credited across the calm poll"
  assert_contains "$out" "stalling for 0s" "the run must restart at the poll that saw the stall again"
  pass "a run that could not be unlinked is invalidated rather than credited across a calm poll"
}

test_an_unconfigured_stall_gate_is_reported_never_silently_unwatched() {
  # A home can switch this condition off, and one that has must be told so. An
  # alarm that quietly does not watch for something is indistinguishable from one
  # that watched and found nothing, which is the failure this whole programme
  # removes, so the absence has to be spoken.
  reset_home
  reading_thrashing 16000 29.30
  local out status=0
  out=$(unconfigured_alarm --status) || status=$?
  expect_code 0 "$status" "an unconfigured stall condition on an otherwise healthy machine"
  assert_contains "$out" "no stall gate is configured" \
    "an unconfigured condition must name itself rather than pass for a clear reading"
  assert_contains "$out" "not being watched for memory stall" \
    "and must say plainly what is not being watched"
  assert_not_contains "$out" "memory stall 29.30%" \
    "an unjudged condition must not print its reading as though it had been judged"
  assert_not_contains "$out" "CROSSED" "and must never fire on a threshold nobody chose"
  pass "an unconfigured stall gate is reported as unwatched, never passed off as calm"
}

test_an_unconfigured_stall_gate_does_not_block_a_recovery_it_never_raised() {
  # STALL_BLIND blocks recovery because the instrument failed. An unset gate
  # must NOT, or a home that never configures one would be stuck crossed forever
  # after its first headroom shortage.
  reset_home
  local out
  reading 16000 true 0
  unconfigured_alarm >/dev/null
  reading 1800 true 0
  out=$(unconfigured_alarm)
  assert_contains "$out" "running out of RAM headroom" "the headroom floor must still cross with no stall threshold set"
  reading 16000 true 0
  out=$(unconfigured_alarm)
  assert_contains "$out" "recovered" \
    "a condition that was never armed must not hold the alarm crossed for ever"
  pass "an unconfigured stall gate leaves the other two conditions working end to end"
}

test_the_shipped_gate_and_window_are_the_ones_the_document_derives() {
  # Every case above sets the gate and window explicitly so it can drive a run
  # deterministically, which means none of them would notice the shipped
  # defaults drifting away from the measurements docs/memory-alarm.md derives
  # them from. This is the case that would.
  reset_home
  reading_thrashing 16000 29.30
  local out
  out=$(env FM_HOME="$HOME_DIR" \
            FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
            FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" "$ALARM" --status)
  assert_contains "$out" "of the 2h0m it would take to count" \
    "the shipped window must stay the 7200s the document derives from the measured 4311s job"
  assert_contains "$out" "stalling for 0s" \
    "and the shipped gate must be low enough that a stall of 29.30 starts a run"
  pass "the shipped gate and window match the measurements the document derives them from"
}

test_a_machine_with_no_swap_is_told_apart_from_one_with_swap() {
  # The 2026-08-30 constraint: the same numbers are not worth the same on both
  # shapes. With swap, a shortage degrades and healthy headroom proves nothing;
  # without swap there is no degrading stretch at all, so the floor is the whole
  # warning - and that floor is a far larger share of a small host than of the
  # one it was derived on.
  reset_home
  local out
  reading 1800 true 0
  out=$(alarm)
  assert_contains "$out" "MiB of swap configured" "a machine with swap did not say so on its crossing"
  assert_contains "$out" "not evidence that this machine is healthy"     "a machine with swap did not say what its healthy headroom is worth"

  reset_home
  # tugboat-cloud's shape, which this vessel is moving onto: 7,746 MiB, no swap.
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_SWAP_TOTAL_KB=0
  reading 1800 true 0
  out=$(alarm)
  assert_contains "$out" "no swap configured" "a machine with no swap did not say so on its crossing"
  assert_contains "$out" "the kernel kills something"     "a swapless machine did not say that there is no degrading stretch below the floor"
  # Where the floor came from, and what share of this machine it is, are the
  # derivation note's job and are tested separately in the floor cases below.
  # What this note owes is what that distance is worth on a host with nowhere to
  # put the pressure, and it must not restate the derivation beside it.
  assert_contains "$out" "the whole warning here" "the swapless machine did not say the floor is the whole warning"
  assert_contains "$out" "is unverified"     "an unverified margin was not reported as unverified"
  assert_not_contains "$out" "31.0% of this machine" "the shape note restated the floor's share, which the derivation note already owns"
  pass "a machine with no swap is told apart from one with swap, and says what its floor is worth"
}

test_swap_that_could_not_be_read_is_never_reported_as_no_swap() {
  # A missing SwapTotal already makes the reading incomplete, so this should not
  # be reachable in the field. It is asserted anyway because "no swap" and "swap
  # could not be read" are opposite findings here, and collapsing them would be
  # the substituted zero this alarm exists to refuse.
  reset_home
  FM_TEST_SWAP_TOTAL_KB=null
  reading 1800 true 0
  local out
  out=$(alarm)
  assert_contains "$out" "could not be read" "unreadable swap was not reported as unread"
  assert_not_contains "$out" "no swap configured" "unreadable swap was reported as a machine with no swap"
  pass "swap that could not be read is never reported as a machine with no swap"
}

test_reading_the_shape_moves_no_threshold() {
  # The standing constraint on this branch: reading the shape ADDS a reading and
  # changes nothing about when the alarm fires. Same headroom, same growth, same
  # stall, two machines - the firing decision must be identical.
  local with_swap without_swap
  reset_home
  reading 1800 true 0
  with_swap=$(alarm)
  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_SWAP_TOTAL_KB=0
  reading 1800 true 0
  without_swap=$(alarm)
  assert_contains "$with_swap" "running out of RAM headroom" "the floor stopped crossing on a machine with swap"
  assert_contains "$without_swap" "running out of RAM headroom" "the floor stopped crossing on a machine with no swap"

  # And a machine above the floor stays silent on both shapes.
  reset_home
  reading 16000 true 0
  with_swap=$(alarm)
  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_SWAP_TOTAL_KB=0
  reading 16000 true 0
  without_swap=$(alarm)
  [ -z "$with_swap" ] || fail "a healthy machine with swap spoke: $with_swap"
  [ -z "$without_swap" ] || fail "a healthy machine with no swap spoke: $without_swap"
  pass "reading the shape changes what the alarm says, never when it fires"
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

# --- the derived floor ------------------------------------------------------

test_the_floor_is_derived_from_the_machine_rather_than_shipped() {
  # The failure this replaced: 2,400 MiB was measured on a 23,456 MiB host and
  # then applied unchanged on a 7,746 MiB one, where it is 31% of the machine and
  # single checks in this repository have been measured at 3,860 MiB. Both halves
  # are driven with a fabricated total rather than reasoned about.
  local out
  reset_home
  # The calibration host itself: the derived floor must land back on the number
  # that was measured there, so nothing about this machine's behaviour moves.
  reading 1800 true 0
  out=$(derived_floor_alarm)
  assert_contains "$out" "below the 2400 MiB floor" "the derivation did not reproduce the calibration host's own floor"
  reset_home
  reading 3000 true 0
  out=$(derived_floor_alarm)
  [ -z "$out" ] || fail "the calibration host spoke above its own floor: $out"

  # A third of the machine, same reading. 1,800 MiB crossed a shipped 2,400 and
  # must not cross a floor derived from a 7,746 MiB host, because that is inside
  # ordinary operation there.
  reset_home
  FM_TEST_TOTAL_KB=7931904
  reading 1800 true 0
  out=$(derived_floor_alarm)
  [ -z "$out" ] || fail "the inherited floor still fires inside ordinary operation on a 7,746 MiB machine: $out"

  # And it is still a floor: below the derived one, it crosses.
  reset_home
  FM_TEST_TOTAL_KB=7931904
  reading 700 true 0
  out=$(derived_floor_alarm)
  assert_contains "$out" "below the 793 MiB floor" "the derived floor did not cross on a machine that really was out of headroom"
  pass "the floor is derived from the running machine, not carried from the one it was measured on"
}

test_every_crossing_states_where_its_floor_came_from() {
  # The omission that cost four hours of wakes to notice: the inherited margin
  # was stated only on a machine with no swap, so a machine with swap never said
  # what its floor was worth. Both shapes must say it now.
  local out
  reset_home
  reading 1800 true 0
  out=$(derived_floor_alarm)
  assert_contains "$out" "MiB of swap configured" "the fixture stopped describing a machine with swap"
  assert_contains "$out" "derived from this machine, not shipped" "a machine WITH swap did not state its floor's derivation"
  assert_contains "$out" "10.2% of its 23456 MiB" "the crossing did not state the share the floor was derived at"

  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_SWAP_TOTAL_KB=0
  reading 700 true 0
  out=$(derived_floor_alarm)
  assert_contains "$out" "derived from this machine, not shipped" "a machine with NO swap did not state its floor's derivation"
  assert_contains "$out" "10.2% of its 7746 MiB" "the swapless crossing did not state the share of ITS own machine"
  assert_contains "$out" "ordinary-headroom baseline on that one host only" "the crossing claimed a baseline this fleet does not have"
  pass "every crossing states the derivation of the floor it crossed"
}

test_the_derived_floor_is_never_raised_above_the_figure_that_was_measured() {
  # The share carries a measurement DOWN honestly and must never carry one UP:
  # 10.2% of a 64 GiB host is 6,706 MiB, a backstop no measurement at that host
  # size supports, and asserting one would be this same defect mirrored upward.
  # Driven with a fabricated total, like both halves above.
  local out
  reset_home
  FM_TEST_TOTAL_KB=67108864          # 64 GiB
  reading 3000 true 0
  out=$(derived_floor_alarm)
  [ -z "$out" ] || fail "a 64 GiB host crossed at 3000 MiB, so the floor was derived above the figure anyone measured: $out"

  reset_home
  FM_TEST_TOTAL_KB=67108864
  reading 1800 true 0
  out=$(derived_floor_alarm)
  assert_contains "$out" "below the 2400 MiB floor" "a 64 GiB host did not fall back to the measured 2400 MiB floor"
  assert_not_contains "$out" "below the 6706 MiB floor" "a 64 GiB host used the uncapped share as its floor"
  assert_contains "$out" "capped there rather than derived upward" "a capped floor did not say it was capped"
  assert_contains "$out" "would be 6706 MiB" "a capped floor did not name the share it declined"
  pass "the derived floor is capped at the figure that was measured, never raised above it"
}

test_a_configured_floor_wins_over_the_derived_one() {
  local out
  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_FLOOR=2400
  reading 1800 true 0
  out=$(derived_floor_alarm)
  unset FM_TEST_FLOOR
  assert_contains "$out" "below the 2400 MiB floor" "an explicitly configured floor did not win over the derived one"
  assert_contains "$out" "the one this home configures" "a configured floor was not reported as configured"
  assert_contains "$out" "793 MiB on this machine" "a configured floor did not state what the derivation would have given"

  # Above the calibration host the derivation is the CAP, not the share, and the
  # note has to name the figure it actually would have used. A reader who checks
  # the multiplication must find it true: 10.2% of 65,536 MiB is 6,706 MiB, and
  # 2,400 MiB is what the cap leaves, so neither may be printed under the other's
  # label.
  reset_home
  FM_TEST_TOTAL_KB=67108864
  FM_TEST_FLOOR=4096
  reading 1800 true 0
  out=$(derived_floor_alarm)
  unset FM_TEST_FLOOR
  assert_contains "$out" "below the 4096 MiB floor" "a configured floor did not win on a machine larger than the calibration host"
  assert_contains "$out" "2400 MiB, capped there rather than derived upward" "a configured floor did not name the capped figure the derivation would have given"
  assert_contains "$out" "would be 6706 MiB" "a configured floor did not name the share the cap declined"
  assert_not_contains "$out" "2400 MiB on this machine" "the capped figure was presented as this machine's share of total RAM"

  # An unusable value is a typo rather than a choice, so it falls back to the
  # derivation the same way an unusable stall gate falls back to the shipped one -
  # and says so, rather than silently switching the condition off.
  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_FLOOR=0
  reading 700 true 0
  out=$(derived_floor_alarm)
  unset FM_TEST_FLOOR
  assert_contains "$out" "below the 793 MiB floor" "a zero floor did not fall back to the derived one"
  assert_contains "$out" "was zero, which no reading can ever fall below" "a zero floor was not reported as unusable"

  reset_home
  FM_TEST_TOTAL_KB=7931904
  FM_TEST_FLOOR=plenty
  reading 700 true 0
  out=$(derived_floor_alarm)
  unset FM_TEST_FLOOR
  assert_contains "$out" "below the 793 MiB floor" "a malformed floor did not fall back to the derived one"
  assert_contains "$out" "was not a number of MiB" "a malformed floor was not reported as unusable"
  pass "a configured floor wins, and an unusable one falls back to the derivation and says so"
}

test_a_healthy_machine_says_nothing
test_the_headroom_floor_crosses_and_names_what_it_found
test_the_horizon_crosses_on_aggregate_growth_and_names_the_offender
test_a_continuing_shortage_is_reported_once
test_crossing_and_recovery_both_leave_a_durable_record
test_a_machine_hovering_at_the_line_does_not_flap
test_an_instrument_that_could_not_read_is_never_an_all_clear
test_one_unreadable_input_does_not_silence_the_conditions_that_were_read
test_a_recovery_is_never_declared_from_a_reading_that_missed_an_input
test_an_input_no_condition_uses_does_not_hold_back_a_recovery
test_a_recovery_states_how_long_the_shortage_actually_lasted
test_sight_is_never_claimed_regained_while_a_condition_is_still_unreadable
test_a_growth_sample_that_merely_aged_out_is_not_a_lost_instrument
test_a_growth_sample_no_poll_can_replace_is_a_lost_instrument
test_a_growth_sample_that_could_not_be_stored_is_a_lost_instrument
test_a_raiser_that_only_dipped_under_its_threshold_is_not_released
test_a_raiser_survives_the_poll_that_could_not_read_its_own_input
test_switching_the_stall_gate_off_releases_a_stall_raiser_it_would_otherwise_pin
test_a_crossing_is_held_for_every_poll_that_could_not_re_read_its_raiser
test_a_second_raiser_that_went_blind_still_holds_the_shortage
test_a_crossing_after_a_blind_stretch_is_timed_from_the_crossing
test_a_shortage_ends_even_where_another_condition_can_never_be_read
test_a_shortage_the_crossed_condition_could_not_re_read_keeps_its_clock
test_a_watch_change_on_a_crossed_machine_says_it_is_still_crossed
test_a_watch_change_past_no_threshold_does_not_claim_a_live_shortage
test_a_shortage_survives_a_damped_poll_and_is_still_reported_as_ended
test_sight_is_reported_regained_once_for_one_loss
test_an_unconfigured_gate_is_not_reported_as_a_condition_the_alarm_lost
test_a_condition_that_becomes_unjudgeable_is_spoken_once
test_a_blind_stall_poll_neither_erases_the_run_nor_credits_it
test_a_reading_that_produced_nothing_is_blindness_not_health
test_recovery_is_not_declared_on_growth_nobody_could_compare
test_scoped_growth_on_a_calm_machine_is_not_a_growth_all_clear
test_a_machine_already_drowning_in_swap_is_seen
test_the_two_original_conditions_stay_silent_on_that_same_reading
test_ordinary_heavy_work_goes_over_the_gate_and_never_crosses
test_a_run_is_only_a_run_if_the_polls_actually_happened
test_the_measured_quiet_band_does_not_even_start_a_run
test_a_calm_machine_says_how_far_a_run_has_got
test_status_does_not_advance_the_run_it_reports
test_the_stall_crossing_names_the_largest_resident_process_not_a_grower
test_the_stall_condition_keeps_the_protected_label
test_a_stall_reading_the_alarm_could_not_take_is_never_an_all_clear
test_recovery_is_not_declared_on_a_stall_nobody_could_read
test_leaving_a_stall_crossing_is_earned_by_the_run_ending
test_a_malformed_stall_gate_falls_back_to_the_shipped_default_and_says_so
test_a_stall_run_that_cannot_be_persisted_is_reported_rather_than_read_as_calm
test_a_zero_stall_gate_falls_back_rather_than_pinning_the_alarm_crossed
test_a_zero_stall_window_falls_back_rather_than_crossing_on_the_first_poll
test_a_run_that_could_not_be_cleared_is_not_credited_across_the_calm_poll
test_an_unconfigured_stall_gate_is_reported_never_silently_unwatched
test_an_unconfigured_stall_gate_does_not_block_a_recovery_it_never_raised
test_the_shipped_gate_and_window_are_the_ones_the_document_derives
test_status_labels_horizon_as_ram_headroom_not_swap_exhaustion
test_the_wake_delivery_listener_keeps_its_label
test_the_alarm_limits_nothing_and_kills_nothing
test_persistence_failures_replace_transition_claims_with_diagnostics
test_arming_registers_a_check_and_is_idempotent
test_an_alarm_that_stopped_running_is_reported
test_a_machine_with_no_swap_is_told_apart_from_one_with_swap
test_swap_that_could_not_be_read_is_never_reported_as_no_swap
test_reading_the_shape_moves_no_threshold
test_the_floor_is_derived_from_the_machine_rather_than_shipped
test_every_crossing_states_where_its_floor_came_from
test_the_derived_floor_is_never_raised_above_the_figure_that_was_measured
test_a_configured_floor_wins_over_the_derived_one
test_usage_errors_exit_two
