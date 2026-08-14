#!/usr/bin/env bash
# Shared records and predicates for this home's external wake-delivery listener.
#
# Wake delivery used to be a waiter the primary session itself held: a harness
# background task, a foreground checkpoint, or a plugin-owned job.  Every one of
# those is an object the harness owns and can destroy, and both measured causes
# of delivery death destroyed exactly that class of object.  The listener now
# lives outside the harness entirely, supervised the way bin/fm-watch.sh is, and
# this file owns the three records that make it observable from outside:
#
#   state/.delivery.lock       who is listening, in the same identity-matched
#                              shape as state/.watch.lock
#   state/.last-delivery-beat  touched at the top of every cycle, BEFORE that
#                              cycle's work, so a beacon inside the grace proves
#                              the loop is turning rather than that it finished
#   state/.primary-endpoint    where the model turn lives, published by the
#                              locked session because only the session can see
#                              its own pane
#
# THE DEFECT THIS FILE EXISTS TO PREVENT.  A listener that is not running and a
# listener with nothing to deliver both produce silence, and silence is what the
# old waiter's death looked like too.  If the only observable is "no wake
# arrived", the fleet cannot tell a healthy quiet fleet from a dead listener,
# and the failure this work removes would simply move house.  So the outside
# view is never a boolean: fm_delivery_report classifies the listener, the
# endpoint, and the queue into one named verdict, and every not-delivering
# verdict names its own cause.  tests/fm-delivery.test.sh feeds each bad
# condition in deliberately and requires the matching verdict back.
#
# The durable wake queue remains the single source of truth for what is pending.
# Nothing here stores a second copy of it; the listener only observes it and
# submits, and only a model turn running bin/fm-wake-drain.sh consumes it.

FM_DELIVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${FM_WAKE_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_DELIVERY_LIB_DIR/fm-wake-lib.sh"
fi

# Seconds a delivery beacon may age before the listener is read as stalled.
# Shared with the watcher's grace on purpose: one fleet, one staleness bar.
FM_DELIVERY_GRACE_DEFAULT=${FM_DELIVERY_GRACE:-${FM_GUARD_GRACE:-300}}

fm_delivery_lock_matches_pid() {  # <state> <delivery-path> <pid> [home]
  local state=$1 delivery_path=$2 pid=$3 home=${4:-$FM_HOME}
  local lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.delivery.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/delivery-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$delivery_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

# The single owner of the listener-health predicate, deliberately shaped like
# fm_watcher_healthy so the two services are judged by one idea of health.
# FM_DELIVERY_HEALTH classifies WHY an unhealthy listener is unhealthy:
#   healthy       a live, identity-matched listener whose beacon is inside grace
#   beacon-stale  a live, identity-matched listener whose beacon has aged out
#   dead          no live, identity-matched listener process at all
# The pid and identity conditions survive a host suspend while the beacon cannot,
# so the beacon-stale case is the one a resumed machine leaves behind and must
# not be reported as a death.
FM_DELIVERY_HEALTHY_PID=
FM_DELIVERY_LIVE_PID=
FM_DELIVERY_HEALTH=
fm_delivery_healthy() {  # <state> <delivery-path> [grace] [home]
  local state=$1 delivery_path=$2 grace=${3:-$FM_DELIVERY_GRACE_DEFAULT} home=${4:-$FM_HOME}
  local lockdir beat pid age
  FM_DELIVERY_HEALTHY_PID=
  FM_DELIVERY_LIVE_PID=
  FM_DELIVERY_HEALTH=dead
  lockdir="$state/.delivery.lock"
  beat="$state/.last-delivery-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_delivery_lock_matches_pid "$state" "$delivery_path" "$pid" "$home" || return 1
  FM_DELIVERY_LIVE_PID=$pid
  age=$(fm_path_age "$beat")
  if [ "$age" -ge "$grace" ]; then
    FM_DELIVERY_HEALTH=beacon-stale
    return 1
  fi
  FM_DELIVERY_HEALTH=healthy
  FM_DELIVERY_HEALTHY_PID=$pid
  return 0
}

# --- the primary endpoint record --------------------------------------------
# The listener runs under a service manager with no session context at all, so
# unlike the away daemon it cannot discover the captain's pane from its own
# environment.  The locked session publishes it instead, and records the session
# lock pid alongside so a record left behind by an exited session is a STATED
# stale condition rather than an address the listener types into blind.

fm_delivery_endpoint_path() {  # <state>
  printf '%s/.primary-endpoint\n' "$1"
}

fm_delivery_endpoint_write() {  # <state> <backend> <target> <harness> <session-lock-pid>
  local state=$1 backend=$2 target=$3 harness=$4 session=$5 record tmp
  record=$(fm_delivery_endpoint_path "$state")
  [ -n "$backend" ] && [ -n "$target" ] || return 2
  case "$backend$target$harness$session" in
    *$'\n'*|*$'\r'*) return 2 ;;
  esac
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'backend=%s\n' "$backend"
    printf 'target=%s\n' "$target"
    printf 'harness=%s\n' "${harness:-unknown}"
    printf 'session-lock-pid=%s\n' "$session"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  chmod 600 "$record" 2>/dev/null || true
}

FM_DELIVERY_ENDPOINT_BACKEND=
FM_DELIVERY_ENDPOINT_TARGET=
FM_DELIVERY_ENDPOINT_HARNESS=
FM_DELIVERY_ENDPOINT_SESSION=
fm_delivery_endpoint_read() {  # <state>
  local state=$1 record line key value
  FM_DELIVERY_ENDPOINT_BACKEND=
  FM_DELIVERY_ENDPOINT_TARGET=
  FM_DELIVERY_ENDPOINT_HARNESS=
  FM_DELIVERY_ENDPOINT_SESSION=
  record=$(fm_delivery_endpoint_path "$state")
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    case "$key" in
      backend) FM_DELIVERY_ENDPOINT_BACKEND=$value ;;
      target) FM_DELIVERY_ENDPOINT_TARGET=$value ;;
      harness) FM_DELIVERY_ENDPOINT_HARNESS=$value ;;
      session-lock-pid) FM_DELIVERY_ENDPOINT_SESSION=$value ;;
    esac
  done < "$record"
  [ -n "$FM_DELIVERY_ENDPOINT_BACKEND" ] && [ -n "$FM_DELIVERY_ENDPOINT_TARGET" ]
}

