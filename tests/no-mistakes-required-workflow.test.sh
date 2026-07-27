#!/usr/bin/env bash
# Contract and synthetic event replay for the PR body compliance workflow.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
SIGNATURE_STEP='Verify no-mistakes signature in PR body'
ANCESTRY_STEP='Verify ancestry-restoring merge'

# Extract one named step's inline run block, so the replays below execute the
# workflow's real script rather than a copy that can drift away from it.
extract_step_script() {
  awk -v step="      - name: $1" '
    $0 == step { instep=1; next }
    instep && $0 == "        run: |" { capture=1; next }
    capture && /^          / { sub(/^          /, ""); print; next }
    capture && /^[[:space:]]*$/ { print ""; next }
    capture { exit }
  ' "$WORKFLOW"
}

extract_signature_script() {
  extract_step_script "$SIGNATURE_STEP"
}

signature_result() {
  local body=$1 script
  script=$(extract_signature_script)
  PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY="$body" bash -c "$script" >/dev/null 2>&1
}

render_group() {
  local action=$1 run_id=$2
  case "$action" in
    opened|edited) printf 'no-mistakes-required-418-%s\n' "$run_id" ;;
    synchronize|reopened) printf 'no-mistakes-required-418-head-change\n' ;;
  esac
}

render_run_name() {
  local action=$1 run_number=$2 run_id=$3
  printf 'PR #418 body compliance - %s - event %s (run %s)\n' "$action" "$run_number" "$run_id"
}

test_signature_sequence_at_fixed_head() {
  signature_result "Synthetic body\n$MARKER" || fail "signed opened event must succeed"
  if signature_result 'Synthetic unsigned edit'; then
    fail "unsigned edited event must fail"
  fi
  signature_result "Synthetic signed edit\n$MARKER" || fail "signed edited event must succeed"
  pass "fixed-head signed opened, unsigned edited, signed edited yields 0/1/0"
}

test_event_identity_contract() {
  local opened edited_one edited_two synchronize reopened
  opened=$(render_group opened 9001)
  edited_one=$(render_group edited 9002)
  edited_two=$(render_group edited 9003)
  synchronize=$(render_group synchronize 9004)
  reopened=$(render_group reopened 9005)
  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] && [ "$edited_one" != "$edited_two" ] || \
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] || fail "synchronize and reopened must share head-change"
  case "$opened $edited_one $edited_two" in *head-change*) fail "body event reused head-change" ;; esac

  assert_grep "group: no-mistakes-required-\${{ github.event.pull_request.number }}-\${{ (github.event.action == 'opened' || github.event.action == 'edited') && github.run_id || 'head-change' }}" "$WORKFLOW" \
    "workflow does not implement immutable body-event groups"
  assert_grep 'cancel-in-progress: true' "$WORKFLOW" "workflow lost cancellation for coalesced head changes"
  pass "body event groups are distinct while head changes remain coalesced"
}

test_run_names_are_ordered_and_unique() {
  local first second
  first=$(render_run_name edited 73 9002)
  second=$(render_run_name edited 74 9003)
  [ "$first" = 'PR #418 body compliance - edited - event 73 (run 9002)' ] || fail "first synthetic run name is incomplete"
  [ "$second" = 'PR #418 body compliance - edited - event 74 (run 9003)' ] || fail "second synthetic run name is incomplete"
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  assert_grep 'run-name: "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"' "$WORKFLOW" \
    "workflow run name does not expose PR, action, monotonic run number, and immutable run ID"
  pass "run names expose monotonic numbers and immutable IDs"
}

test_security_and_signature_contract_is_preserved() {
  assert_grep '  pull_request:' "$WORKFLOW" "workflow must use pull_request"
  assert_no_grep 'pull_request_target' "$WORKFLOW" "workflow must not use pull_request_target"
  assert_grep '  contents: read' "$WORKFLOW" "contents permission must remain read-only"
  assert_no_grep 'contents: write' "$WORKFLOW" "workflow must not gain contents write permission"
  assert_no_grep 'secrets.' "$WORKFLOW" "workflow must not read secrets"
  assert_no_grep 'actions/checkout' "$WORKFLOW" "workflow must not check out fork code"
  assert_grep 'name: PR must be raised via no-mistakes' "$WORKFLOW" "stable required check name changed"
  assert_grep "$MARKER" "$WORKFLOW" "signature marker changed"
  assert_grep "github.event.pull_request.user.login != 'github-actions[bot]'" "$WORKFLOW" "github-actions bot exemption changed"
  assert_grep "github.event.pull_request.user.login != 'dependabot[bot]'" "$WORKFLOW" "dependabot bot exemption changed"
  assert_no_grep 'release-please[bot]' "$WORKFLOW" "Firstmate must not exempt release-please"
  pass "fork, permission, check-name, marker, and bot-exemption contracts are preserved"
}

