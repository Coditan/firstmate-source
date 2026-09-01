#!/usr/bin/env bash
# Portable tmux-hosted keeper for a vessel's primary Firstmate seat.
# Usage: fm-seat-keeper.sh <fm-home> <state-dir> <target-socket> <target-session> <account-home>
#
# <state-dir> is the state directory OF <fm-home>, and this keeper refuses to
# start when it is given anything else. It is not a free-standing keeper-private
# directory: it selects both where this keeper's own lock, log, attempts and
# give-up records live AND, through bin/fm-delivery-service.sh, which delivery
# queue, endpoint and beat the seat-death verdict is computed from. A private
# directory would answer that verdict from an empty wake queue, which reads as a
# healthy seat, and silence next to a dead seat is the exact failure this keeper
# exists to close, so refusing to start is cheaper than serving two meanings.
#
# This is a container stopgap for a home whose systemd user manager is absent.
# It consumes bin/fm-delivery-service.sh's named status verdict and never uses a
# socket pathname or a process-name match as its seat-death detector. The keeper
# itself must run on a separate tmux socket from <target-socket>.
#
# Deliberate shutdown is declared, not inferred: while state/.seat-stay-down
# exists this keeper clears its retry episode and leaves the seat down. Same
# marker, same tool (bin/fm-seat-stay-down.sh), same semantics as the respawner.
#
# Restores are bounded the way bin/fm-seat-respawner.sh bounds them:
# FM_SEAT_KEEPER_MAX_ATTEMPTS per delivery condition, backing off from
# FM_SEAT_KEEPER_RETRY_SEC up to FM_SEAT_KEEPER_MAX_BACKOFF, then a give-up
# marker and one high-severity evidence record through bin/fm-finding.sh instead
# of relaunching a seat that can never come up forever.
#
# TWO KNOWN STOPGAP LIMITS, both deliberate, neither fixed here:
#   1. This keeper does NOT read config/seat-launch-command. Its default relaunch
#      command starts `claude`, so a home whose primary seat is any other tool
#      must set FM_SEAT_KEEPER_SEAT_COMMAND or this keeper brings back the wrong
#      seat. The respawner remains the component that reads the configured
#      launch command.
#   2. This keeper assumes the target terminal server uses base-index 0 and
#      refuses to restore the seat on a server configured with base-index 1.
#      docs/seat-respawner.md owns that symptom: the line it logs, how the
#      attempt bound ends it, and what an operator sees.
#
# Environment: FM_SEAT_KEEPER_POLL (seconds between readings, default 15),
# FM_SEAT_KEEPER_RETRY_SEC (seconds before the first retry of one condition,
# doubling per attempt, default 30), FM_SEAT_KEEPER_MAX_BACKOFF (retry delay
# ceiling, default 900), FM_SEAT_KEEPER_MAX_ATTEMPTS (restore attempts per
# condition before giving up, default 5), FM_SEAT_KEEPER_DELIVERY_SERVICE,
# FM_SEAT_KEEPER_TMUX, FM_SEAT_KEEPER_SEAT_COMMAND,
# FM_SEAT_KEEPER_STATUS_OVERRIDE, and FM_SEAT_KEEPER_MAX_CYCLES (stop after N
# readings; 0, the default, runs the unbounded production loop, and only tests
# set a bound).
set -u

[ "$#" -eq 5 ] || {
  echo "usage: $(basename "$0") <fm-home> <state-dir> <target-socket> <target-session> <account-home>" >&2
  exit 2
}

FM_HOME=$1
KEEPER_STATE=$2
TARGET_SOCKET=$3
TARGET_SESSION=$4
ACCOUNT_HOME=$5

case "$FM_HOME$KEEPER_STATE$TARGET_SOCKET$TARGET_SESSION$ACCOUNT_HOME" in
  *$'\n'*|*$'\r'*) echo "fm-seat-keeper.sh: arguments must be single-line values" >&2; exit 2 ;;
