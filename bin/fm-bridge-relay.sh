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
# Two relaxations exist, both narrow and neither silent. A refresh that merely
# lost a race for a git lock to a concurrent fleet sync while the clone is
# already level with its upstream proceeds, because nothing about its currency is
# actually unproven; see is_contended_refresh_failure. So does a refresh whose
# fetch provably reached origin and that was then blocked while leaving the clone
# level with what that fetch brought back, because being AHEAD of origin - the
# state between a Bridge publish's commit and its push, and the state a failed
# publish leaves behind - does not make a clone stale for reading: its working
# tree holds everything origin holds. See refresh_fetch_proven. Both note the
# blocked outcome on stderr. Every other blocked, absent, or unreadable proof
# still refuses, and a refusal names which of behind, unknown, or unproven-fetch
# it actually is rather than asserting staleness a count contradicts.
# fm-fleet-sync.sh runs bin/fm-guard.sh, whose supervision alarms go to stderr
# and whose full banner is emitted only once per stale episode, so this relay
# captures that stderr but passes every guard line straight back out on its own
# stderr, on the success path too; only the remaining lines are treated as
# fleet-sync's own diagnosis, and that diagnosis is printed with the write-shaped
# warning as well as with the refusal. fleet-sync's own "recovered: ..." notices
# are re-emitted on stderr on every path including success, because they report a
# mutation inside the Bridge clone's .git - a stale lock file removed - that must
# never be invisible. Stdout stays untouched for the Bridge script.
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
# The `--push` spelling was verified by reading bridge-status.sh in the
# coditan-bridge checkout, which is out of scope for this change and so was read,
# not changed: its parser accepts exactly `--push` (write) and `--show <vessel>`
# (read) and rejects every other option with "unknown option" and exit 2, so an
# unrecognised status form can never be a publish this refusal would strand.
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

# strip_project_label: echo one fleet-sync line with this clone's label removed,
# or fail for a line about anything else. fleet-sync labels a project by basename
# or by full path depending on how the path was spelled, and it also prints
# unrelated guard banners on stdout, so every accepted label form is recognised
# here and nothing else is ever read as an outcome for this clone.
strip_project_label() {
  local line=$1
  case "$line" in
    "$label: "*) printf '%s\n' "${line#"$label: "}" ;;
    "$BRIDGE_ROOT: "*) printf '%s\n' "${line#"$BRIDGE_ROOT: "}" ;;
    "$bridge_root: "*) printf '%s\n' "${line#"$bridge_root: "}" ;;
    *) return 1 ;;
  esac
}

# classify_refresh_line: echo "current" or "blocked" for one fleet-sync outcome
# line about this clone, or fail for any other line. Only fleet-sync's documented
# per-project outcome vocabulary ("already current", "synced ...",
# "recovered: ...", "skipped: ...", "STUCK: ...") is classified.
classify_refresh_line() {
  local rest
  rest=$(strip_project_label "$1") || return 1
  case "$rest" in
    "skipped: "*|"STUCK: "*) echo blocked ;;
    "already current"|"synced "*|"recovered: "*) echo current ;;
    *) return 1 ;;
  esac
}

# refresh_fetch_proven: true when this blocked fleet-sync outcome can only have
# been printed after its fetch of origin succeeded, so the clone's
# remote-tracking ref is fresh and HEAD..@{upstream} is worth trusting. Every
# outcome fleet-sync reaches before or at its fetch step ("not a directory",
# "not a git repo", "local-only project", "no origin remote", and every
# "fetch failed" form) leaves that ref possibly stale and is not proof; git's own
# fetch failures are relayed verbatim into that last form and can end in wording
# a later pattern here would otherwise match, so it is rejected first. The list
# is a whitelist: an outcome this relay does not know is never taken as proof.
# Each accepted form is anchored to the spelling fleet-sync uses for it, naming
# the branch side ("local <branch>", "origin/<branch>") or the step
# ("fast-forward") that only exists past the fetch, because an open "skipped:
# ... does not exist" or "skipped: cannot read ..." would also admit a
# pre-fetch skip added to fleet-sync later - and widening in that direction is
# exactly the stale-clone read this guard exists to refuse.
refresh_fetch_proven() {
  local rest
  rest=$(strip_project_label "$1") || return 1
  case "$rest" in
    "skipped: fetch failed"*) return 1 ;;
    "STUCK: "*) return 0 ;;
    "skipped: cannot determine default branch") return 0 ;;
    "skipped: local "*" does not exist"|"skipped: origin/"*" does not exist") return 0 ;;
    "skipped: cannot read local "*|"skipped: cannot read origin/"*) return 0 ;;
    "skipped: fast-forward "*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_contended_refresh_failure: true when this fleet-sync outcome line reports a
