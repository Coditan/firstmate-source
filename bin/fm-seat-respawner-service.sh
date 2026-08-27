#!/usr/bin/env bash
# Own the per-home primary-seat respawner unit.
#
# Usage:
#   fm-seat-respawner-service.sh bootstrap
#   fm-seat-respawner-service.sh select
#   fm-seat-respawner-service.sh ensure
#   fm-seat-respawner-service.sh restart
#   fm-seat-respawner-service.sh install-unit
#   fm-seat-respawner-service.sh status
#   fm-seat-respawner-service.sh --arm
#   fm-seat-respawner-service.sh --armed
#
# A working systemd user manager selects the tracked fm-seat-respawner@.service
# template.  Installation on that tier is explicit only: bootstrap reports
# RESPAWNER_UNIT diagnostics, and bin/fm-bootstrap.sh install
# seat-respawner-unit performs the approved install.  After installation, locked
# bootstrap converges stale template bytes, environment, PATH, and source
# version for this home only.
#
# If systemd is unusable, a detached home-scoped tmux keeper is selected
# automatically, exactly as the watcher and the delivery listener already do.
# Until that tier existed this script reported "no primary-seat respawner can be
# supervised here" and stopped, which is why coditan-vessel had a restarter in
# the tree and none running when its seat died for six hours on 2026-08-27.
#
# WHAT RE-ENSURES THE RESTARTER, WHICH IS THE QUESTION A RESTARTER MUST ANSWER
# Not a seat session start.  Every keeper in this fleet is otherwise started by
# bin/fm-bootstrap.sh and therefore by a seat, so a restarter supervised that way
# is re-ensured by the very thing it exists to restart - a circle that cannot
# turn once the seat is the part that is gone.  So `--arm` installs a watcher
# check that converges the keeper tier on every watcher sweep.  The watcher
# outlives the seat, which takes the seat out of the restart path; and
# bin/fm-seat-respawner.sh revives a provably dead watcher in return, so either
# process surviving restores both.  docs/seat-absence.md owns what remains when
# neither does.
#
# The check converges the KEEPER tier only.  On a systemd home the unit template
# already carries Restart=always and bootstrap already owns its diagnostics, so
# there is nothing here for the check to add and it stays silent rather than
# repeating an install prompt every five minutes.
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
TMUX_CMD=${FM_SEAT_RESPAWNER_TMUX:-tmux}
KEEPER="$SCRIPT_DIR/fm-seat-respawner-keeper.sh"
CHECK="$STATE/seat-respawner.check.sh"
BEAT="$STATE/.last-seat-respawner-beat"
GRACE=${FM_SEAT_RESPAWNER_GRACE:-120}
CONFIRM_TIMEOUT=${FM_SEAT_RESPAWNER_CONFIRM_TIMEOUT:-10}
STALE=${FM_SEAT_RESPAWNER_ARMED_STALE:-1800}
NOW=${FM_SEAT_RESPAWNER_NOW:-$(date +%s)}
case "$GRACE" in ''|*[!0-9]*) GRACE=120 ;; esac
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=10 ;; esac
case "$STALE" in ''|*[!0-9]*) STALE=1800 ;; esac
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

