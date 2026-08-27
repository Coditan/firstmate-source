#!/usr/bin/env bash
# Behavior tests for fm-model-panel.sh: role resolution, the honest
# single-model degradation, the different-models guarantee, the judge gate, and
# the brief contract both analysts and the judge receive.
#
# These drive the real script with the real fm-brief.sh scaffold and the real
# fm-dispatch-select.sh selector, against a copied bin/ whose fm-spawn.sh is
# replaced by a stub that records its argv. That keeps the assertions on what
# the panel ASKS the fleet to dispatch, without starting a backend, a worktree,
# or a harness. Quota data is deliberately unavailable, so an array-backed role
# falls back to the selector's uniform random choice and no test reaches a live
# quota service.
# A stub can only prove what the panel asks for, never that the fleet still
# accepts it, so test_panel_start_dispatches_through_the_real_spawn deliberately
# leaves the stub behind and drives the REAL fm-spawn.sh behind a fake tmux.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-model-panel

FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/.agents/skills/decision-hold-lifecycle"
cp -a "$ROOT/bin" "$FAKE_ROOT/bin"
printf 'decision-hold stub\n' > "$FAKE_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
cat > "$FAKE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
# Records the spawn request and writes the runtime record fm-model-panel.sh
# checks, so the panel's dispatch contract is observable without a backend.
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_SPAWN_LOG"
if [ -n "${FM_FAKE_SPAWN_FAIL_ID:-}" ] && [ "$1" = "$FM_FAKE_SPAWN_FAIL_ID" ]; then
  echo "fake spawn refused $1" >&2
  exit 1
fi
printf 'window=fake:%s\nkind=scout\n' "$1" > "$FM_STATE_OVERRIDE/$1.meta"
echo "spawned $1"
SH
chmod +x "$FAKE_ROOT/bin/fm-spawn.sh"

PANEL="$FAKE_ROOT/bin/fm-model-panel.sh"

# new_home <name> [panel-config-json]: build an isolated home and echo its path.
new_home() {
  local config_json=${2:-} home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/subject"
  [ -z "$config_json" ] || printf '%s\n' "$config_json" > "$home/config/model-panel.json"
  printf '%s\n' "$home"
}

run_panel() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_FAKE_SPAWN_LOG="$home/spawn.log" \
    FM_DISPATCH_QUOTA_AXI=fm-test-absent-quota-axi \
    "$PANEL" "$@" 2>&1
}

spawn_log() {
  cat "$1/spawn.log" 2>/dev/null || true
}

# Append one status EVENT for a panel member, exactly as its scout scaffold tells
# it to. The judge gate reads these, so tests must produce them the same way.
say_status() {  # <home> <task-id> <line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

TWO_MODELS='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5","effort":"xhigh"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},
  "judge":{"harness":"grok","model":"grok-4-fast","effort":"high"}}}'

ONE_MODEL='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"claude","model":"claude-opus-5"},
  "judge":{"harness":"claude","model":"claude-opus-5"}}}'

# The same model reached through two different harnesses is still one model.
ONE_MODEL_TWO_HARNESSES='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"pi","model":"anthropic/claude-opus-5:1m"},
  "judge":{"harness":"claude","model":"claude-opus-5"}}}'

DISTINCT_ANALYST_ARRAYS='{"roles":{
  "analyst_a":[
    {"harness":"claude","model":"claude-opus-5"},
    {"harness":"codex","model":"gpt-5.6-sol"}],
  "analyst_b":[
    {"harness":"claude","model":"claude-opus-5"},
    {"harness":"codex","model":"gpt-5.6-sol"}],
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

ONE_MODEL_ANALYST_ARRAYS='{"roles":{
  "analyst_a":[{"harness":"claude","model":"claude-opus-5"}],
  "analyst_b":[{"harness":"pi","model":"anthropic/claude-opus-5:1m"}],
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

COLLIDING_JUDGE_ARRAY='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":[
    {"harness":"codex","model":"gpt-5.6-sol"},
    {"harness":"claude","model":"claude-opus-5"}]}}'

UNPINNED_ANALYST_COLLISION='{"roles":{
  "analyst_a":{"harness":"codex"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

UNPINNED_ANALYST_B_COLLISION='{"roles":{
  "analyst_a":{"harness":"codex","model":"gpt-5.6-sol"},
  "analyst_b":{"harness":"codex"},
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

MIXED_ANALYST_A_ARRAY='{"roles":{
  "analyst_a":[
    {"harness":"codex"},
    {"harness":"claude","model":"claude-opus-5"}],
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

ALL_UNPINNED_ANALYST_A_ARRAY='{"roles":{
  "analyst_a":[
    {"harness":"codex"},
    {"harness":"claude"}],
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

INVALID_ANALYST_A_ARRAY='{"roles":{
  "analyst_a":[
    {"harness":"spaceship"},
    {"harness":"claude","model":"claude-opus-5"}],
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

INVALID_ANALYST_B_ARRAY='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":[
    {"harness":"spaceship"},
    {"harness":"codex","model":"gpt-5.6-sol"}],
  "judge":{"harness":"grok","model":"grok-4-fast"}}}'

INVALID_JUDGE_ARRAY='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":[
    {"harness":"spaceship"},
    {"harness":"grok","model":"grok-4-fast"}]}}'

UNPINNED_JUDGE_COLLISION='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":{"harness":"codex"}}}'

UNPINNED_FIRST_JUDGE_ARRAY='{"roles":{
  "analyst_a":{"harness":"claude","model":"claude-opus-5"},
  "analyst_b":{"harness":"codex","model":"gpt-5.6-sol"},
  "judge":[
    {"harness":"codex"},
    {"harness":"grok","model":"grok-4-fast"}]}}'

REDUCED_UNPINNED_ANALYST='{"roles":{
  "analyst_a":{"harness":"codex"},
  "analyst_b":{"harness":"claude","model":"claude-opus-5"},
  "judge":{"harness":"codex","model":"gpt-5.6-sol"}}}'

SKILL="$ROOT/.agents/skills/panel/SKILL.md"
CONFIG_DOC="$ROOT/docs/configuration.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_owns_the_cost_decision_and_one_trigger() {
  local count
  assert_present "$SKILL" "the panel skill is missing"
  assert_grep 'name: panel' "$SKILL" "the panel skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "the panel skill must be captain-invocable"
  assert_grep '  internal: true' "$SKILL" "the panel skill must be internal"
  assert_grep 'bin/fm-model-panel.sh' "$SKILL" "the panel skill does not point at its entry point"
  assert_grep 'Is this question worth a panel' "$SKILL" \
    "the panel skill does not own the cost decision"
  assert_grep 'Worth it:' "$SKILL" "the panel skill does not say when a panel earns its cost"
  assert_grep 'Not worth it:' "$SKILL" "the panel skill does not say when a panel wastes its cost"
  assert_grep 'decision-hold-lifecycle' "$SKILL" "the panel skill does not fold in the completion gate"
  assert_grep 'single-analyst review' "$SKILL" "the panel skill does not name the reduced form"
  count=$(grep -Fc 'load the `panel` skill' "$AGENTS")
  [ "$count" -eq 1 ] || fail "the panel skill needs exactly one AGENTS.md trigger, found $count"
  pass "the panel skill owns the cost decision and has one AGENTS.md trigger"
}

test_configuration_doc_owns_the_schema_and_degradation() {
  assert_grep '## Model panel roles (config/model-panel.json)' "$CONFIG_DOC" \
    "docs/configuration.md does not own the panel configuration schema"
  assert_grep 'analyst_a' "$CONFIG_DOC" "the documented schema does not name the analyst roles"
  assert_grep 'bin/fm-dispatch-select.sh' "$CONFIG_DOC" \
    "the documented schema does not point at the shared selector"
  assert_grep 'refuses with exit 4' "$CONFIG_DOC" \
    "the documented degradation contract does not state the refusal"
  assert_grep 'config/model-panel.json` is deliberately NOT in the inheritable set' "$CONFIG_DOC" \
    "the documented contract does not explain why the panel config is not inherited"
  assert_gitignore_ignores 'config/model-panel.json' \
    "the local panel configuration file is not gitignored"
  assert_present "$ROOT/docs/examples/model-panel.json" "the copyable example config is missing"
  pass "docs/configuration.md owns the panel schema, default, and degradation contract"
}

