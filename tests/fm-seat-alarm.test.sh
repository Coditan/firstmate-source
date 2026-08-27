#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALARM="$ROOT/bin/fm-seat-alarm.sh"

fm_test_tmproot TMP_ROOT fm-seat-alarm

PIDNS=$(. "$ROOT/bin/fm-harness-pid-lib.sh"; fm_pid_namespace_token)

# The captain's channel, recording what it was handed. Every message the alarm
# sends outward lands in <home>/outbox terminated by a --- line.
write_recording_send() {  # <home>
  local home=$1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat >> "%s/outbox"\n' "$home"
    printf 'printf -- "---\\n" >> "%s/outbox"\n' "$home"
  } > "$home/send"
  chmod +x "$home/send"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/config" "$home/data"
  write_recording_send "$home"
  printf '%s\n' "$home"
}

# A seat is recorded, never inferred: the record names the pid AND the pid table.
record_seat() {  # <home> <pid>
  printf '%s\npidns=%s\n' "$2" "$PIDNS" > "$1/state/.lock"
}

record_endpoint() {  # <home>
  printf 'backend=tmux\ntarget=%%0\n' > "$1/state/.primary-endpoint"
}

queue_wakes() {  # <home> <count> <oldest-age-seconds>
  local home=$1 count=$2 age=$3 now i
  now=$(date +%s)
  : > "$home/state/.wake-queue"
  for i in $(seq 1 "$count"); do
    printf '%s\t%s\tsignal\tk%s\tp\n' "$((now - age + i - 1))" "$i" "$i" >> "$home/state/.wake-queue"
  done
}

# A process whose name and command line look exactly like a harness, so a reading
# that keys on either is caught by the tests below rather than in production.
start_harness_shaped_process() {  # <home> <basename>
  local home=$1 name=$2
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$home/$name"
  chmod +x "$home/$name"
  # Detached from this function's stdout, or the command substitution around it
  # would wait for the process to exit before returning.
  "$home/$name" >/dev/null 2>&1 </dev/null &
  printf '%s\n' "$!"
}

run_alarm() {  # <home> [extra env assignments...]
  local home=$1; shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEAT_ALARM_SEND="$home/send" FM_SEAT_ALARM_GRACE=0 \
    "$@" "$ALARM"
}

sends() {  # <home>
  grep -c '^---$' "$1/outbox" 2>/dev/null || printf '0\n'
}

test_a_live_seat_is_silent() {
  local home pid
  home=$(make_home present)
  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  record_endpoint "$home"
  [ -z "$(run_alarm "$home")" ] || fail "a healthy vessel produced a line"
  [ "$(sends "$home")" = 0 ] || fail "a healthy vessel notified the captain"
  kill "$pid" 2>/dev/null || true
  pass "a vessel with a live first mate says nothing"
}

# The measured shape of the 2026-08-27 outage: the seat gone, its work piling up,
# and live harness-shaped processes in the container that were crewmates.
test_an_absent_seat_is_reported_outward_with_the_work_that_is_waiting() {
  local home crew line
  home=$(make_home absent)
  crew=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" 999999
  record_endpoint "$home"
  queue_wakes "$home" 43 20880
  line=$(run_alarm "$home")
  assert_contains "$line" "no first mate" "the returning seat is not told it was away"
  [ "$(sends "$home")" = 1 ] || fail "the captain was not told the vessel lost its first mate"
  assert_grep "43 notification" "$home/outbox" "the message did not say how much work was waiting"
  assert_grep "5h48m" "$home/outbox" "the message did not say how long the oldest work had waited"
  kill "$crew" 2>/dev/null || true
  pass "an absent first mate is reported outward while it is still absent"
}

# Fact 5 of the task that produced this file: during the outage both live claude
# processes were crewmates in task worktrees. Anything keying on a process name,
# or on a pane's current command, would have called the vessel healthy while it
# was blind.
test_a_live_crewmate_does_not_make_an_absent_seat_read_present() {
  local home crew status
  home=$(make_home crew-immune)
  crew=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" 999999
  record_endpoint "$home"
  status=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ALARM" --status) && fail \
    "an absent seat exited 0 while a harness-shaped process was running"
  assert_contains "$status" "ABSENT" "a live crewmate made the absent seat read as present"
  kill "$crew" 2>/dev/null || true
  pass "a live crewmate cannot make an absent first mate read as present"
}

test_a_declared_stand_down_is_not_an_alarm() {
  local home
  home=$(make_home stay-down)
  record_seat "$home" 999999
  record_endpoint "$home"
  : > "$home/state/.seat-stay-down"
  [ -z "$(run_alarm "$home")" ] || fail "a declared stand-down produced a line"
  [ "$(sends "$home")" = 0 ] || fail "a declared stand-down notified the captain"
  pass "a deliberately stood-down first mate is not reported as missing"
}

