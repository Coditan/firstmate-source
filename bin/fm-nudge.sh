#!/usr/bin/env bash
# Raise this home's off-grid fleet nudges, one watcher check with several subjects.
#
# WHAT THIS IS FOR
# Some fleet duties are periodic re-measures rather than reactions to a change,
# and an instruction with no mechanism is carried by memory. This is the cadence
# those duties lack. It measures nothing about any other vessel, sweeps nothing,
# and raises one wake per due subject.
#
# THE SUBJECTS
#   curation        every 48 hours. data/learnings.md and data/captain.md are
#                   per-home, captain-private and gitignored. Every vessel has
#                   one pair, no vessel can see another's, and until this check
#                   nothing anywhere re-measured them. AGENTS.md section 10
#                   already said to prune rather than append. Measured on this
#                   seat on 2026-08-17, when this was commissioned:
#                   data/learnings.md had reached 5,445 lines / 417 KB, and with
#                   data/captain.md the pair was 86% of the whole session-start
#                   digest - roughly 130k tokens read before any work, against a
#                   300k context ceiling. Re-measured hours later, a curation
#                   pass had already run and the pair was 171 KB. Both readings
#                   are in docs/nudge-cadence.md, because the second one is the
#                   point: a human sweep can clear the debt, and nothing
#                   scheduled that sweep or the next one.
#   codebase-sweep  every 52 hours. A repository that is hard for a stranger to
#                   navigate is hard for every agent pointed at it, because an
#                   agent arrives with no memory of it at all. The obligation
#                   lives in the codebase-sweep skill; this cadence only fires.
#
# ONE CHECK, SEVERAL SUBJECTS - AND WHY NOT SIBLING UNITS
# A second subject is registered here rather than given a unit of its own.
# Two near-identical units on one host is a trap this fleet has already measured:
# bridge-notify-poll.timer reported loaded, enabled and active on 2026-08-17
# while last having fired nine days earlier, with every surface reporting health.
# Sibling units that behave differently are worse than one unit with two
# subjects, because the difference is invisible until one of them is the one
# that stopped. So there is one armed shim, one arming path, one health reading
# shape, and one place where the cadence rules are written; each subject brings
# only its own period, its own record, and its own payload.
#
# DELIBERATELY DIFFERENT PERIODS
# No two subjects share a period, so no two lock to one wall-clock rhythm and
# arrive together every time. 48 and 52 hours re-approach only at their common
# multiple, and even then each subject draws its own jitter, keeps its own
# record, and raises its own separate wake. docs/nudge-cadence.md
# "Two subjects that do not travel together" records the measured separation.
#
# TWO HOPS, AND WHY THIS IS NOT ONE
# A timer that broadcasts is firstmate calling Bridge project automation
# directly with extra steps, which AGENTS.md section 1 forbids, and it is
# unauditable besides: nobody ever sees what a timer said. So the notice takes
# two hops and this script owns only the first.
#   1. This check fires and raises an ordinary check wake naming what is due.
#   2. Firstmate reads that wake and dispatches a crewmate to send the All-Ships
#      notice, exactly as AGENTS.md section 12 requires of any fleet notice.
# Nothing here writes to Bridge, opens a network connection, or touches a git
# repository. tests/fm-nudge.test.sh asserts that boundary by executing every
# mode with tripwires on every route off-machine.
#
# THE CADENCE, AND THE FIVE-MINUTE REFUSAL
# Each firing draws 180-420 seconds of fresh jitter for the NEXT target, so
# successive fires drift instead of locking to one wall-clock time.
#
# The drawn target's minute is NEVER a multiple of five. Cron defaults, systemd
# timers, monitoring pollers and this fleet's own watcher sweep all cluster on
# five-minute boundaries, so a fleet-wide fire landing there stacks on top of
# everything the machines are already doing. It is implemented as a refusal, not
# a preference: draw_next_due computes a target, and a target whose minute is a
# multiple of five is discarded and re-drawn. The jitter window spans five
# consecutive minutes, of which at most one is on the grid, so a draw refuses at
# most a handful of times; exhausting the attempt bound reports a failure to
# schedule rather than silently accepting an on-grid target.
#
# The minute is computed in UTC and holds in every real local time. Every
# civil UTC offset in use is a whole multiple of 15 minutes - +05:30 and +05:45
# included - so a local rendering shifts the minute by a multiple of five and
# cannot move a target on or off the grid.
#
# WHAT THE TARGET GUARANTEES, AND WHAT IT DOES NOT
# The target is the scheduled firing instant and is off-grid by construction.
# The watcher observes it on its next state/*.check.sh sweep, so the observation
# instant is the target plus however far the sweep has to travel; that sweep's
# phase belongs to bin/fm-watch.sh and is not re-decided here. This script owns
# the target, states it in its own report, and claims nothing about the sweep.
#
# THE HEALTH READING
# Unit state lies. bridge-notify-poll.timer on this host reported enabled,
# active and loaded on 2026-08-17 while having last fired on 2026-08-07; the
# only tell was `Active: active (elapsed)` with `Trigger: n/a`. So --armed never
# asks this check whether it is fine. It reads what the WORK produced, per
# subject: when that subject last actually fired, and whether a next target
# exists and is still plausible. A home whose checks stopped running keeps a
# target that goes further and further past due, which is loud; a home that
# never produced a target at all is the `Trigger: n/a` shape, and is loud too.
#
# An overdue target can also be the durable remainder of a failed publish: the
# failure cannot record itself because publication is the operation that failed.
# So --armed never concludes a supervision outage without first publishing a
# representative report to distinct scratch paths in the state directory,
# whether a target is overdue or the first record is still missing. A usable
# path identifies a supervision outage, an unusable path identifies a
# persistence failure, and an indeterminate or unclean probe names both possible
# causes without asserting either one.
#
# Usage:
#   fm-nudge.sh                     detect: stay silent on an ordinary sweep;
#                                   print the wake on an ordinary firing; print
#                                   the wake plus its diagnostic when successor
#                                   scheduling refuses. A failed atomic publish
#                                   prints its persistence diagnostic instead of
#                                   the wake, leaving the prior due event intact.
#                                   Every subject is evaluated, so a sweep can
#                                   print none, one, or several wakes. Exit 0
#                                   after ordinary sweeps, firings, and persisted
#                                   refusals; exit non-zero when any subject's
#                                   state cannot be persisted. The watcher
#                                   captures printed output regardless of that
#                                   exit status, so a persistence diagnostic
#                                   still becomes a wake.
#   fm-nudge.sh --force             fire now, ignoring the schedule
#   fm-nudge.sh --status            print each subject's schedule and readings;
#                                   writes no state and does not create the state
#                                   directory
#   fm-nudge.sh --draw [n]          print n independently drawn next targets for
#                                   the selected subject as epoch seconds, one
#                                   per line (default 1), writing no state or
#                                   state directory. This is the scheduling
#                                   function itself, exposed so its refusal can
#                                   be asserted over many draws. --subject is
#                                   required, because a count spread over several
#                                   periods names no one schedule.
#   fm-nudge.sh --arm               write and register this home's single watcher
#                                   check shim, serving every subject (idempotent)
#   fm-nudge.sh --armed             print one <SUBJECT CODE> line per subject that
#                                   is not armed, has never scheduled a target,
#                                   or has an overdue target. For an overdue
#                                   target it distinguishes state persistence,
#                                   supervision, and an indeterminate reading;
#                                   silent otherwise
#   fm-nudge.sh --subjects          print each registered subject, its diagnostic
#                                   code, and its period in seconds
#   fm-nudge.sh --help
#
#   --subject <slug> restricts any mode above to one registered subject.
#   Detect, --force, --status and --armed cover every subject without it.
#
# Subjects, their codes, and their default periods:
#   curation         CURATION_NUDGE          172800 (48h)
#   codebase-sweep   CODEBASE_SWEEP_NUDGE    187200 (52h)
#
# State, all under FM_HOME/state:
#   <subject>-nudge.report   the single authoritative, human-readable and
#                            parseable record of that subject's last firing,
#                            current scheduling outcome, cadence, and readings
#   nudge.check.sh           the one armed watcher shim (with .check-trust),
#                            shared by every subject
#
# Environment, per subject, named after that subject's diagnostic code:
#   FM_<CODE>_INTERVAL      cadence in seconds (default: that subject's period)
#   FM_<CODE>_JITTER_MIN    low end of the per-firing jitter (default 180)
#   FM_<CODE>_JITTER_MAX    high end of the per-firing jitter (default 420)
#   FM_<CODE>_OVERDUE       how far past its target a subject may sit before
#                           --armed calls the cadence stopped (default 7200).
#                           The watcher sweeps far more often than that, so this
#                           is slack, not a second cadence.
#   FM_<CODE>_NOW           override the current epoch for that subject (tests)
#   FM_<CODE>_DISABLE=1     silence detect and --armed for that subject only, so
#                           suites that compose bin/fm-bootstrap.sh need not arm
#                           a nudge. --status, --draw, --force, --subjects and
#                           --arm are unaffected.
# So the curation subject reads FM_CURATION_NUDGE_INTERVAL, and the
# codebase-sweep subject reads FM_CODEBASE_SWEEP_NUDGE_INTERVAL.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CHECK="$STATE/nudge.check.sh"
CHECK_ID=nudge

