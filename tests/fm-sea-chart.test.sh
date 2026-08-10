#!/usr/bin/env bash
# Behavior tests for the per-undertaking sea chart.
#
# The headline test is test_the_silent_loss_is_reproduced_then_absent. It pins
# BOTH halves of the defect this tool exists for: first that wiring the gate
# structure naively really does delete an open decision off the actionable
# surface with no footnote anywhere, and then that the chart does not inherit
# that loss. Pinning only the fix would let the reproduction rot into a test that
# passes because the bug moved rather than because it is handled.
#
# The gates-filter test lives here rather than beside the bearings suite because
# it needs this file's fog fixture and it pins chart-kind behavior; the surface
# it asserts on is bin/fm-bearings-snapshot.sh.
#
# Fixtures are synthetic on purpose. They pin the RULES - identity shape, kind,
# and blocker edges - rather than the fleet's live contents, which change daily.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHART="$ROOT/bin/fm-sea-chart.sh"
INV="$ROOT/bin/fm-decision-inventory.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
fm_test_tmproot TMP_ROOT fm-sea-chart

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A bearings-shaped capture carrying exactly these decision ids as actionable.
capture() {  # <name> <id>...
  local out=$TMP_ROOT/$1.capture.json id first=1
  shift
  {
    printf '{"schema":"fm-bearings.v1","decisions_open":['
    for id in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"id":"%s","key":"%s","verb":"captain-hold","summary":"Frage","owner":"(main)"}' "$id" "$id"
    done
    printf ']}'
  } > "$out"
  printf '%s\n' "$out"
}

# A home whose backlog really is read by the snapshot's own Markdown reader.
make_home() {  # <name> -> home dir on stdout
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

chart_json() {  # <home> <chart> <capture> -> chart json on stdout
  "$CHART" "$2" --json --from "$3" \
    --backlog "$1/data/backlog.md" --archive "$1/data/done-archive.md" --data "$1/data"
}

test_the_silent_loss_is_reproduced_then_absent() {
  # PART 1 - REPRODUCE. Two open captain decisions, then one `blocked-by` edge
  # between them, which is what "wiring the gate structure" means in this data.
  local home before after
  home=$(make_home repro)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] grp - The undertaking these decisions belong to (repo: r) (kind: ship) (since 2026-07-28)
- [ ] grp-judge-decision-shape - Choose the shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which shape) (hold-kind: captain)
- [ ] grp-judge-decision-detail - Choose the detail (repo: r) (kind: captain) (since 2026-07-30) (hold: Which detail) (hold-kind: captain)
EOF
  before=$(FM_HOME="$home" "$INV" --summary 2>/dev/null | head -1)
  assert_contains "$before" "records: 2   decisions kept: 2" \
    "fixture must start with both decisions visible"

  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] grp - The undertaking these decisions belong to (repo: r) (kind: ship) (since 2026-07-28)
- [ ] grp-judge-decision-shape - Choose the shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which shape) (hold-kind: captain)
- [ ] grp-judge-decision-detail - Choose the detail blocked-by: grp-judge-decision-shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which detail) (hold-kind: captain)
EOF
  after=$(FM_HOME="$home" "$INV" --summary 2>/dev/null | head -1)
  assert_contains "$after" "records: 1   decisions kept: 1" \
    "the defect this tool exists for has changed shape: one blocked-by edge no longer removes a decision from the actionable surface. Re-derive the chart's reconciliation before relaxing this."
  # And it is SILENT: the whole inventory carries no trace of the lost decision.
  case "$(FM_HOME="$home" "$INV" --json 2>/dev/null)" in
    *grp-judge-decision-detail*) fail "the reproduction is stale: the inventory now mentions the dropped decision" ;;
  esac

  # PART 2 - THE CHART DOES NOT INHERIT IT. Same backlog, same actionable
  # surface, reconciled against the chart's own records.
  local cap out
  cap=$(capture withheld "grp-judge-decision-shape")
  out=$(chart_json "$home" grp "$cap")
  [ "$(printf '%s' "$out" | jq -r '.counts.withheld')" = 1 ] \
    || fail "the chart must COUNT the decision the actionable surface withheld"
  [ "$(printf '%s' "$out" | jq -r '.withheld[0].id')" = "grp-judge-decision-detail" ] \
    || fail "the chart must NAME the withheld decision, not just count it"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[0].held_by')" "grp-judge-decision-shape" \
    "a withheld decision must name what is holding it, or it cannot be acted on"
  [ "$(printf '%s' "$out" | jq -r '.counts.records_in_backlog')" = 2 ] \
    || fail "the chart must report both sides of the reconciliation, not only what it was handed"
  pass "the silent loss is reproduced, and the chart counts and names it instead"
}

test_a_secondmate_decision_reaches_the_merged_surface_then_stays_off_this_chart() {
  # PART 1 - REPRODUCE. The surface a chart is handed is FLEET-WIDE: bearings
  # merges every registered secondmate home's actionable decisions in beside this
  # home's, marked with an owner and an id prefixed "<secondmate-id>/". Fed
  # straight to the collapse rule, such a record groups exactly like a local one.
  local home raw grouped
  home=$(make_home secondmate)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking in THIS home (repo: r) (kind: ship) (since 2026-07-28)
EOF
  raw=$TMP_ROOT/secondmate.capture.json
  cat > "$raw" <<'EOF'
{"schema":"fm-bearings.v1","decisions_open":[
  {"id":"mate-1/voy-judge-decision-shape","key":"shape","verb":"captain-hold",
   "summary":"A decision recorded in the secondmate home","owner":"mate-1"}
]}
EOF
  grouped=$("$INV" --json --from "$raw")
  [ "$(printf '%s' "$grouped" | jq -r '.records')" = 1 ] \
    || fail "the reproduction is stale: the merged surface no longer carries another home's decisions"
  [ "$(printf '%s' "$grouped" | jq -r '.groups[0].group')" = "mate-1/voy" ] \
    || fail "the reproduction is stale: a secondmate record no longer groups under its own home prefix. Re-derive the chart's home scoping before relaxing this."

  # PART 2 - THE CHART DOES NOT COUNT IT. Drawn for exactly the id that record
  # groups under, so the membership rule would match it if it were still there.
  local out
  mkdir -p "$home/data/mate-1/voy"
  printf '# Report\n\nThe surviving report.\n' > "$home/data/mate-1/voy/report.md"
  out=$(chart_json "$home" mate-1/voy "$raw")
  [ "$(printf '%s' "$out" | jq -r '.counts.records')" = 0 ] \
    || fail "a decision owned by another home must never be counted onto this chart"
  [ "$(printf '%s' "$out" | jq -r '.decisions|length')" = 0 ] \
    || fail "a decision owned by another home must never be shown on this chart"
  # Both sides of the reconciliation now come from the same home, so the
  # arithmetic cannot contradict itself.
  [ "$(printf '%s' "$out" | jq -r '.counts.records_in_backlog >= .counts.records')" = true ] \
    || fail "the chart must never report more records reaching the actionable surface than it found in the backlog"
  # And the exclusion is stated, because a silent one is the loss this tool exists against.
  assert_contains "$(printf '%s' "$out" | jq -r '.limits|join(" ")')" "secondmate home" \
    "dropping another home's decisions must be disclosed on the chart, never silent"
  pass "a secondmate decision reaches the merged surface and is kept off a main-home chart, disclosed"
}

test_a_blocker_that_is_done_in_the_archive_no_longer_hides_takeable_work() {
  # PART 1 - REPRODUCE. Blocker resolution in the snapshot is per FILE, so a live
  # record whose blocker was archived long ago still reads as blocked. That is
  # what would drop it out of takeable[] with no footnote.
  local home cap out live
  home=$(make_home archblock)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-implement - Implement the reader blocked-by: voy-setup (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-later - Waits on something still open blocked-by: voy-open (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-open - Still open (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-20
- [x] voy-setup - Set the reader up (repo: r) (kind: ship) (done 2026-07-20)
EOF
  live=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  [ "$(printf '%s' "$live" | jq -r '[.records[]|select(.id=="voy-implement")|.unresolved_blocker_ids[]]|join(",")')" = "voy-setup" ] \
    || fail "the reproduction is stale: the per-file reader now resolves blockers it cannot see. Re-derive the chart's blocker resolution before relaxing this."

  # PART 2 - THE CHART RESOLVES IT, because it already reads both files.
  cap=$(capture archblock)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy-implement")')" != "null" ] \
    || fail "work whose only blocker is Done in the archive must be takeable, not silently dropped"
  # And a genuinely unresolved blocker still holds its work back.
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy-later")')" = "null" ] \
    || fail "a blocker that is still open must keep its work out of takeable"
  pass "a blocker Done in the archive stops hiding takeable work, and a live one still holds"
}

test_an_archived_twin_never_cancels_a_live_blocker() {
  # PART 1 - PIN WHAT THE LIVE RECORDS SAY ON THEIR OWN. The blocker is an open
  # captain decision sitting in the live backlog, and reading that file alone -
  # which is all the snapshot ever does - it is unresolved. Widening to the
  # archive is the chart's business; it must widen the EVIDENCE without letting a
  # stale archived row of the same id decide the question.
  local home cap out owner
  home=$(make_home twinblock)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-judge-decision-k - The open question (repo: r) (kind: captain) (since 2026-07-28) (hold: Which one) (hold-kind: captain)
- [ ] voy-depends - Waits on that question blocked-by: voy-judge-decision-k (repo: r) (kind: ship) (since 2026-07-30)
EOF
  owner=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  [ "$(printf '%s' "$owner" | jq -r '[.records[]|select(.id=="voy-depends")|.unresolved_blocker_ids[]]|join(",")')" = "voy-judge-decision-k" ] \
    || fail "the reproduction is stale: a live queued blocker no longer reads as unresolved. Re-derive the chart's resolution before relaxing this."

  # PART 2 - AN ARCHIVED DUPLICATE DOES NOT CANCEL IT. The same id also sits Done
  # in the archive, which is the stale state the ageing probe exists to surface.
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-31
- [x] voy-judge-decision-k - A stale duplicate of the same id (repo: r) (kind: captain) (done 2026-07-31)
EOF
  cap=$(capture twinblock)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy-depends")')" = "null" ] \
    || fail "an archived duplicate must never cancel a live blocker: work still gated by an open captain decision was offered as takeable"
  pass "an archived twin never cancels a live blocker: the evidence widens, the rule does not"
}

test_a_captain_thread_without_a_decision_key_is_recovered() {
  # PART 1 - REPRODUCE. AGENTS.md sanctions holding an ordinary thread with
  # --kind captain, and such a record carries no "-decision-" in its id. Blocked,
  # it fails captain-actionability and leaves the surface entirely, exactly like
  # a blocked decision record - so nothing hands it to the chart.
  local home cap out live
  home=$(make_home thread)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-thread - A captain-gated thread with no decision key blocked-by: voy-open (repo: r) (kind: captain) (since 2026-07-28) (hold: Needs a call from the captain) (hold-kind: captain)
- [ ] voy-open - The work still holding it (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-31
- [x] voy-earlier-thread - An earlier captain thread, also with no decision key (repo: r) (kind: captain) (done 2026-07-31)
EOF
  live=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  [ "$(printf '%s' "$live" | jq -r '[.records[]|select(.id=="voy-thread")|.captain_actionable]|join(",")')" = "false" ] \
    || fail "the reproduction is stale: a blocked captain-gated thread now reaches the actionable surface on its own"

  # PART 2 - THE RECONCILIATION RECOVERS IT, on the kind and not on the name.
  cap=$(capture thread)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.withheld[].id]|index("voy-thread")')" != "null" ] \
    || fail "a blocked captain-gated thread must be named on the chart, not left invisible because its id carries no decision key"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-thread")|.held_by')" "voy-open" \
    "a withheld thread must name what is holding it, the same way a withheld decision record does"
  [ "$(printf '%s' "$out" | jq -r '.counts.records_in_backlog')" -ge 1 ] \
    || fail "a captain-gated thread must be counted among the records this chart owns"

  # PART 3 - AND NO KEY IS NOT A SHARED KEY. Two records that both lack a
  # decision key are two questions nobody named, never one already answered.
  [ "$(printf '%s' "$out" | jq -r '.counts.possibly_answered')" = 0 ] \
    || fail "a keyless record must never be twinned with another keyless record"
  pass "a blocked captain thread with no decision key is recovered, and keyless records are never twinned"
}

