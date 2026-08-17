#!/usr/bin/env bash
# The bosun's observer tier: it reads the event journal, forms a judgement about
# each event, and records that judgement where a human can watch it.
#
# IT HAS AUTHORITY OVER NOTHING.
# Nothing this file writes changes what surfaces to a supervising session. It
# does not queue a wake, does not drain one, does not suppress one, does not
# write a task's status file, and does not send anything anywhere. Its entire
# output is a record under $STATE/bosun/, and the only thing that reads that
# record today is a human looking at it. That is deliberate and it is the whole
# shape of this unit: a judging tier is worth nothing until its judgements can be
# read back and disagreed with, so the judgements come first and the authority
# comes later, in a separate unit, on the captain's word.
#
# WHY A SEPARATE TIER AT ALL
# docs/supervision-cost.md measures a surfaced wake at a median 171,216 fresh
# tokens, against roughly 207 for the mechanical arm that waits for one. The cost
# is dominated by the size of the conversation a notification lands in, not by
# the number of notifications. A tier that can read the journal and record a
# judgement without waking that conversation is therefore the cheap place to put
# judgement - and this is a LATENCY-AND-ATTENTION programme, not a cost one
# (the captain settled that on 2026-08-12). No claim here is a saving.
#
# VERDICT RECORD FORMAT
# One record per line, eleven tab-separated fields, written once and never
# rewritten, under $STATE/bosun/:
#   vseq        verdict sequence, monotonic within a home, allocated under the
#               bosun lock. Judgement order IS ascending vseq.
#   epoch       when the verdict was recorded.
#   jseq        the journal sequence of the event judged, so a verdict and the
#               event it describes can be matched without guessing. For a verdict
#               about the stream itself rather than about one event, the highest
#               journal sequence the record concerns.
#   kind        the judged event's kind, verbatim from the journal. The value
#               "journal" marks a verdict about the STREAM rather than about an
#               event in it - see fm_bosun_judge_horizon.
#   key         the judged event's key, verbatim from the journal.
#   event       what was judged, as the journal held it: the payload, and the
#               arrival-time state capture appended after " | " when the journal
#               carried one. Copied into this record on purpose rather than left
#               as a pointer, because the journal has a retention horizon and a
#               verdict whose subject has aged out is not a record anyone can
#               read back.
#   verdict     escalate | routine. See FAILING TOWARD ESCALATION.
#   confidence  high | low, as the judge reported it.
#   reason      why, in one line. On any failure to judge, the failure itself.
#   judge       what produced the verdict: the judge identity it reported, or one
#               of the fm_bosun_judge failure identities, so a run judged by a
#               model and a run judged by the failure path are never confused.
#   elapsed_ms  how long the judgement took, in milliseconds.
# No field can contain a tab, a carriage return, or a newline: every field goes
# through fm_wake_clean_field on the way in, the same cleaning the wake queue and
# the journal already apply, so one line is always one whole record.
#
# FAILING TOWARD ESCALATION
# A bosun that cannot be reached, cannot judge, or is unsure must cause the event
# to be treated as if it needed a human. In this observer form that is a RECORDED
# verdict of "escalate", never a dropped row. Every path that fails to obtain a
# usable verdict - a missing judge command, a timeout, a non-zero exit, output
# that is not one JSON object, a missing or unknown verdict value - returns
# escalate with the failure as its reason. A judge that answers "routine" with
# low confidence is also recorded as escalate, with its own answer preserved in
# the reason, because unsure is not the same as safe. A retained journal that
# exists but cannot be read likewise produces a stream-level escalation rather
# than being mistaken for an empty stream.
#
# NEVER A DROPPED ROW
# The cursor advances only after a verdict record reaches disk. A pass that dies
# between judging and recording re-judges that event on the next pass; the cost
# of that is one duplicate judgement, and the cost of the other order is a
# silently unjudged event, which is the failure this tier exists against.
# Events that fell below the journal's retention horizon before they were reached
# are also escalated rather than skipped (fm_bosun_judge_horizon).
#
# QUIET IS NOT DEAD
# The defect this fleet named on 2026-08-12 - a run alive, its log growing, and
# no work produced for seventeen hours - is a health question no process-liveness
# check answers. fm_bosun_health_write records, every pass, both that the pass
# HAPPENED and whether the cursor MOVED, plus the epoch at which the cursor first
# fell behind an advancing journal without moving (backlog_since). Those two
# together are what let bin/fm-bosun.sh separate a bosun that is quiet because
# nothing arrived from one that is stalled because it stopped consuming what did.

