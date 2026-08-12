#!/usr/bin/env bash
# tests/fm-journal.test.sh - the append-only event journal (bin/fm-journal-lib.sh,
# bin/fm-journal.sh).
#
# The first case is the one that matters, and it is deliberately driven by the
# REAL watcher and the REAL drain rather than by hand-written queue rows: it
# records a live sequence, then asserts the two properties the journal exists
# for by comparing the journal against what that same sequence actually
# delivered. Both assertions would still pass against a fixture written to
# match the implementation, which is why neither side of the comparison is
# written by this file.
#
# Queue losslessness and drain behavior itself belong to fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
JOURNAL="$ROOT/bin/fm-journal.sh"

fm_test_tmproot TMP_ROOT fm-journal-tests

# Run the real watcher once in session mode, which exits after it enqueues an
# actionable wake. Same invocation the wake-queue suite uses for a live signal.
run_watcher_once() {
  local dir=$1 state=$2 out=$3
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40
}

journal_read() {
  FM_STATE_OVERRIDE="$1" "$JOURNAL" read
}

journal_field() {  # <state> <seq> <1-based field>
  FM_STATE_OVERRIDE="$1" "$JOURNAL" read | awk -F '\t' -v seq="$2" -v f="$3" '$1 == seq { print $f }'
}

append_journal_wake() {  # <state> <key> <payload>
  append_wake "$1" signal "$2" "$3"
}

test_live_sequence_keeps_both_events_and_the_state_each_arrived_with() {
  local dir state out drain_out status_file lines first_snapshot second_snapshot
  local delivered_signals
  dir=$(make_case live-sequence)
  state="$dir/state"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"

  # Two events, one key. Each carries a captain-relevant verb so the watcher
  # surfaces rather than absorbs it, and the status file MOVES between them -
  # which is the condition under which a payload resolved later stops being the
  # payload that arrived.
  printf 'blocked: first line\n' > "$status_file"
  run_watcher_once "$dir" "$state" "$out" || fail "watcher did not exit for the first event"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not surface the first event"

  printf 'done: second line\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$dir" "$state" "$out" || fail "watcher did not exit for the second event"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not surface the second event"

  # What the fleet actually delivered for that sequence.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain of the live sequence failed"
  delivered_signals=$(awk -F '\t' '$3 == "signal" && $4 == "task.status" { count++ } END { print count + 0 }' "$drain_out")
  [ "$delivered_signals" -eq 1 ] \
    || fail "expected the delivery view to collapse the pair to 1 record, it carried $delivered_signals"

  # Property one: both events are retained, and readable in arrival order.
  lines=$(journal_read "$state" | awk -F '\t' '$3 == "signal" && $4 == "task.status"' | wc -l | tr -d ' ')
  [ "$lines" -eq 2 ] \
    || fail "journal kept $lines of the 2 events sharing one key that the delivery view collapsed to 1"
  journal_read "$state" | awk -F '\t' '{ if ($1 + 0 <= prev) { exit 1 } prev = $1 + 0 }' \
    || fail "journal records are not in ascending arrival order"

  # Property two: each event carries the state as it read AT ARRIVAL, not as it
  # read once the drain got to it. The drain's own annotation is the control:
  # it reports the LATER line for the SAME key, from the same file, because it
  # reads that file at drain time.
  first_snapshot=$(journal_field "$state" 1 7)
  second_snapshot=$(journal_field "$state" 2 7)
  [ "$first_snapshot" = "blocked: first line" ] \
    || fail "first event's captured state was '$first_snapshot', not the line the file held when it arrived"
  [ "$second_snapshot" = "done: second line" ] \
    || fail "second event's captured state was '$second_snapshot', not the line the file held when it arrived"
  grep -F 'wake annotation:' "$drain_out" | grep -F 'done: second line' >/dev/null \
    || fail "control failed: the drain annotation did not resolve the later line, so the contrast is unproven"
  grep -F 'wake annotation:' "$drain_out" | grep -F 'blocked: first line' >/dev/null \
    && fail "control failed: the drain annotation carried the arrival line, so nothing distinguishes the journal"

  pass "a live watcher sequence keeps both same-key events in arrival order, each with the state it arrived with"
}

