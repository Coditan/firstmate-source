#!/usr/bin/env bash
# Contract tests for the scout-research skill, its provenance record, and its
# instruction-surface triggers.
#
# These assert on prose on purpose. The skill ships no script: what it carries
# is an attribution, a dispatch step that must stay executable on this fleet,
# and three evidence disciplines whose whole value is that they are not softened
# into advice. Each degrades silently under a well-meaning edit - a licence
# notice dropped in a tidy-up, a concrete command replaced by "dispatch a
# scout", a label rule reworded into a suggestion - and none of them would fail
# any behavioral test, because there is no behavior to fail. So the checks live
# here.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/scout-research/SKILL.md"
PROV="$ROOT/docs/scout-research-provenance.md"
GUARD="$ROOT/bin/fm-subagent-pretool-check.sh"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"

# --- the dispatch step, which is the entire reason this fork exists ----------

# Upstream's opening instruction is refused in a primary home. A fork whose
# replacement step is only described, rather than named as a command a worker
# can run, would reproduce the defect it was written to fix.
test_the_dispatch_step_names_the_commands_that_actually_run() {
  assert_present "$SKILL" "scout-research skill is missing"
  assert_grep 'bin/fm-brief.sh <id> <repo> --scout' "$SKILL" \
    "the dispatch step must name the scaffold command, not merely describe it"
  assert_grep 'bin/fm-spawn.sh <id> <project-dir> --scout' "$SKILL" \
    "the dispatch step must name the spawn command, not merely describe it"
  assert_grep 'data/<id>/report.md' "$SKILL" \
    "the deliverable must be the scout report path rather than somewhere sensible"
  # The lifecycle belongs to AGENTS.md section 7; a second copy here would drift.
  assert_grep 'The lifecycle is `AGENTS.md` section 7' "$SKILL" \
    "the skill must defer the scout lifecycle to its owner"
  pass "the dispatch step names the commands a worker on this fleet can run"
}

# The guard is real, and the skill's claim about it must stay true in both
# directions. Overstating it - claiming the plugin is unusable everywhere -
# would be the same defect as understating it.
test_the_refusal_claim_is_scoped_the_way_the_guard_actually_is() {
  assert_present "$GUARD" "the delegation guard this skill's claim rests on is missing"
  assert_grep '**In a firstmate primary home that instruction is refused before it runs.**' "$SKILL" \
    "the skill must scope the refusal to a primary home"
  assert_grep 'exits 0 silently inside a task worktree' "$SKILL" \
    "the skill must record that the guard is inert in a task worktree"
  assert_grep 'a crewmate inside its own worktree may still delegate' "$SKILL" \
    "the skill must not overstate the refusal into a fleet-wide block"
  # The guard's own scoping is what makes both halves true. If it ever stopped
  # being scoped to a primary home, this skill's claim would silently invert.
  assert_grep 'fm_primary_scope_matches' "$GUARD" \
    "the guard must still scope itself to a genuine primary home"
  pass "the refusal claim matches the guard in both directions"
}

# --- the three disciplines this fleet added, which are the fork's own --------

test_internal_evidence_is_searched_before_external() {
  assert_grep '**External search is the second move, never the first.**' "$SKILL" \
    "the skill must put the internal record before any external source"
  assert_grep 'bin/fm-transcript-search.sh' "$SKILL" \
    "the internal search must name the session-archive tool"
  assert_grep 'data/learnings.md' "$SKILL" \
    "the internal search must reach the curated knowledge file"
  # An empty search result over a store that was built before the period in
  # question is the failure mode: it looks identical to a real absence.
  assert_grep '**Read the archive'"'"'s build date before treating an empty result as absence.**' "$SKILL" \
    "the skill must require the archive build date to be read"
  assert_grep 'is unknown, not no' "$SKILL" \
    "the skill must say what an empty result over a stale store actually means"
  # The skill cites an incident it did not itself re-measure. Under its own
  # step 4 that has to be visible, or the skill breaks its own rule in its
  # own text.
  assert_grep 'it is reported here rather than re-measured' "$SKILL" \
    "a cited incident the skill did not measure must say so"
  pass "the internal record is searched first and an empty result is bounded"
}

