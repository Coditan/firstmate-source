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
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
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

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
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
