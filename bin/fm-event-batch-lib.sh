#!/usr/bin/env bash
# The event batcher: it groups journal events into batches by priority, holds
# each batch for a bounded time, and records what it grouped.
#
# IT DECIDES NOTHING ABOUT WHAT REACHES A SUPERVISOR.
# It is timing and grouping only. It does not judge, suppress, drop, downgrade,
# dedupe, or reorder an event, it does not queue or drain a wake, and it does not
# write a task's status file. Whether a batch's contents are worth a supervisor's
# attention is a separate unit's question; docs/bosun-observer.md's judging tier
# is where that judgement lives. This one only answers "which events travel
# together, and how long may they wait".
#
# WHERE IT SITS
# It reads docs/event-journal.md's append-only journal, the same stream the bosun
# reads, and it writes its own record under $STATE/batches/. Neither neighbour is
# duplicated here: the journal owns the record of what arrived, the bosun owns
# the record of what was judged, and this owns the record of what was grouped.
# Each keeps its own cursor, so pointing this at the journal changes nothing
# about the bosun's reading of it.
#
# BATCHING DELAYS - THE CAPTAIN'S NUMBERS
#   immediate  no delay at all - the batch closes in the pass that admits it
#   high       at most 60 seconds
#   normal     at most 120 seconds
#   low        at most 600 seconds
# These are the captain's values, shipped as the defaults. A home overrides them
# in config/batch-delays and one run overrides them in the environment; see
# fm_batch_delay below and docs/configuration.md "Event batching delays".
#
# THE BUDGET RUNS FROM ARRIVAL, NOT FROM ADMISSION
# A batch's deadline is its OLDEST member's journal arrival epoch plus that
# class's delay - not the moment this process happened to notice the event. The
# poll interval therefore comes out of the budget rather than being added on top
# of it, so "within one minute" is a statement about the event's own age and not
# about how promptly the batcher was running. Every closed batch records both
# epochs, so the hold it actually took is a measurement in the record rather than
# a claim this file makes about itself.
#
# NOTHING IS DROPPED, AND THE TWO HALVES OF THAT ARE DIFFERENT CLAIMS
# 1. An event that reaches a batch CANNOT be dropped by this unit. members.tsv is
#    append-only; no code path here removes, rewrites, filters, or collapses a
#    member record, and closing a batch appends a record elsewhere rather than
#    touching the members. The size cap on a batch CLOSES it early; it never
#    truncates one. The cursor advances only AFTER a member record reaches disk,
#    so a process killed mid-admit re-admits that event and produces a duplicate
#    rather than a hole - the same trade the bosun made, for the same reason.
# 2. An event that reaches the journal and never reaches a batch is LOUDLY
#    VISIBLE. bin/fm-event-batch.sh's `account` command reconciles every retained
#    journal sequence against the member records and exits non-zero naming any
#    sequence that is missing, duplicated, orphaned, aged out, or held past its
#    own budget. A quiet period and a lost notification look identical from the
#    outside, which is exactly why that reconciliation is a command and not a
#    comment.
#
# MEMBER RECORD FORMAT
# One record per line, eight tab-separated fields, written once and never
# rewritten, under $STATE/batches/members.tsv:
#   mseq      member sequence, monotonic within a home, allocated under the batch
#             lock. Admission order IS ascending mseq.
#   bseq      the batch this member belongs to.
#   priority  the timing class this member was admitted under.
#   jseq      the journal sequence of the event, so a member and the journal
#             record it came from can be matched without guessing.
#   arrived   the journal record's own arrival epoch. The budget runs from this.
#   kind      the event kind, verbatim from the journal.
#   key       the event key, verbatim from the journal.
#   event     what was batched, as the journal held it: the payload, and the
#             arrival-time state capture appended after " | " when the journal
#             carried one. Copied rather than left as a pointer, because the
#             journal has a retention horizon and a batch whose contents have
#             aged out is not something a consumer can read.
#
# BATCH RECORD FORMAT
# One record per closed batch, ten tab-separated fields, under batches.tsv:
#   bseq      the batch sequence its members carry.
#   priority  the timing class.
#   opened    epoch the batch opened (when its first member was admitted).
#   oldest    the earliest member's ARRIVAL epoch - the clock the budget ran on.
#   closed    epoch it closed.
#   deadline  the epoch it was due to close (oldest + the class delay).
#   reason    why it closed: immediate | bypass | deadline | full | flush.
#   count     how many members it carries.
#   first_jseq, last_jseq  the journal range it spans.
# The hold a batch actually took is closed - oldest, and its budget is the class
# delay, so `account` checks every closed batch against the captain's numbers
# without trusting anything this file says about itself.
#
# No field in either record can contain a tab, a carriage return, or a newline:
# every field goes through fm_wake_clean_field on the way in, the same cleaning
# the wake queue, the journal, and the bosun already apply, so one line is always
# one whole record.
#
# RETENTION - DELIBERATELY CRUDE, THE SAME BOUND ITS NEIGHBOURS USE
# Two files of FM_BATCH_MAX_BYTES each for members and for batches, so a
# long-running batcher cannot fill a supervision host. It is a size bound and not
# a policy, and `account` reports the horizon it can no longer see below rather
# than presenting a truncated reconciliation as a clean one.

