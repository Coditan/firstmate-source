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
# this stub gives the watcher FM_WAKE_BEAT_CONFIRM seconds to prove itself with
# a fresh beat and exits only if no beat arrives.  It keeps polling the durable
# queue throughout, so delivery stays armed for the whole confirmation window.
#
# The dead case is untouched: no live identity-matched watcher still exits on
# the first reading past grace, exactly as before.  Only an alive-but-wedged
# watcher - one holding the lock and not beating - is reported later, by the
# confirmation window, and that window is bounded so it is still reported.
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
# Seconds a live, identity-matched watcher gets to emit one fresh beat before
# its silence is reported.  bin/fm-watch.sh touches its beacon at the top of
# every cycle, BEFORE that cycle's work, so the first beat after a resume is due
# within one FM_POLL (15s) of the host waking, whatever the cycle then goes on
# to do; 15-18s is what the reported laptop actually did.  The default is
# several times that, and is bounded from above by the Codex foreground
# checkpoint (FM_CODEX_WATCH_CHECKPOINT, 180s), which is the one caller that
# gives this stub a limited lifetime: a window that outlived the checkpoint
# would restart with each new checkpoint and never report a wedged watcher at
# all.  Keep this comfortably under that bound.
# 0 disables the window and restores single-reading behavior.
BEAT_CONFIRM=${FM_WAKE_BEAT_CONFIRM:-90}
case "$BEAT_CONFIRM" in ''|*[!0-9]*) BEAT_CONFIRM=90 ;; esac
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

# Deadline of the confirmation window currently in flight, empty when none is,
# alongside the beacon mtime that opened it.  A beat that advances past that
# mtime is the watcher proving itself and closes the window.
confirm_deadline=
confirm_mtime=

# Close an open window, announcing the recovery.  A window that opened and then
# went quiet must not read the same as one that is still counting down: a
# recovered suspend and a hung watcher have to be told apart from the log alone.
confirm_close() {
  [ -n "$confirm_deadline" ] || return 0
  echo "wake delivery: watcher beacon advanced; delivery stayed armed across the stale beacon" >&2
  confirm_deadline=
}

while :; do
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
    else
      now=$(date +%s)
      beat_mtime=$(fm_path_mtime "$BEAT" || true)
      if [ -z "$confirm_deadline" ]; then
        confirm_deadline=$((now + BEAT_CONFIRM))
        confirm_mtime=$beat_mtime
        echo "wake delivery: watcher beacon stale for ${age}s (grace ${GRACE}s) but pid $FM_WATCHER_LIVE_PID still holds this home's watcher lock; waiting up to ${BEAT_CONFIRM}s for a fresh beat" >&2
      elif [ "$beat_mtime" != "$confirm_mtime" ]; then
        confirm_close
      elif [ "$now" -ge "$confirm_deadline" ]; then
        echo "wake delivery: FAILED - watcher beacon stale for ${age}s (grace ${GRACE}s); pid $FM_WATCHER_LIVE_PID is alive but produced no beat in ${BEAT_CONFIRM}s" >&2
        exit 1
      fi
    fi
  fi
  sleep "$POLL"
done
