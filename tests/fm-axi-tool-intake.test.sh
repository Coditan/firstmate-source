#!/usr/bin/env bash
# Contract tests for the installed `axi` skill, its provenance record, and the
# `axi-tool-intake` overlay that carries this fleet's own additions.
#
# These assert on prose and on a hash, on purpose. Neither skill ships a script:
# what they carry is a boundary between someone else's words and ours, an
# attribution, and four rules whose entire value is that they are recorded. Every
# failure mode here is invisible when it happens - an upstream file quietly
# edited to satisfy a local convention, a design principle quietly re-explained
# in our half so the two copies drift, a fleet-local rule quietly presented as
# the specification's, an open ownership question quietly answered by whoever
# edited last. None of them would fail any behavioral test, because there is no
# behavior to fail.
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
  assert_present "$AXI" "the official axi skill is not installed"
  assert_present "$LOCK" "skills-lock.json is missing; the install is unrecorded"
  assert_grep '"source": "kunchenguid/axi"' "$LOCK" \
    "the manifest must record the axi skill's upstream source"
  assert_grep '".agents/skills/axi/SKILL.md"' "$LOCK" \
    "the manifest must record where the axi skill was installed"
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
  assert_grep "Both are correct and neither is to be fixed" "$PROV" \
    "the provenance record must forbid tidying the installed file"
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

# A provenance record that cannot say WHICH version is installed cannot tell
# anyone whether an upstream fix has arrived. The installer records a source and
# a hash but no commit, so the commit has to be established and written down.
test_provenance_names_the_upstream_version_and_update_route() {
  assert_grep "408a653" "$PROV" "the provenance record must name the upstream commit read"
  assert_grep "2026-08-19" "$PROV" "the provenance record must date the install"
  assert_grep "npx skills add kunchenguid/axi" "$PROV" \
    "the provenance record must name the install and update command"
  assert_grep "re-record the commit, the hash, and the date" "$PROV" \
    "the provenance record must require itself to be re-taken on update"
  pass "provenance names the upstream version and the update route"
}

# --- the separation ---------------------------------------------------------

# The overlay's entire justification is that it does not compete. The moment it
# starts explaining a principle, there are two owners for one contract and the
# fleet is back where it started, with the added cost of a file that looks
# authoritative.
test_the_overlay_carries_no_design_guidance() {
  assert_present "$INTAKE" "the axi-tool-intake skill is missing"
  assert_grep "contains no design guidance and never will" "$INTAKE" \
    "the overlay must declare that it carries no design guidance"
  assert_grep "owns the AXI contract in full" "$INTAKE" \
    "the overlay must name the axi skill as the contract's sole owner"
  # The principles' own names are the shape a restatement arrives in.
  local term
  for term in "TOON" "exit code" "stdout" "truncat" "empty state" "aggregate"; do
    assert_no_grep "$term" "$INTAKE" \
      "the overlay restates '$term', which belongs to the installed axi skill alone"
  done
  pass "the overlay carries no design guidance"
}

# The description is the only surface a harness skill listing shows, and the two
# skills sit next to each other in it. A reader who never opens either file must
# still be able to tell which one owns the contract.
test_the_overlay_description_defers_to_the_installed_skill() {
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/axi-tool-intake")
  assert_contains "$desc" "owns the design contract in full" \
    "the overlay description must defer to the axi skill"
  assert_contains "$desc" "carrying no design guidance of its own" \
    "the overlay description must disclaim design guidance"
  pass "the overlay description defers to the installed skill"
}

# --- the four fleet additions -----------------------------------------------

# The whole reason this work was ordered: twice in one day this fleet decided to
# build without looking. A check that reads as an appendix is the same failure
# with better documentation, so its position is part of the contract.
test_the_index_check_precedes_every_other_section() {
  local check credentials derive route
  check=$(grep -n '^## 1\. Check both indexes' "$INTAKE" | cut -d: -f1)
  credentials=$(grep -n '^## 2\. Credentials' "$INTAKE" | cut -d: -f1)
  derive=$(grep -n '^## 3\. Deriving' "$INTAKE" | cut -d: -f1)
  route=$(grep -n '^## 4\. How a finished tool' "$INTAKE" | cut -d: -f1)
  [ -n "$check" ] || fail "the overlay lost its numbered index-check section"
  local later
  for later in "$credentials" "$derive" "$route"; do
    [ -n "$later" ] || fail "the overlay lost one of its four numbered sections"
    [ "$check" -lt "$later" ] \
      || fail "the index check must come before every other section, found it at line $check"
  done
  assert_grep "This is the first step" "$INTAKE" \
    "the index check must declare itself the first step"
  pass "the index check is first, not an appendix"
}

