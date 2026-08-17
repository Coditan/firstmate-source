#!/usr/bin/env bash
# Tests for the read side of the captain-decision store: that a settled decision
# survives the session and the retention that took it, that a decision record which
# was started and never finished is detectable, and that the surfaces which present
# open decisions stop presenting an answered one.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-decision-ledger.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
fm_test_tmproot TMP_ROOT fm-decision-ledger

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <args...>
  local home=$1; shift
  (cd "$home" && tasks-axi "$@")
}

run_hold() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@"
}

run_ledger() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$LEDGER" "$@"
}

run_bearings() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-17T12:00:00Z \
    "$BEARINGS" --json "$@"
}

# A decision must outlive the session that took it AND the retention that rotates
# its record out of the live backlog, because both of those are exactly what the
# three temporary homes it used to live in did not.
test_settled_decision_survives_retention_into_the_archive() {
  local home json
  home=$(make_home survives-retention)
  printf 'containment is the missing half\n' > "$home/d.txt"
  run_hold "$home" record tier-review tier-overlap --door chat --decision-file "$home/d.txt" \
    --title "Where does the tier boundary sit" --repo firstmate >/dev/null 2>&1 \
    || fail "recording the chat decision failed"

  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    tasks_in "$home" add "filler-$i" "filler $i" --kind ship --repo sample >/dev/null
    tasks_in "$home" "done" "filler-$i" >/dev/null
  done
  assert_grep "tier-review-decision-tier-overlap" "$home/data/done-archive.md" \
    "retention must have rotated the decision record into the archive"
  if grep -q "tier-review-decision-tier-overlap" "$home/data/backlog.md"; then
    fail "the decision record should no longer be in the live backlog for this case"
  fi

  json=$(run_ledger "$home" --json --all) || fail "the ledger could not read the archive"
  assert_contains "$json" '"settled_total": 1' \
    "an archived decision must still be readable; the archive is what survives cleanup"
  assert_contains "$json" '"decision": "containment is the missing half"' \
    "the captain's words must come back out of the archive unchanged"
  assert_contains "$json" '"verbatim": true' \
    "the archived text must verify against its recorded digest"
  assert_contains "$json" '"source": "archive"' \
    "the ledger must say where it read the record from"

  pass "a settled decision survives retention into the archive and still reads verbatim"
}

# The digest is the whole basis for calling the stored text "his words". If a later
# edit could pass unnoticed, the claim is decoration.
test_an_edited_decision_stops_reading_as_verified() {
  local home audit rc=0
  home=$(make_home altered-record)
  printf '6 stunden\n' > "$home/d.txt"
  run_hold "$home" record bridge rpo --door ask-user --decision-file "$home/d.txt" \
    --title "Recovery point objective" --repo bridge >/dev/null 2>&1 \
    || fail "recording failed"

  sed -i.bak 's/^  6 stunden$/  12 stunden/' "$home/data/backlog.md"
  audit=$(run_ledger "$home" --audit) || rc=$?
  [ "$rc" -eq 1 ] || fail "an altered record must make the audit report a finding"
  assert_contains "$audit" "altered-record bridge-decision-rpo" \
    "the audit must name the record whose text no longer matches its digest"

  pass "an edited decision stops reading as verified instead of passing as his word"
}

# The recovery-point case of 2026-08-17: answered, acted on, and the hold left open
# with nothing detecting it. This is the shape that must not be silent again.
test_audit_finds_every_way_a_close_can_be_unfinished() {
  local home audit rc=0
  home=$(make_home unfinished-closes)

  # acted-but-open: the hold still holds, and every task it gates is finished.
  tasks_in "$home" add "rpo-decision-window" "How much data may we lose" \
    --kind captain --repo bridge >/dev/null
  tasks_in "$home" hold "rpo-decision-window" --reason "captain decision pending" --kind captain >/dev/null
  tasks_in "$home" add "rpo-impl" "implement the window" --kind ship --repo bridge \
    --blocked-by "rpo-decision-window" >/dev/null
  tasks_in "$home" "done" "rpo-impl" >/dev/null

  # closed-without-record: the question is gone and the answer was never stored.
  tasks_in "$home" add "cw-decision-tier" "Which tier owns containment" \
    --kind captain --repo firstmate >/dev/null
  tasks_in "$home" "done" "cw-decision-tier" >/dev/null

  # unfinished-close: the decision is written, the close stopped before Done.
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: abc\nRouted identities: none\nDoor: chat\n\nCaptain decision:\nja\n\nRouted work:\n- (none)\n' \
    > "$home/partial.txt"
  tasks_in "$home" add "uc-decision-sweep" "Ship the sweep" --kind captain --repo firstmate \
    --body-file "$home/partial.txt" >/dev/null

  audit=$(run_ledger "$home" --audit) || rc=$?
  [ "$rc" -eq 1 ] || fail "the audit must exit nonzero when findings exist, so a caller can gate on it"
  assert_contains "$audit" "acted-but-open rpo-decision-window" \
    "a hold whose gated work is all done must be reported; this is the case nothing caught"
  assert_contains "$audit" "closed-without-record cw-decision-tier" \
    "a captain item closed with no stored answer must be reported"
  assert_contains "$audit" "unfinished-close uc-decision-sweep" \
    "a written-but-unclosed decision must be reported"

  pass "the audit finds every way a captain decision record can be left unfinished"
}

