#!/usr/bin/env bash
# Report OUTWARD, while it is still true, that this home has no first mate.
#
# WHAT THIS IS FOR
# On 2026-08-27 the seat process on coditan-vessel was simply gone for about six
# hours. 43 wakes piled up undrained between ~02:27Z and ~08:15Z, two crewmates
# waited on a supervisor that could not answer, and the captain found a bare
# shell behind his own terminal entry. Nothing reported it. The watcher stayed
# alive. The delivery listener stayed alive. The container reported healthy,
# because everything it supervises was fine. The one component that was gone was
# the one component every report was routed THROUGH.
#
# That is the whole shape of the defect, and it is why this file exists
# separately from bin/fm-seat-respawner.sh. A restarter alone moves the silent
# failure one layer out: when the restart does not happen, or does not work,
# nothing says so and the same six hours happen again. Detection is the primary
# half.
#
# WHY THIS ONE GOES STRAIGHT TO THE CAPTAIN, WHEN THE MEMORY ALARM DELIBERATELY
# DOES NOT
# bin/fm-memory-alarm.sh prints a line, the watcher wakes firstmate, and
# firstmate decides what reaches the captain. That routing is correct there and
# it is correct for every other check in this fleet, because firstmate is
# present to make the judgement and can be overruled on it.
#
# It is exactly wrong here. Firstmate is the SUBJECT of this reading. When the
# answer is "absent", the router this fleet routes through is the thing that is
# gone, and a line printed into the wake queue joins the pile that is already
# not being read. So this alarm carries its own message out through
# bin/fm-tg-send.sh, which reaches the captain's phone without needing a session
# to exist. It takes no judgement firstmate could have taken instead; it reports
# one fact firstmate is structurally unable to report about itself.
#
# It still prints its line for the watcher, on transitions only. That line is
# for the seat that eventually returns - it is how a fresh session learns it was
# away and for how long - and it is not the notification path.
#
# WHAT IT KEYS ON, AND WHY NOT A PROCESS NAME
# During the outage both live `claude` processes in this container were
# CREWMATES in task worktrees, each carrying
# `--settings <worktree>/.claude/settings.fm-task.json`, while the seat itself
# was absent. Anything counting processes by name, or reading
# `pane_current_command=claude`, would have called this vessel healthy while it
# was blind. The seat's own tmux window is no better: it is not reproducible by
# anything on this vessel, it survives the seat's death as a bare shell, and a
# respawn opens a NEW window rather than reviving that one.
#
# So the reading keys on the one artefact only a seat produces: this home's
# session lock, `state/.lock`, whose record names the harness pid AND the pid
# table that pid came from. bin/fm-harness-pid-lib.sh owns that record and the
# liveness decision; this file is a second presenter of it, for a different
# audience, and adds no second copy of the procedure.
#
# THE VERDICTS, AND WHY THERE ARE FIVE RATHER THAN TWO
#   present        the lock names a live harness process: a seat is running
#   absent         a seat ran here and is not running now - the lock names a
#                  dead pid, or the lock is gone while a published endpoint
#                  record says a session once existed here
#   standing-down  state/.seat-stay-down exists, so the absence was DECLARED.
#                  Reusing the respawner's existing marker rather than inventing
#                  a second one keeps deliberate shutdown a single fact
#   unattended     no lock record and no endpoint record: no seat has ever been
#                  published in this home. Not a fault, and not an all-clear
#   unmeasured     the reading could not be taken - an unreadable lock, a state
#                  directory this process cannot reach, or a pid in a table this
#                  process cannot see into
#
# `unmeasured` NOTIFIES, on the same cadence as `absent`. An alarm that goes
# quiet when its instrument breaks is indistinguishable from a healthy vessel,
# and that is the defect this whole task exists to remove rather than to add
# another instance of. A reading that could not be taken is never reported as
# healthy anywhere in this file.
#
# WHAT IT ADDS TO THE MESSAGE, AND WHY
# Two facts travel with the absence, because "the seat is down" alone does not
# tell the captain whether to get up.
#   1. How much work is waiting. state/.wake-queue records carry their own
#      queued-at epoch as the first tab-separated field, so the depth AND the
#      age of the oldest waiting item are both readable. Until this existed
#      nothing read either as a symptom - bin/fm-delivery-lib.sh reads the depth
#      only to fill in a verdict sentence, and reads no age at all. A queue that
#      is growing while nothing drains it IS the seat not reading.
#   2. Whether anything is trying to bring the seat back, read from
#      bin/fm-seat-respawner-service.sh status. "Absent and a restart is being
#      attempted" and "absent and nothing is trying" are different messages and
#      the captain acts differently on them.
#
# NOISE CONTROL, AND WHY THE REPEAT HAS NO CAP
# It speaks on TRANSITION, and then repeats while the condition lasts. A phone
# message can be missed, and this one is sent precisely when nobody is watching
# the vessel, so a single unrepeated send would reintroduce the failure in
# miniature. The repeat is deliberately slow (30 minutes by default) and it is
# deliberately UNCAPPED: a cap would make an alarm that goes quiet exactly when
# the outage is longest, which is the same defect as an alarm that goes quiet
# when it cannot see.
#
# BOTH the grace and that cadence are read out of the record below, so when the
# record cannot be written neither is available: the grace is not applied at all
# (silence would be the worse failure), the outward message says plainly that
# this vessel cannot remember having sent it, and the printed line is withheld
# until the memory comes back rather than growing the durable wake queue once
# per sweep on a "first sweep of this episode" nothing here can establish.
#
# A RETURN IS NOT ANNOUNCED AT ALL. This file reports that the first mate is
# gone and says nothing when one is back; the captain learns of the return by
# the repeats stopping. It is recorded in data/seat-alarm.log for whoever reads
# the history later, and that is the whole of it.
#
# It was announced once, and the announcement was removed rather than repaired,
# because ANNOUNCING ONCE REQUIRES A MEMORY THIS ALARM CANNOT ALWAYS KEEP. When
# the record cannot be written, the previous sweep's verdict never advances, so
# every later sweep re-enters the transition and re-sends - measured, four
# sweeps sent "has a first mate again after 10m / 15m / 20m / 25m without one",
# each duration longer than the last and every one of them describing an absence
# that had already ended. The repeat this file does keep is honest for an
# ABSENCE, which is a condition that lasts; it is nonsense for a RETURN, which
# is an event that happened once. Reporting a return with a length of time that
# was never true is worse than not reporting the return.
#
# WHAT IT DOES NOT DO
# It restarts nothing, repairs nothing, and kills nothing. There is no mechanism
# in this file that could. Restart belongs to bin/fm-seat-respawner.sh, and
# keeping the two apart is what lets the detector still speak when the restarter
# is the part that failed.
#
# Usage:
#   fm-seat-alarm.sh            evaluate; notify outward when the state warrants
#                               it; print at most one line, only on a change of
#                               state; always exit 0, because the watcher reads
#                               the line and not the status
#   fm-seat-alarm.sh --status   print the current evaluation in full whether or
#                               not it changed; notifies nothing, records nothing
#   fm-seat-alarm.sh --arm      write and register this home's watcher check
#                               (idempotent)
#   fm-seat-alarm.sh --armed    print one line when the alarm is not armed or has
#                               stopped running; silent otherwise
#   fm-seat-alarm.sh --help
#
# Exit status:
#   0  in the default and --arm modes, always: a check's job is its line
#   0  --status: measured, and a seat is present, standing down, or unattended
#   4  --status: the seat is absent
#   3  --status: the reading could not be taken, so no verdict is issued
#   2  usage error
#
# Durable record, under FM_HOME/data:
#   seat-alarm.log     one append-only line per state change and per outward
#                      send attempt, successful or not. In data/ rather than
#                      state/ because "how often has this vessel lost its first
#                      mate, and did the captain actually get told" is asked
#                      long after the volatile record of the moment is gone.
#   seat-alarm.state   the last state this alarm decided, when it decided it,
#                      and when it last notified - so a transition can be told
#                      from a continuation and the repeat cadence survives a
#                      restart.
#                      IT LIVES BESIDE THE LOG RATHER THAN IN state/ BECAUSE
#                      state/ IS ONE OF THE THINGS THIS ALARM MEASURES, and a
#                      memory kept inside the measured directory failed in both
#                      directions at once: writing it PUT THE DIRECTORY BACK, so
#                      the sweep after an unreachable-records reading found the
#                      records reachable again and settled on `unattended`; and
#                      it VANISHED WITH THE DIRECTORY, so every sweep measured
#                      an age of zero and the grace below never opened. One send
#                      went out and the instrument was quiet from then on. An
#                      instrument does not keep its records inside the thing it
#                      is reading.
#
# State, under FM_HOME/state:
#   seat-alarm.check.sh  the armed watcher check (with .check-trust)
#
# Environment:
#   FM_SEAT_ALARM_REPEAT    seconds between repeats while absent or unmeasured
#                           (default 1800); 0 disables repeating, transitions
#                           still notify
#   FM_SEAT_ALARM_GRACE     seconds an absence must persist before it is
#                           notified (default 60), so an ordinary seat restart
#                           between two sweeps does not page the captain
#   FM_SEAT_ALARM_STALE     how long without a completed evaluation before
#                           --armed calls the alarm stopped (default 1800)
#   FM_SEAT_ALARM_DISABLE=1 silence detect and --armed only, so suites that
#                           compose bin/fm-bootstrap.sh need not arm an alarm;
#                           every fixture home is unarmed by definition.
#                           --arm and --status are unaffected
#   FM_SEAT_ALARM_SEND      the outward sender to use (tests)
#   FM_SEAT_ALARM_SEND_TIMEOUT  seconds allowed for one send (default 15), kept
#                           well inside the watcher's 30s per-check budget
#   FM_SEAT_ALARM_PROBE_TIMEOUT  seconds allowed for the one outward probe this
#                           reading takes (default 5), so probe plus send stay
#                           inside that same 30s budget
#   FM_SEAT_ALARM_NOW       override the current epoch (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SEND=${FM_SEAT_ALARM_SEND:-$SCRIPT_DIR/fm-tg-send.sh}
RESPAWNER_SERVICE="$SCRIPT_DIR/fm-seat-respawner-service.sh"
LOG="$DATA/seat-alarm.log"
STATE_FILE="$DATA/seat-alarm.state"
CHECK="$STATE/seat-alarm.check.sh"
LOCK_FILE="$STATE/.lock"
ENDPOINT="$STATE/.primary-endpoint"
STAY_DOWN="$STATE/.seat-stay-down"
QUEUE="$STATE/.wake-queue"

