#!/usr/bin/env bash
# fm-context-reset.sh - discard this firstmate session's context after its
# durable knowledge has been filed, and only when every condition for doing so
# safely still holds.
#
# Usage:
#   fm-context-reset.sh           verify, then clear this session
#   fm-context-reset.sh --check   run every verification and report, clear nothing
#   fm-context-reset.sh -h|--help print this header
#
# Run it in the SAME firstmate turn as /stow and bin/fm-stow-receipt.sh:
#   /stow  ->  bin/fm-stow-receipt.sh && bin/fm-context-reset.sh
# The clear does not pre-empt the turn; it queues and fires at the natural turn
# boundary, so work in progress is never truncated.
#
# IT REFUSES RATHER THAN PROCEEDS. Every failed check exits 1 with the concrete
# reason on stderr and one durable line in state/.context-reset.log. There is no
# force flag and no partial path: a reset that cannot verify itself is a reset
# that must not happen, because the thing it would destroy is the only copy of
# this session's working knowledge that has not been written down.
#
# The two conditions that are never traded away:
#   1. Never while the captain is in live conversation. The scrollback is wiped,
#      and a message queued during the clear is answered into a context that is
#      then discarded - the captain sees a reply firstmate does not remember
#      giving. Ask instead; the watcher's own wake says so.
#   2. Never before the receipt verifies. The receipt is what says this session's
#      knowledge was filed, and it is bound to the transcript position it was
#      filed at, so it cannot be reused after the session has moved on.
#
# Scope: claude on tmux only. Self-clear is proven end to end there and nowhere
# else - grok's session-start output does not reach model context at all, so a
# clear there would decapitate the session rather than restart it. This script
# refuses on every other harness instead of guessing.
#
# docs/context-reset.md owns the mechanism and the evidence; bin/fm-context-lib.sh
# owns the predicates and the tunable bounds.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-context-lib.sh
. "$SCRIPT_DIR/fm-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

LOG="$STATE/.context-reset.log"
CHECK_ONLY=0

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --check) CHECK_ONLY=1 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

log_line() {  # <outcome> <detail>
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || true
}

refuse() {
  log_line refused "$*"
  printf 'fm-context-reset: REFUSED: %s\n' "$*" >&2
  printf 'fm-context-reset: nothing was discarded.\n' >&2
  exit 1
}

fm_refuse_if_gate_agent

[ -d "$STATE" ] || refuse "state dir $STATE does not exist"

# --- 1. this session, and a transcript that can be measured -----------------
# A session that does not hold this home's lock is read-only by contract, and a
# read-only session must neither file knowledge nor discard any.
fm_context_session_live "$STATE" \
  || refuse "no live firstmate session holds this home's lock; a session that is not operating this home must not discard context"
fm_context_pid_in_ancestry "$FM_CONTEXT_LOCK_PID" \
  || refuse "another session (process $FM_CONTEXT_LOCK_PID) is operating this home, so this one is read-only and must not file or discard anything"
fm_context_record_read "$STATE" || refuse "$FM_CONTEXT_RECORD_ERROR"
fm_context_pid_in_ancestry "$FM_CONTEXT_RECORD_PID" \
  || refuse "the recorded session (process $FM_CONTEXT_RECORD_PID) is not the session running this command; only a session may reset itself"
fm_context_scan "$FM_CONTEXT_TRANSCRIPT" || refuse "$FM_CONTEXT_SCAN_ERROR"

CURRENT_BYTES=$(fm_context_file_bytes "$FM_CONTEXT_TRANSCRIPT") || CURRENT_BYTES=
case "$CURRENT_BYTES" in
  ''|*[!0-9]*) refuse "could not size the transcript $FM_CONTEXT_TRANSCRIPT" ;;
esac

# --- 2. the receipt, and that it still describes this position --------------
RECEIPT=$(fm_context_receipt_path "$STATE")
[ -f "$RECEIPT" ] \
  || refuse "no stow receipt at $RECEIPT; run /stow and bin/fm-stow-receipt.sh first, in this same turn"
[ "$(fm_context_kv "$RECEIPT" status || true)" = ok ] \
  || refuse "the stow receipt is not in its ok state"

R_SESSION=$(fm_context_kv "$RECEIPT" session_id || true)
R_PID=$(fm_context_kv "$RECEIPT" harness_pid || true)
R_PATH=$(fm_context_kv "$RECEIPT" transcript_path || true)
R_BYTES=$(fm_context_kv "$RECEIPT" transcript_bytes || true)
R_HUMAN=$(fm_context_kv "$RECEIPT" last_human_ts || true)
R_WRITTEN=$(fm_context_kv "$RECEIPT" written_at || true)

[ "$R_SESSION" = "$FM_CONTEXT_SESSION_ID" ] \
  || refuse "the stow receipt was written for a different session; file this session's knowledge before resetting it"
[ "$R_PID" = "$FM_CONTEXT_RECORD_PID" ] \
  || refuse "the stow receipt was written by a different session process"
[ "$R_PATH" = "$FM_CONTEXT_TRANSCRIPT" ] \
  || refuse "the stow receipt is bound to a different transcript than this session's"

case "$R_WRITTEN" in
  ''|*[!0-9]*) refuse "the stow receipt has no readable write time" ;;
esac
AGE=$(( $(date +%s) - R_WRITTEN ))
[ "$AGE" -ge 0 ] || refuse "the stow receipt claims to have been written in the future"
[ "$AGE" -le "$FM_CONTEXT_RECEIPT_MAX_AGE" ] \
  || refuse "the stow receipt is ${AGE}s old (limit ${FM_CONTEXT_RECEIPT_MAX_AGE}s); file this session's knowledge again before resetting it"

