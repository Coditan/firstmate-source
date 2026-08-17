#!/usr/bin/env bash
# fm-slot-guard.sh - watch pooled worktrees for a slot two tasks both claim.
#
# WHAT THIS IS FOR - the incident it exists to prevent, measured 2026-08-17
#
# A finished task was torn down. Its state/<id>.meta still recorded pooled slot
# .treehouse/firstmate-fork-c22c88/4/firstmate-fork. By then that slot had been
# re-handed to a different task that was live and mid-work. Teardown returned it.
# `treehouse return` terminates every process in the worktree, so the live
# worker's window died and its uncommitted work went with it. One commit survived
# only because it happened to already be in the shared object store.
#
# Teardown was not missing a refusal - it refuses on unlanded work, and had done
# so for that same task minutes earlier. It was missing a QUESTION: every check
# it runs is scoped to the task it was told about, never to the RESOURCE it is
# about to touch. Nothing anywhere asked who else was standing in that slot.
#
# WHY A WATCHER AND NOT ONLY A CHECK AT THE RETURN
#
# firstmate was the thing that got this wrong, so a fix that depends on the
# caller remembering to ask is the same failure with an extra step. This watcher
# asks continuously and independently: it sweeps this home's recorded slots on
# the ordinary watcher cadence and, the moment a slot is claimed by a task other
# than the live one standing in it, writes a durable dispute marker for the stale
# task and wakes firstmate. The protection therefore already exists before any
# teardown runs, and it survives a caller that never asks.
#
# WHAT A WATCHER CANNOT HOLD HERE, AND WHY - measured, not assumed
#
# Asked to hold "a worktree is never returned while a live task holds it"
# entirely from outside the caller, this watcher cannot, for two reasons that are
# properties of the pool tool rather than of this design:
#
#   1. `treehouse return` is unconditionally destructive and honours no lease by
#      default. Measured: `treehouse return --force <path>` released a lease held
#      by a different holder without complaint, and plain `treehouse return
#      <path>` reported "Terminated lingering processes: bash (903999)". There is
#      no non-destructive return mode to interpose on, and no daemon can veto a
#      return another process has already issued.
#   2. A slot that is already in use cannot be leased retroactively. `treehouse
#      get --lease` allocates a free slot; there is no command to place a lease on
#      an existing occupied one. So this watcher cannot convert the pool's
#      process-based hold into a durable lifecycle-based hold for work already
#      running.
#
# What the tool does offer is `treehouse return --if-lease-holder <holder>`,
# which refuses at the resource rather than in the caller. Measured: against a
# slot leased to fm:B a return claiming fm:A failed with "lease precondition
# failed: lease holder does not match" and exit 1, the lease survived; against an
# unleased slot the same call failed with "is not leased" and exit 1, and the
# live process in it survived. It fails closed in both directions. bin/fm-teardown.sh
# uses it whenever a slot is leased, so for leased slots the refusal is enforced
# by the pool itself and not by firstmate's memory. Leasing every task worktree
# at acquisition - as bin/fm-home-seed.sh already does for secondmate homes - is
# what would make that path universal; docs/slot-guard.md records why that is a
# separate change and what it would cost.
#
# Until then this watcher's dispute markers, plus the ownership question in
# bin/fm-slot-lib.sh that bin/fm-teardown.sh asks before every return, are what
# hold the property for slots the pool cannot enforce on. That split is stated
# here rather than papered over, because a guard whose limits are not written
# down gets trusted past them.
#
# MODES
#   fm-slot-guard.sh                default: the watcher check. Sweeps this home's
#                                   recorded slots, writes and clears dispute
#                                   markers, and prints a SLOT_GUARD: line only
#                                   when the disputed set changes.
#   fm-slot-guard.sh --status       human reading of every recorded slot.
#   fm-slot-guard.sh --holder <p>   print the live task ids holding path <p>,
#                                   one per line; --self <id> excludes that task.
#                                   Exit 0 when a holder was printed, 1 when the
#                                   path is held by nobody else.
#   fm-slot-guard.sh --arm          write and register this home's watcher check.
#   fm-slot-guard.sh --armed        print one line when the guard is not armed or
#                                   has stopped running; silent when healthy.
#
# EXIT STATUS
#   0  in the default, --arm and --armed modes, always: a check's job is its line,
#      and the watcher reads the line rather than the status.
#   --holder returns 1 for "nobody else holds it", which is the common answer and
#      not an error. --status returns 2 when any slot is disputed.
#
# ENVIRONMENT
#   FM_SLOT_GUARD_STALE=<secs>   age past which --armed calls the guard stopped
#                                (default 1800)
#   FM_SLOT_GUARD_DISABLE=1      silence detect and --armed only, so suites that
#                                drive a fake home do not trip this home's guard.
#                                --arm, --status and --holder are unaffected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CHECK="$STATE/slot-guard.check.sh"
STATE_FILE="$STATE/slot-guard.state"
LOG="$DATA/slot-guard.log"

