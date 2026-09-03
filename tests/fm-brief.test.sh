#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-brief

BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# The premise disproof step is the measured control from the 2026-08-18/25 effort lab:
# it disproves ONE named assertion and repairs rather than merely stopping. It must not
# drift into a general verification section - the vendor documents that separate
# verification steps in harness scaffolding cause over-verification on this model - so
# these assertions pin both the repair wording and the absence of a general re-check.
test_premise_step_is_narrow_and_repair_worded() {
  local home id brief kind
  home="$TMP_ROOT/premise-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-premise-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout --premise >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --premise >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind --premise brief was not scaffolded"
    assert_grep "# The premise this brief asserts" "$brief" \
      "$kind --premise brief missing the disproof section"
    assert_grep "{PREMISE}" "$brief" \
      "$kind --premise brief missing the premise slot the caller fills"
    assert_grep "name the single check whose result would show that assertion is WRONG, run that check, and paste its output" "$brief" \
      "$kind --premise brief lost the measured disproof instruction"
    assert_grep "do NOT follow this brief literally: carry out what it was actually trying to achieve" "$brief" \
      "$kind --premise brief lost the repair wording and reads as stop-only"
    assert_grep "This is one named assertion, not a standing instruction to re-check the rest of the brief." "$brief" \
      "$kind --premise brief lost the bound that keeps the step narrow"
    assert_no_grep "# Premise declaration - NONE ASSERTED" "$brief" \
      "$kind --premise brief retained the absent-premise declaration"
    # The step must stay narrow: no general verification instruction anywhere in the brief.
    assert_no_grep "check your work" "$brief" \
      "$kind --premise brief widened into a general verification instruction"
    assert_no_grep "verify before proceeding" "$brief" \
      "$kind --premise brief widened into a general verification instruction"
    assert_no_grep "double-check" "$brief" \
      "$kind --premise brief widened into a general verification instruction"
  done
  pass "fm-brief.sh: --premise emits the narrow repair-worded disproof step"
}

test_premise_omission_is_loud_for_ship_and_scout() {
  local home id brief kind
  home="$TMP_ROOT/premise-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-premise-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Premise declaration - NONE ASSERTED" "$brief" \
      "$kind brief silently omitted the premise declaration"
    assert_grep "'$ROOT/bin/fm-status.sh' '$home/state/$id.status' blocked \"brief asserts a fact but was scaffolded without --premise\"" "$brief" \
      "$kind brief missing the fail-visible stop-and-report the reader can actually perform"
    assert_grep "Do not write a disproof step into this unguarded brief by hand." "$brief" \
      "$kind brief missing the ban on hand-written disproof wording"
    assert_no_grep "# The premise this brief asserts" "$brief" \
      "$kind brief emitted the disproof step without --premise"
    assert_no_grep "{PREMISE}" "$brief" \
      "$kind brief left an unusable premise slot without --premise"
  done
  pass "fm-brief.sh: ship and scout scaffolds make an omitted premise fail-visible"
}

# The scaffold's stdout line is the only cue firstmate gets that a SECOND placeholder
# must be filled before dispatch, and filling it is a manual step on the path where
# a human scaffolds a brief and replaces the slots by hand. Pin both renderings.
test_premise_scaffold_stdout_names_every_placeholder() {
  local home id kind out
  home="$TMP_ROOT/premise-stdout-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-premise-stdout-$kind"
    if [ "$kind" = scout ]; then
      out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout --premise 2>/dev/null)
    else
      out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --premise 2>/dev/null)
    fi
    assert_contains "$out" "replace {TASK} and {PREMISE}" \
      "$kind --premise scaffold did not cue the second placeholder on stdout"

    id="brief-nopremise-stdout-$kind"
    if [ "$kind" = scout ]; then
      out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout 2>/dev/null)
    else
      out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate 2>/dev/null)
    fi
    assert_contains "$out" "replace {TASK}" \
      "$kind scaffold lost the {TASK} cue on stdout"
    assert_not_contains "$out" "{PREMISE}" \
      "$kind scaffold cued a premise placeholder it did not emit"
  done
  pass "fm-brief.sh: the scaffold's stdout names every placeholder still to be filled"
}

