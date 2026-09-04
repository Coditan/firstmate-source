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
# view is never a boolean: fm_delivery_classify classifies the listener, the
# endpoint, and the queue into one named verdict, every not-delivering verdict
# names its own cause, and the prose line and the machine key=value line are
# two renderings of that one classification.  tests/fm-delivery.test.sh feeds
# each bad condition in deliberately and requires the matching verdict back;
# tests/fm-delivery-status-contract.test.sh holds the machine line's contract.
#
# The durable wake queue remains the single source of truth for what is pending.
# Nothing here stores a second copy of it; the listener only observes it and
# submits, and only a model turn running bin/fm-wake-drain.sh consumes it.

FM_DELIVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${FM_WAKE_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_DELIVERY_LIB_DIR/fm-wake-lib.sh"
fi

if ! declare -F fm_session_lock_record_read >/dev/null 2>&1; then
  # shellcheck source=bin/fm-harness-pid-lib.sh
  . "$FM_DELIVERY_LIB_DIR/fm-harness-pid-lib.sh"
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

fm_delivery_tmux_server_valid() {  # <socket-path,server-pid>
  local identity=${1:-} socket pid
  socket=${identity%,*}
  pid=${identity##*,}
  [ "$socket" != "$identity" ] && [ -n "$socket" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null
}

fm_delivery_endpoint_write() {  # <state> <backend> <target> <harness> <session-lock-pid> [tmux-server]
  local state=$1 backend=$2 target=$3 harness=$4 session=$5 tmux_server=${6:-} record tmp
  record=$(fm_delivery_endpoint_path "$state")
  [ -n "$backend" ] && [ -n "$target" ] || return 2
  case "$backend$target$harness$session$tmux_server" in
    *$'\n'*|*$'\r'*) return 2 ;;
  esac
  if [ "$backend" = tmux ]; then
    fm_delivery_tmux_server_valid "$tmux_server" || return 2
  fi
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'backend=%s\n' "$backend"
    printf 'target=%s\n' "$target"
    printf 'harness=%s\n' "${harness:-unknown}"
    printf 'session-lock-pid=%s\n' "$session"
    if [ "$backend" = tmux ]; then
      printf 'tmux-server=%s\n' "$tmux_server"
    fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  chmod 600 "$record" 2>/dev/null || true
}

FM_DELIVERY_ENDPOINT_BACKEND=
FM_DELIVERY_ENDPOINT_TARGET=
FM_DELIVERY_ENDPOINT_HARNESS=
FM_DELIVERY_ENDPOINT_SESSION=
FM_DELIVERY_ENDPOINT_TMUX_SERVER=
fm_delivery_endpoint_read() {  # <state>
  local state=$1 record line key value
  FM_DELIVERY_ENDPOINT_BACKEND=
  FM_DELIVERY_ENDPOINT_TARGET=
  FM_DELIVERY_ENDPOINT_HARNESS=
  FM_DELIVERY_ENDPOINT_SESSION=
  FM_DELIVERY_ENDPOINT_TMUX_SERVER=
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
      tmux-server) FM_DELIVERY_ENDPOINT_TMUX_SERVER=$value ;;
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
#   unproven-server a tmux endpoint carries no valid server identity, so its
#                   pane id is ambiguous across servers on the same machine
FM_DELIVERY_ENDPOINT_STATUS=
fm_delivery_endpoint_status() {  # <state>
  local state=$1 record
  record=$(fm_delivery_endpoint_path "$state")
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    FM_DELIVERY_ENDPOINT_STATUS=absent
    return 1
  fi
  if ! fm_delivery_endpoint_read "$state"; then
    FM_DELIVERY_ENDPOINT_STATUS=malformed
    return 1
  fi
  if [ "$FM_DELIVERY_ENDPOINT_BACKEND" = tmux ] \
     && ! fm_delivery_tmux_server_valid "$FM_DELIVERY_ENDPOINT_TMUX_SERVER"; then
    FM_DELIVERY_ENDPOINT_STATUS=unproven-server
    return 1
  fi
  fm_session_lock_record_read "$state/.lock" || true
  if [ -z "$FM_DELIVERY_ENDPOINT_SESSION" ] || [ "$FM_DELIVERY_ENDPOINT_SESSION" != "$FM_LOCK_RECORD_PID" ]; then
    FM_DELIVERY_ENDPOINT_STATUS=stale-session
    return 1
  fi
  FM_DELIVERY_ENDPOINT_STATUS=ok
  return 0
}

# The one place a status becomes a sentence.  Both readers of the classifier -
# the public verdict and the listener's own log - print the same words for the
# same condition, so a new status cannot be legible in one and a bare label in
# the other.
fm_delivery_endpoint_reason() {  # <status>
  case "$1" in
    absent) printf 'no session has published where the model turn lives\n' ;;
    malformed) printf 'the published endpoint record carries no usable address\n' ;;
    stale-session) printf 'the endpoint was published by a session that no longer holds the fleet lock\n' ;;
    unproven-server) printf 'the published tmux endpoint carries no provable server identity; a pane id alone is ambiguous\n' ;;
    *) printf 'the endpoint is unusable (%s)\n' "$1" ;;
  esac
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

