#!/usr/bin/env bash
# Contract tests for the codebase-sweep skill, its provenance record, its
# drafted adoption notice, and its instruction-surface trigger.
#
# These assert on prose on purpose. The skill ships no script: what it carries
# is an attribution, a boundary someone else's words own, and an autonomy grant
# with named limits. Each of those degrades silently under a well-meaning edit -
# a tier quietly re-narrowed, a scale quietly credited to a source, a posture
# quietly hardcoded - and none of them would fail any behavioral test, because
# there is no behavior to fail. So the checks live here.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/codebase-sweep/SKILL.md"
PROV="$ROOT/docs/codebase-sweep-provenance.md"
NOTICE="$ROOT/docs/codebase-sweep-adoption-broadcast.md"
AGENTS="$ROOT/AGENTS.md"

# --- attribution ------------------------------------------------------------

# The one constraint the originating order named as non-negotiable: the tiers
# are the captain's framing, and crediting them to the talk is the same defect
# class this fleet catalogued on 2026-08-16 - an explanation that fits, put
# where an observation belongs.
test_tiers_are_attributed_to_the_captain_and_never_to_the_talk() {
  assert_grep "the captain's own framing" "$SKILL" \
    "the skill must attribute the three tiers to the captain"
  assert_grep 'The talk defines no risk scale' "$SKILL" \
    "the skill must state that the talk defines no risk scale"
  assert_grep 'Never write, and never let a report imply, that the talk ranks findings' "$SKILL" \
    "the skill must forbid implying the talk ranks findings"
  # The measured negative belongs in the description too: that is the only
  # trigger surface a harness skill listing shows, and a reader who never opens
  # the file must still not walk away believing the scale is sourced.
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/codebase-sweep")
  printf '%s' "$desc" | grep -q "never the talk's" \
    || fail "the skill description must deny the talk as the tiers' source"
  pass "the three tiers are attributed to the captain and denied to the talk"
}

test_the_only_ordering_the_talk_gives_is_kept_as_a_target() {
  assert_grep 'a web of shallow modules is the thing to restructure' "$SKILL" \
    "the skill must carry the one ordering the talk does give"
  assert_grep 'That is a target, not a scale' "$SKILL" \
    "the talk's ordering must be marked a target rather than a scale"
  pass "the talk's own ordering is cited as a target and not as a scale"
}

# --- the boundary, which is his and not ours --------------------------------

# His criterion combines reversibility with his separate containment
# clarification. An earlier draft on this seat also
# required a nameable check, which is stricter than what he asked for; this test
# exists because re-narrowing it back would look like caution rather than like
# the override it is.
test_low_is_his_reversibility_boundary_and_is_not_re_narrowed() {
  assert_grep 'low is everything reversible without me' "$SKILL" \
    "the skill must carry his verbatim definition of the low tier"
  assert_grep 'this skill narrows neither' "$SKILL" \
    "the skill must state that it does not narrow his definition"
  assert_grep 'containment is the missing half' "$SKILL" \
    "the skill must carry his separate containment clarification"
  assert_grep 'Do not quietly re-narrow the tier' "$SKILL" \
    "the skill must forbid re-narrowing the tier to the stricter test"
  pass "the low tier keeps his reversibility boundary unnarrowed"
}

# Both halves of the boundary are his; only the detectability aid is ours. The
# skill said for one revision that the earlier draft containing containment "was
# this seat's invention", which reads as though containment could be dropped as
# ours. This pins the split so the next reader cannot make that trade.
test_both_halves_of_the_boundary_are_attributed_to_him() {
  assert_grep '**Both halves of the boundary are his, and this skill narrows neither.**' "$SKILL" \
    "the skill must attribute reversibility and containment alike to him"
  assert_grep "what was this seat's invention is the detectability requirement alone" "$SKILL" \
    "the skill must confine this seat's invention to the detectability requirement"
  assert_grep 'do not drop containment in the belief that it is ours' "$SKILL" \
    "the skill must bar dropping containment as though it were ours"
  pass "both halves of the boundary are attributed to him, only detectability to us"
}

