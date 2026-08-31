#!/usr/bin/env bash
# Safe, home-scoped arm of the optional direct Telegram receiver.
#
# `config/fm-tg-recv.sh` is local/private operational code.
# This tracked wrapper owns only the session-start arm shape: run it as its own
# harness-tracked background task, never bundled onto another command and never
# with shell `&`.
# It starts one receiver for this FM_HOME or attaches to an already running one.
# Under the legacy harness-owned path, the receiver remains this wrapper's child
# and its output returns to that tracked task. Under the service-owned path,
# selected only by FM_TG_RECV_MANAGER=systemd in the generated service
# environment, routed messages and receiver failures go to the durable wake
# queue before this wrapper exits and systemd restarts it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECV="$CONFIG/fm-tg-recv.sh"
ENV_FILE="$CONFIG/telegram.env"
RECV_LOCK="$STATE/.tg-recv.lock"
ATTACH_POLL=${FM_TG_RECV_ATTACH_POLL:-0.5}
ATTACH_CONFIRM_TIMEOUT=${FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT:-2}
TERM_WAIT_CYCLES=${FM_TG_RECV_TERM_WAIT_CYCLES:-30}
TERM_WAIT_POLL=${FM_TG_RECV_TERM_WAIT_POLL:-0.1}
TG_RECV_MANAGER=${FM_TG_RECV_MANAGER:-harness}
FAILURE_WAKE_QUIET=${FM_TG_RECV_FAILURE_WAKE_QUIET:-300}
FAILURE_WAKE_MARKER="$STATE/.tg-recv-last-failure-wake"
SERVICE_HANDOFF_MARKER="$STATE/.tg-recv-service-handoff"
SERVICE_HANDOFF_LOCK="$STATE/.tg-recv-service-handoff.lock"
RECEIVER_OWNER_FILE="$STATE/.tg-recv-owner"
case "$FAILURE_WAKE_QUIET" in ''|*[!0-9]*) FAILURE_WAKE_QUIET=300 ;; esac

harness_handoff_requested() {
  [ "$TG_RECV_MANAGER" != systemd ] \
    && { [ -f "$SERVICE_HANDOFF_MARKER" ] \
      || [ "$(cat "$RECEIVER_OWNER_FILE" 2>/dev/null || true)" = systemd ]; }
}

acquire_receiver_lock() {
  local rc
  fm_lock_acquire_wait "$SERVICE_HANDOFF_LOCK" || return 3
  if harness_handoff_requested; then
    fm_lock_release "$SERVICE_HANDOFF_LOCK"
    return 2
  fi
  if fm_lock_try_acquire "$RECV_LOCK"; then
    TG_RECV_OWNER_DIR=$FM_LOCK_OWNER_DIR
    rc=0
  else
    rc=$?
  fi
  fm_lock_release "$SERVICE_HANDOFF_LOCK"
  return "$rc"
}

usage() {
  printf 'usage: %s\n' "$(basename "$0")" >&2
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  printf 'telegram receiver: inactive (config/telegram.env absent)\n'
  exit 0
fi

if [ ! -x "$RECV" ]; then
  printf 'telegram receiver: FAILED - config/fm-tg-recv.sh missing or not executable\n'
  exit 1
fi

if harness_handoff_requested; then
  printf 'telegram receiver: service ownership handoff in progress\n'
  exit 0
fi

TG_HEALTHY_PID=
# The receiver is a process this wrapper forks and then never controls the image
# of: the kernel walks its shebang chain after the fork, so its cmdline is still
# changing at the moment the fork returns. The lock therefore records the
# receiver's incarnation - fixed at fork, unchanged by every exec - and never its
# image, so that a healthy receiver stays confirmable for its whole life.
# fm_pid_incarnation_matches_record also accepts a record left by an older
# wrapper, which recorded the image too.
tg_receiver_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_record current_incarnation
  lock_home=$(cat "$RECV_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$RECV_LOCK/receiver-path" 2>/dev/null || true)
  lock_record=$(cat "$RECV_LOCK/pid-incarnation" 2>/dev/null || true)
  [ -n "$lock_record" ] || lock_record=$(cat "$RECV_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$RECV" ] || return 1
  [ -n "$lock_record" ] || return 1
  current_incarnation=$(fm_pid_incarnation "$pid") || return 1
  fm_pid_incarnation_matches_record "$current_incarnation" "$lock_record"
}

