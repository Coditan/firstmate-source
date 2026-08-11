#!/usr/bin/env bash
# Block until this home's durable wake queue is non-empty.
#
# This is the lightweight, session-owned delivery half of supervision.
# It never drains state/.wake-queue; bin/fm-wake-drain.sh remains the sole
# model-invoked atomic drain.  The stub owns state/.wake-stub.lock while waiting
# and exits loudly if the external watcher beacon ages past FM_GUARD_GRACE.
# Arming is idempotent for one session: when a healthy stub of the same session
# already holds that lock, this reports the existing arm and succeeds.
#
# `--hold` changes only what that idempotent case DOES, never what it means.
# Without it this returns immediately, which is right for a caller that owns its
# own re-attempt cadence (bin/fm-watch-checkpoint.sh, the OpenCode plugin) and
# wrong for a caller whose completion IS the wake delivery.  Under a
# background-notify harness the harness cannot see why a delivery attempt
# closed: it only sees that the tracked task finished, and it wakes the model.
# An instant close therefore reads as a wake that carries nothing, the model
# drains an empty queue and re-arms, and that re-arm closes instantly for the
# same reason - a self-sustaining loop of empty deliveries in front of the
# queue rather than inside it.  It is measured, not hypothetical:
# docs/supervision-cost.md records 30 such deliveries in nine minutes.
# With `--hold` a stub that finds delivery already armed stays alive instead,
# polling the durable queue exactly like the holder does and retrying the lock
# every FM_WATCH_CHECKPOINT_REARM_POLL seconds until the holder releases it.
# So the process closes only on a real wake or a real failure, which is the one
# property that makes a close safe to treat as a delivery.
#
# A holding stub keeps watching the queue rather than only waiting for the lock,
# and that ordering is deliberate: waiting for the lock alone would be silent if
# the holder were wedged and nobody were listening to it, and a wake nobody
# hears is the one failure this fleet does not accept.
#
# But content that appears while the holder is still the one delivering belongs
# to the holder to report.  Reporting it here too closes both processes on one
# wake, and since the model arms once per delivery, that doubling sustains
# itself rather than settling.  So such content is INHERITED: this stub waits
# one FM_WATCH_CHECKPOINT_REARM_POLL before it will report it, and it stops
# counting as inherited the moment the queue drains.  A holder that is working
# reports well inside that window; a holder that was killed or wedged never
# does, and then this stub reports it a few seconds late.  Latency, never
# silence.
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

HOLD=0
case "${1:-}" in
  '') ;;
  --hold) HOLD=1 ;;
  -h|--help)
    cat <<'EOF'
Usage: fm-wake-wait.sh [--hold]

Block until this home's durable wake queue is non-empty, then print "wake: queued".
Without --hold, a healthy same-session stub already holding the lock is reported
as "wake delivery: already armed pid=<N> (same session)" and this exits 0 at once.
With --hold, that case waits behind the holder instead of closing, so this process
closes only on a real wake or a real failure.
EOF
    exit 0
    ;;
  *)
    echo "usage: $(basename "$0") [--hold]" >&2
    exit 2
    ;;
esac

STUB_PATH="$SCRIPT_DIR/fm-wake-wait.sh"
STUB_LOCK="$STATE/.wake-stub.lock"
WATCH="$SCRIPT_DIR/fm-watch.sh"
BEAT="$STATE/.last-watcher-beat"
GRACE=${FM_GUARD_GRACE:-300}
POLL=${FM_WAKE_WAIT_POLL:-1}
# Seconds between takeover attempts while holding behind a healthy same-session
# holder.  Shared with bin/fm-watch-checkpoint.sh and the OpenCode plugin on
# purpose: three components take delivery back from a released holder, and one
# fleet should have one cadence for that rather than three that can drift.
REARM_POLL=${FM_WATCH_CHECKPOINT_REARM_POLL:-5}
case "$REARM_POLL" in ''|*[!0-9]*|0) REARM_POLL=5 ;; esac
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

