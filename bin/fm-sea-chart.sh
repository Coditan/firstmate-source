#!/usr/bin/env bash
# fm-sea-chart.sh - assemble ONE undertaking's sea chart: its destination, what
# is decided, what is takeable now, its fog, and its course boundaries.
# Read-only. It never writes, resolves, closes, or reorders anything.
#
# PROVENANCE - THIS AMENDS WAYFINDER, IT DOES NOT INVENT IT
# The destination, the fog of war, the out-of-scope boundary that never rises,
# and the four sections this chart is built around come from the Wayfinder skill
# by Matt Pocock, https://github.com/mattpocock/skills, used under the MIT
# licence (Copyright (c) 2026 Matt Pocock). No Wayfinder code is vendored here -
# Wayfinder ships none, and this script is wholly our own - but the design it
# implements is theirs. What is ours: reading records instead of authoring them,
# the incompleteness counts, the withheld reconciliation below, and the
# per-chart prefix membership rule that replaces Wayfinder's parent-child issue
# edge. What we dropped is the more important half: Wayfinder is a PLANNING
# instrument that breaks work down and sets a course - two write modes, no
# viewing mode - and this amendment kept only the half that shows the result,
# along with dropping its ticket types, its claim, and its two reading
# resolutions. The read-only property above is sound for recording the captain's
# answer and was over-applied to everything else.
# docs/sea-chart-provenance.md carries the licence text, the full comparison,
# and the defects the comparison exposed - including why the wrong-grain
# critique is this amendment's doing rather than something inherited.
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
# captain-gated records straight from the backlog and RECONCILES: any record
# under this chart that the actionable surface did not return is reported in
# `withheld[]`, named, counted, and given the reason it did not reach the
# surface - blocked, in flight, or held some other way. A record the surface DID
# return and the collapse rule then folded away without pairing it to any judge
# ruling in its group is reported there too, as `unpaired-variant`: the fold
# rests on an assumption nothing verifies, so a question only an analyst raised
# must stay on the page rather than fall between the two surfaces. What makes a record
# captain-gated is its KIND, never its name: `kind: captain` together with
# `hold-kind: captain` is the only shape captain-actionability can ever admit,
# and a captain record named without `-decision-` is exactly as lost when it is
# blocked. A record of a DIFFERENT kind carrying a captain hold is not this gap
# and is not recovered here: it never reaches `decisions_open` at all, so the
# decision board cannot see it either. That belongs to the predicate in
# bin/fm-fleet-snapshot.sh and is filed as `fm-snapshot-captain-shape-invisible`.
# Being per-chart is what makes the recovery possible without the fleet-wide
# `decisions_blocked[]` surface that the design defers - a chart knows its own
# scope, so it can ask a bounded question the fleet-wide board cannot.
#
# ONE HOME, ON BOTH SIDES OF THAT RECONCILIATION
# The bearings surface this reads is fleet-wide: it merges every registered
# secondmate home's actionable decisions in beside this home's. A chart is not
# fleet-wide - it belongs to an undertaking, and a secondmate's undertakings are
# its own, recorded in its own backlog under .agents/skills/secondmate-provisioning.
# So records owned by another home are dropped from the capture BEFORE the
# collapse rule groups anything, and the exclusion is stated in `limits[]`. Two
# reasons, in this order: reaching into another home's backlog would put a second
# owner on that home, and leaving the merged records in would leave one side of
# the reconciliation fleet-wide while the other stayed local - which is how a
# chart ends up reporting that more records reached the actionable surface than
# exist in its backlog at all.
#
# BLOCKER EDGES ARE RE-RESOLVED WIDER, AND IN THE SAFE DIRECTION
# The snapshot's `--backlog-json` parser resolves `blocked-by` per FILE, so the
# chart reads the live backlog AND the archive before deciding whether an edge is
# real, resolved, stale, or dangling. An id counts as resolved only when EVERY
# record carrying it is Done.
# That last part is a choice made here, not a copy of anything: the snapshot
# reduce READS as an and-fold but is not one, because jq evaluates `false // true`
# to true, so in practice the last row carrying an id decides it there. Requiring
# all of them is the safe direction, and that is the whole reason. Presenting
# blocked work as takeable invites someone to pick up something that is still
# gated; holding ready work back merely leaves it sitting, and a wrong invitation
# costs more than a wrong omission. So on a duplicated id the two readings
# differ, this one takes the answer that holds work back, and the divergence
# itself is filed as `fm-snapshot-blocker-and-is-not-and` rather than papered
# over here. Only genuinely unresolved real ids are reported where blockers are
# named; an id found nowhere is named as a dangling edge and never holds work.
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
#   withheld[]         open captain-gated records this chart's decision list does
#                      not carry, each with the `cause` that kept it off - blocked,
#                      in-flight, no-hold, other-hold, stale-edge, dangling-edge,
#                      unpaired-variant, not-returned - and `why` in words; blocked
#                      means a decision the fleet has lost, stale-edge and
#                      dangling-edge mean one it can answer right now once the bad
#                      edge is cleared, and unpaired-variant means the fold dropped
#                      a question only an analyst raised
#   fog[]              named dark patches on this course
#   out_of_course[]    deliberate scope boundaries; these never rise
#   takeable[]         work with no unresolved real blocker and no hold, each with
#                      dangling_blocked_by[] plus a navigation PAIR:
#                      {unsupervised_edit, landing{mode,requires}}
#   unplaced[]         members this chart counted and could NOT put in any section
#                      above, each with the `cause` that left it out - no-kind,
#                      marker-kind-mismatch, decision-shape, blocked, held,
#                      unplaced - `kind_defect` for whether the kind itself is the
#                      fault, and `why` in words.
#                      An empty section reads as a claim about the course, so a
#                      member the chart cannot recognise is named rather than
#                      quietly dropped behind a zero. Ordered kind defects first,
#                      so held or blocked ordinary work cannot push one down
#   counts             the incompleteness numbers, computed fresh per build.
#                      `withheld` covers BOTH classes the section carries - the
#                      records the actionable surface never returned and the ones
#                      it did return before the fold dropped them - so it is
#                      labelled by what is true of both, and `withheld_folded`
#                      says how many are the second kind, which is what reconciles
#                      it against `folded` rather than leaving one record counted
#                      twice with nothing on the page explaining why
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"
INVENTORY="$SCRIPT_DIR/fm-decision-inventory.sh"
# shellcheck source=bin/fm-chart-kinds-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-chart-kinds-lib.sh"  # FM_CHART_KINDS: fog and out-of-course
# shellcheck source=bin/fm-blocker-class-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-blocker-class-lib.sh"  # FM_BLOCKER_CLASS_JQ: one owner of "is a blocked-by target real"

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
CAPTURE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-sea-chart.XXXXXX") || die "cannot create a temporary capture"
SCOPED_CAPTURE=$(mktemp "${TMPDIR:-/tmp}/fm-sea-chart.XXXXXX") || die "cannot create a temporary capture"
trap 'rm -f "$CAPTURE_FILE" "$SCOPED_CAPTURE"' EXIT HUP INT TERM

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || die "no such capture: $FROM"
  RAW_CAPTURE=$FROM
