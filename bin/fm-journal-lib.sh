#!/usr/bin/env bash
# The fleet's append-only event journal: a durable, explicitly accountable
# record of notification events, captured at arrival and never collapsed.
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
# exist. This journal is that record: every successfully retained event stays
# distinct and in arrival order, carrying the mutable state it referred to as
# that state read AT THE MOMENT THE EVENT ARRIVED. Records are never rewritten
# or collapsed, and the read side reports known gaps rather than claiming the
# retained stream is complete.
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
# The journal retains only text already destined for a supervising session's
# context: watcher-composed payloads and the last line of a task status file,
# which bin/fm-wake-drain.sh also prints as an annotation. It reads no project
# file or credential store. Its additional privacy consequence is retention:
# the journal keeps that text after delivery until the horizon passes it. A
# crewmate that puts a secret in a status line has already exposed it to the
# supervisor, and the journal prolongs that exposure.

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
FM_JOURNAL_UNRECORDED="$FM_JOURNAL_DIR/.unrecorded"
# Event kinds this journal accepts. Today it is exactly the wake queue's own
# vocabulary, spelled the same way, so a journal record needs no translation to
# be read as the wake it describes. Later units add their own kinds here rather
# than deriving one event from another: an arm cycle and a queued notification
# were measured as 391 against 354 in one window, so neither is recoverable
# from the other.
FM_JOURNAL_KINDS="$FM_WAKE_KINDS"
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

fm_journal_highest_retained_sequence() {
  fm_journal_cat_files | LC_ALL=C awk -F '\t' 'NF >= 7 && $1 ~ /^[0-9]+$/ && $1 + 0 > highest { highest = $1 + 0 } END { print highest + 0 }'
}

