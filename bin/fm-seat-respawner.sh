#!/usr/bin/env bash
# Relaunch this home when the published firstmate seat becomes unreachable.
#
# Usage:
#   fm-seat-respawner.sh
#   FM_SEAT_RESPAWNER_ONCE=1 fm-seat-respawner.sh
#
# The liveness reading comes from bin/fm-delivery-service.sh status.
# This script does not probe panes or infer human intent from processes.
# Deliberate shutdown is declared through state/.seat-stay-down, managed by
# bin/fm-seat-stay-down.sh; when the marker exists, this script leaves the seat
# down.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESPAWNER_PATH="$SCRIPT_DIR/fm-seat-respawner.sh"
DELIVERY_SERVICE="${FM_SEAT_DELIVERY_SERVICE:-$SCRIPT_DIR/fm-delivery-service.sh}"
TMUX_CMD="${FM_SEAT_TMUX:-tmux}"
POLL=${FM_SEAT_RESPAWNER_POLL:-15}
BASE_BACKOFF=${FM_SEAT_RESPAWNER_BACKOFF:-30}
MAX_BACKOFF=${FM_SEAT_RESPAWNER_MAX_BACKOFF:-900}
MAX_ATTEMPTS=${FM_SEAT_RESPAWNER_MAX_ATTEMPTS:-5}
MARKER="$STATE/.seat-stay-down"
ATTEMPTS="$STATE/.seat-respawn-attempts"
GIVEUP="$STATE/.seat-respawn-giveup"
BEAT="$STATE/.last-seat-respawner-beat"
LOCKDIR="$STATE/.seat-respawner.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

num_or_default() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

POLL=$(num_or_default "$POLL" 15)
BASE_BACKOFF=$(num_or_default "$BASE_BACKOFF" 30)
MAX_BACKOFF=$(num_or_default "$MAX_BACKOFF" 900)
MAX_ATTEMPTS=$(num_or_default "$MAX_ATTEMPTS" 5)

log() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/.seat-respawner.log" 2>/dev/null || true
}

write_lock() {
  local tmp identity
  mkdir -p "$LOCKDIR" "$STATE" || return 1
  identity=$(fm_pid_identity "$$") || return 1
  tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$$"
    printf 'pid-identity=%s\n' "$identity"
    printf 'fm-home=%s\n' "$FM_HOME"
    printf 'respawner-path=%s\n' "$RESPAWNER_PATH"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$LOCKDIR/record" || { rm -f "$tmp"; return 1; }
}

beat() {
  mkdir -p "$STATE" || return 1
  : > "$BEAT"
}

stay_down() {
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ]
}

kv_get() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key"=*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "$file"
  return 1
}

launch_command() {
  local line file=$CONFIG/seat-launch-command
  if [ -n "${FM_SEAT_LAUNCH_COMMAND:-}" ]; then
    printf '%s\n' "$FM_SEAT_LAUNCH_COMMAND"
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 1
}

resume_style_launch_command() {  # <command>
  local cmd=" $1 " first base
  first=${1%%[	 ]*}
  base=${first##*/}
  case "$cmd" in
    *" resume "*|*" --resume"*|*" --continue"*)
      return 0
      ;;
  esac
  [ "$base" = claude ] || return 1
  case "$cmd" in
    *" -c "*|*" -c") return 0 ;;
    *) return 1 ;;
  esac
}

endpoint_file() {
  printf '%s/.primary-endpoint\n' "$STATE"
}