test_withheld_records_name_their_own_cause() {
  # Every open captain record under the chart is listed, which is the right
  # trade - but they are off the actionable surface for different reasons, and
  # one sentence covering all of them would be a small untruth in the one place
  # this chart exists to be honest. A record somebody is working right now must
  # not read like a decision the fleet has lost.
  local home cap out causes
  home=$(make_home causes)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] voy-worked - Being worked right now (repo: r) (kind: captain) (since 2026-07-29) (hold: Which shape) (hold-kind: captain)

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-blocked - Blocked by live work blocked-by: voy-open (repo: r) (kind: captain) (since 2026-07-28) (hold: Which one) (hold-kind: captain)
- [ ] voy-open - The work still holding it (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-unheld - Queued with nothing recorded as asked (repo: r) (kind: captain) (since 2026-07-30)
- [ ] voy-future - Held, but not for the captain (repo: r) (kind: captain) (since 2026-07-30) (hold: Wait for the release) (hold-kind: future)
- [ ] voy-plainhold - Held with no kind given (repo: r) (kind: captain) (since 2026-07-30) (hold: The captain must weigh in)
- [ ] voy-stale - Waits on nothing at all blocked-by: voy-setup (repo: r) (kind: captain) (since 2026-07-28) (hold: Which route) (hold-kind: captain)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-20
- [x] voy-setup - Long since finished (repo: r) (kind: ship) (done 2026-07-20)
EOF
  cap=$(capture causes)
  out=$(chart_json "$home" voy "$cap")
  causes=$(printf '%s' "$out" | jq -r '[.withheld[]|{(.id): .cause}]|add|tojson')
  [ "$(printf '%s' "$causes" | jq -r '.["voy-blocked"]')" = "blocked" ] \
    || fail "a record held back by an unresolved blocker is the lost decision this chart exists for and must say so"
  [ "$(printf '%s' "$causes" | jq -r '.["voy-worked"]')" = "in-flight" ] \
    || fail "a captain record being worked right now must not be reported the same way as a lost one"
  [ "$(printf '%s' "$causes" | jq -r '.["voy-unheld"]')" = "no-hold" ] \
    || fail "a queued captain record with no hold recorded has its own cause"
  [ "$(printf '%s' "$causes" | jq -r '.["voy-future"]')" = "other-hold" ] \
    || fail "a record held for something other than the captain has its own cause"
  # The chart already re-resolved this edge, so it must say what it knows rather
  # than filing the likeliest case under the bucket meant for anomalies.
  [ "$(printf '%s' "$causes" | jq -r '.["voy-stale"]')" = "stale-edge" ] \
    || fail "a decision held off only by a blocker that is Done in the archive must be named as answerable now, not reported as an unexplained absence"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-stale")|.why')" "voy-setup" \
    "the stale edge must name the archived blocker, or the reader cannot go and clear it"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-stale")|.why')" "answered now" \
    "the stale-edge reason must state the consequence: this decision can be answered now"
  # A hold with no kind states no audience; it must never render as a raw null.
  case "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-plainhold")|.why')" in
    *null*) fail "a literal null reached a sentence written for the captain" ;;
  esac
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-plainhold")|.why')" "no hold kind recorded" \
    "a hold carrying no kind must say so in words"
  # The reasons in words must not collapse back into one shared sentence.
  [ "$(printf '%s' "$out" | jq -r '[.withheld[].why]|unique|length')" = 6 ] \
    || fail "six distinct situations must carry six distinct reasons, or the labels have silently collapsed"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-blocked")|.held_by')" "voy-open" \
    "a blocked record must still name what is holding it"
  pass "each withheld record names the cause that kept it off the actionable surface"
}

test_fog_and_out_of_course_can_never_be_a_captain_decision() {
  # Structure, not prose: captain-actionability requires hold-kind captain, and
  # AGENTS.md section 10 files both kinds below with a `future` hold.
  local home out
  home=$(make_home kinds)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-retention - Retention is not sharp yet (repo: r) (kind: fog) (since 2026-07-30) (hold: could not name the boundary) (hold-kind: future)
- [ ] voy-oos-tracker - A second tracker (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: out of course) (hold-kind: future)
EOF
  out=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  [ "$(printf '%s' "$out" | jq -r '[.records[]|select(.structured and .captain_actionable==true)]|length')" = 0 ] \
    || fail "a fog or out-of-course record must never read as captain-actionable"
  local cap chart
  cap=$(capture kinds)
  chart=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$chart" | jq -r '.decisions|length')" = 0 ] || fail "neither kind may appear as a decision"
  [ "$(printf '%s' "$chart" | jq -r '.fog[0].patch')" = "retention" ] || fail "fog must be read onto the chart"
  [ "$(printf '%s' "$chart" | jq -r '.out_of_course[0].bound')" = "tracker" ] \
    || fail "a course boundary must be read onto the chart"
  pass "fog and out-of-course are read onto the chart and can never be a captain decision"
}

test_the_chart_kinds_are_stored_on_the_field_the_chart_reads() {
  # THE EXTERNAL FACT THE WHOLE DESIGN RESTS ON, PINNED RATHER THAN ASSUMED.
  # "kind" names two different fields on a backlog row, and they have opposite
  # vocabularies: `add --kind` is open and stores these two names, `hold --kind`
  # is a closed set that rejects both. Assuming the wrong one cost the chart
  # every fog patch and every boundary it ever had - filed with a hold kind
  # alone, the records carried no `.kind`, and the filter below matched nothing.
  # tasks-axi is a third-party AXI-suite package this repo does not own, so if a
  # release ever moves either vocabulary, this test is what says so.
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "skipped: tasks-axi not found, so the storage contract cannot be measured"
    return
  fi
  # shellcheck source=bin/fm-chart-kinds-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-chart-kinds-lib.sh"
  local home
  home=$(make_home storable)
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  local kind
  for kind in $FM_CHART_KINDS; do
    ( cd "$home" && tasks-axi add "voy-probe-$kind" "probe" --kind "$kind" ) >/dev/null 2>&1 \
      || fail "the record kind must store '$kind': AGENTS.md section 10 files fog and course boundaries with 'add --kind', and the chart classifies by that field alone"
    ( cd "$home" && tasks-axi hold "voy-probe-$kind" --reason "probe" --kind "$kind" ) >/dev/null 2>&1 \
      && fail "the hold kind unexpectedly accepts '$kind'. It was a closed set (captain, external, load, parked, future) that rejected both chart kinds, which is WHY section 10 sends them to the record kind. Re-derive that instruction before relaxing this."
  done
  # And the stored rows really do read back as the kind the chart filters on.
  local out
  out=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  for kind in $FM_CHART_KINDS; do
    [ "$(printf '%s' "$out" | jq -r --arg k "$kind" '[.records[]|select(.structured and .kind==$k)]|length')" = 1 ] \
      || fail "a record filed with 'add --kind $kind' must read back as .kind '$kind'"
  done
  pass "the chart kinds store on the record kind, and the hold kind still refuses them"
}

test_the_filing_instruction_names_the_field_the_chart_reads() {
  # The instruction was HALF the defect, not a bystander to it. Section 10 gave
  # the id markers and the hold, never the record kind, so a firstmate following
  # it exactly filed records the chart could not classify - and the next agent
  # follows the instruction, not the code. Fixing one side and leaving the other
  # would have fixed nothing durable, so the instruction is pinned here beside
  # the behavior it has to agree with.
  local agents=$ROOT/AGENTS.md
  assert_present "$agents" "AGENTS.md is missing"
  # One command per kind, spelled out. An alternation written `fog|out-of-course`
  # is a PIPELINE when it is pasted into a shell, which files the boundary as fog
  # and reports nothing but a "command not found" - and pasting the instruction
  # literally is how the first half of this defect happened.
  assert_grep 'add <id> "<title>" --kind fog' "$agents" \
    "section 10 must file fog on the RECORD kind: it is the only field the chart classifies by, and naming only the hold is what made both sections permanently empty"
  assert_grep 'add <id> "<title>" --kind out-of-course' "$agents" \
    "section 10 must give the boundary its own copy-safe command, or the two kinds get written as a shell pipeline and the boundary lands in fog"
  assert_no_grep 'kind fog|out-of-course' "$agents" \
    "an alternation in a pasteable command is a pipeline: spell each kind's command out instead"
  assert_grep 'hold <id> --reason "<why>" --kind future' "$agents" \
    "section 10 must still record the hold, because its reason is what the chart prints under each fog patch and boundary"
  # The two fields are named as different things, so the next reader cannot
  # repeat the substitution that caused this.
  assert_grep 'separate closed vocabulary' "$agents" \
    "section 10 must say WHY the chart kinds do not go on the hold, or the next reader tries the hold again and reads its refusal as the kinds being unstorable"
  pass "the filing instruction names the record kind, the hold, and the difference"
}

test_a_member_the_chart_cannot_place_is_named_not_silently_dropped() {
  # THE SECOND HALF, AND IT STANDS ALONE. Every section places a member by its
  # KIND, so an unrecognised kind empties a section - and an empty section READS
  # AS A CLAIM ("no fog on this course") rather than as a failure to look. That
  # is worse than an error, because nothing about it looks wrong: measured on
  # the real fleet as five members, four of them chart material, drawn as
  # `fog: 0  out_of_course: 0` with no footnote (2026-08-03).
  local home cap chart
  home=$(make_home unplaced)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-retention - Retention is not sharp yet (repo: r) (since 2026-07-30) (hold: could not name it) (hold-kind: future)
- [ ] voy-oos-tracker - A second tracker (repo: r) (kind: foggy) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-fog-unheld - A dark patch whose hold was never filed (repo: r) (since 2026-07-30)
- [ ] voy-real-work - Ordinary takeable work (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cap=$(capture unplaced)
  chart=$(chart_json "$home" voy "$cap")

  # The first row is the original defect exactly: filed with a hold kind and no
  # record kind at all. The second is a plausible misspelling of a chart kind.
  # The third is the same original defect with the follow-up hold ALSO missing,
  # which is the worse half: nothing at all on the record holds it back, so every
  # takeable predicate passes and the chart would otherwise advertise a dark
  # patch as work to pick up, complete with an unsupervised-edit pair.
  [ "$(printf '%s' "$chart" | jq -r '.fog|length')" = 0 ] || fail "fixture drift: no misfiled row may reach the fog section"
  [ "$(printf '%s' "$chart" | jq -r '.counts.unplaced')" = 3 ] \
    || fail "every unplaceable member must be counted, not absorbed into an empty section"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[].id]|sort|join(",")')" = "voy-fog-retention,voy-fog-unheld,voy-oos-tracker" ] \
    || fail "each unplaceable member must be named by id"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-fog-retention")|.cause')" = "no-kind" ] \
    || fail "a member carrying only a hold kind must be reported as having no record kind - that is the fault, and the report is what points at it"
  # A record with no kind says nothing about what it is, so nothing rules out its
  # being a dark patch or a boundary filed the wrong way. Offering it as takeable
  # is the wrong-invitation direction this script refuses everywhere else.
  [ "$(printf '%s' "$chart" | jq -r '[.takeable[].id]|index("voy-fog-unheld")')" = "null" ] \
    || fail "a member with no record kind must never be advertised as takeable: a hold that was forgotten is exactly how the original defect reached the chart"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-fog-unheld")|.cause')" = "no-kind" ] \
    || fail "a member with no kind and no hold must be reported for the missing kind, which is the fault a reader can act on"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-oos-tracker")|.kind')" = "foggy" ] \
    || fail "the unrecognised kind itself must be shown, so a misspelling is visible rather than merely absent"
  # The hold kind is reported too, because it is the field that gets confused for
  # the record kind, and seeing both side by side is what settles which is which.
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-fog-retention")|.hold_kind')" = "future" ] \
    || fail "the hold kind must be shown beside the record kind"

  # It must not cry wolf: work the chart CAN place never appears here, and the
  # undertaking itself is the destination rather than a member drawn on itself.
  case "$(printf '%s' "$chart" | jq -r '[.unplaced[].id]|join(",")')" in
    *voy-real-work*) fail "takeable work must never be reported as unplaced" ;;
  esac
  [ "$(printf '%s' "$chart" | jq -r '[.takeable[].id]|join(",")')" = "voy-real-work" ] \
    || fail "fixture drift: the ordinary row must still be takeable"

  # And it must be visible without reading JSON, next to the member count that
  # is otherwise the only trace these records left.
  local summary
  summary=$("$ROOT/bin/fm-sea-chart.sh" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  assert_contains "$summary" "UNPLACED" "the summary must show unplaceable members, not only the JSON"
  assert_contains "$summary" "could not be placed in any section" \
    "the member count must say how many of its members reached no section"
  pass "a member the chart cannot place is named and counted rather than left behind a zero"
}

