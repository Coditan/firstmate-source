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
TMUX_CMD="${FM_SEAT_TMUX:-${FM_TMUX_COMMAND:-tmux}}"
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
case "$SUBMIT_SLEEP" in ''|.|*[!0-9.]*|*.*.*) SUBMIT_SLEEP=0.4 ;; esac
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
# shellcheck source=bin/fm-seat-presence-lib.sh
. "$SCRIPT_DIR/fm-seat-presence-lib.sh"

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
    # What this process was STARTED with, recorded so a later convergence can
    # compare it, exactly as bin/fm-watch.sh records the same three for the
    # watcher.  A keeper receives its version and PATH as launch arguments that
    # would otherwise leave no trace at all, so without this record the keeper
    # tier could never reconverge on a self-update and would keep running the
    # bytes it started with.
    printf 'manager=%s\n' "${FM_SEAT_RESPAWNER_MANAGER:-session}"
    printf 'source-version=%s\n' "${FM_SEAT_RESPAWNER_SOURCE_VERSION:-unknown}"
    printf 'service-path=%s\n' "${FM_SEAT_RESPAWNER_SERVICE_PATH:-}"
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
  local cmd socket shell_command pane
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

first_turn_pending() {
  [ -f "$FIRST_TURN" ] && [ ! -L "$FIRST_TURN" ]
}

# Add <key>=<now> to the pending record, atomically, leaving what is already in
# it alone. fm_retry_kv_get reads the first match, so a key is only ever marked once.
first_turn_mark() {  # <key>
  local tmp
  first_turn_pending || return 1
  tmp=$(mktemp "$FIRST_TURN.XXXXXX") || return 1
  { cat -- "$FIRST_TURN" && printf '%s=%s\n' "$1" "$(date +%s)"; } > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FIRST_TURN" || { rm -f -- "$tmp"; return 1; }
}

abandon_first_turn() {  # <reason>
  first_turn_pending || return 0
  rm -f -- "$FIRST_TURN"
  log "first turn dropped: $1"
}

# A STANDING RECORD IS NOT A PANE THAT IS THERE, so the one probe that can say
# so writes it down. deliver_first_turn deliberately KEEPS the record on every
# probe answer that is not a confident absence, because "I could not ask" must
# never release a launch beside a seat that may be sitting there. That same
# refusal means the record survives an endpoint whose tmux server has exited, so
# reading the record as evidence of an open pane converts a reading nobody could
# take into a fact - which is exactly what bin/fm-seat-presence-lib.sh refuses to
# do for the lock, and why the alarm has five verdicts rather than two. Only
# rc=0, a CONFIRMED pane, marks; the mark is written once and never cleared,
# because a pane that was confirmed present and later became unreadable is still
# the best answer this component has.
first_turn_confirm_pane() {
  [ -z "$(fm_retry_kv_get "$FIRST_TURN" pane-seen 2>/dev/null || true)" ] || return 0
  first_turn_mark pane-seen || true
}

# AND A CONFIRMATION IS NOT A CONFIRMATION THAT IS STILL GOOD, which is the same
# rule one door further along. `pane-seen` above is durable on purpose: it is the
# standing answer to "was a pane ever confirmed here", and nothing clears it. But
# a present-tense sentence may not rest on it, because the reading behind it can
# be arbitrarily old - a seat confirmed on cycle 2 whose tmux server then exits
# leaves that mark standing through every unanswerable probe after it, and on a
# container restart state/ carries the mark across from a process that died with
# the old server. So the LAST probe outcome is recorded separately and REWRITTEN
# every cycle rather than added once, and it is what a claim about right now is
# allowed to read. one_cycle runs deliver_first_turn immediately before the bound
# test, so the value the give-up reads was taken on that same cycle.
first_turn_record_probe() {  # <rc>
  local tmp
  first_turn_pending || return 1
  tmp=$(mktemp "$FIRST_TURN.XXXXXX") || return 1
  grep -v '^pane-probe=' -- "$FIRST_TURN" > "$tmp" 2>/dev/null
  printf 'pane-probe=%s\n' "$1" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FIRST_TURN" || { rm -f -- "$tmp"; return 1; }
}

