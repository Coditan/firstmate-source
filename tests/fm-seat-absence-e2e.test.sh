#!/usr/bin/env bash
set -u

# End-to-end proof for the two halves of first-mate absence handling, on a real
# tmux server with a real seat process that is really killed.
#
# It exists because the acceptance condition for this work was explicitly NOT a
# service reporting itself active. The 2026-08-27 outage on coditan-vessel
# happened while the watcher, the delivery listener and the container all
# reported healthy, because every one of them was healthy - the seat was the part
# that was gone, and nothing read that. So this kills a seat and requires two
# separate observations back: that its absence left this home, and that something
# put a seat back without a human.
#
# It uses a throwaway FM_HOME and a PRIVATE tmux socket, per the standing rule in
# docs/seat-respawner.md that this must never be tested by killing a live seat.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite drives both halves end to end against its own throwaway home, so
# both suite-wide silencers from tests/lib.sh are lifted here.
export FM_SEAT_ALARM_DISABLE=0
export FM_SEAT_RESPAWNER_DISABLE=0

RESPAWNER="$ROOT/bin/fm-seat-respawner.sh"
ALARM="$ROOT/bin/fm-seat-alarm.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

fm_test_tmproot TMP_ROOT fm-seat-absence-e2e

HOME_DIR="$TMP_ROOT/home"
SOCKET="$TMP_ROOT/tmux.sock"
PIDNS=$(. "$ROOT/bin/fm-harness-pid-lib.sh"; fm_pid_namespace_token)
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"

tm() { tmux -S "$SOCKET" "$@"; }

# The server dies first, then the registered temp roots go. This trap REPLACES
# the one tests/lib.sh installs for fm_test_tmproot, so it has to call
# fm_test_cleanup itself or every run of this suite leaves a whole fixture home
# - lock, logs, endpoint record and tmux socket - behind in TMPDIR forever.
cleanup_server() {
  tm kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_server EXIT

# A stand-in seat: it does what a seat does that this machinery reads - it holds
# this home's session lock, under a process whose name a harness check accepts -
# and nothing else.
# The stand-in seat is a faithful IDLE agent, because idleness is the failure
# that made the first version of this work insufficient. Measured on this fleet
# 2026-08-27: a launched seat publishes no endpoint and takes no session lock
# until something gives it its first turn, and nothing did - the queue stood at
# 47 for four minutes with a healthy agent sitting in the window. So this draws
# the agent composer glyph the shared classifier accepts, waits for one line,
# and only then does what a session start does. A stand-in that took the lock on
# startup would have hidden exactly the defect this test has to catch.
#
# It stays in its own script rather than exec'ing a sleep, because the liveness
# test this machinery uses asks whether the recorded pid is a HARNESS - so the
# stand-in has to keep looking like one for as long as it is meant to be alive.
cat > "$HOME_DIR/claude" <<SEAT
#!/usr/bin/env bash
printf 'seat-started %s\n' "\$\$" >> "$HOME_DIR/launches.log"
printf '\xe2\x9d\xaf '
IFS= read -r line
printf '%s\n' "\$line" >> "$HOME_DIR/first-turns.log"
printf '%s\npidns=%s\n' "\$\$" "$PIDNS" > "$HOME_DIR/state/.lock"
printf 'seat-attended %s\n' "\$\$" >> "$HOME_DIR/launches.log"
printf '\nWORKING\n'
while :; do sleep 1; done
SEAT
chmod +x "$HOME_DIR/claude"

# The configured launch command, in the same shape a real home uses.
printf '%s\n' "$HOME_DIR/claude" > "$HOME_DIR/config/seat-launch-command"

# Stand-in delivery reporting, so this test drives the respawner's real trigger
# without needing a live listener. bin/fm-delivery-lib.sh owns the real verdicts.
cat > "$HOME_DIR/fake-delivery" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 2
cat "$FM_FAKE_DELIVERY_STATUS"
SH
chmod +x "$HOME_DIR/fake-delivery"

cat > "$HOME_DIR/send" <<SH
#!/usr/bin/env bash
cat >> "$HOME_DIR/outbox"
printf -- '---\n' >> "$HOME_DIR/outbox"
SH
chmod +x "$HOME_DIR/send"

seat_pid_from_lock() {
  sed -n '1p' "$HOME_DIR/state/.lock" 2>/dev/null | tr -d '[:space:]'
}

wait_for() {  # <seconds> <command...>
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}

run_alarm() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEAT_ALARM_SEND="$HOME_DIR/send" FM_SEAT_ALARM_GRACE=0 "$ALARM"
}