# shellcheck source=bin/fm-keeper-name-lib.sh
. "$SCRIPT_DIR/fm-keeper-name-lib.sh"
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
    "$KEEPER"
    "$SCRIPT_DIR/fm-seat-stay-down.sh"
    "$SCRIPT_DIR/fm-delivery-lib.sh"
    "$SCRIPT_DIR/fm-service-path-lib.sh"
    "$SCRIPT_DIR/fm-wake-lib.sh"
    "$SCRIPT_DIR/fm-operational-input.sh"
    "$SCRIPT_DIR/fm-backend.sh"
    "$SCRIPT_DIR/fm-pane-activity-lib.sh"
    "$SCRIPT_DIR/fm-harness-pid-lib.sh"
    "$SCRIPT_DIR/fm-seat-presence-lib.sh"
    # The typing path, listed for the same reason watch_source_version lists it:
    # fm_backend_composer_state dispatches into fm-tmux-lib.sh, which classifies
    # through fm-composer-lib.sh, and both the existence probe and the submit go
    # through fm_backend_source tmux into backends/.  A convergence check blind
    # to those would keep a keeper typing into panes with the pre-update rule for
    # what an affirmatively empty agent composer is.
    "$SCRIPT_DIR/fm-tmux-lib.sh"
    "$SCRIPT_DIR/fm-composer-lib.sh"
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
  sum=$(
    for file in "${files[@]}"; do
      printf '%s\0' "${file#"$SCRIPT_DIR"/}"
      cksum < "$file" || exit 1
    done | cksum | awk '{print $1 ":" $2}'
  ) || return 1
  printf 'cksum:%s\n' "$sum"
}

systemd_usable() {
  [ "${FM_SEAT_RESPAWNER_FORCE_BACKEND:-}" = keeper ] && return 1
  [ "${FM_SEAT_RESPAWNER_FORCE_BACKEND:-}" = systemd ] && return 0
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
  fm_keeper_name seat-respawner "$FM_HOME"
}

# One field of the running respawner's own published lock record.
recorded_respawner_field() {  # <key>
  sed -n "s/^$1=//p" "$STATE/.seat-respawner.lock/record" 2>/dev/null | head -1
}

# Does the RUNNING respawner match what this session would start now?  The
# keeper tier has no environment file to compare, so its version and its PATH
# arrive as launch arguments and the lock record is the only evidence of what it
# actually got.  Without this comparison the tier would never reconverge: a home
# would keep running the bytes it started with after every self-update, silently
# and indefinitely, which on a container with no systemd is every home.
# Mirrors watcher_record_matches in bin/fm-watcher-service.sh.
#
# The recorded service PATH has ONE converging owner, and it is the session, not
# the watcher-hosted check.  fm_service_path resolves tools with the CALLER's
# PATH by design, so two managers running in different environments would each
# read the other's recorded value as drift and stop-and-start the keeper on every
# sweep and every session start.  Manager and source version are composed
# identically wherever they are asked, so both tiers may compare those; only the
# environment-dependent field is asked by the session alone, which is also the
# only place a poorly-reaching PATH can be diagnosed and repaired.
respawner_record_matches() {  # <manager> [compare-service-path]
  local manager=$1 compare_path=${2:-0} expected_version expected_path
  expected_version=$(source_version) || return 1
  [ "$(recorded_respawner_field manager)" = "$manager" ] \
    && [ "$(recorded_respawner_field source-version)" = "$expected_version" ] \
    || return 1
  [ "$manager" = keeper ] && [ "$compare_path" = 1 ] || return 0
  expected_path=$(fm_service_path) || return 1
  [ "$(recorded_respawner_field service-path)" = "$expected_path" ]
}

# The running respawner, judged by its own published lock and its own beacon -
# never by a process name.  A process-name test cannot tell one home's respawner
# from another's, and on this fleet's container it could not tell the seat from
# its crew either, which is the mistake this whole area exists to stop making.
healthy_respawner() {
  local pid age
  pid=$(recorded_respawner_field pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(recorded_respawner_field fm-home)" = "$FM_HOME" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -e "$BEAT" ] || return 1
  age=$(fm_path_age "$BEAT") || return 1
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -le "$GRACE" ]
}

# The resolved PATH is passed as an argument, not exported, for the reason
# bin/fm-watcher-service.sh states at its own start_keeper: `tmux new-session`
# runs its command under the tmux SERVER's environment, not this caller's.
start_keeper() {
  local name version resolved_path
  name=$(keeper_name) || return 1
  version=$(source_version) || return 1
  resolved_path=$(fm_service_path) || return 1
  mkdir -p "$STATE" || return 1
  "$TMUX_CMD" new-session -d -s "$name" "$KEEPER" "$FM_HOME" "$FM_ROOT" "$STATE" "$version" "$resolved_path"
}