# Always returns 0. The record is retired only when the turn has LANDED (a seat
# holds this home), when the pane is confidently gone, or when the deadline
# passes - never merely because the keystroke was typed, because session start
# rather than the keystroke is what makes a first mate, and one_cycle holds the
# next launch for exactly as long as this record stands.
deliver_first_turn() {
  local pane server at age submitted composer encoded verdict rc
  first_turn_pending || return 0
  pane=$(fm_retry_kv_get "$FIRST_TURN" pane 2>/dev/null || true)
  server=$(fm_retry_kv_get "$FIRST_TURN" server 2>/dev/null || true)
  at=$(fm_retry_kv_get "$FIRST_TURN" at 2>/dev/null || true)
  submitted=$(fm_retry_kv_get "$FIRST_TURN" submitted 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  age=$(( $(date +%s) - at ))

  # The same three-verdict reading one_cycle acts on, asked of the same lock.
  # A seat holding this home settles the record, whichever seat it is; a reading
  # that could not be taken settles nothing and must not lead on to the typing
  # below, because a first mate this process cannot see is still a first mate.
  fm_seat_presence "$STATE/.lock"
  case "$FM_SEAT_PRESENCE" in
    present)
      rm -f -- "$FIRST_TURN"
      log "a seat now holds this home; the first turn recorded for pane $pane is settled"
      return 0 ;;
    unmeasured)
      return 0 ;;
  esac
  # The pane's own address, established before the deadline test below because
  # that test now asks whether the pane is still there.
  local FM_TMUX_SERVER_IDENTITY=$server FM_TMUX_COMMAND=$TMUX_CMD
  export FM_TMUX_SERVER_IDENTITY FM_TMUX_COMMAND

  # Bounded, and abandoned out loud. A first turn that never lands must not be
  # retried forever in silence, and the absence keeps being reported either way.
  #
  # THE ONE CASE THE DEADLINE MUST NOT END. A pane that was typed into and is
  # still there holds a live agent part-way through its session start. Retiring
  # the record for it would release the launch hold, and the very next cycle
  # would find presence still absent and delivery still undeliverable and open a
  # SECOND seat beside the live one - the orphan this record exists to prevent,
  # arriving through the deadline rather than through a verdict. So the hold
  # keeps standing while both facts hold: the presence arm above still retires
  # the record the moment any seat takes this home, and the confident-absence
  # branch below still retires it the moment the pane goes. Only a CONFIDENT yes
  # holds; an unreachable backend falls through and is abandoned as before,
  # because a hold on a reading nobody could take is a hold on nothing.
  #
  # WAITING IS NOT FREE, AND THAT IS WHAT BOUNDS THIS. one_cycle spends a HOLD on
  # every cycle a wait is otherwise due, and holds count toward the same bound as
  # launches, so a first turn that never lands reaches that bound and gives up out
  # loud instead of waiting forever in silence. It is not counted as a launch,
  # because it is not one. The `held` mark below is also what
  # bin/fm-seat-respawner-service.sh reports as `holding:`, so the captain is told
  # a seat was started and has not finished starting rather than that a restart is
  # under way.
  if [ "$age" -ge "$FIRST_TURN_DEADLINE" ]; then
    if [ -n "$submitted" ] && [ -n "$pane" ]; then
      rc=0
      fm_backend_target_exists tmux "$pane" || rc=$?
      first_turn_record_probe "$rc" || true
      if [ "$rc" -eq 0 ]; then
        first_turn_confirm_pane
        if [ -z "$(fm_retry_kv_get "$FIRST_TURN" held 2>/dev/null || true)" ]; then
          first_turn_mark held || true
          log "first turn held past ${age}s: pane $pane was given its turn and is still open; not launching beside it"
        fi
        return 0
      fi
    fi
    rm -f -- "$FIRST_TURN"
    if [ -n "$submitted" ]; then
      log "first turn abandoned after ${age}s: pane $pane was given its turn and never took this home's lock"
    else
      log "first turn abandoned after ${age}s: pane $pane never presented an empty agent composer"
    fi
    return 0
  fi
  [ -n "$pane" ] || { rm -f -- "$FIRST_TURN"; return 0; }

  rc=0
  fm_backend_target_exists tmux "$pane" || rc=$?
  first_turn_record_probe "$rc" || true
  # Only a CONFIDENT absence retires the record. Every other non-zero answer
  # means the backend could not be asked, and reading "I could not ask" as "the
  # pane is gone" would release the next launch to open a second window beside a
  # seat that is still sitting there - the orphan this record exists to prevent.
  if [ "$rc" -eq 1 ]; then
    rm -f -- "$FIRST_TURN"
    log "first turn abandoned: pane $pane no longer exists"
    return 0
  fi
  [ "$rc" -eq 0 ] || return 0
  first_turn_confirm_pane
  # Typed once: a seat mid-session-start must not be typed into a second time.
  [ -z "$submitted" ] || return 0
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
    # The record stands even when the mark cannot be written. At most one
    # retype follows, which the composer-empty test above already makes
    # unlikely; dropping it instead would release the launch hold on a seat
    # that is at this moment running its session start.
    first_turn_mark submitted \
      || log "first turn was typed into pane $pane but could not be marked; the record stands"
    log "first turn submitted to pane $pane"
  else
    log "first turn was not confirmed (verdict=${verdict:-unknown}); leaving it to the next cycle"
  fi
  return 0
}