# ---------------------------------------------------------------------------
# Ancestry-restoring merge exemption
#
# Both directions are proven against real commit graphs, because the exemption
# is only worth anything if it is decided from the graph. Every case below runs
# the workflow's own inline script, unmodified.
# ---------------------------------------------------------------------------

fm_test_tmproot TMP_ROOT no-mistakes-required-tests
mkdir -p "$TMP_ROOT/runner"

SRC=
DOWN=
ORIGIN=
ANCESTRY_OUT=
ANCESTRY_RC=0

gitx() {
  local repo=$1
  shift
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

write_commit() {
  local repo=$1 path=$2 content=$3 message=$4
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  gitx "$repo" add -- "$path"
  gitx "$repo" commit -qm "$message"
}

# A pin source and a downstream repository that vendors it, shaped like the
# fleet repository this exemption exists for:
#   src/main   A -> B   the pin source; carries bin/tool.sh and AGENTS.md
#   down/main  A -> G   G adds firstmate.lock and a fleet-owned doc
# Pass "nopin" to build the same graph in a repository that vendors nothing,
# which is every ordinary firstmate checkout.
build_fixture() {
  local name=$1 pin=${2:-pin} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  SRC="$dir/src"
  DOWN="$dir/down"
  ORIGIN="$dir/origin.git"

  mkdir -p "$SRC"
  gitx "$SRC" init -q
  gitx "$SRC" checkout -q -B main
  write_commit "$SRC" bin/tool.sh 'echo v1' 'src: add the vendored tool'
  write_commit "$SRC" AGENTS.md 'vendored instructions' 'src: add instructions'

  git clone -q "$SRC" "$DOWN"
  gitx "$DOWN" checkout -q -B main
  if [ "$pin" = pin ]; then
    printf 'source_url=%s\nsource_ref=main\ncommit=%s\n' \
      "$SRC" "$(gitx "$SRC" rev-parse main)" > "$DOWN/firstmate.lock"
    gitx "$DOWN" add -- firstmate.lock
  fi
  mkdir -p "$DOWN/fleet"
  printf 'fleet doctrine v1\n' > "$DOWN/fleet/doctrine.md"
  gitx "$DOWN" add -- fleet/doctrine.md
  gitx "$DOWN" commit -qm 'down: vendor the source under a pin'

  # The source moves on. This is the ancestry the downstream must absorb.
  write_commit "$SRC" bin/tool.sh 'echo v2' 'src: advance the vendored tool'
}

# The documented merge-bump recipe: merge the source's new main and regenerate
# the pin in that same commit, which makes the merge evil on the pin file alone.
make_merge_bump() {
  local branch=$1 smuggle=${2:-} src_head
  src_head=$(gitx "$SRC" rev-parse main)
  gitx "$DOWN" fetch -q "$SRC" 'main:refs/fm-src'
  gitx "$DOWN" checkout -q -B "$branch" main
  # git reports a clean --no-commit merge on stderr regardless of -q.
  gitx "$DOWN" merge -q --no-ff --no-commit refs/fm-src >/dev/null 2>&1 \
    || fail "fixture merge did not apply"
  if [ -f "$DOWN/firstmate.lock" ]; then
    printf 'source_url=%s\nsource_ref=main\ncommit=%s\n' "$SRC" "$src_head" > "$DOWN/firstmate.lock"
    gitx "$DOWN" add -- firstmate.lock
  fi
  if [ -n "$smuggle" ]; then
    printf '%s\n' "$smuggle" > "$DOWN/bin/tool.sh"
    gitx "$DOWN" add -- bin/tool.sh
  fi
  gitx "$DOWN" commit -qm 'down: merge the pin source and regenerate the pin'
}

publish() {
  rm -rf "$ORIGIN"
  git init -q --bare "$ORIGIN"
  gitx "$DOWN" push -q "$ORIGIN" 'refs/heads/main:refs/heads/main'
  gitx "$DOWN" push -q "$ORIGIN" "$(gitx "$DOWN" rev-parse HEAD):refs/pull/7/head"
}

run_ancestry() {
  local script
  script=$(extract_step_script "$ANCESTRY_STEP")
  [ -n "$script" ] || fail "could not extract the '$ANCESTRY_STEP' step from the workflow"
  ANCESTRY_OUT=$(
    PR_AUTHOR=synthetic-contributor PR_NUMBER=7 BASE_REF=main \
      REPO_URL="$ORIGIN" GH_TOKEN='' RUNNER_TEMP="$TMP_ROOT/runner" \
      bash -c "$script" 2>&1
  )
  ANCESTRY_RC=$?
}

test_merge_bump_is_accepted() {
  build_fixture accept
  make_merge_bump pr-accept
  write_commit "$DOWN" fleet/doctrine.md 'fleet doctrine v2 - records the merge bump' \
    'down: record the merge bump'
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -eq 0 ] || fail "genuine ancestry-restoring merge was rejected: $ANCESTRY_OUT"
  assert_contains "$ANCESTRY_OUT" 'is an ancestry-restoring merge' \
    "acceptance did not name the property it verified"
  pass "a merge bump carrying pin-source ancestry passes without a pipeline signature"
}

