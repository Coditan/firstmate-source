#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance. A pull request on
# this fleet's configured Forgejo instance parses into the same identity but
# cannot be watched yet, and is refused here rather than armed.
#
# --no-watch records the identity and arms nothing. It exists for one caller:
# bin/fm-pr-merge.sh merging a pull request on a forge the poll cannot read yet.
# That merge still has to record pr= so the same metadata exists as for any
# other forge, and the alternative - arming a watch that watches nothing - is
# the exact shape this file refuses above. So the recording is separated from
# the arming rather than the arming being faked.
#
# Three things keep --no-watch from becoming a quiet way to lose a watch:
#   - It says in its own output that no watch was armed, rather than printing
#     the "armed:" line the arming path prints.
#   - It refuses when any poll artifact already exists for the task, because
#     rewriting pr= underneath an armed poll invalidates that poll's own
#     identity checks and the poll would then go silent instead of failing.
#   - It never lifts a refusal the arming path makes for its own reasons; it
#     simply is not the arming path.
#
# --pr-head <sha> records a head commit the caller has already resolved from the
# forge, instead of this path reading one. The value is validated as a commit
# SHA like every other pr_head, and the caller that supplies it is the merge
# path, which has to resolve the head anyway to pass it to a forge that requires
# it. Nothing is inferred: an absent flag still means the ordinary lookup.
# --disarm retires a task's armed poll and takes no pull request URL. Arming had
# no inverse before it, and the only removal in the fleet was a side effect of a
# completed teardown - so a poll whose teardown was refused could be stopped only
# by hand-editing state, which AGENTS.md section 2 forbids. A seat facing that
# choice left a half-removed artifact set in place rather than break either rule,
# and a spent poll on another seat woke it every five minutes for hours. This
# verb is what makes that choice unnecessary.
#
# It removes the poll's whole artifact set - the runnable check, the sidecar, the
# registration, and any quarantine entry for the task - or refuses and removes
# none of it. It is idempotent, and it deliberately succeeds on a set that is
# already partly gone: finishing a hand-removal is one of the states it exists to
# resolve. It never touches the task metadata, so the recorded pr= survives and
# the poll can be armed again with a plain rearm.
#
# state/<id>.check.sh is a shared name: bin/fm-check-register.sh binds a
# hand-written custom watcher check to exactly that path. So before removing
# anything under that name, this verb PROVES the check is a merge poll rather
# than assuming it, with fm_pr_poll_artifacts_valid - the same identity proof the
# watcher itself makes, asked the right way round. The check must be byte-
# identical to bin/fm-pr-poll.sh, its sidecar must parse, its registration must
# bind both to the recorded pull request, and the task metadata must name that
# same pull request. When a check.sh exists and that proof does not hold, the
# verb refuses and removes nothing, WHATEVER the reason it failed.
#
# Asking it the other way round - proving the check is not something else - was
# tried and fails open on every case nobody anticipated. The one that found it: a
# registered custom check edited but not yet re-registered no longer matches its
# recorded hash, which is the ordinary mid-iteration state and exactly when the
# watcher is already refusing to run it. A negative test lets that through; a
# positive proof does not, and neither does it let through the next such state.
#
# The trust record is never removed here under any path. A merge poll has none -
# fm_pr_poll_prepare writes the check at mode 600 and writes no trust - and only
# bin/fm-check-register.sh writes that file, so it is by construction not a merge
# poll artifact. bin/fm-teardown.sh is deliberately different: it ends the whole
# task and takes the custom check and its trust with it. The safety validation is
# shared; only the reach differs.
#
# Usage: fm-pr-check.sh [--no-watch] [--pr-head <sha>] <task-id> <pr-url>
#        fm-pr-check.sh --disarm <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