fm_journal_publish_sequence() {
  local seq=$1 tmp
  tmp=$(umask 077; mktemp "$FM_JOURNAL_DIR/.seq.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$seq" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$FM_JOURNAL_SEQ_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_journal_note_unrecorded() {  # <kind> <key> <reason>
  local kind=$1 key=$2 reason=$3
  [ -d "$FM_JOURNAL_DIR" ] || return 0
  kind=$(printf '%s' "$kind" | fm_wake_clean_field)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  reason=$(printf '%s' "$reason" | fm_wake_clean_field)
  printf '%s\t%s\t%s\n' "$kind" "$key" "$reason" >> "$FM_JOURNAL_UNRECORDED" 2>/dev/null || true
}

fm_journal_separate_torn_record() {
  local last
  [ -s "$FM_JOURNAL_ACTIVE" ] || return 0
  last=$(tail -c 1 "$FM_JOURNAL_ACTIVE" 2>/dev/null) || return 1
  [ -z "$last" ] || printf '\n' >> "$FM_JOURNAL_ACTIVE" 2>/dev/null
}

# Append one record. Returns 0 on success, 2 on an invalid kind, 1 on any
# failure to record.
#
# A failure here must never fail the caller's own work: delivery outranks the
# record of it. A published sequence means this event was offered to the
# journal; its absence is the gap fm-journal.sh reports. A failure before
# publication is counted separately so a reader is never told the stream is
# complete when a delivered event was not recorded.
fm_journal_append() {  # <kind> <key> <payload> [<origin>] [<epoch>] [<snapshot>]
  local kind=$1 key=$2 payload=$3 origin=${4:-} epoch=${5:-} snapshot=${6:-}
  local seq status=0 burned=false

  fm_journal_kind_valid "$kind" || {
    fm_journal_note_unrecorded "$kind" "$key" invalid-kind
    printf 'fm_journal_append: invalid event kind: %s\n' "$kind" >&2
    return 2
  }
  [ -n "$epoch" ] || epoch=$(date +%s)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  origin=$(printf '%s' "$origin" | fm_wake_clean_field)
  payload=$(fm_journal_cap_field "$(printf '%s' "$payload" | fm_wake_clean_field)")
  snapshot=$(fm_journal_cap_field "$(printf '%s' "$snapshot" | fm_wake_clean_field)")

  mkdir -p "$FM_JOURNAL_DIR" 2>/dev/null || return 1
  if ! fm_lock_acquire_wait "$FM_JOURNAL_LOCK"; then
    fm_journal_note_unrecorded "$kind" "$key" lock-failed
    return 1
  fi

  seq=$(cat "$FM_JOURNAL_SEQ_FILE" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=$(fm_journal_highest_retained_sequence) ;; esac
  seq=$((seq + 1))
  if fm_journal_publish_sequence "$seq"; then
    burned=true
  else
    status=1
  fi
  [ "$status" -ne 0 ] || fm_journal_rotate_if_full || status=1
  [ "$status" -ne 0 ] || fm_journal_separate_torn_record || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$seq" "$epoch" "$kind" "$key" "$origin" "$payload" "$snapshot" \
      >> "$FM_JOURNAL_ACTIVE" 2>/dev/null || status=1
  fi

  [ "$status" -eq 0 ] || [ "$burned" = true ] || fm_journal_note_unrecorded "$kind" "$key" sequence-publish-failed
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

fm_journal_cat_files_unlocked() {
  [ -f "$FM_JOURNAL_ACTIVE" ] && cat "$FM_JOURNAL_ACTIVE"
  [ -f "$FM_JOURNAL_PREVIOUS" ] && cat "$FM_JOURNAL_PREVIOUS"
  return 0
}

fm_journal_normalize_records() {
  LC_ALL=C sort -t "$(printf '\t')" -k1,1n | awk -F '\t' 'NF >= 7 && !seen[$1]++'
}

fm_journal_snapshot_cleanup() {
  [ -n "${FM_JOURNAL_SNAPSHOT_FILE:-}" ] || return 0
  rm -f "$FM_JOURNAL_SNAPSHOT_FILE" 2>/dev/null || true
}

fm_journal_snapshot() {  # [status]
  local mode=${1:-read} allocated tmp unrecorded
  tmp=$(umask 077; mktemp "$STATE/.journal-snapshot.XXXXXX" 2>/dev/null) || return 1
  FM_JOURNAL_SNAPSHOT_FILE=$tmp
  trap fm_journal_snapshot_cleanup EXIT HUP INT TERM
  if [ ! -d "$FM_JOURNAL_DIR" ]; then
    [ "$mode" != status ] || printf 'allocated\tunknown\nunrecorded\tunknown\n' > "$tmp"
    cat "$tmp"
    fm_journal_snapshot_cleanup
    trap - EXIT HUP INT TERM
    return 0
  fi
  if FM_LOCK_WAIT_TIMEOUT="${FM_JOURNAL_READ_LOCK_TIMEOUT:-1}" fm_lock_acquire_wait "$FM_JOURNAL_LOCK"; then
    if [ "$mode" = status ]; then
      allocated=$(cat "$FM_JOURNAL_SEQ_FILE" 2>/dev/null || true)
      case "$allocated" in ''|*[!0-9]*) allocated=unknown ;; esac
      if [ -f "$FM_JOURNAL_UNRECORDED" ]; then
        unrecorded=$(awk 'END { print NR + 0 }' "$FM_JOURNAL_UNRECORDED" 2>/dev/null || printf unknown)
      else
        unrecorded=0
      fi
      printf 'allocated\t%s\nunrecorded\t%s\n' "$allocated" "$unrecorded" > "$tmp"
    fi
    fm_journal_cat_files >> "$tmp"
    fm_lock_release "$FM_JOURNAL_LOCK"
  else
    [ "$mode" != status ] || printf 'allocated\tunknown\nunrecorded\tunknown\n' > "$tmp"
    fm_journal_cat_files_unlocked | fm_journal_normalize_records >> "$tmp"
  fi
  cat "$tmp"
  fm_journal_snapshot_cleanup
  trap - EXIT HUP INT TERM
  return 0
}

fm_journal_cat() {
  fm_journal_snapshot read
}

fm_journal_status_snapshot() {
  fm_journal_snapshot status
  return 0
}