# The structural duplicate classes are a backstop, and a backstop that cries wolf
# gets read past in the one session that mattered. An investigation legitimately
# raises several distinct questions; a panel's members legitimately each file the
# same one. Only the second is a duplicate.
test_the_duplicate_backstop_separates_distinct_questions_from_repeated_ones() {
  local home audit rc=0 k m
  home=$(make_home duplicate-backstop)
  for k in route access; do
    tasks_in "$home" add "review-decision-$k" "Choose the $k" --kind captain --repo s >/dev/null
    tasks_in "$home" hold "review-decision-$k" --reason "pending" --kind captain >/dev/null
  done
  run_ledger "$home" --audit >/dev/null \
    || fail "two distinct questions from one investigation must not be reported as duplicates"

  for m in a b judge; do
    tasks_in "$home" add "panel-$m-decision-scope" "What is in scope" --kind captain --repo s >/dev/null
    tasks_in "$home" hold "panel-$m-decision-scope" --reason "pending" --kind captain >/dev/null
  done
  audit=$(run_ledger "$home" --audit) || rc=$?
  [ "$rc" -eq 1 ] || fail "one question held open by three panel members must be reported"
  assert_contains "$audit" "duplicate-suspect panel-a-decision-scope" \
    "the panel-shaped duplicate must be named"
  assert_contains "$audit" "panel-judge-decision-scope" \
    "every record in the suspected group must be listed, so none is folded unseen"
  pass "the duplicate backstop separates distinct questions from one question repeated"
}

# A clean home must say nothing, or the alarm becomes background noise and the one
# session where it matters reads past it.
test_a_clean_home_reports_no_findings() {
  local home out
  home=$(make_home clean-audit)
  printf 'ja\n' > "$home/d.txt"
  run_hold "$home" record origin-a key-a --door chat --decision-file "$home/d.txt" \
    --title "Shall we" --repo sample >/dev/null 2>&1 || fail "recording failed"
  out=$(run_ledger "$home" --audit) \
    || fail "a home with no unfinished record must exit 0"
  assert_contains "$out" "no unfinished captain decision records" \
    "a clean audit must say so plainly"
  pass "a home with no unfinished decision record reports no findings and exits clean"
}

# Requirement four, stated as a test: an answered decision must stop being offered
# to the captain as a question. Bearings is the surface the decision board reads.
test_an_answered_decision_is_no_longer_presented_as_open() {
  local home json
  home=$(make_home answered-not-open)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] a-decision-open - A genuinely open question (repo: firstmate) (kind: captain) (since 2026-08-17) (hold: captain decision pending) (hold-kind: captain)
  Origin: a
  Decision key: open
- [ ] b-decision-answered - An answered question whose close did not finish (repo: firstmate) (kind: captain) (since 2026-08-17) (hold: captain decision pending) (hold-kind: captain)
  Resolution recorded by fm-decision-hold.
  Decision digest: abc
  Routed identities: none
  Door: chat

  Captain decision:
  ja

  Routed work:
  - (none)

## Done
EOF
  json=$(run_bearings "$home" --all-decisions --all-queued) || fail "bearings failed"
  assert_contains "$json" '"a-decision-open"' \
    "a genuinely open captain question must still reach the open-decision surface"
  if printf '%s' "$json" | jq -e '[.decisions_open[].id] | index("b-decision-answered")' >/dev/null 2>&1; then
    fail "an answered decision must not be presented as an open question"
  fi
  assert_contains "$json" "answered; close unfinished" \
    "the answered record must stay visible with an honest reason, not vanish"

  pass "an answered decision leaves the open-decision surface and says why"
}

