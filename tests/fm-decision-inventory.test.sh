#!/usr/bin/env bash
# Behavior tests for the open-decision collapse that /decisionboard lays out.
#
# The collapse exists because a model panel registers holds per MEMBER: two
# analysts and a judge each inventory the same investigation, so one question
# becomes up to three records. A board that listed every record would tell the
# captain far more is waiting on him than actually is.
#
# These fixtures are synthetic on purpose. They pin the RULE - identity shape and
# panel role suffix, both owned elsewhere - rather than the fleet's live contents,
# which change every day.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INV="$ROOT/bin/fm-decision-inventory.sh"
fm_test_tmproot TMP_ROOT fm-decision-inventory

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# capture <id>... : write a bearings-shaped snapshot with these decision ids.
capture() {
  local out=$TMP_ROOT/capture.json id
  {
    printf '{"schema":"fm-bearings.v1","decisions_open":['
    local first=1
    for id in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"id":"%s","key":"%s","verb":"captain-hold","summary":"Frage %s","owner":"(main)"}' \
        "$id" "$id" "$id"
    done
    printf ']}'
  } > "$out"
  printf '%s\n' "$out"
}

inv() {  # <capture-file> -> json on stdout
  "$INV" --json --from "$1"
}

test_panel_triplet_becomes_one_decision() {
  local cap out
  cap=$(capture \
    "panel-x-a-decision-store-location" \
    "panel-x-b-decision-store-location" \
    "panel-x-judge-decision-store-location")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.records')" = 3 ] || fail "expected 3 records"
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 1 ] \
    || fail "a panel triplet of one question must collapse to one decision"
  # The judge's formulation is the one the captain answers.
  [ "$(printf '%s' "$out" | jq -r '.decisions_flat[0].id')" = "panel-x-judge-decision-store-location" ] \
    || fail "the judge record must be the authoritative one"
  [ "$(printf '%s' "$out" | jq -r '.decisions_flat[0].variants | length')" = 2 ] \
    || fail "both analyst records must be folded in as variants"
  [ "$(printf '%s' "$out" | jq -r '.decisions_flat[0].variants[0].paired')" = "true" ] \
    || fail "an exact key match must be reported as a confident pairing"
  pass "a panel triplet collapses to one decision led by the judge"
}

test_reworded_judge_key_still_collapses_but_says_so() {
  # The real failure mode: judges reword keys, so key matching alone would leave
  # the analyst record standing as a phantom extra question. The GROUP rule still
  # collapses it; the pairing is honestly reported as unestablished.
  local cap out
  cap=$(capture \
    "grp-b-decision-upstream-engagement" \
    "grp-judge-decision-upstream-firstmate-engagement")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 1 ] \
    || fail "a reworded judge key must still collapse the group to one decision"
  [ "$(printf '%s' "$out" | jq -r '.groups[0].unpaired_variants | length')" = 1 ] \
    || fail "the unmatched analyst record must be reported as an unpaired variant"
  [ "$(printf '%s' "$out" | jq -r '.groups[0].unpaired_variants[0].paired')" = "false" ] \
    || fail "an unmatched variant must not claim a confident pairing"
  pass "a reworded judge key collapses the group and reports the pairing as unestablished"
}

test_replacement_judge_is_recognised() {
  # bin/fm-model-panel.sh names a replacement judge <panel-id>-judge<N>.
  local cap out
  cap=$(capture "panel-y-a-decision-k" "panel-y-judge2-decision-k")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 1 ] \
    || fail "a replacement judge (-judge2) must be recognised as the judge"
  [ "$(printf '%s' "$out" | jq -r '.decisions_flat[0].id')" = "panel-y-judge2-decision-k" ] \
    || fail "the replacement judge must be authoritative"
  pass "a replacement judge id is recognised as the judge"
}

test_group_without_judge_keeps_every_record() {
  # No judge ran, so nothing is superseded and every question stands.
  local cap out
  cap=$(capture "grp-a-decision-one" "grp-b-decision-two")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 2 ] \
    || fail "without a judge every record must stand"
  [ "$(printf '%s' "$out" | jq -r '.groups[0].has_judge')" = "false" ] \
    || fail "has_judge must be false when no judge ran"
  pass "a group with no judge keeps every record"
}

test_unconventional_ids_stand_alone() {
  # A hold that follows neither convention must not be folded into anything.
  # Showing too many questions is recoverable; hiding one is not.
  local cap out
  cap=$(capture "fleet-public-repo-visibility-ungated" "some-other-hold")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 2 ] \
    || fail "ids outside the conventions must each stand alone"
  pass "ids outside the panel conventions each stand alone"
}

test_separate_investigations_do_not_merge() {
  local cap out
  cap=$(capture "alpha-judge-decision-k" "beta-judge-decision-k")
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 2 ] \
    || fail "the same key in two different investigations must stay two decisions"
  pass "the same key under two investigations stays two decisions"
}

