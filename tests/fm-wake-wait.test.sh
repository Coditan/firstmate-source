#!/usr/bin/env bash
# External watcher daemon mode plus the session-owned wake delivery stub.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WAIT="$ROOT/bin/fm-wake-wait.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
fm_test_tmproot TMP_ROOT fm-wake-wait

# `kill -0` alone succeeds for a stub that already exited but has not been
# reaped, so it would pass for the exact regression these assertions exist to
# catch. The stub's identity lock is released by its EXIT trap, so its presence
# is what actually distinguishes a still-armed stub from a dead one.
fm_path_mtime_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

assert_stub_armed() {
  local state=$1 stub=$2 message=$3
  kill -0 "$stub" 2>/dev/null || fail "$message"
  [ -e "$state/.wake-stub.lock/pid" ] || fail "$message (identity lock already released)"
}

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

record_fake_daemon() {
  local home=$1 state=$2 pid=$3 identity
  identity=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

test_daemon_enqueues_and_continues_without_arm_owner() {
  local dir state fakebin out pid lock_pid
  dir=$(make_case daemon-continues)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WATCH_DAEMON=1 \
    FM_WATCH_ARM_OWNER_PID=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  [ -e "$state/.last-watcher-beat" ] || fail "daemon watcher never established its beacon"
  printf 'done: synthetic daemon wake\n' > "$state/demo.status"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$state/.wake-queue" ] && break
    sleep 0.2
  done
  [ -s "$state/.wake-queue" ] || fail "daemon watcher did not enqueue the status wake"
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "daemon watcher exited after an actionable wake"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || fail "daemon watcher lost its singleton lock after the wake"
  [ "$(cat "$state/.watch.lock/daemon" 2>/dev/null || true)" = 1 ] || fail "daemon mode was not recorded in the watcher lock"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "FM_WATCH_DAEMON enqueues and continues while ignoring the obsolete arm-owner parent check"
}

test_killed_stub_loses_no_wake_and_costs_one_rearm() {
  local home state daemon first second out queued
  home="$TMP_ROOT/stub-kill"
  state="$home/state"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid" ] || fail "initial delivery stub did not publish its lock"
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  [ ! -e "$state/.wake-stub.lock/pid" ] || fail "SIGTERM delivery stub left its identity lock behind"

  append_wake "$state" signal demo.status "signal: demo.status"
  out="$home/rearm.out"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$out" & second=$!
  wait "$second" || fail "single replacement delivery stub did not observe the queued wake"
  queued=$(cat "$state/.wake-queue")
  assert_contains "$(cat "$out")" "wake: queued" "replacement stub did not deliver the queued-wake nudge"
  assert_contains "$queued" "signal: demo.status" "stub termination or replacement drained the durable wake"
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "SIGTERM of the delivery stub costs one re-arm and loses zero queued wakes"
}

# Re-arming while a healthy stub of the SAME session already holds the lock is
# the state bin/fm-turnend-guard.sh judges armed and healthy through
# fm_wake_stub_armed. The arm path used to call the identical state FAILED and
# exit 1, so one repo returned two verdicts and the operator was shown only the
# alarming one - with no remedy but killing a working delivery path.
test_healthy_same_session_stub_reports_already_armed() {
  local home state daemon first out status armed_pid
  home="$TMP_ROOT/stub-same-session"
  state="$home/state"
  out="$home/rearm.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  # pid-identity is the LAST file the stub publishes, so waiting on it - rather
  # than on the pid the lock directory acquires first - is what keeps this test
  # out of the window where the lock metadata is still incomplete and the armed
  # predicate would answer about a half-published lock.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"
  armed_pid=$(cat "$state/.wake-stub.lock/pid")

  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$out" 2>&1 || status=$?
  assert_stub_armed "$state" "$first" "re-arming unarmed the healthy stub that already held the lock"
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true

  [ "$status" -eq 0 ] || fail "re-arming against a healthy same-session stub exited $status instead of 0"
  assert_contains "$(cat "$out")" "already armed pid=$armed_pid (same session)" \
    "re-arm did not name the healthy stub it found already armed"
  case "$(cat "$out")" in
    *FAILED*) fail "a healthy same-session stub was still reported as a delivery failure" ;;
  esac
  pass "re-arming while a healthy same-session stub holds the lock succeeds and names it"
}