test_an_unpaired_analyst_variant_is_reconciled_rather_than_counted_as_drawn() {
  # The fold keeps a group's judge ruling and pairs analyst records to it on an
  # exact decision KEY. An analyst record whose key no judge key matches pairs
  # with nothing, so the inventory holds it in unpaired_variants[] - and NO
  # section of this chart emits that list. Treating it as already drawn would
  # take a question only an analyst raised off the decision list, off the
  # reconciliation, and off the unplaced report all at once: the same silent
  # loss this chart exists against, on a fourth flank.
  local home cap chart grouped
  home=$(make_home unpaired)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-judge-decision-shape - Choose the shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which shape) (hold-kind: captain)
- [ ] voy-a-decision-scope - The analyst asked a question the judge never ruled on (repo: r) (kind: captain) (since 2026-07-30) (hold: Which scope) (hold-kind: captain)
EOF
  cap=$(capture unpaired "voy-judge-decision-shape" "voy-a-decision-scope")

  # REPRODUCE. The fold really does hold the analyst record apart, under a key no
  # judge key matches (bin/fm-decision-inventory.sh split_role: -a, -b, -judge).
  grouped=$("$INV" --json --from "$cap")
  [ "$(printf '%s' "$grouped" | jq -r '[.groups[].unpaired_variants[].id]|join(",")')" = "voy-a-decision-scope" ] \
    || fail "the reproduction is stale: an analyst record whose key no judge key matches is no longer left unpaired. Re-derive the chart's placed set before relaxing this."

  chart=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$chart" | jq -r '[.decisions[].id]|join(",")')" = "voy-judge-decision-shape" ] \
    || fail "fixture drift: the fold must keep only the judge ruling on the decision list"
  # It appears in exactly one section, and that section says something true.
  [ "$(printf '%s' "$chart" | jq -r '[.withheld[]|select(.id=="voy-a-decision-scope")]|length')" = 1 ] \
    || fail "an unpaired analyst variant must be reconciled onto the chart: no section draws it, so counting it as returned makes it invisible on every surface at once"
  [ "$(printf '%s' "$chart" | jq -r '.withheld[]|select(.id=="voy-a-decision-scope")|.cause')" = "unpaired-variant" ] \
    || fail "an unpaired variant needs its own cause: it DID reach the actionable surface, so every other withheld reason would be a false sentence about it"
  assert_contains "$(printf '%s' "$chart" | jq -r '.withheld[]|select(.id=="voy-a-decision-scope")|.why')" "reached the actionable surface" \
    "the reason must not claim the surface never carried this record, because it did"
  # And it must not land in unplaced[] instead, whose sentences are written about
  # a kind the chart cannot place and would read as nonsense about a captain record.
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[].id]|join(",")')" = "" ] \
    || fail "a captain record the fold dropped belongs in withheld[], never in unplaced[]"

  # THE COUNT ABOVE THE SECTION MUST NOT CONTRADICT THE SECTION. This record is
  # counted in `folded` and in `withheld` at once, which is honest only while the
  # page says why the same record appears in both. A label claiming it never
  # reached the actionable surface would be refuted three lines further down by
  # its own why, and arithmetic a reader can catch out is what teaches them to
  # stop believing every other number on the chart.
  [ "$(printf '%s' "$chart" | jq -r '.counts.withheld_folded')" = 1 ] \
    || fail "the chart must count how many withheld records the fold dropped, or nothing reconciles the same record being counted as folded and as withheld"
  local summary
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  case "$summary" in
    *"withheld from the actionable surface"*)
      fail "the incompleteness label must not claim this record never reached the actionable surface: it did, and its own why two lines below says so" ;;
  esac
  assert_contains "$summary" "not carried by any decision section: 1" \
    "the incompleteness count must be labelled by what is true of BOTH classes it now covers - never returned, and returned then folded away"
  assert_contains "$summary" "folded away rather than never returned" \
    "the page must reconcile the record it counts as folded with the one it counts as withheld, or the two numbers read as two records"
  pass "an unpaired analyst variant is reconciled onto the chart instead of counted as drawn"
}

test_an_id_marker_and_a_record_kind_that_disagree_are_reported_never_offered() {
  # A kind the chart does not place is USUALLY ordinary work - ship, docs, scout
  # are all legitimately takeable - so a misspelled chart kind is invisible on
  # the kind alone. The id marker is the one piece of evidence that says this
  # record already claims to be chart material: `<chart>-fog-<slug>` and
  # `<chart>-oos-<slug>` are the filing convention in AGENTS.md section 10. When
  # the id and the kind disagree, one of them is a typo, and the direction of the
  # error is the costly one - the record gets advertised under TAKEABLE NOW with
  # an unsupervised-edit pair at the very moment the section it names reads
  # empty, which is the original defect with a hold that was never filed.
  local home cap chart summary
  home=$(make_home mismatch)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-drift - A dark patch whose kind was misspelled (repo: r) (kind: fogg) (since 2026-07-30)
- [ ] voy-oos-tracker - A boundary filed as ordinary work (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-real-work - Ordinary work carrying no chart marker at all (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cap=$(capture mismatch)
  chart=$(chart_json "$home" voy "$cap")

  # Neither row carries a hold or a blocker, which is what made both of them
  # takeable before: nothing on the record held them back at all.
  [ "$(printf '%s' "$chart" | jq -r '[.takeable[].id]|join(",")')" = "voy-real-work" ] \
    || fail "a record whose id claims to be chart material while its kind says otherwise must never be offered as takeable, and ordinary unmarked work must still be"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[]|select(.cause=="marker-kind-mismatch")|.id]|sort|join(",")')" = "voy-fog-drift,voy-oos-tracker" ] \
    || fail "a marker that disagrees with the kind must be reported as its own kind defect, not left to the held or blocked causes that would not fit it"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[]|select(.cause=="marker-kind-mismatch")|.kind_defect]|unique|join(",")')" = "true" ] \
    || fail "a marker-kind mismatch is a kind defect and must sort with the others, not below routine held work"

  # The why must name BOTH halves, because the chart cannot tell which of the two
  # is the typo and the reader has to be able to.
  local fog_why oos_why
  fog_why=$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-fog-drift")|.why')
  assert_contains "$fog_why" "-fog- marker" "the why must name the marker found on the id"
  assert_contains "$fog_why" "record kind is fogg" "the why must name the kind found on the record"
  oos_why=$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-oos-tracker")|.why')
  assert_contains "$oos_why" "-oos- marker" "the boundary marker must be named the same way"
  assert_contains "$oos_why" "record kind is ship" \
    "an ordinary kind on a marked id must be named as the mismatch it is, not treated as ordinary work"

  # And the sections they name really are the empty ones, which is the whole
  # reason a silent takeable row is the wrong place for them.
  [ "$(printf '%s' "$chart" | jq -r '(.fog|length) + (.out_of_course|length)')" = 0 ] \
    || fail "fixture drift: both misfiled rows must miss the sections their ids name"
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  case "$summary" in
    *"TAKEABLE NOW"*"voy-fog-drift"*)
      fail "a misfiled dark patch must not be printed under TAKEABLE NOW with an unsupervised-edit pair" ;;
  esac
  assert_contains "$summary" "KIND DEFECTS" "both mismatches must reach the kind-defect block of the unplaced report"
  pass "an id marker and a record kind that disagree are reported as a kind defect, never offered as takeable"
}

test_a_swapped_chart_kind_is_reported_even_though_a_section_drew_it() {
  # THE SWAP EVERY OTHER REPORT HERE IS BLIND TO. The two filing commands in
  # AGENTS.md section 10 differ in a single word, so the likeliest slip is a
  # boundary filed with the fog kind or the reverse. Such a record IS placed -
  # the fog filter takes it - so every report that asks "did any section draw
  # this member" answers yes and says nothing, while the section its id names
  # renders 0. That is this whole change in miniature: an empty section reads as
  # a claim about the course, and here the claim is refuted by a record already
  # on the same page.
  local home cap chart summary
  home=$(make_home swapped)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-oos-tracker - A boundary filed with the fog kind (repo: r) (kind: fog) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-fog-retention - A dark patch filed with the boundary kind (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: not sharp yet) (hold-kind: future)
EOF
  cap=$(capture swapped)
  chart=$(chart_json "$home" voy "$cap")

  # REPRODUCE. Each record really is drawn, and drawn in the wrong section, so
  # nothing about the placement itself looks wrong.
  [ "$(printf '%s' "$chart" | jq -r '[.fog[].id]|join(",")')" = "voy-oos-tracker" ] \
    || fail "fixture drift: the boundary filed with the fog kind must still be DRAWN under fog - that is what makes it invisible to every unplaced report"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[].id]|join(",")')" = "" ] \
    || fail "a record a section drew must not be forced into unplaced[], whose sentence is about members no section drew"

  # And it is reported anyway, on a surface of its own, naming both halves.
  [ "$(printf '%s' "$chart" | jq -r '.counts.misfiled')" = 2 ] \
    || fail "a swapped chart kind must be counted: it is placed, so no other count on this chart can ever see it"
  [ "$(printf '%s' "$chart" | jq -r '[.misfiled[].id]|sort|join(",")')" = "voy-fog-retention,voy-oos-tracker" ] \
    || fail "both swap directions must be reported, not only the one the fog filter happens to take first"
  local swap
  swap=$(printf '%s' "$chart" | jq -r '.misfiled[]|select(.id=="voy-oos-tracker")')
  [ "$(printf '%s' "$swap" | jq -r '.marker')" = "oos" ] || fail "the marker found on the id must be named"
  [ "$(printf '%s' "$swap" | jq -r '.kind')" = "fog" ] || fail "the kind found on the record must be named beside it"
  [ "$(printf '%s' "$swap" | jq -r '.drawn_in')" = "FOG" ] \
    || fail "the report must say which section actually drew the record, or the reader cannot find the wrong row"
  [ "$(printf '%s' "$swap" | jq -r '.belongs_in')" = "OUT OF COURSE" ] \
    || fail "the report must say which section is empty because of this, since that empty section is the harm"

  # The reverse swap is reported the same way, so the net is not one-directional.
  [ "$(printf '%s' "$chart" | jq -r '.misfiled[]|select(.id=="voy-fog-retention")|.drawn_in')" = "OUT OF COURSE" ] \
    || fail "a dark patch filed with the boundary kind must be reported as drawn out of course"

  # Visible without reading JSON, and above the sections it calls into question.
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  assert_contains "$summary" "MISFILED" "the swap must be visible on the rendered page, not only in the JSON"
  local mis_line fog_line
  mis_line=$(printf '%s\n' "$summary" | grep -n 'MISFILED' | head -1 | cut -d: -f1)
  fog_line=$(printf '%s\n' "$summary" | grep -n '^FOG:' | head -1 | cut -d: -f1)
  [ -n "$mis_line" ] && [ -n "$fog_line" ] && [ "$mis_line" -lt "$fog_line" ] \
    || fail "the report must be rendered above the section whose row it calls into question: $summary"
  pass "a swapped chart kind is reported even though a section drew it, naming both halves"
}

test_a_correctly_filed_chart_record_is_never_called_misfiled() {
  # The net has to be silent on correct work, or it is worth nothing: a report
  # that fires on the right filing teaches a reader to skip it, and the next real
  # swap goes past unread.
  local home cap chart
  home=$(make_home nowolf)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-retention - Retention is not sharp yet (repo: r) (kind: fog) (since 2026-07-30) (hold: could not name it) (hold-kind: future)
- [ ] voy-oos-tracker - A second tracker (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-implement - Ordinary work carrying no chart marker (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cap=$(capture nowolf)
  chart=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$chart" | jq -r '.counts.misfiled')" = 0 ] \
    || fail "a correctly filed dark patch, a correctly filed boundary, and ordinary unmarked work must all stay silent: $(printf '%s' "$chart" | jq -r '[.misfiled[].id]|join(",")')"
  [ "$(printf '%s' "$chart" | jq -r '(.fog|length) + (.out_of_course|length)')" = 2 ] \
    || fail "fixture drift: both correctly filed records must reach their own sections"
  case "$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")" in
    *MISFILED*) fail "the rendered page must carry no misfiled block when nothing is misfiled" ;;
  esac
  pass "a correctly filed record of either chart kind is never called misfiled"
}