# The record is one `blocked=<prose>` line, optionally followed by one
# `reason=<token>` line carrying the same cause as a single machine token from
# the reason vocabulary below.  The token travels with the prose from the moment
# the listener records the blocker, so the machine verdict never has to be
# reverse-engineered from a sentence, which is the two-repository prose match
# the machine line exists to retire.
fm_delivery_reason_token_valid() {  # <token>
  case "${1:-}" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

fm_delivery_attempt_outcome_write_blocked() {  # <state> <reason> [reason-token]
  local state=$1 reason=$2 token=${3:-} record tmp
  record=$(fm_delivery_attempt_outcome_path "$state")
  case "$reason" in
    ''|*$'\n'*|*$'\r'*) return 2 ;;
  esac
  if [ -n "$token" ] && ! fm_delivery_reason_token_valid "$token"; then
    return 2
  fi
  [ "${#reason}" -le 1024 ] || reason=${reason:0:1024}
  mkdir -p "$state" || return 1
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'blocked=%s\n' "$reason"
    [ -z "$token" ] || printf 'reason=%s\n' "$token"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  chmod 600 "$record" 2>/dev/null || true
}

FM_DELIVERY_ATTEMPT_REASON=
FM_DELIVERY_ATTEMPT_REASON_TOKEN=
fm_delivery_attempt_outcome_read_blocked() {  # <state>
  local record line extra rest
  FM_DELIVERY_ATTEMPT_REASON=
  FM_DELIVERY_ATTEMPT_REASON_TOKEN=
  record=$(fm_delivery_attempt_outcome_path "$1")
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  IFS= read -r line < "$record" || return 1
  IFS= read -r extra < <(tail -n +2 "$record") || true
  IFS= read -r rest < <(tail -n +3 "$record") || true
  [ -z "$rest" ] || return 1
  case "$extra" in
    '') ;;
    reason=?*)
      fm_delivery_reason_token_valid "${extra#reason=}" || return 1
      FM_DELIVERY_ATTEMPT_REASON_TOKEN=${extra#reason=}
      ;;
    *) return 1 ;;
  esac
  case "$line" in
    blocked=?*) FM_DELIVERY_ATTEMPT_REASON=${line#blocked=} ;;
    *) return 1 ;;
  esac
  [ "${#FM_DELIVERY_ATTEMPT_REASON}" -le 1024 ]
}

# --- the outside view --------------------------------------------------------
# One line, one verdict, and never a bare silence.  Print it wherever a human or
# an agent asks whether wakes are being delivered.  The verdict vocabulary and
# the exit status each verdict carries are defined HERE and nowhere else: the
# prose line (fm_delivery_report) and the machine line
# (fm_delivery_report_machine) are two renderings of one classification
# (fm_delivery_classify), so they cannot drift apart.  docs/wake-delivery.md
# "Machine-readable status contract" is the consumer-facing statement of the
# machine line, and tests/fm-delivery-status-contract.test.sh holds it.
#
# Verdicts (exit status in brackets):
#   idle           [0] listening, nothing pending - the ONLY healthy silence
#   delivering     [0] listening, wakes pending, submitting to the model turn
#   away           [0] the away daemon owns delivery under the /afk contract,
#                      so the listener deliberately stands down
#   undeliverable  [1] listening, wakes pending, but something concrete blocks
#                      the submit; the reason names it
#   stalled        [1] a live listener whose beacon aged out
#   down           [1] no live identity-matched listener at all
#
# Reason tokens (the machine line's `reason=`; empty for idle and delivering):
#   afk                       away: state/.afk is present
#   beacon-stale              stalled: the beacon aged past the grace
#   listener-dead             down: no live identity-matched listener
#   endpoint-absent           undeliverable: no endpoint has been published
#   endpoint-malformed        undeliverable: the endpoint record has no address
#   endpoint-stale-session    undeliverable: published by a session that no
#                             longer holds the fleet lock
#   endpoint-unproven-server  undeliverable: a tmux endpoint with no provable
#                             server identity
#   backend-unsupported       undeliverable: the listener has no verified
#                             composer primitives for the published backend
#   pane-missing              undeliverable: the published pane no longer exists
#   pane-unverified           undeliverable: the published pane could not be
#                             verified
#   server-mismatch           undeliverable: the tmux server at the recorded
#                             socket is not the recorded server
#   server-unverifiable       undeliverable: the tmux server could not be
#                             verified
#   mid-turn                  undeliverable: the session pane is mid-turn, so
#                             delivery waits; the one blocker that is a wait
#                             rather than a fault
#   composer-pending          undeliverable: the composer holds unsubmitted text
#   composer-unknown          undeliverable: the composer could not be
#                             confirmed empty
#   encode-failed             undeliverable: the delivery message could not be
#                             encoded
#   submit-unconfirmed        undeliverable: the submit was typed but never
#                             confirmed
#   attempt-blocked           undeliverable: a blocked-attempt record written
#                             before tokens existed, carrying prose only
#
# shellcheck disable=SC2034 # Read by sourcing callers and by tests/fm-delivery-status-contract.test.sh.
FM_DELIVERY_VERDICTS='idle delivering away undeliverable stalled down'

