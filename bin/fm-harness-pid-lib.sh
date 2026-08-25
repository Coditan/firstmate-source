#!/usr/bin/env bash
# Shared identification of the harness (agent) process behind a tool call.
# The harness process lives as long as the session, unlike the transient
# subshell pid of any one call, so it is the identity every per-session record
# is keyed on: the session lock (bin/fm-lock.sh) and the primary transcript
# record (bin/fm-sessionstart-nudge.sh) must agree on it, or a consumer of one
# record cannot tell which session the other belongs to.
# This file is sourced by its callers and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|^pi$'

# The waits, in seconds, before each extra attempt fm_harness_pid_settled makes;
# one entry per retry, so an empty value means no retry at all. ONE owner for the
# retry policy, because the budget is the whole argument: a wrong "no harness
# here" that becomes a durable record costs a day of missing protection, and the
# 1.5 seconds this spends before giving up costs nothing at session start.
FM_HARNESS_PID_RETRY_DELAYS="${FM_HARNESS_PID_RETRY_DELAYS-0.1 0.2 0.4 0.8}"

# Why the last fm_harness_pid call returned 1. The two are different claims and
# a consumer that flattens them cannot diagnose its own failure afterwards:
#   no-harness-process     the ancestry walk COMPLETED and no ancestor was a
#                          harness - a settled negative answer.
#   harness-lookup-failed  a `ps` probe failed or returned an unusable parent
#                          pid, so the walk could not be completed and the
#                          answer is UNKNOWN, not negative.
# This distinction is what makes a bounded retry meaningful rather than
# superstitious: an unknown answer can change on the next attempt.
FM_HARNESS_PID_ERROR=

# The pid the last successful fm_harness_pid found. It is published as well as
# printed so a caller can read BOTH the answer and FM_HARNESS_PID_ERROR without
# a command substitution, whose subshell would discard the error variable and
# leave the caller unable to say why it failed.
FM_HARNESS_PID=

# Print the nearest harness pid at or above the sourcing shell's own pid,
# walking at most eight parents. Return 1 when no harness ancestor is found,
# with FM_HARNESS_PID_ERROR naming which of the two failures above it was.
fm_harness_pid() {
  local pid=$$ comm args _
  FM_HARNESS_PID=
  FM_HARNESS_PID_ERROR=no-harness-process
  for _ in 1 2 3 4 5 6 7 8; do
    if ! comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
      FM_HARNESS_PID_ERROR=harness-lookup-failed
      return 1
    fi
    if ! args=$(ps -o args= -p "$pid" 2>/dev/null); then
      FM_HARNESS_PID_ERROR=harness-lookup-failed
      return 1
    fi
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      FM_HARNESS_PID_ERROR=
      FM_HARNESS_PID=$pid
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*)
        if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
          # shellcheck disable=SC2034 # Read by callers after fm_harness_pid returns.
          FM_HARNESS_PID_ERROR=
          # shellcheck disable=SC2034 # Read by callers after fm_harness_pid returns.
          FM_HARNESS_PID=$pid
          echo "$pid"; return 0
        fi
        ;;
    esac
    if ! pid=$(ps -o ppid= -p "$pid" 2>/dev/null); then
      # shellcheck disable=SC2034 # Read by callers after fm_harness_pid returns.
      FM_HARNESS_PID_ERROR=harness-lookup-failed
      return 1
    fi
    pid=$(printf '%s' "$pid" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$pid" in
      ''|*[!0-9]*)
        # shellcheck disable=SC2034 # Read by callers after fm_harness_pid returns.
        FM_HARNESS_PID_ERROR=harness-lookup-failed
        return 1
        ;;
      0|1) return 1 ;;
    esac
  done
  return 1
}

# fm_harness_pid with a bounded retry, for the callers whose wrong answer
# becomes a DURABLE record rather than an immediate visible failure.
# bin/fm-sessionstart-nudge.sh is the one that needs it: its answer is written
# into state/.primary-transcript, is not rewritten until the next primary
# session start, and an unidentified owner there leaves the context ceiling
# unenforced for the whole life of the session. bin/fm-lock.sh deliberately does
# not use it - a lock it cannot acquire stops session start with a message on
# the spot, which is already the loudest possible failure.
# It publishes FM_HARNESS_PID and FM_HARNESS_PID_ERROR from the LAST attempt, so
# a caller that has to record its own failure records the one it actually ended
# on rather than the first one it saw.
fm_harness_pid_settled() {
  local delay
  fm_harness_pid && return 0
  for delay in $FM_HARNESS_PID_RETRY_DELAYS; do
    sleep "$delay" 2>/dev/null || true
    fm_harness_pid && return 0
  done
  return 1
}

# Return 0 when $1 is a live process that looks like a harness.
fm_harness_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