# The single-subject shim this check replaced. --arm removes it, so a home that
# updates does not keep a registered sibling that execs a script no longer there
# - the watcher sends a check's standard error to /dev/null, so such a sibling
# would fail silently forever rather than saying anything.
LEGACY_CHECK="$STATE/curation-nudge.check.sh"
LEGACY_TRUST="$STATE/curation-nudge.check-trust"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

# The registered subjects, in the order they are evaluated and reported.
SUBJECTS='curation codebase-sweep'

# The bound on re-draws. The jitter window spans five consecutive minutes, so at
# most one candidate minute in five is on the grid and a draw refuses maybe once
# or twice. Sixty-four consecutive refusals cannot happen with a sane window; if
# a caller narrows the window onto a single on-grid minute it must be told so
# rather than handed a target the refusal was supposed to prevent.
DRAW_ATTEMPTS=64

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# --- the subject registry ----------------------------------------------------

# Everything that differs between subjects is set here and nowhere else, so a
# third subject is a third case arm rather than a second copy of the mechanism.
SUBJECT=''
CODE=''
REPORT=''
INTERVAL=0
JITTER_MIN=180
JITTER_MAX=420
OVERDUE=7200
NOW=0
DISABLED=0
SUBJECT_SWEEP=''
SUBJECT_NUDGE_NAME=''
SUBJECT_RECORD_NOUN=''
SUBJECT_UNARMED_CONSEQUENCE=''

