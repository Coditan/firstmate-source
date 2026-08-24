#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The walk itself lives in fm-harness-pid-lib.sh, shared with the primary
# transcript record so both name the same session.
#
# Acquisition proves three separate things before it reports success, because a
# lock that was not actually published is worse than no lock at all: this home's
# state directory is writable at all, no other live session holds the lock at
# the moment of the write, and what now sits in the lock file is this session's
# own pid. The claim lock around the second and third is what makes them one
# decision rather than two: without it, two sessions can both read a free lock
# and both write, and each then reports success while only one of them holds it.
# Waiting for that claim is bounded by fm-wake-lib.sh's own acquisition timeout,
# so a contended or wedged claim ends in a refusal a session can act on rather
# than in a session start that never returns.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
# A state directory that cannot be created is refused rather than carried on
# from: every later step here writes into it, and reporting an acquired lock
# that lives nowhere is the exact failure the verification below exists to stop.
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  # An unreadable lock is not a free one. Saying so is the whole value of this
  # branch: a reader that cannot see the holder must not report the holder's
  # absence.
  if ! old=$(cat "$LOCK" 2>/dev/null); then echo "lock: unreadable"; exit 0; fi
  if fm_harness_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

# Why this refusal names two different causes: a lock held by a live session and
# a lock nobody can read are both reasons not to proceed, but only one of them is
# another session's doing, and an operator who cannot tell them apart cannot
# clear either.
refuse_not_ours() {
  local holder
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: the session lock is not a regular file; operate read-only until resolved" >&2
  elif ! holder=$(cat "$LOCK" 2>/dev/null); then
    echo "error: the session lock is unreadable, so this session cannot show it is free; operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $holder); operate read-only until resolved" >&2
  fi
  exit 1
}

me=$(fm_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }

# Prove the state directory is writable before claiming anything, with a file
# that is not the lock. A probe that fails costs one refusal; discovering the
# same failure at the publication step costs a session that believes it holds a
# lock it never wrote.
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}

# The re-acquiring session's own lock needs no claim: it is already the holder,
# so serialising it behind other acquirers would make session start wait on a
# decision that is already made.
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
fi
# The refusal test itself lives in fm-harness-pid-lib.sh so that the primary
# transcript record is gated on exactly the condition this lock refuses on,
# rather than on a second, drifting copy of it.
# Refusing here, before the claim lock, keeps an already-lost acquisition out of
# the queue for a claim it would only lose again.
if fm_session_lock_held_by_other "$LOCK" "$me"; then
  refuse_not_ours
fi

# Serialise the read-then-write below. bin/fm-wake-lib.sh owns this fleet's
# portable lock primitive; this file does not carry a second one.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

claim_rc=0
fm_lock_try_acquire "$CLAIM_LOCK" || claim_rc=$?
# Only genuine contention is worth waiting out; a filesystem failure will not
# resolve itself and waiting on it just delays the same refusal.
if [ "$claim_rc" -eq 1 ]; then
  claim_rc=0
  fm_lock_acquire_wait "$CLAIM_LOCK" || claim_rc=$?
fi
if [ "$claim_rc" -ne 0 ]; then
  echo "error: cannot serialise session-lock acquisition (${FM_LOCK_ERROR:-lock unavailable}); operate read-only until resolved" >&2
  exit 1
fi
CLAIM_LOCK_HELD=1

# Re-read under the claim: the holder may have changed between the pre-check
# above and this point, which is the whole reason the claim exists.
if fm_session_lock_held_by_other "$LOCK" "$me"; then
  refuse_not_ours
fi

if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
# Read back what is actually there. A write that reported success and left
# something else behind - a full filesystem, a lock replaced underneath us - is
# indistinguishable from a held lock until someone reads it, and by then the
# session has already been operating as if it had fleet authority.
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