FM_BOSUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_JOURNAL_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-journal-lib.sh
  . "$FM_BOSUN_LIB_DIR/fm-journal-lib.sh"
fi

FM_BOSUN_DIR="${FM_BOSUN_DIR:-$STATE/bosun}"
FM_BOSUN_ACTIVE="$FM_BOSUN_DIR/verdicts.tsv"
FM_BOSUN_PREVIOUS="$FM_BOSUN_DIR/verdicts.previous.tsv"
FM_BOSUN_LOCK="$FM_BOSUN_DIR/.lock"
# shellcheck disable=SC2034 # Held by bin/fm-bosun.sh's run command, not here.
FM_BOSUN_RUN_LOCK="$FM_BOSUN_DIR/.run.lock"
FM_BOSUN_SEQ_FILE="$FM_BOSUN_DIR/.seq"
FM_BOSUN_CURSOR_FILE="$FM_BOSUN_DIR/.cursor"
FM_BOSUN_HEALTH="$FM_BOSUN_DIR/health"

# The judge is a COMMAND, not a hard-coded provider, and this is the seam the
# model choice rides on. It is handed one event on stdin and must print one JSON
# object on stdout. Swapping the pilot model in later is therefore writing a new
# command, not editing this file - which matters, because the model shipped here
# is provisional (docs/bosun-observer.md records why, and what it is not).
FM_BOSUN_JUDGE_CMD="${FM_BOSUN_JUDGE_CMD:-}"
FM_BOSUN_JUDGE_TIMEOUT="${FM_BOSUN_JUDGE_TIMEOUT:-45}"
# The journal command is reached through this COMMAND only: the retention
# horizon, the batch, and both command readings status takes append their own
# subcommand and flags to this prefix. It is one seam rather than four hard-wired
# paths so a caller can put a different journal underneath the bosun and have the
# WHOLE module query it; two halves querying two different journals would report
# against each other, which is strictly worse than uniform hard-wiring. Like the
# judge, it is a command line, so a caller may configure one carrying its own
# arguments. fm_bosun_journal_unreadable separately inspects the retained files'
# readability and deliberately does not invoke the journal command.
FM_BOSUN_JOURNAL_CMD="${FM_BOSUN_JOURNAL_CMD:-$FM_BOSUN_LIB_DIR/fm-journal.sh}"
# Seconds between passes when running continuously.
FM_BOSUN_INTERVAL="${FM_BOSUN_INTERVAL:-30}"
# Most events one pass will judge. A bound on the pass, not a batching policy:
# batching notifications is a separate filed unit and nothing here takes a
# position on it. Its only job is to stop one pass from running unboundedly long
# against a journal that grew while the bosun was down.
FM_BOSUN_PASS_MAX="${FM_BOSUN_PASS_MAX:-20}"
# How long the cursor may sit behind an advancing journal without moving before
# the bosun is called stalled rather than merely behind.
FM_BOSUN_STALL_AFTER="${FM_BOSUN_STALL_AFTER:-300}"
# Passes' worth of silence before a bosun with no exit record is called dead.
FM_BOSUN_DEAD_PASSES="${FM_BOSUN_DEAD_PASSES:-3}"
# Same per-field cap discipline the journal applies, so one pathological payload
# cannot bury every other record behind itself.
FM_BOSUN_FIELD_BYTES="${FM_BOSUN_FIELD_BYTES:-4096}"
FM_BOSUN_MAX_BYTES="${FM_BOSUN_MAX_BYTES:-8388608}"

fm_bosun_default_judge() {
  printf '%s\n' "$FM_BOSUN_LIB_DIR/fm-bosun-judge-codex.sh"
}