test_released_lock_during_classification_is_retried() {
  local home state daemon holder replacement marker out status
  home="$TMP_ROOT/stub-release-race"
  state="$home/state"
  marker="$home/reconcile"
  out="$home/replacement.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_WAIT_TEST_RECONCILE_MARKER="$marker" FM_WAKE_WAIT_TEST_RECONCILE_DELAY=1 \
    "$WAIT" > "$out" 2>&1 & replacement=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$marker" ] && break
    sleep 0.1
  done
  [ -e "$marker" ] || fail "replacement stub did not reach lock classification"
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  sleep 2
  kill -0 "$replacement" 2>/dev/null || fail "replacement reported a released lock as a foreign conflict"
  append_wake "$state" signal demo.status "signal: demo.status"
  status=0
  wait "$replacement" || status=$?
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true

  [ "$status" -eq 0 ] || fail "replacement exited $status after the raced holder released its lock"
  assert_contains "$(cat "$out")" "wake: queued" "replacement did not take delivery after the raced release"
  case "$(cat "$out")" in
    *FAILED*) fail "replacement emitted a false foreign-lock failure after the raced release" ;;
  esac
  pass "a lock released during classification is retried instead of reported as foreign"
}

# The instant close above is right for a caller that owns a re-attempt cadence
# and ruinous for one whose close IS the wake. Under a background-notify harness
# the harness sees only that a tracked task finished and wakes the model, so an
# instant close reads as a wake carrying nothing: the model drains an empty
# queue, re-arms, and the re-arm closes instantly for the same reason. That loop
# was measured at 30 empty deliveries in nine minutes (docs/supervision-cost.md).
# --hold is the fix, and its whole contract is that the process closes only on a
# real wake or a real failure.
test_holding_stub_does_not_close_on_an_already_armed_delivery() {
  local home state daemon first second out err status
  home="$TMP_ROOT/stub-hold"
  state="$home/state"
  out="$home/hold.out"
  err="$home/hold.err"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_CHECKPOINT_REARM_POLL=1 \
    "$WAIT" --hold > "$out" 2> "$err" & second=$!
  sleep 3
  kill -0 "$second" 2>/dev/null \
    || fail "a holding delivery attempt closed while another stub of this session still owned delivery - that close is exactly what a background-notify harness delivers as an empty wake"
  [ ! -s "$out" ] \
    || fail "a holding delivery attempt wrote a close reason to stdout before it had one: $(cat "$out")"
  assert_contains "$(cat "$err")" "holding behind already-armed pid=" \
    "the holding attempt did not say on stderr what it was waiting behind"

  # Never discard: a wake that arrives while an attempt is holding still has to
  # reach whoever is listening, so the holder is not the only process watching.
  printf '%s\t%s\t%s\t%s\t%s\n' 1700000000 1 signal demo.status 'signal: demo.status' >> "$state/.wake-queue"
  status=0
  wait "$second" || status=$?
  [ "$status" -eq 0 ] || fail "a holding delivery attempt exited $status instead of delivering the queued wake"
  assert_contains "$(cat "$out")" "wake: queued" "a holding delivery attempt did not deliver a wake that arrived while it held"

  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "a holding delivery attempt closes only on a real wake, never on finding delivery already armed"
}

# The other half of holding: it is a takeover, not a queue. When the holder
# releases the lock, the attempt behind it becomes the delivery wait itself
# rather than sitting behind a lock nobody owns.
test_holding_stub_takes_delivery_over_from_a_released_holder() {
  local home state daemon first second holder out
  home="$TMP_ROOT/stub-hold-takeover"
  state="$home/state"
  out="$home/takeover.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_CHECKPOINT_REARM_POLL=1 \
    "$WAIT" --hold > "$out" 2>/dev/null & second=$!
  sleep 2
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true

  holder=''
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    holder=$(cat "$state/.wake-stub.lock/pid" 2>/dev/null || true)
    [ "$holder" = "$second" ] && break
    sleep 0.5
  done
  [ "$holder" = "$second" ] \
    || fail "the holding attempt never took delivery over from the released holder (lock pid: ${holder:-none}, expected $second)"
  kill -0 "$second" 2>/dev/null || fail "the promoted attempt exited instead of becoming the delivery wait"

  kill -TERM "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "a holding delivery attempt takes delivery over once the holder releases the lock"
}