STALE=${FM_SLOT_GUARD_STALE:-1800}
NOW=${FM_SLOT_GUARD_NOW:-$(date +%s)}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 || true
# shellcheck source=bin/fm-slot-lib.sh
. "$SCRIPT_DIR/fm-slot-lib.sh"

MODE=detect
HOLDER_PATH=
HOLDER_SELF=
while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE=status ;;
    --arm) MODE=arm ;;
    --armed) MODE=armed ;;
    --holder) MODE=holder; HOLDER_PATH=${2:-}; shift ;;
    --self) HOLDER_SELF=${2:-}; shift ;;
    --help|-h)
      sed -n '/^# MODES/,/^#   FM_SLOT_GUARD_DISABLE/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'usage: %s [--status|--arm|--armed|--holder <path> [--self <id>]|--help]\n' "$(basename "$0")" >&2
      exit 2 ;;
  esac
  shift
done

human_duration() {
  local s=$1
  if [ "$s" -lt 3600 ]; then printf '%dm\n' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh\n' "$((s / 3600))"
  else printf '%dd\n' "$((s / 86400))"; fi
}

# The project a task's meta records, needed to resolve its pool.
task_project() {  # <id>
  sed -n 's/^project=//p' "$STATE/$1.meta" 2>/dev/null | head -1
}

task_worktree() {  # <id>
  sed -n 's/^worktree=//p' "$STATE/$1.meta" 2>/dev/null | head -1
}

# Every task id in this home that records a worktree.
recorded_tasks() {
  local meta id
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^worktree=' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

# --- the sweep ---------------------------------------------------------------
#
# DISPUTED is the set of "<id> <holder>" pairs where <id>'s recorded slot is
# actually held by <holder>. Returning <id>'s slot would destroy <holder>'s work,
# so <id> is the task that must be stopped, not the one that is in trouble.
DISPUTED=
DISPUTED_IDS=

sweep() {
  local id wt project holders holder line
  DISPUTED=
  DISPUTED_IDS=
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    wt=$(task_worktree "$id")
    [ -n "$wt" ] || continue
    project=$(task_project "$id")
    holders=$(fm_slot_conflicting_holders "$wt" "$id" "$STATE" "$project" 2>/dev/null) || continue
    [ -n "$holders" ] || continue
    while IFS= read -r holder; do
      [ -n "$holder" ] || continue
      line="$id $holder"
      DISPUTED="$DISPUTED$line
"
      case " $DISPUTED_IDS " in
        *" $id "*) ;;
        *) DISPUTED_IDS="$DISPUTED_IDS $id" ;;
      esac
    done <<EOF
$holders
EOF
  done <<EOF
$(recorded_tasks)
EOF
  DISPUTED_IDS=${DISPUTED_IDS# }
}