# refresh step that lost a race for a git lock to a concurrent fleet sync
# (bin/fm-bootstrap.sh runs one over the whole fleet at session start), rather
# than a refresh that could not reach or reconcile with origin. Both losing steps
# count, because they take different locks: the fetch loses .git/packed-refs.lock
# and is reported as "skipped: fetch failed: ...", while the fast-forward merge
# loses .git/index.lock and is reported as "skipped: fast-forward failed: ...".
# fleet-sync relays git's message through its own first_line, which keeps only
# git's FIRST output line with whitespace runs squeezed, so this matches that one
# line and not git's full output the way is_packed_refs_lock_error does: a lock
# error git does not put on its first output line still refuses. An unreachable
# origin, an authentication failure, and every other fetch or fast-forward
# failure are NOT contention.
is_contended_refresh_failure() {
  case "$1" in
    *": skipped: fetch failed: "*|*": skipped: fast-forward failed: "*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"][^'\"]*(packed-refs|index)\.lock['\"]: File exists"
}

# is_guard_banner_line: true for a line bin/fm-guard.sh writes to stderr as one
# of its supervision alarms - the '●'-prefixed banner lines, the one-line
# reminder it prints for the rest of a stale episode, and its two independent
# warnings about a missing wake-delivery stub and pending queued wakes, which the
# banner dedup never suppresses. All of them belong to the caller, never to
# fleet-sync's diagnosis.
is_guard_banner_line() {
  case "$1" in
    "●"*) return 0 ;;
    "WARNING: watcher still down"*) return 0 ;;
    "WARNING: wake delivery stub missing"*) return 0 ;;
    "WARNING: queued wakes pending"*) return 0 ;;
    *) return 1 ;;
  esac
}

# refresh_checkout: refresh this clone through fm-fleet-sync.sh, the single
# sanctioned path that moves a project clone, and record its outcome in
# REFRESH_VERDICT/REFRESH_DETAIL. Its exit status is kept in REFRESH_STATUS, and
# the stderr it produces is split rather than discarded: fm-guard.sh's alarm
# lines are relayed to this script's stderr unchanged, and the last
# REFRESH_ERROR_TAIL_LINES of what remains are kept in REFRESH_ERROR and printed
# with every refusal and every warning, because they carry the lock-retry and
# lock-removal context the one-line outcome omits, and a run that dies before
# printing any outcome at all leaves them as the only diagnosis there is. Every
# "recovered: ..." line fleet-sync writes to stdout is echoed to this script's
# stderr as it is read, including on the path that goes on to dispatch: those
# lines report that the refresh re-attached the clone's default branch or deleted
# a lock file inside its .git, and a relay call must never mutate another
# checkout silently. Branch pruning is off because only the fast-forward is
# wanted here.
REFRESH_VERDICT=none
REFRESH_DETAIL=""
REFRESH_ERROR=""
REFRESH_STATUS=0
REFRESH_ERROR_TAIL_LINES=5
refresh_checkout() {
  local out line rest verdict errfile rc=0
  local -a diagnosis=()
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-relay-refresh.XXXXXX") || errfile=""
  if [ -n "$errfile" ]; then
    out=$(FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" "$BRIDGE_ROOT" 2>"$errfile") || rc=$?
    while IFS= read -r line; do
      if is_guard_banner_line "$line"; then
        printf '%s\n' "$line" >&2
        continue
      fi
      [ -n "$line" ] || continue
      diagnosis+=("$line")
      if [ "${#diagnosis[@]}" -gt "$REFRESH_ERROR_TAIL_LINES" ]; then
        diagnosis=("${diagnosis[@]: -$REFRESH_ERROR_TAIL_LINES}")
      fi
    done < "$errfile"
    rm -f "$errfile"
    [ "${#diagnosis[@]}" -eq 0 ] || REFRESH_ERROR=$(printf '%s\n' "${diagnosis[@]}")
  else
    out=$(FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" "$BRIDGE_ROOT") || rc=$?
  fi
  REFRESH_STATUS=$rc
  while IFS= read -r line; do
    verdict=$(classify_refresh_line "$line") || continue
    rest=$(strip_project_label "$line") || rest=""
    case "$rest" in
      "recovered: "*)
        echo "fm-bridge-relay: the refresh repaired the Bridge checkout: ${rest#recovered: }" >&2
        ;;
    esac
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
distance=""
if [ "$REFRESH_VERDICT" = current ]; then
  :
elif [ "$REFRESH_VERDICT" = blocked ] \
    && is_contended_refresh_failure "$REFRESH_DETAIL" && [ "$behind" = 0 ]; then
  echo "fm-bridge-relay: the refresh lost a race for a git lock, but local '$default' is level with $upstream, so '$subcommand' proceeds ($REFRESH_DETAIL)" >&2
elif [ "$REFRESH_VERDICT" = blocked ] \
    && refresh_fetch_proven "$REFRESH_DETAIL" && [ "$behind" = 0 ]; then
  echo "fm-bridge-relay: the refresh fetched $upstream and was then blocked, but local '$default' holds everything that fetch brought back, so '$subcommand' proceeds ($REFRESH_DETAIL)" >&2
elif [ "$REFRESH_VERDICT" = blocked ]; then
  stale=yes
  if [ -z "$behind" ]; then
    distance="and the clone's distance from $upstream could not be read afterwards, so whether it is current is unknown"
  elif [ "$behind" != 0 ]; then
    distance="and local '$default' is $behind commit(s) behind $upstream"
  else
    distance="and although local '$default' counts 0 commits behind $upstream, that count is against a remote-tracking ref the refresh never proved it updated, so currency stays unproven"
  fi
  case "$REFRESH_DETAIL" in
    *": STUCK: "*)
      stale_reason="the refresh ran and reported the clone stuck, $distance"
      stale_remedy="reconcile $BRIDGE_ROOT with $upstream by hand, landing or dropping whatever the clone holds; the fleet sync never forces, resets, or pushes, so running it again only reports the same state"
      ;;
    *)
      stale_reason="the refresh ran and was blocked by the outcome it reports below, $distance"
      stale_remedy="clear the condition that outcome names, then re-run this command"
      ;;
  esac
