#!/usr/bin/env bash
# The bosun: the observer tier that judges supervision events and records what it
# concluded, where a human can watch it.
#
# IT HAS AUTHORITY OVER NOTHING. It reads the event journal and writes its own
# record under state/bosun/. It does not queue, drain, suppress, or reorder a
# single notification, and nothing it concludes changes what reaches a
# supervising session. bin/fm-bosun-lib.sh's header owns the verdict record
# format, the escalation bias, and the health contract; docs/bosun-observer.md
# owns why it exists, what is proven, and what was deliberately left unbuilt.
#
# Usage:
#   fm-bosun.sh run [--once] [--interval <seconds>] [--limit <n>]
#   fm-bosun.sh status
#   fm-bosun.sh verdicts [--since <seq>] [--limit <n>] [--only <verdict>] [--raw]
#   fm-bosun.sh watch [--interval <seconds>]
#
# run       Judge every journal event above the cursor, then keep doing so every
#           --interval seconds until stopped. --once runs exactly one pass and
#           exits, which is the form to reach for from a test or a cron. --limit
#           bounds how many events one pass judges. One line is printed per
#           verdict as it is recorded, so a foreground run is watchable live.
#           Only one run may hold this home's bosun at a time; a second refuses
#           rather than double-judging the same events.
#
# status    Print the health of this home's bosun and, on the last line, one of
#           five states: WORKING, QUIET, STALLED, STOPPED, or DEAD. The
#           distinction that matters is QUIET against STALLED: a bosun that
#           judged nothing because nothing arrived is healthy, and one whose
#           cursor has sat still while the journal grew is not, and no
#           process-liveness check can tell those two apart. STOPPED means it
#           exited cleanly; DEAD means it stopped reporting without doing so.
#           Exits 0 for WORKING and QUIET, 1 for the three that mean nothing is
#           being judged, so a check can act on it without parsing.
#
# verdicts  Read judgements back, oldest first, in a human-readable form.
#           --since <seq> prints only verdicts above that sequence, --only
#           escalate or routine filters to one, and --raw prints the underlying
#           eleven-field records instead for a machine.
#
# watch     Follow the bosun live from another terminal: reprints its health and
#           streams each new verdict as it lands. Reads only; it never starts a
#           run and never advances anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bosun-lib.sh
. "$SCRIPT_DIR/fm-bosun-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
  -h|--help|help|'')
    usage
    exit 0
    ;;
esac

once=false
since=0
limit=
only=
raw=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) once=true; shift ;;
    --raw) raw=true; shift ;;
    --interval)
      FM_BOSUN_INTERVAL=${2:-}
      shift 2 || true
      case "$FM_BOSUN_INTERVAL" in ''|*[!0-9]*) echo "fm-bosun.sh: --interval needs seconds" >&2; exit 2 ;; esac
      ;;
    --limit)
      limit=${2:-}
      shift 2 || true
      case "$limit" in ''|*[!0-9]*) echo "fm-bosun.sh: --limit needs a count" >&2; exit 2 ;; esac
      ;;
    --since)
      since=${2:-}
      shift 2 || true
      case "$since" in ''|*[!0-9]*) echo "fm-bosun.sh: --since needs a sequence number" >&2; exit 2 ;; esac
      ;;
    --only)
      only=${2:-}
      shift 2 || true
      case "$only" in escalate|routine) ;; *) echo "fm-bosun.sh: --only takes escalate or routine" >&2; exit 2 ;; esac
      ;;
    *)
      echo "fm-bosun.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$limit" ] && FM_BOSUN_PASS_MAX=$limit

# --- status -----------------------------------------------------------------

# Resolve the bosun's health into one word. The whole reason this is computed
# rather than read from the health record is that the interesting failure cannot
# be self-reported: a bosun that has stopped judging still writes "running", and
# a bosun that has stopped ENTIRELY writes nothing at all. Both are diagnosed
# from outside, by comparing what the record says against the clock and against
# the journal it is supposed to be consuming.
bosun_state() {
  local run_state last_pass backlog_since cursor journal_last interval age dead_after
  local now
  now=$(date +%s)

  if [ ! -f "$FM_BOSUN_HEALTH" ]; then
    printf 'DEAD\tno bosun has ever run in this home, or its health record is gone\n'
    return 0
  fi

  run_state=$(fm_bosun_health_field state)
  last_pass=$(fm_bosun_health_field last_pass)
  backlog_since=$(fm_bosun_health_field backlog_since)
  cursor=$(fm_bosun_health_field cursor)
  journal_last=$(fm_bosun_health_field journal_last)
  interval=$(fm_bosun_health_field interval)
  case "$last_pass" in ''|*[!0-9]*) last_pass=0 ;; esac
  case "$backlog_since" in ''|*[!0-9]*) backlog_since=0 ;; esac
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  case "$journal_last" in ''|*[!0-9]*) journal_last=0 ;; esac
  case "$interval" in ''|*[!0-9]*|0) interval=$FM_BOSUN_INTERVAL ;; esac

  # A clean exit is not the same failure as a wedge, and calling both DEAD would
  # hide the one that needs looking at behind the one that does not.
  if [ "$run_state" = stopped ]; then
    printf 'STOPPED\tthe bosun exited cleanly and is not running; nothing is being judged\n'
    return 0
  fi

  age=$((now - last_pass))
  dead_after=$((interval * FM_BOSUN_DEAD_PASSES))
  if [ "$age" -gt "$dead_after" ]; then
    printf 'DEAD\tno pass for %ss, past %s missed passes of a %ss interval\n' \
      "$age" "$FM_BOSUN_DEAD_PASSES" "$interval"
    return 0
  fi

  # The seventeen-hour failure, stated as a test rather than as a hope: passes
  # are still happening, the journal is ahead of the cursor, and the cursor has
  # not moved for longer than the stall bound. Alive, logging, producing nothing.
  if [ "$backlog_since" -gt 0 ] && [ $((now - backlog_since)) -ge "$FM_BOSUN_STALL_AFTER" ]; then
    printf 'STALLED\tstill running, but %s event(s) have gone unjudged for %ss\n' \
      "$((journal_last - cursor))" "$((now - backlog_since))"
    return 0
  fi

  if [ "$journal_last" -gt "$cursor" ]; then
    printf 'WORKING\t%s event(s) still to judge\n' "$((journal_last - cursor))"
    return 0
  fi

  printf 'QUIET\tup to date with the journal; nothing has arrived to judge\n'
  return 0
}