# --disarm is handled before the arming path's own parsing and before the legacy
# migration runs. It takes no URL, so none of the identity resolution below
# applies, and it must not invoke a migration whose job is to REBUILD polls.
if [ "${1-}" = --disarm ]; then
  shift
  if [ "$#" -ne 1 ]; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  DISARM_ID=$1
  if ! fm_pr_task_id_valid "$DISARM_ID"; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  DISARM_CHECK="$STATE/$DISARM_ID.check.sh"
  if { [ -e "$DISARM_CHECK" ] || [ -L "$DISARM_CHECK" ]; } \
    && ! fm_pr_poll_artifacts_valid "$STATE" "$DISARM_ID" "$SCRIPT_DIR/fm-pr-poll.sh"; then
    if fm_custom_check_registered "$STATE" "$DISARM_ID"; then
      echo "REFUSED: state/$DISARM_ID.check.sh is a registered custom watcher check, not a merge poll; nothing was removed." >&2
    else
      echo "REFUSED: state/$DISARM_ID.check.sh does not prove to be this task's merge poll; nothing was removed." >&2
    fi
    echo "Retire it with the tool that owns it, or tear the task down; --disarm removes only a merge poll it can identify." >&2
    exit 1
  fi
  if ! fm_pr_poll_artifacts_present "$STATE" "$DISARM_ID"; then
    echo "not armed: $DISARM_ID has no merge poll artifacts; nothing to disarm."
    exit 0
  fi
  fm_pr_poll_disarm "$STATE" "$DISARM_ID" || exit 1
  echo "disarmed: $DISARM_ID's merge poll is retired; no watcher check remains for it."
  exit 0
fi

NO_WATCH=0
SUPPLIED_PR_HEAD=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-watch)
      NO_WATCH=1
      shift
      ;;
    --pr-head)
      [ "$#" -ge 2 ] || { echo "error: invalid PR check request" >&2; exit 2; }
      SUPPLIED_PR_HEAD=$2
      shift 2
      ;;
    --pr-head=*)
      SUPPLIED_PR_HEAD=${1#--pr-head=}
      shift
      ;;
    *) break ;;
  esac
done

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if [ -n "$SUPPLIED_PR_HEAD" ] && ! fm_pr_head_valid "$SUPPLIED_PR_HEAD"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$NO_WATCH" -eq 0 ] && [ "$PROVIDER" = gitlab ] \
  && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Refuse to arm a Forgejo watch for the same reason. bin/fm-pr-lib.sh resolves a
# Forgejo pull request into the provider-tagged identity, but bin/fm-pr-poll.sh
# reads GitHub and GitLab only and is silent on everything else, so arming one
# here would report success and then watch nothing until a human noticed. The
# refusal lifts when the poll learns to read this forge.
if [ "$NO_WATCH" -eq 0 ] && [ "$PROVIDER" = forgejo ]; then
  echo "error: watching a Forgejo pull request is not supported yet" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# Recording without arming must never silently break a watch that already
# exists. A published poll binds the task metadata's pull request identity, so
# rewriting pr= underneath one leaves artifacts whose own validation fails, and
# a poll that fails validation goes quiet rather than complaining. Refuse here,
# where it can still be said out loud.
if [ "$NO_WATCH" -eq 1 ]; then
  for artifact in "$STATE/$ID.check.sh" "$STATE/$ID.pr-poll" \
    "$STATE/$ID.pr-poll-registration"; do
    if [ -e "$artifact" ] || [ -L "$artifact" ]; then
      cat >&2 <<EOF
error: task $ID already has a merge watch armed, so recording without arming
       would leave that watch bound to a pull request this call is replacing.
       It would then stop reporting instead of failing, which is the outcome
       --no-watch exists to avoid rather than to cause.
remedy: arm the watch for this pull request instead, which records and rearms in
       one step:
         fm-pr-check.sh $ID $URL
EOF
      exit 1
    fi
  done
fi

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# A caller that already resolved the head from the forge supplies it directly,
# and this path records that value rather than reading a second one: two reads
# could disagree, and the one the caller is acting on is the one worth storing.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=$SUPPLIED_PR_HEAD
if [ -z "$PR_HEAD" ] && [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] \
  && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$NO_WATCH" -eq 0 ]; then
  fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
    || { echo "error: could not prepare PR poll" >&2; exit 1; }
fi

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

if [ "$NO_WATCH" -eq 1 ]; then
  # Said out loud, and in different words from the arming path, because the two
  # outcomes differ in exactly one way that matters later: one leaves something
  # that will report this pull request being merged, and this one does not.
  printf 'recorded: state/%s.meta\n' "$ID"
  cat <<EOF
note: no merge watch was armed, because --no-watch was requested. Nothing will
      report PR $NUMBER in $PROJECT_PATH on $HOST being merged; whoever asked
      for that owns the outcome.
EOF
  exit 0
fi

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