run_respawner_once() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEAT_RESPAWNER_ONCE=1 FM_SEAT_RESPAWNER_BACKOFF=1 \
    FM_SEAT_REVIVE_WATCHER=0 \
    FM_SEAT_DELIVERY_SERVICE="$HOME_DIR/fake-delivery" \
    FM_FAKE_DELIVERY_STATUS="$HOME_DIR/delivery-status" \
    FM_SEAT_TMUX="$(command -v tmux)" \
    "$RESPAWNER" >/dev/null 2>&1
}

test_a_killed_seat_is_reported_outward_and_comes_back() {
  local first_pid second_pid server_pid target started turns_before

  # The bare first window mirrors what /usr/local/bin/vessel-entrypoint creates
  # on the real container, and it is load-bearing here for the same reason it is
  # there: it is what keeps the tmux server alive when the seat's own window
  # goes. Without it the server would exit with the seat and the respawner would
  # correctly refuse to launch into an endpoint that no longer exists.
  tm new-session -d -s vessel -n shell "sleep 300" \
    || fail "could not start the stand-in vessel session"
  tm new-window -t vessel -n firstmate "$HOME_DIR/claude" \
    || fail "could not start the stand-in seat window"
  server_pid=$(tm display-message -p '#{pid}') || fail "could not read the tmux server pid"
  target=$(tm display-message -p -t vessel:firstmate '#{pane_id}') || fail "could not resolve the seat pane"

  # The first seat is given its first turn by hand, which is the whole history of
  # this vessel: the firstmate window was made once by a human and nothing on the
  # seat reproduces it. Everything after this point has to happen without one.
  wait_for 10 sh -c "tmux -S '$SOCKET' capture-pane -p -t '$target' | grep -q ." \
    || fail "the stand-in seat never drew a composer"
  tm send-keys -t "$target" begin Enter
  wait_for 10 test -s "$HOME_DIR/state/.lock" || fail "the stand-in seat never took the session lock"
  first_pid=$(seat_pid_from_lock)

  {
    printf 'backend=tmux\n'
    printf 'target=%s\n' "$target"
    printf 'harness=claude\n'
    printf 'session-lock-pid=%s\n' "$first_pid"
    printf 'tmux-server=%s,%s\n' "$SOCKET" "$server_pid"
  } > "$HOME_DIR/state/.primary-endpoint"

  # A running seat is not news, in either half.
  [ -z "$(run_alarm)" ] || fail "a running seat produced an absence line"
  [ ! -s "$HOME_DIR/outbox" ] || fail "a running seat was reported as missing"

  # Work arrives while the seat is alive, so the queue below is the real thing
  # the outage left behind rather than a number written into a fixture.
  printf '%s\t1\tsignal\tcrew\twaiting\n' "$(( $(date +%s) - 600 ))" > "$HOME_DIR/state/.wake-queue"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but the endpoint was published by a session that no longer holds the fleet lock\n' \
    > "$HOME_DIR/delivery-status"

  # THE DELIBERATE STOP. Not a stop marker, not a simulated verdict: the seat
  # process is killed, exactly as it was on 2026-08-27.
  kill -KILL "$first_pid" 2>/dev/null || fail "could not stop the stand-in seat"
  wait_for 10 sh -c "! kill -0 $first_pid 2>/dev/null" || fail "the stand-in seat did not stop"

  # OBSERVATION 1: the absence left this home while it was still absent.
  assert_contains "$(run_alarm)" "no first mate" "the absence produced no report at all"
  [ -s "$HOME_DIR/outbox" ] || fail "the absence was never carried outward"
  assert_grep "1 notification" "$HOME_DIR/outbox" "the outward report did not carry the waiting work"

  # OBSERVATION 2: a seat process is started, with no human in the loop.
  run_respawner_once || fail "the respawner did not complete a cycle"
  wait_for 15 sh -c "[ \$(grep -c seat-started '$HOME_DIR/launches.log') -ge 2 ]" \
    || fail "no replacement seat was started; respawner log: $(tr '\n' '|' < "$HOME_DIR/state/.seat-respawner.log" 2>/dev/null || printf none)"

  # OBSERVATION 3, and the one that makes the difference between a restart and a
  # restoration: the process now exists and the home is STILL unattended. A
  # launched agent waits for input; it publishes no endpoint and takes no lock
  # until something gives it a turn. Both halves must agree that this is not yet
  # a first mate, and the detector reads the lock precisely so that it does.
  [ "$(seat_pid_from_lock)" = "$first_pid" ] \
    || fail "the stand-in seat took the lock without a first turn, so this test cannot see the idle-seat failure"
  [ "$(env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ALARM" --status | sed -n 1p)" \
    = "seat-alarm: ABSENT - the first mate that held this vessel is no longer running" ] \
    || fail "a launched but idle seat was read as a first mate; the process existing is not the test"
  [ -f "$HOME_DIR/state/.seat-first-turn" ] \
    || fail "the respawner recorded no pending first turn for the pane it just created"

  # A reading that could not be taken is not an absence on this half either: a
  # first mate this process cannot see is still a first mate, so an unreadable
  # lock must leave the pane untouched and the pending turn standing.
  turns_before=$(wc -l < "$HOME_DIR/first-turns.log")
  chmod 000 "$HOME_DIR/state/.lock"
  run_respawner_once || true
  sleep 1
  chmod 600 "$HOME_DIR/state/.lock"
  [ "$(wc -l < "$HOME_DIR/first-turns.log")" = "$turns_before" ] \
    || fail "a lock that could not be read still had a first turn typed into the pane"
  [ -f "$HOME_DIR/state/.seat-first-turn" ] \
    || fail "a lock that could not be read retired the pending first turn"

  # OBSERVATION 4: the fresh seat is given its first turn, and only now is there
  # a first mate holding this home - and the cycle that delivers it starts no
  # second seat. The delivery verdict is still undeliverable here, and the retry
  # backoff has passed, so a respawner that launched on schedule would leave the
  # pane it just typed into running with nothing tracking it.
  started=$(grep -c seat-started "$HOME_DIR/launches.log")
  run_respawner_once || fail "the respawner did not complete a first-turn cycle"
  # Two, not one: the first seat's own turn was typed by hand above, so a count
  # of one would pass without the respawner having done anything at all.
  wait_for 20 sh -c "[ \$(wc -l < '$HOME_DIR/first-turns.log') -ge 2 ]" \
    || fail "the fresh seat was never given a first turn; respawner log: $(tr '\n' '|' < "$HOME_DIR/state/.seat-respawner.log" 2>/dev/null || printf none)"
  assert_grep "FIRSTMATE_OP" "$HOME_DIR/first-turns.log" \
    "the first turn was not a typed operational input"
  assert_grep "fm-session-start" "$HOME_DIR/first-turns.log" \
    "the first turn did not tell the fresh seat to run its session start"
  [ "$(grep -c seat-started "$HOME_DIR/launches.log")" = "$started" ] \
    || fail "a second seat was launched while the first had not yet taken the lock"
  wait_for 20 sh -c "[ \"\$(sed -n 1p '$HOME_DIR/state/.lock' | tr -d '[:space:]')\" != '$first_pid' ]" \
    || fail "the replacement seat never took the session lock"
  second_pid=$(seat_pid_from_lock)
  [ "$second_pid" != "$first_pid" ] || fail "the seat pid did not change, so nothing was restarted"
  kill -0 "$second_pid" 2>/dev/null || fail "the replacement seat is not running"

  # OBSERVATION 5: the vessel reads the restored seat as present, says nothing
  # about the return on either channel, and writes it to its own history.
  [ -z "$(run_alarm)" ] || fail "the restored seat produced a line where the alarm has nothing to say"
  assert_grep "recovered from=absent" "$HOME_DIR/data/seat-alarm.log" \
    "the restoration this suite just drove was not written to the alarm's history"

  kill -KILL "$second_pid" 2>/dev/null || true
  pass "a deliberately killed seat is reported outward, comes back, and is given its first turn"
}

