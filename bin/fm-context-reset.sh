#!/usr/bin/env bash
# fm-context-reset.sh - discard this firstmate session's context after its
# durable knowledge has been filed, and only when every condition for doing so
# safely still holds.
#
# Usage:
#   fm-context-reset.sh                    verify, then clear this session
#   fm-context-reset.sh --captain-approved the same, on the path for a reset the
#                                          captain has just approved
#   fm-context-reset.sh --check            run every verification and report,
#                                          clear nothing; combines with the flag
#                                          above
#   fm-context-reset.sh -h|--help          print this header
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
#   1. Never while the captain is in live conversation, unless the captain is the
#      one who asked for the reset (--captain-approved). Otherwise the scrollback
#      is wiped and a message queued during the clear is answered into a context
#      that is then discarded - the captain sees a reply firstmate does not
#      remember giving. Ask instead; the watcher's own wake says so.
#   2. Never before the receipt verifies. The receipt is what says this session's
#      knowledge was filed, and it is bound to the transcript position it was
#      filed at, so it cannot be reused after the session has moved on.
#
# THE TWO PATHS, AND WHY THERE ARE TWO
# The default path is autonomous: nobody asked for this reset, so the tool has to
# INFER that the captain is absent, and it infers it from silence -
# FM_CONTEXT_CAPTAIN_IDLE_SECS of it - under a receipt no older than
# FM_CONTEXT_RECEIPT_MAX_AGE. Those two agree by construction there, because that
# path only ever runs when the captain is already quiet.
#
# --captain-approved is the other case: the captain was asked and said yes. That
# approval REPLACES the silence, because silence was only ever a proxy for absence
# and an approval is the consent itself. Running both would not make the path
# strict, it would make it impossible: the idle window is measured from the moment
# the captain spoke to give the approval, so it demands a silence longer than the
# receipt is allowed to live, and no ordering of the steps opens both at once.
#
# On --captain-approved, therefore:
#   - the idle window does not apply at all;
#   - the receipt's AGE window is replaced by the condition it stood in for, that
#     the receipt was filed AFTER the approval. That needs no constant, cannot
#     deadlock (filing follows approval by construction here), and says exactly
#     what the window was groping at;
#   - EVERYTHING ELSE IS UNCHANGED. In particular the transcript-growth bound is
#     untouched: if this session moved on past its receipt, the reset refuses,
#     approval or not;
#   - and ONE CHECK IS ADDED, because dropping the idle window is what opened the
#     gap it used to cover: the approval record is read AGAIN immediately before
#     the clear is typed. Every other check runs once, well before the terminal
#     probes, and on this path the captain is present by construction - so a
#     follow-up typed into that gap is an ordinary occurrence rather than an edge
#     case. A captain who has spoken since approving refuses the reset, and the
#     operator has to go back and ask for a fresh approval.
#
# WHAT --captain-approved PROVES, AND WHAT IT CANNOT
# It proves a real captain record exists in the transcript, when it arrived, and
# that the knowledge was filed after it. It CANNOT prove that record MEANT
# approval. Semantic consent is not machine-checkable, and the party claiming the
# approval exists is the same party asking for the reset, so a flag that implied
# otherwise would be theatre.
#
# So the flag is built for AUDIT where verification is impossible. Every approved
# run names the exact captain record it relied on, by id and timestamp, on stdout
# and in state/.context-reset.log, and refuses outright when it cannot name one.
# Read that line as "this is what was treated as consent", never as "consent was
# confirmed". Away mode still refuses on this path too: a captain present enough
# to approve a reset has returned, and away mode should be exited first.
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
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

LOG="$STATE/.context-reset.log"
CHECK_ONLY=0
CAPTAIN_APPROVED=0

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) CHECK_ONLY=1 ;;
    --captain-approved) CAPTAIN_APPROVED=1 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

# The captain record an approved run is relying on, once it has been established.
APPROVAL_TS=
APPROVAL_UUID=

# Prefix on every durable log line, so the log always says which path ran and,
# from the moment it is known, which captain record an approved run relied on.
# Empty on the autonomous path, which keeps that path's log lines byte-identical
# to what they have always been.
#
# It is written as `path=` fields rather than prose because a refusal's own text
# can quote the flag name - the idle refusal below names it, to point at the path
# from the exact place it becomes relevant - and a marker a message can imitate is
# not a marker.
LOG_NOTE=
if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
  LOG_NOTE='path=captain-approved; '
