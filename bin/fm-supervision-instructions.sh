#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
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

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

# Away delivery is the daemon, not a session stub, so this branch names the
# daemon relaunch the /afk skill prescribes for the resolved harness: the
# no-separate-terminal native path where the harness owns a tracked background
# job, and the terminal-backed launcher everywhere else. Draining stays out of
# it: the away daemon reads the durable queue through its own cursor.
away_repair_line() {
  local relaunch native_tool
  case "$HARNESS" in
    claude) native_tool='Claude Code background task' ;;
    grok) native_tool='Grok tracked background task' ;;
    *) native_tool='' ;;
  esac
  if [ -n "$native_tool" ]; then
    relaunch="prepare the lifecycle with bin/fm-afk-launch.sh start-native, then run FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh as its own $native_tool (never shell &); if that native launch fails, roll the preparation back with bin/fm-afk-launch.sh stop, which EXITS away mode by clearing state/.afk and therefore must be followed immediately by a fresh away entry so the captain is not left unattended without it"
  else
    relaunch='restart its non-visible tracked terminal with bin/fm-afk-launch.sh start'
  fi
  printf '%s%s%s\n' \
    'Away mode owns wake delivery and no live identity-matched away daemon is reading the durable queue: ' \
    "$relaunch" \
    '. Then confirm state/.supervise-daemon.pid names a live pid matching the daemon lock identity; the external delivery listener stands down while away mode owns delivery, so repairing it is not the fix here.'
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    away_repair_line
    return 0
  fi

  # The repair is the same sentence on every harness now, because the thing that
  # needs repairing is not a harness object.  What differs between seats is how a
  # wake ARRIVES, and that is the snippet's business rather than this line's.
  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  repair=$("$SCRIPT_DIR/fm-delivery-service.sh" repair-command 2>/dev/null \
    || printf '%s\n' 'bin/fm-delivery-service.sh restart')
  printf '%s%s%s%s\n' "$prefix" \
    "this home wake-delivery listener is not running, so nothing will turn a queued wake into a turn: repair it with " \
    "$repair" \
    ", confirm with bin/fm-delivery-service.sh status, and do not arm a session delivery wait instead - there is no longer such a thing."
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk. The away daemon owns delivery and the external listener stands down for it.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; the watcher service loads ' "$x_mode_env" ' and bootstrap restarts it when the file changes.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
printf '%s\n' '- The watcher service owns the loop and a companion service owns delivery; this session arms nothing and holds no delivery object.'
printf '\n'
render_snippet
printf '\n'