test_the_misfiled_report_never_sends_a_reader_to_a_surface_without_the_record() {
  # A report that points somewhere is only worth the pointer being right. Where
  # a misfiled record ended up is therefore LOOKED UP in the arrays this chart
  # emits rather than decided from a second copy of the section predicates: a
  # copy answers only for the kinds whoever wrote it thought of, and this one
  # knew about fog and out-of-course, so every kind captain record carrying a
  # chart marker in its id was sent to the unplaced report, which by definition
  # never carries a record that a decision section already placed.
  local home cap chart
  home=$(make_home pointer)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-of-war-judge-decision-shape - A ruling whose id carries a chart marker (repo: r) (kind: captain) (since 2026-07-30) (hold: Which shape) (hold-kind: captain)
- [ ] voy-fog-of-war-a-decision-scope - An analyst question the judge never ruled on (repo: r) (kind: captain) (since 2026-07-30) (hold: Which scope) (hold-kind: captain)
EOF
  cap=$(capture pointer "voy-fog-of-war-judge-decision-shape")
  chart=$(chart_json "$home" voy "$cap")

  # REPRODUCE THE SETUP. One record is drawn on the decision list, the other is
  # reconciled into withheld, and neither is unplaced - so any sentence sending a
  # reader to the unplaced report is false for both.
  [ "$(printf '%s' "$chart" | jq -r '[.decisions[].id]|join(",")')" = "voy-fog-of-war-judge-decision-shape" ] \
    || fail "fixture drift: the ruling must be drawn on the decision list"
  [ "$(printf '%s' "$chart" | jq -r '[.withheld[].id]|join(",")')" = "voy-fog-of-war-a-decision-scope" ] \
    || fail "fixture drift: the analyst question must be reconciled into withheld"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[].id]|join(",")')" = "" ] \
    || fail "fixture drift: a captain record is always placed, so the unplaced report must be empty here"

  # Both are reported, and each says where it actually is.
  [ "$(printf '%s' "$chart" | jq -r '.counts.misfiled')" = 2 ] \
    || fail "a chart marker on a captain record is still a disagreement between the id and the kind, and must be reported"
  [ "$(printf '%s' "$chart" | jq -r '.misfiled[]|select(.id=="voy-fog-of-war-judge-decision-shape")|.drawn_in')" = "OPEN DECISIONS" ] \
    || fail "the report must name the section that really drew the record, which is what lets a reader go and find the wrong row"
  [ "$(printf '%s' "$chart" | jq -r '.misfiled[]|select(.id=="voy-fog-of-war-a-decision-scope")|.drawn_in')" = "WITHHELD" ] \
    || fail "a record reconciled into withheld must be reported as drawn there, not as drawn nowhere"

  # THE DEFECT ITSELF: neither why may send a reader to a report that does not
  # carry the record.
  # One whole line per row: a why is a sentence and must stay intact, and the
  # claim being pinned is about EACH row, so the body has to run once per row.
  local why seen=0
  while IFS= read -r why; do
    seen=$((seen + 1))
    case "$why" in
      *"unplaced report names it too"*)
        fail "the misfiled report sent a reader to the unplaced report for a record the unplaced report does not carry: $why" ;;
      *"no section drew it at all"*)
        fail "a record a decision section drew must not be described as drawn nowhere: $why" ;;
    esac
  done < <(printf '%s' "$chart" | jq -r '.misfiled[].why')
  [ "$seen" = 2 ] \
    || fail "the whys must be checked one row at a time, so this loop must run once per misfiled record; it ran $seen times for 2 records"

  # And the clause about the section left short must not claim it is empty when
  # a correctly filed record is sitting in it.
  local home2 cap2 chart2 fogwhy
  home2=$(make_home pointer2)
  cat > "$home2/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-retention - A dark patch filed correctly (repo: r) (kind: fog) (since 2026-07-30) (hold: not sharp) (hold-kind: future)
- [ ] voy-fog-drift - A second dark patch whose kind was misspelled (repo: r) (kind: fogg) (since 2026-07-30)
EOF
  cap2=$(capture pointer2)
  chart2=$(chart_json "$home2" voy "$cap2")
  [ "$(printf '%s' "$chart2" | jq -r '.fog|length')" = 1 ] \
    || fail "fixture drift: the correctly filed dark patch must still be drawn under fog"
  fogwhy=$(printf '%s' "$chart2" | jq -r '.misfiled[]|select(.id=="voy-fog-drift")|.why')
  case "$fogwhy" in
    *"renders as if this course had none of them"*)
      fail "the report claimed FOG is empty while a correctly filed dark patch is drawn in it: $fogwhy" ;;
  esac
  assert_contains "$fogwhy" "FOG is drawn without it" \
    "when the named section is not empty the report must say the record is missing FROM it, which is the true and still actionable claim"
  pass "the misfiled report names where each record really is and never points at a surface without it"
}

test_the_report_headings_assert_nothing_their_own_rows_can_contradict() {
  # THE CLASS OF DEFECT THIS PINS, WHICH COST FIVE REVIEW ROUNDS.
  # Every one of those rounds found one more sentence that was true for most
  # inputs and false for one, always the same shape: a heading standing over a
  # list and asserting what the reader would find somewhere ELSE on the chart -
  # "a section below is empty that should not be" - which nothing computed and
  # the rows underneath then denied in the same breath.
  # A heading covers rows it cannot inspect, so it may only say what is true by
  # construction of the list it heads. Anything about the rest of the chart is
  # computed per record and lives in that record. This test therefore renders two
  # charts that disagree about everything the old headings claimed, and requires
  # the headings to come out byte for byte identical.
  local home_a home_b sum_a sum_b heads_a heads_b
  # A: every named section IS drawn, just with the wrong record in it, so nothing
  # anywhere below the reports is empty.
  home_a=$(make_home headsdrawn)
  cat > "$home_a/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-oos-tracker - A boundary filed with the fog kind (repo: r) (kind: fog) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-fog-retention - A dark patch filed with the boundary kind (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: not sharp) (hold-kind: future)
- [ ] voy-nokind - Filed with no record kind at all (repo: r) (since 2026-07-30)
EOF
  # B: the named sections really are empty, which is the case the old wording was
  # written for and the only one it was true of.
  home_b=$(make_home headsempty)
  cat > "$home_b/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-fog-drift - A dark patch whose kind was misspelled (repo: r) (kind: fogg) (since 2026-07-30)
- [ ] voy-nokind - Filed with no record kind at all (repo: r) (since 2026-07-30)
EOF
  sum_a=$("$CHART" voy --summary --from "$(capture headsdrawn)" \
    --backlog "$home_a/data/backlog.md" --archive "$home_a/data/none.md" --data "$home_a/data")
  sum_b=$("$CHART" voy --summary --from "$(capture headsempty)" \
    --backlog "$home_b/data/backlog.md" --archive "$home_b/data/none.md" --data "$home_b/data")

  # The two charts really are the opposite case of each other.
  [ "$(printf '%s\n' "$sum_a" | grep -c '^FOG:')" = 1 ] && [ "$(printf '%s\n' "$sum_b" | grep -c '^FOG:')" = 0 ] \
    || fail "fixture drift: A must draw a fog section and B must leave it empty, or this test compares nothing"

  heads_a=$(printf '%s\n' "$sum_a" | grep -E '^(UNPLACED|MISFILED|WITHHELD)|^  (KIND DEFECTS|HELD OR BLOCKED)')
  heads_b=$(printf '%s\n' "$sum_b" | grep -E '^(UNPLACED|MISFILED|WITHHELD)|^  (KIND DEFECTS|HELD OR BLOCKED)')
  [ -n "$heads_a" ] || fail "fixture drift: chart A must render the reports whose headings this pins"
  [ "$heads_a" = "$heads_b" ] \
    || fail "a report heading changed meaning with its input, which means it is asserting something about the chart rather than about the list it heads:
--- drawn ---
$heads_a
--- empty ---
$heads_b"

  # And the specific claim that took five rounds to find: no heading may say
  # anything about a section being empty, because the heading cannot check it.
  case "$heads_a" in
    *empty*) fail "a heading still claims a section is empty, which its own rows can contradict: $heads_a" ;;
  esac
  # The rows keep saying it, per record and computed, which is where it belongs.
  assert_contains "$sum_a" "is drawn without it" \
    "deleting the heading claim must not delete the per-record one: the row is where that difference can be computed"
  assert_contains "$sum_b" "renders as if this course had none of them" \
    "when a named section really is empty the row must still say so"
  pass "the report headings assert nothing their own rows can contradict"
}

test_a_kind_defect_is_never_pushed_down_the_page_by_routine_held_work() {
  # Held and blocked ordinary work belongs in unplaced[] - this chart has no
  # section for it, and dropping it would be the silent gap the whole report
  # exists against. But it is nobody's mistake, while a kind the chart cannot
  # classify can leave a whole section reading empty. So the report ranks the
  # second above the first, on the page as well as in the JSON: a real kind
  # defect buried under a page of routine held rows is how the empty sections
  # went unnoticed for as long as they did. The kind defect is filed LAST in
  # this backlog on purpose, so passing proves the ranking rather than the order
  # the rows happened to be written in.
  local home cap chart summary
  home=$(make_home ranked)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-parked - Ordinary work, parked until the release (repo: r) (kind: ship) (since 2026-07-29) (hold: waiting on the release) (hold-kind: parked)
- [ ] voy-waiting - Ordinary work waiting on a leg blocked-by: voy-open (repo: r) (kind: ship) (since 2026-07-29)
- [ ] voy-open - The leg still holding it (repo: r) (kind: ship) (since 2026-07-29)
- [ ] voy-fog-unnamed - A dark patch filed with no record kind at all (repo: r) (since 2026-07-30) (hold: could not name it) (hold-kind: future)
EOF
  cap=$(capture ranked)
  chart=$(chart_json "$home" voy "$cap")

  [ "$(printf '%s' "$chart" | jq -r '.counts.unplaced')" = 3 ] \
    || fail "routine held and blocked work must still be reported: this chart has no section for it, and a silent gap is the defect this report exists against"
  [ "$(printf '%s' "$chart" | jq -r '.counts.unplaced_kind_defects')" = 1 ] \
    || fail "the kind defects must be counted apart from the routine rows, or the count cannot say which news it is carrying"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[0].id')" = "voy-fog-unnamed" ] \
    || fail "a kind defect must be ranked ahead of routine held and blocked work, however late it was filed"
  [ "$(printf '%s' "$chart" | jq -r '[.unplaced[].kind_defect]|join(",")')" = "true,false,false" ] \
    || fail "each unplaced row must say whether its kind is the fault, or a renderer cannot keep the two apart"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-parked")|.cause')" = "held" ] \
    || fail "fixture drift: ordinary held work must reach unplaced[] with the routine cause"
  [ "$(printf '%s' "$chart" | jq -r '.unplaced[]|select(.id=="voy-waiting")|.cause')" = "blocked" ] \
    || fail "fixture drift: ordinary blocked work must reach unplaced[] with the routine cause"

  # The ranking has to survive rendering, or it settles nothing for a reader.
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  local defect_head routine_head defect_row routine_row
  defect_head=$(printf '%s\n' "$summary" | grep -n 'KIND DEFECTS' | head -1 | cut -d: -f1)
  routine_head=$(printf '%s\n' "$summary" | grep -n 'HELD OR BLOCKED' | head -1 | cut -d: -f1)
  [ -n "$defect_head" ] && [ -n "$routine_head" ] \
    || fail "the summary must keep kind defects and routine held work under separate headings: $summary"
  [ "$defect_head" -lt "$routine_head" ] \
    || fail "the kind-defect heading must come first on the page, not only first in the JSON"
  defect_row=$(printf '%s\n' "$summary" | grep -n 'voy-fog-unnamed' | head -1 | cut -d: -f1)
  routine_row=$(printf '%s\n' "$summary" | grep -n 'voy-parked' | head -1 | cut -d: -f1)
  [ "$defect_row" -lt "$routine_row" ] \
    || fail "a routine held row must never be printed above a kind defect"
  assert_contains "$summary" "carrying a kind this chart cannot classify" \
    "the member count must say how many of the unplaced members are a kind defect rather than routine held work"
  pass "a kind defect is ranked and rendered ahead of routine held and blocked work"
}