FM_BATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_JOURNAL_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-journal-lib.sh
  . "$FM_BATCH_LIB_DIR/fm-journal-lib.sh"
fi
# bin/fm-classify-lib.sh owns this fleet's status-verb vocabulary. It is sourced
# rather than restated so the classes below key on the same verbs the watcher and
# the away-mode daemon already key on; what is local here is only the mapping of
# those verbs onto TIMING classes, which is a different contract.
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_BATCH_LIB_DIR/fm-classify-lib.sh"

FM_BATCH_DIR="${FM_BATCH_DIR:-$STATE/batches}"
FM_BATCH_MEMBERS="$FM_BATCH_DIR/members.tsv"
FM_BATCH_MEMBERS_PREVIOUS="$FM_BATCH_DIR/members.previous.tsv"
FM_BATCH_BATCHES="$FM_BATCH_DIR/batches.tsv"
FM_BATCH_BATCHES_PREVIOUS="$FM_BATCH_DIR/batches.previous.tsv"
FM_BATCH_OPEN_DIR="$FM_BATCH_DIR/open"
FM_BATCH_LOCK="$FM_BATCH_DIR/.lock"
# shellcheck disable=SC2034 # Held by bin/fm-event-batch.sh's run command, not here.
FM_BATCH_RUN_LOCK="$FM_BATCH_DIR/.run.lock"
FM_BATCH_CURSOR_FILE="$FM_BATCH_DIR/.cursor"
FM_BATCH_MSEQ_FILE="$FM_BATCH_DIR/.mseq"
FM_BATCH_BSEQ_FILE="$FM_BATCH_DIR/.bseq"
FM_BATCH_HEALTH="$FM_BATCH_DIR/health"

# Highest first. The order is load-bearing: the status renderer, `account`, and
# the bypass rule all walk it.
FM_BATCH_PRIORITIES="immediate high normal low"

# Verbs that make a signal immediate: work that has stopped and needs a human.
# Spelled here rather than reused from fm-classify-lib.sh's terminal-verb set
# because this unit splits that set - `done` is finished work, which can travel
# with the next batch, and these three are work that goes nowhere until someone
# acts.
FM_BATCH_VERBS_IMMEDIATE="${FM_BATCH_VERBS_IMMEDIATE:-blocked needs-decision failed}"
# Verbs that make a signal low: ordinary progress and declared waits. Built from
# fm-classify-lib.sh's own constants so the vocabulary keeps one owner.
FM_BATCH_VERBS_LOW="${FM_BATCH_VERBS_LOW:-working ${FM_CLASSIFY_PAUSED_VERB_DEFAULT} ${FM_CLASSIFY_RESOLVE_VERB_DEFAULT} ${FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}}"

