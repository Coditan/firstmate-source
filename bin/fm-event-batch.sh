#!/usr/bin/env bash
# The event batcher: group supervision events into batches by priority, hold each
# batch for a bounded time, and record what was grouped.
#
# IT DECIDES NOTHING ABOUT WHAT REACHES A SUPERVISOR. It reads the event journal
# and writes its own record under state/batches/. It does not judge, suppress,
# drop, downgrade, dedupe, or reorder an event, and it does not queue or drain a
# wake. bin/fm-event-batch-lib.sh's header owns the record formats, the
# never-dropped contract, and the classification rule; docs/event-batching.md
# owns why it exists in this shape, what is proven, and what is deliberately
# unbuilt.
#
# Usage:
#   fm-event-batch.sh run [--once] [--interval <seconds>] [--limit <n>]
#   fm-event-batch.sh status
#   fm-event-batch.sh open
#   fm-event-batch.sh batches [--since <bseq>] [--only <priority>] [--limit <n>] [--raw]
#   fm-event-batch.sh show <bseq> [--raw]
#   fm-event-batch.sh flush
#   fm-event-batch.sh account
#   fm-event-batch.sh delays
#
# run       Admit every journal event above the cursor into its class's batch,
#           close whatever is due, then keep doing so every --interval seconds
#           until stopped. --once runs exactly one pass and exits, which is the
#           form to reach for from a test or a cron. --limit bounds how many
#           events one pass admits; it never bounds a batch. One line is printed
#           per closed batch as it lands, so a foreground run is watchable live.
#           Only one run may hold this home's batcher at a time.
#
# status    Print the batcher's health and, on the last line, one of six states:
#           QUIET, HOLDING, BEHIND, OVERDUE, STOPPED, or DEAD. OVERDUE is the one
#           that matters: a batch whose deadline has passed and which nothing has
#           closed means events are being held that should already have been
#           released, and from the outside that looks exactly like a quiet fleet.
#           Exits 0 for QUIET, HOLDING, and BEHIND; 1 for the three that mean
#           events are stuck or nothing is running.
#
# open      What is being held right now, per class, and when each batch is due
#           to close. Reads only.
#
# batches   Read closed batches back, oldest first, with the hold each actually
#           took against the budget its class allows. --raw prints the underlying
#           ten-field records instead, for a machine.
#
# show      Print the members of one batch: the events that travelled together.
#           This is what a downstream consumer of a batch reads.
#
# flush     Close every open batch now, with reason "flush". It closes; it never
#           discards, and every member of a flushed batch is in its record.
#
# account   Reconcile the journal against the batch records and report anything
#           the batching cannot account for: a journal event that was passed but
#           never batched, one batched twice, an event that aged out before it
#           could be batched, an orphaned or inconsistently closed batch, a
#           recorded count mismatch, a batch held over budget, an immediate
#           batch held at all, or an open batch past its deadline. Exits 0 only
#           when every one of those is empty. This is the drop test, and it is a
#           command rather than a claim because a lost notification and a quiet
#           period look identical from anywhere else.
#
# delays    Print immediate as the class that is never held, plus the resolved
#           high, normal, and low delays and whether each came from the
#           environment, this home's config/batch-delays, or the shipped default.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-event-batch-lib.sh
. "$SCRIPT_DIR/fm-event-batch-lib.sh"

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

# A home that mistyped a delay must not be handed the shipped default while
# believing it configured one.
if [ -n "$FM_BATCH_CONFIG_ERROR" ]; then
  printf 'fm-event-batch.sh: %s\n' "$FM_BATCH_CONFIG_ERROR" >&2
  printf 'fm-event-batch.sh: fix %s, or unset the environment override, before running\n' \
    "$FM_BATCH_DELAY_CONFIG" >&2
  exit 2
fi