subject_known() {  # <slug>
  case " $SUBJECTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# An environment override for the selected subject, named after its code.
env_override() {  # <suffix>
  local name="FM_${CODE}_$1"
  [ -n "${!name+set}" ] || return 1
  printf '%s' "${!name}"
}

numeric_env() {  # <suffix> <default>
  local value
  value=$(env_override "$1") || { printf '%s' "$2"; return 0; }
  case "$value" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  printf '%s' "$value"
}

subject_select() {  # <slug>
  local period
  SUBJECT=$1
  case "$SUBJECT" in
    curation)
      CODE=CURATION_NUDGE
      period=172800
      SUBJECT_SWEEP='curation sweep'
      SUBJECT_NUDGE_NAME='knowledge-file curation nudge'
      SUBJECT_RECORD_NOUN=curation
      SUBJECT_UNARMED_CONSEQUENCE="nothing will re-measure this vessel's learnings and captain files between sessions"
      ;;
    codebase-sweep)
      CODE=CODEBASE_SWEEP_NUDGE
      period=187200
      SUBJECT_SWEEP='codebase-design sweep'
      SUBJECT_NUDGE_NAME='codebase-design sweep nudge'
      SUBJECT_RECORD_NOUN=codebase-sweep
      SUBJECT_UNARMED_CONSEQUENCE='nothing will ask this vessel to re-measure its own repositories between sessions'
      ;;
    *)
      printf 'fm-nudge: unknown subject %s\n' "$SUBJECT" >&2
      return 1
      ;;
  esac
  REPORT="$STATE/$SUBJECT-nudge.report"
  INTERVAL=$(numeric_env INTERVAL "$period")
  JITTER_MIN=$(numeric_env JITTER_MIN 180)
  JITTER_MAX=$(numeric_env JITTER_MAX 420)
  OVERDUE=$(numeric_env OVERDUE 7200)
  [ "$JITTER_MAX" -ge "$JITTER_MIN" ] || { JITTER_MIN=180; JITTER_MAX=420; }
  NOW=$(numeric_env NOW "$(date +%s)")
  DISABLED=0
  [ "$(env_override DISABLE || printf 0)" = 1 ] && DISABLED=1
  return 0
}

# --- argument parsing ---------------------------------------------------------

MODE=detect
DRAW_COUNT=1
SELECTED=''
MODE_SEEN=0

bad_usage() {
  [ "$#" -eq 0 ] || printf 'fm-nudge: %s\n' "$*" >&2
  printf 'usage: %s [--subject <slug>] [--force|--status|--draw [n]|--arm|--armed|--subjects|--help]\n' \
    "$(basename "$0")" >&2
  exit 2
}

set_mode() {  # <mode>
  [ "$MODE_SEEN" -eq 0 ] || bad_usage "only one mode may be given"
  MODE=$1
  MODE_SEEN=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) set_mode force ;;
    --status) set_mode status ;;
    --arm) set_mode arm ;;
    --armed) set_mode armed ;;
    --subjects) set_mode subjects ;;
    --draw)
      set_mode draw
      case "${2:-}" in
        ''|-*) ;;
        *)
          DRAW_COUNT=$2
          shift
          case "$DRAW_COUNT" in
            ''|*[!0-9]*|0) bad_usage "--draw needs a positive count" ;;
          esac
          ;;
      esac
      ;;
    --subject)
      [ "$#" -ge 2 ] || bad_usage "--subject needs a subject name"
      SELECTED=$2
      shift
      subject_known "$SELECTED" || {
        printf 'fm-nudge: unknown subject %s (registered: %s)\n' "$SELECTED" "$SUBJECTS" >&2
        exit 2
      }
      ;;
    *) bad_usage "unknown argument $1" ;;
  esac
  shift
done

# A count spread over several periods names no one schedule, so the scheduling
# function is only exposed for a named subject.
[ "$MODE" != draw ] || [ -n "$SELECTED" ] || bad_usage "--draw needs --subject <slug>"

# The subjects this invocation covers.
if [ -n "$SELECTED" ]; then
  ACTIVE_SUBJECTS=$SELECTED
else
  ACTIVE_SUBJECTS=$SUBJECTS
fi

# The same two-line portability shim bin/fm-currency-round.sh carries: BSD stat
# and GNU stat spell mtime differently.
path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# An epoch as a UTC timestamp under whichever date this machine has.
epoch_utc() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# --- the scheduling function ------------------------------------------------

# The minute of the hour an epoch lands on, in UTC. Every civil offset in use is
# a whole multiple of 15 minutes, so this value's remainder mod five is the same
# in every local rendering of the same instant.
minute_of() {  # <epoch>
  printf '%s' "$(( ( $1 / 60 ) % 60 ))"
}

on_five_minute_grid() {  # <epoch>
  [ "$(( ( ( $1 / 60 ) % 60 ) % 5 ))" -eq 0 ]
}

