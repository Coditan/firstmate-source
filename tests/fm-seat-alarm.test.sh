#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This is the suite that drives the alarm itself, so the suite-wide silencer
# tests/lib.sh sets for every other fixture home is lifted here.
export FM_SEAT_ALARM_DISABLE=0

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

# The same invocation with NOTHING pinned away from the value this vessel
# actually runs with, so a case can exercise the grace and the repeat cadence as
# they ship. A fixture that lowers a threshold to make its assertion pass is
# testing the fixture.
run_alarm_as_shipped() {  # <home> [extra env assignments...]
  local home=$1; shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEAT_ALARM_SEND="$home/send" \
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
  # The outward channel, which is the deliverable itself. The printed line is
  # read by the seat; this is the one the captain gets, and it is the one a test
  # that only reads stdout cannot protect.
  assert_no_grep "has had no first mate" "$home/outbox" \
    "the captain was told of an absence the reading explicitly refused to establish"
  assert_grep "cannot tell whether it has a first mate" "$home/outbox" \
    "the outward message did not say what the vessel had been unable to read"
  pass "an unmeasured reading is never printed as a confirmed absence"
}

# A reading this alarm could not take must never be its quietest, and this
# drives that AS SHIPPED: an absence already paged, the records then made
# unreadable ONCE, and several sweeps at the default grace and the default
# repeat. The alarm must not repair what it just reported, and it must not be
# silenced by an age it had no record to measure.
#
# The fixture removes state/ because that is the cheapest way to make the
# reading unreadable; do not read it as the deleted-directory case covered end
# to end, which it is not - on a vessel the alarm lives inside that directory
# and goes with it. docs/seat-absence.md carries that residual.
test_a_reading_that_cannot_be_taken_is_reported_and_keeps_being_reported() {
  local home now line
  home=$(make_home records-vanished)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 300))" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "the absence was never carried outward"

  # Removed once. Nothing below puts it back, and nothing below may need it to
  # be put back: whatever the alarm does from here, it does to a home whose
  # records stayed gone.
  rm -rf "$home/state"

  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 600))" >/dev/null
  line=$(run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 900))")
  [ ! -e "$home/state" ] \
    || fail "the alarm rebuilt the records it had just reported missing, so the next reading finds a healthy home"
  [ "$(sends "$home")" = 2 ] \
    || fail "a home that lost its records went quiet, leaving the captain holding the absence he was told about"
  assert_grep "cannot tell whether it has a first mate" "$home/outbox" \
    "the captain was not told the reading could no longer be taken"
  assert_contains "$line" "has not been able to tell" \
    "the vessel's own line did not say the records were unreachable"

  # The repeat is uncapped precisely so the alarm does not go quiet while the
  # fault lasts, and the fault here is the instrument itself.
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 1200))" >/dev/null
  [ "$(sends "$home")" = 2 ] || fail "the repeat cadence was ignored while the records were gone"
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 900 + 1800))" >/dev/null
  [ "$(sends "$home")" = 3 ] \
    || fail "a home whose records stayed gone stopped being reported after one message"
  assert_grep "verdict=unmeasured" "$home/data/seat-alarm.state" \
    "an unreachable home was recorded as one that never had a first mate"
  pass "a home that loses its records is reported unmeasured and keeps being reported"
}

# The alarm paces itself out of its own record - the grace and the repeat are
# both read from it - so a home whose data/ cannot be written has neither. That
# must not be what silences it: an absence whose record cannot be kept is still
# an absence, and the captain is the only channel left when the seat is gone.
test_an_absence_is_reported_even_when_the_alarm_cannot_keep_its_own_record() {
  local home now
  home=$(make_home amnesiac)
  record_seat "$home" 999999
  record_endpoint "$home"
  chmod 500 "$home/data"
  now=$(date +%s)
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 300))" >/dev/null
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 600))" >/dev/null
  chmod 700 "$home/data"
  [ "$(sends "$home")" -gt 0 ] \
    || fail "a vessel that could not write its own records went silent about a first mate it had lost"
  assert_grep "no first mate" "$home/outbox" "the absence itself was never carried outward"
  # It must not report a duration it had no record to measure, and it must not
  # promise a cadence it cannot keep.
  assert_no_grep "for 0s" "$home/outbox" \
    "the captain was given a length of absence that was an artefact of the missing record"
  assert_grep "an unknown time" "$home/outbox" \
    "the message named a measured duration where the alarm had none"
  assert_no_grep "repeats every" "$home/outbox" \
    "an alarm that cannot remember having sent a message promised a repeat cadence anyway"
  assert_grep "cannot write its own records" "$home/outbox" \
    "the captain was not told why this vessel keeps repeating itself"
  pass "an absence is reported even when the alarm cannot keep its own record"
}

# The other half of the same reading. Without a record there is no such thing as
# "the first sweep of this episode", so the printed line - which the watcher
# turns into a durable wake, undeduplicated - must not be emitted on the
# strength of a claim nothing here can establish.
test_an_alarm_that_cannot_remember_does_not_grow_the_wake_queue_each_sweep() {
  local home now line lines=0 k
  home=$(make_home amnesiac-quiet)
  record_endpoint "$home"
  rm -rf "$home/state"
  chmod 500 "$home/data"
  now=$(date +%s)
  for k in 0 300 600 900; do
    line=$(run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + k))")
    [ -z "$line" ] || lines=$((lines + 1))
  done
  chmod 700 "$home/data"
  [ "$(sends "$home")" -gt 0 ] || fail "an unreadable home told the captain nothing"
  [ "$lines" = 0 ] \
    || fail "an alarm with no memory printed $lines lines in four sweeps, one durable wake each, for an episode it could not tell apart from the last"
  pass "an alarm that cannot remember does not grow the wake queue on every sweep"
}