esac
case "$FM_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: fm-home must be absolute" >&2; exit 2 ;; esac
case "$KEEPER_STATE" in /*) ;; *) echo "fm-seat-keeper.sh: state-dir must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SOCKET" in /*) ;; *) echo "fm-seat-keeper.sh: target-socket must be absolute" >&2; exit 2 ;; esac
case "$ACCOUNT_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: account-home must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SESSION" in ''|*[!A-Za-z0-9_-]*) echo "fm-seat-keeper.sh: target-session contains unsafe characters" >&2; exit 2 ;; esac

strip_trailing_slashes() {  # <path>
  local value=$1
  while [ "${value%/}" != "$value" ]; do value=${value%/}; done
  [ -n "$value" ] || value=/
  printf '%s\n' "$value"
}

FM_HOME=$(strip_trailing_slashes "$FM_HOME")
KEEPER_STATE=$(strip_trailing_slashes "$KEEPER_STATE")
if [ "$KEEPER_STATE" != "$FM_HOME/state" ]; then
  echo "fm-seat-keeper.sh: state-dir must be the state directory of fm-home; got state-dir=$KEEPER_STATE for fm-home=$FM_HOME, expected $FM_HOME/state" >&2
  exit 2
fi
KEEPER_HOME=$FM_HOME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# The delivery verdict grammar, and the one stable key for the condition a
# verdict names, are owned there; this keeper never re-derives either.
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# The bounded-relaunch episode is owned there and shared with the respawner, so
# both supervisors bound their relaunches by one rule.
# shellcheck source=bin/fm-retry-episode-lib.sh
. "$SCRIPT_DIR/fm-retry-episode-lib.sh"

# The arguments own this keeper's home and state directory. Both libraries above
# define FM_HOME, and derive a STATE, from the environment for their own use, so
# every path this keeper writes hangs off KEEPER_STATE, a name no library
# reaches, and FM_HOME is restated here from the validated argument rather than
# left as whichever value a library settled on. The same ownership binds
# outward: the delivery service derives its own state from FM_STATE_OVERRIDE, so
# delivery_status states this keeper's state dir on that call rather than
# letting an inherited one pick which home it reads.
FM_HOME=$KEEPER_HOME

DELIVERY_SERVICE=${FM_SEAT_KEEPER_DELIVERY_SERVICE:-$SCRIPT_DIR/fm-delivery-service.sh}
TMUX_CMD=${FM_SEAT_KEEPER_TMUX:-tmux}
POLL=${FM_SEAT_KEEPER_POLL:-15}
BASE_BACKOFF=${FM_SEAT_KEEPER_RETRY_SEC:-30}
MAX_BACKOFF=${FM_SEAT_KEEPER_MAX_BACKOFF:-900}
MAX_ATTEMPTS=${FM_SEAT_KEEPER_MAX_ATTEMPTS:-5}
# Bounded run for tests only: 0 means the production unbounded keeper loop.
MAX_CYCLES=${FM_SEAT_KEEPER_MAX_CYCLES:-0}
PIDFILE="$KEEPER_STATE/.seat-keeper.pid"
LOCKDIR="$KEEPER_STATE/.seat-keeper.lock"
TARGET_RECORD="$KEEPER_STATE/.seat-keeper-target"
MARKER="$KEEPER_STATE/.seat-stay-down"
ATTEMPTS="$KEEPER_STATE/.seat-keeper-attempts"
GIVEUP="$KEEPER_STATE/.seat-keeper-giveup"
LOG="$KEEPER_STATE/.seat-keeper.log"
SEAT_COMMAND=${FM_SEAT_KEEPER_SEAT_COMMAND:-'exec bash -lic "claude; exec bash -l"'}
# Read once, here: BASHPID inside a command substitution is the substitution's
# own subshell, so a pid record and its identity taken separately would name two
# different processes.
SELF_PID=${BASHPID:-$$}

POLL=$(fm_retry_num_or_default "$POLL" 15)
BASE_BACKOFF=$(fm_retry_num_or_default "$BASE_BACKOFF" 30)
MAX_BACKOFF=$(fm_retry_num_or_default "$MAX_BACKOFF" 900)
MAX_ATTEMPTS=$(fm_retry_num_or_default "$MAX_ATTEMPTS" 5)
case "$MAX_CYCLES" in ''|*[!0-9]*) MAX_CYCLES=0 ;; esac

log() {
  mkdir -p "$KEEPER_STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# A hand-started keeper is easy to start twice, and two keepers race each other's
# window creation and each other's pid records. The lock record is identity
# matched the way every other firstmate lock is, so a record left behind by a
# keeper that died is taken over rather than being an eternal refusal.
another_keeper_holds_the_lock() {
  local pid identity current
  pid=$(fm_retry_kv_get "$LOCKDIR/record" pid 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$SELF_PID" ] || return 1
  identity=$(fm_retry_kv_get "$LOCKDIR/record" pid-identity 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ]
}

# The lock is a symlink to an owner directory whose record is complete before
# the link exists, so the moment another keeper can see the lock it can also
# read who holds it. A lock published in two steps has a window in between where
# a second keeper reads an empty lock as a stale one and runs beside the first.
publish_lock() {  # <owner-dir>
  local owner=$1 stray
  if [ -e "$LOCKDIR" ] || [ -L "$LOCKDIR" ]; then
    return 1
  fi
  ln -s "$owner" "$LOCKDIR" 2>/dev/null || return 1
  if [ "$(readlink "$LOCKDIR" 2>/dev/null || true)" = "$owner" ]; then
    return 0
  fi
  # ln into a lock another keeper published between the check and here lands
  # INSIDE that keeper's owner directory rather than failing, so a link that
  # does not point at this keeper's own owner is a stray to take back.
  stray="$LOCKDIR/${owner##*/}"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$owner" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
  return 1
}