case "$R_BYTES" in
  ''|*[!0-9]*) refuse "the stow receipt has no readable transcript position" ;;
esac
[ "$CURRENT_BYTES" -ge "$R_BYTES" ] \
  || refuse "the transcript is smaller than when the receipt was written; the recorded position is no longer meaningful"
GROWTH=$(( CURRENT_BYTES - R_BYTES ))
[ "$GROWTH" -le "$FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES" ] \
  || refuse "this session has moved on by ${GROWTH} bytes since the receipt (limit ${FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES}); file its knowledge again before resetting it"

# The single sharpest captain-safety check. If anything the captain said arrived
# after the receipt, the sweep did not cover it and the discard would swallow it.
[ "$R_HUMAN" = "$FM_CONTEXT_LAST_HUMAN_TS" ] \
  || refuse "the captain has spoken since the receipt was written; file this session's knowledge again, and reset only once the conversation has settled"

# --- 3. the captain is not here, and away mode is not in charge -------------
[ ! -e "$STATE/.afk" ] \
  || refuse "away mode is active and owns wake delivery; a reset here is the captain's call, not an autonomous one"
if fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS"; then
  refuse "the captain has been active within the last ${FM_CONTEXT_CAPTAIN_IDLE_SECS}s; ask before resetting instead of resetting during a live conversation"
fi

# --- 4. the fleet is still quiet, re-checked at the moment of the discard ---
fm_context_quiet "$STATE" || refuse "the fleet is no longer quiet: $FM_CONTEXT_NOT_QUIET"

# --- 5. the way back in is intact ------------------------------------------
# Refusal 10 checks that the session-start hook is still WIRED to a clear and
# that its script is still there. It does not check that anything is injected:
# the nudge exits silently whenever this home's lock pid is in its ancestry,
# which is exactly the case on a self-clear, so the fresh session rebuilds from
# AGENTS.md section 3 - always loaded, and already telling it to run
# bin/fm-session-start.sh. This gate catches the hook being unwired or the script
# removed outright, which would leave even that fallback with nothing behind it.
fm_context_restart_path_ok "$FM_HOME" "$FM_ROOT" || refuse "$FM_CONTEXT_RESTART_ERROR"

# --- 6. supervision survives the discard ------------------------------------
# The clear keeps the process, the session lock, and any running background wake
# delivery alive, but a dead watcher would leave the fresh session with nothing
# to wake it. That is a hard requirement. The delivery stub is required only when
# this home actually has work or an X-mode relay to be woken for; with nothing
# recorded there is nothing a missing stub could strand.
fm_watcher_healthy "$STATE" "$FM_ROOT/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" \
  || refuse "supervision is not running (${FM_WATCHER_HEALTH:-unknown}); repair it before discarding this session's context"

NEEDS_STUB=0
for f in "$STATE"/*.meta; do
  [ -e "$f" ] || continue
  NEEDS_STUB=1
  break
done
[ -e "$STATE/x-watch.check.sh" ] && NEEDS_STUB=1
if [ "$NEEDS_STUB" -eq 1 ]; then
  fm_wake_stub_armed "$STATE" "$FM_ROOT/bin/fm-wake-wait.sh" "$FM_HOME" \
    || refuse "wake delivery is not armed, so the session after the reset could not be woken; arm it with bin/fm-watch-arm.sh and re-run"
fi

# --- 7. the harness and pane this was proven on -----------------------------
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
[ "$HARNESS" = claude ] \
  || refuse "self-clear is only verified for claude; this session runs on '${HARNESS:-unknown}', where a reset could leave it unable to restart"

# A POSITIVE detection is required. discover_supervisor_backend still prints its
# tmux default when it detects nothing, and its non-zero status is the only
# signal that it guessed - so swallowing that status would let the tmux-only gate
# pass on a session whose terminal backend is unknown.
BACKEND=$(discover_supervisor_backend) \
  || refuse "this session's terminal backend could not be detected; self-clear is only verified on tmux and must never be typed on a guess"
[ "$BACKEND" = tmux ] \
  || refuse "self-clear is only verified on the tmux terminal backend; this session reports '${BACKEND:-unknown}'"

PANE=$(discover_supervisor_target) \
  || refuse "could not identify this session's own terminal pane; a reset must never be typed into a pane it cannot identify"
TARGET=$(tmux display-message -p -t "$PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
[ -n "$TARGET" ] \
  || refuse "this session's own terminal pane '$PANE' could not be resolved"

if [ "$CHECK_ONLY" -eq 1 ]; then
  log_line check-passed "$FM_CONTEXT_TOKENS tokens; would clear $TARGET"
  printf 'fm-context-reset: all checks pass. %s tokens filed and bound; a real run would clear %s.\n' \
    "$FM_CONTEXT_TOKENS" "$TARGET"
  exit 0
fi

# --- 8. type the clear through the verified submit path ---------------------
# Never a hand-rolled send-keys with a fixed sleep: claude opens a completion
# popup on a slash command, and the shared submit core is the one path that
# types once, retries only the Enter, and reads the pane back to confirm the
# submit landed.
if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$TARGET" /clear; then
  refuse "the reset could not be submitted to this session's own pane $TARGET; context is untouched"
fi

rm -f "$RECEIPT" 2>/dev/null || true
log_line cleared "$FM_CONTEXT_TOKENS tokens; submitted to $TARGET"
printf 'fm-context-reset: reset submitted at %s tokens; it takes effect when this turn ends.\n' "$FM_CONTEXT_TOKENS"