test_journal_records_the_queue_sequence_it_describes() {
  local dir state queue_seq origin
  dir=$(make_case queue-coordinates)
  state="$dir/state"
  printf 'blocked: only\n' > "$state/task.status"
  append_journal_wake "$state" task.status "signal: $state/task.status" || fail "append failed"
  queue_seq=$(awk -F '\t' '{ print $2 }' "$state/.wake-queue")
  origin=$(journal_field "$state" 1 5)
  [ -n "$queue_seq" ] || fail "no queue record was written"
  [ "$origin" = "$queue_seq" ] \
    || fail "journal recorded queue coordinate '$origin' for queue record '$queue_seq'"
  pass "a journal record names the queue record it describes, so the two can be matched without guessing"
}

test_reader_tails_from_a_sequence() {
  local dir state seen
  dir=$(make_case tail)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "first append failed"
  append_journal_wake "$state" b.status "signal: b" || fail "second append failed"
  append_journal_wake "$state" c.status "signal: c" || fail "third append failed"
  seen=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" read --since 1 | awk -F '\t' '{ printf "%s ", $4 }')
  [ "$seen" = "b.status c.status " ] || fail "--since 1 returned '$seen' instead of the records above it"
  seen=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" read --since 1 --limit 1 | awk -F '\t' '{ printf "%s ", $4 }')
  [ "$seen" = "b.status " ] || fail "--limit took '$seen' instead of the oldest unseen record"
  pass "a consumer tails the journal by sequence and advances oldest-first"
}

test_status_reports_a_gap_rather_than_a_whole_stream() {
  local dir state gaps
  dir=$(make_case gap)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "first append failed"
  append_journal_wake "$state" b.status "signal: b" || fail "second append failed"
  append_journal_wake "$state" c.status "signal: c" || fail "third append failed"
  # Stand in for a record that took a sequence number and never reached disk.
  grep -v "$(printf '^2\t')" "$state/journal/events.tsv" > "$state/journal/events.trim" \
    || fail "could not build the gapped stream"
  mv "$state/journal/events.trim" "$state/journal/events.tsv"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  [ "$gaps" = "1" ] || fail "status reported '$gaps' gaps for a stream missing one record"
  pass "status reports a missing record as a gap instead of presenting the stream as whole"
}

test_status_reports_allocated_records_missing_from_the_tail() {
  local dir state gaps last horizon
  dir=$(make_case trailing-gap)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "first append failed"
  append_journal_wake "$state" b.status "signal: b" || fail "second append failed"
  printf '4\n' > "$state/journal/.seq"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  last=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "last" { print $2 }')
  horizon=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "horizon" { print $2 }')
  [ "$gaps" = "2" ] || fail "status reported '$gaps' gaps for two allocated tail records missing from disk"
  [ "$last" = "4" ] || fail "status reported last '$last' instead of the allocated sequence 4"
  [ "$horizon" = "1" ] || fail "status changed horizon '$horizon' while accounting for trailing gaps"

  rm -f "$state/journal/events.tsv"
  printf '1\n' > "$state/journal/.seq"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  last=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "last" { print $2 }')
  horizon=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "horizon" { print $2 }')
  [ "$gaps" = "1" ] || fail "status reported '$gaps' gaps when the only allocation never reached disk"
  [ "$last" = "1" ] || fail "status reported last '$last' when the only allocation never reached disk"
  [ "$horizon" = "none" ] || fail "status invented horizon '$horizon' for an empty retained stream"

  printf 'not-a-sequence\n' > "$state/journal/.seq"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  [ "$gaps" = "unknown" ] || fail "status reported '$gaps' instead of unknown for an invalid allocation sequence"
  pass "status includes valid trailing allocations without confusing them with the retention horizon"
}

test_invalid_sequence_recovers_without_reusing_a_retained_number() {
  local dir state order gaps
  dir=$(make_case sequence-recovery)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "first append failed"
  append_journal_wake "$state" b.status "signal: b" || fail "second append failed"
  : > "$state/journal/.seq"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  [ "$gaps" = "unknown" ] || fail "empty sequence state was presented as '$gaps' gaps instead of unknown"
  append_journal_wake "$state" c.status "signal: c" || fail "append after empty sequence state failed"
  order=$(journal_read "$state" | awk -F '\t' '{ printf "%s ", $1 }')
  [ "$order" = "1 2 3 " ] || fail "sequence recovery produced '$order' instead of continuing above retained records"
  pass "invalid sequence state stays unknown and allocation recovers above retained records"
}

