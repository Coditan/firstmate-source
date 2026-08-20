#!/usr/bin/env bash
# Contract tests for the design-it-twice skill, its provenance record, its
# prepared upstream offer, and its instruction-surface triggers.
#
# These assert on prose on purpose. The skill ships no script: what it carries
# is an attribution, a discrimination borrowed from another skill that must not
# be quietly widened, and a claim about what a formation can and cannot prove.
# Each of those degrades silently under a well-meaning edit - a gate softened
# into an invitation, a borrowed bar restated and drifted, an unsent draft
# losing the word that says it is unsent - and none of them would fail any
# behavioral test, because there is no behavior to fail. So the checks live here.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/design-it-twice/SKILL.md"
PROV="$ROOT/docs/design-it-twice-provenance.md"
OFFER="$ROOT/docs/design-it-twice-upstream-offer.md"
SWEEP="$ROOT/.agents/skills/codebase-sweep/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"

# --- the discrimination, which is the thing most likely to be widened --------

# A skill that offered a panel for every interface decision would be worse than
# one that never offered it, because the offer would stop carrying information.
# The bar belongs to `panel`; this skill must defer to it rather than keep a
# second copy that can drift, and must not soften it on the way through.
test_the_panel_bar_is_borrowed_whole_and_never_restated() {
  assert_present "$SKILL" "design-it-twice skill is missing"
  assert_grep 'The bar belongs to `panel`, and this skill narrows nothing in it' "$SKILL" \
    "the skill must defer the worth-it judgement to panel and narrow nothing in it"
  assert_grep 'Is this question worth a panel' "$SKILL" \
    "the skill must name the section of panel that owns the bar"
  assert_grep 'would be worse than one that never offered it' "$SKILL" \
    "the skill must say why offering a panel for everything is worse than never offering one"
  # The bar is panel's; a second full copy here would drift the moment only one
  # is edited. Two concrete readings are allowed and are not the bar itself.
  assert_no_grep 'Not worth it:' "$SKILL" \
    "the skill must not carry a second copy of panel's worth-it list"
  pass "the panel bar is borrowed from its owner and is not restated here"
}

test_the_default_is_one_head_and_the_fan_out_is_the_exception() {
  assert_grep 'Step 1 - design it twice yourself, which is the default' "$SKILL" \
    "designing it twice in one head must be the default step"
  assert_grep 'Most interface questions end here.' "$SKILL" \
    "the skill must say most interface questions end without a panel"
  assert_grep '**Offer it, never assume it.**' "$SKILL" \
    "the panel must be offered to the captain rather than assumed"
  assert_grep 'start --dry-run' "$SKILL" \
    "the offer must be able to show the lineup before anything is spent"
  pass "the one-head exercise is the default and the panel is offered, not assumed"
}

# Both concrete readings are borrowed from records this fleet already holds, so
# neither may be re-derived here into something stricter or looser than its owner.
test_the_two_concrete_readings_cite_their_owners() {
  assert_grep "reversible without the captain and contained inside one module" "$SKILL" \
    "the low-tier reading must carry both halves of the captain's boundary"
  assert_grep 'Only a middle finding can be one' "$SKILL" \
    "the skill must confine panel-worthy interface questions to the middle tier"
  assert_grep 'whether you would act the same way whatever the judge concluded' "$SKILL" \
    "the skill must carry panel's own would-you-act-differently test"
  pass "the tier and consequence readings cite the records that own them"
}

# --- the formation, and the invariant that makes it evidence ----------------

test_the_question_stays_byte_identical_across_the_analysts() {
  assert_grep 'Both analysts receive byte-identical text' "$SKILL" \
    "the skill must state the panel's identical-question invariant"
  assert_grep '**Do not try to make the constraint the difference between the analysts.**' "$SKILL" \
    "the skill must forbid splitting the constraints across the analysts"
  assert_grep 'disagree by construction, and a judge cannot tell that disagreement from a real one' "$SKILL" \
    "the skill must say why differing questions destroy the judge's reading"
  assert_grep 'Divergence then happens inside each analyst, and independence happens across them' "$SKILL" \
    "the skill must relocate the fan-out inside each analyst rather than dropping it"
  pass "the constraints ride inside one identical question rather than splitting the analysts"
}

