#!/usr/bin/env bash
# Acquire, inspect or hand over the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The walk itself lives in fm-harness-pid-lib.sh, shared with the primary
# transcript record so both name the same session.
#
# A pid alone does not say who holds this home, because a pid only means
# anything inside one process-id table. So the record names the table too, and
# fm-harness-pid-lib.sh owns both the token and the comparison. A session
# reading a record from a table it cannot see into is REFUSED rather than told
# the holder is dead: the liveness test has not been loosened, it has been given
# the one fact that makes it answerable across a container boundary.
#
# Acquisition proves three separate things before it reports success, because a
# lock that was not actually published is worse than no lock at all: this home's
# state directory is writable at all, no other live session holds the lock at
# the moment of the write, and what now sits in the lock file is this session's
# own pid AND its own pid table. The claim lock around the second and third is
# what makes them one decision rather than two: without it, two sessions can
# both read a free lock and both write, and each then reports success while only
# one of them holds it. Waiting for that claim is bounded by fm-wake-lib.sh's own
# acquisition timeout, so a contended or wedged claim ends in a refusal a session
# can act on rather than in a session start that never returns.
#
# Handover exists because a lock that only frees when its owner dies can be
# dropped but never passed. `handover` keeps the outgoing seat recorded as the
# holder - so the home is never unowned - while standing that seat down, and
# prints a one-time ticket. The successor presents the ticket and the record is
# replaced in one atomic rename. THE COST IS STATED RATHER THAN HIDDEN: between
# the offer and the successor's acquisition no seat is acting, and that gap was
# chosen over the alternative, because an unsupervised minute is recoverable and
# two seats both dispatching and merging is not.
#
# Usage: fm-lock.sh                       acquire; exit 1 unless ownership is verified
#        fm-lock.sh acquire [--handover TICKET]
#                                         acquire, presenting a ticket a standing
#                                         offer named; also read from
#                                         FM_LOCK_HANDOVER_TICKET
#        fm-lock.sh status                print holder and liveness; always exits 0
#        fm-lock.sh handover              stand down and print the successor's ticket
#        fm-lock.sh handover --cancel     withdraw a standing offer and resume authority
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

MODE=acquire
TICKET="${FM_LOCK_HANDOVER_TICKET:-}"
CANCEL=0
case "${1:-}" in
  ''|acquire) [ -n "${1:-}" ] && shift ;;
  status) MODE=status; shift ;;
  handover) MODE=handover; shift ;;
  -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unknown command ${1}; run $0 --help" >&2; exit 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --handover)
      [ "$MODE" = acquire ] || { echo "error: --handover applies to acquire only" >&2; exit 2; }
      shift
      [ $# -gt 0 ] || { echo "error: --handover needs a ticket" >&2; exit 2; }
      TICKET=$1; shift ;;
    --cancel)
      [ "$MODE" = handover ] || { echo "error: --cancel applies to handover only" >&2; exit 2; }
      CANCEL=1; shift ;;
    *) echo "error: unknown option $1; run $0 --help" >&2; exit 2 ;;
  esac
done
TICKET=${TICKET//[[:space:]]/}

if [ "$MODE" = status ]; then
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    echo "lock: unavailable (state directory absent)"
    exit 0
  fi
  if [ ! -d "$STATE" ]; then
    echo "lock: unavailable (state path is not a directory)"
    exit 0
  fi
  # Status judges the state directory by whether the lock path inside it can be reached, never by whether the directory can be listed.
  if [ ! -x "$STATE" ]; then
    echo "lock: unavailable (state directory unreadable)"
    exit 0
  fi
  if ! fm_session_lock_record_read "$LOCK"; then
    case "$FM_LOCK_RECORD_ERROR" in
      absent) echo "lock: free" ;;
      # An unreadable lock is not a free one. Saying so is the whole value of
      # this branch: a reader that cannot see the holder must not report the
      # holder's absence.
      unreadable) echo "lock: unreadable" ;;
      *) echo "lock: unavailable (not a regular file)" ;;
    esac
    exit 0
  fi
  offer=
  [ -n "$FM_LOCK_RECORD_HANDOVER" ] && offer=" (handover offered; the successor must present the ticket)"
  case "$FM_LOCK_RECORD_PID" in
    ''|*[!0-9]*) echo "lock: free"; exit 0 ;;
  esac
  if [ -n "$FM_LOCK_RECORD_PIDNS" ] && { ! mine_ns=$(fm_pid_namespace_token) || [ "$mine_ns" != "$FM_LOCK_RECORD_PIDNS" ]; }; then
    # Not "stale" and not "held": this reader has no way to test that pid at
    # all, and reporting either would be a claim it cannot make.
    echo "lock: held by pid $FM_LOCK_RECORD_PID in process namespace $FM_LOCK_RECORD_PIDNS, which this session cannot see into; liveness is unmeasurable from here$offer"
    exit 0
  fi
  if fm_harness_alive "$FM_LOCK_RECORD_PID"; then
    echo "lock: held by live harness pid $FM_LOCK_RECORD_PID$offer"
  else
    echo "lock: stale (pid $FM_LOCK_RECORD_PID dead or not a harness)$offer"
  fi
  exit 0
