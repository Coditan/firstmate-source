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
  # The reasons in words must not collapse back into one shared sentence.
  [ "$(printf '%s' "$out" | jq -r '[.withheld[].why]|unique|length')" = 4 ] \
    || fail "four distinct causes must carry four distinct reasons, or the labels have silently collapsed"
  assert_contains "$(printf '%s' "$out" | jq -r '.withheld[]|select(.id=="voy-blocked")|.held_by')" "voy-open" \
    "a blocked record must still name what is holding it"
  pass "each withheld record names the cause that kept it off the actionable surface"
}

test_fog_and_out_of_course_can_never_be_a_captain_decision() {
  # Structure, not prose: captain-actionability requires kind captain.
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
test_an_archived_twin_never_cancels_a_live_blocker
test_a_captain_thread_without_a_decision_key_is_recovered
test_withheld_records_name_their_own_cause
test_fog_and_out_of_course_can_never_be_a_captain_decision
test_chart_kinds_stay_off_the_blockage_surface_but_are_disclosed
test_a_chart_without_a_destination_is_refused
test_the_destination_is_read_and_never_invented
test_the_ageing_probe_finds_a_decision_its_own_twin_already_closed
test_a_record_is_never_reported_as_its_own_twin
test_the_unsupervised_marking_is_a_pair_and_never_a_scalar
test_membership_is_scoped_and_stated
test_the_chart_prints_its_own_limits_and_does_not_soften_them
test_the_chart_is_read_only
test_both_surfaces_state_the_boundary_between_them
