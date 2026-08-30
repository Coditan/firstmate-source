#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind, the
# adapter forces one same-session follow-up by running `grok --resume <session>`
# with a guard instruction. GROK_TURNEND_GUARD_ACTIVE is the loop guard: the
# nested turn's own Stop hook exits without spawning another nested turn.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

[ -n "${GROK_TURNEND_GUARD_ACTIVE:-}" ] && exit 0

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.sessionId // empty' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-grok.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)

# This adapter prepends its own instruction to the shared guard's message, so it
# has to pick the same addressee the shared guard did. A crewmate or scout
# working on firstmate itself runs this adapter from its task worktree while
# FM_ROOT_OVERRIDE still names the home that launched it, and repairing that
# home's supervision is firstmate's under AGENTS.md, not the worker's.
# An unreadable predicate leaves fm_session_operates_home undefined, which the
# `if` below then reads as "not the operator" - the addressee that is handed no
# command, and so the safe one to fall back to.
FM_ROOT=${FM_ROOT_OVERRIDE:-$ROOT}
if [ -r "$ROOT/bin/fm-primary-scope-lib.sh" ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$ROOT/bin/fm-primary-scope-lib.sh"
fi
if fm_session_operates_home "$ROOT" "$FM_ROOT" 2>/dev/null; then
  HEADLINE='TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.'
  [ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
else
  HEADLINE='SUPERVISION IS OFF IN THE HOME THAT LAUNCHED THIS TASK. Repairing it belongs to firstmate, not to a task worker: report the stalled supervision in your task status line and carry on with your own task in this worktree.'
  [ -n "$REASON" ] || REASON='tasks in flight in the launching home, no live watcher - report it rather than repairing it.'
fi
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
fm_operational_input_encode turn-end-guard \
  "$HEADLINE

$REASON" \
  PROMPT || exit 0

GROK_TURNEND_GUARD_ACTIVE=1 \
  GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
  grok --resume "$SESSION_ID" \
    --cwd "$ROOT" \
    --output-format plain \
    -p "$PROMPT" >/dev/null 2>&1 || true