REPEAT=${FM_SEAT_ALARM_REPEAT:-1800}
GRACE=${FM_SEAT_ALARM_GRACE:-60}
STALE=${FM_SEAT_ALARM_STALE:-1800}
SEND_TIMEOUT=${FM_SEAT_ALARM_SEND_TIMEOUT:-15}
PROBE_TIMEOUT=${FM_SEAT_ALARM_PROBE_TIMEOUT:-5}
NOW=${FM_SEAT_ALARM_NOW:-$(date +%s)}

case "$REPEAT" in *[!0-9]*|'') REPEAT=1800 ;; esac
case "$GRACE" in *[!0-9]*|'') GRACE=60 ;; esac
case "$STALE" in *[!0-9]*|'') STALE=1800 ;; esac
case "$SEND_TIMEOUT" in *[!0-9]*|''|0) SEND_TIMEOUT=15 ;; esac
case "$PROBE_TIMEOUT" in *[!0-9]*|''|0) PROBE_TIMEOUT=5 ;; esac
case "$NOW" in *[!0-9]*|'') NOW=$(date +%s) ;; esac

# shellcheck source=bin/fm-harness-pid-lib.sh
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"
# shellcheck source=bin/fm-seat-presence-lib.sh
. "$SCRIPT_DIR/fm-seat-presence-lib.sh"