test_analysts_dispatch_on_different_models() {
  local home out log
  home=$(new_home different-models "$TWO_MODELS")
  out=$(run_panel "$home" start --id trio --project "$home/subject" "Which queued work is blocked?") \
    || fail "start failed: $out"
  log=$(spawn_log "$home")
  assert_contains "$log" "trio-a $home/subject --harness claude --scout --model claude-opus-5 --effort xhigh" \
    "analyst A was not dispatched on its configured profile"
  assert_contains "$log" "trio-b $home/subject --harness codex --scout --model gpt-5.6-sol --effort xhigh" \
    "analyst B was not dispatched on its configured profile"
  assert_not_contains "$log" "trio-judge" "the judge must not be dispatched before the reports exist"
  assert_grep 'form=panel' "$home/data/trio/panel.meta" "the panel record does not say it is a panel"
  pass "analysts dispatch concurrently on the two configured models"
}

# Every other test in this file replaces fm-spawn.sh with a stub, so nothing here
# ever proved that what the panel ASKS the fleet to dispatch is what the fleet
# still ACCEPTS. This one drives the REAL fm-spawn.sh through the recipe
# tests/fm-spawn-dispatch-profile.test.sh uses - a fake tmux that captures the
# literal launch command, a faked treehouse, and a real isolated git worktree -
# so one command answers whether a panel can start on current source, without
# starting a backend or a harness.
test_panel_start_dispatches_through_the_real_spawn() {
  local case_dir home proj wt fakebin launchlog out status=0 meta
  case_dir="$TMP_ROOT/real-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$TWO_MODELS" > "$home/config/model-panel.json"
  fm_git_worktree "$proj" "$wt" wt-real-spawn
  touch "$home/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-panes) printf '%%1 1\n'; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *pane_id*) printf '%%1\n'; exit 0 ;; esac; done
    printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      [ "$prev" != "-l" ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      prev=$a
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  : > "$launchlog"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_DISPATCH_QUOTA_AXI=fm-test-absent-quota-axi \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-model-panel.sh" start --id realspawn --project "$proj" "Does a panel start?" 2>&1) \
    || status=$?
  expect_code 0 "$status" "a configured panel must start against the real dispatch mechanism: $out"
  assert_contains "$out" "dispatched: realspawn-a harness=claude model=claude-opus-5 effort=xhigh" \
    "the real spawn did not accept analyst A's resolved profile"
  assert_contains "$out" "dispatched: realspawn-b harness=codex model=gpt-5.6-sol effort=xhigh" \
    "the real spawn did not accept analyst B's resolved profile"
  meta="$home/state/realspawn-a.meta"
  assert_present "$meta" "the real spawn recorded no runtime record for analyst A"
  assert_grep 'harness=claude' "$meta" "analyst A's record does not carry its resolved harness"
  assert_grep 'model=claude-opus-5' "$meta" "analyst A's record does not carry its resolved model"
  assert_grep 'effort=xhigh' "$meta" "analyst A's record does not carry its resolved effort"
  assert_grep 'kind=scout' "$meta" "a panel member must be recorded as a scout"
  assert_grep "--model 'claude-opus-5' --effort 'xhigh'" "$launchlog" \
    "the launched command did not carry analyst A's resolved profile axes"
  assert_grep "data/realspawn-a/brief.md" "$launchlog" \
    "the launched command did not point analyst A at its brief"
  assert_absent "$home/state/realspawn-judge.meta" \
    "the judge must not be dispatched before the analyst reports exist"
  pass "a configured panel starts end to end against the real spawn"
}

test_pinned_object_lineup_needs_no_random_source() {
  local home out
  home=$(new_home pinned-objects-no-random "$TWO_MODELS")
  out=$(FM_DISPATCH_RANDOM_SOURCE="$TMP_ROOT/nonexistent-random-source" \
    run_panel "$home" start --id pnr --project "$home/subject" --dry-run "Anything?") \
    || fail "pinned object roles should not enter random selection: $out"
  assert_contains "$out" 'panel: analyst-a {"harness":"claude","model":"claude-opus-5","effort":"xhigh"}' \
    "the pinned analyst-A object did not resolve to itself"
  assert_contains "$out" 'panel: analyst-b {"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}' \
    "the pinned analyst-B object did not resolve to itself"
  assert_contains "$out" 'panel: judge {"harness":"grok","model":"grok-4-fast","effort":"high"}' \
    "the pinned judge object did not resolve to itself"
  assert_not_contains "$out" "OS-backed random source is unavailable" \
    "a pinned object role incorrectly entered random fallback"
  pass "pinned object roles resolve without quota or randomness"
}

test_distinct_analyst_arrays_resolve_to_different_models() {
  local home out
  home=$(new_home distinct-analyst-arrays "$DISTINCT_ANALYST_ARRAYS")
  out=$(run_panel "$home" start --id daa --project "$home/subject" --dry-run "Anything?") \
    || fail "distinct analyst arrays failed: $out"
  assert_contains "$out" '"model":"claude-opus-5"' \
    "the resolved lineup lost the Claude analyst"
  assert_contains "$out" '"model":"gpt-5.6-sol"' \
    "the resolved lineup lost the Codex analyst"
  assert_not_contains "$out" "this would not be a panel" \
    "distinct analyst arrays were incorrectly refused"
  pass "distinct analyst arrays still resolve to two different model identities"
}

test_analyst_array_collision_refuses_after_resolution() {
  local home out status=0
  home=$(new_home colliding-analyst-arrays "$ONE_MODEL_ANALYST_ARRAYS")
  out=$(run_panel "$home" start --id caa --project "$home/subject" --dry-run "Anything?") || status=$?
  expect_code 4 "$status" "analyst arrays resolving to one identity must refuse"
  assert_contains "$out" "both analysts resolve to the model claude-opus-5" \
    "the resolved analyst-array collision was not named"
  [ -z "$(spawn_log "$home")" ] || fail "a refused analyst-array panel must dispatch nothing"
  pass "analyst arrays cannot bypass the resolved-identity exit-4 refusal"
}

test_judge_array_collision_warns_after_resolution() {
  local home out
  home=$(new_home colliding-judge-array "$COLLIDING_JUDGE_ARRAY")
  out=$(run_panel "$home" start --id cja --project "$home/subject" --dry-run "Anything?") \
    || fail "a judge collision must keep the documented warning behavior: $out"
  assert_contains "$out" "no third distinct model is available" \
    "the resolved judge-array collision was silent"
  assert_contains "$out" "the same model as one analyst" \
    "the judge warning did not name the resolved collision"
  assert_contains "$out" "panel: judge" "the warned lineup did not resolve a concrete judge"
  pass "a judge-array collision is caught by the resolved-identity warning"
}

test_unpinned_analyst_refuses_unknown_runtime_identity() {
  local home out status config role id
  for config in "$UNPINNED_ANALYST_COLLISION" "$UNPINNED_ANALYST_B_COLLISION"; do
    case "$config" in
      "$UNPINNED_ANALYST_COLLISION") role=analyst_a; id=uaa ;;
      *) role=analyst_b; id=uab ;;
    esac
    status=0
    home=$(new_home "unpinned-$role" "$config")
    out=$(run_panel "$home" start --id "$id" --project "$home/subject" --dry-run "Anything?") || status=$?
    expect_code 4 "$status" "an unpinned $role must not be presented as a distinct model"
    assert_contains "$out" "$role resolves to a profile with no explicit model pin" \
      "the unpinned-$role refusal did not name the unknown identity"
    assert_contains "$out" "A harness name identifies a launcher, not the runtime model" \
      "the refusal did not explain why a harness placeholder is not identity"
    [ -z "$(spawn_log "$home")" ] || fail "an unpinned-analyst panel must dispatch nothing"
  done
  pass "neither analyst can turn a harness placeholder into a model identity"
}

test_analyst_a_array_prefers_a_pinned_identity() {
  local home out
  home=$(new_home mixed-analyst-a-array "$MIXED_ANALYST_A_ARRAY")
  out=$(FM_DISPATCH_RANDOM_SOURCE=/dev/zero run_panel "$home" start --id maa \
    --project "$home/subject" --dry-run "Anything?") \
    || fail "analyst A should prefer its pinned candidate: $out"
  assert_contains "$out" 'panel: analyst-a {"harness":"claude","model":"claude-opus-5"}' \
    "analyst A selected an unpinned default over a configured identity"
  pass "analyst A prefers a pinned candidate from a mixed array"
}

