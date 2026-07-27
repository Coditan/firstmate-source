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
  assert_grep 'config/model-panel.json' "$ROOT/.gitignore" \
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
  assert_not_contains "$(spawn_log "$home")" "jg-judge" "the judge must wait for every analyst report"

  printf 'analyst b findings\n' > "$home/data/jg-b/report.md"
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

  printf 'judgement\n' > "$home/data/jg-judge/report.md"
  out=$(run_panel "$home" advance jg) || fail "advance failed: $out"
  assert_contains "$out" "complete: $home/data/jg-judge/report.md" \
    "a finished panel does not report its judge report path"
  assert_grep 'stage=complete' "$home/data/jg/panel.meta" "the panel record did not reach the complete stage"
  pass "the judge is created only once every analyst report exists, and sees both blind"
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

test_no_configuration_refuses_with_both_paths_named() {
  local home status=0 out
  home=$(new_home unconfigured)
  out=$(run_panel "$home" start --id nc --project "$home/subject" "Anything?") || status=$?
  [ "$status" -ne 0 ] || fail "an unconfigured home must not silently invent a lineup"
  assert_contains "$out" "model-panel.json" "the refusal does not name the panel configuration file"
  assert_contains "$out" "crew-dispatch.json" "the refusal does not name the fallback configuration file"
  pass "a home with no configuration refuses and names both configuration files"
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
test_identical_analyst_models_refuse
test_same_model_through_two_harnesses_refuses
test_reduced_form_is_named_not_a_panel
test_analyst_briefs_share_the_question_and_forbid_peeking
test_judge_waits_for_every_report_then_gets_both
test_crew_dispatch_default_is_the_documented_fallback
test_no_configuration_refuses_with_both_paths_named
test_dry_run_shows_the_lineup_without_spending_anything
test_failed_second_dispatch_is_reported_and_blocks_advance
test_start_refuses_to_clobber_an_existing_panel