# Seconds between passes. This is ADMISSION latency, shared by every class, and
# it is not a batching delay: the budget runs from an event's arrival epoch, so a
# slower poll spends the budget rather than extending it. Kept short because an
# immediate event still has to be noticed before it can be passed straight
# through, and that noticing is the one delay this unit cannot remove.
FM_BATCH_INTERVAL="${FM_BATCH_INTERVAL:-5}"
# Most journal events one pass will admit. A bound on the pass, not on a batch.
FM_BATCH_PASS_MAX="${FM_BATCH_PASS_MAX:-200}"
# Most members one batch may carry. Reaching it CLOSES the batch early so the
# next member opens a fresh one; nothing is ever discarded to stay under it. It
# exists so a downstream consumer is handed a bounded batch rather than an
# unbounded one after a burst.
FM_BATCH_MAX_EVENTS="${FM_BATCH_MAX_EVENTS:-50}"
# Same per-field cap discipline as the journal and the bosun, so one pathological
# payload cannot bury every other record behind itself.
FM_BATCH_FIELD_BYTES="${FM_BATCH_FIELD_BYTES:-4096}"
FM_BATCH_MAX_BYTES="${FM_BATCH_MAX_BYTES:-8388608}"
# Passes' worth of silence before a batcher with no exit record is called dead.
FM_BATCH_DEAD_PASSES="${FM_BATCH_DEAD_PASSES:-3}"

# --- the delays -------------------------------------------------------------

# Where a home names its own numbers: one "name = seconds" per line, blanks and
# # comments ignored. docs/configuration.md owns the schema.
FM_BATCH_DELAY_CONFIG="${FM_BATCH_DELAY_CONFIG:-${FM_HOME:-}/config/batch-delays}"
# Set when a configured or environment delay is not a whole number of seconds.
# bin/fm-event-batch.sh refuses to run on it rather than quietly substituting the
# shipped default, because a home that mistyped its delay would otherwise believe
# it had configured one.
FM_BATCH_CONFIG_ERROR=

# Capture whatever the environment supplied BEFORE any resolution writes to these
# names, so re-sourcing this library resolves identically instead of reading its
# own previous answer back as an environment override.
_FM_BATCH_ENV_IMMEDIATE="${_FM_BATCH_ENV_IMMEDIATE-${FM_BATCH_DELAY_IMMEDIATE:-}}"
_FM_BATCH_ENV_HIGH="${_FM_BATCH_ENV_HIGH-${FM_BATCH_DELAY_HIGH:-}}"
_FM_BATCH_ENV_NORMAL="${_FM_BATCH_ENV_NORMAL-${FM_BATCH_DELAY_NORMAL:-}}"
_FM_BATCH_ENV_LOW="${_FM_BATCH_ENV_LOW-${FM_BATCH_DELAY_LOW:-}}"

_fm_batch_configured_delay() {  # <priority> -> seconds, or empty
  local want=$1 line name value
  [ -r "$FM_BATCH_DELAY_CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    name=${line%%=*}
    value=${line#*=}
    name=${name//[[:space:]]/}
    value=${value//[[:space:]]/}
    [ "$name" = "$want" ] || continue
    printf '%s' "$value"
    return 0
  done < "$FM_BATCH_DELAY_CONFIG"
  return 0
}

# Resolve one class's delay: the environment wins, then this home's config file,
# then the captain's shipped number. Prints "<seconds>\t<source>".
_fm_batch_resolve_delay() {  # <priority> <shipped-default> <environment-value>
  local priority=$1 shipped=$2 value=$3 source=environment
  if [ -z "$value" ]; then
    value=$(_fm_batch_configured_delay "$priority")
    source=config
  fi
  if [ -z "$value" ]; then
    value=$shipped
    source=default
  fi
  case "$value" in
    ''|*[!0-9]*)
      FM_BATCH_CONFIG_ERROR="the $priority delay '$value' from the $source is not a whole number of seconds"
      value=$shipped
      source="rejected-$source"
      ;;
  esac
  printf '%s\t%s' "$value" "$source"
}

_fm_batch_load_delays() {
  local resolved
  resolved=$(_fm_batch_resolve_delay immediate 0 "$_FM_BATCH_ENV_IMMEDIATE")
  IFS=$'\t' read -r FM_BATCH_DELAY_IMMEDIATE FM_BATCH_DELAY_SOURCE_IMMEDIATE <<< "$resolved"
  resolved=$(_fm_batch_resolve_delay high 60 "$_FM_BATCH_ENV_HIGH")
  IFS=$'\t' read -r FM_BATCH_DELAY_HIGH FM_BATCH_DELAY_SOURCE_HIGH <<< "$resolved"
  resolved=$(_fm_batch_resolve_delay normal 120 "$_FM_BATCH_ENV_NORMAL")
  IFS=$'\t' read -r FM_BATCH_DELAY_NORMAL FM_BATCH_DELAY_SOURCE_NORMAL <<< "$resolved"
  resolved=$(_fm_batch_resolve_delay low 600 "$_FM_BATCH_ENV_LOW")
  IFS=$'\t' read -r FM_BATCH_DELAY_LOW FM_BATCH_DELAY_SOURCE_LOW <<< "$resolved"
}

# A command substitution runs in a subshell, so FM_BATCH_CONFIG_ERROR set inside
# _fm_batch_resolve_delay would die with it. Re-derive the rejection here, from
# the source labels the resolution actually produced, so the refusal survives.
_fm_batch_note_rejected_delays() {
  local priority source
  for priority in $FM_BATCH_PRIORITIES; do
    source=$(fm_batch_delay_source "$priority")
    case "$source" in
      rejected-*)
        # shellcheck disable=SC2034 # Read by bin/fm-event-batch.sh before it runs.
        FM_BATCH_CONFIG_ERROR="the $priority delay from the ${source#rejected-} is not a whole number of seconds"
        return 0
        ;;
    esac
  done
  return 0
}

fm_batch_delay() {  # <priority> -> seconds
  case "$1" in
    immediate) printf '%s' "$FM_BATCH_DELAY_IMMEDIATE" ;;
    high)      printf '%s' "$FM_BATCH_DELAY_HIGH" ;;
    normal)    printf '%s' "$FM_BATCH_DELAY_NORMAL" ;;
    low)       printf '%s' "$FM_BATCH_DELAY_LOW" ;;
    *)         printf '%s' "$FM_BATCH_DELAY_NORMAL" ;;
  esac
}

