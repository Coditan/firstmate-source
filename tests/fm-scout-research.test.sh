#!/usr/bin/env bash
# Behavior and owned-contract tests for the scout-research skill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="$ROOT/.agents/skills/scout-research"
PROV="$ROOT/docs/scout-research-provenance.md"
GUARD="$ROOT/bin/fm-subagent-pretool-check.sh"
README="$ROOT/README.md"
fm_test_tmproot TMP_ROOT fm-scout-research-tests

frontmatter_scalar() {
  local key=$1
  fm_skill_frontmatter "$SKILL_DIR" | awk -F ': *' -v key="$key" '
    $1 == key { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  '
}

frontmatter_metadata_scalar() {
  local key=$1
  fm_skill_frontmatter "$SKILL_DIR" | awk -F ': *' -v key="$key" '
    /^metadata:[[:space:]]*$/ { in_metadata = 1; next }
    in_metadata && /^[^[:space:]]/ { exit }
    in_metadata {
      field = $1
      sub(/^[[:space:]]+/, "", field)
      if (field == key) {
        sub(/^[^:]*:[[:space:]]*/, "")
        print
        exit
      }
    }
  '
}

test_scout_brief_emits_the_dispatch_contract() {
  local home="$TMP_ROOT/brief-home" brief output
  mkdir -p "$home/state"
  output=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-brief.sh" probe-research fixture-repo --scout) \
    || fail "fm-brief.sh could not scaffold a scout brief"
  brief="$home/data/probe-research/brief.md"
  assert_present "$brief" "fm-brief.sh did not generate the scout brief"
  assert_contains "$output" "$brief" "fm-brief.sh did not report the generated brief"
  # Generated scout briefs are the public dispatch contract.
  assert_grep 'data/probe-research/report.md' "$brief" \
    "the generated scout brief must name its report deliverable"
  assert_grep 'decision-hold-lifecycle/SKILL.md' "$brief" \
    "the generated scout brief must require the shared completion gate"
  pass "scout dispatch generates the report and completion-gate contract"
}

test_guard_refuses_primary_delegation_and_allows_task_worktrees() {
  local primary="$TMP_ROOT/primary" child="$TMP_ROOT/child"
  local state="$primary/state" out="$TMP_ROOT/guard.out" err="$TMP_ROOT/guard.err" rc=0 deny
  mkdir -p "$primary/bin" "$state"
  printf '# fixture\n' > "$primary/AGENTS.md"
  git -C "$primary" init -q
  git -C "$primary" add AGENTS.md
  git -C "$primary" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
  git -C "$primary" worktree add -q -b fixture-child "$child"

  FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" FM_STATE_OVERRIDE="$state" \
    "$GUARD" --claude --tool Task > "$out" 2> "$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "Task in a primary fixture must exit 2, got $rc"
  [ ! -s "$out" ] || fail "primary denial wrote unexpected stdout: $(cat "$out")"
  deny=$(cat "$err")
  assert_contains "$deny" 'bin/fm-brief.sh' "primary denial must route through fm-brief.sh"
  assert_contains "$deny" 'bin/fm-spawn.sh' "primary denial must route through fm-spawn.sh"

  rc=0
  : > "$out"
  : > "$err"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$GUARD" --claude --tool Task > "$out" 2> "$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "Task in a linked child worktree must exit 0, got $rc"
  [ ! -s "$out" ] || fail "task-worktree allow wrote stdout: $(cat "$out")"
  [ ! -s "$err" ] || fail "task-worktree allow wrote stderr: $(cat "$err")"
  pass "delegation guard refuses primary scope and allows task scope"
}

test_frontmatter_has_the_agent_only_semantics() {
  local name user_invocable internal description
  name=$(frontmatter_scalar name)
  user_invocable=$(frontmatter_scalar user-invocable)
  internal=$(frontmatter_metadata_scalar internal)
  description=$(fm_skill_description "$SKILL_DIR")
  [ "$name" = "$(basename "$SKILL_DIR")" ] \
    || fail "frontmatter name must equal the skill directory name"
  [ "$user_invocable" = false ] || fail "scout-research must be agent-only"
  [ "$internal" = true ] || fail "scout-research must be internal"
  [ -n "$description" ] || fail "scout-research must emit a listing description"
  pass "frontmatter declares an internal agent-only scout-research skill"
}

test_the_fork_carries_its_licence_notice_and_accounting() {
  assert_present "$PROV" "scout-research provenance and third-party notice is missing"
  # The provenance page owns the verbatim third-party licence contract.
  assert_grep 'Copyright (c) 2026 Matt Pocock' "$PROV" \
    "the provenance lost the MIT copyright notice"
  assert_grep 'The above copyright notice and this permission notice shall be included in all' "$PROV" \
    "the provenance lost the MIT permission notice"
  # The provenance page owns the fork accounting contract.
  for heading in '## What we kept' '## What we changed' '## What we dropped'; do
    assert_grep "$heading" "$PROV" "the provenance is missing '$heading'"
  done
  assert_grep 'Cost:' "$PROV" "each dropped capability must carry its cost"
  assert_grep 'Plugin release **1.2.3**' "$PROV" \
    "the provenance must name the plugin version it read"
  assert_grep 'The source was the installed plugin rather than a clone, so no git commit was read' "$PROV" \
    "the provenance must state honestly that it read no commit"
  # README owns the public index of third-party provenance records.
  assert_grep 'docs/scout-research-provenance.md' "$README" \
    "README does not point at the scout-research third-party notice"
  pass "the fork carries its licence and provenance contracts"
}

test_scout_brief_emits_the_dispatch_contract
test_guard_refuses_primary_delegation_and_allows_task_worktrees
test_frontmatter_has_the_agent_only_semantics
test_the_fork_carries_its_licence_notice_and_accounting