stop_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null; then
    "$TMUX_CMD" kill-session -t "$name" || return 1
  fi
}

# A started SESSION is not a started respawner: `tmux new-session` returns as
# soon as the window exists, and a respawner that dies immediately in it - a
# $STATE it cannot write, a service PATH that cannot reach bash - would leave
# every caller free to report a restoration that did not hold. The watcher's own
# ensure_keeper ends the same way, for the same reason.
wait_for_healthy() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy_respawner && return 0
    sleep 0.2
  done
  healthy_respawner
}

ensure_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null && healthy_respawner \
    && respawner_record_matches keeper 1; then
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
    printf 'FM_SEAT_RESPAWNER_MANAGER=systemd\n'
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
    && grep -Fx 'FM_SEAT_RESPAWNER_MANAGER=systemd' "$SERVICE_ENV" >/dev/null 2>&1 \
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
  case "$(select_backend)" in
    keeper)
      # Converged here as well as from the watcher check, so a home gets its
      # restarter at session start rather than waiting for the next sweep; the
      # check is what keeps it running once the seat is gone.
      if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
        healthy_respawner \
          || echo "RESPAWNER_UNIT: systemd --user unavailable; the lock-holding session will start the tmux keeper fallback"
      elif ! ensure_keeper; then
        echo "RESPAWNER_UNIT: systemd --user unavailable and the tmux keeper fallback failed, so nothing would restart this vessel's first mate if it stopped"
      fi
      return 0 ;;
    none)
      echo "RESPAWNER_UNIT: systemd --user is unavailable and tmux is not installed, so nothing can restart this vessel's first mate if it stops"
      return 0 ;;
  esac
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

# `up:` is composed into a sentence the captain reads on his phone during an
# outage - bin/fm-seat-alarm.sh's restarter_clause turns it into "an automatic
# restart is running and should bring it back on its own" - so it may only be
# printed for the same reading healthy_respawner takes, beacon and home
# included. A live pid that has stopped cycling gets its own `stalled:` prefix,
# as bin/fm-delivery-lib.sh already gives the listener; every reader that is not
# looking for `up:` or `down:` reads it as unknown, which is the honest answer.
status_report() {
  local age=999999 pid backend
  backend=$(select_backend)
  [ -e "$BEAT" ] && age=$(fm_path_age "$BEAT")
  pid=$(recorded_respawner_field pid)
  if healthy_respawner; then
    printf 'up: respawner pid %s last beat %ss ago (%s)\n' "$pid" "$age" "$backend"
  elif [ "$(recorded_respawner_field fm-home)" = "$FM_HOME" ] \
    && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'stalled: respawner pid %s is alive but its beacon is %ss old (grace %ss, %s)\n' \
      "$pid" "$age" "$GRACE" "$backend"
  else
    printf 'down: no live respawner lock for this home (last beat %ss ago, %s)\n' "$age" "$backend"
  fi
}

# The watcher-hosted convergence check.  This is the piece that takes the seat
# out of the restart path: the shim runs every watcher sweep, so the keeper tier
# is re-ensured by a process that outlives the seat rather than by a session that
# cannot start while the seat is gone.
arm_check() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-seat-respawner-service.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This one converges the primary-seat restarter, silently when it is already
# running, so the restarter does not depend on a seat session start to exist.
export FM_HOME="$FM_HOME"
export FM_ROOT_OVERRIDE="$FM_ROOT"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
exec "$SCRIPT_DIR/fm-seat-respawner-service.sh" converge
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    umask 077
    tmp=$(mktemp "$STATE/.fm-seat-respawner-check.XXXXXX") || return 1
    printf '%s\n' "$desired" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" seat-respawner >/dev/null || return 1
}

