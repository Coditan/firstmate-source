#!/usr/bin/env bash
# Contract tests for the installed `axi` skill, its provenance record, and the
# `axi-tool-intake` overlay that carries this fleet's own additions.
#
# The installed file hash and MIT notices are owned byte contracts.
# The overlay's forbidden design terms are its non-competition contract.
# Its four numbered headings and external identifiers are its structural and
# actionable-reference contracts, and the section 13 entries are the delivered
# instruction surface's reachability contract.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AXI="$ROOT/.agents/skills/axi/SKILL.md"
AXI_LICENSE="$ROOT/.agents/skills/axi/LICENSE"
INTAKE="$ROOT/.agents/skills/axi-tool-intake/SKILL.md"
PROV="$ROOT/docs/axi-skill-provenance.md"
LOCK="$ROOT/skills-lock.json"
AGENTS="$ROOT/AGENTS.md"

# --- the installed skill ----------------------------------------------------

# The remedy first proposed for this whole problem was a fleet-written skill
# describing the AXI contract. An official one already existed. If a later edit
# reintroduces a second description, the copy drifts the first time upstream
# moves, which is the defect the installation exists to avoid.
test_the_contract_is_installed_rather_than_restated() {
  local source skill_path
  assert_present "$AXI" "the official axi skill is not installed"
  assert_present "$LOCK" "skills-lock.json is missing; the install is unrecorded"
  if command -v jq >/dev/null 2>&1; then
    source=$(jq -er '.skills.axi.source | strings' "$LOCK") \
      || fail "the manifest must decode the axi skill's upstream source"
    skill_path=$(jq -er '.skills.axi.skillPath | strings' "$LOCK") \
      || fail "the manifest must decode where the axi skill was installed"
  elif command -v python3 >/dev/null 2>&1; then
    source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["skills"]["axi"]["source"])' "$LOCK") \
      || fail "the manifest must decode the axi skill's upstream source"
    skill_path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["skills"]["axi"]["skillPath"])' "$LOCK") \
      || fail "the manifest must decode where the axi skill was installed"
  else
    fail "this contract test requires jq or python3 to decode $LOCK"
  fi
  [ "$source" = "kunchenguid/axi" ] \
    || fail "the decoded axi source must be kunchenguid/axi, found $source"
  [ "$skill_path" = ".agents/skills/axi/SKILL.md" ] \
    || fail "the decoded axi skillPath is wrong: $skill_path"
  fm_installed_skill_dirs | grep -qx axi \
    || fail "axi must be resolvable as an installed skill from skills-lock.json"
  pass "the AXI contract is installed from upstream, not restated here"
}

# The installed file is upstream's. It carries em dashes this repository forbids
# and frontmatter fields it does not declare, and both are correct. An edit that
# tidies either one diverges the file from the hash the installer recorded and
# turns the next update into a conflict - and nothing at load time would ever
# reveal it, because the skill still loads and still works.
test_the_installed_file_is_unmodified() {
  local recorded actual
  recorded=$(grep -o '`sha256` `[0-9a-f]\{64\}`' "$PROV" | grep -o '[0-9a-f]\{64\}')
  [ -n "$recorded" ] || fail "the provenance record must carry the installed file's sha256"
  actual=$(sha256sum "$AXI" | awk '{print $1}')
  [ "$recorded" = "$actual" ] \
    || fail "the installed axi skill has been edited locally: recorded $recorded, on disk $actual"
  pass "the installed axi skill is byte-for-byte what was installed"
}

# MIT asks one thing in return, and a dropped notice is the one licence defect
# that never surfaces at runtime. This fleet has already had to correct it once
# after the fact, which is why the notice is asserted rather than trusted.
test_the_licence_notice_travels_with_the_copy() {
  assert_present "$AXI_LICENSE" "the MIT licence must sit beside the installed copy"
  assert_grep "Copyright (c) 2026 Kun Chen" "$AXI_LICENSE" \
    "the licence beside the copy must carry the upstream copyright line"
  assert_grep "Copyright (c) 2026 Kun Chen" "$PROV" \
    "the provenance record must carry the upstream copyright line"
  assert_grep "shall be included in all" "$PROV" \
    "the provenance record must carry the MIT permission notice, not just the copyright line"
  assert_grep "MIT" "$PROV" "the provenance record must name the licence"
  pass "the MIT notice travels with the installed copy"
}

# --- the separation ---------------------------------------------------------

# The overlay's entire justification is that it does not compete. The moment it
# starts explaining a principle, there are two owners for one contract and the
# fleet is back where it started, with the added cost of a file that looks
# authoritative.
test_the_overlay_carries_no_design_guidance() {
  assert_present "$INTAKE" "the axi-tool-intake skill is missing"
  # The principles' own names are the shape a restatement arrives in.
  local term
  for term in "TOON" "exit code" "stdout" "truncat" "empty state" "aggregate"; do
    assert_no_grep "$term" "$INTAKE" \
      "the overlay restates '$term', which belongs to the installed axi skill alone"
  done
  pass "the overlay carries no design guidance"
}

# --- the four fleet additions -----------------------------------------------

# The whole reason this work was ordered: twice in one day this fleet decided to
# build without looking. A check that reads as an appendix is the same failure
# with better documentation, so its position is part of the contract.
test_the_overlay_has_four_ordered_fleet_contract_sections() {
  local -a headings expected
  mapfile -t headings < <(grep '^## [0-9]\+\.' "$INTAKE")
  expected=(
    "## 1. Check both indexes before building, and state which you checked"
    "## 2. Credentials: this fleet's rule, not the specification's"
    "## 3. Deriving from an existing tool"
    "## 4. How a finished tool reaches every seat - OPEN"
  )
  [ "${#headings[@]}" -eq 4 ] \
    || fail "the overlay must have exactly four top-level numbered sections"
  [ "$(printf '%s\n' "${headings[@]}")" = "$(printf '%s\n' "${expected[@]}")" ] \
    || fail "the overlay's four numbered sections are missing or out of order"
  pass "the overlay has exactly four ordered fleet contract sections"
}

test_the_overlay_retains_actionable_external_identifiers() {
  assert_grep "catalog.yaml" "$INTAKE" \
    "the overlay must identify the AXI catalogue source"
  assert_grep "npm" "$INTAKE" \
    "the overlay must identify the package registry source"
  assert_grep "fleet-forgejo-axi" "$INTAKE" \
    "the overlay must name the record tracking the ownership question"
  assert_grep "fm-axi-nomistakes-guidance-off-argv" "$INTAKE" \
    "the overlay must name the second record asking the same ownership question"
  pass "the overlay retains its actionable external identifiers"
}

# --- reachability -----------------------------------------------------------

test_both_skills_are_reachable_from_the_instruction_surface() {
  local name count
  for name in axi axi-tool-intake; do
    count=$(grep -Fc -- "- \`$name\` - " "$AGENTS")
    [ "$count" -eq 1 ] \
      || fail "$name must have exactly one AGENTS.md section 13 trigger, found $count"
  done
  pass "both skills are reachable from the instruction surface"
}

test_the_contract_is_installed_rather_than_restated
test_the_installed_file_is_unmodified
test_the_licence_notice_travels_with_the_copy
test_the_overlay_carries_no_design_guidance
test_the_overlay_has_four_ordered_fleet_contract_sections
test_the_overlay_retains_actionable_external_identifiers
test_both_skills_are_reachable_from_the_instruction_surface
