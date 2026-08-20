#!/usr/bin/env bash
# Own the external wake-delivery listener for one FM_HOME.
#
# Usage:
#   fm-delivery-service.sh select
#   fm-delivery-service.sh bootstrap
#   fm-delivery-service.sh ensure
#   fm-delivery-service.sh restart
#   fm-delivery-service.sh install-unit
#   fm-delivery-service.sh publish-endpoint
#   fm-delivery-service.sh status
#   fm-delivery-service.sh repair-command
#
# This is the companion of bin/fm-watcher-service.sh: the watcher owns the loop
# that DETECTS wakes, this owns the listener that DELIVERS them.  Both are
# per-home, both are supervised outside the harness, and neither can reach
# another home - the systemd instance name and the tmux keeper name are both
# derived from FM_HOME alone.
#
# A working systemd user manager selects the tracked fm-delivery@.service
# template.  First installation and enablement happen only through install-unit
# after the captain approves the DELIVERY_UNIT bootstrap diagnostic.  An
# already-installed unit converges its tracked bytes, per-home environment,
# source version, and running process automatically at a locked bootstrap
# boundary.  If systemd is unusable, a detached home-scoped tmux keeper is
# selected automatically, because a home without a supervised listener would
# otherwise need a session-held waiter - the object this design exists to remove.
#
# publish-endpoint is the one subcommand that must run INSIDE the primary
# session: the listener has no session context of its own, so the session
# records where its own model turn lives.  Everything else is safe to run from
# anywhere that can reach this home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DELIVERY="$SCRIPT_DIR/fm-delivery.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-delivery@.service"
SYSTEMCTL=${FM_DELIVERY_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_DELIVERY_SYSTEMD_ESCAPE:-systemd-escape}
TMUX_CMD=${FM_DELIVERY_TMUX:-tmux}
USER_UNIT_DIR=${FM_DELIVERY_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-delivery@.service"
SERVICE_ENV="$STATE/.delivery-service.env"
GRACE=${FM_DELIVERY_GRACE:-${FM_GUARD_GRACE:-300}}
CONFIRM_TIMEOUT=${FM_DELIVERY_CONFIRM_TIMEOUT:-10}
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=10 ;; esac
STOP_TIMEOUT=${FM_DELIVERY_STOP_TIMEOUT:-20}
case "$STOP_TIMEOUT" in ''|*[!0-9]*|0) STOP_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-keeper-name-lib.sh
. "$SCRIPT_DIR/fm-keeper-name-lib.sh"
# See fm-watcher-service.sh: composed values resolve tools through THIS
# process's PATH, so the home's own AXI prefix has to lead it here.
fm_axi_prepend_path "$FM_HOME"

