#!/usr/bin/env bash
# Portable tmux-hosted keeper for a vessel's primary Firstmate seat.
# Usage: fm-seat-keeper.sh <fm-home> <state-dir> <target-socket> <target-session> <account-home>
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
#   2. This keeper assumes the target terminal server uses base-index 0. On a
#      server configured with base-index 1 the created session's only window
#      lands where this keeper expects the firstmate window, so it logs
#      "launch refused: <session>:1 exists as 'bash', not firstmate" and never
#      restores the seat.
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
STATE=$2
TARGET_SOCKET=$3
TARGET_SESSION=$4
ACCOUNT_HOME=$5

case "$FM_HOME$STATE$TARGET_SOCKET$TARGET_SESSION$ACCOUNT_HOME" in
  *$'\n'*|*$'\r'*) echo "fm-seat-keeper.sh: arguments must be single-line values" >&2; exit 2 ;;
esac
case "$FM_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: fm-home must be absolute" >&2; exit 2 ;; esac
case "$STATE" in /*) ;; *) echo "fm-seat-keeper.sh: state-dir must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SOCKET" in /*) ;; *) echo "fm-seat-keeper.sh: target-socket must be absolute" >&2; exit 2 ;; esac
case "$ACCOUNT_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: account-home must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SESSION" in ''|*[!A-Za-z0-9_-]*) echo "fm-seat-keeper.sh: target-session contains unsafe characters" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# The delivery verdict grammar, and the one stable key for the condition a
# verdict names, are owned there; this keeper never re-derives either.
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

DELIVERY_SERVICE=${FM_SEAT_KEEPER_DELIVERY_SERVICE:-$SCRIPT_DIR/fm-delivery-service.sh}
TMUX_CMD=${FM_SEAT_KEEPER_TMUX:-tmux}
POLL=${FM_SEAT_KEEPER_POLL:-15}
BASE_BACKOFF=${FM_SEAT_KEEPER_RETRY_SEC:-30}
MAX_BACKOFF=${FM_SEAT_KEEPER_MAX_BACKOFF:-900}
MAX_ATTEMPTS=${FM_SEAT_KEEPER_MAX_ATTEMPTS:-5}
# Bounded run for tests only: 0 means the production unbounded keeper loop.
MAX_CYCLES=${FM_SEAT_KEEPER_MAX_CYCLES:-0}
PIDFILE="$STATE/.seat-keeper.pid"
LOCKDIR="$STATE/.seat-keeper.lock"
TARGET_RECORD="$STATE/.seat-keeper-target"
MARKER="$STATE/.seat-stay-down"
ATTEMPTS="$STATE/.seat-keeper-attempts"
GIVEUP="$STATE/.seat-keeper-giveup"
LOG="$STATE/.seat-keeper.log"
SEAT_COMMAND=${FM_SEAT_KEEPER_SEAT_COMMAND:-'exec bash -lic "claude; exec bash -l"'}
# Read once, here: BASHPID inside a command substitution is the substitution's
# own subshell, so a pid record and its identity taken separately would name two
# different processes.
SELF_PID=${BASHPID:-$$}

num_or_default() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

POLL=$(num_or_default "$POLL" 15)
BASE_BACKOFF=$(num_or_default "$BASE_BACKOFF" 30)
MAX_BACKOFF=$(num_or_default "$MAX_BACKOFF" 900)
MAX_ATTEMPTS=$(num_or_default "$MAX_ATTEMPTS" 5)
case "$MAX_CYCLES" in ''|*[!0-9]*) MAX_CYCLES=0 ;; esac

log() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

kv_get() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key"=*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "$file"
  return 1
}

# A hand-started keeper is easy to start twice, and two keepers race each other's
# window creation and each other's pid records. The lock record is identity
# matched the way every other firstmate lock is, so a record left behind by a
# keeper that died is taken over rather than being an eternal refusal.
another_keeper_holds_the_lock() {
  local pid identity current
  pid=$(kv_get "$LOCKDIR/record" pid 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$SELF_PID" ] || return 1
  identity=$(kv_get "$LOCKDIR/record" pid-identity 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ]
}

take_lock() {
  local tmp identity
  mkdir -p "$STATE" || return 1
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    [ -d "$LOCKDIR" ] || return 1
    if another_keeper_holds_the_lock; then
      return 2
    fi
  fi
  identity=$(fm_pid_identity "$SELF_PID") || return 1
  tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$SELF_PID"
    printf 'pid-identity=%s\n' "$identity"
    printf 'fm-home=%s\n' "$FM_HOME"
    printf 'target-socket=%s\n' "$TARGET_SOCKET"
    printf 'target-session=%s\n' "$TARGET_SESSION"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$LOCKDIR/record" || { rm -f "$tmp"; return 1; }
}

write_records() {
  local tmp
  mkdir -p "$STATE" || return 1
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
  if [ "$(kv_get "$LOCKDIR/record" pid 2>/dev/null || true)" = "$SELF_PID" ]; then
    rm -f "$LOCKDIR/record"
    rmdir "$LOCKDIR" 2>/dev/null || true
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
    status=$(FM_HOME="$FM_HOME" "$DELIVERY_SERVICE" status 2>&1 || true)
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

read_attempt_record() {  # <key>
  local want=$1 key count next
  key=$(kv_get "$ATTEMPTS" key 2>/dev/null || true)
  if [ "$key" != "$want" ]; then
    FM_SEAT_KEEPER_ATTEMPT_COUNT=0
    FM_SEAT_KEEPER_ATTEMPT_NEXT=0
    return 0
  fi
  count=$(kv_get "$ATTEMPTS" count 2>/dev/null || true)
  next=$(kv_get "$ATTEMPTS" next 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$next" in ''|*[!0-9]*) next=0 ;; esac
  FM_SEAT_KEEPER_ATTEMPT_COUNT=$count
  FM_SEAT_KEEPER_ATTEMPT_NEXT=$next
}

write_attempt_record() {  # <key> <count> <next>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$ATTEMPTS.XXXXXX") || return 1
  {
    printf 'key=%s\n' "$1"
    printf 'count=%s\n' "$2"
    printf 'next=%s\n' "$3"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ATTEMPTS"
}

clear_episode() {
  rm -f "$ATTEMPTS" "$GIVEUP"
}

backoff_for() {  # <count-after-attempt>
  local count=$1 delay=$BASE_BACKOFF
  while [ "$count" -gt 1 ]; do
    delay=$((delay * 2))
    [ "$delay" -le "$MAX_BACKOFF" ] || { delay=$MAX_BACKOFF; break; }
    count=$((count - 1))
  done
  printf '%s\n' "$delay"
}

emit_giveup_finding() {  # <key> <status-line>
  local key=$1 status_line=$2 out
  if [ -f "$GIVEUP" ] && [ "$(kv_get "$GIVEUP" key 2>/dev/null || true)" = "$key" ]; then
    return 0
  fi
  if out=$(env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-finding.sh" emit \
      --class evidence \
      --severity high \
      --officer fm-seat-keeper \
      --claim "The terminal-hosted primary firstmate seat keeper exhausted $MAX_ATTEMPTS restore attempt(s) for this home and stopped retrying this episode." \
      --where "bin/fm-seat-keeper.sh for $FM_HOME on $TARGET_SOCKET session $TARGET_SESSION" \
      --measurement "$status_line" \
      --refuted-by "A fresh delivery status for the same queued work stops naming seat death after a restore attempt, or the stay-down marker is set deliberately." 2>&1); then
    {
      printf 'key=%s\n' "$key"
      printf 'finding=%s\n' "$(printf '%s\n' "$out" | awk -F= '/^id=/{print $2; exit}')"
    } > "$GIVEUP" || true
    log "give-up finding emitted for $key"
    return 0
  fi
  log "give-up finding failed: $out"
  return 1
}

# A seat command that can never succeed must not be relaunched forever: the
# episode is keyed by the guarded condition, bounded by MAX_ATTEMPTS, and spaced
# by a doubling backoff, exactly as the respawner bounds its own.
attempt_restore() {  # <condition-key> <delivery-status-line>
  local key=$1 status=$2 now count next delay
  read_attempt_record "$key"
  count=$FM_SEAT_KEEPER_ATTEMPT_COUNT
  next=$FM_SEAT_KEEPER_ATTEMPT_NEXT
  now=$(date +%s)
  if [ "$count" -ge "$MAX_ATTEMPTS" ]; then
    emit_giveup_finding "$key" "$status" || true
    return 0
  fi
  [ "$now" -ge "$next" ] || return 0
  count=$((count + 1))
  delay=$(backoff_for "$count")
  write_attempt_record "$key" "$count" "$((now + delay))" || return 1
  log "restore attempt $count after: $status"
  ensure_topology "$status" || true
}

main() {
  local status verdict_rc verdict_key last_verdict='' seen=0 cycles=0 lock_rc=0
  take_lock || lock_rc=$?
  if [ "$lock_rc" -eq 2 ]; then
    echo "fm-seat-keeper.sh: another keeper already holds $LOCKDIR for this state dir" >&2
    return 1
  fi
  [ "$lock_rc" -eq 0 ] || { echo "fm-seat-keeper.sh: could not take the keeper lock" >&2; return 1; }
  write_records || { echo "fm-seat-keeper.sh: could not publish keeper records" >&2; return 1; }
  log "keeper started for socket=$TARGET_SOCKET session=$TARGET_SESSION"
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
          log "unrecognised delivery verdict; resetting consecutive seat-death evidence: $status"
          last_verdict=''
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
