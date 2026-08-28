#!/usr/bin/env bash
# Portable tmux-hosted keeper for a vessel's primary Firstmate seat.
# Usage: fm-seat-keeper.sh <fm-home> <state-dir> <target-socket> <target-session> <account-home>
#
# This is a container stopgap for a home whose systemd user manager is absent.
# It consumes bin/fm-delivery-service.sh's named status verdict and never uses a
# socket pathname or a process-name match as its seat-death detector. The keeper
# itself must run on a separate tmux socket from <target-socket>.
#
# Environment: FM_SEAT_KEEPER_POLL (seconds between readings, default 15),
# FM_SEAT_KEEPER_RETRY_SEC (minimum seconds between restore attempts, default
# 30), FM_SEAT_KEEPER_DELIVERY_SERVICE, FM_SEAT_KEEPER_TMUX,
# FM_SEAT_KEEPER_SEAT_COMMAND, FM_SEAT_KEEPER_STATUS_OVERRIDE, and
# FM_SEAT_KEEPER_MAX_CYCLES (stop after N readings; 0, the default, runs the
# unbounded production loop, and only tests set a bound).
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_SERVICE=${FM_SEAT_KEEPER_DELIVERY_SERVICE:-$SCRIPT_DIR/fm-delivery-service.sh}
TMUX_CMD=${FM_SEAT_KEEPER_TMUX:-tmux}
POLL=${FM_SEAT_KEEPER_POLL:-15}
RETRY=${FM_SEAT_KEEPER_RETRY_SEC:-30}
# Bounded run for tests only: 0 means the production unbounded keeper loop.
MAX_CYCLES=${FM_SEAT_KEEPER_MAX_CYCLES:-0}
PIDFILE="$STATE/.seat-keeper.pid"
TARGET_RECORD="$STATE/.seat-keeper-target"
LOG="$STATE/.seat-keeper.log"
SEAT_COMMAND=${FM_SEAT_KEEPER_SEAT_COMMAND:-'exec bash -lic "claude; exec bash -l"'}

num_or_default() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

POLL=$(num_or_default "$POLL" 15)
RETRY=$(num_or_default "$RETRY" 30)
case "$MAX_CYCLES" in ''|*[!0-9]*) MAX_CYCLES=0 ;; esac

case "$FM_HOME$STATE$TARGET_SOCKET$TARGET_SESSION$ACCOUNT_HOME" in
  *$'\n'*|*$'\r'*) echo "fm-seat-keeper.sh: arguments must be single-line values" >&2; exit 2 ;;
esac
case "$FM_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: fm-home must be absolute" >&2; exit 2 ;; esac
case "$STATE" in /*) ;; *) echo "fm-seat-keeper.sh: state-dir must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SOCKET" in /*) ;; *) echo "fm-seat-keeper.sh: target-socket must be absolute" >&2; exit 2 ;; esac
case "$ACCOUNT_HOME" in /*) ;; *) echo "fm-seat-keeper.sh: account-home must be absolute" >&2; exit 2 ;; esac
case "$TARGET_SESSION" in ''|*[!A-Za-z0-9_-]*) echo "fm-seat-keeper.sh: target-session contains unsafe characters" >&2; exit 2 ;; esac

log() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

write_records() {
  local tmp
  mkdir -p "$STATE" || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$PIDFILE" || return 1
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
  if [ "$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
    rm -f "$PIDFILE"
  fi
  exit 0
}
trap cleanup HUP INT TERM

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
}

main() {
  local status verdict_rc verdict_key last_verdict='' seen=0 last_attempt=0 now cycles=0
  write_records || { echo "fm-seat-keeper.sh: could not publish keeper records" >&2; return 1; }
  log "keeper started for socket=$TARGET_SOCKET session=$TARGET_SESSION"
  while :; do
    status=$(delivery_status)
    seat_death_verdict "$status"
    verdict_rc=$?
    case "$verdict_rc" in
      0)
        # down: text includes changing details such as last-beat age. Count the
        # guarded condition, not byte-identical prose, across consecutive polls.
        case "$status" in
          down:*) verdict_key=down-and-session-absent ;;
          *) verdict_key=$status ;;
        esac
        if [ "$verdict_key" = "$last_verdict" ]; then
          seen=$((seen + 1))
        else
          last_verdict=$verdict_key
          seen=1
        fi
        now=$(date +%s)
        if [ "$seen" -ge 2 ] && [ $((now - last_attempt)) -ge "$RETRY" ]; then
          last_attempt=$now
          ensure_topology "$status" || true
        fi
        ;;
      1)
        last_verdict=''
        seen=0
        ;;
      *)
        log "unrecognised delivery verdict; resetting consecutive seat-death evidence: $status"
        last_verdict=''
        seen=0
        ;;
    esac
    cycles=$((cycles + 1))
    if [ "$MAX_CYCLES" -gt 0 ] && [ "$cycles" -ge "$MAX_CYCLES" ]; then
      return 0
    fi
    sleep "$POLL"
  done
}

main "$@"