fi

# A state directory that cannot be created is refused rather than carried on
# from: every later step here writes into it, and reporting an acquired lock
# that lives nowhere is the exact failure the verification below exists to stop.
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Why this refusal names several different causes: a lock held by a live session,
# a lock held in a table this session cannot see into, and a lock nobody can read
# are all reasons not to proceed, but only some of them are another session's
# doing, and an operator who cannot tell them apart cannot clear any of them.
refuse_not_ours() {
  case "$FM_SESSION_LOCK_VERDICT" in
    nonregular)
      echo "error: the session lock is not a regular file; operate read-only until resolved" >&2 ;;
    unreadable)
      echo "error: the session lock is unreadable, so this session cannot show it is free; operate read-only until resolved" >&2 ;;
    unidentified)
      echo "error: this session cannot identify its own process namespace, so it cannot show the lock holder is not live; operate read-only until resolved" >&2 ;;
    foreign)
      echo "error: the session lock is held by pid $FM_LOCK_RECORD_PID in process namespace $FM_LOCK_RECORD_PIDNS, which this session cannot see into, so it cannot be shown free; take ownership with a handover from the holding session rather than by assuming it is gone" >&2 ;;
    *)
      echo "error: another live firstmate session holds the lock (pid $FM_LOCK_RECORD_PID); operate read-only until resolved" >&2 ;;
  esac
  exit 1
}