fm_batch_delay_source() {  # <priority> -> environment | config | default | rejected-*
  case "$1" in
    immediate) printf '%s' "$FM_BATCH_DELAY_SOURCE_IMMEDIATE" ;;
    high)      printf '%s' "$FM_BATCH_DELAY_SOURCE_HIGH" ;;
    normal)    printf '%s' "$FM_BATCH_DELAY_SOURCE_NORMAL" ;;
    low)       printf '%s' "$FM_BATCH_DELAY_SOURCE_LOW" ;;
    *)         printf '%s' unknown ;;
  esac
}

FM_BATCH_DELAY_SOURCE_IMMEDIATE=
FM_BATCH_DELAY_SOURCE_HIGH=
FM_BATCH_DELAY_SOURCE_NORMAL=
FM_BATCH_DELAY_SOURCE_LOW=
_fm_batch_load_delays
_fm_batch_note_rejected_delays

# --- the clock --------------------------------------------------------------

# Every time this unit asks what time it is, it asks here. FM_BATCH_CLOCK_FILE
# points that question at a file holding an epoch, which is how the suite
# measures a ten-minute budget against the REAL shipped defaults without waiting
# ten minutes. The seam is not a way around the measurement: a separate case runs
# with no clock file at all and proves a batch closes on real elapsed wall time,
# so the controlled-clock cases are measuring the arithmetic the fleet runs on
# rather than a fiction.
fm_batch_now() {
  local override
  if [ -n "${FM_BATCH_CLOCK_FILE:-}" ] && [ -r "$FM_BATCH_CLOCK_FILE" ]; then
    override=$(cat "$FM_BATCH_CLOCK_FILE" 2>/dev/null || true)
    case "$override" in
      ''|*[!0-9]*) : ;;
      *) printf '%s' "$override"; return 0 ;;
    esac
  fi
  date +%s
}

# --- classification ---------------------------------------------------------

