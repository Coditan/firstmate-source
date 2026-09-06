#!/usr/bin/env bash
# Keep this home's herdr runtime up, and own the process that serves it.
#
# Usage:
#   fm-herdr-runtime.sh                        # supervise until stopped
#   FM_HERDR_RUNTIME_ONCE=1 fm-herdr-runtime.sh  # one reading, one start at most
#   fm-herdr-runtime.sh __serve <session>      # internal: the detached server
#
# bin/fm-herdr-service.sh owns which tier runs this (a systemd user unit or a
# tmux keeper) and how it is converged; this file owns the loop itself.
#
# WHY THE RUNTIME NEEDS AN OWNER AT ALL.  Herdr is where every crewmate on a
# herdr home runs, and until this existed nothing on the machine was responsible
# for the server that hosts them.  It was started by whichever process first
# touched the session - `fm_backend_herdr_server_ensure` runs from a spawn, a
# pane read, a watcher poll - so the runtime that hosts the whole fleet was a
# child of a short-lived reader.  Measured on the coditan vessel 2026-09-06, the
# live server's parent was `bash bin/fm-crew-state.sh <task-id>`, a one-shot
# state read; on 2026-09-04 it was the watcher's own poll, and restarting the
# watcher took every running worker with it.  A container rebuild left the
# runtime down entirely until something touched it by accident, because the
# vessel entrypoint restores the watcher, the delivery listener and the keepers
# and knows nothing about herdr (docs/herdr-backend.md "Runtime ownership").
#
# TWO RULES BIND EVERYTHING BELOW, AND BOTH ARE ABOUT NOT DESTROYING WORK.
#
# 1. THE SERVER IS STARTED DETACHED, NEVER AS A CHILD OF THE THING THAT ASKED.
# `herdr status --json` reports capability `detached_server_daemon: false` on
# 0.7.4, so herdr does not daemonize itself: whatever starts it is its parent and
# its session, and a signal to that session reaches it.  This starts it through
# `setsid` (or `nohup` where setsid is absent, recorded either way) so it lands
# in a session of its own.  That is what makes the owner disposable: killing the
# keeper, restarting the unit, or losing the seat leaves the runtime running.
#
# 2. THIS NEVER STOPS OR RESTARTS A RUNNING SERVER.  Stopping it kills every
# worker's agent process at once, so there is no state of this loop that ends a
# running runtime - not convergence, not a version change, not a stale record.
# It only ever starts one that is DOWN, which is also why it can adopt a server
# somebody else started: ownership here means "something is watching and will
# start it again", not "I am its parent".  That is what lets a fleet with live
# workers gain an owner with no disruption at all.
#
# A READING IT COULD NOT TAKE IS NOT A READING OF `down`.  A missing herdr, a
# missing jq, or unparseable JSON all mean this loop does not know, and a start
# on a "down" it invented could bind a second server against a live socket.  So
# `unreadable` is its own state, it is recorded and reported as itself, and it
# never triggers a start.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RUNTIME_PATH="$SCRIPT_DIR/fm-herdr-runtime.sh"
LOCKDIR="$STATE/.herdr-runtime.lock"
RECORD="$LOCKDIR/record"
READING="$LOCKDIR/reading"
BEAT="$STATE/.last-herdr-runtime-beat"
LOG="$STATE/.herdr-runtime.log"
SERVER_LOG="$STATE/.herdr-server.log"

