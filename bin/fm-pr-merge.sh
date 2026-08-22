#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work even after historical
# or explicitly requested squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh, which decides which
# forge it belongs to; a GitHub URL is addressed by owner/repository through
# gh-axi and a pull request on this fleet's own Forgejo instance is addressed by
# project path through forgejo-axi. A GitLab merge request URL parses but is
# still refused here, because nothing has taught this path to merge one.
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
# ---------------------------------------------------------------------------
# The self-hosted forge
#
# The fleet is replacing GitHub with its own Forgejo instance, and every task
# merge goes through this path so the metadata is recorded and these guards run.
# So the forge becomes mergeable by this path learning to speak to it, not by
# anyone learning a second command. Four things differ, and each is handled by
# saying what it is rather than by making it look like GitHub.
#
# 1. THE HEAD COMMIT IS REQUIRED, AND THAT IS A GUARANTEE GITHUB DOES NOT GIVE.
#    forgejo-axi's `pr merge` refuses without --expected-head, so this path
#    reads the pull request's head from the forge and passes it. The client
#    compares it before merging and again after, so a head that moved between
#    the reading and the merge is refused rather than merged as a different
#    commit; the merge request also carries that head as head_commit_id, which
#    is the forge's own opportunity to refuse a head that moved after the
#    client's comparison. docs/forgejo-merge-helper.md is careful about which of
#    those two was established against a real forge and which was not. A head
#    the forge does not supply stops the merge, with no override, because
#    merging without one is not something this forge offers.
#
# 2. THE BRANCH IS NOT DELETED, AND THAT GUARANTEE IS ABSENT RATHER THAN
#    EMULATED. On GitHub the forge deletes the merged head branch as part of the
#    merge, which is why --delete-branch is added by default below. forgejo-axi's
#    `pr merge` has no branch deletion at all. Deleting it through a second call
#    would be a separate action that can fail on its own while the merge stands,
#    and reporting that as part of the merge is how a half-done thing gets read
#    as done. So --delete-branch is refused on this forge and the merge says the
#    branch stays. docs/merged-branch-cleanup.md owns merged-branch cleanup.
#
# 3. NOTHING WATCHES THE MERGE, AND THE RECORDING SAYS SO. bin/fm-pr-poll.sh
#    reads GitHub and GitLab only, so bin/fm-pr-check.sh refuses to arm a
#    Forgejo watch rather than watch nothing. The recording this path needs is
#    separable from that arming, so it calls fm-pr-check.sh --no-watch, which
#    records pr= and pr_head= exactly as the GitHub path does and prints that no
#    watch exists. The head recorded is the one this merge is gated on, passed
#    with --pr-head, so the metadata and the merge cannot disagree.
#
# 4. THE FLAG LANGUAGE IS NOT gh's, SO EXTRA ARGUMENTS ARE TRANSLATED OR
#    REFUSED, NEVER FORWARDED. --merge, --squash and --rebase become --method,
#    and --delete-branch=false is already this forge's behaviour. Anything else
#    is refused: forwarding a gh-shaped flag to a different client produces an
#    error about the flag rather than about the merge, and a caller reads that
#    as a broken tool instead of a rejected request.
#
# The default merge method is a real merge commit here for the same reason it is
# on GitHub, and it matters more on this forge rather than less: this repository
# requires every upstream-sync PR to land as a true merge commit, because a
# squashed tip is not an ancestor of the default branch and a version pin's
# ancestry would then claim a lineage that does not exist. --squash still works
# where a caller asks for it deliberately.
#
# TWO OPERATIONAL FACTS THIS PATH DOES NOT PAPER OVER.
# The base URL is derived from the pull request's own host, which bin/fm-pr-lib.sh
# has already required to equal this home's configured instance; forgejo-axi
# routes by the configured base URL and never by the URL's host, so passing it
# is what keeps a merge from being sent to whatever instance the environment
# happens to name. Because the base URL arrives as a flag, that client resolves
# a token only from FORGEJO_TOKEN_<HOST> or its hosts.json and never from a bare
# FORGEJO_TOKEN. This path deliberately does not pre-check that credential: a
# reachable token proves nothing about whether it may merge, and the read of the
# pull request that happens first is real evidence where a presence check is not.
# jq is required on this forge because the client answers in JSON and the title
# is compared byte for byte; an absent jq is refused rather than worked around.
# ---------------------------------------------------------------------------
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
# them, but this path addresses GitHub by owner/repository and this fleet's own
# Forgejo instance by project path. A GitLab merge request is refused here
# exactly as it was, because nothing below knows how to merge one.
if { [ -n "$ID" ] && ! fm_pr_task_id_valid "$ID"; } || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github|forgejo) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_PATH=$FM_PR_PATH
PR_HOST=$FM_PR_HOST
PR_NUMBER=$FM_PR_NUMBER
# The instance this merge is sent to is the one the pull request's own address
# names, and bin/fm-pr-lib.sh has already refused every host that is not this
# home's configured instance. forgejo-axi routes by the base URL it is given and
# never by the URL's host, so deriving it here is what keeps a merge from
# following whatever instance the surrounding environment happens to name.
FORGEJO_BASE_URL=
[ "$PROVIDER" != forgejo ] || FORGEJO_BASE_URL="https://$PR_HOST"
# How this pull request is named in a message, and how a caller would retitle
# it, both differ per forge. Naming them once keeps every message below saying
# something the reader can act on rather than a GitHub-shaped guess.
if [ "$PROVIDER" = forgejo ]; then
  PR_LOCATION="$PR_PATH on $PR_HOST"
  PR_RETITLE_CMD="forgejo-axi pr update --repo $PR_PATH $PR_NUMBER --base-url $FORGEJO_BASE_URL --title"
  PR_TITLE_READ_CMD="forgejo-axi pr view --repo $PR_PATH $PR_NUMBER --base-url $FORGEJO_BASE_URL --fields title"
