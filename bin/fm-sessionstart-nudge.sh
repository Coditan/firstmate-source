#!/usr/bin/env bash
# Record a genuine firstmate primary's transcript position, unless another live
# session already holds this home's lock, then print the one-line session-start
# instruction unless that session already acquired the home lock.
# With --rebind-to-lock it instead rebinds the standing record to the holder
# named in this home's session lock, which bin/fm-session-start.sh invokes after
# every acquisition because this hook may have run against a lock it correctly
# refused to write over - a dead container's record it read as foreign, or a
# stale holder cleared only after the hook had already run in this same harness
# process, where no further SessionStart hook ever fires.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# A library that cannot be loaded leaves this wrapper unable to prove anything
# about who it is, so it writes nothing and prints nothing rather than running
# on with its gate functions undefined. Measured 2026-09-03: a copy of this
# script without fm-harness-pid-lib.sh ran with a live home's FM_HOME in its
# environment, every `command not found` from the gate fell through to the
# write, and that home's good record was replaced by an error record.
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh" 2>/dev/null || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh" 2>/dev/null || exit 0
# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh" 2>/dev/null || exit 0

RECORD="$STATE/.primary-transcript"
# The payload this session saw at its own SessionStart, kept only while another
# session's lock forbids publishing it as the record. It is the ONE place this
# session's true transcript path and session id survive a refusal: the hook fires
# once per harness session, so a session refused the record at its start has no
# second payload to record from when it later takes the lock, and without this it
# could only ever rebind to an error record. One file per session, named by the
# harness pid that wrote it, so two refused sessions in one home - a primary and
# a helper the harness started in the same cwd - never write the same file and
# neither can destroy the other's only copy. Promotion reads only the file named
# by the pid the lock publishes, so a second, never-locking session's pending
# file can never become this home's record.
PENDING_PREFIX="$RECORD.pending."
LOCK="$STATE/.lock"

# 0 when the holder in state/.lock is live, names this process's pid table, and
# sits in this process's own ancestry, which means session start already ran in
# this harness session - the state a /clear leaves behind.
# It is also the second, independent way this session can prove the lock is its
# own: it walks parents rather than matching a harness name, so it still answers
# when fm_harness_pid cannot. A session that cannot name its own pid table loses
# this fallback deliberately rather than assuming a same-number pid is its own.
# A legacy record naming no table keeps the old ancestry reading because this
# hook runs before fm-lock.sh can replace that record on the first upgraded
# session; refusing it here would leave that session's context ceiling unmeasured.
# The optional <own-harness-pid> makes the proof exact: the walk stops at this
# session's own nearest harness process, so a lock pid that sits ABOVE it is
# another harness session this one merely descends from, and the answer is 1.
# Measured 2026-09-03: Claude Code's background-job daemon started a helper
# session in the primary's own cwd, four hops under the primary, and the
# unbounded walk found the primary's lock pid in the helper's ancestry and took
# the helper for the lock holder. Without the argument the walk is unbounded,
# which is still the right reading for "did session start already run somewhere
# above me" - a helper under the primary must not be told to run it again.
lock_is_in_ancestry() {  # [own-harness-pid]
  local lock_pid pid=$$ _ mine_ns own=${1-}
  fm_session_lock_record_read "$LOCK" || return 1
  lock_pid=$FM_LOCK_RECORD_PID
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  if [ -n "$FM_LOCK_RECORD_PIDNS" ]; then
    mine_ns=$(fm_pid_namespace_token) || return 1
    [ "$mine_ns" = "$FM_LOCK_RECORD_PIDNS" ] || return 1
  fi
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    [ -n "$own" ] && [ "$pid" = "$own" ] && return 1
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Read one field of the existing record. This wrapper is the record's producer
# and reads back only what it wrote; the consumer-side reader is
# fm_context_kv in bin/fm-context-lib.sh, which is not sourced here because it
# pulls the classification library into a hook that has to stay small.
kv_field() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  return 1
}

record_field() {  # <key>
  kv_field "$RECORD" "$1"
}