# The next firing target from a base epoch: base + this subject's period + fresh
# jitter, REFUSING any target whose minute is a multiple of five and drawing
# again. Fails rather than returning an on-grid target.
draw_next_due() {  # <base-epoch>
  local base=$1 span attempt=0 jitter target
  span=$(( JITTER_MAX - JITTER_MIN + 1 ))
  while [ "$attempt" -lt "$DRAW_ATTEMPTS" ]; do
    jitter=$(( JITTER_MIN + RANDOM % span ))
    target=$(( base + INTERVAL + jitter ))
    if ! on_five_minute_grid "$target"; then
      printf '%s' "$target"
      return 0
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# --- readings ---------------------------------------------------------------

# This seat's own files, and only this seat's. A home cannot read another
# vessel's data/, so every number here is stated as this vessel's own.
# The share of the session-start digest is deliberately NOT computed: modelling
# what that digest contains here would be a second model of bin/fm-session-start.sh
# that drifts silently, and the share is exactly what each vessel measures for
# itself when it takes the sweep this nudge asks for.
file_reading() {  # <path> -> "<lines> lines, <bytes> bytes" or "absent"
  local path=$1 lines bytes
  if [ ! -f "$path" ]; then
    printf 'absent'
    return 0
  fi
  lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
  bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
  case "${lines:-}" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
  case "${bytes:-}" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
  printf '%s %s, %s %s' \
    "$lines" "$(plural "$lines" line)" "$bytes" "$(plural "$bytes" byte)"
}

# "1 lines" in a line a supervisor reads is the kind of sloppiness that makes a
# reading look unmaintained, and an unmaintained-looking reading gets skimmed.
plural() {  # <count> <singular>
  if [ "$1" -eq 1 ] 2>/dev/null; then
    printf '%s' "$2"
  else
    printf '%ss' "$2"
  fi
}

# What this seat can honestly state about its own subject, without sweeping and
# without claiming anything about another vessel. A subject whose material is
# inside repositories has no cheap reading, and says so rather than inventing
# one: only a dispatched sweep can measure it, and this cadence never sweeps.
render_readings() {
  case "$SUBJECT" in
    curation)
      printf 'reading: this vessel data/learnings.md %s\n' "$(file_reading "$DATA/learnings.md")"
      printf 'reading: this vessel data/captain.md %s\n' "$(file_reading "$DATA/captain.md")"
      ;;
    codebase-sweep)
      printf 'reading: none taken. What this sweep measures is inside each repository, and only a dispatched sweep can measure it; this cadence reads no repository, here or anywhere.\n'
      ;;
  esac
}

render_notes() {
  case "$SUBJECT" in
    curation)
      printf 'note: both readings are THIS VESSEL'"'"'S OWN files. They are per-home and gitignored, so this seat cannot see another vessel'"'"'s and makes no claim about one.\n'
      printf 'note: the share of the session-start digest is not measured here; each vessel measures its own, because a second model of that digest would drift silently.\n'
      ;;
    codebase-sweep)
      printf 'note: this cadence sweeps nothing. The obligation lives in the codebase-sweep skill, which runs on one named repository at a time; each vessel runs it on its OWN repositories and decides for itself.\n'
      ;;
  esac
  printf 'note: this nudge raises a wake and nothing else. The All-Ships notice is dispatched to a crewmate by firstmate, per AGENTS.md section 12.\n'
}

RECORD_STATE=''
RECORD_NEXT=0
RECORD_LAST=0
RECORD_RECORDED=0
RECORD_SURFACED=0
RECORD_INTERVAL=0
RECORD_JITTER_MIN=0
RECORD_JITTER_MAX=0
RECORD_ATTEMPTS=0
RECORD_PERSISTENCE_PATH=''
RECORD_PERSISTENCE_CONDITION=''
PERSISTENCE_PATH=''
PERSISTENCE_CONDITION=''

read_record() {
  local key value
  RECORD_STATE=''
  RECORD_NEXT=0
  RECORD_LAST=0
  RECORD_RECORDED=0
  RECORD_SURFACED=0
  RECORD_INTERVAL=0
  RECORD_JITTER_MIN=0
  RECORD_JITTER_MAX=0
  RECORD_ATTEMPTS=0
  RECORD_PERSISTENCE_PATH=''
  RECORD_PERSISTENCE_CONDITION=''
  [ -f "$REPORT" ] || return 1
  while IFS=': ' read -r key value; do
    case "$key" in
      state) RECORD_STATE=$value ;;
      next-epoch) RECORD_NEXT=$value ;;
      last-fire-epoch) RECORD_LAST=$value ;;
      refusal-recorded-epoch) RECORD_RECORDED=$value ;;
      refusal-surfaced) RECORD_SURFACED=$value ;;
      interval-seconds) RECORD_INTERVAL=$value ;;
      jitter-min-seconds) RECORD_JITTER_MIN=$value ;;
      jitter-max-seconds) RECORD_JITTER_MAX=$value ;;
      draw-attempts) RECORD_ATTEMPTS=$value ;;
      persistence-path) RECORD_PERSISTENCE_PATH=$value ;;
      persistence-condition) RECORD_PERSISTENCE_CONDITION=$value ;;
    esac
  done < "$REPORT"
  case "$RECORD_LAST:$RECORD_INTERVAL:$RECORD_JITTER_MIN:$RECORD_JITTER_MAX:$RECORD_ATTEMPTS" in
    *[!0-9:]*) return 1 ;;
  esac
  [ "$RECORD_INTERVAL" -gt 0 ] && [ "$RECORD_ATTEMPTS" -gt 0 ] || return 1
  case "$RECORD_STATE" in
    scheduled)
      case "$RECORD_NEXT" in ''|*[!0-9]*|0) return 1 ;; esac
      ;;
    refused)
      case "$RECORD_RECORDED:$RECORD_SURFACED" in *[!0-9:]*) return 1 ;; esac
      [ "$RECORD_RECORDED" -gt 0 ] || return 1
      ;;
    persistence)
      [ -n "$RECORD_PERSISTENCE_PATH" ] && [ -n "$RECORD_PERSISTENCE_CONDITION" ] || return 1
      ;;
    *) return 1 ;;
  esac
}

