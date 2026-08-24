#!/usr/bin/env bash
# Check whether the source this deployment updates from has instruction-surface
# updates that are not present in it.
#
# This is read-only with respect to the deployment checkout: comparison objects
# are fetched into a temporary repository, and the only persistent writes are
# local diagnostics under FM_HOME/state. It never updates firstmate and never
# contacts Bridge. A supervising firstmate relays FIRSTMATE_UPDATE_AVAILABLE
# through the normal crewmate-dispatch path.
#
# "Relevant" means a source-only commit changes AGENTS.md, roles/, bin/, or
# .agents/skills/. These are the running instruction surfaces named by
# AGENTS.md section 12; roles/ is included because a role overlay amends
# AGENTS.md for whichever home selects it. Public skills/ are installer-facing
# and do not trigger a fleet-wide running-vessel update by themselves.
#
# This script is invoked by bin/fm-currency-round.sh, which supplies the daily
# cadence through the existing watcher. It only reads and writes local state;
# docs/currency-round.md owns why this is not an external cron or systemd timer.
#
# The compared source comes from FM_FIRSTMATE_UPDATE_SOURCE_URL, then the local
# gitignored config/firstmate-update-base file, then the built-in default - see
# bin/fm-currency-base-lib.sh for the full precedence. A present but unusable
# config file records FIRSTMATE_UPDATE_STUCK rather than silently comparing
# against a source this deployment never updates from. FM_FIRSTMATE_UPSTREAM_URL
# remains a compatibility alias.
#
# EVERY FINDING NAMES THE SOURCE IT COMPARED and the hop that source came from,
# because a comparison that does not say what it compared cannot be caught
# reading the wrong thing, and a misconfigured base produces a finding
# indistinguishable from a correct one. The finding says "update source" rather
# than "upstream", because on a fleet-deployed seat the source this deployment
# updates from is the fleet repository.
#
# Usage: fm-firstmate-update-check.sh
# Environment:
#   FM_FIRSTMATE_UPDATE_SOURCE_URL overrides the configured comparison base.
#   FM_FIRSTMATE_UPSTREAM_URL is a compatibility alias for the same override.
#   FM_FIRSTMATE_UPDATE_SOURCE_HEAD skips network discovery and uses the named
#     commit already present in FM_FIRSTMATE_COMPARE_REPO (tests only).
#   FM_FIRSTMATE_UPSTREAM_HEAD is a compatibility alias for the same test head.
#   FM_FIRSTMATE_COMPARE_REPO overrides the comparison repository (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
AVAILABLE="$STATE/firstmate-update.available"
STUCK="$STATE/firstmate-update.stuck"

mkdir -p "$STATE" 2>/dev/null || {
  echo "FIRSTMATE_UPDATE_STUCK: cannot create state directory $STATE"
  exit 0
}

record_stuck() {
  printf 'FIRSTMATE_UPDATE_STUCK: %s\n' "$1" > "$STUCK"
  rm -f "$AVAILABLE"
  cat "$STUCK"
  exit 0
}

# shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-currency-base-lib.sh"
fm_currency_base_resolve "$CONFIG" "$FM_CURRENCY_BASE_UPDATE_ITEM" ||
  record_stuck "config/$FM_CURRENCY_BASE_UPDATE_ITEM is unusable - $FM_CURRENCY_BASE_REASON"
UPDATE_SOURCE_URL=$FM_CURRENCY_BASE_VALUE
UPDATE_SOURCE=$FM_CURRENCY_BASE_SOURCE

# Match fm-update.sh: compare from the deployment's local default-branch ref,
# not a possibly detached or feature-branch HEAD.
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
current=$(primary_head_commit "$FM_ROOT") || record_stuck "local default-branch commit cannot be resolved"

tmp=""
compare_repo=${FM_FIRSTMATE_COMPARE_REPO:-}
if [ -z "$compare_repo" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-firstmate-update.XXXXXX") || record_stuck "temporary comparison repository cannot be created"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init --bare -q || record_stuck "temporary comparison repository cannot be initialized"
  git -C "$tmp" fetch -q --no-tags "$FM_ROOT" "$current:refs/heads/local" || record_stuck "local default-branch commit cannot be copied for comparison"
  if ! git -C "$tmp" fetch -q --no-tags "$UPDATE_SOURCE_URL" HEAD:refs/heads/update-source; then
    record_stuck "update-source default-branch lookup failed ($UPDATE_SOURCE_URL, from $UPDATE_SOURCE)"
  fi
  compare_repo=$tmp
  update_source=$(git -C "$tmp" rev-parse --verify refs/heads/update-source)
else
  update_source=${FM_FIRSTMATE_UPDATE_SOURCE_HEAD:-${FM_FIRSTMATE_UPSTREAM_HEAD:-}}
  [ -n "$update_source" ] || record_stuck "test comparison repository requires FM_FIRSTMATE_UPDATE_SOURCE_HEAD"
fi

git -C "$compare_repo" cat-file -e "$current^{commit}" 2>/dev/null || record_stuck "local comparison commit is unavailable"
git -C "$compare_repo" cat-file -e "$update_source^{commit}" 2>/dev/null || record_stuck "update-source comparison commit is unavailable"

if git -C "$compare_repo" merge-base --is-ancestor "$update_source" "$current" 2>/dev/null; then
  rm -f "$AVAILABLE" "$STUCK"
  exit 0
fi

base=$(git -C "$compare_repo" merge-base "$current" "$update_source" 2>/dev/null) || record_stuck "local and update-source histories have no merge base"
if git -C "$compare_repo" diff --quiet "$base" "$update_source" -- AGENTS.md roles bin .agents/skills; then
  rm -f "$AVAILABLE" "$STUCK"
  exit 0
fi

{
  printf 'FIRSTMATE_UPDATE_AVAILABLE: instruction update %s -> %s on the source this deployment updates from; dispatch a crewmate to broadcast via Bridge All-Ships\n' \
    "$current" "$update_source"
  # Which repository produced that reading. Without this line a base pointing at
  # a repository this deployment never updates from reads exactly like a correct
  # one - the defect its sibling check was caught in on 2026-08-17.
  printf '  compared: this deployment against %s (from %s)\n' "$UPDATE_SOURCE_URL" "$UPDATE_SOURCE"
} > "$AVAILABLE"
rm -f "$STUCK"
cat "$AVAILABLE"