# The case no matcher can catch, and the reason the fold is the filer's act: two
# successive passes over one piece of code asked the same question in entirely
# different vocabulary - whether a named company counts as a customer, and which
# parties count as intra-group. No shared wording, no shared key, no shared origin.
# Both were filed CORRECTLY under the rule as it stood.
test_a_second_question_cannot_be_filed_without_disposing_of_the_first() {
  local home out
  home=$(make_home intake-gate)
  : > "$home/state/pass-one.meta"
  : > "$home/state/pass-two.meta"
  run_hold "$home" hold pass-one customer-scope --title "Does Acme count as a customer" \
    --reason "the customer term is undecided" --repo billing \
    --premise "the billing export treats Acme as external and no ruling exists" >/dev/null 2>&1 \
    || fail "the first question must file cleanly when nothing else is open"

  if out=$(run_hold "$home" hold pass-two intra-group-parties \
    --title "Which parties count as intra-group" --reason "the grouping rule is undecided" \
    --repo billing --premise "the export has no intra-group rule" 2>&1); then
    fail "a second captain question must not be filed without disposing of the first"
  fi
  assert_contains "$out" "pass-one-decision-customer-scope - Does Acme count as a customer" \
    "the refusal must put the existing question in front of the filer, not just refuse"
  assert_contains "$out" "--new-ground" "the refusal must state how to attest"

  run_hold "$home" hold pass-two intra-group-parties \
    --title "Which parties count as intra-group" --reason "the grouping rule is undecided" \
    --repo billing --premise "the export has no intra-group rule" \
    --supersedes pass-one-decision-customer-scope >/dev/null 2>&1 \
    || fail "filing with an explicit fold must succeed"

  out=$(run_ledger "$home" --records)
  assert_contains "$out" "superseded	pass-one-decision-customer-scope" \
    "the folded question must be closed as superseded"
  assert_contains "$out" "open	pass-two-decision-intra-group-parties" \
    "the successor must be the one open question"
  pass "a second question cannot be filed without disposing of the one already there"
}

# The other seat's shape: the captain had ruled hours earlier and the open records
# stayed open. An answer that cannot fold what it settles leaves it standing.
test_an_answer_folds_the_questions_it_settles() {
  local home show out
  home=$(make_home answer-folds)
  : > "$home/state/pass-one.meta"
  run_hold "$home" hold pass-one grouping --title "Which parties count as intra-group" \
    --reason "the grouping rule is undecided" --repo billing \
    --premise "the export has no intra-group rule" >/dev/null 2>&1 || fail "filing failed"

  printf 'intra-group heisst: gleiche muttergesellschaft.\n' > "$home/ruling.txt"
  run_hold "$home" record billing-ruling grouping --door chat --decision-file "$home/ruling.txt" \
    --title "What counts as intra-group" --repo billing \
    --supersedes pass-one-decision-grouping >/dev/null 2>&1 \
    || fail "recording an answer that folds an open question failed"

  show=$(tasks_in "$home" show pass-one-decision-grouping --full)
  assert_contains "$show" "state: done" "the settled question must be closed"
  assert_contains "$show" "Successor: billing-ruling-decision-grouping" \
    "the folded record must point at the record carrying the answer"
  assert_contains "$show" "the captain did not answer this record" \
    "a fold must never read as the captain having answered that record"

  out=$(run_ledger "$home")
  assert_contains "$out" "open captain questions: 0" \
    "nothing may remain open once the answer folded the question"
  assert_contains "$out" "intra-group heisst: gleiche muttergesellschaft." \
    "the answer must be readable in his own words"
  pass "an answer folds the open questions it settles and keeps the trail to them"
}

