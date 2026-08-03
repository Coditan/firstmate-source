#!/usr/bin/env bash
# Behavior tests for the weekly Grossreinschiff cleanup sweep: the cadence
# script, its bootstrap surfacing, the landedness ladder the skill documents,
# and the instruction-surface contracts that make the sweep reachable.
#
# The ladder tests build real git fixtures rather than asserting on prose,
# because the whole point of that section is that a written belief about how
# git behaves is exactly what put the checklist together in the first place.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DUE="$ROOT/bin/fm-grossreinschiff-due.sh"
SKILL="$ROOT/.agents/skills/grossreinschiff/SKILL.md"
DOC="$ROOT/docs/grossreinschiff.md"
AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP_SKILL="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"

# tests/lib.sh silences the detect line for every suite that composes
# fm-bootstrap.sh. This is the suite that owns the mechanism, so it runs with
# the real thing.
export FM_GROSSREINSCHIFF_DISABLE=0

fm_test_tmproot TMPROOT fm-grossreinschiff
STATE="$TMPROOT/state"
mkdir -p "$STATE"

# clock <YYYY-MM-DD> <HH:MM:SS>: the six fields fm-grossreinschiff-due.sh reads,
# in the order `date '+%s %u %H %M %S %F'` prints them.
clock() {
  date -d "$1 $2" '+%s %u %H %M %S %F'
}

due_run() {
  local when=$1 at=$2
  shift 2
  FM_STATE_OVERRIDE="$STATE" FM_GROSSREINSCHIFF_CLOCK="$(clock "$when" "$at")" "$DUE" "$@"
}

# --- cadence ----------------------------------------------------------------

test_absent_record_is_due() {
  rm -f "$STATE/grossreinschiff.last-sweep"
  local out
  out=$(due_run 2026-08-06 09:00:00)
  assert_contains "$out" "GROSSREINSCHIFF:" "a home that never swept must be told the sweep is due"
  assert_contains "$out" "last swept: never" "the due line must say the home has never swept"
  out=$(due_run 2026-08-06 09:00:00 --status)
  assert_contains "$out" "due=yes" "--status must agree with the detect line"
  assert_contains "$out" "last-sweep=never" "--status must report an absent record as never"
  assert_contains "$out" "last-sweep-epoch=0" "an absent record must read as epoch 0"
  pass "an absent sweep record is due"
}

test_recorded_sweep_silences_the_rest_of_the_week() {
  rm -f "$STATE/grossreinschiff.last-sweep"
  due_run 2026-08-06 09:00:00 --record > /dev/null
  grep -Eq '^[0-9]+ 2026-08-06$' "$STATE/grossreinschiff.last-sweep" \
    || fail "--record must store the epoch and the date together, got: $(cat "$STATE/grossreinschiff.last-sweep")"
  local when out
  # Same Thursday evening, the Saturday after, and the Wednesday before the next
  # window opens: all inside the swept week.
  for when in '2026-08-06 18:00:00' '2026-08-08 11:00:00' '2026-08-12 23:59:59'; do
    # shellcheck disable=SC2086
    out=$(due_run ${when})
    [ -z "$out" ] || fail "sweep must stay silent at $when after a recorded sweep, got: $out"
  done
  out=$(due_run 2026-08-12 23:59:59 --status)
  assert_contains "$out" "due=no" "--status must report the swept week as not due"
  assert_contains "$out" "last-sweep=2026-08-06" "--status must report the recorded sweep date"
  pass "a recorded sweep silences the rest of its week"
}

test_next_thursday_reopens_the_window() {
  local out
  out=$(due_run 2026-08-13 00:00:00)
  assert_contains "$out" "GROSSREINSCHIFF:" "the next Thursday must make the sweep due again"
  assert_contains "$out" "last swept: 2026-08-06" "the due line must name the last completed sweep"
  assert_contains "$out" "open 0 day(s)" "a sweep due on Thursday itself is zero days into the window"
  pass "the next Thursday reopens the window"
}

