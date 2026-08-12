#!/usr/bin/env bash
# The fleet's append-only event journal: the durable record of every
# notification event, captured at arrival and never collapsed.
#
# WHY THIS EXISTS
# The durable wake queue is a DELIVERY structure, and it is deliberately lossy
# in two ways that are right for delivery and wrong for a record:
#   1. bin/fm-wake-drain.sh collapses every record sharing one (kind, key) to
#      the last one, so of two events about the same task the first is gone by
#      the time anything reads the queue.
#   2. its status annotation reads state/<id>.status at DRAIN time, so the text
#      attached to an event is resolved from state that has moved since the
#      event arrived - the annotation says so itself, and saying so does not
#      make it a record.
# Neither is a defect in the queue. They are the reason a separate record has to
# exist. This journal is that record: every event is written once, in arrival
# order, carrying the mutable state it referred to as that state read AT THE
# MOMENT THE EVENT ARRIVED, and no record is ever rewritten or collapsed.
#
# It is bash and files. Writing it and reading it cost no model call, and
# nothing about either requires a supervising session to be awake.
#
# RECORD FORMAT
# One record per line, seven tab-separated fields, in this order:
#   seq       journal sequence, monotonic within a home, allocated under the
#             journal lock. Arrival order IS ascending seq.
#   epoch     arrival time in seconds. For a queued wake this is the same epoch
#             the queue record carries, not a second reading of the clock.
#   kind      the event kind (see FM_JOURNAL_KINDS).
#   key       the event key, verbatim from the producer.
#   origin    this record's coordinates in the structure that produced it. For
#             a queued wake, the wake queue's own sequence number, so a journal
#             record and the queue record it describes can be matched without
#             guessing. Empty when the producer has no such coordinate.
#   payload   the payload as the producer composed it at arrival.
#   snapshot  the arrival-time capture of the mutable state the payload points
#             at. Today that is exactly one thing: for a signal whose key names
#             a task status file, the last line that file held when the event
#             arrived. Empty when no mutable state applies.
# No field can contain a tab, a carriage return, or a newline: every field is
# put through fm_wake_clean_field on the way in, the same cleaning the wake
# queue already applies, so one line is always one whole record.
#
# RETENTION - DELIBERATELY CRUDE, SEE docs/event-journal.md
# A size bound, not a policy: when the active file reaches FM_JOURNAL_MAX_BYTES
# it is rotated over the single previous file, so the journal occupies at most
# two files of that size. Records below the retained horizon are gone, and
# fm-journal.sh reports the horizon rather than letting a reader mistake a
# truncated stream for a complete one. Choosing a real retention policy is
# deferred work, recorded as such rather than dressed up as one here.
#
# PRIVACY
# The journal captures only text that was already on its way into a supervising
# session's context: payloads firstmate's own watcher composed, and the last
# line of a task's own status file - the very line bin/fm-wake-drain.sh already
# reads and prints as an annotation. It reads no project file, no environment,
# and no credential store, and it adds no new exposure surface; it only holds
# the same text for longer. A crewmate that writes a secret into its status line
# has already published it to the supervisor, and this journal will keep that
# copy until the horizon passes it.

FM_JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_WAKE_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_JOURNAL_LIB_DIR/fm-wake-lib.sh"
fi

FM_JOURNAL_DIR="${FM_JOURNAL_DIR:-$STATE/journal}"
FM_JOURNAL_ACTIVE="$FM_JOURNAL_DIR/events.tsv"
FM_JOURNAL_PREVIOUS="$FM_JOURNAL_DIR/events.previous.tsv"
FM_JOURNAL_LOCK="$FM_JOURNAL_DIR/.lock"
FM_JOURNAL_SEQ_FILE="$FM_JOURNAL_DIR/.seq"
# Event kinds this journal accepts. Today it is exactly the wake queue's own
# vocabulary, spelled the same way, so a journal record needs no translation to
# be read as the wake it describes. Later units add their own kinds here rather
# than deriving one event from another: an arm cycle and a queued notification
# were measured as 391 against 354 in one window, so neither is recoverable
# from the other.
FM_JOURNAL_KINDS="signal stale check heartbeat"
# One record's variable-length fields are capped so a single pathological
# payload cannot consume the whole size bound and hide every other record behind
# itself. Well clear of any payload this fleet's watcher composes.
FM_JOURNAL_FIELD_BYTES="${FM_JOURNAL_FIELD_BYTES:-16384}"
FM_JOURNAL_MAX_BYTES="${FM_JOURNAL_MAX_BYTES:-8388608}"

fm_journal_kind_valid() {  # <kind>
  local kind=$1 known
  for known in $FM_JOURNAL_KINDS; do
    [ "$kind" = "$known" ] && return 0
  done
  return 1
}

