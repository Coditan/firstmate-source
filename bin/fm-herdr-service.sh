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
case "$GRACE" in ''|*[!0-9]*|0) GRACE=120 ;; esac
# The deadline the OWNER puts on one status read.  This session does not merely
# read it, it PASSES IT ON to whichever tier starts the owner - an environment
# file line for the unit, a launch argument for the keeper - so the owner runs
# with exactly the value the convergence wait below was sized from.
STATUS_TIMEOUT=${FM_HERDR_RUNTIME_STATUS_TIMEOUT:-10}
case "$STATUS_TIMEOUT" in ''|*[!0-9]*|0) STATUS_TIMEOUT=10 ;; esac
# IF YOU ARE TUNING EITHER OF THESE TWO NUMBERS, THIS IS THE RELATIONSHIP THEY
# HAVE.  A converging session waits CONFIRM_TIMEOUT for the owner it just started
# to publish its first reading, and the first thing that owner does is one
# bounded status read of at most STATUS_TIMEOUT.  So the convergence wait must
# OUTLAST one such read, with margin for the tier's own startup - if the wait is
# the shorter of the two, convergence times out INSIDE the owner's first read and
# then reports the wrong fault: it says the tier failed and nothing supervises the
# runtime, while the keeper and its owner are both running and about to publish a
# perfectly good `unreadable` reading about the wedged client that caused the slow
# read in the first place.  The margin is what the default carries; an override
# that loses the relationship is said out loud rather than silently obeyed.
CONVERGE_MARGIN=15
CONFIRM_TIMEOUT=${FM_HERDR_CONFIRM_TIMEOUT:-$(( STATUS_TIMEOUT + CONVERGE_MARGIN ))}
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=$(( STATUS_TIMEOUT + CONVERGE_MARGIN )) ;; esac
if [ "$CONFIRM_TIMEOUT" -le "$STATUS_TIMEOUT" ]; then
  echo "HERDR_RUNTIME: FM_HERDR_CONFIRM_TIMEOUT (${CONFIRM_TIMEOUT}s) is not longer than the owner's status read deadline (${STATUS_TIMEOUT}s), so convergence would time out inside the owner's first read and report a failed tier instead of what the owner saw; using $(( STATUS_TIMEOUT + CONVERGE_MARGIN ))s" >&2
  CONFIRM_TIMEOUT=$(( STATUS_TIMEOUT + CONVERGE_MARGIN ))
fi

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
    "$version" "$resolved_path" "$(runtime_session)" "$STATUS_TIMEOUT"
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

