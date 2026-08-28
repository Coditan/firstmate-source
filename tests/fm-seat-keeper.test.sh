#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEPER="$ROOT/bin/fm-seat-keeper.sh"

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

make_case() {  # <name> -> echoes the case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/account"
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
  pass "seat keeper refuses to act on an unrecognised verdict and says so"
}

test_dead_seat_verdict_restores_the_seat
test_one_reading_is_not_enough
test_healthy_verdict_never_touches_the_seat
test_listener_down_with_a_live_session_is_not_seat_death
test_unrecognised_verdict_resets_the_evidence
