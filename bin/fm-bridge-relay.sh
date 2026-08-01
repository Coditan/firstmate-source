#!/usr/bin/env bash
# Relay envelope-only Bridge traffic through one of the four publishing scripts
# already owned by the coditan-bridge checkout.
# Usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]
# The checkout is always $FM_HOME/projects/coditan-bridge, or
# $FM_PROJECTS_OVERRIDE/coditan-bridge when that override is set.
# Before dispatch, this guard requires a clean checkout on its default branch
# with an upstream; its own Git inspection is strictly read-only and it never
# accepts an arbitrary command. Moving the checkout is delegated entirely to
# bin/fm-fleet-sync.sh, the single sanctioned path that moves a project clone
# (fast-forward only, never forced, stashed, or reset); this relay opens no
# second refresh path of its own and performs no Git mutation itself.
# Every Bridge script answers from the checkout's working tree, so a clone that
# is behind origin reports an empty mailbox for mail that exists. A read-shaped
# call therefore REFUSES loudly when the refresh did not prove the clone current,
# rather than returning a confident wrong answer; a write-shaped call warns on
# stderr and proceeds, because its own publish path already reconciles with
# origin. See classify_read_shaped for which call is which: read-shaped is the
# default, so only a positively recognised write escapes that refusal.
# The single relaxation is a refresh that merely lost a race for a git lock to a
# concurrent fleet sync while the clone is already level with its upstream: that
# call proceeds, with a one-line note on stderr so the relaxation is never
# silent, because nothing about its currency is actually unproven. Every other
# blocked, absent, or unreadable proof still refuses. See
# is_contended_fetch_failure.
# Only the selected whitelisted Bridge script receives the remaining arguments,
# unchanged and from inside the Bridge checkout, and owns any resulting publish.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BRIDGE_ROOT="$PROJECTS/coditan-bridge"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

usage() {
  echo "usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]" >&2
}

[ "$#" -ge 1 ] || { usage; exit 1; }
subcommand=$1
shift

case "$subcommand" in
  send) bridge_script=bridge-send.sh ;;
  inbox) bridge_script=bridge-inbox.sh ;;
  status) bridge_script=bridge-status.sh ;;
  broadcast) bridge_script=bridge-broadcast.sh ;;
  *)
    echo "fm-bridge-relay: unknown subcommand '$subcommand'" >&2
    usage
    exit 1
    ;;
esac

# classify_read_shaped: echo "yes" when this call must never answer from a stale
# clone, "no" only when it is positively recognised as a write that owns its own
# reconciliation with origin. The rule is read-shaped unless positively
# recognised as a write, so any form this script cannot recognise - a bare verb,
# an unknown flag, a future alias, an equals-form spelling - refuses rather than
# answering from a clone it could not prove current. The forwarded arguments are
# inspected, never rewritten: `inbox` writes only in its `--gc` form, `status`
# only in its `--push` form, and `send`/`broadcast` are writes whole.
classify_read_shaped() {
  local arg
  case "$subcommand" in
    inbox)
      for arg in "$@"; do
        [ "$arg" = "--gc" ] && { echo no; return 0; }
      done
      echo yes
      ;;
    status)
      for arg in "$@"; do
        [ "$arg" = "--push" ] && { echo no; return 0; }
      done
      echo yes
      ;;
    *) echo no ;;
  esac
}
read_shaped=$(classify_read_shaped "$@")

[ -d "$BRIDGE_ROOT" ] || {
  echo "fm-bridge-relay: Bridge checkout not found: $BRIDGE_ROOT" >&2
  exit 1
}

git_root=$(git -C "$BRIDGE_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
  echo "fm-bridge-relay: target is not a Git checkout: $BRIDGE_ROOT" >&2
  exit 1
}
bridge_root=$(cd "$BRIDGE_ROOT" && pwd -P)
git_root=$(cd "$git_root" && pwd -P)
[ "$git_root" = "$bridge_root" ] || {
  echo "fm-bridge-relay: target is not the root of its Git checkout: $BRIDGE_ROOT" >&2
  exit 1
}