fm_delivery_verdict_exit() {  # <verdict> -> prints 0 or 1; returns 2 for a non-verdict
  case "${1:-}" in
    idle|delivering|away) printf '0\n' ;;
    undeliverable|stalled|down) printf '1\n' ;;
    *) return 2 ;;
  esac
}

# The endpoint classifier's own status names double as the reason tokens for
# the endpoint-blocked case, prefixed so a consumer can tell an endpoint fault
# from a pane or server fault without knowing which function produced it.
fm_delivery_endpoint_reason_token() {  # <status>
  case "${1:-}" in
    absent|malformed|stale-session|unproven-server) printf 'endpoint-%s\n' "$1" ;;
    *) printf 'endpoint-unusable\n' ;;
  esac
}

# The single classification both renderers read.  Returns the verdict's exit
# status and leaves every field a renderer needs in FM_DELIVERY_VERDICT_*.
FM_DELIVERY_VERDICT=
FM_DELIVERY_VERDICT_PID=
FM_DELIVERY_VERDICT_PENDING=
FM_DELIVERY_VERDICT_BEACON_AGE=
FM_DELIVERY_VERDICT_GRACE=
FM_DELIVERY_VERDICT_BACKEND=
FM_DELIVERY_VERDICT_TARGET=
FM_DELIVERY_VERDICT_HARNESS=
FM_DELIVERY_VERDICT_REASON=
FM_DELIVERY_VERDICT_REASON_TEXT=
fm_delivery_classify() {  # <state> <delivery-path> [grace] [home]
  local state=$1 delivery_path=$2 grace=${3:-$FM_DELIVERY_GRACE_DEFAULT} home=${4:-$FM_HOME}
  FM_DELIVERY_VERDICT=
  FM_DELIVERY_VERDICT_PID=
  FM_DELIVERY_VERDICT_PENDING=$(fm_delivery_queue_depth "$state")
  FM_DELIVERY_VERDICT_BEACON_AGE=$(fm_path_age "$state/.last-delivery-beat")
  FM_DELIVERY_VERDICT_GRACE=$grace
  FM_DELIVERY_VERDICT_BACKEND=
  FM_DELIVERY_VERDICT_TARGET=
  FM_DELIVERY_VERDICT_HARNESS=
  FM_DELIVERY_VERDICT_REASON=
  FM_DELIVERY_VERDICT_REASON_TEXT=
  if ! fm_delivery_healthy "$state" "$delivery_path" "$grace" "$home"; then
    if [ "$FM_DELIVERY_HEALTH" = beacon-stale ]; then
      FM_DELIVERY_VERDICT=stalled
      FM_DELIVERY_VERDICT_PID=$FM_DELIVERY_LIVE_PID
      FM_DELIVERY_VERDICT_REASON=beacon-stale
      return 1
    fi
    FM_DELIVERY_VERDICT=down
    FM_DELIVERY_VERDICT_REASON=listener-dead
    return 1
  fi
  FM_DELIVERY_VERDICT_PID=$FM_DELIVERY_HEALTHY_PID
  if [ -e "$state/.afk" ]; then
    FM_DELIVERY_VERDICT=away
    FM_DELIVERY_VERDICT_REASON=afk
    return 0
  fi
  if [ "$FM_DELIVERY_VERDICT_PENDING" -eq 0 ]; then
    FM_DELIVERY_VERDICT=idle
    return 0
  fi
  if ! fm_delivery_endpoint_status "$state"; then
    FM_DELIVERY_VERDICT=undeliverable
    FM_DELIVERY_VERDICT_REASON=$(fm_delivery_endpoint_reason_token "$FM_DELIVERY_ENDPOINT_STATUS")
    FM_DELIVERY_VERDICT_REASON_TEXT=$(fm_delivery_endpoint_reason "$FM_DELIVERY_ENDPOINT_STATUS")
    return 1
  fi
  FM_DELIVERY_VERDICT_BACKEND=$FM_DELIVERY_ENDPOINT_BACKEND
  FM_DELIVERY_VERDICT_TARGET=$FM_DELIVERY_ENDPOINT_TARGET
  FM_DELIVERY_VERDICT_HARNESS=$FM_DELIVERY_ENDPOINT_HARNESS
  if fm_delivery_attempt_outcome_read_blocked "$state"; then
    FM_DELIVERY_VERDICT=undeliverable
    FM_DELIVERY_VERDICT_REASON=${FM_DELIVERY_ATTEMPT_REASON_TOKEN:-attempt-blocked}
    FM_DELIVERY_VERDICT_REASON_TEXT=$FM_DELIVERY_ATTEMPT_REASON
    return 1
  fi
  FM_DELIVERY_VERDICT=delivering
  return 0
}

