#!/usr/bin/env bash
# Record what the forge's own status page says, and wake firstmate only when the
# reading is new.
#
# WHAT THIS IS FOR
# On 2026-08-17 between 14:58 and 15:01 UTC GitHub reported API requests
# degraded, webhooks degraded, Actions degraded, roughly 20% error rates on web
# and API traffic and roughly 50% on archive and raw content downloads. On this
# seat that hour: two approved merges could not be completed for over ten
# minutes, and three live workers had to be warned BY HAND not to read CI
# failures as their own defects. That hand-warning is the work this check
# exists to make unnecessary - nothing was watching the forge, so a supervisor
# noticed the outage only by walking into it.
#
# WHAT IT DOES, AND THE ONE THING IT DELIBERATELY DOES NOT DO
# It observes, it appends, and it wakes. It does not judge.
#   1. On a due sweep it reads the status page once.
#   2. It renders that reading and compares it to the LAST ENTRY IN THE LOG.
#      An unchanged reading appends nothing and wakes nobody: silence comes
#      from there being no new entry, not from a severity test in this script.
#   3. A new reading is appended to state/forge-status.log - append-only, one
#      block per recorded observation, never rewritten - and printed as one
#      wake line.
#   4. Firstmate reads that entry, decides whether it matters to THIS fleet,
#      and decides whether to raise or lower the cadence with --cadence.
# Step 4 is not this script's to take, and the reason is concrete: no field on
# that status page encodes what a component costs US. Actions degraded is
# severe here because every pipeline runs through it, while a Pages incident may
# be irrelevant to every vessel. A checker that classified severity would be
# guessing at that difference on a schedule; firstmate knows it.
#
# Informing the fleet is likewise firstmate's act. Nothing here writes to
# Bridge: the boundary rules there are content-sensitive, an unattended
# publisher is unauditable, and AGENTS.md section 1 forbids a timer standing in
# for firstmate. The wake is durable, so an absent firstmate does not lose a
# new reading.
#
# CANNOT REACH IS NOT ALL CLEAR
# A watch that goes quiet when the network fails is worse than no watch,
# because silence reads as good news exactly when it is not. A reading that
# cannot be taken - no curl, no jq, no working bounded sink (`head` or `dd`), no
# answer, a non-2xx answer, a body that reaches the configured bound, or an
# unparseable body - is recorded as an UNMEASURABLE entry naming the condition,
# and its wake says so in those words.
# Unmeasurable is never rendered as clear and never omitted. It is fingerprinted
# like any other reading, so a network that stays down appends once rather than
# every sweep, and the last entry in the log keeps saying unmeasurable for as
# long as it is true.
# The deliberate narrow exception is a non-HTTP URL such as a local file://
# status document configured through FM_FORGE_STATUS_URL: curl reports status
# 000 because that transport cannot carry an HTTP status, so a successful fetch
# may still be read. For http:// and https:// URLs, 000 is non-2xx and therefore
# unmeasurable like every other non-2xx answer.
#
# THE CADENCE IS SETTABLE, AND ITS CURRENT SETTING IS READABLE
#   raised   every 300s, for while something is being watched.
#   relaxed  every 7200s plus 180-420s of fresh jitter, and the target minute is
#            never a multiple of five (the default).
# The off-grid refusal is the same one bin/fm-curation-nudge.sh carries and
# exists for the same reason: cron defaults, systemd timers, monitoring pollers
# and this fleet's own watcher sweep all cluster on five-minute boundaries, so a
# fleet-wide relaxed fire landing there stacks on everything the machines
# already do. It governs the relaxed cadence only. A 300s period is on the grid
# by definition, and skipping observations to dodge it during an incident would
# trade the thing being watched for the tidiness of the schedule.
# --status and --cadence both print which cadence is in force, so a reader can
# always tell.
# The observation read/append/schedule transaction and cadence changes share a
# home-scoped non-blocking lock. A detect or force observation that finds
# another writer exits quietly, while read-only modes neither acquire the lock
# nor create its state.
#
# The cadence is the target, not the observation instant. The watcher sees a due
# target on its next state/*.check.sh sweep, so an observation lands at the
# target plus however far that sweep has to travel; that sweep's own period
# belongs to bin/fm-watch.sh and is not re-decided here. At the default sweep
# period a raised watch therefore observes every 300 to 600 seconds rather than
# exactly every 300. This script owns its target, states it, and claims nothing
# about the sweep.
#
# THE SEAM
# This is not a second timer. bin/fm-curation-nudge.sh established the pattern:
# --arm writes state/forge-status.check.sh, the locked bootstrap step arms it,
# and the watcher runs it on its ordinary state/*.check.sh sweep while the
# script self-gates to its own schedule. Two near-identical units on one host is
# a measured trap on this machine - a timer reported loaded, enabled and active
# while it had last fired nine days earlier - so the seam is shared rather than
# copied.
#
# THE HEALTH READING
# --armed never asks this check whether it is fine. It reads what the WORK
# produced: whether a next target exists at all, and whether anything has
# executed the one there is. A home whose checks stopped keeps a target that
# goes further and further past due; a home that never produced one is the
# no-next-trigger shape. Before concluding that supervision stopped, it writes
# and atomically renames representative content between scratch paths in the
# state directory, because a failed publication cannot record its own failure.
#
# Usage:
#   fm-forge-status.sh              detect: silent on a sweep that is not due;
#                                   on a due sweep observe once, append and
#                                   print a wake line only when the reading is
#                                   new, then schedule the next observation.
#                                   Exit 0 for sweeps, observations and
#                                   persisted refusals; non-zero when state
#                                   cannot be persisted. The watcher captures
#                                   printed output regardless of exit status,
#                                   so a persistence diagnostic still wakes.
#   fm-forge-status.sh --force      observe now, ignoring the schedule. Still
#                                   appends and wakes only on a new reading.
#   fm-forge-status.sh --status     print the schedule, the cadence in force and
#                                   the last reading; writes no state and does
#                                   not create the state directory
#   fm-forge-status.sh --cadence    print the cadence in force and its period
#   fm-forge-status.sh --cadence raised|relaxed
#                                   set the cadence and schedule the next
#                                   observation from now
#   fm-forge-status.sh --log [n]    print the last n log entries (default 1),
#                                   newest last; writes no state
#   fm-forge-status.sh --draw [n]   print n independently drawn relaxed targets
#                                   as epoch seconds, one per line (default 1).
#                                   The scheduling function itself, exposed so
#                                   its off-grid refusal can be asserted over
#                                   many draws. Writes no state.
#   fm-forge-status.sh --arm        write and register this home's watcher check
#                                   shim (idempotent)
#   fm-forge-status.sh --armed      print one FORGE_STATUS line when the watch is
#                                   not armed, has never scheduled an
#                                   observation, or has an overdue target;
#                                   silent otherwise
#   fm-forge-status.sh --help
#
# State, all under FM_HOME/state:
#   forge-status.log          append-only readings; the last entry is the
#                             authority on what was last recorded, so a failed
#                             report publish cannot duplicate an entry
#   forge-status.report       schedule, cadence in force, and last observation
#   forge-status.check.sh     the armed watcher shim (with .check-trust)
#
# Environment:
#   FM_FORGE_STATUS_URL           status document (default
#                                 https://www.githubstatus.com/api/v2/summary.json)
#   FM_FORGE_STATUS_INTERVAL      relaxed cadence in seconds (default 7200)
#   FM_FORGE_STATUS_RAISED_INTERVAL raised cadence in seconds (default 300)
#   FM_FORGE_STATUS_JITTER_MIN    low end of the relaxed jitter (default 180)
#   FM_FORGE_STATUS_JITTER_MAX    high end of the relaxed jitter (default 420)
#   FM_FORGE_STATUS_TIMEOUT       seconds allowed for the fetch (default 10),
#                                 clamped to 15 so it stays inside the watcher's
#                                 30-second per-check budget
#   FM_FORGE_STATUS_MAX_BYTES     largest accepted response body in bytes
#                                 (default 1000000, clamped maximum 5000000)
#   FM_FORGE_STATUS_OVERDUE       how far past a relaxed target the watch may
#                                 sit before --armed calls the cadence stopped
#                                 (default 7200)
#   FM_FORGE_STATUS_OVERDUE_RAISED the same slack for the raised cadence
#                                 (default 1800)
#   FM_FORGE_STATUS_LOCK_STALE_AFTER requested minimum lock recovery age
#                                 (default 60); the effective bound is never
#                                 below the bounded fetch timeout plus 60s or
#                                 60s total and is recorded in
#                                 forge-status.report. The clamped body-size
#                                 bound, bounded sink, and clamped timeout keep
#                                 fetching, parsing, hashing, appending, and
#                                 publication inside that recovery margin.
#   FM_FORGE_STATUS_NOW           override the current epoch (tests)
#   FM_FORGE_STATUS_DISABLE=1     silence detect and --armed only, so suites that
#                                 compose bin/fm-bootstrap.sh neither reach the
#                                 network nor see this home's diagnostic.
#                                 --status, --cadence, --log, --draw, --force and
#                                 --arm are unaffected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

