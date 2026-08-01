#!/usr/bin/env bash
# Relay envelope-only Bridge traffic through one of the four publishing scripts
# already owned by the coditan-bridge checkout.
# Usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]
# The checkout is always $FM_HOME/projects/coditan-bridge, or
# $FM_PROJECTS_OVERRIDE/coditan-bridge when that override is set.
# Before dispatch, this guard requires a clean checkout on its default branch
# with an upstream; it performs only read-only Git inspection and never accepts
# an arbitrary command or performs a Git mutation itself.
# It then refreshes the checkout through bin/fm-fleet-sync.sh, the single
# sanctioned path that moves a project clone (fast-forward only, never forced,
# stashed, or reset); this relay opens no second refresh path of its own.
# Every Bridge script answers from the checkout's working tree, so a clone that
# is behind origin reports an empty mailbox for mail that exists. A read-shaped
# call therefore REFUSES loudly when the refresh did not prove the clone current,
# rather than returning a confident wrong answer; a write-shaped call warns on
# stderr and proceeds, because its own publish path already reconciles with
# origin. See classify_read_shaped for which call is which.
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

# classify_read_shaped: echo "yes" when this call only reads the checkout and so
# must never answer from a stale clone, "no" when it publishes something and
# owns its own reconciliation with origin. The forwarded arguments are inspected,
# never rewritten: `inbox` lists (and `--id` reads, which acks) unless `--gc` is
# asked for, and `status` reads only in its `--show` form.
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
        [ "$arg" = "--show" ] && { echo yes; return 0; }
      done
      echo no
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

# refresh_checkout: refresh this clone through fm-fleet-sync.sh, the single
# sanctioned path that moves a project clone, and record its outcome in
# REFRESH_VERDICT/REFRESH_DETAIL. Branch pruning is off because only the
# fast-forward is wanted here.
REFRESH_VERDICT=none
REFRESH_DETAIL=""
refresh_checkout() {
  local out line verdict
  out=$(FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" "$BRIDGE_ROOT" 2>/dev/null) || true
  while IFS= read -r line; do
    verdict=$(classify_refresh_line "$line") || continue
    REFRESH_VERDICT=$verdict
    REFRESH_DETAIL=$line
    [ "$verdict" != blocked ] || return 0
  done <<< "$out"
}

refresh_checkout
refresh_detail=$REFRESH_DETAIL
case "$REFRESH_VERDICT" in
  current) refreshed=yes ;;
  *) refreshed=no ;;
esac
behind=$(git -C "$BRIDGE_ROOT" rev-list --count "HEAD..@{upstream}" 2>/dev/null) || behind=
stale=no
if [ "$refreshed" != yes ]; then
  stale=yes
  stale_reason="the guarded refresh did not complete, so the clone's currency is unknown"
elif [ -z "$behind" ]; then
  stale=yes
  stale_reason="the clone's distance from $upstream could not be read"
elif [ "$behind" != 0 ]; then
  stale=yes
  stale_reason="local '$default' is still $behind commit(s) behind $upstream after the refresh"
fi

if [ "$stale" = yes ]; then
  if [ "$read_shaped" = yes ]; then
    {
      echo "fm-bridge-relay: STALE CHECKOUT - refusing to run '$subcommand' against $BRIDGE_ROOT"
      echo "fm-bridge-relay: NOTHING WAS READ. This is a check that did not complete, not an empty result:"
      echo "fm-bridge-relay: unread mail may be waiting at origin and would not have been listed."
      echo "fm-bridge-relay: reason: $stale_reason"
      echo "fm-bridge-relay: refresh: ${refresh_detail:-fm-fleet-sync.sh reported no outcome for $label}"
      echo "fm-bridge-relay: get the checkout current (bin/fm-fleet-sync.sh $label), then re-run this command"
    } >&2
    exit 1
  fi
  echo "fm-bridge-relay: warning: running '$subcommand' against a checkout that is not proven current ($stale_reason); its own publish path must reconcile with $upstream" >&2
fi

cd "$BRIDGE_ROOT"
exec "$target" "$@"
