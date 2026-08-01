#!/usr/bin/env bash
# fm-sea-chart.sh - assemble ONE undertaking's sea chart: its destination, what
# is decided, what is takeable now, its fog, and its course boundaries.
# Read-only. It never writes, resolves, closes, or reorders anything.
#
# HOW THIS DIFFERS FROM THE DECISION BOARD, AND WHY BOTH EXIST
# `bin/fm-decision-inventory.sh` feeds the fleet-wide standing inbox: everything
# waiting on the captain, across every project, with no scope and no end state.
# A chart is the opposite shape - one undertaking, one DESTINATION, finished when
# the way is clear. The destination is what makes the difference: without a scope
# nothing can be OUTSIDE it, so a fleet-wide surface cannot carry a course
# boundary at all, and fog cannot be fog TOWARDS anything. Merging the two would
# have damaged both. This script therefore reuses the board's collapse rule and
# adds nothing to the board's own surface.
#
# WHAT MAKES A RECORD BELONG TO EXACTLY ONE CHART
# The chart id IS the originating undertaking's task id, and a chart owns that id
# namespace: a record belongs to chart C when its id is C or begins with "C-".
# That is the convention already in service - `bin/fm-decision-hold.sh` names a
# hold `<origin-id>-decision-<key>` and `bin/fm-decision-inventory.sh` parses
# that rather than guessing - so charts add no new naming contract, only two new
# markers under it: `<chart>-fog-<slug>` and `<chart>-oos-<slug>`.
# The rule has one real ambiguity, and it is deliberate rather than hidden: when
# one undertaking's id is a prefix of another's, the shorter chart also draws the
# longer one's records. That direction is the safe one - the same trade the
# inventory makes - because a member shown that does not belong is visible by
# eye, and a member silently missing is not. The membership rule and the member
# count are printed with the chart so a wrong member can be caught.
#
# THE DESTINATION IS READ, NEVER INVENTED, AND A CHART CANNOT EXIST WITHOUT ONE
# Three sources, in order: the originating undertaking's own backlog title; the
# one question a panel gave every member, at data/<chart>/question.md; and the
# surviving report at data/<chart>/report.md. All three already exist and all
# three outlive teardown, so naming the destination is not a new act - it is the
# act of filing the undertaking, which AGENTS.md section 10 already requires.
# This script REFUSES to draw a chart for an id with none of them, rather than
# emitting a chart with a blank cover. A list with a cover sheet and no
# destination is exactly the thing a chart is supposed to stop being.
#
# THE SILENT LOSS THIS EXISTS TO PREVENT - MEASURED, NOT ASSUMED
# Captain-actionability is one predicate (bin/fm-fleet-snapshot.sh) and a decision
# blocked by anything fails it. It then leaves `decisions_open` entirely and lands
# in `gates`, which carries no kind - so it is indistinguishable from a blocked
# ship task, on a surface that is already truncated. Measured on a two-decision
# fixture: adding one `blocked-by` edge takes the reported inventory from
# "records: 2 decisions kept: 2" to "records: 1 decisions kept: 1", with no
# footnote anywhere. A chart built naively on that surface drops an open decision
# and says nothing.
# So this script never trusts that surface alone. It reads its own chart's
# decision records straight from the backlog and RECONCILES: any decision record
# under this chart that the actionable surface did not return is reported in
# `withheld[]` with the blocker holding it, and counted. Being per-chart is what
# makes this possible without the fleet-wide `decisions_blocked[]` surface that
# the design defers - a chart knows its own scope, so it can ask a bounded
# question the fleet-wide board cannot.
#
# THE MARKING FOR UNSUPERVISED WORK IS A PAIR, NEVER A BADGE
# `navigation` is deliberately not a boolean. A single flag renders as a badge,
# and a badge reads as "cleared", which is the one thing this marking must never
# promise. Every entry carries `unsupervised_edit` AND a `landing` object that is
# never empty, so the second step cannot be dropped by a renderer that only had a
# scalar to show. Unsupervised work stays raw material: a supervised worker
# branches from its tip, reviews it as first reader, and drives it commit by
# commit through the pipeline. Two prior overnight runs produced real findings at
# exactly that step (data/learnings.md, 2026-07-15).
#
# Usage:
#   fm-sea-chart.sh <chart-id> [--json | --summary]
#   fm-sea-chart.sh -h | --help
#
# Options:
#   --json          full structured chart (default)
#   --summary       one human-readable chart per invocation
#   --from <f>      read a bearings --json capture from <f> instead of running it
#   --backlog <f>   read this live backlog instead of $FM_HOME/data/backlog.md
#   --archive <f>   read this done archive instead of $FM_HOME/data/done-archive.md
#   --data <d>      look for report.md under this directory instead of $FM_HOME/data
#
# The archive default matches bin/fm-decision-hold.sh rather than resolving the
# configured [markdown] archive path; that shared resolution is already filed as
# its own backlog item and is deliberately not fixed here.
#
# Output contract: `fm-sea-chart.v1`.
#   chart              the undertaking id this chart is drawn for
#   destination        {title, source, report} - refuses rather than emitting empty
#   membership         the rule in one line, plus the member count it produced
#   decided[]          resolved decisions of this chart, newest first
#   decisions[]        open decisions, after the board's collapse rule
#   withheld[]         decision records the actionable surface did not return
#   fog[]              named dark patches on this course
#   out_of_course[]    deliberate scope boundaries; these never rise
#   takeable[]         work with no unresolved blocker and no hold, each with a
#                      navigation PAIR: {unsupervised_edit, landing{mode,requires}}
#   counts             the three incompleteness numbers, computed fresh per build
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"
INVENTORY="$SCRIPT_DIR/fm-decision-inventory.sh"
# shellcheck source=bin/fm-chart-kinds-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-chart-kinds-lib.sh"  # FM_CHART_KINDS: fog and out-of-course