# The loaded summaries are what an agent classifies from, so a summary still
# carrying the pre-clarification boundary would have agents sorting by the
# superseded rule however correct the body is. Both surfaces are checked.
test_every_loaded_summary_carries_containment() {
  assert_grep 'both reversible without him and contained inside one module' "$AGENTS" \
    "the AGENTS.md trigger must state containment alongside reversibility"
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/codebase-sweep")
  printf '%s' "$desc" | grep -q 'contained inside one module' \
    || fail "the skill description must state containment alongside reversibility"
  pass "every loaded summary carries containment, not just the body"
}

test_detectability_is_a_flag_of_ours_and_never_a_demotion() {
  assert_grep 'which is ours and is not a demotion' "$SKILL" \
    "the detectability aid must be labelled ours and non-demoting"
  assert_grep 'a change nobody can tell went wrong is one nobody will know to reverse' "$SKILL" \
    "the skill must state why detectability is still worth recording"
  assert_grep 'do the work anyway' "$SKILL" \
    "an unnameable check must flag the finding, not stop the work"
  assert_grep 'never a demotion to middle' "$SKILL" \
    "the skill must forbid demoting a low finding on our own test"
  pass "detectability is a labelled flag of ours and never a demotion"
}

test_each_tier_carries_a_falsifiable_entry_test() {
  local phrase
  for phrase in \
    '**Entry test: can this change be undone without him, and is it contained inside one module?**' \
    '**Entry test: would a caller outside this module change, or would a person have a view on the shape?**' \
    '**Entry test: can you state the observation that would prove this change wrong?**'; do
    assert_grep "$phrase" "$SKILL" "the skill lost an entry test: $phrase"
  done
  assert_grep 'The inability to name a disproof is the classification' "$SKILL" \
    "the high tier must classify on the absence of a disproof"
  pass "each tier carries its falsifiable entry test"
}

test_a_fix_that_outgrows_its_tier_stops_and_reclassifies() {
  assert_grep 'A finding whose fix grows past what its tier assumed stops and re-classifies' "$SKILL" \
    "the skill must stop and re-classify a fix that outgrows its tier"
  assert_grep 'a tier that only ever gets easier is a tier nobody is enforcing' "$SKILL" \
    "the skill must say why the original classification is carried into the report"
  assert_grep 'ask-user-authority' "$SKILL" \
    "the re-classification rule must point at the ask-user owner"
  pass "a fix that outgrows its tier stops and re-classifies"
}

# --- the autonomy grant, and its limits -------------------------------------

test_the_low_tier_grant_names_what_it_does_not_cover() {
  local phrase
  for phrase in \
    'not authority to skip the delivery path' \
    'not authority for anything destructive or irreversible' \
    'not authority over a finding that turns out to be mis-classified' \
    'not authority to merge'; do
    assert_grep "$phrase" "$SKILL" "the standing authority lost a limit: $phrase"
  done
  pass "the low-tier grant names every limit it does not cover"
}

# A posture baked into this file would be wrong the moment he changes the
# standing merge order, and wrong silently - which is the failure this test is
# guarding, not the wording.
test_merge_authority_is_read_at_the_time_and_never_hardcoded() {
  assert_grep "Read the project's posture at the time and never carry one in your head" "$SKILL" \
    "the skill must require reading the posture at the time"
  assert_grep 'bin/fm-project-mode.sh' "$SKILL" \
    "the skill must name the registry reading it depends on"
  assert_grep "Never hardcode today's merge authority" "$SKILL" \
    "the skill must forbid hardcoding merge authority"
  assert_no_grep 'yolo is on for' "$SKILL" \
    "the skill must not record any project's current yolo posture"
  pass "merge authority is read at the time and never hardcoded"
}

# --- scope ------------------------------------------------------------------

test_the_sweep_is_per_repository_and_registers_no_cadence() {
  assert_grep 'It is not a scheduler, it registers no timer' "$SKILL" \
    "the skill must disclaim owning a cadence"
  assert_grep "never sweeps another vessel's repositories" "$SKILL" \
    "the skill must refuse to sweep repositories it does not own"
  assert_grep 'Name the repository before the sweep starts' "$SKILL" \
    "the skill must require a named repository"
  pass "the sweep runs per repository and registers no cadence"
}

