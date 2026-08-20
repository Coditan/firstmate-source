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
# pr_head the same way for the same reason. The read is retried a small, fixed
# number of times so a rate limit or a network blip does not become a refusal on
# the first attempt; the ceiling is explicit because an unbounded retry is a hang
# rather than a fix.
#
# A title that could not be read after those attempts is refused too, and says so
# distinctly: this path cannot tell a real title from a placeholder without
# reading it. "This title is a placeholder" and "I could not read this title" are
# two different facts, so they get two different messages and two different
# escapes. --allow-unreadable-title says only that the caller is proceeding
# without having read the title, and never lets a title that was read and does
# match a placeholder through; --allow-placeholder-title lands a read placeholder
# deliberately, and never lets an unread title through. Collapsing the two would
# make an operator assert something they do not know in order to merge.
#
# A pull request that no task in this home owns is landed through
# --no-local-task, which takes no task id at all. Two real situations produce
# one. Its task was torn down after the work finished, measured on 2026-08-20 on
# PRs 153, 155 and 156 of Coditan/firstmate-source, all green and none of them
# mergeable here. Or another vessel built it and handed it over for this
# vessel's merge decision, so the task metadata only ever existed in that
# vessel's home. Until this flag existed neither had any sanctioned route to
# land, and a guard that protects nothing while blocking real work is the exact
# pressure that gets guards reached around.
#
# The requirement is untouched for the case it was built for. A merge naming a
# task still records pr= and pr_head= through bin/fm-pr-check.sh and still
# refuses when that recording did not happen; the recording is never optional
# for a task that exists. --no-local-task is not an override of that check,
# because a merge with no local task has no local cleanup to protect: pr= and
# pr_head= exist so bin/fm-teardown.sh can verify landed work after a squash,
# and there is no teardown here to verify anything.
#
# What keeps it from becoming that override wearing a nicer name is that it
# carries no task id, so there is no task it can be aimed at. A second check
# backs that up: it refuses if any task in this home has already recorded this
# pull request's URL, which is the ordinary state of an owned task because
# firstmate records the URL when the pull request is first reported. That check
# cannot see a task that owns the pull request and has not recorded it yet, and
# does not pretend to - the missing task id is what carries the guarantee, and
# this is the second line rather than the first.
#
# The no-local-task merge says in its own output that it recorded nothing and
# why, rather than succeeding silently, because a later reader has to be able to
# tell the two paths apart: one leaves a recorded pr= and an armed merge watch
# behind, and the other leaves nothing at all.
# Usage: fm-pr-merge.sh [--allow-placeholder-title] [--allow-unreadable-title]
#          <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
#        fm-pr-merge.sh [--allow-placeholder-title] [--allow-unreadable-title]
#          --no-local-task <pr-url> [-- <extra gh-axi pr merge args>]
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
ALLOW_UNREADABLE_TITLE=0
NO_LOCAL_TASK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-placeholder-title)
      ALLOW_PLACEHOLDER_TITLE=1
      shift
      ;;
    --allow-unreadable-title)
      ALLOW_UNREADABLE_TITLE=1
      shift
      ;;
    --no-local-task)
      NO_LOCAL_TASK=1
      shift
      ;;
    *) break ;;
  esac
done