test_single_surviving_candidate_resolves_to_itself() {
  local home out fakebin marker
  home=$(new_home single-survivor "$MIXED_ANALYST_A_ARRAY")
  fakebin=$(fm_fakebin "$TMP_ROOT/single-survivor-quota")
  marker="$TMP_ROOT/single-survivor-quota/called"
  # run_panel points the selector's quota command at this name, so an executable
  # with that name proves whether a resolution consulted quota data at all.
  cat > "$fakebin/fm-test-absent-quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/fm-test-absent-quota-axi"
  out=$(PATH="$fakebin:$PATH" FM_DISPATCH_RANDOM_SOURCE="$TMP_ROOT/nonexistent-random-source" \
    run_panel "$home" start --id ssc --project "$home/subject" --dry-run "Anything?") \
    || fail "one surviving candidate should resolve without a random source: $out"
  assert_contains "$out" 'panel: analyst-a {"harness":"claude","model":"claude-opus-5"}' \
    "the sole surviving analyst-A candidate did not resolve to itself"
  assert_not_contains "$out" "OS-backed random source is unavailable" \
    "a seat with one candidate left entered random selection"
  assert_absent "$marker" "a seat with one candidate left consulted quota data"
  pass "a seat left with one candidate resolves to it without quota or randomness"
}

test_all_unpinned_analyst_a_array_still_refuses() {
  local home out status=0
  home=$(new_home all-unpinned-analyst-a-array "$ALL_UNPINNED_ANALYST_A_ARRAY")
  out=$(FM_DISPATCH_RANDOM_SOURCE=/dev/zero run_panel "$home" start --id aua \
    --project "$home/subject" --dry-run "Anything?") || status=$?
  expect_code 4 "$status" "an all-unpinned analyst-A array must still refuse"
  assert_contains "$out" "analyst_a resolves to a profile with no explicit model pin" \
    "the all-unpinned analyst-A array bypassed the role-specific refusal"
  pass "an all-unpinned analyst-A array still refuses"
}

test_invalid_array_candidate_refuses_in_every_seat() {
  local config home id out role status
  for config in "$INVALID_ANALYST_A_ARRAY" "$INVALID_ANALYST_B_ARRAY" "$INVALID_JUDGE_ARRAY"; do
    case "$config" in
      "$INVALID_ANALYST_A_ARRAY") role=analyst_a; id=iaa ;;
      "$INVALID_ANALYST_B_ARRAY") role=analyst_b; id=iab ;;
      *) role=judge; id=ija ;;
    esac
    home=$(new_home "invalid-$role-array" "$config")
    status=0
    out=$(FM_DISPATCH_RANDOM_SOURCE=/dev/zero run_panel "$home" start --id "$id" \
      --project "$home/subject" --dry-run "Anything?") || status=$?
    [ "$status" -ne 0 ] || fail "an invalid $role array candidate must prevent resolution"
    assert_contains "$out" "panel role $role could not be resolved" \
      "the invalid candidate was not attributed to $role"
    assert_contains "$out" "dispatch profile contains an unverified harness" \
      "the invalid $role candidate was hidden by identity filtering"
  done
  pass "an invalid array candidate invalidates every panel seat"
}

test_unpinned_judge_warns_without_model_self_report() {
  local home out fakebin marker
  home=$(new_home unpinned-judge "$UNPINNED_JUDGE_COLLISION")
  fakebin=$(fm_fakebin "$TMP_ROOT/unpinned-judge-self-report")
  marker="$TMP_ROOT/unpinned-judge-self-report/codex-called"
  cat > "$fakebin/codex" <<SH
#!/usr/bin/env bash
printf called > '$marker'
printf 'gpt-5.6-sol\n'
SH
  chmod +x "$fakebin/codex"
  out=$(PATH="$fakebin:$PATH" run_panel "$home" start --id uj --project "$home/subject" --dry-run "Anything?") \
    || fail "an unpinned judge must keep the documented warning behavior: $out"
  assert_contains "$out" "judge has no explicit model pin" \
    "the unpinned judge's unknown identity was silent"
  assert_contains "$out" "may be the same model as one analyst" \
    "the unpinned judge warning did not name the collision risk"
  assert_absent "$marker" "the panel asked the model to self-identify"
  pass "an unpinned judge warns without trusting a model self-report"
}

test_judge_array_prefers_a_known_unused_identity_over_unpinned_default() {
  local home out
  home=$(new_home unpinned-first-judge-array "$UNPINNED_FIRST_JUDGE_ARRAY")
  out=$(FM_DISPATCH_RANDOM_SOURCE=/dev/zero run_panel "$home" start --id uja \
    --project "$home/subject" --dry-run "Anything?") \
    || fail "a known unused judge candidate should remain selectable: $out"
  assert_contains "$out" 'panel: judge {"harness":"grok","model":"grok-4-fast"}' \
    "the judge array selected an unpinned default over a known unused identity"
  assert_not_contains "$out" "runtime model identity is unknown" \
    "a known unused judge candidate was incorrectly treated as unknown"
  pass "a judge array prefers a known unused identity over an unpinned default"
}

test_reduced_unpinned_seat_warns_without_claiming_independence() {
  local home out
  home=$(new_home reduced-unpinned "$REDUCED_UNPINNED_ANALYST")
  out=$(run_panel "$home" start --id rua --project "$home/subject" --reduced --dry-run "Anything?") \
    || fail "the reduced form should preserve its named degradation: $out"
  assert_contains "$out" "at least one reduced-form seat has no explicit model pin" \
    "the reduced form silently treated an unpinned seat as distinct"
  assert_contains "$out" "whether the judge shares the analyst's runtime model is unknown" \
    "the reduced warning did not explain its identity uncertainty"
  assert_contains "$out" "form=single-analyst-review" \
    "the unpinned reduced form was mislabeled as a panel"
  pass "the reduced form warns on unknown identity without claiming panel independence"
}

test_identical_analyst_models_refuse() {
  local home out status=0
  home=$(new_home identical-models "$ONE_MODEL")
  out=$(run_panel "$home" start --id solo --project "$home/subject" "Anything?") || status=$?
  expect_code 4 "$status" "an identical-model panel must refuse with the degraded-refusal status"
  assert_contains "$out" "this would not be a panel" "the refusal does not say why"
  assert_contains "$out" "--reduced" "the refusal does not offer the named reduced form"
  assert_contains "$out" "claude-opus-5" "the refusal does not name the duplicated model"
  [ -z "$(spawn_log "$home")" ] || fail "a refused panel must dispatch nothing"
  assert_absent "$home/data/solo" "a refused panel must leave no panel record behind"
  pass "a single-model home refuses rather than faking independence"
}

test_same_model_through_two_harnesses_refuses() {
  local home status=0 out
  home=$(new_home cross-harness "$ONE_MODEL_TWO_HARNESSES")
  out=$(run_panel "$home" start --id xh --project "$home/subject" "Anything?") || status=$?
  expect_code 4 "$status" "one model reached through two harnesses must still refuse"
  assert_contains "$out" "claude-opus-5" "the refusal does not name the shared model"
  pass "two harnesses onto one model are not treated as two models"
}

test_reduced_form_is_named_not_a_panel() {
  local home out log brief
  home=$(new_home reduced "$ONE_MODEL")
  out=$(run_panel "$home" start --id rd --project "$home/subject" --reduced "Anything?") \
    || fail "reduced start failed: $out"
  log=$(spawn_log "$home")
  assert_contains "$log" "rd-a " "the single analyst was not dispatched"
  assert_not_contains "$log" "rd-b " "the reduced form must not dispatch a second analyst"
  assert_grep 'form=single-analyst-review' "$home/data/rd/panel.meta" \
    "the reduced run must be recorded as a single-analyst review"
  brief="$home/data/rd-a/brief.md"
  assert_grep 'single-analyst review' "$brief" "the reduced analyst brief does not name the reduced form"
  assert_no_grep 'analyst A on a firstmate model panel' "$brief" \
    "the reduced analyst brief must not claim to be a panel"
  pass "the reduced form runs one analyst and is labelled as such"
}

