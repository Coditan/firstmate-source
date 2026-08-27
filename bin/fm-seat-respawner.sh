#!/usr/bin/env bash
# Relaunch this home when the published firstmate seat becomes unreachable.
#
# Usage:
#   fm-seat-respawner.sh
#   FM_SEAT_RESPAWNER_ONCE=1 fm-seat-respawner.sh
#
# The liveness reading comes from bin/fm-delivery-service.sh status.
# This script does not probe panes or infer human intent from processes.
# It RESTARTS and never DETECTS: bin/fm-seat-alarm.sh owns saying out loud that
# the seat is gone, and the two are kept apart so the detector still speaks when
# the restarter is the part that failed.
#
# A LAUNCHED SEAT IS NOT YET A FIRST MATE, WHICH IS WHY THIS DOES NOT END AT
# `new-window`.  Measured on this fleet, 2026-08-27: a seat launched with a
# working launch command, keeper and supervisor all in place SITS IDLE.  It
# publishes no endpoint and takes no session lock until something gives it its
# first turn, and nothing does - bin/fm-sessionstart-nudge.sh injects context and
# explicitly cannot run session start itself.  The observed result was a queue
# standing at 47 for four minutes with a healthy agent sitting in the window.
# So a restart that ends at "the process exists" restores nothing, and giving the
# fresh seat that first turn is a fourth requirement beside launching it,
# supervising the launcher, and reporting the absence.
#
# This is the only component that can do it, because it is the only one that
# knows which pane it just created: the delivery listener cannot, since the
# endpoint it would need is precisely what the idle seat has not published.
# The submit uses this fleet's own owned primitives rather than raw keystrokes -
# bin/fm-pane-activity-lib.sh and bin/fm-backend.sh decide whether a pane is a
# safe target, and bin/fm-operational-input.sh builds the typed input - so the
# "only an affirmatively empty genuine agent composer is typed into" rule holds
# here exactly as it does for delivery.
# The seat's environment belongs to config/seat-launch-command, not to this
# process; launch_in_tmux composes no PATH and the comment there says why.
# Deliberate shutdown is declared through state/.seat-stay-down, managed by
# bin/fm-seat-stay-down.sh; when the marker exists, this script leaves the seat
# down.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESPAWNER_PATH="$SCRIPT_DIR/fm-seat-respawner.sh"
DELIVERY_SERVICE="${FM_SEAT_DELIVERY_SERVICE:-$SCRIPT_DIR/fm-delivery-service.sh}"
TMUX_CMD="${FM_SEAT_TMUX:-tmux}"
POLL=${FM_SEAT_RESPAWNER_POLL:-15}
BASE_BACKOFF=${FM_SEAT_RESPAWNER_BACKOFF:-30}
MAX_BACKOFF=${FM_SEAT_RESPAWNER_MAX_BACKOFF:-900}
MAX_ATTEMPTS=${FM_SEAT_RESPAWNER_MAX_ATTEMPTS:-5}
WATCHER_SERVICE="${FM_SEAT_WATCHER_SERVICE:-$SCRIPT_DIR/fm-watcher-service.sh}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_GRACE=${FM_SEAT_WATCHER_GRACE:-${FM_GUARD_GRACE:-300}}
WATCHER_REVIVE_EVERY=${FM_SEAT_WATCHER_REVIVE_EVERY:-120}
WATCHER_REVIVED="$STATE/.seat-respawner-watcher-revived"
MARKER="$STATE/.seat-stay-down"
FIRST_TURN="$STATE/.seat-first-turn"
FIRST_TURN_DEADLINE=${FM_SEAT_FIRST_TURN_DEADLINE:-600}
SUBMIT_RETRIES=${FM_SEAT_SUBMIT_RETRIES:-3}
SUBMIT_SLEEP=${FM_SEAT_SUBMIT_SLEEP:-0.4}
case "$FIRST_TURN_DEADLINE" in ''|*[!0-9]*) FIRST_TURN_DEADLINE=600 ;; esac
case "$SUBMIT_RETRIES" in ''|*[!0-9]*) SUBMIT_RETRIES=3 ;; esac
ATTEMPTS="$STATE/.seat-respawn-attempts"
GIVEUP="$STATE/.seat-respawn-giveup"
BEAT="$STATE/.last-seat-respawner-beat"
LOCKDIR="$STATE/.seat-respawner.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-retry-episode-lib.sh
. "$SCRIPT_DIR/fm-retry-episode-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pane-activity-lib.sh
. "$SCRIPT_DIR/fm-pane-activity-lib.sh"
# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