# --no-local-task takes the PR URL alone. An empty ID is this path's single
# marker for "no task in this home owns this pull request", and every later
# task-shaped step reads that marker rather than re-deciding the question.
ID=
if [ "$NO_LOCAL_TASK" -eq 1 ]; then
  if [ "$#" -lt 1 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  RAW_URL=$1
  shift 1
  # With no task id the first positional is the URL, so a task id passed here
  # out of habit would otherwise slide silently into the forwarded merge
  # arguments. Extra arguments must be introduced by an explicit -- on this path.
  if [ "$#" -gt 0 ] && [ "$1" != "--" ]; then
    echo "error: --no-local-task takes only the PR URL; pass any extra merge arguments after --" >&2
    exit 2
  fi
else
  if [ "$#" -lt 2 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  ID=$1
  RAW_URL=$2
  shift 2
fi
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if { [ -n "$ID" ] && ! fm_pr_task_id_valid "$ID"; } || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
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

# `tr` rather than ${var,,} so this guard also runs on the bash 3.2 that a stock
# macOS still ships; a bad substitution here would abort the very merge path this
# guard exists to make trustworthy.
lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

title_is_placeholder() {
  local candidate=$1 known
  candidate=${candidate//$'\r'/}
  candidate="${candidate#"${candidate%%[![:space:]]*}"}"
  candidate="${candidate%"${candidate##*[![:space:]]}"}"
  candidate=$(lowercase "$candidate")
  for known in "${PLACEHOLDER_TITLES[@]}"; do
    if [ "$candidate" = "$(lowercase "$known")" ]; then
      return 0
    fi
  done
  return 1
}

# A transient read failure - a rate limit, a network blip, a token momentarily
# short of read scope - must not be reported as a title that cannot be read, so
# the read gets a few attempts. The count is fixed and small: this sits in front
# of a merge an operator is waiting on.
TITLE_READ_ATTEMPTS=3
TITLE_READ_RETRY_DELAY=1

read_pr_title() {
  local attempt=1 title
  command -v gh >/dev/null 2>&1 || return 1
  while :; do
    if title=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      --json title -q .title 2>/dev/null) \
      && [ -n "${title//[[:space:]]/}" ]; then
      printf '%s' "$title"
      return 0
    fi
    [ "$attempt" -lt "$TITLE_READ_ATTEMPTS" ] || return 1
    attempt=$((attempt + 1))
    sleep "$TITLE_READ_RETRY_DELAY"
  done
}

# The task in this home, if any, that has already recorded this pull request's
# URL. Symlinked metadata is skipped rather than followed, for the same reason
# the task path refuses one below.
owning_task_id() {
  local candidate id
  [ -d "$STATE" ] || return 0
  for candidate in "$STATE"/*.meta; do
    [ -f "$candidate" ] || continue
    [ ! -L "$candidate" ] || continue
    if grep -qxF "pr=$URL" "$candidate"; then
      id=${candidate##*/}
      printf '%s' "${id%.meta}"
      return 0
    fi
  done
  return 0
}

# Task-derived paths are constructed only after the canonical ID validation.
META=
if [ -n "$ID" ]; then
  META="$STATE/$ID.meta"
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    cat >&2 <<EOF
error: task metadata is unavailable
remedy: this home holds no record of task $ID, so there is nothing here to
       record this merge against. Check the task id first, because a typo lands
       exactly here. If no task in this home owns this pull request - its task
       was already cleaned up, or another vessel built it and handed it over -
       merge it with no task id at all:
         fm-pr-merge.sh --no-local-task $URL
       That path records nothing and says so in its own output. It is not a way
       to skip the recording for a task that does exist.
EOF
    exit 1
  fi
else
  OWNING_TASK=$(owning_task_id)
  if [ -n "$OWNING_TASK" ]; then
    cat >&2 <<EOF
error: PR $PR_NUMBER in $PR_OWNER/$PR_REPO is already recorded by task
       $OWNING_TASK in this home, so a local task does own it and
       --no-local-task does not describe it. Merging it that way would skip the
       recording that task's cleanup reads to verify its work landed.
remedy: merge it naming the task it belongs to:
         fm-pr-merge.sh $OWNING_TASK $URL
EOF
    exit 1
  fi
fi

# Refuse a placeholder title before any state is recorded and before the merge,
# because the subject line it would produce cannot be repaired afterwards. The
# read runs even under --allow-placeholder-title, so that override can never
# double as a way past a title nobody read.
PR_TITLE=
PR_TITLE_READ=0
if PR_TITLE=$(read_pr_title); then
  PR_TITLE_READ=1
fi

if [ "$PR_TITLE_READ" -eq 0 ]; then
  if [ "$ALLOW_UNREADABLE_TITLE" -eq 0 ]; then
    cat >&2 <<EOF
error: could not read the title of PR $PR_NUMBER in $PR_OWNER/$PR_REPO, after up
       to $TITLE_READ_ATTEMPTS attempts, so this merge does not know what the
       title says. That is all this reports: the title was not read, not judged.
remedy: the cause may be transient - a rate limit, a network failure, or a token
       momentarily without read scope on that repository - in which case re-running
       this merge is usually enough. It may also be that gh is not installed, or
       not authenticated for that repository; check with
         gh pr view $PR_NUMBER --repo $PR_OWNER/$PR_REPO --json title
       To merge without having read the title, re-run with
       --allow-unreadable-title before the task id. That flag asserts only that
       you are proceeding unread, and nothing at all about what the title says.
EOF
    exit 1
  fi
elif [ "$ALLOW_PLACEHOLDER_TITLE" -eq 0 ] && title_is_placeholder "$PR_TITLE"; then
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

if [ -n "$ID" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
else
  # Said out loud, and before the merge, so this outcome can never be mistaken
  # for the recorded one by whoever reads the run afterwards.
  cat <<EOF
note: PR $PR_NUMBER in $PR_OWNER/$PR_REPO is being merged with no local task, so
      no pr= and no pr_head= were recorded and no merge watch was armed. Nothing
      here will need that record: it exists so a task's cleanup can verify its
      work landed, and this pull request has no task in this home to clean up. A
      merge naming a task still records both.
EOF
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args+=(--merge)
fi
# The forge deletes the head branch as part of this merge, and only this merge.
if ! caller_has_delete_choice "$@"; then
  merge_args+=(--delete-branch)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
