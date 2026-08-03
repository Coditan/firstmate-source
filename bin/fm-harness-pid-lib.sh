#!/usr/bin/env bash
# Shared identification of the harness (agent) process behind a tool call.
# The harness process lives as long as the session, unlike the transient
# subshell pid of any one call, so it is the identity every per-session record
# is keyed on: the session lock (bin/fm-lock.sh) and the primary transcript
# record (bin/fm-sessionstart-nudge.sh) must agree on it, or a consumer of one
# record cannot tell which session the other belongs to.
# This file is sourced by its callers and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|^pi$'

# Print the nearest harness pid at or above the sourcing shell's own pid,
# walking at most eight parents. Return 1 when no harness ancestor is found.
fm_harness_pid() {
  local pid=$$ comm args _
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Return 0 when $1 is a live process that looks like a harness.
fm_harness_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}