MODE=detect
case "${1:-}" in
  '') ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  --help|-h)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")"
    exit 0 ;;
  *)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
  exit 2
fi

human_duration() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  else printf '%dd%dh' "$((s / 86400))" "$(((s % 86400) / 3600))"
  fi
}

iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- the reading ------------------------------------------------------------
#
# VERDICT is one of: present, absent, standing-down, unattended, unmeasured.
# REASON is one clause naming what settled it, always populated.
# Nothing below converts a failed reading into a pass.

VERDICT=unmeasured
REASON='the reading did not run'
RECORDS_REACHABLE=0
MEMORY_PERSISTABLE=1
SEAT_PID=
QUEUE_DEPTH=
QUEUE_OLDEST_AGE=
RESTARTER=

read_queue() {
  local first epoch
  QUEUE_DEPTH=
  QUEUE_OLDEST_AGE=
  [ -f "$QUEUE" ] && [ ! -L "$QUEUE" ] || { QUEUE_DEPTH=0; return 0; }
  QUEUE_DEPTH=$(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ') || { QUEUE_DEPTH=; return 0; }
  case "$QUEUE_DEPTH" in ''|*[!0-9]*) QUEUE_DEPTH=; return 0 ;; esac
  [ "$QUEUE_DEPTH" -gt 0 ] || return 0
  # Records are epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload, oldest first, so the
  # first field of the first line is when the oldest waiting item was queued.
  IFS= read -r first < "$QUEUE" 2>/dev/null || return 0
  epoch=${first%%	*}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$epoch" -le "$NOW" ] || return 0
  QUEUE_OLDEST_AGE=$((NOW - epoch))
}