test_failures_before_and_after_sequence_publication_stay_visible() {
  local dir state gaps unrecorded
  dir=$(make_case failure-accounting)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "initial append failed"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_journal_rotate_if_full() { return 1; }
    FM_JOURNAL_MAX_BYTES=0
    fm_wake_append signal rotation.status "signal: rotation"
  ' _ "$ROOT/bin/fm-wake-lib.sh" 2>/dev/null || fail "rotation failure escaped into delivery"
  gaps=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "gaps" { print $2 }')
  [ "$gaps" = "1" ] || fail "failed rotation produced '$gaps' gaps instead of one burned sequence"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_journal_publish_sequence() { return 1; }
    eval "$(declare -f fm_lock_release | sed "1s/fm_lock_release/fm_lock_release_original/")"
    fm_lock_release() {
      [ "$1" != "$FM_JOURNAL_LOCK" ] || awk "END { exit !(NR == 1) }" "$FM_JOURNAL_UNRECORDED" || exit 8
      fm_lock_release_original "$@"
    }
    fm_wake_append signal publish.status "signal: publish"
  ' _ "$ROOT/bin/fm-wake-lib.sh" 2>/dev/null || fail "sequence publication failure was not marked before journal lock release"
  unrecorded=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "unrecorded" { print $2 }')
  [ "$unrecorded" = "1" ] || fail "failed sequence publication reported '$unrecorded' unrecorded events"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_lock_acquire_wait | sed "1s/fm_lock_acquire_wait/fm_lock_acquire_wait_original/")"
    fm_lock_acquire_wait() {
      [ "$1" != "$FM_JOURNAL_LOCK" ] || return 1
      fm_lock_acquire_wait_original "$@"
    }
    fm_wake_append signal lock.status "signal: lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" 2>/dev/null || fail "journal lock failure escaped into delivery"
  unrecorded=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "unrecorded" { print $2 }')
  [ "$unrecorded" = "2" ] || fail "failed lock acquisition reported '$unrecorded' unrecorded events"
  pass "journal failures either burn a sequence or increment durable unrecorded accounting"
}

test_torn_record_does_not_consume_the_next_record() {
  local dir state order
  dir=$(make_case torn-record)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "initial append failed"
  printf '2\t1\tsignal\ttorn.status' >> "$state/journal/events.tsv"
  printf '2\n' > "$state/journal/.seq"
  append_journal_wake "$state" c.status "signal: c" || fail "append after torn record failed"
  order=$(journal_read "$state" | awk -F '\t' '{ printf "%s ", $1 }')
  [ "$order" = "1 3 " ] || fail "torn record consumed the following record: '$order'"
  pass "a torn append is isolated before the next complete record"
}

test_fresh_home_status_is_quiet_and_unknown() {
  local dir state out err gaps
  dir=$(make_case fresh-status)
  state="$dir/state"
  out="$dir/status.out"
  err="$dir/status.err"
  FM_STATE_OVERRIDE="$state" "$JOURNAL" status > "$out" 2> "$err" || fail "fresh-home status failed"
  [ ! -s "$err" ] || fail "fresh-home status wrote a lock diagnostic: $(cat "$err")"
  gaps=$(awk -F ': ' '$1 == "gaps" { print $2 }' "$out")
  [ "$gaps" = "unknown" ] || fail "fresh-home status reported '$gaps' gaps instead of unknown"
  pass "a fresh home reports unknown quietly without attempting a journal lock"
}

test_every_accepted_wake_kind_is_journalled() {
  local dir state kind kinds recorded
  dir=$(make_case wake-kinds)
  state="$dir/state"
  kinds=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; printf "%s" "$FM_WAKE_KINDS"' _ "$ROOT/bin/fm-wake-lib.sh")
  for kind in $kinds; do
    append_wake "$state" "$kind" "$kind.key" "$kind payload" || fail "accepted wake kind '$kind' failed"
  done
  recorded=$(journal_read "$state" | awk -F '\t' '{ printf "%s ", $3 }')
  [ "$recorded" = "$kinds " ] || fail "accepted wake kinds journalled as '$recorded'"
  pass "every wake kind accepted for delivery is accepted by the journal"
}