# The whole reason the captain asked for this: ad-hoc parallel sub-agents make
# the failure invisible, and the panel refuses rather than hiding it.
test_the_skill_states_what_ad_hoc_sub_agents_cannot_guarantee() {
  assert_grep 'refuses to start unless it can prove two distinct pinned model identities' "$SKILL" \
    "the skill must state the refusal that makes the panel's independence provable"
  assert_grep "one model's priors three times" "$SKILL" \
    "the skill must state what parallel sub-agents on one default actually produce"
  assert_grep 'nothing in that formation tells you which happened' "$SKILL" \
    "the skill must state that the ad-hoc failure is invisible"
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/design-it-twice")
  printf '%s' "$desc" | grep -q 'all run the same model' \
    || fail "the skill description must carry the independence warning to the harness listing"
  pass "the skill states what ad-hoc parallel sub-agents cannot guarantee"
}

# A design comparison settled on how the designs read is rhetoric. In the panel
# form the judge does this; in the one-head default nobody else would.
test_claims_are_verified_against_the_code_before_the_recommendation() {
  assert_grep 'Before the recommendation, re-check each shape' "$SKILL" \
    "the skill must verify load-bearing claims before recommending"
  assert_grep 'Does the deletion test hold for this module' "$SKILL" \
    "the verification must reach the deletion test"
  assert_grep 'or is the seam hypothetical' "$SKILL" \
    "the verification must ask whether the second adapter actually exists"
  pass "load-bearing claims are checked against the code before the recommendation"
}

test_the_exercise_decides_nothing_and_routes_the_shape_choice() {
  assert_grep 'It does not decide.' "$SKILL" \
    "the skill must state that the verdict is not the decision"
  assert_grep 'decision-hold-lifecycle' "$SKILL" \
    "the shape choice must route to the durable-decision owner"
  pass "the exercise produces evidence and routes the decision to its owner"
}

test_the_skill_states_what_it_does_not_cover() {
  assert_grep 'What this does not cover' "$SKILL" \
    "the skill must state its own gaps"
  assert_grep 'not a correctness, security, or performance review' "$SKILL" \
    "the skill must disclaim the reviews it is not"
  assert_grep 'reduced form is a single-analyst review that must never be relayed as a second opinion' "$SKILL" \
    "the skill must keep panel's reduced form from being relayed as a panel"
  pass "the skill states what it does not cover"
}

# --- attribution, which MIT makes a term rather than a courtesy -------------

test_the_adoption_carries_its_licence_notice_and_accounting() {
  assert_grep 'mattpocock/skills' "$SKILL" "the skill does not name its source"
  assert_grep 'MIT licence' "$SKILL" "the skill does not name the licence it is used under"
  assert_present "$PROV" "design-it-twice provenance and third-party notice is missing"
  assert_grep 'Copyright (c) 2026 Matt Pocock' "$PROV" \
    "the provenance lost the MIT copyright notice"
  assert_grep 'The above copyright notice and this permission notice shall be included in all' "$PROV" \
    "the provenance lost the MIT permission notice"
  for heading in '## What we kept' '## What we changed' '## What we dropped'; do
    assert_grep "$heading" "$PROV" "the provenance is missing '$heading'"
  done
  assert_grep 'docs/design-it-twice-provenance.md' "$README" \
    "README does not point at the design-it-twice third-party notice"
  pass "the adoption carries its notice and its kept-changed-dropped accounting"
}

