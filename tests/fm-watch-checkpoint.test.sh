#!/usr/bin/env bash
# Tests for bounded foreground wake-delivery checkpoints used by Codex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
fm_test_tmproot TMP_ROOT fm-watch-checkpoint

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

record_fake_daemon() {
  local home=$1 pid=$2 identity
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status daemon
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$daemon"
  status=0
  FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_contains "$(cat "$err")" "clamping it to 1s" \
    "a 1s checkpoint did not clamp the child's beat-confirmation window to the 1s floor"
  assert_absent "$home/state/.wake-stub.lock/pid" "stub lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 and its timed-out delivery stub releases the lock"
}

# The clamp may shorten the window but must never switch it off. 0 is the one
# value bin/fm-wake-wait.sh reads as "no window at all, one reading is the whole
# verdict", so an unfloored SECONDS_ARG/2 would disable suspend survival for the
# shortest checkpoints - the silent gap the clamp was added to prevent.
test_clamp_floors_the_window_at_one_second() {
  local home out err daemon seconds
  for seconds in 1 2 3; do
    home=$(make_home "clamp-floor-$seconds")
    out="$home/out.txt"
    err="$home/err.txt"
    sleep 60 & daemon=$!
    record_fake_daemon "$home" "$daemon"
    touch -t 200001010000 "$home/state/.last-watcher-beat"
    FM_HOME="$home" FM_GUARD_GRACE=1 "$CHECKPOINT" --seconds "$seconds" >"$out" 2>"$err" || true
    kill "$daemon" 2>/dev/null || true
    wait "$daemon" 2>/dev/null || true
    case "$(cat "$err")" in
      *"clamping it to 0s"*)
        fail "--seconds $seconds clamped the beat-confirmation window to 0s, disabling it entirely" ;;
    esac
    assert_contains "$(cat "$err")" "clamping it to 1s" \
      "--seconds $seconds did not clamp the beat-confirmation window to the 1s floor"
    if [ "$seconds" -gt 1 ]; then
      assert_contains "$(cat "$err")" "waiting up to 1s for a fresh beat" \
        "--seconds $seconds left a stale-beacon watcher with no confirmation window at all"
    fi
  done
  pass "a short checkpoint clamps the beat-confirmation window to at least 1s, never to 0s"
}

test_queued_wake_passes_through_and_exits_zero() {
  local home out err status daemon queued
  home=$(make_home queued)
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$daemon"
  (
    sleep 1
    FM_HOME="$home" bash -c '. "$1"; fm_wake_append signal demo.status "signal: demo.status"' _ "$ROOT/bin/fm-wake-lib.sh"
  ) &
  status=0
  FM_HOME="$home" "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  expect_code 0 "$status" "queued checkpoint exit"
  assert_contains "$(cat "$out")" "wake: queued" "queue delivery signal was not passed through"
  queued=$(cat "$home/state/.wake-queue")
  assert_contains "$queued" $'\tsignal\tdemo.status\tsignal: demo.status' "checkpoint drained or lost the durable wake"
  pass "checkpoint reports a queued wake and leaves the queue untouched"
}

test_existing_delivery_stub_is_not_success() {
  local home out err status daemon first
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$daemon"
  FM_HOME="$home" "$ROOT/bin/fm-wake-wait.sh" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$home/state/.wake-stub.lock/pid" ] && break
    sleep 0.1
  done
  status=0
  FM_HOME="$home" "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  kill "$first" "$daemon" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  expect_code 1 "$status" "duplicate delivery checkpoint exit"
  assert_contains "$(cat "$err")" "another delivery stub already holds" "duplicate delivery failure was not explained"
  pass "checkpoint rejects a duplicate session delivery stub"
}

test_quiet_checkpoint_exits_124_cleanly
test_clamp_floors_the_window_at_one_second
test_queued_wake_passes_through_and_exits_zero
test_existing_delivery_stub_is_not_success