# Cap one field, marking it when the cap bites. A silently shortened record
# reads as a whole one, which is the failure mode this journal exists against.
fm_journal_cap_field() {  # <text> -> capped text on stdout
  local text=$1 marker=' [truncated]' keep
  local LC_ALL=C
  if [ "${#text}" -le "$FM_JOURNAL_FIELD_BYTES" ]; then
    printf '%s' "$text"
    return 0
  fi
  keep=$((FM_JOURNAL_FIELD_BYTES - ${#marker}))
  [ "$keep" -gt 0 ] || keep=0
  printf '%s%s' "${text:0:$keep}" "$marker"
}

# Capture the mutable state an arriving event points at, AT ARRIVAL.
#
# This is the whole difference between this journal and the drain annotation
# that reads the same file later, so it is called by fm_wake_append before it
# takes any lock - as early in the event's life as the code can reach - and its
# result is carried into the record rather than recomputed at write time.
# Reuses fm-wake-lib.sh's validated key mapping and bounded tail read rather
# than opening a second path to the same files.
FM_JOURNAL_SNAPSHOT=
fm_journal_capture() {  # <kind> <key>
  local kind=$1 key=$2 path
  FM_JOURNAL_SNAPSHOT=
  [ "$kind" = signal ] || return 0
  fm_wake_status_key_map "$key" || return 0
  path="$STATE/$FM_WAKE_STATUS_KEY"
  fm_wake_latest_event "$path" 8192 || return 0
  FM_JOURNAL_SNAPSHOT=$FM_WAKE_EVENT_LINE
  [ "$FM_WAKE_EVENT_TRUNCATED" = false ] || FM_JOURNAL_SNAPSHOT="$FM_JOURNAL_SNAPSHOT [truncated]"
  return 0
}

# Rotate the active file over the single previous one once it reaches the size
# bound. Called with the journal lock held.
fm_journal_rotate_if_full() {
  local size
  [ -f "$FM_JOURNAL_ACTIVE" ] || return 0
  size=$(wc -c < "$FM_JOURNAL_ACTIVE" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$FM_JOURNAL_MAX_BYTES" ] || return 0
  mv -f "$FM_JOURNAL_ACTIVE" "$FM_JOURNAL_PREVIOUS" 2>/dev/null || return 1
  return 0
}

# Append one record. Returns 0 on success, 2 on an invalid kind, 1 on any
# failure to record.
#
# A failure here must never fail the caller's own work: delivery outranks the
# record of it. Callers report the failure and carry on, and the hole the failed
# write leaves in the sequence is what fm-journal.sh reports, so a reader is
# told the stream is incomplete rather than left to assume it is whole.
fm_journal_append() {  # <kind> <key> <payload> [<origin>] [<epoch>] [<snapshot>]
  local kind=$1 key=$2 payload=$3 origin=${4:-} epoch=${5:-} snapshot=${6:-}
  local seq status=0

  fm_journal_kind_valid "$kind" || {
    printf 'fm_journal_append: invalid event kind: %s\n' "$kind" >&2
    return 2
  }
  [ -n "$epoch" ] || epoch=$(date +%s)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  origin=$(printf '%s' "$origin" | fm_wake_clean_field)
  payload=$(fm_journal_cap_field "$(printf '%s' "$payload" | fm_wake_clean_field)")
  snapshot=$(fm_journal_cap_field "$(printf '%s' "$snapshot" | fm_wake_clean_field)")

  mkdir -p "$FM_JOURNAL_DIR" 2>/dev/null || return 1
  fm_lock_acquire_wait "$FM_JOURNAL_LOCK" || return 1

  fm_journal_rotate_if_full || status=1
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$FM_JOURNAL_SEQ_FILE" 2>/dev/null || echo 0)
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    seq=$((seq + 1))
    # Allocate before writing on purpose. A crash between the two leaves a gap
    # in the sequence, which fm-journal.sh reports; reusing the number instead
    # would make a lost record indistinguishable from one that never existed.
    printf '%s\n' "$seq" > "$FM_JOURNAL_SEQ_FILE" 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$seq" "$epoch" "$kind" "$key" "$origin" "$payload" "$snapshot" \
      >> "$FM_JOURNAL_ACTIVE" 2>/dev/null || status=1
  fi

  fm_lock_release "$FM_JOURNAL_LOCK"
  return "$status"
}

# Print every retained record, oldest first. The previous file always precedes
# the active one, and within each file records are already in ascending seq
# because the lock serializes allocation and write together.
fm_journal_cat_files() {
  [ -f "$FM_JOURNAL_PREVIOUS" ] && cat "$FM_JOURNAL_PREVIOUS"
  [ -f "$FM_JOURNAL_ACTIVE" ] && cat "$FM_JOURNAL_ACTIVE"
  return 0
}

fm_journal_cat() {
  if FM_LOCK_WAIT_TIMEOUT="${FM_JOURNAL_READ_LOCK_TIMEOUT:-1}" fm_lock_acquire_wait "$FM_JOURNAL_LOCK"; then
    fm_journal_cat_files
    fm_lock_release "$FM_JOURNAL_LOCK"
  else
    fm_journal_cat_files
  fi
  return 0
}
