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
# per-chart membership rule - prefix ownership plus the retrofit member list
# below - that replaces Wayfinder's parent-child issue edge. What we dropped is
# the more important half: Wayfinder is a PLANNING
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
# AND WHAT MAKES ONE BELONG WITHOUT BEING RENAMED - data/<chart>/members
# The prefix rule is right for records created UNDER a chart: they are named at
# creation, carry the prefix by construction, and cannot drift out. That is its
# virtue and nothing here weakens it. It fails in exactly one place - an
# undertaking named OVER work that already exists - because membership IS the
# identifier there and nothing else, the backlog tool has no rename at all (its
# move command moves a record between backlog files and preserves the id
# byte-exact), and renaming a record by hand breaks every reference to it that
# has already left this vessel. Measured on the seat that raised it: six of
# seven named undertakings drew ZERO members while their assignment was settled
# and written down (2026-08-10).
# So membership is a UNION: the prefix rule, OR one line per bare record id in
# the optional `data/<chart>/members` file, beside the `question.md` and
# `report.md` this script already reads from the same directory - no new location
# contract, and it survives teardown for the same reason they do. "#" starts a
# comment and blank lines are ignored. Everything drawing today keeps drawing.
# Four properties, and each is load-bearing:
#   ONE HOME, BARE IDS. A qualified or cross-home id is refused and named, never
#     resolved. This script drops other homes' records before the collapse rule
#     groups anything (see ONE HOME below), and honouring a qualified member id
#     would quietly re-open exactly that. Cross-vessel dependency is a blocker
#     edge or a routed request; both already exist.
#   EXCLUSIVE. A record belongs to at most one undertaking. Counted in two "what
#     is left" views it leaves NEITHER chart able to say whether it is finished,
#     and exclusivity is what makes a deviation from a destination measurable at
#     all. Two member lists naming one record are caught here - this is the only
#     place both lists are in hand - and where nothing decides the tie by
#     construction the record is drawn on neither. Where the prefix rule DOES
#     decide it, see the paragraph on prefix ownership below: the record stays
#     with its owner and the foreign line is refused, so it is drawn exactly once.
#   RETROFIT ONLY. Anything created after its undertaking exists is still named
#     under the chart by construction, so a line naming an id the prefix rule
#     already takes is reported as doing nothing. Two ways to assign the same
#     record put a second owner on one contract.
#   PERMANENT, NOT A MIGRATION. Undertakings are recognised as often as they are
#     planned, so the retrofit case reappears every time one is named over work
#     already under way. This is built to stay, with a decaying share of records.
# The list is a hand-maintained SECOND source and rots in ways an id cannot, so
# every line it cannot honour is named in `membership_defects[]` rather than
# dropped, on the same principle as the paragraph above: a member named and
# missing is invisible, a member named and wrong is visible by eye.
# A listed record that already sits inside ANOTHER undertaking's prefix namespace
# IS caught, whenever that owner is itself a record this home holds - and the
# owner is decidable from the record set the chart already has, without
# enumerating undertakings. Both halves are reported, because a collision seen
# from one side only is a collision nobody fixes: the chart whose list names it
# refuses the entry as `owned-elsewhere` and does not draw it, while the chart
# that owns it by prefix keeps drawing it and reports the foreign line as
# `claimed-elsewhere`. A prefix claim is not something a third party can edit
# away, so nothing drawing today stops drawing; the record ends up on exactly one
# chart, which is what makes the exclusivity above real rather than asserted.
# Prefix nesting is the ORDINARY case here, not a rarity: measured 2026-08-10 on
# this home, 845 live and archived record ids carry 142 child records under 51
# distinct parents, overwhelmingly `<origin>-decision-<key>` holds - which is the
# naming convention the prefix rule was built for in the first place. So the
# owner of a listed id is nearly always a real record, and nearly always found.
# (An earlier revision of this comment claimed the opposite, that no id was a
# name-boundary prefix of another. That was a false measurement: the jq that
# produced it read `$e | startswith(. + "-")`, where `.` binds to `$e` rather
# than to the candidate parent, so the test could never be true. It is recorded
# here rather than quietly deleted, because a measurement is a claim and a wrong
# one that leaves no trace is how the next reader repeats it.)
# One residual overlap is still NOT caught, and the chart says so in `limits[]`:
# an owner that is a bare chart root - no record of its own beneath it, no member
# list, no panel question - is indistinguishable from ordinary retrofit material
# from the reaching side, because every record could be somebody's undertaking.
# What is deliberately NOT used as evidence is the mere existence of
# `data/<id>/`: 287 of those 845 ids have one and most hold only a brief.md, so
# it marks a record that was once dispatched as a task, which is exactly what a
# retrofit target is. Refusing on it would refuse about a third of the work this
# path exists to assign.
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
# captain-gated is its KIND, never its name: what captain-actionability admits is
# `hold-kind: captain` (bin/fm-fleet-snapshot.sh), and a captain record named
# without `-decision-` is exactly as lost when it is blocked. This chart draws its
# own reconciliation baseline narrower, from records of `kind: captain` under this
# chart, because those are the ones its sections can classify. An UNBLOCKED
# record of a DIFFERENT kind carrying a captain hold no longer needs that
# baseline: since 2026-08-09 the predicate admits it on the hold kind alone, so
# it arrives here through the inventory and is drawn like any other decision.
# A BLOCKED one reaches NEITHER surface: the predicate fails it on the blocker,
# and this chart's baseline fails it on the kind, so `withheld[]` never names it
# either. It falls through to `unplaced[]`, where the reason reads cause
# `blocked` and names its kind and its blocker but never says the captain is
# being asked. That class is recovered nowhere as a decision - it lies outside
# the recovery this header opens with rather than inside it. It behaved
# identically before 2026-08-09, so this is not a regression, and the narrow
# baseline is deliberate rather than an oversight.
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
#   --data <d>      look for report.md, question.md and the member lists under
#                   this directory instead of $FM_HOME/data
#
# The archive default matches bin/fm-decision-hold.sh rather than resolving the
# configured [markdown] archive path; that shared resolution is already filed as
# its own backlog item and is deliberately not fixed here.
#
# Output contract: `fm-sea-chart.v1`.
#   chart              the undertaking id this chart is drawn for
#   destination        {title, source, report} - refuses rather than emitting empty
#   membership         what actually determined membership, in one line, plus the
#                      member count it produced, the member list that was read
#                      (`list`, null when the chart has none) and how many members
#                      only that list assigned (`from_list`)
#   membership_defects[]  member-list lines this chart could not honour, each with
#                      the `cause` - contested, claimed-elsewhere, owned-elsewhere,
#                      qualified, malformed, unresolvable, redundant - the other
#                      charts that also claim it in `claimed_by`, and `why` in
#                      words. Most causes refuse the entry, so the record is not
#                      drawn here; `redundant` and `claimed-elsewhere` do not,
#                      because the prefix rule holds that record either way and no
#                      line in any file can take it off this chart.
#                      `claimed-elsewhere` is the one row NOT about a line of this
#                      chart's own list: it reports another chart's list naming a
#                      record this chart owns by construction, which is invisible
#                      from anywhere else. Ordered contested first, then the two
#                      prefix-ownership collisions, then the refused-boundary
#                      causes, then unresolvable, then the entries that assign
#                      nothing, so a broken exclusivity is never pushed down the
#                      page by a list line that is merely superfluous
#   decided[]          resolved decisions of this chart, newest first
#   decisions[]        open decisions, after the board's collapse rule
#   withheld[]         open captain-gated records this chart's decision list does
#                      not carry, each with the `cause` that kept it off - blocked,
#                      no-hold, other-hold, stale-edge, dangling-edge,
#                      unpaired-variant, folded-elsewhere, non-member-variant,
#                      not-returned - and `why` in words; blocked
#                      means a decision the fleet has lost, stale-edge and
#                      dangling-edge mean one it can answer right now once the bad
#                      edge is cleared, unpaired-variant means the fold dropped
#                      a question only an analyst raised, and folded-elsewhere
#                      means the fold hung it under a ruling of a DIFFERENT
#                      undertaking, so no section here can carry it
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
#   misfiled[]         members whose id marker and record kind disagree, whether or
#                      not a section drew them, each naming the `marker` found, the
#                      `kind` found, the section it `belongs_in`, and the one it was
#                      `drawn_in`. A boundary filed with the fog kind IS drawn, so
#                      no report about unplaced members can see it, while the
#                      section its id names is drawn without it. This states the
#                      disagreement and picks no winner
#   counts             the incompleteness numbers, computed fresh per build.
#                      `withheld` covers BOTH classes the section carries - the
#                      records the actionable surface never returned and the ones
#                      it did return before the fold dropped them - so it is
#                      labelled by what is true of both, and `withheld_folded`
#                      says how many are the second kind - unpaired-variant and
#                      folded-elsewhere together - which is what reconciles it
#                      against `folded` rather than leaving one record counted
#                      twice with nothing on the page explaining why.
#                      `records` counts every record of this chart the actionable
#                      surface returned, folded-elsewhere ones included, so it is
#                      never smaller than what the withheld rows below claim.
#                      `named_not_owned` is counted APART from all of those, and
#                      the separation is the point: those are records of another
#                      undertaking that the fold hung beneath a ruling drawn here,
#                      so they are named rather than drawn. Counting them among
#                      `records` once made this page report more captain-gated
#                      records in the backlog than the chart holds
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

