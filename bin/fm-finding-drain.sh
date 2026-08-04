#!/usr/bin/env bash
# fm-finding-drain.sh - take findings off the political officer's surface by
# rule, and write each drained finding's outcome back onto it.
#
# The officer instructs nobody. He appends claims with `bin/fm-finding.sh emit`
# and stops there; a builder runs THIS script to decide what to work on and to
# report how it turned out. The two command surfaces are separate so "the
# outcome is written back by whoever drained it, never by the officer" is a fact
# about which command each seat runs, not a rule either has to remember.
#
# Usage:
#   fm-finding-drain.sh queue [--state open|taken|closed|unknown|all] [--overdue] [--json]
#   fm-finding-drain.sh next [--json]
#   fm-finding-drain.sh take --by <seat> [--id <id>]
#   fm-finding-drain.sh resolve <id> --outcome upheld|refuted|unresolved
#                                     --by <seat> --evidence <text>
#
#   queue    every finding in the drain rule's order, with its deadline, its
#            lateness in seconds, and whether it is overdue. Columns are
#            id, state, severity, deadline, lateness, overdue, drained_by, claim.
#            --overdue keeps only the findings past their deadline; with the
#            default open state that is exactly the set being ignored.
#   next     the one finding the rule selects, without taking it.
#   take     select and claim. Creating the claim is the atomic act, so two
#            builders racing cannot both get the same finding.
#   resolve  write the outcome back. Only the seat that took it may.
#
# THE DRAIN RULE: earliest deadline first. A finding's deadline is the moment it
# was observed plus the waiting time its severity allows. bin/fm-finding-lib.sh
# owns the rule and the argument for it; docs/findings-surface.md owns what the
# waiting times mean to a reader.
#
# Surface location: FM_FINDINGS_DIR, else the FM_HOME/config/findings-dir
# pointer, else FM_HOME/data/findings.
# FM_FINDING_NOW pins the clock to an ISO-8601 UTC instant, which is what makes
# a deadline reproducible.
#
# Exit codes:
#   0  done. `next` on a surface with nothing takeable is this: it prints
#      open=0 and next= with no value, having actually counted.
#   2  usage error
#   3  the surface could not be reached, or could not be claimed on. Never
#      confused with an empty queue: an unreachable surface prints no queue and
#      no counts at all, because nothing was measured.
#   4  the queue is incomplete - the surface holds a file that is not a finding,
#      an outcome that cannot be read, or a finding whose deadline cannot be
#      computed. The best available answer is still printed, and it is still
#      flagged, because a rule that ordered a queue it could not fully read
#      would hand back a confident wrong answer.
#   5  contested: the finding is already claimed by another seat, or already
#      carries a different written-back outcome.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-finding-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-finding-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message>
  printf 'fm-finding-drain.sh: %s\n' "$2" >&2
  exit "$1"
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || die "$FM_FINDING_EXIT_USAGE" "jq is required to read the findings surface and is not installed"
}

SURFACE=""
RECORDS=""
INCOMPLETE=0
NOW=""

# resolve_now: set NOW, refusing a clock this script cannot read rather than
# silently substituting the wall clock. A pinned instant nobody can parse would
# otherwise produce a queue ordered against a different moment than the caller
# asked for, which is the whole defect class in miniature.
resolve_now() {
  NOW=$(fm_finding_now)
  jq -e -n --arg now "$NOW" \
    '($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) | type == "number"' >/dev/null 2>&1 \
    || die "$FM_FINDING_EXIT_USAGE" \
      "the clock '$NOW' is not an ISO-8601 UTC instant, so no deadline can be computed"
}

# collect: build RECORDS, one JSON object per line, for every VALID finding on
# the surface, each carrying the drain state its outcome sidecar reports.
#
# A malformed file is counted and named, never dropped. A finding whose outcome
# sidecar cannot be read keeps its place in the queue in state `unknown` rather
# than being removed from it: dropping it would hide a real claim behind a
# broken answer, and calling it open would hand a second builder work somebody
# may already be doing.
collect() {
  local file id outcome_path state drained_by outcome_value violations record
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! violations=$(fm_finding_validate "$file"); then
      INCOMPLETE=$((INCOMPLETE + 1))
      printf 'not a finding: %s: %s\n' "$file" "$(printf '%s' "$violations" | tr '\n' ';')" >&2
      continue
    fi
    id=$(basename "$file")
    id=${id%.json}
    outcome_path=$(fm_finding_outcome_path "$SURFACE" "$id")
    state=open
    drained_by=""
    outcome_value=""
    if [ -e "$outcome_path" ]; then
      if violations=$(fm_finding_outcome_validate "$outcome_path" "$id"); then
        state=$(jq -r '.state' "$outcome_path")
        drained_by=$(jq -r '.drained_by' "$outcome_path")
        outcome_value=$(jq -r '.outcome // ""' "$outcome_path")
      else
        INCOMPLETE=$((INCOMPLETE + 1))
        state=unknown
        printf 'not an outcome: %s: %s\n' "$outcome_path" \
          "$(printf '%s' "$violations" | tr '\n' ';')" >&2
      fi
    fi
    if ! record=$(jq -c --arg s "$state" --arg by "$drained_by" --arg o "$outcome_value" \
      '{id, class, severity, observed, claim, officer,
        drain_state:$s, drained_by:$by, outcome:$o}' "$file"); then
      INCOMPLETE=$((INCOMPLETE + 1))
      printf 'could not read the finding %s into the queue\n' "$file" >&2
      continue
    fi
    RECORDS="$RECORDS$record"$'\n'
  done < <(fm_finding_each_record)
}