print_status() {
  local resolved word note gaps
  resolved=$(bosun_state)
  word=${resolved%%$'\t'*}
  note=${resolved#*$'\t'}

  if [ -f "$FM_BOSUN_HEALTH" ]; then
    cat "$FM_BOSUN_HEALTH"
  else
    printf 'state: never run\n'
  fi
  printf 'verdicts_total: %s\n' "$(fm_bosun_cat | wc -l | tr -d ' ')"
  printf 'escalations_total: %s\n' "$(fm_bosun_cat | awk -F '\t' '$7 == "escalate"' | wc -l | tr -d ' ')"

  # The journal's own incompleteness is reported here rather than smoothed over:
  # a consumer that mistakes a truncated stream for a whole one judges on it.
  gaps=$(fm_bosun_journal_gaps)
  case "$gaps" in
    ''|0) : ;;
    *) printf 'journal_gaps: %s (events allocated a sequence that never reached disk; never judged)\n' "$gaps" ;;
  esac

  printf '%s - %s\n' "$word" "$note"
  case "$word" in
    STALLED|DEAD|STOPPED) return 1 ;;
  esac
  return 0
}

# --- verdict rendering ------------------------------------------------------

render_verdicts() {  # reads records on stdin
  if [ "$raw" = true ]; then
    cat
    return 0
  fi
  LC_ALL=C awk -F '\t' '
    {
      stamp = strftime("%Y-%m-%d %H:%M:%S", $2 + 0)
      printf "#%s  %s  %-8s %-4s  [%s %s]\n", $1, stamp, $7, $8, $4, $5
      printf "      event:  %s\n", $6
      printf "      reason: %s\n", $9
      printf "      judge:  %s in %sms (journal event %s)\n\n", $10, $11, $3
    }
  '
}

select_verdicts() {
  fm_bosun_cat | LC_ALL=C awk -F '\t' \
    -v since="$since" -v only="$only" -v limit="${limit:-0}" '
    NF >= 11 && $1 + 0 > since && (only == "" || $7 == only) {
      if (limit > 0 && ++shown > limit) { exit }
      print
    }
  '
}

# --- commands ---------------------------------------------------------------

case "$cmd" in
  run)
    mkdir -p "$FM_BOSUN_DIR" 2>/dev/null || {
      echo "fm-bosun.sh: cannot create $FM_BOSUN_DIR" >&2
      exit 1
    }
    # One bosun per home. Two would judge the same events twice and interleave
    # their cursors; refusing is cheaper to understand than reconciling that.
    if ! fm_lock_try_acquire "$FM_BOSUN_RUN_LOCK"; then
      echo "fm-bosun.sh: a bosun is already running in this home" >&2
      exit 1
    fi

    started=$(date +%s)
    passes=0
    verdicts=0
    last_judged=0
    run_state=running

    finish() {
      fm_bosun_health_write stopped "$started" "$passes" "$verdicts" "$last_judged" \
        "$(fm_bosun_cursor)" || true
      fm_lock_release "$FM_BOSUN_RUN_LOCK"
    }
    trap 'finish; exit 0' INT TERM
    trap 'fm_lock_release "$FM_BOSUN_RUN_LOCK"' EXIT

    printf 'fm-bosun: observing (judge: %s, interval: %ss). It records; it decides nothing.\n' \
      "$(fm_bosun_judge_command)" "$FM_BOSUN_INTERVAL"

    while :; do
      cursor_before=$(fm_bosun_cursor)
      fm_bosun_pass
      passes=$((passes + 1))
      if [ "$FM_BOSUN_PASS_JUDGED" -gt 0 ]; then
        verdicts=$((verdicts + FM_BOSUN_PASS_JUDGED))
        last_judged=$(date +%s)
      fi
      # Written on EVERY pass, judged or not: a beacon that only ticks when there
      # is work cannot prove a quiet bosun is alive.
      fm_bosun_health_write "$run_state" "$started" "$passes" "$verdicts" \
        "$last_judged" "$cursor_before" || true
      [ "$once" = true ] && break
      sleep "$FM_BOSUN_INTERVAL"
    done

    if [ "$once" = true ]; then
      finish
    fi
    ;;

  status)
    print_status
    exit $?
    ;;

  verdicts)
    select_verdicts | render_verdicts
    ;;

  watch)
    # Read-only follow. It starts nothing and advances nothing; every number it
    # shows was put on disk by the run it is watching.
    while :; do
      clear 2>/dev/null || true
      print_status || true
      printf '\n--- verdicts ---\n'
      fm_bosun_cat | LC_ALL=C awk -F '\t' 'NF >= 11' | tail -20 | render_verdicts
      printf '(watching; nothing here changes what reaches a supervisor)\n'
      sleep "$FM_BOSUN_INTERVAL"
    done
    ;;

  *)
    echo "fm-bosun.sh: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
