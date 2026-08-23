#!/usr/bin/env bash
# Remove a registered project clone through one guarded path.
#
# The helper refuses before any destructive step when it cannot prove the removal
# is lossless enough for firstmate's project-write exception:
#   - the captain-approved flag is present;
#   - the project clone exists under this home's projects/ directory;
#   - data/projects.md contains exactly one matching registry entry;
#   - no registered secondmate home still carries this project;
#   - no in-flight or queued backlog item names this project as its repo;
#   - no live task metadata still references this project;
#   - the primary clone has no uncommitted changes;
#   - every attached worktree is either the primary clone or a prunable stale
#     entry;
#   - every local work-bearing ref is either preserved on a COUNTED remote's
#     remote-tracking ref, has content already represented on the default
#     branch, or names a merged PR.
#
# COUNTED REMOTES. A preservation proof used to accept any remote-tracking ref at
# all, and the validation pipeline's own bare mirror under
# ~/.no-mistakes/repos/<id>.git is a remote by git's reckoning. So a branch that
# got no further than the pipeline's own scratch read as preserved and the whole
# clone was deleted. bin/fm-landing-remote-lib.sh owns the recognition, shared
# with bin/fm-teardown.sh so the two cannot drift; only remotes the project is
# actually registered against are cited as proof here, and a remote whose name
# cannot serve as a ref selector is named as left out rather than silently
# counted.
#
# WHERE THIS DIVERGES FROM TEARDOWN, DELIBERATELY. Teardown treats a remote it
# could not re-read as supplying no evidence at all: it drops that remote's
# cached refs and refuses. Removal must not, and the REMOTE REFRESH note below
# says why - a dead origin is the ordinary reason a clone is being removed, and
# refusing on the fetch would make such a clone unremovable while its own local
# proofs are unchanged. Removal therefore keeps the cached refs, names every
# remote it could not re-read, and reaches its verdict on the landed-work
# evidence. The residual is stated rather than hidden: when a counted remote
# cannot be re-read, a branch deleted on that remote since the last fetch still
# passes on its stale tracking ref, and the warning is what tells an operator the
# proof rests on unrefreshed state. Teardown closes that half; removal reports it.
#
# WORK-BEARING REFS. Only refs/heads used to be enumerated, so a stash entry, a
# detached-HEAD commit, a local-only tag, a clone parked mid-rebase, and the
# recorded HEAD of a pruned worktree were all invisible to the landed-work test:
# each of those clones passed with PASS and would have been deleted. One
# enumeration closes all of them. It covers:
#   - every ref in the shared ref space except refs/remotes/* and
#     refs/prefetch/*, which hold remote content rather than local work:
#     refs/heads, refs/tags, refs/stash, refs/notes, and anything else a tool
#     has written;
#   - every entry of the refs/stash reflog AND the refs/stash tip, because
#     refs/stash names only the newest stash while `git stash list` IS that
#     reflog, so older entries hang off no ref and a reflog-less refs/stash
#     lists nothing;
#   - HEAD, the only ref holding a detached commit or the replay point of an
#     interrupted rebase;
#   - the recorded HEAD of every worktree entry, prunable ones included, because
#     a pruned worktree's directory is gone while its commits still live only in
#     this clone's object database.
# Deliberately NOT enumerated: the HEAD reflog. It is an automatic undo log, not
# a deliberate save, and every reset, amend, and rebase leaves entries in it that
# no longer represent wanted work, so honouring it would refuse nearly every
# clone. This limit is stated rather than left implied: the sweep is complete
# over named refs, stashes, HEADs, and worktree heads, and no further.
#
# REMOTE REFRESH. Only counted remotes are refreshed; the pipeline's mirror is
# neither fetched nor cited, and each remote is fetched on its own so one dead
# remote does not cost another its re-read. The refresh runs after the cheap
# read-only checks, so a project that will be refused anyway never gets its
# remote-tracking refs pruned first, and a failed refresh no longer ends the run:
# a deleted origin, or a network or auth outage, is exactly the situation that
# motivates removing a clone. When the
# refresh fails, the run continues and every verdict it prints carries the notice
# that the proofs rest on the last known remote-tracking state, so the run
# refuses on the landed-work evidence or passes on it, never on the fetch.
#
# On a real removal the project directory and registry entry are changed as one
# operation: the registry is snapshotted, the clone is moved to a private removal
# path, the registry is atomically rewritten, and only then is the moved clone
# deleted. An EXIT/INT/TERM/HUP trap restores both the clone and the registry if
# anything interrupts that window before the delete begins.
#
# Usage: fm-project-remove.sh <project-name> --captain-approved [--dry-run]
#   --captain-approved  required proof that firstmate is acting on the captain's
#                       explicit project-removal decision. Required for --dry-run
#                       too, so the documented dry-run invocation names both.
#   --dry-run           run the full read-only safety inspection and print what
#                       would be removed, without fetching, pruning, moving, or
#                       deleting anything. Because it does not refresh remotes,
#                       its verdict is computed against the current
#                       remote-tracking state, and it says so in its output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"
BACKLOG="$DATA/backlog.md"
SECONDMATES="$DATA/secondmates.md"