test_every_finding_carries_how_it_was_obtained() {
  assert_grep '- **Measured.**' "$SKILL" "the measured label is missing"
  assert_grep '- **Documented.**' "$SKILL" "the documented label is missing"
  assert_grep '- **Inferred.**' "$SKILL" "the inferred label is missing"
  assert_grep 'the label is set by how the claim was obtained rather than by how sure its author feels' "$SKILL" \
    "the skill must state what sets the label"
  assert_grep '**A measured finding is never dressed as a documented one, and an inferred one is never dressed as either.**' "$SKILL" \
    "the skill must forbid upgrading a label"
  assert_grep 'never evidence about another vessel or about the tool in general' "$SKILL" \
    "a measured finding must stay bounded to the seat and day that measured it"
  pass "every finding carries how it was obtained, and the label cannot be upgraded"
}

test_an_unsettled_question_is_reported_as_unknown() {
  assert_grep 'Step 5 - unknown is a finding, and it is reported as one' "$SKILL" \
    "the skill must make an unknown a reportable finding"
  assert_grep 'An honest gap beats a tidy answer' "$SKILL" \
    "the skill must state why a gap is reported rather than closed over"
  assert_grep 'whose unknown section is empty is the shape to distrust' "$SKILL" \
    "the skill must name the confident-and-complete report as the suspect one"
  pass "an unsettled question is reported as unknown rather than tidied away"
}

# --- what upstream owned, and what this fork routes elsewhere ---------------

test_the_kept_upstream_discipline_survives() {
  assert_grep 'not a secondary write-up of them' "$SKILL" \
    "the primary-source rule must survive the fork"
  assert_grep 'Follow every claim back to the source that owns it' "$SKILL" \
    "the chain back to the owning source must survive the fork"
  assert_grep 'single Markdown file' "$SKILL" \
    "the one-file deliverable must survive the fork"
  pass "the upstream disciplines worth keeping survived the fork"
}

test_the_investigation_decides_nothing_and_routes_the_gate() {
  assert_grep 'decision-hold-lifecycle' "$SKILL" \
    "the completion gate must route to its owner"
  assert_grep 'That skill owns the gate in full and this one adds nothing to it' "$SKILL" \
    "the skill must not keep a second copy of the completion gate"
  assert_grep 'it never authorizes it' "$SKILL" \
    "a recommendation must not read as authorization to implement"
  pass "the investigation routes its gate and authorizes nothing"
}

test_the_skill_states_what_it_does_not_cover() {
  assert_grep 'What this does not cover' "$SKILL" \
    "the skill must state its own gaps"
  assert_grep 'It does not make a stale archive current' "$SKILL" \
    "the skill must disclaim refreshing the archive it depends on"
  assert_grep 'Primary is a test of provenance, not of correctness' "$SKILL" \
    "the skill must disclaim that a primary source is thereby a right one"
  pass "the skill states what it does not cover"
}

# --- attribution, which MIT makes a term rather than a courtesy -------------

test_the_fork_carries_its_licence_notice_and_accounting() {
  assert_grep 'mattpocock/skills' "$SKILL" "the skill does not name its source"
  assert_grep 'MIT licence' "$SKILL" "the skill does not name the licence it is used under"
  assert_present "$PROV" "scout-research provenance and third-party notice is missing"
  assert_grep 'Copyright (c) 2026 Matt Pocock' "$PROV" \
    "the provenance lost the MIT copyright notice"
  assert_grep 'The above copyright notice and this permission notice shall be included in all' "$PROV" \
    "the provenance lost the MIT permission notice"
  for heading in '## What we kept' '## What we changed' '## What we dropped'; do
    assert_grep "$heading" "$PROV" "the provenance is missing '$heading'"
  done
  assert_grep 'Cost:' "$PROV" "each dropped capability must carry its cost"
  assert_grep 'docs/scout-research-provenance.md' "$README" \
    "README does not point at the scout-research third-party notice"
  pass "the fork carries its notice and its kept-changed-dropped accounting"
}

# A version and a file list are the only identifiers this reading can carry,
# because the source was an installed plugin rather than a clone. A later page
# that quietly claims a commit would be claiming evidence nobody took.
test_the_provenance_names_the_version_and_admits_it_read_no_commit() {
  assert_grep '## What was inspected' "$PROV" \
    "the provenance must say what was inspected"
  assert_grep 'skills/engineering/research/SKILL.md' "$PROV" \
    "the provenance must name the source file it read"
  assert_grep 'Plugin release **1.2.3**' "$PROV" \
    "the provenance must name the plugin version it read"
  assert_grep 'The source was the installed plugin rather than a clone, so no git commit was read' "$PROV" \
    "the provenance must state honestly that it read no commit"
  pass "the provenance names its version, its files, and the identifier it lacks"
}

