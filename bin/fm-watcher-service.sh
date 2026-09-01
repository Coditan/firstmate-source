#!/usr/bin/env bash
# Own the external firstmate watcher loop for one FM_HOME.
#
# Usage:
#   fm-watcher-service.sh select
#   fm-watcher-service.sh bootstrap
#   fm-watcher-service.sh ensure
#   fm-watcher-service.sh restart
#   fm-watcher-service.sh install-unit
#   fm-watcher-service.sh enable-linger
#   fm-watcher-service.sh repair-command
#
# A working systemd user manager selects the tracked fm-watch@.service template.
# First installation and enablement happen only through install-unit after the
# captain approves the WATCHER_UNIT bootstrap diagnostic.  An already-installed
# unit converges its tracked bytes, per-home environment, source version, and
# running process automatically at a locked bootstrap boundary.  If systemd is
# unusable, a detached home-scoped tmux keeper is selected automatically.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-watch@.service"
SYSTEMCTL=${FM_WATCH_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_WATCH_SYSTEMD_ESCAPE:-systemd-escape}
TMUX=${FM_WATCH_TMUX:-tmux}
USER_UNIT_DIR=${FM_WATCH_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-watch@.service"
SERVICE_ENV="$STATE/.watch-service.env"
GRACE=${FM_GUARD_GRACE:-300}
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
STOP_TIMEOUT=${FM_WATCH_STOP_TIMEOUT:-20}
case "$STOP_TIMEOUT" in ''|*[!0-9]*|0) STOP_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-keeper-name-lib.sh
. "$SCRIPT_DIR/fm-keeper-name-lib.sh"
# Composed values resolve tools through THIS process's PATH, so the home's own
# AXI prefix has to lead it here or the service would be handed whichever older
# copy the launching session happened to resolve.
fm_axi_prepend_path "$FM_HOME"