# The keeper is not the only thing that can be holding a live owner, so stopping
# the keeper is not enough to guarantee exactly one.  A keeper killed outright -
# SIGKILL, a lost container, a torn-down pane - leaves its owner child alive and
# reparented to init, and stop_keeper returns 0 the moment `has-session` is
# false without ever looking at it.  A convergence that then starts a second
# owner gets two processes writing $RECORD, $BEAT and $READING every poll: the
# record flaps between them, every locked bootstrap sees an unconverged owner
# and restarts the keeper again, and on a genuinely down runtime both race to
# start a server.  So convergence stops the owner it is about to REPLACE, judged
# by the record's own identity so a recycled pid is never signalled.
#
# This stops the WATCHING only.  The owner leaves the runtime running by
# construction (bin/fm-herdr-runtime.sh's cleanup), so nothing here reaches a
# worker - the asymmetry this whole service is built around holds.
recorded_owner_alive() {
  local pid identity recorded_identity
  pid=$(recorded_owner_field pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(recorded_owner_field fm-home)" = "$FM_HOME" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_identity=$(recorded_owner_field pid-identity)
  [ -n "$recorded_identity" ] || return 0
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fm_pid_incarnation_matches_record "$identity" "$recorded_identity"
}

stop_recorded_owner() {
  local pid
  recorded_owner_alive || return 0
  pid=$(recorded_owner_field pid)
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_owner_stop || {
    echo "HERDR_RUNTIME: the recorded runtime owner (pid $pid) did not exit when it was replaced" >&2
    return 1
  }
}

# THE SINGLE OWNER OF "make room for the owner this path is about to leave in
# place".  EVERY path in this file that ends or replaces the watching calls this
# and nothing else - ensure_keeper and restart_keeper on the keeper tier,
# ensure_systemd, install_systemd, restart_selected's systemd arm and stop_owner
# on the other.  The sequence is two steps and the order is load-bearing: the
# keeper goes first, because its respawn loop puts a new owner back two seconds
# after any stop, so stopping the owner first only buys two seconds.
#
# It is one function because this file has spent four review rounds proving the
# alternative: each round added the pair to the call sites it could see and the
# next round found the one it had missed.  A guard that holds at some of its call
# sites is worse than no guard at all, because the next reader trusts the
# property it claims.  Add a fifth path and it calls this; do not open-code
# either half.
#
# A stop that did not take fails here rather than being swallowed.  Carrying on
# past a keeper that is still alive is exactly how a path ends with two owners:
# the survivor respawns its own while the caller starts another beside it.
#
# Both steps stop the WATCHING only.  An owner leaves the runtime running by
# construction (bin/fm-herdr-runtime.sh's cleanup), so nothing here reaches a
# worker - the asymmetry this whole service is built around holds.
#
# <manager> names the tier whose own owner may stay; omit it to leave none, which
# is what the keeper tier and the rollback both need.  FM_HERDR_OWNER_CLEARED
# reports whether a live one was actually stopped, for a caller that must then
# restart what it displaced.
clear_replaced_owner() {  # [manager-whose-owner-may-stay]
  local keep=${1:-}
  FM_HERDR_OWNER_CLEARED=0
  stop_keeper || return 1
  [ -n "$keep" ] && owner_record_matches "$keep" && return 0
  recorded_owner_alive || return 0
  stop_recorded_owner || return 1
  FM_HERDR_OWNER_CLEARED=1
  return 0
}

ensure_keeper() {
  local name
  name=$(keeper_name) || return 1
  if "$TMUX_CMD" has-session -t "$name" 2>/dev/null && healthy_owner \
    && owner_record_matches keeper 1; then
    return 0
  fi
  restart_keeper
}

restart_keeper() {
  clear_replaced_owner || return 1
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
    printf 'FM_HERDR_RUNTIME_STATUS_TIMEOUT=%s\n' "$(systemd_env_quote "$STATUS_TIMEOUT")"
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
    && grep -Fx "FM_HERDR_RUNTIME_STATUS_TIMEOUT=$(systemd_env_quote "$STATUS_TIMEOUT")" "$SERVICE_ENV" >/dev/null 2>&1 \
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
  clear_replaced_owner systemd || return 1
  [ "${FM_HERDR_OWNER_CLEARED:-0}" -eq 0 ] || changed=1
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
  home_runs_herdr || { echo "this home does not spawn workers into herdr; nothing to install" >&2; return 1; }
  systemd_usable || { echo "error: systemd --user is unavailable; the tmux keeper tier needs no install" >&2; return 1; }
  unit=$(unit_instance) || return 1
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  clear_replaced_owner systemd || return 1
  "$SYSTEMCTL" --user enable --now "$unit" || return 1
  wait_for_healthy || {
    echo "error: $unit did not establish a healthy herdr runtime owner" >&2
    return 1
  }
}

# The PATH the keeper tier's owner was actually launched with, read from the
# owner's own record - the keeper receives it as a launch argument, so the record
# is the only evidence of what it got.
recorded_keeper_path() {
  recorded_owner_field service-path
}

# Report what the environment the OWNER actually runs with cannot reach, asked of
# the recorded value rather than recomputed, exactly as bin/fm-watcher-service.sh
# does: the question "can the running owner reach its own tools" must not be
# answered from the asking session's reach.
#
# Two sentences, because the two conditions have different owners and different
# repairs: a tool this session CAN reach is fixed by converging the service from
# here, while one this session cannot reach means the recorded value was composed
# blind and no convergence from this session can improve it.  Emitted for both
# tiers - the keeper tier is the one this vessel actually runs, and the
# unresolvable half is the one a thin container entrypoint creates.
#
# Scoped to the two tools this owner needs: without herdr or jq it reads the
# runtime as `unreadable` forever and never starts it, which is correct and
# useless, and is exactly the silence this line exists to break.
report_recorded_path() {  # <recorded-path>
  local recorded=$1 unreachable unresolvable
  local FM_SERVICE_REQUIRED_TOOLS=${FM_SERVICE_REQUIRED_TOOLS:-'herdr jq'}
  unreachable=$(fm_service_path_unreachable "$recorded")
  if [ -n "$unreachable" ]; then
    echo "HERDR_RUNTIME: the runtime owner's recorded PATH cannot reach $(printf '%s' "$unreachable" | tr '\n' ' ' | sed 's/ $//') - it reads the runtime as unreadable until it can"
  fi
  unresolvable=$(fm_service_path_unresolvable "$recorded")
  if [ -n "$unresolvable" ]; then
    echo "HERDR_RUNTIME: the runtime owner's recorded PATH cannot reach $(printf '%s' "$unresolvable" | tr '\n' ' ' | sed 's/ $//'), and this session cannot resolve it either, so the recorded environment was composed without it - it reads the runtime as unreadable until a session that can reach it converges the service"
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

# What the owner last established about the runtime, said in the digest rather
# than left in a file: an owner that is up but reading `unreadable` looks exactly
# like a healthy home from the outside, and that is the state this whole area
# exists to stop reporting as fine.
#
# Gated on has_current_reading, because the runtime's cleanup deliberately leaves
# $READING behind when an owner dies: without the gate an hours-old sentence is
# stated in the present tense and attributed to an owner that no longer exists -
# and it may be false by now, since a lazy fm_backend_herdr_server_ensure can
# have started the server since. A reading nothing current stands behind does not
# get to assert the runtime's state at all.
report_reading() {
  local reading note
  reading=$(recorded_reading_field reading)
  [ -n "$reading" ] || return 0
  if ! has_current_reading; then
    echo "HERDR_RUNTIME: no owner watching now has established whether the worker runtime is running - the last reading is older than the ${GRACE}s grace"
    return 0
  fi
  note=$(recorded_reading_field note)
  case "$reading" in
    running|'') return 0 ;;
    unreadable)
      echo "HERDR_RUNTIME: the runtime owner cannot read whether the worker runtime is running - $note"
      ;;
    down)
      echo "HERDR_RUNTIME: the worker runtime is not running - $note"
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
        # A convergence that did not complete always says so, and says which of
        # the three things went wrong rather than the worst of them.  An
        # unsupervised runtime is one fact; an owner that is up and watching but
        # could not be replaced with what this session would start now is a
        # different one, and the second must never be reported as the first -
        # most sharply in the case this owner exists to notice, a wedged client,
        # where the owner is up and reporting `unreadable`.  Silence is not the
        # alternative either: a failed convergence that printed nothing would be
        # indistinguishable from a converged one.  What the owner SAW is
        # report_reading's line below, separately and without contradiction.
        if ! healthy_owner; then
          echo "HERDR_RUNTIME: systemd --user unavailable and the tmux keeper tier failed, so nothing supervises the runtime every worker on this home runs in"
        elif ! has_current_reading; then
          echo "HERDR_RUNTIME: the runtime owner is running but has not published a reading yet, so the worker runtime's state is not established"
        else
          echo "HERDR_RUNTIME: an owner is still watching the worker runtime, but the tmux keeper tier convergence failed, so this session could not replace it with what it would start now - inspect state/.herdr-runtime.log"
        fi
      fi
      # Same question, same wording, asked of the keeper's own record.  Skipped
      # when there is no record at all, because "nothing is watching" is the
      # branch above's sentence to say, not this one's.
      if [ -n "$(recorded_keeper_path)" ]; then
        report_recorded_path "$(recorded_keeper_path)"
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
  # Asked after any convergence above, so it reports what the running owner can
  # actually reach.
  if systemd_installed; then
    report_recorded_path "$(recorded_service_path 2>/dev/null || true)"
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
  home_runs_herdr || { echo "this home does not spawn workers into herdr; nothing to restart" >&2; return 1; }
  case "$(select_backend)" in
    systemd)
      if ! systemd_installed || ! systemd_enabled; then
        echo "HERDR_RUNTIME: install or enable requires approval through bin/fm-bootstrap.sh install herdr-unit" >&2
        return 2
      fi
      write_service_env || return 1
      clear_replaced_owner systemd || return 1
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
  if [ "$(select_backend)" = systemd ]; then
    if systemd_installed; then
      "$SYSTEMCTL" --user disable --now "$(unit_instance)" || return 1
    else
      echo "no herdr runtime unit is installed for this home" >&2
    fi
  fi
  # The sentence below is a postcondition, not a hope: a keeper killed outright
  # leaves its owner alive and reparented, and stopping the tier it was hosted by
  # does not reach it.  The rollback is only true once NO live owner is left, so
  # no tier is named here and it is claimed only after this returns.
  clear_replaced_owner || return 1
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
