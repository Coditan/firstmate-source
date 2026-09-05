#!/usr/bin/env bash
# Run one session-start check OFF the critical path, and make its result reach
# the session either way.
#
# WHY THIS EXISTS. Session start waited for its own network. Measured on
# tugboat-cloud 2026-09-04, a 45.7s start spent 43.5s in bootstrap, and the
# single largest item was the project-clone refresh: fourteen sequential
# fetches, waited on in a poll loop before the first model turn could be
# produced. Every one of those costs scales with a quantity that only grows, and
# this is vendored code, so every vessel pays it. The work still has to happen;
# what it does not have to do is block.
#
# THE ONE RULE THIS MECHANISM IS BUILT AROUND: a deferred check must never be
# able to finish silently. An absent line reads as an all-clear, and a check
# whose silence is indistinguishable from a clean result is the defect class
# this fleet keeps recording. So exactly one of three things happens to every
# run, and the caller can tell which:
#   - the run finished before the digest asked, and `collect` prints its
#     complete output into the digest;
#   - the run is still going, and `collect` says so, so the caller can print a
#     PENDING line naming what is not yet known;
#   - the run finishes after the digest, and the runner itself queues a `check`
#     wake carrying the result - INCLUDING a clean result, because "nothing to
#     report" is the answer a pending line is still waiting for.
#
# THE HANDOFF. The digest gets first refusal, because a result printed in the
# digest is one the session already has and a wake is a second turn. So a
# finished runner does not deliver on its own: it waits until `collect` either
# takes the result (a `delivered` claim) or states that it will not (a
# `released` marker), and only then queues the wake. Both sides then settle it
# with one atomic mkdir, so a run that completes in the instant between those
# two steps is delivered once, never twice and never zero times. A runner whose
# digest never returns at all - a bootstrap killed mid-run - waits
# FM_DEFERRED_CHECK_HANDOFF_TIMEOUT seconds (default 120) and then delivers
# anyway, late rather than lost.
#
# Usage: fm-deferred-check.sh start <name> -- <command> [arg...]
#          Launch <command> detached from this process, with its stdin, stdout
#          and stderr fully detached from the caller's, and return immediately.
#          Combined output is captured for `collect`. Any UNDELIVERED result
#          left by a previous run of <name> is printed on stdout first, so a
#          result whose runner was killed before it could queue its wake is
#          picked up by the next session start instead of being lost.
#          Exit 0 = launched. Exit 3 = a previous runner for <name> is still
#          alive, so nothing new was started and the caller should treat <name>
#          as pending. Exit 1 = the launch itself failed.
#        fm-deferred-check.sh collect <name> [<grace-seconds>]
#          NON-BLOCKING, and deliberately so: this is the call that used to be a
#          wait. The optional grace (default 0) is the one exception, and a small
#          one: a check that normally finishes in milliseconds would otherwise
#          cost the session a whole extra turn to be told it found nothing, so
#          its caller may spend a second here rather than a wake there. Exit 0 = finished, and its complete output (possibly empty) was
#          printed here. Exit 3 = still running, and this call has just released
#          the result to the runner to deliver. Exit 4 = finished, but the runner
#          had already taken delivery, so the result is arriving as a wake. Exit
#          1 = no runner exists and no result can arrive.
#        fm-deferred-check.sh run <name> -- <command> [arg...]
#          The runner body. Started by `start`; not called directly.
#        fm-deferred-check.sh status <name>
#          One line: running, finished-undelivered, delivered, or absent. Read
#          only; claims nothing.
#
# NO TIMEOUT OF ITS OWN, ON PURPOSE. Each deferred check already bounds its own
# network (fm-fleet-sync.sh through fm-bootstrap.sh's fleet-sync timeout,
# fm-axi-suite.sh through FM_AXI_SUITE_NETWORK_TIMEOUT), and a second ceiling
# here would be a second owner of the same contract. A vessel with no network
# therefore behaves as it always did - the check reports its own skip or timeout
# - except that the digest no longer waits for it, so an offline start cannot
# hang on this path at all.
#
# WHAT RUNS OUTSIDE THE SESSION LOCK: nothing new. The caller only defers work
# it was already running under the lock, the lock is a durable record naming the
# harness process rather than any one subprocess (bin/fm-lock.sh), and it is
# held for the whole session, so a runner that outlives bootstrap is still
# inside the locked session. A runner that outlives the SESSION is the same
# exposure the previous code already had, where the refresh was likewise a
# background child of a bootstrap that could be killed.
#
# State lives in $STATE/.deferred/<name>/ (pid, out, done, released, delivered/)
# and is machinery: bin/fm-deferred-check.sh is the only thing that writes it.
# docs/session-start-deferral.md carries the measurements this was built from,
# including the two checks that were deliberately NOT deferred and why.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