test_analyst_briefs_share_the_question_and_forbid_peeking() {
  local home out brief_a brief_b question
  home=$(new_home independence "$TWO_MODELS")
  question="$TMP_ROOT/question.md"
  printf 'Line one of the question.\nLine two with detail.\n' > "$question"
  out=$(run_panel "$home" start --id ind --project "$home/subject" --question-file "$question") \
    || fail "start failed: $out"
  brief_a="$home/data/ind-a/brief.md"
  brief_b="$home/data/ind-b/brief.md"
  for brief in "$brief_a" "$brief_b"; do
    assert_grep 'Line one of the question.' "$brief" "an analyst brief lost the question"
    assert_grep 'Line two with detail.' "$brief" "an analyst brief truncated the question"
    assert_grep 'Verify status prose, never trust it' "$brief" \
      "an analyst brief lost the verify-status-prose discipline"
    assert_grep 'Check your vantage point' "$brief" "an analyst brief lost the vantage-point check"
    assert_grep 'Highest-conviction calls' "$brief" "an analyst brief lost the scored-calls contract"
    assert_grep 'Unresolved captain decisions' "$brief" "an analyst brief lost the decisions inventory"
    assert_grep 'decision-hold-lifecycle' "$brief" "an analyst brief lost the completion gate"
  done
  assert_grep "$home/data/ind-b/report.md" "$brief_a" "analyst A was not told which report to avoid"
  assert_grep "$home/data/ind-a/report.md" "$brief_b" "analyst B was not told which report to avoid"
  assert_grep 'Do not read their report at' "$brief_a" "analyst A was not forbidden to read the other report"
  assert_grep 'Do not read their report at' "$brief_b" "analyst B was not forbidden to read the other report"
  pass "both analysts get the identical question and an explicit independence rule"
}

# A panel member is handed a QUESTION to derive, not an asserted fact to act on,
# so every panel brief must carry the DECLARED-none premise state. The undeclared
# state tells its reader to append `blocked:` and stop, and `blocked:` is not a
# terminal event for this panel, so a complying member would leave no report and
# stand the panel down non-waivably with no firstmate to regenerate anything.
test_panel_briefs_declare_they_carry_no_premise() {
  local home out brief question
  home=$(new_home premise "$TWO_MODELS")
  question="$TMP_ROOT/premise-question.md"
  printf 'Why does the deploy stall?\n' > "$question"
  out=$(run_panel "$home" start --id prem --project "$home/subject" --question-file "$question") \
    || fail "start failed: $out"

  printf 'analyst a findings\n' > "$home/data/prem-a/report.md"
  printf 'analyst b findings\n' > "$home/data/prem-b/report.md"
  say_status "$home" prem-a 'done: analysed'
  say_status "$home" prem-b 'done: analysed'
  out=$(run_panel "$home" advance prem) || fail "advance failed: $out"

  for brief in "$home/data/prem-a/brief.md" "$home/data/prem-b/brief.md" \
    "$home/data/prem-judge/brief.md"; do
    assert_present "$brief" "a panel brief was not scaffolded"
    assert_grep '# Premise declaration - DECLARED NONE' "$brief" \
      "a panel brief does not declare that it carries no premise"
    assert_no_grep '# Premise declaration - NONE ASSERTED' "$brief" \
      "a panel brief left its premise state undeclared"
    assert_no_grep 'append `blocked: brief asserts a fact but was scaffolded without --premise`' "$brief" \
      "a panel brief tells its member to stop with a status the panel never treats as terminal"
    # The question is the thing to DERIVE, so it must not be restated as an
    # assertion to disprove. It still reaches the member inside the task text.
    assert_no_grep '# The premise this brief asserts' "$brief" \
      "a panel brief reframed its question as an asserted premise"
    assert_grep 'Why does the deploy stall?' "$brief" "a panel brief lost the question"
  done
  pass "every panel brief declares it carries no premise to disprove"
}

test_judge_waits_for_every_report_then_gets_both() {
  local home out log brief
  home=$(new_home judge-gate "$TWO_MODELS")
  out=$(run_panel "$home" start --id jg --project "$home/subject" "Which claim holds up?") \
    || fail "start failed: $out"

  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "advance must wait while a report is missing"
  assert_not_contains "$(spawn_log "$home")" "jg-judge" "the judge must not be dispatched early"

  printf 'analyst a findings\n' > "$home/data/jg-a/report.md"
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "advance must still wait while the second report is missing"
  assert_contains "$out" "jg-b" "the waiting line must name the analyst with no report"
  assert_not_contains "$(spawn_log "$home")" "jg-judge" "the judge must wait for every analyst report"

  # Both reports EXIST now, but neither analyst has said it is finished. A file
  # that exists is not a file that is finished, so this must still wait, and a
  # nonterminal progress line must not be mistaken for a terminal event. Both
  # analysts are still present, so this is the ordinary write-then-declare window
  # and the override must not be advertised in it.
  printf 'analyst b findings\n' > "$home/data/jg-b/report.md"
  say_status "$home" jg-a 'working: still drafting'
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "the ordinary write-then-declare window must print the plain waiting line"
  assert_contains "$out" "terminal status event" "the outcome must name the missing terminal event"
  assert_contains "$out" "jg-a" "the outcome must name the analyst that has not finished"
  assert_not_contains "$out" "--accept-unfinished" \
    "the override must not be advertised while the analyst is still present and may be writing"
  assert_not_contains "$(spawn_log "$home")" "jg-judge" \
    "the judge must not be dispatched against a report whose analyst is still writing"

  say_status "$home" jg-a 'done: analyst a finished'
  say_status "$home" jg-b 'done: analyst b finished'
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  log=$(spawn_log "$home")
  assert_contains "$log" "jg-judge $home/subject --harness grok --scout --model grok-4-fast --effort high" \
    "the judge was not dispatched on its configured profile"
  assert_grep 'stage=judge' "$home/data/jg/panel.meta" "the panel record did not advance to the judge stage"

  brief="$home/data/jg-judge/brief.md"
  assert_grep "$home/data/jg-a/report.md" "$brief" "the judge was not given analyst A's report"
  assert_grep "$home/data/jg-b/report.md" "$brief" "the judge was not given analyst B's report"
  assert_grep 'Re-verify, do not referee' "$brief" "the judge brief lost its re-verification instruction"
  assert_grep 'Verify status prose, never trust it' "$brief" \
    "the judge brief lost the verify-status-prose discipline"
  assert_grep 'Scored highest-conviction calls' "$brief" "the judge brief lost the scoring contract"
  assert_grep 'Shared mistakes' "$brief" "the judge brief lost the shared-mistake hunt"
  assert_grep 'Unresolved captain decisions' "$brief" "the judge brief lost the decisions inventory"
  assert_grep 'decision-hold-lifecycle' "$brief" "the judge brief lost the completion gate"
  assert_no_grep 'claude-opus-5' "$brief" "the judge must not be told which model wrote which report"
  assert_no_grep 'gpt-5.6-sol' "$brief" "the judge must not be told which model wrote which report"

  # The judge's own report passes the SAME two-condition gate: a report that
  # exists is not a report that is finished, on the final hop either.
  printf 'partial verdict\n' > "$home/data/jg-judge/report.md"
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "a half-written judge report must not complete the panel"
  assert_not_contains "$out" "complete:" "a half-written judge report must not complete the panel"
  assert_contains "$out" "jg-judge" "the outcome must name the judge that has not finished"
  assert_no_grep 'stage=complete' "$home/data/jg/panel.meta" \
    "the panel must not record itself complete over an unfinished judge"

  say_status "$home" jg-judge 'done: verdict written'
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "complete: $home/data/jg-judge/report.md" \
    "a finished panel does not report its judge report path"
  assert_not_contains "$out" "CAVEAT" "a panel nobody overrode must not carry an accepted-unfinished caveat"
  assert_grep 'stage=complete' "$home/data/jg/panel.meta" "the panel record did not reach the complete stage"
  pass "the judge is created only once every analyst report exists, and sees both blind"
}