test_chart_kinds_stay_off_the_blockage_surface_but_are_disclosed() {
  # They are held forever on purpose, so left in gates they permanently crowd a
  # surface that is already truncated. Hiding them silently would be the same
  # defect this tool exists against, so the withholding is disclosed and
  # reversible.
  local home default revealed
  home=$(make_home gates)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy-fog-retention - Retention is not sharp yet (repo: r) (kind: fog) (since 2026-07-30) (hold: could not name it) (hold-kind: future)
- [ ] voy-oos-tracker - A second tracker (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-real-blocker - A genuinely blocked ship task (repo: r) (kind: ship) (since 2026-07-30)
EOF
  default=$(FM_HOME="$home" "$BEARINGS" --json 2>/dev/null)
  [ "$(printf '%s' "$default" | jq -r '[.gates[].id]|join(",")')" = "voy-real-blocker" ] \
    || fail "fog and out-of-course must not occupy the blockage surface"
  [ "$(printf '%s' "$default" | jq -r '[.omitted[]|select(.surface|test("sea-chart"))]|length')" = 1 ] \
    || fail "withholding them must be disclosed in omitted[], never silent"
  revealed=$(FM_HOME="$home" "$BEARINGS" --json --all-queued 2>/dev/null)
  [ "$(printf '%s' "$revealed" | jq -r '[.gates[].id]|length')" = 3 ] \
    || fail "--all-queued must reveal every withheld record"
  # The documented gates field set must not have grown a leaked kind.
  [ "$(printf '%s' "$default" | jq -r '.gates[0]|keys|join(",")')" = "blocked_by,id,owner,reason,title" ] \
    || fail "the gates field set is a published contract and must not change"
  pass "the chart kinds stay off the blockage surface, disclosed and reversible"
}

test_a_chart_without_a_destination_is_refused() {
  # Naming the destination is the first act, enforced rather than asked for: a
  # chart with a blank cover is the flat list it was supposed to replace.
  local home cap out rc=0
  home=$(make_home nodest)
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  cap=$(capture nodest)
  out=$(chart_json "$home" ghost-voyage "$cap" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a chart with no destination must be refused, not drawn empty"
  assert_contains "$out" "no destination" "the refusal must say what is missing"
  pass "an undertaking with no destination is refused rather than drawn blank"
}

test_the_destination_is_read_and_never_invented() {
  local home cap out
  home=$(make_home dest)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - Make the per-vessel reader trustworthy end to end (repo: r) (kind: ship) (since 2026-07-28)
EOF
  cap=$(capture dest)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.destination.title')" = "Make the per-vessel reader trustworthy end to end" ] \
    || fail "the destination must be the undertaking's own recorded title"
  [ "$(printf '%s' "$out" | jq -r '.destination.source')" = "backlog record" ] \
    || fail "the chart must say where it read the destination, since the sources differ in strength"

  # A panel keeps its destination in the question every member was given, and
  # that file outlives teardown (AGENTS.md section 2).
  local home2 out2
  home2=$(make_home dest2)
  printf '# Backlog\n\n## Queued\n' > "$home2/data/backlog.md"
  mkdir -p "$home2/data/panel-x"
  printf '# Question\n\nWhere does a passing check fail to mean what a reader assumes?\n' \
    > "$home2/data/panel-x/question.md"
  out2=$("$CHART" panel-x --json --from "$cap" \
    --backlog "$home2/data/backlog.md" --archive "$home2/data/none.md" --data "$home2/data")
  assert_contains "$(printf '%s' "$out2" | jq -r '.destination.title')" "passing check" \
    "a panel chart must take its destination from the surviving question"
  [ "$(printf '%s' "$out2" | jq -r '.destination.source')" = "panel question" ] \
    || fail "a weaker destination source must be named as such"
  pass "the destination is read from the records, and the chart says which source it used"
}

test_the_ageing_probe_finds_a_decision_its_own_twin_already_closed() {
  # The record that actually rots is the folded analyst variant whose judge twin
  # was answered and closed while it stayed open. This found a real four-day-old
  # discrepancy on the live fleet.
  local home cap out
  home=$(make_home ageing)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-b-decision-provenance - Analyst wording of the provenance question (repo: r) (kind: captain) (since 2026-07-28) (hold: Which provenance) (hold-kind: captain)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-31
- [x] voy-judge-decision-provenance - Choose the provenance (repo: r) (kind: captain) (done 2026-07-31)
EOF
  cap=$(capture ageing "voy-b-decision-provenance")
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.counts.possibly_answered')" = 1 ] \
    || fail "an open record whose twin key is already closed must be flagged"
  [ "$(printf '%s' "$out" | jq -r '.possibly_answered[0].twin')" = "voy-judge-decision-provenance" ] \
    || fail "the probe must name the closed twin so the finding can be checked"
  pass "the ageing probe finds an open decision whose sibling already closed the same key"
}

test_a_record_is_never_reported_as_its_own_twin() {
  local home cap out
  home=$(make_home selftwin)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-judge-decision-k - The question (repo: r) (kind: captain) (since 2026-07-28) (hold: Which one) (hold-kind: captain)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-07-31
- [x] voy-judge-decision-k - The question (repo: r) (kind: captain) (done 2026-07-31)
EOF
  cap=$(capture selftwin "voy-judge-decision-k")
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.counts.possibly_answered')" = 0 ] \
    || fail "a record must never be reported as its own twin"
  pass "a record is never its own twin"
}

test_the_unsupervised_marking_is_a_pair_and_never_a_scalar() {
  # A lone boolean renders as a badge, and a badge reads as "cleared". The shape
  # of the field is what stops that, not a sentence asking a renderer not to.
  local home cap out
  home=$(make_home nav)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-implement - Implement the reader (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cap=$(capture nav)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.takeable[0].id')" = "voy-implement" ] \
    || fail "unblocked, unheld work must be takeable"
  [ "$(printf '%s' "$out" | jq -r '.takeable[0].navigation|type')" = "object" ] \
    || fail "navigation must be a pair, never a scalar a renderer can show as one badge"
  [ "$(printf '%s' "$out" | jq -r '.takeable[0].navigation.landing.requires')" != "" ] \
    || fail "the landing half of the pair must never be empty"
  assert_contains "$(printf '%s' "$out" | jq -r '.takeable[0].navigation.landing.requires')" "first reader" \
    "the landing half must state the supervised review that unsupervised work still needs"
  # The undertaking itself is the destination, not a leg towards it.
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy")')" = "null" ] \
    || fail "the chart's own origin must not be listed as a leg of itself"
  pass "the unsupervised marking is a pair whose second half is never empty"
}

test_a_dangling_blocker_stops_hiding_takeable_work_and_is_named() {
  # A blocked-by target that is a real record in neither the backlog nor the
  # archive - never created, renamed, or mistyped - never held anything. The
  # snapshot still counts it as unresolved and would drop the work off the chart
  # with no footnote; the chart must keep it takeable and name the stale edge, and
  # must surface a phantom-blocked captain decision as answerable now.
  local home cap out live
  home=$(make_home dangling)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-phantom - Ready leg masked as blocked blocked-by: ghost-leg (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-real-target - A real leg (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-real-blocked - Genuinely blocked blocked-by: voy-real-target (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-decision - A captain call held by a phantom blocked-by: ghost-dec (repo: r) (kind: captain) (since 2026-07-28) (hold: Which route) (hold-kind: captain)
EOF
  : > "$home/data/done-archive.md"
  # The reproduction: the per-file reader still counts the phantom as unresolved.
  live=$("$ROOT/bin/fm-fleet-snapshot.sh" --backlog-json "$home/data/backlog.md")
  [ "$(printf '%s' "$live" | jq -r '[.records[]|select(.id=="voy-phantom")|.unresolved_blocker_ids[]]|join(",")')" = "ghost-leg" ] \
    || fail "the reproduction is stale: the per-file reader now drops phantom blockers on its own. Re-derive the chart's blocker resolution before relaxing this."

  cap=$(capture dangling)
  out=$(chart_json "$home" voy "$cap")
  # The phantom-blocked leg is takeable and names the stale edge to clear.
  printf '%s' "$out" | jq -e '
    (.takeable | any(.[]; .id == "voy-phantom" and (.dangling_blocked_by == ["ghost-leg"])))
    and (.takeable | any(.[]; .id == "voy-real-blocked") | not)
  ' >/dev/null || fail "a phantom-blocked leg must be takeable and name its dangling edge, and a real block must still hold: $out"
  # The phantom-blocked captain decision is recovered as answerable now.
  printf '%s' "$out" | jq -e '
    .withheld | any(.[]; .id == "voy-decision" and .cause == "dangling-edge")
  ' >/dev/null || fail "a phantom-blocked captain decision must surface as a dangling-edge that can be answered now: $out"
  pass "a dangling blocker stops hiding takeable work, names the stale edge, and recovers a phantom-blocked decision"
}

test_membership_is_scoped_and_stated() {
  local home cap out
  home=$(make_home member)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-implement - Belongs to this chart (repo: r) (kind: ship) (since 2026-07-30)
- [ ] unrelated-thing - Belongs to no chart of ours (repo: r) (kind: ship) (since 2026-07-30)
EOF
  cap=$(capture member)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.membership.members')" = 2 ] \
    || fail "membership must cover the undertaking and its namespace, and nothing else"
  [ "$(printf '%s' "$out" | jq -r '.membership.rule')" != "" ] \
    || fail "the chart must state the rule that produced its membership"
  pass "membership is scoped to the undertaking's id namespace and the rule is stated"
}

# --- MEMBERSHIP BEYOND THE ID -----------------------------------------------
# The prefix rule is right for records created UNDER a chart and it is not
# touched by anything below. It fails in one place: an undertaking named OVER
# work that already exists. Membership IS the identifier there, `tasks-axi` has
# no rename, and renaming a record breaks every reference to it that has already
# left this vessel. Measured on the seat that raised it: six of seven named
# undertakings drew ZERO members while their assignment was settled and written
# down (2026-08-10). `data/<chart>/members` is the second half of the union.

# The rich fixture the additive claim is proved against. Every section of the
# chart draws something, so a change that leaked past the member-list code would
# have somewhere to show up.
member_list_home() {  # <name> -> home dir on stdout
  local home
  home=$(make_home "$1")
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - Make the retrofit path exist (repo: r) (kind: ship) (since 2026-07-28)
- [ ] voy-judge-decision-shape - Choose the shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which shape) (hold-kind: captain)
- [ ] voy-judge-decision-detail - Choose the detail blocked-by: voy-judge-decision-shape (repo: r) (kind: captain) (since 2026-07-30) (hold: Which detail) (hold-kind: captain)
- [ ] voy-fog-retention - Retention is not sharp yet (repo: r) (kind: fog) (since 2026-07-30) (hold: could not name it) (hold-kind: future)
- [ ] voy-oos-tracker - A second tracker (repo: r) (kind: out-of-course) (since 2026-07-30) (hold: out of course) (hold-kind: future)
- [ ] voy-real-work - Ordinary takeable work (repo: r) (kind: ship) (since 2026-07-30)
- [ ] voy-fog-unheld - A dark patch filed with no record kind (repo: r) (since 2026-07-30)
- [ ] voy-oos-swapped - A boundary filed with the fog kind (repo: r) (kind: fog) (since 2026-07-30) (hold: never rises) (hold-kind: future)
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
# Done archive

## Done
- [x] voy-judge-decision-base - The base was settled (repo: r) (kind: captain) (since 2026-07-20) (done 2026-07-25)
EOF
  printf '%s\n' "$home"
}

test_a_chart_with_no_member_list_draws_exactly_what_it_drew_before() {
  # THE ADDITIVE CLAIM, PROVED RATHER THAN ASSERTED. The whole page a chart with
  # no member list draws - every section, every count, every reason string, every
  # limit - is compared byte for byte against a capture taken from the script
  # BEFORE the member list existed. Only the four fields the list itself adds are
  # removed before the comparison, because they are the change rather than a
  # side effect of it.
  # Re-blessing this golden is a deliberate act. If a later change to the chart
  # makes it fail, that is the file telling you the change reached further than
  # the section you edited - read the diff before regenerating it.
  local home cap out golden=$ROOT/tests/fm-sea-chart.no-member-list.golden.json
  assert_present "$golden" "the pre-change capture is missing; without it nothing proves the member list is additive"
  home=$(member_list_home nolist)
  [ ! -e "$home/data/voy/members" ] || fail "fixture drift: this home must have no member list"
  cap=$(capture nolist "voy-judge-decision-shape")
  out=$(chart_json "$home" voy "$cap")

  if ! printf '%s' "$out" \
    | jq -S 'del(.membership.list, .membership.from_list, .membership_defects, .counts.membership_defects)' \
    | diff -u "$golden" - > "$TMP_ROOT/nolist.diff" 2>&1; then
    cat "$TMP_ROOT/nolist.diff" >&2
    fail "a chart with no member list must draw exactly what it drew before the member list existed - the diff above is what changed"
  fi
  # And the four added fields say, on such a chart, that nothing was added.
  [ "$(printf '%s' "$out" | jq -r '.membership.list')" = "null" ] \
    || fail "a chart with no member list must not name one"
  [ "$(printf '%s' "$out" | jq -r '.membership.from_list')" = 0 ] \
    || fail "a chart with no member list can have drawn no member from one"
  [ "$(printf '%s' "$out" | jq -r '.membership.rule')" = 'id is "voy" or begins with "voy-"; a longer undertaking sharing this prefix is drawn here too, which is the recoverable direction' ] \
    || fail "the rule line must state what actually determined membership, and here that is the prefix rule alone"
  pass "a chart with no member list draws exactly the page it drew before"
}

test_an_existing_record_joins_an_undertaking_without_being_renamed() {
  # THE DEFECT THIS EXISTS FOR. `tasks-axi` has no rename - `mv` moves a record
  # between backlog files and preserves the id byte-exact - so assigning existing
  # work to a newly named undertaking meant renaming it, and renaming it breaks
  # every reference that has already left this vessel. The list assigns it in
  # place instead, and the id is not touched by anything here.
  local home cap out before
  home=$(member_list_home retrofit)
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] legacy-reader - Existed long before the undertaking was named (repo: r) (kind: ship) (since 2026-07-01)
- [ ] legacy-fog-shape - A dark patch that predates the chart (repo: r) (kind: fog) (since 2026-07-01) (hold: nobody could name it yet) (hold-kind: future)
EOF
  cap=$(capture retrofit "voy-judge-decision-shape")

  # REPRODUCE. Without a list, the prefix rule cannot see either record.
  before=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$before" | jq -r '[.takeable[].id]|index("legacy-reader")')" = "null" ] \
    || fail "the reproduction is stale: the prefix rule now reaches a record that does not carry the prefix"

  mkdir -p "$home/data/voy"
  cat > "$home/data/voy/members" <<'EOF'
# work this undertaking was named over
legacy-reader
legacy-fog-shape
EOF
  out=$(chart_json "$home" voy "$cap")

  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("legacy-reader")')" != "null" ] \
    || fail "a record named in the member list must be drawn, or the retrofit path assigns nothing"
  [ "$(printf '%s' "$out" | jq -r '[.fog[].id]|index("legacy-fog-shape")')" != "null" ] \
    || fail "a listed member must reach the section its kind names, exactly like a prefix member"
  # The id is untouched: it is still the id the backlog and every reference off
  # this vessel already carry.
  assert_grep 'legacy-reader - Existed long before' "$home/data/backlog.md" \
    "the record id must not have moved: assigning it is the whole point of not renaming it"
  assert_no_grep 'voy-legacy-reader' "$home/data/backlog.md" \
    "nothing may rename a record into the chart namespace"
  # Everything the prefix rule drew before still draws.
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy-real-work")')" != "null" ] \
    || fail "the union must not cost the prefix rule a single member"
  [ "$(printf '%s' "$out" | jq -r '.membership.members')" = "$(( $(printf '%s' "$before" | jq -r '.membership.members') + 2 ))" ] \
    || fail "the listed records must be counted as members, on top of the prefix members"

  # The rule line the chart prints has to stay true of the chart it is on.
  assert_contains "$(printf '%s' "$out" | jq -r '.membership.rule')" "plus 2 records named in" \
    "the membership line must say what actually determined membership, including how many members the list added"
  assert_contains "$(printf '%s' "$out" | jq -r '.membership.rule')" 'begins with "voy-"' \
    "the prefix rule must still be stated: it is not replaced, only joined"
  [ "$(printf '%s' "$out" | jq -r '.membership.from_list')" = 2 ] \
    || fail "the chart must count how many of its members only the list assigned"
  [ "$(printf '%s' "$out" | jq -r '.membership.list')" = "$home/data/voy/members" ] \
    || fail "the chart must name the list it read, or a wrong member cannot be traced to its line"
  # A permanent path, not a migration: the disclosure of what it cannot check is
  # printed with it rather than filed in documentation somebody has to find.
  assert_contains "$(printf '%s' "$out" | jq -r '.limits|join(" ")')" "not itself a record in this backlog or archive" \
    "a chart drawn from a member list must print the overlap that list still cannot catch, and that is a prefix owner this home holds no record for"
  pass "an existing record joins an undertaking through the member list, with no id change anywhere"
}

test_a_member_id_qualified_with_another_home_is_refused_rather_than_resolved() {
  # The chart already drops another home's records before the collapse rule
  # groups anything, because reaching into another home's backlog would put a
  # second owner on that home. A qualified member id would quietly re-open
  # exactly that, so it is refused and named instead of resolved.
  local home cap out
  home=$(member_list_home qualified)
  mkdir -p "$home/data/voy"
  printf 'sc1/legacy-reader\n' > "$home/data/voy/members"
  cap=$(capture qualified)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.counts.membership_defects')" = 1 ] \
    || fail "a qualified member id must be counted as a defect, not silently ignored"
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].cause')" = "qualified" ] \
    || fail "a qualified member id needs its own cause: it is refused for a different reason than an id that resolves to nothing"
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].id')" = "sc1/legacy-reader" ] \
    || fail "the refused entry must be named exactly as it was written, or nobody can find the line"
  [ "$(printf '%s' "$out" | jq -r '.membership.from_list')" = 0 ] \
    || fail "a refused entry must assign no member"
  assert_contains "$(printf '%s' "$out" | jq -r '.membership_defects[0].why')" "ONE home" \
    "the refusal must say which boundary it is holding, or it reads as pedantry"
  assert_contains "$(printf '%s' "$out" | jq -r '.membership_defects[0].why')" "routed request" \
    "the refusal must name the paths that DO cross vessels, or it leaves the reader stuck"
  pass "a member id qualified with another home is refused loudly rather than resolved"
}

