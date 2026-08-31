#!/usr/bin/env bash
# Claude primary watcher-continuity PreToolUse gate.
#
# This hook is deliberately narrow. It denies only an executed bin/fm-*.sh fleet
# command other than bin/fm-wake-drain.sh, bin/fm-delivery-service.sh, or the
# independently fail-closed bin/fm-teardown.sh, and only when the active primary
# home has task metadata in flight but no identity-matched live watcher holds the
# home lock. Ordinary shell commands, recovery commands, healthy supervision,
# fleet-idle homes, and child worktrees are always allowed.
#
# The existing turn-end guard remains the unchanged final backstop. This gate
# closes the long-turn gap before another fleet mutation, but does not replace or
# weaken the Stop hook.
#
# One refusal, two addressees. The recovery commands this message names are
# reserved to the session that operates this home, so they are printed only when
# this hook was loaded from that home's own checkout. The comparison is against
# FM_ROOT, the home this session would be operating, which coincides with the
# FM_HOME the supervision predicate judged on every path traced. A worker running
# the same tracked hook from its task worktree is told to report the stalled
# supervision instead and is handed no command. See fm_session_operates_home in
# bin/fm-primary-scope-lib.sh; the refusal is identical either way.
#
# Input is Claude PreToolUse JSON on stdin. Tests may pass --command directly.
# Malformed transport, missing jq/Node, a missing classifier, or classifier
# failure all fail open. A deny writes Claude's hook decision to stderr only and
# exits 2.
set -u

COMMAND=
COMMAND_SET=0

usage() {
  cat <<'EOF'
Usage: fm-continuity-pretool-check.sh [--command <shell-command>]

Reads Claude PreToolUse JSON from stdin unless --command is supplied.
Exits 0 to allow. Exits 2 with a Claude deny object on stderr only when an
unhealthy primary tries to execute a non-recovery firstmate fleet script.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      COMMAND=$2
      COMMAND_SET=1
      shift 2
      ;;
    --command=*)
      COMMAND=${1#--command=}
      COMMAND_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  COMMAND=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi
[ -n "$COMMAND" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
WATCH="$SCRIPT_DIR/fm-watch.sh"
POLICY="$SCRIPT_DIR/fm-continuity-command-policy.mjs"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
LOCK_PID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
if fm_pid_alive "$LOCK_PID" && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$LOCK_PID" "$FM_HOME"; then
  exit 0
fi

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
CLASSIFICATION=$(node "$POLICY" --command "$COMMAND" --root "$FM_ROOT" 2>/dev/null) || exit 0
case "$CLASSIFICATION" in
  deny*) ;;
  *) exit 0 ;;
esac

TAB=$(printf '\t')
REST=${CLASSIFICATION#*"$TAB"}
[ -n "$REST" ] && [ "$REST" != "$CLASSIFICATION" ] || exit 0
BLOCKED_SCRIPT=${REST%%"$TAB"*}
REASON_CODE=${REST#*"$TAB"}
[ "$REASON_CODE" != "$REST" ] || REASON_CODE=""
# Same refusal, different addressee. The supervision-repair commands are reserved
# to the session that operates this home; AGENTS.md gives a crewmate or scout none
# of them, and a worker cannot see the other homes on the account or what else is
# in flight. So the default worker message says what is wrong and asks for a
# report, and hands over no command.
# unsafe-teardown is the exception, because it is not a supervision-repair
# refusal at all: the ordinary literal bin/fm-teardown.sh stays allowed for every
# addressee, so the retry remedy is as true for a worker as for firstmate and a
# worker that got the report-it wording instead would be reading a wrong
# diagnosis. The refusal itself is identical either way.
OPERATES_HOME=0
fm_session_operates_home "$SCRIPT_DIR/.." "$FM_ROOT" && OPERATES_HOME=1
case "$REASON_CODE" in
  unsafe-teardown)
    if [ "$OPERATES_HOME" -eq 1 ]; then
      REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: $BLOCKED_SCRIPT)"
    else
      REASON="[watcher-continuity] tasks are in flight in the home that launched this task and no live watcher holds its home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: $BLOCKED_SCRIPT)"
    fi
    ;;
  *)
    if [ "$OPERATES_HOME" -eq 1 ]; then
      REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, and repair supervision through bin/fm-watcher-service.sh and bin/fm-delivery-service.sh before running other fleet commands (blocked: $BLOCKED_SCRIPT)"
    else
      REASON="[watcher-continuity] tasks are in flight in the home that launched this task and no live watcher holds its home lock; repairing that home's supervision belongs to firstmate and not to a task worker - report the stalled supervision in your task status line and carry on with your own task in this worktree (blocked: $BLOCKED_SCRIPT)"
    fi
    ;;
esac
ESCAPED=$(printf '%s' "$REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