else
  PR_LOCATION="$PR_OWNER/$PR_REPO"
  PR_RETITLE_CMD="gh pr edit $PR_NUMBER --repo $PR_OWNER/$PR_REPO --title"
  PR_TITLE_READ_CMD="gh pr view $PR_NUMBER --repo $PR_OWNER/$PR_REPO --json title"
fi
[ "${1:-}" = "--" ] && shift

# Both tools are refused before anything is recorded, read, or merged, because
# an absent one here is a merge that cannot happen rather than a merge that
# happens differently.
if [ "$PROVIDER" = forgejo ]; then
  if ! command -v forgejo-axi >/dev/null 2>&1; then
    cat >&2 <<EOF
error: merging a pull request on $PR_HOST needs forgejo-axi on PATH, and it is
       not installed where this session can run it.
remedy: install it where both an agent session and the validation pipeline's
       daemon resolve it:
         npm install -g --prefix "\$HOME/.local" 'forgejo-axi@^1.3.0'
       bin/fm-bootstrap.sh reports the same requirement at session start
       wherever this home names a Forgejo instance.
EOF
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    cat >&2 <<EOF
error: merging a pull request on $PR_HOST needs jq on PATH. The forge client
       answers in JSON, and this path compares the pull request's title byte for
       byte and checks the forge's own merged proof against the head it merged;
       neither is something to do with a hand-rolled parser.
remedy: install jq, then re-run this merge.
EOF
    exit 1
  fi
  # One trap, named rather than left to be met as an unexplained refusal from
  # the forge. Passing the instance as a flag is what keeps this merge on the
  # right server, and it is also what makes that client ignore a bare
  # FORGEJO_TOKEN: with a flag base URL it reads only a host-scoped
  # FORGEJO_TOKEN_<HOST> or its own hosts.json. Measured against forgejo-axi
  # 1.3.0 by whether the request carried an Authorization header at all.
  #
  # This is a note and never a check. It says a credential that is set will not
  # be read; it says nothing about whether any credential would be accepted,
  # because only the forge can answer that and the read below is what asks it.
  # Names only are examined and no value is ever printed.
  if [ -n "${FORGEJO_TOKEN:-}" ] \
    && ! env | grep -q '^FORGEJO_TOKEN_[A-Za-z0-9_]*=' \
    && [ ! -f "${HOME:-}/.config/forgejo-axi/hosts.json" ]; then
    cat >&2 <<EOF
note: FORGEJO_TOKEN is set, and this merge names the instance as a flag, which
      is exactly the case where that client reads a token only from a
      host-scoped FORGEJO_TOKEN_<HOST> variable or from its own hosts.json. So
      this merge will reach $PR_HOST with no credential at all, and whatever the
      forge then says will be about permission rather than about the token being
      ignored. Nothing here judges whether a credential would be accepted.
EOF
  fi
fi

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

