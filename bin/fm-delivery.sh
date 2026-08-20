#!/usr/bin/env bash
# This home's external wake-delivery listener: the process that turns a pending
# durable wake into a model turn.  bin/fm-delivery-service.sh owns launching and
# supervising it; docs/wake-delivery.md owns the contract this implements.
#
# Usage:
#   fm-delivery.sh            long-lived loop (how the service runs it)
#   fm-delivery.sh --once     run exactly one cycle and exit (tests, probes)
#   fm-delivery.sh --report   print this home's one-line delivery verdict
#
# WHY IT IS NOT IN THE HARNESS.  Delivery used to be a waiter the primary
# session held as one of its own objects, and an object the harness owns is an
# object the harness can destroy: 101 of 101 observed listener deaths matched
# the harness reaper's idle precondition, and the independent keystroke channel
# killed the same object by hand.  The watcher service has never been reaped
# because systemd, not the harness, owns it.  This process is the delivery half
# moved into that same domain, so a session now holds no delivery object at all.
#
# WHAT IT DOES NOT OWN.  state/.wake-queue stays the single source of truth for
# what is pending.  This loop only OBSERVES the queue; it never writes it, never
# consumes it, and keeps no second copy.  Only a model turn running
# bin/fm-wake-drain.sh removes a record, which is exactly why the retry below is
# a retry-until-drained rather than a fire-and-forget: the queue emptying is the
# only evidence a submit actually became a turn.
#
# AWAY MODE.  While state/.afk exists, bin/fm-supervise-daemon.sh owns delivery
# under the /afk contract and this loop deliberately stands down rather than
# injecting a second message into the same composer.  It keeps beating, so
# standing down still reads as "up and holding" from outside and never as death.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared pre-typing pane reads, identical to the ones the away daemon takes.
# shellcheck source=bin/fm-pane-activity-lib.sh
. "$SCRIPT_DIR/fm-pane-activity-lib.sh"

DELIVERY_PATH="$SCRIPT_DIR/fm-delivery.sh"
DELIVERY_LOCK="$STATE/.delivery.lock"
BEAT="$STATE/.last-delivery-beat"
LOG="$STATE/.delivery.log"
GRACE=${FM_DELIVERY_GRACE:-${FM_GUARD_GRACE:-300}}
POLL=${FM_DELIVERY_POLL:-2}
# Seconds between submits while the same wakes are still pending.  A submitted
# wake becomes a model turn that has to run before it can drain, so resubmitting
# faster than a turn takes would type a second message into a composer whose
# first message is still being worked - the doubling failure the away daemon
# already learned.  Long enough for an ordinary turn, short enough that a submit
# swallowed by a transient busy pane is retried while the captain is still awake.
RETRY=${FM_DELIVERY_RETRY:-45}
# Seconds before retrying after a DEFERRAL rather than a submit.  A deferral is
# a pane read that said "not now" - busy, unsubmitted text, no endpoint - and
# re-reading the pane every poll while a captain types buys nothing and costs a
# capture per second.  Much shorter than the post-submit retry, because a
# deferral means nothing was delivered and the wake is still waiting.
DEFER=${FM_DELIVERY_DEFER:-10}
SUBMIT_RETRIES=${FM_DELIVERY_SUBMIT_RETRIES:-3}
SUBMIT_SLEEP=${FM_DELIVERY_SUBMIT_SLEEP:-0.5}
LOG_MAX_BYTES=${FM_DELIVERY_LOG_MAX_BYTES:-262144}
LOG_KEEP_LINES=${FM_DELIVERY_LOG_KEEP_LINES:-500}
# Backends this listener has verified composer and submit primitives for, the
# same pair bin/fm-supervise-daemon.sh restricts itself to.  Anything else
# refuses by name instead of running tmux primitives against a pane that is not
# a tmux pane.
SUPPORTED_BACKENDS="tmux herdr"

case "${POLL}" in ''|*[!0-9.]*) POLL=2 ;; esac
case "${RETRY}" in ''|*[!0-9]*) RETRY=45 ;; esac
case "${DEFER}" in ''|*[!0-9]*) DEFER=10 ;; esac

MODE=loop
case "${1:-}" in
  '') ;;
  --once) MODE=once ;;
  --report) MODE=report ;;
  -h|--help)
    sed -n '2,26p' "$DELIVERY_PATH" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: $(basename "$0") [--once|--report]" >&2
    exit 2
    ;;
esac

if [ "$MODE" = report ]; then
  fm_delivery_report "$STATE" "$DELIVERY_PATH" "$GRACE" "$FM_HOME"
  exit $?
fi

