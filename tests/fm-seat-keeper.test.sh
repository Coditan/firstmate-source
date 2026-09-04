#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEPER="$ROOT/bin/fm-seat-keeper.sh"
STAY_DOWN="$ROOT/bin/fm-seat-stay-down.sh"

fm_test_tmproot TMP_ROOT fm-seat-keeper

# The fake tmux records every invocation and answers the three readings the
# keeper makes: list-sessions proves the target server survived, has-session
# answers session presence, and list-windows answers topology. The case dir's
# has-session-rc and windows files drive those two answers per test.
write_fake_tmux() {
  local path=$1 log=$2 dirvar=$3
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
for arg do
  case "\$arg" in
    list-sessions) exit 0 ;;
    has-session) exit "\$(cat "$dirvar/has-session-rc")" ;;
    list-windows) cat "$dirvar/windows"; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$path"
}

# A delivery service whose verdict names the same condition every time while the
# volatile parts of the line, the listener pid and the pending wake count, change
# between readings the way a real queue makes them change.
write_drifting_delivery() {
  local path=$1 dirvar=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
n=\$(cat "$dirvar/reading-count" 2>/dev/null || printf '0')
n=\$((n + 1))
printf '%s\n' "\$n" > "$dirvar/reading-count"
printf 'undeliverable: listener pid %s is up with %s wake(s) pending, but the published pane %%9 no longer exists\n' "\$n" "\$n"
SH
  chmod +x "$path"
}

# A delivery service that answers from the state directory it is told to read,
# which is how bin/fm-delivery-service.sh derives its own state: FM_STATE_OVERRIDE
# first, then FM_HOME/state.
write_state_reading_delivery() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
cat "$state/verdict"
SH
  chmod +x "$path"
}

make_case() {  # <name> -> echoes the case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data/findings" "$dir/account"
  printf '1\n' > "$dir/has-session-rc"
  : > "$dir/windows"
  write_fake_tmux "$dir/fake-tmux" "$dir/tmux.log" "$dir"
  printf '%s\n' "$dir"
}

run_keeper() {  # <case-dir> <status-line> <cycles>
  local dir=$1 status=$2 cycles=$3
  FM_SEAT_KEEPER_STATUS_OVERRIDE="$status" \
  FM_SEAT_KEEPER_TMUX="$dir/fake-tmux" \
  FM_SEAT_KEEPER_POLL=1 \
  FM_SEAT_KEEPER_RETRY_SEC=1 \
  FM_SEAT_KEEPER_MAX_CYCLES="$cycles" \
    "$KEEPER" "$dir/home" "$dir/home/state" "$dir/target.sock" seat "$dir/account"
}

