#!/usr/bin/env bash

fm_keeper_home_digest() {  # <home>
  local home=$1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$home" | sha256sum | awk '{print substr($1,1,20)}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$home" | shasum -a 256 | awk '{print substr($1,1,20)}'
    return
  fi
  echo 'error: keeper naming requires sha256sum or shasum -a 256' >&2
  return 1
}

fm_keeper_name() {  # <service> <home>
  local service=$1 home=$2 base digest
  base=$(basename "$home" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
  digest=$(fm_keeper_home_digest "$home") || return 1
  printf 'fm-%s-%s-%s\n' "$service" "$base" "$digest"
}

fm_legacy_keeper_name() {  # <service> <home>
  local service=$1 home=$2 base sum
  base=$(basename "$home" | tr -c 'A-Za-z0-9_-' '_')
  sum=$(printf '%s' "$home" | cksum | awk '{print $1}')
  printf 'fm-%s-%s-%s\n' "$service" "$base" "$sum"
}

fm_legacy_keeper_owned_by_home() {  # <tmux> <name> <keeper-pid-file> <lock> <home>
  local tmux=$1 name=$2 pid_file=$3 lock=$4 home=$5 recorded_pid pane pane_pid recorded_home
  "$tmux" has-session -t "$name" 2>/dev/null || return 1
  recorded_pid=$(cat "$pid_file" 2>/dev/null || true)
  case "$recorded_pid" in ''|*[!0-9]*) return 1 ;; esac
  pane=$(fm_tmux_resolve_pane "$name" "$tmux") || return 1
  pane_pid=$("$tmux" display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 1
  recorded_home=$(cat "$lock/fm-home" 2>/dev/null || true)
  [ "$pane_pid" = "$recorded_pid" ] && [ "$recorded_home" = "$home" ]
}