# One `herdr status --json` per interval, forever, so the interval is chosen
# against what it costs rather than against how fast a reading could be taken:
# 30s is two CLI invocations a minute and still notices a dead runtime long
# before a supervisor could act on it.
POLL=${FM_HERDR_RUNTIME_POLL:-30}
START_TIMEOUT=${FM_HERDR_RUNTIME_START_TIMEOUT:-20}
BASE_BACKOFF=${FM_HERDR_RUNTIME_BACKOFF:-30}
MAX_BACKOFF=${FM_HERDR_RUNTIME_MAX_BACKOFF:-300}
CONFIRM_SLEEP=${FM_HERDR_RUNTIME_CONFIRM_SLEEP:-1}
# The detached server's own stdout and stderr go to $SERVER_LOG, apart from this
# owner's lines in $LOG, and that file is capped.  A bound exists at all because
# the volume a long-lived `herdr server` writes under a live fleet is unmeasured,
# and the lazy start this replaces discarded that output entirely; the runtime
# must not become the first unbounded writer under state/.  At the bound the file
# is copied once to $SERVER_LOG.1 and truncated in place - truncation rather
# than a rename because the server holds the file open in append mode and would
# keep writing to a renamed file - so a crashed runtime's last words survive.
SERVER_LOG_MAX_BYTES=${FM_HERDR_SERVER_LOG_MAX_BYTES:-4194304}
case "$POLL" in ''|*[!0-9]*|0) POLL=30 ;; esac
case "$START_TIMEOUT" in ''|*[!0-9]*|0) START_TIMEOUT=20 ;; esac
case "$BASE_BACKOFF" in ''|*[!0-9]*|0) BASE_BACKOFF=30 ;; esac
case "$MAX_BACKOFF" in ''|*[!0-9]*|0) MAX_BACKOFF=300 ;; esac
case "$CONFIRM_SLEEP" in ''|.|*[!0-9.]*|*.*.*) CONFIRM_SLEEP=1 ;; esac
case "$SERVER_LOG_MAX_BYTES" in ''|*[!0-9]*|0) SERVER_LOG_MAX_BYTES=4194304 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# fm_backend_herdr_cli is the one owner of how a herdr call is scoped to a named
# session, and docs/herdr-backend.md "Session targeting" owns why the explicit
# `--session` flag rather than HERDR_SESSION alone is the only safe form.  This
# loop re-encodes neither; it sources the adapter and calls that function.
fm_backend_source herdr || {
  echo "error: the herdr adapter could not be sourced; this home has no runtime to own" >&2
  exit 1
}

# The session this loop is responsible for.  Resolution mirrors
# fm_backend_herdr_session so the owner and every spawn name the same server:
# an explicit per-service value first, then the ambient HERDR_SESSION a session
# would resolve, then herdr's own default.
SESSION=${FM_HERDR_RUNTIME_SESSION:-${HERDR_SESSION:-default}}

log() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

write_record() {
  local tmp identity
  mkdir -p "$LOCKDIR" "$STATE" || return 1
  identity=$(fm_pid_identity "$$") || return 1
  tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX") || return 1
  {
    printf 'pid=%s\n' "$$"
    printf 'pid-identity=%s\n' "$identity"
    printf 'fm-home=%s\n' "$FM_HOME"
    printf 'runtime-path=%s\n' "$RUNTIME_PATH"
    printf 'session=%s\n' "$SESSION"
    # What this process was STARTED with, recorded for the same reason
    # bin/fm-seat-respawner.sh records its three: a keeper receives its version
    # and PATH as launch arguments that would otherwise leave no trace, so
    # without this the keeper tier could never reconverge on a self-update.
    printf 'manager=%s\n' "${FM_HERDR_RUNTIME_MANAGER:-session}"
    printf 'source-version=%s\n' "${FM_HERDR_RUNTIME_SOURCE_VERSION:-unknown}"
    printf 'service-path=%s\n' "${FM_HERDR_RUNTIME_SERVICE_PATH:-}"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; return 1; }
}