fi

log_line() {  # <outcome> <detail>
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || true
}

refuse() {
  log_line refused "${LOG_NOTE}$*"
  printf 'fm-context-reset: REFUSED: %s\n' "$*" >&2
  printf 'fm-context-reset: nothing was discarded.\n' >&2
  exit 1
}

# Say on stdout exactly which captain record was treated as the approval, and in
# the same breath what that does not establish. Both halves are required: the
# first is the audit trail, and without the second the first reads as a
# confirmation the tool never made.
print_approval_note() {
  printf 'fm-context-reset: the approval was taken to be captain record %s at %s.\n' \
    "$APPROVAL_UUID" "$APPROVAL_TS"
  printf 'fm-context-reset: that record exists and this session filed its knowledge after it; whether it meant approval is not something this tool can check.\n'
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
# The AGE window is the autonomous path's stand-in for "this receipt still
# describes a session nobody has been talking to". On the approved path the thing
# it stands in for can be checked directly - the receipt was filed after the
# approval - so the window is replaced there rather than stretched to a bigger
# constant that would be wrong for some other session.
if [ "$CAPTAIN_APPROVED" -eq 0 ]; then
  [ "$AGE" -le "$FM_CONTEXT_RECEIPT_MAX_AGE" ] \
    || refuse "the stow receipt is ${AGE}s old (limit ${FM_CONTEXT_RECEIPT_MAX_AGE}s); file this session's knowledge again before resetting it"
fi

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
#
# An UNKNOWN captain timestamp refuses rather than matches. Two unknowns comparing
# equal would turn this check into a rubber stamp on precisely the state where
# nothing can be said about the captain at all - the equality would pass while
# proving nothing, which is worse than not checking.
if [ -z "$FM_CONTEXT_LAST_HUMAN_TS" ] || [ "$R_HUMAN" = unknown ]; then
  if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
    refuse "no captain record could be established from $FM_CONTEXT_TRANSCRIPT, so this run cannot name what it would be treating as the approval; --captain-approved rests on a real captain record and refuses without one, because a reset that cannot say what it relied on is not auditable by anyone"
  fi
  refuse "the captain's last message could not be established from $FM_CONTEXT_TRANSCRIPT, so nothing can show the captain has stayed silent since the receipt was written"
fi
[ "$R_HUMAN" = "$FM_CONTEXT_LAST_HUMAN_TS" ] \
  || refuse "the captain has spoken since the receipt was written; file this session's knowledge again, and reset only once the conversation has settled"

# --- 2b. the approval, on the captain-approved path -------------------------
# The equality just above is what makes "the last captain record" the right one to
# read as the approval: it proves the receipt was bound with this exact record as
# the latest thing the captain said. Anything the captain said afterwards would
# already have refused there, so the approval cannot be some older message with a
# newer one sitting unexamined behind it.
if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
  APPROVAL_TS=$FM_CONTEXT_LAST_HUMAN_TS
  APPROVAL_UUID=$FM_CONTEXT_LAST_HUMAN_UUID
  [ -n "$APPROVAL_UUID" ] \
    || refuse "the captain record at $APPROVAL_TS carries no id, so an approved reset could not record WHICH message it treated as the approval; a reset that cannot be audited afterwards must not run"
  case "$APPROVAL_TS" in
    [0-9][0-9][0-9][0-9]-*) ;;
    *) refuse "the captain record $APPROVAL_UUID has no readable timestamp ('$APPROVAL_TS'), so nothing can establish whether the receipt was filed after it" ;;
  esac
  RECEIPT_ISO=$(fm_context_iso_utc "$R_WRITTEN") || RECEIPT_ISO=
  [ -n "$RECEIPT_ISO" ] \
    || refuse "the stow receipt's write time could not be read as an instant, so nothing can establish whether it was filed after the approval"
  # Second precision against the transcript's millisecond stamps, compared
  # lexicographically exactly as fm_context_captain_active does. A receipt filed
  # in the SAME second as the approval reads as not-after and refuses: that biases
  # the one ambiguous case toward refusing, and costs at most a second.
  [ "$RECEIPT_ISO" \> "$APPROVAL_TS" ] \
    || refuse "the receipt was filed at ${RECEIPT_ISO}Z and the captain record $APPROVAL_UUID is stamped $APPROVAL_TS, so the receipt came first and its filing cannot have covered the approval (a same-second filing reads this way too, and refuses on purpose); file this session's knowledge again after the approval, then re-run"
  LOG_NOTE="path=captain-approved approval-record=$APPROVAL_UUID approval-ts=$APPROVAL_TS; "