# One wake must produce one delivery even when two stubs are watching. The
# holder reports and exits; the stub behind it must let the queue it INHERITED
# go rather than reporting the same wake again, because the model arms once per
# delivery and a doubling would then sustain itself instead of settling.
test_holding_stub_lets_the_holder_report_an_inherited_wake() {
  local home state daemon first second out status
  home="$TMP_ROOT/stub-hold-inherited"
  state="$home/state"
  out="$home/inherited.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$home/holder.out" 2>/dev/null & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  # The inherited grace has to be long enough that draining the queue is not a
  # race against a loaded machine, and the observation after the drain long
  # enough that a deferral which was merely a delay would have fired by then.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_CHECKPOINT_REARM_POLL=8 \
    "$WAIT" --hold > "$out" 2>/dev/null & second=$!
  sleep 1
  printf '%s\t%s\t%s\t%s\t%s\n' 1700000000 1 signal demo.status 'signal: demo.status' >> "$state/.wake-queue"

  for _ in $(seq 1 40); do
    grep -q 'wake: queued' "$home/holder.out" 2>/dev/null && break
    sleep 0.25
  done
  # The model's drain, immediately after the holder reported the wake it owned.
  : > "$state/.wake-queue"
  assert_contains "$(cat "$home/holder.out")" "wake: queued" "the holder did not report the wake it owned"
  status=0
  wait "$first" || status=$?
  [ "$status" -eq 0 ] || fail "the holder exited $status instead of reporting the wake it owned"

  sleep 10
  kill -0 "$second" 2>/dev/null \
    || fail "the stub behind the holder reported the same wake again: $(cat "$out")"
  [ ! -s "$out" ] || fail "the stub behind the holder wrote a second delivery for one wake: $(cat "$out")"

  kill -TERM "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "one wake produces one delivery even with a stub holding behind the holder"
}

# The other side of that deferral, and the reason it is bounded rather than
# unconditional: a holder that is alive but wedged never reports and never
# releases the lock, so a stub that waited on it forever would lose the wake
# outright. Deferral may cost latency; it may never cost the notification.
test_holding_stub_reports_a_wake_a_wedged_holder_never_did() {
  local home state daemon first second out status delivered
  home="$TMP_ROOT/stub-hold-wedged"
  state="$home/state"
  out="$home/wedged.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_CHECKPOINT_REARM_POLL=2 \
    "$WAIT" --hold > "$out" 2>/dev/null & second=$!
  sleep 1
  # Alive to every liveness predicate, and never going to report anything.
  kill -STOP "$first" 2>/dev/null || fail "could not wedge the holder"
  printf '%s\t%s\t%s\t%s\t%s\n' 1700000000 1 signal demo.status 'signal: demo.status' >> "$state/.wake-queue"

  delivered=0
  for _ in $(seq 1 100); do
    kill -0 "$second" 2>/dev/null || { delivered=1; break; }
    sleep 0.2
  done
  if [ "$delivered" -eq 0 ]; then
    kill -CONT "$first" 2>/dev/null || true
    fail "a wake a wedged holder never reported was never delivered by the stub behind it"
  fi
  status=0
  wait "$second" || status=$?
  kill -CONT "$first" 2>/dev/null || true
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true

  [ "$status" -eq 0 ] || fail "the stub behind a wedged holder exited $status instead of delivering"
  assert_contains "$(cat "$out")" "wake: queued" "the stub behind a wedged holder did not deliver the queued wake"
  pass "a wake a wedged holder never reported is still delivered, late rather than lost"
}

