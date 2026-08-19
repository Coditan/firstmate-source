#!/usr/bin/env bash
# Record a genuine firstmate primary's transcript position, unless another live
# session already holds this home's lock, then print the one-line session-start
# instruction unless that session already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

RECORD="$STATE/.primary-transcript"
LOCK="$STATE/.lock"

# 0 when the pid in state/.lock is live and sits in this process's own ancestry,
# which means session start already ran in this harness session - the state a
# /clear leaves behind, since a clear starts a new session id inside the same
# harness process the lock is keyed on.
# It is also the second, independent way this session can prove the lock is its
# own: it walks parents rather than matching a harness name, so it still answers
# when fm_harness_pid cannot.
lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$LOCK" ] || return 1
  IFS= read -r lock_pid < "$LOCK" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# 0 when this session must not touch the record, because another live session
# already holds this home's lock and will therefore keep every authority the
# record's consumers act on.
# Recording is gated on the lock rather than merely coinciding with it: a second
# session in a home that already has one is refused the lock and stays
# read-only, but it used to rewrite the record with its own transcript, so the
# ceiling then measured the new, nearly empty session while the session actually
# running the fleet went unmeasured - the protection absent exactly where it was
# meant to apply.
# Two independent proofs that the lock is this session's own are accepted, and
# either is enough: the holder is this session's harness pid, or the holder is
# in this process's ancestry. When neither can be shown the record is left
# alone, which is the conservative reading of a session that cannot say who it
# is: leaving another session's true record in place costs nothing, and
# overwriting it costs the measurement.
record_belongs_to_another_session() {  # <this-session-harness-pid>
  lock_is_in_ancestry && return 1
  fm_session_lock_held_by_other "$LOCK" "$1"
}

# Leave nothing behind that a reader could still take for a current record when
# this session cannot publish its own: a previous session's ok record names
# another session's transcript and owner. Truncation is the fallback for a state
# directory whose entries cannot be unlinked, because an empty record has no
# status=ok and a conforming reader refuses it.
invalidate_transcript_record() {
  rm -f "$RECORD" 2>/dev/null || : > "$RECORD" 2>/dev/null || true
}

# Record where this session's transcript lives and which harness process owns
# it, for the context-reset mechanism that later measures that transcript and
# binds a receipt to its position. Written on every primary session start this
# home's lock is not already held against - including the one a /clear creates,
# which is why it runs before the already-ran check below, whose lock ancestry
# survives a clear - so the record can never outlive the session it names.
# A value that cannot be determined is recorded as an explicit error rather than
# left out, because a consumer that silently compares against the wrong
# transcript is worse than one that refuses.
# docs/sessionstart-nudge.md owns the fields and the consumer contract.
record_transcript_position() {
  local payload='' pid='' sid='' path='' err='' tmp
  # Resolved with a bounded retry, and before anything else, because everything
  # below turns on it: the gate needs it to tell this session apart from the
  # lock holder, and the record needs it to name its own owner.
  fm_harness_pid_settled >/dev/null && pid=$FM_HARNESS_PID
  record_belongs_to_another_session "$pid" && return 0
  [ -t 0 ] || IFS= read -r -d '' -t 2 payload 2>/dev/null
  if [ -z "$pid" ]; then
    err=${FM_HARNESS_PID_ERROR:-no-harness-process}
  elif [ -z "$payload" ]; then
    err=no-hook-payload
  elif ! command -v jq >/dev/null 2>&1; then
    err=no-jq
  else
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
    # A newline inside a value would forge further record lines, so a value
    # that cannot be written as one key=value line is a failure, not a record.
    case "$path" in
      *$'\n'*) err=unusable-transcript-path ;;
      /*)
        case "$sid" in
          '') err=no-session-id ;;
          *$'\n'*) err=unusable-session-id ;;
        esac
        ;;
      *) err=no-transcript-path ;;
    esac
  fi
  tmp="$RECORD.$$"
  if [ -n "$err" ]; then
    printf 'status=error\nerror=%s\nharness_pid=%s\nrecorded_at=%s\n' \
      "$err" "$pid" "$(date +%s)" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null; invalidate_transcript_record; return 0; }
  else
    printf 'status=ok\nharness_pid=%s\nsession_id=%s\ntranscript_path=%s\nrecorded_at=%s\n' \
      "$pid" "$sid" "$path" "$(date +%s)" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null; invalidate_transcript_record; return 0; }
  fi
  mv -f "$tmp" "$RECORD" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; invalidate_transcript_record; }
  return 0
}

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
record_transcript_position

lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