log() {  # <message>
  local size
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || true
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return ;; esac
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.trim" 2>/dev/null \
      && mv -f "$LOG.trim" "$LOG" 2>/dev/null || rm -f "$LOG.trim" 2>/dev/null || true
  fi
}

# Say a thing once per distinct condition rather than once per poll: a listener
# that cannot deliver logs the reason when it starts and when it changes, so the
# log stays a record of what happened rather than a per-second transcript of one
# unchanged fact.  The state itself is always readable through --report, so
# collapsing repeats here costs no observability.
LAST_CONDITION=
log_condition() {  # <condition-key> <message>
  [ "$1" = "$LAST_CONDITION" ] && return 0
  LAST_CONDITION=$1
  log "$2"
}

# The one message this listener submits.  Its body is deliberately the
# instruction and not the wake content: the durable queue is the source of
# truth, and a body that summarised the queue would be a second copy that could
# disagree with it.
delivery_body() {  # <queue-depth>
  printf 'Wake delivery: %s wake record(s) are pending in the durable queue. Run bin/fm-wake-drain.sh now, before reading anything else or composing a reply, and handle what it returns.' "$1"
}

# Attempt one submit.  Prints nothing; returns 0 when the backend confirmed the
# submit, and sets SUBMIT_REASON to the concrete blocker otherwise so the caller
# can name it rather than falling silent.
SUBMIT_REASON=
attempt_submit() {  # <backend> <target> <tmux-server> <queue-depth>
  local backend=$1 target=$2 tmux_server=$3 depth=$4 composer verdict encoded body
  SUBMIT_REASON=
  if ! fm_backend_list_contains "$SUPPORTED_BACKENDS" "$backend"; then
    SUBMIT_REASON="the published endpoint names backend '$backend', which this listener has no verified composer primitives for"
    return 1
  fi
  if [ "$backend" = tmux ]; then
    if ! fm_delivery_tmux_server_valid "$tmux_server"; then
      SUBMIT_REASON="the published tmux endpoint carries no provable server identity; a pane id alone is ambiguous"
      return 1
    fi
    local FM_TMUX_SERVER_IDENTITY=$tmux_server
    export FM_TMUX_SERVER_IDENTITY
  fi
  if fm_backend_target_exists "$backend" "$target"; then
    :
  else
    case $? in
      1) SUBMIT_REASON="the published pane $target no longer exists" ;;
      125) SUBMIT_REASON="the published tmux server identity does not match the server at its recorded socket" ;;
      126) SUBMIT_REASON="the published tmux server could not be verified" ;;
      *) SUBMIT_REASON="the published pane $target could not be verified" ;;
    esac
    return 1
  fi
  if pane_is_busy "$target" "$backend"; then
    SUBMIT_REASON="the session pane is mid-turn; delivery waits rather than typing into a working agent"
    return 1
  fi
  # Only an affirmatively empty GENUINE agent composer is a safe target.  The
  # shared classifier reports 'pending' for real unsubmitted text - a half-typed
  # captain line, or a previous submit whose Enter was swallowed - and 'unknown'
  # for a bare dead-shell prompt or an unreadable pane.  Typing into either of
  # the last two would merge with the captain's text or hand a shell a command.
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    case "$composer" in
      pending) SUBMIT_REASON="the session composer holds unsubmitted text; delivery waits rather than merging with it" ;;
      server-mismatch) SUBMIT_REASON="the published tmux server identity does not match the server at its recorded socket" ;;
      server-unverifiable) SUBMIT_REASON="the published tmux server could not be verified" ;;
      *) SUBMIT_REASON="the session composer could not be confirmed empty (state=${composer:-unknown}: dead shell prompt or unreadable pane)" ;;
    esac
    return 1
  fi
  body=$(delivery_body "$depth")
  if ! fm_operational_input_encode watcher "$body" encoded; then
    SUBMIT_REASON="the delivery message could not be encoded"
    return 1
  fi
  # Type once, then confirm.  Never retype: a swallowed Enter leaves the text in
  # the composer, and a second copy typed on top of it concatenates into one
  # corrupted turn.  The backend primitive retries the Enter alone.
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$SUBMIT_RETRIES" "$SUBMIT_SLEEP" "$SUBMIT_SLEEP")
  if [ "$verdict" = empty ]; then
    return 0
  fi
  if [ "$verdict" = server-mismatch ]; then
    SUBMIT_REASON="the published tmux server identity does not match the server at its recorded socket"
    return 1
  fi
  if [ "$verdict" = server-unverifiable ]; then
    SUBMIT_REASON="the published tmux server could not be verified"
    return 1
  fi
  SUBMIT_REASON="the submit was not confirmed (verdict=${verdict:-unknown}); the text may be sitting in the composer"
  return 1
}