DEFERRED_ROOT="$STATE/.deferred"
# How much of a finished check's output the wake payload carries. The full text
# always stays in the out file, and the payload names that path, so the cap
# bounds one queue record rather than the finding.
PAYLOAD_MAX=${FM_DEFERRED_CHECK_PAYLOAD_MAX:-600}
case "$PAYLOAD_MAX" in ''|0|*[!0-9]*) PAYLOAD_MAX=600 ;; esac
# How long a finished runner waits for its digest to take the result before
# delivering it itself. Only a digest that never reaches its collect call - one
# that was killed - ever spends this, and spending it delivers late rather than
# not at all.
HANDOFF_TIMEOUT=${FM_DEFERRED_CHECK_HANDOFF_TIMEOUT:-120}
case "$HANDOFF_TIMEOUT" in ''|*[!0-9]*) HANDOFF_TIMEOUT=120 ;; esac
HANDOFF_POLL=${FM_DEFERRED_CHECK_HANDOFF_POLL:-0.2}

usage() {
  echo "usage: fm-deferred-check.sh start|collect|run|status <name> [-- <command> [arg...]]" >&2
}

# A name is a directory component under state/, so it is held to a slug rather
# than trusted: a name that could escape the state directory is refused loudly
# instead of being sanitized into a different check's directory.
valid_name() {  # <name>
  case "${1:-}" in
    ''|*[!a-z0-9-]*|-*|*-) return 1 ;;
  esac
  return 0
}

check_dir() {  # <name>
  printf '%s\n' "$DEFERRED_ROOT/$1"
}

# Claim delivery of a finished run. mkdir is atomic on every filesystem this
# fleet runs on, which is the whole point: the digest and the runner can both
# arrive at a finished result at the same instant and exactly one of them wins.
claim_delivery() {  # <dir>
  mkdir "$1/delivered" 2>/dev/null
}

read_result() {  # <name> <dir>
  local name=$1 dir=$2
  if ! cat "$dir/status" >/dev/null 2>&1; then
    printf 'DEFERRED_CHECK_FAILED: %s: recorded exit status is unreadable or missing (%s/status)\n' "$name" "$dir"
  fi
  if ! cat "$dir/out" 2>/dev/null; then
    printf 'DEFERRED_CHECK_FAILED: %s: recorded output is unreadable or missing (%s/out)\n' "$name" "$dir"
  fi
}