render_record() {
  local state=$1 next=$2 last=$3 recorded=$4 surfaced=$5 persistence_path=$6 persistence_condition=$7
  printf 'subject: %s\n' "$SUBJECT"
  printf 'code: %s\n' "$CODE"
  printf 'state: %s\n' "$state"
  printf 'next-epoch: %s\n' "$next"
  printf 'last-fire-epoch: %s\n' "$last"
  printf 'refusal-recorded-epoch: %s\n' "$recorded"
  printf 'refusal-surfaced: %s\n' "$surfaced"
  printf 'interval-seconds: %s\n' "$INTERVAL"
  printf 'jitter-min-seconds: %s\n' "$JITTER_MIN"
  printf 'jitter-max-seconds: %s\n' "$JITTER_MAX"
  printf 'draw-attempts: %s\n' "$DRAW_ATTEMPTS"
  printf 'persistence-path: %s\n' "$persistence_path"
  printf 'persistence-condition: %s\n' "$persistence_condition"
  printf 'nudge: %s\n' "$(epoch_utc "$NOW")"
  case "$state" in
    scheduled) printf 'next: %s (minute %s, off the five-minute grid)\n' "$(epoch_utc "$next")" "$(minute_of "$next")" ;;
    refused) printf 'next: refused because all %s candidate minutes from FM_%s_JITTER_MIN=%s through FM_%s_JITTER_MAX=%s with FM_%s_INTERVAL=%s landed on the five-minute grid\n' "$DRAW_ATTEMPTS" "$CODE" "$JITTER_MIN" "$CODE" "$JITTER_MAX" "$CODE" "$INTERVAL" ;;
    persistence) printf 'next: scheduling state persistence failed at %s because %s\n' "$persistence_path" "$persistence_condition" ;;
  esac
  if [ "$last" -gt 0 ]; then
    printf 'last-fire: %s\n' "$(epoch_utc "$last")"
  else
    printf 'last-fire: never\n'
  fi
  printf 'cadence: every %ss, plus %s-%ss of fresh jitter drawn at each firing\n' \
    "$INTERVAL" "$JITTER_MIN" "$JITTER_MAX"
  render_readings
  render_notes
}

publish_record() {
  local state=$1 next=$2 last=$3 recorded=$4 surfaced=$5 persistence_path=$6 persistence_condition=$7 tmp
  PERSISTENCE_PATH=''
  PERSISTENCE_CONDITION=''
  [ ! -d "$REPORT" ] || {
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION="the authoritative $SUBJECT_RECORD_NOUN record could not replace a directory at its state path"
    return 1
  }
  tmp=$(mktemp "$STATE/.$SUBJECT-nudge-report.XXXXXX") || {
    PERSISTENCE_PATH=$STATE
    PERSISTENCE_CONDITION="temporary state for the authoritative $SUBJECT_RECORD_NOUN record could not be created"
    return 1
  }
  render_record "$state" "$next" "$last" "$recorded" "$surfaced" "$persistence_path" "$persistence_condition" > "$tmp" || {
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$tmp
    PERSISTENCE_CONDITION="the authoritative $SUBJECT_RECORD_NOUN record could not be written to temporary state"
    return 1
  }
  if ! mv -f -- "$tmp" "$REPORT"; then
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION="the authoritative $SUBJECT_RECORD_NOUN record could not be atomically published"
    return 1
  fi
}

schedule_transition() {
  local firing_epoch=${1:-0} target last=0
  if read_record; then
    last=$RECORD_LAST
  fi
  [ "$firing_epoch" -eq 0 ] || last=$firing_epoch
  if target=$(draw_next_due "$NOW"); then
    publish_record scheduled "$target" "$last" 0 0 '' '' || return 2
    return 0
  fi
  if [ "$firing_epoch" -eq 0 ] && [ "$RECORD_STATE" = refused ] \
    && [ "$RECORD_INTERVAL" = "$INTERVAL" ] \
    && [ "$RECORD_JITTER_MIN" = "$JITTER_MIN" ] \
    && [ "$RECORD_JITTER_MAX" = "$JITTER_MAX" ] \
    && [ "$RECORD_ATTEMPTS" = "$DRAW_ATTEMPTS" ] \
    && [ "$RECORD_SURFACED" -eq 1 ]; then
    return 3
  fi
  publish_record refused 0 "$last" "$NOW" 1 '' '' || return 2
  return 1
}