launch_calls() {  # <case-dir>
  local n
  n=$(grep -cE 'new-session|new-window' "$1/tmux.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

session_creations() {  # <case-dir>
  local n
  n=$(grep -cE 'new-session' "$1/tmux.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

DEAD_PANE='undeliverable: listener pid 1 is up with 1 wake(s) pending, but the published pane %9 no longer exists'

test_dead_seat_verdict_restores_the_seat() {
  local dir
  dir=$(make_case dead-pane)
  run_keeper "$dir" "$DEAD_PANE" 2 || fail "keeper exited non-zero on a dead-seat verdict"
  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "keeper did not restore the seat after two consecutive dead-pane verdicts"
  pass "seat keeper restores the seat on a named dead-seat verdict"
}

test_one_reading_is_not_enough() {
  local dir
  dir=$(make_case single-reading)
  run_keeper "$dir" "$DEAD_PANE" 1 || fail "keeper exited non-zero on a single reading"
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper restored the seat on a single unconfirmed reading"
  pass "seat keeper requires consecutive evidence before restoring"
}

test_a_changing_wake_count_is_still_one_condition() {
  local dir
  dir=$(make_case wake-count-drift)
  write_drifting_delivery "$dir/fake-delivery" "$dir"
  FM_SEAT_KEEPER_DELIVERY_SERVICE="$dir/fake-delivery" \
    run_keeper "$dir" "" 2 || fail "keeper exited non-zero on drifting dead-seat verdicts"
  [ "$(cat "$dir/reading-count")" = 2 ] \
    || fail "the drifting delivery service was not read twice"
  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "a changed wake count reset the consecutive-evidence counter and the dead seat stayed down"
  pass "seat keeper counts the guarded condition, not the changing wake count"
}

test_healthy_verdict_never_touches_the_seat() {
  local dir
  dir=$(make_case healthy)
  run_keeper "$dir" "idle: listener pid 1 is up with 0 wake(s) pending" 3 \
    || fail "keeper exited non-zero on a healthy verdict"
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper restored a seat that delivery reported healthy"
  pass "seat keeper leaves a healthy seat alone"
}

test_listener_down_with_a_live_session_is_not_seat_death() {
  local dir
  dir=$(make_case listener-down)
  printf '0\n' > "$dir/has-session-rc"
  run_keeper "$dir" "down: listener is not running; last beat 90s ago" 3 \
    || fail "keeper exited non-zero on a listener-down verdict"
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper treated a listener restart as seat death while the session was live"
  pass "seat keeper does not mistake a listener restart for a dead seat"
}

test_unrecognised_verdict_resets_the_evidence() {
  local dir
  dir=$(make_case unrecognised)
  run_keeper "$dir" "surprise: a verdict this keeper has never seen" 3 \
    || fail "keeper exited non-zero on an unrecognised verdict"
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper acted on an unrecognised delivery verdict"
  assert_grep "unrecognised delivery verdict" "$dir/home/state/.seat-keeper.log" \
    "unrecognised verdict was not operator-visible in the keeper log"
  [ "$(grep -c 'unrecognised delivery verdict' "$dir/home/state/.seat-keeper.log")" = 1 ] \
    || fail "the same unrecognised verdict was announced once per poll rather than once per onset"
  pass "seat keeper refuses to act on an unrecognised verdict and says so once"
}

test_declared_stay_down_leaves_the_seat_down() {
  local dir
  dir=$(make_case stay-down)
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    "$STAY_DOWN" down "test stay down" >/dev/null \
    || fail "could not declare the stay-down marker"
  run_keeper "$dir" "$DEAD_PANE" 3 || fail "keeper exited non-zero with a stay-down marker"
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper relaunched a seat that was deliberately declared down"
  [ ! -e "$dir/home/state/.seat-keeper-attempts" ] \
    || fail "stay-down marker left an active retry episode"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    "$STAY_DOWN" up >/dev/null || fail "could not clear the stay-down marker"
  run_keeper "$dir" "$DEAD_PANE" 2 || fail "keeper exited non-zero after the marker was cleared"
  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "keeper did not restore the seat once the stay-down marker was cleared"
  pass "seat keeper honors the declared stay-down marker and resumes when it is cleared"
}

test_restore_attempts_are_bounded_and_reported() {
  local dir finding
  dir=$(make_case giveup)
  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=1 \
    run_keeper "$dir" "$DEAD_PANE" 4 || fail "keeper exited non-zero on the give-up path"
  [ "$(session_creations "$dir")" = 1 ] \
    || fail "keeper kept relaunching past its attempt bound; got $(session_creations "$dir") restores"
  finding=$(find "$dir/home/data/findings" -maxdepth 1 -type f -name '*.json')
  [ "$(printf '%s\n' "$finding" | wc -l | tr -d ' ')" = 1 ] && [ -n "$finding" ] \
    || fail "give-up path did not emit exactly one finding; got: $finding"
  assert_grep "exhausted 1 restore attempt" "$finding" \
    "give-up finding did not name the exhausted attempt bound"
  [ -f "$dir/home/state/.seat-keeper-giveup" ] || fail "give-up episode marker was not recorded"
  pass "seat keeper bounds its restore attempts and reports giving up as evidence"
}

test_a_second_keeper_refuses_to_run() {
  local dir first_pid waited=0 out rc=0
  dir=$(make_case second-keeper)
  FM_SEAT_KEEPER_STATUS_OVERRIDE='idle: listener pid 1 is up and the durable queue is empty' \
  FM_SEAT_KEEPER_TMUX="$dir/fake-tmux" \
  FM_SEAT_KEEPER_POLL=1 \
  FM_SEAT_KEEPER_MAX_CYCLES=0 \
    "$KEEPER" "$dir/home" "$dir/home/state" "$dir/target.sock" seat "$dir/account" \
    > "$dir/first-keeper.out" 2>&1 &
  first_pid=$!
  while [ ! -f "$dir/home/state/.seat-keeper.lock/record" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -f "$dir/home/state/.seat-keeper.lock/record" ]; then
    kill "$first_pid" 2>/dev/null || true
    fail "the first keeper never published its lock record"
  fi

  out=$(run_keeper "$dir" "$DEAD_PANE" 2 2>&1) || rc=$?
  kill "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true

  [ "$rc" -ne 0 ] || fail "a second keeper ran alongside a live one"
  case "$out" in
    *"another keeper already holds"*) ;;
    *) fail "the refused second keeper did not name the held lock: $out" ;;
  esac
  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "the refused second keeper still touched the target terminal"
  pass "a second keeper refuses to run beside a live one"
}

test_the_state_dir_argument_wins_over_the_environment() {
  local dir strays
  dir=$(make_case state-dir-argument)
  mkdir -p "$dir/elsewhere"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    "$STAY_DOWN" down "test stay down" >/dev/null \
    || fail "could not declare the stay-down marker"

  FM_STATE_OVERRIDE="$dir/elsewhere" \
    run_keeper "$dir" "$DEAD_PANE" 3 || fail "keeper exited non-zero with FM_STATE_OVERRIDE set"

  [ "$(launch_calls "$dir")" = 0 ] \
    || fail "keeper read the stay-down marker from FM_STATE_OVERRIDE instead of the state dir it was given"
  [ -f "$dir/home/state/.seat-keeper.log" ] \
    || fail "the keeper log did not land under the state dir given as the argument"
  [ -f "$dir/home/state/.seat-keeper-target" ] \
    || fail "the keeper target record did not land under the state dir given as the argument"
  strays=$(find "$dir/elsewhere" -maxdepth 1 -name '.seat-keeper*' | wc -l | tr -d ' ')
  [ "$strays" = 0 ] \
    || fail "keeper records landed in FM_STATE_OVERRIDE; got $strays of them"
  pass "the state-dir argument owns every keeper record, whatever the environment says"
}

test_a_hand_start_lifts_an_exhausted_bound() {
  local dir key
  dir=$(make_case restart-clears-giveup)
  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=1 \
    run_keeper "$dir" "$DEAD_PANE" 4 || fail "keeper exited non-zero on the give-up path"
  [ -f "$dir/home/state/.seat-keeper-giveup" ] || fail "the give-up episode marker was not recorded"
  key=$(sed -n 's/^key=//p' "$dir/home/state/.seat-keeper-giveup")
  [ -n "$key" ] || fail "the give-up marker named no condition"
  [ "$(session_creations "$dir")" = 1 ] || fail "the first run did not restore exactly once"

  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=1 \
    run_keeper "$dir" "$DEAD_PANE" 3 || fail "keeper exited non-zero on the restart"
  [ "$(session_creations "$dir")" = 2 ] \
    || fail "the restart inherited the exhausted bound and restored nothing"
  assert_grep "cleared the exhausted retry episode for condition $key" \
    "$dir/home/state/.seat-keeper.log" \
    "the restart did not say which exhausted condition it lifted"
  pass "a hand-start lifts an exhausted bound and names the condition it lifted"
}

# The give-up marker is written only after the finding is filed, so a keeper that
# reached its bound against an unreachable findings surface leaves an episode
# that is exhausted and unfiled. A hand-start must lift that one too, and say so.
test_a_hand_start_lifts_an_exhausted_but_unfiled_bound() {
  local dir key
  dir=$(make_case restart-clears-unfiled-giveup)
  : > "$dir/not-a-surface"
  FM_FINDINGS_DIR="$dir/not-a-surface" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=1 \
    run_keeper "$dir" "$DEAD_PANE" 4 || fail "keeper exited non-zero when the findings surface was unreachable"
  [ "$(session_creations "$dir")" = 1 ] || fail "the first run did not restore exactly once"
  assert_grep "give-up finding failed" "$dir/home/state/.seat-keeper.log" \
    "the unreachable findings surface did not fail the give-up finding"
  [ ! -f "$dir/home/state/.seat-keeper-giveup" ] \
    || fail "a give-up marker was recorded although the finding was never filed"
  key=$(sed -n 's/^key=//p' "$dir/home/state/.seat-keeper-attempts")
  [ -n "$key" ] || fail "the exhausted attempts record named no condition"

  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=1 \
    run_keeper "$dir" "$DEAD_PANE" 3 || fail "keeper exited non-zero on the restart"
  [ "$(session_creations "$dir")" = 2 ] \
    || fail "the restart inherited the exhausted-but-unfiled bound and restored nothing"
  assert_grep "cleared the exhausted retry episode for condition $key, exhausted but unfiled" \
    "$dir/home/state/.seat-keeper.log" \
    "the restart did not name the unfiled condition it lifted"
  pass "a hand-start lifts an exhausted-but-unfiled bound and names it as unfiled"
}

# A mid-episode record is not exhausted, so a hand-start must leave its count
# alone rather than handing an unattended loop a fresh set of attempts.
test_a_hand_start_leaves_a_mid_episode_record_alone() {
  local dir key
  dir=$(make_case restart-keeps-mid-episode)
  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=5 \
    run_keeper "$dir" "$DEAD_PANE" 2 || fail "keeper exited non-zero mid-episode"
  [ "$(sed -n 's/^count=//p' "$dir/home/state/.seat-keeper-attempts")" = 1 ] \
    || fail "the first run did not leave a mid-episode record with one attempt"
  key=$(sed -n 's/^key=//p' "$dir/home/state/.seat-keeper-attempts")

  FM_FINDINGS_DIR="$dir/home/data/findings" \
  FM_SEAT_KEEPER_MAX_ATTEMPTS=5 \
    run_keeper "$dir" "$DEAD_PANE" 2 || fail "keeper exited non-zero on the restart"
  [ "$(sed -n 's/^count=//p' "$dir/home/state/.seat-keeper-attempts")" = 2 ] \
    || fail "the hand-start reset a mid-episode record instead of carrying its count"
  [ "$(sed -n 's/^key=//p' "$dir/home/state/.seat-keeper-attempts")" = "$key" ] \
    || fail "the carried mid-episode record named a different condition"
  assert_no_grep "cleared the exhausted retry episode" \
    "$dir/home/state/.seat-keeper.log" \
    "the hand-start lifted a bound that was never reached"
  pass "a hand-start carries a mid-episode record rather than lifting it"
}

test_a_dead_keepers_lock_is_taken_over() {
  local dir first_pid waited=0
  dir=$(make_case dead-lock)
  FM_SEAT_KEEPER_STATUS_OVERRIDE='idle: listener pid 1 is up and the durable queue is empty' \
  FM_SEAT_KEEPER_TMUX="$dir/fake-tmux" \
  FM_SEAT_KEEPER_POLL=1 \
  FM_SEAT_KEEPER_MAX_CYCLES=0 \
    "$KEEPER" "$dir/home" "$dir/home/state" "$dir/target.sock" seat "$dir/account" \
    > "$dir/first-keeper.out" 2>&1 &
  first_pid=$!
  while [ ! -f "$dir/home/state/.seat-keeper.lock/record" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
  [ -e "$dir/home/state/.seat-keeper.lock" ] \
    || fail "the killed keeper left no lock behind, so there was nothing to take over"

  run_keeper "$dir" "$DEAD_PANE" 2 \
    || fail "a keeper refused to start over a dead keeper's lock"
  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "the keeper that took over the dead lock never restored the seat"
  pass "a dead keeper's lock is taken over rather than refusing every later keeper"
}

test_the_delivery_verdict_is_read_for_the_home_given() {
  local dir
  dir=$(make_case delivery-state-argument)
  mkdir -p "$dir/decoy/state"
  printf '%s\n' "$DEAD_PANE" > "$dir/home/state/verdict"
  printf 'idle: listener pid 1 is up and the durable queue is empty\n' > "$dir/decoy/state/verdict"
  write_state_reading_delivery "$dir/fake-delivery"

  FM_SEAT_KEEPER_DELIVERY_SERVICE="$dir/fake-delivery" \
  FM_STATE_OVERRIDE="$dir/decoy/state" \
    run_keeper "$dir" "" 2 || fail "keeper exited non-zero reading the delivery verdict"

  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "keeper acted on the decoy home's verdict from FM_STATE_OVERRIDE and left its own dead seat down"
  pass "the delivery verdict is read for the home the keeper was given, not the environment's"
}

test_a_state_dir_that_is_not_the_homes_own_is_refused() {
  local dir out rc=0
  dir=$(make_case foreign-state)
  mkdir -p "$dir/elsewhere"
  out=$(FM_SEAT_KEEPER_STATUS_OVERRIDE="$DEAD_PANE" \
    FM_SEAT_KEEPER_TMUX="$dir/fake-tmux" \
    FM_SEAT_KEEPER_POLL=1 \
    FM_SEAT_KEEPER_MAX_CYCLES=2 \
      "$KEEPER" "$dir/home" "$dir/elsewhere" "$dir/target.sock" seat "$dir/account" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "a state dir that is not the home's own was not refused with exit 2; got $rc"
  case "$out" in *"$dir/elsewhere"*) ;; *) fail "the refusal did not name the state dir it was given: $out" ;; esac
  case "$out" in *"$dir/home/state"*) ;; *) fail "the refusal did not name the state dir it expected: $out" ;; esac
  [ ! -e "$dir/elsewhere/.seat-keeper.log" ] && [ ! -e "$dir/elsewhere/.seat-keeper.lock" ] \
    || fail "the refused keeper still published records into the state dir it was given"
  [ "$(launch_calls "$dir")" = 0 ] || fail "the refused keeper still touched the target terminal"

  rc=0
  FM_SEAT_KEEPER_STATUS_OVERRIDE="$DEAD_PANE" \
  FM_SEAT_KEEPER_TMUX="$dir/fake-tmux" \
  FM_SEAT_KEEPER_POLL=1 \
  FM_SEAT_KEEPER_RETRY_SEC=1 \
  FM_SEAT_KEEPER_MAX_CYCLES=2 \
    "$KEEPER" "$dir/home" "$dir/home/state//" "$dir/target.sock" seat "$dir/account" || rc=$?
  [ "$rc" = 0 ] || fail "the home's own state dir with a trailing slash was refused; got $rc"
  [ "$(launch_calls "$dir")" -gt 0 ] \
    || fail "a trailing slash on the home's own state dir stopped the keeper restoring the seat"
  pass "a state dir that is not the home's own is refused before the keeper takes anything"
}

test_dead_seat_verdict_restores_the_seat
test_one_reading_is_not_enough
test_a_changing_wake_count_is_still_one_condition
test_healthy_verdict_never_touches_the_seat
test_listener_down_with_a_live_session_is_not_seat_death
test_unrecognised_verdict_resets_the_evidence
test_declared_stay_down_leaves_the_seat_down
test_restore_attempts_are_bounded_and_reported
test_the_state_dir_argument_wins_over_the_environment
test_a_state_dir_that_is_not_the_homes_own_is_refused
test_the_delivery_verdict_is_read_for_the_home_given
test_a_hand_start_lifts_an_exhausted_bound
test_a_hand_start_lifts_an_exhausted_but_unfiled_bound
test_a_hand_start_leaves_a_mid_episode_record_alone
test_a_second_keeper_refuses_to_run
test_a_dead_keepers_lock_is_taken_over