test_empty_inventory_is_not_an_error() {
  local cap out
  cap=$(capture)
  out=$(inv "$cap")
  [ "$(printf '%s' "$out" | jq -r '.decisions')" = 0 ] || fail "empty inventory must report zero"
  [ "$(printf '%s' "$out" | jq -r '.records')" = 0 ] || fail "empty inventory must report zero records"
  pass "an empty decision inventory is reported, not treated as an error"
}

test_summary_names_the_unpaired_variants() {
  local cap out
  cap=$(capture "grp-b-decision-upstream-engagement" "grp-judge-decision-other-wording")
  out=$("$INV" --summary --from "$cap")
  assert_contains "$out" "records: 2   decisions kept: 1" "summary lost its counts"
  assert_contains "$out" "pairing not established" \
    "summary must disclose that a variant's pairing is unestablished"
  pass "the summary discloses counts and unestablished pairings"
}

test_the_fold_does_not_claim_to_be_exact() {
  # The fold keeps the judge's records on an assumption the script cannot check:
  # that the judge raised one hold per distinct question the analysts raised. A
  # question only an analyst raised is folded away, so the count must not be
  # presented as a proven count of distinct questions.
  local cap out skill=$ROOT/.agents/skills/decisionboard/SKILL.md
  cap=$(capture "grp-b-decision-upstream-engagement" "grp-judge-decision-other-wording")
  out=$("$INV" --summary --from "$cap")
  assert_contains "$out" "NOT verified" \
    "the summary must disclose that the fold's assumption is unverified"
  assert_no_grep 'ounting is exact' "$INV" "the header must not claim exact counting"
  assert_present "$skill" "the decisionboard skill is missing"
  assert_no_grep 'counts exactly' "$skill" "the skill must not claim the collapse counts exactly"
  pass "neither the tool nor the skill claims the collapse counts exactly"
}

test_every_stated_purpose_describes_the_fold_the_same_way() {
  # The three surfaces a reader actually meets - the --help synopsis, the skill
  # frontmatter an agent reads before loading, and the scripts table - each used
  # to promise "the distinct questions". They drifted from the header once, so
  # they are pinned to one shared phrase.
  local out skill=$ROOT/.agents/skills/decisionboard/SKILL.md
  local scripts=$ROOT/docs/scripts.md
  out=$("$INV" --help)
  assert_contains "$out" "by originating investigation" \
    "the synopsis must say what the tool does, not promise distinct questions"
  case "$out" in
    *"set of distinct questions"*) fail "the synopsis still promises the distinct questions" ;;
  esac
  assert_grep 'by originating investigation' "$skill" \
    "the skill description must describe the same fold as the tool"
  assert_no_grep 'into the distinct questions' "$skill" \
    "the skill description must not promise the distinct questions"
  assert_grep 'by originating investigation' "$scripts" \
    "the scripts table must describe the same fold as the tool"
  assert_no_grep 'into distinct questions' "$scripts" \
    "the scripts table must not promise distinct questions"
  pass "help, skill description, and scripts table describe the fold identically"
}

test_folded_records_must_stay_visible_on_the_board() {
  # Making the failure mode visible is the whole mitigation: a record folded away
  # and never rendered is a question the captain cannot see.
  local skill=$ROOT/.agents/skills/decisionboard/SKILL.md
  local layout=$ROOT/docs/board-layout.md
  assert_grep 'fm-variants' "$skill" \
    "the skill must require the folded records to be rendered"
  assert_grep 'fm-variants' "$layout" \
    "the layout reference must document the component the skill is told to use"
  assert_grep 'fm-variants' "$ROOT/bin/board-assets/layout.css" \
    "the folded-records component must exist in the shared layout"
  pass "the folded records are required to stay visible, in a documented component"
}

test_inventory_is_read_only() {
  # The board presents; bin/fm-decision-hold.sh owns every mutation.
  assert_no_grep 'fm-decision-hold.sh hold' "$INV" "the inventory must not create holds"
  assert_no_grep 'fm-decision-hold.sh resolve' "$INV" "the inventory must not resolve holds"
  assert_no_grep 'tasks-axi' "$INV" "the inventory must not mutate the backlog"
  pass "the inventory never writes a decision"
}

test_panel_triplet_becomes_one_decision
test_reworded_judge_key_still_collapses_but_says_so
test_replacement_judge_is_recognised
test_group_without_judge_keeps_every_record
test_unconventional_ids_stand_alone
test_separate_investigations_do_not_merge
test_empty_inventory_is_not_an_error
test_summary_names_the_unpaired_variants
test_the_fold_does_not_claim_to_be_exact
test_every_stated_purpose_describes_the_fold_the_same_way
test_folded_records_must_stay_visible_on_the_board
test_inventory_is_read_only