POLL=$(fm_retry_num_or_default "$POLL" 15)
BASE_BACKOFF=$(fm_retry_num_or_default "$BASE_BACKOFF" 30)
MAX_BACKOFF=$(fm_retry_num_or_default "$MAX_BACKOFF" 900)
MAX_ATTEMPTS=$(fm_retry_num_or_default "$MAX_ATTEMPTS" 5)

log() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/.seat-respawner.log" 2>/dev/null || true
}

write_lock() {
  local tmp identity
  mkdir -p "$LOCKDIR" "$STATE" || return 1
  identity=$(fm_pid_identity "$$") || return 1
  tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$$"
    printf 'pid-identity=%s\n' "$identity"
    printf 'fm-home=%s\n' "$FM_HOME"
    printf 'respawner-path=%s\n' "$RESPAWNER_PATH"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$LOCKDIR/record" || { rm -f "$tmp"; return 1; }
}

beat() {
  mkdir -p "$STATE" || return 1
  : > "$BEAT"
}

stay_down() {
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ]
}

launch_command() {
  local line file=$CONFIG/seat-launch-command
  if [ -n "${FM_SEAT_LAUNCH_COMMAND:-}" ]; then
    printf '%s\n' "$FM_SEAT_LAUNCH_COMMAND"
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 1
}

resume_style_launch_command() {  # <command>
  local cmd=" $1 " first base
  first=${1%%[	 ]*}
  base=${first##*/}
  case "$cmd" in
    *" resume "*|*" --resume"*|*" --continue"*)
      return 0
      ;;
  esac
  [ "$base" = claude ] || return 1
  case "$cmd" in
    *" -c "*|*" -c") return 0 ;;
    *) return 1 ;;
  esac
}

endpoint_file() {
  printf '%s/.primary-endpoint\n' "$STATE"
}