test_the_sweep_carries_the_five_source_grounded_subjects() {
  local n count
  for n in 1 2 3 4 5; do
    count=$(grep -c "^$n\. \*\*" "$SKILL")
    [ "$count" -eq 1 ] || fail "sweep subject $n must appear exactly once, found $count"
  done
  local phrase
  for phrase in \
    'Could a stranger find the right module from folder names and public interface types alone?' \
    'Are the modules deep, with small interfaces, or is this a web of shallow ones?' \
    'Is the interface where a person applies taste, while the implementation is the agent' \
    'Does the file system match the mental map?' \
    "Are the tests good enough to be the agent's feedback loop?"; do
    assert_grep "$phrase" "$SKILL" "the sweep lost a source-grounded subject: $phrase"
  done
  pass "the sweep carries all five source-grounded subjects"
}

test_codebase_design_has_a_version_independent_plain_file_fallback() {
  assert_grep 'mattpocock-skills:codebase-design' "$SKILL" \
    "the skill must name where codebase-design actually lives on this seat"
  assert_grep 'installed_plugins.json' "$SKILL" \
    "the fallback must resolve the installed plugin through its manifest"
  assert_grep '<installPath>/skills/engineering/codebase-design/SKILL.md' "$SKILL" \
    "the fallback must read the registered skill payload"
  assert_grep 'never construct that path from a version number' "$SKILL" \
    "the fallback must not freeze the plugin cache version"
  assert_grep 'not invocation-equivalent' "$SKILL" \
    "the fallback must distinguish content equivalence from harness invocation"
  assert_grep 'Start every sweep report with the vocabulary route used' "$SKILL" \
    "the report must identify how it received the vocabulary"
  assert_grep 'say so in the report and stop rather than improvising its vocabulary' "$SKILL" \
    "a missing loaded skill and fallback file must stop the sweep rather than be improvised"
  if grep -Eq '/mattpocock-skills/[0-9]+(\.[0-9]+)+/' "$SKILL"; then
    fail "the skill must not hardcode a plugin version"
  fi
  pass "codebase-design has a version-independent plain-file fallback with report provenance"
}

test_the_sort_is_by_tier_then_by_unblocked_findings() {
  assert_grep 'tier first, then by how many other findings each one unblocks' "$SKILL" \
    "the sort must be tier first, then unblock count"
  assert_grep 'ordered, not listed' "$SKILL" \
    "the report must reach the captain ordered rather than listed"
  pass "the sort is by tier and then by how many findings each unblocks"
}

test_middle_and_high_findings_are_routed_as_durable_decisions() {
  assert_grep 'decision-hold-lifecycle' "$SKILL" \
    "unresolved captain decisions must route to their owner"
  assert_grep 'a decision does not live in a report alone' "$SKILL" \
    "the skill must say why a report is not enough for a captain decision"
  pass "middle and high findings route to the durable-decision owner"
}

# A sweep that implies completeness it does not have is the same silent
# all-clear the fleet's currency and memory instruments each had to be taught
# not to give.
test_the_skill_states_what_it_does_not_cover() {
  assert_grep 'What this sweep does not cover' "$SKILL" \
    "the skill must state its own gaps"
  assert_grep 'not a correctness review, a security review, or a performance review' "$SKILL" \
    "the skill must disclaim the reviews it is not"
  assert_grep 'a clean sweep of a vessel is never a statement about the fleet' "$SKILL" \
    "a clean sweep must never read as a fleet-wide all-clear"
  pass "the skill states what it does not cover"
}

# --- provenance and the drafted notice --------------------------------------

test_provenance_records_the_measurement_and_its_source() {
  assert_grep '437478b02576d1f9' "$PROV" \
    "the provenance must name the envelope the transcript arrived in"
  assert_grep 'No risk classification anywhere in the talk' "$PROV" \
    "the provenance must record the measured negative"
  assert_grep 'low is everything reversible without me' "$PROV" \
    "the provenance must record his verbatim boundary"
  assert_grep 'What this seat wrote before that, and why it is not the boundary' "$PROV" \
    "the provenance must separate what this seat wrote from what he said"
  assert_grep 'copies nothing from it' "$PROV" \
    "the provenance must record that codebase-design is loaded and not adopted"
  pass "the provenance records the measurement, its source, and his words"
}