LOG="$STATE/forge-status.log"
REPORT="$STATE/forge-status.report"
CHECK="$STATE/forge-status.check.sh"
TRANSACTION_LOCK="$STATE/forge-status.transaction.lock.d"

URL=${FM_FORGE_STATUS_URL:-https://www.githubstatus.com/api/v2/summary.json}
INTERVAL=${FM_FORGE_STATUS_INTERVAL:-7200}
RAISED_INTERVAL=${FM_FORGE_STATUS_RAISED_INTERVAL:-300}
JITTER_MIN=${FM_FORGE_STATUS_JITTER_MIN:-180}
JITTER_MAX=${FM_FORGE_STATUS_JITTER_MAX:-420}
TIMEOUT_DEFAULT=10
TIMEOUT_CEILING=15
TIMEOUT_CONFIGURED=${FM_FORGE_STATUS_TIMEOUT:-}
MAX_BYTES_DEFAULT=1000000
MAX_BYTES_CEILING=5000000
MAX_BYTES_CONFIGURED=${FM_FORGE_STATUS_MAX_BYTES:-}
OVERDUE=${FM_FORGE_STATUS_OVERDUE:-7200}
OVERDUE_RAISED=${FM_FORGE_STATUS_OVERDUE_RAISED:-1800}
LOCK_STALE_CONFIGURED=${FM_FORGE_STATUS_LOCK_STALE_AFTER:-60}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=7200 ;; esac
case "$RAISED_INTERVAL" in ''|*[!0-9]*|0) RAISED_INTERVAL=300 ;; esac
case "$JITTER_MIN" in ''|*[!0-9]*) JITTER_MIN=180 ;; esac
case "$JITTER_MAX" in ''|*[!0-9]*) JITTER_MAX=420 ;; esac
case "$TIMEOUT_CONFIGURED" in
  ''|*[!0-9]*|0|????????*) TIMEOUT=$TIMEOUT_DEFAULT ;;
  *)
    TIMEOUT=$TIMEOUT_CONFIGURED
    [ "$TIMEOUT" -le "$TIMEOUT_CEILING" ] || TIMEOUT=$TIMEOUT_CEILING
    ;;
esac
case "$MAX_BYTES_CONFIGURED" in
  ''|*[!0-9]*|0|????????*) MAX_BYTES=$MAX_BYTES_DEFAULT ;;
  *)
    MAX_BYTES=$MAX_BYTES_CONFIGURED
    [ "$MAX_BYTES" -le "$MAX_BYTES_CEILING" ] || MAX_BYTES=$MAX_BYTES_CEILING
    ;;
esac
case "$OVERDUE" in ''|*[!0-9]*) OVERDUE=7200 ;; esac
case "$OVERDUE_RAISED" in ''|*[!0-9]*) OVERDUE_RAISED=1800 ;; esac
case "$LOCK_STALE_CONFIGURED" in ''|*[!0-9]*) LOCK_STALE_CONFIGURED=60 ;; esac
[ "$JITTER_MAX" -ge "$JITTER_MIN" ] || { JITTER_MIN=180; JITTER_MAX=420; }
LOCK_STALE_FLOOR=$(( TIMEOUT + 60 ))
[ "$LOCK_STALE_FLOOR" -ge 60 ] || LOCK_STALE_FLOOR=60
LOCK_STALE_AFTER=$LOCK_STALE_CONFIGURED
[ "$LOCK_STALE_AFTER" -ge "$LOCK_STALE_FLOOR" ] || LOCK_STALE_AFTER=$LOCK_STALE_FLOOR

# The bound on re-draws, and the reason for it, are bin/fm-curation-nudge.sh's:
# the jitter window spans five consecutive minutes, so at most one candidate
# minute in five is on the grid. Exhausting sixty-four consecutive draws means
# the window was narrowed onto the grid, and the caller must be told rather than
# handed the target the refusal exists to prevent.
DRAW_ATTEMPTS=64

# How much of an incident update body a log entry keeps, and how much of it the
# one-line wake carries. The entry keeps enough to judge from; the wake keeps
# enough to decide whether to open the entry.
BODY_ENTRY_MAX=600
BODY_WAKE_MAX=200
# How many non-operational components a rendered reading names before it counts
# the rest. A whole-platform incident lists dozens, and a line nobody can read
# is a line nobody reads.
COMPONENT_LIST_MAX=8

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=detect
DRAW_COUNT=1
LOG_COUNT=1
CADENCE_ARG=''
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --force) MODE=force ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  --cadence)
    MODE=cadence
    if [ "$#" -eq 2 ]; then
      CADENCE_ARG=$2
      case "$CADENCE_ARG" in
        raised|relaxed) ;;
        *)
          printf 'fm-forge-status: --cadence takes raised or relaxed\n' >&2
          exit 2
          ;;
      esac
    fi
    ;;
  --log)
    MODE=log
    if [ "$#" -eq 2 ]; then
      LOG_COUNT=$2
      case "$LOG_COUNT" in
        ''|*[!0-9]*|0)
          printf 'fm-forge-status: --log needs a positive count\n' >&2
          exit 2
          ;;
      esac
    fi
    ;;
  --draw)
    MODE=draw
    if [ "$#" -eq 2 ]; then
      DRAW_COUNT=$2
      case "$DRAW_COUNT" in
        ''|*[!0-9]*|0)
          printf 'fm-forge-status: --draw needs a positive count\n' >&2
          exit 2
          ;;
      esac
    fi
    ;;
  *)
    printf 'fm-forge-status: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--force|--status|--cadence [raised|relaxed]|--log [n]|--draw [n]|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
