#!/usr/bin/env bash
# Safe, home-scoped arm of the optional direct Telegram receiver.
#
# `config/fm-tg-recv.sh` is local/private operational code.
# This tracked wrapper owns only the session-start arm shape: run it as its own
# harness-tracked background task, never bundled onto another command and never
# with shell `&`.
# It starts one receiver for this FM_HOME or attaches to an already running one.
# Only one arm wrapper remains attached for a home at a time.
# The receiver remains this wrapper's child when started here, so the harness
# gets notified when a Telegram message makes the receiver print one routed
# captain or operational-input line and exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECV="$CONFIG/fm-tg-recv.sh"
ENV_FILE="$CONFIG/telegram.env"
RECV_LOCK="$STATE/.tg-recv.lock"
ARM_LOCK="$STATE/.tg-recv-arm.lock"
ATTACH_POLL=${FM_TG_RECV_ATTACH_POLL:-0.5}
ATTACH_CONFIRM_TIMEOUT=${FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT:-2}
TERM_WAIT_CYCLES=${FM_TG_RECV_TERM_WAIT_CYCLES:-30}
TERM_WAIT_POLL=${FM_TG_RECV_TERM_WAIT_POLL:-0.1}
ARM_PARENT_PID=${FM_TG_RECV_ARM_PARENT_PID:-$PPID}
ARM_PARENT_INCARNATION=$(fm_pid_incarnation "$ARM_PARENT_PID" 2>/dev/null || true)
ARM_OWNER_DIR=
ARM_MODE=starting

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

TG_HEALTHY_PID=
TG_ARM_COUNT=
TG_ARM_COUNT_REASON=

tg_arm_cmdline_matches() {
  local cmdline_file=$1 arg base
  base=$(basename "$0")
  while IFS= read -r -d '' arg; do
    case "$arg" in
      "$0"|"$SCRIPT_DIR/$base"|*/"$base"|"$base") return 0 ;;
    esac
  done < "$cmdline_file"
  return 1
}

tg_arm_env_matches_home() {
  local env_file=$1 entry saw_home=0
  while IFS= read -r -d '' entry; do
    case "$entry" in
      FM_HOME=*)
        saw_home=1
        [ "$entry" = "FM_HOME=$FM_HOME" ] && return 0
        ;;
    esac
  done < "$env_file"
  [ "$saw_home" -eq 0 ] && return 2
  return 1
}

tg_arm_default_home_matches() {
  local proc_dir=$1 cwd
  [ "$FM_HOME" = "$FM_ROOT" ] || return 1
  cwd=$(readlink "$proc_dir/cwd" 2>/dev/null) || return 1
  [ "$cwd" = "$FM_HOME" ]
}

tg_count_same_home_arms() {
  local proc_root proc_dir env_rc
  TG_ARM_COUNT=0
  TG_ARM_COUNT_REASON=
  proc_root=${FM_TG_RECV_PROC_ROOT:-${FM_PROC_ROOT_OVERRIDE:-/proc}}
  [ -d "$proc_root" ] || {
    TG_ARM_COUNT_REASON=proc-unavailable
    return 1
  }
  for proc_dir in "$proc_root"/[0-9]*; do
    [ -d "$proc_dir" ] || continue
    [ -r "$proc_dir/cmdline" ] || continue
    [ -r "$proc_dir/environ" ] || continue
    tg_arm_cmdline_matches "$proc_dir/cmdline" || continue
    tg_arm_env_matches_home "$proc_dir/environ"
    env_rc=$?
    if [ "$env_rc" -eq 0 ]; then
      :
    elif [ "$env_rc" -eq 2 ]; then
      tg_arm_default_home_matches "$proc_dir" || continue
    else
      continue
    fi
    TG_ARM_COUNT=$((TG_ARM_COUNT + 1))
  done
  return 0
}

print_arm_count_reading() {
  if tg_count_same_home_arms; then
    printf 'telegram receiver arms: measured count=%s expected=1\n' "$TG_ARM_COUNT"
    return
  fi
  printf 'telegram receiver arms: unmeasured expected=1 reason=%s\n' "${TG_ARM_COUNT_REASON:-unknown}"
}

record_arm_lock_metadata_if_possible() {
  local current_incarnation
  [ -n "$ARM_OWNER_DIR" ] || return 0
  fm_lock_points_to_owner "$ARM_LOCK" "$ARM_OWNER_DIR" || return 0
  current_incarnation=$(fm_pid_incarnation "$(fm_current_pid)" 2>/dev/null || true)
  {
    printf '%s\n' "$FM_HOME" > "$ARM_OWNER_DIR/fm-home"
    printf '%s/%s\n' "$SCRIPT_DIR" "$(basename "$0")" > "$ARM_OWNER_DIR/arm-path"
    printf '%s\n' "$ARM_MODE" > "$ARM_OWNER_DIR/arm-mode"
    printf '%s\n' "$ARM_PARENT_PID" > "$ARM_OWNER_DIR/parent-pid"
    [ -n "$ARM_PARENT_INCARNATION" ] && printf '%s\n' "$ARM_PARENT_INCARNATION" > "$ARM_OWNER_DIR/parent-incarnation"
    [ -n "$current_incarnation" ] && printf '%s\n' "$current_incarnation" > "$ARM_OWNER_DIR/pid-incarnation"
  } 2>/dev/null || true
}