test_terminal_member_without_a_report_stands_the_panel_down() {
  local home out status=0
  home=$(new_home stand-down "$TWO_MODELS")
  out=$(run_panel "$home" start --id sd --project "$home/subject" "Anything?") \
    || fail "start failed: $out"

  # A member that ended terminal with no report has stopped writing, so no report
  # can arrive: the panel's premise has failed and it cannot be waited out.
  printf 'analyst a findings\n' > "$home/data/sd-a/report.md"
  say_status "$home" sd-a 'done: analyst a finished'
  say_status "$home" sd-b 'failed: ran out of budget before writing anything'
  out=$(run_panel "$home" advance sd) || status=$?
  [ "$status" -ne 0 ] || fail "a panel that can never complete must not report success"
  assert_contains "$out" "stood down:" "a member that finished with no report must not print the bland waiting line"
  assert_contains "$out" "sd-b" "the stand-down block must name the member that left no report"
  assert_contains "$out" "Stand this panel down" "the stand-down block must name the operator's action"
  assert_contains "$out" "--reduced" "the stand-down block must name the deliberate salvage path"
  assert_not_contains "$out" "next step is" "a dead panel must not hint at a next advance"
  assert_grep 'stage=stood-down' "$home/data/sd/panel.meta" "the dead panel was not recorded durably"
  assert_grep 'stood_down=sd-b' "$home/data/sd/panel.meta" "the record does not name the member that killed the panel"
  assert_not_contains "$(spawn_log "$home")" "sd-judge" "a stood-down panel must never dispatch a judge"

  # Idempotent: the recorded stand-down keeps saying the same thing.
  status=0
  out=$(run_panel "$home" advance sd) || status=$?
  [ "$status" -ne 0 ] || fail "a recorded stand-down must keep reporting failure"
  assert_contains "$out" "stood down:" "the recorded stand-down must re-print its block"
  assert_contains "$out" "sd-b" "the recorded stand-down must keep naming the member"

  # The override never manufactures a panel out of the one report that survived.
  status=0
  out=$(run_panel "$home" advance sd --accept-unfinished sd-b) || status=$?
  [ "$status" -ne 0 ] || fail "a missing report must never be waivable"
  assert_no_grep 'accepted_unfinished' "$home/data/sd/panel.meta" \
    "a stood-down panel must not record an acceptance it can never use"
  pass "a member that finishes with no report stands the panel down, durably and unwaivably"
}

test_gone_analyst_with_nothing_stands_the_panel_down() {
  local home out status=0
  home=$(new_home gone-empty "$TWO_MODELS")
  out=$(run_panel "$home" start --id ge --project "$home/subject" "Anything?") \
    || fail "start failed: $out"

  # Both analysts were just dispatched and still hold their runtime records, so
  # this is the ordinary early window and must stay a plain wait.
  out=$(run_panel "$home" advance ge) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "a member that has only just started must still be a plain wait"
  assert_not_contains "$out" "stood down:" "the early window must not be mistaken for a member that is gone"
  assert_not_contains "$out" "--accept-unfinished" "the early window must not advertise the override"

  # Analyst B is torn down before writing anything, and teardown removes its
  # status file and runtime record together, so nothing further can ever arrive.
  printf 'analyst a findings\n' > "$home/data/ge-a/report.md"
  say_status "$home" ge-a 'done: a finished'
  rm -f "$home/state/ge-b.status" "$home/state/ge-b.meta"
  out=$(run_panel "$home" advance ge) || status=$?
  [ "$status" -ne 0 ] || fail "a panel whose analyst is gone with nothing must not report success"
  assert_contains "$out" "stood down:" "a gone analyst that produced nothing must not wait forever"
  assert_contains "$out" "ge-b" "the stand-down must name the analyst that produced nothing"
  assert_not_contains "$out" "next step is" "a dead panel must not hint at a next advance"
  assert_grep 'stage=stood-down' "$home/data/ge/panel.meta" "the dead panel was not recorded durably"
  assert_grep 'stood_down=ge-b' "$home/data/ge/panel.meta" "the record does not name the member that killed the panel"
  assert_not_contains "$(spawn_log "$home")" "ge-judge" "a stood-down panel must never dispatch a judge"
  pass "an analyst that is gone having produced nothing stands the panel down instead of waiting forever"
}

test_gone_judge_with_nothing_offers_the_rejudge() {
  local home out
  home=$(new_home gone-judge "$TWO_MODELS")
  out=$(run_panel "$home" start --id gj --project "$home/subject" "Anything?") \
    || fail "start failed: $out"
  printf 'analyst a findings\n' > "$home/data/gj-a/report.md"
  printf 'analyst b findings\n' > "$home/data/gj-b/report.md"
  say_status "$home" gj-a 'done: a finished'
  say_status "$home" gj-b 'done: b finished'
  out=$(run_panel "$home" advance gj) || fail "advance failed: $out"

  # The judge is torn down before writing anything. The evidence is intact, so
  # this is the same lost verdict as a judge that declared itself finished.
  rm -f "$home/state/gj-judge.status" "$home/state/gj-judge.meta"
  out=$(run_panel "$home" advance gj) \
    || fail "a panel that only lost its verdict must not report failure: $out"
  assert_contains "$out" "verdict lost:" "a gone judge that produced nothing must be offered the re-judge"
  assert_not_contains "$out" "stood down:" "a healthy panel must not be stood down over its judge"
  assert_contains "$out" "advance gj --rejudge" "the block must print the exact re-judge command"
  assert_no_grep 'stage=stood-down' "$home/data/gj/panel.meta" "a healthy panel must not be recorded dead"

  out=$(run_panel "$home" advance gj --rejudge) || fail "the re-judge must be permitted for a gone judge: $out"
  assert_contains "$(spawn_log "$home")" "gj-judge2 " "the offered re-judge must actually dispatch"
  assert_grep 'superseded_judges=gj-judge' "$home/data/gj/panel.meta" "the superseded judge was not recorded"
  assert_no_grep 'accepted_unfinished' "$home/data/gj/panel.meta" \
    "replacing a gone judge must not stamp the analysts' complete reports"
  pass "a judge that is gone having produced nothing is offered the re-judge the state actually permits"
}

test_readiness_latch_survives_teardown() {
  local home out status=0
  home=$(new_home latch "$TWO_MODELS")
  out=$(run_panel "$home" start --id lt --project "$home/subject" "Anything?") \
    || fail "start failed: $out"
  printf 'analyst a findings\n' > "$home/data/lt-a/report.md"
  say_status "$home" lt-a 'done: a finished'

  # The first observation latches lt-a even while the panel waits for lt-b.
  out=$(run_panel "$home" advance lt) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "the panel must still wait for the second analyst"
  assert_grep 'ready_members=lt-a' "$home/data/lt/panel.meta" \
    "readiness was not latched on first observation"

  # Real teardown removes the status file and the runtime record together, so a
  # gate that re-derived readiness from state/ would now call lt-a wedged.
  rm -f "$home/state/lt-a.status" "$home/state/lt-a.meta"
  out=$(run_panel "$home" advance lt) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "a torn-down member that was observed ready must not change the outcome"
  assert_not_contains "$out" "wedged:" "a torn-down member that was observed ready must not become wedged"
  assert_not_contains "$out" "lt-a" "a latched member must not be reported as missing anything"
  assert_not_contains "$out" "--accept-unfinished" "a latched member must never be offered the override"

  out=$(run_panel "$home" advance lt --accept-unfinished lt-a) || status=$?
  expect_code 2 "$status" "a member already observed ready must not be waivable"
  assert_contains "$out" "nothing to waive" "the refusal must say the report was already finished"
  assert_no_grep 'accepted_unfinished' "$home/data/lt/panel.meta" \
    "a refused override must never stamp a complete report"

  printf 'analyst b findings\n' > "$home/data/lt-b/report.md"
  say_status "$home" lt-b 'done: b finished'
  out=$(run_panel "$home" advance lt) || fail "advance failed: $out"
  assert_contains "$(spawn_log "$home")" "lt-judge " "the judge must be dispatched on the latched readiness"
  assert_no_grep 'accepted_unfinished' "$home/data/lt/panel.meta" \
    "no acceptance may be recorded for members that finished properly"
  assert_no_grep 'Reports accepted without their author finishing' "$home/data/lt-judge/brief.md" \
    "the judge brief must never call a complete report possibly incomplete"
  pass "readiness is latched on first observation and survives teardown of the status file"
}