# Both indexes are mandatory because they were measured disagreeing in both
# directions on the same day. An edit that drops either one, or that presents a
# single clean lookup as sufficient, restores the exact blind spot that caused
# the miss.
test_both_indexes_are_required_because_they_disagree() {
  assert_grep "neither is a superset of the other" "$INTAKE" \
    "the overlay must state that neither index contains the other"
  assert_grep "npm view <domain>-axi" "$INTAKE" \
    "the overlay must require the package registry to be checked by exact name"
  assert_grep "catalog.yaml" "$INTAKE" \
    "the overlay must require the axi.md catalogue to be checked"
  assert_grep "is on npm at 1.2.0 and is **not** in the axi.md catalogue" "$INTAKE" \
    "the overlay must carry the measured registry-only case"
  assert_grep "return a flat 404 on npm under those names" "$INTAKE" \
    "the overlay must carry the measured catalogue-only case, or the rule reads as one-directional"
  assert_grep "checking one index and finding nothing proves nothing at all" "$INTAKE" \
    "the overlay must state the conclusion the two directions force"
  pass "both indexes are required, and the measurement that forces it is recorded"
}

# Recording the search is the half that was actually missing. Nobody had to be
# told to search; what nobody did was write down that they had, which is why an
# unrecorded search and no search were indistinguishable after the fact.
test_the_result_names_which_indexes_were_checked() {
  assert_grep "state the result and name which indexes you checked" "$INTAKE" \
    "the overlay must require the result to name which indexes were checked"
  assert_grep "is a finding" "$INTAKE" \
    "the overlay must state that finding nothing is itself a finding"
  assert_grep "An unrecorded search is indistinguishable from no search" "$INTAKE" \
    "the overlay must state why an unrecorded search does not count"
  pass "the recorded result names which indexes were checked"
}

# An absent catalogue entry is a fact about who filed a pull request, nothing
# more. Reading it as a quality signal is how a perfectly good tool gets
# rebuilt from scratch with a straight face.
test_a_catalogue_absence_is_not_read_as_a_verdict() {
  assert_grep "means only that nobody added an entry" "$INTAKE" \
    "the overlay must say what a catalogue absence actually means"
  assert_grep "not evidence that a tool is unofficial, unmaintained, or unsuitable" "$INTAKE" \
    "the overlay must deny the readings a catalogue absence invites"
  pass "a catalogue absence is not read as a verdict on the tool"
}

# Both directions belong here. Filing a build for a tool that exists and
# adopting a tool that never existed are the same missing habit, and recording
# only the first teaches half the lesson.
test_both_directions_of_the_failure_are_recorded_with_dates() {
  assert_grep "2026-08-17" "$INTAKE" "the overlay must date the too-late build task"
  assert_grep "2026-08-03" "$INTAKE" \
    "the overlay must carry the registry's own first-publish date, not the fleet's recollection of it"
  assert_grep "had never been persisted at all" "$INTAKE" \
    "the overlay must record the opposite failure - adopting a tool that never existed"
  assert_grep "the registry is the authority" "$INTAKE" \
    "the overlay must resolve the fleet's own note against the registry, and say so"
  pass "both directions of the failure are recorded with their dates"
}

# A one-sentence description is what both of this fleet's candidate assessments
# leaned on. The delta has to be a number, because a prose comparison always
# concludes that the fit is roughly fine.
test_coverage_is_enumerated_and_reported_as_a_number() {
  assert_grep "is not its coverage" "$INTAKE" \
    "the overlay must state that a description is not coverage"
  assert_grep "report the delta as a number" "$INTAKE" \
    "the overlay must require the coverage delta as a number"
  assert_grep "grep the real call sites, do not recall them" "$INTAKE" \
    "the overlay must require the fleet's own verbs to be enumerated from the code"
  pass "coverage is enumerated from the call sites and reported as a number"
}