once=false
since=0
limit=
only=
raw=false
target=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) once=true; shift ;;
    --raw) raw=true; shift ;;
    --interval)
      FM_BATCH_INTERVAL=${2:-}
      shift 2 || true
      case "$FM_BATCH_INTERVAL" in ''|*[!0-9]*) echo "fm-event-batch.sh: --interval needs seconds" >&2; exit 2 ;; esac
      ;;
    --limit)
      limit=${2:-}
      shift 2 || true
      case "$limit" in ''|*[!0-9]*) echo "fm-event-batch.sh: --limit needs a count" >&2; exit 2 ;; esac
      ;;
    --since)
      since=${2:-}
      shift 2 || true
      case "$since" in ''|*[!0-9]*) echo "fm-event-batch.sh: --since needs a sequence number" >&2; exit 2 ;; esac
      ;;
    --only)
      only=${2:-}
      shift 2 || true
      case " $FM_BATCH_PRIORITIES " in
        *" $only "*) ;;
        *) echo "fm-event-batch.sh: --only takes one of: $FM_BATCH_PRIORITIES" >&2; exit 2 ;;
      esac
      ;;
    -*)
      echo "fm-event-batch.sh: unknown option: $1" >&2
      exit 2
      ;;
    *)
      [ -z "$target" ] || { echo "fm-event-batch.sh: unexpected argument: $1" >&2; exit 2; }
      target=$1
      shift
      ;;
  esac
done
[ -n "$limit" ] && FM_BATCH_PASS_MAX=$limit

journal_field() {  # <name>
  "$SCRIPT_DIR/fm-journal.sh" status 2>/dev/null | awk -F': ' -v want="$1" '$1 == want { print $2; exit }'
}

# --- account ----------------------------------------------------------------

# Emit every input the reconciliation needs as tagged lines, so one awk pass can
# compare them without a second read of anything.
account_inputs() {
  local priority
  printf 'cursor\t%s\n' "$(fm_batch_cursor)"
  printf 'now\t%s\n' "$(fm_batch_now)"
  printf 'grace\t%s\n' "$FM_BATCH_INTERVAL"
  printf 'horizon\t%s\n' "$(journal_field horizon)"
  printf 'jgaps\t%s\n' "$(journal_field gaps)"
  for priority in $FM_BATCH_PRIORITIES; do
    printf 'delay\t%s\t%s\n' "$priority" "$(fm_batch_delay "$priority")"
  done
  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_open_read "$priority" || continue
    printf 'open\t%s\t%s\t%s\t%s\n' \
      "$FM_BATCH_OPEN_BSEQ" "$priority" "$FM_BATCH_OPEN_DEADLINE" "$FM_BATCH_OPEN_COUNT"
  done < <(fm_batch_open_priorities)
  "$SCRIPT_DIR/fm-journal.sh" read 2>/dev/null \
    | LC_ALL=C awk -F '\t' 'NF >= 7 && $1 ~ /^[0-9]+$/ { print "journal\t" $1 }'
  fm_batch_cat_members \
    | LC_ALL=C awk -F '\t' 'NF >= 8 && $4 ~ /^[0-9]+$/ { print "member\t" $4 "\t" $2 }'
  fm_batch_cat_batches \
    | LC_ALL=C awk -F '\t' 'NF >= 10 && $1 ~ /^[0-9]+$/ { print "batch\t" $1 "\t" $2 "\t" $4 "\t" $5 "\t" $7 "\t" $8 }'
}

