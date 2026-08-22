#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, refresh/prune the project's clone for PR-based ship
# tasks, then print a backlog-refresh reminder for ship and scout teardowns
# (a secondmate teardown prints none, since secondmates are not backlog items).
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from a remote-tracking branch of a COUNTED remote - one the project is
# registered against, never the validation pipeline's own local mirror, and re-read
# from the remote itself with --prune immediately before the test, so a branch the
# remote no longer has cannot pass off a stale cached ref (see "Which remotes may
# prove that work has LANDED" below; a fork still counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This continues to recognize
# historical or explicitly requested squash-merge-then-delete-branch flows, where
# the branch's own commits live nowhere on a remote yet the change is fully in main.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge after configured approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# Before destructive cleanup, teardown validates task check artifacts and any
# matching quarantine entries as ordinary single-link files on the state
# device. It refuses and preserves task state when that proof fails; otherwise
# it removes the task's check, trust record, PR sidecar, publication record, and
# quarantine entries with the rest of the volatile state.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-slot-lib.sh
. "$SCRIPT_DIR/fm-slot-lib.sh"  # fm_slot_conflicting_holders: who else is standing in this worktree
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
FORCE=${2:-}
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown
"$FM_ROOT/bin/fm-guard.sh" || true

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
if [ "$BACKEND" = orca ]; then
  T_ORCA=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$T_ORCA" ] && T=$T_ORCA
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

# --- Which remotes may prove that work has LANDED ----------------------------
# `git log HEAD --not --remotes` counts EVERY remote-tracking ref, and a model
# panel reproduced both ways that lied on 2026-08-21, in a clean sandbox:
#
#   1. The validation pipeline pushes every task branch into its own bare mirror
#      under ~/.no-mistakes/repos/<id>.git (docs/merged-branch-cleanup.md section
#      3). That mirror is a remote by git's reckoning, never reaches the forge,
#      and is invisible to gh - so work that got no further than the pipeline's
#      own scratch passed as landed and the worktree was cleared.
#   2. A remote-tracking ref is a local cache of what a remote had at the last
#      fetch. A branch deleted on the remote afterwards leaves its ref standing,
#      and that stale ref passed as landed too.
#
# So landing evidence now needs both halves. The ref must belong to a remote the
# PROJECT is registered against - never the pipeline's private mirror - and it
# must be re-read from that remote, with --prune, immediately before the test.
# A remote that cannot be re-read supplies no evidence at all: its cached refs
# are dropped rather than trusted, so an unreadable remote makes teardown refuse
# instead of quietly reporting work as landed that nobody could confirm.
#
# Nothing here widens what counts, and nothing here narrows it into an outage: a
# fork remote still counts, because a fork is a repository the project is
# registered against and a fork-pushed contribution really has left this machine.
# The re-read also ACCEPTS work no cached ref mentioned, which the check refused
# before. tests/fm-teardown.test.sh covers both directions.
#
# Nothing in this block is specific to one hosting service. A self-hosted forge
# is simply another remote the project is registered against, matched by the same
# effective URL, so extending the landed proof to read PR state from that forge
# is a change to pr_is_merged and nothing here.
FM_LANDING_REMOTES_RESOLVED=0
FM_LANDING_REMOTES=
FM_LANDING_REMOTES_UNREADABLE=
FM_LANDING_REMOTES_UNUSABLE=

# The URL a remote actually uses. `remote get-url` reports the configured string;
# `ls-remote --get-url` reports what git would really talk to, with
# url.<base>.insteadOf rewriting applied, and contacts nothing to say so.
remote_effective_url() {  # <repo dir> <remote name>
  git -C "$1" ls-remote --get-url "$2" 2>/dev/null
}

# Compare URLs by the repository they address rather than by how they were typed:
# a trailing slash and a trailing .git name the same place.
normalized_remote_url() {  # <url>
  local url=$1
  url=${url%/}
  url=${url%.git}
  url=${url%/}
  printf '%s' "$url"
}

