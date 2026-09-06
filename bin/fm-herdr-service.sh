#!/usr/bin/env bash
# Own the supervised owner of this home's herdr runtime.
#
# Usage:
#   fm-herdr-service.sh select
#   fm-herdr-service.sh bootstrap
#   fm-herdr-service.sh ensure
#   fm-herdr-service.sh restart
#   fm-herdr-service.sh stop-owner
#   fm-herdr-service.sh install-unit
#   fm-herdr-service.sh status
#   fm-herdr-service.sh repair-command
#   fm-herdr-service.sh entrypoint-command
#
# This is the third member of the family bin/fm-watcher-service.sh and
# bin/fm-delivery-service.sh already form: the watcher owns the loop that detects
# wakes, delivery owns the listener that delivers them, and this owns the runtime
# the workers themselves live in.  A working systemd user manager selects the
# tracked fm-herdr@.service template, installed only after the captain approves
# the HERDR_RUNTIME diagnostic; where systemd is unusable a home-scoped tmux
# keeper is selected automatically through bin/fm-herdr-keeper.sh.
# bin/fm-herdr-runtime.sh is the loop both tiers run, and its header owns why
# that loop never stops a running server.
#
# THIS SERVICE IS SILENT ON A HOME THAT IS NOT RUNNING HERDR.  The backend is
# resolved once, through fm_backend_name, so a tmux home neither installs a unit
# nor reports a line about a runtime it does not have.  That resolution reads
# FM_BACKEND and config/backend and then the session's own runtime markers, which
# is why `bootstrap` belongs in a session and not in the keeper.
#
# WHAT CONVERGENCE MAY AND MAY NOT DO HERE, WHICH IS WHERE THIS DIFFERS FROM ITS
# TWO SIBLINGS.  Restarting the delivery listener costs a few seconds of queued
# wakes; restarting the herdr runtime kills every worker's agent process on the
# home at once.  So every path below converges the OWNER and never the runtime:
# a stale source version, a changed PATH, or a keeper from a previous boot is
# repaired by replacing the watching process, and the server it was watching is
# left exactly as it is.  `restart` restarts the owner for the same reason; there
# is deliberately no subcommand anywhere in this family that stops a runtime.
# docs/herdr-backend.md "Runtime ownership" owns the rollback that falls out of
# this: stopping the owner leaves the runtime running, so removing this feature
# returns the home to its previous behavior with nothing lost.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RUNTIME="$SCRIPT_DIR/fm-herdr-runtime.sh"
KEEPER="$SCRIPT_DIR/fm-herdr-keeper.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-herdr@.service"
SYSTEMCTL=${FM_HERDR_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_HERDR_SYSTEMD_ESCAPE:-systemd-escape}
TMUX_CMD=${FM_HERDR_TMUX:-${FM_TMUX_COMMAND:-tmux}}
USER_UNIT_DIR=${FM_HERDR_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-herdr@.service"
SERVICE_ENV="$STATE/.herdr-service.env"
LOCKDIR="$STATE/.herdr-runtime.lock"
RECORD="$LOCKDIR/record"
READING="$LOCKDIR/reading"
BEAT="$STATE/.last-herdr-runtime-beat"
GRACE=${FM_HERDR_GRACE:-120}
CONFIRM_TIMEOUT=${FM_HERDR_CONFIRM_TIMEOUT:-10}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=120 ;; esac
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=10 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# shellcheck source=bin/fm-keeper-name-lib.sh
. "$SCRIPT_DIR/fm-keeper-name-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# See fm-watcher-service.sh: composed values resolve tools through THIS
# process's PATH, so the home's own AXI prefix has to lead it here.
fm_axi_prepend_path "$FM_HOME"

# Is herdr the runtime this home spawns workers into?  fm_backend_name is the one
# owner of that answer; its auto-detect arm prints a notice on stderr that this
# service has no business repeating, so the notice is dropped and only the name
# is read.
home_runs_herdr() {
  [ "$(fm_backend_name 2>/dev/null)" = herdr ]
}

# The session the owner is responsible for, resolved exactly as a spawn resolves
# it (fm_backend_herdr_session), so the owner and the fleet name one server.
runtime_session() {
  printf '%s' "${FM_HERDR_RUNTIME_SESSION:-${HERDR_SESSION:-default}}"
}

source_version() {
  local file sum size
  local -a files=(
    "$RUNTIME"
    "$KEEPER"
    "$SCRIPT_DIR/fm-backend.sh"
    "$SCRIPT_DIR/backends/herdr.sh"
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
  [ "${FM_HERDR_SERVICE_FORCE_BACKEND:-}" = keeper ] && return 1
  [ "${FM_HERDR_SERVICE_FORCE_BACKEND:-}" = systemd ] && return 0
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

keeper_name() {
  fm_keeper_name herdr "$FM_HOME"
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-herdr@%s.service\n' "$escaped"
}

recorded_owner_field() {  # <key>
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -1
}

recorded_reading_field() {  # <key>
  sed -n "s/^$1=//p" "$READING" 2>/dev/null | head -1
}

# The running owner, judged by its own published record and its own beacon,
# never by a process name: a process-name test cannot tell one home's owner from
# another's on a machine that hosts several.
healthy_owner() {
  local pid age
  pid=$(recorded_owner_field pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(recorded_owner_field fm-home)" = "$FM_HOME" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -e "$BEAT" ] || return 1
  age=$(fm_path_age "$BEAT") || return 1
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -le "$GRACE" ]
}

# Does the RUNNING owner match what this session would start now?  The keeper
# tier has no environment file to compare, so its version and its PATH arrive as
# launch arguments and the record is the only evidence of what it got.  The
# service PATH has one converging owner, the session, for the reason
# bin/fm-seat-respawner-service.sh states at its own record comparison.
owner_record_matches() {  # <manager> [compare-service-path]
  local manager=$1 compare_path=${2:-0} expected_version expected_path
  expected_version=$(source_version) || return 1
  [ "$(recorded_owner_field manager)" = "$manager" ] \
    && [ "$(recorded_owner_field source-version)" = "$expected_version" ] \
    && [ "$(recorded_owner_field session)" = "$(runtime_session)" ] \
    || return 1
  [ "$manager" = keeper ] && [ "$compare_path" = 1 ] || return 0
  expected_path=$(fm_service_path) || return 1
  [ "$(recorded_owner_field service-path)" = "$expected_path" ]
}

# Converged means a live owner that has also published a reading; has_current_reading
# below owns why the second half is not optional.
wait_for_healthy() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy_owner && has_current_reading && return 0
    sleep 0.2
  done
  healthy_owner && has_current_reading
}

# Has the owner published what it saw recently enough to be this owner's own
# reading?  A started owner records itself and beats before it has looked at the
# runtime once, so a wait that ends at the beacon hands the digest an owner with
# no reading at all and lets `status` report the runtime state as unknown
# immediately after a successful convergence.  The window is the same grace the
# beacon uses, so a healthy owner mid-poll is never made to look unconverged.
has_current_reading() {
  local at age
  at=$(recorded_reading_field at)
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - at ))
  [ "$age" -ge 0 ] && [ "$age" -le "$GRACE" ]
}