default=$(fm_default_branch "$BRIDGE_ROOT") || {
  echo "fm-bridge-relay: cannot determine the default branch for $BRIDGE_ROOT" >&2
  exit 1
}
current=$(git -C "$BRIDGE_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$current" = "$default" ] || {
  current=${current:-detached HEAD}
  echo "fm-bridge-relay: Bridge checkout must be on default branch '$default' (found '$current')" >&2
  exit 1
}

upstream=$(git -C "$BRIDGE_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
[ -n "$upstream" ] || {
  echo "fm-bridge-relay: default branch '$default' is not tracking an upstream" >&2
  exit 1
}

if ! dirty=$(git -C "$BRIDGE_ROOT" status --porcelain 2>/dev/null); then
  echo "fm-bridge-relay: cannot inspect Bridge checkout cleanliness: $BRIDGE_ROOT" >&2
  exit 1
fi
[ -z "$dirty" ] || {
  echo "fm-bridge-relay: Bridge checkout has uncommitted changes: $BRIDGE_ROOT" >&2
  exit 1
}

target="$BRIDGE_ROOT/bin/$bridge_script"
[ -x "$target" ] || {
  echo "fm-bridge-relay: Bridge script is missing or not executable: $target" >&2
  exit 1
}

label=$(basename "$BRIDGE_ROOT")

# classify_refresh_line: echo "current" or "blocked" for one fleet-sync outcome
# line about this clone, or fail for any other line. fleet-sync labels a project
# by basename or by full path depending on how the path was spelled, and it also
# prints unrelated guard banners on stdout, so every accepted label form is
# stripped first and only its documented per-project outcome vocabulary
# ("already current", "synced ...", "recovered: ...", "skipped: ...", "STUCK: ...")
# is classified.
classify_refresh_line() {
  local line=$1 rest
  case "$line" in
    "$label: "*) rest=${line#"$label: "} ;;
    "$BRIDGE_ROOT: "*) rest=${line#"$BRIDGE_ROOT: "} ;;
    "$bridge_root: "*) rest=${line#"$bridge_root: "} ;;
    *) return 1 ;;
  esac
  case "$rest" in
    "skipped: "*|"STUCK: "*) echo blocked ;;
    "already current"|"synced "*|"recovered: "*) echo current ;;
    *) return 1 ;;
  esac
}

# is_contended_fetch_failure: true when this fleet-sync outcome line reports a
# fetch that lost a race for a git lock (.git/packed-refs.lock or .git/index.lock
# held by a concurrent fleet sync - bin/fm-bootstrap.sh runs one over the whole
# fleet at session start), rather than a refresh that could not reach or reconcile
# with origin. The signature mirrors is_packed_refs_lock_error in
# bin/fm-fleet-sync.sh, widened to index.lock; an unreachable origin, an
# authentication failure, and every other fetch failure are NOT contention.
is_contended_fetch_failure() {
  case "$1" in
    *": skipped: fetch failed: "*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"][^'\"]*(packed-refs|index)\.lock['\"]: File exists"
}