# The forge's client speaks a different flag language, so the caller's merge
# arguments are translated into it or refused, never handed over as they are.
FORGEJO_METHOD=merge
forgejo_plan_merge_args() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --merge)
        FORGEJO_METHOD=merge
        shift
        ;;
      --squash)
        FORGEJO_METHOD=squash
        shift
        ;;
      --rebase)
        FORGEJO_METHOD=rebase
        shift
        ;;
      --method)
        if [ "$#" -lt 2 ]; then
          echo "error: --method needs a merge method after it" >&2
          return 1
        fi
        FORGEJO_METHOD=$2
        shift 2
        ;;
      --method=*)
        FORGEJO_METHOD=${arg#--method=}
        shift
        ;;
      --delete-branch=false)
        # Already what this forge does, so the caller's choice is honoured by
        # doing nothing rather than by passing a flag the client does not have.
        shift
        ;;
      --delete-branch|--delete-branch=true)
        cat >&2 <<EOF
error: this path cannot delete the head branch on $PR_HOST. The forge client's
       pr merge has no branch deletion at all, and deleting it through a second
       call would be a separate action that can fail while the merge stands -
       reported as part of the merge, that reads as done when it is half done.
remedy: drop --delete-branch. The merge leaves the head branch in place; remove
       it separately if you want it gone. docs/merged-branch-cleanup.md owns
       merged-branch cleanup.
EOF
        return 1
        ;;
      *)
        cat >&2 <<EOF
error: "$arg" is not a merge argument this path can send to $PR_HOST. Extra
       arguments here are written for GitHub's client, and this forge's client
       accepts a different set; forwarding one produces a complaint about the
       flag rather than about the merge.
remedy: pass --merge, --squash, --rebase, --method <merge|squash|rebase>, or
       --delete-branch=false. Anything else has to be done against the forge
       directly, outside this merge.
EOF
        return 1
        ;;
    esac
  done
  case "$FORGEJO_METHOD" in
    merge|squash|rebase) ;;
    *)
      echo "error: merge method must be merge, squash, or rebase" >&2
      return 1
      ;;
  esac
}

if [ "$PROVIDER" = forgejo ]; then
  forgejo_plan_merge_args "$@" || exit 1
fi

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