# The last thing this loop actually established about the runtime, kept apart
# from the identity record because the two answer different questions: the record
# says who is watching, this says what they saw.
write_reading() {  # <reading> <note>
  local reading=$1 note=$2 tmp
  mkdir -p "$LOCKDIR" || return 1
  tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX") || return 1
  {
    printf 'reading=%s\n' "$reading"
    printf 'session=%s\n' "$SESSION"
    printf 'at=%s\n' "$(date +%s)"
    printf 'detach=%s\n' "${LAST_DETACH:-none}"
    printf 'starts=%s\n' "${STARTS:-0}"
    printf 'note=%s\n' "$note"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$READING" || { rm -f "$tmp"; return 1; }
}

beat() {
  mkdir -p "$STATE" || return 1
  : > "$BEAT"
}

# running | down | unreadable, never a substituted value: an absent tool or an
# answer that does not parse is reported as itself, because the caller's response
# to "I could not look" must not be the response to "it is not running".
server_state() {
  local out running
  command -v herdr >/dev/null 2>&1 || { printf 'unreadable'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unreadable'; return 0; }
  out=$(fm_backend_herdr_cli "$SESSION" status --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  [ -n "$out" ] || { printf 'unreadable'; return 0; }
  running=$(printf '%s' "$out" | jq -r 'if (.server.running | type) == "boolean" then .server.running else "unreadable" end' 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  case "$running" in
    true) printf 'running' ;;
    false) printf 'down' ;;
    *) printf 'unreadable' ;;
  esac
}

unreadable_cause() {
  command -v herdr >/dev/null 2>&1 || { printf 'the herdr CLI is not on this service PATH'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'jq is not on this service PATH, so herdr status cannot be parsed'; return 0; }
  printf 'herdr status --json for session %s returned nothing usable' "$SESSION"
}

cap_server_log() {
  local size
  [ -f "$SERVER_LOG" ] || return 0
  size=$(wc -c < "$SERVER_LOG" 2>/dev/null | tr -d ' ') || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$SERVER_LOG_MAX_BYTES" ] || return 0
  cp -f "$SERVER_LOG" "$SERVER_LOG.1" 2>/dev/null || true
  : > "$SERVER_LOG" 2>/dev/null || return 0
  log "server output for session $SESSION reached ${size} bytes; kept one copy at $SERVER_LOG.1 and truncated $SERVER_LOG"
}

# Start the server in a session of its OWN.  setsid is the mechanism, and the
# recorded `detach=` field is how a reader can tell which one was used rather
# than assuming the stronger one.  The started process re-enters this script's
# __serve arm so the command itself keeps its single owner in the adapter.
start_detached() {
  mkdir -p "$STATE" 2>/dev/null || true
  cap_server_log
  if command -v setsid >/dev/null 2>&1; then
    setsid "$RUNTIME_PATH" __serve "$SESSION" >>"$SERVER_LOG" 2>&1 </dev/null &
    LAST_DETACH="setsid"
    return 0
  fi
  # nohup is weaker - it only ignores SIGHUP and leaves the process in this
  # session's process group - so a home without setsid keeps a runtime that a
  # group-wide signal can still reach.  It is recorded rather than smoothed over.
  nohup "$RUNTIME_PATH" __serve "$SESSION" >>"$SERVER_LOG" 2>&1 </dev/null &
  LAST_DETACH="nohup"
  return 0
}

wait_for_running() {
  local deadline
  deadline=$(( $(date +%s) + START_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(server_state)" = running ] && return 0
    sleep 0.5
  done
  [ "$(server_state)" = running ]
}

# One supervision pass.  Returns 0 whatever it found: this loop reports, it does
# not fail out of existence, because a runtime it cannot read still needs an
# owner watching for the moment it can.
supervise_once() {
  local state confirm now cause
  cap_server_log
  state=$(server_state)
  case "$state" in
    running)
      [ "${LAST_STATE:-}" = running ] || log "runtime for session $SESSION is running (adopted, not restarted)"
      LAST_STATE=running
      BACKOFF=$BASE_BACKOFF
      write_reading running "the herdr runtime for session $SESSION is up"
      return 0
      ;;
    unreadable)
      cause=$(unreadable_cause)
      [ "${LAST_STATE:-}" = unreadable ] || log "runtime state for session $SESSION is unreadable: $cause"
      LAST_STATE=unreadable
      write_reading unreadable "$cause"
      return 0
      ;;
  esac

  # A single `down` is not enough to act on: a status call can lose a race with a
  # server that is still binding, and a start against a live socket is exactly
  # the mistake that would cost a fleet its workers.  Confirm it once more.
  sleep "$CONFIRM_SLEEP"
  confirm=$(server_state)
  if [ "$confirm" != down ]; then
    LAST_STATE=$confirm
    write_reading "$confirm" "a first reading of down did not hold on confirmation"
    return 0
  fi

  now=$(date +%s)
  if [ "${LAST_START_AT:-0}" -gt 0 ] && [ $((now - LAST_START_AT)) -lt "${BACKOFF:-$BASE_BACKOFF}" ]; then
    LAST_STATE=down
    write_reading down "the runtime is down and the next start attempt is held off for $(( BACKOFF - (now - LAST_START_AT) ))s"
    return 0
  fi

  LAST_START_AT=$now
  STARTS=$(( ${STARTS:-0} + 1 ))
  start_detached
  if wait_for_running; then
    log "started the herdr runtime for session $SESSION detached ($LAST_DETACH), attempt $STARTS"
    LAST_STATE=running
    BACKOFF=$BASE_BACKOFF
    write_reading running "started detached ($LAST_DETACH) after finding the runtime down"
    return 0
  fi
  log "start attempt $STARTS for session $SESSION did not report a running server within ${START_TIMEOUT}s"
  LAST_STATE=down
  BACKOFF=$(( ${BACKOFF:-$BASE_BACKOFF} * 2 ))
  [ "$BACKOFF" -le "$MAX_BACKOFF" ] || BACKOFF=$MAX_BACKOFF
  write_reading down "a detached start ($LAST_DETACH) did not report a running server within ${START_TIMEOUT}s"
  return 0
}

# The detached server itself.  Deliberately minimal: it exists so the start can
# go through setsid, which needs an executable rather than a shell function, and
# so the herdr call keeps exactly one owner in the adapter.
if [ "${1:-}" = __serve ]; then
  [ "$#" -eq 2 ] || { echo "usage: $(basename "$0") __serve <session>" >&2; exit 2; }
  exec_session=$2
  log "serving herdr session $exec_session (pid $$, sid $(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')); its output goes to $SERVER_LOG"
  fm_backend_herdr_cli "$exec_session" server
  exit $?
fi

[ "$#" -eq 0 ] || { echo "usage: $(basename "$0") [__serve <session>]" >&2; exit 2; }

cleanup() {
  trap - HUP INT TERM
  case "${SLEEP_PID:-}" in
    ''|*[!0-9]*) ;;
    *) kill -TERM "$SLEEP_PID" 2>/dev/null || true ;;
  esac
  # The runtime is deliberately left running: this process owns the WATCH, never
  # the server, and stopping the server here would end every worker on the home.
  log "owner stopping; the herdr runtime for session $SESSION is left running"
  if [ "$(sed -n 's/^pid=//p' "$RECORD" 2>/dev/null | head -1)" = "$$" ]; then
    rm -f "$RECORD"
  fi
  exit 0
}
trap cleanup HUP INT TERM

# A previous owner's reading is not this owner's reading, and leaving it behind
# lets a convergence report a runtime state that nothing currently watching has
# established.  It is dropped here, so the first thing any reader sees from this
# owner is something this owner actually looked at.
mkdir -p "$LOCKDIR" 2>/dev/null || true
rm -f "$READING"
write_record || { echo "error: could not record the herdr runtime owner under $LOCKDIR" >&2; exit 1; }
beat || { echo "error: could not write the herdr runtime beacon under $STATE" >&2; exit 1; }
BACKOFF=$BASE_BACKOFF
STARTS=0
LAST_START_AT=0
LAST_DETACH=none

if [ "${FM_HERDR_RUNTIME_ONCE:-0}" = 1 ]; then
  supervise_once
  beat
  exit 0
fi

SLEEP_PID=
while :; do
  supervise_once
  beat
  # A foreground `sleep` would defer the exit trap until the whole interval had
  # elapsed, so a convergence that replaces this owner would wait a full poll for
  # it to go - and the replacement would meanwhile find a live record and beacon
  # belonging to a process on its way out.  Backgrounding the sleep and waiting
  # on it lets the signal land at once.
  sleep "$POLL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
done
