#!/usr/bin/env bash
# Raise this home's fleet knowledge-file curation nudge on a 48-hour cadence.
#
# WHAT THIS IS FOR
# data/learnings.md and data/captain.md are per-home, captain-private and
# gitignored. Every vessel has one pair, no vessel can see another's, and until
# this script nothing anywhere re-measured them. AGENTS.md section 10 already
# said to prune rather than append; a rule with no mechanism is carried by
# memory, and memory did not carry it. Measured on this seat on 2026-08-17, when
# this was commissioned: data/learnings.md had reached 5,445 lines / 417 KB, and
# with data/captain.md the pair was 86% of the whole session-start digest -
# roughly 130k tokens read before any work, against a 300k context ceiling. A
# fresh session finished its startup read at about 360k, so that session's first
# context-ceiling wake fired on the startup read itself. Re-measured hours later
# while this script was written, a curation pass had already run and the pair was
# 171 KB, of which data/captain.md was 151 KB. Both readings are in
# docs/curation-nudge.md, because the second one is the point: a human sweep can
# clear the debt, and nothing scheduled that sweep or the next one. This script
# is the cadence that duty lacked.
#
# It measures, records, and raises one wake. It curates nothing, decides no
# vessel's split, and never touches another vessel's files.
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
# repository. tests/fm-curation-nudge.test.sh asserts that boundary by executing
# every mode with tripwires on every route off-machine.
#
# THE CADENCE, AND THE FIVE-MINUTE REFUSAL
# The period is 48 hours. Not daily: bin/fm-currency-round.sh already owns the
# daily slot, and a curation sweep at that rate is noise rather than a prompt.
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
# asks this check whether it is fine. It reads what the WORK produced: when the
# nudge last actually fired, and whether a next target exists and is still
# plausible. A home whose checks stopped running keeps a target that goes
# further and further past due, which is loud; a home that never produced a
# target at all is the `Trigger: n/a` shape, and is loud too.
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
#   fm-curation-nudge.sh            detect: stay silent on an ordinary sweep;
#                                   print the wake on an ordinary firing; print
#                                   the wake plus its diagnostic when successor
#                                   scheduling refuses. A failed atomic publish
#                                   prints its persistence diagnostic instead of
#                                   the wake, leaving the prior due event intact.
#                                   Exit 0 after ordinary sweeps, firings, and
#                                   persisted refusals; exit non-zero when state
#                                   cannot be persisted. The watcher captures
#                                   printed output regardless of that exit status,
#                                   so a persistence diagnostic still becomes a wake.
#   fm-curation-nudge.sh --force    fire now, ignoring the schedule
#   fm-curation-nudge.sh --status   print the schedule and this seat's own
#                                   readings; writes no state and does not create
#                                   the state directory
#   fm-curation-nudge.sh --draw [n] print n independently drawn next targets as
#                                   epoch seconds, one per line (default 1),
#                                   writing no state or state directory. This is
#                                   the scheduling
#                                   function itself, exposed so its refusal can
#                                   be asserted over many draws.
#   fm-curation-nudge.sh --arm      write and register this home's watcher check
#                                   shim (idempotent)
#   fm-curation-nudge.sh --armed    print one CURATION_NUDGE line when the nudge
#                                   is not armed, has never scheduled a target,
#                                   or has an overdue target. For an overdue
#                                   target it distinguishes state persistence,
#                                   supervision, and an indeterminate reading;
#                                   silent otherwise
#   fm-curation-nudge.sh --help
#
# State, all under FM_HOME/state:
#   curation-nudge.report     the single authoritative, human-readable and
#                             parseable record of the last firing, current
#                             scheduling outcome, cadence, and readings
#   curation-nudge.check.sh   the armed watcher shim (with .check-trust)
#
# Environment:
#   FM_CURATION_NUDGE_INTERVAL    cadence in seconds (default 172800, 48h)
#   FM_CURATION_NUDGE_JITTER_MIN  low end of the per-firing jitter (default 180)
#   FM_CURATION_NUDGE_JITTER_MAX  high end of the per-firing jitter (default 420)
#   FM_CURATION_NUDGE_OVERDUE     how far past its target a nudge may sit before
#                                 --armed calls the cadence stopped (default
#                                 7200). The watcher sweeps far more often than
#                                 that, so this is slack, not a second cadence.
#   FM_CURATION_NUDGE_NOW         override the current epoch (tests)
#   FM_CURATION_NUDGE_DISABLE=1   silence detect and --armed only, so suites
#                                 that compose bin/fm-bootstrap.sh need not arm
#                                 a nudge. --status, --draw, --force and --arm
#                                 are unaffected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

REPORT="$STATE/curation-nudge.report"
CHECK="$STATE/curation-nudge.check.sh"