# The credential rule is this fleet's addition. Presenting it as AXI's makes it
# unenforceable the moment someone checks the specification and finds it absent.
test_the_credential_rule_is_labelled_as_this_fleets_own() {
  assert_grep "The AXI specification is silent on secret handling" "$INTAKE" \
    "the overlay must state that the specification does not cover secrets"
  assert_grep "This fleet is not" "$INTAKE" \
    "the overlay must claim the credential rule as this fleet's own"
  assert_grep "never accepted as a value on the command line and never emitted" "$INTAKE" \
    "the overlay must carry the credential rule itself"
  assert_grep "verified by its effect" "$INTAKE" \
    "the overlay must require credentials to be verified by effect"
  assert_grep "secrets-handling" "$INTAKE" \
    "the overlay must cross-reference the secrets-handling owner"
  assert_no_grep "Authorization: Bearer" "$INTAKE" \
    "the overlay must not copy secrets-handling's worked command mechanics"
  pass "the credential rule is carried, labelled as ours, and its mechanics left with their owner"
}

# This fleet shipped a fix for asserting licensing beyond what was evidenced.
# Inferring a licence from the ecosystem is the same defect in a different hat,
# and a dropped copyright notice never fails anything at runtime.
test_derivation_requires_evidenced_licence_and_named_provenance() {
  assert_grep "Read the actual licence file of that specific upstream" "$INTAKE" \
    "the overlay must require the upstream's own licence file to be read"
  assert_grep "Do not infer it from the ecosystem" "$INTAKE" \
    "the overlay must forbid inferring a licence from the surrounding ecosystem"
  assert_grep "copyright notice travels with the derived work" "$INTAKE" \
    "the overlay must state that the copyright notice travels"
  assert_grep "its version, its commit, and what changed" "$INTAKE" \
    "the provenance rule must name upstream, version, commit, and the change"
  assert_grep "axi-sdk-js" "$INTAKE" \
    "the overlay must point at the maintained SDK rather than leaving the primitives hand-rolled"
  pass "derivation requires an evidenced licence, a named provenance record, and the SDK"
}

# The one thing the overlay must never do is answer this. Publication to the
# public catalogue IS solved, and letting that answer stand in for this one is
# the specific confusion worth guarding: they are different questions.
test_the_fleet_delivery_route_is_stated_as_open() {
  assert_grep "has no settled answer, and inventing one is worse than naming the gap" "$INTAKE" \
    "the overlay must mark the fleet-delivery route as open and forbid inventing an answer"
  assert_grep "not this one" "$INTAKE" \
    "the overlay must separate catalogue publication from reaching this fleet's seats"
  assert_grep "CONTRIBUTING.md" "$INTAKE" \
    "the overlay must point at the upstream procedure for the half that IS answered"
  assert_grep "fleet-forgejo-axi" "$INTAKE" \
    "the overlay must name the record tracking the ownership question"
  assert_grep "fm-axi-nomistakes-guidance-off-argv" "$INTAKE" \
    "the overlay must name the second record asking the same ownership question"
  assert_grep "is a captain decision" "$INTAKE" \
    "the overlay must route the delivery decision to the captain"
  pass "the fleet-delivery route is stated as open, not answered"
}

# --- reachability -----------------------------------------------------------

test_both_skills_are_reachable_from_the_instruction_surface() {
  local name count
  for name in axi axi-tool-intake; do
    count=$(grep -Fc -- "- \`$name\` - " "$AGENTS")
    [ "$count" -eq 1 ] \
      || fail "$name must have exactly one AGENTS.md section 13 trigger, found $count"
  done
  assert_grep "installed verbatim from upstream and never edited here" "$AGENTS" \
    "the axi trigger must say the installed skill is not edited here"
  assert_grep "docs/axi-skill-provenance.md" "$AGENTS" \
    "the axi trigger must point at the provenance record that carries the licence notice"
  assert_grep "before telling the captain that none exists for a domain" "$AGENTS" \
    "the intake trigger must cover the moment a nothing-exists claim is about to be made"
  pass "both skills are reachable from the instruction surface"
}

test_the_contract_is_installed_rather_than_restated
test_the_installed_file_is_unmodified
test_the_licence_notice_travels_with_the_copy
test_provenance_names_the_upstream_version_and_update_route
test_the_overlay_carries_no_design_guidance
test_the_overlay_description_defers_to_the_installed_skill
test_the_index_check_precedes_every_other_section
test_both_indexes_are_required_because_they_disagree
test_the_result_names_which_indexes_were_checked
test_a_catalogue_absence_is_not_read_as_a_verdict
test_both_directions_of_the_failure_are_recorded_with_dates
test_coverage_is_enumerated_and_reported_as_a_number
test_the_credential_rule_is_labelled_as_this_fleets_own
test_derivation_requires_evidenced_licence_and_named_provenance
test_the_fleet_delivery_route_is_stated_as_open
test_both_skills_are_reachable_from_the_instruction_surface