# THE GIVE-UP RECORD BELONGS TO THE EPISODE BEING COUNTED, AND THIS IS WHERE
# THAT IS MADE TRUE.
#
# Everything that reads state/.seat-respawn-giveup - this file's own early
# return in fm_retry_giveup_emit, and the `gave-up:` verdict in
# bin/fm-seat-respawner-service.sh - takes its key matching the attempt
# record's as "this episode is spent". Nothing maintained that. clear_episode
# is the only other remover and it fires on stay-down, presence turning
# `present`, or a status that is no longer undeliverable; a condition key that
# merely CHANGES takes none of those doors, and a dead seat's blocked reason is
# not stable - a bare shell in the published pane and one unanswerable tmux
# probe are different reasons and therefore different keys. So the reasons
# flipping A-B-A left a give-up written for the first A episode standing while a
# second one counted under the same key, which reported a launching restarter as
# one that had stopped and silenced the new episode's own give-up.
#
# Every spend of an episode passes through here, launches and holds alike, and
# this is where the new key actually lands - so a give-up naming a different
# condition is dropped as the record is written. The shared library's write is
# deliberately not where this lives: what a stale give-up means is this
# supervisor's, and the read that would pair with it is a reader, asked on
# cycles that spend nothing, so a probe still does not mutate what it measures.
write_attempt_record() {  # <key> <count> <next> <holds>
  fm_retry_write_attempts "$ATTEMPTS" "$1" "$2" "$3" "$4" || return 1
  [ "$(fm_retry_kv_get "$GIVEUP" key 2>/dev/null || true)" = "$1" ] || rm -f "$GIVEUP"
}

clear_episode() {
  fm_retry_clear_episode "$ATTEMPTS" "$GIVEUP"
}