# ordered: RECORDS as a JSON array in the drain rule's order, on stdout.
#
# The single sort key is lateness, descending: how far past its deadline a
# finding is, negative when the deadline is still ahead. That one number is both
# the order and the coupling - overdue is exactly lateness >= 0 - so there is no
# second mechanism that could keep reporting a healthy queue after the ordering
# broke. Ties go to the lower id, which is the older observation.
#
# A finding whose `observed` cannot be parsed gets no deadline and therefore no
# place in the order. It is carried through as undatable and counted, because
# such a record could be the most urgent one on the surface and dropping it
# would make the very finding the rule cannot handle the one nobody sees.
ordered() {
  local out
  if ! out=$(printf '%s' "$RECORDS" | jq -s \
    --arg now "$NOW" \
    --argjson deadlines "$(fm_finding_deadline_json)" '
    ($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $now_epoch
    | map(
        ((try (.observed | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null)) as $observed_epoch
        | (if $observed_epoch == null or ($deadlines[.severity] // null) == null
           then null
           else $observed_epoch + $deadlines[.severity] end) as $deadline
        | . + {
            deadline: (if $deadline == null then null
                       else ($deadline | todate) end),
            lateness: (if $deadline == null then null else $now_epoch - $deadline end),
            overdue: (if $deadline == null then null else $now_epoch >= $deadline end),
            undatable: ($deadline == null)
          })
    | (map(select(.undatable | not)) | sort_by([-(.lateness), .id]))
      + (map(select(.undatable)) | sort_by(.id))
  ' 2>&1); then
    die "$FM_FINDING_EXIT_MALFORMED" \
      "the queue could not be ordered, so no finding has a known place in it: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
  printf '%s\n' "$out"
}

# load_queue <read|append>: everything the commands below share. `append` is
# what `take` needs, because a surface it cannot write a claim onto is not a
# queue with nothing takeable. Every command loads through here so none of them
# can end up reading a queue on terms the others would have refused.
load_queue() {
  require_jq
  resolve_now
  fm_finding_resolve_surface
  fm_finding_require_surface "$1"
  collect
  QUEUE=$(ordered) || exit $?
  local undatable
  undatable=$(printf '%s' "$QUEUE" | jq '[.[] | select(.undatable)] | length')
  if [ "$undatable" -gt 0 ]; then
    INCOMPLETE=$((INCOMPLETE + undatable))
    printf '%s' "$QUEUE" | jq -r '.[] | select(.undatable)
      | "no deadline for \(.id): observed \"\(.observed)\" is not an ISO-8601 UTC instant"' >&2
  fi
}

# report_incomplete: exit 4 after the answer has already been printed. The
# answer is printed first on purpose - a caller that ignores the exit code still
# gets the best available reading, and one that checks it learns the reading is
# partial.
report_incomplete() {
  [ "$INCOMPLETE" -gt 0 ] || return 0
  printf 'fm-finding-drain.sh: %d record(s) on %s could not be placed in the queue; this ordering is incomplete\n' \
    "$INCOMPLETE" "$SURFACE" >&2
  exit "$FM_FINDING_EXIT_MALFORMED"
}

# next_open_id: the id the rule selects, or empty. `unknown` is deliberately not
# takeable: a finding whose claim state could not be read may already be
# somebody's work.
next_open_id() {
  printf '%s' "$QUEUE" | jq -r 'map(select(.drain_state == "open" and (.undatable | not))) | .[0].id // ""'
}

cmd_queue() {
  local want_state=open overdue_only=0 as_json=0 filtered
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)
        [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--state requires a value"
        case "$2" in
          open|taken|closed|unknown|all) want_state=$2 ;;
          *) die "$FM_FINDING_EXIT_USAGE" "--state must be one of: open taken closed unknown all" ;;
        esac
        shift 2
        ;;
      --overdue) overdue_only=1; shift ;;
      --json) as_json=1; shift ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for queue: $1" ;;
    esac
  done
  load_queue read

  filtered=$(printf '%s' "$QUEUE" | jq \
    --arg state "$want_state" --argjson overdue_only "$overdue_only" '
    map(select($state == "all" or .drain_state == $state))
    | map(select($overdue_only == 0 or .overdue == true))')

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$filtered" | jq '.'
  else
    printf '%s' "$filtered" | jq -r '.[]
      | [.id, .drain_state, .severity,
         (.deadline // "-"),
         (if .lateness == null then "-" else (.lateness | tostring) end),
         (if .overdue == null then "-" elif .overdue then "yes" else "no" end),
         (if .drained_by == "" then "-" else .drained_by end),
         .claim] | @tsv'
  fi
  report_incomplete
}

cmd_next() {
  local as_json=0 id open_count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for next: $1" ;;
    esac
  done
  load_queue read
  id=$(next_open_id)
  open_count=$(printf '%s' "$QUEUE" | jq '[.[] | select(.drain_state == "open" and (.undatable | not))] | length')

  if [ "$as_json" -eq 1 ]; then
    printf '%s' "$QUEUE" | jq --arg id "$id" 'map(select(.id == $id)) | .[0] // null'
  else
    # Both keys always carry a value on a surface that was read, because both
    # were counted. An empty queue says open=0; an unreachable surface never
    # reaches this line at all and prints neither.
    printf 'surface=%s\nnow=%s\nopen=%d\nnext=%s\n' "$SURFACE" "$NOW" "$open_count" "$id"
  fi
  report_incomplete
}

cmd_take() {
  local by="" id="" state record tmp path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --by) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--by requires a value"; by=$2; shift 2 ;;
      --id) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--id requires a value"; id=$2; shift 2 ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for take: $1" ;;
    esac
  done
  fm_finding_blank_p "$by" \
    && die "$FM_FINDING_EXIT_USAGE" "--by is empty: a claim nobody is named on cannot be written back by whoever drained it"

  load_queue append

  if [ -z "$id" ]; then
    id=$(next_open_id)
    if [ -z "$id" ]; then
      printf 'surface=%s\nnow=%s\ntaken=0\nid=\n' "$SURFACE" "$NOW"
      report_incomplete
      return 0
    fi
  else
    state=$(printf '%s' "$QUEUE" | jq -r --arg id "$id" 'map(select(.id == $id)) | .[0].drain_state // ""')
    [ -n "$state" ] || die "$FM_FINDING_EXIT_USAGE" "no finding $id on $SURFACE"
    case "$state" in
      open) : ;;
      *) die "$FM_FINDING_EXIT_CONTESTED" "finding $id is already $state, not open" ;;
    esac
  fi

  record=$(jq -n -S \
    --arg schema "$FM_FINDING_OUTCOME_SCHEMA" \
    --arg finding "$id" \
    --arg by "$by" \
    --arg now "$NOW" \
    '{schema:$schema, finding:$finding, drained_by:$by, drained:$now, state:"taken"}') \
    || die "$FM_FINDING_EXIT_USAGE" "the claim could not be encoded as JSON"

  path=$(fm_finding_outcome_path "$SURFACE" "$id")
  tmp=$(mktemp "$SURFACE/.take.XXXXXX") \
    || die "$FM_FINDING_EXIT_UNREACHABLE" "could not write to the findings surface $SURFACE"
  printf '%s\n' "$record" > "$tmp" || { rm -f "$tmp"; die "$FM_FINDING_EXIT_UNREACHABLE" "could not write the claim"; }

  local violations
  if ! violations=$(fm_finding_outcome_validate "$tmp" "$id"); then
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_USAGE" "the claim did not validate: $(printf '%s' "$violations" | tr '\n' ';')"
  fi

  # `ln` refuses an existing target, so creating the claim is the atomic act.
  # Two builders reaching for the same finding cannot both win, and neither
  # needs a lock on a surface a container appends to without one.
  if ! ln "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_CONTESTED" "finding $id is already claimed; $path exists"
  fi
  rm -f "$tmp"
  printf 'surface=%s\nnow=%s\ntaken=1\nid=%s\nby=%s\n' "$SURFACE" "$NOW" "$id" "$by"
  report_incomplete
}

