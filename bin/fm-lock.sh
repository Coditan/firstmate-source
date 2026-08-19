#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The walk itself lives in fm-harness-pid-lib.sh, shared with the primary
# transcript record so both name the same session.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if fm_harness_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(fm_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
# The refusal test itself lives in fm-harness-pid-lib.sh so that the primary
# transcript record is gated on exactly the condition this lock refuses on,
# rather than on a second, drifting copy of it.
if fm_session_lock_held_by_other "$LOCK" "$me"; then
  echo "error: another live firstmate session holds the lock (pid $(cat "$LOCK")); operate read-only until resolved" >&2
  exit 1
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