else
  [ -x "$BEARINGS" ] || die "missing $BEARINGS"
  "$BEARINGS" --json --all-decisions > "$CAPTURE_FILE" || die "bearings snapshot failed"
  RAW_CAPTURE=$CAPTURE_FILE
fi

# MAIN-HOME SCOPE, APPLIED BEFORE THE COLLAPSE RULE EVER SEES A RECORD.
# `decisions_open` is a MERGED surface: bearings appends every registered
# secondmate home's own actionable decisions, marked with an owner other than
# "(main)" and an id prefixed "<secondmate-id>/". This chart reads exactly one
# home - the backlog and archive it was pointed at - so if those records reached
# the grouping, one side of the reconciliation would be fleet-wide while the
# other stayed local, and the counts could assert that more records reached the
# actionable surface than exist in the backlog at all. Dropping them here makes
# both sides the same scope by construction. It is disclosed in limits[].
jq '.decisions_open = [ (.decisions_open // [])[]
      | select(((.owner // "(main)") == "(main)") and (((.id // "") | index("/")) == null)) ]' \
  "$RAW_CAPTURE" > "$SCOPED_CAPTURE" || die "cannot read the bearings capture $RAW_CAPTURE"
INV=$("$INVENTORY" --json --from "$SCOPED_CAPTURE") || die "decision inventory failed"

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
  mode=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$repo" 2>/dev/null | head -1 | awk '{print $1}') || mode=""
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
  --argjson chart_kinds "$(fm_chart_kinds_json)" "$FM_BLOCKER_CLASS_JQ"'
  def member($id): $id == $chart or ($id | startswith($chart + "-"));
  def dkey: . as $id
    | ($id | index("-decision-")) as $at
    | if $at == null then null else $id[($at + 10):] end;
  def marker($m): . as $id
    | ($id | index("-" + $m + "-")) as $at
    | if $at == null then null else $id[($at + 2 + ($m | length)):] end;
  def open_state: .state == "queued" or .state == "in_flight";
  # An id is resolved only when EVERY record carrying it is Done. The snapshot
  # resolves per FILE, so a live record whose blocker was archived long ago reads
  # as blocked forever and never becomes takeable, with no footnote; the chart
  # holds the live backlog and the archive together and asks across both.
  # Requiring all of them is chosen for the DIRECTION of the error, not because
  # it copies anything: a live queued row is never cancelled by an archived Done
  # twin of the same id, because presenting gated work as takeable invites
  # someone to pick up something still held, while holding ready work back only
  # leaves it sitting. See the header for where this and the snapshot diverge.
  # $known holds every id that is a real record in the live backlog or the archive
  # (built once in the body). A blocker whose target is real nowhere is dangling -
  # a data-integrity fault, not a leg that can hold this one - so it is excluded
  # here and named separately, exactly as fm-fleet-snapshot and fm-backlog-lint do.
  def unresolved($done; $known):
    [ (.blocked_by_ids // .unresolved_blocker_ids // [])[]
      | select(fm_blocker_is_real(.; $known; {}) and ($done[.] != true)) ];

  # Blockers this record names that are real in neither the backlog nor the archive.
  # These are the reason the snapshot fell the record off the actionable surface
  # while nothing real held it: a mistyped, renamed, or never-created target.
  def dangling_edges($known): fm_dangling_blockers(.blocked_by_ids; $known; {});

  # Blockers this record names that ARE Done, but only somewhere the live backlog
  # alone cannot see - the archive. These are what the snapshot still counts as
  # holding the record, and they are the reason it fell off the actionable
  # surface even though nothing is really holding it.
  def stale_edges($done; $live_done):
    [ (.blocked_by_ids // [])[] | select($done[.] == true and $live_done[.] != true) ];

  # A record whose ID says one thing and whose KIND says another. The id markers
  # and the kind names are two separate spellings, owned by the header above and
  # by AGENTS.md section 10 - this reads the two together rather than adding a
  # third. It is the only evidence the chart has that a non-chart kind is a
  # MISTAKE rather than ordinary work: kind ship, docs, and scout are all
  # legitimately takeable, and nothing distinguishes a typo from any of them
  # except an id that already claims to be chart material. Whichever of the two
  # the filer got wrong, the pair cannot both be right, and the direction of the
  # error is the costly one - the record is offered as work to pick up while the
  # section it names reads empty.
  def marker_kind_mismatch:
    if (.id | marker("fog")) != null and .kind != $fog_kind
    then {marker: "fog", expected: $fog_kind, section: "FOG"}
    elif (.id | marker("oos")) != null and .kind != $oos_kind
    then {marker: "oos", expected: $oos_kind, section: "OUT OF COURSE"}
    else null end;

  # Why a captain-gated record is not on the decision list of this chart. These are
  # different pieces of news and must not share one sentence: a blocked record is
  # one the fleet has lost track of, while an in-flight one is being worked right
  # now. Captain-actionability (bin/fm-fleet-snapshot.sh) wants a queued record of
  # kind captain, held with hold-kind captain, and nothing unresolved against it,
  # so each failing clause gets its own name and its own words.
  # The unpaired-variant clause comes FIRST because it is the one case where the
  # record did reach the actionable surface, so every sentence below it - each of
  # which says the surface never carried it - would be false of such a record.
  # The stale-edge clause comes last of the named ones ON PURPOSE: reaching it
  # means every other clause of that predicate already passes, which is what
  # makes the claim that the decision can be answered now true rather than hoped.
  def withheld_reason($done; $live_done; $known; $unpaired):
    if (. as $r | ($unpaired | index($r.id)) != null)
    then {cause: "unpaired-variant",
          why: "it reached the actionable surface, but no judge ruling in its group carries its decision key, so the collapse rule folded it away and the decision list below does not show it. It is a question only an analyst raised: the fold assumes a judge picked that question up, nothing verifies that assumption, so read this record rather than take the fold at its word."}
    elif (unresolved($done; $known) | length) > 0
    then {cause: "blocked",
          why: "blocked by another record that has not resolved, so it never reaches the actionable surface"}
    elif .state != "queued"
    then {cause: "in-flight",
          why: "in flight rather than queued: somebody is working it right now, so it is not a decision lying unanswered"}
    elif .hold_reason == null
    then {cause: "no-hold",
          why: "queued with no hold recorded, so nothing on the record states what the captain is being asked"}
    elif .hold_kind != "captain"
    then {cause: "other-hold",
          why: (if .hold_kind == null
                then "held with no hold kind recorded, so nothing on it names the captain as the audience and the actionable surface never carries it"
                else "held as \(.hold_kind), which is not a captain hold, so the actionable surface never carries it" end)}
    elif (stale_edges($done; $live_done) | length) > 0
    then {cause: "stale-edge",
          why: "held off by a stale edge only: it names \(stale_edges($done; $live_done) | join(", ")) as blocking, and that lies Done in the archive where a reader of the live backlog alone cannot see it. Nothing is holding this decision - it can be answered now, and the blocked-by edge wants clearing."}
    elif (dangling_edges($known) | length) > 0
    then {cause: "dangling-edge",
          why: "held off by a dangling edge only: it names \(dangling_edges($known) | join(", ")) as blocking, and that is a real record in neither the backlog nor the archive - never created, renamed, or mistyped. Nothing is holding this decision - it can be answered now, and the blocked-by edge wants clearing."}
    else {cause: "not-returned",
          why: "present in the backlog but not returned as actionable"}
    end;

  # Why a member reached NO section at all. Every section below places a member
  # by its KIND, and every one of those filters can simply fail to match, which
  # leaves the member counted in `membership` and drawn nowhere. The kind is
  # asked about first because a missing or unplaceable kind hides a whole CLASS
  # of record rather than one row: it is what drew five members while reporting
  # no fog and no boundaries.
  # These causes are not equal news, and `kind_defect` is what says so. A kind
  # the chart cannot classify can empty a whole section while the course is not
  # empty at all; a held or blocked ordinary kind is simply work this chart has
  # no section for, which is worth stating and is no one to blame. Both are
  # reported - dropping the second would be the silent gap this section exists
  # against - but the first is ranked above it, because a real kind defect
  # pushed down the page by a long tail of routine held rows is how the original
  # defect went unnoticed.
  def unplaced_reason($done; $known):
    marker_kind_mismatch as $mis
    | if .kind == null
    then {cause: "no-kind", kind_defect: true,
          why: "no kind is recorded on it, and every section of this chart places a member by its kind, so none of them can take it. File a dark patch on the course as kind \($fog_kind), a deliberate boundary as kind \($oos_kind), and anything else as the kind of work it actually is; AGENTS.md section 10 has the commands. A hold kind is a different field and never places a record here."}
    elif $mis != null
    then {cause: "marker-kind-mismatch", kind_defect: true,
          why: "its id carries the -\($mis.marker)- marker, which files it under this chart as \($mis.expected), but its record kind is \(.kind). One of the two is wrong and the chart cannot tell which: correct the kind to \($mis.expected), or rename the id if this record is not that. Until they agree the \($mis.section) section reads empty while this record sits on the course, and the record is not offered as takeable either, because a kind nobody can trust is not an invitation to pick work up."}
    elif (.id | dkey) != null
    then {cause: "decision-shape", kind_defect: true,
          why: "its id is named as a decision but it is filed as kind \(.kind) rather than captain, so the decision sections do not carry it and the takeable filter excludes every decision-named id. Either file it as a captain decision or rename it."}
    elif (unresolved($done; $known) | length) > 0
    then {cause: "blocked", kind_defect: false,
          why: "kind \(.kind) is none this chart places as fog, as a boundary, or as a decision, and it is held back by \(unresolved($done; $known) | join(", ")), so it is not takeable either."}
    elif .hold_reason != null
    then {cause: "held", kind_defect: false,
          why: "kind \(.kind) is none this chart places as fog, as a boundary, or as a decision, and it is held\(if .hold_kind == null then " with no hold kind recorded" else " as \(.hold_kind)" end), so it is not takeable either."}
    else {cause: "unplaced", kind_defect: true,
          why: "kind \(.kind) is none this chart places, and no hold or blocker explains why it is not takeable either. This is a chart defect rather than a record defect - report it."}
    end;

  input as $live
  | input as $arch
  | input as $inv
  | ([ $live.records[]?, $arch.records[]? | select(.structured) ]) as $all
  | ([ $all[] | select(.id != null) ] | group_by(.id)
     | map({key: .[0].id, value: all(.[]; .state == "done")}) | from_entries) as $done
  | ([ $live.records[]? | select(.structured and .id != null) ] | group_by(.id)
     | map({key: .[0].id, value: all(.[]; .state == "done")}) | from_entries) as $live_done
  # Every id that is a real record somewhere the chart can see. A blocked-by target
  # absent from this map is dangling, not a leg that holds the record.
  | ([ $all[] | select(.id != null) | {key:.id, value:true} ] | from_entries) as $known
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
  # What the fold actually KEPT, and therefore what this chart goes on to draw:
  # the decisions it returns and the variants it paired to them by key. The
  # `unpaired_variants[]` of the inventory are held apart on purpose and counted as
  # $unpaired instead. They are records the surface returned and the fold could
  # not attach to any ruling, and no section of this chart emits them - so
  # counting them as returned would delete each one from every surface at once,
  # which is the same silent loss on a fourth flank. They are reconciled below
  # like any other record the decision list does not carry.
  | ([ $groups[]
       | (.decisions[]? | .id), (.decisions[]?.variants[]? | .id) ]) as $seen
  | ([ $groups[] | (.unpaired_variants[]? | .id) ]) as $unpaired

  # RECONCILIATION. Every record this chart owns that waits on the captain,
  # straight from the backlog - then whatever the actionable surface did not
  # return. The test is the KIND, never the identifier: `kind: captain` with
  # `hold-kind: captain` is the only shape captain-actionability can ever admit,
  # so the record kind IS the thing while a name is only what it happens to be
  # called. Keying on `-decision-` in the id would leave a blocked captain record
  # named any other way not merely undercounted but invisible, every count
  # reading zero - the same silent loss this chart exists against, on a third
  # flank. A record of some other kind carrying a captain hold is a different
  # gap: it never reaches `decisions_open` either, so the decision board cannot
  # see it in the first place. That one belongs to the captain-actionable
  # predicate in bin/fm-fleet-snapshot.sh and is filed as
  # `fm-snapshot-captain-shape-invisible`; this chart cannot close it.
  | ([ $mine[] | select(open_state and .kind == "captain") ]) as $own_decision_records
  | ([ $own_decision_records[]
       | select(.id as $id | ($seen | index($id)) == null)
       | withheld_reason($done; $live_done; $known; $unpaired) as $reason
       | {id, key:(.id | dkey), title:(.title // ""),
          held_by:(unresolved($done; $known) | join(", ")),
          cause: $reason.cause,
          why: $reason.why} ]) as $withheld

  | ([ $mine[] | select(.state == "done" and (.id | dkey) != null)
       | {id, key:(.id | dkey), title:(.title // ""),
          closed:((.completion.date // "-"))} ]
     | sort_by(.closed) | reverse) as $decided

  # THE AGEING PROBE. It runs over every open decision record this chart owns -
  # not only the ones the fold kept - because the record that actually rots is
  # the folded analyst variant whose judge twin was answered and closed while it
  # stayed open. A record is never its own twin: the finding is that a SIBLING
  # under this chart already closed the same decision key. A record with NO key
  # has no twin either - two absent keys are not the same question, they are two
  # questions nobody named - so a keyless record is skipped rather than paired.
  | ([ $own_decision_records[]
       | . as $r
       | ($r.id | dkey) as $k
       | select($k != null)
       | ([ $decided[] | select(.key == $k and .id != $r.id) | .id ]) as $twins
       | select(($twins | length) > 0)
       | {id: $r.id, key: $k, twin: $twins[0]} ]) as $possibly_answered

  | ([ $mine[] | select(open_state and .kind == $fog_kind)
       | {id, patch:((.id | marker("fog")) // .id), title:(.title // ""),
          why:((.hold_reason // "-"))} ]) as $fog
  | ([ $mine[] | select(open_state and .kind == $oos_kind)
       | {id, bound:((.id | marker("oos")) // .id), title:(.title // ""),
          why:((.hold_reason // "-"))} ]) as $out_of_course

  # Takeable: work on this course with nothing REAL unresolved holding it. A
  # dangling blocked-by edge - a target real in neither the backlog nor the archive
  # - never held it, so it stays takeable and the stale edge is named on the row so
  # it gets cleared rather than silently gating the work off the chart forever.
  # A record with NO kind is never takeable. Nothing on it says what it is, so
  # nothing rules out its being a dark patch or a boundary somebody filed with
  # the hold alone - the exact miss this chart was drawing blank on - and this
  # script refuses the wrong-invitation direction everywhere else for the same
  # reason: offering held work as takeable costs more than holding ready work
  # back. Such a record is reported in unplaced[], which names the missing kind.
  # Nor is a record whose id already claims to be chart material while its kind
  # says otherwise. That pair cannot both be right, and offering it here is the
  # same wrong invitation wearing a typo: the FOG or OUT OF COURSE section it
  # names reads empty at the same moment the chart advertises it as work to pick
  # up. An ordinary kind carrying no chart marker is untouched by this and stays
  # takeable, which is the whole reason the marker rather than the kind alone is
  # what decides.
  | ([ $mine[]
       | select(open_state)
       | select(.id != $chart)          # the undertaking itself is the destination, not a leg of it
       | select((.id | dkey) == null)
       | select(.kind != null)
       | select(marker_kind_mismatch == null)
       | select(.kind as $k | ($chart_kinds | index($k)) == null)
       | select(.kind != "captain")
       | select((unresolved($done; $known) | length) == 0)
       | select(.hold_reason == null)
       | {id, title:(.title // ""), repo:(.repo // "-"),
          dangling_blocked_by: (dangling_edges($known)),
          navigation: {
            unsupervised_edit: true,
            landing: {
              mode: (($modes[.repo // ""]) // "unknown"),
              requires: "a supervised worker branches from the tip, reviews it as first reader, and drives it commit by commit through the pipeline"
            }
          }} ]) as $takeable

  # THE SILENT ZERO THIS SECTION EXISTS AGAINST.
  # A chart that finds members and places none of them reports empty sections,
  # and an empty section READS AS A CLAIM - "there is no fog on this course" -
  # when the truth is that the chart could not recognise what it was holding.
  # That is strictly worse than an error, because nothing about it looks wrong.
  # Measured: five correctly-named members, four of them chart material, drawn as
  # `fog: 0  out_of_course: 0` with no footnote anywhere (2026-08-03).
  # The placed set is read out of the ARRAYS this chart emits, never re-derived
  # from copies of their predicates. A second copy would drift from the first the
  # moment either was edited, and unnoticed drift is the exact fault this reports.
  # So a section added later that is not folded in here shows up as a false
  # unplaced row - loud, and in the recoverable direction - rather than as
  # another silent zero. Reading the emitted arrays is also what keeps the claim
  # honest in the other direction: an id that no section prints can never count
  # as placed just because some intermediate list happened to mention it.
  | ([ ($open_decisions[] | .id), ($open_decisions[] | .variants[]? | .id),
       ($withheld[] | .id), ($fog[] | .id),
       ($out_of_course[] | .id), ($takeable[] | .id) ] | unique) as $placed
  | ([ $mine[]
       | select(open_state)
       | select(.id != $chart)          # the undertaking is the destination, not a member drawn on its own chart
       | select(.id as $id | ($placed | index($id)) == null)
       | unplaced_reason($done; $known) as $reason
       | {id, title:(.title // ""),
          kind:(.kind // null), hold_kind:(.hold_kind // null),
          cause: $reason.cause, kind_defect: $reason.kind_defect,
          why: $reason.why} ]
     | sort_by(if .kind_defect then 0 else 1 end)) as $unplaced

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
      unplaced: $unplaced,
      counts: {
        # Both sides are drawn from the same home, so the first can never be the
        # smaller. The guard is here anyway: printing arithmetic that cannot be
        # true teaches a reader to stop believing the numbers, which is worse
        # than any single wrong one.
        records_in_backlog: ([ ($own_decision_records | length),
                               ([ $groups[] | .record_count ] | add // 0) ] | max),
        records: ([ $groups[] | .record_count ] | add // 0),
        decisions: ($open_decisions | length),
        folded: (([ $groups[] | .record_count ] | add // 0) - ($open_decisions | length)),
        withheld: ($withheld | length),
        # How many of those the fold dropped rather than the surface never
        # returning. Without it a folded variant is counted once above and once
        # below with nothing saying they are the same record, and arithmetic a
        # reader cannot reconcile is the same fault as arithmetic that is wrong.
        withheld_folded: ([ $withheld[] | select(.cause == "unpaired-variant") ] | length),
        possibly_answered: ($possibly_answered | length),
        unplaced: ($unplaced | length),
        unplaced_kind_defects: ([ $unplaced[] | select(.kind_defect) ] | length)
      },
      possibly_answered: $possibly_answered,
      # Printed ON the chart, not filed in documentation. A chart that names its
      # own gaps is the counter-design to the flat list that was wrong four times
      # in one week. Do not soften these when rendering.
      limits: [
        "Where a judge ruled, this chart shows the formulation the judge gave. That the judge picked up every question the analysts raised is verified by nothing, so every folded record stays listed underneath.",
        "Withheld decisions are found within the scope of THIS chart, by reading its own records back from the backlog. For every cause but unpaired-variant the fleet-wide decision board cannot count them at all, so a number here does not mean the board agrees; an unpaired variant is the one the board does list, as a variant of its group rather than as a decision.",
        "This chart reads ONE home, the one it was pointed at. A decision recorded in a secondmate home is dropped before anything here is counted, because a secondmate owns its own undertakings and its own backlog. Nothing on this chart says anything about them, in either direction.",
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
    "  \(.counts.records_in_backlog) captain-gated \(if .counts.records_in_backlog == 1 then "record" else "records" end) in the backlog for this chart",
    "    of those, \(.counts.records) reached the actionable surface -> \(.counts.decisions) shown (\(.counts.folded) folded away)",
    "    not carried by any decision section: \(.counts.withheld)" +
      (if .counts.withheld_folded > 0
       then " (\(.counts.withheld_folded) of them folded away above rather than never returned)"
       else "" end),
    "  possibly already answered: \(.counts.possibly_answered)",
    "",
    "members: \(.membership.members)   rule: \(.membership.rule)",
    (if .counts.unplaced > 0 then
      "  of those, \(.counts.unplaced) could not be placed in any section below - see UNPLACED" +
      (if .counts.unplaced_kind_defects > 0
       then " (\(.counts.unplaced_kind_defects) carrying a kind this chart cannot classify)"
       else "" end) else empty end),
    "",
    (if (.unplaced | length) > 0 then
      "UNPLACED - members on this course the chart drew in no section below:" else empty end),
    # Kind defects first and under their own heading, because they are the ones
    # that can leave a section reading empty while the course is not. Routine
    # held or blocked work is reported too - a silent gap is what this exists
    # against - but it must never be what a reader meets first.
    (if .counts.unplaced_kind_defects > 0 then
      "  KIND DEFECTS - the chart cannot classify these, so a section above may read empty while the course is not:",
      (.unplaced[] | select(.kind_defect)
        | "  ? \(.id)  [kind: \(.kind // "none")\(if .hold_kind == null then "" else ", hold-kind: \(.hold_kind)" end)]\n      \(.why)")
      else empty end),
    (if ((.unplaced | length) - .counts.unplaced_kind_defects) > 0 then
      "  HELD OR BLOCKED - ordinary work this chart has no section for; the kind is not the fault here:",
      (.unplaced[] | select(.kind_defect | not)
        | "  ? \(.id)  [kind: \(.kind // "none")\(if .hold_kind == null then "" else ", hold-kind: \(.hold_kind)" end)]\n      \(.why)")
      else empty end),
    (if (.unplaced | length) > 0 then "" else empty end),
    (if (.withheld | length) > 0 then
      "WITHHELD - open captain-gated records no decision section of this chart carries:",
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
      (.takeable[] | "  > \(.id)\n      unsupervised edit: \(.navigation.unsupervised_edit)   landing: \(.navigation.landing.mode)\n      \(.navigation.landing.requires)" +
        (if ((.dangling_blocked_by // []) | length) > 0
         then "\n      ! stale edge to clear: names \((.dangling_blocked_by | join(", "))) as blocking, a real record nowhere - never held this"
         else "" end)),
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