# Map one journal event onto a TIMING class. This decides how long an event may
# be held and nothing else: no class suppresses an event, and no class is a
# statement that a supervisor should or should not see it.
#
# For a signal the class comes from the leading verb of the status line the
# journal captured at arrival, read through fm-classify-lib.sh's own verb reader,
# so a nonterminal line is never promoted by prose that happens to contain a
# terminal word ("working: rebased onto merged #76" is progress, not a merge).
fm_batch_priority() {  # <kind> <payload> <snapshot> -> class on stdout
  local kind=$1 payload=$2 snapshot=$3 line verb
  case "$kind" in
    heartbeat) printf 'low'; return 0 ;;
    stale)     printf 'high'; return 0 ;;
    check)     printf 'normal'; return 0 ;;
  esac
  line=$snapshot
  [ -n "$line" ] || line=$payload
  verb=$(status_line_verb "$line")
  case " $FM_BATCH_VERBS_IMMEDIATE " in *" $verb "*) printf 'immediate'; return 0 ;; esac
  case " $FM_BATCH_VERBS_LOW " in *" $verb "*) printf 'low'; return 0 ;; esac
  # Everything else falls to fm-classify-lib.sh's own captain-relevance test,
  # which also covers the legacy bare lines ("PR ready", "checks green") that
  # carry no verb at all. An unrecognised line lands in normal rather than low: a
  # line nobody can classify must not be the one held longest.
  if status_is_captain_relevant "$line"; then
    printf 'high'
  else
    printf 'normal'
  fi
  return 0
}

# --- record plumbing --------------------------------------------------------