render_absent_report() {
  printf 'subject: %s\n' "$SUBJECT"
  printf 'code: %s\n' "$CODE"
  printf 'state: absent\n'
  printf 'next: none scheduled\n'
  printf 'last-fire: never\n'
  printf 'cadence: every %ss, plus %s-%ss of fresh jitter drawn at each firing\n' "$INTERVAL" "$JITTER_MIN" "$JITTER_MAX"
  render_readings
}

# The one line worth waking a supervisor for. It is a prompt to measure, never a
# claim about any vessel other than this one.
nudge_line() {
  case "$SUBJECT" in
    curation)
      printf 'CURATION_NUDGE: the fleet knowledge-file curation sweep is due (every %s hours). Dispatch a crewmate to send the All-Ships notice asking every vessel to measure its OWN data/learnings.md and data/captain.md - line count, byte size, and what share of its own session-start digest the pair is - and to decide for itself whether that share is worth what it costs. This vessel'"'"'s own reading: learnings.md %s; captain.md %s. Nothing is claimed about any other vessel. Full record: %s\n' \
        "$(( INTERVAL / 3600 ))" \
        "$(file_reading "$DATA/learnings.md")" \
        "$(file_reading "$DATA/captain.md")" \
        "$REPORT"
      ;;
    codebase-sweep)
      printf 'CODEBASE_SWEEP_NUDGE: the codebase-design sweep is due (every %s hours). Dispatch a crewmate to send the All-Ships notice asking every vessel to load the codebase-sweep skill and run it on its OWN repositories, one named repository at a time, and to decide for itself which findings it may take without the captain. This cadence only fires: it sweeps nothing, reads no repository, and claims nothing about any vessel'"'"'s code, here or anywhere. Full record: %s\n' \
        "$(( INTERVAL / 3600 ))" \
        "$REPORT"
      ;;
  esac
}

schedule_refusal_line() {
  printf '%s: no next %s was scheduled because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_%s_JITTER_MIN=%s, FM_%s_JITTER_MAX=%s, FM_%s_INTERVAL=%s); the draw attempt bound was exhausted, so set the jitter window to include an off-grid target minute\n' \
    "$CODE" "$SUBJECT_SWEEP" "$DRAW_ATTEMPTS" "$CODE" "$JITTER_MIN" "$CODE" "$JITTER_MAX" "$CODE" "$INTERVAL"
}

state_persistence_line() {
  printf '%s: state persistence failure at %s because %s; repair that state path and run the check again\n' \
    "$CODE" "$PERSISTENCE_PATH" "$PERSISTENCE_CONDITION"
}

# --- modes ------------------------------------------------------------------

case "$MODE" in
  draw|status|subjects) ;;
  armed)
    if { [ -e "$STATE" ] && [ ! -d "$STATE" ]; } \
      || { [ ! -e "$STATE" ] && [ ! -d "${STATE%/*}" ]; }; then
      # Deliberately said even for a subject silenced by its DISABLE flag: that
      # flag exists so composing suites are not polluted by an ordinary cadence,
      # and an unusable state directory is not the ordinary cadence.
      for subject in $ACTIVE_SUBJECTS; do
        subject_select "$subject" || exit 2
        printf '%s: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' \
          "$CODE" "$STATE"
      done
      exit 1
    fi
    ;;
  *)
    if ! mkdir -p "$STATE" 2>/dev/null; then
      if [ "$MODE" = detect ]; then
        for subject in $ACTIVE_SUBJECTS; do
          subject_select "$subject" || exit 2
          printf '%s: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' \
            "$CODE" "$STATE"
        done
        exit 1
      fi
      printf 'fm-nudge: cannot create state directory %s\n' "$STATE" >&2
      exit 1
    fi
    ;;
esac

# Write this home's watcher shim and bind it to its own bytes. Every location is
# baked in rather than inherited: the watcher runs a check from a private
# snapshot with its own environment, so a shim that guessed its home would nudge
# a different one. Idempotent - an already-correct, already-registered shim is
# left exactly as it is, so bootstrap can call this on every session.
#
# One shim, every subject. The shim passes no subject, so a subject added to the
# registry arrives on every already-armed home by self-update, without that home
# having to re-arm anything for the new subject to start being scheduled.
arm() {
  local desired current tmp refusal
  # Before the write, not after: refusing only at registration would
  # still leave the other home's check overwritten and its trust stale.
  refusal=$(fm_check_arm_home_refusal "$STATE" "$FM_HOME") || {
    printf 'fm-nudge: %s\n' "$refusal" >&2
    return 1
  }
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-nudge.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: the subjects, the cadences, the jitter refusal, and
# the payloads all live in the script itself, so they arrive by self-update
# instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-nudge.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    # Written through a temp file in the same directory and moved into place, so
    # a watcher sweeping mid-write can never snapshot half a check and reject it
    # as unauthenticated.
    umask 077
    tmp=$(mktemp "$STATE/.fm-nudge-check.XXXXXX") || return 1
    printf '%s\n' "$desired" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || return 1
  # Retire the single-subject predecessor only once its replacement is armed and
  # registered, so a failure here never leaves a home with neither.
  rm -f -- "$LEGACY_CHECK" "$LEGACY_TRUST" 2>/dev/null || return 1
  [ ! -e "$LEGACY_CHECK" ] && [ ! -e "$LEGACY_TRUST" ]
}