# 0 when the record already standing is a good one whose owner is still alive.
# Liveness is the kernel's answer, not the process table's: on 2026-09-03 the
# table a run consulted was a test's fake `ps`, which called the live holder
# dead and let an error record through.
good_record_owner_is_alive() {
  local owner
  [ "$(record_field status)" = ok ] || return 1
  owner=$(record_field harness_pid) || return 1
  case "$owner" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  kill -0 "$owner" 2>/dev/null
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
# in this process's ancestry at or below this session's own harness process.
# The ancestry proof is handed that harness pid so it stops there: a lock pid
# further up belongs to a session this one descends from, not to this one, and
# a descendant that could replace its parent's record is the same defect through
# a third door. When neither can be shown the record is left alone, which is
# the conservative reading of a session that cannot say who it is: leaving
# another session's true record in place costs nothing, and overwriting it
# costs the measurement.
# A session that cannot name its own harness process has nothing better to
# offer than a good record whose owner is still alive, so it leaves that record
# alone whatever the lock says - measured twice on 2026-09-03 as
# `status=error error=no-harness-process harness_pid=` written over a live
# holder's good record. The cost accepted here is narrow: a lock holder that
# clears its context and at that instant cannot resolve its own harness keeps
# its previous transcript path instead of recording the failure.
record_belongs_to_another_session() {  # <this-session-harness-pid>
  if [ -z "$1" ] && good_record_owner_is_alive; then
    return 0
  fi
  lock_is_in_ancestry "$1" && return 1
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
  local payload='' pid='' sid='' path='' err='' refused=0
  # Resolved with a bounded retry, and before anything else, because everything
  # below turns on it: the gate needs it to tell this session apart from the
  # lock holder, and the record needs it to name its own owner.
  fm_harness_pid_settled >/dev/null && pid=$FM_HARNESS_PID
  record_belongs_to_another_session "$pid" && refused=1
  # The payload is read whether or not this session may publish, and BEFORE the
  # refusal returns, because stdin is readable exactly once: a refused session
  # that skipped this read would have nothing to promote from when it later takes
  # the lock. Reading it never publishes it; only publish_transcript_record does.
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
  if [ "$refused" = 1 ]; then
    # Another live session holds this home, so this session's payload is stashed
    # rather than published. A payload that yielded no usable transcript is worth
    # nothing to a later rebind, so it leaves no pending file behind to promote.
    if [ -n "$err" ]; then
      [ -z "$pid" ] || discard_pending_record "$pid"
    else
      publish_pending_record "$pid" "$sid" "$path"
    fi
    return 0
  fi
  # This session is publishing for real, so its own stash has nothing left to
  # say. Another session's stash is left where it is: that session may still take
  # the lock later, and it is the only copy of its transcript position.
  [ -z "$pid" ] || discard_pending_record "$pid"
  publish_transcript_record "$pid" "$sid" "$path" "$err"
  return 0
}

pending_path() {  # <pid>
  printf '%s%s' "$PENDING_PREFIX" "$1"
}

# Stash this session's own transcript position while another session's lock
# forbids publishing it. Written atomically like the record itself, and a stash
# that cannot be written leaves nothing behind rather than a partial file a
# later rebind would read as this session's.
publish_pending_record() {  # <pid> <session-id> <transcript-path>
  local pending tmp
  pending=$(pending_path "$1")
  tmp="$pending.$$"
  printf 'status=ok\nharness_pid=%s\nsession_id=%s\ntranscript_path=%s\nrecorded_at=%s\n' \
    "$1" "$2" "$3" "$(date +%s)" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; discard_pending_record "$1"; return 0; }
  mv -f "$tmp" "$pending" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; discard_pending_record "$1"; }
  return 0
}

# Remove only the stash named by <pid>. Every other session's stash is left
# where it is, for the reason record_transcript_position gives.
discard_pending_record() {  # <pid>
  local pending
  pending=$(pending_path "$1")
  rm -f "$pending" 2>/dev/null || : > "$pending" 2>/dev/null || true
}

# Remove every stash written before this container started: its pid names a
# process in a pid table that no longer exists, and the same small numbers are
# handed out again in this one. A reading that cannot be taken never proves a
# stash current, so such a stash is removed rather than kept.
sweep_stale_pending_records() {
  local pending
  for pending in "$PENDING_PREFIX"*; do
    [ -e "$pending" ] || continue
    file_postdates_this_container "$pending" && continue
    rm -f "$pending" 2>/dev/null || : > "$pending" 2>/dev/null || true
  done
}