healthy_receiver() {
  local pid
  TG_HEALTHY_PID=
  pid=$(cat "$RECV_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  tg_receiver_lock_matches_pid "$pid" || return 1
  TG_HEALTHY_PID=$pid
  return 0
}

clear_dead_recorded_receiver_lock() {
  local lock_home lock_path pid
  lock_home=$(cat "$RECV_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$RECV_LOCK/receiver-path" 2>/dev/null || true)
  pid=$(cat "$RECV_LOCK/pid" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$RECV" ] || return 0
  fm_pid_alive "$pid" && return 0
  relay_recorded_receiver_output_once || return 1
  fm_lock_remove_path "$RECV_LOCK" || true
}

service_failure_is_due() {
  local now last
  now=$(date +%s)
  last=$(cat "$FAILURE_WAKE_MARKER" 2>/dev/null || printf '0')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$FAILURE_WAKE_QUIET" ] || return 1
}

record_failure_wake() {
  local payload=$1 now
  service_failure_is_due || return 0
  fm_wake_append check telegram-receiver "$payload" || return 1
  now=$(date +%s)
  ( umask 077 && printf '%s\n' "$now" > "$FAILURE_WAKE_MARKER" ) || {
    printf 'telegram receiver: FAILED - failure wake was queued but its quiet-window marker could not be recorded\n' >&2
    return 0
  }
}

queue_service_output() {
  local relay_path=$1 receiver_status=$2 line had_output=0 output_seq=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    had_output=1
    if [ "$receiver_status" = 0 ] || [ "$receiver_status" = unknown ]; then
      output_seq=$((output_seq + 1))
      fm_wake_append signal "telegram.$(date +%s).$(fm_current_pid).$output_seq" "$line" || return 1
    fi
  done < "$relay_path"

  [ "$receiver_status" = shutdown ] && return 0
  if [ "$receiver_status" != 0 ] && [ "$receiver_status" != unknown ]; then
    record_failure_wake \
      "check: telegram receiver: FAILED - receiver exited $receiver_status; the service will restart it" || return 1
  elif [ "$had_output" -eq 0 ]; then
    record_failure_wake \
      "check: telegram receiver: FAILED - receiver exited without a message or diagnostic; the service will restart it" || return 1
  fi
}

relay_output_file_once() {
  local output_path=$1 receiver_status=${2:-unknown} relay_path
  [ -n "$output_path" ] || return 0
  [ -e "$output_path" ] || return 0
  relay_path="$output_path.relay.$$"
  if mv "$output_path" "$relay_path" 2>/dev/null; then
    if [ "$TG_RECV_MANAGER" = systemd ]; then
      if ! queue_service_output "$relay_path" "$receiver_status"; then
        mv "$relay_path" "$output_path" 2>/dev/null || true
        return 1
      fi
    elif [ -s "$relay_path" ]; then
      cat "$relay_path"
    fi
    rm -f "$relay_path" 2>/dev/null || true
  fi
}

relay_recorded_receiver_output_once() {
  local output_path
  output_path=$(cat "$RECV_LOCK/output-path" 2>/dev/null || true)
  relay_output_file_once "$output_path"
}

attach_and_wait() {
  while :; do
    harness_handoff_requested && exit 0
    if healthy_receiver; then
      sleep "$ATTACH_POLL"
      continue
    fi
    relay_recorded_receiver_output_once || {
      printf 'telegram receiver: FAILED - receiver output could not be durably relayed\n'
      exit 1
    }
    clear_dead_recorded_receiver_lock
    exit 0
  done
}

attach_if_receiver_becomes_healthy() {
  local deadline now
  deadline=$(($(date +%s) + ATTACH_CONFIRM_TIMEOUT))
  while [ -e "$RECV_LOCK" ] || [ -L "$RECV_LOCK" ]; do
    harness_handoff_requested && exit 0
    if healthy_receiver; then
      printf 'telegram receiver: attached pid=%s\n' "$TG_HEALTHY_PID"
      attach_and_wait
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$ATTACH_POLL"
  done
  return 1
}

if healthy_receiver; then
  printf 'telegram receiver: attached pid=%s\n' "$TG_HEALTHY_PID"
  attach_and_wait
fi

clear_dead_recorded_receiver_lock

ownerdir=
TG_RECV_OWNER_DIR=
if acquire_receiver_lock; then
  :
else
  acquire_rc=$?
  [ "$acquire_rc" -ne 2 ] || {
    printf 'telegram receiver: service ownership handoff in progress\n'
    exit 0
  }
  [ "$acquire_rc" -eq 1 ] || {
    printf 'telegram receiver: FAILED - receiver ownership gate could not be acquired\n'
    exit 1
  }
  attach_if_receiver_becomes_healthy
  if acquire_receiver_lock; then
    :
  else
    acquire_rc=$?
    [ "$acquire_rc" -ne 2 ] || {
      printf 'telegram receiver: service ownership handoff in progress\n'
      exit 0
    }
    printf 'telegram receiver: FAILED - receiver lock is held but no live matching receiver was confirmed\n'
    exit 1
  fi
fi
ownerdir=$TG_RECV_OWNER_DIR

child=
child_out=
release_lock_if_owned() {
  [ -n "$ownerdir" ] || return 0
  if fm_lock_points_to_owner "$RECV_LOCK" "$ownerdir"; then
    fm_lock_remove_path "$RECV_LOCK" 2>/dev/null || true
  fi
}

record_child_lock_metadata_if_possible() {
  local current_incarnation
  [ -n "$ownerdir" ] || return 0
  [ -n "$child" ] || return 0
  fm_lock_points_to_owner "$RECV_LOCK" "$ownerdir" || return 0
  current_incarnation=$(fm_pid_incarnation "$child" 2>/dev/null) || return 0
  {
    printf '%s\n' "$child" > "$ownerdir/pid"
    printf '%s\n' "$FM_HOME" > "$ownerdir/fm-home"
    printf '%s\n' "$current_incarnation" > "$ownerdir/pid-incarnation"
    printf '%s\n' "$RECV" > "$ownerdir/receiver-path"
    [ -n "$child_out" ] && printf '%s\n' "$child_out" > "$ownerdir/output-path"
  } 2>/dev/null || true
}

child_still_running() {
  local stat
  fm_pid_alive "$child" || return 1
  stat=$(ps -p "$child" -o stat= 2>/dev/null | sed 's/^[[:space:]]*//') || return 1
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

terminate_child_bounded() {
  local i=0
  [ -n "$child" ] || return 0
  if child_still_running; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  while child_still_running && [ "$i" -lt "$TERM_WAIT_CYCLES" ]; do
    sleep "$TERM_WAIT_POLL"
    i=$((i + 1))
  done
  if child_still_running; then
    return 1
  fi
  wait "$child" 2>/dev/null || true
  return 0
}

cleanup() {
  record_child_lock_metadata_if_possible
  if terminate_child_bounded; then
    if [ -n "$child_out" ] && ! relay_output_file_once "$child_out" shutdown; then
      printf 'telegram receiver: FAILED - receiver output could not be durably relayed during shutdown\n' >&2
      return 1
    fi
    release_lock_if_owned
    [ -n "$child_out" ] && rm -f "$child_out" 2>/dev/null || true
    return
  fi
}
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 143' TERM INT

child_out=$(mktemp "$STATE/.tg-recv-output.XXXXXX") || {
  cleanup
  printf 'telegram receiver: FAILED - could not create output capture\n'
  exit 1
}

FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" "$RECV" >"$child_out" &
child=$!
incarnation=$(fm_pid_incarnation "$child" 2>/dev/null || true)
if [ -z "$incarnation" ]; then
  if [ -s "$child_out" ] || ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    {
      printf '%s\n' "$child" > "$ownerdir/pid"
      printf '%s\n' "$FM_HOME" > "$ownerdir/fm-home"
      printf '%s\n' "$RECV" > "$ownerdir/receiver-path"
      printf '%s\n' "$child_out" > "$ownerdir/output-path"
    } 2>/dev/null || true
    if ! relay_output_file_once "$child_out" "$rc"; then
      printf 'telegram receiver: FAILED - receiver output could not be durably relayed\n'
      trap - HUP TERM INT
      exit 1
    fi
    release_lock_if_owned
    rm -f "$child_out" 2>/dev/null || true
    trap - HUP TERM INT
    exit "$rc"
  fi
  cleanup
  printf 'telegram receiver: FAILED - could not identify receiver process\n'
  exit 1
fi

{
  printf '%s\n' "$child" > "$ownerdir/pid"
  printf '%s\n' "$FM_HOME" > "$ownerdir/fm-home"
  printf '%s\n' "$incarnation" > "$ownerdir/pid-incarnation"
  printf '%s\n' "$RECV" > "$ownerdir/receiver-path"
  printf '%s\n' "$child_out" > "$ownerdir/output-path"
} 2>/dev/null || {
  cleanup
  printf 'telegram receiver: FAILED - could not record receiver lock metadata\n'
  exit 1
}

printf 'telegram receiver: started pid=%s\n' "$child"
wait "$child"
rc=$?
if ! relay_output_file_once "$child_out" "$rc"; then
  printf 'telegram receiver: FAILED - receiver output could not be durably relayed\n'
  trap - HUP TERM INT
  exit 1
fi
release_lock_if_owned
rm -f "$child_out" 2>/dev/null || true
trap - HUP TERM INT
exit "$rc"