tmux_socket_from_endpoint() {
  local server socket pid endpoint
  endpoint=$(endpoint_file)
  [ "$(fm_retry_kv_get "$endpoint" backend 2>/dev/null || true)" = tmux ] || return 1
  server=$(fm_retry_kv_get "$endpoint" tmux-server 2>/dev/null || true)
  socket=${server%,*}
  pid=${server##*,}
  [ "$socket" != "$server" ] && [ -n "$socket" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$socket"
}

shell_quote() {
  printf '%q' "$1"
}

launch_in_tmux() {  # <reason>
  local cmd socket shell_command
  cmd=$(launch_command) || {
    log "launch refused: no config/seat-launch-command and no FM_SEAT_LAUNCH_COMMAND"
    return 1
  }
  if resume_style_launch_command "$cmd"; then
    log "launch refused: resume-style config/seat-launch-command is not safe for the seat respawner"
    return 1
  fi
  socket=$(tmux_socket_from_endpoint) || {
    log "launch refused: published endpoint is not a live tmux server-bound endpoint"
    return 1
  }
  # DELIBERATELY NO PATH HERE.  This used to pin the respawner's own PATH into
  # the new seat, which meant a respawned seat silently ran a different tool set
  # from a hand-started one - it never reads ~/.profile, so whatever environment
  # the launcher happened to have became the seat's.
  #
  # Measured on coditan-vessel, 2026-08-27, with `env -i HOME=/home/coditan`:
  # `bash -lc  'command -v claude'` resolves /usr/local/bin/claude 2.1.234, and
  # `bash -lic 'command -v claude'` resolves ~/.npm-global/bin/claude 2.1.247.
  # The difference is ~/.bashrc's own `case $- in *i*) ;; *) return;; esac` guard,
  # which returns before the line that puts the npm prefix on PATH, so only an
  # INTERACTIVE login shell reaches the newer agent binary.  No value composed
  # out here can reproduce that chain, and pinning one can only contradict it.
  # So the launch command owns its own environment resolution and this composes
  # none: see the seat-launch-command section of docs/configuration.md, which
  # owns what a launch command must therefore be.
  shell_command="cd $(shell_quote "$FM_HOME") && export FM_HOME=$(shell_quote "$FM_HOME") FM_ROOT_OVERRIDE=$(shell_quote "$FM_ROOT") && exec $cmd"
  # -P -F prints the pane the window was created with. That id is the whole
  # reason this step is here rather than in the delivery listener: it is the only
  # address of a seat that has not yet published one, and without recording it
  # the fresh seat could never be given its first turn.
  pane=$("$TMUX_CMD" -S "$socket" new-window -P -F '#{pane_id}' -n firstmate "$shell_command") || return 1
  [ -n "$pane" ] || return 1
  record_first_turn "$pane" "$socket"
}

# --- the first turn ---------------------------------------------------------
#
# A launched agent waits for input. Session start, the endpoint publication and
# the session lock are all downstream of a turn it has not had, so until this
# submits, the seat exists and the home is still unattended - which is exactly
# what bin/fm-seat-alarm.sh goes on reporting, because it reads the lock rather
# than the process. That agreement is deliberate: neither half calls a restart
# finished before a first mate is actually holding the home.

record_first_turn() {  # <pane> <socket>
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$FIRST_TURN.XXXXXX") || return 1
  {
    printf 'pane=%s\n' "$1"
    printf 'server=%s\n' "$2,$(tmux_server_pid_from_endpoint)"
    printf 'at=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FIRST_TURN" || { rm -f -- "$tmp"; return 1; }
}

tmux_server_pid_from_endpoint() {
  local server
  server=$(fm_retry_kv_get "$(endpoint_file)" tmux-server 2>/dev/null || true)
  printf '%s' "${server##*,}"
}

# The one message a fresh seat is given. Its body is the instruction and nothing
# else: what the seat then does is AGENTS.md section 3's, and a body that
# summarised the fleet here would be a second copy of state that could disagree
# with the durable records the seat is about to read for itself.
first_turn_body() {
  printf 'You are the firstmate primary seat for this home, started automatically after the previous seat stopped. Run bin/fm-session-start.sh now, exactly once, before reading anything else, and follow the supervision block it prints.'
}

# Returns 0 when the first turn is settled - submitted, abandoned, or none
# pending - and leaves the record in place when it should simply be retried.
deliver_first_turn() {
  local pane server at age composer encoded verdict
  [ -f "$FIRST_TURN" ] && [ ! -L "$FIRST_TURN" ] || return 0
  pane=$(fm_retry_kv_get "$FIRST_TURN" pane 2>/dev/null || true)
  server=$(fm_retry_kv_get "$FIRST_TURN" server 2>/dev/null || true)
  at=$(fm_retry_kv_get "$FIRST_TURN" at 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  age=$(( $(date +%s) - at ))

  # A seat that took the lock has had its turn; nothing more is owed to it.
  if seat_holds_lock; then
    rm -f -- "$FIRST_TURN"
    log "first turn landed: a seat now holds this home"
    return 0
  fi
  # Bounded, and abandoned out loud. A first turn that never lands must not be
  # retried forever in silence, and the absence keeps being reported either way.
  if [ "$age" -ge "$FIRST_TURN_DEADLINE" ]; then
    rm -f -- "$FIRST_TURN"
    log "first turn abandoned after ${age}s: pane $pane never presented an empty agent composer"
    return 0
  fi
  [ -n "$pane" ] || { rm -f -- "$FIRST_TURN"; return 0; }

  local FM_TMUX_SERVER_IDENTITY=$server
  export FM_TMUX_SERVER_IDENTITY
  fm_backend_target_exists tmux "$pane" || {
    rm -f -- "$FIRST_TURN"
    log "first turn abandoned: pane $pane no longer exists"
    return 0
  }
  # The same two reads delivery takes, from the same owners, for the same
  # reason: a busy pane must not be interrupted and only an affirmatively empty
  # genuine agent composer is ever typed into. A bare shell reads as unknown
  # here, which is what a launch command that failed leaves behind - and handing
  # a shell this text is precisely what must not happen.
  pane_is_busy "$pane" tmux && return 0
  composer=$(fm_backend_composer_state tmux "$pane" 2>/dev/null)
  [ "$composer" = empty ] || return 0

  fm_operational_input_encode session-start "$(first_turn_body)" encoded || {
    log "first turn could not be encoded"
    return 0
  }
  verdict=$(fm_backend_send_text_submit tmux "$pane" "$encoded" "$SUBMIT_RETRIES" "$SUBMIT_SLEEP" "$SUBMIT_SLEEP")
  if [ "$verdict" = empty ]; then
    rm -f -- "$FIRST_TURN"
    log "first turn submitted to pane $pane"
  else
    log "first turn was not confirmed (verdict=${verdict:-unknown}); leaving it to the next cycle"
  fi
  return 0
}

# Only a session start takes this home's lock, so the lock naming a live harness
# is the one proof that a restart produced a first mate rather than a process.
seat_holds_lock() {
  local pid
  pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_alive "$pid"
}

clear_episode() {
  fm_retry_clear_episode "$ATTEMPTS" "$GIVEUP"
}

emit_giveup_finding() {  # <key> <status-line>
  local key=$1 status_line=$2 out rc=0
  out=$(fm_retry_giveup_emit "$GIVEUP" "$key" fm-seat-respawner \
    "The primary firstmate seat respawner exhausted $MAX_ATTEMPTS launch attempt(s) for this home and stopped retrying this episode." \
    "bin/fm-seat-respawner.sh for $FM_HOME" \
    "$status_line") || rc=$?
  [ -z "$out" ] || log "$out"
  return "$rc"
}

# Revive a PROVABLY dead watcher, and nothing more.
#
# This is the return half of the arrangement described in
# bin/fm-seat-respawner-service.sh: that service's armed check has the watcher
# converge this respawner every sweep, and this has the respawner revive the
# watcher when the watcher is the one that died.  Neither supervises the other in
# any general sense; each simply restores the other from the dead, so the loss of
# either one is recoverable without a seat.  Without this the two form a chain
# rather than a pair, and a chain has an end.
#
# Deliberately narrow.  It acts only when fm_watcher_healthy - this fleet's one
# owner of that question - says there is no healthy watcher at all, never on a
# recorded-version or recorded-PATH mismatch.  Those are convergence decisions
# that belong to a session with the fleet lock, and a background process racing
# one over them would produce two managers fighting over one service.  It is also
# rate-limited, so a watcher that cannot start is retried rather than hammered,
# and skipped entirely on a systemd home where the unit's own Restart=always
# already owns this.
revive_watcher_if_dead() {
  local age
  [ "${FM_SEAT_REVIVE_WATCHER:-1}" = 1 ] || return 0
  [ -x "$WATCHER_SERVICE" ] || return 0
  [ "$("$WATCHER_SERVICE" select 2>/dev/null || true)" = keeper ] || return 0
  fm_watcher_healthy "$STATE" "$WATCH" "$WATCHER_GRACE" "$FM_HOME" && return 0
  if [ -e "$WATCHER_REVIVED" ]; then
    age=$(fm_path_age "$WATCHER_REVIVED") || age=$WATCHER_REVIVE_EVERY
    case "$age" in ''|*[!0-9]*) age=$WATCHER_REVIVE_EVERY ;; esac
    [ "$age" -ge "$WATCHER_REVIVE_EVERY" ] || return 0
  fi
  : > "$WATCHER_REVIVED" 2>/dev/null || true
  if "$WATCHER_SERVICE" ensure >/dev/null 2>&1; then
    log "revived a dead supervision loop"
  else
    log "a dead supervision loop could not be revived"
  fi
}

respawn_needed() {  # <status-line>
  case "$1" in
    undeliverable:*) return 0 ;;
    *) return 1 ;;
  esac
}

one_cycle() {
  local status_line key now count next delay
  beat || return 1
  revive_watcher_if_dead
  deliver_first_turn
  if stay_down; then
    clear_episode
    log "stay-down marker present; leaving seat down"
    return 0
  fi
  status_line=$("$DELIVERY_SERVICE" status 2>&1 || true)
  case "$status_line" in *$'\n'*) status_line=${status_line%%$'\n'*} ;; esac
  if ! respawn_needed "$status_line"; then
    clear_episode
    return 0
  fi
  key=$(fm_delivery_condition_key "$status_line")
  fm_retry_read_attempts "$ATTEMPTS" "$key"
  count=$FM_RETRY_ATTEMPT_COUNT
  next=$FM_RETRY_ATTEMPT_NEXT
  now=$(date +%s)
  if [ "$count" -ge "$MAX_ATTEMPTS" ]; then
    emit_giveup_finding "$key" "$status_line" || true
    return 0
  fi
  if [ "$now" -lt "$next" ]; then
    return 0
  fi
  count=$((count + 1))
  delay=$(fm_retry_backoff "$count" "$BASE_BACKOFF" "$MAX_BACKOFF")
  next=$((now + delay))
  fm_retry_write_attempts "$ATTEMPTS" "$key" "$count" "$next" || return 1
  if launch_in_tmux "$status_line"; then
    log "launch attempt $count submitted after: $status_line"
  else
    log "launch attempt $count failed after: $status_line"
  fi
}

main() {
  write_lock || { echo "fm-seat-respawner.sh: could not publish lock" >&2; return 1; }
  while :; do
    one_cycle || true
    [ "${FM_SEAT_RESPAWNER_ONCE:-0}" = 1 ] && break
    sleep "$POLL"
  done
}

main "$@"
