#!/usr/bin/env bash
# Own the systemd user service for one home's bosun observer.
#
# Usage:
#   fm-bosun-service.sh bootstrap
#   fm-bosun-service.sh ensure
#   fm-bosun-service.sh install-unit
#   fm-bosun-service.sh health
#
# The bosun works and has no lifetime of its own: it stops the moment whoever
# started it goes away. This gives it one, per home, the same way the watcher
# and the delivery listener have one, because several firstmate homes share a
# machine and each needs an independent restart boundary.
#
# OPTED IN, NOT ROLLED OUT
# A home opts in by creating gitignored config/bosun. Without that file this
# script is silent and installs nothing: the bosun spends an agent turn per
# judgement (docs/bosun-observer.md records the cost), so a standing process
# that spends it is a decision each home makes rather than one that arrives with
# an instruction-surface update. First installation and enablement then happen
# only through install-unit, after the captain approves the BOSUN_UNIT
# diagnostic; an already-installed unit converges at locked bootstrap
# boundaries. The flag gates whether this component is considered at all;
# removing it after installation stops future convergence rather than stopping
# the unit, deliberately matching the frequency monitor's two-step off switch.
#
# THE LIVENESS READING IS NOT THE UNIT'S OWN STATE
# This script never asks systemd whether the bosun is active, and that absence is
# the point rather than an omission. On this host bridge-notify-poll.timer
# reported loaded, enabled and active for nine days after it last did any work:
# a unit's own state answers whether something was started, never whether it is
# doing the thing it was started for. The reading here is bin/fm-bosun.sh
# status, which exits 0 for WORKING and QUIET and 1 for BLIND, STALLED, STOPPED
# and DEAD, and which separates a bosun that judged nothing because nothing
# arrived from one whose cursor froze while the journal grew. is-enabled is
# still read, because that is a question about installation and consent rather
# than about liveness.
#
# WHAT IT RESTARTS AND WHAT IT ONLY REPORTS
# STOPPED and DEAD mean no bosun process is judging, which a restart fixes, so
# locked convergence restarts them. STALLED and BLIND mean a bosun that IS
# running has stopped consuming the journal, or cannot read it; a restart may
# clear the symptom and hide the fault behind a fresh cursor, so those are never
# restarted without a durable findings-surface record. With no configuration
# drift they are reported and left alone; with drift, the pre-restart evidence
# is recorded before convergence proceeds.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOSUN="$SCRIPT_DIR/fm-bosun.sh"
FINDING="$SCRIPT_DIR/fm-finding.sh"
UNIT_SOURCE="$FM_ROOT/systemd/fm-bosun@.service"
SYSTEMCTL=${FM_BOSUN_SYSTEMCTL:-systemctl}
SYSTEMD_ESCAPE=${FM_BOSUN_SYSTEMD_ESCAPE:-systemd-escape}
USER_UNIT_DIR=${FM_BOSUN_SYSTEMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
UNIT_DEST="$USER_UNIT_DIR/fm-bosun@.service"
SERVICE_ENV="$STATE/.bosun-service.env"
OPT_IN="$FM_HOME/config/bosun"
CONFIRM_TIMEOUT=${FM_BOSUN_CONFIRM_TIMEOUT:-20}
case "$CONFIRM_TIMEOUT" in ''|*[!0-9]*|0) CONFIRM_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-service-path-lib.sh
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
# See fm-watcher-service.sh: the composed PATH resolves through this process.
fm_axi_prepend_path "$FM_HOME"

bosun_opted_in() {
  [ -f "$OPT_IN" ]
}

# The environment every reading and the recorded service both run under, so a
# reading this script takes and the value the unit runs with cannot drift.
bosun_env() {
  FM_HOME="$FM_HOME" \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$STATE" \
    "$@"
}

