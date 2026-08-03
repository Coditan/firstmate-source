#!/usr/bin/env bash
# Report whether this home's Grossreinschiff cleanup sweep is due, and record a
# completed one.
#
# This script owns ONLY the cadence. What the sweep covers, how each item is
# tested, and what it may delete live in
# .agents/skills/grossreinschiff/SKILL.md; the measured incident behind each
# checklist item lives in docs/grossreinschiff.md.
#
# The sweep is due when the last recorded sweep predates the most recent
# Thursday 00:00 local. An absent record means never swept, which is due: a
# home that has never swept is the one most likely to have accumulated
# something, and it joins the Thursday rhythm after its first sweep. A home
# that ran no session on Thursday sweeps late at its next session start rather
# than skipping the week.
#
# The due line's window-open count says how far into the CURRENT window this
# session start falls. It is bounded to 0 through 6 by construction and does
# not measure how long the home has been dark: a home three weeks behind that
# wakes on a Thursday reads 0. The "last swept:" date on the same line is what
# shows how many weeks were missed.
#
# There is deliberately no scheduler here. The check is one file read and one
# date comparison, so bin/fm-bootstrap.sh runs it in the detect pass that
# already happens once per session start. An external timer would add a
# per-home install step that nothing verifies, so a home that never installed
# it would silently never sweep - the no-op-instruction defect the sweep itself
# exists to find. docs/grossreinschiff.md records the full comparison against a
# scheduled wake and a fleet-wide notice.
#
# Usage:
#   fm-grossreinschiff-due.sh           detect: print one GROSSREINSCHIFF line
#                                       when the sweep is due, print nothing
#                                       when it is not, and always exit 0
#   fm-grossreinschiff-due.sh --status  print due=, last-sweep=,
#                                       last-sweep-epoch=, and
#                                       window-open-days= whether or not the
#                                       sweep is due
#   fm-grossreinschiff-due.sh --record  record a COMPLETED sweep as of now
#   fm-grossreinschiff-due.sh --help
#
# State: FM_HOME/state/grossreinschiff.last-sweep holds one line,
# "<epoch> <YYYY-MM-DD>". Both forms are written at record time so no caller
# ever has to convert an epoch back to a date, which GNU date and BSD date
# spell differently. An absent, empty, or unparseable marker reads as never
# swept, so a corrupt record makes the sweep due rather than silently skipping
# it.
#
# Environment:
#   FM_GROSSREINSCHIFF_CLOCK overrides the current clock with the six fields
#     `date '+%s %u %H %M %S %F'` would print (tests only).
#   FM_GROSSREINSCHIFF_DISABLE=1 silences the DETECT mode only, so behavior
#     suites that compose bin/fm-bootstrap.sh do not have to seed a sweep
#     record to assert on bootstrap's other output. --status and --record are
#     unaffected, because bootstrap never calls them and they can pollute
#     nothing. tests/lib.sh exports this for the whole suite; the sweep's own
#     suite sets it back to 0.
#
# The week boundary is today's local midnight minus whole days, so a
# daylight-saving change inside the preceding week moves it by an hour twice a
# year. That is deliberate: an hour of drift cannot make a weekly sweep fire
# twice or skip a week.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/grossreinschiff.last-sweep"

# Thursday, in the %u numbering both GNU and BSD date use (1=Monday..7=Sunday).
SWEEP_DOW=4

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  ''|--status|--record) ;;
  *)
    printf 'fm-grossreinschiff-due: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--status|--record|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: %s [--status|--record|--help]\n' "$(basename "$0")" >&2
  exit 2
}

clock=${FM_GROSSREINSCHIFF_CLOCK:-$(date '+%s %u %H %M %S %F')}
IFS=' ' read -r NOW DOW HH MM SS TODAY <<EOF
$clock
EOF
for field in "${NOW:-}" "${DOW:-}" "${HH:-}" "${MM:-}" "${SS:-}"; do
  case "$field" in
    ''|*[!0-9]*)
      printf 'fm-grossreinschiff-due: unusable clock reading "%s"\n' "$clock" >&2
      exit 2
      ;;
  esac
done
[ -n "${TODAY:-}" ] || {
  printf 'fm-grossreinschiff-due: unusable clock reading "%s"\n' "$clock" >&2
  exit 2
}

# Most recent Thursday 00:00 local, as an epoch. 10# forces base ten so a
# zero-padded hour like 08 is not read as an invalid octal literal.
seconds_today=$(( 10#$HH * 3600 + 10#$MM * 60 + 10#$SS ))
midnight=$(( NOW - seconds_today ))
days_back=$(( (10#$DOW - SWEEP_DOW + 7) % 7 ))
window_open=$(( midnight - days_back * 86400 ))

last_epoch=0
last_date=never
if [ -f "$MARKER" ]; then
  recorded_epoch=
  recorded_date=
  IFS=' ' read -r recorded_epoch recorded_date < "$MARKER" || true
  case "${recorded_epoch:-}" in
    ''|*[!0-9]*) ;;
    *)
      last_epoch=$recorded_epoch
      last_date=${recorded_date:-unknown}
      ;;
  esac
fi

if [ "${1:-}" = "--record" ]; then
  mkdir -p "$STATE" 2>/dev/null || {
    printf 'fm-grossreinschiff-due: cannot create state directory %s\n' "$STATE" >&2
    exit 1
  }
  printf '%s %s\n' "$NOW" "$TODAY" > "$MARKER" || {
    printf 'fm-grossreinschiff-due: cannot record the sweep in %s\n' "$MARKER" >&2
    exit 1
  }
  printf 'recorded Grossreinschiff sweep on %s\n' "$TODAY"
  exit 0
fi

due=no
[ "$last_epoch" -lt "$window_open" ] && due=yes
window_open_days=$(( (NOW - window_open) / 86400 ))

if [ "${1:-}" = "--status" ]; then
  printf 'due=%s\n' "$due"
  printf 'last-sweep=%s\n' "$last_date"
  printf 'last-sweep-epoch=%s\n' "$last_epoch"
  printf 'window-open-days=%s\n' "$window_open_days"
  exit 0
fi

[ "${FM_GROSSREINSCHIFF_DISABLE:-0}" = 1 ] && exit 0
[ "$due" = yes ] || exit 0
printf 'GROSSREINSCHIFF: weekly fleet cleanup sweep is due (last swept: %s; this week'"'"'s window has been open %s day(s)) - load the grossreinschiff skill\n' \
  "$last_date" "$window_open_days"
exit 0