# The stay-down marker is the declared exception, and it has to hold under the
# same real conditions: a seat killed on purpose must not be dragged back.
test_a_declared_stand_down_survives_a_real_kill() {
  local before
  : > "$HOME_DIR/state/.seat-stay-down"
  before=$(grep -c seat-started "$HOME_DIR/launches.log" 2>/dev/null || printf 0)
  # A turn recorded before the marker was set. The declared stand-down has to
  # settle it rather than race it: typed on the next cycle, it would run session
  # start and leave this home attended despite the declared absence.
  {
    printf 'pane=%s\n' "$(tm display-message -p -t vessel:firstmate '#{pane_id}' 2>/dev/null || printf '%%9')"
    printf 'server=%s,%s\n' "$SOCKET" "$(tm display-message -p '#{pid}' 2>/dev/null || printf 1)"
    printf 'at=%s\n' "$(date +%s)"
  } > "$HOME_DIR/state/.seat-first-turn"
  run_respawner_once || fail "the respawner did not complete a cycle"
  sleep 1
  [ "$(grep -c seat-started "$HOME_DIR/launches.log" 2>/dev/null || printf 0)" = "$before" ] \
    || fail "a deliberately stood-down seat was restarted anyway"
  [ ! -e "$HOME_DIR/state/.seat-first-turn" ] \
    || fail "a declared stand-down left a first turn pending, which the next cycle would type"
  [ -z "$(run_alarm)" ] || fail "a deliberately stood-down seat was reported as missing"
  rm -f "$HOME_DIR/state/.seat-stay-down"
  pass "a deliberately stood-down seat is left down and not reported as missing"
}