# Classify the endpoint record without touching the pane, so a caller can name
# the concrete reason delivery cannot happen:
#   ok              a well-formed record whose session still holds the fleet lock
#   absent          no session has published where the model turn lives
#   malformed       a record exists but carries no usable backend/target pair
#   stale-session   the session that published it is not the one holding the
#                   lock now, so its pane is somebody else's or nobody's
FM_DELIVERY_ENDPOINT_STATUS=
fm_delivery_endpoint_status() {  # <state>
  local state=$1 record current
  record=$(fm_delivery_endpoint_path "$state")
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    FM_DELIVERY_ENDPOINT_STATUS=absent
    return 1
  fi
  if ! fm_delivery_endpoint_read "$state"; then
    FM_DELIVERY_ENDPOINT_STATUS=malformed
    return 1
  fi
  current=$(cat "$state/.lock" 2>/dev/null || true)
  if [ -z "$FM_DELIVERY_ENDPOINT_SESSION" ] || [ "$FM_DELIVERY_ENDPOINT_SESSION" != "$current" ]; then
    FM_DELIVERY_ENDPOINT_STATUS=stale-session
    return 1
  fi
  FM_DELIVERY_ENDPOINT_STATUS=ok
  return 0
}

fm_delivery_queue_depth() {  # <state>
  local queue=$1/.wake-queue
  [ -s "$queue" ] || { printf '0\n'; return; }
  wc -l < "$queue" | tr -d ' '
}

fm_delivery_attempt_outcome_path() {  # <state>
  printf '%s/.delivery-attempt-outcome\n' "$1"
}

fm_delivery_attempt_outcome_clear() {  # <state>
  rm -f "$(fm_delivery_attempt_outcome_path "$1")"
}

fm_delivery_attempt_outcome_write_blocked() {  # <state> <reason>
  local state=$1 reason=$2 record tmp
  record=$(fm_delivery_attempt_outcome_path "$state")
  case "$reason" in
    ''|*$'\n'*|*$'\r'*) return 2 ;;
  esac
  [ "${#reason}" -le 1024 ] || reason=${reason:0:1024}
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$record.XXXXXX") || return 1
  printf 'blocked=%s\n' "$reason" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  chmod 600 "$record" 2>/dev/null || true
}