# Whether anything is trying to bring the seat back. Read rather than assumed,
# because "absent and a restart is under way" and "absent and nothing is trying"
# are different messages and the captain acts differently on them. An
# unanswerable reading says so; it never reads as "a restart is under way".
#
# This is the one call in this file that leaves the process, and it is BOUNDED
# for the same reason the outward send is: the whole check is killed by
# bin/fm-watch.sh at FM_CHECK_TIMEOUT, and a probe that can block until then
# takes the message down with it - on a systemd home whose user manager is
# wedged, the D-Bus reading inside it blocks, and the alarm would die before
# notify() and before write_state(), silently, every sweep, on exactly the dead
# seat it exists to shout about. A probe that ran out of time is already an
# unreadable restarter, which is a state this reading can report.
#
# It also refuses to run at all when this home's records were found unreachable,
# because it is the probe named in the mutation rule above evaluate: it reaches
# bin/fm-wake-lib.sh, which creates this home's state directory as a side effect
# of being sourced. The unread default is the honest answer there.
read_restarter() {
  local line
  RESTARTER=
  [ "$RECORDS_REACHABLE" -eq 1 ] || return 0
  RESTARTER=unknown
  [ -x "$RESPAWNER_SERVICE" ] || return 0
  line=$(timeout "$PROBE_TIMEOUT" "$RESPAWNER_SERVICE" status 2>/dev/null) || true
  case "$line" in
    up:*) RESTARTER=up ;;
    down:*) RESTARTER=down ;;
    *) RESTARTER=unknown ;;
  esac
}