test_a_home_that_never_seated_is_not_an_alarm() {
  local home
  home=$(make_home unattended)
  [ -z "$(run_alarm "$home")" ] || fail "a home that never seated produced a line"
  [ "$(sends "$home")" = 0 ] || fail "a home that never seated notified the captain"
  pass "a home that has never had a first mate is not reported as missing one"
}

# The constraint this whole design is held to: a reading that could not be taken
# is never an all-clear. An alarm that goes quiet when its instrument breaks is
# indistinguishable from a healthy vessel.
test_an_unreadable_record_is_reported_and_never_read_as_healthy() {
  local home status rc=0
  home=$(make_home unmeasured)
  record_endpoint "$home"
  printf 'x\n' > "$home/state/.lock"
  chmod 000 "$home/state/.lock"
  status=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ALARM" --status) || rc=$?
  chmod 600 "$home/state/.lock"
  [ "$rc" = 3 ] || fail "an unreadable record did not report itself unmeasured (exit $rc)"
  assert_contains "$status" "UNMEASURED" "an unreadable record did not say it was unmeasured"
  assert_contains "$status" "not an all-clear" "an unmeasured reading did not refuse to be an all-clear"
  pass "a reading that could not be taken is never reported as healthy"
}

# The same constraint, in the words the vessel prints rather than the verdict it
# records: a reading that could not be taken must not be reported as a state it
# never established. The outward message already keeps the two apart.
test_an_unmeasured_reading_is_not_printed_as_a_confirmed_absence() {
  local home line pid
  home=$(make_home unmeasured-wording)
  record_endpoint "$home"
  printf 'x\n' > "$home/state/.lock"
  chmod 000 "$home/state/.lock"
  line=$(run_alarm "$home")
  chmod 600 "$home/state/.lock"
  assert_not_contains "$line" "has had no first mate" \
    "an unmeasured reading was printed as a confirmed absence"
  assert_contains "$line" "has not been able to tell" \
    "an unmeasured reading did not say that is what it was"

  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  line=$(run_alarm "$home")
  kill "$pid" 2>/dev/null || true
  assert_not_contains "$line" "without a first mate" \
    "recovering from an unmeasured reading claimed an absence that was never established"
  assert_contains "$line" "could not tell" \
    "recovering from an unmeasured reading did not say what it had been unable to read"
  # The outward channel, which is the deliverable itself. The printed line is
  # read by the seat that comes back; this is the one the captain gets, and it
  # is the one a test that only reads stdout cannot protect.
  assert_no_grep "without one" "$home/outbox" \
    "the captain was told of an absence the reading explicitly refused to establish"
  assert_grep "of not being able to tell" "$home/outbox" \
    "the outward recovery message did not say what the vessel had been unable to read"
  pass "an unmeasured reading is never printed as a confirmed absence"
}

test_it_speaks_on_change_then_repeats_on_its_own_cadence() {
  local home now
  home=$(make_home cadence)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "entering the absence did not notify"
  [ -z "$(run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 60))")" ] \
    || fail "an unchanged absence produced a second line"
  [ "$(sends "$home")" = 1 ] || fail "an unchanged absence notified again inside its own window"
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 1900))" >/dev/null
  [ "$(sends "$home")" = 2 ] || fail "a persisting absence went quiet instead of repeating"
  pass "an absence is reported once, then repeats on its own cadence"
}

test_recovery_is_reported_only_to_someone_who_was_told() {
  local home now pid line
  home=$(make_home recovery)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  line=$(run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 900))")
  assert_contains "$line" "has one again" "the returned first mate was not told it had been away"
  [ "$(sends "$home")" = 2 ] || fail "the captain was not told the first mate came back"
  kill "$pid" 2>/dev/null || true
  pass "a recovery is reported to a captain who was told about the absence"
}

# A notification path that fails quietly gets trusted while it is dead, which is
# this alarm's own defect wearing a different hat.
# The restarter clause is composed from bin/fm-seat-respawner-service.sh status,
# and during an outage there is no session start to contradict it, so it is the
# only word the captain gets about whether anything is coming. A respawner
# process that is alive but has stopped cycling must not become an assurance.
test_a_restarter_that_stopped_cycling_is_never_called_running() {
  local home restarter
  home=$(make_home stalled-restarter)
  record_seat "$home" 999999
  record_endpoint "$home"
  # A live pid recorded as this home's respawner, and no beacon it ever wrote.
  restarter=$(start_harness_shaped_process "$home" claude)
  mkdir -p "$home/state/.seat-respawner.lock"
  {
    printf 'pid=%s\n' "$restarter"
    printf 'fm-home=%s\n' "$home"
  } > "$home/state/.seat-respawner.lock/record"

  run_alarm "$home" >/dev/null
  kill "$restarter" 2>/dev/null || true
  assert_no_grep "should bring it back on its own" "$home/outbox" \
    "a restarter that never cycled was reported to the captain as bringing the seat back"
  assert_grep "Whether anything is trying to bring it back could not be read" "$home/outbox" \
    "an unreadable restarter state was not reported as unreadable"
  pass "a restarter that has stopped cycling is never reported as running"
}