# Which remotes may be cited as proof that work left this machine. Shared with
# bin/fm-teardown.sh so one reading of "that is only the pipeline's own mirror"
# serves both; the policy built on it below is this script's own.
# shellcheck source=bin/fm-landing-remote-lib.sh
. "$SCRIPT_DIR/fm-landing-remote-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-project-remove.sh <project-name> --captain-approved [--dry-run]
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

PROJECT_NAME=${1:-}
[ -n "$PROJECT_NAME" ] || { usage; exit 2; }
shift

CAPTAIN_APPROVED=0
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain-approved) CAPTAIN_APPROVED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

case "$PROJECT_NAME" in
  ''|.*|*/*|*[!A-Za-z0-9._-]*)
    die "invalid project name: $PROJECT_NAME"
    ;;
esac

[ "$CAPTAIN_APPROVED" -eq 1 ] \
  || refuse "missing --captain-approved; project removal requires the captain's explicit removal decision."

# Removal-window and scratch-file bookkeeping, read by cleanup_on_exit below.
REMOVE_PATH=''
REMOVAL_STAGED=0
REMOVAL_DELETING=0
REMOVAL_REGISTRY_BACKUP=''
PATCH_INDEX_FILE=''
PROJECT_ABS=''

# The move/rewrite/delete window is the one stretch where an interrupted run can
# leave the clone at a hidden path with its registry entry already gone, so it
# restores both halves rather than leaving manual recovery to whoever finds it.
# Once the delete has begun the clone is no longer whole, so it is deliberately
# NOT moved back into place looking like a working checkout; the leftover path is
# named instead.
cleanup_on_exit() {
  if [ "$REMOVAL_STAGED" -eq 1 ] && [ "$REMOVAL_DELETING" -eq 0 ]; then
    REMOVAL_STAGED=0
    if [ -n "$REMOVAL_REGISTRY_BACKUP" ] && [ -f "$REMOVAL_REGISTRY_BACKUP" ]; then
      cp -- "$REMOVAL_REGISTRY_BACKUP" "$REG" 2>/dev/null \
        || printf 'ERROR: could not restore %s from %s.\n' "$REG" "$REMOVAL_REGISTRY_BACKUP" >&2
    fi
    if mv -- "$REMOVE_PATH" "$PROJECT_ABS" 2>/dev/null; then
      printf 'REFUSED: removal of %s was interrupted; the clone and its registry entry were restored.\n' \
        "$PROJECT_NAME" >&2
    else
      printf 'ERROR: removal of %s was interrupted and its clone could not be restored to %s; it is at %s.\n' \
        "$PROJECT_NAME" "$PROJECT_ABS" "$REMOVE_PATH" >&2
    fi
  fi
  [ -z "$REMOVAL_REGISTRY_BACKUP" ] || rm -f -- "$REMOVAL_REGISTRY_BACKUP"
  [ -z "$PATCH_INDEX_FILE" ] || rm -f -- "$PATCH_INDEX_FILE"
}

# shellcheck disable=SC2317,SC2329 # Invoked by the signal traps below.
signal_exit() {
  trap - HUP INT TERM
  exit "$1"
}

trap cleanup_on_exit EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] && [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

project_default_ref() {
  local ref branch
  ref=$(git -C "$PROJECT_ABS" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for branch in origin/main origin/master main master; do
    if git -C "$PROJECT_ABS" rev-parse --quiet --verify "$branch^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

path_is_under() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 0
  case "$path" in "$ancestor"/*) return 0 ;; esac
  return 1
}

path_is_child_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in "$ancestor"/*) return 0 ;; esac
  return 1
}

# The remotes whose refs may be cited as preservation proof: every remote this
# clone is configured against except the validation pipeline's own mirror, which
# never leaves the machine. Resolved once per run and locally only - reading a
# remote's effective URL contacts nothing.
#
# A remote whose name cannot serve as a ref selector is recorded separately and
# named in the output. Dropping it silently would understate the proof; counting
# it would let its pattern select refs it does not own.
FM_COUNTED_REMOTES_RESOLVED=0
FM_COUNTED_REMOTES=
FM_COUNTED_REMOTES_UNUSABLE=
FM_REMOTES_UNREADABLE=
FM_COUNTED_REF_PATTERNS=()

#
# The ref-selector patterns are built once here, not per ref. Every work-bearing
# ref asks commit_on_any_remote below, and rebuilding them there would put a
# subshell back into the loop the one-git-call note is about.
# `refs/remotes/<name>` matches that remote's refs and no others: git matches a
# literal pattern completely or up to a slash, so `refs/remotes/origin` selects
# refs/remotes/origin/main and never refs/remotes/origin-fork/main.
resolve_counted_remotes() {
  local name url counted='' unusable=''
  [ "$FM_COUNTED_REMOTES_RESOLVED" = 1 ] && return 0
  FM_COUNTED_REMOTES_RESOLVED=1
  FM_COUNTED_REF_PATTERNS=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! remote_name_selects_refs "$name"; then
      unusable="$unusable $name"
      continue
    fi
    url=$(remote_effective_url "$PROJECT_ABS" "$name") || continue
    [ -n "$url" ] || continue
    url_is_pipeline_mirror "$url" && continue
    counted="$counted $name"
    FM_COUNTED_REF_PATTERNS+=("refs/remotes/$name")
  done <<EOF
$(git -C "$PROJECT_ABS" remote 2>/dev/null)
EOF
  FM_COUNTED_REMOTES=${counted# }
  FM_COUNTED_REMOTES_UNUSABLE=${unusable# }
}

# One git call rather than one merge-base per remote ref: the enumeration below
# asks this of every branch, tag, stash entry, and worktree head, and a repo with
# many remote branches would otherwise multiply out into thousands of processes.
# `--contains` is the same reachability test `merge-base --is-ancestor` performs.
#
# With no counted remote there is no remote proof to be had, and the empty
# pattern list must NOT fall through to scanning all of refs/remotes - that is
# exactly the reading this narrowing exists to remove.
commit_on_any_remote() {
  local commit=$1 found
  resolve_counted_remotes
  [ "${#FM_COUNTED_REF_PATTERNS[@]}" -gt 0 ] || return 1
  found=$(git -C "$PROJECT_ABS" for-each-ref --count=1 --contains "$commit" \
    --format='%(refname)' "${FM_COUNTED_REF_PATTERNS[@]}" 2>/dev/null) || return 1
  [ -n "$found" ]
}

commit_in_default_history() {
  local commit=$1
  git -C "$PROJECT_ABS" merge-base --is-ancestor "$commit" "$DEFAULT_REF" 2>/dev/null
}

commit_patch_id() {
  git -C "$PROJECT_ABS" show --pretty=medium --no-ext-diff "$1" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# Naming the commit that landed a patch used to rescan the whole default history
# per unlanded commit per branch: 6.7ms a commit, so a 20k-commit project spent
# ~135s per commit with no output and looked hung. `git log -p | git patch-id`
# builds the same mapping in one pass, once per run, lazily - nothing is scanned
# unless a ref actually needs a name.
#
# Every caller between here and the main shell reports through a variable rather
# than through stdout, because a command substitution runs in a subshell and the
# built index would be forgotten the moment the proof for one ref finished - the
# per-ref rescan back again, plus a leaked scratch file per ref.
build_patch_index() {
  local file
  [ -z "$PATCH_INDEX_FILE" ] || return 0
  file=$(mktemp "${TMPDIR:-/tmp}/fm-project-remove-patch-index.XXXXXX") || return 1
  printf 'note: indexing %s patch ids once to name landed content.\n' "$DEFAULT_REF" >&2
  git -C "$PROJECT_ABS" log -p --no-ext-diff "$DEFAULT_REF" 2>/dev/null \
    | git patch-id --stable > "$file" 2>/dev/null || true
  PATCH_INDEX_FILE=$file
}

# `git cherry` reporting no `+` line has ALREADY proved the content landed. What
# follows only names the landed commits for the audit trail, so a naming miss
# leaves PATCH_PROOF_NAMES empty and still returns the proof, instead of
# revoking it and pushing the ref toward refusal.
PATCH_PROOF_NAMES=''
rev_patch_content_in_default() {
  local rev=$1 cherry line commit patch_id landed matches='' seen=0
  PATCH_PROOF_NAMES=''
  cherry=$(git -C "$PROJECT_ABS" cherry "$DEFAULT_REF" "$rev" 2>/dev/null) || return 1
  [ -n "$cherry" ] || return 0
  ! printf '%s\n' "$cherry" | grep -q '^+' || return 1
  while IFS= read -r line; do
    case "$line" in '- '*)
      seen=1
      commit=${line#'- '}
      patch_id=$(commit_patch_id "$commit") || continue
      [ -n "$patch_id" ] || continue
      build_patch_index || continue
      landed=$(awk -v id="$patch_id" '$1 == id { print $2; exit }' "$PATCH_INDEX_FILE") || continue
      [ -n "$landed" ] || continue
      landed=$(git -C "$PROJECT_ABS" rev-parse --short "$landed" 2>/dev/null || printf '%s' "$landed")
      case "
$matches
" in *"
$landed
"*) ;;
        *)
          matches="${matches}${landed}
"
          ;;
      esac
      ;;
    esac
  done <<EOF
$cherry
EOF
  [ "$seen" -eq 1 ] || return 1
  [ -z "$matches" ] || PATCH_PROOF_NAMES=$(printf '%s' "$matches" | paste -sd, -)
  return 0
}

rev_tree_in_default_history() {
  local rev=$1 tree commit
  tree=$(git -C "$PROJECT_ABS" rev-parse --verify "$rev^{tree}" 2>/dev/null) || return 1
  commit=$(git -C "$PROJECT_ABS" log --format='%H %T' "$DEFAULT_REF" 2>/dev/null \
    | awk -v t="$tree" '$2 == t { print $1; exit }') || return 1
  [ -n "$commit" ] || return 1
  git -C "$PROJECT_ABS" rev-parse --short "$commit" 2>/dev/null || printf '%s\n' "$commit"
}

pr_number_from_branch() {
  local branch=$1 stem
  stem=${branch#refs/heads/}
  case "$stem" in
    pr[0-9]*|pr[0-9]*tmp)
      stem=${stem#pr}
      stem=${stem%tmp}
      case "$stem" in *[!0-9]*|'') return 1 ;; esac
      printf '%s\n' "$stem"
      ;;
    *) return 1 ;;
  esac
}

github_repo_slug() {
  local url slug
  url=$(git -C "$PROJECT_ABS" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*) slug=${url#git@github.com:} ;;
    https://github.com/*) slug=${url#https://github.com/} ;;
    ssh://git@github.com/*) slug=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%.git}
  case "$slug" in
    */*) printf '%s\n' "$slug" ;;
    *) return 1 ;;
  esac
}