case "$MODE" in
  cadence|log|draw)
    [ "$#" -le 2 ] || { printf 'usage: %s %s [value]\n' "$(basename "$0")" "--$MODE" >&2; exit 2; }
    ;;
  *)
    [ "$#" -le 1 ] || {
      printf 'usage: %s [--force|--status|--cadence [raised|relaxed]|--log [n]|--draw [n]|--arm|--armed|--help]\n' "$(basename "$0")" >&2
      exit 2
    }
    ;;
esac

NOW=${FM_FORGE_STATUS_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

# The same two-line portability shim bin/fm-curation-nudge.sh carries: BSD stat
# and GNU stat spell mtime differently.
path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

epoch_utc() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# --- the scheduling function ------------------------------------------------

minute_of() {  # <epoch>
  printf '%s' "$(( ( $1 / 60 ) % 60 ))"
}

on_five_minute_grid() {  # <epoch>
  [ "$(( ( ( $1 / 60 ) % 60 ) % 5 ))" -eq 0 ]
}

# The next relaxed target from a base epoch: base + period + fresh jitter,
# REFUSING any target whose minute is a multiple of five and drawing again.
# Fails rather than returning an on-grid target.
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

cadence_overdue_slack() {  # <cadence>
  if [ "$1" = raised ]; then printf '%s' "$OVERDUE_RAISED"; else printf '%s' "$OVERDUE"; fi
}

cadence_line() {  # <cadence>
  if [ "$1" = raised ]; then
    printf 'raised: every %ss, on the grid deliberately, for while something is being watched' "$RAISED_INTERVAL"
  else
    printf 'relaxed: every %ss plus %s-%ss of fresh jitter, target minute never a multiple of five' \
      "$INTERVAL" "$JITTER_MIN" "$JITTER_MAX"
  fi
}

# --- the reading ------------------------------------------------------------

READING_KIND=''
READING_HTTP=''
READING_FINGERPRINT=''
READING_INDICATOR=''
READING_DESCRIPTION=''
READING_COMPONENTS=''
READING_INCIDENTS=''
READING_UPDATE=''
READING_CONDITION=''

# A stable digest of the canonical reading. sha is preferred; cksum is the
# floor, because a seat with neither would otherwise silently compare full
# texts of different lengths and call every reading new.
digest_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    cksum | awk '{ print "cksum-" $1 "-" $2 }'
  fi
}

set_unmeasurable() {  # <http> <condition>
  READING_KIND=unmeasurable
  READING_HTTP=$1
  READING_CONDITION=$2
  READING_INDICATOR='unmeasurable'
  READING_DESCRIPTION='the status page could not be read'
  READING_COMPONENTS=''
  READING_INCIDENTS=''
  READING_UPDATE=''
  # The condition is part of the fingerprint, so a changed failure mode is a new
  # reading while an unchanged one stays quiet.
  READING_FINGERPRINT=$(printf 'unmeasurable\n%s\n%s\n' "$1" "$2" | digest_of_stdin)
}

bounded_sink() {
  case "$1" in
    head) head -c "$MAX_BYTES" ;;
    dd) dd bs=1 count="$MAX_BYTES" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# One bounded fetch, then a strict read of the document. Every route out of the
