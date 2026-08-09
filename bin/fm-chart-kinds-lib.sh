#!/usr/bin/env bash
# fm-chart-kinds-lib.sh - the two sea-chart backlog kinds, named once.
#
# WHY THIS IS A LIBRARY AND NOT TWO STRING LITERALS
# Both `bin/fm-sea-chart.sh` (which reads these kinds onto a chart) and
# `bin/fm-bearings-snapshot.sh` (which keeps them out of the blockage surface)
# have to agree on the exact spelling. Two copies drift the moment one is
# edited, and the failure is silent in the worst direction: a renamed kind stops
# being filtered and starts crowding gates, or stops being read and vanishes off
# the chart. AGENTS.md section 10 owns what these kinds MEAN; this file owns how
# they are SPELLED.
#
# WHICH FIELD THESE ARE SPELLED IN, BECAUSE "KIND" NAMES TWO DIFFERENT FIELDS
# These are RECORD kinds: `tasks-axi add --kind`, rendered `(kind: fog)` in the
# backlog and read as `.kind` by every consumer below. That vocabulary is open,
# so both store exactly as written here.
# A backlog row carries a SECOND field also called a kind - `tasks-axi hold
# --kind`, rendered `(hold-kind: ...)` and read as `.hold_kind` - and THAT
# vocabulary is closed: captain, external, load, parked, future, enforced by
# tasks-axi, which is a third-party AXI-suite package this repo does not own.
# Neither name below is in that closed set. Because the package updates on its
# own schedule, that is measured rather than assumed: the storable-field test in
# tests/fm-sea-chart.test.sh fails if either vocabulary ever moves.
# This is written down because the two fields were confused once and the cost
# was total: fog and course boundaries filed with only a hold kind carry no
# `.kind` at all, so the chart's filter matched nothing, and a chart drew five
# members while reporting no fog and no boundaries. AGENTS.md section 10 owns
# the filing commands that keep the two fields apart.
#
# WHY THESE KINDS ARE SAFE BY CONSTRUCTION
# Neither can ever be mistaken for a captain decision. Captain-actionability is
# one predicate in bin/fm-fleet-snapshot.sh and it requires `hold_kind ==
# "captain"`, which is the field that names who is being asked. Both kinds below
# are filed with `hold --kind future`, so both read `captain_actionable: false`.
# That is structure, not a rule in prose that drifts - but it is structure in the
# HOLD kind, so a fog record filed with a captain hold would surface as a captain
# decision, which is the correct direction: a misfiled question the captain can
# see is recoverable, one he cannot is not.
#
# Sourced, never executed.

# fog: a named dark patch on one chart's course - a question the investigation
#      could not yet make sharp. It is a signpost, not a question for the
#      captain, and nothing in the lifecycle promotes it to one.
# out-of-course: a deliberate scope boundary. It stays queued and held rather
#      than Done, because a Done record leaves `tasks-axi list` after the
#      configured retention and a boundary nobody can see is not a boundary.
FM_CHART_KIND_FOG="fog"
FM_CHART_KIND_OUT_OF_COURSE="out-of-course"
FM_CHART_KINDS="$FM_CHART_KIND_FOG $FM_CHART_KIND_OUT_OF_COURSE"

# The id markers that place a record on a chart - `<chart>-fog-<slug>` and
# `<chart>-oos-<slug>` - are a different thing from these kind names and are
# owned by bin/fm-sea-chart.sh's header, their only reader, plus AGENTS.md
# section 10 where firstmate is told how to file them.

# fm_chart_kinds_json: the same list as a JSON array, for jq --argjson.
fm_chart_kinds_json() {
  local kind out=""
  for kind in $FM_CHART_KINDS; do
    out="$out${out:+,}\"$kind\""
  done
  printf '[%s]\n' "$out"
}

# fm_chart_kind_p <kind>: true when <kind> is one of the chart kinds.
fm_chart_kind_p() {
  local probe=$1 kind
  for kind in $FM_CHART_KINDS; do
    [ "$probe" = "$kind" ] && return 0
  done
  return 1
}