gh_pr_state_and_head() {
  local number=$1 repo=$2
  command -v gh >/dev/null 2>&1 || return 1
  (cd "$PROJECT_ABS" && gh pr view "$number" --repo "$repo" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null)
}

github_has_commit() {
  local repo=$1 commit=$2
  command -v gh >/dev/null 2>&1 || return 1
  (cd "$PROJECT_ABS" && gh api "repos/$repo/commits/$commit" --jq .sha >/dev/null 2>&1)
}

merged_pr_proves_branch() {
  local branch=$1 tip=$2 number out state pr_head repo
  number=$(pr_number_from_branch "$branch") || return 1
  [ -n "$tip" ] || return 1
  if command -v gh-axi >/dev/null 2>&1; then
    out=$(cd "$PROJECT_ABS" && gh-axi pr view "$number" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || out=''
    state=${out%%	*}
    pr_head=${out#*	}
    if [ "$state" = MERGED ] || [ "$state" = merged ]; then
      [ "$pr_head" = "$tip" ] && return 0
    fi
  fi
  repo=$(github_repo_slug) || return 1
  out=$(gh_pr_state_and_head "$number" "$repo") || return 1
  state=${out%%	*}
  pr_head=${out#*	}
  [ "$state" = MERGED ] || [ "$state" = merged ] || return 1
  [ "$pr_head" = "$tip" ] || github_has_commit "$repo" "$tip"
}

work_ref_noun() {
  case "$1" in
    branch) printf 'local branch\n' ;;
    tag) printf 'local tag\n' ;;
    stash) printf 'stashed change\n' ;;
    head) printf 'detached HEAD\n' ;;
    worktree) printf 'worktree HEAD\n' ;;
    *) printf 'local ref\n' ;;
  esac
}

