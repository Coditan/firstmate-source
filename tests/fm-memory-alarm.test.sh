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

# reading <available_mib> <complete> [<growth_kb_per_min> <protected> <kind> <detail>]
reading() {
  local avail_mib=$1 complete=$2 growth=${3:-0} protected=${4:-false} kind=${5:-task} detail=${6:-'alpha (ship, alpha-project)'}
  local procs='[]' unmeasured='[]' growth_obj='{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null}'
  if [ "$growth" != 0 ]; then
    procs=$(printf '[{"pid":4242,"account":"coditan","rss_kb":900000,"growth_kb_per_min":%s,"attribution":{"kind":"%s","detail":"%s","route":"cwd"},"protected":%s,"command":"python3 balloon.py"}]' \
      "$growth" "$kind" "$detail" "$protected")
  fi
  [ "$complete" = false ] && unmeasured='[{"input":"process-table","reason":"the process table could not be read"}]'
  printf '{"schema":"fm-memory-reading.v1","complete":%s,"unmeasured":%s,"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":33554428,"swap_free_kb":33554428},"stall":%s,"growth":%s,"processes":%s}\n' \
    "$complete" "$unmeasured" "$((avail_mib * 1024))" "$(stall_obj "$FM_TEST_STALL")" "$growth_obj" "$procs" >"$ANSWER"
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
  printf '{"schema":"fm-memory-reading.v1","complete":true,"unmeasured":[],"headroom":{"total_kb":24019908,"available_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s},"stall":%s,"growth":{"interval_seconds":300,"scope_reason":null,"unmeasured_reason":null},"processes":[{"pid":9001,"account":"coditan","rss_kb":%s,"growth_kb_per_min":0,"attribution":{"kind":"task","detail":"beta (ship, beta-project)","route":"cwd"},"protected":false,"command":"chrome --headless"},{"pid":9002,"account":"coditan","rss_kb":40000,"growth_kb_per_min":0,"attribution":{"kind":"task","detail":"gamma (ship, gamma-project)","route":"cwd"},"protected":false,"command":"node small.js"}]}\n' \
    "$((avail_mib * 1024))" "$swap_total" "$((swap_total - swap_used * 1024))" \
    "$(stall_obj "$stall" "$some")" "$((rss_mib * 1024))" >"$ANSWER"
}

# A reading whose growth the instrument could not compare at all.
reading_growth_scoped() {
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

# The alarm as a home gets it with no stall threshold chosen, which is how it
# ships. `alarm` above sets one so the stall cases can exercise the condition.
unconfigured_alarm() {
  env FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
      FM_MEMORY_ALARM_FLOOR_MIB=2400 FM_MEMORY_ALARM_HORIZON_MIN=15 \
      FM_MEMORY_ALARM_STALL='' \
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
  FM_TEST_STALL=0.00
  FM_TEST_STALL_WINDOW=5400
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
  assert_contains "$out" "not re-evaluated" "the alarm must say why it cannot call the shortage over"
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

test_a_malformed_stall_gate_falls_back_rather_than_holding_the_alarm_crossed() {
  # An unparsable threshold would compare as zero in awk and hold this condition
  # crossed on every reading forever, which is the loudest possible way to go
  # blind. It must fall back to the shipped default instead.
  reset_home
  reading_thrashing 16000 0.00
  local out
  out=$(env FM_HOME="$HOME_DIR" \
            FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
            FM_MEMORY_ALARM_READING="$FAKE" FM_TEST_ANSWER="$ANSWER" \
            FM_MEMORY_ALARM_STALL="not a number" "$ALARM" --status)
  assert_contains "$out" "memory-alarm: ok" "a malformed threshold must not hold a calm machine crossed"
  assert_contains "$out" "no stall gate is configured" \
    "a gate that could not be understood must leave the condition unwatched and say so"
  pass "a malformed stall gate leaves the condition unwatched rather than firing forever"
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
test_a_malformed_stall_gate_falls_back_rather_than_holding_the_alarm_crossed
test_an_unconfigured_stall_gate_is_reported_never_silently_unwatched
test_an_unconfigured_stall_gate_does_not_block_a_recovery_it_never_raised
test_the_shipped_gate_and_window_are_the_ones_the_document_derives
test_status_labels_horizon_as_ram_headroom_not_swap_exhaustion
test_the_wake_delivery_listener_keeps_its_label
test_the_alarm_limits_nothing_and_kills_nothing
test_persistence_failures_replace_transition_claims_with_diagnostics
test_arming_registers_a_check_and_is_idempotent
test_an_alarm_that_stopped_running_is_reported
test_usage_errors_exit_two