release_lock_path() {
  local owner
  if [ -L "$LOCKDIR" ]; then
    owner=$(readlink "$LOCKDIR" 2>/dev/null || true)
    rm -f "$LOCKDIR" || return 1
    if [ -n "$owner" ] && [ -d "$owner" ]; then
      rm -f "$owner/record"
      rmdir "$owner" 2>/dev/null || true
    fi
    return 0
  fi
  [ -e "$LOCKDIR" ] || return 0
  rm -f "$LOCKDIR/record"
  rmdir "$LOCKDIR" 2>/dev/null
}

take_lock() {
  local owner identity attempts=3
  mkdir -p "$KEEPER_STATE" || return 1
  identity=$(fm_pid_identity "$SELF_PID") || return 1
  owner=$(mktemp -d "$LOCKDIR.owner.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$SELF_PID"
    printf 'pid-identity=%s\n' "$identity"
    printf 'fm-home=%s\n' "$FM_HOME"
    printf 'target-socket=%s\n' "$TARGET_SOCKET"
    printf 'target-session=%s\n' "$TARGET_SESSION"
  } > "$owner/record" || { rm -rf "$owner"; return 1; }
  while [ "$attempts" -gt 0 ]; do
    if publish_lock "$owner"; then
      return 0
    fi
    if another_keeper_holds_the_lock; then
      rm -rf "$owner"
      return 2
    fi
    release_lock_path || { rm -rf "$owner"; return 1; }
    attempts=$((attempts - 1))
  done
  rm -rf "$owner"
  return 1
}

write_records() {
  local tmp
  mkdir -p "$KEEPER_STATE" || return 1
  printf '%s\n' "$SELF_PID" > "$PIDFILE" || return 1
  tmp=$(mktemp "$TARGET_RECORD.XXXXXX") || return 1
  {
    printf 'socket=%s\n' "$TARGET_SOCKET"
    printf 'session=%s\n' "$TARGET_SESSION"
    printf 'bash-window=0:bash\n'
    printf 'seat-window=1:firstmate\n'
    printf 'launch-shell=interactive-login\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$TARGET_RECORD"
}

cleanup() {
  trap - HUP INT TERM
  if [ "$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)" = "$SELF_PID" ]; then
    rm -f "$PIDFILE"
  fi
  if [ "$(fm_retry_kv_get "$LOCKDIR/record" pid 2>/dev/null || true)" = "$SELF_PID" ]; then
    release_lock_path || true
  fi
  exit 0
}
trap cleanup HUP INT TERM

stay_down() {
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ]
}

delivery_status() {
  local status
  if [ -n "${FM_SEAT_KEEPER_STATUS_OVERRIDE:-}" ]; then
    status=$FM_SEAT_KEEPER_STATUS_OVERRIDE
  else
    status=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$KEEPER_STATE" \
      "$DELIVERY_SERVICE" status 2>&1 || true)
  fi
  case "$status" in *$'\n'*) status=${status%%$'\n'*} ;; esac
  printf '%s\n' "$status"
}

