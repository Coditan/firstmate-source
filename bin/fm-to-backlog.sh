#!/usr/bin/env bash
# fm-to-backlog.sh - file ONE approved breakdown into the backlog, in dependency
# order, under the originating undertaking's own id.
#
# PROVENANCE - THIS ADOPTS TO-TICKETS, IT DOES NOT INVENT IT
# The design this serves - tracer-bullet units sized to one working session,
# each declaring the units that block it, published blockers-first so every edge
# names an identifier that already exists, and the frontier read off those edges
# - comes from the to-tickets skill by Matt Pocock,
# https://github.com/mattpocock/skills, used under the MIT licence
# (Copyright (c) 2026 Matt Pocock). No to-tickets code is vendored here -
# to-tickets ships none, and this script is wholly our own. What is ours: the
# backlog item as the unit, the id composed under the originating undertaking so
# the unit lands on that undertaking's sea chart, and the refusals below.
# docs/to-backlog-provenance.md carries the licence text, the full accounting of
# what was kept, changed, and dropped, and the cost of each omission.
#
# WHAT THIS OWNS, AND WHAT IT DELIBERATELY DOES NOT
# .agents/skills/to-backlog owns the procedure: gathering the source, slicing,
# sizing, and the captain's approval. By the time this script runs the captain
# has already approved the breakdown. This script owns only the mechanical half,
# which is the half agent memory gets wrong: dependency order, cycles, the id
# prefix, and whether each unit actually carries what it delivers and at least
# one acceptance criterion. It decides nothing and it sizes nothing.
# It is NOT a second backlog. Every write is a `tasks-axi` call in FM_HOME.
#
# WHY THE ORIGIN MUST ALREADY EXIST
# The id of every unit is <origin>-<slug>, which is the prefix rule
# bin/fm-sea-chart.sh already uses to decide chart membership, so filing here is
# what puts a unit on the originating undertaking's chart. An origin that is not
# in the backlog has no title, so the chart it feeds would have no destination
# and refuse to draw. Refusing here reports that at filing time instead, where
# it is cheap to fix, rather than leaving orphan units nobody's chart shows.
#
# WHY THREE KINDS ARE REFUSED
# `captain` is the kind durable captain decisions carry, and those are owned by
# bin/fm-decision-hold.sh under .agents/skills/decision-hold-lifecycle. This
# script never calls `tasks-axi hold`, and a hold is what
# bin/fm-fleet-snapshot.sh reads for captain-actionability, so the refusal is
# about ownership rather than the surface. `fog` and
# `out-of-course` are the sea chart's own kinds, spelled by
# bin/fm-chart-kinds-lib.sh and carried on `-fog-`/`-oos-` ids this script does
# not compose. Slicing work must never manufacture a record of any of the three
# as a side effect, so all three are refused rather than filed with a warning.
#
# WHY EVERY WRITE IS IDEMPOTENT
# `tasks-axi add` is a no-op on an id that already exists and `tasks-axi block`
# is a no-op on an edge that already exists, so a run interrupted halfway can be
# repeated and converges. The trade is that an existing id is REPORTED and left
# alone rather than rewritten: a hand-edited body is never clobbered, and a slug
# that collides with unrelated work is visible in the report as `exists` instead
# of silently overwriting it. `add` does not apply --blocked-by to a record that
# already exists, so edges are always filed by a separate `block` call.
#
# Usage:
#   fm-to-backlog.sh check <breakdown.json>   validate and print the ordered
#                                             plan; writes nothing
#   fm-to-backlog.sh file <breakdown.json>    validate, then file in that order
#   fm-to-backlog.sh --help
#
# Breakdown file (JSON):
#   {
#     "origin": "<existing backlog id this is a breakdown of>",
#     "repo":   "<optional repo name applied to every unit>",
#     "kind":   "<optional default kind for every unit; default ship>",
#     "units": [
#       {
#         "slug":       "<slug appended to the origin id>",
#         "title":      "<one line, no parentheses>",
#         "delivers":   "<the end-to-end behaviour this unit makes work>",
#         "acceptance": ["<one line>", "..."],
#         "blocked_by": ["<slug in this file>", "<existing backlog id>"],
#         "kind":       "<optional, overrides the default>",
#         "priority":   0
#       }
#     ]
#   }
#
# A `blocked_by` entry naming a slug in this same file is an internal edge; any
# other entry must already exist in the backlog. A slug wins over a backlog id of
# the same spelling, so a breakdown is always readable on its own terms.
# No entry may name the origin itself: a breakdown may never close the
# undertaking it is a slice of, so that edge could never clear.
#
# A slug may not compose `-decision-` into the id either. bin/fm-decision-hold.sh
# owns that spelling for a captain hold and bin/fm-sea-chart.sh reads the marker
# positionally rather than by kind, so an ordinary unit carrying it would drop
# out of the chart's takeable work and, once Done, be listed as a settled captain
# decision.
#
# Exit status is 0 on success and 1 on any refusal. Every refusal names the unit
# and the exact fault, and nothing is filed after one: `check` runs the whole
# validation before `file` writes anything.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-axi-path-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-chart-kinds-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-chart-kinds-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-to-backlog: %s\n' "$*" >&2
  exit 1
}

axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_title() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
    # The backlog record spells its own fields as "(repo: x) (kind: y)", so a
    # parenthesis in a title is parsed as a field rather than as prose. This is
    # the same refusal tasks-axi makes for a hold reason.
    *'('*|*')'*) fail "$label must not contain parentheses: $value" ;;
  esac
}

MODE=${1:-}
case "$MODE" in
  --help|-h|help) usage; exit 0 ;;
  check|file) : ;;
  '') usage >&2; exit 1 ;;
  *) fail "unknown command: $MODE (expected check or file)" ;;
esac

FILE=${2:-}
[ -n "$FILE" ] || fail "$MODE requires a breakdown file"
[ -f "$FILE" ] || fail "breakdown file not found: $FILE"

command -v jq >/dev/null 2>&1 || fail "jq is required"
jq -e . "$FILE" >/dev/null 2>&1 || fail "breakdown file is not valid JSON: $FILE"

# --- structural validation --------------------------------------------------
#
# One jq pass reports every type fault in the document rather than the first, so
# a malformed breakdown is fixed in one edit instead of one refusal at a time.

STRUCT_ERRORS=$(jq -r '
  [
    (if (type) != "object" then "the breakdown must be a JSON object" else empty end),
    (if (.origin? | type) != "string" then "origin must be a string" else empty end),
    (if (.units? | type) != "array" then "units must be an array"
     elif (.units | length) == 0 then "units must not be empty"
     else empty end),
    (if (.units? | type) == "array" then
      (.units | to_entries[] | .key as $k | .value as $u |
        if ($u | type) != "object" then "units[\($k)] must be an object"
        elif ($u.slug | type) != "string" then "units[\($k)].slug must be a string"
        elif ($u.title | type) != "string" then "units[\($k)].title must be a string"
        elif ($u.delivers | type) != "string" then "units[\($k)].delivers must be a string"
        elif (($u.acceptance // []) | type) != "array" then "units[\($k)].acceptance must be an array"
        elif (($u.acceptance // []) | length) == 0 then "units[\($k)].acceptance must list at least one criterion"
        elif (($u.acceptance // []) | any(type != "string")) then "units[\($k)].acceptance must contain only strings"
        # Each criterion becomes one "- [ ]" line in the record body, so a
        # multi-line string would spill into an unchecked continuation line.
        elif (($u.acceptance // []) | any(test("\n"))) then "units[\($k)].acceptance criteria must each be one line"
        elif (($u.blocked_by // []) | type) != "array" then "units[\($k)].blocked_by must be an array"
        elif (($u.blocked_by // []) | any(type != "string")) then "units[\($k)].blocked_by must contain only strings"
        else empty end)
     else empty end)
  ] | .[]
' "$FILE") || fail "could not read the breakdown file: $FILE"

if [ -n "$STRUCT_ERRORS" ]; then
  printf 'fm-to-backlog: %s\n' "$STRUCT_ERRORS" >&2
  exit 1
fi

ORIGIN=$(jq -r '.origin' "$FILE")
REPO=$(jq -r '.repo // ""' "$FILE")
DEFAULT_KIND=$(jq -r '.kind // "ship"' "$FILE")
UNIT_COUNT=$(jq -r '.units | length' "$FILE")

validate_slug origin "$ORIGIN"
[ -z "$REPO" ] || validate_slug repo "$REPO"
validate_slug kind "$DEFAULT_KIND"

reserved_kind() {  # <kind>
  local kind=$1
  [ "$kind" = captain ] && return 0
  fm_chart_kind_p "$kind"
}

# --- per-unit validation ----------------------------------------------------

declare -a SLUG TITLE KIND DELIVERS PRIORITY ID DEPS_INT DEPS_EXT INDEG DEPENDENTS
i=0
while [ "$i" -lt "$UNIT_COUNT" ]; do
  SLUG[i]=$(jq -r --argjson i "$i" '.units[$i].slug' "$FILE")
  TITLE[i]=$(jq -r --argjson i "$i" '.units[$i].title' "$FILE")
  DELIVERS[i]=$(jq -r --argjson i "$i" '.units[$i].delivers' "$FILE")
  KIND[i]=$(jq -r --argjson i "$i" --arg d "$DEFAULT_KIND" '.units[$i].kind // $d' "$FILE")
  PRIORITY[i]=$(jq -r --argjson i "$i" '.units[$i].priority // "" | tostring' "$FILE")

  validate_slug "units[$i].slug" "${SLUG[i]}"
  validate_title "units[$i].title" "${TITLE[i]}"
  [ -n "$(printf '%s' "${DELIVERS[i]}" | tr -d '[:space:]')" ] \
    || fail "units[$i] (${SLUG[i]}) must say what it delivers"
  validate_slug "units[$i].kind" "${KIND[i]}"
  if reserved_kind "${KIND[i]}"; then
    fail "units[$i] (${SLUG[i]}) may not be filed as kind ${KIND[i]}: captain decisions belong to bin/fm-decision-hold.sh, and $FM_CHART_KINDS belong to the sea chart's own markers"
  fi
  case "${PRIORITY[i]}" in
    ''|[0-4]) : ;;
    *) fail "units[$i] (${SLUG[i]}) priority must be 0-4, got ${PRIORITY[i]}" ;;
  esac

  ID[i]="$ORIGIN-${SLUG[i]}"
  [ "${ID[i]}" != "$ORIGIN" ] || fail "units[$i] slug must not be empty"

  # A slug that introduces `-decision-` composes an id bin/fm-decision-hold.sh
  # already owns, which spells a hold as <origin>-decision-<key>, and
  # bin/fm-sea-chart.sh reads that marker POSITIONALLY rather than by kind (its
  # `dkey`, bin/fm-sea-chart.sh lines 291-293). A perfectly ordinary `ship` unit
  # carrying it is therefore dropped from TAKEABLE (bin/fm-sea-chart.sh:423) and,
  # once Done, listed under DECIDED (bin/fm-sea-chart.sh:391) as though the
  # captain had settled it. This is refused rather than written down as an
  # accepted limit, because a limit that silently swallows units is missed on
  # reading and a refusal is not - which is the exact defect this script exists
  # to prevent - and because refusing keeps the header's claim true.
  # Only `-decision-` is refused. The neighbouring marker("fog") and
  # marker("oos") parses at bin/fm-sea-chart.sh lines 413 and 416 are gated on
  # .kind, and both of those kinds are already refused just above, so no slug can
  # reach them and this refusal must not be widened without a new reason.
  case "${ID[i]}" in
    *-decision-*)
      fail "units[$i] (${SLUG[i]}) may not compose the id ${ID[i]}: it carries the reserved -decision- marker, which bin/fm-decision-hold.sh owns and bin/fm-sea-chart.sh parses positionally rather than by kind, so this unit would be dropped from the chart's takeable work and later read as a settled captain decision"
      ;;
  esac

  j=0
  while [ "$j" -lt "$i" ]; do
    [ "${SLUG[j]}" != "${SLUG[i]}" ] || fail "duplicate slug in the breakdown: ${SLUG[i]}"
    j=$((j + 1))
  done

  acc=0
  while read -r line; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] \
      || fail "units[$i] (${SLUG[i]}) has an empty acceptance criterion"
    acc=$((acc + 1))
  done <<EOF
$(jq -r --argjson i "$i" '.units[$i].acceptance[]' "$FILE")
EOF
  [ "$acc" -gt 0 ] || fail "units[$i] (${SLUG[i]}) must list at least one acceptance criterion"

  INDEG[i]=0
  DEPENDENTS[i]=""
  i=$((i + 1))
done

# Edges are resolved only once every slug is known, so a unit may name a
# blocker that appears later in the file: the file's order is the author's, and
# the dependency order is computed below.
i=0
while [ "$i" -lt "$UNIT_COUNT" ]; do
  DEPS_INT[i]=""
  DEPS_EXT[i]=""
  while read -r dep; do
    [ -n "$dep" ] || continue
    validate_slug "units[$i].blocked_by" "$dep"
    target=""
    j=0
    while [ "$j" -lt "$UNIT_COUNT" ]; do
      if [ "${SLUG[j]}" = "$dep" ]; then
        target=$j
        break
      fi
      j=$((j + 1))
    done
    if [ -n "$target" ]; then
      [ "$target" != "$i" ] || fail "unit ${SLUG[i]} is blocked by itself"
      DEPS_INT[i]="${DEPS_INT[i]} $target"
    else
      # The origin is the undertaking every unit here is a slice of, and the
      # skill forbids ever closing it (.agents/skills/to-backlog/SKILL.md step 6,
      # "Never close or modify the originating item"), so an edge onto it can
      # never clear: the unit would sit in `tasks-axi ready` forever and never
      # reach the frontier. That is the same unsatisfiable-edge class the cycle
      # refusal below exists to catch, and self-reference through the origin
      # escapes it only because the origin is not one of this breakdown's own
      # slugs, which is why the refusal is stated separately here.
      [ "$dep" != "$ORIGIN" ] \
        || fail "unit ${SLUG[i]} is blocked by its own origin $ORIGIN, which a breakdown may never close, so that edge could never clear"
      DEPS_EXT[i]="${DEPS_EXT[i]} $dep"
    fi
  done <<EOF
$(jq -r --argjson i "$i" '(.units[$i].blocked_by // [])[]' "$FILE")
EOF
  i=$((i + 1))
done

# --- dependency order, and the cycle refusal --------------------------------

i=0
while [ "$i" -lt "$UNIT_COUNT" ]; do
  for dep in ${DEPS_INT[i]}; do
    INDEG[i]=$((INDEG[i] + 1))
    DEPENDENTS[dep]="${DEPENDENTS[dep]} $i"
  done
  i=$((i + 1))
done

declare -a QUEUE ORDER
QUEUE=()
ORDER=()
i=0
while [ "$i" -lt "$UNIT_COUNT" ]; do
  if [ "${INDEG[i]}" -eq 0 ]; then
    QUEUE+=("$i")
  fi
  i=$((i + 1))
done

qhead=0
while [ "$qhead" -lt "${#QUEUE[@]}" ]; do
  cur=${QUEUE[qhead]}
  qhead=$((qhead + 1))
  ORDER+=("$cur")
  for d in ${DEPENDENTS[cur]}; do
    INDEG[d]=$((INDEG[d] - 1))
    if [ "${INDEG[d]}" -eq 0 ]; then
      QUEUE+=("$d")
    fi
  done
done

if [ "${#ORDER[@]}" -ne "$UNIT_COUNT" ]; then
  stuck=""
  i=0
  while [ "$i" -lt "$UNIT_COUNT" ]; do
    if [ "${INDEG[i]}" -gt 0 ]; then
      stuck="$stuck ${SLUG[i]}"
    fi
    i=$((i + 1))
  done
  fail "the blocking edges contain a cycle, so nothing in it can ever start:$stuck"
fi

# --- existence checks against the live backlog ------------------------------

AXI_OK=0
if command -v tasks-axi >/dev/null 2>&1 && fm_tasks_axi_compatible; then
  AXI_OK=1
fi

declare -a EXISTS
ORIGIN_TITLE=""
if [ "$AXI_OK" -eq 1 ]; then
  axi show "$ORIGIN" >/dev/null 2>&1 \
    || fail "origin $ORIGIN is not in the backlog: file the undertaking first, so its units have a destination"
  # `tasks-axi show` has no --json, so the title is read off its text output.
  # It is cosmetic - it only labels the report - so an unparseable line leaves it
  # empty rather than refusing a breakdown that is otherwise sound.
  ORIGIN_TITLE=$(axi show "$ORIGIN" 2>/dev/null |
    sed -n 's/^  title: //p' | head -1 | sed 's/^"//; s/"$//')
  i=0
  while [ "$i" -lt "$UNIT_COUNT" ]; do
    if axi show "${ID[i]}" >/dev/null 2>&1; then
      EXISTS[i]=1
    else
      EXISTS[i]=0
    fi
    for dep in ${DEPS_EXT[i]}; do
      axi show "$dep" >/dev/null 2>&1 \
        || fail "unit ${SLUG[i]} is blocked by $dep, which is not in the backlog"
    done
    i=$((i + 1))
  done
else
  i=0
  while [ "$i" -lt "$UNIT_COUNT" ]; do
    EXISTS[i]=0
    i=$((i + 1))
  done
fi

# --- report -----------------------------------------------------------------

printf 'origin: %s' "$ORIGIN"
if [ -n "$ORIGIN_TITLE" ]; then
  printf ' - %s' "$ORIGIN_TITLE"
fi
printf '\n'
if [ "$AXI_OK" -ne 1 ]; then
  printf 'note: no compatible tasks-axi, so nothing was checked against the live backlog\n'
fi
printf 'units: %s in dependency order\n' "$UNIT_COUNT"

for idx in "${ORDER[@]}"; do
  edges=""
  for dep in ${DEPS_INT[idx]}; do
    edges="$edges $ORIGIN-${SLUG[dep]}"
  done
  for dep in ${DEPS_EXT[idx]}; do
    edges="$edges $dep"
  done
  [ -n "$edges" ] || edges=" none - can start immediately"
  if [ "${EXISTS[idx]}" -eq 1 ]; then
    printf '  %s [exists] blocked-by:%s\n' "${ID[idx]}" "$edges"
  else
    printf '  %s [new] blocked-by:%s\n' "${ID[idx]}" "$edges"
  fi
done

if [ "$MODE" = check ]; then
  printf 'ok: breakdown is fileable\n'
  exit 0
fi

# --- file -------------------------------------------------------------------

[ "$AXI_OK" -eq 1 ] \
  || fail "filing needs a compatible tasks-axi; the ordered plan above is what to file by hand"
if fm_backlog_backend_manual "$CONFIG"; then
  fail "config/backlog-backend selects manual, so this home files by hand; the ordered plan above is what to write into data/backlog.md"
fi

BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-to-backlog.XXXXXX") || fail "could not create a temporary file"
trap 'rm -f "$BODY_TMP"' EXIT

added=0
skipped=0
for idx in "${ORDER[@]}"; do
  if [ "${EXISTS[idx]}" -eq 1 ]; then
    printf 'exists: %s left untouched\n' "${ID[idx]}"
    skipped=$((skipped + 1))
  else
    {
      printf 'Origin: %s - this is one slice of that undertaking.\n\n' "$ORIGIN"
      printf 'What to build: %s\n\n' "${DELIVERS[idx]}"
      printf 'Acceptance criteria:\n'
      jq -r --argjson i "$idx" '.units[$i].acceptance[] | "- [ ] " + .' "$FILE"
    } > "$BODY_TMP"

    set -- add "${ID[idx]}" "${TITLE[idx]}" --kind "${KIND[idx]}" --queue --body-file "$BODY_TMP"
    [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
    [ -z "${PRIORITY[idx]}" ] || set -- "$@" --priority "${PRIORITY[idx]}"
    axi "$@" >/dev/null || fail "could not file ${ID[idx]}"
    printf 'added: %s\n' "${ID[idx]}"
    added=$((added + 1))
  fi

  # Edges are recorded after the record exists, and separately from `add`,
  # because `add` is a no-op on an id that is already present and would silently
  # drop its --blocked-by. `block` is idempotent, so a repeated run converges.
  for dep in ${DEPS_INT[idx]}; do
    axi block "${ID[idx]}" --by "$ORIGIN-${SLUG[dep]}" >/dev/null \
      || fail "could not record the edge ${ID[idx]} blocked-by $ORIGIN-${SLUG[dep]}"
  done
  for dep in ${DEPS_EXT[idx]}; do
    axi block "${ID[idx]}" --by "$dep" >/dev/null \
      || fail "could not record the edge ${ID[idx]} blocked-by $dep"
  done
done

printf 'ok: %s filed, %s already present\n' "$added" "$skipped"