# One read of the pull request answers both questions this path has to ask the
# forge before it merges: what the title says, and which commit is the head it
# will be gated on. Reading them together means they describe the same moment,
# and it gets the same bounded retry for the same reason. The client omits a
# field the host did not supply rather than emitting a null, so an absent field
# arrives as an absent field and each one is judged on its own below.
FORGEJO_VIEW_JSON=
read_forgejo_pull_view() {
  local attempt=1 out
  while :; do
    if out=$(forgejo-axi pr view "$PR_NUMBER" --repo "$PR_PATH" \
      --base-url "$FORGEJO_BASE_URL" --fields title,head_sha --json 2>/dev/null) \
      && [ -n "$out" ] \
      && printf '%s' "$out" | jq -e 'has("pull_request")' >/dev/null 2>&1; then
      FORGEJO_VIEW_JSON=$out
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
error: PR $PR_NUMBER in $PR_LOCATION is already recorded by task
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
FORGEJO_HEAD=
if [ "$PROVIDER" = forgejo ]; then
  if read_forgejo_pull_view; then
    PR_TITLE=$(printf '%s' "$FORGEJO_VIEW_JSON" | jq -r '.pull_request.title // ""')
    FORGEJO_HEAD=$(printf '%s' "$FORGEJO_VIEW_JSON" | jq -r '.pull_request.head_sha // ""')
    # An empty title is a title this path did not get, not a title that is
    # empty: the forge has no way to show one and the client renders an absent
    # one the same way. It is reported as unread rather than judged.
    [ -z "${PR_TITLE//[[:space:]]/}" ] || PR_TITLE_READ=1
  fi
elif PR_TITLE=$(read_pr_title); then
  PR_TITLE_READ=1
fi

if [ "$PR_TITLE_READ" -eq 0 ]; then
  if [ "$ALLOW_UNREADABLE_TITLE" -eq 0 ]; then
    cat >&2 <<EOF
error: could not read the title of PR $PR_NUMBER in $PR_LOCATION, after up
       to $TITLE_READ_ATTEMPTS attempts, so this merge does not know what the
       title says. That is all this reports: the title was not read, not judged.
remedy: the cause may be transient - a rate limit, a network failure, or a token
       momentarily without read scope on that repository - in which case re-running
       this merge is usually enough. It may also be that the forge client is not
       installed, or not authenticated for that repository; check with
         $PR_TITLE_READ_CMD
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
         $PR_RETITLE_CMD '<type(scope): what changed>'
       To land this title deliberately, re-run with --allow-placeholder-title
       before the task id.
EOF
  exit 1
fi

# The head this merge will be gated on, on a forge that gates merges on it. A
# head the forge did not supply has no override: the client refuses a merge
# without --expected-head, so proceeding would not be a looser merge, it would
# be no merge at all with a friendlier-looking message in front of it.
if [ "$PROVIDER" = forgejo ] && ! fm_pr_head_valid "$FORGEJO_HEAD"; then
  cat >&2 <<EOF
error: could not read the head commit of PR $PR_NUMBER in $PR_LOCATION, so this
       merge does not know which commit it would be merging. That forge merges
       only a named head, and naming one this path never read is how a merge
       lands a commit nobody checked.
remedy: the cause may be transient, or the address may name an issue rather than
       a pull request, which that forge serves from the same index. Check with
         $PR_TITLE_READ_CMD,head_sha
       then re-run this merge. There is no flag that skips this: the forge
       requires the head and this path has nothing to give it.
EOF
  exit 1
fi

if [ -n "$ID" ]; then
  if [ "$PROVIDER" = forgejo ]; then
    # --no-watch records pr= and pr_head= and arms nothing, because the monitor
    # cannot read this forge yet and a watch that watches nothing is worse than
    # an absent one. The head recorded is the head this merge is gated on, so
    # the record and the merge cannot describe different commits.
    "$SCRIPT_DIR/fm-pr-check.sh" --no-watch --pr-head "$FORGEJO_HEAD" "$ID" "$URL"
  else
    "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
else
  # Said out loud, and before the merge, so this outcome can never be mistaken
  # for the recorded one by whoever reads the run afterwards.
  cat <<EOF
note: PR $PR_NUMBER in $PR_LOCATION is being merged with no local task, so
      no pr= and no pr_head= were recorded and no merge watch was armed. Nothing
      here will need that record: it exists so a task's cleanup can verify its
      work landed, and this pull request has no task in this home to clean up. A
      merge naming a task still records both.
EOF
fi

if [ "$PROVIDER" = forgejo ]; then
  # Said before the merge rather than discovered after it. Both of these are
  # things the GitHub path does and this forge does not, and neither is
  # emulated here.
  cat <<EOF
note: this merge deletes no branch. On GitHub the forge deletes the merged head
      branch as part of the merge; this forge's client has no branch deletion,
      and this path will not delete one through a separate call and present it
      as part of the merge. The head branch stays.
      docs/merged-branch-cleanup.md owns merged-branch cleanup.
EOF

  set +e
  MERGE_OUT=$(forgejo-axi pr merge "$PR_NUMBER" --repo "$PR_PATH" \
    --base-url "$FORGEJO_BASE_URL" --expected-head "$FORGEJO_HEAD" \
    --method "$FORGEJO_METHOD" --json)
  MERGE_RC=$?
  set -e
  # The client answers on stdout in both directions, refusal included, and this
  # path captures stdout so it can check the proof. A refusal captured and then
  # dropped would leave a failing merge with nothing said about why, so it is
  # put back on stderr before this path gives up.
  if [ "$MERGE_RC" -ne 0 ]; then
    [ -z "$MERGE_OUT" ] || printf '%s\n' "$MERGE_OUT" >&2
    exit "$MERGE_RC"
  fi

  # The client returns the forge's own merged proof, and this path reads it
  # rather than reading the exit status. An exit status says the call finished;
  # the proof says the pull request is merged and says which head was merged. A
  # success reported without those two facts is exactly the shape this fleet
  # keeps finding, so it is refused here even though the call itself succeeded.
  MERGED=$(printf '%s' "$MERGE_OUT" | jq -r '.proof.merged // false' 2>/dev/null || printf 'false')
  PROOF_HEAD=$(printf '%s' "$MERGE_OUT" | jq -r '.proof.head_sha // ""' 2>/dev/null || printf '')
  if [ "$MERGED" != true ] || [ "$PROOF_HEAD" != "$FORGEJO_HEAD" ]; then
    printf '%s\n' "$MERGE_OUT" >&2
    cat >&2 <<EOF
error: the merge of PR $PR_NUMBER in $PR_LOCATION returned success, but its own
       merged proof above does not confirm it: the proof must say merged and
       must name $FORGEJO_HEAD as the head that was merged. This does not mean
       the merge did not happen - it means nothing here can say that it did.
remedy: read the pull request on the forge before acting on either answer:
         forgejo-axi pr merged --repo $PR_PATH $PR_NUMBER --base-url $FORGEJO_BASE_URL
EOF
    exit 1
  fi

  printf 'merged: PR %s in %s, method %s, head %s\n' \
    "$PR_NUMBER" "$PR_LOCATION" "$FORGEJO_METHOD" "$FORGEJO_HEAD"
  printf '%s\n' "$MERGE_OUT"
  exit 0
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