fm_batch_cap_field() {  # <text> -> capped text on stdout
  local text=$1 marker=' [truncated]' keep
  local LC_ALL=C
  if [ "${#text}" -le "$FM_BATCH_FIELD_BYTES" ]; then
    printf '%s' "$text"
    return 0
  fi
  keep=$((FM_BATCH_FIELD_BYTES - ${#marker}))
  [ "$keep" -gt 0 ] || keep=0
  printf '%s%s' "${text:0:$keep}" "$marker"
}

fm_batch_read_number() {  # <file> <default>
  local value
  value=$(cat "$1" 2>/dev/null || printf '%s' "$2")
  case "$value" in ''|*[!0-9]*) value=$2 ;; esac
  printf '%s' "$value"
}

fm_batch_cursor() {
  fm_batch_read_number "$FM_BATCH_CURSOR_FILE" 0
}

fm_batch_rotate_if_full() {  # <active> <previous>
  local active=$1 previous=$2 size
  [ -f "$active" ] || return 0
  size=$(wc -c < "$active" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$FM_BATCH_MAX_BYTES" ] || return 0
  mv -f "$active" "$previous" 2>/dev/null || return 1
  return 0
}

fm_batch_cat_members() {
  [ -f "$FM_BATCH_MEMBERS_PREVIOUS" ] && cat "$FM_BATCH_MEMBERS_PREVIOUS"
  [ -f "$FM_BATCH_MEMBERS" ] && cat "$FM_BATCH_MEMBERS"
  return 0
}

fm_batch_cat_batches() {
  [ -f "$FM_BATCH_BATCHES_PREVIOUS" ] && cat "$FM_BATCH_BATCHES_PREVIOUS"
  [ -f "$FM_BATCH_BATCHES" ] && cat "$FM_BATCH_BATCHES"
  return 0
}

# --- open batches -----------------------------------------------------------

# The open marker is DERIVED state: everything in it is recoverable from
# members.tsv, which is why it is the only file here rewritten in place. The
# record is the members; this is where the current batch's running totals live
# between passes.
FM_BATCH_OPEN_BSEQ=
FM_BATCH_OPEN_OPENED=
FM_BATCH_OPEN_OLDEST=
FM_BATCH_OPEN_DEADLINE=
FM_BATCH_OPEN_COUNT=
FM_BATCH_OPEN_FIRST_JSEQ=
FM_BATCH_OPEN_LAST_JSEQ=

fm_batch_open_read() {  # <priority> -> 0 when a batch is open
  local priority=$1 file
  file="$FM_BATCH_OPEN_DIR/$priority"
  FM_BATCH_OPEN_BSEQ=
  [ -r "$file" ] || return 1
  IFS=$'\t' read -r FM_BATCH_OPEN_BSEQ FM_BATCH_OPEN_OPENED FM_BATCH_OPEN_OLDEST \
    FM_BATCH_OPEN_DEADLINE FM_BATCH_OPEN_COUNT FM_BATCH_OPEN_FIRST_JSEQ \
    FM_BATCH_OPEN_LAST_JSEQ < "$file" || return 1
  case "$FM_BATCH_OPEN_BSEQ" in ''|*[!0-9]*) FM_BATCH_OPEN_BSEQ=; return 1 ;; esac
  return 0
}

fm_batch_open_write() {  # <priority>
  local priority=$1 tmp
  mkdir -p "$FM_BATCH_OPEN_DIR" 2>/dev/null || return 1
  tmp="$FM_BATCH_OPEN_DIR/.$priority.$$"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$FM_BATCH_OPEN_BSEQ" "$FM_BATCH_OPEN_OPENED" "$FM_BATCH_OPEN_OLDEST" \
    "$FM_BATCH_OPEN_DEADLINE" "$FM_BATCH_OPEN_COUNT" "$FM_BATCH_OPEN_FIRST_JSEQ" \
    "$FM_BATCH_OPEN_LAST_JSEQ" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FM_BATCH_OPEN_DIR/$priority" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

fm_batch_open_priorities() {
  local priority
  for priority in $FM_BATCH_PRIORITIES; do
    [ -r "$FM_BATCH_OPEN_DIR/$priority" ] || continue
    printf '%s\n' "$priority"
  done
}

# --- admitting and closing --------------------------------------------------
#
# Both mutate. Both require the caller to hold FM_BATCH_LOCK.

# How many batches the last close call put on disk. Returned in a global rather
# than on stdout because these functions also PRINT one human-readable line per
# closed batch, so a foreground run is watchable as it happens.
FM_BATCH_CLOSED=0

# Close one open batch. Appends the batch record FIRST and drops the open marker
# second, so a process killed between the two leaves a closed batch that is
# merely still marked open - recoverable, and visible to `account` - rather than
# a batch whose members belong to nothing.
fm_batch_close() {  # <priority> <reason> -> 0 when a record reached disk
  local priority=$1 reason=$2 status=0 now hold
  fm_batch_open_read "$priority" || return 1
  now=$(fm_batch_now)

  mkdir -p "$FM_BATCH_DIR" 2>/dev/null || return 1
  fm_batch_rotate_if_full "$FM_BATCH_BATCHES" "$FM_BATCH_BATCHES_PREVIOUS" || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$FM_BATCH_OPEN_BSEQ" "$priority" "$FM_BATCH_OPEN_OPENED" "$FM_BATCH_OPEN_OLDEST" \
      "$now" "$FM_BATCH_OPEN_DEADLINE" "$reason" "$FM_BATCH_OPEN_COUNT" \
      "$FM_BATCH_OPEN_FIRST_JSEQ" "$FM_BATCH_OPEN_LAST_JSEQ" \
      >> "$FM_BATCH_BATCHES" 2>/dev/null || status=1
  fi
  [ "$status" -eq 0 ] || return 1
  rm -f "$FM_BATCH_OPEN_DIR/$priority" 2>/dev/null || return 1

  hold=0
  case "$FM_BATCH_OPEN_OLDEST" in
    ''|*[!0-9]*) : ;;
    *) hold=$((now - FM_BATCH_OPEN_OLDEST)) ;;
  esac
  printf 'batch #%-4s %-9s %-9s %s event(s), held %ss of a %ss budget\n' \
    "$FM_BATCH_OPEN_BSEQ" "$priority" "$reason" "$FM_BATCH_OPEN_COUNT" \
    "$hold" "$(fm_batch_delay "$priority")"
  FM_BATCH_CLOSED=$((FM_BATCH_CLOSED + 1))
  return 0
}

# Close every open batch. Used by the bypass rule and by `flush`.
fm_batch_close_all() {  # <reason>
  local reason=$1 priority
  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_close "$priority" "$reason" || true
  done < <(fm_batch_open_priorities)
  return 0
}

# Close every open batch whose deadline has passed.
fm_batch_close_due() {
  local priority now
  now=$(fm_batch_now)
  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_open_read "$priority" || continue
    case "$FM_BATCH_OPEN_DEADLINE" in ''|*[!0-9]*) continue ;; esac
    [ "$now" -ge "$FM_BATCH_OPEN_DEADLINE" ] || continue
    fm_batch_close "$priority" deadline || true
  done < <(fm_batch_open_priorities)
  return 0
}