# A quotation is either verbatim or it is not. An automated documentation step
# silently smoothed the captain's own spelling on this page on 2026-08-17, on the
# one page whose entire purpose is attribution fidelity, and firstmate ruled it
# restored. This is the guard against the next well-meaning correction: it pins
# the misspelling he actually wrote, and bars the tidied form from the quotation.
test_his_quoted_spelling_survives_correction() {
  assert_grep 'have the dameno tell the fleet to use the skill' "$PROV" \
    "the captain's quoted spelling must stay exactly as he wrote it"
  assert_no_grep 'have the daemon tell the fleet to use the skill' "$PROV" \
    "the quotation must not carry the tidied spelling"
  # The note explaining the spelling has to sit outside the quotation, or the
  # explanation becomes another edit of his words.
  assert_grep 'The spelling in that quotation is his and is reproduced as he wrote it' "$PROV" \
    "the odd spelling must be explained beside the quotation rather than inside it"
  pass "the captain's quoted spelling survives an automated correction"
}

test_the_adoption_notice_is_a_draft_with_a_delivery_condition() {
  assert_grep 'NOT SENT' "$NOTICE" \
    "the adoption notice must be marked unsent"
  assert_grep 'merged-is-not-delivered' "$NOTICE" \
    "the notice must name the error its send condition prevents"
  assert_grep 'An envelope id proves composition and never delivery' "$NOTICE" \
    "the notice must keep composition and delivery apart"
  assert_grep "THE COMMODORE'S OWN FRAMING" "$NOTICE" \
    "the drafted notice must carry the attribution outward"
  # The body is a fixed-width block, so match within one of its lines rather
  # than across the wrap.
  assert_grep 'risk scale of any kind: no tiers, no severity ranking' "$NOTICE" \
    "the drafted notice must carry the measured negative outward"
  pass "the adoption notice is a draft carrying its own delivery condition"
}

# --- reachability -----------------------------------------------------------

test_the_skill_is_reachable_from_the_instruction_surface() {
  assert_grep 'Load the `codebase-sweep` skill' "$AGENTS" \
    "AGENTS.md must carry a load trigger for the sweep"
  assert_grep '/codebase-sweep' "$AGENTS" \
    "AGENTS.md must name the captain's invocation"
  # user-invocable skills are not section 13 entries; the trigger belongs in the
  # operating section that owns project knowledge.
  fm_skill_frontmatter "$ROOT/.agents/skills/codebase-sweep" | grep -qx 'user-invocable: true' \
    || fail "codebase-sweep must declare itself user-invocable"
  pass "the sweep is reachable from the instruction surface"
}

test_tiers_are_attributed_to_the_captain_and_never_to_the_talk
test_the_only_ordering_the_talk_gives_is_kept_as_a_target
test_low_is_his_reversibility_boundary_and_is_not_re_narrowed
test_both_halves_of_the_boundary_are_attributed_to_him
test_every_loaded_summary_carries_containment
test_detectability_is_a_flag_of_ours_and_never_a_demotion
test_each_tier_carries_a_falsifiable_entry_test
test_a_fix_that_outgrows_its_tier_stops_and_reclassifies
test_the_low_tier_grant_names_what_it_does_not_cover
test_merge_authority_is_read_at_the_time_and_never_hardcoded
test_the_sweep_is_per_repository_and_registers_no_cadence
test_the_sweep_carries_the_five_source_grounded_subjects
test_codebase_design_has_a_version_independent_plain_file_fallback
test_the_sort_is_by_tier_then_by_unblocked_findings
test_middle_and_high_findings_are_routed_as_durable_decisions
test_the_skill_states_what_it_does_not_cover
test_provenance_records_the_measurement_and_its_source
test_his_quoted_spelling_survives_correction
test_the_adoption_notice_is_a_draft_with_a_delivery_condition
test_the_skill_is_reachable_from_the_instruction_surface