# The wrapper is where the defect actually reached the model: it is what a
# background-notify harness runs as its tracked task, so it is the one caller
# that must never be handed the instant close. Nothing else in this file would
# notice if the flag were dropped from that one line.
test_arm_wrapper_waits_with_hold() {
  local home state daemon holder wrapper fixture old_watch out delivered
  home="$TMP_ROOT/arm-wrapper-hold"
  state="$home/state"
  fixture="$home/bin"
  out="$home/arm.out"
  mkdir -p "$state" "$fixture"
  cp "$ROOT/bin/fm-watch-arm.sh" "$fixture/fm-watch-arm.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fixture/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-wake-wait.sh" "$fixture/fm-wake-wait.sh"
  ln -s "$ROOT/bin/fm-watch.sh" "$fixture/fm-watch.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/fm-watcher-service.sh"
  chmod +x "$fixture/fm-watch-arm.sh" "$fixture/fm-watcher-service.sh"

  sleep 60 & daemon=$!
  old_watch=$WATCH
  WATCH="$fixture/fm-watch.sh"
  record_fake_daemon "$home" "$state" "$daemon"
  WATCH=$old_watch
  touch "$state/.last-watcher-beat"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$fixture/fm-wake-wait.sh" >/dev/null 2>&1 & holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$fixture/fm-watch-arm.sh" > "$out" 2>&1 & wrapper=$!
  sleep 1
  kill -0 "$wrapper" 2>/dev/null || fail "arm wrapper closed merely because delivery was already armed"
  append_wake "$state" signal demo.status "signal: demo.status"
  delivered=0
  for _ in $(seq 1 50); do
    kill -0 "$wrapper" 2>/dev/null || { delivered=1; break; }
    sleep 0.2
  done
  [ "$delivered" -eq 1 ] || fail "arm wrapper did not close for a real queued wake"
  wait "$wrapper" || fail "arm wrapper failed instead of delivering the queued wake"
  assert_contains "$(cat "$out")" "wake: queued" "arm wrapper did not report the queued wake"
  kill -TERM "$holder" "$daemon" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "the arm wrapper stays open until a real wake"
}

# The other half of the same branch: everything fm_wake_stub_armed rejects is a
# real conflict and has to stay exactly as loud as it was. A live holder is not
# enough - the lock has to belong to THIS session and match its recorded
# identity - so both a session takeover and a lock whose identity no longer
# matches must still fail.
test_foreign_stub_lock_still_fails_loudly() {
  local home state daemon first out status
  home="$TMP_ROOT/stub-foreign"
  state="$home/state"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  printf '4242\n' > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" >/dev/null 2>&1 & first=$!
  # Wait for pid-identity, the last published file: rewriting state/.lock while
  # the stub is still between acquiring the lock and recording session-lock-pid
  # would make the holder record 9999 as its OWN session and flip this test's
  # verdict to the healthy branch, failing for a reason unrelated to the code.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid-identity" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid-identity" ] || fail "initial delivery stub did not publish its lock"

  # A different session now owns this home: the lock was recorded under session
  # 4242 and the live session lock reads 9999.
  printf '9999\n' > "$state/.lock"
  out="$home/other-session.out"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$out" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "a stub lock held by another session exited $status instead of 1"
  assert_contains "$(cat "$out")" "FAILED - another delivery stub already holds" \
    "another session's stub lock was not reported as a delivery failure"

  # Same session again, but the recorded identity no longer matches the live pid
  # behind the lock - a stale lock survived by pid reuse.
  printf '4242\n' > "$state/.lock"
  printf '%s\n' 'linux-starttime=1 cmdline-hex=00' > "$state/.wake-stub.lock/pid-identity"
  out="$home/stale-identity.out"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WAIT" > "$out" 2>&1 || status=$?
  kill -TERM "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true

  [ "$status" -eq 1 ] || fail "a stub lock whose identity no longer matches exited $status instead of 1"
  assert_contains "$(cat "$out")" "FAILED - another delivery stub already holds" \
    "a stale stub lock was not reported as a delivery failure"
  pass "a stub lock from another session or with a stale identity still fails loudly"
}

test_stub_exits_loudly_on_stale_daemon_beacon() {
  local home state daemon out status
  home="$TMP_ROOT/stub-stale"
  state="$home/state"
  out="$home/stale.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WAKE_BEAT_CONFIRM=2 \
    "$WAIT" > "$out" 2>&1 || status=$?
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "delivery stub succeeded with a stale daemon beacon"
  assert_contains "$(cat "$out")" "watcher beacon stale" "stale daemon failure was not loud"
  pass "delivery stub exits loudly when the daemon beacon exceeds guard grace"
}