# Adopting half of a skill is defensible and was defended; adopting half by
# accident is the failure this fleet's first adoption from this upstream made.
test_the_partial_adoption_is_defended_and_its_cost_is_named() {
  assert_grep 'Why this is a partial adoption, which was a decision and not an oversight' "$PROV" \
    "the provenance must defend taking only half of the skill"
  assert_grep 'cannot work without `codebase-design` installed on the seat' "$PROV" \
    "the provenance must name the cost of depending on the plugin it did not adopt"
  assert_grep 'Cost:' "$PROV" \
    "each dropped capability must carry its cost"
  # The sweep's published record says it copies nothing from codebase-design.
  # That claim is still true and must not be silently contradicted.
  assert_grep 'the sweep still only loads the plugin skill and still copies nothing from it' \
    "$ROOT/docs/codebase-sweep-provenance.md" \
    "the sweep's provenance must reconcile with the new adoption rather than be contradicted by it"
  pass "the partial adoption is defended and its cost is named"
}

# --- the offer upstream, which is prepared and must stay unsent -------------

test_the_upstream_offer_is_complete_and_marked_unsent() {
  assert_present "$OFFER" "the prepared upstream offer is missing"
  assert_grep 'NOT SENT' "$OFFER" "the upstream offer must be marked unsent"
  assert_grep 'The decision this is waiting on' "$OFFER" \
    "the offer must name the decision that gates publishing it"
  assert_grep 'Under what identity' "$OFFER" \
    "the offer must name the identity question, which is not merely a wording review"
  assert_grep 'The exact command that would open it' "$OFFER" \
    "the offer must carry the exact command that would publish it"
  assert_grep 'The covering note, which is the pull-request body' "$OFFER" \
    "the offer must carry the covering note"
  pass "the upstream offer is complete, has a command, and is marked unsent"
}

# An upstream skill runs in repositories that have never heard of this fleet, so
# proposing our script would be proposing a dependency he cannot take.
test_the_offer_proposes_no_dependency_on_this_fleet() {
  assert_grep '**None of that is being proposed upstream.**' "$OFFER" \
    "the offer must state that our mechanism is not what is proposed"
  assert_grep 'an upstream skill cannot depend on one fleet' "$PROV" \
    "the provenance must record the implementation-neutrality constraint"
  assert_grep 'That mechanism is ours and is not what I am proposing' "$OFFER" \
    "the covering note must disclaim proposing our mechanism"
  pass "the offer stays implementation-neutral and proposes no fleet dependency"
}

# --- reachability -----------------------------------------------------------

test_the_skill_is_reachable_from_the_instruction_surface() {
  assert_grep 'load the `design-it-twice` skill' "$AGENTS" \
    "AGENTS.md must carry a load trigger for the exercise"
  assert_no_grep '- `design-it-twice` - ' "$AGENTS" \
    "a captain-invocable skill must not be listed in AGENTS.md section 13"
  fm_skill_frontmatter "$ROOT/.agents/skills/design-it-twice" | grep -qx 'user-invocable: true' \
    || fail "design-it-twice must declare itself user-invocable"
  fm_skill_frontmatter "$ROOT/.agents/skills/design-it-twice" | grep -qx '  internal: true' \
    || fail "design-it-twice must be internal, since it assumes a live firstmate home"
  # The sweep is the other door into this exercise, and it used to send the
  # reader to upstream's file, which is the ad-hoc formation this replaces.
  assert_grep 'load `design-it-twice` rather than its `DESIGN-IT-TWICE.md`' "$SWEEP" \
    "the sweep must send a shape question to this skill rather than to upstream's file"
  pass "the exercise is reachable from AGENTS.md and from the sweep"
}

test_the_panel_bar_is_borrowed_whole_and_never_restated
test_the_default_is_one_head_and_the_fan_out_is_the_exception
test_the_two_concrete_readings_cite_their_owners
test_the_question_stays_byte_identical_across_the_analysts
test_the_skill_states_what_ad_hoc_sub_agents_cannot_guarantee
test_claims_are_verified_against_the_code_before_the_recommendation
test_the_exercise_decides_nothing_and_routes_the_shape_choice
test_the_skill_states_what_it_does_not_cover
test_the_adoption_carries_its_licence_notice_and_accounting
test_the_partial_adoption_is_defended_and_its_cost_is_named
test_the_upstream_offer_is_complete_and_marked_unsent
test_the_offer_proposes_no_dependency_on_this_fleet
test_the_skill_is_reachable_from_the_instruction_surface