# The prose rendering: for humans, and unchanged for every consumer that still
# matches its first word.
fm_delivery_report() {  # <state> <delivery-path> [grace] [home]
  local rc
  fm_delivery_classify "$@"
  rc=$?
  case "$FM_DELIVERY_VERDICT" in
    stalled)
      printf 'stalled: delivery listener pid %s is alive but its beacon is %ss old (grace %ss); %s wake(s) pending\n' \
        "$FM_DELIVERY_VERDICT_PID" "$FM_DELIVERY_VERDICT_BEACON_AGE" "$FM_DELIVERY_VERDICT_GRACE" "$FM_DELIVERY_VERDICT_PENDING"
      ;;
    down)
      printf 'down: no live identity-matched delivery listener for this home (last beat %ss ago); %s wake(s) pending\n' \
        "$FM_DELIVERY_VERDICT_BEACON_AGE" "$FM_DELIVERY_VERDICT_PENDING"
      ;;
    away)
      printf 'away: listener pid %s is up and standing down because away mode owns delivery; %s wake(s) pending\n' \
        "$FM_DELIVERY_VERDICT_PID" "$FM_DELIVERY_VERDICT_PENDING"
      ;;
    idle)
      printf 'idle: listener pid %s is up and the durable queue is empty\n' "$FM_DELIVERY_VERDICT_PID"
      ;;
    undeliverable)
      printf 'undeliverable: listener pid %s is up with %s wake(s) pending, but %s\n' \
        "$FM_DELIVERY_VERDICT_PID" "$FM_DELIVERY_VERDICT_PENDING" "$FM_DELIVERY_VERDICT_REASON_TEXT"
      ;;
    delivering)
      printf 'delivering: listener pid %s is up with %s wake(s) pending for %s pane %s (%s)\n' \
        "$FM_DELIVERY_VERDICT_PID" "$FM_DELIVERY_VERDICT_PENDING" "$FM_DELIVERY_VERDICT_BACKEND" \
        "$FM_DELIVERY_VERDICT_TARGET" "${FM_DELIVERY_VERDICT_HARNESS:-unknown harness}"
      ;;
  esac
  return "$rc"
}

# The machine rendering: one line of space-separated key=value pairs, every
# key always present, no value ever containing whitespace, parsed by splitting
# on spaces and then once on the first `=`.  Field order is stable.
fm_delivery_machine_value() {  # <value> -> the value with whitespace collapsed to `_`
  printf '%s' "$1" | tr -s '[:space:]' '_'
}

fm_delivery_report_machine() {  # <state> <delivery-path> [grace] [home]
  local rc
  fm_delivery_classify "$@"
  rc=$?
  printf 'verdict=%s exit=%s listener_pid=%s pending=%s beacon_age_seconds=%s grace_seconds=%s backend=%s target=%s reason=%s\n' \
    "$FM_DELIVERY_VERDICT" "$(fm_delivery_verdict_exit "$FM_DELIVERY_VERDICT")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_PID")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_PENDING")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_BEACON_AGE")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_GRACE")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_BACKEND")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_TARGET")" \
    "$(fm_delivery_machine_value "$FM_DELIVERY_VERDICT_REASON")"
  return "$rc"
}