release_arm_lock_if_owned() {
  [ -n "$ARM_OWNER_DIR" ] || return 0
  if fm_lock_points_to_owner "$ARM_LOCK" "$ARM_OWNER_DIR"; then
    fm_lock_release "$ARM_LOCK" 2>/dev/null || true
  fi
}

arm_parent_alive() {
  local current_incarnation
  fm_pid_alive "$ARM_PARENT_PID" || return 1
  [ -n "$ARM_PARENT_INCARNATION" ] || return 0
  current_incarnation=$(fm_pid_incarnation "$ARM_PARENT_PID" 2>/dev/null) || return 1
  fm_pid_incarnation_matches_record "$current_incarnation" "$ARM_PARENT_INCARNATION"
}

stand_down_for_dead_parent() {
  printf 'telegram receiver: arm parent gone; standing down\n'
  release_arm_lock_if_owned
  exit 0
}

detach_child_for_dead_parent() {
  record_child_lock_metadata_if_possible
  disown "$child" 2>/dev/null || true
  trap - HUP TERM INT
  release_arm_lock_if_owned
  printf 'telegram receiver: arm parent gone; receiver left running pid=%s\n' "$child"
  exit 0
}

acquire_arm_lock_or_stand_down() {
  local rc held_pid
  if fm_lock_try_acquire "$ARM_LOCK"; then
    ARM_OWNER_DIR=$FM_LOCK_OWNER_DIR
    record_arm_lock_metadata_if_possible
    print_arm_count_reading
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    printf 'telegram receiver: FAILED - arm lock could not be checked\n'
    exit 1
  fi
  held_pid=${FM_LOCK_HELD_PID:-unknown}
  print_arm_count_reading
  printf 'telegram receiver: already armed pid=%s\n' "$held_pid"
  exit 0
}

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
  relay_recorded_receiver_output_once
  fm_lock_remove_path "$RECV_LOCK" || true
}

relay_output_file_once() {
  local output_path=$1 relay_path
  [ -n "$output_path" ] || return 0
  [ -e "$output_path" ] || return 0
  relay_path="$output_path.relay.$$"
  if mv "$output_path" "$relay_path" 2>/dev/null; then
    [ -s "$relay_path" ] && cat "$relay_path"
    rm -f "$relay_path" 2>/dev/null || true
  fi
}

relay_recorded_receiver_output_once() {
  local output_path
  output_path=$(cat "$RECV_LOCK/output-path" 2>/dev/null || true)
  relay_output_file_once "$output_path"
}

attach_and_wait() {
  ARM_MODE=attached
  record_arm_lock_metadata_if_possible
  while :; do
    arm_parent_alive || stand_down_for_dead_parent
    if healthy_receiver; then
      sleep "$ATTACH_POLL"
      continue
    fi
    relay_recorded_receiver_output_once
    clear_dead_recorded_receiver_lock
    release_arm_lock_if_owned
    exit 0
  done
}

attach_if_receiver_becomes_healthy() {
  local deadline now
  deadline=$(($(date +%s) + ATTACH_CONFIRM_TIMEOUT))
  while [ -e "$RECV_LOCK" ] || [ -L "$RECV_LOCK" ]; do
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
  acquire_arm_lock_or_stand_down
  printf 'telegram receiver: attached pid=%s\n' "$TG_HEALTHY_PID"
  attach_and_wait
fi

clear_dead_recorded_receiver_lock

acquire_arm_lock_or_stand_down

ownerdir=
if ! fm_lock_try_acquire "$RECV_LOCK"; then
  attach_if_receiver_becomes_healthy
  if ! fm_lock_try_acquire "$RECV_LOCK"; then
    printf 'telegram receiver: FAILED - receiver lock is held but no live matching receiver was confirmed\n'
    release_arm_lock_if_owned
    exit 1
  fi
fi
ownerdir=$FM_LOCK_OWNER_DIR

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
    release_lock_if_owned
    [ -n "$child_out" ] && relay_output_file_once "$child_out"
    [ -n "$child_out" ] && rm -f "$child_out" 2>/dev/null || true
  fi
  release_arm_lock_if_owned
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
    [ -s "$child_out" ] && cat "$child_out"
    release_lock_if_owned
    release_arm_lock_if_owned
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
ARM_MODE=starter
record_arm_lock_metadata_if_possible
while child_still_running; do
  arm_parent_alive || detach_child_for_dead_parent
  sleep "$ATTACH_POLL"
done
wait "$child"
rc=$?
relay_output_file_once "$child_out"
release_lock_if_owned
release_arm_lock_if_owned
rm -f "$child_out" 2>/dev/null || true
trap - HUP TERM INT
exit "$rc"
