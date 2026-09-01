#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash.
# Session mode exits after an actionable queue append, while daemon mode keeps
# the external loop alive after the same durable append.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause or
# a firstmate-declared parked terminal task is the separate idle absorb case and
# re-surfaces only on its long bounded cadence. A run the authoritative run-step
# reports stopped at a DECISION GATE still surfaces on first sight - nothing has
# relayed that gate yet - but does not ESCALATE as a wedge afterwards, since
# idling at a gate is the correct behavior; that hold lasts only as long as the
# worker's agent PROCESS is confirmed alive, because a crashed worker leaves the
# run parked identically and forever (parked_gate_liveness_class).
# A new status write still surfaces immediately in normal mode and clears parked
# tracking.
# While state/.afk exists, the away daemon owns triage and this watcher queues
# every actionable wake without running the more expensive normal-mode
# classifiers, though signal records are collapsed to one per task in away mode
# too.
# Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause or firstmate-declared parked terminal
#                          wait is absorbed instead with its own long re-surface
#                          cadence, never as a wedge; parked rechecks falling due
#                          together share one record, keyed parked-recheck, that
#                          lists the windows once with one shared age (a range
#                          when they differ).
#                          A run parked at a decision gate
#                          whose worker is confirmed alive surfaces its first sighting
#                          like any other stopped crew, then holds the wedge ladder on
#                          the same bounded-recheck terms as an active run. Only when
#                          no absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Once one possible-wedge alarm for a pane/state
#                          has surfaced, unchanged later rungs are retained in
#                          state/.wedge-alarm-history but not delivered again
#                          until FM_WEDGE_REPEAT_RESURFACE_SECS elapses. A changed
#                          state re-arms immediate delivery. Unless afk is active.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: context-ceiling: <what to do>
#                          this session's own context passed the captain's ceiling
#                          at a quiet boundary. The payload carries the branch:
#                          reset (with the exact commands), ask (the captain has
#                          been active, or away mode owns delivery), or that the
#                          ceiling cannot be measured at all - which is reported
#                          rather than skipped, because an unmeasurable ceiling is
#                          an unenforced one. See docs/context-reset.md.
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: certsync health: unhealthy: <reason>
#   check: certsync health: cannot run: <reason>
#                          heartbeat found a confirmed unhealthy certsync status
#                          JSON reading, found a healthy reading with a stale
#                          heartbeat, or could not read certsync status at all,
#                          and surfaced it through the ordinary durable check
#                          wake path
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-state-marker-prune-lib.sh
. "$SCRIPT_DIR/fm-state-marker-prune-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# Context-ceiling measurement and the reset/ask branch. The watcher OBSERVES the
# threshold because the alternative - firstmate remembering to check a number -
# has no failure surface at all: nothing anywhere reports a rule that was never
# applied, and the measured history is that it drifts. Here the observation lands
# in the durable wake queue, which firstmate is already structurally obliged to
# drain, and whose own staleness is already alarmed.
# shellcheck source=bin/fm-context-lib.sh
. "$SCRIPT_DIR/fm-context-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
WATCH_DAEMON=${FM_WATCH_DAEMON:-0}
case "$WATCH_DAEMON" in 1|true|TRUE|yes|YES) WATCH_DAEMON=1 ;; *) WATCH_DAEMON=0 ;; esac
# Legacy session-owned watcher launches may still provide an explicit owner pid.
# The external daemon never does, and skips this compatibility parent check even
# if an inherited environment accidentally carries the variable.
WATCH_ARM_OWNER_PID=${FM_WATCH_ARM_OWNER_PID:-}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes either the compatible
# one-shot runtime or the external daemon loop selected above.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
  signal_stat_sig() { stat -L -f '%z:%Fm' "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
  signal_stat_sig() { stat -L -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
CERTSYNC_HEALTH_TIMEOUT=${FM_CERTSYNC_HEALTH_TIMEOUT:-5}  # seconds allowed for certsync heartbeat health
CERTSYNC_HEALTH_RESURFACE=${FM_CERTSYNC_HEALTH_RESURFACE:-3600}  # seconds before repeating unchanged unhealthy or cannot-run certsync
CERTSYNC_HEARTBEAT_MAX_AGE=${FM_CERTSYNC_HEARTBEAT_MAX_AGE:-7200}  # certsync heartbeat older than this reads as unhealthy (daemon stopped / syncs failing); 2x the 3600s max sync interval; 0 disables
CONTEXT_CHECK_INTERVAL=${FM_CONTEXT_CHECK_INTERVAL:-300}  # seconds between context-ceiling reads
# Shared Bridge detection and enqueue-before-marker deduplication.  The
# standalone frequency monitor loads this same library, and its own lock keeps
# the two independent processes from surfacing one signature twice.
# shellcheck source=bin/fm-bridge-inbox-lib.sh
. "$SCRIPT_DIR/fm-bridge-inbox-lib.sh"
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a stale pane past the threshold whose
# crew is no longer provably working, or anything unknown) is written to the
# durable queue. A captain-relevant status the signal path ALREADY surfaced does
# not wake firstmate a second time when the same crew's pane then settles stale
# (status_already_surfaced), and an idle pane whose run is still active does not
# climb the wedge ladder (wedge_timer_check).
# In daemon mode the loop continues and the delivery stub wakes the model.
# The same classifier (fm-classify-lib.sh) backs the away-mode daemon; while
# state/.afk exists this watcher enqueues every actionable wake (signal records
# still collapsed to one per task) and skips the costly provably-working read so
# the away daemon can triage each new queue record.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A crew that DECLARED a pause (paused: <reason>, fm-classify-lib.sh), or a terminal
# task that firstmate marks state/.parked-<window-key> after relaying its outcome,
# is idling on a known external wait. Its stale pane is absorbed rather than
# wedge-escalated and re-surfaces once for a recheck every PAUSE_RESURFACE_SECS -
# far longer than the wedge threshold, but finite so a forgotten wait cannot rot
# invisibly. Status writes and metadata changes clear a parked declaration.
# Parked rechecks that come due together are carried on ONE record naming every
# task it covers, not one record per task (parked_recheck_enqueue). The cadence
# is per task and unchanged; only the number of records carrying it is.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Delivery bound for an unchanged possible-wedge finding that has already
# surfaced once. The watcher still evaluates it every STALE_ESCALATE_SECS and
# appends every candidate to WEDGE_ALARM_HISTORY; it suppresses delivery only.
# Default to the existing one-hour pause/hold cadence so all long-idle rechecks
# share the same operational horizon while keeping an independent override for
# a fleet that wants wedge repeats sooner. A continuously unchanged real wedge
# therefore re-surfaces no later than this bound plus one stale interval and poll.
WEDGE_REPEAT_RESURFACE_SECS=${FM_WEDGE_REPEAT_RESURFACE_SECS:-$PAUSE_RESURFACE_SECS}
# Append-only delivery history for possible-wedge candidates. Unlike the
# size-capped triage debug log, this record is never truncated: suppressed
# candidates must remain inspectable. Suppression fails open to delivery when
# this append cannot be completed.
WEDGE_ALARM_HISTORY=${FM_WEDGE_ALARM_HISTORY:-$STATE/.wedge-alarm-history}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled and the loop
# reverts to polling.
# A disabled capability is re-probed periodically because daemon mode may keep
# one watcher process alive indefinitely.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
EVENT_CAP_REPROBE_SECS=${FM_EVENT_CAP_REPROBE_SECS:-300}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll).
# It is keyed by "<backend>:<session>" and also expires after the configured
# re-probe interval when the capability is disabled.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0
_event_cap_probe_epoch=0

# afk_present: 0 while the away-mode flag exists.
# When set, the away daemon owns triage, so the watcher must enqueue every
# actionable wake (one signal record per task) and let the daemon classify it
# instead of absorbing it here.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Retain one possible-wedge candidate exactly as classified.
# Format: epoch<TAB>surfaced|suppressed<TAB>window<TAB>reason.
# The watcher singleton is the only writer, so append order is event order.
wedge_alarm_history_append() {  # <disposition> <window> <reason>
  local disposition=$1 win=$2 reason=$3
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$disposition" "$win" "$reason" 2>/dev/null >> "$WEDGE_ALARM_HISTORY"
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

# window_harness: the harness recorded in the meta whose window= matches <w>,
# empty when no matching meta carries the field. Read only to scope the codex
# static-pane liveness backstop in pause_state_class - never to pick a busy
# regex, which stays harness-agnostic.
window_harness() {
  local w=$1 meta harness
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    harness=$(grep '^harness=' "$meta" | cut -d= -f2- || true)
    echo "$harness"
    return 0
  fi
  echo ""
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Report a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
# A session-owned one-shot watcher exits as before.  The external service sets
# FM_WATCH_DAEMON=1, records WAKE_PENDING, and lets the main loop advance to its
# next cycle without restarting the process.
WAKE_PENDING=0
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  if [ "$WATCH_DAEMON" -eq 1 ]; then
    WAKE_PENDING=1
    return 0
  fi
  exit 0
}

# Consecutive wedge-escalation count for one unchanged pane/current-state class.
# Every rung is retained in WEDGE_ALARM_HISTORY, while delivery happens on the
# first rung, a changed class, or the bounded repeat cadence. At
# FM_WEDGE_DEMAND_INSPECT_COUNT (default 3), wedge_timer_check adds a
# "demand-deep-inspection" marker so the retained finding and the next bounded
# delivery say that this is no longer a one-off. Reset wherever pane/hash state
# becomes genuinely active and whenever the authoritative class changes.
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# ladder_hold: the one implementation of "this stale pane has a positive reason not
# to climb the wedge ladder". Refreshes the escalation timer so the reason is
# RE-READ every window rather than trusted once, and surfaces one bounded recheck
# whenever the pane has been frozen for a full PAUSE_RESURFACE_SECS - measured on
# the frozen hash's own age, not on the timer this hold keeps refreshing, so a hold
# can never postpone its own recheck. A transition into this positive class resets
# the escalation counter; an unchanged hold never touches it, so a held pane never
# climbs toward demand-deep-inspection. The shared .wedgeheld marker records both
# the current observed class and the last delivery/recheck mtime, so a later class
# change re-arms an immediate alarm instead of inheriting the old class's throttle.
# <situation> names the evidence in the wake text and the triage log; <next-step>
# is what firstmate should confirm. Both callers pass their own, because "the run
# is running" and "the run is parked at a gate" need different confirmations.
ladder_hold() {  # <window> <since-file> <triage-label> <class> <situation> <next-step>
  local win=$1 since_file=$2 label=$3 class=$4 situation=$5 next_step=$6
  local wkey hold_age rf prior reason
  date +%s > "$since_file"
  wkey=$(window_state_key "$win")
  hold_age=$(age_of "$STATE/.stale-$wkey")
  rf="$STATE/.wedgeheld-$wkey"
  prior=$(cat "$rf" 2>/dev/null || true)
  if [ "$prior" != "$class" ]; then
    printf '%s' "$class" > "$rf"
    # With no prior observation, preserve the frozen pane's existing cadence
    # rather than starting a fresh full window at this first re-read. A genuine
    # class transition has a prior value and deliberately re-anchors at now.
    if [ -z "$prior" ] && [ -e "$STATE/.stale-$wkey" ]; then
      touch -r "$STATE/.stale-$wkey" "$rf" 2>/dev/null || true
    fi
  fi
  if [ "$hold_age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$(age_of "$rf")" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (pane unchanged ${hold_age}s while $situation - bounded recheck on a long cadence, not a wedge escalation; $next_step)"
    fm_wake_append stale "$win" "$reason" || exit 1
    printf '%s' "$class" > "$rf"
    wake "$reason"
    return
  fi
  triage_log "absorbed $label ($situation, ladder held): $win"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Shared by both places a hash
# can be absorbed this way: the plain non-terminal path, and the
# stale_is_terminal-overridden path (a captain-relevant status-log line that an
# active run/busy pane outranked).
#
# One bounded crew-state re-read gates the escalation itself. The absorb verdict
# taken at classification time is by definition at least STALE_ESCALATE_SECS old
# by the time this fires, and a single long no-mistakes STEP - a test or review
# round running for minutes - legitimately holds a quiet pane for all of it: the
# live 2026-07-26 evidence had this ladder climb all the way to its
# demand-deep-inspection rung against a run whose test step was active, agent
# alive, last activity 55s earlier. So an ACTIVE run never climbs the ladder at
# all, instead of climbing two rungs and then being told at the third not to
# trust the run-step. The ladder is untouched for a crew with NO active run: the
# read is what distinguishes them, it runs once per interval rather than once per
# poll, and the moment a run ends or dies the crew stops reading as working and
# the next elapse escalates on the unchanged schedule.
#
# A run PARKED at a decision gate holds the ladder on the same terms, with one
# extra requirement the active-run case does not need: the gate reading is only
# trusted while agent liveness confirms a worker is still there to answer it
# (parked_gate_liveness_class). Both holds are one function - ladder_hold above.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason wtask wclass
  local wkey state_file prior_class same_class history_failed
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        wtask=$(window_to_task "$win" "$STATE")
        wclass=$(crew_absorb_class "$wtask")
        # The gate reading is re-corroborated against agent liveness HERE, not
        # carried over from the classification that started this timer: a worker
        # can die at any point during the hold, and a stale `alive` from minutes
        # ago is exactly the evidence that would let it rot. A dead or unreadable
        # agent falls straight through to the ordinary escalation below, on the
        # unchanged timings. The codex static-pane upgrade is deliberately NOT
        # applied here - it absorbs a first sighting only, and a genuinely wedged
        # codex must still reach demand-deep-inspection.
        [ "$wclass" = parked ] && wclass=$(parked_gate_liveness_class "$win")
        wkey=$(window_state_key "$win")
        state_file="$STATE/.wedgeheld-$wkey"
        prior_class=$(cat "$state_file" 2>/dev/null || true)
        same_class=0
        if [ "$prior_class" = "$wclass" ]; then
          same_class=1
        else
          # The escalation count describes consecutive observations of one
          # pane/state, not merely one pane. A changed authoritative class is a
          # new finding and must start at escalation 1 with no inherited quiet
          # window from the prior class.
          rm -f "$escalation_file"
        fi
        if [ "$wclass" = degraded ]; then
          # The crew state was never read - a tool the reader needs is missing
          # from this service's PATH. Climbing the ladder here would escalate a
          # possible wedge on a reading nobody took, which is exactly what this
          # home did roughly every four minutes for weeks. Report the broken
          # instrument on the bounded cadence and leave the ladder alone.
          [ "$same_class" -eq 1 ] || printf '%s' degraded > "$state_file"
          date +%s > "$since_file"
          handle_degraded_stale "$win" "$wtask" "$label"
          return
        fi
        if [ "$wclass" = working ]; then
          # Bounded insurance against the one way an active run can lie: a run
          # whose agent died mid-step keeps reporting `running` indefinitely, and
          # holding the ladder on that reading alone would let a dead crew rot
          # invisibly - so the hold earns one bounded recheck per window.
          ladder_hold "$win" "$since_file" "$label" working \
            "the run still reports active" \
            "confirm the run is really progressing"
          return
        fi
        if [ "$wclass" = parked ]; then
          # The run is stopped at a decision gate AND the worker is confirmed
          # alive: the pane is idle because the crew asked a question and waited,
          # which is the behavior its brief requires. Hold the ladder on the same
          # terms as an active run - including the bounded recheck, so a gate
          # nobody ever answers still cannot rot invisibly.
          ladder_hold "$win" "$since_file" "$label" parked \
            "the run is parked at a decision gate and this worker is still alive" \
            "answer the gate or confirm the decision is still pending"
          return
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        # The first observation, any changed state, and a repeat past the
        # configured bound all deliver. An unchanged repeat inside the bound is
        # retained but absorbed. Record BEFORE suppressing: if the append-only
        # history cannot be written, suppression fails open and the ordinary
        # durable queue carries the alarm instead of letting quiet masquerade as
        # correctness.
        if [ "$same_class" -eq 1 ] && [ "$(age_of "$state_file")" -lt "$WEDGE_REPEAT_RESURFACE_SECS" ]; then
          if wedge_alarm_history_append suppressed "$win" "$reason"; then
            rm -f "$since_file"
            triage_log "absorbed unchanged possible wedge (delivery suppressed, history retained): $win escalation $n"
            return
          fi
          history_failed=1
          reason="$reason (repeat suppression disabled: append-only wedge alarm history could not be written)"
        else
          history_failed=0
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        if [ "$history_failed" -eq 0 ]; then
          wedge_alarm_history_append surfaced "$win" "$reason" \
            || triage_log "wedge alarm history append failed after durable queueing: $win"
        else
          # The queue is already the durable fail-open record. A second append
          # attempt would only repeat the same filesystem error.
          triage_log "wedge alarm history unavailable; delivered unchanged possible wedge fail-open: $win"
        fi
        printf '%s' "$wclass" > "$state_file"
        rm -f "$since_file"
        wake "$reason"
        return
      fi
      ;;
  esac
}

# Absorb a stale pane whose crew is in a DECLARED external-wait pause (paused:),
# and re-surface it once every PAUSE_RESURFACE_SECS for a recheck so it cannot rot
# invisibly. Called on any stale poll once the crew is known paused (first sight,
# after crew_absorb_class; and repeat sights, gated by the .paused-<key> flag), so
# it must be cheap: it NEVER re-reads the crew state. The re-surface age is anchored
# on the pause's own STATUS-FILE mtime, not a per-hash marker, so a churny idle pane
# (a ticking clock, a token counter) cannot keep resetting the cadence the way a
# hash-tied timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.wedgeheld-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
    return
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

# Report the one condition no other branch here can express: this home cannot
# read its crews' state at all, because a tool bin/fm-crew-state.sh needs is not
# on the PATH this service runs with. Every other stale verdict is a claim about
# the CREW; this one is a claim about the machine, so it must not be dressed as a
# wedge, must not climb the escalation ladder, and must not be silently absorbed
# either - a supervisor that cannot see is the most urgent thing to say.
#
# Bounded to the PAUSE_RESURFACE_SECS cadence per window, for the same reason the
# declared-pause path is: the condition persists until someone repairs the
# toolchain, and repeating it every poll would spend a model turn on unchanged
# news. The throttle marker is deliberately time-only and is cleared by NO reset
# path: a broken toolchain is a standing condition, not an episode, so a pane
# that goes busy and stale again must not earn it a fresh report. The reason
# names the missing tool, so it costs one extra read of the authoritative
# helper - affordable precisely because it is throttled.
handle_degraded_stale() {  # <window> <task> <triage-label>
  local win=$1 task=$2 label=$3 key rf line detail reason
  key=$(window_state_key "$win")
  rf="$STATE/.degraded-$key"
  if [ "$(age_of "$rf")" -lt "$PAUSE_RESURFACE_SECS" ]; then
    triage_log "absorbed $label (crew state unreadable, already reported): $win"
    return 0
  fi
  line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || line=""
  detail=${line##*· }
  [ -n "$detail" ] || detail="a required tool is not on this service's PATH"
  reason="stale: $win (crew state unreadable - $detail; this crew's state has NOT been read, so treat neither progress nor a wedge as established, and repair the monitoring toolchain first)"
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$rf"
  wake "$reason"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.wedgeheld-$key"
}

window_state_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  key=${key//./_}
  printf '%s' "$key"
}

# mark_parked: the single creation path for a firstmate-declared parked marker.
# Takes the window exactly as it appears in a task's meta (never a hand-computed
# key), derives the marker key itself via window_state_key, and refuses a window
# that names no currently recorded task - a typo'd window would otherwise create
# a marker matching nothing, which fails open (reconcile_parked_markers just
# clears it next poll) instead of erroring, so the mistake would only ever show
# up as the wake clutter it was meant to remove not going away.
mark_parked() {  # <window>
  local win=${1-} key candidate found=1
  if [ -z "$win" ]; then
    echo "mark_parked: window argument required" >&2
    return 1
  fi
  while IFS= read -r candidate; do
    if [ "$candidate" = "$win" ]; then
      found=0
      break
    fi
  done < <(recorded_windows)
  if [ "$found" -ne 0 ]; then
    echo "mark_parked: '$win' does not match any recorded task window (check state/*.meta)" >&2
    return 1
  fi
  if [ "$(window_kind "$win")" = secondmate ]; then
    echo "mark_parked: '$win' is a secondmate window; secondmates use pause tracking, not .parked markers" >&2
    return 1
  fi
  key=$(window_state_key "$win")
  : > "$STATE/.parked-$key"
}

clear_parked_key_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.parked-$key" "$STATE/.parkedmeta-$key" "$STATE/.parkedresurfaced-$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.wedgeheld-$key"
}

clear_parked_tracking() {  # <window>
  clear_parked_key_tracking "$(window_state_key "$1")"
}

# A status write is authoritative new task information. Clear both the marker
# for the task's current target and any registered marker for its prior target
# before classifying the signal, so the signal wakes normally and a later stale
# cannot remain muted under an obsolete declaration.
clear_parked_for_status_file() {  # <status-file>
  local f=$1 base task meta win tf key _marker_sig recorded_meta _meta_sig
  case "$f" in
    "$STATE"/*.status) ;;
    *) return 0 ;;
  esac
  base=$(basename "$f")
  task=${base%.status}
  meta="$STATE/$task.meta"
  if [ -e "$meta" ]; then
    win=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
    [ -z "$win" ] || clear_parked_tracking "$win"
  fi
  for tf in "$STATE"/.parkedmeta-*; do
    [ -e "$tf" ] || continue
    IFS=$(printf '\t') read -r _marker_sig recorded_meta _meta_sig < "$tf" || true
    [ "$recorded_meta" = "$meta" ] || continue
    key=$(basename "$tf")
    key=${key#.parkedmeta-}
    clear_parked_key_tracking "$key"
  done
}

# Bind each explicit parked marker to the metadata that currently resolves its
# window key. A later metadata content/mtime signature change, target change, or
# removal invalidates the declaration and clears stale suppressors so the task is
# classified afresh. Re-touching the marker is a new firstmate declaration and
# refreshes the binding to the then-current metadata.
reconcile_parked_markers() {
  local marker base key tracking meta candidate win marker_sig meta_sig
  local recorded_marker recorded_meta recorded_meta_sig
  for marker in "$STATE"/.parked-*; do
    [ -e "$marker" ] || continue
    base=$(basename "$marker")
    key=${base#.parked-}
    meta=
    for candidate in "$STATE"/*.meta; do
      [ -e "$candidate" ] || continue
      win=$(fm_backend_target_of_meta "$candidate" 2>/dev/null || true)
      [ -n "$win" ] || continue
      if [ "$(window_state_key "$win")" = "$key" ]; then
        meta=$candidate
        break
      fi
    done
    if [ -z "$meta" ]; then
      clear_parked_key_tracking "$key"
      continue
    fi
    tracking="$STATE/.parkedmeta-$key"
    marker_sig=$(stat_sig "$marker" 2>/dev/null || true)
    meta_sig=$(stat_sig "$meta" 2>/dev/null || true)
    if [ ! -e "$tracking" ]; then
      if [ "$meta" -nt "$marker" ]; then
        clear_parked_key_tracking "$key"
      else
        printf '%s\t%s\t%s\n' "$marker_sig" "$meta" "$meta_sig" > "$tracking"
      fi
      continue
    fi
    recorded_marker=
    recorded_meta=
    recorded_meta_sig=
    IFS=$(printf '\t') read -r recorded_marker recorded_meta recorded_meta_sig < "$tracking" || true
    if [ "$recorded_marker" != "$marker_sig" ]; then
      printf '%s\t%s\t%s\n' "$marker_sig" "$meta" "$meta_sig" > "$tracking"
    elif [ "$recorded_meta" != "$meta" ] || [ "$recorded_meta_sig" != "$meta_sig" ]; then
      clear_parked_key_tracking "$key"
    fi
  done
}

# Print the age of a parked wait whose bounded recheck is due, or nothing while
# still inside the cadence. Pure detection, so both the poll path and the
# backend-push path can gather every due window before either of them enqueues.
parked_recheck_due_age() {  # <window> -> parked age in seconds, or 1 when not due
  local win=$1 key marker mtime age rf rf_age
  key=$(window_state_key "$win")
  marker="$STATE/.parked-$key"
  [ -e "$marker" ] || return 1
  mtime=$(stat_mtime "$marker")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.parkedresurfaced-$key"
  rf_age=$(age_of "$rf")
  [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ] || return 1
  printf '%s' "$age"
}

# Gathered by parked_recheck_enqueue, consumed by parked_recheck_commit. They are
# globals rather than a return value because the commit half has to advance a
# throttle marker per gathered window AFTER its caller has finished its own
# bookkeeping, and a command substitution would run the gather in a subshell
# where the list dies with it.
PARKED_DUE_WINDOWS=()
PARKED_DUE_REASON=

# Enqueue ONE wake record covering every parked window whose recheck is due,
# starting from the window that came due at the call site. Fleet-wide tasks get
# parked in batches - firstmate relays a run of outcomes and parks each one - so
# their markers age together and their rechecks come due together. Surfaced one
# per window, that arrives as one full-context turn per task to learn N times
# that nothing changed: 14 parked tasks put 14 records on the queue over three
# and a half minutes on 2026-09-01, because the window loop below surfaces at
# most one wake per pass and then re-polls. Coalescing changes only how many
# records carry the recheck, never whether it happens: every gathered window's
# throttle is advanced together in parked_recheck_commit, so a window left out of
# this gather keeps its due state and is carried by the next pass.
# A single due window keeps its exact historical record - same key, same text -
# so nothing downstream sees a new shape for the common case.
# The gather is deliberately pane-INDEPENDENT: it asks each parked window only
# whether its own bounded cadence is due, not what its pane is doing. The cadence
# is anchored on the marker for exactly that reason (pane redraws must not
# postpone it), and a parked declaration survives only while no status write or
# metadata change has cleared it, so a window folded in here is genuinely due and
# is delivered no later than a pane-gated one would have been.
parked_recheck_enqueue() {  # <window that came due> -> 1 when nothing is due
  local trigger=$1 win age list='' n i lo hi span
  local -a ages=()
  age=$(parked_recheck_due_age "$trigger") || return 1
  PARKED_DUE_WINDOWS=("$trigger")
  ages=("$age")
  while IFS= read -r win; do
    [ "$win" = "$trigger" ] && continue
    age=$(parked_recheck_due_age "$win") || continue
    PARKED_DUE_WINDOWS+=("$win")
    ages+=("$age")
  done < <(recorded_windows)
  n=${#PARKED_DUE_WINDOWS[@]}
  if [ "$n" -eq 1 ]; then
    PARKED_DUE_REASON=$(printf 'stale: %s (parked %ss, awaiting external human action - supervisor-declared terminal wait, rechecked on a long cadence not a wedge; confirm the wait still holds)' "$trigger" "${ages[0]}")
    fm_wake_append stale "$trigger" "$PARKED_DUE_REASON" || exit 1
    return 0
  fi
  # Names once, comma-separated, and ONE age for the whole set: parked markers
  # age together (that is the premise of coalescing them), so a per-window age
  # buys nothing and costs the bytes that push a fleet-sized record past the
  # drain's per-row echo bound (fm_wake_bound_echo), where it would be shortened
  # and the seat would need a second read to learn which tasks it covers.
  lo=${ages[0]}; hi=${ages[0]}
  for (( i = 0; i < n; i++ )); do
    list="$list${list:+, }${PARKED_DUE_WINDOWS[i]}"
    if [ "${ages[i]}" -lt "$lo" ]; then lo=${ages[i]}; fi
    if [ "${ages[i]}" -gt "$hi" ]; then hi=${ages[i]}; fi
  done
  if [ "$lo" -eq "$hi" ]; then span="parked ${lo}s"; else span="parked ${lo}s-${hi}s"; fi
  PARKED_DUE_REASON=$(printf 'stale: %s parked tasks due for recheck (%s; %s) - awaiting external human action - supervisor-declared terminal waits, rechecked on a long cadence not a wedge; confirm each wait still holds' "$n" "$span" "$list")
  # A key of its own: this record speaks for a set, so collapsing it on drain
  # against a later single-window stale for any one of them would lose the rest.
  fm_wake_append stale parked-recheck "$PARKED_DUE_REASON" || exit 1
  return 0
}

# Advance every gathered throttle, then wake once. Split from the enqueue half so
# each caller keeps its own ordering between the queue append and its own
# bookkeeping - the push path has a transition to commit in between, and wake()
# exits the process outright in session mode.
parked_recheck_commit() {
  local win
  for win in "${PARKED_DUE_WINDOWS[@]:-}"; do
    [ -n "$win" ] || continue
    date +%s > "$STATE/.parkedresurfaced-$(window_state_key "$win")"
  done
  PARKED_DUE_WINDOWS=()
  wake "$PARKED_DUE_REASON"
}

# Absorb pane churn for a terminal task whose outcome firstmate already relayed
# and explicitly parked while external human action remains. The marker mtime is
# the cadence anchor, so pane redraws cannot postpone the bounded recheck.
handle_parked_stale() {  # <window> <hash>
  local win=$1 h=$2 key age
  key=$(window_state_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.wedgeheld-$key"
  if parked_recheck_enqueue "$win"; then
    parked_recheck_commit
    return
  fi
  age=$(age_of "$STATE/.parked-$key")
  triage_log "absorbed stale (parked terminal wait, age ${age}s): $win"
}

# codex_static_pane_upgrade: interface-text-INDEPENDENT liveness backstop for the
# codex false-idle regression. Codex 0.145.0 renders its "esc to interrupt" busy
# row ONLY in the pre-answer phase of a turn: it drops the row while an answer
# streams and for the whole of a mid-turn tool call (fleet-verified against tag
# rust-v0.145.0, docs/codex-busy-detection.md). Our ordinary pane evidence still
# covers streaming bursts that change the pane hash and the pre-answer phase where
# the row is present, but a healthy codex worker sitting on a STATIC pane between
# visible updates, or in a static tool-call phase, renders NO busy text at all, so
# window_is_busy reads idle and the wake would otherwise surface as a possible
# wedge the moment the pane held still past two polls.
#
# Corroborate with a signal that does not read interface text: the codex agent
# PROCESS itself. When fm_backend_agent_alive confidently reports the codex binary
# still running in the pane (`alive`), treat an otherwise-`none` stale verdict as
# provably working - absorb and start the wedge timer - instead of surfacing
# immediately. A genuinely wedged codex still escalates past STALE_ESCALATE_SECS
# and on to demand-deep-inspection, and a crashed codex reads `dead` (a bare shell
# is the foreground command) and still surfaces at once. Only `alive` upgrades;
# `dead`/`unknown` keep the caller's fallback verdict.
#
# Scoped to codex on purpose: the other verified harnesses keep rendering their
# busy indicator for the whole turn, so their static-pane stale really is idle.
# This is confined to the STALE path (not crew_absorb_class itself) because agent
# liveness cannot tell a mid-tool-call apart from an idle post-turn composer - both
# leave codex running - so the signal/turn-end absorb path must keep the pure
# crew_absorb_class semantics, and only the two-poll-static, no-captain-relevant-line
# stale context here justifies trusting process liveness (see the two-poll gate below).
#
# SUPERVISION-INFRA CAVEAT: the busy regex this backstops is built from codex's
# DEFAULT Escape keybinding ("esc to interrupt"). An operator who remaps or unbinds
# tui.keymap.chat.interrupt_turn blinds the busy-row layer for EVERY codex worker on
# the host, at which point this process-liveness backstop is the only thing between
# a healthy static-pane codex worker and a false wedge. Keep it in the absorb path;
# do not fold it back into the interface-text layer.
codex_static_pane_upgrade() {  # <window> <fallback-class>
  local win=$1 fallback=$2 alive
  [ "$fallback" = none ] || { printf '%s' "$fallback"; return; }
  [ "$(window_harness "$win")" = codex ] || { printf '%s' "$fallback"; return; }
  [ "$(window_kind "$win")" != secondmate ] || { printf '%s' "$fallback"; return; }
  alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || alive=unknown
  if [ "$alive" = alive ]; then printf 'working'; return; fi
  printf '%s' "$fallback"
}

# parked_gate_liveness_class: decide what a `parked` absorb class (crew_absorb_class
# in bin/fm-classify-lib.sh - the authoritative run-step reports the pipeline stopped
# at a decision gate) is worth on the WEDGE-ESCALATION path, by corroborating it with
# a signal that does not read interface text: the harness-agent PROCESS.
#
# Scoped to the ladder on purpose: a gate only ever holds an escalation on a stale
# pane firstmate has ALREADY been woken for. The first sighting of that pane still
# surfaces at once, whatever the run-step says, because nothing has told anyone
# about the gate yet.
#
# The gate answers the wedge question outright for the crew that is still there. A
# worker parked at an ask-user finding is idle because it did exactly what its brief
# requires - ask, then stop. The 2026-08-08 evidence: two such workers escalated as
# `idle 254s, possible wedge, escalation 1` while fm-crew-state.sh, run against the
# same tasks at the same moment, returned `state: parked - source: run-step - parked
# at review: 3 finding(s) (ask-user: captain decision)`. The fleet already knew.
#
# But `parked` alone is NOT that answer, and absorbing on it would be the failure
# this whole absorb path exists to avoid. A worker that crashed one second after
# printing its gate prompt leaves the run parked in exactly the same way, forever:
# no-mistakes has no idea its agent is gone, so the run-step reading is IDENTICAL
# for a healthy gate and a dead one. Only `alive` - a confirmed agent process, the
# one piece of evidence that changes when the worker dies - licenses the absorb:
#   alive   -> parked  (hold the ladder on the long bounded cadence)
#   dead    -> none    (the caller's ordinary escalation path: a run parked with
#                       nobody left to answer it is a real failure, and it must
#                       reach firstmate on the unchanged timings, never be
#                       swallowed by the parked case)
#   unknown -> none    (fm_backend_agent_alive's contract: never license an action
#                       from unknown. Today that covers pi, whose launcher execs
#                       into a generic `node`, and every backend past tmux/herdr -
#                       those crews keep exactly today's behavior)
# Secondmates are excluded like the codex backstop excludes them: they never drive
# a run, so a `parked` verdict cannot be theirs to begin with.
#
# COST: this adds no crew-state read anywhere. The wedge escalation already had the
# fm-crew-state.sh verdict in hand, and the only new work is one liveness probe on
# the branch where that verdict is `parked`, once per escalation window. Nothing
# here runs per poll per task, which is the budget the watcher's whole absorb design
# is built around.
parked_gate_liveness_class() {  # <window>
  local win=$1 alive
  [ "$(window_kind "$win")" != secondmate ] || { printf 'none'; return; }
  alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || alive=unknown
  case "$alive" in
    alive) printf 'parked' ;;
    *)     printf 'none' ;;
  esac
}

pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    class=$(crew_absorb_class "$task")
    # A gate reading never absorbs a FIRST sighting, for ANY harness: at first
    # sight nothing has relayed the gate to firstmate yet (this path is reached
    # precisely when the crew's last status line is not captain-relevant), so
    # swallowing it would leave the decision waiting on the long bounded cadence
    # with nobody told. The gate only ever holds the wedge LADDER, once the pane
    # is a known stale firstmate has already seen (wedge_timer_check).
    # It short-circuits BEFORE codex_static_pane_upgrade rather than being folded
    # into its `none` fallback: that backstop answers "no run-step says anything,
    # is the process still there?" for a codex worker mid-turn on a static pane,
    # and a run-step that authoritatively reports the run STOPPED at a gate is not
    # that question. Routing the gate through it would hand codex alone the
    # first-sight absorb every other harness just lost.
    if [ "$class" = parked ]; then
      printf 'none'
      return
    fi
    codex_static_pane_upgrade "$win" "$class"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  # Below this line the crew has DECLARED a pause or a verified captain hold, and
  # the branch's own dead-agent rule already owns that idle pane. The run-step gate
  # reading adds nothing here and its liveness corroboration would collide with the
  # declaration's, so `parked` keeps the exact `none` handling it had before the
  # gate class existed; only the undeclared path above consults it.
  [ "$class" = parked ] && class=none
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedgeheld-$key" "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  wake "stale: $win"
  return
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Record every observation of an absent-protection ceiling without raising a
# second wake for an unchanged condition. state/.context-ceiling-absent-since
# carries "<class> <condition> <first-observed-epoch> <observations>" as content rather than
# relying on its mtime, because the mtime moves on every rewrite and the whole
# point of the record is the moment that did NOT move. A change of class or
# semantic condition restarts it: dating a new absence from the old one would
# overstate it.
context_absence_observe() {  # <class> <condition>
  local class=$1 condition=$2 file="$STATE/.context-ceiling-absent-since"
  local prev_class prev_condition since observations now
  now=$(date +%s)
  # The redirect is opened before the 2>/dev/null would take effect, so an absent
  # file is checked for rather than left to print a shell error on every poll.
  [ -f "$file" ] && { read -r prev_class prev_condition since observations < "$file" 2>/dev/null || true; }
  case "${since:-}${observations:-}" in
    *[!0-9]*|'') prev_class=; prev_condition=; since=; observations= ;;
  esac
  if [ "${prev_class:-}" != "$class" ] || [ "${prev_condition:-}" != "$condition" ]; then
    since=$now
    observations=0
  fi
  observations=$((observations + 1))
  printf '%s %s %s %s\n' "$class" "$condition" "$since" "$observations" > "$file" 2>/dev/null
}

context_ceiling_observe() {  # <class> <condition>
  local class=$1 condition=$2 file="$STATE/.context-ceiling-surfaced"
  local prev_class prev_condition since observations now
  now=$(date +%s)
  [ -f "$file" ] && { read -r prev_class prev_condition since observations < "$file" 2>/dev/null || true; }
  case "${since:-}${observations:-}" in
    *[!0-9]*|'') prev_class=; prev_condition=; since=; observations= ;;
  esac
  if [ "${prev_class:-}" != "$class" ] || [ "${prev_condition:-}" != "$condition" ]; then
    since=$now
    observations=0
  fi
  observations=$((observations + 1))
  printf '%s %s %s %s\n' "$class" "$condition" "$since" "$observations" > "$file" 2>/dev/null
}

# Print the context-ceiling wake reason when there is one, and nothing on an
# ordinary poll. bin/fm-context-lib.sh owns what "over ceiling", "quiet", and
# "captain active" mean, so the watcher's branch and the reset tool's refusals
# cannot drift apart. It is called directly rather than through a command
# substitution because the branch class and the poll's resolution state are
# published as variables, and a subshell would discard both.
#
# EVERY reason is suppressed after its first wake, not just the unmeasurable one.
# Each branch there describes a condition rather than an event: a captain who is present stays
# present, a broken re-entry hook stays broken, and an unmeasurable transcript
# stays unmeasurable, so re-reporting any of them on the poll cadence would spend
# a model turn every CONTEXT_CHECK_INTERVAL on news that has not changed - the
# opposite of what this mechanism exists to do. Suppression is keyed on the
# published semantic identity, so a condition that CHANGES (the captain leaves and the ask
# branch becomes the reset branch) surfaces on the very next poll instead of
# inheriting the previous branch's silence. Only an unchanged, still-true
# condition stays quiet, and its marker remains durable until the condition
# changes or resolves.
#
# Only a RESOLVED poll clears the marker. A suppressed one leaves it exactly as
# it is: the wake this check produces sits in state/.wake-queue until firstmate
# drains it, and an undrained queue is precisely what makes the next poll
# non-quiet - so clearing on "no reason this poll" would let every ceiling wake
# erase its own suppression marker and re-fire once per drain cycle.
#
# A class whose protection is ABSENT keeps its first-observed time and observation
# count current on every eligible poll, including polls whose wake is suppressed.
# This is the escalation path for an unchanged absence: the durable record and
# session-start digest keep it visible without spending another model turn.
# If that record cannot be updated, suppression fails open and the wake repeats,
# because an unenforced ceiling must never become both silent and unrecorded.
context_ceiling_surface() {
  local marker previous_class='' previous_condition='' reason recorded=1 absence_recorded=1
  fm_context_ceiling_reason "$STATE" "$FM_HOME" "$FM_ROOT" >/dev/null || return 0
  marker="$STATE/.context-ceiling-surfaced"
  case "$FM_CONTEXT_CEILING_STATE" in
    resolved)
      rm -f "$marker" "$STATE/.context-ceiling-absent-since" 2>/dev/null || true
      return 0
      ;;
    surfaced) ;;
    *) return 0 ;;
  esac
  [ -f "$marker" ] \
    && { read -r previous_class previous_condition _ _ < "$marker" 2>/dev/null || true; }
  if [ "$FM_CONTEXT_CEILING_PROTECTION" = absent ]; then
    if ! context_absence_observe "$FM_CONTEXT_CEILING_CLASS" "$FM_CONTEXT_CEILING_CONDITION"; then
      absence_recorded=0
      triage_log "could not update the standing context-ceiling absence record"
    fi
  else
    rm -f "$STATE/.context-ceiling-absent-since" 2>/dev/null || true
  fi
  if ! context_ceiling_observe "$FM_CONTEXT_CEILING_CLASS" "$FM_CONTEXT_CEILING_CONDITION"; then
    recorded=0
    triage_log "could not update the standing context-ceiling record"
  fi
  if [ "$previous_class" = "$FM_CONTEXT_CEILING_CLASS" ] \
    && [ "$previous_condition" = "$FM_CONTEXT_CEILING_CONDITION" ] \
    && [ "$absence_recorded" -eq 1 ] && [ "$recorded" -eq 1 ]; then
    triage_log "absorbed context-ceiling $FM_CONTEXT_CEILING_CLASS (unchanged since it was last reported)"
    return 0
  fi
  reason=$FM_CONTEXT_CEILING_REASON
  printf '%s' "$reason"
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
# Signal signatures follow symlinks so public state/<id>.status and
# state/<id>.turn-ended links into a Codex task's private .crew-signal directory
# wake on target changes, not only on link creation.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(signal_stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

# Bounded run of "$@" with stdout captured by the caller and stderr discarded.
# Unlike run_check (which always reports success to its caller), run_bounded's
# own exit status IS the underlying command's real exit status - a timeout also
# returns non-zero - so a caller that needs "the command could not run" to read
# differently from "the command ran and said healthy" can read $? after a
# capturing call (certsync_health_reason does). A caller that discards the exit
# status anyway (e.g. a fire-and-forget git fetch) is unaffected.
run_bounded() {
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" "$@" 2>/dev/null
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" "$@" 2>/dev/null
  else
    # shellcheck disable=SC2016
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "$@" 2>/dev/null
  fi
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# 0 if <status-file>'s CURRENT last line is exactly the captain-relevant line
# already surfaced to firstmate (the .hb-surfaced-<task> marker mark_surfaced
# writes on surface, and only on surface). Content equality is the whole point:
# it says "firstmate has already been woken for this exact fact", so a wake
# carrying nothing else is redundant, while any newer or changed captain-relevant
# line fails the check and still surfaces.
status_already_surfaced() {  # <status-file>
  local f=$1 task last recorded
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 1
  status_is_captain_relevant "$last" || return 1
  recorded=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
  [ -n "$recorded" ] && [ "$recorded" = "$last" ]
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

FM_CERTSYNC_HEALTH_REASON=
FM_CERTSYNC_HEALTH_SIGNATURE=

certsync_health_mark_surfaced() {
  [ -n "$FM_CERTSYNC_HEALTH_SIGNATURE" ] || return 0
  printf '%s\n' "$FM_CERTSYNC_HEALTH_SIGNATURE" > "$STATE/.certsync-health-surfaced" 2>/dev/null || true
}

# Read certsync's own monitoring interface and produce one bounded wake reason
# for either a confirmed unhealthy JSON payload OR a confirmed inability to read
# that payload at all. The two must never collapse into the same silent "nothing
# to report" answer: a check that cannot tell its own failure apart from success
# is not a check. Every "cannot run" branch below therefore sets
# FM_CERTSYNC_HEALTH_REASON instead of returning early, so it shares the same
# resurface-dedup and wake path as a confirmed-unhealthy reason - bounded
# repetition (CERTSYNC_HEALTH_RESURFACE), never silence. Absence of the project
# or its compose file is the one legitimate "nothing to check here" case: it
# means certsync is not deployed on this host, not that a deployed check failed.
certsync_health_reason() {
  local project compose src state_db heartbeat_file daemon_state marker previous timeout_previous
  local py out out_rc healthy summary hb_age
  FM_CERTSYNC_HEALTH_REASON=
  FM_CERTSYNC_HEALTH_SIGNATURE=
  project=${FM_CERTSYNC_PROJECT:-$FM_HOME/projects/hlr-certsync}
  compose=${FM_CERTSYNC_COMPOSE_FILE:-$project/docker-compose.yml}
  src=${FM_CERTSYNC_SRC:-$project/src}
  state_db=${FM_CERTSYNC_STATE_DB:-/var/lib/hlr-certsync/certsync-state.sqlite3}
  heartbeat_file=${FM_CERTSYNC_HEARTBEAT_FILE:-/var/lib/hlr-certsync/certsync-heartbeat.json}
  daemon_state=${FM_CERTSYNC_DAEMON_STATE:-running}
  marker="$STATE/.certsync-health-surfaced"

  [ -d "$project" ] || return 1
  [ -f "$compose" ] || return 1

  if ! command -v python3 >/dev/null 2>&1; then
    FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: python3 missing"
  elif ! command -v jq >/dev/null 2>&1; then
    FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: jq missing"
  elif [ ! -f "$src/hlr_certsync/status.py" ]; then
    FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: certsync source unavailable at $src"
  else
    # Read certsync's status directly off the heartbeat file and state DB on the
    # host - no docker socket, no `exec`, no docker-group membership. certsync
    # exposes both under a readable host bind mount (certsync repo's
    # docs/deploy.md, "State host path"). build_status computes healthy/reason
    # purely from those two files plus the daemon-state argument, so invoking it
    # here reproduces exactly what `docker compose exec certsync certsync status`
    # produced, byte for byte, but needs no docker access at all.
    py='import json,sys
from hlr_certsync.status import build_status
from hlr_certsync.state import StateStore
print(json.dumps(build_status(StateStore(sys.argv[1]), sys.argv[2], daemon_state=sys.argv[3]), sort_keys=True))'
    timeout_previous=$CHECK_TIMEOUT
    CHECK_TIMEOUT=$CERTSYNC_HEALTH_TIMEOUT
    out=$(run_bounded env PYTHONPATH="$src" python3 -c "$py" "$state_db" "$heartbeat_file" "$daemon_state")
    out_rc=$?
    CHECK_TIMEOUT=$timeout_previous

    if [ "$out_rc" -ne 0 ]; then
      FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: status command failed (exit $out_rc)"
    elif [ -z "$out" ]; then
      FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: no status output"
    else
      healthy=$(printf '%s' "$out" | jq -r 'if (.healthy == true or .healthy == false) then .healthy else empty end' 2>/dev/null)
      if [ -z "$healthy" ]; then
        FM_CERTSYNC_HEALTH_REASON="check: certsync health: cannot run: invalid or missing status JSON"
      elif [ "$healthy" = true ]; then
        # A running daemon rewrites the heartbeat on every successful sync pass
        # (<=3600s apart). Reading frozen files off the host cannot, on its own,
        # tell a live healthy daemon from a stopped container whose last-written
        # files still say "success" - the old docker-exec check caught that only
        # because exec itself failed when the container was down. Reinstate that
        # liveness signal here: a heartbeat older than the bound reads as
        # unhealthy, never healthy, so "cannot confirm well" never collapses into
        # "is well". Set FM_CERTSYNC_HEARTBEAT_MAX_AGE=0 to disable.
        hb_age=$(age_of "$heartbeat_file")
        if [ "${CERTSYNC_HEARTBEAT_MAX_AGE:-0}" -gt 0 ] 2>/dev/null && [ "$hb_age" -gt "$CERTSYNC_HEARTBEAT_MAX_AGE" ]; then
          FM_CERTSYNC_HEALTH_REASON="check: certsync health: unhealthy: heartbeat stale (${hb_age}s > ${CERTSYNC_HEARTBEAT_MAX_AGE}s); daemon may be stopped or syncs failing"
        else
          rm -f "$marker" 2>/dev/null || true
          return 1
        fi
      else
        summary=$(printf '%s' "$out" | jq -r '.reason // "unhealthy"' 2>/dev/null \
          | tr '\n\t' '  ' \
          | sed 's/[[:space:]]*$//' \
          | cut -c1-300)
        [ -n "$summary" ] || summary=unhealthy
        FM_CERTSYNC_HEALTH_REASON="check: certsync health: unhealthy: $summary"
      fi
    fi
  fi

  FM_CERTSYNC_HEALTH_SIGNATURE=$FM_CERTSYNC_HEALTH_REASON
  previous=$(cat "$marker" 2>/dev/null || true)
  if [ "$previous" = "$FM_CERTSYNC_HEALTH_SIGNATURE" ] \
    && [ "$(age_of "$marker")" -lt "$CERTSYNC_HEALTH_RESURFACE" ]; then
    triage_log "absorbed certsync health (unchanged: $FM_CERTSYNC_HEALTH_SIGNATURE)"
    return 1
  fi
  return 0
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc now
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read).  A one-shot watcher naturally re-probed on its next process.  A
  # long-lived daemon also re-probes a disabled path on a bounded cadence so one
  # transient herdr failure cannot disable push delivery until service restart.
  now=$(date +%s)
  if [ "$_event_cap_key" != "$first_backend:$first_session" ] \
    || { [ "$_event_cap_ok" != 1 ] && [ $((now - _event_cap_probe_epoch)) -ge "$EVENT_CAP_REPROBE_SECS" ]; }; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
    _event_cap_probe_epoch=$now
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      if [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ]; then
        _event_cap_ok=0
        _event_cap_probe_epoch=$(date +%s)
      fi
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause and supervisor-parked exemptions (a known external wait is not
# a surprise block - absorb it on the poll loop's long cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task key reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reconcile_parked_markers
  key=$(window_state_key "$window")
  if ! afk_present && [ -e "$STATE/.parked-$key" ]; then
    # Same coalescing as the poll path, and reachable by the same burst: a batch
    # of parked panes produces a transition record each, one per wait cycle.
    if parked_recheck_enqueue "$window"; then
      fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
      parked_recheck_commit
      return
    fi
    triage_log "absorbed push $to (parked terminal wait, awaiting external human action): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
  return
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# mark-parked: internal one-shot entry point used by fm-mark-parked.sh, so the
# wrapper delegates validation and key derivation without acquiring the
# watcher's singleton lock or entering its loop.
if [ "${1-}" = "mark-parked" ]; then
  mark_parked "${2-}"
  exit $?
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

lock_rc=0
fm_lock_try_acquire "$WATCH_LOCK" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  if [ "$lock_rc" -eq 2 ]; then
    echo "watcher: lock acquisition failed for $WATCH_LOCK" >&2
    exit 1
  fi
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watch_arm_owner_is_parent() {
  local current_parent
  [ -n "$WATCH_ARM_OWNER_PID" ] || return 0
  current_parent=$(LC_ALL=C ps -p "$WATCHER_PID" -o ppid= 2>/dev/null | tr -d '[:space:]')
  # A failed or empty ps read is inconclusive, not proof the arm owner is gone;
  # only exit on a reliable read that names a different parent.
  [ -n "$current_parent" ] || return 0
  [ "$current_parent" = "$WATCH_ARM_OWNER_PID" ]
}

watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction and
# arm-owner checks.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
printf '%s\n' "${FM_WATCH_MANAGER:-session}" > "$WATCH_LOCK/manager" || true
printf '%s\n' "${FM_WATCH_SOURCE_VERSION:-unknown}" > "$WATCH_LOCK/source-version" || true
printf '%s\n' "${FM_WATCH_X_MODE_VERSION:-absent}" > "$WATCH_LOCK/x-mode-version" || true
# The PATH this watcher was HANDED, recorded so a later convergence can compare
# it. Only the keeper tier sets it: systemd's copy lives in the service
# environment file the unit loads, which fm-watcher-service.sh already compares,
# while a keeper receives its PATH as a launch argument that would otherwise
# leave no trace at all.
printf '%s\n' "${FM_WATCH_SERVICE_PATH:-}" > "$WATCH_LOCK/service-path" || true
printf '%s\n' "$WATCH_DAEMON" > "$WATCH_LOCK/daemon" || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  WAKE_PENDING=0
  # A legacy one-shot child whose explicit owner died cannot rely on that
  # owner's traps. The externally kept daemon deliberately ignores this check.
  if [ "$WATCH_DAEMON" -eq 0 ]; then
    watch_arm_owner_is_parent || exit 0
  fi

  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Context ceiling: read this session's own context size and, at a quiet
  # boundary over the captain's 300k ceiling, enqueue the one wake that says
  # whether to reset or to ask. Placed before the per-task checks for the same
  # reason those precede the signal scan - wake() ends the cycle, so a chatty
  # fleet would otherwise starve a slow poll indefinitely. Cheap on every other
  # cycle: one mtime read decides whether it runs at all.
  if [ "$(age_of "$STATE/.last-context-check")" -ge "$CONTEXT_CHECK_INTERVAL" ]; then
    touch "$STATE/.last-context-check"
    context_reason=$(context_ceiling_surface)
    if [ -n "$context_reason" ]; then
      fm_wake_append check context-ceiling "$context_reason" || exit 1
      wake "$context_reason"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    fi
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          provider=$FM_PR_DATA_PROVIDER
          url=$FM_PR_DATA_URL
          host=$FM_PR_DATA_HOST
          path=$FM_PR_DATA_PATH
          number=$FM_PR_DATA_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
        [ "$WAKE_PENDING" -eq 0 ] || break
      fi
    done
    [ "$WAKE_PENDING" -eq 0 ] || continue
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    fi
    touch "$STATE/.last-check"
  fi

  if [ "${#BRIDGE_VESSELS[@]}" -eq 0 ] || [ ! -d "$BRIDGE_ROOT/.git" ]; then
    bridge_interval=$CHECK_INTERVAL
  elif [ "$(age_of "$STATE/.last-bridge-discovery")" -ge "$BRIDGE_URGENT_CHECK_INTERVAL" ]; then
    run_bounded git -C "$BRIDGE_ROOT" fetch --quiet origin main >/dev/null
    bridge_interval=$(bridge_check_interval)
    printf '%s' "$bridge_interval" > "$STATE/.bridge-interval-cache" 2>/dev/null || true
    touch "$STATE/.last-bridge-discovery"
  else
    bridge_interval=$(cat "$STATE/.bridge-interval-cache" 2>/dev/null)
    [ -n "$bridge_interval" ] || bridge_interval=$CHECK_INTERVAL
  fi
  if [ "$(age_of "$STATE/.last-bridge-check")" -ge "$bridge_interval" ]; then
    reason=$(bridge_inbox_surface 0) || exit 1
    touch "$STATE/.last-bridge-check"
    if [ -n "$reason" ]; then
      wake "$reason"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    fi
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Distinct signalling TASKS, in first-seen order. One crewmate turn normally
    # touches BOTH state/<id>.status and state/<id>.turn-ended, and the grace
    # re-scan can list the same file twice, so this poll's pending list holds
    # several rows per task.
    sig_tasks=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      sig_base=${f##*/}
      case "$sig_base" in
        *.status)     sig_task=${sig_base%.status} ;;
        *.turn-ended) sig_task=${sig_base%.turn-ended} ;;
        *)            continue ;;
      esac
      case " $sig_tasks " in *" $sig_task "*) ;; *) sig_tasks="$sig_tasks $sig_task" ;; esac
    done <<EOF