LAST_SUBMIT=0
LAST_DEFER=0
cycle() {
  local depth now reason
  touch "$BEAT" 2>/dev/null || true
  depth=$(fm_delivery_queue_depth "$STATE")
  if [ "$depth" -eq 0 ]; then
    fm_delivery_attempt_outcome_clear "$STATE"
  fi
  if [ -e "$STATE/.afk" ]; then
    log_condition away "standing down: away mode owns delivery ($depth pending)"
    return 0
  fi
  if [ "$depth" -eq 0 ]; then
    log_condition idle 'idle: the durable queue is empty'
    LAST_SUBMIT=0
    LAST_DEFER=0
    return 0
  fi
  if ! fm_delivery_endpoint_status "$STATE"; then
    reason=$(fm_delivery_endpoint_reason "$FM_DELIVERY_ENDPOINT_STATUS")
    log_condition "endpoint:$FM_DELIVERY_ENDPOINT_STATUS" \
      "undeliverable: $depth wake(s) pending but $reason"
    return 0
  fi
  now=$(date +%s)
  if [ "$LAST_SUBMIT" -ne 0 ] && [ $((now - LAST_SUBMIT)) -lt "$RETRY" ]; then
    log_condition submitted "submitted: $depth wake(s) pending, waiting up to ${RETRY}s for the turn to drain them"
    return 0
  fi
  if [ "$LAST_DEFER" -ne 0 ] && [ $((now - LAST_DEFER)) -lt "$DEFER" ]; then
    return 0
  fi
  if attempt_submit "$FM_DELIVERY_ENDPOINT_BACKEND" "$FM_DELIVERY_ENDPOINT_TARGET" \
      "$FM_DELIVERY_ENDPOINT_TMUX_SERVER" "$depth"; then
    fm_delivery_attempt_outcome_clear "$STATE"
    LAST_SUBMIT=$now
    LAST_DEFER=0
    LAST_CONDITION=
    log "delivered: submitted $depth wake(s) to $FM_DELIVERY_ENDPOINT_BACKEND pane $FM_DELIVERY_ENDPOINT_TARGET"
    return 0
  fi
  LAST_DEFER=$now
  log_condition "blocked:$SUBMIT_REASON" "undeliverable: $depth wake(s) pending but $SUBMIT_REASON"
  # Publish the outside-visible verdict only after its audit record exists.
  # Report readers may observe the outcome immediately after its atomic rename.
  fm_delivery_attempt_outcome_write_blocked "$STATE" "$SUBMIT_REASON" || true
  return 0
}

if [ "$MODE" = once ]; then
  cycle
  exit 0
fi

lock_rc=0
fm_lock_try_acquire "$DELIVERY_LOCK" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  if [ "$lock_rc" -eq 2 ]; then
    echo "delivery: lock acquisition failed for $DELIVERY_LOCK" >&2
    exit 1
  fi
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    echo "delivery: already running pid $FM_LOCK_HELD_PID"
  else
    echo "delivery: already running"
  fi
  exit 0
fi

DELIVERY_PID=${BASHPID:-$$}
delivery_cleanup() {
  fm_lock_release "$DELIVERY_LOCK"
}
trap delivery_cleanup EXIT
trap 'exit 1' HUP INT TERM

printf '%s\n' "$FM_HOME" > "$DELIVERY_LOCK/fm-home" || true
printf '%s\n' "$DELIVERY_PATH" > "$DELIVERY_LOCK/delivery-path" || true
fm_pid_identity "$DELIVERY_PID" > "$DELIVERY_LOCK/pid-identity" 2>/dev/null || true
printf '%s\n' "${FM_DELIVERY_MANAGER:-session}" > "$DELIVERY_LOCK/manager" || true
printf '%s\n' "${FM_DELIVERY_SOURCE_VERSION:-unknown}" > "$DELIVERY_LOCK/source-version" || true
printf '%s\n' "${FM_DELIVERY_SERVICE_PATH:-}" > "$DELIVERY_LOCK/service-path" || true

log "listener up: pid $DELIVERY_PID, manager ${FM_DELIVERY_MANAGER:-session}, poll ${POLL}s, retry ${RETRY}s"

while :; do
  # A second listener taking the lock means this one is a duplicate; stand down
  # so the rightful singleton continues alone.  The release in the EXIT trap
  # no-ops because the lock no longer names this pid.
  if [ "$(cat "$DELIVERY_LOCK/pid" 2>/dev/null || true)" != "$DELIVERY_PID" ]; then
    exit 0
  fi
  cycle
  sleep "$POLL"
done