test_unlocked_reader_does_not_advance_past_a_rotated_tail() {
  local dir state order
  dir=$(make_case unlocked-rotation)
  state="$dir/state"
  append_journal_wake "$state" a.status "signal: a" || fail "first append failed"
  append_journal_wake "$state" b.status "signal: b" || fail "second append failed"
  order=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait() { return 1; }
    cat() {
      command cat "$@"
      if [ "$1" = "$FM_JOURNAL_ACTIVE" ] && [ ! -f "$STATE/rotated" ]; then
        mv "$FM_JOURNAL_ACTIVE" "$FM_JOURNAL_PREVIOUS"
        printf "3\t1\tsignal\tc.status\t3\tsignal: c\t\n" > "$FM_JOURNAL_ACTIVE"
        : > "$STATE/rotated"
      fi
    }
    fm_journal_cat
  ' _ "$ROOT/bin/fm-journal-lib.sh" | awk -F '\t' '{ printf "%s ", $1 }')
  [ "$order" = "1 2 " ] || fail "unlocked rotation read returned '$order' instead of the tail present when reading began"
  pass "an unlocked read cannot advance past an older tail moved by rotation"
}

test_a_queued_wake_survives_a_journal_that_cannot_be_written() {
  local dir state err rc queued
  dir=$(make_case journal-unwritable)
  state="$dir/state"
  err="$dir/append.err"
  # A regular file where the journal directory belongs: mkdir -p refuses it, on
  # every platform, without needing the suite to run as anyone in particular.
  mkdir -p "$state"
  : > "$state/journal"
  rc=0
  append_journal_wake "$state" task.status "signal: $state/task.status" 2> "$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "an unwritable journal failed the wake append (rc=$rc); delivery must outrank the record"
  queued=$(awk -F '\t' '$3 == "signal" { count++ } END { print count + 0 }' "$state/.wake-queue")
  [ "$queued" -eq 1 ] || fail "the wake was not queued when the journal could not be written"
  grep -F 'could not be journalled' "$err" >/dev/null \
    || fail "the unrecorded wake was not reported: $(cat "$err")"
  pass "a wake that cannot be journalled is still delivered, and the failure to record it is reported"
}

test_an_oversized_field_is_marked_rather_than_silently_shortened() {
  local dir state payload recorded
  dir=$(make_case oversized)
  state="$dir/state"
  payload="signal: $(head -c 400 /dev/zero | tr '\0' 'x')"
  FM_JOURNAL_FIELD_BYTES=64 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_append signal task.status "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$payload" || fail "append with an oversized payload failed"
  recorded=$(journal_field "$state" 1 6)
  [ "${#recorded}" -eq 64 ] || fail "capped payload is ${#recorded} bytes, not the stated 64"
  case "$recorded" in
    *' [truncated]') ;;
    *) fail "a capped payload was shortened without saying so" ;;
  esac
  pass "an oversized field is capped at its stated bound and marked as capped"
}

test_retention_bound_rotates_and_moves_the_horizon() {
  local dir state horizon records order
  dir=$(make_case retention)
  state="$dir/state"
  FM_JOURNAL_MAX_BYTES=1 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_append signal a.status "signal: a"
    fm_wake_append signal b.status "signal: b"
    fm_wake_append signal c.status "signal: c"
  ' _ "$ROOT/bin/fm-wake-lib.sh" || fail "appends under the retention bound failed"
  horizon=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "horizon" { print $2 }')
  records=$(FM_STATE_OVERRIDE="$state" "$JOURNAL" status | awk -F ': ' '$1 == "records" { print $2 }')
  [ "$horizon" = "2" ] || fail "horizon is '$horizon'; the bound did not drop the oldest record"
  [ "$records" = "2" ] || fail "expected 2 retained records under the bound, got '$records'"
  order=$(journal_read "$state" | awk -F '\t' '{ printf "%s ", $1 }')
  [ "$order" = "2 3 " ] || fail "rotated stream read back as '$order' instead of oldest-first across both files"
  pass "the size bound drops the oldest records, reports the new horizon, and still reads back in arrival order"
}

test_live_sequence_keeps_both_events_and_the_state_each_arrived_with
test_journal_records_the_queue_sequence_it_describes
test_reader_tails_from_a_sequence
test_status_reports_a_gap_rather_than_a_whole_stream
test_status_reports_allocated_records_missing_from_the_tail
test_invalid_sequence_recovers_without_reusing_a_retained_number
test_failures_before_and_after_sequence_publication_stay_visible
test_torn_record_does_not_consume_the_next_record
test_fresh_home_status_is_quiet_and_unknown
test_every_accepted_wake_kind_is_journalled
test_unlocked_reader_does_not_advance_past_a_rotated_tail
test_a_queued_wake_survives_a_journal_that_cannot_be_written
test_an_oversized_field_is_marked_rather_than_silently_shortened
test_retention_bound_rotates_and_moves_the_horizon