# A watcher pid that is alive and identity-matched but never beats is a wedge,
# not a sleep: the beat-confirmation window is bounded so it is still reported.
test_wedged_live_watcher_is_reported_after_the_bounded_window() {
  local home state daemon out status started elapsed
  home="$TMP_ROOT/stub-wedged"
  state="$home/state"
  out="$home/wedged.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  touch -t 200001010000 "$state/.last-watcher-beat"
  started=$(date +%s)
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WAKE_BEAT_CONFIRM=4 \
    "$WAIT" > "$out" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started ))
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "delivery stub survived a live watcher that never beat"
  assert_contains "$(cat "$out")" "never came back inside the grace within the 4s confirmation window" \
    "wedged-watcher failure did not name the elapsed confirmation window"
  [ "$elapsed" -ge 4 ] || fail "wedged watcher was reported before its confirmation window elapsed (${elapsed}s)"
  [ "$elapsed" -lt 20 ] || fail "wedged watcher report was not bounded by the confirmation window (${elapsed}s)"
  pass "a live watcher that never beats is still reported, bounded by the confirmation window"
}

# Recovery means the beacon is back INSIDE the grace, not merely that its mtime
# moved. A watcher that keeps beating but never fast enough to be healthy was
# reportable before the window existed and has to stay reportable: closing the
# window on a bare mtime change would let it flap stale-window-beat-close
# forever and turn a loud report into no report at all.
test_beacon_advancing_outside_the_grace_is_not_recovery() {
  local home state daemon toucher out status started elapsed first_mtime last_mtime
  home="$TMP_ROOT/stub-chronic-stall"
  state="$home/state"
  out="$home/chronic.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  # A beacon whose mtime advances every second but is always stamped well past
  # the grace: beating, never healthy. Prove the backdating mechanism works
  # before relying on it - a silently failing toucher leaves an ordinary aging
  # beacon behind, which the stub reports at the same window for the wrong
  # reason, and this test is the only coverage of the grace-gated recovery rule.
  backdate_beacon() {
    perl -e 'my $t = time - 30; utime($t, $t, $ARGV[0]) or exit 1;' "$state/.last-watcher-beat"
  }
  backdate_beacon || fail "could not backdate the watcher beacon, so the chronic-stall case was never set up"
  first_mtime=$(fm_path_mtime_of "$state/.last-watcher-beat")
  (
    while :; do
      backdate_beacon || exit 1
      sleep 1
    done
  ) & toucher=$!
  started=$(date +%s)
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=3 FM_WAKE_BEAT_CONFIRM=4 \
    "$WAIT" > "$out" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started ))
  last_mtime=$(fm_path_mtime_of "$state/.last-watcher-beat")
  kill -TERM "$toucher" 2>/dev/null || true
  wait "$toucher" 2>/dev/null || true
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  [ "$last_mtime" -gt "$first_mtime" ] \
    || fail "the beacon mtime never advanced during the run, so nothing about grace-gated recovery was exercised"
  [ "$status" -ne 0 ] || fail "a beacon advancing outside the grace was accepted as recovery"
  assert_contains "$(cat "$out")" "never came back inside the grace within the 4s confirmation window" \
    "chronically stalling watcher was not reported against the confirmation window"
  case "$(cat "$out")" in
    *"delivery stayed armed across the stale beacon"*)
      fail "an advanced but still-stale beacon closed the confirmation window" ;;
  esac
  [ "$elapsed" -ge 4 ] || fail "chronic staller was reported before its confirmation window elapsed (${elapsed}s)"
  [ "$elapsed" -lt 20 ] || fail "chronic staller reopened its window instead of being reported (${elapsed}s)"
  pass "a beacon that advances but never returns inside the grace is still reported"
}