run_account() {
  account_inputs | LC_ALL=C awk -F '\t' '
    $1 == "cursor"  { cursor = $2 + 0; next }
    $1 == "now"     { now = $2 + 0; next }
    $1 == "grace"   { grace = $2 + 0; next }
    $1 == "horizon" { horizon = $2; next }
    $1 == "jgaps"   { jgaps = $2; next }
    $1 == "delay"   { delay[$2] = $3 + 0; next }
    $1 == "open"    { open_bseq[$2 + 0] = 1; open_pri[$2 + 0] = $3
                      open_due[$2 + 0] = $4 + 0; open_count[$2 + 0] = $5 + 0
                      opens++; next }
    $1 == "journal" { jseq[$2 + 0] = 1; if (($2 + 0) > jlast) jlast = $2 + 0; next }
    $1 == "member"  { members[$2 + 0]++; member_bseq[$3 + 0] = 1
                      member_count[$3 + 0]++; total_members++; next }
    $1 == "batch"   { closed_bseq[$2 + 0]++; bpri[$2 + 0] = $3
                      boldest[$2 + 0] = $4 + 0; bclosed[$2 + 0] = $5 + 0
                      breason[$2 + 0] = $6; batch_count[$2 + 0] = $7 + 0
                      total_batches++; next }
    END {
      fault = 0
      printf "journal_horizon: %s\n", (horizon == "" ? "none" : horizon)
      printf "journal_last: %d\n", jlast
      printf "cursor: %d\n", cursor
      printf "members: %d\n", total_members + 0
      printf "closed_batches: %d\n", total_batches + 0
      printf "open_batches: %d\n", opens + 0

      # A journal event at or below the cursor was passed by the batcher. If it
      # is not in a batch, batching lost it, and that is the whole point of this
      # command.
      # s + 0 on purpose: an array subscript comes back from `for (s in ...)` as a
      # plain string, so comparing it to the cursor directly is a STRING
      # comparison, under which "10" sorts below "3" and every event past the
      # ninth reads as lost the moment the cursor is behind.
      for (s in jseq) {
        if (s + 0 <= cursor && !(s in members)) {
          missing = missing " " s
          missing_n++
        }
        if (s + 0 > cursor) pending_n++
      }
      # An event that fell below the retention horizon before the batcher reached
      # it existed and will never be batched. Reported, never stepped over.
      if (horizon ~ /^[0-9]+$/ && cursor < horizon - 1) aged = horizon - 1 - cursor

      for (s in members) if (members[s] > 1) { dup = dup " " s; dup_n++ }
      for (b in member_bseq)
        if (!(b in closed_bseq) && !(b in open_bseq)) { orphan = orphan " " b; orphan_n++ }
      for (b in closed_bseq) {
        if (closed_bseq[b] > 1) { duplicate_close = duplicate_close " " b; duplicate_close_n++ }
        if (b in open_bseq) { overlap = overlap " " b; overlap_n++ }
        if (batch_count[b] != member_count[b]) {
          mismatch = mismatch sprintf(" #%d(recorded %d, members %d)", b, batch_count[b], member_count[b])
          mismatch_n++
        }
      }

      # Two different questions, and conflating them would leave one of them
      # unanswerable. The budget check measures from the oldest member ARRIVED,
      # which is the clock the captain named his numbers against, and allows one
      # poll interval on top because noticing an event is admission latency
      # shared by every class rather than batching.
      #
      # "No delay at all" is not a duration comparison, so it is not checked as
      # one: an immediate batch is closed by the admission that opened it, in the
      # same pass, and that close is the only one that records the reason
      # "immediate". Any other reason on an immediate batch means it survived the
      # pass that should have released it - that is, it was held.
      for (b in closed_bseq) {
        hold = bclosed[b] - boldest[b]
        budget = delay[bpri[b]]
        if (hold > budget + grace) {
          over = over sprintf(" #%d(%s held %ds of %ds+%ds)", b, bpri[b], hold, budget, grace)
          over_n++
        }
        if (bpri[b] == "immediate" && breason[b] != "immediate") {
          heldi = heldi sprintf(" #%d(closed as %s, not passed straight through)", b, breason[b])
          heldi_n++
        }
      }
      for (b in open_bseq)
        if (now > open_due[b] + grace) {
          overdue = overdue sprintf(" #%d(%s, %d event(s), %ds past due)", \
            b, open_pri[b], open_count[b], now - open_due[b])
          overdue_n++
        }

      printf "pending: %d (journal events above the cursor, not yet admitted)\n", pending_n + 0
      if (missing_n) { printf "missing:%s\n", missing; fault = 1 }
      if (aged) { printf "aged_out: %d event(s) fell below the journal horizon before batching\n", aged; fault = 1 }
      if (dup_n) { printf "duplicated:%s\n", dup; fault = 1 }
      if (orphan_n) { printf "orphaned_batches:%s\n", orphan; fault = 1 }
      if (duplicate_close_n) { printf "duplicate_closures:%s\n", duplicate_close; fault = 1 }
      if (overlap_n) { printf "open_closed_overlap:%s\n", overlap; fault = 1 }
      if (mismatch_n) { printf "count_mismatch:%s\n", mismatch; fault = 1 }
      if (over_n) { printf "over_budget:%s\n", over; fault = 1 }
      if (heldi_n) { printf "immediate_held:%s\n", heldi; fault = 1 }
      if (overdue_n) { printf "overdue_open:%s\n", overdue; fault = 1 }
      if (jgaps != "" && jgaps != "0")
        printf "journal_gaps: %s (allocated a sequence and never reached disk; never batched)\n", jgaps

      if (fault) {
        printf "UNACCOUNTED - %d missing, %d aged out, %d duplicated, %d orphaned, %d duplicate closures, %d open/closed overlaps, %d count mismatches, %d over budget, %d immediate held, %d overdue\n", \
          missing_n + 0, aged + 0, dup_n + 0, orphan_n + 0, duplicate_close_n + 0, overlap_n + 0, mismatch_n + 0, over_n + 0, heldi_n + 0, overdue_n + 0
        exit 1
      }
      printf "ACCOUNTED - every journal event at or below the cursor is in exactly one batch, within its budget\n"
      exit 0
    }
  '
}