fm_bosun_judge_command() {
  local configured
  if [ -n "$FM_BOSUN_JUDGE_CMD" ]; then
    printf '%s\n' "$FM_BOSUN_JUDGE_CMD"
    return 0
  fi
  configured="${FM_HOME:-}/config/bosun-judge"
  if [ -r "$configured" ]; then
    # First non-empty, non-comment line. A home names its own judge here.
    configured=$(grep -v '^[[:space:]]*#' "$configured" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
    if [ -n "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
  fi
  fm_bosun_default_judge
}

fm_bosun_cap_field() {  # <text> -> capped text on stdout
  local text=$1 marker=' [truncated]' keep
  local LC_ALL=C
  if [ "${#text}" -le "$FM_BOSUN_FIELD_BYTES" ]; then
    printf '%s' "$text"
    return 0
  fi
  keep=$((FM_BOSUN_FIELD_BYTES - ${#marker}))
  [ "$keep" -gt 0 ] || keep=0
  printf '%s%s' "${text:0:$keep}" "$marker"
}

fm_bosun_read_number() {  # <file> <default>
  local value
  value=$(cat "$1" 2>/dev/null || printf '%s' "$2")
  case "$value" in ''|*[!0-9]*) value=$2 ;; esac
  printf '%s' "$value"
}

fm_bosun_cursor() {
  fm_bosun_read_number "$FM_BOSUN_CURSOR_FILE" 0
}

# Rotate the active verdict file over the single previous one at the size bound.
# Same crude bound as the journal's, and the same honesty about it: this is a
# size bound so a long-running observer cannot fill a supervision host, not a
# retention policy. Called with the bosun lock held.
fm_bosun_rotate_if_full() {
  local size
  [ -f "$FM_BOSUN_ACTIVE" ] || return 0
  size=$(wc -c < "$FM_BOSUN_ACTIVE" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$FM_BOSUN_MAX_BYTES" ] || return 0
  mv -f "$FM_BOSUN_ACTIVE" "$FM_BOSUN_PREVIOUS" 2>/dev/null || return 1
  return 0
}

# Append one verdict and advance the cursor to the event it judged, both under
# one lock. Returns 0 only when the record reached disk; the caller must not
# advance past an event whose verdict did not.
fm_bosun_record() {  # <jseq> <kind> <key> <event> <verdict> <confidence> <reason> <judge> <elapsed_ms>
  local jseq=$1 kind=$2 key=$3 event=$4 verdict=$5 confidence=$6 reason=$7 judge=$8 elapsed=$9
  local seq status=0 epoch

  epoch=$(date +%s)
  kind=$(printf '%s' "$kind" | fm_wake_clean_field)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  event=$(fm_bosun_cap_field "$(printf '%s' "$event" | fm_wake_clean_field)")
  reason=$(fm_bosun_cap_field "$(printf '%s' "$reason" | fm_wake_clean_field)")
  judge=$(printf '%s' "$judge" | fm_wake_clean_field)
  case "$elapsed" in ''|*[!0-9]*) elapsed=0 ;; esac

  mkdir -p "$FM_BOSUN_DIR" 2>/dev/null || return 1
  fm_lock_acquire_wait "$FM_BOSUN_LOCK" || return 1

  fm_bosun_rotate_if_full || status=1
  if [ "$status" -eq 0 ]; then
    seq=$(fm_bosun_read_number "$FM_BOSUN_SEQ_FILE" 0)
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$FM_BOSUN_SEQ_FILE" 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$seq" "$epoch" "$jseq" "$kind" "$key" "$event" \
      "$verdict" "$confidence" "$reason" "$judge" "$elapsed" \
      >> "$FM_BOSUN_ACTIVE" 2>/dev/null || status=1
  fi
  # The cursor moves only behind a record that reached disk. Advancing first
  # would turn a failed append into a silently unjudged event.
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$jseq" > "$FM_BOSUN_CURSOR_FILE" 2>/dev/null || status=1
  fi

  fm_lock_release "$FM_BOSUN_LOCK"
  return "$status"
}

fm_bosun_cat() {
  [ -f "$FM_BOSUN_PREVIOUS" ] && cat "$FM_BOSUN_PREVIOUS"
  [ -f "$FM_BOSUN_ACTIVE" ] && cat "$FM_BOSUN_ACTIVE"
  return 0
}

# --- judging ----------------------------------------------------------------

# The prompt the judge is handed. Deliberately short and deliberately one-sided:
# it asks only whether a human supervisor needs to look NOW, and it tells the
# judge which way to fall when unsure. It carries no fleet-private strategy and
# no project content beyond the event text the journal already holds.
fm_bosun_prompt() {  # <kind> <key> <event>
  cat <<PROMPT
You are judging one notification event from a software fleet's supervision log.

Event kind: $1
Event key: $2
Event text: $3

Decide whether a human supervisor must look at this event NOW.
Answer "escalate" if it reports a failure, a blocker, a decision someone must
make, a request for a credential, finished work awaiting review, or anything
destructive, irreversible, or security-sensitive.
Answer "routine" only for ordinary progress that needs no human.
If you are unsure, say so with low confidence: unsure is treated as escalate.
Give one short sentence of reasoning.
PROMPT
}

# Judge one event. ALWAYS succeeds in producing a verdict: every failure path
# returns escalate with the failure as its reason, because a bosun that cannot
# judge must not be a bosun that goes quiet.
#
# Sets FM_BOSUN_VERDICT, FM_BOSUN_CONFIDENCE, FM_BOSUN_REASON, FM_BOSUN_JUDGE,
# and FM_BOSUN_ELAPSED_MS. Returns 0 always; read the fields.
FM_BOSUN_VERDICT=
FM_BOSUN_CONFIDENCE=
FM_BOSUN_REASON=
FM_BOSUN_JUDGE=
FM_BOSUN_ELAPSED_MS=0
fm_bosun_judge() {  # <kind> <key> <event>
  local kind=$1 key=$2 event=$3
  local cmd raw rc start end parsed verdict confidence reason identity

  FM_BOSUN_VERDICT=escalate
  FM_BOSUN_CONFIDENCE=low
  FM_BOSUN_REASON=
  FM_BOSUN_JUDGE=
  FM_BOSUN_ELAPSED_MS=0

  cmd=$(fm_bosun_judge_command)
  start=$(date +%s%N 2>/dev/null || echo 0)

  # A judge that is not there is the single most likely reachability failure, and
  # it must read as an escalation rather than as an error the caller can skip.
  if ! command -v "${cmd%% *}" >/dev/null 2>&1 && [ ! -x "${cmd%% *}" ]; then
    FM_BOSUN_JUDGE=unreachable
    FM_BOSUN_REASON="judge command not available: $cmd"
    return 0
  fi

  # Deliberately unquoted: a judge is a COMMAND LINE, so a home may configure one
  # with its own arguments (a curl wrapper and its endpoint, a model flag).
  # shellcheck disable=SC2086
  raw=$(fm_bosun_prompt "$kind" "$key" "$event" \
    | timeout "$FM_BOSUN_JUDGE_TIMEOUT" $cmd 2>/dev/null)
  rc=$?
  end=$(date +%s%N 2>/dev/null || echo 0)
  if [ "$start" != 0 ] && [ "$end" != 0 ]; then
    FM_BOSUN_ELAPSED_MS=$(( (end - start) / 1000000 ))
  fi

  if [ "$rc" -eq 124 ]; then
    FM_BOSUN_JUDGE=timeout
    FM_BOSUN_REASON="judge did not answer within ${FM_BOSUN_JUDGE_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    FM_BOSUN_JUDGE=failed
    FM_BOSUN_REASON="judge exited $rc"
    return 0
  fi

  parsed=$(printf '%s' "$raw" | jq -sr '
    if length == 1 and (.[0] | type) == "object" then
      .[0] | [ (.verdict // ""), (.confidence // ""), (.reason // ""), (.judge // "") ]
      | @tsv
    else empty end' 2>/dev/null)
  if [ -z "$parsed" ]; then
    FM_BOSUN_JUDGE=unparsed
    FM_BOSUN_REASON="judge did not return exactly one JSON object"
    return 0
  fi

  IFS=$'\t' read -r verdict confidence reason identity <<< "$parsed"
  [ -n "$identity" ] || identity=unnamed
  FM_BOSUN_JUDGE=$identity
  [ -n "$reason" ] || reason="judge gave no reason"

  case "$confidence" in
    high|low) ;;
    *) confidence=low ;;
  esac
  FM_BOSUN_CONFIDENCE=$confidence

  case "$verdict" in
    escalate)
      FM_BOSUN_VERDICT=escalate
      FM_BOSUN_REASON=$reason
      ;;
    routine)
      if [ "$confidence" = low ]; then
        # Unsure is not safe. The judge's own answer is preserved in the reason
        # so the record stays honest about what was overridden and why.
        FM_BOSUN_VERDICT=escalate
        FM_BOSUN_REASON="unsure, escalated (judge said routine): $reason"
      else
        FM_BOSUN_VERDICT=routine
        FM_BOSUN_REASON=$reason
      fi
      ;;
    *)
      FM_BOSUN_VERDICT=escalate
      FM_BOSUN_REASON="judge returned an unknown verdict '$verdict': $reason"
      ;;
  esac
  return 0
}

# --- the pass ---------------------------------------------------------------

# Events that fell below the journal's retention horizon before this bosun
# reached them existed and will never be judged. That is exactly the case the
# escalation bias is for: record one verdict naming the range, rather than
# letting the cursor jump the gap in silence.
fm_bosun_judge_horizon() {  # <horizon> -> 0 if a record was written
  local horizon=$1 cursor missed
  cursor=$(fm_bosun_cursor)
  [ "$horizon" -gt $((cursor + 1)) ] || return 1
  missed=$((horizon - cursor - 1))
  fm_bosun_record "$((horizon - 1))" journal journal-horizon \
    "events $((cursor + 1))-$((horizon - 1)) fell below the journal's retention horizon" \
    escalate high \
    "$missed event(s) aged out of the journal before they were judged and can never be judged" \
    horizon 0
}

fm_bosun_judge_journal_unreadable() {
  local cursor
  cursor=$(fm_bosun_cursor)
  fm_bosun_record "$cursor" journal journal-unreadable \
    "the retained journal stream could not be read" \
    escalate high \
    "the journal stream could not be read, so events may exist that were never judged" \
    journal 0
}

fm_bosun_journal_unreadable() {
  if [ -d "$FM_JOURNAL_DIR" ] && { [ ! -r "$FM_JOURNAL_DIR" ] || [ ! -x "$FM_JOURNAL_DIR" ]; }; then
    return 0
  fi
  [ -e "$FM_JOURNAL_ACTIVE" ] && [ ! -r "$FM_JOURNAL_ACTIVE" ] && return 0
  [ -e "$FM_JOURNAL_PREVIOUS" ] && [ ! -r "$FM_JOURNAL_PREVIOUS" ] && return 0
  return 1
}

# Run one pass: judge every journal record above the cursor, up to the pass
# bound. Prints one human-readable line per verdict on stdout, so a foreground
# run is watchable as it happens rather than only in the record afterwards.
# Sets FM_BOSUN_PASS_JUDGED to how many verdicts it recorded.
# shellcheck disable=SC2034 # Read by bin/fm-bosun.sh's run loop.
FM_BOSUN_PASS_JUDGED=0
fm_bosun_pass() {
  local since jseq kind key event payload snapshot horizon
  local judged=0

  FM_BOSUN_PASS_JUDGED=0

  if fm_bosun_journal_unreadable; then
    if fm_bosun_judge_journal_unreadable; then
      judged=$((judged + 1))
      printf '%s  %-8s %-9s %s: %s\n' \
        "$(date +%H:%M:%S)" escalate high journal-unreadable \
        "the journal stream could not be read, so events may exist that were never judged"
    else
      printf 'fm-bosun: could not record that the journal stream was unreadable\n' >&2
    fi
    FM_BOSUN_PASS_JUDGED=$judged
    return 0
  fi

  # shellcheck disable=SC2086 # A command PREFIX; see FM_BOSUN_JOURNAL_CMD.
  horizon=$($FM_BOSUN_JOURNAL_CMD status 2>/dev/null \
    | awk -F': ' '$1 == "horizon" { print $2 }')
  case "$horizon" in
    ''|*[!0-9]*) : ;;
    *) fm_bosun_judge_horizon "$horizon" && judged=$((judged + 1)) ;;
  esac

  since=$(fm_bosun_cursor)
  # Read into a temp file rather than a pipe: the loop below must run in this
  # shell so the cursor it reads back is the one the record just wrote.
  local batch
  batch=$(mktemp "${TMPDIR:-/tmp}/fm-bosun-pass.XXXXXX") || return 1
  # shellcheck disable=SC2086 # A command PREFIX; see FM_BOSUN_JOURNAL_CMD.
  $FM_BOSUN_JOURNAL_CMD read --since "$since" --limit "$FM_BOSUN_PASS_MAX" \
    > "$batch" 2>/dev/null

  while IFS=$'\t' read -r jseq _epoch kind key _origin payload snapshot; do
    [ -n "$jseq" ] || continue
    case "$jseq" in *[!0-9]*) continue ;; esac
    event=$payload
    [ -z "$snapshot" ] || event="$payload | $snapshot"

    fm_bosun_judge "$kind" "$key" "$event"
    if fm_bosun_record "$jseq" "$kind" "$key" "$event" \
      "$FM_BOSUN_VERDICT" "$FM_BOSUN_CONFIDENCE" "$FM_BOSUN_REASON" \
      "$FM_BOSUN_JUDGE" "$FM_BOSUN_ELAPSED_MS"; then
      judged=$((judged + 1))
      printf '%s  %-8s %-9s %s: %s\n' \
        "$(date +%H:%M:%S)" "$FM_BOSUN_VERDICT" "$FM_BOSUN_CONFIDENCE" "$key" "$FM_BOSUN_REASON"
    else
      # The cursor did not move, so this event is judged again next pass. Say so
      # loudly: a bosun whose record is failing is not a bosun anyone should
      # read as quiet.
      printf 'fm-bosun: could not record the verdict for journal event %s; it will be judged again\n' \
        "$jseq" >&2
      break
    fi
  done < "$batch"
  rm -f "$batch"

  # shellcheck disable=SC2034 # Read by bin/fm-bosun.sh's run loop.
  FM_BOSUN_PASS_JUDGED=$judged
  return 0
}