# Emit one "kind<TAB>label<TAB>rev" record per work-bearing ref. See the
# WORK-BEARING REFS note in the header for what is enumerated and what is not.
work_ref_records() {
  local refname oid path head _branch _prunable abs_path
  # The stash reflog comes first so its selector labels win the commit-level
  # deduplication over the bare refs/stash tip below. Both are emitted: the
  # reflog IS `git stash list`, but a refs/stash written without a reflog - by
  # `git update-ref`, or after .git/logs/refs/stash is lost - lists nothing at
  # all, and its commit would otherwise be enumerated nowhere.
  while IFS=$'\t' read -r oid refname; do
    [ -n "$oid" ] || continue
    printf 'stash\t%s\t%s\n' "${refname:-refs/stash}" "$oid"
  done <<EOF
$(git -C "$PROJECT_ABS" reflog show --format='%H%x09%gd' refs/stash 2>/dev/null || true)
EOF
  while IFS=$'\t' read -r refname oid; do
    [ -n "$refname" ] && [ -n "$oid" ] || continue
    case "$refname" in
      # refs/remotes/* is the preservation proof itself. refs/prefetch/* is
      # written only by `git maintenance`'s prefetch task, straight from the
      # remote and never from local work, and it can run ahead of the last real
      # fetch - so enumerating it would refuse a clone over commits that are on
      # the remote by construction.
      refs/remotes/*|refs/prefetch/*) continue ;;
      refs/stash) printf 'stash\t%s\t%s\n' "$refname" "$oid" ;;
      refs/heads/*) printf 'branch\t%s\t%s\n' "${refname#refs/heads/}" "$oid" ;;
      refs/tags/*) printf 'tag\t%s\t%s\n' "${refname#refs/tags/}" "$oid" ;;
      *) printf 'ref\t%s\t%s\n' "$refname" "$oid" ;;
    esac
  done <<EOF
$(git -C "$PROJECT_ABS" for-each-ref --format='%(refname)%09%(objectname)' 2>/dev/null || true)
EOF
  oid=$(git -C "$PROJECT_ABS" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  [ -z "$oid" ] || printf 'head\tHEAD\t%s\n' "$oid"
  while IFS=$'\t' read -r path head _branch _prunable; do
    [ -n "$path" ] && [ -n "$head" ] || continue
    if [ -d "$path" ]; then
      abs_path=$(canonical_existing_dir "$path" 2>/dev/null || printf '%s' "$path")
    else
      abs_path=$path
    fi
    [ "$abs_path" != "$PROJECT_ABS" ] || continue
    printf 'worktree\t%s\t%s\n' "$path" "$head"
  done <<EOF
$(worktree_records)
EOF
}

REF_PROOF=''
ref_is_safe() {
  local kind=$1 label=$2 tip=$3 tree_proof
  REF_PROOF=''
  if commit_on_any_remote "$tip"; then
    REF_PROOF="remote-tracking ref contains $tip"
    return 0
  fi
  if commit_in_default_history "$tip"; then
    REF_PROOF="default branch contains $tip by ancestry"
    return 0
  fi
  if rev_patch_content_in_default "$tip"; then
    if [ -n "$PATCH_PROOF_NAMES" ]; then
      REF_PROOF="default branch history contains patch content landed as $PATCH_PROOF_NAMES"
    else
      REF_PROOF="default branch history contains the patch content of every commit above $DEFAULT_REF"
    fi
    return 0
  fi
  if tree_proof=$(rev_tree_in_default_history "$tip"); then
    REF_PROOF="default branch history contains this tip tree landed as $tree_proof"
    return 0
  fi
  if [ "$kind" = branch ] && merged_pr_proves_branch "$label" "$tip"; then
    REF_PROOF="merged PR $(pr_number_from_branch "$label") records this branch tip"
    return 0
  fi
  return 1
}

# `--not --remotes --not "$DEFAULT_REF"` flipped the default ref back to a
# POSITIVE ref, so the evidence listed the default branch's own landed commits
# beneath the unlanded one and made the risk look several times larger than it
# was. One `--not` excludes both.
#
# The exclusions name the counted remotes rather than all of them, so the
# evidence is drawn against the same set the verdict was: a bare `--remotes`
# here would hide the very commits that reached only the pipeline's mirror, and
# a refusal would print nothing to justify itself.
ref_refusal_detail() {
  local tip=$1 name
  local -a not=()
  resolve_counted_remotes
  for name in $FM_COUNTED_REMOTES; do
    not+=("--remotes=$name")
  done
  git -C "$PROJECT_ABS" log --oneline "$tip" --not ${not[@]+"${not[@]}"} "$DEFAULT_REF" -- 2>/dev/null \
    | sed -n '1,6p'
}

check_primary_clean() {
  local dirty_raw dirty line
  dirty=$(git -C "$PROJECT_ABS" status --porcelain=v1 --untracked-files=all 2>/dev/null) \
    || refuse "cannot inspect $PROJECT_ABS for uncommitted changes."
  dirty_raw=$dirty
  dirty=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if primary_dirty_line_is_registered_claude_worktree "$line"; then
      continue
    fi
    dirty=$line
    break
  done <<EOF
$dirty_raw
EOF
  [ -z "$dirty" ] || {
    printf '%s\n' "$dirty_raw" | sed -n '1,10p' >&2
    refuse "project clone $PROJECT_ABS has uncommitted changes."
  }
}

registered_claude_worktree_paths() {
  local path _head branch prunable abs_path
  while IFS=$'\t' read -r path _head branch prunable; do
    [ -n "$path" ] || continue
    if [ -d "$path" ]; then
      abs_path=$(canonical_existing_dir "$path" 2>/dev/null || printf '%s' "$path")
    else
      abs_path=$path
    fi
    path_is_child_of "$PROJECT_ABS/.claude/worktrees" "$abs_path" || continue
    printf '%s\n' "$abs_path"
  done <<EOF
$(worktree_records)
EOF
}

path_is_registered_claude_worktree() {
  local abs_path=$1 rec
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    [ "$abs_path" = "$rec" ] && return 0
    path_is_child_of "$rec" "$abs_path" && return 0
  done <<EOF
$(registered_claude_worktree_paths)
EOF
  return 1
}

claude_worktree_directory_only_has_registered_entries() {
  local dir="$PROJECT_ABS/.claude/worktrees" entry abs_entry seen=0
  [ -d "$dir" ] || return 1
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || continue
    seen=1
    if [ -d "$entry" ]; then
      abs_entry=$(canonical_existing_dir "$entry" 2>/dev/null || printf '%s' "$entry")
    else
      abs_entry=$entry
    fi
    path_is_registered_claude_worktree "$abs_entry" || return 1
  done
  [ "$seen" -eq 1 ]
}

primary_dirty_line_is_registered_claude_worktree() {
  local line=$1 rel abs_path
  case "$line" in '?? '*)
    rel=${line#'?? '}
    rel=${rel%/}
    ;;
    *) return 1 ;;
  esac
  case "$rel" in
    .claude/worktrees)
      claude_worktree_directory_only_has_registered_entries
      return
      ;;
    .claude/worktrees/*) ;;
    *) return 1 ;;
  esac
  abs_path="$PROJECT_ABS/$rel"
  if [ -d "$abs_path" ]; then
    abs_path=$(canonical_existing_dir "$abs_path" 2>/dev/null || printf '%s' "$abs_path")
  fi
  path_is_registered_claude_worktree "$abs_path"
}

check_local_work_refs() {
  local kind label rev noun tip detail seen='' bad=0
  while IFS=$'\t' read -r kind label rev; do
    [ -n "$kind" ] || continue
    noun=$(work_ref_noun "$kind")
    tip=$(git -C "$PROJECT_ABS" rev-parse --verify --quiet "$rev^{commit}" 2>/dev/null) || tip=''
    if [ -z "$tip" ]; then
      bad=1
      printf '%s %s records %s, which is not a commit this clone can resolve\n' \
        "$noun" "$label" "$rev" >&2
      continue
    fi
    case "
$seen
" in *"
$tip
"*) continue ;;
    esac
    seen="${seen}${tip}
"
    if ref_is_safe "$kind" "$label" "$tip"; then
      WORK_PROOFS="${WORK_PROOFS}${noun} ${label}: ${REF_PROOF}
"
      continue
    fi
    bad=1
    printf '%s %s has no preservation or landed-content proof\n' "$noun" "$label" >&2
    detail=$(ref_refusal_detail "$tip" || true)
    [ -z "$detail" ] || printf '%s\n' "$detail" >&2
  done <<EOF
$(work_ref_records)
EOF
  [ "$bad" -eq 0 ] \
    || refuse "local branches, tags, stashes, or worktree heads carry commits that are not proved landed or preserved."
}

emit_worktree_record() {
  [ -n "${wt_path:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$wt_path" "$wt_head" "$wt_branch" "$wt_prunable"
}

worktree_records() {
  local line wt_path='' wt_head='' wt_branch='' wt_prunable=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        emit_worktree_record
        wt_path=${line#worktree }
        wt_head=''
        wt_branch=''
        wt_prunable=0
        ;;
      HEAD\ *) wt_head=${line#HEAD } ;;
      branch\ refs/heads/*) wt_branch=${line#branch refs/heads/} ;;
      detached) wt_branch=DETACHED ;;
      prunable*) wt_prunable=1 ;;
    esac
  done <<EOF
$(git -C "$PROJECT_ABS" -c core.quotePath=false worktree list --porcelain 2>/dev/null)
EOF
  emit_worktree_record
}

attachment_kind() {
  local path=$1
  if path_is_child_of "$PROJECT_ABS/.claude/worktrees" "$path"; then
    printf 'claude\n'
    return 0
  fi
  case "$path" in
    */.treehouse/*/*/"$PROJECT_NAME"|*/.treehouse/*/"$PROJECT_NAME")
      printf 'treehouse\n'
      return 0
      ;;
  esac
  return 1
}

check_attached_worktrees() {
  local path head branch prunable abs_path kind dirty bad=0
  while IFS=$'\t' read -r path head branch prunable; do
    [ -n "$path" ] || continue
    if [ -d "$path" ]; then
      abs_path=$(canonical_existing_dir "$path" 2>/dev/null || printf '%s' "$path")
    else
      abs_path=$path
    fi
    [ "$abs_path" != "$PROJECT_ABS" ] || continue
    if [ "$prunable" = 1 ]; then
      ATTACHED_PROOFS="${ATTACHED_PROOFS}${path}: prunable stale worktree entry; its recorded HEAD ${head:-none} is proved with the local work refs
"
      continue
    fi
    kind=$(attachment_kind "$abs_path") || {
      bad=1
      printf 'attached worktree %s is not a known treehouse or .claude worktree\n' "$path" >&2
      continue
    }
    if [ -d "$abs_path" ]; then
      dirty=$(git -C "$abs_path" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
        bad=1
        printf 'attached %s worktree %s cannot be inspected for uncommitted changes\n' "$kind" "$path" >&2
        continue
      }
      if [ -n "$dirty" ]; then
        bad=1
        printf 'attached %s worktree %s has uncommitted changes\n' "$kind" "$path" >&2
        printf '%s\n' "$dirty" | sed -n '1,10p' >&2
        continue
      fi
    fi
    bad=1
    printf 'attached %s worktree %s is live; detach or prune it before removing %s\n' "$kind" "$path" "$PROJECT_NAME" >&2
  done <<EOF
$(worktree_records)
EOF
  [ "$bad" -eq 0 ] || refuse "attached worktrees must be detached or pruned before removal."
}

field_contains_project() {
  local field=$1 item
  field=${field//,/ }
  for item in $field; do
    [ "$item" = "$PROJECT_NAME" ] && return 0
  done
  return 1
}

check_secondmates() {
  local line id home projects bad=0
  [ -e "$SECONDMATES" ] || return 0
  [ -f "$SECONDMATES" ] && [ ! -L "$SECONDMATES" ] \
    || refuse "cannot safely inspect secondmate registry at $SECONDMATES."
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*)
      id=$(printf '%s\n' "$line" | awk '{ print $2 }')
      home=$(printf '%s\n' "$line" | sed -n 's/.*(home: \([^;)]*\).*/\1/p')
      projects=$(printf '%s\n' "$line" | sed -n 's/.*; projects: \([^;)]*\).*/\1/p')
      if [ -n "$projects" ] && field_contains_project "$projects"; then
        bad=1
        printf 'secondmate %s registry lists project %s\n' "$id" "$PROJECT_NAME" >&2
      fi
      if [ -n "$home" ] && [ -e "$home/projects/$PROJECT_NAME" ]; then
        bad=1
        printf 'secondmate %s has clone %s/projects/%s\n' "$id" "$home" "$PROJECT_NAME" >&2
      fi
      ;;
    esac
  done < "$SECONDMATES"
  [ "$bad" -eq 0 ] || refuse "registered secondmate clones still exist for $PROJECT_NAME."
}

