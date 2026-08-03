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

test_stow_skill_owns_the_context_ceiling_cadence() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'Cadence: the 300k context ceiling' "$stow" "stow skill does not own the context-ceiling cadence"
  assert_grep "session's context passes 300k" "$stow" "stow skill does not state the 300k threshold"
  assert_grep 'quiet boundary' "$stow" "stow skill does not bound the timing to a quiet boundary"
  assert_grep 'never compaction' "$stow" "stow skill does not rule compaction out as the instrument"
  assert_grep 'no hook, no daemon' "$stow" "stow skill does not record that the rejected measuring machinery stays out"
  pass "stow skill owns the 300k ceiling, its quiet-boundary condition, and the not-compaction instrument"
}

test_agents_heartbeat_checklist_observes_the_ceiling() {
  local agents="$ROOT/AGENTS.md"

  assert_grep '300k context ceiling' "$agents" "AGENTS.md heartbeat checklist does not state the ceiling"
  assert_grep 'stow-then-clear from durable records and never compaction' "$agents" \
    "AGENTS.md heartbeat checklist does not name the instrument or rule compaction out"
  assert_grep 'at this or the next quiet boundary' "$agents" \
    "AGENTS.md heartbeat checklist lost the quiet-boundary condition"
  pass "AGENTS.md heartbeat checklist makes the context ceiling observed rather than remembered"
}

test_stow_skill_task_note_contract
test_agents_backlog_task_note_contract
test_stow_skill_owns_the_context_ceiling_cadence
test_agents_heartbeat_checklist_observes_the_ceiling