# The absence repeats end when the condition ends, so the recovery message is
# the only thing that can correct what the captain was last told. One transient
# send failure must not be the end of it.
test_a_failed_recovery_send_is_retried_on_the_next_sweep() {
  local home now pid
  home=$(make_home recovery-retry)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "the absence was never carried outward"

  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$home/send"
  chmod +x "$home/send"
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 900))" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "a failed recovery send was counted as delivered"

  write_recording_send "$home"
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 960))" >/dev/null
  kill "$pid" 2>/dev/null || true
  [ "$(sends "$home")" = 2 ] \
    || fail "the recovery message was never retried, so the captain keeps the absence he was told about"
  assert_grep "has a first mate again" "$home/outbox" \
    "the retried message was not the recovery"
  pass "a recovery message nobody got is retried on the next sweep"
}

# The retry must be of the SEND, not of the reading. A channel that stays broken
# must not leave the alarm asserting an absence the lock says has ended, must not
# re-announce the recovery every sweep, and must not let the earlier episode's
# clock measure the next absence.
test_a_recovery_the_channel_never_took_stays_out_of_the_record() {
  local home now pid line
  home=$(make_home recovery-broken-channel)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "the absence was never carried outward"

  # The seat comes back, and the captain's channel is broken from here on.
  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$home/send"
  chmod +x "$home/send"
  line=$(run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 600))")
  assert_contains "$line" "has one again" "the returning seat was not told it had been away"

  line=$(run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 900))")
  [ -z "$line" ] || fail "an undelivered recovery was announced again a sweep later: $line"
  line=$(run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 1200))")
  [ -z "$line" ] || fail "an undelivered recovery was announced again two sweeps later: $line"

  # state/seat-alarm.state is this alarm's own record of its last reading.
  assert_grep "verdict=present" "$home/state/seat-alarm.state" \
    "the alarm recorded an absence while a live first mate held this home's lock"

  # The seat dies again. The new absence is its own, and must be measured from
  # its own start rather than from the episode whose recovery never landed.
  kill "$pid" 2>/dev/null || true
  record_seat "$home" 999999
  write_recording_send "$home"
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 2400))" >/dev/null
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 2400 + 1800))" >/dev/null
  assert_grep "no first mate for 30m" "$home/outbox" \
    "the second absence was not measured from its own start"
  assert_no_grep "no first mate for 40m" "$home/outbox" \
    "the captain was given the earlier episode's clock for a later absence"
  pass "a recovery the channel never took stays out of the record"
}

test_a_failed_send_is_retried_rather_than_counted() {
  local home now
  home=$(make_home send-failure)
  record_seat "$home" 999999
  record_endpoint "$home"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$home/send"
  chmod +x "$home/send"
  now=$(date +%s)
  run_alarm "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  assert_grep "send-failed" "$home/data/seat-alarm.log" "a failed send was not recorded"
  printf '#!/usr/bin/env bash\ncat >> "%s/outbox"\nprintf -- "---\\n" >> "%s/outbox"\n' "$home" "$home" > "$home/send"
  chmod +x "$home/send"
  run_alarm "$home" FM_SEAT_ALARM_NOW="$((now + 60))" >/dev/null
  [ "$(sends "$home")" = 1 ] \
    || fail "a send that failed was counted as delivered and never retried"
  pass "a send that failed is retried rather than counted as delivered"
}

test_a_live_seat_is_silent
test_an_absent_seat_is_reported_outward_with_the_work_that_is_waiting
test_a_live_crewmate_does_not_make_an_absent_seat_read_present
test_a_declared_stand_down_is_not_an_alarm
test_a_home_that_never_seated_is_not_an_alarm
test_an_unreadable_record_is_reported_and_never_read_as_healthy
test_an_unmeasured_reading_is_not_printed_as_a_confirmed_absence
test_it_speaks_on_change_then_repeats_on_its_own_cadence
test_recovery_is_reported_only_to_someone_who_was_told
test_a_failed_send_is_retried_rather_than_counted
test_a_restarter_that_stopped_cycling_is_never_called_running
test_a_failed_recovery_send_is_retried_on_the_next_sweep
test_a_recovery_the_channel_never_took_stays_out_of_the_record