# A PROBE THAT MUTATES WHAT IT MEASURES IS NOT A PROBE, AND THIS IS THE RULE
# THAT KEEPS THIS FUNCTION HONEST. Whether this home's records are reachable is
# measured on the FIRST line of evaluate, before anything else runs, and
# published in RECORDS_REACHABLE.
#
# It is a rule rather than a caution on one call site because this file met it
# twice through different doors. First a probe REPAIRED the condition before it
# was measured: read_restarter runs bin/fm-seat-respawner-service.sh, which
# sources bin/fm-wake-lib.sh, which creates this home's state directory as a
# side effect of BEING SOURCED, so the unreachable-records branch could never
# fire. Then, with the reading taken first, the alarm repaired the condition
# AFTER measuring it: write_state made the directory it had just reported
# missing, so the next sweep read a healthy home.
#
# Two things hold it closed, and both are needed. The reading is taken FIRST, so
# no probe added below it can answer the question before it is asked; and in
# detect mode this file WRITES NOTHING INTO $STATE - its log and its memory both
# live in $DATA, so no write of its own can put back what it just reported
# missing. (--arm does write the check shim into $STATE, which is the one
# deliberate exception and is not part of a reading.) If you add a probe to
# evaluate, add it below the measurement; if you add a write, put it in data/,
# which this alarm does not read as a symptom.
evaluate() {
  RECORDS_REACHABLE=1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || RECORDS_REACHABLE=0

  if [ "$RECORDS_REACHABLE" -eq 0 ]; then
    # What actually reaches this branch on a vessel is a $STATE that exists and
    # is not a usable directory - a symlink, most of it. A state/ that has been
    # DELETED mostly cannot: this alarm runs only from the check shim inside it,
    # bin/fm-watch.sh finds checks by globbing "$STATE"/*.check.sh, so the shim
    # goes with the directory and nothing invokes this file at all. The reading
    # is still taken and still reported - that costs nothing and the branch is
    # genuinely reachable - but do not read it as covering a deleted state/ end
    # to end. docs/seat-absence.md carries that residual.
    #
    # Nothing else is read here: the queue and the restarter both live behind
    # the records this reading just found unreachable, so asking them would
    # answer with confident clauses ("nothing is waiting") composed from a
    # directory that is not there. Their unset defaults say "could not be read",
    # which is the truth.
    VERDICT=unmeasured
    REASON="this home's local records are not reachable at $STATE, so whether a first mate is running cannot be read"
    return
  fi

  read_queue

  if [ -f "$STAY_DOWN" ] && [ ! -L "$STAY_DOWN" ]; then
    VERDICT=standing-down
    REASON='the first mate was deliberately stood down and is meant to be absent'
    return
  fi

  # The lock reading itself belongs to bin/fm-seat-presence-lib.sh, which
  # bin/fm-seat-respawner.sh consumes too, so the detector and the restarter
  # cannot disagree about what the record says.
  fm_seat_presence "$LOCK_FILE"
  # shellcheck disable=SC2153 # Published by fm_seat_presence above.
  SEAT_PID=$FM_SEAT_PRESENCE_PID
  case "$FM_SEAT_PRESENCE" in
    present|unmeasured)
      VERDICT=$FM_SEAT_PRESENCE
      REASON=$FM_SEAT_PRESENCE_REASON
      return ;;
  esac

  # Absent, and only the alarm splits it further: whether a home that records no
  # holder ever had one is a question the ENDPOINT answers, not the lock, and
  # only this half reports the difference.
  if [ -z "$SEAT_PID" ]; then
    if [ -f "$ENDPOINT" ] && [ ! -L "$ENDPOINT" ]; then
      VERDICT=absent
      REASON='no first mate holds this vessel, though one has run here before'
    else
      VERDICT=unattended
      REASON='no first mate has ever run in this home, so there is none to be missing'
    fi
    return
  fi
  VERDICT=absent
  REASON=$FM_SEAT_PRESENCE_REASON
}

# --- durable record ---------------------------------------------------------

log_line() {  # <text>
  mkdir -p "$DATA" 2>/dev/null || return 0
  printf '%s %s\n' "$(iso "$NOW")" "$1" >> "$LOG" 2>/dev/null || true
}

PREV_VERDICT=
PREV_SINCE=
PREV_NOTIFIED=
read_state() {
  local line
  PREV_VERDICT=
  PREV_SINCE=
  PREV_NOTIFIED=
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      verdict=*) PREV_VERDICT=${line#verdict=} ;;
      since=*) PREV_SINCE=${line#since=} ;;
      notified=*) PREV_NOTIFIED=${line#notified=} ;;
    esac
  done < "$STATE_FILE"
  case "$PREV_SINCE" in *[!0-9]*|'') PREV_SINCE= ;; esac
  case "$PREV_NOTIFIED" in *[!0-9]*|'') PREV_NOTIFIED= ;; esac
}

# Whether this alarm can keep a memory at all, measured the only way it can be:
# by writing. An empty record cannot tell "this alarm has never run here" from
# "this alarm cannot remember anything", and those two want opposite treatment -
# the first is an ordinary first sweep, the second means every later reading in
# this sweep that leans on the previous one is an artefact.
# It performs the WHOLE of what write_state performs - create, fill, rename over
# a target, remove - because a cheaper prefix answers a different question. A
# filesystem that is full or over quota lets mktemp make the empty entry and
# then refuses the content or the rename, and that is exactly the failure this
# is being asked about; a probe that stopped at the create would call such a
# home persistable and hand the grace an age it can never measure.
#
# AN EXIT STATUS IS NOT THE READING; WHERE THE RECORD LANDED IS. `mv file dir`
# does not fail - it moves the file INSIDE the directory and reports success -
# so a target that is not a plain file leaves the record somewhere nothing will
# ever read it while every step says it worked. That is why this asks whether
# the byte it wrote is now a plain file AT the target, and why $STATE_FILE, the
# path this alarm actually renames over, is held to the same test.
memory_persistable() {
  local tmp probe="$DATA/.fm-seat-alarm-probe"
  mkdir -p "$DATA" 2>/dev/null || return 1
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
  fi
  tmp=$(mktemp "$DATA/.fm-seat-alarm-probe.XXXXXX" 2>/dev/null) || return 1
  printf 'probe\n' > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  if ! mv -f -- "$tmp" "$probe" 2>/dev/null \
    || [ ! -f "$probe" ] || [ -L "$probe" ]; then
    rm -f -- "$tmp" "$probe/${tmp##*/}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "$probe" 2>/dev/null || true
}