# --- status -----------------------------------------------------------------

batch_state() {
  local now cursor jlast priority run_state last_pass interval age dead_after
  local holding=0 overdue=0
  now=$(fm_batch_now)
  cursor=$(fm_batch_cursor)
  jlast=$(journal_field last)
  case "$jlast" in ''|*[!0-9]*) jlast=0 ;; esac

  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_open_read "$priority" || continue
    holding=$((holding + 1))
    case "$FM_BATCH_OPEN_DEADLINE" in ''|*[!0-9]*) continue ;; esac
    [ "$now" -gt $((FM_BATCH_OPEN_DEADLINE + FM_BATCH_INTERVAL)) ] || continue
    overdue=$((overdue + 1))
  done < <(fm_batch_open_priorities)

  # The fault that matters first: events are being held that should already have
  # been released, and nothing about a quiet fleet looks any different.
  if [ "$overdue" -gt 0 ]; then
    printf 'OVERDUE\t%s batch(es) past their deadline are still being held\n' "$overdue"
    return 0
  fi

  if [ ! -f "$FM_BATCH_HEALTH" ]; then
    printf 'DEAD\tno batcher has ever run in this home, or its health record is gone\n'
    return 0
  fi
  run_state=$(fm_batch_health_field state)
  last_pass=$(fm_batch_health_field last_pass)
  interval=$(fm_batch_health_field interval)
  case "$last_pass" in ''|*[!0-9]*) last_pass=0 ;; esac
  case "$interval" in ''|*[!0-9]*|0) interval=$FM_BATCH_INTERVAL ;; esac

  if [ "$run_state" = stopped ]; then
    printf 'STOPPED\tthe batcher exited cleanly and is not running; nothing is being grouped\n'
    return 0
  fi
  age=$((now - last_pass))
  dead_after=$((interval * FM_BATCH_DEAD_PASSES))
  if [ "$age" -gt "$dead_after" ]; then
    printf 'DEAD\tno pass for %ss, past %s missed passes of a %ss interval\n' \
      "$age" "$FM_BATCH_DEAD_PASSES" "$interval"
    return 0
  fi

  if [ "$jlast" -gt "$cursor" ]; then
    printf 'BEHIND\t%s event(s) still to admit\n' "$((jlast - cursor))"
    return 0
  fi
  if [ "$holding" -gt 0 ]; then
    printf 'HOLDING\t%s batch(es) open and inside their budget\n' "$holding"
    return 0
  fi
  printf 'QUIET\tup to date with the journal; nothing is being held\n'
  return 0
}

print_status() {
  local resolved word note
  resolved=$(batch_state)
  word=${resolved%%$'\t'*}
  note=${resolved#*$'\t'}

  if [ -f "$FM_BATCH_HEALTH" ]; then
    cat "$FM_BATCH_HEALTH"
  else
    printf 'state: never run\n'
  fi
  printf 'members_total: %s\n' "$(fm_batch_cat_members | wc -l | tr -d ' ')"
  printf 'batches_total: %s\n' "$(fm_batch_cat_batches | wc -l | tr -d ' ')"
  printf '%s - %s\n' "$word" "$note"
  case "$word" in
    OVERDUE|STOPPED|DEAD) return 1 ;;
  esac
  return 0
}

print_open() {
  local priority now found=0
  now=$(fm_batch_now)
  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_open_read "$priority" || continue
    found=1
    printf 'batch #%-4s %-9s %s event(s), held %ss of a %ss budget, due in %ss\n' \
      "$FM_BATCH_OPEN_BSEQ" "$priority" "$FM_BATCH_OPEN_COUNT" \
      "$((now - FM_BATCH_OPEN_OLDEST))" "$(fm_batch_delay "$priority")" \
      "$((FM_BATCH_OPEN_DEADLINE - now))"
  done < <(fm_batch_open_priorities)
  [ "$found" -eq 1 ] || printf 'nothing is being held\n'
  return 0
}

render_batches() {  # reads records on stdin
  if [ "$raw" = true ]; then
    cat
    return 0
  fi
  LC_ALL=C awk -F '\t' '
    {
      printf "#%s  %s  %-9s %-9s %s event(s)  journal %s-%s\n", \
        $1, strftime("%Y-%m-%d %H:%M:%S", $5 + 0), $2, $7, $8, $9, $10
      printf "      opened %s, oldest event arrived %s, due %s\n", \
        strftime("%H:%M:%S", $3 + 0), strftime("%H:%M:%S", $4 + 0), strftime("%H:%M:%S", $6 + 0)
      printf "      held %ss\n\n", $5 - $4
    }
  '
}

