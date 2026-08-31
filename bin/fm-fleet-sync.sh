#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of origin/<default>) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# Every other off-default state - a non-default named branch, a detached HEAD with
# unique commits, a dirty tree, or a diverged default - may hold real work, so it
# is left untouched and reported as a quantified, loud "STUCK: ... N commits behind
# ... - needs attention" warning rather than a quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# fetch_with_packed_refs_lock_guard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
# The per-project outcome lines printed here ("already current", "synced ...",
# "recovered: ...", "skipped: ...", "STUCK: ...") are a parsed contract, not just
# prose: bin/fm-bridge-relay.sh classifies them to decide whether a Bridge read may
# answer at all, so rewording one changes that decision and must re-run
# tests/fm-bridge-relay.test.sh (bin/fm-test-run.sh selects it from this path).
# Usage: fm-fleet-sync.sh [<project-dir-or-name>]
# With no argument, whole-fleet sync processes projects registered in this
# home's data/projects.md first, preserving their parsed skip lines for missing
# or non-repository entries, then scans this home's projects dir for
# unregistered directories only when they are git roots.
# A registry that is PRESENT and cannot be read stops the whole-fleet form with
# "fleet: STUCK: cannot read the project registry ..." on stdout and exit 3,
# because a home that cannot tell which projects it has must not report that it
# has none. It refuses on a registry that is not a regular file, one that cannot be
# read or parsed, a dangling symlink, and a path whose own ABSENCE cannot be
# established because an ancestor directory cannot be searched. An ABSENT registry
# under a directory this process can look in is not a fault: the directory scan is
# the whole answer for a home that registers nothing.
# The directory scan is held to the same standard: a projects dir that is PRESENT
# and cannot be listed - or one whose absence cannot be established - stops the
# whole-fleet form with "fleet: STUCK: cannot list the projects directory ..." on
# stdout and exit 3, because an unlistable dir would otherwise render as a home
# holding no unregistered clones. An ABSENT projects dir is not a fault either, for
# the same reason.
# The single-project form accepts either a path (absolute, or relative to the
# caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
# this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.sh dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh" || true

# Bounded recovery for an orphaned .git/packed-refs.lock. A git ref rewrite
# (fetch --prune, branch -D, pack-refs) killed after creating the lock but before
# renaming it - e.g. bootstrap's fleet-sync timeout kill, or teardown's process
# kills - leaves a lock that makes the next sync's fetch fail with Git's
# "Unable to create '...packed-refs.lock': File exists". These knobs bound the
# patience-then-provably-stale-clear recovery; see fetch_with_packed_refs_lock_guard.
FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "fleet-sync: invalid packed-refs lock retry wait '$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

