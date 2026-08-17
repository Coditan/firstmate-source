#!/usr/bin/env bash
# Remove a registered project clone through one guarded path.
#
# The helper refuses before any destructive step when it cannot prove the removal
# is lossless enough for firstmate's project-write exception:
#   - the captain-approved flag is present;
#   - the project clone exists under this home's projects/ directory;
#   - data/projects.md contains exactly one matching registry entry;
#   - the primary clone has no uncommitted changes;
#   - every local branch tip is either preserved on a remote-tracking ref, has
#     content already represented on the default branch, or names a merged PR;
#   - every attached worktree is either the primary clone or a prunable stale
#     entry;
#   - no registered secondmate home still carries this project;
#   - no in-flight or queued backlog item names this project as its repo.
#
# On a real removal the project directory and registry entry are changed as one
# operation: the clone is first moved to a private removal path, the registry is
# atomically rewritten, and only then is the moved clone deleted. If the registry
# rewrite fails, the clone is moved back before the helper exits.
#
# Usage: fm-project-remove.sh <project-name> --captain-approved [--dry-run]
#   --captain-approved  required proof that firstmate is acting on the captain's
#                       explicit project-removal decision.
#   --dry-run           run the full read-only safety inspection and print what
#                       would be removed, without fetching, pruning, moving, or
#                       deleting anything.
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

commit_on_any_remote() {
  local commit=$1 ref
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$PROJECT_ABS" merge-base --is-ancestor "$commit" "$ref" 2>/dev/null && return 0
  done <<EOF
$(git -C "$PROJECT_ABS" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null || true)
EOF
  return 1
}

commit_in_default_history() {
  local commit=$1
  git -C "$PROJECT_ABS" merge-base --is-ancestor "$commit" "$DEFAULT_REF" 2>/dev/null
}

branch_patch_content_in_default() {
  local branch=$1 cherry
  cherry=$(git -C "$PROJECT_ABS" cherry "$DEFAULT_REF" "$branch" 2>/dev/null) || return 1
  [ -n "$cherry" ] || return 0
  ! printf '%s\n' "$cherry" | grep -q '^+'
}

branch_tree_in_default_history() {
  local branch=$1 tree
  tree=$(git -C "$PROJECT_ABS" rev-parse --verify "$branch^{tree}" 2>/dev/null) || return 1
  git -C "$PROJECT_ABS" log --format=%T "$DEFAULT_REF" 2>/dev/null | grep -Fx "$tree" >/dev/null
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

merged_pr_proves_branch() {
  local branch=$1 number out
  number=$(pr_number_from_branch "$branch") || return 1
  command -v gh-axi >/dev/null 2>&1 || return 1
  out=$(cd "$PROJECT_ABS" && gh-axi pr view "$number" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]*state: merged$' || return 1
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]*merged: "?[0-9]' || return 1
}

branch_is_safe() {
  local branch=$1 tip proof
  tip=$(git -C "$PROJECT_ABS" rev-parse --verify "$branch^{commit}" 2>/dev/null) || return 1
  if commit_on_any_remote "$tip"; then
    printf 'remote-tracking ref contains %s\n' "$tip"
    return 0
  fi
  if commit_in_default_history "$tip"; then
    printf 'default branch contains %s by ancestry\n' "$tip"
    return 0
  fi
  if branch_patch_content_in_default "$branch"; then
    proof=$(git -C "$PROJECT_ABS" rev-parse --short "$tip" 2>/dev/null || printf '%s' "$tip")
    printf 'default branch contains %s by patch-id\n' "$proof"
    return 0
  fi
  if branch_tree_in_default_history "$branch"; then
    printf 'default branch history contains the branch tip tree\n'
    return 0
  fi
  if merged_pr_proves_branch "$branch"; then
    printf 'merged PR %s recorded by GitHub\n' "$(pr_number_from_branch "$branch")"
    return 0
  fi
  return 1
}

branch_refusal_detail() {
  local branch=$1
  git -C "$PROJECT_ABS" log --oneline "$branch" --not --remotes --not "$DEFAULT_REF" -- 2>/dev/null \
    | sed -n '1,6p'
}

