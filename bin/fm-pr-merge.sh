#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work even after historical
# or explicitly requested squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --merge, producing a real merge commit, when the
# caller passes none of --squash, --merge, --rebase, or --method after the
# optional -- separator. A real merge commit is the default because a squashed
# branch tip is never an ancestor of the default branch, so squash ancestry
# cannot prove a branch landed and every later reader has to fall back to the
# patch-id and content ladder. Extra args must not include --repo or -R because
# the repository comes only from the URL.
#
# The merged head branch is deleted by default: --delete-branch is added unless
# the caller already chose, with --delete-branch, or --delete-branch=false to
# keep the branch. Only those long forms count as a choice, because gh-axi's pr
# merge rebuilds the gh argv from the flags it recognizes and silently discards
# leftovers such as -d, so honouring the shorthand as an opt-out deleted nothing
# at all; an opt-out that silently fails to apply is worse than none. A caller
# passing -d therefore still gets this path's own --delete-branch. The forge
# performs that deletion as part of the merge, so this path never issues a
# branch-delete command of its own. Verified against gh
# 2.96.0: a failed merge returns before either deletion, only the just-merged
# PR's own head branch is deleted, a head branch the forge already removed under
# delete_branch_on_merge is tolerated rather than an error, and no local branch
# is touched because this path always passes --repo. Merged branches have two
# further producers this does not cover; docs/merged-branch-cleanup.md owns them.
#
# A placeholder PR title is refused before anything is recorded or merged. The
# validation pipeline that opens most task PRs drafts the title with an agent
# call and, when that call fails, falls back to one fixed literal; the pipeline
# then opens the PR anyway. Merging that PR writes the literal into the merge
# commit's subject line, which is the first and often only line every later
# reader of the history sees, and which no one can edit afterwards. Observed
# twice on 2026-08-10 in this repository, on PRs 85 and 86, from two different
# tasks; both were caught and retitled by hand, which is memory rather than a
# mechanism. That producing tool is not this repository's to change, so this
# guard does not fix the placeholder; it keeps the result out of the history.
#
# Three deliberate choices in that guard:
#   - The match is an exact, case-insensitive comparison against a list of
#     literals actually observed, never a pattern. A heuristic such as "any
#     chore: update ..." would eventually refuse a legitimate title, and a guard
#     that cries wolf is bypassed rather than heeded, which is worse than none.
#   - The guard stops; it never rewrites. A subject line invented from the body
#     is a plausible-looking guess landing permanently in history, which is the
#     same defect wearing a different coat.
#   - The refusal is overridable with --allow-placeholder-title before the task
#     id. Merges here can run unattended under a standing authorization, and a
#     refusal with no way through invites the next operator to reach for a bare
#     forge merge instead, which records no pr= and leaves teardown's landed
#     check nothing to verify against. An escape hatch keeps a deliberate merge
#     inside this path.
# The title is read with plain `gh` rather than gh-axi because only `gh` exposes
# a single field as machine-readable output (-q); bin/fm-pr-check.sh reads
# pr_head the same way for the same reason. An unreadable title is refused too,
# and says so distinctly: this path cannot tell a real title from a placeholder
# without reading it, and `gh` is already required for the merge itself.
# Usage: fm-pr-merge.sh [--allow-placeholder-title] <task-id> <pr-url>
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# This path's own options are read before the positional arguments, so they can
# never collide with a gh-axi flag forwarded after the -- separator.
ALLOW_PLACEHOLDER_TITLE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-placeholder-title)
      ALLOW_PLACEHOLDER_TITLE=1
      shift
      ;;
    *) break ;;
  esac
done

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_has_delete_choice() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --delete-branch|--delete-branch=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Exactly the titles seen landing as placeholders, matched whole. Add a literal
# here only after observing it on a real PR; the narrowness is the point.
PLACEHOLDER_TITLES=(
  'chore: update pull request'
)

title_is_placeholder() {
  local candidate=$1 known
  candidate=${candidate//$'\r'/}
  candidate="${candidate#"${candidate%%[![:space:]]*}"}"
  candidate="${candidate%"${candidate##*[![:space:]]}"}"
  candidate=${candidate,,}
  for known in "${PLACEHOLDER_TITLES[@]}"; do
    if [ "$candidate" = "${known,,}" ]; then
      return 0
    fi
  done
  return 1
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Refuse a placeholder title before any state is recorded and before the merge,
# because the subject line it would produce cannot be repaired afterwards.
if [ "$ALLOW_PLACEHOLDER_TITLE" -eq 0 ]; then
  PR_TITLE=
  if command -v gh >/dev/null 2>&1; then
    PR_TITLE=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      --json title -q .title 2>/dev/null) || PR_TITLE=
  fi
  if [ -z "${PR_TITLE//[[:space:]]/}" ]; then
    cat >&2 <<EOF
error: could not read the title of PR $PR_NUMBER in $PR_OWNER/$PR_REPO, so this
       merge cannot tell a real title from the placeholder the validation
       pipeline falls back to when its title drafting fails.
remedy: make sure gh is installed and authenticated for that repository, then
       re-run this merge. To merge without checking the title, re-run with
       --allow-placeholder-title before the task id.
EOF
    exit 1
  fi
  if title_is_placeholder "$PR_TITLE"; then
    cat >&2 <<EOF
error: PR $PR_NUMBER is titled "$PR_TITLE", which is the validation pipeline's
       placeholder for a title it could not draft, not a description of the
       change. Merging writes it into the merge commit's subject line, where it
       becomes the first line of history every later reader sees and can no
       longer be edited.
remedy: give the PR a real title describing the change, then re-run this merge:
         gh pr edit $PR_NUMBER --repo $PR_OWNER/$PR_REPO --title '<type(scope): what changed>'
       To land this title deliberately, re-run with --allow-placeholder-title
       before the task id.
EOF
    exit 1
  fi
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args+=(--merge)
fi
# The forge deletes the head branch as part of this merge, and only this merge.
if ! caller_has_delete_choice "$@"; then
  merge_args+=(--delete-branch)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
