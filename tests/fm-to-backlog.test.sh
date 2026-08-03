#!/usr/bin/env bash
# Behavior tests for bin/fm-to-backlog.sh, plus the attribution contract for the
# to-tickets adoption it belongs to.
#
# The attribution tests are here on purpose rather than left to review. The MIT
# condition is that the notice travels with the work, and the failure mode is
# silent: a later edit that drops the notice leaves a working skill and an
# unmet licence term, which no behavior test would ever catch.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TO_BACKLOG="$ROOT/bin/fm-to-backlog.sh"
SKILL="$ROOT/.agents/skills/to-backlog/SKILL.md"
PROVENANCE="$ROOT/docs/to-backlog-provenance.md"
README="$ROOT/README.md"
SCRIPTS_DOC="$ROOT/docs/scripts.md"
AGENTS="$ROOT/AGENTS.md"

# --- attribution contract (no external tools needed) ------------------------

test_attribution_travels_with_the_work() {
  local file
  # Every surface a reader arrives on must name the source, the author, and the
  # licence. A pointer alone is not enough on the skill and the script: those
  # are the files that get copied out of this repository.
  for file in "$SKILL" "$TO_BACKLOG" "$PROVENANCE"; do
    assert_present "$file" "$(basename "$file") is missing"
    assert_grep "to-tickets" "$file" "$(basename "$file") does not name the source skill"
    assert_grep "mattpocock/skills" "$file" "$(basename "$file") does not name the source repository"
    assert_grep "Matt Pocock" "$file" "$(basename "$file") does not name the author"
    assert_grep "MIT" "$file" "$(basename "$file") does not name the licence"
  done
  # The two files that get copied out of this repository must also carry the
  # route back to the notice; the provenance page is that notice.
  for file in "$SKILL" "$TO_BACKLOG"; do
    assert_grep "docs/to-backlog-provenance.md" "$file" \
      "$(basename "$file") does not point at the provenance page carrying the notice"
  done
  pass "the skill, the script, and the provenance page each carry the attribution"
}

test_provenance_carries_the_notice_and_the_comparison() {
  assert_grep "Copyright (c) 2026 Matt Pocock" "$PROVENANCE" \
    "the provenance page does not carry the copyright notice"
  assert_grep "Permission is hereby granted, free of charge" "$PROVENANCE" \
    "the provenance page does not carry the permission notice"
  assert_grep "The above copyright notice and this permission notice shall be included" "$PROVENANCE" \
    "the provenance page does not carry the notice-retention condition"
  # The comparison is only repeatable against a named commit; without one, a
  # later reader cannot tell what changed upstream since.
  assert_grep "2ab9580" "$PROVENANCE" \
    "the provenance page does not record the upstream commit it was compared against"
  assert_grep "git clone --depth 1 https://github.com/mattpocock/skills.git" "$PROVENANCE" \
    "the provenance page does not record how to repeat the comparison"
  pass "the provenance page carries the notice and a repeatable comparison"
}

test_provenance_states_what_was_dropped_and_what_it_costs() {
  local dropped
  # The captain's condition on this adoption was: whole, or write down which
  # half is left out AND why. A "What we dropped" heading with no cost attached
  # to each entry is the half-adoption this repository already paid for once.
  dropped=$(awk '/^## What we dropped$/{f=1;next} f && /^## /{exit} f' "$PROVENANCE")
  [ -n "$dropped" ] || fail "the provenance page has no 'What we dropped' section"
  local count
  count=$(printf '%s\n' "$dropped" | grep -c '^[0-9]\+\. ')
  [ "$count" -ge 5 ] || fail "the dropped section lists only $count items; the comparison found more"
  count=$(printf '%s\n' "$dropped" | grep -c 'Cost:')
  [ "$count" -ge 5 ] || fail "only $count dropped items state their cost"
  pass "every dropped capability is named with its cost"
}

test_readme_and_script_index_disclose_the_adoption() {
  assert_grep "/to-backlog" "$README" "README does not list the skill"
  assert_grep "docs/to-backlog-provenance.md" "$README" \
    "README does not point at the to-backlog provenance page"
  assert_grep "fm-to-backlog.sh" "$SCRIPTS_DOC" "docs/scripts.md does not list the script"
  assert_grep "to-backlog" "$AGENTS" "AGENTS.md declares no load trigger for the skill"
  pass "the public surfaces disclose the adoption"
}

# --- behavior ---------------------------------------------------------------

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

fm_test_tmproot TMP_ROOT fm-to-backlog

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  (cd "$home" && tasks-axi add demo-origin "Demo undertaking" --kind scout --queue >/dev/null)
  printf '%s\n' "$home"
}