# The resolved PATH is passed as an argument, not exported: `tmux new-session`
# runs its command under the tmux SERVER's environment, not this caller's.
start_keeper() {
  local name version resolved_path
  name=$(keeper_name) || return 1
  version=$(source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  "$TMUX_CMD" new-session -d -s "$name" "$KEEPER" "$FM_HOME" "$FM_ROOT" "$STATE" \
    "$version" "$resolved_path" "$(runtime_session)"
}

# Stops the WATCHING, never the runtime: the owner leaves the server running by
# construction (bin/fm-herdr-runtime.sh's cleanup), so nothing here can reach a
# worker.
stop_keeper() {
  local name
  name=$(keeper_name) || return 1
  "$TMUX_CMD" has-session -t "$name" 2>/dev/null || return 0
  "$TMUX_CMD" kill-session -t "$name" || return 1
  wait_for_owner_stop || {
    echo "HERDR_RUNTIME: the previous runtime owner did not exit after its keeper was stopped" >&2
    return 1
  }
}

# The stopped owner must actually be GONE before a replacement is started.  A
# convergence that skips this can be satisfied by the very process it just
# stopped - its record and beacon outlive it by milliseconds - and then reports
# a converged owner that is on its way out.  That is not a cosmetic race: the
# reported reading would be the dead owner's, so the digest would describe a
# runtime nothing is watching.
wait_for_owner_stop() {
  local deadline pid
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pid=$(recorded_owner_field pid)
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

ensure_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null && healthy_owner \
    && owner_record_matches keeper 1; then
    return 0
  fi
  stop_keeper || return 1
  start_keeper || return 1
  wait_for_healthy
}

restart_keeper() {
  stop_keeper || return 1
  start_keeper || return 1
  wait_for_healthy
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

# The unit template sets no PATH, so without this the owner would inherit the
# user manager's default and silently lose `herdr` itself - and an owner that
# cannot reach herdr reads the runtime as unreadable forever.
write_service_env() {
  local version resolved_path tmp
  version=$(source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$SERVICE_ENV.XXXXXX") || return 1
  {
    printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
    printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
    printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
    printf 'FM_CONFIG_OVERRIDE=%s\n' "$(systemd_env_quote "$CONFIG")"
    printf 'FM_HERDR_RUNTIME_EXEC=%s\n' "$(systemd_env_quote "$RUNTIME")"
    printf 'FM_HERDR_RUNTIME_MANAGER=systemd\n'
    printf 'FM_HERDR_RUNTIME_SESSION=%s\n' "$(systemd_env_quote "$(runtime_session)")"
    printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
    printf 'FM_HERDR_RUNTIME_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    FM_HERDR_ENV_CHANGED=1
  else
    rm -f "$tmp"
    FM_HERDR_ENV_CHANGED=0
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
    && grep -Fx "FM_HERDR_RUNTIME_EXEC=$(systemd_env_quote "$RUNTIME")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx 'FM_HERDR_RUNTIME_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_HERDR_RUNTIME_SESSION=$(systemd_env_quote "$(runtime_session)")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "PATH=$(systemd_env_quote "$resolved_path")" "$SERVICE_ENV" >/dev/null 2>&1 \
    && grep -Fx "FM_HERDR_RUNTIME_SOURCE_VERSION=$(systemd_env_quote "$version")" "$SERVICE_ENV" >/dev/null 2>&1
}

ensure_systemd() {
  local unit changed=0
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "HERDR_RUNTIME: missing - approve: bin/fm-bootstrap.sh install herdr-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "HERDR_RUNTIME: disabled - approve: bin/fm-bootstrap.sh install herdr-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    install_unit_bytes || return 1
    "$SYSTEMCTL" --user daemon-reload || return 1
    changed=1
  fi
  write_service_env || return 1
  [ "${FM_HERDR_ENV_CHANGED:-0}" -eq 0 ] || changed=1
  # Restarting the unit replaces the OWNER only; the runtime it watches keeps
  # running across it, which is what makes this convergence safe with a full
  # fleet of workers on the home.
  if [ "$changed" -eq 1 ] || ! systemd_active || ! healthy_owner; then
    "$SYSTEMCTL" --user restart "$unit" || return 1
  fi
  wait_for_healthy
}

install_systemd() {
  local unit
  systemd_usable || { echo "error: systemd --user is unavailable; the tmux keeper tier needs no install" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable --now "$unit" || return 1
  wait_for_healthy || {
    echo "error: $unit did not establish a healthy herdr runtime owner" >&2
    return 1
  }
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

# What the owner last established about the runtime, said in the digest rather
# than left in a file: an owner that is up but reading `unreadable` looks exactly
# like a healthy home from the outside, and that is the state this whole area
# exists to stop reporting as fine.
report_reading() {
  local reading note
  reading=$(recorded_reading_field reading)
  note=$(recorded_reading_field note)
  case "$reading" in
    running|'') return 0 ;;
    unreadable)
      echo "HERDR_RUNTIME: the runtime owner cannot read whether the worker runtime is running - $note"
      ;;
    down)
      echo "HERDR_RUNTIME: the worker runtime is down and the owner has not been able to start it - $note"
      ;;
    *)
      echo "HERDR_RUNTIME: the runtime owner published an unrecognized reading '$reading' - $note"
      ;;
  esac
}

bootstrap_check() {
  local unit
  home_runs_herdr || return 0
  case "$(select_backend)" in
    keeper)
      if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        healthy_owner \
          || echo "HERDR_RUNTIME: systemd --user unavailable; the lock-holding session will start the tmux keeper tier for the worker runtime"
      elif ! ensure_keeper; then
        echo "HERDR_RUNTIME: systemd --user unavailable and the tmux keeper tier failed, so nothing supervises the runtime every worker on this home runs in"
      fi
      report_reading
      return 0
      ;;
    none)
      echo "HERDR_RUNTIME: systemd --user is unavailable and tmux is not installed, so nothing can supervise the runtime every worker on this home runs in"
      return 0
      ;;
  esac
  unit=$(unit_instance) || { echo "HERDR_RUNTIME: failed to encode FM_HOME $FM_HOME"; return 0; }
  if ! systemd_installed; then
    echo "HERDR_RUNTIME: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install herdr-unit"
  elif ! systemd_enabled; then
    echo "HERDR_RUNTIME: $unit is disabled - approve: bin/fm-bootstrap.sh install herdr-unit"
  elif [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches \
      || ! systemd_active || ! healthy_owner || ! owner_record_matches systemd; then
      echo "HERDR_RUNTIME: $unit needs locked convergence from the session holding the fleet lock"
    fi
  elif ! ensure_systemd >/dev/null; then
    echo "HERDR_RUNTIME: $unit convergence failed - inspect systemctl --user status $unit"
  fi
  if systemd_installed; then
    local recorded unreachable
    recorded=$(recorded_service_path 2>/dev/null || true)
    unreachable=$(fm_service_path_unreachable "$recorded")
    [ -z "$unreachable" ] || echo "HERDR_RUNTIME: the runtime owner's recorded PATH cannot reach $(printf '%s' "$unreachable" | tr '\n' ' ' | sed 's/ $//')"
  fi
  report_reading
}

status_report() {
  local age=999999 pid backend reading
  backend=$(select_backend)
  [ -e "$BEAT" ] && age=$(fm_path_age "$BEAT")
  pid=$(recorded_owner_field pid)
  reading=$(recorded_reading_field reading)
  [ -n "$reading" ] || reading=none
  if ! home_runs_herdr; then
    printf 'not-applicable: this home does not spawn workers into herdr\n'
    return 0
  fi
  if healthy_owner; then
    printf 'up: runtime owner pid %s for session %s last beat %ss ago, runtime reading %s (%s)\n' \
      "$pid" "$(recorded_owner_field session)" "$age" "$reading" "$backend"
    [ "$reading" = running ] || return 1
    return 0
  fi
  if [ "$(recorded_owner_field fm-home)" = "$FM_HOME" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'stalled: runtime owner pid %s is alive but its beacon is %ss old (grace %ss, %s)\n' \
      "$pid" "$age" "$GRACE" "$backend"
    return 1
  fi
  printf 'down: no live runtime owner for this home (last beat %ss ago, %s)\n' "$age" "$backend"
  return 1
}

ensure_selected() {
  home_runs_herdr || { echo "this home does not spawn workers into herdr; nothing to supervise" >&2; return 0; }
  case "$(select_backend)" in
    systemd) ensure_systemd ;;
    keeper) ensure_keeper ;;
    *) echo "error: no herdr runtime service backend available" >&2; return 1 ;;
  esac
}