INTERVAL=${FM_CURATION_NUDGE_INTERVAL:-172800}
JITTER_MIN=${FM_CURATION_NUDGE_JITTER_MIN:-180}
JITTER_MAX=${FM_CURATION_NUDGE_JITTER_MAX:-420}
OVERDUE=${FM_CURATION_NUDGE_OVERDUE:-7200}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=172800 ;; esac
case "$JITTER_MIN" in ''|*[!0-9]*) JITTER_MIN=180 ;; esac
case "$JITTER_MAX" in ''|*[!0-9]*) JITTER_MAX=420 ;; esac
case "$OVERDUE" in ''|*[!0-9]*) OVERDUE=7200 ;; esac
[ "$JITTER_MAX" -ge "$JITTER_MIN" ] || { JITTER_MIN=180; JITTER_MAX=420; }

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

MODE=detect
DRAW_COUNT=1
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --force) MODE=force ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  --draw)
    MODE=draw
    if [ "$#" -eq 2 ]; then
      DRAW_COUNT=$2
      case "$DRAW_COUNT" in
        ''|*[!0-9]*|0)
          printf 'fm-curation-nudge: --draw needs a positive count\n' >&2
          exit 2
          ;;
      esac
    fi
    ;;
  *)
    printf 'fm-curation-nudge: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--force|--status|--draw [n]|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
if [ "$MODE" = draw ]; then
  [ "$#" -le 2 ] || { printf 'usage: %s --draw [n]\n' "$(basename "$0")" >&2; exit 2; }
else
  [ "$#" -le 1 ] || {
    printf 'usage: %s [--force|--status|--draw [n]|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2
  }
fi

NOW=${FM_CURATION_NUDGE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

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

# The next firing target from a base epoch: base + the 48-hour period + fresh
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

# This seat's own knowledge files, and only this seat's. A home cannot read
# another vessel's data/, so every number here is stated as this vessel's own.
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
    refused) printf 'next: refused because all %s candidate minutes from FM_CURATION_NUDGE_JITTER_MIN=%s through FM_CURATION_NUDGE_JITTER_MAX=%s with FM_CURATION_NUDGE_INTERVAL=%s landed on the five-minute grid\n' "$DRAW_ATTEMPTS" "$JITTER_MIN" "$JITTER_MAX" "$INTERVAL" ;;
    persistence) printf 'next: scheduling state persistence failed at %s because %s\n' "$persistence_path" "$persistence_condition" ;;
  esac
  if [ "$last" -gt 0 ]; then
    printf 'last-fire: %s\n' "$(epoch_utc "$last")"
  else
    printf 'last-fire: never\n'
  fi
  printf 'cadence: every %ss, plus %s-%ss of fresh jitter drawn at each firing\n' \
    "$INTERVAL" "$JITTER_MIN" "$JITTER_MAX"
  printf 'reading: this vessel data/learnings.md %s\n' "$(file_reading "$DATA/learnings.md")"
  printf 'reading: this vessel data/captain.md %s\n' "$(file_reading "$DATA/captain.md")"
  printf 'note: both readings are THIS VESSEL'"'"'S OWN files. They are per-home and gitignored, so this seat cannot see another vessel'"'"'s and makes no claim about one.\n'
  printf 'note: the share of the session-start digest is not measured here; each vessel measures its own, because a second model of that digest would drift silently.\n'
  printf 'note: this nudge raises a wake and nothing else. The All-Ships notice is dispatched to a crewmate by firstmate, per AGENTS.md section 12.\n'
}

publish_record() {
  local state=$1 next=$2 last=$3 recorded=$4 surfaced=$5 persistence_path=$6 persistence_condition=$7 tmp
  PERSISTENCE_PATH=''
  PERSISTENCE_CONDITION=''
  [ ! -d "$REPORT" ] || {
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION='the authoritative curation record could not replace a directory at its state path'
    return 1
  }
  tmp=$(mktemp "$STATE/.curation-nudge-report.XXXXXX") || {
    PERSISTENCE_PATH=$STATE
    PERSISTENCE_CONDITION='temporary state for the authoritative curation record could not be created'
    return 1
  }
  render_record "$state" "$next" "$last" "$recorded" "$surfaced" "$persistence_path" "$persistence_condition" > "$tmp" || {
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$tmp
    PERSISTENCE_CONDITION='the authoritative curation record could not be written to temporary state'
    return 1
  }
  if ! mv -f -- "$tmp" "$REPORT"; then
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION='the authoritative curation record could not be atomically published'
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
  printf 'state: absent\n'
  printf 'next: none scheduled\n'
  printf 'last-fire: never\n'
  printf 'cadence: every %ss, plus %s-%ss of fresh jitter drawn at each firing\n' "$INTERVAL" "$JITTER_MIN" "$JITTER_MAX"
  printf 'reading: this vessel data/learnings.md %s\n' "$(file_reading "$DATA/learnings.md")"
  printf 'reading: this vessel data/captain.md %s\n' "$(file_reading "$DATA/captain.md")"
}

