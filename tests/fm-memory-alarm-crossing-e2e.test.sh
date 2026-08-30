#!/usr/bin/env bash
# End-to-end: drive a real runaway on this host and require the alarm to fire.
#
# WHY A LIVE TEST AND NOT ONLY FIXTURES
# tests/fm-memory-alarm.test.sh proves what the alarm decides when it is handed
# a reading. It cannot prove that a genuinely fast-growing process on this
# machine produces such a reading in the first place - that the process is
# tracked, that its growth is measured across two samples, and that the numbers
# reach the threshold. An alarm proven only against fixtures has been shown to
# be self-consistent, not to work.
#
# WHAT IT DRIVES
# One process that allocates anonymous memory fast enough to trip the horizon
# condition against the headroom this host actually has, then releases it. The
# growth rate is computed from the machine's own RAM headroom rather than
# fixed, so the test drives the REAL threshold rather than a number that
# happened to work on the day it was written.
#
# WHY IT IS SAFE TO RUN
# The balloon is capped twice - by its own loop and by an RLIMIT_AS the caller
# sets - and the cap is a fraction of the free memory measured at the start. The
# test refuses to run at all unless this host has generous headroom, so it never
# adds pressure to a machine already under it. It kills nothing. Neither does
# the alarm: this test also asserts that the crossing it just drove left every
# process alone.
#
# WHY IT NEEDS THREE POLLS AND NOT TWO
# Growth is measured between two stored samples, so a process that did not exist
# at the previous sample has no growth yet however fast it is climbing. The
# alarm therefore cannot see a brand-new runaway on the first poll after it
# appears - a real limitation, stated in docs/memory-alarm.md, and the reason
# the headroom floor exists as a backstop. The sequence below reproduces it
# deliberately: first sighting silent, second poll crossing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_MEMORY_ALARM_DISABLE=0

fm_test_tmproot TMP_ROOT fm-memory-alarm-e2e

ALARM="$ROOT/bin/fm-memory-alarm.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

HORIZON_MIN=15
MIN_AVAIL_MIB=6144
CAP_MIB=2200

avail_mib() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

# --- refusals ---------------------------------------------------------------
#
# Each of these is a reason the run would measure something other than what it
# claims to. Skipping is announced by name; the suite never passes silently on a
# host where it did not actually drive anything.

skip() {
  printf 'ok - SKIPPED (%s)\n' "$1"
  exit 0
}

[ -r /proc/meminfo ] || skip "/proc/meminfo is unreadable, so this host's headroom could not be read"
command -v jq >/dev/null 2>&1 || skip "jq is not installed, so the alarm cannot read its own instrument"
command -v python3 >/dev/null 2>&1 || skip "python3 is not installed, so no runaway could be driven"

START_AVAIL=$(avail_mib)
[ -n "$START_AVAIL" ] || skip "MemAvailable could not be read from /proc/meminfo"
[ "$START_AVAIL" -ge "$MIN_AVAIL_MIB" ] ||
  skip "only $START_AVAIL MiB RAM headroom available, below the $MIN_AVAIL_MIB MiB floor this test refuses to run under"