run_to_backlog() {  # <home> <mode> <file>
  local home=$1 mode=$2 file=$3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$TO_BACKLOG" "$mode" "$file" 2>&1
}

write_breakdown() {  # <path> <json>
  printf '%s\n' "$2" > "$1"
}

THREE_UNITS='{
  "origin": "demo-origin",
  "repo": "demo",
  "units": [
    {"slug": "route", "title": "Serve the new route", "delivers": "A caller gets an answer end to end.",
     "acceptance": ["the route answers"], "blocked_by": ["expand"]},
    {"slug": "expand", "title": "Add the new column beside the old", "delivers": "Both columns exist and nothing reads the new one.",
     "acceptance": ["migration applies", "checks stay green"]},
    {"slug": "contract", "title": "Delete the old column", "delivers": "Only the new column remains.",
     "acceptance": ["no caller references the old column"], "blocked_by": ["route"]}
  ]
}'

test_check_orders_by_dependency_and_writes_nothing() {
  local home out before after
  home=$(make_home check-only)
  write_breakdown "$home/b.json" "$THREE_UNITS"
  before=$(cat "$home/data/backlog.md")
  out=$(run_to_backlog "$home" check "$home/b.json") || fail "check refused a sound breakdown: $out"
  after=$(cat "$home/data/backlog.md")

  [ "$before" = "$after" ] || fail "check wrote to the backlog"
  assert_contains "$out" "demo-origin - Demo undertaking" "check did not name the origin"
  assert_contains "$out" "ok: breakdown is fileable" "check did not report the breakdown as fileable"
  # The author wrote route before expand; the plan must lead with expand.
  local order
  order=$(printf '%s\n' "$out" | sed -n 's/^  \(demo-origin-[a-z-]*\) .*/\1/p' | tr '\n' ' ')
  [ "$order" = "demo-origin-expand demo-origin-route demo-origin-contract " ] \
    || fail "check did not order the units blockers-first, got: $order"
  pass "check orders blockers first and leaves the backlog untouched"
}

test_file_records_real_edges_and_a_correct_frontier() {
  local home out ready
  home=$(make_home file-edges)
  write_breakdown "$home/b.json" "$THREE_UNITS"
  out=$(run_to_backlog "$home" file "$home/b.json") || fail "file refused a sound breakdown: $out"
  assert_contains "$out" "ok: 3 filed, 0 already present" "file did not report three new units"

  # The edge must be a real backlog edge, not prose in the body: the frontier is
  # computed from it, and the sea chart reads it.
  local shown
  shown=$(cd "$home" && tasks-axi show demo-origin-contract)
  assert_contains "$shown" "blocked_by" "the filed unit carries no dependency edge"
  assert_contains "$shown" "demo-origin-route" "the filed unit's edge does not name its blocker"

  ready=$(cd "$home" && tasks-axi ready)
  assert_contains "$ready" "demo-origin-expand" "the unblocked unit is not on the frontier"
  assert_not_contains "$ready" "demo-origin-route" "a blocked unit reached the frontier"
  assert_not_contains "$ready" "demo-origin-contract" "a blocked unit reached the frontier"

  # The body carries the origin and the acceptance criteria, not a duplicate of
  # the structured edge.
  assert_grep "Origin: demo-origin" "$home/data/backlog.md" "the filed body does not name its origin"
  assert_grep "- [ ] migration applies" "$home/data/backlog.md" "the filed body dropped an acceptance criterion"
  pass "file records real edges and the frontier reflects them"
}

test_refiling_is_idempotent_and_never_clobbers_an_edited_unit() {
  local home out
  home=$(make_home idempotent)
  write_breakdown "$home/b.json" "$THREE_UNITS"
  run_to_backlog "$home" file "$home/b.json" >/dev/null || fail "the first filing failed"
  (cd "$home" && tasks-axi update demo-origin-expand --title "Hand-edited title" >/dev/null) \
    || fail "could not edit a filed unit"

  out=$(run_to_backlog "$home" file "$home/b.json") || fail "the second filing failed: $out"
  assert_contains "$out" "ok: 0 filed, 3 already present" "a repeated filing was not idempotent"
  assert_contains "$out" "exists: demo-origin-expand left untouched" "a repeated filing did not report the existing unit"
  assert_grep "Hand-edited title" "$home/data/backlog.md" "a repeated filing clobbered a hand-edited unit"
  pass "a repeated filing converges and never rewrites an existing unit"
}

