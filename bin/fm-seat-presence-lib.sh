#!/usr/bin/env bash
# fm-seat-presence-lib.sh - the ONE reading of "does a first mate hold this
# home", taken from the session lock and shared by both halves of seat absence.
#
# WHY THIS IS A LIBRARY AND NOT A PREDICATE IN EACH CALLER
# bin/fm-seat-alarm.sh classifies the lock record three ways and refuses to call
# a reading it could not take an absence.  bin/fm-seat-respawner.sh asked the
# same record a BOOLEAN question - "does a seat hold this?" - and every answer
# that was not a confident yes became "no seat", which is the one conversion
# that turns into a second agent window beside a first mate.  Four separate
# review findings on this branch were that same shape arriving through different
# doors: a relaunch on the retry schedule while a first turn was pending, a
# merely busy seat producing the same `undeliverable:` verdict, a hand-started
# seat taking the lock mid-respawn, and a lock record that could not be read.
# Guarding each door left the conversion in place.  So the classification moved
# here, both halves consume the same three verdicts, and "I cannot tell" can no
# longer mean "nobody is there" on one side while meaning "say so out loud" on
# the other.
#
# The verdicts are of the LOCK and nothing else:
#   present     the record names a live harness in this process's own pid table
#   absent      nothing usable is recorded, or the recorded holder is dead
#   unmeasured  the record could not be read, or names a pid table this process
#               cannot see into - never an absence, and never an all-clear
#
# `standing-down` and `unattended` are deliberately NOT here.  They are read
# from the stay-down marker and the published endpoint rather than from the
# lock, only the alarm reports them, and the respawner already reads the marker
# itself; putting them here would give this file inputs it does not own.
#
# This file is sourced by its callers and has no side effects on source. It
# needs bin/fm-harness-pid-lib.sh - the owner of the lock-record parse and of
# harness liveness - sourced first.

# Publishes, from the last fm_seat_presence call:
#   FM_SEAT_PRESENCE         one of present|absent|unmeasured
#   FM_SEAT_PRESENCE_REASON  one sentence, in the words the captain is given
#   FM_SEAT_PRESENCE_PID     the recorded holder pid, empty when none was read
# shellcheck disable=SC2034 # Read by callers after fm_seat_presence returns.
FM_SEAT_PRESENCE=
# shellcheck disable=SC2034 # Read by callers after fm_seat_presence returns.
FM_SEAT_PRESENCE_REASON=
# shellcheck disable=SC2034 # Read by callers after fm_seat_presence returns.
FM_SEAT_PRESENCE_PID=

# shellcheck disable=SC2034 # Every assignment below is read by a caller.
fm_seat_presence() {  # <session-lock-file>
  local lock=$1 ns
  FM_SEAT_PRESENCE=
  FM_SEAT_PRESENCE_REASON=
  FM_SEAT_PRESENCE_PID=
  if ! fm_session_lock_record_read "$lock"; then
    case "$FM_LOCK_RECORD_ERROR" in
      absent)
        FM_SEAT_PRESENCE=absent
        FM_SEAT_PRESENCE_REASON='no first mate holds this vessel'
        ;;
      unreadable)
        FM_SEAT_PRESENCE=unmeasured
        FM_SEAT_PRESENCE_REASON='this vessel keeps a record of which first mate holds it and that record cannot be read, so its absence cannot be told from its presence'
        ;;
      *)
        FM_SEAT_PRESENCE=unmeasured
        FM_SEAT_PRESENCE_REASON='the record naming this vessel'"'"'s first mate is not a usable file, so nothing here can say whether one is running'
        ;;
    esac
    return 0
  fi
  # shellcheck disable=SC2153 # Set by fm_session_lock_record_read above.
  FM_SEAT_PRESENCE_PID=$FM_LOCK_RECORD_PID
  case "$FM_SEAT_PRESENCE_PID" in
    ''|*[!0-9]*)
      FM_SEAT_PRESENCE_PID=
      FM_SEAT_PRESENCE=absent
      FM_SEAT_PRESENCE_REASON='no first mate holds this vessel'
      return 0
      ;;
  esac
  # A pid means nothing outside the table it was issued from. When the record
  # names a table this process cannot see into, the honest answer is that
  # liveness is unreadable from here - never that the holder is gone.
  if [ -n "$FM_LOCK_RECORD_PIDNS" ] \
    && { ! ns=$(fm_pid_namespace_token) || [ "$ns" != "$FM_LOCK_RECORD_PIDNS" ]; }; then
    FM_SEAT_PRESENCE=unmeasured
    FM_SEAT_PRESENCE_REASON='this vessel'"'"'s first mate is recorded as running somewhere this check cannot see into, so whether it is still running is unreadable from here'
    return 0
  fi
  if fm_harness_alive "$FM_SEAT_PRESENCE_PID"; then
    FM_SEAT_PRESENCE=present
    FM_SEAT_PRESENCE_REASON='a first mate is running and holds this vessel'
    return 0
  fi
  FM_SEAT_PRESENCE=absent
  FM_SEAT_PRESENCE_REASON='the first mate that held this vessel is no longer running'
}