$pending
EOF
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      clear_parked_for_status_file "$f"
    done <<EOF
$pending
EOF
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      # One event, one wake. Every record built from this poll carries the same
      # "$reason" payload, so enqueuing per changed FILE made firstmate drain two
      # identical-payload records - and pay two full supervision cycles - for the
      # single crewmate turn that wrote a status line and then tripped its
      # turn-end hook. The drain's dedupe is keyed on (kind, key), so two distinct
      # keys both survive it; collapsing has to happen here. Enqueue one record
      # per TASK, keyed on that task's .status file whenever this poll touched it:
      # the status key names a real file the drain can read the crew's own last
      # line from (fm_wake_status_key_map), while a bare .turn-ended key carries
      # nothing beyond "a turn ended" and is only the fallback when the turn-end
      # marker moved alone. Dedup is per task and never across tasks, so two
      # crewmates signalling in the same poll still produce one wake each.
      for sig_task in $sig_tasks; do
        case " $files " in
          *" $STATE/$sig_task.status "*) sig_key="$sig_task.status" ;;
          *)                             sig_key="$sig_task.turn-ended" ;;
        esac
        fm_wake_append signal "$sig_key" "$reason" || exit 1
      done
      # Markers stay per FILE: every changed file's signature must advance and
      # every status file must mark_surfaced, or the collapsed-away file re-fires
      # this same wake on the next poll, forever.
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  reconcile_parked_markers
  fm_state_marker_prune_watcher "$STATE"

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_state_key "$w")
    pkf="$STATE/.parked-$key"
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    whf="$STATE/.wedgeheld-$key"   # current wedge class + last delivery/recheck mtime (wedge_timer_check)
    pf="$STATE/.paused-$key"   # flag: this key's current stale is a declared pause
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Away mode owns triage: enqueue once per distinct stale hash.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif [ -e "$pkf" ]; then
          handle_parked_stale "$w" "$h"
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if status_already_surfaced "$STATE/$task.status"; then
              # Same terminal fact, second wake: the crew wrote its captain-relevant
              # line (surfaced through the signal path), then its turn ended and the
              # pane settled to a new stable hash seconds later, and this branch
              # re-reported that identical line as a stale wake - a second full
              # supervision cycle for one event. Suppression is keyed on the status
              # CONTENT already surfaced (the .hb-surfaced-<task> marker), never on
              # the window: a new or changed captain-relevant line still surfaces
              # here, and this absorb starts the wedge timer, so a crew that is
              # genuinely wedged behind an already-relayed line still escalates past
              # STALE_ESCALATE_SECS.
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (terminal status already surfaced by the signal path): $w"
            elif crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly run-step read runs only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS recheck cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              degraded)
                # Not "the crew stopped" - "nobody read the crew". Advance the
                # suppressor and start the wedge timer exactly as an absorb
                # would, so the condition is reported on its own bounded cadence
                # instead of re-surfacing as a fresh stale on every poll.
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                handle_degraded_stale "$w" "$task" "non-terminal stale"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf" "$whf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf" "$whf"
      task=$(window_to_task "$w" "$STATE")
      if [ "$kind" = secondmate ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      elif ! afk_present && [ -e "$pkf" ] && ! window_is_busy "$w" "$tail40"; then
        handle_parked_stale "$w" "$h"
      elif ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
    [ "$WAKE_PENDING" -eq 0 ] || break
  done < <(recorded_windows)
  [ "$WAKE_PENDING" -eq 0 ] || continue

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting).
    if certsync_health_reason; then
      fm_wake_append check certsync-health "$FM_CERTSYNC_HEALTH_REASON" || exit 1
      touch "$STATE/.last-heartbeat"
      certsync_health_mark_surfaced
      wake "$FM_CERTSYNC_HEALTH_REASON"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    elif afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
      [ "$WAKE_PENDING" -eq 0 ] || continue
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