# Give the digest first refusal on a finished result: it prints into the turn
# the session is already reading, where a wake costs a second one. Returns as
# soon as the digest has either taken the result or said it will not, and after
# HANDOFF_TIMEOUT regardless, so a digest that was killed delays delivery
# instead of cancelling it.
await_handoff() {  # <dir>
  local dir=$1 deadline
  deadline=$(( $(date +%s) + HANDOFF_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ ! -d "$dir/delivered" ] || return 0
    [ ! -f "$dir/released" ] || return 0
    sleep "$HANDOFF_POLL" 2>/dev/null || sleep 1
  done
  return 0
}

runner_alive() {  # <dir>
  local pid
  pid=$(cat "$1/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$pid"
}

cmd_status() {  # <name>
  local dir
  dir=$(check_dir "$1")
  if [ -f "$dir/done" ] && [ -d "$dir/delivered" ]; then
    echo delivered
  elif [ -f "$dir/done" ]; then
    echo finished-undelivered
  elif runner_alive "$dir"; then
    echo running
  else
    echo absent
  fi
}

cmd_start() {  # <name> <command> [arg...]
  local name=$1 dir leftover
  shift
  dir=$(check_dir "$name")

  # A finished run is finished whatever its recorded pid says now: pids are
  # reused, and a stale one that happened to match a live process would
  # otherwise block this check from ever being started again.
  if [ ! -f "$dir/done" ] && runner_alive "$dir"; then
    return 3
  fi

  # A finished result nobody took is printed HERE rather than discarded, which
  # is the one case the wake path cannot cover: a runner killed between writing
  # its result and queueing its wake leaves a complete answer and no messenger.
  if [ -f "$dir/done" ] && [ ! -d "$dir/delivered" ] && claim_delivery "$dir"; then
    leftover=$(read_result "$name" "$dir")
    [ -z "$leftover" ] || printf '%s\n' "$leftover"
  fi

  rm -rf "$dir" 2>/dev/null || return 1
  [ ! -e "$dir" ] || return 1
  mkdir -p "$DEFERRED_ROOT" || return 1
  mkdir "$dir" || return 1

  # DETACHED FROM THE CALLER'S STDOUT, AND THIS IS LOAD-BEARING. Session start
  # reads bootstrap through a command substitution, which does not return until
  # every holder of that pipe has closed it. A runner that inherited stdout
  # would keep the pipe open and make the digest wait for exactly the work this
  # mechanism exists to stop waiting for - the deferral would silently do
  # nothing. tests/fm-deferred-check.test.sh pins that.
  ( "$SCRIPT_DIR/fm-deferred-check.sh" run "$name" -- "$@" ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/pid" || return 1
  return 0
}

cmd_run() {  # <name> <command> [arg...]
  local name=$1 dir rc=0 out payload summary
  shift
  dir=$(check_dir "$name")
  [ -d "$dir" ] || mkdir -p "$dir" || return 1

  "$@" > "$dir/command.out.part" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$dir/status" 2>/dev/null || return 1
  {
    if [ "$rc" -ne 0 ]; then
      printf 'DEFERRED_CHECK_FAILED: %s: command exited with status %s\n' "$name" "$rc"
    fi
    cat "$dir/command.out.part"
  } > "$dir/out.part" 2>/dev/null || return 1
  rm "$dir/command.out.part" 2>/dev/null || return 1
  mv "$dir/out.part" "$dir/out" 2>/dev/null || return 1
  # The done marker goes down LAST and by rename, so a reader sees either no
  # result or a whole one, never a half-written one it would report as complete.
  : > "$dir/done.part" 2>/dev/null || return 1
  mv "$dir/done.part" "$dir/done" 2>/dev/null || return 1

  await_handoff "$dir"
  claim_delivery "$dir" || return 0

  out=$(read_result "$name" "$dir")
  if [ -z "$out" ]; then
    summary="completed with nothing to report"
  else
    summary=$(printf '%s' "$out" | tr '\n' ';' | cut -c "1-$PAYLOAD_MAX")
    [ "${#out}" -le "$PAYLOAD_MAX" ] || summary="$summary [truncated]"
  fi
  payload="check: $name: finished after session start: $summary (full output: $dir/out)"
  if ! fm_wake_append check "$name" "$payload"; then
    # No messenger, so do not keep the claim: leaving the result unclaimed is
    # what lets the next session start print it instead of losing it.
    rmdir "$dir/delivered" 2>/dev/null || true
    return 1
  fi
  return 0
}

cmd_collect() {  # <name> [grace-seconds]
  local dir grace deadline
  dir=$(check_dir "$1")
  grace=${2:-0}
  case "$grace" in ''|*[!0-9]*) grace=0 ;; esac
  # A grace is not the wait this mechanism removed: it is a fraction of a second
  # spent to keep a check that finishes in milliseconds from costing the session
  # a whole extra turn to be told nothing happened. It is bounded, it is the
  # caller's choice per check, and it is zero by default.
  if [ "$grace" -gt 0 ] && [ ! -f "$dir/done" ] && runner_alive "$dir"; then
    deadline=$(( $(date +%s) + grace ))
    while [ ! -f "$dir/done" ] && [ "$(date +%s)" -lt "$deadline" ]; do
      sleep "$HANDOFF_POLL" 2>/dev/null || sleep 1
    done
  fi
  if [ ! -f "$dir/done" ]; then
    runner_alive "$dir" || return 1
    # Not finished. Release the result to the runner and say so.
    [ -d "$dir" ] && : > "$dir/released" 2>/dev/null
    return 3
  fi
  claim_delivery "$dir" || return 4
  read_result "$1" "$dir"
  return 0
}

[ $# -ge 2 ] || { usage; exit 1; }
ACTION=$1
NAME=$2
shift 2
valid_name "$NAME" || { echo "fm-deferred-check.sh: invalid check name: $NAME" >&2; exit 1; }
if [ "${1:-}" = "--" ]; then shift; fi

case "$ACTION" in
  start)
    [ $# -ge 1 ] || { usage; exit 1; }
    cmd_start "$NAME" "$@"
    ;;
  run)
    [ $# -ge 1 ] || { usage; exit 1; }
    cmd_run "$NAME" "$@"
    ;;
  collect)
    cmd_collect "$NAME" "${1:-0}"
    ;;
  status)
    cmd_status "$NAME"
    ;;
  *)
    usage
    exit 1
    ;;
esac