# THE RETROFIT PATH, READ FOR EVERY CHART IN THIS HOME AND NOT ONLY THIS ONE.
# Header: `data/<chart>/members` assigns work that already existed when the
# undertaking was named, without renaming the record. Nothing is validated here -
# every entry, good or bad, is handed to the projection below, which owns the one
# statement of what a member list may say and why each refusal is a refusal.
# The OTHER charts' lists come along because exclusivity cannot be checked from
# one list: two undertakings each claiming a record is visible only to a reader
# holding both, and this is the only moment both are in hand.
MEMBER_FILE=""
[ -f "$DATA/$CHART/members" ] && MEMBER_FILE="$DATA/$CHART/members"

# An ABSENT list is genuinely empty - most charts have none, and that is normal.
# An UNREADABLE one is fatal, exactly as read_backlog above treats an unreadable
# backlog and for the same reason: degrading it to "this list is empty" would
# silently shrink the page. For a FOREIGN list it is worse than a shrunken page -
# the exclusivity check simply stops firing, and a contested record is then drawn
# on both charts with no defect row anywhere to say so.
read_member_claims() {  # -> "<chart>\t<entry>" lines, comments and blanks stripped
  local f owner
  for f in "$DATA"/*/members; do
    [ -f "$f" ] || continue
    owner=$(basename "$(dirname "$f")")
    FM_CHART_OWNER="$owner" awk '
      { sub(/#.*/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
      $0 == "" { next }
      { printf "%s\t%s\n", ENVIRON["FM_CHART_OWNER"], $0 }
    ' "$f" || { printf 'fm-sea-chart.sh: cannot read the member list %s\n' "$f" >&2; return 1; }
  done
}

# Read into a variable rather than straight down a pipe: a pipeline reports only
# the status of its LAST command, and `jq -R -s` succeeds on every input there is,
# so a reader failing upstream would have arrived here as an empty list with a
# zero exit status.
MEMBER_CLAIMS=$(read_member_claims) \
  || die "refusing to draw a chart from a partial membership - see the reader error above"