write_state() {  # <verdict> <since> <notified>
  local tmp
  mkdir -p "$DATA" || return 1
  tmp=$(mktemp "$DATA/.fm-seat-alarm-state.XXXXXX") || return 1
  {
    printf 'verdict=%s\n' "$1"
    printf 'since=%s\n' "$2"
    printf 'notified=%s\n' "$3"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; return 1; }
}

# --- what the captain is told -----------------------------------------------
#
# Written in the captain's own nouns per AGENTS.md section 9, because it reaches
# him directly with no first mate in between to translate it. The two facts that
# travel with the absence are the ones that decide whether he has to get up: how
# much work is waiting, and whether anything is trying to bring the seat back.

waiting_clause() {
  if [ -z "$QUEUE_DEPTH" ]; then
    printf 'How much work is waiting could not be read.'
    return
  fi
  if [ "$QUEUE_DEPTH" -eq 0 ]; then
    printf 'Nothing is waiting for it yet.'
    return
  fi
  if [ -n "$QUEUE_OLDEST_AGE" ]; then
    printf '%s notification(s) are waiting, the oldest from %s ago.' \
      "$QUEUE_DEPTH" "$(human_duration "$QUEUE_OLDEST_AGE")"
    return
  fi
  printf '%s notification(s) are waiting.' "$QUEUE_DEPTH"
}

restarter_clause() {
  case "$RESTARTER" in
    up) printf 'An automatic restart is running and should bring it back on its own.' ;;
    down) printf 'Nothing on this vessel is currently trying to bring it back.' ;;
    *) printf 'Whether anything is trying to bring it back could not be read.' ;;
  esac
}

repeat_clause() {
  [ "$MEMORY_PERSISTABLE" -eq 1 ] || {
    printf 'This vessel cannot write its own records, so it cannot remember having told you: expect this on every check until that is fixed.'
    return
  }
  [ "$REPEAT" -gt 0 ] || { printf 'This is the only message you will get about it.'; return; }
  printf 'This repeats every %s while it lasts.' "$(human_duration "$REPEAT")"
}

compose_message() {  # <verdict> <duration-seconds>
  local verdict=$1 age=$2
  case "$verdict" in
    absent)
      printf 'Captain, this vessel has had no first mate for %s.\n' "$(human_duration "$age")"
      printf 'This message comes from the vessel itself, because there is no first mate here to send it.\n'
      printf '%s\n' "$(waiting_clause)"
      printf '%s\n' "$(restarter_clause)"
      printf '%s\n' "$(repeat_clause)"
      ;;
    unmeasured)
      printf 'Captain, this vessel cannot tell whether it has a first mate: %s.\n' "$REASON"
      printf 'That is not an all-clear - it may have none and this could not see.\n'
      printf '%s\n' "$(waiting_clause)"
      printf '%s\n' "$(repeat_clause)"
      ;;
  esac
}

# The line the watcher prints, which is the one the returning seat reads. The
# two verdicts get different words for the same reason compose_message gives
# them different words: an absence was established and an unmeasured reading was
# not, so printing the confirmed sentence for both would state a fact the
# reading explicitly did not take.
transition_line() {  # <verdict> <duration-seconds>
  case "$1" in
    unmeasured)
      printf 'seat-alarm: this vessel has not been able to tell whether it has a first mate for %s (%s); %s %s\n' \
        "$(human_duration "$2")" "$REASON" "$(waiting_clause)" "$(restarter_clause)" ;;
    *)
      printf 'seat-alarm: this vessel has had no first mate for %s (%s); %s %s\n' \
        "$(human_duration "$2")" "$REASON" "$(waiting_clause)" "$(restarter_clause)" ;;
  esac
}