# happy path lands on set_unmeasurable with the concrete condition, and none of
# them lands on "operational".
observe() {
  local body body_bytes code headers pipeline_status sink sink_status status canonical jq_indicator scheme
  READING_UPDATE=''
  command -v curl >/dev/null 2>&1 \
    || { set_unmeasurable '-' 'curl is not installed on this seat, so the status page cannot be read at all'; return 0; }
  command -v jq >/dev/null 2>&1 \
    || { set_unmeasurable '-' 'jq is not installed on this seat, so a fetched status document cannot be read'; return 0; }
  if command -v head >/dev/null 2>&1 && head -c 0 </dev/null >/dev/null 2>&1; then
    sink='head'
  elif command -v dd >/dev/null 2>&1 && dd if=/dev/null of=/dev/null bs=1 count=0 2>/dev/null; then
    sink='dd'
  else
    set_unmeasurable '-' 'neither a working head nor dd is available on this seat, so the status response cannot be written through a bounded sink'
    return 0
  fi

  body=$(mktemp "${TMPDIR:-/tmp}/fm-forge-status.XXXXXX" 2>/dev/null) \
    || { set_unmeasurable '-' 'temporary space for the fetched status document could not be created'; return 0; }
  headers=$(mktemp "${TMPDIR:-/tmp}/fm-forge-status-headers.XXXXXX" 2>/dev/null) \
    || { rm -f -- "$body"; set_unmeasurable '-' 'temporary space for the status response headers could not be created'; return 0; }
  curl -m "$TIMEOUT" -s --max-filesize "$MAX_BYTES" -D "$headers" -o - \
    -H 'Accept: application/json' "$URL" 2>/dev/null \
    | bounded_sink "$sink" > "$body"
  pipeline_status=("${PIPESTATUS[@]}")
  status=${pipeline_status[0]}
  sink_status=${pipeline_status[1]}
  body_bytes=$(wc -c < "$body" 2>/dev/null | tr -d '[:space:]')
  case "$body_bytes" in
    ''|*[!0-9]*)
      rm -f -- "$body" "$headers"
      set_unmeasurable '-' "the response size from $URL could not be measured before parsing"
      return 0
      ;;
  esac
  if [ "$body_bytes" -ge "$MAX_BYTES" ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable '-' "the status page at $URL reached the effective ${MAX_BYTES}-byte response limit"
    return 0
  fi
  if [ "$sink_status" -ne 0 ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable '-' "the $sink bounded sink could not write the response from $URL"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    rm -f -- "$body" "$headers"
    if [ "$status" -eq 63 ]; then
      set_unmeasurable '-' "the status page at $URL exceeded the effective ${MAX_BYTES}-byte response limit"
      return 0
    fi
    set_unmeasurable '-' "the status page at $URL could not be read (fetch exit $status, bounded at ${TIMEOUT}s)"
    return 0
  fi
  code=$(awk '/^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { code=$2 } END { print code }' "$headers" 2>/dev/null)
  [ -n "$code" ] || code=000
  if [ "$body_bytes" -gt "$MAX_BYTES" ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable "$code" "the status page at $URL returned ${body_bytes} bytes, exceeding the effective ${MAX_BYTES}-byte response limit"
    return 0
  fi
  scheme=${URL%%:*}
  scheme=$(printf '%s' "$scheme" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$code:$scheme" in
    2[0-9][0-9]:*) ;;
    000:http|000:https)
      rm -f -- "$body" "$headers"
      set_unmeasurable "$code" "the status page at $URL answered HTTP $code instead of a status document"
      return 0
      ;;
    000:*) ;;
    *)
      rm -f -- "$body" "$headers"
      set_unmeasurable "$code" "the status page at $URL answered HTTP $code instead of a status document"
      return 0
      ;;
  esac
  if [ ! -s "$body" ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable "$code" "the status page at $URL answered with an empty body"
    return 0
  fi
  jq_indicator=$(jq -r '.status.indicator // empty' "$body" 2>/dev/null)
  if [ -z "$jq_indicator" ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable "$code" "the answer from $URL is not a readable status document (no overall status indicator in it)"
    return 0
  fi

  # The canonical reading. Deliberately carries NO timestamps: a status page
  # restamps its own updated_at on every publish, and a fingerprint that
  # included one would call every single sweep a new reading, which is the
  # noise this design exists to avoid.
  canonical=$(jq -r '
      def flat: gsub("[[:space:]]+"; " ");
      [ "indicator=" + ((.status.indicator // "?") | flat),
        "description=" + ((.status.description // "?") | flat) ]
      + ( [ .components[]? | select(.group != true)
            | "component " + ((.name // "?") | flat) + "=" + ((.status // "?") | flat) ] | sort )
      + ( [ .incidents[]?
            | "incident " + ((.id // "?") | flat) + "=" + ((.status // "?") | flat)
              + "/" + ((.impact // "?") | flat)
              + "/" + (((.incident_updates[0].id) // "-") | flat) ] | sort )
      + ( [ .scheduled_maintenances[]?
            | "maintenance " + ((.id // "?") | flat) + "=" + ((.status // "?") | flat) ] | sort )
      | .[]' "$body" 2>/dev/null)
  if [ -z "$canonical" ]; then
    rm -f -- "$body" "$headers"
    set_unmeasurable "$code" "the answer from $URL could not be reduced to a comparable reading"
    return 0
  fi

  READING_KIND=measured
  READING_HTTP=$code
  READING_CONDITION=''
  READING_FINGERPRINT=$(printf '%s\n' "$canonical" | digest_of_stdin)
  # Every rendered value is flattened to a single line. The text comes from a
  # remote document, and the entry log is line-structured: a component or
  # incident whose name carried a newline would otherwise split its own entry
  # and could forge a fingerprint line, which is the field deduplication reads.
  READING_INDICATOR=$(printf '%s' "$jq_indicator" | tr '\n\r\t' '   ')
  READING_DESCRIPTION=$(jq -r '(.status.description // "no description") | gsub("[[:space:]]+"; " ")' "$body" 2>/dev/null)
  READING_COMPONENTS=$(jq -r --argjson max "$COMPONENT_LIST_MAX" '
      def flat: gsub("[[:space:]]+"; " ");
      [ .components[]? | select(.group != true) | select(.status != "operational")
        | ((.name // "?") | flat) + "=" + ((.status // "?") | flat) ] as $bad
      | if ($bad | length) == 0 then "all operational"
        elif ($bad | length) > $max
        then (($bad[0:$max]) | join("; ")) + "; and " + (($bad | length) - $max | tostring) + " more"
        else ($bad | join("; ")) end' "$body" 2>/dev/null)
  READING_INCIDENTS=$(jq -r '
      def flat: gsub("[[:space:]]+"; " ");
      [ .incidents[]? | ((.name // "?") | flat) + " (" + ((.status // "?") | flat) + ", "
        + ((.impact // "?") | flat) + " impact)"
        + (if (.shortlink // "") == "" then "" else " " + (.shortlink | flat) end) ] as $open
      | if ($open | length) == 0 then "none open" else ($open | join(" | ")) end' "$body" 2>/dev/null)
  READING_UPDATE=$(jq -r --argjson max "$BODY_ENTRY_MAX" '
      [ .incidents[]? | .incident_updates[0]?.body // empty ] as $u
      | if ($u | length) == 0 then ""
        else ($u[0] | gsub("[[:space:]]+"; " ") | .[0:$max]) end' "$body" 2>/dev/null)
  rm -f -- "$body" "$headers"
  [ -n "$READING_COMPONENTS" ] || READING_COMPONENTS='unreadable component list'
  [ -n "$READING_INCIDENTS" ] || READING_INCIDENTS='unreadable incident list'
}

# --- the log ----------------------------------------------------------------

# The last entry in the append-only log is the authority on what was last
# recorded. Deduplicating against IT rather than against the report means a
# report publish that fails after an append cannot cause the same reading to be
# appended twice on the next sweep.
last_logged_fingerprint() {
  [ -f "$LOG" ] || return 0
  sed -n 's/^fingerprint: //p' "$LOG" 2>/dev/null | tail -n 1
}

render_entry() {  # <cadence>
  printf 'entry: %s\n' "$(epoch_utc "$NOW")"
  printf 'epoch: %s\n' "$NOW"
  printf 'cadence: %s\n' "$1"
  printf 'source: %s\n' "$URL"
  printf 'http: %s\n' "${READING_HTTP:--}"
  printf 'reading: %s\n' "$READING_KIND"
  if [ "$READING_KIND" = measured ]; then
    printf 'indicator: %s (%s)\n' "$READING_INDICATOR" "$READING_DESCRIPTION"
    printf 'components: %s\n' "$READING_COMPONENTS"
    printf 'incidents: %s\n' "$READING_INCIDENTS"
    [ -z "$READING_UPDATE" ] || printf 'incident-update: %s\n' "$READING_UPDATE"
  else
    printf 'condition: %s\n' "$READING_CONDITION"
    printf 'note: unmeasurable is NOT clear. Nothing here says the forge is healthy; it says this seat could not read whether it is.\n'
  fi
  printf 'fingerprint: %s\n' "$READING_FINGERPRINT"
}

# One append per new reading, ending in the blank line that separates entries.
# The blank line is written here rather than by render_entry because command
# substitution strips trailing newlines, and an entry log with no separators is
# one entry as far as any reader is concerned.
append_entry() {  # <cadence>
  local entry
  entry=$(render_entry "$1") || return 1
  printf '%s\n\n' "$entry" >> "$LOG" || return 1
}

# --- the report -------------------------------------------------------------

RECORD_STATE=''
RECORD_CADENCE=relaxed
RECORD_NEXT=0
RECORD_OBSERVED=0
RECORD_ENTRY=0
RECORD_RECORDED=0
RECORD_SURFACED=0
RECORD_INTERVAL=0
RECORD_RAISED=0
RECORD_JITTER_MIN=0
RECORD_JITTER_MAX=0
RECORD_ATTEMPTS=0
PERSISTENCE_PATH=''
PERSISTENCE_CONDITION=''

read_record() {
  local key value
  RECORD_STATE=''
  RECORD_CADENCE=relaxed
  RECORD_NEXT=0
  RECORD_OBSERVED=0
  RECORD_ENTRY=0
  RECORD_RECORDED=0
  RECORD_SURFACED=0
  RECORD_INTERVAL=0
  RECORD_RAISED=0
  RECORD_JITTER_MIN=0
  RECORD_JITTER_MAX=0
  RECORD_ATTEMPTS=0
  [ -f "$REPORT" ] || return 1
  while IFS=': ' read -r key value; do
    case "$key" in
      state) RECORD_STATE=$value ;;
      cadence) RECORD_CADENCE=$value ;;
      next-epoch) RECORD_NEXT=$value ;;
      last-observation-epoch) RECORD_OBSERVED=$value ;;
      last-entry-epoch) RECORD_ENTRY=$value ;;
      refusal-recorded-epoch) RECORD_RECORDED=$value ;;
      refusal-surfaced) RECORD_SURFACED=$value ;;
      relaxed-interval-seconds) RECORD_INTERVAL=$value ;;
      raised-interval-seconds) RECORD_RAISED=$value ;;
      jitter-min-seconds) RECORD_JITTER_MIN=$value ;;
      jitter-max-seconds) RECORD_JITTER_MAX=$value ;;
      draw-attempts) RECORD_ATTEMPTS=$value ;;
    esac
  done < "$REPORT"
  case "$RECORD_OBSERVED:$RECORD_ENTRY:$RECORD_INTERVAL:$RECORD_RAISED:$RECORD_ATTEMPTS" in
    *[!0-9:]*) return 1 ;;
  esac
  case "$RECORD_CADENCE" in raised|relaxed) ;; *) return 1 ;; esac
  [ "$RECORD_INTERVAL" -gt 0 ] && [ "$RECORD_ATTEMPTS" -gt 0 ] || return 1
  case "$RECORD_STATE" in
    scheduled)
      case "$RECORD_NEXT" in ''|*[!0-9]*|0) return 1 ;; esac
      ;;
    refused)
      case "$RECORD_RECORDED:$RECORD_SURFACED" in *[!0-9:]*) return 1 ;; esac
      [ "$RECORD_RECORDED" -gt 0 ] || return 1
      ;;
    *) return 1 ;;
  esac
}

render_record() {  # <state> <cadence> <next> <observed> <entry> <recorded> <surfaced>
  local state=$1 cadence=$2 next=$3 observed=$4 entry=$5 recorded=$6 surfaced=$7
  printf 'state: %s\n' "$state"
  printf 'cadence: %s\n' "$cadence"
  printf 'next-epoch: %s\n' "$next"
  printf 'last-observation-epoch: %s\n' "$observed"
  printf 'last-entry-epoch: %s\n' "$entry"
  printf 'refusal-recorded-epoch: %s\n' "$recorded"
  printf 'refusal-surfaced: %s\n' "$surfaced"
  printf 'relaxed-interval-seconds: %s\n' "$INTERVAL"
  printf 'raised-interval-seconds: %s\n' "$RAISED_INTERVAL"
  printf 'jitter-min-seconds: %s\n' "$JITTER_MIN"
  printf 'jitter-max-seconds: %s\n' "$JITTER_MAX"
  printf 'draw-attempts: %s\n' "$DRAW_ATTEMPTS"
  printf 'status-fetch-timeout-seconds: %s\n' "$TIMEOUT"
  printf 'status-max-response-bytes: %s\n' "$MAX_BYTES"
  printf 'transaction-lock-stale-after-seconds: %s\n' "$LOCK_STALE_AFTER"
  printf 'source: %s\n' "$URL"
  printf 'written: %s\n' "$(epoch_utc "$NOW")"
  printf 'cadence-in-force: %s\n' "$(cadence_line "$cadence")"
  case "$state" in
    scheduled)
      if [ "$cadence" = raised ]; then
        printf 'next-observation: %s\n' "$(epoch_utc "$next")"
      else
        printf 'next-observation: %s (minute %s, off the five-minute grid)\n' "$(epoch_utc "$next")" "$(minute_of "$next")"
      fi
      ;;
    refused)
      printf 'next-observation: refused because all %s candidate minutes from FM_FORGE_STATUS_JITTER_MIN=%s through FM_FORGE_STATUS_JITTER_MAX=%s with FM_FORGE_STATUS_INTERVAL=%s landed on the five-minute grid\n' \
        "$DRAW_ATTEMPTS" "$JITTER_MIN" "$JITTER_MAX" "$INTERVAL"
      ;;
  esac
  if [ "$observed" -gt 0 ]; then
    printf 'last-observation: %s\n' "$(epoch_utc "$observed")"
  else
    printf 'last-observation: never\n'
  fi
  if [ "$entry" -gt 0 ]; then
    printf 'last-new-reading: %s\n' "$(epoch_utc "$entry")"
  else
    printf 'last-new-reading: never\n'
  fi
  printf 'log: %s\n' "$LOG"
  printf 'note: this watch records readings and wakes firstmate on a new one. It never decides whether a reading matters to this fleet, and never changes its own cadence.\n'
  printf 'note: a reading that could not be taken is recorded as unmeasurable and is never rendered as clear.\n'
}

publish_record() {  # <state> <cadence> <next> <observed> <entry> <recorded> <surfaced>
  local tmp
  PERSISTENCE_PATH=''
  PERSISTENCE_CONDITION=''
  [ ! -d "$REPORT" ] || {
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION='the authoritative forge-watch record could not replace a directory at its state path'
    return 1
  }
  tmp=$(mktemp "$STATE/.forge-status-report.XXXXXX") || {
    PERSISTENCE_PATH=$STATE
    PERSISTENCE_CONDITION='temporary state for the authoritative forge-watch record could not be created'
    return 1
  }
  render_record "$@" > "$tmp" || {
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$tmp
    PERSISTENCE_CONDITION='the authoritative forge-watch record could not be written to temporary state'
    return 1
  }
  if ! mv -f -- "$tmp" "$REPORT"; then
    rm -f -- "$tmp"
    PERSISTENCE_PATH=$REPORT
    PERSISTENCE_CONDITION='the authoritative forge-watch record could not be atomically published'
    return 1
  fi
}

# Schedule the next observation under a cadence. Returns 0 scheduled, 1 refused
# and recorded, 2 state could not be persisted, 3 refused again with nothing new
# to say.
schedule_next() {  # <cadence> <observed> <entry>
  local cadence=$1 observed=$2 entry=$3 target
  if [ "$cadence" = raised ]; then
    target=$(( NOW + RAISED_INTERVAL ))
    publish_record scheduled "$cadence" "$target" "$observed" "$entry" 0 0 || return 2
    return 0
  fi
  if target=$(draw_next_due "$NOW"); then
    publish_record scheduled "$cadence" "$target" "$observed" "$entry" 0 0 || return 2
    return 0
  fi
  if [ "$RECORD_STATE" = refused ] \
    && [ "$RECORD_INTERVAL" = "$INTERVAL" ] \
    && [ "$RECORD_JITTER_MIN" = "$JITTER_MIN" ] \
    && [ "$RECORD_JITTER_MAX" = "$JITTER_MAX" ] \
    && [ "$RECORD_ATTEMPTS" = "$DRAW_ATTEMPTS" ] \
    && [ "$RECORD_SURFACED" -eq 1 ]; then
    return 3
  fi
  publish_record refused "$cadence" 0 "$observed" "$entry" "$NOW" 1 || return 2
  return 1
}

render_absent_report() {
  printf 'state: absent\n'
  printf 'cadence: %s\n' relaxed
  printf 'cadence-in-force: %s\n' "$(cadence_line relaxed)"
  printf 'next-observation: none scheduled\n'
  printf 'last-observation: never\n'
  printf 'last-new-reading: never\n'
  printf 'status-fetch-timeout-seconds: %s\n' "$TIMEOUT"
  printf 'status-max-response-bytes: %s\n' "$MAX_BYTES"
  printf 'transaction-lock-stale-after-seconds: %s\n' "$LOCK_STALE_AFTER"
  printf 'source: %s\n' "$URL"
  printf 'log: %s\n' "$LOG"
}

# --- the lines worth waking a supervisor for --------------------------------

truncated_update() {
  [ -n "$READING_UPDATE" ] || return 0
  printf '%s' "${READING_UPDATE:0:$BODY_WAKE_MAX}"
}

reading_wake_line() {  # <cadence>
  local update
  if [ "$READING_KIND" = measured ]; then
    update=$(truncated_update)
    printf 'FORGE_STATUS: new forge status reading at %s: %s (%s); components not operational: %s; open incidents: %s.%s Judge whether this touches this fleet'"'"'s work - a red check, a hung gate, a failed push or an unopenable pull request in this window may be the forge and not our code, and a CI failure should be reproduced locally before it is believed - and decide whether to raise or lower the watch: %s/fm-forge-status.sh --cadence raised (every %ss) or --cadence relaxed (every %ss off the five-minute grid). Cadence now: %s. Full entry: %s\n' \
      "$(epoch_utc "$NOW")" "$READING_INDICATOR" "$READING_DESCRIPTION" \
      "$READING_COMPONENTS" "$READING_INCIDENTS" \
      "${update:+ Latest update: \"$update\"}" \
      "$SCRIPT_DIR" "$RAISED_INTERVAL" "$INTERVAL" "$1" "$LOG"
    return 0
  fi
  printf 'FORGE_STATUS: new forge status reading at %s: UNMEASURABLE - %s. This is NOT a clear reading and must never be relayed as one; nothing is known here about whether the forge is healthy. Decide whether to raise or lower the watch: %s/fm-forge-status.sh --cadence raised (every %ss) or --cadence relaxed (every %ss off the five-minute grid). Cadence now: %s. Full entry: %s\n' \
    "$(epoch_utc "$NOW")" "$READING_CONDITION" \
    "$SCRIPT_DIR" "$RAISED_INTERVAL" "$INTERVAL" "$1" "$LOG"
}

schedule_refusal_line() {
  printf 'FORGE_STATUS: no next forge observation was scheduled because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_FORGE_STATUS_JITTER_MIN=%s, FM_FORGE_STATUS_JITTER_MAX=%s, FM_FORGE_STATUS_INTERVAL=%s); the draw attempt bound was exhausted, so set the jitter window to include an off-grid target minute\n' \
    "$DRAW_ATTEMPTS" "$JITTER_MIN" "$JITTER_MAX" "$INTERVAL"
}

state_persistence_line() {
  printf 'FORGE_STATUS: state persistence failure at %s because %s; repair that state path and run the check again\n' \
    "$PERSISTENCE_PATH" "$PERSISTENCE_CONDITION"
}

log_append_line() {
  printf 'FORGE_STATUS: a new forge status reading could not be appended to %s, so the reading was taken and then lost; repair that state path and run the check again\n' "$LOG"
}

# --- state directory --------------------------------------------------------

case "$MODE" in
  draw|status|log|cadence) ;;
  armed)
    if { [ -e "$STATE" ] && [ ! -d "$STATE" ]; } \
      || { [ ! -e "$STATE" ] && [ ! -d "${STATE%/*}" ]; }; then
      printf 'FORGE_STATUS: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' "$STATE"
      exit 1
    fi
    ;;
  *)
    if ! mkdir -p "$STATE" 2>/dev/null; then
      if [ "$MODE" = detect ]; then
        printf 'FORGE_STATUS: state persistence failure at %s because the state directory is unavailable; repair that state path and run the check again\n' "$STATE"
        exit 1
      fi
      printf 'fm-forge-status: cannot create state directory %s\n' "$STATE" >&2
      exit 1
    fi
    ;;
esac
if [ "$MODE" = cadence ] && [ -n "$CADENCE_ARG" ] && ! mkdir -p "$STATE" 2>/dev/null; then
  printf 'fm-forge-status: cannot create state directory %s\n' "$STATE" >&2
  exit 1
fi

TRANSACTION_LOCK_HELD=0

transaction_path_age() {
  local path=$1 modified now
  modified=$(path_mtime "$path") || return 1
  now=$(date +%s) || return 1
  case "$modified:$now" in *[!0-9:]*) return 1 ;; esac
  printf '%s\n' "$(( now - modified ))"
}

transaction_path_reclaimable() {
  local path=$1 owner age threshold=$LOCK_STALE_AFTER
  owner=$(cat "$path/pid" 2>/dev/null || true)
  age=$(transaction_path_age "$path") || return 1
  case "$owner" in
    ''|*[!0-9]*) [ "$threshold" -ge 2 ] || threshold=2 ;;
    *)
      [ "$age" -ge "$threshold" ] && return 0
      kill -0 "$owner" 2>/dev/null && return 1
      return 0
      ;;
  esac
  [ "$age" -ge "$threshold" ]
}

claim_transaction_lock() {
  mkdir "$TRANSACTION_LOCK" 2>/dev/null || return 1
  if ! printf '%s\n' "${BASHPID:-$$}" > "$TRANSACTION_LOCK/pid"; then
    rmdir "$TRANSACTION_LOCK" 2>/dev/null || true
    return 2
  fi
  TRANSACTION_LOCK_HELD=1
  trap release_transaction_lock EXIT
  trap 'exit 1' HUP INT TERM
}

# shellcheck disable=SC2329
release_transaction_lock() {
  local owner
  [ "$TRANSACTION_LOCK_HELD" -eq 1 ] || return 0
  owner=$(cat "$TRANSACTION_LOCK/pid" 2>/dev/null || true)
  if [ "$owner" = "${BASHPID:-$$}" ]; then
    rm -f -- "$TRANSACTION_LOCK/pid" 2>/dev/null || true
    rmdir "$TRANSACTION_LOCK" 2>/dev/null || true
  fi
  TRANSACTION_LOCK_HELD=0
}

claim_reclaim_lock() {
  local reclaim=$1
  mkdir "$reclaim" 2>/dev/null || return 1
  if ! printf '%s\n' "${BASHPID:-$$}" > "$reclaim/pid"; then
    rmdir "$reclaim" 2>/dev/null || true
    return 2
  fi
}

release_reclaim_lock() {
  local reclaim=$1 owner
  owner=$(cat "$reclaim/pid" 2>/dev/null || true)
  [ "$owner" = "${BASHPID:-$$}" ] || return 0
  rm -f -- "$reclaim/pid" 2>/dev/null || true
  rmdir "$reclaim" 2>/dev/null || true
}

acquire_reclaim_lock() {
  local reclaim=$1
  claim_reclaim_lock "$reclaim" && return 0
  [ -d "$reclaim" ] || return 2
  transaction_path_reclaimable "$reclaim" || return 1
  transaction_path_reclaimable "$reclaim" || return 1
  rm -f -- "$reclaim/pid" 2>/dev/null || true
  rmdir "$reclaim" 2>/dev/null || return 1
  claim_reclaim_lock "$reclaim"
}

acquire_transaction_lock() {
  local reclaim="$TRANSACTION_LOCK.reclaim"
  claim_transaction_lock && return 0
  [ -d "$TRANSACTION_LOCK" ] || return 2
  transaction_path_reclaimable "$TRANSACTION_LOCK" || return 1
  acquire_reclaim_lock "$reclaim" || return $?
  if transaction_path_reclaimable "$TRANSACTION_LOCK"; then
    rm -f -- "$TRANSACTION_LOCK/pid" 2>/dev/null || true
    rmdir "$TRANSACTION_LOCK" 2>/dev/null || true
  fi
  if claim_transaction_lock; then
    release_reclaim_lock "$reclaim"
    return 0
  fi
  release_reclaim_lock "$reclaim"
  return 1
}

# Write this home's watcher shim and bind it to its own bytes. Every location is
# baked in rather than inherited, because the watcher runs a check from a private
# snapshot with its own environment: a shim that guessed its home would observe
# for a different one. Idempotent, so bootstrap can call this every session.
arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-forge-status.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: the cadence, the reading, the append-only log and
# the payload all live in the script itself, so they arrive by self-update
# instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
exec "$SCRIPT_DIR/fm-forge-status.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    # Written through a temp file in the same directory and moved into place, so
    # a watcher sweeping mid-write can never snapshot half a check and reject it
    # as unauthenticated.
    umask 077
    tmp=$(mktemp "$STATE/.fm-forge-status-check.XXXXXX") || return 1
    printf '%s\n' "$desired" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" forge-status >/dev/null || return 1
}

# --- the health reading -----------------------------------------------------

STATE_PROBE_CONDITION=''

# Publication is the operation whose failure cannot record itself, so before
# concluding that nothing is executing this home's checks, prove the state
# directory can still take a write and an atomic rename. Returns 0 usable,
# 1 unusable, 2 indeterminate.
probe_state_publishability() {
  local probe published
  STATE_PROBE_CONDITION=''
  if [ ! -d "$STATE" ]; then
    STATE_PROBE_CONDITION='the state path is not a directory'
    return 1
  fi
  if [ -d "$REPORT" ]; then
    STATE_PROBE_CONDITION='the authoritative record path is a directory and cannot be atomically replaced'
    return 1
  fi
  probe=$(mktemp "$STATE/.forge-status-health.XXXXXX" 2>/dev/null) || {
    STATE_PROBE_CONDITION='temporary state cannot be created in the state directory'
    return 1
  }
  published="$probe.published"
  if ! render_record scheduled relaxed "$(( NOW + INTERVAL + JITTER_MIN ))" 0 0 0 0 > "$probe" 2>/dev/null; then
    rm -f -- "$probe" "$published" 2>/dev/null
    STATE_PROBE_CONDITION='representative record content cannot be written in the state directory'
    return 1
  fi
  if ! mv -f -- "$probe" "$published" 2>/dev/null; then
    rm -f -- "$probe" "$published" 2>/dev/null
    STATE_PROBE_CONDITION='a same-directory atomic rename cannot complete in the state directory'
    return 1
  fi
  if ! rm -f -- "$probe" "$published" 2>/dev/null || [ -e "$published" ]; then
    STATE_PROBE_CONDITION='the representative publish completed but its scratch state could not be cleaned up, so publishability cannot be determined'
    return 2
  fi
  return 0
}

diagnose_unexecuted_work() {  # <missing|overdue> <elapsed> <last-observation>
  local kind=$1 elapsed=$2 last=${3:-0} probe_status
  probe_state_publishability
  probe_status=$?
  if [ "$probe_status" -eq 1 ]; then
    printf 'FORGE_STATUS: state persistence failure at %s because %s; the forge watch ran but cannot persist its state\n' \
      "$STATE" "$STATE_PROBE_CONDITION"
    return 0
  fi
  if [ "$probe_status" -eq 2 ]; then
    printf 'FORGE_STATUS: state health indeterminate at %s because %s; the missing observation could mean either a state publication failure or a supervision outage, and this reading asserts neither cause\n' \
      "$STATE" "$STATE_PROBE_CONDITION"
    return 0
  fi
  if [ "$kind" = missing ]; then
    printf 'FORGE_STATUS: supervision outage: the forge status watch has been armed for %s minute(s) and has never scheduled an observation, so nothing is running this home'"'"'s checks and the forge is unwatched (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))"
  elif [ "$last" -gt 0 ]; then
    printf 'FORGE_STATUS: supervision outage: the forge status observation was due %s minute(s) ago and has not run (it last read the status page %s); the schedule stands but nothing is executing it, so the forge is unwatched (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))" "$(epoch_utc "$last")"
  else
    printf 'FORGE_STATUS: supervision outage: the forge status observation was due %s minute(s) ago and has never run; the schedule stands but nothing is executing it, so the forge is unwatched (inspect the monitoring service for this home)\n' \
      "$(( elapsed / 60 ))"
  fi
}

armed_diagnostic() {
  local shim_mtime shim_age overdue_by age slack
  if read_record; then
    if [ "$RECORD_STATE" = refused ]; then
      age=$(( NOW - RECORD_RECORDED ))
      [ "$age" -ge 0 ] || age=0
      printf 'FORGE_STATUS: the forge watch scheduler has refused to create a next observation for %s minute(s) because all %s candidate minutes drawn from the configured jitter window landed on the five-minute grid (FM_FORGE_STATUS_JITTER_MIN=%s, FM_FORGE_STATUS_JITTER_MAX=%s, FM_FORGE_STATUS_INTERVAL=%s); set the jitter window to include an off-grid target minute\n' \
        "$(( age / 60 ))" "$RECORD_ATTEMPTS" "$RECORD_JITTER_MIN" "$RECORD_JITTER_MAX" "$RECORD_INTERVAL"
      return 0
    fi
    slack=$(cadence_overdue_slack "$RECORD_CADENCE")
    overdue_by=$(( NOW - RECORD_NEXT ))
    [ "$overdue_by" -ge "$slack" ] || return 0
    diagnose_unexecuted_work overdue "$overdue_by" "$RECORD_OBSERVED"
    return 0
  fi
  if [ -e "$REPORT" ]; then
    printf 'FORGE_STATUS: state persistence failure at %s because the authoritative forge-watch record is unreadable; repair that state path and run the check again\n' "$REPORT"
    return 0
  fi
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'FORGE_STATUS: the forge status watch is not armed on this home, so nothing will notice a forge outage between sessions and workers will keep reading its failures as their own defects (fix: %s/fm-forge-status.sh --arm)\n' "$SCRIPT_DIR"
    return 0
  fi
  shim_mtime=$(path_mtime "$CHECK") || shim_mtime=$NOW
  case "${shim_mtime:-}" in ''|*[!0-9]*) shim_mtime=$NOW ;; esac
  shim_age=$(( NOW - shim_mtime ))
  [ "$shim_age" -ge "$OVERDUE_RAISED" ] || return 0
  diagnose_unexecuted_work missing "$shim_age"
}

# --- observation --------------------------------------------------------

# One observation: read, append only if the reading is new, then schedule the
# next one under whatever cadence is in force. Prints the wake line for a new
# reading, and any scheduling or persistence diagnostic after it.
run_observation() {  # <cadence>
  local cadence=$1 previous entry_epoch appended=0 transition
  observe
  previous=$(last_logged_fingerprint)
  entry_epoch=$RECORD_ENTRY
  if [ "$READING_FINGERPRINT" != "$previous" ]; then
    if ! append_entry "$cadence"; then
      log_append_line
      return 1
    fi
    appended=1
    entry_epoch=$NOW
  fi
  [ "$appended" -eq 0 ] || reading_wake_line "$cadence"
  schedule_next "$cadence" "$NOW" "$entry_epoch"
  transition=$?
  case "$transition" in
    0|3) return 0 ;;
    1) schedule_refusal_line; return 0 ;;
    *) state_persistence_line; return 1 ;;
  esac
}

# --- modes ------------------------------------------------------------------

case "$MODE" in
  draw)
    drawn=0
    while [ "$drawn" -lt "$DRAW_COUNT" ]; do
      if ! target=$(draw_next_due "$NOW"); then
        printf 'fm-forge-status: no target off the five-minute grid could be drawn in %s attempts; refusing to schedule one on it\n' \
          "$DRAW_ATTEMPTS" >&2
        exit 1
      fi
      printf '%s\n' "$target"
      drawn=$(( drawn + 1 ))
    done
    exit 0
    ;;
  arm)
    arm || { printf 'fm-forge-status: cannot arm the forge status watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0
    ;;
  armed)
    [ "${FM_FORGE_STATUS_DISABLE:-0}" = 1 ] && exit 0
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
  log)
    if [ ! -f "$LOG" ]; then
      printf 'no forge status readings have been recorded on this home yet (%s)\n' "$LOG"
      exit 0
    fi
    awk -v want="$LOG_COUNT" '
      { block = block $0 "\n"; if ($0 == "") { blocks[++n] = block; block = "" } }
      END {
        if (block != "") blocks[++n] = block
        start = n - want + 1
        if (start < 1) start = 1
        for (i = start; i <= n; i++) printf "%s", blocks[i]
      }' "$LOG"
    exit 0
    ;;
  cadence)
    if [ -z "$CADENCE_ARG" ]; then
      if read_record; then
        printf 'cadence: %s\n' "$(cadence_line "$RECORD_CADENCE")"
        if [ "$RECORD_STATE" = scheduled ]; then
          printf 'next-observation: %s\n' "$(epoch_utc "$RECORD_NEXT")"
        else
          printf 'next-observation: none scheduled\n'
        fi
      else
        printf 'cadence: %s\n' "$(cadence_line relaxed)"
        printf 'next-observation: none scheduled (this home has no forge watch record yet)\n'
      fi
      exit 0
    fi
    lock_status=0
    acquire_transaction_lock || lock_status=$?
    if [ "$lock_status" -ne 0 ]; then
      if [ "$lock_status" -eq 1 ]; then
        printf 'fm-forge-status: another forge-status update is already in progress\n' >&2
      else
        printf 'fm-forge-status: cannot lock forge-status state in %s\n' "$STATE" >&2
      fi
      exit 1
    fi
    read_record || true
    schedule_next "$CADENCE_ARG" "$RECORD_OBSERVED" "$RECORD_ENTRY"
    transition_status=$?
    case "$transition_status" in
      0)
        printf 'cadence: %s\n' "$(cadence_line "$CADENCE_ARG")"
        read_record && printf 'next-observation: %s\n' "$(epoch_utc "$RECORD_NEXT")"
        exit 0
        ;;
      1|3) schedule_refusal_line >&2; exit 1 ;;
      *) state_persistence_line >&2; exit 1 ;;
    esac
    ;;