check_backlog() {
  local conflicts listing
  [ -e "$BACKLOG" ] || return 0
  [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ] \
    || refuse "cannot safely inspect backlog at $BACKLOG."
  command -v tasks-axi >/dev/null 2>&1 \
    || refuse "cannot safely inspect backlog at $BACKLOG because tasks-axi is unavailable."
  listing=$(tasks-axi list --file "$BACKLOG" </dev/null 2>/dev/null) \
    || refuse "cannot inspect backlog at $BACKLOG with tasks-axi."
  conflicts=$(
    printf '%s\n' "$listing" |
      awk -v n="$PROJECT_NAME" '
        function trim(s) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
          return s
        }
        function unquote(s) {
          s = trim(s)
          if (substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") {
            s = substr(s, 2, length(s) - 2)
            gsub(/""/, "\"", s)
          }
          return s
        }
        function csv_field(line, wanted,    i, ch, field, quoted, count) {
          count = 1
          field = ""
          quoted = 0
          for (i = 1; i <= length(line); i++) {
            ch = substr(line, i, 1)
            if (ch == "\"") {
              if (quoted && substr(line, i + 1, 1) == "\"") {
                field = field ch substr(line, i + 1, 1)
                i++
              } else {
                quoted = !quoted
                field = field ch
              }
            } else if (ch == "," && !quoted) {
              if (count == wanted) {
                return unquote(field)
              }
              count++
              field = ""
            } else {
              field = field ch
            }
          }
          return count == wanted ? unquote(field) : ""
        }
        function repo_names_project(repo, n,    parts, names, repos, repo_count, i) {
          split(repo, parts, ",")
          names = trim(parts[1])
          repo_count = split(names, repos, /[[:space:]]+/)
          for (i = 1; i <= repo_count; i++) {
            if (repos[i] == n) {
              return 1
            }
          }
          return 0
        }
        /^tasks\[/ { rows = 1; next }
        rows && $0 !~ /^  / { rows = 0 }
        !rows { next }
        {
          row = substr($0, 3)
          id = csv_field(row, 1)
          state = csv_field(row, 2)
          repo = csv_field(row, 4)
          if ((state == "in_flight" || state == "queued") && repo_names_project(repo, n)) {
            print id "," state "," repo
          }
        }
      '
  ) || refuse "cannot inspect backlog at $BACKLOG with tasks-axi."
  [ -z "$conflicts" ] || {
    printf '%s\n' "$conflicts" >&2
    refuse "in-flight or queued backlog work still names $PROJECT_NAME as its repo."
  }
}