watch_source_version() {
  local file sum size
  local -a files=(
    "$WATCH"
    "$SCRIPT_DIR/fm-wake-lib.sh"
    "$SCRIPT_DIR/fm-bridge-inbox-lib.sh"
    "$SCRIPT_DIR/fm-bounded-lib.sh"
    "$SCRIPT_DIR/fm-classify-lib.sh"
    "$SCRIPT_DIR/fm-backend.sh"
    "$SCRIPT_DIR/fm-transition-lib.sh"
    "$SCRIPT_DIR/fm-pr-lib.sh"
    "$SCRIPT_DIR/fm-x-lib.sh"
    "$SCRIPT_DIR/fm-check-lib.sh"
    "$SCRIPT_DIR/fm-tmux-lib.sh"
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

x_mode_version() {
  local file="$FM_HOME/config/x-mode.env" sum size
  [ -f "$file" ] || { echo absent; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
    printf 'sha256:%s\n' "$sum"
    return
  fi
  read -r sum size _ <<EOF
$(cksum "$file" 2>/dev/null)
EOF
  [ -n "$sum" ] && [ -n "$size" ] || return 1
  printf 'cksum:%s:%s\n' "$sum" "$size"
}

systemd_usable() {
  [ "${FM_WATCH_SERVICE_FORCE_BACKEND:-}" = keeper ] && return 1
  [ "${FM_WATCH_SERVICE_FORCE_BACKEND:-}" = systemd ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

keeper_usable() {
  command -v "$TMUX" >/dev/null 2>&1
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
  printf 'fm-watch@%s.service\n' "$escaped"
}

keeper_name() {
  fm_keeper_name watch "$FM_HOME"
}

legacy_keeper_name() {
  fm_legacy_keeper_name watch "$FM_HOME"
}

legacy_keeper_owned() {
  local name=$1
  fm_legacy_keeper_owned_by_home "$TMUX" "$name" "$STATE/.watch-keeper.pid" \
    "$STATE/.watch.lock" "$FM_HOME"
}

stop_legacy_keeper() {
  local name
  FM_WATCH_LEGACY_STOPPED=0
  name=$(legacy_keeper_name) || return 1
  "$TMUX" has-session -t "$name" 2>/dev/null || return 0
  legacy_keeper_owned "$name" || return 0
  "$TMUX" kill-session -t "$name" || return 1
  FM_WATCH_LEGACY_STOPPED=1
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

# The unit template sets no PATH, so without this line the watcher would inherit
# systemd's user-manager default and silently lose every tool outside it (see
# bin/fm-service-path-lib.sh for the verified failure).  Recorded here rather
# than in the unit because the tool locations are per-deployment, and compared by
# service_env_matches so a home whose toolchain moved reconverges and restarts.
write_service_env() {
  local version x_version resolved_path tmp changed=0
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.watch-service.env.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_WATCH_EXEC=%s\n' "$(systemd_env_quote "$WATCH")"
    printf 'FM_WATCH_MANAGER=systemd\n'
    printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
    printf 'FM_WATCH_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
    printf 'FM_WATCH_X_MODE_VERSION=%s\n' "$(systemd_env_quote "$x_version")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_WATCH_ENV_CHANGED=$changed
}

service_env_matches() {
  local version x_version resolved_path
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  grep -Fx "FM_HOME=$(systemd_env_quote "$FM_HOME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_ROOT_OVERRIDE=$(systemd_env_quote "$FM_ROOT")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_STATE_OVERRIDE=$(systemd_env_quote "$STATE")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_EXEC=$(systemd_env_quote "$WATCH")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx 'FM_WATCH_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "PATH=$(systemd_env_quote "$resolved_path")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_WATCH_X_MODE_VERSION=$(systemd_env_quote "$x_version")" "$SERVICE_ENV" >/dev/null 2>&1
}

# The PATH the INSTALLED service will actually run with, read back from the file
# systemd loads rather than recomputed - the question "can the running watcher
# reach its own tools" must not be answered from the asking session's reach.
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

# The PATH the RUNNING keeper was launched with, as the watcher itself recorded
# it.  The systemd tier has no equivalent because its PATH lives in the compared
# service environment file; a keeper receives it as a launch argument, so the
# record the watcher writes is the only evidence of what it actually got.
recorded_keeper_path() {
  cat "$STATE/.watch.lock/service-path" 2>/dev/null || true
}

watcher_record_matches() {
  local manager=$1 expected_version expected_x_version expected_path actual_manager actual_version actual_x_version
  expected_version=$(watch_source_version) || return 1
  expected_x_version=$(x_mode_version) || return 1
  actual_manager=$(cat "$STATE/.watch.lock/manager" 2>/dev/null || true)
  actual_version=$(cat "$STATE/.watch.lock/source-version" 2>/dev/null || true)
  actual_x_version=$(cat "$STATE/.watch.lock/x-mode-version" 2>/dev/null || true)
  [ "$actual_manager" = "$manager" ] \
    && [ "$actual_version" = "$expected_version" ] \
    && [ "$actual_x_version" = "$expected_x_version" ] \
    || return 1
  # Compared for the keeper only, and for the same reason service_env_matches
  # compares the systemd tier's recorded PATH: a home whose toolchain moves must
  # reconverge and restart rather than keep running with a stale environment
  # until some unrelated source-version change happens to notice.  Without it the
  # two tiers are only at parity for whichever rollout also changed the watcher's
  # own bytes.
  [ "$manager" = keeper ] || return 0
  expected_path=$(fm_service_path) || return 1
  [ "$(recorded_keeper_path)" = "$expected_path" ]
}

healthy_watcher() {
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"
}

wait_for_healthy() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy_watcher && return 0
    sleep 0.2
  done
  healthy_watcher
}

stop_recorded_watcher() {
  local pid i max_attempts
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 0
  fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$pid" "$FM_HOME" || return 0
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
    echo "WATCHER_UNIT: missing - approve: bin/fm-bootstrap.sh install watcher-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "WATCHER_UNIT: disabled - approve: bin/fm-bootstrap.sh install watcher-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  FM_WATCH_ENV_CHANGED=0
  write_service_env || return 1
  [ "$FM_WATCH_ENV_CHANGED" -eq 0 ] || changed=1

  if healthy_watcher && ! watcher_record_matches systemd; then
    stop_recorded_watcher || return 1
    changed=1
  fi
  if [ "$changed" -eq 1 ] || ! systemd_active || ! healthy_watcher; then
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
    echo "error: $unit did not establish a healthy watcher" >&2
    return 1
  }
}

stop_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX" has-session -t "$name" 2>/dev/null; then
    "$TMUX" kill-session -t "$name" || return 1
  fi
  stop_legacy_keeper
}

# The resolved PATH is passed as an argument, not exported: `tmux new-session`
# runs its command under the tmux SERVER's environment, not this caller's, so a
# server started long ago from a stripped context would hand the keeper exactly
# the defect the systemd side just fixed.  An argument is the only channel that
# reaches the keeper regardless of who started the server.
start_keeper() {
  local name version x_version resolved_path
  name=$(keeper_name) || return 1
  version=$(watch_source_version) || return 1
  x_version=$(x_mode_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  "$TMUX" new-session -d -s "$name" "$SCRIPT_DIR/fm-watch-keeper.sh" "$FM_HOME" "$FM_ROOT" "$STATE" "$version" "$x_version" "$resolved_path"
}

ensure_keeper() {
  local name
  name=$(keeper_name) || return 1
  stop_legacy_keeper || return 1
  if [ "${FM_WATCH_LEGACY_STOPPED:-0}" -eq 1 ]; then
    stop_recorded_watcher || return 1
  fi
  if healthy_watcher && watcher_record_matches keeper; then
    return 0
  fi
  if "$TMUX" has-session -t "$name" 2>/dev/null; then
    stop_keeper || return 1
  fi
  if healthy_watcher; then
    stop_recorded_watcher || return 1
  fi
  start_keeper || return 1
  wait_for_healthy
}

restart_keeper() {
  stop_keeper || return 1
  stop_recorded_watcher || return 1
  start_keeper || return 1
  wait_for_healthy
}

linger_enabled() {
  command -v loginctl >/dev/null 2>&1 || return 1
  [ "$(loginctl show-user "${FM_WATCH_USER_NAME:-$(id -un)}" -p Linger --value 2>/dev/null || true)" = yes ]
}

# Report what the environment the watcher ACTUALLY runs with cannot reach, asked
# of the recorded value rather than recomputed - the question "can the running
# watcher reach its own tools" must not be answered from the asking session's
# reach.  A watcher that cannot resolve its own tools does not fail; it answers
# "no state available" for every crew, which is why this has to be stated rather
# than waited for.
#
# Two sentences, because the two conditions have different owners and different
# repairs: a tool this session CAN reach is fixed by converging the service from
# here, while one this session cannot reach means the recorded value was composed
# blind and no convergence from this session can improve it.  Emitted for both
# tiers, because a keeper-backed home running blind says exactly as little as a
# systemd-backed one.
report_recorded_path() {  # <recorded-path>
  local recorded=$1 unreachable unresolvable
  unreachable=$(fm_service_path_unreachable "$recorded")
  if [ -n "$unreachable" ]; then
    echo "WATCHER_UNIT: the watcher's recorded PATH cannot reach $(printf '%s' "$unreachable" | tr '\n' ' ' | sed 's/ $//') - crew state will read as unavailable until it can"
  fi
  unresolvable=$(fm_service_path_unresolvable "$recorded")
  if [ -n "$unresolvable" ]; then
    echo "WATCHER_UNIT: the watcher's recorded PATH cannot reach $(printf '%s' "$unresolvable" | tr '\n' ' ' | sed 's/ $//'), and this session cannot resolve it either, so the recorded environment was composed without it - crew state will read as unavailable until a session that can reach it converges the service"
  fi
}

bootstrap_check() {
  local backend unit changed=0
  backend=$(select_backend)
  case "$backend" in
    systemd)
      unit=$(unit_instance) || { echo "WATCHER_UNIT: failed to encode FM_HOME $FM_HOME"; return 0; }
      if ! systemd_installed; then
        echo "WATCHER_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install watcher-unit"
      elif ! systemd_enabled; then
        echo "WATCHER_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install watcher-unit"
      elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches \
          || ! systemd_active || ! healthy_watcher || ! watcher_record_matches systemd; then
          echo "WATCHER_UNIT: $unit needs locked convergence from the session holding the fleet lock"
        fi
      elif ! ensure_systemd >/dev/null; then
        echo "WATCHER_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
      fi
      # Asked after any convergence above, so it reports what the running
      # service can actually reach.
      if systemd_installed; then
        report_recorded_path "$(recorded_service_path 2>/dev/null || true)"
      fi
      if ! linger_enabled; then
        echo "WATCHER_UNIT: user lingering is disabled - approve: bin/fm-bootstrap.sh install watcher-linger"
      fi
      ;;
    keeper)
      if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        healthy_watcher && watcher_record_matches keeper \
          || echo "WATCHER_UNIT: systemd --user unavailable; the lock-holding session will start the tmux keeper fallback"
      elif ! ensure_keeper; then
        echo "WATCHER_UNIT: systemd --user unavailable and the tmux keeper fallback failed"
      fi
      # Same question, same wording, asked of the keeper's own record.  Skipped
      # when there is no record at all, because "no keeper is running" is the
      # branch above's sentence to say, not this one's.
      if [ -n "$(recorded_keeper_path)" ]; then
        report_recorded_path "$(recorded_keeper_path)"
      fi
      ;;
    *)
      echo "WATCHER_UNIT: systemd --user is unavailable and tmux is not installed; no watcher keeper is available"
      ;;
  esac
}

ensure_selected() {
  case "$(select_backend)" in
    systemd) ensure_systemd ;;
    keeper) ensure_keeper ;;
    *) echo "error: no watcher service backend available" >&2; return 1 ;;
  esac
}