# The premise slot has exactly three states and a brief must always be in one of
# them: a premise asserted, no premise DECLARED by the caller, or the omission
# left undeclared. Only the undeclared state tells the reader to stop, so a brief
# that is in none of them has quietly lost the whole contract.
test_every_brief_declares_exactly_one_premise_state() {
  local home id kind brief states
  home="$TMP_ROOT/premise-states-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    local -a scout_flag=()
    [ "$kind" = ship ] || scout_flag=(--scout)
    for id in asserted declared undeclared; do
      local -a flag=()
      case "$id" in
        asserted) flag=(--premise) ;;
        declared) flag=(--no-premise) ;;
      esac
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "premise-state-$kind-$id" firstmate \
        "${scout_flag[@]+"${scout_flag[@]}"}" "${flag[@]+"${flag[@]}"}" >/dev/null 2>&1
      brief="$home/data/premise-state-$kind-$id/brief.md"
      assert_present "$brief" "$kind/$id brief was not scaffolded"
      states=$(grep -c -e '# The premise this brief asserts' \
        -e '# Premise declaration - DECLARED NONE' \
        -e '# Premise declaration - NONE ASSERTED' "$brief" || true)
      [ "$states" = 1 ] \
        || fail "$kind/$id brief declares $states premise states, expected exactly 1"
    done

    brief="$home/data/premise-state-$kind-declared/brief.md"
    assert_grep '# Premise declaration - DECLARED NONE' "$brief" \
      "$kind --no-premise brief lost the declared-none block"
    assert_no_grep '# Premise declaration - NONE ASSERTED' "$brief" \
      "$kind --no-premise brief kept the undeclared stop-and-report block"
    assert_no_grep '{PREMISE}' "$brief" \
      "$kind --no-premise brief left an unusable premise slot"
    # Scope the stop assertions to the declared block itself: the brief's
    # unrelated Herdr declaration legitimately carries its own stop wording.
    local block="$home/data/premise-state-$kind-declared/premise-block.md"
    awk '/^# Premise declaration - DECLARED NONE$/ { inblock = 1; next }
         inblock && /^# / { exit }
         inblock { print }' "$brief" > "$block"
    assert_grep 'Do not write a disproof step into this brief by hand.' "$block" \
      "$kind --no-premise brief lost the ban on hand-written disproof wording"
    # Removing the stop is the whole point: a programmatic caller has no
    # firstmate to regenerate a brief for a member it already dispatched.
    assert_no_grep 'blocked:' "$block" \
      "$kind --no-premise block still tells its reader to stop"
    assert_no_grep 'and stop' "$block" \
      "$kind --no-premise block still tells its reader to stop"
    assert_no_grep 'firstmate will regenerate' "$block" \
      "$kind --no-premise block still promises a regeneration no programmatic caller can do"
    assert_no_grep 'regenerate the brief' "$block" \
      "$kind --no-premise block still asks its reader to seek a regeneration"
    # The declaration covers this scaffold only; vouching for task text the
    # caller pastes in unread is the overclaim this whole control exists to catch.
    assert_no_grep 'carries no asserted fact' "$block" \
      "$kind --no-premise block vouches for task text its caller never inspected"
    assert_no_grep 'There is nothing to disprove here' "$block" \
      "$kind --no-premise block makes a blanket denial about the task's content"
  done
  pass "fm-brief.sh: every scaffold declares exactly one of the three premise states"
}

test_premise_flags_are_mutually_exclusive() {
  local home status
  home="$TMP_ROOT/premise-exclusive-home"
  mkdir -p "$home/data"
  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" premise-both firstmate --premise --no-premise \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--premise with --no-premise must be rejected"
  assert_absent "$home/data/premise-both/brief.md" \
    "rejected --premise --no-premise still wrote a brief"

  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" no-premise-secondmate --secondmate firstmate --no-premise \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --no-premise must be rejected"
  assert_absent "$home/data/no-premise-secondmate/brief.md" \
    "rejected secondmate --no-premise still wrote a brief"
  pass "fm-brief.sh: --no-premise refuses to combine with --premise or a charter"
}