# Send, and never discard the result. A notification path that fails quietly
# gets trusted while it is dead, which is this task's own defect wearing a
# different hat. A failed send is recorded and NOT counted as a notification, so
# the next sweep tries again rather than falling silent on a message nobody got.
notify() {  # <verdict> <duration-seconds>
  local body rc=0 out
  body=$(compose_message "$1" "$2")
  [ -n "$body" ] || return 1
  if [ ! -x "$SEND" ]; then
    log_line "send-unavailable verdict=$1 no usable outward channel at $SEND"
    return 1
  fi
  out=$(printf '%s\n' "$body" | timeout "$SEND_TIMEOUT" "$SEND" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_line "sent verdict=$1 duration=$2 depth=${QUEUE_DEPTH:-unreadable} restarter=$RESTARTER"
    return 0
  fi
  log_line "send-failed verdict=$1 rc=$rc detail=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 1
}

# --- modes ------------------------------------------------------------------

arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-seat-alarm.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# The watcher is where this has to live: it is the one loop on this vessel that
# outlives the seat, and it is what stayed alive through the outage this alarm
# was written for. This shim is only the seam; the reading, the thresholds, and
# the outward message all live in the alarm itself, so they arrive by
# self-update instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-seat-alarm.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    umask 077
    tmp=$(mktemp "$STATE/.fm-seat-alarm-check.XXXXXX") || return 1
    printf '%s\n' "$desired" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" seat-alarm >/dev/null || return 1
}

armed_diagnostic() {
  local mtime age
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'SEAT_ALARM: nothing is watching whether this vessel still has a first mate, so its absence would again be noticed only by the captain (fix: %s/fm-seat-alarm.sh --arm)\n' \
      "$SCRIPT_DIR"
    return 0
  fi
  if [ ! -f "$STATE_FILE" ]; then
    mtime=$(stat -c %Y "$CHECK" 2>/dev/null) || return 0
    age=$((NOW - mtime))
    [ "$age" -gt "$STALE" ] &&
      printf 'SEAT_ALARM: the first-mate watch was armed %s ago and has never completed a reading, so nothing is watching for its absence (fix: %s/fm-seat-alarm.sh --status)\n' \
        "$(human_duration "$age")" "$SCRIPT_DIR"
    return 0
  fi
  mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null) || return 0
  age=$((NOW - mtime))
  [ "$age" -gt "$STALE" ] &&
    printf 'SEAT_ALARM: the first-mate watch last read this vessel %s ago and has stopped running, so nothing is watching for its absence now (fix: %s/fm-seat-alarm.sh --status)\n' \
      "$(human_duration "$age")" "$SCRIPT_DIR"
  return 0
}

case "$MODE" in
  arm)
    arm || { printf 'fm-seat-alarm: cannot arm the first-mate watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0 ;;
  armed)
    [ "${FM_SEAT_ALARM_DISABLE:-0}" = 1 ] && exit 0
    armed_diagnostic
    exit 0 ;;
  status)
    evaluate
    read_restarter
    printf 'seat-alarm: %s - %s\n' "$(printf '%s' "$VERDICT" | tr '[:lower:]' '[:upper:]')" "$REASON"
    [ -z "$SEAT_PID" ] || printf 'recorded first mate: pid %s\n' "$SEAT_PID"
    printf 'waiting work: %s\n' "$(waiting_clause)"
    printf 'restarter: %s\n' "$(restarter_clause)"
    case "$VERDICT" in
      absent)
        printf 'nothing has been restarted, repaired, or killed by this alarm, and nothing here can be\n'
        exit 4 ;;
      unmeasured)
        printf 'this is not an all-clear: this vessel may have no first mate and this could not tell\n'
        exit 3 ;;
      *) exit 0 ;;
    esac ;;
esac

# --- detect -----------------------------------------------------------------
#
# The watcher reads the line, not the exit status, so this mode always exits 0.
# It speaks on transition; the outward message repeats while the condition lasts.

[ "${FM_SEAT_ALARM_DISABLE:-0}" = 1 ] && exit 0

MEMORY_PERSISTABLE=1
memory_persistable || MEMORY_PERSISTABLE=0
read_state
evaluate

SINCE=$NOW
NOTIFIED=
if [ "$VERDICT" = "$PREV_VERDICT" ]; then
  SINCE=${PREV_SINCE:-$NOW}
  NOTIFIED=$PREV_NOTIFIED