# Publish this stub's identity into the lock it just won.  Factored out because
# a holding stub runs it later, at takeover, rather than at start-up, and one
# copy of the publication order is what keeps the armed predicate from ever
# reading a half-published lock.
publish_stub_identity() {
  local stub_pid=${BASHPID:-$$}
  printf '%s\n' "$FM_HOME" > "$STUB_LOCK/fm-home" || return 1
  printf '%s\n' "$STUB_PATH" > "$STUB_LOCK/stub-path" || return 1
  printf '%s\n' "$(cat "$STATE/.lock" 2>/dev/null || true)" > "$STUB_LOCK/session-lock-pid" || return 1
  fm_pid_identity "$stub_pid" > "$STUB_LOCK/pid-identity" 2>/dev/null || return 1
}

stub_lock_observation() {
  local file value observation=present
  [ -d "$STUB_LOCK" ] || { echo missing; return 0; }
  for file in pid fm-home stub-path session-lock-pid pid-identity; do
    value=$(cat "$STUB_LOCK/$file" 2>/dev/null || true)
    observation="$observation|$file=$value"
  done
  printf '%s\n' "$observation"
}

reconcile_stub_lock() {
  local attempt=0 rc before after
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    rc=0
    fm_lock_try_acquire "$STUB_LOCK" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) return 2 ;;
    esac
    before=$(stub_lock_observation)
    if [ -n "${FM_WAKE_WAIT_TEST_RECONCILE_MARKER:-}" ]; then
      : > "$FM_WAKE_WAIT_TEST_RECONCILE_MARKER"
    fi
    case "${FM_WAKE_WAIT_TEST_RECONCILE_DELAY:-0}" in
      0|'') ;;
      *[!0-9.]*) ;;
      *) sleep "$FM_WAKE_WAIT_TEST_RECONCILE_DELAY" ;;
    esac
    fm_wake_stub_armed "$STATE" "$STUB_PATH" "$FM_HOME" && return 1
    after=$(stub_lock_observation)
    if [ "$before" = missing ] || [ "$before" != "$after" ]; then
      continue
    fi
    return 3
  done
  return 3
}

HOLDING=0
lock_rc=0
reconcile_stub_lock || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  if [ "$lock_rc" -eq 2 ]; then
    echo "wake delivery: FAILED - lock acquisition failed for $STUB_LOCK" >&2
    exit 1
  fi
  # Losing this lock to a HEALTHY stub of the same session is the arm path
  # succeeding, not failing: delivery is already armed, which is precisely what
  # the caller asked for.  fm_wake_stub_armed is the repo's existing owner of
  # that question - bin/fm-guard.sh and bin/fm-turnend-guard.sh both judge this
  # same state armed through it - so consulting it here is what stops one repo
  # from returning two verdicts on one state.  Reporting FAILED here was worse
  # than noise: the operating instructions treat FAILED as an alarm to clear
  # before the turn ends, this case has no remedy, and the obvious reaction -
  # kill the holder and re-arm - destroys a working delivery path.
  if [ "$lock_rc" -eq 1 ]; then
    if [ "$HOLD" -eq 0 ]; then
      echo "wake delivery: already armed pid=$FM_WAKE_STUB_ARMED_PID (same session)"
      exit 0
    fi
    # Deliberately stderr, and deliberately not the "already armed" line: this
    # process has not finished doing its job, and a caller that treats stdout as
    # the close reason must not be handed a close reason yet.
    echo "wake delivery: holding behind already-armed pid=$FM_WAKE_STUB_ARMED_PID (same session); retrying every ${REARM_POLL}s and still watching the queue" >&2
    HOLDING=1
  else
    # Anything the predicate rejects is a genuine conflict - another session,
    # another home, or a lock whose recorded identity no longer matches - and
    # stays exactly as loud as it was.
    echo "wake delivery: FAILED - another delivery stub already holds $STUB_LOCK" >&2
    exit 1
  fi
fi
if [ "$HOLDING" -eq 0 ]; then
  LOCK_OWNED=1
  publish_stub_identity || {
    echo "wake delivery: FAILED - could not record stub identity" >&2
    exit 1
  }