# Concrete undeliverable verdicts remain direct death signals. Listener-down is
# death only when an independent tmux reading also says the target session is
# absent; listener-down alone can be a harmless listener restart. Return 1 for
# the known not-death verdicts (including other undeliverable reasons such as a
# busy or pending composer), and 2 for an unrecognised verdict so the loop must
# handle it deliberately instead of silently resetting its evidence counter.
seat_death_verdict() {  # <delivery-status-line>
  case "$1" in
    undeliverable:*"the published pane "*" no longer exists"*) return 0 ;;
    undeliverable:*"the endpoint was published by a session that no longer holds the fleet lock"*) return 0 ;;
    undeliverable:*"the published tmux server identity does not match the server at its recorded socket"*) return 0 ;;
    undeliverable:*"the published tmux server could not be verified"*) return 0 ;;
    undeliverable:*"the session composer could not be confirmed empty (state=unknown: dead shell prompt or unreadable pane)"*) return 0 ;;
    down:*)
      "$TMUX_CMD" -S "$TARGET_SOCKET" has-session -t "$TARGET_SESSION" 2>/dev/null && return 1
      return 0
      ;;
    undeliverable:*|stalled:*|away:*|idle:*|delivering:*) return 1 ;;
    *) return 2 ;;
  esac
}