# Resolve the judge through its own owner rather than re-reading config/bosun-judge
# here, so the seam keeps one implementation. Run in a child shell because
# fm-bosun-lib.sh sets FM_ROOT, FM_HOME and STATE of its own.
bosun_judge_command() {
  # Ignore a converging session's ambient override so resolution matches the
  # durable per-home configuration the unit will see when systemd starts it.
  # shellcheck disable=SC2016 # $1 is the child shell's own positional parameter.
  bosun_env env -u FM_BOSUN_JUDGE_CMD \
    bash -c '. "$1/fm-bosun-lib.sh"; fm_bosun_judge_command' _ "$SCRIPT_DIR" 2>/dev/null
}

# The program the judge command actually runs. A judge given as an absolute path
# is its own answer; a bare name is what must be reachable from the recorded PATH.
bosun_judge_program() {
  local cmd
  cmd=$(bosun_judge_command) || return 1
  # shellcheck disable=SC2086 # A command LINE; its first word is the program.
  set -- $cmd
  [ "$#" -gt 0 ] || return 1
  printf '%s\n' "$1"
}

# The bosun's judge is a per-home command and is not on the service tool list,
# so a service PATH composed from that list alone would reach the loop and not
# the thing it exists to call. An unreachable judge is not silent - every event
# is recorded as a failure-path escalation - but it is invisible to a liveness
# reading, which would go on saying WORKING, so the judge is resolved into the
# composed value and separately checked below.
bosun_service_path() {
  local program tools
  tools=${FM_SERVICE_TOOLS:-$FM_SERVICE_TOOLS_DEFAULT}
  program=$(bosun_judge_program 2>/dev/null || true)
  case "$program" in
    ''|/*|./*|../*) ;;
    *) tools="$tools $program" ;;
  esac
  FM_SERVICE_TOOLS="$tools" fm_service_path
}

systemd_usable() {
  [ "${FM_BOSUN_FORCE_SYSTEMD:-0}" = 1 ] && return 0
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  command -v "$SYSTEMD_ESCAPE" >/dev/null 2>&1 || return 1
  "$SYSTEMCTL" --user show-environment >/dev/null 2>&1
}

unit_instance() {
  local escaped
  escaped=$("$SYSTEMD_ESCAPE" --path "$FM_HOME") || return 1
  printf 'fm-bosun@%s.service\n' "$escaped"
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

bosun_source_version() {
  local file sum size
  local files=(
    "$BOSUN"
    "$SCRIPT_DIR/fm-bosun-lib.sh"
    "$SCRIPT_DIR/fm-journal-lib.sh"
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

service_env_values() {  # prints the whole recorded environment on stdout
  local version resolved_path interval timeout
  version=$(bosun_source_version) || return 1
  resolved_path=$(bosun_service_path) || return 1
  interval=${FM_BOSUN_INTERVAL:-30}
  timeout=${FM_BOSUN_JUDGE_TIMEOUT:-45}
  printf 'FM_HOME=%s\n' "$(systemd_env_quote "$FM_HOME")"
  printf 'FM_ROOT_OVERRIDE=%s\n' "$(systemd_env_quote "$FM_ROOT")"
  printf 'FM_STATE_OVERRIDE=%s\n' "$(systemd_env_quote "$STATE")"
  printf 'FM_BOSUN_EXEC=%s\n' "$(systemd_env_quote "$BOSUN")"
  printf 'PATH=%s\n' "$(systemd_env_quote "$resolved_path")"
  printf 'FM_BOSUN_SOURCE_VERSION=%s\n' "$(systemd_env_quote "$version")"
  printf 'FM_BOSUN_INTERVAL=%s\n' "$(systemd_env_quote "$interval")"
  printf 'FM_BOSUN_JUDGE_TIMEOUT=%s\n' "$(systemd_env_quote "$timeout")"
}

write_service_env() {
  local tmp changed=0
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.bosun-service.env.XXXXXX") || return 1
  service_env_values > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -f "$SERVICE_ENV" ] || ! cmp -s "$tmp" "$SERVICE_ENV"; then
    mv -f "$tmp" "$SERVICE_ENV" || { rm -f "$tmp"; return 1; }
    chmod 600 "$SERVICE_ENV" || return 1
    changed=1
  else
    rm -f "$tmp"
  fi
  FM_BOSUN_ENV_CHANGED=$changed
}

service_env_matches() {
  local expected
  [ -f "$SERVICE_ENV" ] && [ ! -L "$SERVICE_ENV" ] || return 1
  expected=$(service_env_values) || return 1
  printf '%s\n' "$expected" | cmp -s - "$SERVICE_ENV"
}

systemd_installed() {
  [ -f "$UNIT_DEST" ] && [ ! -L "$UNIT_DEST" ]
}

systemd_enabled() {
  local unit
  unit=$(unit_instance) || return 1
  "$SYSTEMCTL" --user is-enabled --quiet "$unit"
}

install_unit_bytes() {
  [ -f "$UNIT_SOURCE" ] && [ ! -L "$UNIT_SOURCE" ] || return 1
  mkdir -p "$USER_UNIT_DIR" || return 1
  install -m 0644 "$UNIT_SOURCE" "$UNIT_DEST"
}

# One word and its note, from the bosun's own health reading. FM_BOSUN_HEALTH_WORD
# and FM_BOSUN_HEALTH_NOTE carry it back; the return code is the reading's, so a
# caller can act on it without parsing the word at all.
bosun_health() {
  local out rc
  out=$(bosun_env "$BOSUN" status 2>/dev/null)
  rc=$?
  out=$(printf '%s\n' "$out" | tail -1)
  FM_BOSUN_HEALTH_WORD=${out%% *}
  FM_BOSUN_HEALTH_NOTE=${out#* - }
  [ -n "$FM_BOSUN_HEALTH_WORD" ] || {
    FM_BOSUN_HEALTH_WORD=UNREADABLE
    FM_BOSUN_HEALTH_NOTE="bin/fm-bosun.sh status produced no reading"
    return 1
  }
  return "$rc"
}

# Confirm a bosun PROCESS took over, which is a narrower question than whether it
# is doing its job, and the two are kept apart on purpose. STALLED means a bosun
# is running and behind, so a start that produces it did start something; whether
# that is acceptable is report_health's judgement, taken separately and printed
# in its own words. BLIND, STOPPED and DEAD mean no bosun is consuming the
# journal at all, which is a failed start.
#
# It polls because a bosun's beacon lands within a second of starting but its
# next record waits for the pass to end, and a pass against a long backlog is
# minutes.
wait_for_running_bosun() {
  local deadline
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while :; do
    bosun_health
    case "$FM_BOSUN_HEALTH_WORD" in
      WORKING|QUIET|STALLED) return 0 ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.5
  done
  return 1
}

judge_unreachable() {  # <recorded path> -> prints the judge program when it cannot be reached
  local path=$1 program
  program=$(bosun_judge_program 2>/dev/null) || return 0
  case "$program" in
    /*|./*|../*)
      [ -x "$program" ] || printf '%s\n' "$program"
      return 0
      ;;
  esac
  PATH="$path" command -v "$program" >/dev/null 2>&1 || printf '%s\n' "$program"
  return 0
}

recorded_service_path() {
  [ -f "$SERVICE_ENV" ] || return 1
  sed -n 's/^PATH="\(.*\)"$/\1/p' "$SERVICE_ENV" | head -1
}

record_restart_fault() {  # <restart trigger> <drift description>
  local trigger=$1 drift=$2 health_record measurement emitted
  health_record=$(cat "$STATE/bosun/health" 2>&1 || true)
  [ -n "$health_record" ] || health_record="health record absent or empty"
  measurement=$(printf 'trigger: %s\ndrift: %s\nhealth: %s - %s\nhealth record:\n%s\nrestart consequence: this restart is about to erase the live fault evidence' \
    "$trigger" "$drift" "$FM_BOSUN_HEALTH_WORD" "$FM_BOSUN_HEALTH_NOTE" "$health_record")
  if emitted=$(bosun_env "$FINDING" emit \
    --class evidence \
    --severity high \
    --claim "A $FM_BOSUN_HEALTH_WORD bosun will be restarted by $trigger after its fault evidence is preserved" \
    --where "$FM_HOME bosun observer service" \
    --measurement "$measurement" \
    --refuted-by "the pre-restart health reading was neither STALLED nor BLIND, or the named restart was not attempted" \
    --officer fm-bosun-service 2>&1); then
    return 0
  fi
  FM_BOSUN_FINDING_ERROR=$emitted
  return 1
}

ensure_systemd() {
  local unit unit_changed=0 env_changed=0 drift=''
  bosun_opted_in || return 0
  systemd_usable || {
    echo "BOSUN_UNIT: systemd --user is unavailable; the observer stops with whoever starts it and judges nothing between sessions" >&2
    return 2
  }
  unit=$(unit_instance) || return 1
  if ! systemd_installed; then
    echo "BOSUN_UNIT: missing - approve: bin/fm-bootstrap.sh install bosun-unit" >&2
    return 2
  fi
  if ! systemd_enabled; then
    echo "BOSUN_UNIT: disabled - approve: bin/fm-bootstrap.sh install bosun-unit" >&2
    return 2
  fi
  if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST"; then
    unit_changed=1
  fi
  service_env_matches || env_changed=1
  if [ "$unit_changed" -eq 1 ] || [ "$env_changed" -eq 1 ]; then
    if [ "$unit_changed" -eq 1 ] && [ "$env_changed" -eq 1 ]; then
      drift='unit bytes and recorded environment'
    elif [ "$unit_changed" -eq 1 ]; then
      drift='unit bytes'
    else
      drift='recorded environment'
    fi
    bosun_health || true
    case "$FM_BOSUN_HEALTH_WORD" in
      STALLED|BLIND)
        if ! record_restart_fault "locked bootstrap convergence" "$drift"; then
          printf 'BOSUN_UNIT: cannot restart the drifted %s observer without a durable incident record - %s\n' \
            "$FM_BOSUN_HEALTH_WORD" "$FM_BOSUN_FINDING_ERROR" >&2
          return 4
        fi
        ;;
    esac
    if [ "$unit_changed" -eq 1 ]; then
      install_unit_bytes || return 1
      "$SYSTEMCTL" --user daemon-reload || return 1
    fi
    if [ "$env_changed" -eq 1 ]; then
      write_service_env || return 1
    fi
    "$SYSTEMCTL" --user restart "$unit" || return 1
    wait_for_running_bosun || return 3
    return 0
  fi
  bosun_health && return 0
  case "$FM_BOSUN_HEALTH_WORD" in
    STALLED|BLIND)
      # Converged and left alone. See the header: a restart would clear the
      # symptom and hide the fault, which is what a unit's own state already
      # does. The reading itself is what gets reported, by report_health.
      return 0
      ;;
  esac
  "$SYSTEMCTL" --user restart "$unit" || return 1
  wait_for_running_bosun || return 3
  return 0
}

install_systemd() {
  local unit unit_changed=0 env_changed=0 drift=''
  bosun_opted_in || {
    echo "error: this home has not opted into the bosun; create $OPT_IN first" >&2
    return 1
  }
  systemd_usable || { echo "error: systemd --user is unavailable" >&2; return 1; }
  unit=$(unit_instance) || return 1
  cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || unit_changed=1
  service_env_matches || env_changed=1
  if [ "$unit_changed" -eq 1 ] && [ "$env_changed" -eq 1 ]; then
    drift='unit bytes and recorded environment'
  elif [ "$unit_changed" -eq 1 ]; then
    drift='unit bytes'
  elif [ "$env_changed" -eq 1 ]; then
    drift='recorded environment'
  else
    drift='no configuration bytes changed during approved installation'
  fi
  install_unit_bytes || return 1
  write_service_env || return 1
  "$SYSTEMCTL" --user daemon-reload || return 1
  "$SYSTEMCTL" --user enable "$unit" || return 1
  bosun_health || true
  case "$FM_BOSUN_HEALTH_WORD" in
    STALLED|BLIND)
      if ! record_restart_fault "approved bosun-unit installation" "$drift"; then
        printf 'error: the unit and recorded environment are in place, but restart was deliberately withheld because the running observer reads %s and its evidence could not be recorded - %s; make that surface writable, then rerun bin/fm-bootstrap.sh install bosun-unit\n' \
          "$FM_BOSUN_HEALTH_WORD" "$FM_BOSUN_FINDING_ERROR" >&2
        return 1
      fi
      ;;
  esac
  # Installation must make the recorded configuration the running one;
  # enable --now does not restart an instance that is already active.
  "$SYSTEMCTL" --user restart "$unit" || return 1
  wait_for_running_bosun || {
    echo "error: $unit was started but nothing is being judged: $FM_BOSUN_HEALTH_WORD - $FM_BOSUN_HEALTH_NOTE" >&2
    return 1
  }
}

report_health() {
  bosun_health && return 0
  echo "BOSUN_UNIT: nothing is being judged - $FM_BOSUN_HEALTH_WORD: $FM_BOSUN_HEALTH_NOTE"
  return 1
}

report_judge_reach() {
  local path unreachable
  path=$(recorded_service_path) || return 0
  [ -n "$path" ] || return 0
  unreachable=$(judge_unreachable "$path")
  [ -n "$unreachable" ] || return 0
  echo "BOSUN_UNIT: the observer's recorded PATH cannot reach its judge $unreachable - it would keep running and record every event as an unjudged escalation"
}

bootstrap_check() {
  local unit rc
  bosun_opted_in || return 0
  if ! systemd_usable; then
    echo "BOSUN_UNIT: systemd --user is unavailable; the observer stops with whoever starts it and judges nothing between sessions"
    return 0
  fi
  unit=$(unit_instance) || {
    echo "BOSUN_UNIT: failed to encode FM_HOME $FM_HOME"
    return 0
  }
  if ! systemd_installed; then
    echo "BOSUN_UNIT: missing $UNIT_DEST - approve: bin/fm-bootstrap.sh install bosun-unit"
    return 0
  fi
  if ! systemd_enabled; then
    echo "BOSUN_UNIT: $unit is disabled - approve: bin/fm-bootstrap.sh install bosun-unit"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    if ! cmp -s "$UNIT_SOURCE" "$UNIT_DEST" || ! service_env_matches; then
      echo "BOSUN_UNIT: $unit needs locked convergence from the session holding the fleet lock"
    fi
  else
    ensure_systemd 2>&1 >/dev/null && rc=0 || rc=$?
    # 3 is "converged, restarted, and still nothing is judging". That is a real
    # fault, but naming it a convergence failure would send the reader to
    # systemctl, and the reading below already names the concrete state.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && [ "$rc" -ne 4 ]; then
      echo "BOSUN_UNIT: $unit convergence failed - inspect systemctl --user status $unit"
    fi
  fi
  # Taken last and taken always, locked or not: it is a read, it is the only
  # reading that answers whether the observer is doing its job, and a read-only
  # session that can see a stalled bosun should say so rather than defer it.
  report_health || true
  report_judge_reach
}

case "${1:-}" in
  bootstrap) bootstrap_check ;;
  ensure) ensure_systemd ;;
  install-unit) install_systemd ;;
  health) report_health ;;
  *)
    echo "usage: $(basename "$0") {bootstrap|ensure|install-unit|health}" >&2
    exit 2
    ;;
esac