restart_selected() {
  case "$(select_backend)" in
    systemd)
      if ! systemd_installed || ! systemd_enabled; then
        echo "HERDR_RUNTIME: install or enable requires approval through bin/fm-bootstrap.sh install herdr-unit" >&2
        return 2
      fi
      write_service_env || return 1
      "$SYSTEMCTL" --user restart "$(unit_instance)" || return 1
      wait_for_healthy
      ;;
    keeper) restart_keeper ;;
    *) echo "error: no herdr runtime service backend available" >&2; return 1 ;;
  esac
}

# The rollback, as one command rather than as prose.  It stops the WATCHING and
# leaves the runtime running, which is the property that makes removing this
# feature free: the home returns to starting its server lazily through
# fm_backend_herdr_server_ensure exactly as it did before, with no worker
# disturbed.  It is deliberately not called by any convergence path.
stop_owner() {
  case "$(select_backend)" in
    systemd)
      systemd_installed || { echo "no herdr runtime unit is installed for this home" >&2; return 0; }
      "$SYSTEMCTL" --user disable --now "$(unit_instance)" || return 1
      ;;
    *)
      stop_keeper || return 1
      ;;
  esac
  printf 'the herdr runtime owner is stopped; the runtime itself is left running\n'
}

repair_command() {
  local unit
  if [ "$(select_backend)" = systemd ] && unit=$(unit_instance); then
    printf 'systemctl --user restart %s\n' "$unit"
  else
    printf '%s restart\n' "$SCRIPT_DIR/fm-herdr-service.sh"
  fi
}

# The one command a vessel entrypoint needs, printed rather than described, so
# the definition in the Tugboat repository can copy it verbatim.  It is
# idempotent by construction: it adopts a runtime that is already up and starts
# one that is not, and it is safe to run before any seat exists.
entrypoint_command() {
  printf 'FM_HOME=%s %s ensure\n' "$FM_HOME" "$SCRIPT_DIR/fm-herdr-service.sh"
}

case "${1:-}" in
  select) select_backend ;;
  bootstrap) bootstrap_check ;;
  ensure) ensure_selected ;;
  restart) restart_selected ;;
  stop-owner) stop_owner ;;
  install-unit) install_systemd ;;
  status) status_report ;;
  repair-command) repair_command ;;
  entrypoint-command) entrypoint_command ;;
  *)
    echo "usage: $(basename "$0") {select|bootstrap|ensure|restart|stop-owner|install-unit|status|repair-command|entrypoint-command}" >&2
    exit 2
    ;;
esac