# A dispute marker is the durable half of this guard: it survives the watcher
# tick that found it, so a teardown that runs when nothing is watching still has
# the finding in front of it.
write_markers() {
  local id holder pair tmp
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    id=${pair%% *}
    holder=${pair#* }
    tmp=$(mktemp "$STATE/.fm-slot-disputed.XXXXXX") || continue
    printf 'holder=%s\nrecorded=%s\nobserved=%s\n' \
      "$holder" "$(task_worktree "$id")" "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)" >"$tmp" || { rm -f -- "$tmp"; continue; }
    mv -f -- "$tmp" "$STATE/$id.slot-disputed" || rm -f -- "$tmp"
  done <<EOF
$DISPUTED
EOF
}

clear_stale_markers() {
  local marker id
  [ -d "$STATE" ] || return 0
  for marker in "$STATE"/*.slot-disputed; do
    [ -e "$marker" ] || continue
    id=$(basename "$marker" .slot-disputed)
    case " $DISPUTED_IDS " in
      *" $id "*) continue ;;
    esac
    rm -f -- "$marker"
  done
}

read_state() { sed -n 's/^disputed=//p' "$STATE_FILE" 2>/dev/null | head -1; }

write_state() {  # <disputed-ids>
  local tmp
  tmp=$(mktemp "$STATE/.fm-slot-guard-state.XXXXXX") || return 1
  printf 'disputed=%s\nat=%s\n' "$1" "$NOW" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; return 1; }
}

arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-slot-guard.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: what counts as a holder, and what to do about one,
# live in the guard itself so they arrive by self-update rather than being frozen
# into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-slot-guard.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    umask 077
    tmp=$(mktemp "$STATE/.fm-slot-guard-check.XXXXXX") || return 1
    printf '%s\n' "$desired" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" slot-guard >/dev/null || return 1
}

armed_diagnostic() {
  local mtime age
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'SLOT_GUARD: nothing is watching for a pooled worktree two tasks both claim, so a cleanup can still destroy a running worker (fix: %s/fm-slot-guard.sh --arm)\n' \
      "$SCRIPT_DIR"
    return 0
  fi
  if [ ! -f "$STATE_FILE" ]; then
    mtime=$(stat -c %Y "$CHECK" 2>/dev/null) || return 0
    age=$((NOW - mtime))
    [ "$age" -gt "$STALE" ] &&
      printf 'SLOT_GUARD: the worktree-ownership watch was armed %s ago and has never completed a sweep, so nothing is watching for a slot two tasks both claim (fix: %s/fm-slot-guard.sh --status)\n' \
        "$(human_duration "$age")" "$SCRIPT_DIR"
    return 0
  fi
  mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null) || return 0
  age=$((NOW - mtime))
  [ "$age" -gt "$STALE" ] &&
    printf 'SLOT_GUARD: the worktree-ownership watch last swept %s ago and has stopped running, so a cleanup could return a worktree a live worker is standing in (fix: %s/fm-slot-guard.sh --status)\n' \
      "$(human_duration "$age")" "$SCRIPT_DIR"
  return 0
}

case "$MODE" in
  arm)
    arm || { printf 'fm-slot-guard: cannot arm the worktree-ownership watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0 ;;
  armed)
    [ "${FM_SLOT_GUARD_DISABLE:-0}" = 1 ] && exit 0
    armed_diagnostic
    exit 0 ;;
  holder)
    [ -n "$HOLDER_PATH" ] || { printf 'fm-slot-guard: --holder needs a path\n' >&2; exit 2; }
    project=
    [ -n "$HOLDER_SELF" ] && project=$(task_project "$HOLDER_SELF")
    if [ -z "$project" ]; then
      # No self task to resolve the pool from: fall back to the path's own repo.
      project=$(git -C "$HOLDER_PATH" rev-parse --show-toplevel 2>/dev/null || true)
    fi
    fm_slot_conflicting_holders "$HOLDER_PATH" "$HOLDER_SELF" "$STATE" "$project"
    exit $? ;;
  status)
    sweep
    if [ -z "$DISPUTED" ]; then
      printf 'slot-guard: clear - no recorded worktree in this home is held by another live task\n'
      exit 0
    fi
    printf 'slot-guard: DISPUTED - a cleanup of these tasks would return a worktree someone else is standing in\n'
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      printf '  %s records %s, which is held by %s\n' \
        "${pair%% *}" "$(task_worktree "${pair%% *}")" "${pair#* }"
    done <<EOF
$DISPUTED
EOF
    exit 2 ;;
esac

# --- detect -----------------------------------------------------------------
#
# The watcher reads the line, not the exit status, so this mode always exits 0.
# It speaks only when the disputed set changes, so a standing dispute is reported
# once rather than every tick.

[ "${FM_SLOT_GUARD_DISABLE:-0}" = 1 ] && exit 0

sweep
write_markers
clear_stale_markers

PREVIOUS=$(read_state)
CURRENT=$DISPUTED_IDS

if [ "$CURRENT" = "$PREVIOUS" ]; then
  write_state "$CURRENT" || true
  exit 0
fi

LINE=
if [ -n "$CURRENT" ]; then
  FIRST=$(printf '%s' "$DISPUTED" | head -1)
  LINE="SLOT_GUARD: a finished task's recorded worktree is being used by a different live worker - cleaning up ${FIRST%% *} would destroy the work of ${FIRST#* }. Cleanup of $CURRENT is now refused until this is resolved."
elif [ -n "$PREVIOUS" ]; then
  LINE="SLOT_GUARD: resolved - no recorded worktree in this home is held by another live worker any more (was: $PREVIOUS)."
fi

mkdir -p "$DATA" 2>/dev/null || true
printf '%s\t%s\n' "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)" "$LINE" >>"$LOG" 2>/dev/null || true

if ! write_state "$CURRENT"; then
  printf 'SLOT_GUARD: the worktree-ownership watch saw the disputed set change to "%s" but could not persist it in %s; the finding was measured but not durably completed.\n' \
    "$CURRENT" "$STATE_FILE"
  exit 0
fi

[ -z "$LINE" ] || printf '%s\n' "$LINE"
exit 0
