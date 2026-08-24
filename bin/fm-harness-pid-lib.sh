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
#   harness-lookup-failed  a `ps` probe failed, so the walk could not be
#                          completed and the answer is UNKNOWN, not negative.
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
    pid=${pid//[[:space:]]/}
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
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

# Return 0 when this session cannot show the home is free: the session lock path
# <lock> exists but is not a usable regular file (including any symlink), cannot
# be read at all, or is held by a LIVE harness process that is not
# <my-harness-pid> - exactly the conditions bin/fm-lock.sh refuses acquisition
# on, and therefore the conditions under which this session will get no fleet
# authority at all. A lock path absent altogether returns 1 (free).
# ONE owner, because the lock and the primary transcript record have to agree on
# who this home's session is: a second copy of "another session holds this home"
# would let a session be refused the lock by one test and take over the record
# by another, which is precisely the gap this predicate exists to close.
# An empty <my-harness-pid> - a session that could not identify itself - never
# equals the holder and is therefore refused. That is the conservative reading
# rather than an accident: a session that cannot prove it is the holder must not
# act as one.
fm_session_lock_held_by_other() {  # <lock-file> <my-harness-pid>
  local lock=$1 me=$2 holder
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 0
  # Read with cat rather than one `read`: a lock file written without a trailing
  # newline makes `read` report failure even though it filled the variable, and
  # a holder mistaken for absent is the takeover this predicate exists to stop.
  # A lock that exists and cannot be READ is answered the same way, and for the
  # same reason: the question is whether this session can show the home is free,
  # and a reader that cannot see the holder has shown nothing.
  holder=$(cat "$lock" 2>/dev/null) || return 0
  holder=${holder%%$'\n'*}
  holder=${holder//[[:space:]]/}
  case "$holder" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$holder" = "$me" ] && return 1
  fm_harness_alive "$holder"
}