check_primary_clean() {
  local dirty_raw dirty
  dirty=$(git -C "$PROJECT_ABS" status --porcelain=v1 --untracked-files=all 2>/dev/null) \
    || refuse "cannot inspect $PROJECT_ABS for uncommitted changes."
  dirty_raw=$dirty
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? \.claude/worktrees/' | head -1 || true)
  [ -z "$dirty" ] || {
    printf '%s\n' "$dirty_raw" | sed -n '1,10p' >&2
    refuse "project clone $PROJECT_ABS has uncommitted changes."
  }
}

check_local_branches() {
  local branch proof detail bad=0
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if proof=$(branch_is_safe "$branch"); then
      BRANCH_PROOFS="${BRANCH_PROOFS}${branch}: ${proof}
"
      continue
    fi
    bad=1
    printf 'local branch %s has no preservation or landed-content proof\n' "$branch" >&2
    detail=$(branch_refusal_detail "$branch" || true)
    [ -z "$detail" ] || printf '%s\n' "$detail" >&2
  done <<EOF
$(git -C "$PROJECT_ABS" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
EOF
  [ "$bad" -eq 0 ] || refuse "local branches carry commits that are not proved landed or preserved."
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
      ATTACHED_PROOFS="${ATTACHED_PROOFS}${path}: prunable stale worktree entry
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
  local conflicts
  [ -e "$BACKLOG" ] || return 0
  [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ] \
    || refuse "cannot safely inspect backlog at $BACKLOG."
  conflicts=$(awk -v n="$PROJECT_NAME" '
    function repo_names_project(meta, n, value, parts, names, repo_count, repos, i) {
      value = substr(meta, 8, length(meta) - 8)
      split(value, parts, ",")
      names = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", names)
      repo_count = split(names, repos, /[[:space:]]+/)
      for (i = 1; i <= repo_count; i++) {
        if (repos[i] == n) {
          return 1
        }
      }
      return 0
    }
    /^## / {
      active = ($0 == "## In flight" || $0 == "## Queued")
      next
    }
    active && $0 ~ /^- \[ \]/ {
      line = $0
      while (match(line, /\(repo: [^)]*\)/)) {
        meta = substr(line, RSTART, RLENGTH)
        if (repo_names_project(meta, n)) {
          print
          next
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$BACKLOG") || refuse "cannot inspect backlog at $BACKLOG."
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

fetch_before_removal() {
  local remotes
  remotes=$(git -C "$PROJECT_ABS" remote 2>/dev/null || true)
  [ -n "$remotes" ] || return 0
  git -C "$PROJECT_ABS" fetch --all --prune --quiet
}

remove_attached_worktrees() {
  local path head branch prunable abs_path
  while IFS=$'\t' read -r path head branch prunable; do
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

if [ "$DRY_RUN" -eq 0 ]; then
  fetch_before_removal || refuse "cannot refresh remotes for $PROJECT_NAME before removal."
fi

DEFAULT_REF=$(project_default_ref) \
  || refuse "cannot determine a default branch for $PROJECT_NAME."
BRANCH_PROOFS=''
ATTACHED_PROOFS=''

check_registry
check_primary_clean
check_local_branches
check_attached_worktrees
check_secondmates
check_backlog
check_live_meta

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'PASS: project %s removal safety checks passed.\n' "$PROJECT_NAME"
  printf 'DRY-RUN: would remove %s.\n' "$PROJECT_ABS"
  printf 'DRY-RUN: would remove the matching entry from %s in the same operation.\n' "$REG"
  printf 'Default ref: %s\n' "$DEFAULT_REF"
  printf 'Local branch proofs:\n%s' "$BRANCH_PROOFS"
  printf 'Attached worktree proofs:\n%s' "$ATTACHED_PROOFS"
  exit 0
fi

REMOVE_PATH="$PROJECTS_ABS/.fm-removing-${PROJECT_NAME}.$$"
[ ! -e "$REMOVE_PATH" ] || refuse "temporary removal path already exists: $REMOVE_PATH."

remove_attached_worktrees || refuse "failed to remove attached worktrees for $PROJECT_NAME; project clone and registry left in place."
mv "$PROJECT_ABS" "$REMOVE_PATH" || refuse "failed to move project clone to removal path; registry left unchanged."
if ! rewrite_registry_without_project; then
  mv "$REMOVE_PATH" "$PROJECT_ABS" 2>/dev/null || true
  refuse "failed to remove $PROJECT_NAME from $REG; project clone restored if possible."
fi
rm -rf -- "$REMOVE_PATH"
printf 'removed project %s and registry entry from %s\n' "$PROJECT_NAME" "$REG"