usage() {
  echo "usage: fm-fleet-sync.sh [<project-dir-or-name>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# ABSENCE IS A READING TOO, and `test -e` is false whenever the STAT fails rather
# than only when the file is not there: a containing directory this process cannot
# look in makes a present, populated path answer exactly like a missing one. Absence
# may therefore only be concluded from an ancestor that can actually be searched,
# and this names the nearest one that cannot.
absence_unprovable() {  # <path>; prints the nearest ancestor that cannot be searched
  local dir=$1
  while :; do
    case "$dir" in
      /) return 1 ;;
      */*) dir=${dir%/*}; [ -n "$dir" ] || dir=/ ;;
      *) dir=. ;;
    esac
    if [ -e "$dir" ]; then
      if [ ! -d "$dir" ] || [ ! -x "$dir" ] || [ ! -r "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
      fi
      return 1
    fi
    if [ -L "$dir" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    case "$dir" in
      /|.) return 1 ;;
    esac
  done
}

# AN UNREADABLE REGISTRY IS NOT AN EMPTY ONE. registered_project_names is called in
# a command substitution, so its exit status is discarded by the `for` that consumes
# it: a parse that failed used to fall through to an empty name list, every
# registered project dropped out of the run without a line, and the whole-fleet form
# exited 0. Nothing downstream - bootstrap's relay included - could tell a home with
# no projects from a home that could not look. So the readability of the registry is
# established ONCE, before the walk, by a function that names the concrete cause.
#
# An ABSENT registry is not a fault: a home that registers no projects has no file,
# and the directory scan below is the whole answer for it.
registry_fault() {  # prints why the registry cannot be read, and returns 0 when so
  # A symlink that does not resolve is a PRESENT registry that cannot be read, not
  # an absent one: `test -e` follows the link and answers for the target, so this
  # asks about the link itself before concluding the home simply has no file.
  local unsearchable
  if [ ! -e "$REG" ]; then
    if [ -L "$REG" ]; then
      printf 'broken symlink to %s\n' "$(readlink "$REG" 2>/dev/null || printf '%s' 'an unreadable target')"
      return 0
    fi
    if unsearchable=$(absence_unprovable "$REG"); then
      printf 'cannot tell whether the registry exists: %s cannot be searched\n' "$unsearchable"
      return 0
    fi
    return 1
  fi
  if [ ! -f "$REG" ]; then
    printf 'not a regular file\n'
    return 0
  fi
  if [ ! -r "$REG" ]; then
    printf 'permission denied\n'
    return 0
  fi
  # Readable by mode and still unreadable in fact - an I/O error, a dead network
  # mount - is only visible by reading it.
  if ! awk 'END { }' "$REG" 2>/dev/null; then
    printf 'the registry could not be parsed\n'
    return 0
  fi
  return 1
}

# The scan half of the same answer. `[ -d "$PROJECTS" ]` only stats, so a projects
# dir that is present and cannot be listed left the glob unexpanded, every clone in
# it dropped out of the run without a line, and the whole-fleet form exited 0 - the
# same silence a home with no clones produces.
#
# An ABSENT projects dir is not a fault: a home that keeps no clones has no such
# directory, and the registered walk above is the whole answer for it.
projects_dir_fault() {  # prints why the projects dir cannot be listed, returns 0 when so
  local unsearchable
  if [ ! -e "$PROJECTS" ]; then
    if [ -L "$PROJECTS" ]; then
      printf 'broken symlink to %s\n' "$(readlink "$PROJECTS" 2>/dev/null || printf '%s' 'an unreadable target')"
      return 0
    fi
    if unsearchable=$(absence_unprovable "$PROJECTS"); then
      printf 'cannot tell whether the projects directory exists: %s cannot be searched\n' "$unsearchable"
      return 0
    fi
    return 1
  fi
  if [ ! -d "$PROJECTS" ]; then
    printf 'not a directory\n'
    return 0
  fi
  # Listing needs read, and stat-ing what the listing names needs search; without
  # either one the walk sees nothing and cannot tell that from an empty dir.
  if [ ! -r "$PROJECTS" ] || [ ! -x "$PROJECTS" ]; then
    printf 'permission denied\n'
    return 0
  fi
  if ! ls -A "$PROJECTS" >/dev/null 2>&1; then
    printf 'the projects directory could not be listed\n'
    return 0
  fi
  return 1
}

registered_project_names() {
  [ -f "$REG" ] || return 0
  awk '$1=="-" && $2!="" { print $2 }' "$REG"
}

registry_has_project() {
  local name=$1
  [ -f "$REG" ] || return 1
  awk -v n="$name" '
    $1=="-" && $2==n { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$REG"
}

project_is_git_root() {
  local proj=$1 git_root project_root
  [ -d "$proj" ] || return 1
  git_root=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null) || return 1
  project_root=$(cd "$proj" && pwd -P) || return 1
  [ -n "$git_root" ] \
    && [ "$(cd "$git_root" 2>/dev/null && pwd -P)" = "$project_root" ]
}

# resolve_project_arg <arg>: accept a path (used as-is when it already exists)
# or a bare/"projects/<name>" project name, resolved against $PROJECTS. Falls
# back to the original argument unresolved so a genuinely bad path still hits
# sync_project's existing "not a directory" skip.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# True when git stderr shows the packed-refs.lock "File exists" race. The lock
# path can appear anywhere in the message (git prefixes it with the failed ref op,
# e.g. "could not delete reference ...:"). Other "File exists" errors must not match.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $PROJ's packed-refs.lock, or empty when it cannot be resolved.
packed_refs_lock_path() {
  local lock abs
  lock=$(git -C "$PROJ" rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs=$(cd "$PROJ" && pwd -P) || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Run `git -C "$PROJ" fetch origin --prune --quiet`, tolerating an orphaned
# packed-refs.lock left by a killed ref rewrite. Sets FETCH_OUTPUT to the git
# command's combined output and returns its exit status. On the packed-refs.lock
# signature ONLY: retry up to FLEET_SYNC_PACKED_REFS_LOCK_RETRIES times (a
# transient lock self-clears as the owning process exits), then - only if the lock
# is provably stale per fm-lock-lib.sh (still present, mtime age past the
# threshold, no lsof holder of the lock or the clone worktree $PROJ) - remove it
# and retry once more. A live lock, an unprovable one, or any other failure keeps
# today's behavior. Every wait, retry, and removal prints to stderr, and a
# successful recovery also prints one "$label: recovered: ..." summary to stdout so
# a session-start refresh (which discards fleet-sync stderr) still surfaces it.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$label: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      # One stdout summary so a session-start refresh (which discards fleet-sync
      # stderr and relays only stdout) still surfaces the recovery.
      echo "$label: recovered: packed-refs lock cleared on its own during retry"
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  # The companion liveness dir is $PROJ (the clone worktree): a live `git -C "$PROJ"`
  # keeps its cwd there even in the narrow window after it closes packed-refs.lock
  # and before it exits, so lsof on $PROJ still catches a holder the lock-file check
  # alone would miss.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! rm -f "$lock"; then
        echo "$label: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$label: fetch succeeded after stale packed-refs lock cleanup" >&2
        echo "$label: recovered: removed a stale packed-refs lock (no live holder)"
        return 0
      fi
      return "$rc"
    fi
    echo "$label: fetch blocked by packed-refs lock $lock that persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$label: fetch packed-refs lock signature persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of origin/<default> - the
  # fleet's history contains squash merges, and callers can still request them,
  # so some merged branches are not ancestors. The no-worktree guard is the real
  # safety net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

# True when some worktree of $PROJ has $DEFAULT checked out (so we cannot attach
# to it here). The current worktree is detached when this is consulted, so any
# match is necessarily another worktree.
default_checked_out_elsewhere() {
  git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p' \
    | grep -Fxq -- "$DEFAULT"
}

local_default_safe_for_recovery() {
  ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
    || git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE" 2>/dev/null
}

# Human-readable name for the unsafe state the clone is in, used in the STUCK
# warning. Reads $cur (current branch, empty when detached), $dirty, and the
# HEAD-vs-$BASE ancestry to pick the most informative description.
stuck_state() {
  local s
  if [ -n "$cur" ]; then
    s="branch $cur"
  elif [ "$dirty" = yes ]; then
    s="detached HEAD"
  elif ! git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null; then
    s="detached HEAD with unique commits"
  elif default_checked_out_elsewhere; then
    s="detached HEAD ($DEFAULT checked out in another worktree)"
  elif ! local_default_safe_for_recovery; then
    s="detached HEAD (local $DEFAULT diverged from $BASE)"
  else
    s="detached HEAD"
  fi
  [ "$dirty" = no ] || s="$s with uncommitted changes"
  printf '%s\n' "$s"
}

# Loud, quantified report for a clone we deliberately leave untouched. Includes
# how far behind origin/<default> it is, so a chronically-stuck clone is visibly
# distinct from a benign one-off skip.
report_stuck() {
  local state=$1 behind
  behind=$(git -C "$PROJ" rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$label: STUCK: on $state, $behind commits behind $BASE - needs attention"
}

sync_project() {
  PROJ=$1
  label=$(project_label)

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! project_is_git_root "$PROJ"; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  if ! fetch_with_packed_refs_lock_guard; then
    reason="fetch failed"
    if [ -n "$FETCH_OUTPUT" ]; then
      reason="$reason: $(first_line "$FETCH_OUTPUT")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi

  prune_gone_branches || true

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  BASE="origin/$DEFAULT"
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  dirty=no
  [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  recovered=no

  if [ "$cur" != "$DEFAULT" ]; then
    # Off the default branch. Auto-recover only the one unambiguously safe drift:
    # a clean, detached HEAD that holds no unique commits (it is an ancestor of
    # origin/<default>) and whose <default> branch is free to check out here.
    # Re-attaching to an already-published commit strands nothing, and the
    # fast-forward path below then catches the clone up. Anything else - a
    # non-default named branch, a detached HEAD with unique commits, a dirty tree,
    # or <default> already checked out elsewhere - may hold real work, so it is
    # reported loudly and left untouched.
    if [ -z "$cur" ] && [ "$dirty" = no ] \
        && git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null \
        && ! default_checked_out_elsewhere \
        && local_default_safe_for_recovery; then
      if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then
        report_stuck "$(stuck_state)"
        return 0
      fi
      recovered=yes
      cur=$DEFAULT
    else
      report_stuck "$(stuck_state)"
      return 0
    fi
  elif [ "$dirty" = yes ]; then
    # On the default branch but with uncommitted changes we must not disturb.
    report_stuck "$(stuck_state)"
    return 0
  fi

  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    if [ "$recovered" = yes ]; then
      echo "$label: recovered: re-attached $DEFAULT (already current)"
    else
      echo "$label: already current"
    fi
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    report_stuck "diverged $DEFAULT"
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  if [ "$recovered" = yes ]; then
    echo "$label: recovered: re-attached $DEFAULT, synced $before..$after"
  else
    echo "$label: synced $before..$after"
  fi
  return 0
}

if [ $# -eq 1 ]; then
  sync_project "$(resolve_project_arg "$1")"
  exit 0
fi

# The refusal goes to STDOUT and carries the "STUCK:" word its readers classify by:
# bin/fm-bootstrap.sh relays this stream and discards stderr, so a registry fault
# announced on stderr alone would be a fault nobody hears.
if REG_FAULT=$(registry_fault); then
  echo "fleet: STUCK: cannot read the project registry $REG: $REG_FAULT - this home cannot tell which projects it has, so it is not reporting that it has none - needs attention"
  exit 3
fi

if PROJECTS_FAULT=$(projects_dir_fault); then
  echo "fleet: STUCK: cannot list the projects directory $PROJECTS: $PROJECTS_FAULT - this home cannot tell which clones it holds, so it is not reporting that it holds none - needs attention"
  exit 3
fi

for name in $(registered_project_names); do
  sync_project "$PROJECTS/$name"
done
[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  name=$(basename "$proj")
  registry_has_project "$name" && continue
  project_is_git_root "$proj" || continue
  sync_project "$proj"
done