me=$(fm_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
my_ns=$(fm_pid_namespace_token) || {
  echo "error: cannot identify this session's process namespace, so the lock it wrote could not be read correctly by anyone else; operate read-only until resolved" >&2
  exit 1
}

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

# Serialise the read-then-write below. bin/fm-wake-lib.sh owns this fleet's
# portable lock primitive; this file does not carry a second one.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
LOCK_PUBLISH_TMP=
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
cleanup_lock_acquisition() {
  if [ -n "$LOCK_PUBLISH_TMP" ]; then
    rm -f "$LOCK_PUBLISH_TMP" 2>/dev/null || true
    LOCK_PUBLISH_TMP=
  fi
  release_claim_lock
}
trap cleanup_lock_acquisition EXIT
trap 'exit 1' HUP INT TERM

take_claim_lock() {
  local claim_rc=0
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
}

# publish_record <pid> <pidns> <ticket-or-empty>: write the whole record and
# prove what is on disk afterwards. Read back rather than trusted, because a
# write that reported success and left something else behind - a full
# filesystem, a lock replaced underneath us - is indistinguishable from a held
# lock until someone reads it, and by then the session has already been
# operating as if it had fleet authority.
publish_record() {
  local pid=$1 ns=$2 ticket=$3
  LOCK_PUBLISH_TMP=$(mktemp "$STATE/.lock-publish.XXXXXX" 2>/dev/null) || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  {
    printf '%s\n' "$pid"
    printf 'pidns=%s\n' "$ns"
    if [ -n "$ticket" ]; then printf 'handover=%s\n' "$ticket"; fi
  } > "$LOCK_PUBLISH_TMP" 2>/dev/null || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! mv -f -- "$LOCK_PUBLISH_TMP" "$LOCK" 2>/dev/null; then
    echo "error: cannot publish session lock; operate read-only until resolved" >&2
    exit 1
  fi
  LOCK_PUBLISH_TMP=
  fm_session_lock_record_read "$LOCK" || {
    echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$FM_LOCK_RECORD_PID" != "$pid" ] \
    || [ "$FM_LOCK_RECORD_PIDNS" != "$ns" ] \
    || [ "$FM_LOCK_RECORD_HANDOVER" != "$ticket" ]; then
    echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
    exit 1
  fi
}

if [ "$MODE" = handover ]; then
  take_claim_lock
  if fm_session_lock_held_by_other "$LOCK" "$me"; then
    refuse_not_ours
  fi
  if [ "$FM_SESSION_LOCK_VERDICT" != mine ]; then
    echo "error: this session does not hold the lock, so it has no ownership to hand over; acquire it first" >&2
    exit 1
  fi
  if [ "$CANCEL" -eq 1 ]; then
    if [ -z "$FM_LOCK_RECORD_HANDOVER" ]; then
      echo "error: no handover offer stands on this lock; nothing to cancel" >&2
      exit 1
    fi
    publish_record "$me" "$my_ns" ""
    release_claim_lock
    echo "handover cancelled: harness pid $me holds the lock and is acting again"
    exit 0
  fi
  if [ -n "$FM_LOCK_RECORD_HANDOVER" ]; then
    echo "error: a handover offer already stands on this lock; cancel it before making another so exactly one successor is named" >&2
    exit 1
  fi
  # Refused rather than weakened to a guessable value: a ticket anyone can
  # predict is not a named successor, and an unnamed successor is the second
  # seat this whole file exists to keep out.
  new_ticket=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || new_ticket=
  if [ "${#new_ticket}" -ne 32 ]; then
    echo "error: cannot generate a handover ticket from /dev/urandom; ownership was not offered and this session still holds the lock" >&2
    exit 1
  fi
  publish_record "$me" "$my_ns" "$new_ticket"
  release_claim_lock
  cat <<TXT
handover offered by harness pid $me
ticket: $new_ticket
This session is still the recorded holder, so the home is never unowned, but it
has stood down and must not act with fleet authority again unless it runs
"$0 handover --cancel".
No seat is supervising until the successor runs:
  FM_LOCK_HANDOVER_TICKET=$new_ticket <its session start>
or, directly:
  $0 acquire --handover $new_ticket
TXT
  exit 0
fi

# --- acquire ---------------------------------------------------------------

if [ -n "$TICKET" ]; then
  # A presented ticket is the ONE path that takes a lock this session cannot
  # otherwise show is free, and it is not a bypass of the liveness test: it is
  # the outgoing holder's own recorded decision to pass ownership, matched
  # exactly, under the same claim lock every other write takes.
  take_claim_lock
  if ! fm_session_lock_record_read "$LOCK"; then
    echo "error: the session lock cannot be read ($FM_LOCK_RECORD_ERROR), so the handover ticket cannot be matched against a standing offer; operate read-only until resolved" >&2
    exit 1
  fi
  if [ -z "$FM_LOCK_RECORD_HANDOVER" ]; then
    echo "error: a handover ticket was presented but no offer stands on this lock; ask the holding session to run \"$0 handover\"" >&2
    exit 1
  fi
  if [ "$FM_LOCK_RECORD_HANDOVER" != "$TICKET" ]; then
    echo "error: the handover ticket presented does not match the offer standing on this lock; ownership was not taken" >&2
    exit 1
  fi
  # Captured before publishing, because publishing re-reads the record into the
  # same variables and the outgoing holder would otherwise be reported as this
  # session handing over to itself.
  from_pid=$FM_LOCK_RECORD_PID
  publish_record "$me" "$my_ns" ""
  release_claim_lock
  echo "lock acquired by handover: harness pid $me (from pid $from_pid)"
  exit 0
fi

# The re-acquiring session's own lock needs no claim: it is already the holder,
# so serialising it behind other acquirers would make session start wait on a
# decision that is already made.
if ! fm_session_lock_held_by_other "$LOCK" "$me" && [ "$FM_SESSION_LOCK_VERDICT" = mine ]; then
  if [ -n "$FM_LOCK_RECORD_HANDOVER" ]; then
    echo "error: this session offered its ownership away and stood down, so it must not resume authority by re-acquiring; run \"$0 handover --cancel\" to take it back deliberately, or let the successor present its ticket" >&2
    exit 1
  fi
  # A record from before this fork wrote pid tables names no table, so it is
  # upgraded in place rather than trusted as-is - and only after re-proving,
  # under the claim, that it is still ours.
  if [ "$FM_SESSION_LOCK_LEGACY" -eq 0 ]; then
    # Read once more before reporting authority this session did not just write.
    # The fast path skips the claim lock deliberately, so the only thing standing
    # between "the record said mine a moment ago" and "the record says mine" is
    # this second look; without it a record replaced in between is reported back
    # as ours.
    if ! fm_session_lock_held_by_other "$LOCK" "$me" \
      && [ "$FM_SESSION_LOCK_VERDICT" = mine ] \
      && [ "$FM_SESSION_LOCK_LEGACY" -eq 0 ] \
      && [ -z "$FM_LOCK_RECORD_HANDOVER" ]; then
      echo "lock acquired: harness pid $me"
      exit 0
    fi
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
TOOK_LEGACY=$FM_SESSION_LOCK_LEGACY

take_claim_lock

# Re-read under the claim: the holder may have changed between the pre-check
# above and this point, which is the whole reason the claim exists.
if fm_session_lock_held_by_other "$LOCK" "$me"; then
  refuse_not_ours
fi
[ "$FM_SESSION_LOCK_LEGACY" -eq 1 ] && TOOK_LEGACY=1

publish_record "$me" "$my_ns" ""
release_claim_lock
if [ "$TOOK_LEGACY" -eq 1 ]; then
  # Said out loud rather than upgraded quietly. The record this replaced named
  # no pid table, so the only reading available for it was "a pid in my own
  # table" - which is exactly the assumption that lets a seat in one namespace
  # judge a live holder in another one dead. It is a one-shot: what this session
  # just wrote names a table, so the next reader is not in that position.
  echo "warning: the lock record this session replaced named no process namespace, so this session could not prove the previous holder was one it can see; the record it just wrote names one" >&2
fi
echo "lock acquired: harness pid $me"