# THE ONE THING THIS FINDING MAY NOT DO IS OVERSTATE WHAT WAS TRIED.
# It is read on a phone, by someone deciding whether a machine is worth walking
# to. "Exhausted five launch attempts" and "made one launch and then waited out
# the seat it had already started" call for opposite actions, and the second is
# what a held episode actually is: the pane is open, an agent is in it, and the
# only reason nothing more happens is that opening a second seat beside a live
# one is the orphan this whole component exists to prevent. That refusal is the
# fact he can act on, so it is stated rather than left to be inferred from
# silence - the same standard by which the alarm on this branch declines to print
# `armed` for a home it deliberately did not arm.
#
# WHICH CLAIM IS SELECTED IS DECIDED BY WHAT WAS ACTUALLY ESTABLISHED, NEVER BY
# THE HOLD COUNT AND NEVER BY A RECORD MERELY STANDING.
# A held cycle is evidence that a pane WAS open then, and says nothing about now.
# A standing record says almost as little, because deliver_first_turn keeps the
# record on every probe answer that is not a confident absence - so an endpoint
# whose tmux server has exited leaves a record standing forever while no probe
# after the first can be answered at all. There are therefore THREE things this
# can honestly say, and each has its own sentence: the pane was confirmed present
# and a second seat is being refused beside it; a seat was started and whether its
# pane is still there could not be read; or no record stands at all. The middle one
# exists because collapsing it into either neighbour is the same defect in
# opposite directions - the fleet's rule, enforced for the lock by
# bin/fm-seat-presence-lib.sh and for the seat by the alarm's five verdicts, is
# that a reading nobody could take is never reported as one that was.
#
# THE FIRST SENTENCE IS PRESENT TENSE, SO IT READS THIS CYCLE'S PROBE AND NOT THE
# DURABLE MARK. `pane-seen` says a pane was confirmed at some point and is never
# cleared, which is right for what it is and wrong for "is still open": the seat
# confirmed on an early cycle whose tmux server then exits keeps that mark through
# every unanswerable probe afterwards, and that is the dominant shape of a held
# episode rather than a corner of it. So the selector is `pane-probe`, rewritten
# on every cycle by deliver_first_turn, which one_cycle runs immediately before
# the bound test. A confirmation that has gone stale falls to the middle sentence,
# where it belongs; the durable mark is still reported in the measurement, so
# nothing is lost by not letting it speak in the present tense.
#
# REFUTING A SENTENCE IS NOT ENDING THE EPISODE, AND THE REFUTED-BY LINE SAYS
# WHICH IT MEANS. Past the bound, one_cycle returns at the bound test on every
# later cycle: the attempt record still holds launches+holds at MAX_ATTEMPTS for
# this key, so an observation that only disproves a sentence above - the pane
# closing, or a probe of it finally being answered - retires the first-turn
# record and changes nothing about whether another seat is started. Exactly
# three things clear the episode: a changed delivery status for the queued work
# (a new condition key, or work that is deliverable again), presence turning
# `present` when a seat takes this home's lock, and the stay-down marker. They
# are named, because a captain reading this on a phone must not wait for a
# relaunch that cannot come.
#
# The once-per-episode marker, the emit, and the log line are the shared
# library's, because both seat supervisors owe those the same way. Only the
# sentences are this file's, because only this file held a pane.
emit_giveup_finding() {  # <key> <status-line> <launches> <holds> <pane> <ever-confirmed> <last-probe-rc>
  local key=$1 status_line=$2 launches=$3 holds=$4 pane=$5 confirmed=$6 probe=$7 out rc=0
  local claim measurement refuted seen
  seen=no
  [ -z "$confirmed" ] || seen=yes
  [ -n "$pane" ] || seen=none
  measurement="$status_line | launches=$launches holds=$holds pane=${pane:-none} pane-confirmed=$seen pane-probe=${probe:-none}"
  refuted="This episode is cleared by exactly three things: the delivery status for the queued work changes, a seat takes this home's lock, or the stay-down marker is set deliberately. Until one of them happens nothing here launches again."
  if [ -n "$pane" ] && [ "$probe" = 0 ]; then
    claim="The primary firstmate seat respawner stopped retrying this episode at its $MAX_ATTEMPTS-cycle bound after $launches launch attempt(s) and $holds held cycle(s). A seat it started is still open in pane $pane and has not taken this home's lock, so it is deliberately not opening another beside it; this home has an agent and no first mate."
    refuted="The pane above closing refutes the still-open-pane sentence and nothing else: it does not end this episode. $refuted"
  elif [ -n "$pane" ]; then
    claim="The primary firstmate seat respawner stopped retrying this episode at its $MAX_ATTEMPTS-cycle bound after $launches launch attempt(s) and $holds held cycle(s). It started a seat in pane $pane and cannot tell whether that pane is still there: the last probe of it could not be answered, which is what an endpoint whose tmux server has exited looks like. That is not a report that a seat is open and not a report that it is gone; either way this home has no first mate."
    refuted="A probe of the pane above being answered either way refutes the could-not-read sentence and nothing else: it does not end this episode. $refuted"
  else
    claim="The primary firstmate seat respawner exhausted $launches launch attempt(s) for this home and stopped retrying this episode at its $MAX_ATTEMPTS-cycle bound after $holds held cycle(s). No seat it started is still on record, so nothing is being held and no pane is being refused."
  fi
  out=$(fm_retry_giveup_emit "$GIVEUP" "$key" fm-seat-respawner \
    "$claim" \
    "bin/fm-seat-respawner.sh for $FM_HOME" \
    "$measurement" \
    "$refuted") || rc=$?
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
# Deliberately narrow.  It acts only on the `dead` classification published by
# fm_watcher_healthy - this fleet's one owner of that question - never on a
# recorded-version or recorded-PATH mismatch.  Those are convergence decisions
# that belong to a session with the fleet lock, and a background process racing
# one over them would produce two managers fighting over one service.  It is also
# rate-limited, so a watcher that cannot start is retried rather than hammered,
# and skipped entirely on a systemd home where the unit's own Restart=always
# already owns this.
#
# `dead` RATHER THAN THE BOOLEAN, AND A WEDGED-BUT-LIVE WATCHER IS THEREFORE
# LEFT ALONE ON PURPOSE.  fm_watcher_healthy returns non-zero for two states,
# and only one of them is a death: bin/fm-wake-lib.sh classifies a live,
# identity-matched watcher whose beacon has aged out as `beacon-stale`, and
# names machine suspend as the case that necessarily produces it, because a
# frozen host cannot touch a beacon.  Reviving on the boolean would restart a
# watcher that is alive - `ensure` stops it first - and the sweep it kills is
# the one that now carries the seat alarm itself.  When staleness is caused by a
# slow sweep, the replacement is killed the same way and the sweep never
# completes.  So the trade is taken deliberately in the other direction: a
# watcher that is alive but wedged is not restarted here, and is left to a
# session holding the fleet lock, which is the half that may decide it.
revive_watcher_if_dead() {
  local age
  [ "${FM_SEAT_REVIVE_WATCHER:-1}" = 1 ] || return 0
  [ -x "$WATCHER_SERVICE" ] || return 0
  [ "$("$WATCHER_SERVICE" select 2>/dev/null || true)" = keeper ] || return 0
  fm_watcher_healthy "$STATE" "$WATCH" "$WATCHER_GRACE" "$FM_HOME" && return 0
  [ "${FM_WATCHER_HEALTH:-}" = dead ] || return 0
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
  local status_line key now count next delay holds pane seen probe spent
  beat || return 1
  revive_watcher_if_dead
  # The declared stand-down is read BEFORE any pending turn is delivered, and it
  # settles that turn rather than racing it: a marker set after a launch must
  # leave the home unattended, not have the session-start instruction typed into
  # the pane on the next cycle.
  if stay_down; then
    clear_episode
    abandon_first_turn "the stay-down marker was set before it landed"
    log "stay-down marker present; leaving seat down"
    return 0
  fi
  deliver_first_turn
  # PRESENCE, ASKED BEFORE REACHABILITY, AND ONLY AN ABSENCE OPENS A LAUNCH.
  # A home whose lock names a live harness is not missing a seat whatever the
  # delivery verdict says about reaching it - an ordinary busy seat produces
  # `undeliverable:` through the listener's own busy-pane branch. A reading that
  # could not be taken is not an absence either, and this is the half that acts:
  # only the alarm may speak about an unmeasured home, and neither half may
  # start a second seat over one. docs/seat-respawner.md carries the revision.
  fm_seat_presence "$STATE/.lock"
  case "$FM_SEAT_PRESENCE" in
    present)
      clear_episode
      return 0 ;;
    unmeasured)
      # The episode is left exactly as it stands: this half declines to act on a
      # reading it could not take, and saying so out loud is the alarm's, which
      # reports an unmeasured home to the captain on its own cadence.
      return 0 ;;
  esac
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
  holds=$FM_RETRY_ATTEMPT_HOLDS
  now=$(date +%s)
  spent=$((count + holds))
  # THE BOUND IS ON THE EPISODE, NOT ON THE LAUNCHES, and it is tested before
  # anything is spent so a held episode ends the same way a launching one does.
  # A hold used to fall out of the loop above this test and so was bounded by
  # nothing: a first turn that never landed left this home with an agent, no
  # first mate, and no component anywhere willing to say so. The captain ruled
  # the hold stays and the bound applies to it, so both spends count toward
  # MAX_ATTEMPTS while only launches are ever reported as launches.
  if [ "$spent" -ge "$MAX_ATTEMPTS" ]; then
    pane=$(fm_retry_kv_get "$FIRST_TURN" pane 2>/dev/null || true)
    seen=$(fm_retry_kv_get "$FIRST_TURN" pane-seen 2>/dev/null || true)
    probe=$(fm_retry_kv_get "$FIRST_TURN" pane-probe 2>/dev/null || true)
    first_turn_pending || { pane=; seen=; probe=; }
    emit_giveup_finding "$key" "$status_line" "$count" "$holds" "$pane" "$seen" "$probe" || true
    return 0
  fi
  # A seat this respawner already started, still on its way to the lock, is not
  # a reason to start another. The delivery verdict stays undeliverable until
  # session start publishes an endpoint - well past the first backoff - so
  # launching on schedule here would leave a live agent in a window nothing
  # tracks or reports. The wait is paced by the same backoff a launch would take
  # and spends a hold rather than a launch, and FM_SEAT_FIRST_TURN_DEADLINE still
  # frees a pane that never presents a composer.
  if first_turn_pending; then
    if [ "$now" -ge "$next" ]; then
      holds=$((holds + 1))
      delay=$(fm_retry_backoff "$((count + holds))" "$BASE_BACKOFF" "$MAX_BACKOFF")
      next=$((now + delay))
      write_attempt_record "$key" "$count" "$next" "$holds" || return 1
      log "launch held: the seat already started for this episode has not taken this home's lock yet (hold $holds, $((MAX_ATTEMPTS - count - holds)) cycle(s) left before this episode gives up)"
    fi
    return 0
  fi
  if [ "$now" -lt "$next" ]; then
    return 0
  fi
  count=$((count + 1))
  delay=$(fm_retry_backoff "$((count + holds))" "$BASE_BACKOFF" "$MAX_BACKOFF")
  next=$((now + delay))
  write_attempt_record "$key" "$count" "$next" "$holds" || return 1
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