# The beat-confirmation window must never be consulted when no live,
# identity-matched watcher holds the lock: a genuinely dead watcher has to be
# reported on the first reading past grace, exactly as before this window
# existed. The huge FM_WAKE_BEAT_CONFIRM here is the assertion - if the dead
# path ever fell into the window, this test would hang for 600s.
test_dead_watcher_is_reported_without_waiting_for_a_beat() {
  local home state daemon out status started elapsed
  home="$TMP_ROOT/stub-dead"
  state="$home/state"
  out="$home/dead.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  kill -KILL "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  touch -t 200001010000 "$state/.last-watcher-beat"
  started=$(date +%s)
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WAKE_BEAT_CONFIRM=600 \
    "$WAIT" > "$out" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "delivery stub survived a dead watcher with a stale beacon"
  assert_contains "$(cat "$out")" "watcher beacon stale" "dead-watcher failure was not loud"
  case "$(cat "$out")" in
    *"waiting up to"*) fail "dead watcher opened a beat-confirmation window it can never satisfy" ;;
  esac
  [ "$elapsed" -lt 10 ] || fail "dead watcher was not reported on the first reading past grace (${elapsed}s)"
  pass "a dead watcher is reported on the first reading past grace, never through the confirmation window"
}

# The suspend regression, proven by freezing rather than by reading the code.
# SIGSTOP on BOTH the real watcher and the delivery stub reproduces what a
# machine suspend does to this pair: neither process runs, wall clock advances,
# and the beacon ages past grace because nothing can touch it. The stub is
# resumed first and given time to observe the aged beacon before the watcher is
# resumed, which is strictly harsher than a real resume, where both come back
# together and the stub may not even get a reading before the next beat.
test_stub_survives_a_freeze_of_both_watcher_and_stub() {
  local dir state fakebin watcher stub queued out err
  dir=$(make_case suspend-equivalent)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/wait.out"
  err="$dir/wait.err"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WATCH_DAEMON=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  watcher=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  [ -e "$state/.last-watcher-beat" ] || fail "watcher never established its beacon"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=4 FM_WAKE_BEAT_CONFIRM=60 \
    "$WAIT" > "$out" 2>"$err" &
  stub=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid" ] || fail "delivery stub did not publish its lock"

  kill -STOP "$watcher" 2>/dev/null || fail "could not freeze the watcher"
  kill -STOP "$stub" 2>/dev/null || fail "could not freeze the delivery stub"
  sleep 7
  kill -CONT "$stub" 2>/dev/null || fail "could not resume the delivery stub"
  sleep 2
  assert_stub_armed "$state" "$stub" \
    "delivery stub unarmed itself on resume before the watcher could beat again"
  kill -CONT "$watcher" 2>/dev/null || fail "could not resume the watcher"
  sleep 3
  assert_stub_armed "$state" "$stub" "delivery stub unarmed itself across a host freeze"
  assert_contains "$(cat "$err")" "waiting up to 60s for a fresh beat" \
    "stub did not record that it was waiting on the resumed watcher's next beat"
  assert_contains "$(cat "$err")" "delivery stayed armed across the stale beacon" \
    "a recovered stale beacon left no trace distinguishing it from a watcher that never came back"

  append_wake "$state" signal demo.status "signal: demo.status"
  wait "$stub" || fail "the surviving delivery stub did not deliver the wake queued after resume"
  queued=$(cat "$state/.wake-queue")
  assert_contains "$(cat "$out")" "wake: queued" "resumed stub did not deliver the queued-wake nudge"
  assert_contains "$queued" "signal: demo.status" "resumed stub drained the durable wake"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass "wake delivery stays armed across a freeze of both the watcher and the delivery stub"
}