# refuse <home> <json> <expected fragment> <label>: `check` must refuse, and
# `file` must leave the backlog byte-identical.
refuse() {
  local home=$1 json=$2 want=$3 label=$4 out before after rc=0
  write_breakdown "$home/bad.json" "$json"
  before=$(cat "$home/data/backlog.md")
  out=$(run_to_backlog "$home" check "$home/bad.json") || rc=$?
  expect_code 1 "$rc" "$label was not refused by check"
  assert_contains "$out" "$want" "$label was refused for the wrong reason"
  rc=0
  out=$(run_to_backlog "$home" file "$home/bad.json") || rc=$?
  expect_code 1 "$rc" "$label was not refused by file"
  after=$(cat "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "$label was refused but the backlog still changed"
}

test_unfileable_breakdowns_are_refused_before_anything_is_written() {
  local home kind
  home=$(make_home refusals)

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["x"],"blocked_by":["b"]},
    {"slug":"b","title":"B","delivers":"b","acceptance":["x"],"blocked_by":["a"]}]}' \
    "contain a cycle" "a cycle"

  refuse "$home" '{"origin":"no-such-undertaking","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["x"]}]}' \
    "is not in the backlog" "an origin that does not exist"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["x"],"blocked_by":["ghost-task"]}]}' \
    "which is not in the backlog" "a blocker that does not exist"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":[]}]}' \
    "at least one criterion" "a unit with no acceptance criterion"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"   ","acceptance":["x"]}]}' \
    "must say what it delivers" "a unit that says nothing about what it delivers"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["one\ntwo"]}]}' \
    "must each be one line" "an acceptance criterion that would spill past its checkbox"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A (repo: elsewhere)","delivers":"a","acceptance":["x"]}]}' \
    "must not contain parentheses" "a title that would be parsed as a backlog field"

  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["x"],"kind":"captain"}]}' \
    "may not be filed as kind captain" "a unit filed as a captain decision"

  # bin/fm-sea-chart.sh finds `-decision-` positionally, so this id would be read
  # as a captain decision no matter that its kind is the ordinary ship.
  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"decision-log-view","title":"A","delivers":"a","acceptance":["x"]}]}' \
    "reserved -decision- marker" "a slug that composes a captain decision id"

  # The skill may never close the originating undertaking, so this edge could
  # never clear and the unit would never reach the frontier.
  refuse "$home" '{"origin":"demo-origin","units":[
    {"slug":"a","title":"A","delivers":"a","acceptance":["x"],"blocked_by":["demo-origin"]}]}' \
    "blocked by its own origin" "a unit blocked by the undertaking it is a slice of"

  # Read the chart kinds from their owner, so renaming one there cannot quietly
  # reopen the hole this refusal exists to close.
  # shellcheck source=bin/fm-chart-kinds-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-chart-kinds-lib.sh"
  for kind in $FM_CHART_KINDS; do
    refuse "$home" "{\"origin\":\"demo-origin\",\"units\":[
      {\"slug\":\"a\",\"title\":\"A\",\"delivers\":\"a\",\"acceptance\":[\"x\"],\"kind\":\"$kind\"}]}" \
      "may not be filed as kind $kind" "a unit filed as the chart kind $kind"
  done

  pass "every unfileable breakdown is refused with the backlog untouched"
}

test_manual_backend_refuses_to_file_but_still_plans() {
  local home out rc=0
  home=$(make_home manual-backend)
  printf 'manual\n' > "$home/config/backlog-backend"
  write_breakdown "$home/b.json" "$THREE_UNITS"

  out=$(run_to_backlog "$home" check "$home/b.json") || fail "check refused under the manual backend: $out"
  assert_contains "$out" "ok: breakdown is fileable" "check did not validate under the manual backend"

  rc=0
  out=$(run_to_backlog "$home" file "$home/b.json") || rc=$?
  expect_code 1 "$rc" "file did not refuse under the manual backend"
  assert_contains "$out" "files by hand" "the manual-backend refusal does not say what to do instead"
  # The plan is still printed, so the refusal hands over usable work.
  assert_contains "$out" "demo-origin-expand" "the manual-backend refusal dropped the ordered plan"
  assert_no_grep "demo-origin-expand" "$home/data/backlog.md" "the manual backend still wrote to the backlog"
  pass "the manual backend refuses to file and hands over the ordered plan"
}

test_attribution_travels_with_the_work
test_provenance_carries_the_notice_and_the_comparison
test_provenance_states_what_was_dropped_and_what_it_costs
test_readme_and_script_index_disclose_the_adoption
test_check_orders_by_dependency_and_writes_nothing
test_file_records_real_edges_and_a_correct_frontier
test_refiling_is_idempotent_and_never_clobbers_an_edited_unit
test_unfileable_breakdowns_are_refused_before_anything_is_written
test_manual_backend_refuses_to_file_but_still_plans