fi

# --- 3. the captain is not here, and away mode is not in charge -------------
if [ -e "$STATE/.afk" ]; then
  if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
    refuse "away mode is still active and owns wake delivery, so this home is recorded as one the captain has stepped away from; a captain present enough to approve a reset has returned, so let away mode exit first and re-run"
  fi
  refuse "away mode is active and owns wake delivery; a reset here is the captain's call, not an autonomous one"
fi
# This is the INFERENCE that the captain is absent, drawn from silence. An
# explicit approval is the consent that silence was only ever a proxy for, so on
# the approved path it replaces this check rather than stacking on top of it - see
# "the two paths" in the header for why stacking them would make that path
# unreachable rather than merely careful.
#
# The refusal names WHICH condition it hit, because more than one reaches this
# point and they are not the same news. "The captain spoke" is a fact about the
# captain; "presence could not be established" is a fact about the transcript, and
# the fail-safe in fm_context_captain_active deliberately reports it as present.
# Both refuse - unknown must keep meaning present - but an operator who is told
# the first when the second is true has been sent to look in the wrong place, and
# on 2026-08-20 that cost three attempts before anyone measured underneath it.
if [ "$CAPTAIN_APPROVED" -eq 0 ] && fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS"; then
  if [ "$FM_CONTEXT_CAPTAIN_PRESENCE" = spoke ]; then
    refuse "$FM_CONTEXT_CAPTAIN_PRESENCE_WHY; ask before resetting instead of resetting during a live conversation, and re-run with --captain-approved only once the captain has actually approved"
  fi
  refuse "$FM_CONTEXT_CAPTAIN_PRESENCE_WHY, and a presence that cannot be established counts as present rather than absent; repair what stopped it being readable, or re-run with --captain-approved once the captain has actually approved"
fi

# --- 4. the fleet is still quiet, re-checked at the moment of the discard ---
fm_context_quiet "$STATE" || refuse "the fleet is no longer quiet: $FM_CONTEXT_NOT_QUIET"

# --- 5. the way back in is intact ------------------------------------------
# The re-entry-hook refusal in docs/context-reset.md checks that the session-start
# hook is still WIRED to a clear and that its script is still there. It does not
# check that anything is injected:
# the nudge exits silently whenever this home's lock pid is in its ancestry,
# which is exactly the case on a self-clear, so the fresh session rebuilds from
# AGENTS.md section 3 - always loaded, and already telling it to run
# bin/fm-session-start.sh. This gate catches the hook being unwired or the script
# removed outright, which would leave even that fallback with nothing behind it.
fm_context_restart_path_ok "$FM_HOME" "$FM_ROOT" || refuse "$FM_CONTEXT_RESTART_ERROR"

# --- 6. supervision survives the discard ------------------------------------
# The clear keeps the process and the session lock, and the wake listener is not
# the session's object at all any more, so the reset cannot take it with it. What
# would still strand the fresh session is a dead watcher or a dead listener: the
# first would notice nothing, the second would deliver nothing. Both are hard
# requirements. The listener is required only when this home actually has work or
# an X-mode relay to be woken for; with nothing recorded there is nothing a down
# listener could strand.
fm_watcher_healthy "$STATE" "$FM_ROOT/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" \
  || refuse "supervision is not running (${FM_WATCHER_HEALTH:-unknown}); repair it before discarding this session's context"