STATE_PROBE_CONDITION=''
cleanup_state_probe() {
  rm -f -- "$1" "$2" 2>/dev/null || return 1
  [ ! -e "$1" ] && [ ! -e "$2" ]
}

probe_state_publishability() {
  local probe published status representative
  STATE_PROBE_CONDITION=''
  if [ ! -d "$STATE" ]; then
    STATE_PROBE_CONDITION='the state path is not a directory'
    return 1
  fi
  if [ -d "$REPORT" ]; then
    STATE_PROBE_CONDITION='the authoritative record path is a directory and cannot be atomically replaced'
    return 1
  fi
  probe=$(mktemp "$STATE/.$SUBJECT-nudge-health.XXXXXX" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
      STATE_PROBE_CONDITION='the temporary-state probe could not be executed'
      return 2
    fi
    STATE_PROBE_CONDITION='temporary state cannot be created in the state directory'
    return 1
  fi
  published="$probe.published"
  representative=$(render_record scheduled "$(( NOW + INTERVAL + JITTER_MIN ))" 0 0 0 '' '')
  status=$?
  if [ "$status" -ne 0 ]; then
    if ! cleanup_state_probe "$probe" "$published"; then
      STATE_PROBE_CONDITION='the representative content could not be rendered and its scratch state could not be cleaned up, so publishability cannot be determined'
      return 2
    fi
    STATE_PROBE_CONDITION='the representative content could not be rendered, so publishability cannot be determined'
    return 2
  fi
  printf '%s\n' "$representative" | dd of="$probe" bs=4096 2>/dev/null
  status=$?
  if [ "$status" -ne 0 ]; then
    if ! cleanup_state_probe "$probe" "$published"; then
      STATE_PROBE_CONDITION='the representative write failed and its scratch state could not be cleaned up, so publishability cannot be determined'
      return 2
    fi
    if [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
      STATE_PROBE_CONDITION='the representative-write probe could not be executed, so publishability cannot be determined'
      return 2
    fi
    STATE_PROBE_CONDITION='representative authoritative-record content cannot be written in the state directory'
    return 1
  fi
  mv -f -- "$probe" "$published"
  status=$?
  if [ "$status" -ne 0 ]; then
    if ! cleanup_state_probe "$probe" "$published"; then
      STATE_PROBE_CONDITION='the same-directory atomic rename failed and its scratch state could not be cleaned up, so publishability cannot be determined'
      return 2
    fi
    if [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
      STATE_PROBE_CONDITION='the same-directory rename probe could not be executed, so publishability cannot be determined'
      return 2
    fi
    STATE_PROBE_CONDITION='a same-directory atomic rename cannot complete in the state directory'
    return 1
  fi
  if ! cleanup_state_probe "$probe" "$published"; then
    STATE_PROBE_CONDITION='the representative publish completed but its scratch state could not be cleaned up, so publishability cannot be determined'
    return 2
  fi
  return 0
}

diagnose_unexecuted_work() {
  local kind=$1 elapsed=$2 last=${3:-0} probe_status
  probe_state_publishability
  probe_status=$?
  if [ "$probe_status" -eq 1 ]; then
    if [ "$kind" = overdue ]; then
      printf '%s: state persistence failure at %s because %s; the check ran but cannot persist its state, and the prior overdue target remains queued for retry\n' \
        "$CODE" "$STATE" "$STATE_PROBE_CONDITION"
    else
      printf '%s: state persistence failure at %s because %s; the check ran but cannot persist its first authoritative schedule\n' \
        "$CODE" "$STATE" "$STATE_PROBE_CONDITION"
    fi
    return 0
  fi
  if [ "$probe_status" -eq 2 ]; then
    printf '%s: state health indeterminate at %s because %s; the missing work could mean either a state publication failure or a supervision outage, and this reading asserts neither cause\n' \
      "$CODE" "$STATE" "$STATE_PROBE_CONDITION"
    return 0
  fi
  if [ "$kind" = missing ]; then
    printf '%s: supervision outage: the %s has been armed for %s minute(s) and has never published its authoritative schedule, so nothing is running this home'"'"'s checks (inspect the monitoring service for this home)\n' \
      "$CODE" "$SUBJECT_NUDGE_NAME" "$(( elapsed / 60 ))"
  elif [ "$last" -gt 0 ]; then
    printf '%s: supervision outage: the %s was due %s minute(s) ago and has not fired (it last fired %s); the schedule stands but nothing is executing it (inspect the monitoring service for this home)\n' \
      "$CODE" "$SUBJECT_SWEEP" "$(( elapsed / 60 ))" "$(epoch_utc "$last")"
  else
    printf '%s: supervision outage: the %s was due %s minute(s) ago and has never fired; the schedule stands but nothing is executing it (inspect the monitoring service for this home)\n' \
      "$CODE" "$SUBJECT_SWEEP" "$(( elapsed / 60 ))"
  fi
}

# The reading that is NOT this check's own claim about itself. It asks what the
# work produced: is there a next target at all, and has anything executed the
# one there is?
armed_diagnostic() {
  local shim_mtime shim_age overdue_by age
  # Asked first, and asked of every subject: one shim serves them all, so an
  # unarmed shim means nothing will run any of them. Reading the record first
  # would let a still-plausible schedule speak for a check that is not there -
  # a surface reporting health while nothing executes, which is the exact shape
  # this reading exists to refuse. It stays silent for at most one period, and
  # that silence is the whole defect.
  if ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf '%s: the %s is not armed on this home, so %s (fix: %s/fm-nudge.sh --arm)\n' \
      "$CODE" "$SUBJECT_NUDGE_NAME" "$SUBJECT_UNARMED_CONSEQUENCE" "$SCRIPT_DIR"
    return 0
  fi
  if read_record; then
    if [ "$RECORD_STATE" = refused ]; then
      age=$(( NOW - RECORD_RECORDED ))
      [ "$age" -ge 0 ] || age=0
      printf '%s: the %s scheduler has refused to create a next target for %s minute(s) because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_%s_JITTER_MIN=%s, FM_%s_JITTER_MAX=%s, FM_%s_INTERVAL=%s); set the jitter window to include an off-grid target minute\n' \
        "$CODE" "$SUBJECT_SWEEP" "$(( age / 60 ))" "$RECORD_ATTEMPTS" \
        "$CODE" "$RECORD_JITTER_MIN" "$CODE" "$RECORD_JITTER_MAX" "$CODE" "$RECORD_INTERVAL"
      return 0
    fi
    if [ "$RECORD_STATE" = persistence ]; then
      printf '%s: state persistence failure at %s because %s; repair that state path and run the check again\n' \
        "$CODE" "$RECORD_PERSISTENCE_PATH" "$RECORD_PERSISTENCE_CONDITION"
      return 0
    fi
    overdue_by=$(( NOW - RECORD_NEXT ))
    [ "$overdue_by" -ge "$OVERDUE" ] || return 0
    diagnose_unexecuted_work overdue "$overdue_by" "$RECORD_LAST"
    return 0
  fi
  if [ -e "$REPORT" ]; then
    printf '%s: state persistence failure at %s because the authoritative %s record is unreadable; repair that state path and run the check again\n' \
      "$CODE" "$REPORT" "$SUBJECT_RECORD_NOUN"
    return 0
  fi
  shim_mtime=$(path_mtime "$CHECK") || shim_mtime=$NOW
  case "${shim_mtime:-}" in ''|*[!0-9]*) shim_mtime=$NOW ;; esac
  shim_age=$(( NOW - shim_mtime ))
  [ "$shim_age" -ge "$OVERDUE" ] || return 0
  diagnose_unexecuted_work missing "$shim_age"
}

case "$MODE" in
  subjects)
    for subject in $ACTIVE_SUBJECTS; do
      subject_select "$subject" || exit 2
      printf '%s %s %s\n' "$SUBJECT" "$CODE" "$INTERVAL"
    done
    exit 0
    ;;
  draw)
    subject_select "$SELECTED" || exit 2
    drawn=0
    while [ "$drawn" -lt "$DRAW_COUNT" ]; do
      if ! target=$(draw_next_due "$NOW"); then
        printf 'fm-nudge: no %s target off the five-minute grid could be drawn in %s attempts; refusing to schedule one on it\n' \
          "$SUBJECT" "$DRAW_ATTEMPTS" >&2
        exit 1
      fi
      printf '%s\n' "$target"
      drawn=$(( drawn + 1 ))
    done
    exit 0
    ;;
  arm)
    arm || { printf 'fm-nudge: cannot arm the fleet nudges in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    for subject in $SUBJECTS; do
      subject_select "$subject" || exit 2
      printf 'subject: %s (%s, every %ss)\n' "$SUBJECT" "$CODE" "$INTERVAL"
    done
    exit 0
    ;;
  armed)
    for subject in $ACTIVE_SUBJECTS; do
      subject_select "$subject" || exit 2
      [ "$DISABLED" -eq 1 ] && continue
      armed_diagnostic
    done
    exit 0
    ;;
  status)
    for subject in $ACTIVE_SUBJECTS; do
      subject_select "$subject" || exit 2
      if [ -f "$REPORT" ]; then
        cat "$REPORT"
      else
        render_absent_report
      fi
    done
    exit 0
    ;;
esac

# detect and --force, subject by subject. One subject's outcome never suppresses
# another's: a persistence failure on one is reported and remembered in the exit
# status, and the next subject is still evaluated.
exit_status=0
for subject in $ACTIVE_SUBJECTS; do
  subject_select "$subject" || exit 2
  [ "$MODE" = detect ] && [ "$DISABLED" -eq 1 ] && continue

  if [ "$MODE" = detect ]; then
    if ! read_record; then
      schedule_transition
      case "$?" in
        0|3) continue ;;
        1) schedule_refusal_line; continue ;;
        *) state_persistence_line; exit_status=1; continue ;;
      esac
    fi
    if [ "$RECORD_STATE" != scheduled ]; then
      schedule_transition
      case "$?" in
        0|3) continue ;;
        1) schedule_refusal_line; continue ;;
        *) state_persistence_line; exit_status=1; continue ;;
      esac
    fi
    [ "$NOW" -ge "$RECORD_NEXT" ] || continue
  fi

  schedule_transition "$NOW"
  case "$?" in
    0|3) nudge_line ;;
    1) nudge_line; schedule_refusal_line ;;
    *) state_persistence_line; exit_status=1 ;;
  esac
done
exit "$exit_status"