FM_ROOT="${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

die() {
  printf 'fm-sea-chart.sh: %s\n' "$1" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^# ?/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

MODE="json"
CHART=""
FROM=""
BACKLOG=""
ARCHIVE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) MODE="json"; shift ;;
    --summary) MODE="summary"; shift ;;
    --from) [ "$#" -gt 1 ] || die "--from needs a path"; FROM=$2; shift 2 ;;
    --backlog) [ "$#" -gt 1 ] || die "--backlog needs a path"; BACKLOG=$2; shift 2 ;;
    --archive) [ "$#" -gt 1 ] || die "--archive needs a path"; ARCHIVE=$2; shift 2 ;;
    --data) [ "$#" -gt 1 ] || die "--data needs a path"; DATA=$2; shift 2 ;;
    -*) die "unknown argument '$1' (see --help)" ;;
    *) [ -z "$CHART" ] || die "one chart at a time (got '$CHART' and '$1')"; CHART=$1; shift ;;
  esac
done

[ -n "$CHART" ] || die "which undertaking? give a chart id (see --help)"
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -x "$FLEET" ] || die "missing $FLEET"

[ -n "$BACKLOG" ] || BACKLOG="$DATA/backlog.md"
[ -n "$ARCHIVE" ] || ARCHIVE="$DATA/done-archive.md"

# The snapshot's own Markdown reader, not a second parser: one owner for the
# backlog format, used twice.
# An ABSENT file is genuinely empty - a home with no archive yet is normal. An
# UNREADABLE one is fatal: degrading it to "no records" would silently shrink
# every count on the chart, which is precisely the failure this tool exists to
# stop. It must not commit that failure while reporting on it.
read_backlog() {  # <path> -> {"records":[...]}
  [ -f "$1" ] || { printf '{"records":[]}\n'; return 0; }
  "$FLEET" --backlog-json "$1" || die "cannot read $1 - refusing to draw a chart from a partial record set"
}

LIVE=$(read_backlog "$BACKLOG")
ARCH=$(read_backlog "$ARCHIVE")

# The collapse rule stays owned by the board's inventory; this only scopes it.
if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || die "no such capture: $FROM"
  INV=$("$INVENTORY" --json --from "$FROM") || die "decision inventory failed"