NEEDS_DELIVERY=0
for f in "$STATE"/*.meta; do
  [ -e "$f" ] || continue
  NEEDS_DELIVERY=1
  break
done
[ -e "$STATE/x-watch.check.sh" ] && NEEDS_DELIVERY=1
if [ "$NEEDS_DELIVERY" -eq 1 ]; then
  fm_delivery_healthy "$STATE" "$FM_ROOT/bin/fm-delivery.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" \
    || refuse "this home wake-delivery listener is not running (${FM_DELIVERY_HEALTH:-unknown}), so the session after the reset could not be woken; repair it with $("$FM_ROOT/bin/fm-delivery-service.sh" repair-command 2>/dev/null || printf 'bin/fm-delivery-service.sh restart') and re-run"
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
# Resolve BEFORE reading, or the refusal below cannot fire: `tmux
# display-message` answers for a different pane instead of refusing an
# unresolvable target (fm_tmux_resolve_pane, bin/fm-tmux-lib.sh), so a $PANE
# that no longer names anything would produce a real-looking TARGET belonging to
# some other window - and this script types a reset into whatever TARGET names.
RESOLVED_PANE=$(fm_tmux_resolve_pane "$PANE") \
  || refuse "this session's own terminal pane '$PANE' does not name a live pane"
TARGET=$(tmux display-message -p -t "$RESOLVED_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
[ -n "$TARGET" ] \
  || refuse "this session's own terminal pane '$PANE' could not be resolved"

# bin/fm-send.sh reads any target beginning with `fm-` as a recorded worker-task
# selector and looks for its metadata instead of resolving a live tmux endpoint,
# so a home whose terminal session is named that way would get an opaque "no
# metadata" error at the very last step. Refuse here instead, naming the cause.
case "$TARGET" in
  fm-*)
    refuse "this session's own pane is in tmux session '${TARGET%%:*}', whose name begins with fm-; bin/fm-send.sh reserves that prefix for a recorded worker task and would look this target up as one instead of typing into the pane, so rename this home's terminal session to something that does not begin with fm-"
    ;;
esac

if [ "$CHECK_ONLY" -eq 1 ]; then
  log_line check-passed "${LOG_NOTE}$FM_CONTEXT_TOKENS tokens; would clear $TARGET"
  printf 'fm-context-reset: all checks pass. %s tokens filed and bound; a real run would clear %s.\n' \
    "$FM_CONTEXT_TOKENS" "$TARGET"
  if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
    print_approval_note
  fi
  exit 0
fi

# --- 8. the approval is still the last thing the captain said, re-checked at
# --- the moment of the discard ----------------------------------------------
# Section 2b established the approval; everything since - the backend probe, the
# pane resolution, the display-message round trips - is time in which the captain
# can type again, and on this path the captain is present by construction. The
# idle window covered that gap on the autonomous path and does not apply here, so
# the record is read again as the last thing before the send.
#
# A failed re-scan refuses rather than passes: if the transcript cannot be read
# at the moment of the discard, nothing can show the captain stayed silent, which
# is the same fail-closed direction as every other check here.
#
# fm_context_scan overwrites FM_CONTEXT_TOKENS, so the figure this run actually
# verified is captured first and reported from there.
TOKENS=$FM_CONTEXT_TOKENS
if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
  fm_context_scan "$FM_CONTEXT_TRANSCRIPT" \
    || refuse "the transcript could not be re-read at the moment of the discard ($FM_CONTEXT_SCAN_ERROR), so nothing can show the captain has stayed silent since approving"
  if [ "$FM_CONTEXT_LAST_HUMAN_UUID" != "$APPROVAL_UUID" ] \
    || [ "$FM_CONTEXT_LAST_HUMAN_TS" != "$APPROVAL_TS" ]; then
    refuse "the captain SPOKE AFTER APPROVING: the approval was captain record $APPROVAL_UUID at $APPROVAL_TS, and the last captain record is now ${FM_CONTEXT_LAST_HUMAN_UUID:-unnamed} at ${FM_CONTEXT_LAST_HUMAN_TS:-unknown}; that message arrived after this session filed its knowledge and would be answered into the context this clear discards, so ask again and re-run only with a FRESH APPROVAL"
  fi
fi

# --- 9. type the clear through the verified submit path ---------------------
# Never a hand-rolled send-keys with a fixed sleep: claude opens a completion
# popup on a slash command, and the shared submit core is the one path that
# types once, retries only the Enter, and reads the pane back to confirm the
# submit landed.
if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$TARGET" /clear; then
  refuse "the reset could not be submitted to this session's own pane $TARGET; context is untouched"
fi

rm -f "$RECEIPT" 2>/dev/null || true
log_line cleared "${LOG_NOTE}$TOKENS tokens; submitted to $TARGET"
printf 'fm-context-reset: reset submitted at %s tokens; it takes effect when this turn ends.\n' "$TOKENS"
if [ "$CAPTAIN_APPROVED" -eq 1 ]; then
  print_approval_note
fi
exit 0