window_name() {  # <index>
  local want=$1 line index name
  while IFS= read -r line; do
    index=${line%%:*}
    name=${line#*:}
    if [ "$index" = "$want" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <("$TMUX_CMD" -S "$TARGET_SOCKET" list-windows -t "$TARGET_SESSION" \
    -F '#{window_index}:#{window_name}' 2>/dev/null)
  return 1
}

start_bash_window() {
  "$TMUX_CMD" -S "$TARGET_SOCKET" new-window -d -t "$TARGET_SESSION:0" -n bash \
    -c "$ACCOUNT_HOME" 'exec bash -l'
}

start_firstmate_window() {
  "$TMUX_CMD" -S "$TARGET_SOCKET" new-window -d -t "$TARGET_SESSION:1" -n firstmate \
    -c "$FM_HOME" "$SEAT_COMMAND" || return 1
  "$TMUX_CMD" -S "$TARGET_SOCKET" select-window -t "$TARGET_SESSION:1"
}

ensure_topology() {  # <delivery-status-line>
  local status=$1 name changed=0

  # A real tmux command proves the target server survived. Do not create a new
  # target server: this stopgap is only for seat/session loss while it survives.
  "$TMUX_CMD" -S "$TARGET_SOCKET" list-sessions >/dev/null 2>&1 || {
    log "launch refused: delivery reported seat death, but the target tmux server is unreachable"
    return 1
  }

  if ! "$TMUX_CMD" -S "$TARGET_SOCKET" has-session -t "$TARGET_SESSION" 2>/dev/null; then
    "$TMUX_CMD" -S "$TARGET_SOCKET" new-session -d -s "$TARGET_SESSION" -n bash \
      -c "$ACCOUNT_HOME" 'exec bash -l' || return 1
    changed=1
  else
    name=$(window_name 0 || true)
    if [ -z "$name" ]; then
      start_bash_window || return 1
      changed=1
    elif [ "$name" != bash ]; then
      log "launch refused: $TARGET_SESSION:0 exists as '$name', not bash"
      return 1
    fi
  fi

  name=$(window_name 1 || true)
  case "$status" in
    *"the session composer could not be confirmed empty (state=unknown: dead shell prompt or unreadable pane)"*)
      if [ -n "$name" ]; then
        [ "$name" = firstmate ] || {
          log "launch refused: $TARGET_SESSION:1 exists as '$name', not firstmate"
          return 1
        }
        "$TMUX_CMD" -S "$TARGET_SOCKET" kill-window -t "$TARGET_SESSION:1" || return 1
        name=
      fi
      ;;
  esac
  if [ -z "$name" ]; then
    start_firstmate_window || return 1
    changed=1
  elif [ "$name" != firstmate ]; then
    log "launch refused: $TARGET_SESSION:1 exists as '$name', not firstmate"
    return 1
  fi

  if [ "$changed" -eq 1 ]; then
    log "restored target topology after delivery verdict: $status"
  fi
  return 0
}

clear_episode() {
  fm_retry_clear_episode "$ATTEMPTS" "$GIVEUP"
}

emit_giveup_finding() {  # <key> <status-line>
  local key=$1 status_line=$2 out rc=0
  out=$(fm_retry_giveup_emit "$GIVEUP" "$key" fm-seat-keeper \
    "The terminal-hosted primary firstmate seat keeper exhausted $MAX_ATTEMPTS restore attempt(s) for this home and stopped retrying this episode." \
    "bin/fm-seat-keeper.sh for $FM_HOME on $TARGET_SOCKET session $TARGET_SESSION" \
    "$status_line") || rc=$?
  [ -z "$out" ] || log "$out"
  return "$rc"
}

# A seat command that can never succeed must not be relaunched forever: the
# episode is keyed by the guarded condition, bounded by MAX_ATTEMPTS, and spaced
# by a doubling backoff, exactly as the respawner bounds its own.
attempt_restore() {  # <condition-key> <delivery-status-line>
  local key=$1 status=$2 now count next delay
  fm_retry_read_attempts "$ATTEMPTS" "$key"
  count=$FM_RETRY_ATTEMPT_COUNT
  next=$FM_RETRY_ATTEMPT_NEXT
  now=$(date +%s)
  if [ "$count" -ge "$MAX_ATTEMPTS" ]; then
    emit_giveup_finding "$key" "$status" || true
    return 0
  fi
  [ "$now" -ge "$next" ] || return 0
  count=$((count + 1))
  delay=$(fm_retry_backoff "$count" "$BASE_BACKOFF" "$MAX_BACKOFF")
  fm_retry_write_attempts "$ATTEMPTS" "$key" "$count" "$((now + delay))" || return 1
  log "restore attempt $count after: $status"
  ensure_topology "$status" || true
}

main() {
  local status verdict_rc verdict_key last_verdict='' seen=0 cycles=0 lock_rc=0 cleared
  take_lock || lock_rc=$?
  if [ "$lock_rc" -eq 2 ]; then
    echo "fm-seat-keeper.sh: another keeper already holds $LOCKDIR for this state dir" >&2
    return 1
  fi
  [ "$lock_rc" -eq 0 ] || { echo "fm-seat-keeper.sh: could not take the keeper lock" >&2; return 1; }
  write_records || { echo "fm-seat-keeper.sh: could not publish keeper records" >&2; return 1; }
  log "keeper started for socket=$TARGET_SOCKET session=$TARGET_SESSION"
  cleared=$(fm_retry_clear_exhausted_episode "$ATTEMPTS" "$GIVEUP") \
    && log "cleared the exhausted retry episode for condition $cleared; a hand-start is the operator deciding to try again"
  while :; do
    if stay_down; then
      clear_episode
      if [ "$last_verdict" != stay-down ]; then
        log "stay-down marker present; leaving seat down"
      fi
      last_verdict=stay-down
      seen=0
    else
      status=$(delivery_status)
      seat_death_verdict "$status"
      verdict_rc=$?
      case "$verdict_rc" in
        0)
          # Every death verdict carries details that change between two readings
          # of the same condition, such as the wake count and the listener pid.
          # Count the guarded condition, not byte-identical prose.
          verdict_key=$(fm_delivery_condition_key "$status")
          if [ "$verdict_key" = "$last_verdict" ]; then
            seen=$((seen + 1))
          else
            last_verdict=$verdict_key
            seen=1
          fi
          if [ "$seen" -ge 2 ]; then
            attempt_restore "$verdict_key" "$status" || true
          fi
          ;;
        1)
          clear_episode
          last_verdict=''
          seen=0
          ;;
        *)
          if [ "$last_verdict" != unrecognised ]; then
            log "unrecognised delivery verdict; resetting consecutive seat-death evidence: $status"
          fi
          last_verdict=unrecognised
          seen=0
          ;;
      esac
    fi
    cycles=$((cycles + 1))
    if [ "$MAX_CYCLES" -gt 0 ] && [ "$cycles" -ge "$MAX_CYCLES" ]; then
      cleanup
    fi
    sleep "$POLL"
  done
}

main "$@"