# Always exit 0: the watcher reads the line, not the status.  Silent while the
# restarter is running, and silent on the systemd tier, which bootstrap owns.
converge() {
  local stale=0
  [ "${FM_SEAT_RESPAWNER_DISABLE:-0}" = 1 ] && return 0
  case "$(select_backend)" in
    keeper)
      if healthy_respawner; then
        respawner_record_matches keeper && return 0
        # Running, and not what this home would start now.  A restarter left on
        # pre-update bytes is the half of a restart that silently stops being a
        # restoration, so it is converged and said out loud rather than counted
        # as healthy because something with the right name is alive.
        stale=1
      fi
      if ensure_keeper; then
        if [ "$stale" -eq 1 ]; then
          echo "seat-respawner: the automatic restart for this vessel's first mate was running an out-of-date copy and has been restarted on the current one"
        else
          echo "seat-respawner: the automatic restart for this vessel's first mate had stopped and has been started again"
        fi
      else
        echo "seat-respawner: the automatic restart for this vessel's first mate is not running and could not be started, so nothing would bring it back if it stopped"
      fi
      ;;
    none)
      echo "seat-respawner: nothing on this vessel can restart its first mate if it stops (no service manager and no tmux)"
      ;;
  esac
  return 0
}

armed_diagnostic() {
  local mtime age
  [ "${FM_SEAT_RESPAWNER_DISABLE:-0}" = 1 ] && return 0
  [ "$(select_backend)" = keeper ] || return 0
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'RESPAWNER_UNIT: nothing keeps this vessel'"'"'s first-mate restart running between sessions, so it would stop with the next one that ends (fix: %s/fm-seat-respawner-service.sh --arm)\n' \
      "$SCRIPT_DIR"
    return 0
  fi
  # A beacon that was never created is the state this whole area exists to
  # remove - a restarter in the tree and never once running - so it is read from
  # the check's own mtime and reported, exactly as bin/fm-seat-alarm.sh reports
  # its never-evaluated case, rather than being the one state that stays silent.
  if [ ! -e "$BEAT" ]; then
    mtime=$(stat -c %Y "$CHECK" 2>/dev/null) || return 0
    age=$((NOW - mtime))
    [ "$age" -gt "$STALE" ] &&
      printf 'RESPAWNER_UNIT: this vessel'"'"'s first-mate restart was armed %ss ago and has never run, so nothing would bring the first mate back if it stopped now (fix: %s/fm-seat-respawner-service.sh restart)\n' \
        "$age" "$SCRIPT_DIR"
    return 0
  fi
  mtime=$(stat -c %Y "$BEAT" 2>/dev/null) || return 0
  age=$((NOW - mtime))
  [ "$age" -gt "$STALE" ] &&
    printf 'RESPAWNER_UNIT: this vessel'"'"'s first-mate restart last ran %ss ago and has stopped, so nothing would bring the first mate back if it stopped now (fix: %s/fm-seat-respawner-service.sh restart)\n' \
      "$age" "$SCRIPT_DIR"
  return 0
}

ensure_selected() {
  case "$(select_backend)" in
    systemd) ensure_systemd ;;
    keeper) ensure_keeper ;;
    *) echo "error: no seat-respawner service backend available" >&2; return 1 ;;
  esac
}

restart_selected() {
  case "$(select_backend)" in
    systemd)
      write_service_env || return 1
      "$SYSTEMCTL" --user restart "$(unit_instance)"
      ;;
    keeper) restart_keeper ;;
    *) echo "error: no seat-respawner service backend available" >&2; return 1 ;;
  esac
}

case "${1:-}" in
  bootstrap) bootstrap_check ;;
  select) select_backend ;;
  ensure) ensure_selected ;;
  converge) converge ;;
  restart) restart_selected ;;
  install-unit) install_systemd ;;
  status) status_report ;;
  --arm|arm)
    arm_check || { printf 'fm-seat-respawner-service: cannot arm the restart watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    ;;
  --armed|armed) armed_diagnostic ;;
  *)
    echo "usage: $(basename "$0") {bootstrap|select|ensure|converge|restart|install-unit|status|--arm|--armed}" >&2
    exit 2
    ;;
esac