FM_DELIVERY_ATTEMPT_REASON=
fm_delivery_attempt_outcome_read_blocked() {  # <state>
  local record line extra
  FM_DELIVERY_ATTEMPT_REASON=
  record=$(fm_delivery_attempt_outcome_path "$1")
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  IFS= read -r line < "$record" || return 1
  IFS= read -r extra < <(tail -n +2 "$record") || true
  [ -z "$extra" ] || return 1
  case "$line" in
    blocked=?*) FM_DELIVERY_ATTEMPT_REASON=${line#blocked=} ;;
    *) return 1 ;;
  esac
  [ "${#FM_DELIVERY_ATTEMPT_REASON}" -le 1024 ]
}

# --- the outside view --------------------------------------------------------
# One line, one verdict, and never a bare silence.  Print it wherever a human or
# an agent asks whether wakes are being delivered; the verdict word is stable and
# machine-readable, and the remainder of the line names the cause.
#
# Verdicts:
#   idle           listening, nothing pending - the ONLY healthy silence
#   delivering     listening, wakes pending, submitting to the model turn
#   undeliverable  listening, wakes pending, but something concrete blocks the
#                  submit; the reason follows
#   away           the away daemon owns delivery under the /afk contract, so the
#                  listener deliberately stands down
#   stalled        a live listener whose beacon aged out
#   down           no live identity-matched listener at all
#
fm_delivery_report() {  # <state> <delivery-path> [grace] [home]
  local state=$1 delivery_path=$2 grace=${3:-$FM_DELIVERY_GRACE_DEFAULT} home=${4:-$FM_HOME}
  local depth age reason
  depth=$(fm_delivery_queue_depth "$state")
  if ! fm_delivery_healthy "$state" "$delivery_path" "$grace" "$home"; then
    age=$(fm_path_age "$state/.last-delivery-beat")
    if [ "$FM_DELIVERY_HEALTH" = beacon-stale ]; then
      printf 'stalled: delivery listener pid %s is alive but its beacon is %ss old (grace %ss); %s wake(s) pending\n' \
        "$FM_DELIVERY_LIVE_PID" "$age" "$grace" "$depth"
      return 1
    fi
    printf 'down: no live identity-matched delivery listener for this home (last beat %ss ago); %s wake(s) pending\n' \
      "$age" "$depth"
    return 1
  fi
  if [ -e "$state/.afk" ]; then
    printf 'away: listener pid %s is up and standing down because away mode owns delivery; %s wake(s) pending\n' \
      "$FM_DELIVERY_HEALTHY_PID" "$depth"
    return 0
  fi
  if [ "$depth" -eq 0 ]; then
    printf 'idle: listener pid %s is up and the durable queue is empty\n' "$FM_DELIVERY_HEALTHY_PID"
    return 0
  fi
  if ! fm_delivery_endpoint_status "$state"; then
    case "$FM_DELIVERY_ENDPOINT_STATUS" in
      absent) reason='no session has published where the model turn lives' ;;
      malformed) reason='the published endpoint record carries no usable address' ;;
      stale-session) reason='the endpoint was published by a session that no longer holds the fleet lock' ;;
      *) reason="the endpoint is unusable ($FM_DELIVERY_ENDPOINT_STATUS)" ;;
    esac
    printf 'undeliverable: listener pid %s is up with %s wake(s) pending, but %s\n' \
      "$FM_DELIVERY_HEALTHY_PID" "$depth" "$reason"
    return 1
  fi
  if fm_delivery_attempt_outcome_read_blocked "$state"; then
    printf 'undeliverable: listener pid %s is up with %s wake(s) pending, but %s\n' \
      "$FM_DELIVERY_HEALTHY_PID" "$depth" "$FM_DELIVERY_ATTEMPT_REASON"
    return 1
  fi
  printf 'delivering: listener pid %s is up with %s wake(s) pending for %s pane %s (%s)\n' \
    "$FM_DELIVERY_HEALTHY_PID" "$depth" "$FM_DELIVERY_ENDPOINT_BACKEND" "$FM_DELIVERY_ENDPOINT_TARGET" \
    "${FM_DELIVERY_ENDPOINT_HARNESS:-unknown harness}"
  return 0
}
