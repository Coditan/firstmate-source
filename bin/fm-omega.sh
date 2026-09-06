#!/usr/bin/env bash
# fm-omega.sh - own the durable omega-window marker and close-record log.
#
# Usage:
#   fm-omega.sh open --task <text> --record <decision-record-id>
#   fm-omega.sh status
#   fm-omega.sh close
#
# The marker is a record, never an authority.
# Its presence is evidence that the captain invoked the protocol for this away
# window, but it grants nothing by itself, widens no approval authority, and
# never authorizes a merge, destructive step, or credential operation.
#
# state/.omega and state/omega-window.log are written only by this script.
# The marker is bound to the exact state/.afk content present at `open`.
# `status` returns 0 for IN FORCE, 3 for NOT IN FORCE, 4 for STALE, and 1 when
# the stored state cannot be classified safely.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.omega"
LOG="$STATE/omega-window.log"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_value() { # <field-name> <value>
  local name=$1 value=$2
  [ -n "$value" ] || { printf 'fm-omega: %s must not be empty\n' "$name" >&2; return 1; }
  case "$value" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      printf 'fm-omega: %s must be one line without tabs\n' "$name" >&2
      return 1
      ;;
  esac
  printf '%s' "$value"
}

read_marker() {
  local key value extra schema='' opened='' task='' record='' away='' count=0
  [ -f "$MARKER" ] || return 3
  while IFS="$(printf '\t')" read -r key value extra || [ -n "$key$value${extra:-}" ]; do
    [ -z "${extra:-}" ] || { printf 'fm-omega: unreadable marker: extra field on %s\n' "$key" >&2; return 1; }
    case "$key" in
      schema) [ -z "$schema" ] || { printf 'fm-omega: unreadable marker: duplicate schema\n' >&2; return 1; }; schema=$value ;;
      opened) [ -z "$opened" ] || { printf 'fm-omega: unreadable marker: duplicate opened\n' >&2; return 1; }; opened=$value ;;
      task) [ -z "$task" ] || { printf 'fm-omega: unreadable marker: duplicate task\n' >&2; return 1; }; task=$value ;;
      record) [ -z "$record" ] || { printf 'fm-omega: unreadable marker: duplicate record\n' >&2; return 1; }; record=$value ;;
      away-entry) [ -z "$away" ] || { printf 'fm-omega: unreadable marker: duplicate away-entry\n' >&2; return 1; }; away=$value ;;
      *) printf 'fm-omega: unreadable marker: unknown field %s\n' "$key" >&2; return 1 ;;
    esac
    count=$((count + 1))
  done < "$MARKER" || return 1
  [ "$count" -eq 5 ] && [ "$schema" = fm-omega.v1 ] &&
    case "$opened" in ''|*[!0-9]*) false ;; *) true ;; esac &&
    [ -n "$task" ] && [ -n "$record" ] && [ -n "$away" ] || {
      printf 'fm-omega: unreadable marker: invalid or incomplete record\n' >&2
      return 1
    }
  OMEGA_OPENED=$opened
  OMEGA_TASK=$task
  OMEGA_RECORD=$record
  OMEGA_AWAY_ENTRY=$away
}

open_window() {
  local task='' record='' away opened pending
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || { usage >&2; return 2; }; task=$2; shift 2 ;;
      --record) [ "$#" -ge 2 ] || { usage >&2; return 2; }; record=$2; shift 2 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  task=$(clean_value task "$task") || return 2
  record=$(clean_value record "$record") || return 2
  [ ! -e "$MARKER" ] || { printf 'fm-omega: open refused: marker already exists\n' >&2; return 1; }
  [ -f "$STATE/.afk" ] || { printf 'fm-omega: open refused: away mode is not active\n' >&2; return 1; }
  IFS= read -r away < "$STATE/.afk" || { printf 'fm-omega: open refused: away-entry identity is unreadable\n' >&2; return 1; }
  away=$(clean_value away-entry "$away") || return 1
  opened=$(date +%s) || { printf 'fm-omega: open refused: clock is unreadable\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  pending=$(mktemp "$STATE/.omega.pending.XXXXXX") || return 1
  {
    printf 'schema\tfm-omega.v1\n'
    printf 'opened\t%s\n' "$opened"
    printf 'task\t%s\n' "$task"
    printf 'record\t%s\n' "$record"
    printf 'away-entry\t%s\n' "$away"
  } > "$pending" || { rm -f "$pending"; return 1; }
  if ! ln "$pending" "$MARKER" 2>/dev/null; then
    rm -f "$pending"
    printf 'fm-omega: open refused: marker already exists\n' >&2
    return 1
  fi
  rm -f "$pending"
}

status_window() {
  local current
  if [ ! -e "$MARKER" ]; then
    printf 'OMEGA: NOT IN FORCE - no marker\n'
    return 3
  fi
  read_marker || return 1
  if [ ! -f "$STATE/.afk" ]; then
    printf 'OMEGA: STALE - expected away-entry %s, found no active away entry\n' "$OMEGA_AWAY_ENTRY"
    return 4
  fi
  IFS= read -r current < "$STATE/.afk" || {
    printf 'fm-omega: status unreadable: current away-entry identity cannot be read\n' >&2
    return 1
  }
  if [ "$current" != "$OMEGA_AWAY_ENTRY" ]; then
    printf 'OMEGA: STALE - expected away-entry %s, found %s\n' "$OMEGA_AWAY_ENTRY" "$current"
    return 4
  fi
  printf 'OMEGA: IN FORCE - task=%s record=%s opened=%s away-entry=%s\n' \
    "$OMEGA_TASK" "$OMEGA_RECORD" "$OMEGA_OPENED" "$OMEGA_AWAY_ENTRY"
}

close_window() {
  local closed
  [ -e "$MARKER" ] || return 0
  read_marker || return 1
  closed=$(date +%s) || { printf 'fm-omega: close refused: clock is unreadable\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  printf 'closed\topened=%s\tclosed=%s\ttask=%s\trecord=%s\n' \
    "$OMEGA_OPENED" "$closed" "$OMEGA_TASK" "$OMEGA_RECORD" >> "$LOG" || return 1
  rm -f "$MARKER"
}

case "${1:-}" in
  open) shift; open_window "$@" ;;
  status) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; status_window ;;
  close) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; close_window ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