# Forking was a choice, and the alternative - keep loading the plugin, as
# codebase-sweep does - is a legitimate outcome this fleet has taken before.
# The reason for not taking it must stay a measurement, not a preference.
# The replacement dispatch step was executed rather than described, and the half
# that was not executed is labelled as such. A later edit that quietly promotes
# the unexecuted half to measured would be the exact defect step 4 forbids.
test_the_provenance_separates_what_was_run_from_what_was_not() {
  assert_grep '## The dispatch step, followed rather than described' "$PROV" \
    "the provenance must record following the dispatch step, not only describing it"
  assert_grep 'scaffolded: <scratch>/data/probe-research/brief.md (scout; replace {TASK})' "$PROV" \
    "the provenance must carry the scaffold's own output as the reading"
  assert_grep '**What was not executed, and why.**' "$PROV" \
    "the provenance must name the half of the step it did not run"
  assert_grep 'Under this skill'"'"'s own step 4 that is an inferred claim, and it is labelled as one' "$PROV" \
    "the unexecuted half must be labelled inferred rather than folded into the measured half"
  pass "the provenance separates the step it ran from the step it did not"
}

test_the_fork_is_defended_by_a_measurement_rather_than_a_preference() {
  assert_grep '## Why this one was forked rather than loaded' "$PROV" \
    "the provenance must defend forking over loading the plugin"
  assert_grep 'codebase-sweep-provenance.md' "$PROV" \
    "the provenance must name the record where the other outcome was taken"
  assert_grep 'delegation-shaped on' "$PROV" \
    "the provenance must carry the guard's own refusal output as the measurement"
  assert_grep 'the second one alone would have overstated the case' "$PROV" \
    "the provenance must record both readings, not only the refusal"
  pass "the fork is defended by a measurement, and both readings are recorded"
}

# The plugin stays installed and reachable under a name one word away from
# ours. A reader has to be able to choose between them from the listing alone.
test_the_two_skills_can_be_told_apart_from_their_descriptions() {
  local desc
  desc=$(fm_skill_description "$ROOT/.agents/skills/scout-research")
  printf '%s' "$desc" | grep -q 'mattpocock-skills:research' \
    || fail "the description must name the plugin skill a reader might load instead"
  printf '%s' "$desc" | grep -q 'ordinary repository with no fleet dispatch behind it' \
    || fail "the description must state when the plugin is the right choice instead"
  assert_grep '## The name, and how a reader chooses between the two' "$PROV" \
    "the provenance must state how a reader chooses between the fork and the plugin"
  assert_grep 'A local skill named `research` would sit beside it' "$PROV" \
    "the provenance must record why the fork does not take the bare name"
  pass "a reader can choose between the fork and the plugin from the listing alone"
}

# --- reachability -----------------------------------------------------------

test_the_skill_is_reachable_from_the_instruction_surface() {
  assert_grep '- `scout-research` - ' "$AGENTS" \
    "an agent-only skill must carry exactly one AGENTS.md section 13 trigger"
  fm_skill_frontmatter "$ROOT/.agents/skills/scout-research" | grep -qx 'user-invocable: false' \
    || fail "scout-research must declare itself agent-only"
  fm_skill_frontmatter "$ROOT/.agents/skills/scout-research" | grep -qx '  internal: true' \
    || fail "scout-research must be internal, since it assumes a live firstmate home"
  pass "the skill is reachable from AGENTS.md and is declared agent-only"
}

test_the_dispatch_step_names_the_commands_that_actually_run
test_the_refusal_claim_is_scoped_the_way_the_guard_actually_is
test_internal_evidence_is_searched_before_external
test_every_finding_carries_how_it_was_obtained
test_an_unsettled_question_is_reported_as_unknown
test_the_kept_upstream_discipline_survives
test_the_investigation_decides_nothing_and_routes_the_gate
test_the_skill_states_what_it_does_not_cover
test_the_fork_carries_its_licence_notice_and_accounting
test_the_provenance_names_the_version_and_admits_it_read_no_commit
test_the_provenance_separates_what_was_run_from_what_was_not
test_the_fork_is_defended_by_a_measurement_rather_than_a_preference
test_the_two_skills_can_be_told_apart_from_their_descriptions
test_the_skill_is_reachable_from_the_instruction_surface