tmux_socket_from_endpoint() {
  local server socket pid endpoint
  endpoint=$(endpoint_file)
  [ "$(kv_get "$endpoint" backend 2>/dev/null || true)" = tmux ] || return 1
  server=$(kv_get "$endpoint" tmux-server 2>/dev/null || true)
  socket=${server%,*}
  pid=${server##*,}
  [ "$socket" != "$server" ] && [ -n "$socket" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$socket"
}

shell_quote() {
  printf '%q' "$1"
}

launch_in_tmux() {  # <reason>
  local cmd socket shell_command
  cmd=$(launch_command) || {
    log "launch refused: no config/seat-launch-command and no FM_SEAT_LAUNCH_COMMAND"
    return 1
  }
  if resume_style_launch_command "$cmd"; then
    log "launch refused: resume-style config/seat-launch-command is not safe for the seat respawner"
    return 1
  fi
  socket=$(tmux_socket_from_endpoint) || {
    log "launch refused: published endpoint is not a live tmux server-bound endpoint"
    return 1
  }
  shell_command="cd $(shell_quote "$FM_HOME") && export FM_HOME=$(shell_quote "$FM_HOME") FM_ROOT_OVERRIDE=$(shell_quote "$FM_ROOT") PATH=$(shell_quote "${PATH:-}") && exec $cmd"
  "$TMUX_CMD" -S "$socket" new-window -n firstmate "$shell_command" >/dev/null
}

condition_key() {  # <status-line>
  local status=$1 condition=$1
  case "$status" in
    undeliverable:*)
      condition=${status#undeliverable: listener pid }
      case "$condition" in
        *" is up with "*" wake(s) pending, but "*)
          condition=${condition#* is up with }
          condition=${condition#* wake(s) pending, but }
          condition="undeliverable:$condition"
          ;;
      esac
      ;;
  esac
  printf '%s' "$condition" | cksum | awk '{print $1 ":" $2}'
}

read_attempt_record() {  # <key>
  local want=$1 key count next
  key=$(kv_get "$ATTEMPTS" key 2>/dev/null || true)
  if [ "$key" != "$want" ]; then
    FM_SEAT_ATTEMPT_COUNT=0
    FM_SEAT_ATTEMPT_NEXT=0
    return 0
  fi
  count=$(kv_get "$ATTEMPTS" count 2>/dev/null || true)
  next=$(kv_get "$ATTEMPTS" next 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$next" in ''|*[!0-9]*) next=0 ;; esac
  FM_SEAT_ATTEMPT_COUNT=$count
  FM_SEAT_ATTEMPT_NEXT=$next
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
      --officer fm-seat-respawner \
      --claim "The primary firstmate seat respawner exhausted $MAX_ATTEMPTS launch attempt(s) for this home and stopped retrying this episode." \
      --where "bin/fm-seat-respawner.sh for $FM_HOME" \
      --measurement "$status_line" \
      --refuted-by "A fresh delivery status for the same queued work becomes deliverable after a launch attempt, or the stay-down marker is set deliberately." 2>&1); then
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

respawn_needed() {  # <status-line>
  case "$1" in
    undeliverable:*) return 0 ;;
    *) return 1 ;;
  esac
}

one_cycle() {
  local status_line key now count next delay
  beat || return 1
  if stay_down; then
    clear_episode
    log "stay-down marker present; leaving seat down"
    return 0
  fi
  status_line=$("$DELIVERY_SERVICE" status 2>&1 || true)
  case "$status_line" in *$'\n'*) status_line=${status_line%%$'\n'*} ;; esac
  if ! respawn_needed "$status_line"; then
    clear_episode
    return 0
  fi
  key=$(condition_key "$status_line")
  read_attempt_record "$key"
  count=$FM_SEAT_ATTEMPT_COUNT
  next=$FM_SEAT_ATTEMPT_NEXT
  now=$(date +%s)
  if [ "$count" -ge "$MAX_ATTEMPTS" ]; then
    emit_giveup_finding "$key" "$status_line" || true
    return 0
  fi
  if [ "$now" -lt "$next" ]; then
    return 0
  fi
  count=$((count + 1))
  delay=$(backoff_for "$count")
  next=$((now + delay))
  write_attempt_record "$key" "$count" "$next" || return 1
  if launch_in_tmux "$status_line"; then
    log "launch attempt $count submitted after: $status_line"
  else
    log "launch attempt $count failed after: $status_line"
  fi
}

main() {
  write_lock || { echo "fm-seat-respawner.sh: could not publish lock" >&2; return 1; }
  while :; do
    one_cycle || true
    [ "${FM_SEAT_RESPAWNER_ONCE:-0}" = 1 ] && break
    sleep "$POLL"
  done
}

main "$@"
