#!/usr/bin/env bash
# Atomically drain durable watcher wake records within a bounded echo, optionally
# annotate validated signal status keys after raw consumption commits, then
# assert liveness.
#
# Both halves of the printed output are bounded, so no queue this fleet can
# accumulate turns one wake turn into an unbounded context read: fm_wake_bound_echo
# caps the raw records and fm_wake_print_annotations caps the status-event
# annotations, both in bin/fm-wake-lib.sh, which owns the limits and the
# reasoning. Bounded never means lost. When the echo holds anything back, the
# drained queue file is preserved under state/.wake-drain-overflow.<epoch>.<pid>
# and its path is printed, so one read recovers every record in full.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=

# Defense in depth for both halves of supervision: this script runs at the top
# of every wake-handling and recovery turn, so assert daemon health and the
# session delivery-stub identity here too.
# Reuse fm-guard.sh's daemon beacon and stub-pid predicates rather than
# duplicating either calculation.
# Call after the queue is emptied so guard never reprints its own queued-wakes
# notice for records this run just drained, and never let a guard hiccup change
# the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit "$?"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

RAW_ROWS=$(fm_wake_print_deduped "$DRAIN_TMP") || exit "$?"
fm_wake_bound_echo "$RAW_ROWS" || exit "$?"
case "${FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
# Whatever the echo bound held back is preserved rather than dropped: the
# drained queue file already holds every record in full, so keeping it under a
# stable name and naming that name IS the recovery path. Preserve before
# printing, so the pointer can never name a file a crash left unwritten.
OVERFLOW_PATH=
if [ "$FM_WAKE_ECHO_OMITTED" -gt 0 ] || [ "$FM_WAKE_ECHO_SHORTENED" -gt 0 ]; then
  OVERFLOW_PATH="$STATE/.wake-drain-overflow.$(date +%s).$(fm_current_pid)"
  mv "$DRAIN_TMP" "$OVERFLOW_PATH" 2>/dev/null || OVERFLOW_PATH="$DRAIN_TMP"
  # Either way the drained file survives under a name that gets printed. A
  # rename that failed must never fall through to the delete below: these are
  # exactly the records the echo did not carry, so deleting them here would turn
  # "withheld" into "discarded" at the one moment it matters.
  DRAIN_TMP=
fi
if [ -n "$FM_WAKE_ECHO_ROWS" ]; then
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  printf '%s\n' "$FM_WAKE_ECHO_ROWS" || exit "$?"
fi
if [ -n "$OVERFLOW_PATH" ]; then
  printf 'wake echo: %s record(s) withheld and %s row(s) shortened by the drain echo bound; every drained record in full: %s\n' \
    "$FM_WAKE_ECHO_OMITTED" "$FM_WAKE_ECHO_SHORTENED" "$OVERFLOW_PATH" || exit "$?"
else
  rm -f "$DRAIN_TMP" || exit "$?"
  DRAIN_TMP=
fi
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
(fm_wake_print_annotations "$RAW_ROWS") || true
assert_watcher_liveness
exit 0