# Admit one journal event into its class's batch. Returns 0 only when the member
# record reached disk; the caller must not advance the cursor past an event whose
# record did not.
fm_batch_admit() {  # <jseq> <arrived> <kind> <key> <event> <priority>
  local jseq=$1 arrived=$2 kind=$3 key=$4 event=$5 priority=$6
  local mseq now status=0

  now=$(fm_batch_now)
  kind=$(printf '%s' "$kind" | fm_wake_clean_field)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  event=$(fm_batch_cap_field "$(printf '%s' "$event" | fm_wake_clean_field)")

  mkdir -p "$FM_BATCH_DIR" "$FM_BATCH_OPEN_DIR" 2>/dev/null || return 1

  if ! fm_batch_open_read "$priority"; then
    FM_BATCH_OPEN_BSEQ=$(fm_batch_read_number "$FM_BATCH_BSEQ_FILE" 0)
    FM_BATCH_OPEN_BSEQ=$((FM_BATCH_OPEN_BSEQ + 1))
    printf '%s\n' "$FM_BATCH_OPEN_BSEQ" > "$FM_BATCH_BSEQ_FILE" 2>/dev/null || return 1
    FM_BATCH_OPEN_OPENED=$now
    FM_BATCH_OPEN_OLDEST=$arrived
    FM_BATCH_OPEN_DEADLINE=$((arrived + $(fm_batch_delay "$priority")))
    FM_BATCH_OPEN_COUNT=0
    FM_BATCH_OPEN_FIRST_JSEQ=$jseq
  fi

  fm_batch_rotate_if_full "$FM_BATCH_MEMBERS" "$FM_BATCH_MEMBERS_PREVIOUS" || status=1
  if [ "$status" -eq 0 ]; then
    mseq=$(fm_batch_read_number "$FM_BATCH_MSEQ_FILE" 0)
    mseq=$((mseq + 1))
    printf '%s\n' "$mseq" > "$FM_BATCH_MSEQ_FILE" 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$mseq" "$FM_BATCH_OPEN_BSEQ" "$priority" "$jseq" "$arrived" "$kind" "$key" "$event" \
      >> "$FM_BATCH_MEMBERS" 2>/dev/null || status=1
  fi
  [ "$status" -eq 0 ] || return 1

  FM_BATCH_OPEN_COUNT=$((FM_BATCH_OPEN_COUNT + 1))
  FM_BATCH_OPEN_LAST_JSEQ=$jseq
  fm_batch_open_write "$priority" || return 1
  return 0
}

# --- the pass ---------------------------------------------------------------

# shellcheck disable=SC2034 # Read by bin/fm-event-batch.sh's run loop.
FM_BATCH_PASS_ADMITTED=0
# shellcheck disable=SC2034 # Read by bin/fm-event-batch.sh's run loop.
FM_BATCH_PASS_CLOSED=0