restart_selected() {
  local unit
  case "$(select_backend)" in
    systemd)
      if ! systemd_installed || ! systemd_enabled; then
        echo "WATCHER_UNIT: install or enable requires approval through bin/fm-bootstrap.sh install watcher-unit" >&2
        return 2
      fi
      write_service_env || return 1
      stop_keeper 2>/dev/null || true
      unit=$(unit_instance) || return 1
      "$SYSTEMCTL" --user restart "$unit" || return 1
      wait_for_healthy
      ;;
    keeper) restart_keeper ;;
    *) echo "error: no watcher service backend available" >&2; return 1 ;;
  esac
}

repair_command() {
  local unit
  if [ "$(select_backend)" = systemd ] && unit=$(unit_instance); then
    printf 'systemctl --user restart %s\n' "$unit"
  else
    printf 'bin/fm-watcher-service.sh restart\n'
  fi
}

case "${1:-}" in
  select) select_backend ;;
  bootstrap) bootstrap_check ;;
  ensure) ensure_selected ;;
  restart) restart_selected ;;
  install-unit) install_systemd ;;
  enable-linger)
    command -v loginctl >/dev/null 2>&1 || { echo "error: loginctl is unavailable" >&2; exit 1; }
    loginctl enable-linger "${FM_WATCH_USER_NAME:-$(id -un)}"
    ;;
  repair-command) repair_command ;;
  *)
    echo "usage: $(basename "$0") {select|bootstrap|ensure|restart|install-unit|enable-linger|repair-command}" >&2
    exit 2
    ;;
esac
