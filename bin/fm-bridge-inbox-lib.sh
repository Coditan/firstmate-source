#!/usr/bin/env bash
# Shared read-only Bridge inbox detection and durable wake publication.
#
# Source after bin/fm-wake-lib.sh, which owns fm_wake_append, and from a caller
# that owns run_bounded_process (bin/fm-watch.sh) - every Bridge read goes
# through that one bounded-process helper rather than a private copy, so the
# child's process group is torn down with the watcher on HUP/INT/TERM too.
#
# bridge_inbox_surface
#   Compares every watched vessel's fetched inbox tree against its own surfaced
#   marker and, for each vessel whose pending mail is new, appends a durable
#   check wake keyed on that vessel alone, publishing that vessel's marker only
#   after its own append succeeded. The queue keeps the last record per kind and
#   key, so a shared key would let a vessel enqueued later collapse an earlier
#   vessel's still-undrained record while that vessel's marker already claims it
#   was surfaced; per-vessel keys are what make each vessel independent in the
#   drained output too. Prints one actionable reason naming every vessel
#   surfaced this cycle, and only for vessels whose append succeeded, so a crash
#   between detection and enqueue re-detects instead of losing the mail.
#
# bridge_inbox_fetch
#   Refreshes the shared clone's origin/main ref. Every read below resolves
#   against that fetched ref rather than the working tree, so a stale or dirty
#   local checkout can neither invent nor mask pending mail, and the checkout is
#   never mutated.
#
# All Bridge reads are bounded by FM_CHECK_TIMEOUT and never acknowledge, move,
# or otherwise write an envelope: acknowledgement stays with the Bridge tooling.

FM_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BRIDGE_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_BRIDGE_LIB_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_BRIDGE_LIB_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
BRIDGE_CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}
BRIDGE_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BRIDGE_ROOT=${FM_BRIDGE_ROOT:-${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/coditan-bridge}
BRIDGE_URGENT_CHECK_INTERVAL=${FM_BRIDGE_URGENT_CHECK_INTERVAL:-30}

# read reports failure at EOF on a final line with no newline, having already
# assigned it, so the vessel is taken from the variable rather than the status.
BRIDGE_VESSEL_RAW=
if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
  BRIDGE_VESSEL_RAW=$FM_BRIDGE_VESSEL
elif [ -f "$BRIDGE_CONFIG/bridge-vessel" ]; then
  IFS= read -r BRIDGE_VESSEL_RAW < "$BRIDGE_CONFIG/bridge-vessel" || true
fi

# BRIDGE_VESSEL keeps the first/primary value so a pre-existing single-vessel
# configuration reads exactly as before, while the ordered array carries the
# optional space-separated multi-vessel list.
BRIDGE_VESSELS=()
read -r -a BRIDGE_VESSELS <<< "$BRIDGE_VESSEL_RAW"
BRIDGE_VESSEL=${BRIDGE_VESSELS[0]:-}

bridge_run_bounded() {
  ( run_bounded_process "$BRIDGE_CHECK_TIMEOUT" "$@" ) 2>/dev/null || true
}

# A whole scan, not a single git call, is what has to stay inside one bounded
# read, so each scan runs as a child shell. Their programs are passed inline
# with the clone and vessel as positional arguments, so nothing about this
# default-off feature is exported into the environment of every other process
# the watcher spawns.
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands these.
BRIDGE_SIGNATURE_SCAN='sig=$(git -C "$1" rev-parse "origin/main:inbox/$2/new" 2>/dev/null || true); printf "%s" "${sig:-empty}"'

# shellcheck disable=SC2016
BRIDGE_PRIORITY_SCAN='
root=$1; inbox="inbox/$2/new"; rank=-1
while IFS= read -r -d "" f; do
  case "$f" in *.json) ;; *) continue ;; esac
  priority=$(git -C "$root" show "origin/main:$inbox/$f" 2>/dev/null | jq -r ".priority // \"normal\"" 2>/dev/null || echo normal)
  case "$priority" in
    immediate) rank=3 ;;
    high) [ "$rank" -lt 2 ] && rank=2 ;;
    normal) [ "$rank" -lt 1 ] && rank=1 ;;
    low) [ "$rank" -lt 0 ] && rank=0 ;;
    *) [ "$rank" -lt 1 ] && rank=1 ;;
  esac
done < <(git -C "$root" ls-tree -z --name-only "origin/main:$inbox" 2>/dev/null)
case "$rank" in 3) echo immediate ;; 2) echo high ;; 1) echo normal ;; 0) echo low ;; *) echo none ;; esac
'