# --- health -----------------------------------------------------------------

fm_bosun_journal_last() {
  # shellcheck disable=SC2086 # A command PREFIX; see FM_BOSUN_JOURNAL_CMD.
  $FM_BOSUN_JOURNAL_CMD status 2>/dev/null \
    | awk -F': ' '$1 == "last" && $2 ~ /^[0-9]+$/ { print $2 }'
}

fm_bosun_journal_gaps() {
  # shellcheck disable=SC2086 # A command PREFIX; see FM_BOSUN_JOURNAL_CMD.
  $FM_BOSUN_JOURNAL_CMD status 2>/dev/null \
    | awk -F': ' '$1 == "gaps" && $2 ~ /^[0-9]+$/ { print $2 }'
}

fm_bosun_health_field() {  # <name>
  awk -F': ' -v want="$1" '$1 == want { print $2; exit }' "$FM_BOSUN_HEALTH" 2>/dev/null
}

# Write the health record. Called at the END of every pass INCLUDING a pass that
# judged nothing, because a beacon that only ticks when there is work cannot tell
# quiet from dead - which is the entire defect this record exists to make
# visible.
#
# backlog_since is the discriminator between behind and stalled: it is stamped
# the first time the cursor sits below the journal's head without having moved,
# and cleared the moment it moves. A cursor that is behind and advancing is
# working; a cursor that is behind and frozen while the journal grows is the
# seventeen-hour failure, and it is visible here with no process inspection.
# The stall clock deliberately survives a restart. A fresh run inherits the
# backlog_since a dead one left, because the events it names have genuinely gone
# unjudged for that long and clearing it on every start would make a bosun that
# crash-loops - restarting, writing a fresh beacon, judging nothing, dying -
# unable to ever report STALLED. It clears the moment the cursor moves, which is
# the evidence that actually settles it.
fm_bosun_health_write() {  # <state> <started> <passes> <verdicts> <last_judged> <cursor_before>
  local run_state=$1 started=$2 passes=$3 verdicts=$4 last_judged=$5 cursor_before=$6
  local now cursor journal_last backlog_since tmp
  now=$(date +%s)
  cursor=$(fm_bosun_cursor)
  journal_last=$(fm_bosun_journal_last)
  case "$journal_last" in ''|*[!0-9]*) journal_last=0 ;; esac

  backlog_since=$(fm_bosun_health_field backlog_since)
  case "$backlog_since" in ''|*[!0-9]*) backlog_since=0 ;; esac
  if [ "$cursor" != "$cursor_before" ] || [ "$journal_last" -le "$cursor" ]; then
    backlog_since=0
  elif [ "$backlog_since" -eq 0 ]; then
    backlog_since=$now
  fi

  mkdir -p "$FM_BOSUN_DIR" 2>/dev/null || return 1
  tmp="$FM_BOSUN_HEALTH.$$"
  {
    printf 'state: %s\n' "$run_state"
    printf 'pid: %s\n' "${BASHPID:-$$}"
    printf 'started: %s\n' "$started"
    printf 'last_pass: %s\n' "$now"
    # Scoped in the name: these count THIS run, and the totals on disk are
    # reported separately by fm-bosun.sh status. An unqualified "verdicts: 0"
    # sitting above a lifetime count of 4 reads as a contradiction.
    printf 'passes_this_run: %s\n' "$passes"
    printf 'verdicts_this_run: %s\n' "$verdicts"
    printf 'last_judged: %s\n' "$last_judged"
    printf 'cursor: %s\n' "$cursor"
    printf 'journal_last: %s\n' "$journal_last"
    printf 'backlog_since: %s\n' "$backlog_since"
    printf 'interval: %s\n' "$FM_BOSUN_INTERVAL"
    printf 'judge: %s\n' "$(fm_bosun_judge_command)"
  } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$FM_BOSUN_HEALTH" 2>/dev/null || return 1
  return 0
}