meta_value() {
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" | tail -1
}

check_live_meta() {
  local meta project worktree bad=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || {
      bad=1
      printf 'cannot safely inspect task meta %s\n' "$meta" >&2
      continue
    }
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    if [ "$project" = "$PROJECT_ABS" ] || [ "$project" = "$PROJECT_NAME" ]; then
      bad=1
      printf 'task meta %s records project %s\n' "$meta" "$project" >&2
    elif [ -n "$worktree" ] && path_is_under "$PROJECT_ABS" "$worktree"; then
      bad=1
      printf 'task meta %s records worktree inside %s\n' "$meta" "$PROJECT_ABS" >&2
    fi
  done
  [ "$bad" -eq 0 ] || refuse "live task metadata still references $PROJECT_NAME."
}

registry_match_count() {
  awk -v n="$PROJECT_NAME" '$1=="-" && $2==n { c++ } END { print c + 0 }' "$REG"
}

check_registry() {
  local count
  [ -f "$REG" ] && [ ! -L "$REG" ] || refuse "no ordinary project registry at $REG."
  count=$(registry_match_count) || refuse "cannot inspect project registry at $REG."
  [ "$count" = 1 ] || refuse "expected exactly one data/projects.md entry for $PROJECT_NAME, found $count."
}

rewrite_registry_without_project() {
  local tmp count
  tmp="$REG.tmp.$$"
  awk -v n="$PROJECT_NAME" '!($1=="-" && $2==n) { print }' "$REG" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  count=$(awk -v n="$PROJECT_NAME" '$1=="-" && $2==n { c++ } END { print c + 0 }' "$tmp") || {
    rm -f "$tmp"
    return 1
  }
  if [ "$count" != 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$REG"
}

# Refresh the counted remotes only. `fetch --all` also fetched the pipeline's
# mirror, which supplies no proof and whose absence would fail the whole refresh
# and cost every real remote its re-read. Each is fetched on its own so one dead
# remote does not hide another that answered.
fetch_before_removal() {
  local name failed=''
  resolve_counted_remotes
  [ -n "$FM_COUNTED_REMOTES" ] || return 0
  for name in $FM_COUNTED_REMOTES; do
    git -C "$PROJECT_ABS" fetch --prune --quiet "$name" || failed="$failed $name"
  done
  FM_REMOTES_UNREADABLE=${failed# }
  [ -z "$failed" ]
}

remove_attached_worktrees() {
  local path _head branch prunable abs_path
  while IFS=$'\t' read -r path _head branch prunable; do
    [ -n "$path" ] || continue
    if [ -d "$path" ]; then
      abs_path=$(canonical_existing_dir "$path" 2>/dev/null || printf '%s' "$path")
    else
      abs_path=$path
    fi
    [ "$abs_path" != "$PROJECT_ABS" ] || continue
    if [ "$prunable" = 1 ]; then
      continue
    fi
    refuse "attached worktree appeared after safety checks: $path."
  done <<EOF
$(worktree_records)
EOF
  git -C "$PROJECT_ABS" worktree prune
}

PROJECTS_ABS=$(canonical_existing_dir "$PROJECTS") \
  || refuse "projects directory $PROJECTS does not exist or cannot be inspected."
PROJECT_PATH="$PROJECTS_ABS/$PROJECT_NAME"
[ -e "$PROJECT_PATH" ] || refuse "project clone $PROJECT_PATH does not exist."
[ -d "$PROJECT_PATH" ] && [ ! -L "$PROJECT_PATH" ] \
  || refuse "project path $PROJECT_PATH is not an ordinary directory."
PROJECT_ABS=$(canonical_existing_dir "$PROJECT_PATH") \
  || refuse "cannot canonicalize project path $PROJECT_PATH."
path_is_child_of "$PROJECTS_ABS" "$PROJECT_ABS" \
  || refuse "project path $PROJECT_ABS is not directly under $PROJECTS_ABS."
git -C "$PROJECT_ABS" rev-parse --show-toplevel >/dev/null 2>&1 \
  || refuse "project path $PROJECT_ABS is not an inspectable git worktree."

# Cheap, read-only, repository-untouching checks first: a project that will be
# refused for a registry, backlog, secondmate, or live-work reason must not have
# its remote-tracking refs pruned by a refresh it never needed.
check_registry
check_secondmates
check_backlog
check_live_meta

REMOTES_REFRESHED=1
if [ "$DRY_RUN" -eq 1 ]; then
  REMOTES_REFRESHED=0
elif ! fetch_before_removal; then
  REMOTES_REFRESHED=0
  printf 'WARNING: could not refresh remotes for %s (%s); preservation proofs below rest on the last known remote-tracking state.\n' \
    "$PROJECT_NAME" "$FM_REMOTES_UNREADABLE" >&2
fi

# Named here rather than only inside a refusal: a remote left out of the proof is
# just as material to a run that PASSES, and this is the only place that says so.
# Resolved explicitly, because a dry run never reaches the fetch that would
# otherwise have resolved it, and it must report the same omission a real run does.
resolve_counted_remotes
[ -z "$FM_COUNTED_REMOTES_UNUSABLE" ] \
  || printf 'WARNING: these remote names cannot select refs and were not counted as preservation proof for %s: %s\n' \
    "$PROJECT_NAME" "$FM_COUNTED_REMOTES_UNUSABLE" >&2

DEFAULT_REF=$(project_default_ref) \
  || refuse "cannot determine a default branch for $PROJECT_NAME."
WORK_PROOFS=''
ATTACHED_PROOFS=''

check_primary_clean
check_attached_worktrees
check_local_work_refs

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'PASS: project %s removal safety checks passed.\n' "$PROJECT_NAME"
  printf 'DRY-RUN: would remove %s.\n' "$PROJECT_ABS"
  printf 'DRY-RUN: would remove the matching entry from %s in the same operation.\n' "$REG"
  printf 'DRY-RUN: remote-tracking state was not refreshed, so a real run can reach a different verdict.\n'
  printf 'Default ref: %s\n' "$DEFAULT_REF"
  printf 'Local work proofs:\n%s' "$WORK_PROOFS"
  printf 'Attached worktree proofs:\n%s' "$ATTACHED_PROOFS"
  exit 0
fi

[ "$REMOTES_REFRESHED" -eq 1 ] \
  || printf 'WARNING: the proofs for %s rest on unrefreshed remote-tracking state.\n' "$PROJECT_NAME" >&2

REMOVE_PATH="$PROJECTS_ABS/.fm-removing-${PROJECT_NAME}.$$"
[ ! -e "$REMOVE_PATH" ] || refuse "temporary removal path already exists: $REMOVE_PATH."

remove_attached_worktrees || refuse "failed to remove attached worktrees for $PROJECT_NAME; project clone and registry left in place."

REMOVAL_REGISTRY_BACKUP="$REG.removing.$$"
cp -- "$REG" "$REMOVAL_REGISTRY_BACKUP" \
  || refuse "could not snapshot the project registry at $REG; project clone and registry left in place."

mv -- "$PROJECT_ABS" "$REMOVE_PATH" || refuse "failed to move project clone to removal path; registry left unchanged."
REMOVAL_STAGED=1

rewrite_registry_without_project \
  || refuse "failed to remove $PROJECT_NAME from $REG."

REMOVAL_DELETING=1
rm -rf -- "$REMOVE_PATH" || {
  printf 'ERROR: %s was unregistered but its moved clone could not be deleted; it is at %s and must be removed by hand.\n' \
    "$PROJECT_NAME" "$REMOVE_PATH" >&2
  exit 1
}
REMOVAL_STAGED=0
printf 'removed project %s and registry entry from %s\n' "$PROJECT_NAME" "$REG"