# The window-open count is a position inside the CURRENT week's window, not a
# measure of lateness: it is days_back, bounded to 0 through 6. These two cases
# are the pair that proves it, so neither reads as a lateness check.
test_a_missed_week_stays_due_and_reports_its_window_position() {
  local out
  out=$(due_run 2026-08-17 08:30:00)
  assert_contains "$out" "GROSSREINSCHIFF:" "a missed Thursday must stay due, not be skipped"
  assert_contains "$out" "open 4 day(s)" \
    "the Monday after a missed Thursday is four days into the current window"
  pass "a missed week stays due and reports its position in the current window"
}

test_a_home_dark_for_weeks_reports_a_low_window_count() {
  local out
  # Last swept 2026-08-06, waking three Thursdays later. Three weeks dark, and
  # the window count still reads 0, while the four-days-late case above reads 4.
  out=$(due_run 2026-08-27 09:00:00)
  assert_contains "$out" "GROSSREINSCHIFF:" "a home dark for weeks must still be told the sweep is due"
  assert_contains "$out" "open 0 day(s)" \
    "the window count must NOT grow with staleness - it is a window position, bounded 0..6"
  assert_contains "$out" "last swept: 2026-08-06" \
    "the last-swept date is the field that carries how many weeks were missed"
  out=$(due_run 2026-08-27 09:00:00 --status)
  assert_contains "$out" "window-open-days=0" "--status must report the same bounded window position"
  assert_contains "$out" "last-sweep=2026-08-06" "--status must carry the staleness in the date"
  pass "a home dark for weeks reports a low window count, and its last-swept date carries the staleness"
}

test_a_corrupt_record_reads_as_never_swept() {
  local out
  printf 'not-an-epoch garbage\n' > "$STATE/grossreinschiff.last-sweep"
  out=$(due_run 2026-08-08 11:00:00)
  assert_contains "$out" "last swept: never" \
    "an unparseable record must make the sweep due rather than silently skip it"
  : > "$STATE/grossreinschiff.last-sweep"
  out=$(due_run 2026-08-08 11:00:00 --status)
  assert_contains "$out" "due=yes" "an empty record must make the sweep due"
  rm -f "$STATE/grossreinschiff.last-sweep"
  pass "a corrupt or empty record reads as never swept"
}