test_premise_is_rejected_for_secondmate_charters() {
  local home status
  home="$TMP_ROOT/premise-secondmate-home"
  mkdir -p "$home/data"
  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" premise-secondmate --secondmate firstmate --premise >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --premise must be rejected"
  assert_absent "$home/data/premise-secondmate/brief.md" \
    "rejected secondmate --premise still wrote a brief"
  pass "fm-brief.sh: --premise is rejected for secondmate charters"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working --key <work-slug> "{material phase}"' "$brief" \
    "secondmate charter did not key material routed-work phases through the writer"
  assert_grep 'resolved --key <work-slug> "{why it is no longer active}"' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase through the writer"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# The decision key is read from the status line's verb PREFIX only
# (bin/fm-classify-lib.sh's _fm_decision_key), so a key written anywhere else
# does not name the decision the worker meant, and the failure surfaces far from
# the line that caused it. Every scaffold therefore hands the worker
# bin/fm-status.sh, which composes the line from parts and refuses a bad key at
# the write, in place of a bare shell append that left the grammar to be typed.
# The brief may say the writer refuses only because the writer actually does:
# the last block below runs the exact command the brief shows, at the exact
# path it names, and requires the refusal, so the promise is measured here
# rather than asserted. An earlier version of this test forbade the words
# "refuses it by name" because nothing performed the refusal then.
test_status_writer_replaces_bare_echo_in_every_scaffold() {
  local home ship scout charter writer status out rc
  home="$TMP_ROOT/key-position-home"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" key-ship alpha >/dev/null 2>&1 \
    || fail "ship scaffold exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" key-scout alpha --scout >/dev/null 2>&1 \
    || fail "scout scaffold exited non-zero"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" key-mate --secondmate alpha >/dev/null 2>&1 \
    || fail "secondmate scaffold exited non-zero"
  ship="$home/data/key-ship/brief.md"
  scout="$home/data/key-scout/brief.md"
  charter="$home/data/key-mate/brief.md"

  writer="'$ROOT/bin/fm-status.sh'"
  for brief in "$ship" "$scout"; do
    status="'$home/state/$(basename "$(dirname "$brief")").status'"
    assert_grep "$writer $status {state} \"{one short line}\"" "$brief" \
      "$brief does not hand the worker the status writer for a plain line"
    assert_grep "$writer $status needs-decision --key <slug> \"{summary of options}\"" "$brief" \
      "$brief does not show the keyed needs-decision write"
    assert_grep "$writer $status resolved --key <slug> \"{how it was decided or unblocked}\"" "$brief" \
      "$brief does not show the keyed resolved write"
  done
  status="'$home/state/key-mate.status'"
  assert_grep "$writer $status {state} \"{one short line}\"" "$charter" \
    "charter does not hand the secondmate the status writer for a plain line"
  assert_grep "$writer $status working --key <work-slug> \"{material phase}\"" "$charter" \
    "charter does not show the keyed working write"
  assert_grep "$writer $status resolved --key <work-slug> \"{how it was decided or unblocked}\"" "$charter" \
    "charter does not show the keyed resolved write for an answered decision"
  for brief in "$ship" "$scout" "$charter"; do
    assert_grep 'in the verb prefix, between the verb and the colon' "$brief" \
      "$brief does not state where the writer puts the decision key"
    assert_grep 'never with a bare shell append' "$brief" \
      "$brief does not route every status append through the writer"
    assert_no_grep 'echo "{state}' "$brief" \
      "$brief still shows a bare echo status append"
    assert_no_grep '>> '"'"'' "$brief" \
      "$brief still shows a shell append onto a quoted path"
    assert_no_grep '[key=<slug>]' "$brief" \
      "$brief still shows the key grammar for the worker to type by hand"
    assert_no_grep '[key=<work-slug>]' "$brief" \
      "$brief still shows the key grammar for the worker to type by hand"
  done

  # The refusal the briefs describe is performed by the command they name: run it
  # as the worker would, with a key the fold could not read, at the ship brief's
  # own status path, and require the refusal by name with nothing written.
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-status.sh" "$home/state/key-ship.status" \
    needs-decision --key 'route choice' 'pick' 2>&1); rc=$?
  expect_code 2 "$rc" "the writer the ship brief names did not refuse a bad key"
  assert_contains "$out" "fm-status: decision key must be a privacy-safe slug: route choice" \
    "the writer's refusal did not name the key"
  assert_absent "$home/state/key-ship.status" "a refused key wrote a status line"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-status.sh" "$home/state/key-ship.status" \
    needs-decision --key route-choice 'pick' 2>&1); rc=$?
  expect_code 0 "$rc" "the writer the ship brief names refused a good key: $out"
  assert_grep 'needs-decision [key=route-choice]: pick' "$home/state/key-ship.status" \
    "the accepted key did not land in the verb prefix"
  pass "fm-brief.sh: every scaffold hands the worker the status writer, and the writer refuses as described"
}

# Rule 1's push ban and Bridge's publish step both target the default branch, and a
# crewmate has already read the ban as covering the publish: it passed --no-publish,
# reported two envelope ids, and delivered nothing. Nothing downstream catches that,
# so every scaffold carrying a rule 1 must state the boundary and the verification.
test_rule_one_states_its_bridge_boundary() {
  local home brief
  home="$TMP_ROOT/bridge-boundary-home"
  write_registry "$home"

  for id in nm:alpha direct:direct-proj local:local-proj; do
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "bridge-${id%%:*}" "${id#*:}" >/dev/null 2>&1 \
      || fail "ship scaffold (${id%%:*}) exited non-zero"
  done
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bridge-scout alpha --scout >/dev/null 2>&1 \
    || fail "scout scaffold exited non-zero"

  # shellcheck disable=SC2016  # backticks below are literal brief text, not substitutions.
  for brief in "$home"/data/bridge-{nm,direct,local,scout}/brief.md; do
    assert_grep 'Rule 1 is about code pushes.' "$brief" \
      "$brief does not scope rule 1 to code pushes"
    assert_grep 'rule 1 does not cover it: never pass `--no-publish` to a Bridge' "$brief" \
      "$brief does not exclude the Bridge publish step from rule 1"
    assert_grep 'An envelope id proves composition, never delivery' "$brief" \
      "$brief lets an envelope id stand as proof of delivery"
    assert_grep 'out of `inbox/<us>/new/` into `acked/`' "$brief" \
      "$brief does not name the remote-side delivery check"
  done

  # Pin each ship brief's delivery mode: if the registry fixture ever stops resolving,
  # all three collapse to no-mistakes briefs and the assertions above still pass.
  assert_grep 'Firstmate will then instruct you to run /no-mistakes' \
    "$home/data/bridge-nm/brief.md" "bridge-nm did not render as a no-mistakes brief"
  assert_grep 'This project ships **direct-PR**' \
    "$home/data/bridge-direct/brief.md" "bridge-direct did not render as a direct-PR brief"
  assert_grep 'This project ships **local-only**' \
    "$home/data/bridge-local/brief.md" "bridge-local did not render as a local-only brief"
  pass "fm-brief.sh: every rule 1 states its Bridge-publish boundary and verification"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_premise_step_is_narrow_and_repair_worded
test_premise_omission_is_loud_for_ship_and_scout
test_premise_scaffold_stdout_names_every_placeholder
test_every_brief_declares_exactly_one_premise_state
test_premise_flags_are_mutually_exclusive
test_premise_is_rejected_for_secondmate_charters
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_status_writer_replaces_bare_echo_in_every_scaffold
test_rule_one_states_its_bridge_boundary
test_scout_and_secondmate_scaffold