render_members() {  # reads records on stdin
  if [ "$raw" = true ]; then
    cat
    return 0
  fi
  LC_ALL=C awk -F '\t' '
    { printf "  journal %-6s %-9s %-9s %s\n", $4, $3, $6, $8 }
  '
}

# --- commands ---------------------------------------------------------------

case "$cmd" in
  run)
    mkdir -p "$FM_BATCH_DIR" 2>/dev/null || {
      echo "fm-event-batch.sh: cannot create $FM_BATCH_DIR" >&2
      exit 1
    }
    # One batcher per home. Two would admit the same events twice and interleave
    # their cursors; refusing is cheaper to understand than reconciling that.
    if ! fm_lock_try_acquire "$FM_BATCH_RUN_LOCK"; then
      echo "fm-event-batch.sh: a batcher is already running in this home" >&2
      exit 1
    fi

    started=$(fm_batch_now)
    passes=0
    admitted=0
    closed=0

    finish() {
      fm_batch_health_write stopped "$started" "$passes" "$admitted" "$closed" || true
      fm_lock_release "$FM_BATCH_RUN_LOCK"
    }
    trap 'finish; exit 0' INT TERM
    trap 'fm_lock_release "$FM_BATCH_RUN_LOCK"' EXIT

    printf 'fm-event-batch: grouping (immediate %ss, high %ss, normal %ss, low %ss; interval %ss).\n' \
      "$FM_BATCH_DELAY_IMMEDIATE" "$FM_BATCH_DELAY_HIGH" "$FM_BATCH_DELAY_NORMAL" \
      "$FM_BATCH_DELAY_LOW" "$FM_BATCH_INTERVAL"
    printf 'It groups and holds; it decides nothing about what reaches a supervisor.\n'

    while :; do
      if fm_batch_pass; then
        admitted=$((admitted + FM_BATCH_PASS_ADMITTED))
        closed=$((closed + FM_BATCH_PASS_CLOSED))
      else
        printf 'fm-event-batch: a pass could not run; the journal cursor did not move\n' >&2
      fi
      passes=$((passes + 1))
      # Written on EVERY pass, admitted or not: a beacon that only ticks when
      # there is work cannot prove a batcher holding a quiet fleet is alive.
      fm_batch_health_write running "$started" "$passes" "$admitted" "$closed" || true
      [ "$once" = true ] && break
      # Never sleep past a deadline: an open batch is due when its budget says
      # so, not when the poll happens to come round again.
      sleep "$(fm_batch_next_wait)"
    done

    if [ "$once" = true ]; then
      finish
    fi
    ;;

  status)
    print_status
    exit $?
    ;;

  open)
    print_open
    ;;

  batches)
    fm_batch_cat_batches | LC_ALL=C awk -F '\t' \
      -v since="$since" -v only="$only" -v limit="${limit:-0}" '
      NF >= 10 && $1 + 0 > since && (only == "" || $2 == only) {
        if (limit > 0 && ++shown > limit) { exit }
        print
      }
    ' | render_batches
    ;;

  show)
    case "$target" in
      ''|*[!0-9]*) echo "fm-event-batch.sh: show needs a batch sequence number" >&2; exit 2 ;;
    esac
    fm_batch_cat_members | LC_ALL=C awk -F '\t' -v want="$target" 'NF >= 8 && $2 + 0 == want + 0' \
      | render_members
    ;;

  flush)
    mkdir -p "$FM_BATCH_DIR" "$FM_BATCH_OPEN_DIR" 2>/dev/null || exit 1
    fm_lock_acquire_wait "$FM_BATCH_LOCK" || {
      echo "fm-event-batch.sh: could not take this home's batch lock" >&2
      exit 1
    }
    FM_BATCH_CLOSED=0
    fm_batch_close_all flush
    fm_lock_release "$FM_BATCH_LOCK"
    [ "$FM_BATCH_CLOSED" -gt 0 ] || printf 'nothing was open to close\n'
    ;;

  account)
    run_account
    exit $?
    ;;

  delays)
    for priority in $FM_BATCH_PRIORITIES; do
      printf '%-9s %6ss  (%s)\n' "$priority" "$(fm_batch_delay "$priority")" \
        "$(fm_batch_delay_source "$priority")"
    done
    ;;

  *)
    echo "fm-event-batch.sh: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