# --- the pid table a recorded pid belongs to -------------------------------
# A pid is only meaningful inside one process-id table. `kill -0` resolves it in
# the CALLER's table, so a reader in a different pid namespace tests a number
# against a table the number was never issued from, finds nothing, and concludes
# the process is dead. Measured on this fleet's own host on 2026-08-25: a host
# pid answered `kill -0` from the host and did NOT answer it from an unprivileged
# `unshare --user --pid --fork` namespace, while `ps` still saw it through the
# host /proc that was still mounted - so even a reader that consults both is
# answered "dead" by the first test.
# That is why every session-lock record names the table its pid came from. The
# comparison is not decoration: it is what lets a reader say "I cannot see that
# process" instead of "that process is gone", and those are different answers.

# Print a token naming this process's pid table. Return 1 when none can be
# formed, which a caller must treat as "I cannot say which table I am in" and
# never as a match.
# On Linux the namespace inode identifies the table within one kernel, and the
# machine-id scopes it across machines sharing a home. The boot id is not used:
# after a reboot it would make the old record foreign and wedge the home instead
# of letting the dead holder free normally. If either stable machine identity or
# namespace identity cannot be read, Linux refuses rather than publishing a
# token that can collide. On kernels without pid namespaces the whole machine is
# one table, so the machine names it with its host name included.
fm_pid_namespace_token() {
  local token sys host machine
  sys=$(uname -s 2>/dev/null) || return 1
  sys=${sys//[[:space:]]/}
  [ -n "$sys" ] || return 1
  if [ "$sys" = Linux ]; then
    token=$(readlink /proc/self/ns/pid 2>/dev/null) || return 1
    token=${token//[[:space:]]/}
    [ -n "$token" ] || return 1
    machine=$(cat /etc/machine-id 2>/dev/null) || return 1
    machine=${machine//[[:space:]]/}
    [ -n "$machine" ] || return 1
    printf 'linux:%s:%s\n' "$machine" "$token"
    return 0
  fi
  host=$(uname -n 2>/dev/null) || return 1
  host=${host//[[:space:]]/}
  [ -n "$host" ] || return 1
  printf 'nons:%s:%s\n' "$sys" "$host"
}

# The session-lock record, as published by bin/fm-lock.sh:
#
#     <holder-pid>
#     pidns=<token>
#     handover=<ticket>        (present only while an offer stands)
#
# Line one stays the bare pid it has always been, so every reader that already
# takes the first line keeps working unchanged; the fields below it are additive.
# ONE owner for the parse, because a second copy of it would decide "who holds
# this home" by its own rules the moment either is edited.
#
# Publishes FM_LOCK_RECORD_PID, FM_LOCK_RECORD_PIDNS and FM_LOCK_RECORD_HANDOVER.
# Returns 1 when the path is absent, is not a usable regular file, or cannot be
# read - three conditions a caller must keep apart from an empty record, which
# is why FM_LOCK_RECORD_ERROR names which one it was.
FM_LOCK_RECORD_PID=
FM_LOCK_RECORD_PIDNS=
FM_LOCK_RECORD_HANDOVER=
FM_LOCK_RECORD_ERROR=
fm_session_lock_record_read() {  # <lock-file>
  local lock=$1 body line
  FM_LOCK_RECORD_PID=
  FM_LOCK_RECORD_PIDNS=
  FM_LOCK_RECORD_HANDOVER=
  FM_LOCK_RECORD_ERROR=
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    FM_LOCK_RECORD_ERROR=absent
    return 1
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_RECORD_ERROR=not-a-regular-file
    return 1
  fi
  # cat rather than one `read`: a record written without a trailing newline makes
  # `read` report failure even though it filled the variable, and a holder
  # mistaken for absent is the takeover this whole file exists to stop.
  body=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_RECORD_ERROR=unreadable
    return 1
  }
  FM_LOCK_RECORD_PID=${body%%$'\n'*}
  FM_LOCK_RECORD_PID=${FM_LOCK_RECORD_PID//[[:space:]]/}
  while IFS= read -r line; do
    line=${line//[[:space:]]/}
    # shellcheck disable=SC2034 # Both fields are read by callers after fm_session_lock_record_read returns.
    case "$line" in
      pidns=*) FM_LOCK_RECORD_PIDNS=${line#pidns=} ;;
      handover=*) FM_LOCK_RECORD_HANDOVER=${line#handover=} ;;
    esac
  done <<< "$body"
  return 0
}

# Return 0 when this session cannot show the home is free: the session lock path
# <lock> exists but is not a usable regular file (including any symlink), cannot
# be read at all, names a holder whose pid table this session cannot see into,
# or names a LIVE harness process that is not <my-harness-pid> - exactly the
# conditions bin/fm-lock.sh refuses acquisition on, and therefore the conditions
# under which this session will get no fleet authority at all. A lock path absent
# altogether returns 1 (free).
# ONE owner, because the lock and the primary transcript record have to agree on
# who this home's session is: a second copy of "another session holds this home"
# would let a session be refused the lock by one test and take over the record
# by another, which is precisely the gap this predicate exists to close.
# An empty <my-harness-pid> - a session that could not identify itself - never
# equals the holder and is therefore refused. That is the conservative reading
# rather than an accident: a session that cannot prove it is the holder must not
# act as one.
#
# The pid-table comparison is what makes this predicate answerable across a
# container boundary, and it is deliberately NOT a liveness test that has been
# loosened. A holder recorded in another table is refused, not probed: this
# session has no way to see whether that process is alive, and a reader that
# cannot see must say so rather than assume the answer it would prefer. Passing
# ownership to such a session is what `fm-lock.sh handover` exists for; there is
# no path here that takes it by guessing.
#
# Publishes FM_SESSION_LOCK_VERDICT so a caller can name WHICH refusal it hit
# without re-reading and re-deciding the record itself:
#   free          nothing usable is recorded, or the recorded holder is dead
#   mine          the recorded holder is this session
#   held          a live harness holds it, in this session's own pid table
#   foreign       a holder is recorded in a pid table this session cannot see
#   unreadable    the record exists and cannot be read
#   nonregular    the lock path is not a usable regular file
#   unidentified  this session cannot name its own pid table
FM_SESSION_LOCK_VERDICT=
FM_SESSION_LOCK_LEGACY=0
fm_session_lock_held_by_other() {  # <lock-file> <my-harness-pid>
  local lock=$1 me=$2 mine_ns
  FM_SESSION_LOCK_VERDICT=free
  FM_SESSION_LOCK_LEGACY=0
  if ! fm_session_lock_record_read "$lock"; then
    case "$FM_LOCK_RECORD_ERROR" in
      absent) FM_SESSION_LOCK_VERDICT=free; return 1 ;;
      not-a-regular-file) FM_SESSION_LOCK_VERDICT=nonregular; return 0 ;;
      *) FM_SESSION_LOCK_VERDICT=unreadable; return 0 ;;
    esac
  fi
  # shellcheck disable=SC2153 # Assigned by fm_session_lock_record_read just above; not a misspelling of FM_LOCK_RECORD_PIDNS.
  # shellcheck disable=SC2153 # Assigned by fm_session_lock_record_read just above; not a misspelling of FM_LOCK_RECORD_PIDNS.
  case "$FM_LOCK_RECORD_PID" in
    ''|*[!0-9]*) FM_SESSION_LOCK_VERDICT=free; return 1 ;;
  esac
  if [ "$FM_LOCK_RECORD_PID" = "$me" ] && [ -n "$me" ]; then
    # Same number, and this session's own table by construction - but only when
    # the record agrees about the table. A record naming another table with the
    # same pid number is a DIFFERENT process that happens to share an integer,
    # and reading it as ours is the collision this comparison exists to catch.
    if [ -z "$FM_LOCK_RECORD_PIDNS" ]; then
      FM_SESSION_LOCK_LEGACY=1
      FM_SESSION_LOCK_VERDICT=mine
      return 1
    fi
    if mine_ns=$(fm_pid_namespace_token) && [ "$mine_ns" = "$FM_LOCK_RECORD_PIDNS" ]; then
      FM_SESSION_LOCK_VERDICT=mine
      return 1
    fi
    FM_SESSION_LOCK_VERDICT=foreign
    return 0
  fi
  if [ -n "$FM_LOCK_RECORD_PIDNS" ]; then
    if ! mine_ns=$(fm_pid_namespace_token); then
      FM_SESSION_LOCK_VERDICT=unidentified
      return 0
    fi
    if [ "$mine_ns" != "$FM_LOCK_RECORD_PIDNS" ]; then
      FM_SESSION_LOCK_VERDICT=foreign
      return 0
    fi
  else
    # A record with no table named is one this fork wrote before it recorded
    # them. It is read the way it was written - as a pid in the reader's own
    # table - and the first acquisition after it replaces it with a record that
    # names one. That transitional reading is the ONE case here that cannot tell
    # a foreign holder from a dead one, which is why bin/fm-lock.sh says so out
    # loud when it takes such a lock rather than upgrading it silently.
    # shellcheck disable=SC2034 # Read by callers after the predicate returns.
    FM_SESSION_LOCK_LEGACY=1
  fi
  if fm_harness_alive "$FM_LOCK_RECORD_PID"; then
    FM_SESSION_LOCK_VERDICT=held
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers after the predicate returns.
  FM_SESSION_LOCK_VERDICT=free
  return 1
}