# The tier that removes the seat from the restart path. Until it existed, this
# script's own service reported "no primary-seat respawner can be supervised
# here" on a container with no service manager and stopped, so the restarter was
# in the tree and never running.
test_the_keeper_tier_is_selected_and_converged_without_a_seat() {
  local service line beat
  service="$ROOT/bin/fm-seat-respawner-service.sh"

  # A tmux pinned to this test's private socket, so the probe never creates or
  # kills a session next to the fleet this repo actually runs.
  #
  # It also publishes FM_SEAT_REVIVE_WATCHER=0 into that server's environment
  # before every call. The keeper this test starts is launched by `tmux
  # new-session`, which runs its command under the SERVER's environment rather
  # than this caller's, so the variable set below in run_service does not reach
  # the respawner the keeper spawns - and that respawner would otherwise revive
  # a "dead" watcher for this fixture home on the DEFAULT socket, where this
  # repo runs its own live fleet. A server this shim has to create instead
  # inherits the value from run_service through this process.
  cat > "$HOME_DIR/tmux-shim" <<SHIM
#!/usr/bin/env bash
TMUX_BIN=$(command -v tmux)
"\$TMUX_BIN" -S "$SOCKET" set-environment -g FM_SEAT_REVIVE_WATCHER 0 2>/dev/null || true
"\$TMUX_BIN" -S "$SOCKET" set-environment -g FM_SEAT_RESPAWNER_POLL 2 2>/dev/null || true
exec "\$TMUX_BIN" -S "$SOCKET" "\$@"
SHIM
  chmod +x "$HOME_DIR/tmux-shim"

  run_service() {
    env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_SEAT_REVIVE_WATCHER=0 \
      FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper FM_SEAT_RESPAWNER_TMUX="$HOME_DIR/tmux-shim" \
      "$service" "$@"
  }

  [ "$(run_service select)" = keeper ] \
    || fail "a home with no usable service manager did not select the keeper tier"

  # Converging says so when it had to act, and the running respawner is proved by
  # its own published lock and beacon rather than by a process name.
  line=$(run_service converge)
  assert_contains "$line" "has been started again" \
    "converging a missing restarter reported nothing"
  wait_for 20 sh -c "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$ROOT' FM_STATE_OVERRIDE='$HOME_DIR/state' FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper FM_SEAT_RESPAWNER_TMUX='$HOME_DIR/tmux-shim' '$service' status | grep -q '^up:'" \
    || fail "the keeper tier did not produce a running restarter"

  # And says nothing at all once it is running, because a check that spoke every
  # sweep would bury the one sweep where it mattered.
  [ -z "$(run_service converge)" ] \
    || fail "converging an already-running restarter was not silent"

  # No fixture may reach the host's default tmux socket. A watcher revived for
  # this throwaway home would be started there, and would then go on sweeping a
  # home this suite deletes.
  #
  # Read after a SECOND beacon rather than on a timer: the beacon is touched at
  # the start of every cycle, so a newer one proves the previous cycle ran to
  # completion - and the revive step is the first thing in it. The rate-limit
  # marker is what that step writes before it calls the watcher service at all,
  # so it catches the attempt even when the start itself is slow or fails.
  beat=$(stat -c %Y "$HOME_DIR/state/.last-seat-respawner-beat" 2>/dev/null) \
    || fail "the running restarter published no beacon to read"
  wait_for 30 sh -c "[ \"\$(stat -c %Y '$HOME_DIR/state/.last-seat-respawner-beat' 2>/dev/null)\" != '$beat' ]" \
    || fail "the restarter never began a second cycle, so what its first one did could not be read"
  [ ! -e "$HOME_DIR/state/.seat-respawner-watcher-revived" ] \
    || fail "the fixture respawner tried to revive a watcher for a throwaway home"
  [ ! -e "$HOME_DIR/state/.watch-keeper.pid" ] \
    || fail "the fixture respawner started a real watcher keeper for a throwaway home"

  run_service restart >/dev/null 2>&1 || true
  "$HOME_DIR/tmux-shim" kill-session -t "$(. "$ROOT/bin/fm-keeper-name-lib.sh"; fm_keeper_name seat-respawner "$HOME_DIR")" 2>/dev/null || true
  pass "the restarter is supervised without a service manager and without a seat"
}

test_a_killed_seat_is_reported_outward_and_comes_back
test_a_declared_stand_down_survives_a_real_kill
test_the_keeper_tier_is_selected_and_converged_without_a_seat