# The fetched inbox tree object id is the whole change signal: it advances on a
# new, edited, or acknowledged envelope and on nothing else. "timeout" is a
# distinct third value so a bounded read that never completed is never mistaken
# for an empty inbox.
bridge_inbox_signature() {
  local vessel=${1:-$BRIDGE_VESSEL} out
  out=$(bridge_run_bounded bash -c "$BRIDGE_SIGNATURE_SCAN" _ "$BRIDGE_ROOT" "$vessel")
  printf '%s' "${out:-timeout}"
}

# The primary vessel keeps the historical unsuffixed state filenames.
bridge_state_suffix() {
  local vessel=$1
  [ "$vessel" = "$BRIDGE_VESSEL" ] && return 0
  printf -- '-%s' "$(printf '%s' "$vessel" | tr -c 'A-Za-z0-9_.-' '_')"
}

# Reading every envelope costs one git show plus one jq per file, so the derived
# priority is cached against the tree signature that produced it and re-read only
# when that signature moves.
bridge_pending_priority() {
  local sig=${1:-} vessel=${2:-$BRIDGE_VESSEL} cache cached_sig="" cached_priority="" out
  [ -n "$vessel" ] || { printf '%s' none; return; }
  [ -d "$BRIDGE_ROOT/.git" ] || { printf '%s' none; return; }
  cache="$STATE/.bridge-priority-cache$(bridge_state_suffix "$vessel")"
  [ -n "$sig" ] || sig=$(bridge_inbox_signature "$vessel")
  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_sig cached_priority < "$cache" 2>/dev/null || true
  fi
  if [ "$sig" = timeout ]; then printf '%s' "${cached_priority:-none}"; return; fi
  if [ -n "$cached_sig" ] && [ "$sig" = "$cached_sig" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  out=$(bridge_run_bounded bash -c "$BRIDGE_PRIORITY_SCAN" _ "$BRIDGE_ROOT" "$vessel")
  if [ -z "$out" ]; then printf '%s' "${cached_priority:-none}"; return; fi
  printf '%s\t%s\n' "$sig" "$out" > "$cache" 2>/dev/null || true
  printf '%s' "$out"
}

# Urgent mail in ANY watched vessel tightens the one shared fetch-and-check
# cadence; it never changes the watcher's own CHECK_INTERVAL for other polls.
bridge_check_interval() {
  local vessel
  for vessel in "${BRIDGE_VESSELS[@]}"; do
    case "$(bridge_pending_priority "" "$vessel")" in
      high|immediate) echo "$BRIDGE_URGENT_CHECK_INTERVAL"; return ;;
    esac
  done
  echo "${CHECK_INTERVAL:-300}"
}

bridge_inbox_check() {
  local vessel=$1 sig=${2:-}
  local inbox="inbox/$vessel/new" highest count
  highest=$(bridge_pending_priority "$sig" "$vessel")
  [ "$highest" != none ] || return 0
  count=$(bridge_run_bounded git -C "$BRIDGE_ROOT" ls-tree --name-only "origin/main:$inbox" | awk '/[.]json$/' | wc -l | tr -d '[:space:]')
  printf 'bridge-inbox %s pending=%s highest=%s\n' "$vessel" "${count:-0}" "$highest"
}

bridge_inbox_fetch() {
  bridge_run_bounded git -C "$BRIDGE_ROOT" fetch --quiet origin main >/dev/null
}

bridge_inbox_surface() {
  local vessel marker sig surfaced vessel_out out=""

  [ "${#BRIDGE_VESSELS[@]}" -gt 0 ] || return 0
  [ -d "$BRIDGE_ROOT/.git" ] || return 0

  for vessel in "${BRIDGE_VESSELS[@]}"; do
    marker="$STATE/.bridge-surfaced$(bridge_state_suffix "$vessel")"
    sig=$(bridge_inbox_signature "$vessel")
    surfaced=$(cat "$marker" 2>/dev/null || true)
    [ "$sig" != timeout ] || continue
    [ "$sig" != "$surfaced" ] || continue
    vessel_out=$(bridge_inbox_check "$vessel" "$sig")
    if [ -n "$vessel_out" ]; then
      fm_wake_append check "bridge-inbox:$vessel" "check: bridge-inbox: $vessel_out" || return "$?"
      printf '%s' "$sig" > "$marker" 2>/dev/null || true
      out="${out:+$out; }$vessel_out"
    else
      # An acknowledged inbox drops its marker so the same envelopes surface
      # again if Bridge re-delivers them byte-identically later.
      rm -f "$marker" 2>/dev/null || true
    fi
  done

  [ -n "$out" ] || return 0
  printf 'check: bridge-inbox: %s\n' "$out"
}
