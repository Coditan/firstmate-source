#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# Return 0 when the session that invoked this hook is the one operating $2, the
# checkout-derived firstmate root, which all three call sites resolve as FM_ROOT:
# the checkout the running hook was loaded from ($1) resolves to that same root.
# The addressee is therefore decided from WHERE the guard was loaded, not from
# which home it went on to judge. FM_ROOT and FM_HOME are not interchangeable
# here: they diverge whenever FM_HOME names a home other than the checkout, which
# docs/configuration.md documents as the normal meaning of FM_HOME.
# The known limit of deciding it this way is recorded at the bin/fm-guard.sh call
# site and tracked as backlog item fm-guard-addressee-fm-root-callers.
# Firstmate runs the tracked hooks out of its own home, and so does a secondmate
# in its own home, so both match.
# A crewmate or scout runs the very same tracked hooks out of its disposable task
# worktree while FM_ROOT_OVERRIDE still names the home that launched it, so the
# two differ and the session is a worker that may not repair that home.
# This decides only WHO a guard addresses. It never selects which home is
# evaluated and never takes part in judging that home's supervision, so a wrong
# answer here can only misaddress a message, never suppress a refusal.
# An unresolvable path answers "not the operator", because handing a repair
# command to a worker is the failure this predicate exists to prevent.
fm_session_operates_home() {
  local session=$1 home=$2 session_real home_real
  session_real=$(CDPATH='' cd -- "$session" 2>/dev/null && pwd -P) || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  [ "$session_real" = "$home_real" ]
}
