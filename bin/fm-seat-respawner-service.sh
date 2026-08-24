#!/usr/bin/env bash
# Own the per-home primary-seat respawner unit.
#
# Usage:
#   fm-seat-respawner-service.sh bootstrap
#   fm-seat-respawner-service.sh ensure
#   fm-seat-respawner-service.sh restart
#   fm-seat-respawner-service.sh install-unit
#   fm-seat-respawner-service.sh status
#
# Installation is explicit only: bootstrap reports RESPAWNER_UNIT diagnostics,
# and bin/fm-bootstrap.sh install seat-respawner-unit performs the approved
# install. After installation, locked bootstrap converges stale template bytes,
# environment, PATH, and source version for this home only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESPAWNER="$SCRIPT_DIR/fm-seat-respawner.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-seat-respawner@.service"
SYSTEMCTL=${FM_RESPAWNER_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_RESPAWNER_SYSTEMD_ESCAPE:-systemd-escape}
USER_UNIT_DIR=${FM_RESPAWNER_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-seat-respawner@.service"
SERVICE_ENV="$STATE/.seat-respawner-service.env"

# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_axi_prepend_path "$FM_HOME"

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
    "$RESPAWNER"
    "$SCRIPT_DIR/fm-seat-stay-down.sh"
    "$SCRIPT_DIR/fm-delivery-lib.sh"
    "$SCRIPT_DIR/fm-service-path-lib.sh"
    "$SCRIPT_DIR/fm-wake-lib.sh"
  )
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(
      for file in "${files[@]}"; do
        printf '%s\0' "${file#"$SCRIPT_DIR"/}"
        sha256sum < "$file" || exit 1
      done | sha256sum | awk '{print $1}'
    ) || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  sum=$(
    for file in "${files[@]}"; do
      printf '%s\0' "${file#"$SCRIPT_DIR"/}"
      cksum < "$file" || exit 1
    done | cksum | awk '{print $1 ":" $2}'
  ) || return 1
  printf 'cksum:%s\n' "$sum"
}

systemd_usable() {
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-seat-respawner@%s.service\n' "$escaped"
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

install_unit_bytes() {
  [ -f "$UNIT_SOURCE" ] && [ ! -L "$UNIT_SOURCE" ] || return 1
  mkdir -p "$USER_UNIT_DIR" || return 1
  install -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
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
    printf 'FM_SEAT_RESPAWNER_EXEC=%s\n' "$(systemd_env_quote "$RESPAWNER")"
    printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
    printf 'FM_SEAT_RESPAWNER_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    FM_RESPAWNER_ENV_CHANGED=1
  else
    rm -f "$tmp"
    FM_RESPAWNER_ENV_CHANGED=0
  fi
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
    && grep -Fx "FM_SEAT_RESPAWNER_EXEC=$(systemd_env_quote "$RESPAWNER")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "PATH=$(systemd_env_quote "$resolved_path")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_SEAT_RESPAWNER_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1
}

ensure_systemd() {
  local unit changed=0
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "RESPAWNER_UNIT: missing - approve: bin/fm-bootstrap.sh install seat-respawner-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "RESPAWNER_UNIT: disabled - approve: bin/fm-bootstrap.sh install seat-respawner-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  write_service_env || return 1
  [ "${FM_RESPAWNER_ENV_CHANGED:-0}" -eq 0 ] || changed=1
  if [ "$changed" -eq 1 ] || ! systemd_active; then
    "$SYSTEMCTL" --user restart "$unit" || return 1
  fi
}

install_systemd() {
  local unit
  systemd_usable || { echo "error: systemd --user is unavailable; seat respawn needs a user unit" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable --now "$unit"
}

bootstrap_check() {
  local unit
  if ! systemd_usable; then
    echo "RESPAWNER_UNIT: systemd --user is unavailable; no primary-seat respawner can be supervised here"
    return 0
  fi
  unit=$(unit_instance) || { echo "RESPAWNER_UNIT: failed to encode FM_HOME $FM_HOME"; return 0; }
  if ! systemd_installed; then
    echo "RESPAWNER_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install seat-respawner-unit"
  elif ! systemd_enabled; then
    echo "RESPAWNER_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install seat-respawner-unit"
  elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches || ! systemd_active; then
      echo "RESPAWNER_UNIT: $unit needs locked convergence from the session holding the fleet lock"
    fi
  elif ! ensure_systemd >/dev/null; then
    echo "RESPAWNER_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
  fi
}

status_report() {
  local age=999999 pid
  [ -e "$STATE/.last-seat-respawner-beat" ] && age=$(fm_path_age "$STATE/.last-seat-respawner-beat")
  pid=$(sed -n 's/^pid=//p' "$STATE/.seat-respawner.lock/record" 2>/dev/null | head -1)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'up: respawner pid %s last beat %ss ago\n' "$pid" "$age"
  else
    printf 'down: no live respawner lock for this home (last beat %ss ago)\n' "$age"
  fi
}

case "${1:-}" in
  bootstrap) bootstrap_check ;;
  ensure) ensure_systemd ;;
  restart)
    write_service_env || exit 1
    "$SYSTEMCTL" --user restart "$(unit_instance)"
    ;;
  install-unit) install_systemd ;;
  status) status_report ;;
  *)
    echo "usage: $(basename "$0") {bootstrap|ensure|restart|install-unit|status}" >&2
    exit 2
    ;;
esac