# The one line worth waking a supervisor for. It is a prompt to measure, never a
# claim about any vessel other than this one.
nudge_line() {
  printf 'CURATION_NUDGE: the fleet knowledge-file curation sweep is due (every %s hours). Dispatch a crewmate to send the All-Ships notice asking every vessel to measure its OWN data/learnings.md and data/captain.md - line count, byte size, and what share of its own session-start digest the pair is - and to decide for itself whether that share is worth what it costs. This vessel'"'"'s own reading: learnings.md %s; captain.md %s. Nothing is claimed about any other vessel. Full record: %s\n' \
    "$(( INTERVAL / 3600 ))" \
    "$(file_reading "$DATA/learnings.md")" \
    "$(file_reading "$DATA/captain.md")" \
    "$REPORT"
}

schedule_refusal_line() {
  printf 'CURATION_NUDGE: no next curation sweep was scheduled because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_CURATION_NUDGE_JITTER_MIN=%s, FM_CURATION_NUDGE_JITTER_MAX=%s, FM_CURATION_NUDGE_INTERVAL=%s); the draw attempt bound was exhausted, so set the jitter window to include an off-grid target minute\n' \
    "$DRAW_ATTEMPTS" "$JITTER_MIN" "$JITTER_MAX" "$INTERVAL"
}

state_persistence_line() {
  printf 'CURATION_NUDGE: state persistence failure at %s because %s; repair that state path and run the check again\n' \
    "$PERSISTENCE_PATH" "$PERSISTENCE_CONDITION"
}

# --- modes ------------------------------------------------------------------

case "$MODE" in
  draw|status) ;;
  armed)
    if { [ -e "$STATE" ] && [ ! -d "$STATE" ]; } \
      || { [ ! -e "$STATE" ] && [ ! -d "${STATE%/*}" ]; }; then
      printf 'CURATION_NUDGE: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' "$STATE"
      exit 1
    fi
    ;;
  *)
    if ! mkdir -p "$STATE" 2>/dev/null; then
      if [ "$MODE" = detect ]; then
        printf 'CURATION_NUDGE: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' "$STATE"
        exit 1
      fi
      printf 'fm-curation-nudge: cannot create state directory %s\n' "$STATE" >&2
      exit 1
    fi
    ;;
esac

# Write this home's watcher shim and bind it to its own bytes. Every location is
# baked in rather than inherited: the watcher runs a check from a private
# snapshot with its own environment, so a shim that guessed its home would nudge
# a different one. Idempotent - an already-correct, already-registered shim is
# left exactly as it is, so bootstrap can call this on every session.
arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-curation-nudge.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: the cadence, the jitter refusal, and the payload
# all live in the script itself, so they arrive by self-update instead of being
# frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-curation-nudge.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    # Written through a temp file in the same directory and moved into place, so
    # a watcher sweeping mid-write can never snapshot half a check and reject it
    # as unauthenticated.
    umask 077
    tmp=$(mktemp "$STATE/.fm-curation-nudge-check.XXXXXX") || return 1
    printf '%s\n' "$desired" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" curation-nudge >/dev/null || return 1
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
  probe=$(mktemp "$STATE/.curation-nudge-health.XXXXXX" 2>/dev/null)
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
      printf 'CURATION_NUDGE: state persistence failure at %s because %s; the check ran but cannot persist its state, and the prior overdue target remains queued for retry\n' \
        "$STATE" "$STATE_PROBE_CONDITION"
    else
      printf 'CURATION_NUDGE: state persistence failure at %s because %s; the check ran but cannot persist its first authoritative schedule\n' \
        "$STATE" "$STATE_PROBE_CONDITION"
    fi
    return 0
  fi
  if [ "$probe_status" -eq 2 ]; then
    printf 'CURATION_NUDGE: state health indeterminate at %s because %s; the missing work could mean either a state publication failure or a supervision outage, and this reading asserts neither cause\n' \
      "$STATE" "$STATE_PROBE_CONDITION"
    return 0
  fi
  if [ "$kind" = missing ]; then
    printf 'CURATION_NUDGE: supervision outage: the curation nudge has been armed for %s minute(s) and has never published its authoritative schedule, so nothing is running this home'"'"'s checks (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))"
  elif [ "$last" -gt 0 ]; then
    printf 'CURATION_NUDGE: supervision outage: the curation sweep was due %s minute(s) ago and has not fired (it last fired %s); the schedule stands but nothing is executing it (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))" "$(epoch_utc "$last")"
  else
    printf 'CURATION_NUDGE: supervision outage: the curation sweep was due %s minute(s) ago and has never fired; the schedule stands but nothing is executing it (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))"
  fi
}