# The dark-wake sequence: a laptop that resumes briefly, sleeps again before the
# watcher's next beat, and only then sleeps long. The confirmation window is
# already OPEN when the second freeze starts, so a wall-clock deadline expires
# unobserved while the stub cannot run and the first post-resume reading fails -
# the original symptom, reproduced through the fix meant to prevent it. The
# single-freeze test above cannot reach this: it only ever freezes before a
# window exists. FM_WAKE_BEAT_CONFIRM has to mean awake seconds for this to pass.
test_stub_survives_a_second_freeze_while_the_window_is_open() {
  local dir state fakebin watcher stub queued out err
  dir=$(make_case dark-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/wait.out"
  err="$dir/wait.err"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WATCH_DAEMON=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  watcher=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  [ -e "$state/.last-watcher-beat" ] || fail "watcher never established its beacon"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=3 FM_WAKE_BEAT_CONFIRM=10 \
    "$WAIT" > "$out" 2>"$err" &
  stub=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$state/.wake-stub.lock/pid" ] && break
    sleep 0.1
  done
  [ -e "$state/.wake-stub.lock/pid" ] || fail "delivery stub did not publish its lock"

  kill -STOP "$watcher" 2>/dev/null || fail "could not freeze the watcher"
  kill -STOP "$stub" 2>/dev/null || fail "could not freeze the delivery stub"
  sleep 5
  # First resume: the stub alone, so it is forced to read the aged beacon and
  # open the window before the watcher can beat.
  kill -CONT "$stub" 2>/dev/null || fail "could not resume the delivery stub"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "waiting up to 10s for a fresh beat" "$err" && break
    sleep 0.2
  done
  assert_contains "$(cat "$err")" "waiting up to 10s for a fresh beat" \
    "stub did not open a confirmation window on the aged beacon"

  # Second freeze, longer than the whole window, with the watcher still frozen
  # so no beat can arrive: wall clock runs past the deadline, awake time does not.
  kill -STOP "$stub" 2>/dev/null || fail "could not freeze the delivery stub again"
  sleep 12
  # Resume the stub alone again, so it is forced to read the still-aged beacon
  # against a deadline that wall clock has already run past. Resuming both at
  # once would let the watcher's next beat land first and hide the regression.
  kill -CONT "$stub" 2>/dev/null || fail "could not resume the delivery stub again"
  sleep 2
  assert_stub_armed "$state" "$stub" \
    "delivery stub unarmed itself on a wall-clock deadline that expired while it was frozen"
  kill -CONT "$watcher" 2>/dev/null || fail "could not resume the watcher"
  sleep 3
  assert_stub_armed "$state" "$stub" \
    "delivery stub unarmed itself after the twice-frozen watcher resumed"
  assert_contains "$(cat "$err")" "delivery stayed armed across the stale beacon" \
    "the reopened watcher beat did not close the confirmation window"

  append_wake "$state" signal demo.status "signal: demo.status"
  wait "$stub" || fail "the twice-frozen delivery stub did not deliver the wake queued after resume"
  queued=$(cat "$state/.wake-queue")
  assert_contains "$(cat "$out")" "wake: queued" "twice-frozen stub did not deliver the queued-wake nudge"
  assert_contains "$queued" "signal: demo.status" "twice-frozen stub drained the durable wake"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass "an open confirmation window survives a freeze longer than the window itself"
}

# The documented "0 disables the window" has to be true on the FIRST stale
# reading: a zero-length window that still opens, narrates, and only exits one
# poll later is not the single-reading behavior the knob promises.
test_zero_confirm_window_restores_single_reading_behavior() {
  local home state daemon out status started elapsed
  home="$TMP_ROOT/stub-zero-window"
  state="$home/state"
  out="$home/zero.out"
  mkdir -p "$state"
  sleep 60 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  touch -t 200001010000 "$state/.last-watcher-beat"
  started=$(date +%s)
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WAKE_BEAT_CONFIRM=0 \
    "$WAIT" > "$out" 2>&1 || status=$?
  elapsed=$(( $(date +%s) - started ))
  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "delivery stub survived a stale beacon with the window disabled"
  case "$(cat "$out")" in
    *"waiting up to"*) fail "FM_WAKE_BEAT_CONFIRM=0 still opened a confirmation window" ;;
  esac
  [ "$elapsed" -lt 3 ] || fail "FM_WAKE_BEAT_CONFIRM=0 did not exit on the first stale reading (${elapsed}s)"
  pass "FM_WAKE_BEAT_CONFIRM=0 restores single-reading behavior exactly as documented"
}

