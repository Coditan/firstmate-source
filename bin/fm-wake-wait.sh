#!/usr/bin/env bash
# Block until this home's durable wake queue is non-empty.
#
# This is the lightweight, session-owned delivery half of supervision.
# It never drains state/.wake-queue; bin/fm-wake-drain.sh remains the sole
# model-invoked atomic drain.  The stub owns state/.wake-stub.lock while waiting
# and exits loudly if the external watcher beacon ages past FM_GUARD_GRACE.
#
# One beacon reading is not proof of a dead watcher.  A machine suspend freezes
# the watcher along with everything else, so on resume the beacon is necessarily
# as old as the sleep and a single-reading exit unarms delivery on every wake
# from sleep - silently, until a human notices.  A suspend and a death are
# already distinguishable without any suspend detection: fm_watcher_healthy
# checks a live pid, a matching lock identity, and a fresh beacon, and only the
# third fails on resume.  So when the beacon age is the SOLE failing condition,
# this stub gives the watcher FM_WAKE_BEAT_CONFIRM seconds to get its beacon
# back INSIDE the grace, and exits only if it never does.  It keeps polling the
# durable queue throughout, so delivery stays armed for the whole window.
#
# Those seconds are awake seconds, not wall-clock ones.  A window can be open
# when the host suspends, and wall clock keeps running while this process does
# not, so a wall-clock deadline would expire unobserved and fail on the first
# post-resume reading - the very bug the window exists to fix.  The loop sleeps
# POLL between iterations, so an inter-iteration gap far larger than POLL is
# local, portable evidence that the whole host was frozen, and the whole gap is
# added back to an open deadline.  Frozen time was never time the watcher had to
# prove itself in.
#
# Recovery means the beacon is back inside the grace, not merely that its mtime
# moved: a watcher that keeps beating but always slower than the grace would
# otherwise flap stale-window-beat-close forever and never be reported at all.
#
# The dead case is untouched: no live identity-matched watcher still exits on
# the first reading past grace, exactly as before.  Only an alive-but-wedged
# watcher - one holding the lock and not beating back inside the grace - is
# reported later, by the window, and that window is bounded so it is still
# reported.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STUB_PATH="$SCRIPT_DIR/fm-wake-wait.sh"
STUB_LOCK="$STATE/.wake-stub.lock"
WATCH="$SCRIPT_DIR/fm-watch.sh"
BEAT="$STATE/.last-watcher-beat"
GRACE=${FM_GUARD_GRACE:-300}
POLL=${FM_WAKE_WAIT_POLL:-1}
# Awake seconds a live, identity-matched watcher gets to get its beacon back
# inside the grace before its silence is reported.  bin/fm-watch.sh touches its
# beacon at the top of every cycle, BEFORE that cycle's work, so the first beat
# after a resume is due within one FM_POLL (15s) of the host waking, whatever
# the cycle then goes on to do; 15-18s is what the reported laptop actually did.
# The default is several times that, and is bounded from above by the Codex
# foreground checkpoint (FM_CODEX_WATCH_CHECKPOINT, 180s), which is the one
# caller that gives this stub a limited lifetime: a window that outlived the
# checkpoint would restart with each new checkpoint and never report a wedged
# watcher at all.  bin/fm-watch-checkpoint.sh clamps the value it passes down so
# that bound holds by construction, not by memory.
# 0 disables the window and restores single-reading behavior.
BEAT_CONFIRM=${FM_WAKE_BEAT_CONFIRM:-$FM_WAKE_BEAT_CONFIRM_DEFAULT}
case "$BEAT_CONFIRM" in ''|*[!0-9]*) BEAT_CONFIRM=$FM_WAKE_BEAT_CONFIRM_DEFAULT ;; esac
# An inter-iteration gap this large cannot be ordinary scheduling jitter over a
# POLL-second sleep, so it is read as the host having been frozen.  Derived from
# POLL rather than configured: this is a property of the loop's own cadence, and
# one more knob is one more thing to get wrong.  Erring long is safe - it only
# lets an identity-matched watcher run a little further inside a still-bounded
# window - while erring short brings the suspend bug back.
POLL_WHOLE=${POLL%%.*}
case "$POLL_WHOLE" in ''|*[!0-9]*) POLL_WHOLE=1 ;; esac
FREEZE_GAP=$((POLL_WHOLE * 2 + 5))
LOCK_OWNED=0