test_a_member_that_lives_in_another_home_is_named_and_never_reached_for() {
  # A BARE id can also name a record that exists - in a home this chart does not
  # read. Membership must not reach for it. From here it is indistinguishable
  # from a record that was never created, and saying so plainly is the honest
  # report: the reason names both possibilities rather than asserting the wrong one.
  local home other cap out
  home=$(member_list_home crosshome)
  other=$(make_home crosshome-secondmate)
  cat > "$other/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] secondmate-only-work - Real, and owned by another home (repo: r) (kind: ship) (since 2026-07-01)
EOF
  mkdir -p "$home/data/voy"
  printf 'secondmate-only-work\n' > "$home/data/voy/members"
  cap=$(capture crosshome)

  # The record really does exist where the chart is not looking.
  assert_grep 'secondmate-only-work' "$other/data/backlog.md" "fixture drift: the other home must really hold this record"
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.membership_defects[]|select(.id=="secondmate-only-work")]|length')" = 1 ] \
    || fail "a member that resolves nowhere in this home must be named, never dropped behind a member count"
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].cause')" = "unresolvable" ] \
    || fail "a member this home cannot resolve must say so; reaching into the other home is the boundary this chart holds"
  assert_contains "$(printf '%s' "$out" | jq -r '.membership_defects[0].why')" "another home this chart deliberately does not read" \
    "the reason must offer the other home as a possibility rather than claim the record does not exist"
  case "$(printf '%s' "$out" | jq -r '[.takeable[].id,.fog[].id,.out_of_course[].id]|join(",")')" in
    *secondmate-only-work*) fail "a record from another home must never be drawn on this chart" ;;
  esac
  pass "a bare member id living in another home is named and never reached for"
}

test_a_member_that_resolves_to_nothing_is_named_rather_than_dropped() {
  # The list is a SECOND source and it rots: the record it names can be deleted
  # or moved after the line is written. Dropping the line quietly would shrink
  # the chart with nothing on the page saying so, which is the exact failure this
  # tool exists against - prefer the chart accusing itself over under-drawing.
  local home cap out summary
  home=$(member_list_home gone)
  mkdir -p "$home/data/voy"
  printf 'legacy-reader\n' > "$home/data/voy/members"
  cap=$(capture gone)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].cause')" = "unresolvable" ] \
    || fail "a member the backlog and the archive do not hold must be reported as unresolvable"
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].id')" = "legacy-reader" ] \
    || fail "the missing member must be named, or the reader cannot tell which line rotted"
  [ "$(printf '%s' "$out" | jq -r '.membership.members')" = 9 ] \
    || fail "an unresolvable entry must not inflate the member count: there is no record to count"

  # And it is visible without reading JSON, directly under the count it questions.
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  assert_contains "$summary" "MEMBER LIST" "the refused entries must reach the human-readable chart, not only the JSON"
  assert_contains "$summary" "could not be honoured" "the member count must say how many of its list lines failed"
  assert_contains "$summary" "legacy-reader" "the summary must name the entry, not only count it"
  pass "a member that resolves to nothing is named on the chart rather than dropped"
}

test_a_record_two_undertakings_both_claim_is_drawn_on_neither() {
  # EXCLUSIVITY, AND IT IS THE LOAD-BEARING ONE. A record counted in two "what is
  # left" views leaves NEITHER chart able to say whether it is finished for its
  # own purposes, and exclusivity is what makes a deviation from a destination
  # measurable at all. Two lists in one home is the only form of this the chart
  # can see, because it is the only one where both claims are in hand.
  local home cap voy other
  home=$(member_list_home contested)
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] other - The other undertaking (repo: r) (kind: ship) (since 2026-07-02)
- [ ] shared-reader - Both lists name it (repo: r) (kind: ship) (since 2026-07-01)
EOF
  mkdir -p "$home/data/voy" "$home/data/other"
  printf 'shared-reader\n' > "$home/data/voy/members"
  printf 'shared-reader\n' > "$home/data/other/members"
  cap=$(capture contested)

  voy=$(chart_json "$home" voy "$cap")
  other=$(chart_json "$home" other "$cap")
  # NEITHER draws it. The chart picks no winner, exactly as it picks none between
  # a disagreeing id marker and record kind.
  case "$(printf '%s' "$voy" | jq -r '[.takeable[].id]|join(",")')" in
    *shared-reader*) fail "a contested record must not be drawn: counted twice, neither chart can say whether it is finished" ;;
  esac
  case "$(printf '%s' "$other" | jq -r '[.takeable[].id]|join(",")')" in
    *shared-reader*) fail "the second chart must not draw a contested record either - drawing it on one side only would be picking a winner in silence" ;;
  esac
  # BOTH say so, and each names the other claimant so the collision can be found
  # from whichever chart the reader happens to be on.
  [ "$(printf '%s' "$voy" | jq -r '.membership_defects[0].cause')" = "contested" ] \
    || fail "the first chart must report the collision loudly"
  [ "$(printf '%s' "$other" | jq -r '.membership_defects[0].cause')" = "contested" ] \
    || fail "the second chart must report the collision too, or the defect is invisible from that side"
  [ "$(printf '%s' "$voy" | jq -r '.membership_defects[0].claimed_by|join(",")')" = "other" ] \
    || fail "the collision must name the other undertaking claiming the record"
  [ "$(printf '%s' "$other" | jq -r '.membership_defects[0].claimed_by|join(",")')" = "voy" ] \
    || fail "the collision must name the other claimant from that side too"
  assert_contains "$(printf '%s' "$voy" | jq -r '.membership_defects[0].why')" "cut too coarsely" \
    "the report must name the real fix - re-cutting the work - rather than leave the reader to choose a chart"
  # And this is the case `contested` is now the only true report of: no record of
  # this home owns `shared-reader` by prefix, so nothing decides the tie by
  # construction and refusing both is the honest move. Where a prefix owner DOES
  # exist the news is different, and a different pair of causes says so.
  [ "$(printf '%s' "$voy" | jq -r '[.membership_defects[]|select(.cause=="owned-elsewhere" or .cause=="claimed-elsewhere")]|length')" = 0 ] \
    || fail "fixture drift: no record may own shared-reader by prefix, or this stopped being the contested case at all"

  # It is ranked above the merely superfluous, so a broken exclusivity is never
  # pushed down the page by a line that assigns nothing.
  printf 'voy-real-work\n' >> "$home/data/voy/members"
  voy=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$voy" | jq -r '.membership_defects[0].cause')" = "contested" ] \
    || fail "a contested record must be reported first: it is the one that makes two charts unmeasurable"
  pass "a record two undertakings both claim is reported on both and drawn on neither"
}

