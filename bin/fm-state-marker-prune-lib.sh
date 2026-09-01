#!/usr/bin/env bash
# Prune per-task supervision markers after their task record is gone.
#
# state/ is script-owned machinery, so this file is only a helper for the
# owning long-lived loops. It deliberately leaves global records alone: wake
# queues, append-only wedge history, away-mode escalation buffers, locks, and
# batch/journal state are not per-task markers.

fm_state_marker_key() {  # <task-or-window>
  printf '%s' "$1" | tr ':/.' '___'
}

fm_state_marker_set_contains() {  # <pipe-wrapped-set> <key>
  case "$1" in *"|$2|"*) return 0 ;; *) return 1 ;; esac
}

fm_state_marker_live_task_keys() {  # <state-dir>
  local state=$1 meta status task key seen="|"
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta")
    task=${task%.meta}
    key=$(fm_state_marker_key "$task")
    seen="${seen}${key}|"
  done
  for status in "$state"/*.status; do
    [ -e "$status" ] || continue
    task=$(basename "$status")
    task=${task%.status}
    key=$(fm_state_marker_key "$task")
    fm_state_marker_set_contains "$seen" "$key" || seen="${seen}${key}|"
  done
  printf '%s' "$seen"
}

fm_state_marker_live_window_keys() {  # <state-dir>
  local state=$1 meta window key seen="|"
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
    [ -n "$window" ] || continue
    key=$(fm_state_marker_key "$window")
    fm_state_marker_set_contains "$seen" "$key" || seen="${seen}${key}|"
  done
  printf '%s' "$seen"
}

fm_state_marker_live_seen_markers() {  # <state-dir>
  local state=$1 f marker seen="|"
  for f in "$state"/*.status "$state"/*.turn-ended; do
    [ -e "$f" ] || continue
    marker="$state/.seen-$(basename "$f" | tr '.' '_')"
    fm_state_marker_set_contains "$seen" "$marker" || seen="${seen}${marker}|"
  done
  printf '%s' "$seen"
}

fm_state_marker_prune_prefix_set() {  # <state-dir> <live-key-set> <prefix>...
  local state=$1 live=$2 prefix marker base key
  shift 2
  for prefix in "$@"; do
    for marker in "$state"/"$prefix"*; do
      [ -e "$marker" ] || continue
      base=$(basename "$marker")
      case "$prefix:$base" in
        .stale-:.stale-since-*|.paused-:.paused-rechecked-*|.paused-:.paused-resurfaced-*)
          continue
          ;;
      esac
      key=${base#"$prefix"}
      [ -n "$key" ] || continue
      fm_state_marker_set_contains "$live" "$key" && continue
      rm -f "$marker" 2>/dev/null || true
    done
  done
}

fm_state_marker_prune_watcher() {  # <state-dir>
  local state=$1 live_seen live_tasks live_windows marker base key
  [ -d "$state" ] || return 0
  live_seen=$(fm_state_marker_live_seen_markers "$state")
  live_tasks=$(fm_state_marker_live_task_keys "$state")
  live_windows=$(fm_state_marker_live_window_keys "$state")

  for marker in "$state"/.seen-*; do
    [ -e "$marker" ] || continue
    fm_state_marker_set_contains "$live_seen" "$marker" && continue
    rm -f "$marker" 2>/dev/null || true
  done

  for marker in "$state"/.hb-surfaced-*; do
    [ -e "$marker" ] || continue
    base=$(basename "$marker")
    key=${base#.hb-surfaced-}
    fm_state_marker_set_contains "$live_tasks" "$key" && continue
    rm -f "$marker" 2>/dev/null || true
  done

  fm_state_marker_prune_prefix_set "$state" "$live_windows" \
    .stale-since- .wedge-escalations- .paused-rechecked- \
    .paused-resurfaced- .parkedresurfaced- .parkedmeta- \
    .herdr-escalated- .hash- .count- .stale- .wedgeheld- \
    .paused- .parked- .degraded-
}

fm_state_marker_prune_subsuper() {  # <state-dir>
  local state=$1 live_tasks
  [ -d "$state" ] || return 0
  live_tasks=$(fm_state_marker_live_task_keys "$state")
  fm_state_marker_prune_prefix_set "$state" "$live_tasks" \
    .subsuper-seen-status- .subsuper-seen-check- .subsuper-stale- .subsuper-paused-
}
