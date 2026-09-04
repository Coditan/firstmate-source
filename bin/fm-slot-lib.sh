#!/usr/bin/env bash
# shellcheck shell=bash
# fm-slot-lib.sh - one owner for "which live task holds this pooled worktree".
#
# Usage: . bin/fm-slot-lib.sh
#
# WHY THIS EXISTS - measured 2026-08-17
#
# A pooled treehouse slot has two owners that can silently disagree.
#
#   The pool's owner is a PROCESS. treehouse-state.json records one owner_pid per
#   slot, and `treehouse status` calls a slot in-use only while a process is alive
#   inside it. When that process exits, the slot becomes available immediately.
#
#   firstmate's owner is a TASK. state/<id>.meta records worktree=<path> and keeps
#   recording it until teardown, which can be long after the task's window died.
#
# Those two disagree in exactly one direction, and it is the dangerous one: a
# task's window dies, the pool calls the slot free and hands it to the next spawn,
# and the first task's meta still names it. Measured in a sandbox pool, slot 1
# went in-use(A) -> available (A's process died) -> in-use(B), with A's meta still
# recording slot 1 throughout. Tearing A down then returned a slot B was standing
# in: `treehouse return` terminates every process in the worktree and resets it,
# so B's window died and B's uncommitted work was destroyed. Committed work
# survived only because it was already in the shared object store.
#
# So the loss is not a missing refusal - teardown already refuses on unlanded
# work. It is a missing QUESTION: the checks are scoped to the task teardown was
# told about, never to the RESOURCE it is about to touch. This library is that
# question, stated once, so every caller asks it the same way. It detects holders
# already represented when asked; on an unleased slot it cannot detect a holder
# that arrives before the later return or processes with no window or task record.
#
# TWO INDEPENDENT WITNESSES, because either alone has a blind spot
#
#   The lease witness (fm_slot_lease_holder) reads the pool's own durable lease
#   when one exists. It is authoritative for a leased slot, but ordinary task
#   slots are unleased today and therefore have no lease witness.
#
#   The record witness (fm_slot_live_meta_claimants) reads every state/<id>.meta
#   that names the path and keeps only the tasks whose window is still alive. Its
#   blind spot is a holder that has no meta in THIS home.
#
# A conflict from either witness is a real conflict. Requiring both to agree
# would reintroduce the gap, so fm_slot_conflicting_holders unions them.
#
# WHAT NO WITNESS HERE CAN SEE - measured, not assumed
#
# `treehouse return --force <path>` released a lease held by a different holder
# without complaint, and plain `treehouse return <path>` terminated a live
# process ("Terminated lingering processes: bash (903999)"). There is no
# non-destructive return mode and no lease the tool itself honours at return
# time. So nothing here can stop a return issued outside firstmate; these
# predicates bind the callers that ask them and contain the measured stale-holder
# incident, but they do not establish an unconditional ownership invariant.

# Absolute path with symlinks resolved, so two spellings of one slot compare
# equal. Falls back to the input when the path is gone: a vanished worktree still
# has to be comparable against a recorded one.
fm_slot_canonical() {  # <path>
  local p=$1
  [ -n "$p" ] || return 1
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P ) && return 0
  fi
  printf '%s\n' "${p%/}"
}