# The validation pipeline's own scratch mirror, recognized the way
# bin/fm-gate-refuse-lib.sh recognizes a gate worktree: by the pipeline's own
# path contract, plus NM_HOME for an install that relocated its state. The path
# shape is the signal that survives a renamed remote.
url_is_pipeline_mirror() {  # <url>
  local url=$1 nm_repos
  case "$url" in
    */.no-mistakes/repos/*) return 0 ;;
  esac
  if [ -n "${NM_HOME:-}" ]; then
    nm_repos="${NM_HOME%/}/repos/"
    case "$url" in "$nm_repos"*) return 0 ;; esac
  fi
  return 1
}

# The remote URLs this project is registered against: every remote configured on
# the project clone except the pipeline's mirror. Reading them from the PROJECT
# uses the project's own record of where it publishes. A linked worktree shares
# that remote configuration, so this is not a trust boundary against a worker
# that deliberately adds a remote and pushes to it. This is a confused-worker
# check, like bin/fm-gate-refuse-lib.sh, not an adversarial one. It establishes
# that landed work is on a project-registered remote matched by effective URL,
# never merely on the pipeline mirror, and confirmed by re-reading the remote
# instead of trusting a cached ref. Falls back to the worktree's own remotes only
# when the project directory is not a readable repository - for a linked
# worktree that is the same set anyway.
project_registered_remote_urls() {
  local dir name url
  dir=$PROJ
  if [ -z "$dir" ] || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    dir=$WT
  fi
  git -C "$dir" remote 2>/dev/null | while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(remote_effective_url "$dir" "$name") || continue
    [ -n "$url" ] || continue
    url_is_pipeline_mirror "$url" && continue
    printf '%s\n' "$(normalized_remote_url "$url")"
  done | sort -u
}

# Re-read one remote, pruning refs it no longer has. Bounded, because a remote
# that hangs must not hold cleanup open forever; a timeout is a failed read, and
# a failed read costs the remote its vote.
fetch_landing_remote() {  # <remote name>
  local name=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FM_TEARDOWN_FETCH_TIMEOUT_SECS:-120}" \
      git -C "$WT" fetch --quiet --prune "$name" >/dev/null 2>&1
  else
    git -C "$WT" fetch --quiet --prune "$name" >/dev/null 2>&1
  fi
}

# Resolve, once per run, which of the worktree's remotes count and refresh them.
# Sets FM_LANDING_REMOTES (the names that count), FM_LANDING_REMOTES_UNREADABLE
# (the ones that would have counted but could not be re-read) and
# FM_LANDING_REMOTES_UNUSABLE (the ones whose name cannot be used as a ref
# selector). The last two are named in the refusal, so an operator sees which
# remotes were left out and why rather than only that the check said no.
resolve_landing_remotes() {
  local registered name url norm remotes='' unreadable='' unusable=''
  [ "$FM_LANDING_REMOTES_RESOLVED" = 1 ] && return 0
  FM_LANDING_REMOTES_RESOLVED=1
  registered=$(project_registered_remote_urls)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # A remote name is used below as a `git log --remotes=<glob>` pattern. A name
    # carrying glob metacharacters would select refs it does not own, so it is
    # dropped rather than guessed at.
    case "$name" in
      *[!A-Za-z0-9._-]*) unusable="$unusable $name" ; continue ;;
    esac
    url=$(remote_effective_url "$WT" "$name") || continue
    [ -n "$url" ] || continue
    norm=$(normalized_remote_url "$url")
    printf '%s\n' "$registered" | grep -qxF -- "$norm" || continue
    if fetch_landing_remote "$name"; then
      remotes="$remotes $name"
    else
      unreadable="$unreadable $name"
    fi
  done <<EOF
$(git -C "$WT" remote 2>/dev/null)
EOF
  FM_LANDING_REMOTES=${remotes# }
  FM_LANDING_REMOTES_UNREADABLE=${unreadable# }
  FM_LANDING_REMOTES_UNUSABLE=${unusable# }
}

# The committed work that no counted remote has, in the requested `git log`
# format. Returns non-zero when git could not answer, which every caller treats
# exactly as it treated a failed `git log` before.
commits_not_on_landing_remotes() {  # <git log format flag>
  local fmt=$1 name
  local -a not=()
  resolve_landing_remotes
  for name in $FM_LANDING_REMOTES; do
    not+=("--remotes=$name")
  done
  git -C "$WT" log "$fmt" HEAD --not ${not[@]+"${not[@]}"} -- 2>/dev/null
}

# Names the registered remotes whose refs were left out of the test, or prints
# nothing when every one of them answered and counted.
unreadable_remotes_note() {
  if [ -n "$FM_LANDING_REMOTES_UNREADABLE" ]; then
    printf 'not counted, because these remotes could not be re-read: %s\n' \
      "$FM_LANDING_REMOTES_UNREADABLE"
  fi
  if [ -n "$FM_LANDING_REMOTES_UNUSABLE" ]; then
    printf 'not counted, because these remote names cannot select refs: %s\n' \
      "$FM_LANDING_REMOTES_UNUSABLE"
  fi
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

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(commits_not_on_landing_remotes --format=%H) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  [ "$KIND" = secondmate ] && return 0
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3
TEARDOWN_SLOT_HELD_REFUSED=4

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

treehouse_return_is_lease_precondition_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "lease precondition failed: .*([Ll]ease holder does not match|is not leased)"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 ownership_refresh=${2:-} lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    [ -z "$ownership_refresh" ] || "$ownership_refresh" || return $?
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# THE OWNERSHIP QUESTION - refuse a holder visible when this decision is taken.
#
# Every other check in this script is scoped to the task it was told about. This
# one is scoped to the RESOURCE, which is the check that was missing when a
# teardown returned a pooled slot a different live task had since been given and
# killed that worker mid-work (bin/fm-slot-guard.sh header records the incident).
#
# It holds under --force on purpose. The captain's authority to discard work is
# authority over THIS task's work; it is never authority to destroy a third
# party's work he was never told was there. An operator who really must return a
# contested slot sets FM_TEARDOWN_SLOT_OVERRIDE to the holder this refusal named,
# which is deliberately harder than typing --force and, unlike --force, cannot be
# given without first learning who is being displaced.
require_no_other_slot_holder() {  # <dir> <cd_dir> <label> <self-id> <state-dir>
  local dir=$1 cd_dir=$2 label=$3 self=$4 state_dir=$5 holders marker

  marker="$state_dir/$self.slot-disputed"
  if [ -f "$marker" ]; then
    holders=$(sed -n 's/^holder=//p' "$marker" | head -1)
    if [ -n "$holders" ] && [ "${FM_TEARDOWN_SLOT_OVERRIDE:-}" != "$holders" ]; then
      echo "REFUSED: $label $dir is recorded by $self but is held by $holders, which is still live." >&2
      echo "Returning it would terminate every process in that worktree and reset it, destroying $holders's uncommitted work." >&2
      echo "Resolve the holder first (let $holders finish, or tear $holders down), or set FM_TEARDOWN_SLOT_OVERRIDE=$holders to displace it deliberately." >&2
      return "$TEARDOWN_SLOT_HELD_REFUSED"
    fi
  fi

  holders=$(fm_slot_conflicting_holders "$dir" "$self" "$state_dir" "$cd_dir" 2>/dev/null) || return 0
  [ -n "$holders" ] || return 0
  holders=$(printf '%s' "$holders" | tr '\n' ' ')
  holders=${holders% }
  if [ "${FM_TEARDOWN_SLOT_OVERRIDE:-}" = "$holders" ]; then
    echo "teardown: displacing $holders from $label $dir on an explicit FM_TEARDOWN_SLOT_OVERRIDE" >&2
    return 0
  fi
  echo "REFUSED: $label $dir is recorded by $self but is held by $holders, which is still live." >&2
  echo "Returning it would terminate every process in that worktree and reset it, destroying $holders's uncommitted work." >&2
  echo "Resolve the holder first (let $holders finish, or tear $holders down), or set FM_TEARDOWN_SLOT_OVERRIDE=$holders to displace it deliberately." >&2
  return "$TEARDOWN_SLOT_HELD_REFUSED"
}

# The lease-conditional form of the return, when the pool can enforce ownership
# itself. Measured 2026-08-17: `treehouse return --if-lease-holder <h>` exits 1
# and changes nothing both when the lease belongs to someone else ("lease holder
# does not match") and when the slot is not leased at all ("is not leased"), so
# it fails closed in both directions. It is therefore only safe to add when this
# task is the recorded lease holder; on an unleased slot it would refuse every
# ordinary teardown, so the refusal above contains visible holders on that path
# but cannot make its later unconditional return atomic.
refresh_teardown_return_ownership() {  # <dir> <cd_dir> <label> <self-id> <state-dir>
  local dir=$1 cd_dir=$2 label=$3 self=$4 state_dir=$5 lease holder
  lease_args=()
  require_no_other_slot_holder "$dir" "$cd_dir" "$label" "$self" "$state_dir" || return $?
  if ! lease=$(fm_slot_lease_holder "$dir" "$cd_dir" 2>/dev/null); then
    echo "REFUSED: ownership of $label $dir could not be read from the treehouse pool." >&2
    echo "Retry after the pool status can be read; returning it now could destroy another task's uncommitted work." >&2
    return "$TEARDOWN_SLOT_HELD_REFUSED"
  fi
  [ -n "$lease" ] || return 0
  case "$lease" in
    "fm:$self"|"$self") lease_args=(--if-lease-holder "$lease") ;;
    *)
      holder=$(fm_slot_task_of_lease_label "$lease" 2>/dev/null) || holder=$lease
      if [ "${FM_TEARDOWN_SLOT_OVERRIDE:-}" = "$holder" ]; then
        echo "teardown: displacing $holder from $label $dir on an explicit FM_TEARDOWN_SLOT_OVERRIDE" >&2
        return 0
      fi
      echo "REFUSED: $label $dir is recorded by $self but is held by $holder, which is still live." >&2
      echo "Returning it would terminate every process in that worktree and reset it, destroying $holder's uncommitted work." >&2
      echo "Resolve the holder first (let $holder finish, or tear $holder down), or set FM_TEARDOWN_SLOT_OVERRIDE=$holder to displace it deliberately." >&2
      return "$TEARDOWN_SLOT_HELD_REFUSED"
      ;;
  esac
}

refresh_current_treehouse_ownership() {
  refresh_teardown_return_ownership "$WT" "$PROJ" "worktree" "$ID" "$STATE"
}

current_worktree_uses_treehouse() {
  [ "$BACKEND" != orca ] && [ "$KIND" != secondmate ]
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-} self=${5:-$ID} state_dir=${6:-$STATE} pre_return_cleanup=${7:-}
  local out lock attempt=0 max_retries lock_desc holder_rc
  local -a lease_args=()

  if refresh_teardown_return_ownership "$dir" "$cd_dir" "$label" "$self" "$state_dir"; then
    :
  else
    holder_rc=$?
    return "$holder_rc"
  fi

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  [ -z "$pre_return_cleanup" ] || "$pre_return_cleanup" "$dir" || return 1
  if out=$( ( cd "$cd_dir" && treehouse return --force ${lease_args[@]+"${lease_args[@]}"} "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if treehouse_return_is_lease_precondition_error "$out"; then
    return "$TEARDOWN_SLOT_HELD_REFUSED"
  fi
  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if refresh_teardown_return_ownership "$dir" "$cd_dir" "$label" "$self" "$state_dir"; then
      :
    else
      holder_rc=$?
      return "$holder_rc"
    fi

    [ -z "$pre_return_cleanup" ] || "$pre_return_cleanup" "$dir" || return 1
    if out=$( ( cd "$cd_dir" && treehouse return --force ${lease_args[@]+"${lease_args[@]}"} "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if treehouse_return_is_lease_precondition_error "$out"; then
      return "$TEARDOWN_SLOT_HELD_REFUSED"
    fi
    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      if refresh_teardown_return_ownership "$dir" "$cd_dir" "$label" "$self" "$state_dir"; then
        :
      else
        holder_rc=$?
        return "$holder_rc"
      fi
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if refresh_teardown_return_ownership "$dir" "$cd_dir" "$label" "$self" "$state_dir"; then
        :
      else
        holder_rc=$?
        return "$holder_rc"
      fi
      [ -z "$pre_return_cleanup" ] || "$pre_return_cleanup" "$dir" || return 1
      if out=$( ( cd "$cd_dir" && treehouse return --force ${lease_args[@]+"${lease_args[@]}"} "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      if treehouse_return_is_lease_precondition_error "$out"; then
        return "$TEARDOWN_SLOT_HELD_REFUSED"
      fi
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac
  # Resolve and refresh the counted remotes HERE, in this shell. The unpushed
  # query below runs in a command substitution, and a subshell's answer about
  # which remotes could not be re-read would die with it - leaving a refusal that
  # cannot say why it did not trust the refs it saw.
  resolve_landing_remotes

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  # The '?? ' branch only skips UNTRACKED generated hook files. The task's own
  # Claude settings overlay needs the wider '.. ' branch too: if a repo ever tracks
  # that exact path, a regenerated copy shows up as tracked-and-dirty, which would
  # otherwise make the worktree permanently unteardownable without --force. Kept to
  # that one filename so genuine uncommitted work still refuses.
  dirty=$(printf '%s\n' "$dirty_raw" \
    | grep -vE '^(\?\? (\.claude/|\.fm-grok-turnend$)|.. \.claude/settings\.fm-task\.json$)' \
    | head -1 || true)

  if ! unpushed_raw=$(commits_not_on_landing_remotes --oneline); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      unreadable_remotes_note >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      unreadable_remotes_note >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

refresh_firstmate_home_ownership_if_pooled() {  # <home> <label> <self-id> <state-dir>
  local home=$1 label=$2 self=$3 state_dir=$4
  firstmate_home_has_treehouse_slot "$home" || return 0
  command -v treehouse >/dev/null 2>&1 || {
    echo "error: treehouse command not found; cannot verify $label $home ownership" >&2
    return 1
  }
  refresh_teardown_return_ownership "$home" "$FM_ROOT" "$label" "$self" "$state_dir"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} state_dir=${4:-$STATE} abs_home_path return_rc
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    if teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "" "${expected_id:-$ID}" "$state_dir"; then
      :
    else
      return_rc=$?
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return "$return_rc"
    fi
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

# Removes the generated turn-end hook files from a worktree so a reused pool
# worktree cannot fire signals for a dead task. Worktrees spawned before the Claude
# hook moved to .claude/settings.fm-task.json still carry the legacy
# .claude/settings.local.json copy, which Claude Code auto-loads, so it has to go
# too - but ONLY when git AFFIRMATIVELY reports that path untracked AND it still
# holds firstmate's generated turn-end hook. A repository is free to track that
# path, and an unconditional removal there would discard repo content. Every
# inconclusive git answer (no git, not a work tree, a transient failure) is treated
# as "assume tracked, keep the file", so the failure direction is never data loss.
remove_task_turnend_hooks() {
  local wt=$1 legacy inside tracked
  [ -n "$wt" ] || return 0
  rm -f "$wt/.claude/settings.fm-task.json" "$wt/.opencode/plugins/fm-turn-end.js" "$wt/.fm-grok-turnend"
  legacy="$wt/.claude/settings.local.json"
  [ -f "$legacy" ] || return 0
  inside=$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null) || return 0
  [ "$inside" = true ] || return 0
  tracked=$(git -C "$wt" ls-files -- .claude/settings.local.json 2>/dev/null) || return 0
  [ -z "$tracked" ] || return 0
  grep -q '\.turn-ended' "$legacy" 2>/dev/null || return 0
  rm -f "$legacy"
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        refresh_firstmate_home_ownership_if_pooled "$child_home" "child firstmate home" "$child_id" "$sub_state" || return $?
      fi
    fi
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    if [ -n "$child_t" ]; then
      if [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) 2>/dev/null || true
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" 2>/dev/null || true
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        refresh_firstmate_home_ownership_if_pooled "$child_home" "child firstmate home" "$child_id" "$sub_state" || return $?
        cleanup_firstmate_home_children "$child_home" || return $?
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" "$sub_state" || return $?
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      require_no_other_slot_holder "$child_wt" "$child_proj" "child worktree" "$child_id" "$sub_state" || return $?
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" "" "$child_id" "$sub_state" remove_task_turnend_hooks; then
          :
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ] \
             || [ "$child_return_rc" -eq "$TEARDOWN_SLOT_HELD_REFUSED" ]; then
            return "$child_return_rc"
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj"
        fi
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token"
    rm -rf "$sub_state/.crew-signal/$child_id"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
fi

# Every pool-backed target is checked as soon as it is known, before any path can mutate or descend into it, and each later mutation rechecks immediately before acting, but an unleased check and return are not atomic.
if [ "$KIND" = secondmate ]; then
  refresh_firstmate_home_ownership_if_pooled "$HOME_PATH" "secondmate home" "$ID" "$STATE" || exit $?
elif [ -d "$WT" ] && current_worktree_uses_treehouse; then
  refresh_teardown_return_ownership "$WT" "$PROJ" "worktree" "$ID" "$STATE" || exit $?
fi

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

if [ "$KIND" = secondmate ]; then
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  refresh_firstmate_home_ownership_if_pooled "$HOME_PATH" "secondmate home" "$ID" "$STATE" || exit $?
  cleanup_firstmate_home_children "$HOME_PATH" || exit $?
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$ID" >/dev/null; then
    echo "REFUSED: scout task $ID has not passed the unresolved-decision completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-decision-hold.sh before teardown." >&2
    exit 1
  fi
fi

if [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      stale_lock_ownership_refresh=
      if current_worktree_uses_treehouse; then
        stale_lock_ownership_refresh=refresh_current_treehouse_ownership
      fi
      cleanup_stale_lock_for_safety_check "$WT" "$stale_lock_ownership_refresh" || exit $?
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  [ -z "$T_ORCA" ] || fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
  if [ "$branch" != "HEAD" ]; then
    git -C "$PROJ" branch -D "$branch" >/dev/null 2>&1 || true
  fi
elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  post_lock_cleanup_check=
  if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ]; then
    post_lock_cleanup_check=validate_worktree_teardown_safety
  fi
  if teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" "$ID" "$STATE" remove_task_turnend_hooks; then
    if [ "$branch" != "HEAD" ]; then
      git -C "$PROJ" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  else
    return_rc=$?
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    if [ "$return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
      return_rc=1
    fi
    exit "$return_rc"
  fi
fi

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  HERDR_PRESENTATION_FOCUS_LOCK=
  HERDR_PRESENTATION_FOCUS_LOCK_HELD=0
  HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT=0
  if HERDR_PRESENTATION_FOCUS_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_PRESENTATION_SESSION"); then
    while [ "$HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT" -lt 50 ]; do
      if fm_lock_try_acquire "$HERDR_PRESENTATION_FOCUS_LOCK"; then
        HERDR_PRESENTATION_FOCUS_LOCK_HELD=1
        break
      fi
      sleep 0.1
      HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT=$((HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT + 1))
    done
  fi
  if [ "$HERDR_PRESENTATION_FOCUS_LOCK_HELD" = 1 ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" 2>/dev/null || true
    HERDR_PRESENTATION_FOCUS_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_FOCUS_LOCK" || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" != orca ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" || exit $?
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token"
rm -rf "$STATE/.crew-signal/$ID"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
