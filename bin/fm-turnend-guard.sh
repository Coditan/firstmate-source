#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
DELIVERY="$SCRIPT_DIR/fm-delivery.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
# A queued durable wake is protected work in its own right: state/*.meta records
# can be cleaned up while terminal wakes still sit unread in state/.wake-queue.
if [ "$FM_SUP_IN_FLIGHT" -eq 0 ] && [ "$FM_SUP_QUEUE_PENDING" != true ]; then
  exit 0
fi
daemon_healthy=0
delivery_armed=0
afk=0
[ -e "$STATE/.afk" ] && afk=1
fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && daemon_healthy=1
if [ "$afk" -eq 1 ]; then
  # Away mode's own daemon consumes new durable queue records, and the external
  # listener deliberately stands down for it under the /afk contract.
  fm_pusher_healthy "$STATE" && delivery_armed=1
elif fm_delivery_healthy "$STATE" "$DELIVERY" "$GRACE" "$FM_HOME"; then
  # Delivery is an externally supervised listener, not an object this turn holds,
  # so ending a turn cannot end delivery. What this guard still has to catch is a
  # turn ending while that listener is down, because then nothing will wake the
  # next one.
  delivery_armed=1
fi
[ "$daemon_healthy" -eq 1 ] && [ "$delivery_armed" -eq 1 ] && exit 0
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
queue_pending=0
[ "$FM_SUP_QUEUE_PENDING" = true ] && queue_pending=1
# --- who is being told -------------------------------------------------------
# This guard ships in tracked hook files, so a crewmate or scout working on
# firstmate itself runs the very same hook from its task worktree while
# FM_ROOT_OVERRIDE still names the home that launched it. The diagnosis below is
# then correct and the block is still worth one forced continuation - the worker
# needs that turn to report it - but the repair is not the worker's to run:
# AGENTS.md reserves supervision repair to firstmate, and a worker can see
# neither the other homes on this account nor what else is in flight. So the
# repair commands are computed and printed only for the session that operates
# this checkout, measured against FM_ROOT. That decides the addressee from WHERE
# this hook was loaded and deliberately not from the home judged above;
# fm_session_operates_home in bin/fm-primary-scope-lib.sh owns that contract and
# records its limits.
# Nothing above this line changes: which home is evaluated and whether its
# supervision is unhealthy are decided identically for both addressees.
operator=0
fm_session_operates_home "$SCRIPT_DIR/.." "$FM_ROOT" && operator=1
DELIVERY_REASON=
DAEMON_REASON=
if [ "$operator" -eq 1 ]; then
  DELIVERY_REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" \
    --queue-pending "$queue_pending" --repair-line 2>/dev/null \
    || printf '%s\n' 're-arm wake delivery according to the session-start operating block before ending the turn')
  DAEMON_REASON=$("$SCRIPT_DIR/fm-watcher-service.sh" repair-command 2>/dev/null \
    || printf '%s\n' 'bin/fm-watcher-service.sh restart')
fi
if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
  protected_desc="$FM_SUP_IN_FLIGHT task(s) in flight"
else
  protected_desc='queued wake(s) pending in the durable queue'
fi
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS INCOMPLETE\n'
  if [ "$daemon_healthy" -eq 0 ]; then
    printf '●  Watcher daemon down: %s and no healthy daemon holds this home lock (last beat: %s).\n' "$protected_desc" "$FM_SUP_BEACON_DESC"
    if [ "$operator" -eq 1 ]; then
      printf '●  Daemon repair: %s; treat this as a supervision incident and verify the beacon+lock predicate.\n' "$DAEMON_REASON"
    fi
  fi
  if [ "$delivery_armed" -eq 0 ]; then
    if [ "$afk" -eq 1 ]; then
      printf '●  Away wake delivery missing: no live identity-matched pusher holds the supervise-daemon lock.\n'
    else
      printf '●  Wake delivery missing: no identity-matched delivery stub is armed for this session.\n'
    fi
    if [ "$operator" -eq 1 ]; then
      printf '●  Delivery repair: %s\n' "$DELIVERY_REASON"
    fi
  fi
  if [ "$operator" -eq 0 ]; then
    printf '●  This is the supervision of the home that launched this task, and repairing it belongs to firstmate, not to a task worker: report the stalled supervision in your task status line and carry on with your own task in this worktree.\n'
  elif [ "$afk" -eq 1 ]; then
    printf '●  This forced continuation is internal maintenance; after restoring away delivery, end silently unless a queued wake is captain-relevant under AGENTS.md section 9.\n'
  else
    printf '●  This forced continuation is internal maintenance; after draining and restoring delivery, end silently unless a queued wake is captain-relevant under AGENTS.md section 9.\n'
  fi
  printf '●%s\n' "$rule"
} >&2
exit 2
