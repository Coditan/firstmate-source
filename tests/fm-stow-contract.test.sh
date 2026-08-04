#!/usr/bin/env bash
# Behavior tests for /stow's inspect-then-update memory contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stow_skill_task_note_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'tasks-axi show <id> --full' "$stow" "stow skill does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$stow" "stow skill does not require task body replacement"
  assert_grep '--archive-body' "$stow" "stow skill does not document recoverable task body archival"
  assert_grep 'Never append.' "$stow" "stow skill does not forbid append-first task notes"
  assert_no_grep 'carry that context into the replacement body' "$stow" "stow skill still preserves archive-only context in the replacement body"
  pass "stow skill task-note contract includes recoverable body archival"
}

test_agents_backlog_task_note_contract() {
  local agents="$ROOT/AGENTS.md"

  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'current `tasks-axi --help` own the backlog schema' "$agents" \
    "AGENTS.md does not point exact task-note mechanics to the command owner"
  assert_grep 'Inspect the current task note before replacing its considered body' "$agents" \
    "AGENTS.md does not require inspecting task notes before replacement"
  assert_grep 'archive the superseded body when recoverability matters rather than appending by default' "$agents" \
    "AGENTS.md lost recoverable replacement and no-append semantics"
  assert_no_grep 'tasks-axi show <id> --full' "$agents" \
    "AGENTS.md duplicates exact task-note read syntax from its conditional owner"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" \
    "AGENTS.md duplicates exact task-note update syntax from its conditional owner"
  pass "AGENTS.md keeps task-note hygiene inline and points exact mechanics to their owner"
}

# The reset path is plain code except for the sweep itself, so the sweep is the
# only place a thin pass can make a structurally valid receipt substantively
# false. These assertions keep that sweep-side consequence stated where the sweep
# is performed, and keep the mechanism's own clauses (the receipt, the refusals)
# pointed at their owner in docs/context-reset.md rather than restated here, where
# the two copies would drift - the one-owner rule.
test_stow_skill_owns_the_sweep_side_of_the_context_reset() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'When the context ceiling calls this sweep' "$stow" \
    "stow skill does not cover the context-ceiling caller"
  assert_grep 'the receipt can only attest to this sweep, never verify it' "$stow" \
    "stow skill does not state that the receipt cannot verify the sweep"
  assert_grep 'a thin sweep still produces a structurally valid receipt' "$stow" \
    "stow skill does not warn that a thin sweep still passes the receipt"
  assert_grep 'voids the receipt' "$stow" \
    "stow skill does not warn that captain input between the sweep and its receipt voids it"
  assert_grep 'never compaction' "$stow" "stow skill does not rule compaction out as the instrument"
  assert_grep 'docs/context-reset.md' "$stow" \
    "stow skill does not point the mechanism itself at its owning doc"
  # The invariant is that the skill states the ceiling IS measured now and the
  # sweep runs for the reset branch alone - not the absence of one dead phrasing
  # of the opposite ("no hook, no daemon" never reached main and only fires on a
  # verbatim retype). Assert the live claim, which any reintroduction must
  # contradict in whatever words it uses.
  assert_grep 'the watcher measures the session' "$stow" \
    "stow skill no longer acknowledges that the watcher measures the ceiling"
  assert_grep 'the reset branch, which fires when the session is over the ceiling' "$stow" \
    "stow skill no longer ties the sweep to the single branch that authorises the reset"
  pass "stow skill owns the sweep side of the reset and leaves the mechanism to its doc"
}

# The frontmatter description is the dispatch trigger: it decides whether the
# body is read at all, so a section the ceiling wake never reaches is a section
# that is not there. Asserted on the trigger line alone, because a mention
# further down the file would satisfy a whole-file grep without firing the skill.
test_stow_skill_trigger_names_the_context_ceiling_caller() {
  local trigger
  # Read the description from the frontmatter alone (tests/lib.sh owns the
  # bounded reader): a whole-file `sed` would be satisfied by a body mention -
  # exactly the case this test's own comment says the trigger surface excludes -
  # and would mangle a YAML folded scalar the reader flattens correctly.
  trigger=$(fm_skill_description "$ROOT/.agents/skills/stow")

  [ -n "$trigger" ] || fail "stow skill frontmatter carries no description trigger"
  assert_contains "$trigger" 'context-ceiling wake' \
    "stow skill trigger does not name the context-ceiling wake as a second caller"
  assert_contains "$trigger" 'never the instrument that holds the context ceiling' \
    "stow skill trigger lets a compaction read as the instrument that holds the ceiling"
  pass "stow skill trigger fires on the context-ceiling wake and keeps compaction off the ceiling"
}

# The reset and ask branches carry a next step in their payload; the unenforced
# and blocked branches carry a diagnosis instead. Without this, section 8 item 3
# describes every ceiling wake as self-directing and a model meeting the other
# two branches has nothing to act on.
test_agents_covers_ceiling_wakes_that_carry_no_next_step() {
  local agents="$ROOT/AGENTS.md"

  assert_grep 'reports the ceiling unenforced, or a reset blocked, names a condition rather than a next step' "$agents" \
    "AGENTS.md treats every context-ceiling wake as if it carried its own next step"
  assert_grep 'say plainly that it stands unrepaired' "$agents" \
    "AGENTS.md does not require an unrepaired ceiling to be reported rather than dropped"
  pass "AGENTS.md handles the ceiling wakes that report a condition instead of an action"
}

test_stow_skill_task_note_contract
test_agents_backlog_task_note_contract
test_stow_skill_owns_the_sweep_side_of_the_context_reset
test_stow_skill_trigger_names_the_context_ceiling_caller
test_agents_covers_ceiling_wakes_that_carry_no_next_step