fi
AGE=$((NOW - SINCE))
[ "$AGE" -ge 0 ] || AGE=0
# SINCE comes from the previous sweep's record. With no memory to keep it, every
# sweep sets SINCE to itself and the age that falls out is an artefact of that,
# not a measurement - so it is not reported as one. human_duration renders an
# empty age as "an unknown time".
[ "$MEMORY_PERSISTABLE" -eq 1 ] || AGE=

case "$VERDICT" in
  absent|unmeasured)
    # The grace exists so an ordinary restart between two sweeps does not page
    # him. What it costs is measured rather than nominal: SINCE is reset on the
    # verdict TRANSITION, so AGE is 0 on the sweep that first observes the
    # absence - that sweep records the state and sends nothing, and the message
    # goes out on the SECOND sweep, between one and two sweep intervals after
    # the seat actually died (5 to 10 minutes at the FM_CHECK_INTERVAL default
    # of 300). Any grace below the sweep interval is therefore indistinguishable
    # from any other: GRACE=60 and GRACE=299 behave identically, and only
    # GRACE=0 pages on the observing sweep. docs/seat-absence.md sets the
    # captain's expectation to that second sweep so a working alarm is not read
    # as a broken one.
    #
    # A GRACE IS APPLIED TO AN AGE, AND AN AGE THIS ALARM COULD NOT MEASURE MUST
    # NEVER BE WHAT SILENCES IT. When the memory cannot be kept, every sweep
    # measures 0, a nonzero grace never opens, and the alarm goes permanently
    # quiet on the one reading it exists to shout about - measured, on a home
    # whose data/ could not be written: eight sweeps, an hour of a dead seat,
    # nothing sent and nothing printed. So the grace is asked only when there is
    # a remembered age to ask it about.
    GRACE_PASSED=0
    if [ "$MEMORY_PERSISTABLE" -eq 0 ]; then
      GRACE_PASSED=1
    elif [ "$AGE" -ge "$GRACE" ]; then
      GRACE_PASSED=1
    fi
    if [ "$GRACE_PASSED" -eq 1 ]; then
      DUE=0
      if [ -z "$NOTIFIED" ]; then
        DUE=1
      elif [ "$REPEAT" -gt 0 ] && [ "$((NOW - NOTIFIED))" -ge "$REPEAT" ]; then
        DUE=1
      fi
      if [ "$DUE" -eq 1 ]; then
        # FIRST means "this is the first sweep of this episode", which is a fact
        # about the previous sweep and is therefore not knowable without a
        # memory. An alarm that cannot tell one sweep from the next must not
        # claim one, and must not grow the durable wake queue once per sweep on
        # the strength of the claim - so the printed line waits for the memory
        # to come back, while the outward send below does not.
        FIRST=0
        [ "$MEMORY_PERSISTABLE" -eq 1 ] && [ -z "$NOTIFIED" ] && FIRST=1
        # Asked here rather than in the reading, per that reading's own rule
        # that a probe goes below the measurement: nothing above needs it, only
        # the message about to go out does, and a healthy vessel then pays no
        # subprocess for it on any sweep.
        read_restarter
        if notify "$VERDICT" "$AGE"; then
          NOTIFIED=$NOW
        fi
        # The printed line is for the seat that eventually returns, so it is
        # emitted once per episode rather than on every repeat: a queue nobody
        # is draining must not be grown by the alarm that says nobody is
        # draining it.
        if [ "$FIRST" -eq 1 ]; then
          log_line "entered verdict=$VERDICT reason=$REASON depth=${QUEUE_DEPTH:-unreadable} restarter=$RESTARTER"
          transition_line "$VERDICT" "$AGE"
        fi
      fi
    fi
    ;;
  present)
    # The return goes into the history and nowhere else. Nothing is sent and
    # nothing is printed: telling him once needs a memory this alarm cannot
    # always keep, and a return re-announced every sweep with a duration that
    # grows past the absence it describes is worse than the silence.
    case "$PREV_VERDICT" in
      absent|unmeasured)
        AWAY=$((NOW - ${PREV_SINCE:-$NOW}))
        [ "$AWAY" -ge 0 ] || AWAY=0
        log_line "recovered from=$PREV_VERDICT away=$AWAY depth=${QUEUE_DEPTH:-unreadable}"
        ;;
    esac
    ;;
esac

write_state "$VERDICT" "$SINCE" "$NOTIFIED" || true
exit 0