test_pipeline_skipping_pull_request_is_rejected() {
  build_fixture ordinary
  gitx "$DOWN" checkout -q -B pr-ordinary main
  write_commit "$DOWN" bin/tool.sh 'echo hand-edited' 'down: edit the vendored tool by hand'
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "an ordinary pipeline-skipping PR was exempted"
  assert_contains "$ANCESTRY_OUT" 'brings in ancestry from' "rejection reason was not the missing merge"
  assert_contains "$ANCESTRY_OUT" 'was not raised through no-mistakes' \
    "rejection dropped the contributor guidance"
  pass "an ordinary pull request that skips the pipeline is still rejected"
}

test_merge_of_a_local_branch_is_rejected() {
  build_fixture localmerge
  gitx "$DOWN" checkout -q -B feature main
  write_commit "$DOWN" fleet/doctrine.md 'fleet doctrine, locally authored' 'down: local work'
  gitx "$DOWN" checkout -q -B pr-localmerge main
  gitx "$DOWN" merge -q --no-ff -m 'down: merge my own branch' feature \
    || fail "fixture merge did not apply"
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "merging a local branch bought an exemption"
  assert_contains "$ANCESTRY_OUT" 'brings in ancestry from' \
    "a two-parent merge from outside the pin source was not the stated reason"
  pass "a two-parent merge whose other parent is not published in the pin source is rejected"
}

test_rider_commit_adding_a_new_file_is_rejected() {
  build_fixture rider-add
  make_merge_bump pr-rider-add
  write_commit "$DOWN" rider.sh 'echo rider' 'down: bolt unreviewed work onto the merge'
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "a new file rode in on an exempt merge"
  assert_contains "$ANCESTRY_OUT" 'adds rider.sh' "rejection did not name the smuggled file"
  pass "a genuine merge cannot carry a new file past the pipeline"
}

test_rider_commit_editing_a_vendored_file_is_rejected() {
  build_fixture rider-edit
  make_merge_bump pr-rider-edit
  write_commit "$DOWN" bin/tool.sh 'echo hand-edited' 'down: hand-edit a vendored file'
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "a hand-edited vendored file rode in on an exempt merge"
  assert_contains "$ANCESTRY_OUT" 'changes bin/tool.sh by hand' \
    "rejection did not name the hand-edited vendored file"
  pass "a genuine merge cannot carry a hand-edited vendored file past the pipeline"
}

test_evil_merge_payload_is_rejected() {
  build_fixture evil
  make_merge_bump pr-evil 'echo smuggled-inside-the-merge'
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "an evil merge smuggled a vendored edit past the gate"
  assert_contains "$ANCESTRY_OUT" 'changes bin/tool.sh by hand' \
    "rejection did not attribute the evil merge's own payload"
  pass "content a merge introduces beyond every parent is judged like any other edit"
}

test_repository_without_a_pin_never_gets_the_exemption() {
  build_fixture nopin nopin
  make_merge_bump pr-nopin
  publish
  run_ancestry
  [ "$ANCESTRY_RC" -ne 0 ] || fail "a repository with no vendoring pin was exempted"
  assert_contains "$ANCESTRY_OUT" 'declares no vendoring pin' \
    "rejection did not name the absent pin"
  pass "the same graph is denied where no pin declares a trusted source"
}

test_exemption_never_reads_author_controlled_text() {
  local script
  script=$(extract_step_script "$ANCESTRY_STEP")
  case "$script" in
    *PR_BODY*) fail "the exemption reads the PR body, which the author controls" ;;
    *PR_TITLE*) fail "the exemption reads the PR title, which the author controls" ;;
    *HEAD_REF*) fail "the exemption reads the head branch name, which the author controls" ;;
  esac
  assert_grep 'refs/fm/base:firstmate.lock' "$WORKFLOW" \
    "the trusted source must be read from the base branch, not the pull request"
  pass "the exemption is decided from the commit graph, never from author-controlled text"
}

test_signature_sequence_at_fixed_head
test_event_identity_contract
test_run_names_are_ordered_and_unique
test_security_and_signature_contract_is_preserved
test_merge_bump_is_accepted
test_pipeline_skipping_pull_request_is_rejected
test_merge_of_a_local_branch_is_rejected
test_rider_commit_adding_a_new_file_is_rejected
test_rider_commit_editing_a_vendored_file_is_rejected
test_evil_merge_payload_is_rejected
test_repository_without_a_pin_never_gets_the_exemption
test_exemption_never_reads_author_controlled_text