test_a_retrofitted_decision_is_drawn_and_its_group_siblings_are_not() {
  # The member list assigns a RECORD, while the collapse rule groups by the
  # undertaking the record id names - and a decision that predates this chart
  # keeps the id it always had, so its group is some other undertaking. Left
  # alone, such a record reached the actionable surface, was dropped by this
  # scoping, and was then reconciled as "not returned as actionable": a sentence
  # refuted by the very surface it describes, which is this chart's own failure
  # mode rather than an acceptable edge.
  # The other half matters just as much: taking the group WHOLE would draw its
  # non-member siblings here, and a record on two charts is the exclusivity this
  # membership rule is built on.
  local home cap grouped out
  home=$(make_home retrogroup)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] legacy-judge-decision-shape - The ruling, and it predates the chart (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
- [ ] legacy-a-decision-shape - The analyst restating the same key (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
- [ ] legacy-a-decision-scope - A question only the analyst raised (repo: r) (kind: captain) (since 2026-07-01) (hold: Which scope) (hold-kind: captain)
EOF
  mkdir -p "$home/data/voy"
  printf 'legacy-judge-decision-shape\n' > "$home/data/voy/members"
  cap=$(capture retrogroup "legacy-judge-decision-shape" "legacy-a-decision-shape" "legacy-a-decision-scope")

  # REPRODUCE THE SHAPE. The fold really does file all three under one group whose
  # id is not this chart, with one ruling, one folded variant, one unpaired.
  grouped=$("$INV" --json --from "$cap")
  [ "$(printf '%s' "$grouped" | jq -r '[.groups[].group]|join(",")')" = "legacy" ] \
    || fail "the reproduction is stale: the fold no longer groups these under the undertaking their ids name"

  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.decisions[].id]|join(",")')" = "legacy-judge-decision-shape" ] \
    || fail "a retrofitted decision must be DRAWN: it reached the actionable surface, and dropping it here is the loss this chart exists against"
  [ "$(printf '%s' "$out" | jq -r '.counts.withheld')" = 0 ] \
    || fail "nothing may be reported as withheld from a surface that returned it - that sentence would be refuted by the record it describes"
  # And the siblings of that group stay on whatever chart owns them.
  case "$(printf '%s' "$out" | jq -r '[.decisions[].id, (.decisions[]|.variants[]?.id), .withheld[].id, .unplaced[].id]|join(",")')" in
    *legacy-a-decision-shape*|*legacy-a-decision-scope*)
      fail "a non-member sibling of the group must not be drawn here: the list assigns a record, never the group around it, and one record on two charts is the exclusivity this rule rests on" ;;
  esac
  [ "$(printf '%s' "$out" | jq -r '.counts.records')" = 1 ] \
    || fail "the count of records that reached the actionable surface must count the member records only, or it asserts more arrived than this chart owns"
  pass "a retrofitted decision is drawn from a group this chart does not own, and its siblings are not"
}

test_a_member_list_line_the_prefix_rule_already_covers_assigns_nothing() {
  # The list is the RETROFIT path only. Anything created after its undertaking
  # exists is named under the chart by construction, so a line restating that
  # puts a second way to assign one record on one contract. The record keeps
  # drawing - the prefix rule has it either way - and the line is reported as
  # doing nothing rather than as a reason to withdraw a member.
  local home cap out
  home=$(member_list_home redundant)
  mkdir -p "$home/data/voy"
  printf 'voy-real-work\n' > "$home/data/voy/members"
  cap=$(capture redundant)
  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '.membership_defects[0].cause')" = "redundant" ] \
    || fail "a line the prefix rule already covers must be reported as assigning nothing"
  [ "$(printf '%s' "$out" | jq -r '[.takeable[].id]|index("voy-real-work")')" != "null" ] \
    || fail "a redundant line must never cost the chart the member the prefix rule already had"
  [ "$(printf '%s' "$out" | jq -r '.membership.from_list')" = 0 ] \
    || fail "a record the prefix rule already draws was not assigned by the list, and the count must not claim it was"
  assert_contains "$(printf '%s' "$out" | jq -r '.membership_defects[0].why')" "delete the line" \
    "the report must say what to do about it, since nothing is wrong with the record itself"
  pass "a member list line the prefix rule already covers is reported as assigning nothing"
}

test_a_member_the_fold_hung_under_a_foreign_ruling_is_named_with_a_true_cause() {
  # The mirror of the retrofitted-decision case above, and the harder half. There
  # the member WAS the ruling of a group this chart does not own. Here the member
  # is the record the fold attached UNDER a ruling that belongs to another
  # undertaking, and neither move is open: showing it beneath that ruling would
  # draw a record this chart does not own, while lifting it onto the decision list
  # would put an analyst restatement where the ruling belongs - the substitution
  # the fold exists to prevent. What must not happen is the third thing, and it is
  # what happened: the record was dropped and then reconciled as "present in the
  # backlog but not returned as actionable", a sentence the very surface it came
  # from refutes.
  local home cap grouped out summary
  home=$(make_home foldedelsewhere)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] legacy-judge-decision-shape - The ruling, and it belongs to another undertaking (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
- [ ] legacy-a-decision-shape - The analyst restating the same key (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
EOF
  mkdir -p "$home/data/voy"
  printf 'legacy-a-decision-shape\n' > "$home/data/voy/members"
  cap=$(capture foldedelsewhere "legacy-judge-decision-shape" "legacy-a-decision-shape")

  # REPRODUCE THE SHAPE THAT MAKES THE OLD SENTENCE FALSE. The surface really did
  # return the member, and the fold really did hang it under a ruling whose group
  # is not this chart - which is exactly the state in which "not returned as
  # actionable" is refuted by the record it describes.
  [ "$(jq -r '[.decisions_open[].id]|index("legacy-a-decision-shape")' "$cap")" != "null" ] \
    || fail "the reproduction is stale: the member must reach the actionable surface, or there is no false sentence left to prevent"
  grouped=$("$INV" --json --from "$cap")
  [ "$(printf '%s' "$grouped" | jq -r '.groups[]|select(.group=="legacy")|.decisions[]|select(.id=="legacy-judge-decision-shape")|[.variants[].id]|join(",")')" = "legacy-a-decision-shape" ] \
    || fail "the reproduction is stale: the fold no longer folds the analyst record under a judge ruling whose group this chart does not own"

  out=$(chart_json "$home" voy "$cap")
  [ "$(printf '%s' "$out" | jq -r '[.withheld[]|select(.id=="legacy-a-decision-shape")]|length')" = 1 ] \
    || fail "a member the fold hung under a foreign ruling must still be reconciled onto this chart: no section draws it, so dropping it makes it invisible on every surface at once"
  [ "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="legacy-a-decision-shape")|.cause')" = "folded-elsewhere" ] \
    || fail "it needs its own cause: the surface DID return it, so every cause below the returned-record ones is a false sentence about this record"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="legacy-a-decision-shape")|.why')" "reached the actionable surface" \
    "the reason must not claim the surface never carried this record, because it did"
  # THE FALSE SENTENCE, PINNED ABSENT BY ITS OWN WORDS.
  case "$(printf '%s' "$out" | jq -r '[.withheld[].why]|join(" ")')" in
    *"not returned as actionable"*)
      fail "the record reached the actionable surface, so nothing on this chart may say it did not" ;;
  esac

  # AND THE FOLD IS NOT UNDONE. The restatement is not promoted to the ruling,
  # and the ruling of the other undertaking is not dragged onto this chart to
  # carry it.
  [ "$(printf '%s' "$out" | jq -r '[.decisions[].id]|join(",")')" = "" ] \
    || fail "no decision may be drawn here: the ruling belongs to another undertaking and this chart owns only the record folded beneath it"
  case "$(printf '%s' "$out" | jq -r '[.decisions[].id, (.decisions[]|.variants[]?.id), .takeable[].id, .unplaced[].id, .withheld[].id]|join(",")')" in
    *legacy-judge-decision-shape*)
      fail "a ruling of another undertaking must never be drawn here merely because this chart owns the record folded under it" ;;
  esac

  # AND THE NUMBERS ABOVE MUST NOT REFUTE THE ROW BELOW. This record reached the
  # actionable surface and the fold then dropped it, so it is counted in `records`
  # and in `folded` and in `withheld` at once - honest only while the page says
  # they are one record, which is the whole job of `withheld_folded`.
  [ "$(printf '%s' "$out" | jq -r '.counts.records')" = 1 ] \
    || fail "a record the surface returned must be counted as having reached it, or the count refutes the row four lines below that says it did"
  [ "$(printf '%s' "$out" | jq -r '.counts.folded')" = 1 ] \
    || fail "the fold dropped this record, so the folded-away count must carry it"
  [ "$(printf '%s' "$out" | jq -r '.counts.withheld_folded')" = 1 ] \
    || fail "without this the same record is counted as folded and as withheld with nothing on the page saying they are one record"

  # Read end to end on the RENDERED page, which is where a reader meets them.
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  assert_contains "$summary" "of those, 1 reached the actionable surface" \
    "the page must not say nothing reached the actionable surface a few lines above a row whose reason says this record did"
  assert_contains "$summary" "folded away rather than never returned" \
    "the page must reconcile the record it counts as folded with the one it counts as withheld, or the two numbers read as two records"
  case "$summary" in
    *"of those, 0 reached the actionable surface"*)
      fail "arithmetic a reader can catch out is what teaches them to stop believing every other number on the chart" ;;
  esac
  pass "a member the fold hung under a foreign ruling is named with a cause that is true of it, and the counts above it agree"
}

test_a_member_list_line_naming_a_group_id_never_drags_that_group_onto_this_chart() {
  # The member list assigns a RECORD, never the namespace around it. A record id
  # that happens to be a collapse-rule GROUP id is still just one record, so the
  # decisions filed under that group belong to whatever undertaking owns it and
  # drawing them here would put one record on two charts - the exclusivity this
  # whole membership rule rests on.
  # A group may be taken WHOLE only on the PREFIX rule, because only there is
  # every record inside it a member of this chart by the same construction.
  local home cap grouped voy grp
  home=$(make_home listedgroup)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
- [ ] grp - The other undertaking, and the id the list names (repo: r) (kind: ship) (since 2026-07-02)
- [ ] grp-judge-decision-shape - The ruling of that other undertaking (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
- [ ] grp-a-decision-shape - The analyst restating the same key (repo: r) (kind: captain) (since 2026-07-01) (hold: Which shape) (hold-kind: captain)
EOF
  mkdir -p "$home/data/voy"
  printf 'grp\n' > "$home/data/voy/members"
  cap=$(capture listedgroup "grp-judge-decision-shape" "grp-a-decision-shape")

  # REPRODUCE THE SHAPE. The fold really does file both decisions under one group
  # whose id is exactly the id the member list names - which is the only reason a
  # whole-group take could ever reach records this chart does not own.
  grouped=$("$INV" --json --from "$cap")
  [ "$(printf '%s' "$grouped" | jq -r '[.groups[].group]|join(",")')" = "grp" ] \
    || fail "the reproduction is stale: the fold no longer groups these two under the id the member list names"

  voy=$(chart_json "$home" voy "$cap")
  grp=$(chart_json "$home" grp "$cap")

  # The listed record itself is drawn - that is what the line asked for.
  [ "$(printf '%s' "$voy" | jq -r '[.takeable[].id]|index("grp")')" != "null" ] \
    || fail "the record the line actually names must still be drawn, or the retrofit path assigns nothing"
  # Its group siblings are not, in any section and not as a folded variant either.
  case "$(printf '%s' "$voy" | jq -r '[.decisions[].id, (.decisions[]|.variants[]?.id), .withheld[].id, .takeable[].id, .unplaced[].id]|join(",")')" in
    *grp-judge-decision-shape*|*grp-a-decision-shape*)
      fail "a member list line names ONE record: taking the group around it draws records that are members of neither rule, and that is one record on two charts" ;;
  esac
  [ "$(printf '%s' "$voy" | jq -r '.counts.records')" = 0 ] \
    || fail "no record of that group reached this chart, so the count of what did must not claim otherwise"

  # And the undertaking that owns them by prefix still draws both - nothing
  # drawing today stops drawing because another chart list named its group id.
  [ "$(printf '%s' "$grp" | jq -r '[.decisions[].id]|join(",")')" = "grp-judge-decision-shape" ] \
    || fail "the owning chart must still draw its own ruling"
  [ "$(printf '%s' "$grp" | jq -r '[.decisions[]|.variants[].id]|join(",")')" = "grp-a-decision-shape" ] \
    || fail "the owning chart must still draw the variant folded under its ruling"
  pass "a member list line naming a group id assigns that record only, and its group siblings stay on the chart that owns them"
}