test_judge_without_a_verdict_offers_a_recorded_rejudge() {
  local home out log status=0
  home=$(new_home rejudge "$TWO_MODELS")
  out=$(run_panel "$home" start --id rj --project "$home/subject" "Anything?") \
    || fail "start failed: $out"
  printf 'analyst a findings\n' > "$home/data/rj-a/report.md"
  printf 'analyst b findings\n' > "$home/data/rj-b/report.md"
  say_status "$home" rj-a 'done: a finished'
  say_status "$home" rj-b 'done: b finished'
  out=$(run_panel "$home" advance rj) || fail "advance failed: $out"

  # A judge that still looks live must not be superseded out from under itself.
  out=$(run_panel "$home" advance rj --rejudge) || status=$?
  expect_code 2 "$status" "re-judging a judge that still looks live must be refused"
  assert_contains "$out" "rj-judge" "the refusal must name the judge it will not replace"
  assert_contains "$out" "appears to be running" "the refusal must say why it refuses"
  assert_contains "$out" "tear it down" "the refusal must name what the operator can do instead"
  assert_not_contains "$(spawn_log "$home")" "rj-judge2" "a refused re-judge must dispatch nothing"
  assert_no_grep 'superseded_judges' "$home/data/rj/panel.meta" "a refused re-judge must record nothing"
  assert_grep 'judge_task=rj-judge' "$home/data/rj/panel.meta" "a refused re-judge must leave the judge in place"

  # The judge dies without a verdict. The evidence is complete and untouched, so
  # this must not discard two finished investigations.
  say_status "$home" rj-judge 'failed: ran out of budget'
  out=$(run_panel "$home" advance rj) \
    || fail "a panel that only lost its verdict must not report failure: $out"
  assert_contains "$out" "verdict lost:" "a reportless judge must not print the analyst stand-down"
  assert_not_contains "$out" "stood down:" "a healthy panel must not be stood down over its judge"
  assert_contains "$out" "rj-judge" "the block must name the judge that left no verdict"
  assert_contains "$out" "advance rj --rejudge" "the block must print the exact re-judge command"
  assert_no_grep 'stage=stood-down' "$home/data/rj/panel.meta" "a healthy panel must not be recorded dead"

  out=$(run_panel "$home" advance rj --rejudge) || fail "rejudge failed: $out"
  log=$(spawn_log "$home")
  assert_contains "$log" "rj-judge2 $home/subject --harness grok --scout --model grok-4-fast --effort high" \
    "the replacement judge was not dispatched on the judge profile"
  assert_grep 'judge_task=rj-judge2' "$home/data/rj/panel.meta" "the record does not point at the replacement judge"
  assert_grep 'superseded_judges=rj-judge' "$home/data/rj/panel.meta" "the superseded judge was not recorded"
  assert_no_grep 'accepted_unfinished' "$home/data/rj/panel.meta" \
    "replacing a judge must not stamp the analysts' complete reports"
  assert_grep "$home/data/rj-a/report.md" "$home/data/rj-judge2/brief.md" \
    "the replacement judge was not given the unchanged analyst reports"
  assert_no_grep 'Reports accepted without their author finishing' "$home/data/rj-judge2/brief.md" \
    "the replacement judge must not be told a complete report is truncated"
  assert_grep 'analyst a findings' "$home/data/rj-a/report.md" "the analyst reports must be left untouched"

  printf 'verdict\n' > "$home/data/rj-judge2/report.md"
  say_status "$home" rj-judge2 'done: verdict written'
  out=$(run_panel "$home" advance rj --rejudge) || status=$?
  expect_code 2 "$status" "re-judging a judge that left a verdict must be refused"
  assert_contains "$out" "nothing to re-judge" "the refusal must say a verdict already exists"

  out=$(run_panel "$home" advance rj) || fail "advance failed: $out"
  assert_contains "$out" "complete: $home/data/rj-judge2/report.md" \
    "the replacement judge must be able to complete the panel"
  assert_not_contains "$out" "CAVEAT" "a replaced judge is not an accepted-unfinished one"
  pass "a judge that leaves no verdict is replaced by an explicit recorded re-judge"
}

test_rejudge_replaces_a_torn_down_judge_and_records_only_after_dispatch() {
  local home out status=0
  home=$(new_home rejudge-torndown "$TWO_MODELS")
  out=$(run_panel "$home" start --id rf --project "$home/subject" "Anything?") \
    || fail "start failed: $out"
  printf 'analyst a findings\n' > "$home/data/rf-a/report.md"
  printf 'analyst b findings\n' > "$home/data/rf-b/report.md"
  say_status "$home" rf-a 'done: a finished'
  say_status "$home" rf-b 'done: b finished'
  out=$(run_panel "$home" advance rf) || fail "advance failed: $out"

  # Real teardown removes the status file and the runtime record together, so a
  # torn-down judge has neither. It must still be replaceable: a precondition
  # that required the status file would make it unreplaceable forever.
  rm -f "$home/state/rf-judge.status" "$home/state/rf-judge.meta"

  # A replacement whose dispatch fails must leave the record exactly as it was.
  out=$(FM_FAKE_SPAWN_FAIL_ID=rf-judge2 run_panel "$home" advance rf --rejudge) || status=$?
  [ "$status" -ne 0 ] || fail "a failed replacement dispatch must not report success"
  assert_no_grep 'superseded_judges' "$home/data/rf/panel.meta" \
    "a failed replacement dispatch must not record a supersede that did not happen"
  assert_grep 'judge_task=rf-judge' "$home/data/rf/panel.meta" \
    "a failed replacement dispatch must leave judge_task naming the original judge"

  out=$(run_panel "$home" advance rf --rejudge) || fail "rejudge of a torn-down judge failed: $out"
  assert_contains "$(spawn_log "$home")" "rf-judge2 " "a torn-down judge must be replaceable"
  assert_grep 'judge_task=rf-judge2' "$home/data/rf/panel.meta" "the record does not point at the replacement judge"
  assert_grep 'superseded_judges=rf-judge' "$home/data/rf/panel.meta" "the superseded judge was not recorded"
  assert_no_grep 'accepted_unfinished' "$home/data/rf/panel.meta" \
    "replacing a torn-down judge must not stamp any report"
  pass "a torn-down judge is replaceable, and the record is written only after the dispatch succeeds"
}

test_generated_task_ids_stay_within_the_task_id_limit() {
  local home out id longest=panel-id-length-check status=0
  home=$(new_home id-length "$TWO_MODELS")
  while [ "${#longest}" -lt 56 ]; do longest="${longest}x"; done
  out=$(run_panel "$home" start --id "$longest" --project "$home/subject" "Anything?") \
    || fail "the documented maximum panel id must be accepted: $out"
  for id in "$longest-a" "$longest-b" "$longest-judge" "$longest-judge99"; do
    [ "${#id}" -le 64 ] || fail "generated task id $id exceeds the 64-character limit (${#id})"
  done

  out=$(run_panel "$home" start --id "${longest}x" --project "$home/subject" "Anything?") || status=$?
  expect_code 2 "$status" "a panel id one character over the cap must be refused"
  assert_contains "$out" "64 characters" "the refusal must name the task-id limit"
  pass "every generated task id stays within the 64-character task-id limit"
}

test_accepted_judge_caveat_repeats_on_every_complete() {
  local home out
  home=$(new_home judge-caveat "$TWO_MODELS")
  out=$(run_panel "$home" start --id jc --project "$home/subject" "Anything?") \
    || fail "start failed: $out"
  printf 'analyst a findings\n' > "$home/data/jc-a/report.md"
  printf 'analyst b findings\n' > "$home/data/jc-b/report.md"
  say_status "$home" jc-a 'done: a finished'
  say_status "$home" jc-b 'done: b finished'
  out=$(run_panel "$home" advance jc) || fail "advance failed: $out"

  # The judge wrote a verdict and was then torn down without declaring itself
  # finished, so the operator accepts it explicitly.
  printf 'partial verdict\n' > "$home/data/jc-judge/report.md"
  rm -f "$home/state/jc-judge.meta"
  out=$(run_panel "$home" advance jc --accept-unfinished jc-judge) || fail "advance failed: $out"
  assert_contains "$out" "complete: $home/data/jc-judge/report.md" "the accepted judge must complete the panel"
  assert_contains "$out" "CAVEAT" "the completing invocation must carry the caveat"

  # A later idempotent advance reads on a fresh context and must say the same.
  out=$(run_panel "$home" advance jc) || fail "advance failed: $out"
  assert_contains "$out" "complete: $home/data/jc-judge/report.md" "the repeat advance must still report completion"
  assert_contains "$out" "CAVEAT" "every complete: output must carry the caveat, not only the one that recorded it"
  assert_contains "$out" "jc-judge" "the caveat must name the member whose report may be incomplete"
  pass "an accepted judge report carries its caveat on every complete: output"
}

test_acceptance_is_not_recorded_when_the_stage_cannot_use_it() {
  local home out status=0
  home=$(new_home accept-stage "$TWO_MODELS")
  out=$(FM_FAKE_SPAWN_FAIL_ID=as-b run_panel "$home" start --id as --project "$home/subject" "Anything?") \
    || status=$?
  [ "$status" -ne 0 ] || fail "a failed analyst dispatch must not report success"
  printf 'analyst a findings\n' > "$home/data/as-a/report.md"

  status=0
  out=$(run_panel "$home" advance as --accept-unfinished as-a) || status=$?
  [ "$status" -ne 0 ] || fail "advance must still refuse a panel that never finished dispatching"
  assert_contains "$out" "never finished dispatching" "the stage refusal must still be the reported failure"
  assert_no_grep 'accepted_unfinished' "$home/data/as/panel.meta" \
    "an acceptance the stage can never use must not be recorded as verdict provenance"
  pass "an acceptance is recorded only on a stage that can actually use it"
}

