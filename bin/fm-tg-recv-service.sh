#!/usr/bin/env bash
# Own the systemd user service for one home's optional direct Telegram receiver.
#
# Usage:
#   fm-tg-recv-service.sh bootstrap
#   fm-tg-recv-service.sh ensure
#   fm-tg-recv-service.sh install-unit
#   fm-tg-recv-service.sh selected
#   fm-tg-recv-service.sh status
#
# config/telegram.env opts a home into detection. Installation and enablement
# happen only through install-unit after the captain approves the
# TELEGRAM_RECEIVER_UNIT bootstrap diagnostic. Until then session start retains
# the legacy tracked-task arm path. Once installed, locked bootstrap converges
# the unit and environment and session start no longer asks a harness to arm it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ARM="$SCRIPT_DIR/fm-tg-recv-arm.sh"
RECV="$CONFIG/fm-tg-recv.sh"
ENV_FILE="$CONFIG/telegram.env"
UNIT_SOURCE="$FM_ROOT/systemd/fm-tg-recv@.service"
SYSTEMCTL=${FM_TG_RECV_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_TG_RECV_SYSTEMD_ESCAPE:-systemd-escape}
USER_UNIT_DIR=${FM_TG_RECV_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-tg-recv@.service"
SERVICE_ENV="$STATE/.tg-recv-service.env"
SERVICE_HANDOFF_MARKER="$STATE/.tg-recv-service-handoff"
SERVICE_HANDOFF_LOCK="$STATE/.tg-recv-service-handoff.lock"
RECEIVER_OWNER_FILE="$STATE/.tg-recv-owner"
RECV_LOCK="$STATE/.tg-recv.lock"
CONFIRM_TIMEOUT=${FM_TG_RECV_CONFIRM_TIMEOUT:-10}
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=10 ;; esac

# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_axi_prepend_path "$FM_HOME"

configured() {
  [ -f "$ENV_FILE" ]
}

receiver_ready() {
  [ -x "$RECV" ]
}

systemd_usable() {
  [ "${FM_TG_RECV_FORCE_SYSTEMD:-0}" = 1 ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-tg-recv@%s.service\n' "$escaped"
}

systemd_installed() {
  [ -f "$UNIT_DEST" ] && [ ! -L "$UNIT_DEST" ]
}

systemd_enabled() {
  local unit
  unit=$(unit_instance) || return 1
  "$SYSTEMCTL" --user is-enabled --quiet "$unit"
}

systemd_active() {
  local unit
  unit=$(unit_instance) || return 1
  "$SYSTEMCTL" --user is-active --quiet "$unit"
}

systemd_env_quote() {
  local value=$1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

source_version() {
  local file sum
  local -a files=(
    "$ARM"
    "$SCRIPT_DIR/fm-wake-lib.sh"
    "$SCRIPT_DIR/fm-journal-lib.sh"
    "$RECV"
  )
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(
      for file in "${files[@]}"; do
        [ -f "$file" ] || return 1
        printf '%s\0' "${file#"$FM_ROOT"/}"
        sha256sum < "$file" || return 1
      done | sha256sum | awk '{print $1}'
    ) || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  sum=$(
    for file in "${files[@]}"; do
      [ -f "$file" ] || return 1
      printf '%s\0' "${file#"$FM_ROOT"/}"
      cksum < "$file" || return 1
    done | cksum | awk '{print $1 ":" $2}'
  ) || return 1
  printf 'cksum:%s\n' "$sum"
}

write_service_env() {
  local version resolved_path tmp changed=0
  version=$(source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$SERVICE_ENV.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_CONFIG_OVERRIDE=%s\n' "$(systemd_env_quote "$CONFIG")"
    printf 'FM_TG_RECV_EXEC=%s\n' "$(systemd_env_quote "$ARM")"
    printf 'FM_TG_RECV_MANAGER=systemd\n'
    printf 'FM_TG_RECV_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
    printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_TG_RECV_ENV_CHANGED=$changed
}

service_env_matches() {
  local version resolved_path
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  version=$(source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  grep -Fx "FM_HOME=$(systemd_env_quote "$FM_HOME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_ROOT_OVERRIDE=$(systemd_env_quote "$FM_ROOT")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_STATE_OVERRIDE=$(systemd_env_quote "$STATE")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_CONFIG_OVERRIDE=$(systemd_env_quote "$CONFIG")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_TG_RECV_EXEC=$(systemd_env_quote "$ARM")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx 'FM_TG_RECV_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_TG_RECV_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "PATH=$(systemd_env_quote "$resolved_path")" "$SERVICE_ENV" >/dev/null 2>&1
}

install_unit_bytes() {
  [ -f "$UNIT_SOURCE" ] && [ ! -L "$UNIT_SOURCE" ] || return 1
  mkdir -p "$USER_UNIT_DIR" || return 1
  install -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
}

wait_for_active() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    systemd_active && return 0
    sleep 0.2
  done
  systemd_active
}

begin_service_handoff() {
  local tmp owner_tmp
  mkdir -p "$STATE" || return 1
  owner_tmp=$(mktemp "$RECEIVER_OWNER_FILE.XXXXXX") || return 1
  printf '%s\n' systemd > "$owner_tmp" || { rm -f "$owner_tmp"; return 1; }
  mv -f "$owner_tmp" "$RECEIVER_OWNER_FILE" || return 1
  tmp=$(mktemp "$SERVICE_HANDOFF_MARKER.XXXXXX") || return 1
  printf '%s\n' "$$" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SERVICE_HANDOFF_MARKER"
}

converge_service_receiver() {
  local unit=$1 action=$2
  fm_lock_acquire_wait "$SERVICE_HANDOFF_LOCK" || return 1
  begin_service_handoff || { fm_lock_release "$SERVICE_HANDOFF_LOCK"; return 1; }
  if ! retire_harness_receiver; then
    rm -f "$SERVICE_HANDOFF_MARKER"
    fm_lock_release "$SERVICE_HANDOFF_LOCK"
    return 1
  fi
  if [ "$action" = enable ]; then
    if ! "$SYSTEMCTL" --user enable --now "$unit"; then
      rm -f "$SERVICE_HANDOFF_MARKER"
      fm_lock_release "$SERVICE_HANDOFF_LOCK"
      return 1
    fi
  else
    if ! "$SYSTEMCTL" --user restart "$unit"; then
      rm -f "$SERVICE_HANDOFF_MARKER"
      fm_lock_release "$SERVICE_HANDOFF_LOCK"
      return 1
    fi
  fi
  fm_lock_release "$SERVICE_HANDOFF_LOCK"
  if ! wait_for_active; then
    rm -f "$SERVICE_HANDOFF_MARKER"
    return 1
  fi
  rm -f "$SERVICE_HANDOFF_MARKER"
}

retire_harness_receiver() {
  local deadline pid lock_home lock_path record current
  [ -e "$RECV_LOCK" ] || [ -L "$RECV_LOCK" ] || return 0
  pid=$(cat "$RECV_LOCK/pid" 2>/dev/null || true)
  lock_home=$(cat "$RECV_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$RECV_LOCK/receiver-path" 2>/dev/null || true)
  record=$(cat "$RECV_LOCK/pid-incarnation" 2>/dev/null || true)
  [ -n "$record" ] || record=$(cat "$RECV_LOCK/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_incarnation "$pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    [ "$lock_home" = "$FM_HOME" ] && [ "$lock_path" = "$RECV" ] \
      && fm_pid_incarnation_matches_record "$current" "$record" || {
        echo "error: receiver lock does not identify a safe handoff target" >&2
        return 1
      }
    kill -TERM "$pid" 2>/dev/null || return 1
  fi
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ -e "$RECV_LOCK" ] || [ -L "$RECV_LOCK" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      echo "error: harness receiver did not release $RECV_LOCK" >&2
      return 1
    }
    sleep 0.2
  done
}

ensure_systemd() {
  local unit changed=0 owner
  configured || return 0
  receiver_ready || {
    echo "TELEGRAM_RECEIVER_UNIT: config/telegram.env exists but config/fm-tg-recv.sh is missing or not executable" >&2
    return 2
  }
  systemd_usable || {
    echo "TELEGRAM_RECEIVER_UNIT: systemd --user is unavailable; session start retains the tracked receiver fallback" >&2
    return 2
  }
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "TELEGRAM_RECEIVER_UNIT: missing - approve: bin/fm-bootstrap.sh install telegram-receiver-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "TELEGRAM_RECEIVER_UNIT: disabled - approve: bin/fm-bootstrap.sh install telegram-receiver-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  FM_TG_RECV_ENV_CHANGED=0
  write_service_env || return 1
  [ "$FM_TG_RECV_ENV_CHANGED" -eq 0 ] || changed=1
  owner=$(cat "$RECEIVER_OWNER_FILE" 2>/dev/null || true)
  [ "$owner" = systemd ] || changed=1
  if [ "$changed" -eq 1 ] || ! systemd_active; then
    converge_service_receiver "$unit" restart || return 1
  fi
  wait_for_active
}

install_systemd() {
  local unit
  configured || { echo "error: config/telegram.env is absent" >&2; return 1; }
  receiver_ready || { echo "error: config/fm-tg-recv.sh is missing or not executable" >&2; return 1; }
  systemd_usable || { echo "error: systemd --user is unavailable" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  if ! converge_service_receiver "$unit" enable; then
    echo "error: $unit ownership handoff failed" >&2
    return 1
  fi
}

bootstrap_check() {
  local unit
  configured || return 0
  if ! receiver_ready; then
    echo "TELEGRAM_RECEIVER_UNIT: config/telegram.env exists but config/fm-tg-recv.sh is missing or not executable"
    return 0
  fi
  if ! systemd_usable; then
    echo "TELEGRAM_RECEIVER_UNIT: systemd --user is unavailable; session start retains the tracked receiver fallback"
    return 0
  fi
  unit=$(unit_instance) || { echo "TELEGRAM_RECEIVER_UNIT: failed to encode FM_HOME $FM_HOME"; return 0; }
  if ! systemd_installed; then
    echo "TELEGRAM_RECEIVER_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install telegram-receiver-unit"
  elif ! systemd_enabled; then
    echo "TELEGRAM_RECEIVER_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install telegram-receiver-unit"
  elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches || ! systemd_active; then
      echo "TELEGRAM_RECEIVER_UNIT: $unit needs locked convergence from the session holding the fleet lock"
    fi
  elif ! ensure_systemd >/dev/null; then
    echo "TELEGRAM_RECEIVER_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
  fi
}

selected() {
  configured && receiver_ready && systemd_usable && systemd_installed && systemd_enabled \
    && service_env_matches && systemd_active
}

status_report() {
  local pid record current
  configured || { echo "inactive: config/telegram.env absent"; return 0; }
  selected || { echo "fallback: receiver service is not installed and enabled"; return 1; }
  systemd_active || { echo "down: receiver service is not active"; return 1; }
  pid=$(cat "$STATE/.tg-recv.lock/pid" 2>/dev/null || true)
  record=$(cat "$STATE/.tg-recv.lock/pid-incarnation" 2>/dev/null || true)
  fm_pid_alive "$pid" || { echo "down: service is active but no live receiver is recorded"; return 1; }
  current=$(fm_pid_incarnation "$pid" 2>/dev/null || true)
  fm_pid_incarnation_matches_record "$current" "$record" \
    || { echo "down: service is active but the receiver record does not match its process"; return 1; }
  printf 'up: receiver pid %s is live and identity-matched\n' "$pid"
}

case "${1:-}" in
  bootstrap) bootstrap_check ;;
  ensure) ensure_systemd ;;
  install-unit) install_systemd ;;
  selected) selected ;;
  status) status_report ;;
  *)
    echo "usage: $(basename "$0") {bootstrap|ensure|install-unit|selected|status}" >&2
    exit 2
    ;;
esac
