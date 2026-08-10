#!/usr/bin/env bash
# fm-stow-receipt.sh - record that this session's durable knowledge has been
# filed, bound to the exact transcript position it was filed at.
#
# Usage:
#   fm-stow-receipt.sh            write the receipt for this session
#   fm-stow-receipt.sh --show     print the current receipt, or report its absence
#   fm-stow-receipt.sh --clear    discard the receipt
#   fm-stow-receipt.sh -h|--help  print this header
#
# Run it IMMEDIATELY AFTER /stow, in the same firstmate turn as the reset that
# consumes it. bin/fm-context-reset.sh refuses without a receipt, refuses on a
# receipt older than FM_CONTEXT_RECEIPT_MAX_AGE, refuses once the transcript has
# advanced past FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES beyond it, and refuses if the
# captain has said anything since it was written. That tool owns its own refusals
# and is where the exceptions live - on its --captain-approved path the age bound
# is replaced by the requirement that this receipt was filed after the approval.
#
# WHAT THIS RECEIPT IS, STATED HONESTLY
# It is an ATTESTATION, not a proof. Whether a semantic sweep actually caught
# every durable fact cannot be checked mechanically - deciding what knowledge
# matters is the one step in this whole mechanism that needs judgement, which is
# precisely why /stow is a model step and this is not. What the receipt DOES make
# real is structural: no receipt, no reset; a receipt that has gone stale, no
# reset; a receipt from a different session, no reset. Combined with the fact
# that a cleared conversation stays on disk and is resumable by session id, a
# sweep that misses something misplaces it rather than destroying it.
#
# docs/context-reset.md owns the mechanism; bin/fm-context-lib.sh owns the
# predicates and the tunable bounds.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-context-lib.sh
. "$SCRIPT_DIR/fm-context-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

refuse() {
  printf 'fm-stow-receipt: refusing: %s\n' "$*" >&2
  exit 1
}

RECEIPT=$(fm_context_receipt_path "$STATE")

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --show)
    if [ -f "$RECEIPT" ]; then cat "$RECEIPT"; exit 0; fi
    printf 'fm-stow-receipt: no receipt at %s\n' "$RECEIPT" >&2
    exit 1
    ;;
  --clear) rm -f "$RECEIPT"; printf 'fm-stow-receipt: cleared\n'; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

fm_refuse_if_gate_agent

[ -d "$STATE" ] || refuse "state dir $STATE does not exist"

# A session that does not hold this home's lock is read-only by contract, and a
# read-only session has no business attesting that it filed anything.
fm_context_session_live "$STATE" \
  || refuse "no live firstmate session holds this home's lock"
fm_context_pid_in_ancestry "$FM_CONTEXT_LOCK_PID" \
  || refuse "another session (process $FM_CONTEXT_LOCK_PID) is operating this home, so this one is read-only"

fm_context_record_read "$STATE" || refuse "$FM_CONTEXT_RECORD_ERROR"

# The record must describe THIS session. A receipt written against another
# session's transcript would let the reset tool verify freshness against a file
# that has nothing to do with what is about to be discarded - a check that passes
# against the wrong file is worse than no check at all.
fm_context_pid_in_ancestry "$FM_CONTEXT_RECORD_PID" \
  || refuse "the recorded session (process $FM_CONTEXT_RECORD_PID) is not the session running this command; a receipt may only be written from the session it describes"

fm_context_scan "$FM_CONTEXT_TRANSCRIPT" || refuse "$FM_CONTEXT_SCAN_ERROR"

BYTES=$(fm_context_file_bytes "$FM_CONTEXT_TRANSCRIPT") \
  || refuse "could not size the transcript $FM_CONTEXT_TRANSCRIPT"
case "$BYTES" in
  ''|*[!0-9]*) refuse "could not size the transcript $FM_CONTEXT_TRANSCRIPT" ;;
esac

TMP="$RECEIPT.$$"
{
  printf 'status=ok\n'
  printf 'session_id=%s\n' "$FM_CONTEXT_SESSION_ID"
  printf 'harness_pid=%s\n' "$FM_CONTEXT_RECORD_PID"
  printf 'transcript_path=%s\n' "$FM_CONTEXT_TRANSCRIPT"
  printf 'transcript_bytes=%s\n' "$BYTES"
  printf 'context_tokens=%s\n' "$FM_CONTEXT_TOKENS"
  # Recorded honestly as `unknown` rather than as an empty field: an empty field
  # would compare equal to a later empty scan and quietly PASS the reset's
  # captain check on exactly the state where nothing is known about the captain.
  printf 'last_human_ts=%s\n' "${FM_CONTEXT_LAST_HUMAN_TS:-unknown}"
  printf 'written_at=%s\n' "$(date +%s)"
} > "$TMP" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; refuse "could not write $RECEIPT"; }
mv -f "$TMP" "$RECEIPT" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; refuse "could not publish $RECEIPT"; }

printf 'fm-stow-receipt: filed at %s tokens; valid for %ss or until this session moves on\n' \
  "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_RECEIPT_MAX_AGE"