fi

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

# Try to take the lock back from a released holder on the shared cadence rather
# than on every poll: a takeover attempt is a lock operation, the poll is one
# second, and hammering a healthy holder's lock buys nothing.
try_takeover() {
  local rc=0
  reconcile_stub_lock || rc=$?
  case "$rc" in
    0)
      LOCK_OWNED=1
      if ! publish_stub_identity; then
        echo "wake delivery: FAILED - could not record stub identity" >&2
        exit 1
      fi
      HOLDING=0
      echo "wake delivery: took delivery over from the released holder" >&2
      ;;
    2)
      echo "wake delivery: FAILED - lock acquisition failed for $STUB_LOCK" >&2
      exit 1
      ;;
    1) ;;
    *)
      echo "wake delivery: FAILED - another delivery stub already holds $STUB_LOCK" >&2
      exit 1
      ;;
  esac
}

prev_iter=$(date +%s)
next_takeover=$((prev_iter + REARM_POLL))
# Epoch this process first saw the CURRENT queue content, cleared when it drains.
queue_since=
# 1 while the current queue content belongs to a stub this process is holding
# behind.  Set when content is first seen while still holding - never at
# start-up, where there is nothing yet to inherit - and cleared when the queue
# drains.  It deliberately outlives the hold itself: content that appeared while
# holding is still the holder's to report even after this process has taken the
# lock over, which is exactly the moment the two would otherwise both report.
INHERITED=0
while :; do
  now=$(date +%s)
  gap=$((now - prev_iter))
  prev_iter=$now
  # Give an open window back every second the host spent frozen.  The gap is
  # tracked on every iteration, window or not, so a freeze that straddles the
  # moment a window opens is measured against the right previous reading.
  #
  # Known residual, accepted deliberately: this credit has no cumulative bound.
  # On a host where the loop body ITSELF consistently exceeds FREEZE_GAP - a
  # stalled filesystem under STATE blocking the stat and /proc reads, say - the
  # deadline advances as fast as wall clock and a wedged watcher is never
  # reported.  Bounding cumulative credit would close that, but it would also
  # break the primary case this exists for, a laptop that dark-wakes several
  # times inside one open window, so the residual is kept and named instead.
  # The bound that would preserve both is a cap on cumulative credit, not on a
  # single gap.
  if [ -n "$confirm_deadline" ] && [ "$gap" -ge "$FREEZE_GAP" ]; then
    confirm_deadline=$((confirm_deadline + gap))
  fi
  if [ -s "$FM_WAKE_QUEUE" ]; then
    if [ -z "$queue_since" ]; then
      queue_since=$now
      # Content that appears while ANOTHER stub of this session owns delivery is
      # that stub's to report, and this one INHERITS it.  Without that, one wake
      # closes the holder and this process within the same second and is
      # delivered twice, and since the model arms once per delivery the doubling
      # sustains itself rather than settling.  The flag is set when the content
      # is first seen rather than at start-up, because at start-up there is no
      # content to inherit and a flag cleared then would never protect anything.
      [ "$HOLDING" -eq 1 ] && INHERITED=1
    fi
    # Inherited content is reported anyway once a takeover cadence has passed
    # with it still sitting there, which means the holder never delivered it: a
    # killed holder, or one alive but wedged.  A wrong call here costs
    # REARM_POLL seconds of latency and never a lost wake, which is the
    # direction this fleet trades in.
    if [ "$INHERITED" -eq 0 ] || [ $((now - queue_since)) -ge "$REARM_POLL" ]; then
      echo "wake: queued"
      exit 0
    fi
  else
    # The queue drained, so whoever was going to report it did.  Nothing is
    # inherited any more and this is an ordinary delivery wait from here on,
    # whether or not it has taken the lock over yet.
    queue_since=
    INHERITED=0
  fi
  if [ "$HOLDING" -eq 1 ] && [ "$now" -ge "$next_takeover" ]; then
    next_takeover=$((now + REARM_POLL))
    try_takeover
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