test_bad_input_refuses_instead_of_guessing() {
  local out status
  out=$(FM_STATE_OVERRIDE="$STATE" "$DUE" --sweep-everything 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument must exit 2, got $status"
  assert_contains "$out" "unknown argument" "an unknown argument must say so"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_GROSSREINSCHIFF_CLOCK="nonsense" "$DUE" 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "an unusable clock must exit 2, got $status"
  assert_contains "$out" "unusable clock" "an unusable clock must say so"
  pass "bad input refuses instead of guessing a verdict"
}

test_help_comes_from_the_header() {
  local out
  out=$("$DUE" --help)
  assert_contains "$out" "Thursday 00:00 local" "help must state the cadence rule"
  assert_contains "$out" "--record" "help must document every mode"
  assert_contains "$out" "no scheduler" "help must state why there is no scheduler of its own"
  pass "--help renders the header block, so the two cannot drift"
}

# --- bootstrap surfacing ----------------------------------------------------

# run_bootstrap <home> [extra env assignments...]: run the real bootstrap
# against a fixture home. FM_ROOT_OVERRIDE points the tangle guard at the
# non-git fixture so the ambient feature-branch checkout cannot leak a TANGLE
# line in, exactly as tests/fm-bootstrap.test.sh does. Output is grepped rather
# than compared whole, so this stays a test of the cadence line and not of
# every other bootstrap check.
run_bootstrap() {
  local home=$1
  shift
  mkdir -p "$home/state" "$home/config"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$@" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_surfaces_the_due_line() {
  local out
  out=$(run_bootstrap "$TMPROOT/boot-due" \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" FM_GROSSREINSCHIFF_DISABLE=0)
  assert_contains "$out" "GROSSREINSCHIFF:" \
    "a real bootstrap run on a home that never swept must print the due line"

  # The detect pass runs whether or not the session holds the fleet lock, so a
  # read-only session still learns the sweep is owed.
  out=$(run_bootstrap "$TMPROOT/boot-readonly" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" FM_GROSSREINSCHIFF_DISABLE=0)
  assert_contains "$out" "GROSSREINSCHIFF:" \
    "the due line must still print in a read-only session, where it is advisory"
  pass "a real bootstrap run surfaces the due line, locked or read-only"
}

test_bootstrap_is_silent_once_the_home_has_swept() {
  local home out
  home="$TMPROOT/boot-swept"
  mkdir -p "$home/state"
  FM_STATE_OVERRIDE="$home/state" FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" \
    "$DUE" --record > /dev/null
  out=$(run_bootstrap "$home" \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-08 11:00:00)" FM_GROSSREINSCHIFF_DISABLE=0)
  assert_not_contains "$out" "GROSSREINSCHIFF:" \
    "bootstrap must stop printing the due line once the sweep is recorded"
  pass "bootstrap stops printing the due line once the home has swept"
}

test_disable_silences_detect_but_not_the_other_modes() {
  local home out
  home="$TMPROOT/disable"
  mkdir -p "$home/state"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_GROSSREINSCHIFF_DISABLE=1 \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" "$DUE")
  [ -z "$out" ] || fail "the disable knob must silence the detect line, got: $out"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_GROSSREINSCHIFF_DISABLE=1 \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" "$DUE" --status)
  assert_contains "$out" "due=yes" \
    "the disable knob must not change what --status reports, only whether detect prints"
  out=$(run_bootstrap "$TMPROOT/boot-disabled" \
    FM_GROSSREINSCHIFF_CLOCK="$(clock 2026-08-06 09:00:00)" FM_GROSSREINSCHIFF_DISABLE=1)
  assert_not_contains "$out" "GROSSREINSCHIFF:" \
    "the disable knob must keep the line out of suites that compose bootstrap"
  pass "the disable knob silences detect only, and never changes the verdict"
}

# --- the landedness ladder --------------------------------------------------
#
# Property 2 of the skill: never judge landedness by ancestry, because this
# fleet squashes. These build the squash flow and prove each rung.

ladder_fixture() {
  local repo=$1
  fm_git_init_commit "$repo"
  git -C "$repo" checkout -q -b feature
  printf 'the branch change\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'feature work'
  git -C "$repo" checkout -q master 2>/dev/null || git -C "$repo" checkout -q main
  git -C "$repo" merge -q --squash feature >/dev/null
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'squashed feature'
}

default_ref() {
  git -C "$1" rev-parse --verify -q main >/dev/null && printf 'main\n' || printf 'master\n'
}

test_ancestry_calls_landed_work_unmerged() {
  local repo def
  repo="$TMPROOT/ladder-a"
  ladder_fixture "$repo"
  def=$(default_ref "$repo")
  if git -C "$repo" merge-base --is-ancestor feature "$def" 2>/dev/null; then
    fail "fixture is wrong: a squash merge must leave the branch un-ancestored"
  fi
  pass "ancestry reports squash-landed work as unmerged, which is why it is banned as a verdict"
}

test_patch_id_settles_the_squash_flow() {
  local repo def squash branch_patch squash_patch
  repo="$TMPROOT/ladder-p"
  ladder_fixture "$repo"
  def=$(default_ref "$repo")
  squash=$(git -C "$repo" rev-parse "$def")
  branch_patch=$(git -C "$repo" diff "$(git -C "$repo" merge-base "$def" feature)" feature \
    | git patch-id --stable | awk '{print $1}')
  squash_patch=$(git -C "$repo" diff "$squash^" "$squash" | git patch-id --stable | awk '{print $1}')
  [ -n "$branch_patch" ] || fail "the branch produced no patch-id"
  [ "$branch_patch" = "$squash_patch" ] \
    || fail "patch-id must equate the branch diff with its squash commit's diff"
  git -C "$repo" merge-base --is-ancestor "$squash" "$def" \
    || fail "the squash commit must be verified as an ancestor of the default branch"
  pass "patch-id settles a squash-landed branch that ancestry calls unmerged"
}

test_content_test_is_inconclusive_once_the_default_branch_moves_on() {
  local repo def merged status default_tree
  repo="$TMPROOT/ladder-c"
  ladder_fixture "$repo"
  def=$(default_ref "$repo")
  default_tree=$(git -C "$repo" rev-parse "$def^{tree}")

  # Before the default branch touches the file again, merge-tree is conclusive.
  merged=$(git -C "$repo" merge-tree --write-tree "$def" feature) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "merge-tree should still be conclusive before the file is edited again"
  [ "$(printf '%s\n' "$merged" | head -1)" = "$default_tree" ] \
    || fail "a landed branch must add nothing to the default branch"

  # Now the default branch edits the same file, as two weeks of main would.
  printf 'the branch change, revised on the default branch\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'later work on the same file'
  merged=$(git -C "$repo" merge-tree --write-tree "$def" feature 2>/dev/null) && status=0 || status=$?
  [ "$status" -ne 0 ] \
    || fail "fixture is wrong: merge-tree should conflict once the default branch edits the same file"
  default_tree=$(git -C "$repo" rev-parse "$def^{tree}")
  [ "$(printf '%s\n' "$merged" | head -1)" != "$default_tree" ] \
    || fail "the conflict tree should not equal the default tree"
  pass "the content test goes inconclusive once the default branch edits the same file, so its exit status must be read"
}

# E's condition in isolation is trivially true for far more branches than E is
# meant to catch, which is why these test it through the ORDER of the ladder.
# Checking the condition alone is what let the unreachable-rung defect through.
test_empty_branch_is_vacuously_landed_only_because_e_precedes_c() {
  local repo def base_tree tip_tree merged status
  repo="$TMPROOT/ladder-e"
  fm_git_init_commit "$repo"
  def=$(default_ref "$repo")
  git -C "$repo" checkout -q -b empty
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m 'no content'
  base_tree=$(git -C "$repo" rev-parse "$(git -C "$repo" merge-base "$def" empty)^{tree}")
  tip_tree=$(git -C "$repo" rev-parse 'empty^{tree}')
  [ "$base_tree" = "$tip_tree" ] || fail "an empty commit must leave the tree unchanged"

  # A is inconclusive here, so the branch really does reach the later rungs.
  if git -C "$repo" merge-base --is-ancestor empty "$def" 2>/dev/null; then
    fail "fixture is wrong: the empty branch must not be an ancestor of the default branch"
  fi

  # C would absorb it first: a content-free branch cannot make merge-tree
  # conflict, so C exits 0 with the default branch's own tree and settles it as
  # plain landed. That is why E has to be consulted before C, or it never fires.
  merged=$(git -C "$repo" merge-tree --write-tree "$def" empty) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a content-free branch must not make merge-tree conflict"
  [ "$(printf '%s\n' "$merged" | head -1)" = "$(git -C "$repo" rev-parse "$def^{tree}")" ] \
    || fail "C would otherwise settle the empty branch as plain landed, which is the point of this test"
  pass "an empty branch is vacuously landed only because E is consulted before C"
}

test_e_before_ancestry_would_mislabel_a_landed_branch() {
  local repo def base_tree tip_tree
  repo="$TMPROOT/ladder-e-order"
  fm_git_init_commit "$repo"
  def=$(default_ref "$repo")
  git -C "$repo" checkout -q -b ancestored
  printf 'real content, really landed\n' > "$repo/landed.txt"
  git -C "$repo" add landed.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'real work'
  git -C "$repo" checkout -q "$def"
  git -C "$repo" merge -q --ff-only ancestored

  git -C "$repo" merge-base --is-ancestor ancestored "$def" \
    || fail "fixture is wrong: this branch must be an ancestor of the default branch"
  # The merge base IS the branch, so E's tree equality holds on a branch that
  # carries real content. Placed before A, E would call every ordinarily landed
  # branch "landed (vacuous)".
  base_tree=$(git -C "$repo" rev-parse "$(git -C "$repo" merge-base "$def" ancestored)^{tree}")
  tip_tree=$(git -C "$repo" rev-parse 'ancestored^{tree}')
  [ "$base_tree" = "$tip_tree" ] \
    || fail "an ancestor branch must satisfy E's condition trivially - that is the trap"
  [ -s "$repo/landed.txt" ] || fail "the branch must carry real content for the mislabel to matter"
  pass "E placed before A would mislabel an ancestry-landed branch as vacuous, so A comes first"
}

test_ladder_order_is_a_p_e_c_x() {
  local order
  order=$(sed -n 's/^| \*\*\([APECX]\)\*\* |.*/\1/p' "$SKILL" | tr -d '\n')
  [ "$order" = "APECX" ] \
    || fail "the ladder must be applied A, P, E, C, X - the order is measured, got: $order"
  pass "the skill's ladder table states the measured A, P, E, C, X order"
}

test_x_is_withheld_from_a_branch_that_adds_no_paths() {
  local repo def added merged status
  repo="$TMPROOT/ladder-x"
  ladder_fixture "$repo"
  def=$(default_ref "$repo")
  # A modify-only branch: it touches a file the default branch already has and
  # adds nothing. Reached exactly where the skill says the ladder is routine.
  git -C "$repo" checkout -q -b modify-only
  printf 'revised, adding no new path\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'modify only'
  git -C "$repo" checkout -q "$def"
  printf 'the default branch edits the same file too\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'later work on README'

  if git -C "$repo" merge-base --is-ancestor modify-only "$def" 2>/dev/null; then
    fail "fixture is wrong: A must not settle this branch"
  fi
  git -C "$repo" merge-tree --write-tree "$def" modify-only >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "fixture is wrong: C must go inconclusive on the conflicting edit"

  added=$(git -C "$repo" diff --name-only --diff-filter=A \
    "$(git -C "$repo" merge-base "$def" modify-only)" modify-only)
  [ -z "$added" ] || fail "fixture is wrong: a modify-only branch must add no path, got: $added"
  # With an empty added-path set X's universal is vacuously true, so without the
  # precondition it would hand out a definitive not-landed verdict on nothing.
  assert_grep 'Precondition: the branch adds at least one path' "$SKILL" \
    "rung X must carry its precondition in the row a sweeper reads"
  assert_grep 'falls through to `undetermined`, never to `not landed`' "$SKILL" \
    "a branch that adds no path must fall through to undetermined"
  pass "a modify-only branch adds no path, so the documented precondition withholds X"
}

# --- instruction-surface contracts ------------------------------------------

test_skill_states_the_five_safety_properties() {
  local phrase
  for phrase in \
    'It reports before it deletes.' \
    'It never tests landedness by ancestry.' \
    'It never touches unlanded work, and a refusal is a stop-and-investigate result.' \
    'Each finding names its evidence' \
    'It states what it did NOT cover.'; do
    assert_grep "$phrase" "$SKILL" "the sweep skill lost safety property: $phrase"
  done
  assert_grep 'undetermined' "$SKILL" "the ladder must carry an undetermined verdict"
  assert_grep 'Never a deletion candidate' "$SKILL" \
    "an undetermined verdict must be barred from the deletion set"
  pass "the sweep skill states all five safety properties"
}

test_skill_covers_all_nine_checklist_items() {
  local n section
  for n in 1 2 3 4 5 6 7 8 9; do
    section=$(grep -c "^### $n\. " "$SKILL")
    [ "$section" -eq 1 ] || fail "checklist item $n must appear exactly once, found $section"
  done
  # Every item has to carry the evidence that put it there, or the next sweep
  # inherits a belief instead of re-measuring - property 4 applied to the skill.
  local evidence
  evidence=$(grep -c '^\*\*Evidence:\*\*' "$SKILL")
  [ "$evidence" -eq 9 ] || fail "each of the nine items needs an evidence line, found $evidence"
  pass "all nine checklist items are present and each names its evidence"
}

test_skill_never_promises_deletion_authority() {
  assert_grep 'standing `yolo` authority does not cover it' "$SKILL" \
    "the sweep must not read as covered by routine autonomy"
  assert_grep 'firstmate never performs the deletion itself' "$SKILL" \
    "deletion inside a project must stay a dispatched worker's task"
  assert_grep '## What this sweep did not cover' "$SKILL" \
    "the sweep must own a mandatory uncovered-scope section"
  pass "the sweep reports and never claims deletion authority"
}

test_cadence_is_reachable_from_the_instruction_surface() {
  assert_grep 'grossreinschiff' "$AGENTS" "AGENTS.md must name the sweep skill"
  assert_grep 'GROSSREINSCHIFF:' "$AGENTS" \
    "AGENTS.md section 13 must list the due line among the bootstrap diagnostics"
  assert_grep 'grossreinschiff.last-sweep' "$AGENTS" \
    "AGENTS.md section 2 must record the cadence state file"
  assert_grep 'GROSSREINSCHIFF: weekly fleet cleanup sweep is due' "$BOOTSTRAP_SKILL" \
    "bootstrap-diagnostics must own the response to the due line"
  assert_grep 'advisory only' "$BOOTSTRAP_SKILL" \
    "bootstrap-diagnostics must say the due line is advisory without the fleet lock"
  pass "the sweep is reachable from the instruction surface by both routes"
}

test_doc_owns_the_cadence_decision_and_its_alternatives() {
  local phrase
  for phrase in \
    'Scheduled wake' \
    'External timer' \
    'Fleet-wide notice' \
    'Known limits'; do
    assert_grep "$phrase" "$DOC" "the cadence decision must record the option it rejected: $phrase"
  done
  assert_grep 'Not a cadence' "$DOC" \
    "the doc must say a fleet-wide notice announces rather than schedules"
  pass "the doc owns the cadence decision, its alternatives, and its own limits"
}

test_doc_records_the_ladder_order_and_its_own_checklist_hits() {
  assert_grep 'The applied order is A → P → E → C → X' "$DOC" \
    "the doc must state the applied ladder order"
  assert_grep 'E must never be placed before A' "$DOC" \
    "the doc must record why E sits after the ancestry rung"
  assert_grep 'A(ancestry)=18  P(patch-id)=33  C(content)=1  undetermined=0' "$DOC" \
    "the published measurement must stay exactly as measured"
  assert_grep "## The sweep's own checklist, applied to the sweep" "$DOC" \
    "the doc must record that the checklist was run against this skill's own prose"
  pass "the doc records the ladder order and the hits the checklist scored on itself"
}

test_absent_record_is_due
test_recorded_sweep_silences_the_rest_of_the_week
test_next_thursday_reopens_the_window
test_a_missed_week_stays_due_and_reports_its_window_position
test_a_home_dark_for_weeks_reports_a_low_window_count
test_a_corrupt_record_reads_as_never_swept
test_bad_input_refuses_instead_of_guessing
test_help_comes_from_the_header
test_bootstrap_surfaces_the_due_line
test_bootstrap_is_silent_once_the_home_has_swept
test_disable_silences_detect_but_not_the_other_modes
test_ancestry_calls_landed_work_unmerged
test_patch_id_settles_the_squash_flow
test_content_test_is_inconclusive_once_the_default_branch_moves_on
test_empty_branch_is_vacuously_landed_only_because_e_precedes_c
test_e_before_ancestry_would_mislabel_a_landed_branch
test_ladder_order_is_a_p_e_c_x
test_x_is_withheld_from_a_branch_that_adds_no_paths
test_skill_states_the_five_safety_properties
test_skill_covers_all_nine_checklist_items
test_skill_never_promises_deletion_authority
test_cadence_is_reachable_from_the_instruction_surface
test_doc_owns_the_cadence_decision_and_its_alternatives
test_doc_records_the_ladder_order_and_its_own_checklist_hits