# Folding a question must take its gated work with it. Leaving the work pointing at
# a closed record strands it; dropping the edge outright lifts a gate nobody lifted.
test_a_fold_moves_the_work_the_question_gated() {
  local home out
  home=$(make_home fold-moves-gates)
  : > "$home/state/o1.meta"
  : > "$home/state/o2.meta"
  run_hold "$home" hold o1 scope --title "First question" --reason "undecided" \
    --repo widgets --premise "the scope rule is unwritten" >/dev/null 2>&1 || fail "filing failed"
  tasks_in "$home" add w1 "gated work" --kind ship --repo widgets --blocked-by o1-decision-scope >/dev/null
  tasks_in "$home" add w2 "other gated work" --kind ship --repo widgets --blocked-by o1-decision-scope >/dev/null

  run_hold "$home" hold o2 scope-v2 --title "Better question" --reason "undecided" \
    --repo widgets --premise "the scope rule is still unwritten" \
    --supersedes o1-decision-scope >/dev/null 2>&1 || fail "filing with a fold failed"
  out=$(tasks_in "$home" list --blocked --fields blocked_by)
  assert_contains "$out" "w1,queued,ship,widgets,gated work,o2-decision-scope-v2" \
    "gated work must follow the question to its successor, not strand on a closed record"
  assert_contains "$out" "w2,queued,ship,widgets,other gated work,o2-decision-scope-v2" \
    "every gated task must move, not just the first"

  printf 'scope heisst: nur direkte kunden.\n' > "$home/ruling.txt"
  run_hold "$home" record widgets-ruling scope --door chat --decision-file "$home/ruling.txt" \
    --title "What the scope rule is" --repo widgets \
    --supersedes o2-decision-scope-v2 >/dev/null 2>&1 || fail "recording the answer failed"
  out=$(tasks_in "$home" list --blocked --fields blocked_by)
  assert_contains "$out" "0 blocked tasks" \
    "once the successor carries the captain's answer the gate must lift, not re-attach"
  pass "a fold carries the work the question gated, and the answer lifts that gate"
}

# The dangerous one. A premise that could not be measured is not a premise that is
# false: the seat had moved and the wrong registration may still stand where it was
# found. A re-check that folded on that reading would close a live finding with
# nobody left who could see it.
test_an_unmeasurable_premise_is_never_treated_as_a_false_one() {
  local home out audit rc=0
  home=$(make_home premise-unmeasurable)
  : > "$home/state/gate-review.meta"
  run_hold "$home" hold gate-review wrong-repo \
    --title "The validation gate pushes to the wrong public repository" \
    --reason "the push target is wrong and unfixed" --repo firstmate \
    --premise "the validation registry maps this home to the wrong public repository" \
    >/dev/null 2>&1 || fail "filing failed"

  if out=$(run_hold "$home" recheck gate-review wrong-repo --outcome false --measured-at x 2>&1); then
    fail "an outcome outside the three must be refused"
  fi
  assert_contains "$out" "never infer unmeasurable as broken" \
    "the refusal must name the conflation it exists to prevent"

  out=$(run_hold "$home" recheck gate-review wrong-repo --outcome unmeasurable \
    --measured-at "the validation registry on this seat" \
    --note "registry empty here; the seat moved and the original machine is unreachable" 2>&1) \
    || fail "recording an unmeasurable reading failed"
  assert_contains "$out" "do not fold it" \
    "an unmeasurable reading must say plainly that it is not grounds to fold"

  out=$(run_ledger "$home" --records)
  assert_contains "$out" "open	gate-review-decision-wrong-repo" \
    "an unmeasurable premise must leave the record OPEN; folding it would close a live finding"

  audit=$(run_ledger "$home" --audit) || rc=$?
  [ "$rc" -eq 1 ] || fail "an unmeasurable premise must surface as a finding"
  assert_contains "$audit" "premise-unmeasurable gate-review-decision-wrong-repo" \
    "the audit must name the record whose premise is out of reach"
  assert_contains "$audit" "may still be live where it was made" \
    "the finding must say why it must not be folded"

  out=$(run_ledger "$home" --premises)
  assert_contains "$out" "never that it still holds" \
    "the sweep input must not imply the listed premises were verified"
  pass "a premise that could not be measured is surfaced, never folded as a false one"
}

test_settled_decision_survives_retention_into_the_archive
test_a_second_question_cannot_be_filed_without_disposing_of_the_first
test_an_answer_folds_the_questions_it_settles
test_a_fold_moves_the_work_the_question_gated
test_an_unmeasurable_premise_is_never_treated_as_a_false_one
test_an_edited_decision_stops_reading_as_verified
test_audit_finds_every_way_a_close_can_be_unfinished
test_the_duplicate_backstop_separates_distinct_questions_from_repeated_ones
test_a_clean_home_reports_no_findings
test_an_answered_decision_is_no_longer_presented_as_open
