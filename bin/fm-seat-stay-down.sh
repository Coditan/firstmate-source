#!/usr/bin/env bash
# Declare whether this firstmate home's primary seat should stay down.
#
# Usage:
#   fm-seat-stay-down.sh down [reason]
#   fm-seat-stay-down.sh up
#   fm-seat-stay-down.sh status
#
# The respawner never guesses deliberate shutdown from process state.
# A present state/.seat-stay-down marker is authoritative and suppresses
# relaunch; absence means an unreachable seat may be relaunched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.seat-stay-down"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

cmd_down() {
  local reason=${1:-declared stay-down}
  case "$reason" in
    *$'\n'*|*$'\r'*) echo "fm-seat-stay-down.sh: reason must be one line" >&2; return 2 ;;
  esac
  mkdir -p "$STATE" || return 1
  {
    printf 'declared=%s\n' "$(iso_now)"
    printf 'pid=%s\n' "$$"
    printf 'reason=%s\n' "$reason"
  } > "$MARKER" || return 1
  chmod 600 "$MARKER" 2>/dev/null || true
  printf 'seat stay-down marker set: %s\n' "$MARKER"
}

cmd_up() {
  rm -f "$MARKER" || return 1
  printf 'seat stay-down marker cleared: %s\n' "$MARKER"
}

cmd_status() {
  if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
    printf 'down: marker present at %s\n' "$MARKER"
    sed -n '1,3p' "$MARKER" 2>/dev/null || true
  else
    printf 'up: no stay-down marker at %s\n' "$MARKER"
  fi
}

case "${1:-}" in
  down)
    shift
    cmd_down "$*"
    ;;
  up|clear)
    cmd_up
    ;;
  status)
    cmd_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