elif [ "$REFRESH_STATUS" -eq 0 ]; then
  stale=yes
  stale_reason="fm-fleet-sync.sh exited 0 but printed no outcome for $label that this relay recognises, so the refresh most likely SUCCEEDED while its outcome vocabulary and classify_refresh_line here have drifted apart"
  stale_remedy="reconcile classify_refresh_line in bin/fm-bridge-relay.sh with the per-project outcome vocabulary bin/fm-fleet-sync.sh actually prints; re-running the fleet sync cannot clear this, because it already succeeded"
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

# emit_refresh_diagnosis: print the kept tail of fleet-sync's own stderr, one
# attributed line at a time. Both unproven paths call it: the refusal and the
# write-shaped warning describe the same unproven clone, so the context that
# explains the verdict belongs to both.
emit_refresh_diagnosis() {
  local diagnosis_line
  [ -n "$REFRESH_ERROR" ] || return 0
  while IFS= read -r diagnosis_line; do
    echo "fm-bridge-relay: fm-fleet-sync.sh stderr: $diagnosis_line"
  done <<< "$REFRESH_ERROR"
}

if [ "$stale" = yes ]; then
  refresh_line=${REFRESH_DETAIL:-fm-fleet-sync.sh reported no outcome for $label}
  if [ "$read_shaped" = yes ]; then
    {
      echo "fm-bridge-relay: STALE CHECKOUT - refusing to run '$subcommand' against $BRIDGE_ROOT"
      echo "fm-bridge-relay: NOTHING WAS READ. This is a check that did not complete, not an empty result:"
      echo "fm-bridge-relay: unread mail may be waiting at origin and would not have been listed."
      echo "fm-bridge-relay: reason: $stale_reason"
      echo "fm-bridge-relay: refresh: $refresh_line"
      emit_refresh_diagnosis
      echo "fm-bridge-relay: remedy: $stale_remedy"
    } >&2
    exit 1
  fi
  {
    echo "fm-bridge-relay: warning: running '$subcommand' against a checkout that is not proven current ($stale_reason); its own publish path must reconcile with $upstream"
    echo "fm-bridge-relay: refresh: $refresh_line"
    emit_refresh_diagnosis
  } >&2
fi

cd "$BRIDGE_ROOT"
exec "$target" "$@"