# The memory reading is only worth what it measures. A record write that cannot
# LAND - the create succeeds and the rename does not, which is what a full or
# over-quota filesystem does - has to read as unpersistable, or the grace is
# handed an age of zero on every sweep and the alarm is silent about a dead seat
# for as long as it lasts.
test_an_absence_is_reported_when_the_record_write_cannot_land() {
  local home now k
  home=$(make_home write-cannot-land)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)

  # The record's own destination cannot be renamed over.
  mkdir -p "$home/data/seat-alarm.state"
  for k in 0 300 600; do
    run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + k))" >/dev/null
  done
  [ "$(sends "$home")" -gt 0 ] \
    || fail "a dead seat went unreported because the alarm's own record could not be renamed into place"
  rm -rf "$home/data/seat-alarm.state"

  # The same shape one step earlier, and the one a create-only probe cannot see:
  # the probe's own rename REPORTS SUCCESS while putting the record where
  # nothing will read it, because mv moves a file into a directory rather than
  # refusing. What the alarm says on those sweeps is the assertion - a send
  # count alone is satisfied by the ordinary grace path.
  : > "$home/outbox"
  mkdir -p "$home/data/.fm-seat-alarm-probe"
  for k in 900 1200; do
    run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + k))" >/dev/null
  done
  rm -rf "$home/data/.fm-seat-alarm-probe"
  [ "$(sends "$home")" -gt 0 ] \
    || fail "a dead seat went unreported while the alarm's record could be created but never landed"
  assert_grep "cannot write its own records" "$home/outbox" \
    "the captain was not told this vessel cannot keep the record it paces itself on"
  assert_no_grep "repeats every" "$home/outbox" \
    "a vessel that cannot remember having sent a message promised the repeat cadence anyway"
  pass "an absence is reported when the alarm's record write cannot land"
}

# The cadence AT THE VALUES THIS ALARM SHIPS WITH. A fixture that drops the
# grace to zero passes straight over a gate that never opens, which is how a
# permanently silent alarm survived a review round, and this is the case whose
# whole subject is WHEN it speaks. The sweep that first observes the absence
# records it and says nothing; the message goes out once the grace has passed;
# then not again until the repeat interval is out.
test_it_speaks_on_change_then_repeats_on_its_own_cadence() {
  local home now
  home=$(make_home cadence)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  [ -z "$(run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$now")" ] \
    || fail "the sweep that first observed the absence spoke before its grace had passed"
  [ "$(sends "$home")" = 0 ] || fail "the observing sweep notified inside the grace"
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 300))" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "an absence that outlasted the grace did not notify"
  [ -z "$(run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 600))")" ] \
    || fail "an unchanged absence produced a second line"
  [ "$(sends "$home")" = 1 ] || fail "an unchanged absence notified again inside its own window"
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 300 + 1800))" >/dev/null
  [ "$(sends "$home")" = 2 ] || fail "a persisting absence went quiet instead of repeating"
  pass "an absence is reported once its grace has passed, then repeats on its own cadence"
}

# A return is written to the history and announced nowhere. Announcing it once
# would need a memory this alarm cannot always keep, and the sweeps after a
# return must add nothing to either channel however many of them there are.
test_a_returning_first_mate_is_recorded_and_never_announced() {
  local home now pid line k
  home=$(make_home returned)
  record_seat "$home" 999999
  record_endpoint "$home"
  now=$(date +%s)
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$now" >/dev/null
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 300))" >/dev/null
  [ "$(sends "$home")" = 1 ] || fail "the absence was never carried outward"

  pid=$(start_harness_shaped_process "$home" claude)
  record_seat "$home" "$pid"
  for k in 900 1200 1500 3600; do
    line=$(run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + k))")
    [ -z "$line" ] || fail "the return was announced to the wake queue: $line"
  done
  [ "$(sends "$home")" = 1 ] \
    || fail "the captain was sent more than one message for a return that happened once"
  assert_grep "recovered from=absent away=900" "$home/data/seat-alarm.log" \
    "the return was not written to the history an investigator reads"

  # The seat dies again: the new absence is its own, and is measured from its
  # own start rather than from the episode that ended.
  kill "$pid" 2>/dev/null || true
  record_seat "$home" 999999
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 3900))" >/dev/null
  run_alarm_as_shipped "$home" FM_SEAT_ALARM_NOW="$((now + 4200))" >/dev/null
  [ "$(sends "$home")" = 2 ] || fail "the second absence was never carried outward"
  assert_grep "no first mate for 5m" "$home/outbox" \
    "the second absence was not measured from its own start"
  assert_no_grep "1h10m" "$home/outbox" \
    "the captain was given the earlier episode's clock for a later absence"
  pass "a returning first mate is recorded and never announced"
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
test_a_reading_that_cannot_be_taken_is_reported_and_keeps_being_reported
test_an_absence_is_reported_even_when_the_alarm_cannot_keep_its_own_record
test_an_alarm_that_cannot_remember_does_not_grow_the_wake_queue_each_sweep
test_an_absence_is_reported_when_the_record_write_cannot_land
test_it_speaks_on_change_then_repeats_on_its_own_cadence
test_a_returning_first_mate_is_recorded_and_never_announced
test_a_failed_send_is_retried_rather_than_counted
test_a_restarter_that_stopped_cycling_is_never_called_running