delivery_source_version() {
  local file sum size
  local -a files=(
    "$DELIVERY"
    "$SCRIPT_DIR/fm-delivery-lib.sh"
    "$SCRIPT_DIR/fm-wake-lib.sh"
    "$SCRIPT_DIR/fm-operational-input.sh"
    "$SCRIPT_DIR/fm-pane-activity-lib.sh"
    "$SCRIPT_DIR/fm-composer-lib.sh"
    "$SCRIPT_DIR/fm-tmux-lib.sh"
    "$SCRIPT_DIR/fm-backend.sh"
    "$SCRIPT_DIR/fm-keeper-name-lib.sh"
    "$SCRIPT_DIR"/backends/*.sh
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
  if command -v shasum >/dev/null 2>&1; then
    sum=$(
      for file in "${files[@]}"; do
        printf '%s\0' "${file#"$SCRIPT_DIR"/}"
        shasum -a 256 < "$file" || exit 1
      done | shasum -a 256 | awk '{print $1}'
    ) || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  read -r sum size _ <<EOF
$({
  for file in "${files[@]}"; do
    printf '%s\0' "${file#"$SCRIPT_DIR"/}"
    cksum < "$file" || exit 1
  done
} | cksum)
EOF
  [ -n "$sum" ] && [ -n "$size" ] || return 1
  printf 'cksum:%s:%s\n' "$sum" "$size"
}

systemd_usable() {
  [ "${FM_DELIVERY_SERVICE_FORCE_BACKEND:-}" = keeper ] && return 1
  [ "${FM_DELIVERY_SERVICE_FORCE_BACKEND:-}" = systemd ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

keeper_usable() {
  command -v "$TMUX_CMD" >/dev/null 2>&1
}

select_backend() {
  if systemd_usable; then
    echo systemd
  elif keeper_usable; then
    echo keeper
  else
    echo none
  fi
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-delivery@%s.service\n' "$escaped"
}

keeper_name() {
  fm_keeper_name delivery "$FM_HOME"
}

legacy_keeper_name() {
  fm_legacy_keeper_name delivery "$FM_HOME"
}

legacy_keeper_owned() {
  local name=$1
  fm_legacy_keeper_owned_by_home "$TMUX_CMD" "$name" "$STATE/.delivery-keeper.pid" \
    "$STATE/.delivery.lock" "$FM_HOME"
}

stop_legacy_keeper() {
  local name
  FM_DELIVERY_LEGACY_STOPPED=0
  name=$(legacy_keeper_name) || return 1
  "$TMUX_CMD" has-session -t "$name" 2>/dev/null || return 0
  legacy_keeper_owned "$name" || return 0
  "$TMUX_CMD" kill-session -t "$name" || return 1
  FM_DELIVERY_LEGACY_STOPPED=1
}

systemd_env_quote() {
  local value=$1
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

# The unit template sets no PATH, so without this the listener would inherit the
# user manager's default and silently lose every tool outside it - including the
# session-backend CLI it needs to type into the captain's pane.
write_service_env() {
  local version resolved_path tmp changed=0
  version=$(delivery_source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.delivery-service.env.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_DELIVERY_EXEC=%s\n' "$(systemd_env_quote "$DELIVERY")"
    printf 'FM_DELIVERY_MANAGER=systemd\n'
    printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
    printf 'FM_DELIVERY_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_DELIVERY_ENV_CHANGED=$changed
}

service_env_matches() {
  local version resolved_path
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  version=$(delivery_source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  grep -Fx "FM_HOME=$(systemd_env_quote "$FM_HOME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_ROOT_OVERRIDE=$(systemd_env_quote "$FM_ROOT")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_STATE_OVERRIDE=$(systemd_env_quote "$STATE")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_DELIVERY_EXEC=$(systemd_env_quote "$DELIVERY")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx 'FM_DELIVERY_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "PATH=$(systemd_env_quote "$resolved_path")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_DELIVERY_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1
}

recorded_keeper_path() {
  cat "$STATE/.delivery.lock/service-path" 2>/dev/null || true
}

listener_record_matches() {
  local manager=$1 expected_version expected_path actual_manager actual_version
  expected_version=$(delivery_source_version) || return 1
  actual_manager=$(cat "$STATE/.delivery.lock/manager" 2>/dev/null || true)
  actual_version=$(cat "$STATE/.delivery.lock/source-version" 2>/dev/null || true)
  [ "$actual_manager" = "$manager" ] && [ "$actual_version" = "$expected_version" ] || return 1
  [ "$manager" = keeper ] || return 0
  expected_path=$(fm_service_path) || return 1
  [ "$(recorded_keeper_path)" = "$expected_path" ]
}

healthy_listener() {
  fm_delivery_healthy "$STATE" "$DELIVERY" "$GRACE" "$FM_HOME"
}

wait_for_healthy() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy_listener && return 0
    sleep 0.2
  done
  healthy_listener
}

stop_recorded_listener() {
  local pid i max_attempts
  pid=$(cat "$STATE/.delivery.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 0
  fm_delivery_lock_matches_pid "$STATE" "$DELIVERY" "$pid" "$FM_HOME" || return 0
  kill -TERM "$pid" 2>/dev/null || return 1
  max_attempts=$((STOP_TIMEOUT * 10))
  i=0
  while [ "$i" -lt "$max_attempts" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! fm_pid_alive "$pid"
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

ensure_systemd() {
  local unit changed=0
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "DELIVERY_UNIT: missing - approve: bin/fm-bootstrap.sh install delivery-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "DELIVERY_UNIT: disabled - approve: bin/fm-bootstrap.sh install delivery-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  FM_DELIVERY_ENV_CHANGED=0
  write_service_env || return 1
  [ "$FM_DELIVERY_ENV_CHANGED" -eq 0 ] || changed=1

  if healthy_listener && ! listener_record_matches systemd; then
    stop_recorded_listener || return 1
    changed=1
  fi
  if [ "$changed" -eq 1 ] || ! systemd_active || ! healthy_listener; then
    "$SYSTEMCTL" --user restart "$unit" || return 1
  fi
  wait_for_healthy
}

install_systemd() {
  local unit
  systemd_usable || { echo "error: systemd --user is unavailable; the tmux keeper fallback needs no install" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable --now "$unit" || return 1
  wait_for_healthy || {
    echo "error: $unit did not establish a healthy delivery listener" >&2
    return 1
  }
}

stop_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null; then
    "$TMUX_CMD" kill-session -t "$name" || return 1
  fi
  stop_legacy_keeper
}

# The resolved PATH is passed as an argument, not exported: `tmux new-session`
# runs its command under the tmux SERVER's environment, not this caller's.
start_keeper() {
  local name version resolved_path
  name=$(keeper_name) || return 1
  version=$(delivery_source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  "$TMUX_CMD" new-session -d -s "$name" "$SCRIPT_DIR/fm-delivery-keeper.sh" "$FM_HOME" "$FM_ROOT" "$STATE" "$version" "$resolved_path"
}

ensure_keeper() {
  local name
  name=$(keeper_name) || return 1
  stop_legacy_keeper || return 1
  if [ "${FM_DELIVERY_LEGACY_STOPPED:-0}" -eq 1 ]; then
    stop_recorded_listener || return 1
  fi
  if healthy_listener && listener_record_matches keeper; then
    return 0
  fi
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null; then
    stop_keeper || return 1
  fi
  if healthy_listener; then
    stop_recorded_listener || return 1
  fi
  start_keeper || return 1
  wait_for_healthy
}

restart_keeper() {
  stop_keeper || return 1
  stop_recorded_listener || return 1
  start_keeper || return 1
  wait_for_healthy
}

# Publish where this session's model turn lives, so the listener has an address
# to submit into.  Refuses rather than guessing: a listener typing into a pane
# nobody verified is worse than one that reports it has nowhere to deliver.
publish_endpoint() {
  local backend target harness session tmux_server resolved_target
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  backend=${FM_DELIVERY_ENDPOINT_BACKEND_OVERRIDE:-}
  target=${FM_DELIVERY_ENDPOINT_TARGET_OVERRIDE:-}
  if [ -z "$backend" ] || [ -z "$target" ]; then
    if ! target=$(discover_supervisor_target); then
      echo "DELIVERY_ENDPOINT: this session is not running inside a pane the listener can reach (no tmux or herdr pane in its environment); wake delivery has nowhere to submit" >&2
      return 1
    fi
    backend=$(discover_supervisor_backend) || true
  fi
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  session=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ -z "$session" ]; then
    echo "DELIVERY_ENDPOINT: no fleet lock is recorded for this home, so the endpoint would name no session; publish it from the session holding the lock" >&2
    return 1
  fi
  tmux_server=
  if [ "$backend" = tmux ]; then
    resolved_target=$(fm_tmux_resolve_pane "$target" "$TMUX_CMD") || {
      echo "DELIVERY_ENDPOINT: tmux target $target could not be proved on this session's server; no endpoint was published" >&2
      return 1
    }
    tmux_server=$("$TMUX_CMD" display-message -p -t "$resolved_target" '#{socket_path},#{pid}' 2>/dev/null) || {
      echo "DELIVERY_ENDPOINT: the tmux server for pane $resolved_target could not be identified; no endpoint was published" >&2
      return 1
    }
    fm_delivery_tmux_server_valid "$tmux_server" || {
      echo "DELIVERY_ENDPOINT: tmux returned an unusable server identity for pane $resolved_target; no endpoint was published" >&2
      return 1
    }
    target=$resolved_target
  fi
  fm_delivery_endpoint_write "$STATE" "$backend" "$target" "$harness" "$session" "$tmux_server" || {
    echo "DELIVERY_ENDPOINT: could not write the endpoint record under $STATE" >&2
    return 1
  }
  printf 'delivery endpoint published: %s pane %s (harness %s)\n' "$backend" "$target" "$harness"
}

report_recorded_path() {  # <recorded-path>
  local recorded=$1 unreachable unresolvable
  unreachable=$(fm_service_path_unreachable "$recorded")
  if [ -n "$unreachable" ]; then
    echo "DELIVERY_UNIT: the listener's recorded PATH cannot reach $(printf '%s' "$unreachable" | tr '\n' ' ' | sed 's/ $//') - it cannot submit wakes until it can"
  fi
  unresolvable=$(fm_service_path_unresolvable "$recorded")
  if [ -n "$unresolvable" ]; then
    echo "DELIVERY_UNIT: the listener's recorded PATH cannot reach $(printf '%s' "$unresolvable" | tr '\n' ' ' | sed 's/ $//'), and this session cannot resolve it either, so the recorded environment was composed without it - converge the service from a session that can reach it"
  fi
}

recorded_service_path() {
  local line
  line=$(grep -E '^PATH=' "$SERVICE_ENV" 2>/dev/null | tail -1) || return 1
  [ -n "$line" ] || return 1
  line=${line#PATH=}
  case "$line" in
    \"*\") line=${line#\"}; line=${line%\"} ;;
  esac
  printf '%s' "$line"
}

bootstrap_check() {
  local backend unit
  backend=$(select_backend)
  case "$backend" in
    systemd)
      unit=$(unit_instance) || { echo "DELIVERY_UNIT: failed to encode FM_HOME $FM_HOME"; return 0; }
      if ! systemd_installed; then
        echo "DELIVERY_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install delivery-unit"
      elif ! systemd_enabled; then
        echo "DELIVERY_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install delivery-unit"
      elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches \
          || ! systemd_active || ! healthy_listener || ! listener_record_matches systemd; then
          echo "DELIVERY_UNIT: $unit needs locked convergence from the session holding the fleet lock"
        fi
      elif ! ensure_systemd >/dev/null; then
        echo "DELIVERY_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
      fi
      if systemd_installed; then
        report_recorded_path "$(recorded_service_path 2>/dev/null || true)"
      fi
      ;;
    keeper)
      if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        healthy_listener && listener_record_matches keeper \
          || echo "DELIVERY_UNIT: systemd --user unavailable; the lock-holding session will start the tmux keeper fallback"
      elif ! ensure_keeper; then
        echo "DELIVERY_UNIT: systemd --user unavailable and the tmux keeper fallback failed"
      fi
      if [ -n "$(recorded_keeper_path)" ]; then
        report_recorded_path "$(recorded_keeper_path)"
      fi
      ;;
    *)
      echo "DELIVERY_UNIT: systemd --user is unavailable and tmux is not installed; no wake-delivery listener can be supervised here"
      ;;
  esac
}

ensure_selected() {
  case "$(select_backend)" in
    systemd) ensure_systemd ;;
    keeper) ensure_keeper ;;
    *) echo "error: no delivery service backend available" >&2; return 1 ;;
  esac
}

restart_selected() {
  local unit
  case "$(select_backend)" in
    systemd)
      if ! systemd_installed || ! systemd_enabled; then
        echo "DELIVERY_UNIT: install or enable requires approval through bin/fm-bootstrap.sh install delivery-unit" >&2
        return 2
      fi
      write_service_env || return 1
      stop_keeper 2>/dev/null || true
      unit=$(unit_instance) || return 1
      "$SYSTEMCTL" --user restart "$unit" || return 1
      wait_for_healthy
      ;;
    keeper) restart_keeper ;;
    *) echo "error: no delivery service backend available" >&2; return 1 ;;
  esac
}

repair_command() {
  local unit
  if [ "$(select_backend)" = systemd ] && unit=$(unit_instance); then
    printf 'systemctl --user restart %s\n' "$unit"
  else
    printf 'bin/fm-delivery-service.sh restart\n'
  fi
}

case "${1:-}" in
  select) select_backend ;;
  bootstrap) bootstrap_check ;;
  ensure) ensure_selected ;;
  restart) restart_selected ;;
  install-unit) install_systemd ;;
  publish-endpoint) publish_endpoint ;;
  status) fm_delivery_report "$STATE" "$DELIVERY" "$GRACE" "$FM_HOME" ;;
  repair-command) repair_command ;;
  *)
    echo "usage: $(basename "$0") {select|bootstrap|ensure|restart|install-unit|publish-endpoint|status|repair-command}" >&2
    exit 2
    ;;
esac