cmd_resolve() {
  local id=${1:-} outcome="" by="" evidence="" path finding_path record existing tmp violations
  [ -n "$id" ] || die "$FM_FINDING_EXIT_USAGE" "resolve requires a finding id"
  case "$id" in
    --*) die "$FM_FINDING_EXIT_USAGE" "resolve requires a finding id before its options" ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--outcome requires a value"; outcome=$2; shift 2 ;;
      --by) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--by requires a value"; by=$2; shift 2 ;;
      --evidence) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--evidence requires a value"; evidence=$2; shift 2 ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for resolve: $1" ;;
    esac
  done
  fm_finding_member_p "$outcome" "$FM_FINDING_OUTCOMES" \
    || die "$FM_FINDING_EXIT_USAGE" "--outcome must be one of: $FM_FINDING_OUTCOMES"
  fm_finding_blank_p "$by" && die "$FM_FINDING_EXIT_USAGE" "--by is empty"
  # The evidence is what makes the outcome a reading rather than a verdict. An
  # `unresolved` needs it most: without it, "we could not settle this" is
  # indistinguishable from "we did not look".
  fm_finding_blank_p "$evidence" \
    && die "$FM_FINDING_EXIT_USAGE" \
      "--evidence is empty: an outcome with no reading behind it is an opinion about the officer, not an answer to his finding"

  require_jq
  resolve_now
  fm_finding_resolve_surface
  fm_finding_require_surface append

  finding_path=$(fm_finding_path "$SURFACE" "$id")
  [ -f "$finding_path" ] || die "$FM_FINDING_EXIT_USAGE" "no finding $id on $SURFACE"
  if ! violations=$(fm_finding_validate "$finding_path"); then
    die "$FM_FINDING_EXIT_MALFORMED" \
      "$finding_path is on the surface but is not a finding, so nothing can be written back to it: $(printf '%s' "$violations" | tr '\n' ';')"
  fi

  path=$(fm_finding_outcome_path "$SURFACE" "$id")
  # An outcome can only be written back for a finding this seat drained. Without
  # that, any seat could answer any claim it never looked at, and the accuracy
  # score would be computed from verdicts nobody did the work for.
  [ -f "$path" ] \
    || die "$FM_FINDING_EXIT_USAGE" \
      "finding $id was never taken; take it before writing back what it turned out to be"
  if ! violations=$(fm_finding_outcome_validate "$path" "$id"); then
    die "$FM_FINDING_EXIT_MALFORMED" \
      "$path is not a readable outcome record, so this seat's claim on $id cannot be confirmed: $(printf '%s' "$violations" | tr '\n' ';')"
  fi

  existing=$(jq -r '.drained_by' "$path")
  [ "$existing" = "$by" ] \
    || die "$FM_FINDING_EXIT_CONTESTED" \
      "finding $id was drained by $existing, not $by; the outcome is written back by whoever drained it"

  record=$(jq -S \
    --arg outcome "$outcome" --arg evidence "$evidence" --arg now "$NOW" \
    '. + {state:"closed", outcome:$outcome, closed:$now, evidence:$evidence}' "$path") \
    || die "$FM_FINDING_EXIT_USAGE" "the outcome could not be encoded as JSON"

  if [ "$(jq -r '.state' "$path")" = "closed" ]; then
    # A written-back outcome is the record, not a draft. A repeated identical
    # write-back is a retry and is allowed; a different one would quietly
    # replace a verdict the accuracy score has already counted.
    if [ "$(jq -S -c 'del(.closed)' "$path")" = "$(printf '%s' "$record" | jq -S -c 'del(.closed)')" ]; then
      printf 'surface=%s\nid=%s\noutcome=%s\nby=%s\nwritten=0\n' "$SURFACE" "$id" "$outcome" "$by"
      return 0
    fi
    die "$FM_FINDING_EXIT_CONTESTED" \
      "finding $id already carries the outcome $(jq -r '.outcome' "$path"); a written-back outcome is not edited"
  fi

  tmp=$(mktemp "$SURFACE/.resolve.XXXXXX") \
    || die "$FM_FINDING_EXIT_UNREACHABLE" "could not write to the findings surface $SURFACE"
  printf '%s\n' "$record" > "$tmp" || { rm -f "$tmp"; die "$FM_FINDING_EXIT_UNREACHABLE" "could not write the outcome"; }
  if ! violations=$(fm_finding_outcome_validate "$tmp" "$id"); then
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_USAGE" "the outcome did not validate: $(printf '%s' "$violations" | tr '\n' ';')"
  fi
  mv "$tmp" "$path" || { rm -f "$tmp"; die "$FM_FINDING_EXIT_UNREACHABLE" "could not place the outcome at $path"; }
  printf 'surface=%s\nid=%s\noutcome=%s\nby=%s\nwritten=1\n' "$SURFACE" "$id" "$outcome" "$by"
}

QUEUE=""
CMD=${1:-}
[ "$#" -gt 0 ] && shift
case "$CMD" in
  queue) cmd_queue "$@" ;;
  next) cmd_next "$@" ;;
  take) cmd_take "$@" ;;
  resolve) cmd_resolve "$@" ;;
  -h|--help) usage ;;
  '') usage >&2; exit "$FM_FINDING_EXIT_USAGE" ;;
  *) die "$FM_FINDING_EXIT_USAGE" "unknown command: $CMD" ;;
esac