# A tab cannot appear in a bare record id, so an entry carrying one is malformed
# and must reach the projection intact to be named as such - hence the rejoin
# rather than taking field 2 and discarding the rest.
CLAIMS_JSON=$(printf '%s' "$MEMBER_CLAIMS" | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t") | {chart: .[0], id: (.[1:] | join("\t"))})') \
  || die "cannot read the member lists under $DATA"
LISTED_RAW=$(printf '%s' "$CLAIMS_JSON" | jq -c --arg chart "$CHART" \
  '[ .[] | select(.chart == $chart) | .id ] | unique')

# FILE EVIDENCE THAT AN ID IS AN UNDERTAKING IN ITS OWN RIGHT.
# Used by the ownership test below, where a member list reaching for a record
# another chart owns has to be refused rather than honoured. Only a member list
# or a panel question counts: a chart has either of those because somebody
# curated it as a chart. The bare existence of `data/<id>/` is deliberately NOT
# evidence - the header carries the measurement, but in short it marks a record
# that was once dispatched as a task, which is precisely what retrofit material
# is, so refusing on it would refuse the work this path exists to assign.
CHART_ROOT_FILES=$(
  for f in "$DATA"/*/members "$DATA"/*/question.md; do
    [ -f "$f" ] || continue
    basename "$(dirname "$f")"
  done
)
CHART_ROOTS_JSON=$(printf '%s' "$CHART_ROOT_FILES" | jq -R -s -c \
  'split("\n") | map(select(length > 0)) | unique | map({key: ., value: true}) | from_entries') \
  || die "cannot read the chart directories under $DATA"

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
# was given. bin/fm-model-panel.sh's header owns that record and guarantees the
# question outlives scout teardown exactly like the reports, so a chart can still
# be drawn after the panel is cleaned up.
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
# This reads the member list RAW, before any entry is refused, and that is
# deliberate: the result is a lookup table, so an entry the projection later
# refuses contributes at worst an unused key, while validating here would put a
# second copy of the membership rule in front of the one that owns it.
# A failure is NOT swallowed. It would empty the lookup table, and every takeable
# row would then print `landing: unknown` - a claim about how the work lands that
# reads as recorded fact. Found the hard way while widening the selector below:
# an error inside it silently mislabelled every row on the page.
MODES=$(printf '%s\n%s' "$LIVE" "$ARCH" | jq -s --arg chart "$CHART" --argjson listed "$LISTED_RAW" -r '
  [ .[].records[]? | select(.structured) | . as $r
    | select($r.id == $chart or ($r.id | startswith($chart + "-")) or (($listed | index($r.id)) != null))
    | .repo // empty ]
  | unique | .[]') || die "cannot resolve the delivery modes of this chart"
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
  --arg member_file "$MEMBER_FILE" \
  --argjson listed_raw "$LISTED_RAW" \
  --argjson claims "$CLAIMS_JSON" \
  --argjson chart_roots "$CHART_ROOTS_JSON" \
  --argjson modes "$MODE_MAP" \
  --arg fog_kind "$FM_CHART_KIND_FOG" \
  --arg oos_kind "$FM_CHART_KIND_OUT_OF_COURSE" \
  --argjson chart_kinds "$(fm_chart_kinds_json)" "$FM_BLOCKER_CLASS_JQ"'
  # Half of membership, and the half that is self-maintaining: a record named
  # under this chart carries the prefix by construction and cannot drift out of
  # it. The other half is the member list, which cannot be resolved until the
  # record set is in hand, so the union is formed in the body rather than here.
  def prefix_member($id): $id == $chart or ($id | startswith($chart + "-"));
  def dkey: . as $id
    | ($id | index("-decision-")) as $at
    | if $at == null then null else $id[($at + 10):] end;
  def marker($m): . as $id
    | ($id | index("-" + $m + "-")) as $at
    | if $at == null then null else $id[($at + 2 + ($m | length)):] end;
  def open_state: .state == "queued" or .state == "in_flight";

  # The withheld causes that describe a record the actionable surface DID return,
  # kept as two named lists because they answer two different questions and a
  # cause added later belongs to whichever is true of it - possibly both, possibly
  # neither. They live here, beside each other, because the failure they exist
  # against has now happened twice: a cause was added and one of these two places
  # was not, so a sentence or a number quietly stopped covering it.
  # `board_carried_causes` is what the fleet-wide decision board also lists, as a
  # variant of its group rather than as a decision, and it decides what the
  # withheld limit may claim.
  # `own_returned_causes` is the narrower set of records THIS chart owns, and it
  # decides which counts a record may be reconciled against. `non-member-variant`
  # is in the first and not the second on purpose: the board carries it, and this
  # chart does not own it.
  def board_carried_causes: ["unpaired-variant", "folded-elsewhere", "non-member-variant"];
  def own_returned_causes: ["unpaired-variant", "folded-elsewhere"];
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
  # section its id names is drawn without it.
  def marker_kind_mismatch:
    if (.id | marker("fog")) != null and .kind != $fog_kind
    then {marker: "fog", expected: $fog_kind, section: "FOG"}
    elif (.id | marker("oos")) != null and .kind != $oos_kind
    then {marker: "oos", expected: $oos_kind, section: "OUT OF COURSE"}
    else null end;

  # Why a captain-gated record is not on the decision list of this chart. These are
  # different pieces of news and must not share one sentence, so each failing
  # clause gets its own name and its own words. Captain-actionability
  # (bin/fm-captain-actionable-lib.sh) wants a non-terminal record held with
  # hold-kind captain and nothing unresolved against it.
  # There is deliberately NO in-flight clause. Until 2026-08-29 the predicate also
  # required `queued`, and this function named that as a cause - which read as
  # reassurance ("somebody is working it right now") for the one shape that is the
  # opposite of reassuring: a question that did not merely precede the work, it
  # STOPPED work already under way. That clause is gone from the predicate, so
  # such a record now reaches the decision list and never arrives here at all; an
  # in-flight record that still arrives here is held off by something else, and
  # the clauses below name whichever it is rather than blaming the phase.
  # The unpaired-variant and folded-elsewhere clauses come FIRST, together,
  # because they are the two cases where the record DID reach the actionable
  # surface, so every sentence below them - each of which says the surface never
  # carried it - would be false of such a record.
  # The stale-edge clause comes last of the named ones ON PURPOSE: reaching it
  # means every other clause of that predicate already passes, which is what
  # makes the claim that the decision can be answered now true rather than hoped.
  def withheld_reason($done; $live_done; $known; $unpaired; $folded):
    if (. as $r | ($unpaired | index($r.id)) != null)
    then {cause: "unpaired-variant",
          why: "it reached the actionable surface, but no judge ruling in its group carries its decision key, so the collapse rule folded it away and the decision list does not show it. It is a question only an analyst raised: the fold assumes a judge picked that question up, nothing verifies that assumption, so read this record rather than take the fold at its word."}
    elif (. as $r | ($folded | index($r.id)) != null)
    then {cause: "folded-elsewhere",
          why: "it reached the actionable surface, but the collapse rule attached it as a folded variant of a ruling that belongs to a DIFFERENT undertaking, so this chart cannot show it under that ruling and does not draw it as a decision of its own. Showing the ruling here would draw a record this chart does not own; showing this record as the decision would put an analyst restatement where the ruling belongs, which is the substitution the fold exists to prevent. Read this record rather than take the fold at its word."}
    elif (unresolved($done; $known) | length) > 0
    then {cause: "blocked",
          why: "blocked by another record that has not resolved, so it never reaches the actionable surface"}
    elif .hold_reason == null
    then {cause: "no-hold",
          why: "open with no hold recorded, so nothing on the record states what the captain is being asked"}
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
          why: "its id carries the -\($mis.marker)- marker, which files it under this chart as \($mis.expected), but its record kind is \(.kind), so no section of this chart could take it. It is not offered as takeable either, because a kind nobody can trust is not an invitation to pick work up. The misfiled report names this record too, with both spellings side by side."}
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

  # Why a line of the member list of this chart could not be honoured. It is a
  # hand-maintained SECOND source of membership and rots in ways an id cannot: it
  # can name a record that was deleted, one another undertaking also claims, or
  # something that is not a bare id at all. Those are different pieces of news and
  # must not share one sentence, so each gets its own name and its own words - the
  # same shape the withheld and unplaced reasons above already use.
  # Every cause but `redundant` REFUSES the entry, and refusing is not dropping:
  # the entry is still named on the chart. Under-drawing in silence is the fault
  # this whole script is built against, and it would be a poor tool that committed
  # it while reporting on it.
  # The record whose id namespace an entry already sits inside. Decided from the
  # records this chart is holding anyway, never from a roll of undertakings that
  # nobody keeps - so it costs no new contract and rots with nothing. The most
  # specific owner wins: a longer id is the nearer claim, and the shorter one has
  # its own ambiguity stated in the header already.
  # Structural evidence that an id heads an undertaking of its own, which is what
  # makes an entry naming it a record another chart owns rather than ordinary
  # retrofit material. Only hard signals count, never prose: records of its own
  # beneath it, its own member list, or its own panel question. The mere presence
  # of a data directory is deliberately excluded and the header says why.
  # This is the ONLY thing that lets an entry be owned by the id it already is,
  # and the narrowness is the whole point: any record at all could be made an
  # undertaking, so treating a bare record as one would refuse every retrofit,
  # which is the path this exists to open.
  def heads_an_undertaking($known; $roots): . as $c
    | ($roots[$c] == true) or any($known | keys_unsorted[]; startswith($c + "-"));

  def prefix_owner($known; $roots): . as $e
    | [ ($known | keys_unsorted[]) as $p
        | select($p != $chart)
        | select(($e | startswith($p + "-"))
                 or ($p == $e and ($p | heads_an_undertaking($known; $roots))))
        | $p ]
    | sort_by(length) | last;

  # The clause order is the order of the news. EXISTENCE is asked first of all,
  # right after the two checks that read the line itself, because it is a fact
  # about the record while every clause below is a fact about a claim on it, and
  # nothing can be claimed by anybody when no record answers to the id. Asked
  # last, `unresolvable` was masked the moment a second list named the same typo:
  # the page then said contested and sent the reader off to re-cut work over an id
  # that never existed, which is worse than silence because it is confidently
  # wrong. The clauses below are unaffected - `redundant` and `owned-elsewhere`
  # both required the record to exist, so `contested` is the only cause the order
  # changes. Neither states that requirement any longer: an existence test below
  # this clause can no longer decide anything, and a condition that cannot decide
  # reads as load-bearing to whoever next reasons about this order.
  # The two clauses that turn on the PREFIX rule are then asked before the ones
  # that turn on a file, because a prefix claim exists by construction and no line
  # in any list can add to it or take it away. `redundant` therefore precedes
  # `contested`: a record this chart
  # already owns by its id is not up for contest, and calling it contested printed
  # "drawn on NEITHER chart" beside a record this chart went on drawing.
  # `owned-elsewhere` sits in the same place for the mirror reason. `contested`
  # keeps the case it was written for and the only one it is now true of - two
  # lists naming a record that NO record owns by prefix - and stays ranked first
  # on the page, because it is the one that says a record is being counted towards
  # two destinations at once with nothing to break the tie. `redundant` comes last
  # because it withdraws nothing: the prefix rule has the record either way, and
  # the line merely says so twice.
  def member_list_defect($foreign; $known; $roots): . as $e
    | ($e | prefix_owner($known; $roots)) as $owner
    | if ($e | index("/")) != null
      then {id: $e, cause: "qualified",
            why: "it names a record with a home qualifier, and this chart reads ONE home - the backlog and the archive it was pointed at. Resolving it would reach into the backlog of another home and put a second owner on that home, which is the same boundary this chart already holds when it drops the records of a secondmate before anything is counted. Cross-vessel dependency is a blocked-by edge or a routed request, both of which already exist. The entry is refused rather than resolved."}
      elif ($e | test("^[A-Za-z0-9._-]+$") | not)
      then {id: $e, cause: "malformed",
            why: "it is not a bare record id: a member list carries one id per line and nothing else. Nothing here guesses what was meant, because a guess would assign a record on the authority of this chart rather than on the authority of whoever filed the line. The entry is refused rather than half-read."}
      elif $known[$e] != true
      then {id: $e, cause: "unresolvable",
            why: "no record with this id is in the backlog or the archive of this home. It was never created, it was renamed, or it lives in another home this chart deliberately does not read. It is named here rather than dropped, because a member named and missing is invisible while a member named and wrong is visible by eye - the same direction this chart takes everywhere else."}
      elif prefix_member($e)
      then {id: $e, cause: "redundant",
            why: "it is already a member by the prefix rule - its id is \"\($chart)\" or begins with \"\($chart)-\" - so this line assigns nothing and the record is drawn either way. The list is the retrofit path for work that already existed when this undertaking was named; anything named under the chart is assigned by its id alone. Two ways to assign one record put a second owner on one contract: delete the line."}
      elif $owner != null
      then {id: $e, cause: "owned-elsewhere", claimed_by: [$owner],
            why: ((if $owner == $e
                   then "its id IS the name of an undertaking of this home, and that undertaking carries records of its own beneath it, a member list, or a panel question - so it heads a chart rather than sitting on one. "
                   else "its id places it under \($owner) by construction - it begins with \"\($owner)-\", and \($owner) is a record of this home - so the prefix rule already owns it there. " end)
                  + "A member list cannot take a record the prefix rule holds: the id is what the fleet and everything that has left this vessel already go by, and a line here cannot edit that. Honouring it would draw one record on two charts, and then neither could say whether it is finished for its own purposes. The entry is refused and the record keeps drawing on \($owner). Delete the line, or re-cut the work so it really belongs to one undertaking.")}
      elif $foreign[$e] != null
      then {id: $e, cause: "contested", claimed_by: $foreign[$e],
            why: "the member list of this chart names it, and so does the list of \($foreign[$e] | join(", ")). No record owns it by prefix either, so nothing decides the tie by construction. A record belongs to at most one undertaking: counted in two \"what is left\" views it leaves neither chart able to say whether it is finished for its own purposes. This chart draws it in NEITHER rather than pick a winner. A record that genuinely fits two undertakings is evidence that one of them is cut too coarsely, or that it is really two pieces of work - both fixed by re-cutting the work, never by listing it twice."}
      else null end;

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

  # THE OTHER HALF OF MEMBERSHIP, AND IT IS A UNION RATHER THAN A REPLACEMENT.
  # See the header: the prefix rule stands untouched and everything drawing today
  # keeps drawing; this only adds the records an undertaking named OVER existing
  # work could otherwise reach in no way but by renaming them.
  # Every OTHER chart of this home claiming an id is what makes exclusivity
  # checkable at all, so the foreign claims are folded first and the entries that
  # collide with one are refused before the union is formed.
  | ([ $claims[] | select(.chart != $chart) ] | group_by(.id)
     | map({key: .[0].id, value: ([ .[].chart ] | unique)}) | from_entries) as $foreign_claims
  | ([ $listed_raw[]
       | member_list_defect($foreign_claims; $known; $chart_roots)
       | select(. != null)
       | {id, cause, claimed_by: (.claimed_by // []), why} ]) as $own_defects
  # Refused entries assign nothing. `redundant` is the one cause here that does
  # not refuse: the prefix rule already holds that record, and withdrawing it here
  # would remove a member over a line that only restated what was true anyway.
  | ([ $own_defects[] | select(.cause != "redundant") | .id ]
     | map({key: ., value: true}) | from_entries) as $refused
  | ([ $listed_raw[] | select($refused[.] != true) ]
     | map({key: ., value: true}) | from_entries) as $listed
  | def member($id): prefix_member($id) or ($listed[$id] == true);

  # THE OTHER SIDE OF THE SAME COLLISION, and the only place it can be reported:
  # the offending line sits in a list this chart does not own, so nothing above
  # can see it, and a collision visible from one side only is one nobody fixes.
  # It withdraws NOTHING here. Prefix ownership is by construction, so a record
  # cannot stop drawing on the chart whose name its id carries because a third
  # party edited a file - the foreign line is the defect, and it is the line to
  # delete. That chart refuses the entry on its own page, so the record is drawn
  # exactly once and the exclusivity above is real rather than asserted.
  ([ $foreign_claims | to_entries[]
     | select(prefix_member(.key) and $known[.key] == true)
     | {id: .key, cause: "claimed-elsewhere", claimed_by: .value,
        why: "the member list of \(.value | join(", ")) names it, and this chart owns it by construction: its id is \"\($chart)\" or begins with \"\($chart)-\". It is STILL DRAWN here. A prefix claim is not something another chart can take away by writing a line, and nothing drawing today may stop drawing because a file elsewhere was edited. The foreign line is the one to delete. This row says what THIS chart does and claims nothing about the other page: a chart reaching for a record refuses it only when the owner is visible from that side, and an owner with no records of its own beneath it, no member list and no panel question is not - which is why the report lives here, on the side that can always see it."} ]) as $foreign_defects
  | (($own_defects + $foreign_defects)
     | sort_by(if .cause == "contested" then 0
               elif .cause == "claimed-elsewhere" or .cause == "owned-elsewhere" then 1
               elif .cause == "qualified" or .cause == "malformed" then 2
               elif .cause == "unresolvable" then 3
               else 4 end)) as $member_defects

  | ([ $all[] | select(member(.id)) ]) as $mine
  # How many members the prefix rule alone would not have drawn. Counted off the
  # member records themselves rather than off the list, so the number the chart
  # prints beside `members` is measured the same way `members` is.
  | ([ $mine[] | select(prefix_member(.id) | not) ] | length) as $from_list

  # The destination, read from records the fleet already keeps, never invented here.
  | ([ $all[] | select(.id == $chart) ] | first) as $origin
  | (if $origin != null then $origin.title
     elif $question_text != "" then $question_text
     elif $report != "" then "(title not in the backlog; see the report)"
     else null end) as $dest_title

  # What the actionable surface returned for this chart, after the fold.
  # A group whose ID is not a member can still CONTAIN one: the member list
  # assigns a RECORD, while the collapse rule groups by the undertaking the
  # record id names, and a retrofitted decision keeps the id it always had.
  # Without the second branch such a record reached the actionable surface, was
  # dropped by this scoping, and was then reconciled below as never returned - a
  # false sentence, and the silent loss this chart exists against in a new hat.
  # Only the member records are taken from such a group, its folded variants
  # included. The rest belong to whatever undertaking owns that group, and
  # drawing them here would put one record on two charts.
  # A group is taken WHOLE on the PREFIX rule alone, never on the union, and that
  # is the whole reason the test differs from `member` here. A prefix member group
  # id makes every record inside it a prefix member of this chart too, by the same
  # construction - so taking it whole draws nothing this chart does not own. A
  # group id the member LIST named carries no such guarantee: the list assigns one
  # record, never the namespace around it, so its siblings are members of neither
  # rule and taking them whole is exactly the one record on two charts the
  # paragraph above refuses.
  | ([ $inv.groups[]?
       | if prefix_member(.group) then .
         else (.decisions = [ .decisions[]? | select(member(.id))
                              | .variants = [ (.variants // [])[] | select(member(.id)) ] ])
              | (.unpaired_variants = [ (.unpaired_variants // [])[] | select(member(.id)) ])
              | if ((.decisions | length) + (.unpaired_variants | length)) == 0 then empty
                else .decision_count = (.decisions | length)
                     # DISTINCT record ids, never one per (ruling, variant) pair.
                     # The fold hangs a variant under EVERY authoritative ruling
                     # whose key it matches, and the role convention admits more
                     # than one judge per group, so a variant is reachable from
                     # several rulings at once. Summing per ruling counts that one
                     # record once per ruling it pairs to, and the sentence this
                     # number is printed inside says records.
                     | .record_count = ([ .decisions[].id,
                                          .decisions[].variants[].id,
                                          .unpaired_variants[].id ] | unique | length)
                end
         end ]) as $groups
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
  # The one member record the scoping above cannot take: the fold hung it as a
  # variant under a ruling of ANOTHER undertaking. Neither move is open - showing
  # it under that ruling would draw a record this chart does not own, and lifting
  # it onto the decision list would put an analyst restatement where the ruling
  # belongs. So no section carries it, and it is reconciled below with a cause
  # that says the surface DID return it, rather than with `not-returned`, a
  # sentence the very surface it describes refutes.
  # The test is `prefix_member` for the same reason the scoping above uses it, and
  # the two have to stay the same test: every group the scoping filters rather
  # than takes whole is a group that can drop a member variant this way, so a
  # narrower test here would put the loss straight back for the groups the wider
  # one no longer takes whole.
  # DEDUPED TWICE, AND BOTH HALVES ARE LOAD-BEARING. `unique` for the same reason
  # `record_count` above counts distinct ids: such a record pairs to every
  # non-member ruling sharing its key, and it is still one record. Then the ids
  # $seen ALREADY holds are dropped, because a group can carry a member ruling and
  # a non-member ruling at once - the fold hangs one variant under every
  # authoritative ruling whose key matches, and a group admits several judges - so
  # one member variant can be kept under the member ruling and hang under the
  # non-member one in the same breath. It is drawn, so it is not folded away.
  # (An earlier revision deduped with `unique` alone, on the premise stated one
  # line further down that the fold DROPPED every folded-elsewhere record so no
  # group could carry one. False for exactly the overlap above: with two judges in
  # one non-prefix group and both a ruling and its variant listed, the chart drew
  # the variant under the kept ruling and counted it a second time as folded away
  # - 3 records and 2 folded for the 2 records it held, with no withheld row to
  # account for the third. It is recorded rather than swapped out, because a
  # premise that reads as obviously true is one the next reader will re-adopt.)
  # Nothing is lost by the exclusion: a record in `$seen` is filtered out below
  # before `withheld_reason` is ever reached, so it could produce no withheld row
  # of any cause either way.
  # Array subtraction rather than a select on `index`: `$seen | index(.)` binds `.`
  # to `$seen` itself, so it asks whether the array contains itself, answers 0 for
  # every non-empty `$seen`, and silently empties the list it was meant to filter.
  # That is the same jq scoping trap as the false measurement in the header, and
  # it survived a round here because the fixtures that exercised the exclusion all
  # had an EMPTY `$seen`, where the wrong expression happens to answer null.
  | (([ $inv.groups[]? | select(prefix_member(.group) | not)
        | .decisions[]? | select(member(.id) | not)
        | .variants[]? | select(member(.id)) | .id ]
      | unique) - $seen) as $folded_elsewhere
  # THE MIRROR OF THE ABOVE, AND THE SIDE THAT WAS SILENT. Here the RULING is the
  # member - a member list retrofitted it out of a group this chart does not own -
  # and the record the fold hung beneath it is not. The scoping strips it, because
  # drawing it would put one record on two charts. Stripping it silently is the
  # other thing that cannot happen: `limits[0]` on this very page promises that
  # every folded record stays listed underneath the ruling, and a page that keeps
  # that promise for the groups it owns whole while dropping it for a retrofitted
  # ruling has printed a limit its own content refutes. Measured before this
  # existed: one ruling drawn with `variants: []`, `folded` 0, `withheld` 0, and
  # the promise printed verbatim, while the board held the restatement.
  # So the record is NAMED in `withheld[]` and drawn nowhere. Exclusivity forbids
  # COUNTING one record in two what-is-left views; `withheld[]` is a reconciliation
  # report rather than such a view, so naming is not counting and the rule is
  # untouched. It stays out of `decisions[]`, out of every `variants[]`, and out of
  # `takeable[]`.
  # Only variants PAIRED under a kept ruling qualify. A stripped
  # `unpaired_variant` was folded under no ruling at all - the board shows it at
  # group level - so `limits[0]` says nothing about it and naming it here would
  # widen this page to records nothing on it promised.
  | (([ $inv.groups[]? | select(prefix_member(.group) | not)
        | .decisions[]? | select(member(.id))
        | (.variants // [])[] | select(member(.id) | not) | .id ]
      | unique) - $seen) as $stripped_variants
  # What the actionable surface returned for the records of this chart, counted in
  # distinct records. No group carries a folded-elsewhere or a stripped record -
  # that is true by construction rather than by premise, since the ids the groups
  # do carry are the ones both lists just excluded - but the surface returned them
  # all the same, and a page that says 0 reached it, four lines above a row whose
  # why says one did, teaches a reader to stop believing every other number on it.
  | (([ $groups[] | .record_count ] | add // 0)
     + ($folded_elsewhere | length)) as $records_returned
  # The stripped variants are counted APART, and that separation is the whole
  # point. `records_returned` is printed under a sentence that says records of
  # THIS chart, and a stripped variant belongs to the undertaking its own id
  # names - which is the entire reason it is named rather than drawn. Adding it
  # here once made the page say "2 captain-gated records in the backlog for this
  # chart" for a chart holding exactly one, and a count that overstates what a
  # chart holds is the same fault as one that understates it.
  | ($stripped_variants | length) as $records_named_not_owned

  # RECONCILIATION. Every record this chart owns that waits on the captain,
  # straight from the backlog - then whatever the actionable surface did not
  # return. The test is the KIND, never the identifier, so the record kind IS the
  # thing while a name is only what it happens to be called. Keying on
  # `-decision-` in the id would leave a blocked captain record named any other
  # way not merely undercounted but invisible, every count reading zero - the same
  # silent loss this chart exists against, on a third flank.
  # This baseline stays narrower than the captain-actionable predicate, which
  # admits any queued record held with `hold-kind: captain`. That is deliberate:
  # an UNBLOCKED record of some other kind now reaches `decisions_open` on its own
  # and is drawn from the inventory, so naming it here would only reconcile it
  # against a surface that already carries it. A BLOCKED one reaches neither: the
  # predicate fails it on the blocker and this line fails it on the kind, so it is
  # recovered nowhere as a decision and lands in `unplaced[]` under cause
  # `blocked`, named by kind and blocker but never as a question put to the
  # captain. It behaved identically before 2026-08-09, so that is not a loss this
  # line introduced, and staying narrow here is deliberate.
  | ([ $mine[] | select(open_state and .kind == "captain") ]) as $own_decision_records
  # The stripped rows are built apart from the member ones because they are the
  # one entry here that is NOT a record of this chart, so no reason function that
  # runs over the members could ever reach them, and their cause is decided by
  # where the fold put them rather than by anything on the record.
  | ([ $stripped_variants[] as $sv
       | ([ $all[] | select(.id == $sv) ] | first)
       | select(. != null)
       | {id, key:(.id | dkey), title:(.title // ""),
          held_by:(unresolved($done; $known) | join(", ")),
          cause: "non-member-variant",
          why: "it reached the actionable surface, and the collapse rule paired it as a folded variant under a ruling THIS chart draws out of a group this chart does not own. How that ruling came to be a member of this chart does not matter here and is deliberately not claimed: the prefix rule alone reaches this shape whenever a chart id is a panel seat, because the collapse rule groups by the origin with the seat stripped off. The ruling is a member of this chart; this record is not, and it belongs to the undertaking its own id names, so drawing it beneath that ruling would count one record towards two destinations and neither could then say whether it is finished. It is NAMED here and drawn nowhere, so that the promise above - that every record the fold hung beneath a ruling stays listed under it - is kept on this page rather than quietly qualified. Naming is not counting: read the record itself on the chart of the undertaking it belongs to."} ]) as $stripped_rows
  | (([ $own_decision_records[]
        | select(.id as $id | ($seen | index($id)) == null)
        | withheld_reason($done; $live_done; $known; $unpaired; $folded_elsewhere) as $reason
        | {id, key:(.id | dkey), title:(.title // ""),
           held_by:(unresolved($done; $known) | join(", ")),
           cause: $reason.cause,
           why: $reason.why} ]) + $stripped_rows) as $withheld

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
  # same wrong invitation wearing a typo: the FOG or OUT OF COURSE section its id
  # names is drawn without it at the same moment the chart advertises it as work
  # to pick up. An ordinary kind carrying no chart marker is untouched and stays
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

  # THE SWAP EVERY OTHER REPORT ON THIS CHART IS BLIND TO.
  # The two filing commands in AGENTS.md section 10 differ in one word, so the
  # likeliest slip of all is a boundary filed with the fog kind or the reverse.
  # Such a record is PLACED - the fog filter takes it - so nothing that asks
  # "did any section draw this member" can ever see it, and the section its id
  # names renders 0. That is this whole change in miniature: an empty section is
  # read as a claim about the course, and here the claim is refuted by a record
  # already on the same page. So the cross-check runs over EVERY open member
  # rather than only the leftovers, and reports on its own surface - unplaced[]
  # means members no section drew, and stretching it to hold records that ARE
  # drawn would cost that sentence its meaning.
  # WHERE the record went is LOOKED UP in the arrays this chart emits, and this
  # runs last so that every one of them exists to be read. Deciding it from a
  # second copy of the section predicates answers only for the kinds whoever
  # wrote the copy thought of: it sent every misfiled captain record to a report
  # that did not carry it, which is the one thing a report pointing somewhere
  # must never do. The arrays answer for the chart that was actually drawn.
  # The same standard applies to the section named as short. It is asked whether
  # that section is genuinely empty rather than assumed, because one misfiled
  # record does not stop another record filing correctly beside it.
  # This REPORTS the disagreement and stops there. That the marker and the kind
  # are two independent spellings able to disagree at all is a separate question,
  # filed as `fm-seekarte-zwei-kodierungen-widersprechen-sich`; nothing here
  # unifies them, derives one from the other, or picks a winner.
  # A record with no kind at all is left to the no-kind cause instead, which
  # already names the one missing field: it disagrees with nothing, it is simply
  # not filled in, and reporting it twice would blunt both reports.
  | ([ $mine[]
       | select(open_state)
       | select(.id != $chart)
       | select(.kind != null)
       | . as $r
       | marker_kind_mismatch as $mis
       | select($mis != null)
       | (if ([ $fog[].id ] | index($r.id)) != null then "FOG"
          elif ([ $out_of_course[].id ] | index($r.id)) != null then "OUT OF COURSE"
          elif ([ $open_decisions[].id ] | index($r.id)) != null then "OPEN DECISIONS"
          elif ([ $open_decisions[] | .variants[]? | .id ] | index($r.id)) != null then "OPEN DECISIONS, folded under the ruling it restates"
          elif ([ $withheld[].id ] | index($r.id)) != null then "WITHHELD"
          elif ([ $takeable[].id ] | index($r.id)) != null then "TAKEABLE NOW"
          elif ([ $unplaced[].id ] | index($r.id)) != null then "UNPLACED"
          else null end) as $drawn
       | (if $mis.marker == "fog" then ($fog | length) == 0
          else ($out_of_course | length) == 0 end) as $named_is_empty
       | {id, title:(.title // ""),
          marker: $mis.marker, kind: .kind,
          belongs_as: $mis.expected, belongs_in: $mis.section,
          drawn_in: $drawn,
          why: ("its id carries the -\($mis.marker)- marker, which files it under this chart as \($mis.expected), but its record kind is \(.kind). Every section here places a member by its kind, so "
                + (if $drawn == null then "this chart cannot say which of its sections ended up carrying it"
                   elif $drawn == "UNPLACED" then "no section drew it at all and the unplaced report names it too"
                   else "this record is drawn under \($drawn)" end)
                + (if $named_is_empty
                   then ", while \($mis.section) renders as if this course had none of them"
                   else ", and \($mis.section) is drawn without it" end)
                + ". One of the two spellings is wrong and the chart cannot tell which: correct the kind to \($mis.expected), or rename the id if this record is not that.")} ]) as $misfiled

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
      # The rule line has to stay true of the chart it is printed on, so it names
      # BOTH sources when both are in play and neither more than it did before
      # when only the prefix rule is. A chart with no member list reads exactly as
      # it always has, because that sentence is still the whole of what determined
      # its membership.
      membership: {
        rule: ("id is \"\($chart)\" or begins with \"\($chart)-\"; a longer undertaking sharing this prefix is drawn here too, which is the recoverable direction"
               + (if $member_file == "" then ""
                  else ", plus \($from_list) \(if $from_list == 1 then "record" else "records" end) named in \($member_file), which is how an undertaking named over work that already existed takes that work in without renaming it"
                  end)),
        members: ($mine | length),
        list: (if $member_file == "" then null else $member_file end),
        from_list: $from_list
      },
      membership_defects: $member_defects,
      decided: $decided,
      decisions: $open_decisions,
      withheld: $withheld,
      fog: $fog,
      out_of_course: $out_of_course,
      takeable: $takeable,
      unplaced: $unplaced,
      misfiled: $misfiled,
      counts: {
        # Both sides are drawn from the same home, so the first can never be the
        # smaller. The guard is here anyway: printing arithmetic that cannot be
        # true teaches a reader to stop believing the numbers, which is worse
        # than any single wrong one.
        records_in_backlog: ([ ($own_decision_records | length),
                               $records_returned ] | max),
        records: $records_returned,
        decisions: ($open_decisions | length),
        folded: ($records_returned - ($open_decisions | length)),
        withheld: ($withheld | length),
        # How many of those the fold dropped rather than the surface never
        # returning. Without it a folded variant is counted once above and once
        # below with nothing saying they are the same record, and arithmetic a
        # reader cannot reconcile is the same fault as arithmetic that is wrong.
        # Every cause that describes a record OF THIS CHART that the surface
        # returned belongs here, and for the same reason: each is counted in
        # `folded` above and in `withheld` below, and this is the only number
        # that says they are one record.
        # `non-member-variant` is deliberately NOT one of them, and the reason is
        # the same line the counts above are drawn on: that record is not this
        # chart to fold. It never entered `records` or `folded`, so claiming it
        # here would reconcile it against a number that never held it - and the
        # page would then read "0 folded away" two lines above "1 of them folded
        # away". It has its own count below, under a sentence that is true of it.
        withheld_folded: ([ $withheld[]
                            | select(.cause as $c | (own_returned_causes | index($c)) != null) ] | length),
        # Records the fold hung beneath a ruling this chart draws, which belong to
        # another undertaking and are named rather than drawn. Counted so they are
        # never invisible, and counted apart so no sentence above has to stretch.
        named_not_owned: $records_named_not_owned,
        possibly_answered: ($possibly_answered | length),
        unplaced: ($unplaced | length),
        unplaced_kind_defects: ([ $unplaced[] | select(.kind_defect) ] | length),
        misfiled: ($misfiled | length),
        membership_defects: ($member_defects | length)
      },
      possibly_answered: $possibly_answered,
      # Printed ON the chart, not filed in documentation. A chart that names its
      # own gaps is the counter-design to the flat list that was wrong four times
      # in one week. Do not soften these when rendering.
      # The last entry is appended only when a member list is in play - this
      # chart having one, or another chart having named a record of this one. A
      # limit is a claim about the page it is printed on, and a caveat about a
      # list nothing on this page came from would be one more sentence a reader
      # has to check against nothing.
      limits: ([
        "Where a judge ruled, this chart shows the formulation the judge gave. That the judge picked up every question the analysts raised is verified by nothing, so every folded record stays listed underneath.",
        # The exception clause is extended on the FACT that a folded-elsewhere row
        # is on this page, never on a proxy for it. A limit is a claim about the
        # page it is printed on, so only what that page carries may decide it.
        # (An earlier revision gated it on whether a member list was read, and
        # said so here: that `folded-elsewhere` could not arise without one, so on
        # a listless chart the shorter sentence was the whole truth. That premise
        # is false. The collapse group is the origin with its panel role stripped,
        # so on any chart whose id ends in -a, -b or -judgeN - the seat convention
        # this home actually uses - the group is the seat above it rather than the
        # chart, the whole-group branch is not taken, and a folded-elsewhere row
        # arises with no member list anywhere. Reproduced on chart voy-a holding
        # voy-a, voy-a-decision-shape and voy-judge-decision-shape with no members
        # file: the row printed beneath the shorter sentence, which is the
        # incomplete disclosure this clause exists to close. It is recorded rather
        # than quietly swapped, because the list reads as an obviously sufficient
        # proxy on a second reading and is one the next reader would re-adopt.)
        ("Withheld decisions are found within the scope of THIS chart, by reading its own records back from the backlog. For every cause but unpaired-variant the fleet-wide decision board cannot count them at all, so a number here does not mean the board agrees; an unpaired variant is the one the board does list, as a variant of its group rather than as a decision."
         + (([ $withheld[]
               | select(.cause as $c | (board_carried_causes | index($c)) != null)
               | select(.cause != "unpaired-variant") | .cause ] | unique) as $also
            | if ($also | length) == 0 then ""
              else " This chart also carries \($also | join(" and ")), and the board does count those too, as a variant under the ruling of the undertaking whose id each record bears." end)),
        "This chart reads ONE home, the one it was pointed at. A decision recorded in a secondmate home is dropped before anything here is counted, because a secondmate owns its own undertakings and its own backlog. Nothing on this chart says anything about them, in either direction.",
        "Fog is whatever somebody wrote down as fog. Nothing proves this course has no other dark patches.",
        "An unsupervised marking means the work may be EDITED unsupervised. It never means it may LAND unsupervised.",
        "Whether a piece of work is destructive, irreversible, security-sensitive, or outward-facing is recorded nowhere per record and is not derived here; that judgment stays the always-loaded rule in AGENTS.md sections 7 and 9.",
        "A decision the captain rejects outright cannot be filed away today, because the closing path requires follow-up work that a refusal does not create. Such a decision can be shown here but not laid to rest."
      ] + (if $member_file == "" and ($member_defects | length) == 0 then []
           else ["Membership beyond the prefix rule is whatever a member list in this home names. Two member lists naming one record are caught here and the record is drawn on neither chart. A listed record sitting inside ANOTHER undertaking prefix namespace is caught too, whenever that owner is itself a record of this home: it keeps drawing on its owner, the chart that listed it refuses the entry, and both pages say so. What is NOT caught is an owner that is a bare record - nothing of its own filed beneath it, no member list, no panel question - because from the reaching side that is indistinguishable from ordinary work an undertaking was named over, which is exactly what a member list is for. Such a record is still reported on the page of the chart that owns it."]
           end))
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
       then " (\(.counts.withheld_folded) of them folded away rather than never returned)"
       else "" end),
    # On its own line, and outside the "of those" arithmetic above, because these
    # records are not this chart to count. Folding them into that sentence made
    # the page claim more captain-gated records in the backlog than the chart
    # holds; leaving them off it entirely would hide them. Named, counted, apart.
    (if .counts.named_not_owned > 0
     then "    named but not owned by this chart: \(.counts.named_not_owned) - the fold hung \(if .counts.named_not_owned == 1 then "it" else "them" end) beneath a ruling drawn here, and \(if .counts.named_not_owned == 1 then "it belongs" else "they belong" end) to the undertaking \(if .counts.named_not_owned == 1 then "its" else "their" end) own id names"
     else empty end),
    "  possibly already answered: \(.counts.possibly_answered)",
    "",
    "members: \(.membership.members)   rule: \(.membership.rule)",
    (if .counts.unplaced > 0 then
      "  of those, \(.counts.unplaced) could not be placed in any section - see UNPLACED" +
      (if .counts.unplaced_kind_defects > 0
       then " (\(.counts.unplaced_kind_defects) carrying a kind this chart cannot classify)"
       else "" end) else empty end),
    (if .counts.membership_defects > 0 then
      "  \(.counts.membership_defects) \(if .counts.membership_defects == 1 then "line" else "lines" end) of a member list in this home could not be honoured - see MEMBER LIST"
      else empty end),
    "",
    # Directly under the member count, because that is the number these rows call
    # into question: a refused entry is a record the reader was told belongs here
    # and the chart is not drawing, and a foreign claim is a record the reader may
    # have been told belongs somewhere else while this chart goes on drawing it.
    (if (.membership_defects | length) > 0 then
      (if .membership.list == null
       then "MEMBER LIST - entries in the member lists of this home this chart could not honour:"
       else "MEMBER LIST - entries in \(.membership.list), and in the member lists of other charts, this chart could not honour:" end),
      (.membership_defects[]
        | "  ! \(.id)  [\(.cause)]"
          + (if (.claimed_by | length) > 0 then "  also claimed by: \(.claimed_by | join(", "))" else "" end)
          + "\n      \(.why)"),
      "" else empty end),
    (if (.unplaced | length) > 0 then
      "UNPLACED - members this chart counted and drew in no section:" else empty end),
    # Kind defects first and under their own heading, because they are the ones
    # that can leave a section reading empty while the course is not. Routine
    # held or blocked work is reported too - a silent gap is what this exists
    # against - but it must never be what a reader meets first.
    (if .counts.unplaced_kind_defects > 0 then
      "  KIND DEFECTS - the kind on these is missing, unrecognised, or at odds with the id:",
      (.unplaced[] | select(.kind_defect)
        | "  ? \(.id)  [kind: \(.kind // "none")\(if .hold_kind == null then "" else ", hold-kind: \(.hold_kind)" end)]\n      \(.why)")
      else empty end),
    (if ((.unplaced | length) - .counts.unplaced_kind_defects) > 0 then
      "  HELD OR BLOCKED - ordinary work this chart has no section for; the kind is not the fault here:",
      (.unplaced[] | select(.kind_defect | not)
        | "  ? \(.id)  [kind: \(.kind // "none")\(if .hold_kind == null then "" else ", hold-kind: \(.hold_kind)" end)]\n      \(.why)")
      else empty end),
    (if (.unplaced | length) > 0 then "" else empty end),
    # Above the sections it calls into question, because it is the one report
    # whose subject is a row the reader would otherwise believe.
    (if (.misfiled | length) > 0 then
      "MISFILED - the id marker and the record kind of these members disagree:",
      (.misfiled[] | "  ! \(.id)  [marker: -\(.marker)-, kind: \(.kind)\(if .drawn_in == null then "" else ", drawn under \(.drawn_in)" end)]\n      \(.why)"),
      "" else empty end),
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