# The reading needs a live process table to see the balloon at all, and RAM
# headroom to divide by. It is asked against THIS test's own state directory,
# not the ambient home: a reading given a home with no state directory cannot
# store or find a growth sample and reports itself incomplete, which is a fact
# about the question asked rather than about the host.
#
# The guard is on those inputs and NOT on the reading's exit status. An
# incomplete reading is no longer a blind alarm - a host whose memory pressure
# account is absent or provably not accounting exits 3 while headroom, growth
# and the process table are all perfectly readable, and the crossing this test
# drives is a headroom and horizon crossing that such a host judges exactly as
# any other does. Skipping on exit 3 would retire the only live proof there is
# on precisely the hosts the stall work was measured against.
READING_JSON=$(env FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-memory-reading.sh" --no-store --json 2>/dev/null || true)
[ -n "$READING_JSON" ] ||
  skip "the memory reading produced nothing on this host, so a crossing could not be attributed to anything"
[ "$(printf '%s' "$READING_JSON" | jq -r '.headroom.available_kb')" != null ] ||
  skip "this host's RAM headroom is unmeasured, so no condition could judge a crossing"
[ "$(printf '%s' "$READING_JSON" | jq -r \
    '[.unmeasured[].input] | map(select(. == "processes" or . == "growth-sample")) | length')" = 0 ] ||
  skip "this host's process table or growth sample is unmeasured, so a crossing could not be attributed to anything"

# --- the runaway ------------------------------------------------------------

BALLOON="$TMP_ROOT/balloon.py"
cat >"$BALLOON" <<'EOF'
import os, resource, sys, time
cap_mib, rate_mib_s, hold_s = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
# Capped twice: this loop, and the kernel. A bug in the loop cannot turn a test
# into an incident.
resource.setrlimit(resource.RLIMIT_AS, ((cap_mib + 256) * 1024 * 1024,) * 2)
block, grown, start = bytearray(), 0, time.time()
while grown < cap_mib:
    block.extend(b"\xa5" * (1024 * 1024))
    grown += 1
    block[-1024 * 1024] = 1          # touch it so it is resident, not merely reserved
    due = start + grown / rate_mib_s
    if due > time.time():
        time.sleep(due - time.time())
print(os.getpid(), flush=True)
time.sleep(hold_s)
del block
EOF

# Grow fast enough to exhaust the memory this host actually has inside the
# horizon, with a 25% margin so a slightly slow allocator still crosses.
NEEDED_MIB_MIN=$(( START_AVAIL * 125 / 100 / HORIZON_MIN ))
RATE_MIB_S=$(( (NEEDED_MIB_MIN + 59) / 60 ))
GROW_SECONDS=$(( CAP_MIB / RATE_MIB_S ))
[ "$GROW_SECONDS" -ge 25 ] ||
  skip "this host has so little free memory that the runaway would finish in ${GROW_SECONDS}s, too fast to span two samples"

alarm() {
  # The sampling-window contract has fixture coverage in fm-memory-reading.test.sh.
  # This live test compresses time and lowers the floor so it can prove the separate process-to-alarm path.
  # Waiting 270 seconds between live test polls would add no evidence about that path.
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_MEMORY_ALARM_HORIZON_MIN="$HORIZON_MIN" \
      FM_MEMORY_SAMPLE_MIN_AGE=1 \
      "$ALARM"
}

printf '# driving a runaway at %s MiB/s to a %s MiB cap, against %s MiB RAM headroom\n' \
  "$RATE_MIB_S" "$CAP_MIB" "$START_AVAIL"

alarm >/dev/null                                    # baseline sample

python3 "$BALLOON" "$CAP_MIB" "$RATE_MIB_S" 45 >"$TMP_ROOT/balloon.out" &
BALLOON_PID=$!
# shellcheck disable=SC2317  # reached only via the EXIT trap
cleanup_balloon() { kill "$BALLOON_PID" 2>/dev/null || true; }
trap 'cleanup_balloon; fm_test_cleanup' EXIT

sleep 20
FIRST=$(alarm)
sleep "$GROW_SECONDS"
CROSSING=$(alarm)

wait "$BALLOON_PID" 2>/dev/null || true
trap 'fm_test_cleanup' EXIT
sleep 15
RECOVERY=$(alarm)

# --- what the run must show -------------------------------------------------

test_a_brand_new_runaway_is_not_yet_visible_as_growth() {
  assert_contains "|$FIRST|" "||" \
    "the poll that first SEES a runaway has no previous sample to compare it against, so it must not claim growth"
  pass "a runaway is silent on the poll that first sees it, which is why the headroom floor exists"
}

test_a_real_runaway_makes_the_alarm_fire() {
  assert_contains "$CROSSING" "MEMORY_ALARM:" "a real runaway must make the alarm fire"
  assert_contains "$CROSSING" "running out of RAM headroom" "the crossing must say what is happening"
  assert_contains "$CROSSING" "balloon" "the crossing must name the process that caused it"
  assert_contains "$CROSSING" "account $(id -un)" "the crossing must name the account it runs under"
  pass "a real runaway makes the alarm fire and names the process and its account"
}

test_the_crossing_is_recorded_durably_with_its_evidence() {
  assert_grep 'ok -> crossed' "$HOME_DIR/data/memory-alarm.log" "the crossing must leave a durable record"
  assert_grep 'balloon' "$HOME_DIR/data/memory-alarm.log" "the record must name the process"
  assert_grep 'MiB/min growth' "$HOME_DIR/data/memory-alarm.log" "the record must carry the growth it decided on"
  pass "the crossing leaves a durable record carrying the evidence it was decided on"
}

test_the_alarm_left_every_process_alone() {
  # It fired while a process was visibly running away with memory. If anything
  # in this programme were ever going to reach for a kill, this is the moment.
  assert_contains "$CROSSING" "Nothing has been limited or killed" \
    "the crossing must state that nothing was acted against"
  [ -s "$TMP_ROOT/balloon.out" ] ||
    fail "the runaway did not report its own pid, so it did not survive to finish on its own terms"
  pass "the alarm fired, named the offender, and left it running"
}

test_the_machine_recovers_and_says_so() {
  assert_contains "$RECOVERY" "recovered" "the end of the shortage must be announced"
  assert_grep 'crossed -> ok' "$HOME_DIR/data/memory-alarm.log" "the recovery must leave a durable record"
  pass "the machine recovers and both ends of the episode are on the record"
}

test_a_brand_new_runaway_is_not_yet_visible_as_growth
test_a_real_runaway_makes_the_alarm_fire
test_the_crossing_is_recorded_durably_with_its_evidence
test_the_alarm_left_every_process_alone
test_the_machine_recovers_and_says_so