# publish_transcript_record <pid> <session-id> <transcript-path> <error>: write
# the whole record atomically, as an error record when <error> is non-empty. A
# record that cannot be written or replaced leaves nothing behind, for the
# reason invalidate_transcript_record gives.
publish_transcript_record() {
  local pid=$1 sid=$2 path=$3 err=$4 tmp
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

# Rebind the record to the holder named in this home's session lock, after
# bin/fm-session-start.sh has acquired it - whether by an ordinary acquisition
# or by superseding a dead container's lock. This hook may have run before that
# acquisition against a record it was right to leave alone, and wrote nothing
# for this session; without this the record still names a dead harness and the
# context ceiling is reported unenforced for the whole life of the new session.
# Measured on this seat 2026-09-06: a record naming the pre-rebuild session's
# pid 147 left the ceiling unenforced from 11:32Z to the end of the day, because
# the lock was cleared and session start re-run inside the same harness process,
# where no second SessionStart hook fires. The owner is the
# pid the new lock names, in this process's own pid table, because that is the
# value the consumer compares the record against. The SessionStart payload that
# carries session_id and transcript_path is not available here and is never
# invented: a record that already names that holder AND was written after this
# container started is left as it is, and any other is replaced by an explicit
# error naming the new holder, so the reader reports an unmeasured ceiling with
# its cause instead of a mismatch against a dead harness. Pid equality alone is
# not enough, because the record persists with the home and a fresh pid table
# hands out the same small numbers again: the previous container's ok record
# can name the very pid this container's harness got, and leaving it would
# measure the previous container's transcript for the life of this session. The
# record's age is its mtime, the same kernel-set reading the lock predicate
# uses, and an age or container start that cannot be read never proves the
# record current. Prints one line saying what it did, and nothing at all when
# the record already names the holder and is current, so an ordinary healthy
# session start carries no extra line.
file_postdates_this_container() {  # <path>
  local mtime started
  mtime=$(fm_file_mtime_epoch "$1") || return 1
  started=$(fm_container_start_epoch) || return 1
  [ "$mtime" -ge "$started" ]
}

record_postdates_this_container() {
  file_postdates_this_container "$RECORD"
}

# Promote the stash this session left at its own SessionStart into the record.
# Only the file named by <holder> - the pid the lock now publishes - is read,
# and it is promoted when its own harness_pid names that holder and it was
# written after this container started. Both tests are the record's own: a
# stash naming another pid belongs to another session, and a stash predating
# this container was written in a pid table that no longer exists, where the
# same small pid numbers are handed out again. Returns 1 when there is nothing
# promotable, leaving the record untouched for the caller's error path. The
# holder's stash is discarded either way: it has served its one purpose, and a
# stash left behind would be promoted again by a later rebind against a pid it
# no longer describes. Every other session's stash is left alone.
promote_pending_record() {  # <holder-pid>
  local holder=$1 pending pid sid path
  pending=$(pending_path "$holder")
  pid=$(kv_field "$pending" harness_pid) || return 1
  sid=$(kv_field "$pending" session_id) || { discard_pending_record "$holder"; return 1; }
  path=$(kv_field "$pending" transcript_path) || { discard_pending_record "$holder"; return 1; }
  if [ "$pid" != "$holder" ] || [ -z "$sid" ] || [ -z "$path" ] \
     || ! file_postdates_this_container "$pending"; then
    discard_pending_record "$holder"
    return 1
  fi
  discard_pending_record "$holder"
  publish_transcript_record "$holder" "$sid" "$path" ""
  [ "$(record_field status)" = ok ] && [ "$(record_field harness_pid)" = "$holder" ]
}

rebind_record_to_lock() {
  local lock_pid mine_ns
  sweep_stale_pending_records
  if ! fm_session_lock_record_read "$LOCK"; then
    invalidate_transcript_record
    printf 'context-ceiling record: the lock cannot be read back (%s), so the previous record was removed rather than left naming a dead harness\n' \
      "$FM_LOCK_RECORD_ERROR"
    return 0
  fi
  lock_pid=$FM_LOCK_RECORD_PID
  case "$lock_pid" in
    ''|*[!0-9]*|0|1)
      invalidate_transcript_record
      printf 'context-ceiling record: the lock names no usable holder pid, so the previous record was removed rather than left naming a dead harness\n'
      return 0 ;;
  esac
  mine_ns=$(fm_pid_namespace_token) || {
    printf 'context-ceiling record: this session cannot name its own pid table, so the record was left alone\n'
    return 0
  }
  if [ "$FM_LOCK_RECORD_PIDNS" != "$mine_ns" ]; then
    printf 'context-ceiling record: the lock names pid table %s rather than this session'"'"'s, so the record was left alone\n' \
      "$FM_LOCK_RECORD_PIDNS"
    return 0
  fi
  if [ "$(record_field harness_pid)" = "$lock_pid" ] && record_postdates_this_container; then
    return 0
  fi
  if promote_pending_record "$lock_pid"; then
    printf 'context-ceiling record: rebound to harness pid %s from the transcript this session recorded at its own start, which the lock standing then forbade publishing\n' \
      "$lock_pid"
    return 0
  fi
  publish_transcript_record "$lock_pid" "" "" rebound-without-hook-payload
  if [ "$(record_field harness_pid)" = "$lock_pid" ]; then
    printf 'context-ceiling record: rebound to harness pid %s as an explicit error (rebound-without-hook-payload), because no SessionStart payload naming this session'"'"'s transcript is available to rebind from; the ceiling is reported unenforced with that cause until this session records its transcript again\n' \
      "$lock_pid"
  else
    printf 'context-ceiling record: could not be rebound to harness pid %s, so the previous record was removed rather than left naming a dead harness\n' \
      "$lock_pid"
  fi
  return 0
}

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
if [ "${1-}" = --rebind-to-lock ]; then
  rebind_record_to_lock
  exit 0
fi
record_transcript_position

lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