test_wedged_member_names_its_override_and_the_override_is_per_member() {
  local home out brief
  home=$(new_home wedged "$TWO_MODELS")
  out=$(run_panel "$home" start --id wd --project "$home/subject" "Which claim holds up?") \
    || fail "start failed: $out"

  # Both analysts left a report and were then torn down without ever signalling
  # that they finished: the one state that can never clear on its own.
  printf 'analyst a findings\n' > "$home/data/wd-a/report.md"
  printf 'analyst b findings\n' > "$home/data/wd-b/report.md"
  out=$(run_panel "$home" advance wd) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "a member that is still present is in the ordinary window, not wedged"
  assert_not_contains "$out" "--accept-unfinished" \
    "the override must not be advertised while both analysts are still present"

  rm -f "$home/state/wd-a.meta" "$home/state/wd-b.meta"
  out=$(run_panel "$home" advance wd) || fail "advance failed: $out"
  assert_contains "$out" "wedged:" "a member with a report and no runtime record left must not print the bland waiting line"
  assert_contains "$out" "torn down or died" "the wedged block must say why the terminal line will never arrive"
  assert_contains "$out" "wd-a" "the wedged block must name the wedged member"
  assert_contains "$out" "advance wd --accept-unfinished wd-a" \
    "the wedged block must print the exact override command"
  assert_contains "$out" "INCOMPLETE" "the wedged block must say the accepted report may be incomplete"
  assert_contains "$out" "no timeout" "the wedged block must say nothing advances on its own"

  # Per-member: accepting one analyst waives nothing for the other.
  out=$(run_panel "$home" advance wd --accept-unfinished wd-a) || fail "advance failed: $out"
  assert_contains "$out" "wedged:" "overriding one member must not waive the gate for another"
  assert_contains "$out" "wd-b" "the still-wedged member must still be named"
  assert_not_contains "$out" "advance wd --accept-unfinished wd-a" \
    "an already-accepted member must not still be offered the override"
  assert_not_contains "$(spawn_log "$home")" "wd-judge" \
    "one accepted member must not be enough to dispatch the judge"
  assert_grep 'accepted_unfinished=wd-a' "$home/data/wd/panel.meta" \
    "the override was not recorded durably in the panel record"

  out=$(run_panel "$home" advance wd --accept-unfinished wd-b) || fail "advance failed: $out"
  assert_contains "$(spawn_log "$home")" "wd-judge " "accepting every member must let the judge be dispatched"
  assert_grep 'accepted_unfinished=wd-a wd-b' "$home/data/wd/panel.meta" \
    "the panel record must carry every accepted member"

  brief="$home/data/wd-judge/brief.md"
  assert_grep 'Reports accepted without their author finishing' "$brief" \
    "the judge brief does not disclose that a report was accepted unfinished"
  assert_grep "- Analyst A: \`$home/data/wd-a/report.md\`" "$brief" \
    "the judge brief does not name the possibly incomplete report"
  assert_grep 'truncated or incomplete' "$brief" \
    "the judge brief does not tell the judge to treat that report as possibly incomplete"
  assert_no_grep 'claude-opus-5' "$brief" "disclosing completeness must not disclose the model"
  assert_no_grep 'gpt-5.6-sol' "$brief" "disclosing completeness must not disclose the model"
  pass "the wedge names its per-member override, which is recorded and disclosed to the judge"
}

test_accept_unfinished_refuses_a_nonmember_and_a_missing_report() {
  local home out status=0
  home=$(new_home accept-guard "$TWO_MODELS")
  out=$(run_panel "$home" start --id ag --project "$home/subject" "Anything?") \
    || fail "start failed: $out"

  out=$(run_panel "$home" advance ag --accept-unfinished not-a-member) || status=$?
  expect_code 2 "$status" "accepting a task that is not a panel member must be a usage error"
  assert_contains "$out" "not a member" "the refusal does not say the task is not a panel member"
  assert_no_grep 'accepted_unfinished' "$home/data/ag/panel.meta" \
    "a refused override must not be recorded"

  status=0
  out=$(run_panel "$home" advance ag --accept-unfinished ag-a) || status=$?
  expect_code 2 "$status" "accepting a member with no report at all must be a usage error"
  assert_contains "$out" "nothing to accept" "the refusal does not say there is no report to accept"
  assert_no_grep 'accepted_unfinished' "$home/data/ag/panel.meta" \
    "a refused override must not be recorded"
  pass "the override refuses a non-member and refuses to waive a report that does not exist"
}

test_failed_analyst_with_a_report_still_reaches_the_judge() {
  local home out
  home=$(new_home failed-analyst "$ONE_MODEL")
  out=$(run_panel "$home" start --id fa --project "$home/subject" --reduced "Anything?") \
    || fail "reduced start failed: $out"

  # The reduced form's single analyst is gated exactly like a panel's two.
  printf 'partial findings\n' > "$home/data/fa-a/report.md"
  out=$(run_panel "$home" advance fa) || fail "advance failed: $out"
  assert_contains "$out" "waiting:" "the single analyst of the reduced form must be gated too"
  assert_contains "$out" "fa-a" "the waiting line must name the single analyst"
  assert_not_contains "$(spawn_log "$home")" "fa-judge" \
    "the reduced form must not dispatch the judge before its analyst has finished"

  # The gate asks whether the analyst stopped writing, not whether it succeeded.
  say_status "$home" fa-a 'failed: ran out of budget partway'
  out=$(run_panel "$home" advance fa) || fail "advance failed: $out"
  assert_contains "$(spawn_log "$home")" "fa-judge " \
    "a failed analyst that still left a report must reach the judge"
  assert_grep 'stage=judge' "$home/data/fa/panel.meta" \
    "the panel record did not advance to the judge stage after a terminal failure"
  pass "failed: is terminal too, and the reduced form's single analyst is gated the same way"
}

test_crew_dispatch_default_is_the_documented_fallback() {
  local home out log
  home=$(new_home crew-fallback)
  printf '%s\n' '{"default":[{"harness":"claude","model":"claude-opus-5"},{"harness":"codex","model":"gpt-5.6-sol"}]}' \
    > "$home/config/crew-dispatch.json"
  out=$(run_panel "$home" start --id cd --project "$home/subject" "Fallback?") \
    || fail "start failed: $out"
  log=$(spawn_log "$home")
  assert_contains "$log" "cd-a " "analyst A was not dispatched from the crew-dispatch default"
  assert_contains "$log" "cd-b " "analyst B was not dispatched from the crew-dispatch default"
  case "$log" in
    *"claude-opus-5"*) : ;;
    *) fail "the crew-dispatch fallback did not use a configured model" ;;
  esac
  case "$log" in
    *"gpt-5.6-sol"*) : ;;
    *) fail "the crew-dispatch fallback did not pick a second distinct model for analyst B" ;;
  esac
  pass "an unconfigured home falls back to the crew-dispatch default profile set"
}

test_no_configuration_refuses_with_every_source_named() {
  local home status=0 out
  home=$(new_home unconfigured)
  # `unknown` is fm-harness.sh's sentinel for a harness it could not detect, so
  # this home genuinely has no dispatch source at any of the three hops.
  printf 'unknown\n' > "$home/config/crew-harness"
  out=$(run_panel "$home" start --id nc --project "$home/subject" "Anything?") || status=$?
  [ "$status" -ne 0 ] || fail "a home with no dispatch source must not silently invent a lineup"
  assert_contains "$out" "model-panel.json" "the refusal does not name the panel configuration file"
  assert_contains "$out" "crew-dispatch.json" "the refusal does not name the fallback configuration file"
  assert_contains "$out" "crew-harness" "the refusal does not name the static crewmate harness"
  assert_not_contains "$out" "dispatch input must be" \
    "a missing profile leaked the selector's internal parse error over the actionable refusal"
  pass "a home with no dispatch source at all refuses and names every source"
}