cleanup() {
  trap - HUP INT TERM
  [ "$LOCK_OWNED" -eq 0 ] || fm_lock_release "$STUB_LOCK"
}
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

lock_rc=0
fm_lock_try_acquire "$STUB_LOCK" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  if [ "$lock_rc" -eq 2 ]; then
    echo "wake delivery: FAILED - lock acquisition failed for $STUB_LOCK" >&2
    exit 1
  fi
  echo "wake delivery: FAILED - another delivery stub already holds $STUB_LOCK" >&2
  exit 1
fi
LOCK_OWNED=1
STUB_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$STUB_LOCK/fm-home" || exit 1
printf '%s\n' "$STUB_PATH" > "$STUB_LOCK/stub-path" || exit 1
printf '%s\n' "$(cat "$STATE/.lock" 2>/dev/null || true)" > "$STUB_LOCK/session-lock-pid" || exit 1
fm_pid_identity "$STUB_PID" > "$STUB_LOCK/pid-identity" 2>/dev/null || {
  echo "wake delivery: FAILED - could not record stub identity" >&2
  exit 1
}

# Deadline of the confirmation window currently in flight, empty when none is.
# Only a beacon back inside the grace closes it; an mtime that merely advanced
# is not recovery, because a watcher beating slower than the grace never was.
confirm_deadline=

# Close an open window, announcing the recovery.  A window that opened and then
# went quiet must not read the same as one that is still counting down: a
# recovered suspend and a hung watcher have to be told apart from the log alone.
confirm_close() {
  [ -n "$confirm_deadline" ] || return 0
  echo "wake delivery: watcher beacon back inside the ${GRACE}s grace; delivery stayed armed across the stale beacon" >&2
  confirm_deadline=
}

prev_iter=$(date +%s)
while :; do
  now=$(date +%s)
  gap=$((now - prev_iter))
  prev_iter=$now
  # Give an open window back every second the host spent frozen.  The gap is
  # tracked on every iteration, window or not, so a freeze that straddles the
  # moment a window opens is measured against the right previous reading.
  if [ -n "$confirm_deadline" ] && [ "$gap" -ge "$FREEZE_GAP" ]; then
    confirm_deadline=$((confirm_deadline + gap))
  fi
  if [ -s "$FM_WAKE_QUEUE" ]; then
    echo "wake: queued"
    exit 0
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    confirm_close
  else
    age=$(fm_path_age "$BEAT")
    if [ "$age" -lt "$GRACE" ]; then
      confirm_close
    elif [ "$FM_WATCHER_HEALTH" != beacon-stale ]; then
      # No live watcher holds this home's lock, so no beat can be coming.
      echo "wake delivery: FAILED - watcher beacon stale for ${age}s (grace ${GRACE}s)" >&2
      exit 1
    elif [ "$BEAT_CONFIRM" -eq 0 ]; then
      # The window is switched off, so this single reading is the whole verdict.
      echo "wake delivery: FAILED - watcher beacon stale for ${age}s (grace ${GRACE}s)" >&2
      exit 1
    elif [ -z "$confirm_deadline" ]; then
      confirm_deadline=$((now + BEAT_CONFIRM))
      echo "wake delivery: watcher beacon stale for ${age}s (grace ${GRACE}s) but pid $FM_WATCHER_LIVE_PID still holds this home's watcher lock; waiting up to ${BEAT_CONFIRM}s for a fresh beat" >&2
    elif [ "$now" -ge "$confirm_deadline" ]; then
      echo "wake delivery: FAILED - watcher beacon stale for ${age}s (grace ${GRACE}s); pid $FM_WATCHER_LIVE_PID is alive but its beacon never came back inside the grace within the ${BEAT_CONFIRM}s confirmation window" >&2
      exit 1
    fi
  fi
  sleep "$POLL"
done