# The worktree path a `treehouse status` line names, or empty when the line names
# none. `treehouse status` abbreviates the pool root as "~/", so a reader that
# takes the field verbatim compares an unexpanded tilde against an absolute path
# and silently matches nothing. One reader, so both callers expand it the same way.
fm_slot_status_line_path() {  # <status-line>
  local line=$1 body lpath
  body=${line%%"(held by "*}
  lpath=$(printf '%s\n' "$body" | awk '{print $3}')
  # shellcheck disable=SC2088  # the literal leading tilde is exactly what treehouse prints
  case "$lpath" in
    '~/'*) printf '%s\n' "$HOME/${lpath#'~/'}" ;;
    /*) printf '%s\n' "$lpath" ;;
    *) return 1 ;;
  esac
}

# The lease holder label the pool records for a slot, or empty when the slot is
# not leased. Runs treehouse from <project> because treehouse resolves the pool
# from the working directory. Never fabricates an answer: an unreadable pool
# returns 1 with no output, so a caller can tell "nobody" from "cannot tell".
fm_slot_lease_holder() {  # <path> <project>
  local path=$1 project=$2 canon status_out line
  canon=$(fm_slot_canonical "$path") || return 1
  [ -n "$project" ] && [ -d "$project" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  status_out=$( ( cd "$project" && treehouse status ) 2>/dev/null ) || return 1
  while IFS= read -r line; do
    case "$line" in
      *"(held by "*) ;;
      *) continue ;;
    esac
    # "<name>  leased  <path>  (held by <label>)" - take the path field by
    # stripping the trailing "(held by ...)" and the leading name+state.
    local label lpath
    label=${line##*"(held by "}
    label=${label%%")"*}
    lpath=$(fm_slot_status_line_path "$line") || continue
    lpath=$(fm_slot_canonical "$lpath") || continue
    if [ "$lpath" = "$canon" ]; then
      printf '%s\n' "$label"
      return 0
    fi
  done <<EOF
$status_out
EOF
  return 0
}

# The lease-holder label this home uses for a task. One spelling, one owner.
fm_slot_lease_label() {  # <task-id>
  printf 'fm:%s\n' "$1"
}

# The task id inside a lease label, or empty when the label is not one of ours -
# a lease some other tool placed is still a holder, but it is not a task id.
#
# Two spellings are ours because two callers already write leases: this guard
# writes "fm:<id>", while bin/fm-home-seed.sh has leased secondmate homes with a
# bare "<id>" since before this guard existed. Reading only the prefixed form
# would report every existing secondmate home as held by a stranger.
fm_slot_task_of_lease_label() {  # <label>
  case "$1" in
    fm:?*) printf '%s\n' "${1#fm:}" ;;
    ?*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# Every task id in <state-dir> whose meta records <path>, one per line.
fm_slot_meta_claimants() {  # <path> <state-dir>
  local path=$1 state=$2 canon meta id recorded
  canon=$(fm_slot_canonical "$path") || return 1
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    recorded=$(sed -n 's/^worktree=//p' "$meta" | head -1)
    [ -n "$recorded" ] || continue
    recorded=$(fm_slot_canonical "$recorded") || continue
    [ "$recorded" = "$canon" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

# True when a task's recorded window still exists on its recorded backend.
# Deliberately conservative: a task whose liveness cannot be read counts as LIVE,
# because the cost of guessing wrong is destroying a running worker's work,
# while the cost of a false hold is a refusal the operator can inspect.
fm_slot_task_window_live() {  # <task-id> <state-dir>
  local id=$1 state=$2 meta backend target
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  target=$(sed -n 's/^window=//p' "$meta" | head -1)
  [ -n "$target" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
  [ -n "$backend" ] || backend=$(fm_backend_of_meta "$meta" 2>/dev/null) || backend=
  [ -n "$backend" ] || return 0
  fm_backend_source "$backend" >/dev/null 2>&1 || return 0
  if fm_backend_target_exists "$backend" "$target" "fm-$id" 2>/dev/null; then
    return 0
  else
    [ "$?" -ne 1 ]
  fi
}

# Task ids that record <path> AND still have a live window.
fm_slot_live_meta_claimants() {  # <path> <state-dir>
  local path=$1 state=$2 id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if fm_slot_task_window_live "$id" "$state"; then
      printf '%s\n' "$id"
    fi
  done <<EOF
$(fm_slot_meta_claimants "$path" "$state")
EOF
}

# THE QUESTION teardown never asked: who else is standing in this slot?
#
# Prints one holder per line - a task id, or a bare lease label when the lease
# belongs to something that is not one of our tasks - and returns 0 when at least
# one exists. Returns 1 when nobody else holds it. <self-id> is excluded: a task
# holding its own slot is the normal case, not a conflict.
fm_slot_conflicting_holders() {  # <path> <self-id> <state-dir> <project>
  local path=$1 self=$2 state=$3 project=$4 holder lease lease_task found=1 seen

  seen=" "
  lease=$(fm_slot_lease_holder "$path" "$project" 2>/dev/null) || lease=
  if [ -n "$lease" ]; then
    if lease_task=$(fm_slot_task_of_lease_label "$lease"); then
      if [ "$lease_task" != "$self" ]; then
        printf '%s\n' "$lease_task"
        seen="$seen$lease_task "
        found=0
      fi
    else
      printf '%s\n' "$lease"
      found=0
    fi
  fi

  while IFS= read -r holder; do
    [ -n "$holder" ] || continue
    [ "$holder" != "$self" ] || continue
    case "$seen" in
      *" $holder "*) continue ;;
    esac
    printf '%s\n' "$holder"
    seen="$seen$holder "
    found=0
  done <<EOF
$(fm_slot_live_meta_claimants "$path" "$state")
EOF

  return "$found"
}

# The spelling the POOL uses for a slot, given any spelling of the same
# directory. Prints its input unchanged when the pool cannot be read or lists no
# slot that resolves to the same directory.
#
# WHY - measured 2026-09-04
#
# One directory can be reachable under two names: on this vessel ~/.treehouse is
# a symlink to /var/lib/vessel/work/worktrees, so one slot is reachable as both
# ~/.treehouse/<pool>/<n>/<repo> and
# /var/lib/vessel/work/worktrees/<pool>/<n>/<repo>. treehouse keys its pool on
# the name the worktree was created under and compares the argument to
# `treehouse return` as a STRING. Handing it the other spelling of the same
# directory was measured to give "worktree <path> is not managed by treehouse"
# and change nothing, while the pool's own spelling of that same directory
# reached the lease check normally. firstmate cannot change the comparison inside
# that tool, so it owns the spelling it hands over.
#
# The answer is DERIVED, never enumerated: the pool's own listing supplies the
# accepted spelling, so a third path form arriving later needs no change here.
# Never fabricates: an unreadable pool or an unlisted directory yields the input
# path, so the caller behaves exactly as it did before this existed.
fm_slot_pool_path() {  # <path> <project>
  local path=$1 project=$2 canon status_out line lpath lcanon
  if [ -z "$path" ] || [ -z "$project" ] || [ ! -d "$project" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  if ! command -v treehouse >/dev/null 2>&1; then
    printf '%s\n' "$path"
    return 0
  fi
  if ! canon=$(fm_slot_canonical "$path"); then
    printf '%s\n' "$path"
    return 0
  fi
  if ! status_out=$( ( cd "$project" && treehouse status ) 2>/dev/null ); then
    printf '%s\n' "$path"
    return 0
  fi
  while IFS= read -r line; do
    lpath=$(fm_slot_status_line_path "$line") || continue
    lcanon=$(fm_slot_canonical "$lpath") || continue
    if [ "$lcanon" = "$canon" ]; then
      printf '%s\n' "$lpath"
      return 0
    fi
  done <<POOLPATH
$status_out
POOLPATH
  printf '%s\n' "$path"
}