test_a_foreign_claim_on_a_prefix_owned_record_is_refused_there_and_reported_here() {
  # PREFIX OWNERSHIP IS BY CONSTRUCTION AND CANNOT BE EDITED AWAY. A record whose
  # id carries this chart name belongs here whatever any file says, so a foreign
  # list naming it changes NOTHING about what is drawn - it is simply a wrong
  # line, and the only chart that can see it is the one it points at. Reported on
  # both pages, the collision resolves to the record being drawn exactly once,
  # which is what makes the exclusivity rule real rather than asserted.
  local home cap voy other summary
  home=$(member_list_home foreignclaim)
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] other - The other undertaking (repo: r) (kind: ship) (since 2026-07-02)
EOF
  mkdir -p "$home/data/other"
  printf 'voy-real-work\n' > "$home/data/other/members"
  cap=$(capture foreignclaim)
  [ ! -e "$home/data/voy/members" ] \
    || fail "fixture drift: the owning chart must have no list of its own, or this proves nothing about a claim it never made"

  voy=$(chart_json "$home" voy "$cap")
  other=$(chart_json "$home" other "$cap")

  # THE LOAD-BEARING HALF: the owner goes on drawing it.
  [ "$(printf '%s' "$voy" | jq -r '[.takeable[].id]|index("voy-real-work")')" != "null" ] \
    || fail "the chart that owns a record by prefix must keep drawing it: nothing drawing today may stop because a third party edited a file"
  [ "$(printf '%s' "$voy" | jq -r '.membership_defects[0].cause')" = "claimed-elsewhere" ] \
    || fail "the owner must report the foreign claim: it is written in a file this chart does not own, so no other page can show it"
  [ "$(printf '%s' "$voy" | jq -r '.membership_defects[0].claimed_by|join(",")')" = "other" ] \
    || fail "the report must name the chart whose list made the claim, or the offending line cannot be found"
  assert_contains "$(printf '%s' "$voy" | jq -r '.membership_defects[0].why')" "STILL DRAWN" \
    "the report must say the record keeps drawing here, or it contradicts the section further down that draws it"
  assert_contains "$(printf '%s' "$voy" | jq -r '.membership_defects[0].why')" "foreign line is the one to delete" \
    "the report must name the line to delete, since nothing is wrong with the record or with this chart"

  # THE OTHER HALF, and together they are the whole point: one record, one chart.
  [ "$(printf '%s' "$other" | jq -r '.membership_defects[0].cause')" = "owned-elsewhere" ] \
    || fail "a line naming a record the prefix rule already owns must be refused under its own cause, never called contested"
  [ "$(printf '%s' "$other" | jq -r '.membership_defects[0].claimed_by|join(",")')" = "voy" ] \
    || fail "the refusal must name the undertaking that owns the record by construction"
  case "$(printf '%s' "$other" | jq -r '[.takeable[].id,.fog[].id,.out_of_course[].id,.decisions[].id,.withheld[].id,.unplaced[].id]|join(",")')" in
    *voy-real-work*)
      fail "the chart whose list named it must NOT draw it: drawing it on both sides is the one record on two charts this rule rests on refusing" ;;
  esac
  [ "$(printf '%s' "$other" | jq -r '.membership.from_list')" = 0 ] \
    || fail "a refused entry must assign no member"

  # The owner has no list of its own, so its page must read as a report about
  # somebody else's file rather than name a file this chart does not have.
  [ "$(printf '%s' "$voy" | jq -r '.membership.list')" = "null" ] \
    || fail "fixture drift: the owning chart must still have no member list"
  summary=$("$CHART" voy --summary --from "$cap" \
    --backlog "$home/data/backlog.md" --archive "$home/data/done-archive.md" --data "$home/data")
  assert_contains "$summary" "MEMBER LIST" "a foreign claim must reach the human-readable chart too, not only the JSON"
  assert_contains "$summary" "voy-real-work" "the summary must name the record another list claimed"
  case "$summary" in
    *"entries in null"*) fail "a chart with no member list of its own must never name one" ;;
  esac
  # And the printed disclosure names what is STILL uncaught rather than a case the
  # chart now catches, because a false limit is the fault this script exists on.
  assert_contains "$(printf '%s' "$voy" | jq -r '.limits|join(" ")')" "not itself a record in this backlog or archive" \
    "the limit must name the residual case - a prefix owner this home holds no record for - now that the record-owned case is caught"
  pass "a foreign claim on a prefix-owned record is refused there and reported here, so the record is drawn exactly once"
}

test_an_unreadable_member_list_is_fatal_rather_than_silently_empty() {
  # The policy the backlog reader in this same file already holds, for the same
  # reason. An ABSENT list is genuinely empty and normal; degrading an UNREADABLE
  # one to "this list is empty" shrinks the page with nothing on it saying so.
  # For a FOREIGN list it is worse than a shrunken page: the exclusivity check
  # simply stops firing, and a contested record is drawn on both charts with no
  # defect row anywhere.
  local home cap out rc
  home=$(member_list_home unreadable)
  mkdir -p "$home/data/voy" "$home/data/other"
  printf 'legacy-reader\n' > "$home/data/voy/members"
  cap=$(capture unreadable)
  chmod 000 "$home/data/voy/members"
  if [ -r "$home/data/voy/members" ]; then
    chmod 600 "$home/data/voy/members"
    pass "skipped: this user can read a mode-000 file, so an unreadable list cannot be staged here"
    return 0
  fi

  rc=0
  out=$(chart_json "$home" voy "$cap" 2>&1) || rc=$?
  chmod 600 "$home/data/voy/members"
  [ "$rc" != 0 ] \
    || fail "an unreadable member list must be fatal: drawing anyway names a list the chart never read and under-draws in silence"
  assert_contains "$out" "$home/data/voy/members" \
    "the refusal must name the file it could not read, or nobody can tell which list to fix"

  # The foreign half, which is the one no reader of this chart could have guessed.
  printf 'voy-real-work\n' > "$home/data/other/members"
  chmod 000 "$home/data/other/members"
  rc=0
  out=$(chart_json "$home" voy "$cap" 2>&1) || rc=$?
  chmod 600 "$home/data/other/members"
  [ "$rc" != 0 ] \
    || fail "an unreadable list belonging to ANOTHER chart must be fatal too: read as empty it silently stops exclusivity being checked at all"
  assert_contains "$out" "$home/data/other/members" \
    "the refusal must name the foreign list it could not read"
  pass "an unreadable member list is fatal rather than degraded into an empty one"
}

test_the_chart_prints_its_own_limits_and_does_not_soften_them() {
  local home cap out limits
  home=$(make_home limits)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] voy - The undertaking (repo: r) (kind: ship) (since 2026-07-28)
EOF
  cap=$(capture limits)
  out=$(chart_json "$home" voy "$cap")
  limits=$(printf '%s' "$out" | jq -r '.limits|join(" ")')
  # The honesty the board already holds itself to survives into the chart.
  assert_contains "$limits" "verified by nothing" \
    "the unverified-judge-coverage limit must survive onto the chart"
  assert_contains "$limits" "EDITED unsupervised" \
    "the chart must print that unsupervised editing is not unsupervised landing"
  assert_contains "$limits" "Fog is whatever somebody wrote down as fog" \
    "the chart must not imply its fog is complete"
  [ "$(printf '%s' "$out" | jq -r '.limits|length')" -ge 5 ] \
    || fail "the printed limits must not be quietly trimmed"
  pass "the chart prints its own limits, including the ones it inherits"
}

test_the_chart_is_read_only() {
  assert_no_grep 'fm-decision-hold.sh hold' "$CHART" "the chart must not create holds"
  assert_no_grep 'fm-decision-hold.sh resolve' "$CHART" "the chart must not resolve holds"
  assert_no_grep 'tasks-axi' "$CHART" "the chart must not mutate the backlog"
  pass "the chart never writes a record"
}

test_both_surfaces_state_the_boundary_between_them() {
  # Two tools that look alike and do not name their own edge get chosen wrongly,
  # and the wrong choice is silent. Each must point at the other.
  local chart_skill=$ROOT/.agents/skills/sea-chart/SKILL.md
  local board_skill=$ROOT/.agents/skills/decisionboard/SKILL.md
  assert_present "$chart_skill" "the sea-chart skill is missing"
  assert_present "$board_skill" "the decisionboard skill is missing"
  assert_grep 'decision board' "$chart_skill" "the chart must say when to use the board instead"
  assert_grep 'sea-chart' "$board_skill" "the board must say when to use the chart instead"
  assert_grep 'destination' "$chart_skill" "the chart must name the destination as the difference"
  assert_grep 'destination' "$board_skill" "the board must name the destination as the difference"
  assert_grep '/sea-chart' "$ROOT/AGENTS.md" "the chart needs its load trigger declared inline"
  assert_grep '/sea-chart' "$ROOT/README.md" "the chart belongs in the built-in skill table"
  pass "each surface states the boundary against the other, and the trigger is declared"
}

test_the_silent_loss_is_reproduced_then_absent
test_a_secondmate_decision_reaches_the_merged_surface_then_stays_off_this_chart
test_a_blocker_that_is_done_in_the_archive_no_longer_hides_takeable_work
test_a_dangling_blocker_stops_hiding_takeable_work_and_is_named
test_an_archived_twin_never_cancels_a_live_blocker
test_a_captain_thread_without_a_decision_key_is_recovered
test_withheld_records_name_their_own_cause
test_fog_and_out_of_course_can_never_be_a_captain_decision
test_the_chart_kinds_are_stored_on_the_field_the_chart_reads
test_the_filing_instruction_names_the_field_the_chart_reads
test_a_member_the_chart_cannot_place_is_named_not_silently_dropped
test_an_unpaired_analyst_variant_is_reconciled_rather_than_counted_as_drawn
test_an_id_marker_and_a_record_kind_that_disagree_are_reported_never_offered
test_a_swapped_chart_kind_is_reported_even_though_a_section_drew_it
test_a_correctly_filed_chart_record_is_never_called_misfiled
test_the_misfiled_report_never_sends_a_reader_to_a_surface_without_the_record
test_the_report_headings_assert_nothing_their_own_rows_can_contradict
test_a_kind_defect_is_never_pushed_down_the_page_by_routine_held_work
test_chart_kinds_stay_off_the_blockage_surface_but_are_disclosed
test_a_chart_without_a_destination_is_refused
test_the_destination_is_read_and_never_invented
test_the_ageing_probe_finds_a_decision_its_own_twin_already_closed
test_a_record_is_never_reported_as_its_own_twin
test_the_unsupervised_marking_is_a_pair_and_never_a_scalar
test_membership_is_scoped_and_stated
test_a_chart_with_no_member_list_draws_exactly_what_it_drew_before
test_an_existing_record_joins_an_undertaking_without_being_renamed
test_a_member_id_qualified_with_another_home_is_refused_rather_than_resolved
test_a_member_that_lives_in_another_home_is_named_and_never_reached_for
test_a_member_that_resolves_to_nothing_is_named_rather_than_dropped
test_a_record_two_undertakings_both_claim_is_drawn_on_neither
test_a_retrofitted_decision_is_drawn_and_its_group_siblings_are_not
test_a_member_list_line_the_prefix_rule_already_covers_assigns_nothing
test_a_member_the_fold_hung_under_a_foreign_ruling_is_named_with_a_true_cause
test_a_member_list_line_naming_a_group_id_never_drags_that_group_onto_this_chart
test_a_foreign_claim_on_a_prefix_owned_record_is_refused_there_and_reported_here
test_an_unreadable_member_list_is_fatal_rather_than_silently_empty
test_the_chart_prints_its_own_limits_and_does_not_soften_them
test_the_chart_is_read_only
test_both_surfaces_state_the_boundary_between_them