# The reading that is NOT this check's own claim about itself. It asks what the
# work produced: is there a next target at all, and has anything executed the
# one there is?
armed_diagnostic() {
  local shim_mtime shim_age overdue_by age
  if read_record; then
    if [ "$RECORD_STATE" = refused ]; then
      age=$(( NOW - RECORD_RECORDED ))
      [ "$age" -ge 0 ] || age=0
      printf 'CURATION_NUDGE: the curation scheduler has refused to create a next sweep for %s minute(s) because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_CURATION_NUDGE_JITTER_MIN=%s, FM_CURATION_NUDGE_JITTER_MAX=%s, FM_CURATION_NUDGE_INTERVAL=%s); set the jitter window to include an off-grid target minute\n' \
        "$(( age / 60 ))" "$RECORD_ATTEMPTS" "$RECORD_JITTER_MIN" "$RECORD_JITTER_MAX" "$RECORD_INTERVAL"
      return 0
    fi
    if [ "$RECORD_STATE" = persistence ]; then
      printf 'CURATION_NUDGE: state persistence failure at %s because %s; repair that state path and run the check again\n' \
        "$RECORD_PERSISTENCE_PATH" "$RECORD_PERSISTENCE_CONDITION"
      return 0
    fi
    overdue_by=$(( NOW - RECORD_NEXT ))
    [ "$overdue_by" -ge "$OVERDUE" ] || return 0
    diagnose_unexecuted_work overdue "$overdue_by" "$RECORD_LAST"
    return 0
  fi
  if [ -e "$REPORT" ]; then
    printf 'CURATION_NUDGE: state persistence failure at %s because the authoritative curation record is unreadable; repair that state path and run the check again\n' "$REPORT"
    return 0
  fi
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'CURATION_NUDGE: the knowledge-file curation nudge is not armed on this home, so nothing will re-measure this vessel'"'"'s learnings and captain files between sessions (fix: %s/fm-curation-nudge.sh --arm)\n' "$SCRIPT_DIR"
    return 0
  fi
  shim_mtime=$(path_mtime "$CHECK") || shim_mtime=$NOW
  case "${shim_mtime:-}" in ''|*[!0-9]*) shim_mtime=$NOW ;; esac
  shim_age=$(( NOW - shim_mtime ))
  [ "$shim_age" -ge "$OVERDUE" ] || return 0
  diagnose_unexecuted_work missing "$shim_age"
}

case "$MODE" in
  draw)
    drawn=0
    while [ "$drawn" -lt "$DRAW_COUNT" ]; do
      if ! target=$(draw_next_due "$NOW"); then
        printf 'fm-curation-nudge: no target off the five-minute grid could be drawn in %s attempts; refusing to schedule one on it\n' \
          "$DRAW_ATTEMPTS" >&2
        exit 1
      fi
      printf '%s\n' "$target"
      drawn=$(( drawn + 1 ))
    done
    exit 0
    ;;
  arm)
    arm || { printf 'fm-curation-nudge: cannot arm the curation nudge in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0
    ;;
  armed)
    [ "${FM_CURATION_NUDGE_DISABLE:-0}" = 1 ] && exit 0
    armed_diagnostic
    exit 0
    ;;
  status)
    if [ -f "$REPORT" ]; then
      cat "$REPORT"
    else
      render_absent_report
    fi
    exit 0
    ;;
esac

[ "$MODE" = detect ] && [ "${FM_CURATION_NUDGE_DISABLE:-0}" = 1 ] && exit 0

if [ "$MODE" = detect ]; then
  if ! read_record; then
    schedule_transition
    transition_status=$?
    case "$transition_status" in
      0) exit 0 ;;
      1) schedule_refusal_line; exit 0 ;;
      3) exit 0 ;;
      *) state_persistence_line; exit 1 ;;
    esac
  fi
  if [ "$RECORD_STATE" != scheduled ]; then
    schedule_transition
    transition_status=$?
    case "$transition_status" in
      0|3) exit 0 ;;
      1) schedule_refusal_line; exit 0 ;;
      *) state_persistence_line; exit 1 ;;
    esac
  fi
  [ "$NOW" -ge "$RECORD_NEXT" ] || exit 0
fi

firing_epoch=$NOW
schedule_transition "$firing_epoch"
transition_status=$?
case "$transition_status" in
  0) nudge_line; exit 0 ;;
  1) nudge_line; schedule_refusal_line; exit 0 ;;
  3) nudge_line; exit 0 ;;
  *) state_persistence_line; exit 1 ;;
esac