# Run one pass: admit every journal record above the cursor, then close whatever
# is due.
fm_batch_pass() {
  local since jseq arrived kind key payload snapshot event priority
  local admitted=0 work

  FM_BATCH_PASS_ADMITTED=0
  FM_BATCH_PASS_CLOSED=0
  FM_BATCH_CLOSED=0

  mkdir -p "$FM_BATCH_DIR" "$FM_BATCH_OPEN_DIR" 2>/dev/null || return 1
  fm_lock_acquire_wait "$FM_BATCH_LOCK" || return 1

  since=$(fm_batch_cursor)
  # Read into a temp file rather than a pipe: the loop below must run in this
  # shell so the open-batch state it carries between events is the state the last
  # admission left behind.
  work=$(mktemp "${TMPDIR:-/tmp}/fm-event-batch-pass.XXXXXX") || {
    fm_lock_release "$FM_BATCH_LOCK"
    return 1
  }
  "$FM_BATCH_LIB_DIR/fm-journal.sh" read --since "$since" --limit "$FM_BATCH_PASS_MAX" \
    > "$work" 2>/dev/null

  while IFS=$'\t' read -r jseq arrived kind key _origin payload snapshot; do
    [ -n "$jseq" ] || continue
    case "$jseq" in *[!0-9]*) continue ;; esac
    case "$arrived" in ''|*[!0-9]*) arrived=$(fm_batch_now) ;; esac
    event=$payload
    [ -z "$snapshot" ] || event="$payload | $snapshot"
    priority=$(fm_batch_priority "$kind" "$payload" "$snapshot")

    if ! fm_batch_admit "$jseq" "$arrived" "$kind" "$key" "$event" "$priority"; then
      # The cursor did not move, so this event is admitted again next pass. Say
      # so loudly: a batcher whose record is failing is not a batcher anyone
      # should read as quiet.
      printf 'fm-event-batch: could not record journal event %s into a batch; it will be admitted again\n' \
        "$jseq" >&2
      break
    fi
    admitted=$((admitted + 1))
    # The member record is down, so the event is safe. Only now may the cursor
    # move past it; the other order turns a failed append into a lost event.
    printf '%s\n' "$jseq" > "$FM_BATCH_CURSOR_FILE" 2>/dev/null || break

    if [ "$priority" = immediate ]; then
      # No delay at all for the immediate event, and nothing sits behind it:
      # every other open batch closes now rather than making its members wait out
      # a budget that has just been overtaken.
      fm_batch_close immediate immediate || true
      fm_batch_close_all bypass
    elif [ "$FM_BATCH_OPEN_COUNT" -ge "$FM_BATCH_MAX_EVENTS" ]; then
      # Full closes the batch; it never truncates one. The next member opens a
      # fresh batch, and no member is discarded to stay under the bound.
      fm_batch_close "$priority" full || true
    fi
  done < "$work"
  rm -f "$work"

  fm_batch_close_due
  fm_lock_release "$FM_BATCH_LOCK"

  # shellcheck disable=SC2034 # Read by bin/fm-event-batch.sh's run loop.
  FM_BATCH_PASS_ADMITTED=$admitted
  # shellcheck disable=SC2034 # Read by bin/fm-event-batch.sh's run loop.
  FM_BATCH_PASS_CLOSED=$FM_BATCH_CLOSED
  return 0
}

# --- health -----------------------------------------------------------------

# Written at the END of every pass INCLUDING a pass that admitted nothing,
# because a beacon that only ticks when there is work cannot tell a batcher
# holding a quiet fleet apart from one that has stopped - and a batcher that has
# stopped is holding events that will never be released, which looks from the
# outside exactly like a quiet period.
fm_batch_health_write() {  # <state> <started> <passes> <admitted> <closed>
  local run_state=$1 started=$2 passes=$3 admitted=$4 closed=$5 tmp now
  now=$(fm_batch_now)
  mkdir -p "$FM_BATCH_DIR" 2>/dev/null || return 1
  tmp="$FM_BATCH_HEALTH.$$"
  {
    printf 'state: %s\n' "$run_state"
    printf 'pid: %s\n' "${BASHPID:-$$}"
    printf 'started: %s\n' "$started"
    printf 'last_pass: %s\n' "$now"
    printf 'passes_this_run: %s\n' "$passes"
    printf 'admitted_this_run: %s\n' "$admitted"
    printf 'closed_this_run: %s\n' "$closed"
    printf 'cursor: %s\n' "$(fm_batch_cursor)"
    printf 'interval: %s\n' "$FM_BATCH_INTERVAL"
  } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$FM_BATCH_HEALTH" 2>/dev/null || return 1
  return 0
}

# How long the run loop should wait before its next pass: the poll interval, or
# less when an open batch is due sooner. Without this the poll interval would be
# added to every deadline, so a class's delay would be its budget PLUS however
# long the batcher happened to sleep - which is the batcher spending a budget it
# was given rather than holding to it.
fm_batch_next_wait() {  # -> seconds
  local priority now wait due
  now=$(fm_batch_now)
  wait=$FM_BATCH_INTERVAL
  while IFS= read -r priority; do
    [ -n "$priority" ] || continue
    fm_batch_open_read "$priority" || continue
    case "$FM_BATCH_OPEN_DEADLINE" in ''|*[!0-9]*) continue ;; esac
    due=$((FM_BATCH_OPEN_DEADLINE - now))
    [ "$due" -lt "$wait" ] || continue
    wait=$due
  done < <(fm_batch_open_priorities)
  [ "$wait" -ge 1 ] || wait=1
  printf '%s' "$wait"
}

fm_batch_health_field() {  # <name>
  awk -F': ' -v want="$1" '$1 == want { print $2; exit }' "$FM_BATCH_HEALTH" 2>/dev/null
}
