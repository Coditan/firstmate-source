#!/usr/bin/env bash
# Stable PreToolUse transport for the lavish-guard command policy.
#
# A bare `lavish-axi` binds loopback and hands the captain a
# http://127.0.0.1:<port>/... link that opens nothing on his PC or phone, and it
# fails silently because the board looks correct on the machine that made it.
# This seatbelt denies that command before it runs and names the entry point
# that gets it right (bin/fm-lavish.sh). It exists because a written instruction
# already failed here: ~/.bashrc returns early for non-interactive shells and an
# agent tool shell loads its own snapshot, so nothing an operator exports ever
# reaches the invocation.
#
# bin/fm-lavish-command-policy.mjs is the sole owner of the block/allow
# decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only scopes the guard, acquires
# the harness payload, invokes that policy, and renders the established harness
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/lavish-access.md for the complete contract and validation record.
#
# SCOPE, and this deliberately differs from bin/fm-cd-pretool-check.sh: the
# guard fires wherever the wrapper exists, including a linked task worktree, not
# only in the plain primary checkout. Boards get opened from crew worktrees too,
# and a guard that is inert exactly where the mistake happens is not a guard.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-lavish-pretool-check.sh
#   bin/fm-lavish-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - no firstmate checkout with bin/fm-lavish.sh here: exit 0 with no
#           output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-lavish-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Fires wherever this firstmate checkout carries bin/fm-lavish.sh, including task
worktrees; it is a silent no-op anywhere else.
Exits 0 to allow and 2 to deny a bare lavish-axi invocation.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
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

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes the classifier joins within a shell word before
# looking for the guarded program name, so an ordinary quoted or escaped
# fragment cannot hide a deniable invocation from the policy owner. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct the name from bytes this
# substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote or
# expansion form the classifier decodes REQUIRES extending it here in the same
# change, or the prefilter stops being a strict superset. Deliberate deeper
# obfuscation is out of scope by the same agent-mistake threat model the policy
# uses.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *lavish-axi*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Scope to any firstmate checkout that actually carries the wrapper. There is
# deliberately no git-dir/git-common-dir test here: a crewmate task worktree is
# a linked worktree, and that is one of the places boards get opened. Any
# failure to confirm the checkout is inert (exit 0), never a block, so a broken
# environment never denies a shell command.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
WRAPPER="$FM_ROOT/bin/fm-lavish.sh"
[ -x "$WRAPPER" ] || exit 0

POLICY="$FM_ROOT/bin/fm-lavish-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --wrapper "$WRAPPER" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