# refresh_checkout: refresh this clone through fm-fleet-sync.sh, the single
# sanctioned path that moves a project clone, and record its outcome in
# REFRESH_VERDICT/REFRESH_DETAIL. Its stderr and exit status are kept in
# REFRESH_ERROR/REFRESH_STATUS rather than discarded, because a run that dies
# before printing any per-project outcome leaves them as the only diagnosis.
# Branch pruning is off because only the fast-forward is wanted here.
REFRESH_VERDICT=none
REFRESH_DETAIL=""
REFRESH_ERROR=""
REFRESH_STATUS=0
refresh_checkout() {
  local out line verdict errfile rc=0
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-relay-refresh.XXXXXX") || errfile=""
  if [ -n "$errfile" ]; then
    out=$(FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" "$BRIDGE_ROOT" 2>"$errfile") || rc=$?
    REFRESH_ERROR=$(head -n 1 "$errfile" 2>/dev/null) || REFRESH_ERROR=""
    rm -f "$errfile"
  else
    out=$(FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" "$BRIDGE_ROOT" 2>/dev/null) || rc=$?
  fi
  REFRESH_STATUS=$rc
  while IFS= read -r line; do
    verdict=$(classify_refresh_line "$line") || continue
    REFRESH_VERDICT=$verdict
    REFRESH_DETAIL=$line
    [ "$verdict" != blocked ] || return 0
  done <<< "$out"
}

refresh_checkout
behind=$(git -C "$BRIDGE_ROOT" rev-list --count "HEAD..@{upstream}" 2>/dev/null) || behind=
stale=no
stale_reason=""
stale_remedy=""
if [ "$REFRESH_VERDICT" = current ]; then
  :
elif [ "$REFRESH_VERDICT" = blocked ] \
    && is_contended_fetch_failure "$REFRESH_DETAIL" && [ "$behind" = 0 ]; then
  echo "fm-bridge-relay: the refresh lost a race for a git lock, but local '$default' is level with $upstream, so '$subcommand' proceeds ($REFRESH_DETAIL)" >&2
elif [ "$REFRESH_VERDICT" = blocked ]; then
  stale=yes
  case "$REFRESH_DETAIL" in
    *": STUCK: "*)
      stale_reason="the refresh ran and reported the clone stuck, which proves it is NOT current and cannot be fast-forwarded to $upstream"
      stale_remedy="reconcile $BRIDGE_ROOT with $upstream by hand, landing or dropping whatever the clone holds - a Bridge publish that failed after committing leaves the clone ahead of origin, which is reported as diverged too; the fleet sync never forces, resets, or pushes, so running it again only reports the same state"
      ;;
    *)
      stale_reason="the refresh ran and was blocked by the outcome it reports below, before it could bring the clone current"
      stale_remedy="clear the condition that outcome names, then re-run this command"
      ;;
  esac
else
  stale=yes
  stale_reason="the guarded refresh did not complete (fm-fleet-sync.sh exited $REFRESH_STATUS reporting no outcome for $label), so the clone's currency is unknown"
  stale_remedy="get the checkout current (bin/fm-fleet-sync.sh $label), then re-run this command"
fi
if [ "$stale" = no ]; then
  if [ -z "$behind" ]; then
    stale=yes
    stale_reason="the clone's distance from $upstream could not be read"
    stale_remedy="restore $BRIDGE_ROOT's tracking of $upstream, then re-run this command"
  elif [ "$behind" != 0 ]; then
    stale=yes
    stale_reason="local '$default' is still $behind commit(s) behind $upstream after the refresh"
    stale_remedy="reconcile $BRIDGE_ROOT with $upstream, then re-run this command"
  fi
fi

if [ "$stale" = yes ]; then
  refresh_line=$REFRESH_DETAIL
  if [ -z "$refresh_line" ]; then
    refresh_line="fm-fleet-sync.sh reported no outcome for $label"
    [ -z "$REFRESH_ERROR" ] || refresh_line="$refresh_line; its first stderr line was: $REFRESH_ERROR"
  fi
  if [ "$read_shaped" = yes ]; then
    {
      echo "fm-bridge-relay: STALE CHECKOUT - refusing to run '$subcommand' against $BRIDGE_ROOT"
      echo "fm-bridge-relay: NOTHING WAS READ. This is a check that did not complete, not an empty result:"
      echo "fm-bridge-relay: unread mail may be waiting at origin and would not have been listed."
      echo "fm-bridge-relay: reason: $stale_reason"
      echo "fm-bridge-relay: refresh: $refresh_line"
      echo "fm-bridge-relay: remedy: $stale_remedy"
    } >&2
    exit 1
  fi
  echo "fm-bridge-relay: warning: running '$subcommand' against a checkout that is not proven current ($stale_reason); its own publish path must reconcile with $upstream" >&2
fi

cd "$BRIDGE_ROOT"
exec "$target" "$@"