else
  [ -x "$BEARINGS" ] || die "missing $BEARINGS"
  CAPTURE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-sea-chart.XXXXXX") || die "cannot create a temporary capture"
  trap 'rm -f "$CAPTURE_FILE"' EXIT HUP INT TERM
  "$BEARINGS" --json --all-decisions > "$CAPTURE_FILE" || die "bearings snapshot failed"
  INV=$("$INVENTORY" --json --from "$CAPTURE_FILE") || die "decision inventory failed"
fi

REPORT=""
[ -f "$DATA/$CHART/report.md" ] && REPORT="$DATA/$CHART/report.md"

# A panel-originated chart keeps its destination in the one question every member
# was given. AGENTS.md section 2 guarantees that file outlives teardown exactly
# like the reports, so a chart can still be drawn after the panel is cleaned up.
QUESTION=""
QUESTION_TEXT=""
if [ -f "$DATA/$CHART/question.md" ]; then
  QUESTION="$DATA/$CHART/question.md"
  QUESTION_TEXT=$(awk '
    /^#/ { next }
    /^[[:space:]]*$/ { if (got) exit; next }
    { line = line (line ? " " : "") $0; got = 1 }
    END { print line }' "$QUESTION")
fi

# Delivery mode per repo, resolved fresh: the chart never stores how work lands.
MODES=$(printf '%s\n%s' "$LIVE" "$ARCH" | jq -s --arg chart "$CHART" -r '
  [ .[].records[]? | select(.structured) | select(.id == $chart or (.id | startswith($chart + "-"))) | .repo // empty ]
  | unique | .[]' 2>/dev/null || true)
MODE_MAP="{}"
for repo in $MODES; do
  mode=$("$SCRIPT_DIR/fm-project-mode.sh" "$repo" 2>/dev/null | head -1 | awk '{print $1}') || mode=""
  [ -n "$mode" ] || mode="unknown"
  MODE_MAP=$(printf '%s' "$MODE_MAP" | jq --arg r "$repo" --arg m "$mode" '.[$r] = $m')
done

# The backlog, the archive, and the inventory all grow with the size of a home,
# so they go to jq on stdin and bind with `input`, never on argv. The reason and
# the ceiling are owned by bin/fm-fleet-snapshot.sh's `json_stdin` header; the
# regression is pinned in tests/fm-fleet-snapshot-argv-limit.test.sh. `input`
# binds in stream order, so these three lines must match the order written here.
CHART_JSON=$(printf '%s\n%s\n%s\n' "$LIVE" "$ARCH" "$INV" 2>/dev/null | jq -n \
  --arg chart "$CHART" \
  --arg report "$REPORT" \
  --arg question "$QUESTION" \
  --arg question_text "$QUESTION_TEXT" \
  --argjson modes "$MODE_MAP" \
  --arg fog_kind "$FM_CHART_KIND_FOG" \
  --arg oos_kind "$FM_CHART_KIND_OUT_OF_COURSE" \
  --argjson chart_kinds "$(fm_chart_kinds_json)" '
  def member($id): $id == $chart or ($id | startswith($chart + "-"));
  def dkey: . as $id
    | ($id | index("-decision-")) as $at
    | if $at == null then null else $id[($at + 10):] end;
  def marker($m): . as $id
    | ($id | index("-" + $m + "-")) as $at
    | if $at == null then null else $id[($at + 2 + ($m | length)):] end;
  def open_state: .state == "queued" or .state == "in_flight";

  input as $live
  | input as $arch
  | input as $inv
  | ([ $live.records[]?, $arch.records[]? | select(.structured) ]) as $all
  | ([ $all[] | select(member(.id)) ]) as $mine

  # The destination, read from records the fleet already keeps, never invented here.
  | ([ $all[] | select(.id == $chart) ] | first) as $origin
  | (if $origin != null then $origin.title
     elif $question_text != "" then $question_text
     elif $report != "" then "(title not in the backlog; see the report)"
     else null end) as $dest_title

  # What the actionable surface returned for this chart, after the fold.
  | ([ $inv.groups[]? | select(member(.group)) ]) as $groups
  | ([ $groups[] | .decisions[]? ]) as $open_decisions
  | ([ $groups[]
       | (.decisions[]? | .id), (.decisions[]?.variants[]? | .id), (.unpaired_variants[]? | .id) ]) as $seen

  # RECONCILIATION. Every decision record this chart owns, straight from the
  # backlog - then whatever the actionable surface did not return.
  | ([ $mine[] | select(open_state and (.id | dkey) != null and .kind == "captain") ]) as $own_decision_records
  | ([ $own_decision_records[]
       | select(.id as $id | ($seen | index($id)) == null)
       | {id, key:(.id | dkey), title:(.title // ""),
          held_by:((.unresolved_blocker_ids // []) | join(", ")),
          why:(if ((.unresolved_blocker_ids // []) | length) > 0
               then "blocked by another record, so it never reaches the actionable surface"
               else "present in the backlog but not returned as actionable" end)} ]) as $withheld

  | ([ $mine[] | select(.state == "done" and (.id | dkey) != null)
       | {id, key:(.id | dkey), title:(.title // ""),
          closed:((.completion.date // "-"))} ]
     | sort_by(.closed) | reverse) as $decided

  # THE AGEING PROBE. It runs over every open decision record this chart owns -
  # not only the ones the fold kept - because the record that actually rots is
  # the folded analyst variant whose judge twin was answered and closed while it
  # stayed open. A record is never its own twin: the finding is that a SIBLING
  # under this chart already closed the same decision key.
  | ([ $own_decision_records[]
       | . as $r
       | ($r.id | dkey) as $k
       | ([ $decided[] | select(.key == $k and .id != $r.id) | .id ]) as $twins
       | select(($twins | length) > 0)
       | {id: $r.id, key: $k, twin: $twins[0]} ]) as $possibly_answered

  | ([ $mine[] | select(open_state and .kind == $fog_kind)
       | {id, patch:((.id | marker("fog")) // .id), title:(.title // ""),
          why:((.hold_reason // "-"))} ]) as $fog
  | ([ $mine[] | select(open_state and .kind == $oos_kind)
       | {id, bound:((.id | marker("oos")) // .id), title:(.title // ""),
          why:((.hold_reason // "-"))} ]) as $out_of_course

  # Takeable: work on this course with nothing unresolved holding it.
  | ([ $mine[]
       | select(open_state)
       | select(.id != $chart)          # the undertaking itself is the destination, not a leg of it
       | select((.id | dkey) == null)
       | select(.kind as $k | ($chart_kinds | index($k)) == null)
       | select(.kind != "captain")
       | select(((.unresolved_blocker_ids // []) | length) == 0)
       | select(.hold_reason == null)
       | {id, title:(.title // ""), repo:(.repo // "-"),
          navigation: {
            unsupervised_edit: true,
            landing: {
              mode: (($modes[.repo // ""]) // "unknown"),
              requires: "a supervised worker branches from the tip, reviews it as first reader, and drives it commit by commit through the pipeline"
            }
          }} ]) as $takeable

  | {
      schema: "fm-sea-chart.v1",
      chart: $chart,
      destination: {
        title: $dest_title,
        source: (if $origin != null then "backlog record"
                 elif $question_text != "" then "panel question"
                 elif $report != "" then "report" else null end),
        report: (if $report == "" then null else $report end),
        question: (if $question == "" then null else $question end)
      },
      membership: {
        rule: ("id is \"\($chart)\" or begins with \"\($chart)-\"; a longer undertaking sharing this prefix is drawn here too, which is the recoverable direction"),
        members: ($mine | length)
      },
      decided: $decided,
      decisions: $open_decisions,
      withheld: $withheld,
      fog: $fog,
      out_of_course: $out_of_course,
      takeable: $takeable,
      counts: {
        records_in_backlog: ($own_decision_records | length),
        records: ([ $groups[] | .record_count ] | add // 0),
        decisions: ($open_decisions | length),
        folded: (([ $groups[] | .record_count ] | add // 0) - ($open_decisions | length)),
        withheld: ($withheld | length),
        possibly_answered: ($possibly_answered | length)
      },
      possibly_answered: $possibly_answered,
      # Printed ON the chart, not filed in documentation. A chart that names its
      # own gaps is the counter-design to the flat list that was wrong four times
      # in one week. Do not soften these when rendering.
      limits: [
        "Where a judge ruled, this chart shows the formulation the judge gave. That the judge picked up every question the analysts raised is verified by nothing, so every folded record stays listed underneath.",
        "Withheld decisions are found within the scope of THIS chart, by reading its own records back from the backlog. The fleet-wide decision board still cannot count them, so a number here does not mean the board agrees.",
        "Fog is whatever somebody wrote down as fog. Nothing proves this course has no other dark patches.",
        "An unsupervised marking means the work may be EDITED unsupervised. It never means it may LAND unsupervised.",
        "Whether a piece of work is destructive, irreversible, security-sensitive, or outward-facing is recorded nowhere per record and is not derived here; that judgment stays the always-loaded rule in AGENTS.md sections 7 and 9.",
        "A decision the captain rejects outright cannot be filed away today, because the closing path requires follow-up work that a refusal does not create. Such a decision can be shown here but not laid to rest."
      ]
    }
') || die "chart projection failed"

DEST=$(printf '%s' "$CHART_JSON" | jq -r '.destination.title // ""')
if [ -z "$DEST" ]; then
  die "no destination for '$CHART': no backlog record, no data/$CHART/question.md, no data/$CHART/report.md.
A chart without a destination has no scope, so nothing can be outside its course
and nothing can be fog towards anything. File the undertaking first."
fi

if [ "$MODE" = "summary" ]; then
  printf '%s' "$CHART_JSON" | jq -r '
    "chart: \(.chart)",
    "destination: \(.destination.title)   [read from the \(.destination.source)]",
    (if .destination.report != null then "  report: \(.destination.report)" else empty end),
    (if .destination.question != null then "  question: \(.destination.question)" else empty end),
    "",
    "INCOMPLETENESS, computed fresh for this build:",
    "  \(.counts.records_in_backlog) decision records in the backlog for this chart",
    "    of those, \(.counts.records) reached the actionable surface -> \(.counts.decisions) shown (\(.counts.folded) folded away)",
    "    withheld from the actionable surface: \(.counts.withheld)",
    "  possibly already answered: \(.counts.possibly_answered)",
    "",
    "members: \(.membership.members)   rule: \(.membership.rule)",
    "",
    (if (.withheld | length) > 0 then
      "WITHHELD - open decisions the actionable surface did not return:",
      (.withheld[] | "  ! \(.id)\n      \(.why)" +
        (if .held_by != "" then "\n      held by: \(.held_by)" else "" end)),
      "" else empty end),
    (if (.possibly_answered | length) > 0 then
      "POSSIBLY ALREADY ANSWERED - same chart, same decision key, already closed:",
      (.possibly_answered[] | "  ? \(.id)\n      twin already closed: \(.twin)"),
      "" else empty end),
    (if (.decisions | length) > 0 then
      "OPEN DECISIONS:", (.decisions[] | "  * \(.id)\n      \(.summary)"), "" else empty end),
    (if (.decided | length) > 0 then
      "DECIDED:", (.decided[] | "  + \(.id)  (\(.closed))"), "" else empty end),
    (if (.takeable | length) > 0 then
      "TAKEABLE NOW:",
      (.takeable[] | "  > \(.id)\n      unsupervised edit: \(.navigation.unsupervised_edit)   landing: \(.navigation.landing.mode)\n      \(.navigation.landing.requires)"),
      "" else empty end),
    (if (.fog | length) > 0 then
      "FOG:", (.fog[] | "  ~ \(.patch): \(.title)\n      \(.why)"), "" else empty end),
    (if (.out_of_course | length) > 0 then
      "OUT OF COURSE - these never rise:",
      (.out_of_course[] | "  x \(.bound): \(.title)\n      \(.why)"), "" else empty end)
  '
  exit 0
fi

printf '%s\n' "$CHART_JSON"