# The ordering of the two defaults is only half the invariant: an operator who
# shortens the checkpoint re-creates the very failure the ordering prevents. The
# checkpoint knows both numbers, so it clamps. A wedged watcher under a short
# checkpoint must therefore still be reported, not timed out and forgotten.
test_checkpoint_clamps_the_confirmation_window_below_its_own_bound() {
  local home state daemon out status
  home="$TMP_ROOT/checkpoint-clamp"
  state="$home/state"
  mkdir -p "$state"
  sleep 120 & daemon=$!
  record_fake_daemon "$home" "$state" "$daemon"
  touch -t 200001010000 "$state/.last-watcher-beat"

  # The stub's own default window outlives this checkpoint, so without the clamp
  # the checkpoint would simply time out (rc 124) and report nothing.
  out="$home/default.out"
  status=0
  env -u FM_WAKE_BEAT_CONFIRM FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 \
    "$CHECKPOINT" --seconds 8 > "$out" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "short checkpoint did not report the wedged watcher (exit $status)"
  assert_contains "$(cat "$out")" "wake delivery: FAILED" \
    "short checkpoint swallowed the wedged-watcher report"
  assert_contains "$(cat "$out")" "clamping it to 4s" \
    "checkpoint clamped the default window without saying so"

  # The same clamp has to cover an ambient value, not just the stub's default.
  out="$home/ambient.out"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_WAKE_BEAT_CONFIRM=90 \
    "$CHECKPOINT" --seconds 8 > "$out" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "short checkpoint did not clamp an ambient FM_WAKE_BEAT_CONFIRM (exit $status)"
  assert_contains "$(cat "$out")" "wake delivery: FAILED" \
    "short checkpoint swallowed the wedged-watcher report under an ambient window"

  kill -TERM "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  pass "the Codex checkpoint clamps the beat-confirmation window below its own bound at runtime"
}

# The Codex foreground checkpoint is the one caller that gives the delivery stub
# a bounded lifetime. A beat-confirmation window at or above that bound would be
# restarted by every new checkpoint and would never reach its own deadline, so a
# wedged watcher would never be reported under that harness at all - a bounded
# delay silently becoming no report. Enforce the ordering rather than trusting
# whoever next tunes either default to remember the coupling.
test_default_confirm_window_fits_inside_the_codex_checkpoint() {
  local window checkpoint
  window=$(sed -n 's/^FM_WAKE_BEAT_CONFIRM_DEFAULT=\([0-9]\{1,\}\).*/\1/p' \
    "$ROOT/bin/fm-wake-lib.sh" | head -1)
  checkpoint=$(sed -n 's/^SECONDS_ARG=.*FM_CODEX_WATCH_CHECKPOINT:-\([0-9]\{1,\}\).*/\1/p' \
    "$ROOT/bin/fm-watch-checkpoint.sh" | head -1)
  [ -n "$window" ] || fail "could not read FM_WAKE_BEAT_CONFIRM_DEFAULT from bin/fm-wake-lib.sh"
  [ -n "$checkpoint" ] || fail "could not read the default FM_CODEX_WATCH_CHECKPOINT from bin/fm-watch-checkpoint.sh"
  [ "$window" -lt "$checkpoint" ] \
    || fail "beat-confirmation window ${window}s does not fit inside the ${checkpoint}s Codex checkpoint, so a wedged watcher would never be reported under Codex"
  pass "the default beat-confirmation window (${window}s) fits inside the Codex foreground checkpoint (${checkpoint}s)"
}

test_daemon_enqueues_and_continues_without_arm_owner
test_killed_stub_loses_no_wake_and_costs_one_rearm
test_healthy_same_session_stub_reports_already_armed
test_released_lock_during_classification_is_retried
test_holding_stub_does_not_close_on_an_already_armed_delivery
test_holding_stub_takes_delivery_over_from_a_released_holder
test_holding_stub_lets_the_holder_report_an_inherited_wake
test_holding_stub_reports_a_wake_a_wedged_holder_never_did
test_arm_wrapper_waits_with_hold
test_foreign_stub_lock_still_fails_loudly
test_stub_exits_loudly_on_stale_daemon_beacon
test_wedged_live_watcher_is_reported_after_the_bounded_window
test_beacon_advancing_outside_the_grace_is_not_recovery
test_dead_watcher_is_reported_without_waiting_for_a_beat
test_stub_survives_a_freeze_of_both_watcher_and_stub
test_stub_survives_a_second_freeze_while_the_window_is_open
test_zero_confirm_window_restores_single_reading_behavior
test_default_confirm_window_fits_inside_the_codex_checkpoint
test_checkpoint_clamps_the_confirmation_window_below_its_own_bound