esac

[ "$MODE" = detect ] && [ "${FM_FORGE_STATUS_DISABLE:-0}" = 1 ] && exit 0

lock_status=0
acquire_transaction_lock || lock_status=$?
if [ "$lock_status" -ne 0 ]; then
  if [ "$lock_status" -eq 1 ] && { [ "$MODE" = detect ] || [ "$MODE" = force ]; }; then exit 0; fi
  if [ "$lock_status" -eq 1 ]; then
    printf 'fm-forge-status: another forge-status update is already in progress\n' >&2
  else
    printf 'fm-forge-status: cannot lock forge-status state in %s\n' "$STATE" >&2
  fi
  exit 1
fi

if [ "$MODE" = detect ]; then
  if ! read_record; then
    # First sweep on a fresh home: schedule, observe nothing, wake nobody. An
    # arming that woke a supervisor would train them to ignore this check.
    schedule_next relaxed 0 0
    transition_status=$?
    case "$transition_status" in
      0|3) exit 0 ;;
      1) schedule_refusal_line; exit 0 ;;
      *) state_persistence_line; exit 1 ;;
    esac
  fi
  if [ "$RECORD_STATE" != scheduled ]; then
    schedule_next "$RECORD_CADENCE" "$RECORD_OBSERVED" "$RECORD_ENTRY"
    transition_status=$?
    case "$transition_status" in
      0|3) exit 0 ;;
      1) schedule_refusal_line; exit 0 ;;
      *) state_persistence_line; exit 1 ;;
    esac
  fi
  [ "$NOW" -ge "$RECORD_NEXT" ] || exit 0
else
  read_record || true
fi

run_observation "$RECORD_CADENCE"
exit $?