# The defect this file could not see: fm-spawn.sh's own last resort when neither
# profile file exists is the static crewmate harness, and the panel used to stop
# one hop short of it, so a home that dispatched crew perfectly well could not
# start a panel at all - and failed mechanically rather than honestly.
test_static_crew_harness_backs_the_panel_and_still_refuses_honestly() {
  local home status=0 out
  home=$(new_home static-harness)
  printf 'claude\n' > "$home/config/crew-harness"
  out=$(run_panel "$home" start --id sh --project "$home/subject" "Anything?") || status=$?
  expect_code 4 "$status" "an unpinned static-harness lineup must refuse as not-a-panel"
  assert_contains "$out" "would not be a panel" \
    "the static-harness fallback did not reach the honest unpinned-analyst refusal"
  assert_not_contains "$out" "no profile for panel role" \
    "the static crewmate harness did not fill the seat"
  assert_not_contains "$out" "dispatch input must be" \
    "the refusal leaked the selector's internal parse error"
  [ -z "$(spawn_log "$home")" ] || fail "a refused panel must dispatch nothing"
  pass "a home configured only with a crewmate harness refuses as not-a-panel, not mechanically"
}

test_static_crew_harness_runs_the_reduced_form() {
  local home out log
  home=$(new_home static-harness-reduced)
  printf 'claude\n' > "$home/config/crew-harness"
  out=$(run_panel "$home" start --id shr --project "$home/subject" --reduced "Anything?") \
    || fail "the reduced form must run on a home whose dispatch is the static crewmate harness: $out"
  assert_contains "$out" "no explicit model pin" \
    "the reduced form did not warn that the seat's runtime identity is unknown"
  log=$(spawn_log "$home")
  assert_contains "$log" "shr-a $home/subject --harness claude --scout" \
    "the analyst was not dispatched on the static crewmate harness"
  assert_not_contains "$log" "--model" \
    "a harness with no model pin must not be dispatched with an invented model"
  pass "the reduced form runs on a home whose only dispatch source is the crewmate harness"
}

test_dry_run_shows_the_lineup_without_spending_anything() {
  local home out
  home=$(new_home dry-run "$TWO_MODELS")
  out=$(run_panel "$home" start --id dr --project "$home/subject" --dry-run "Anything?") \
    || fail "dry run failed: $out"
  assert_contains "$out" "claude-opus-5" "the dry run does not show the analyst A model"
  assert_contains "$out" "gpt-5.6-sol" "the dry run does not show the analyst B model"
  assert_contains "$out" "grok-4-fast" "the dry run does not show the judge model"
  [ -z "$(spawn_log "$home")" ] || fail "a dry run must dispatch nothing"
  assert_absent "$home/data/dr" "a dry run must write no panel record"
  pass "the dry run shows the resolved lineup and changes nothing"
}

test_failed_second_dispatch_is_reported_and_blocks_advance() {
  local home status=0 out
  home=$(new_home partial-dispatch "$TWO_MODELS")
  out=$(FM_FAKE_SPAWN_FAIL_ID=pd-b run_panel "$home" start --id pd --project "$home/subject" "Anything?") \
    || status=$?
  [ "$status" -ne 0 ] || fail "a failed analyst dispatch must not report success"
  assert_contains "$out" "pd-a" "the failure does not name the analyst that is already running"
  assert_grep 'stage=incomplete' "$home/data/pd/panel.meta" \
    "a half-dispatched panel must record that it never finished dispatching"
  status=0
  out=$(run_panel "$home" advance pd) || status=$?
  [ "$status" -ne 0 ] || fail "advance must refuse a panel that never finished dispatching"
  pass "a half-dispatched panel reports the failure and refuses to advance"
}

test_failed_first_dispatch_records_incomplete() {
  local home status=0 out
  home=$(new_home first-dispatch "$TWO_MODELS")
  out=$(FM_FAKE_SPAWN_FAIL_ID=fd-a run_panel "$home" start --id fd --project "$home/subject" "Anything?") \
    || status=$?
  [ "$status" -ne 0 ] || fail "a failed first dispatch must not report success"
  assert_contains "$out" "fd-a" "the failure does not name the analyst that never dispatched"
  assert_grep 'stage=incomplete' "$home/data/fd/panel.meta" \
    "a panel whose first analyst never dispatched must record that it never finished dispatching"
  status=0
  out=$(run_panel "$home" advance fd) || status=$?
  [ "$status" -ne 0 ] || fail "advance must refuse a panel whose first analyst never dispatched"
  pass "a failed analyst-A dispatch is recorded, so advance refuses instead of waiting on a report nobody will write"
}

test_rollback_never_deletes_a_directory_it_did_not_create() {
  local home status=0 out
  home=$(new_home rollback "$TWO_MODELS")
  # An earlier scout's durable report survived teardown under the task id this
  # panel is about to use, and so did its brief, so the shared scaffold refuses
  # and start dies before it attempts any dispatch.
  mkdir -p "$home/data/rb-a"
  printf 'an earlier scout report\n' > "$home/data/rb-a/report.md"
  printf 'an earlier brief\n' > "$home/data/rb-a/brief.md"
  out=$(run_panel "$home" start --id rb --project "$home/subject" "Anything?") || status=$?
  [ "$status" -ne 0 ] || fail "start must fail when a task directory already holds a brief: $out"
  assert_present "$home/data/rb-a/report.md" "the rollback deleted a report this run did not create"
  assert_grep 'an earlier scout report' "$home/data/rb-a/report.md" \
    "the pre-existing report was clobbered by the failed start"
  assert_absent "$home/data/rb" "a start that failed before dispatch must roll back the record it did create"
  pass "a failed start rolls back only what it created and leaves an earlier task's report intact"
}

test_start_refuses_to_clobber_an_existing_panel() {
  local home status=0 out
  home=$(new_home existing "$TWO_MODELS")
  out=$(run_panel "$home" start --id dup --project "$home/subject" "First") || fail "start failed: $out"
  out=$(run_panel "$home" start --id dup --project "$home/subject" "Second") || status=$?
  [ "$status" -ne 0 ] || fail "a second start on a live panel id must refuse"
  assert_contains "$out" "already exists" "the refusal does not say the panel already exists"
  assert_grep 'First' "$home/data/dup/question.md" "the live panel's question was overwritten"
  pass "start refuses an existing panel id instead of clobbering it"
}

test_skill_owns_the_cost_decision_and_one_trigger
test_configuration_doc_owns_the_schema_and_degradation
test_analysts_dispatch_on_different_models
test_panel_start_dispatches_through_the_real_spawn
test_pinned_object_lineup_needs_no_random_source
test_distinct_analyst_arrays_resolve_to_different_models
test_analyst_array_collision_refuses_after_resolution
test_judge_array_collision_warns_after_resolution
test_unpinned_analyst_refuses_unknown_runtime_identity
test_analyst_a_array_prefers_a_pinned_identity
test_single_surviving_candidate_resolves_to_itself
test_all_unpinned_analyst_a_array_still_refuses
test_invalid_array_candidate_refuses_in_every_seat
test_unpinned_judge_warns_without_model_self_report
test_judge_array_prefers_a_known_unused_identity_over_unpinned_default
test_reduced_unpinned_seat_warns_without_claiming_independence
test_identical_analyst_models_refuse
test_same_model_through_two_harnesses_refuses
test_reduced_form_is_named_not_a_panel
test_analyst_briefs_share_the_question_and_forbid_peeking
test_panel_briefs_declare_they_carry_no_premise
test_judge_waits_for_every_report_then_gets_both
test_terminal_member_without_a_report_stands_the_panel_down
test_gone_analyst_with_nothing_stands_the_panel_down
test_gone_judge_with_nothing_offers_the_rejudge
test_readiness_latch_survives_teardown
test_judge_without_a_verdict_offers_a_recorded_rejudge
test_rejudge_replaces_a_torn_down_judge_and_records_only_after_dispatch
test_generated_task_ids_stay_within_the_task_id_limit
test_accepted_judge_caveat_repeats_on_every_complete
test_acceptance_is_not_recorded_when_the_stage_cannot_use_it
test_wedged_member_names_its_override_and_the_override_is_per_member
test_accept_unfinished_refuses_a_nonmember_and_a_missing_report
test_failed_analyst_with_a_report_still_reaches_the_judge
test_crew_dispatch_default_is_the_documented_fallback
test_no_configuration_refuses_with_every_source_named
test_static_crew_harness_backs_the_panel_and_still_refuses_honestly
test_static_crew_harness_runs_the_reduced_form
test_dry_run_shows_the_lineup_without_spending_anything
test_failed_second_dispatch_is_reported_and_blocks_advance
test_failed_first_dispatch_records_incomplete
test_rollback_never_deletes_a_directory_it_did_not_create
test_start_refuses_to_clobber_an_existing_panel
