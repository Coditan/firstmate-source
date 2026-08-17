#!/usr/bin/env bash
# Behavior tests for the run-decisionboard driver.
#
# The driver exists because a seven-decision board reached the captain on
# 2026-08-17 with no way to answer it: every decision carried its options in
# prose and nothing on the page could be clicked. These tests pin the two things
# that would let that recur silently - a board whose decisions carry no controls
# reported as fine, and a screenshot reported as taken when nothing was written.
#
# The browser hops cannot run here: the machine CI runs on has no Chrome bridge,
# and the ones that do share the host with another UNIX account. So the readers
# are exercised through FM_RUN_DECISIONBOARD_SNAPSHOT, the driver's own test
# seam, against accessibility snapshots RECORDED from real boards driven on
# crew-hlr on 2026-08-17 - not invented, which is the failure mode this whole
# skill was written about. The full browser loop stays behind `selftest`, which
# is what a host with a bridge runs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$ROOT/.agents/skills/run-decisionboard/fm-run-decisionboard.sh"
SKILL="$ROOT/.agents/skills/run-decisionboard/SKILL.md"
fm_test_tmproot TMP_ROOT fm-run-decisionboard

# --- recorded snapshots -----------------------------------------------------

# An answerable board: two decisions, each with radios, a note field and a
# submit button. Recorded verbatim, INCLUDING the literal newline inside the
# LineBreak node's accessible name - a `<br>` in an option label puts the opening
# quote on one line and the closing quote on the next. A line-oriented parser
# reads that stray quote at column zero as a top-level node and walks out of the
# artifact frame, which is exactly how this parser first reported this board as
# one decision with no note field and no submit button.
answerable_snapshot() {
  cat <<'SNAP'
page:
  title: Probebrett · Lavish
  refs: 45
snapshot:
uid=g1159:76_0 RootWebArea "Probebrett · Lavish" url="http://crew-hlr.tail7b8448.ts.net:4451/session/4c8194ee373f1b68"
  uid=g1159:76_1 StaticText "Lavish"
  uid=g1159:76_5 Iframe
    uid=g1159:76_6 RootWebArea "Probebrett" url="http://crew-hlr.tail7b8448.ts.net:4451/artifact/4c8194ee373f1b68/index.html?artifact_revision=1&artifact_load_token=T0xDYLjFa639uKBXqtDMdLg7GCEfaIuj"
      uid=g1159:76_7 heading "Probebrett" level="1"
      uid=g1159:76_11 StaticText "Probe-Entscheidung A"
      uid=g1159:76_15 form
        uid=g1159:76_16 radio "Option eins Die Option, die der Treiber wählt."
        uid=g1159:76_17 StaticText "Option eins"
        uid=g1159:76_18 LineBreak "
"
        uid=g1159:76_19 StaticText "Die Option, die der Treiber wählt."
        uid=g1159:76_20 radio "Option zwei Bleibt ungewählt."
        uid=g1159:76_24 textbox "Begründung (optional)" multiline
        uid=g1159:76_25 button "Antwort vormerken"
      uid=g1159:76_26 DisclosureTriangle "0 weitere Aufzeichnungen zu dieser Untersuchung" expandable
      uid=g1159:76_28 StaticText "Probe-Entscheidung B"
      uid=g1159:76_30 form
        uid=g1159:76_31 radio "Ja"
        uid=g1159:76_33 radio "Nein"
        uid=g1159:76_35 textbox "Begründung (optional)" multiline
        uid=g1159:76_36 button "Antwort vormerken"
  uid=g1159:76_38 complementary
    uid=g1159:76_39 heading "Conversation" level="2"
    uid=g1159:76_41 StaticText "Your agent is not listening. If this persists, ask your agent to poll for updates from Lavish."
    uid=g1159:76_44 button "Send to Agent"
SNAP
}

# The defect itself, reproduced as a real board and recorded: two decision cards
# whose options are prose. Nothing on this page can be clicked.
prose_snapshot() {
  cat <<'SNAP'
page:
  title: Prosabrett · Lavish
  refs: 27
snapshot:
uid=g1162:79_0 RootWebArea "Prosabrett · Lavish" url="http://crew-hlr.tail7b8448.ts.net:4451/session/5d6d578cac0d7722"
  uid=g1162:79_5 Iframe
    uid=g1162:79_6 RootWebArea "Prosabrett" url="http://crew-hlr.tail7b8448.ts.net:4451/artifact/5d6d578cac0d7722/index.html?artifact_revision=1&artifact_load_token=xIVWfrWlgoMBbP2Ux-O0BO0fh1gqp8YT"
      uid=g1162:79_11 StaticText "Entscheidung ohne Bedienelemente"
      uid=g1162:79_13 StaticText "Option A:"
      uid=g1162:79_15 StaticText "Option B:"
      uid=g1162:79_18 StaticText "Zweite Entscheidung ohne Bedienelemente"
  uid=g1162:79_20 complementary
    uid=g1162:79_23 StaticText "Your agent is not listening. If this persists, ask your agent to poll for updates from Lavish."
    uid=g1162:79_26 button "Send to Agent"
SNAP
}

# A board answerable in appearance only: options to pick, nowhere to send them.
optionless_send_snapshot() {
  cat <<'SNAP'
page:
  title: Halbbrett · Lavish
snapshot:
uid=g1:1_0 RootWebArea "Halbbrett · Lavish" url="http://example.invalid/session/x"
  uid=g1:1_5 Iframe
    uid=g1:1_6 RootWebArea "Halbbrett" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"
      uid=g1:1_7 form
        uid=g1:1_8 radio "Ja"
        uid=g1:1_9 radio "Nein"
SNAP
}

# A decision form carrying nothing at all. The parser must still count the form,
# or a decision whose options are prose is invisible rather than reported - and
# invisible is what let the original board ship.
empty_form_snapshot() {
  cat <<'SNAP'
page:
  title: Leerbrett · Lavish
snapshot:
uid=g2:1_0 RootWebArea "Leerbrett · Lavish" url="http://example.invalid/session/x"
  uid=g2:1_5 Iframe
    uid=g2:1_6 RootWebArea "Leerbrett" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"
      uid=g2:1_7 form
      uid=g2:1_8 StaticText "Option A: das eine. Option B: das andere."
SNAP
}

# query_with <snapshot-producer> runs the driver's reader against that recorded
# snapshot and sets QUERY_OUT and QUERY_STATUS in the CALLING shell. Both matter
# to every caller, and a command substitution would run this in a subshell and
# lose the status - which is the half that says whether the board is answerable.
QUERY_OUT=''
QUERY_STATUS=0
query_with() {  # <snapshot-producer>
  local producer=$1 snap="$TMP_ROOT/snapshot.txt"
  "$producer" > "$snap"
  QUERY_STATUS=0
  QUERY_OUT=$(FM_RUN_DECISIONBOARD_SNAPSHOT="$snap" "$DRIVER" query 2>&1) || QUERY_STATUS=$?
}

# --- the driver is present and self-describing ------------------------------

test_driver_ships_beside_the_skill() {
  assert_present "$DRIVER" "the run-decisionboard driver is missing"
  [ -x "$DRIVER" ] || fail "the driver must be executable; SKILL.md tells an agent to run it directly"
  assert_present "$SKILL" "run-decisionboard has no SKILL.md"
  assert_grep 'fm-run-decisionboard.sh selftest' "$SKILL" \
    "SKILL.md must name the driver as the primary path"
  pass "the driver ships beside its skill and the skill points at it"
}

test_help_lists_the_whole_loop() {
  local out
  out=$("$DRIVER" --help 2>&1)
  local verb
  for verb in selftest doctor guard-check build open drive query shot answer send poll end; do
    assert_contains "$out" "fm-run-decisionboard.sh $verb" "help does not document '$verb'"
  done
  pass "help documents every hop of the loop"
}

# --- the board the driver builds --------------------------------------------

test_fixture_declares_the_documented_controls() {
  local body
  body=$("$DRIVER" fixture)
  # docs/board-layout.md "Decision controls" owns this markup. A fixture that
  # drifts from it would exercise a shape no real board has.
  local marker
  for marker in 'data-fm-question=' 'data-fm-label=' 'class="fm-opts"' 'class="fm-opt"' \
    'data-fm-note' 'class="fm-submit"' 'class="fm-queued"' 'class="fm-offline"'; do
    assert_contains "$body" "$marker" "the fixture board dropped $marker"
  done
  # The radio name must equal data-fm-question; board.js warns when it does not.
  assert_contains "$body" 'name="probe-a" value="option-eins"' \
    "the fixture's radio name must match its question key"
  pass "the fixture board declares the documented decision controls"
}

test_build_writes_a_board_that_passes_the_guard() {
  local out board
  board="$TMP_ROOT/built.html"
  out=$("$DRIVER" build --out "$board" --title "Testbrett" 2>&1) \
    || fail "build failed: $out"
  [ -s "$board" ] || fail "build reported success but wrote no board"
  "$ROOT/bin/fm-board.sh" --check "$board" >/dev/null 2>&1 \
    || fail "the board the driver builds does not pass fm-board.sh --check"
  pass "build writes a board that passes the no-network guard"
}

test_guard_check_proves_the_refusal() {
  local out status=0
  out=$("$DRIVER" guard-check 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "guard-check failed on a healthy builder: $out"
  assert_contains "$out" "refused" "guard-check must report the refusal it observed"
  pass "guard-check proves the no-network guard still bites"
}

# --- the readers, against recorded snapshots --------------------------------

test_parser_survives_a_newline_inside_an_accessible_name() {
  local inv
  inv=$(answerable_snapshot | "$DRIVER" parse)
  # The regression: the LineBreak node's embedded newline used to end the walk,
  # losing decision 2 entirely along with both note fields and both buttons.
  [ "$(printf '%s\n' "$inv" | awk -F'\t' '{print $1}' | sort -u | wc -l)" -eq 2 ] \
    || fail "the parser did not find both decisions"$'\n'"$inv"
  [ "$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "button"' | wc -l)" -eq 2 ] \
    || fail "the parser lost a submit button to the embedded newline"$'\n'"$inv"
  [ "$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "textbox"' | wc -l)" -eq 2 ] \
    || fail "the parser lost a note field to the embedded newline"$'\n'"$inv"
  pass "a newline inside an accessible name does not end the walk"
}

test_parser_ignores_the_editor_chrome() {
  local inv
  inv=$(answerable_snapshot | "$DRIVER" parse)
  # "Send to Agent" lives in the Lavish chrome, outside the artifact frame.
  # Counting it as a decision's submit button would make an optionless board
  # look answerable.
  assert_not_contains "$inv" "Send to Agent" \
    "the parser must not read the editor chrome as board content"
  pass "the parser reads the artifact frame only"
}

test_query_accepts_an_answerable_board() {
  query_with answerable_snapshot
  [ "$QUERY_STATUS" -eq 0 ] || fail "query rejected an answerable board"$'\n'"$QUERY_OUT"
  assert_contains "$QUERY_OUT" "decision cards: 2" "query must count both decisions"
  assert_contains "$QUERY_OUT" "with a submit button: 2" "query must see both submit buttons"
  pass "query accepts a board whose decisions can be answered"
}

test_query_refuses_a_board_with_options_in_prose() {
  query_with prose_snapshot
  [ "$QUERY_STATUS" -ne 0 ] \
    || fail "query passed the very board shape this skill exists to catch"$'\n'"$QUERY_OUT"
  assert_contains "$QUERY_OUT" "FINDING:" "query must report a finding, not just fail"
  assert_contains "$QUERY_OUT" "nothing on it can be answered" \
    "query must say plainly that the board cannot be answered"
  pass "query refuses a board whose decisions carry only prose"
}

test_query_refuses_a_board_with_no_way_to_submit() {
  query_with optionless_send_snapshot
  [ "$QUERY_STATUS" -ne 0 ] \
    || fail "query passed a board whose selection has nowhere to go"$'\n'"$QUERY_OUT"
  assert_contains "$QUERY_OUT" "no submit button" "query must name the missing submit button"
  pass "query refuses a board whose selection has nowhere to go"
}

test_query_counts_a_decision_form_that_carries_nothing() {
  query_with empty_form_snapshot
  [ "$QUERY_STATUS" -ne 0 ] \
    || fail "query passed a decision form with no controls at all"$'\n'"$QUERY_OUT"
  assert_contains "$QUERY_OUT" "decision cards: 1" \
    "an empty decision form must still be counted, or it is invisible rather than reported"
  assert_contains "$QUERY_OUT" "no selectable options" \
    "query must name the missing options"
  pass "query counts a decision form that carries nothing and reports it"
}

test_query_reports_an_unlistened_board() {
  query_with answerable_snapshot
  # A poll dies with the session that armed it, and a board listening to nobody
  # is indistinguishable from a healthy one in a screenshot.
  assert_contains "$QUERY_OUT" "poll listening: no" "query must report the on-screen listening state"
  assert_contains "$QUERY_OUT" "no poll is armed" "query must call an unlistened board out as a finding"
  pass "query reports a board that is listening to nobody"
}

# --- the screenshot, which is the one that lies -----------------------------

test_shot_refuses_a_screenshot_that_wrote_nothing() {
  # The measured failure: to a path it cannot write, the bridge EXITS 0, PRINTS
  # THE PATH, and writes nothing. A driver that trusts the exit status reports
  # evidence it does not have.
  local shot_tmp fakebin out status=0
  fm_test_tmproot shot_tmp fm-run-db-shot
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" != "screenshot" ] || printf 'screenshot: %s\n' "$2"
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging"
  out=$(PATH="$fakebin:$PATH" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot reported success for a screenshot that was never written"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot wrote a destination file with no screenshot behind it"
  assert_contains "$out" "wrote no screenshot" "shot must say the file is missing, not that it failed vaguely"
  pass "shot refuses a screenshot that exited 0 and wrote nothing"
}

test_shot_refuses_a_stale_staging_file() {
  # The staging path is stable, because a file owned by the bridge account in a
  # sticky /tmp cannot be deleted from here and a unique name would leave one
  # orphan per run. The cost of a stable name is that "the file is there" stops
  # being proof, so a run that captured nothing must not pass on the last run's
  # file.
  local shot_tmp fakebin out status=0
  fm_test_tmproot shot_tmp fm-run-db-stale
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging"
  printf 'the previous run left this behind\n' \
    > "$shot_tmp/staging/fm-run-decisionboard-shot.$(id -un).png"
  out=$(PATH="$fakebin:$PATH" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot passed on a staging file this run never touched"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot copied a stale staging file to the destination"
  assert_contains "$out" "unchanged" "shot must say the staging file is from an earlier run"
  pass "shot refuses a staging file this run did not refresh"
}

# --- the skill's own contract -----------------------------------------------

test_skill_records_the_measured_host_facts() {
  # Each of these was hit on this host and each one costs a session if it has to
  # be rediscovered. They are in the skill because an agent reaching past the
  # driver meets them in the same order.
  local fact
  for fact in 'ERR_FILE_NOT_FOUND' 'ERR_CONNECTION_REFUSED' 'allow-same-origin' \
    'Stale ref' 'chromium-cli' 'Your agent is not listening'; do
    assert_grep "$fact" "$SKILL" "SKILL.md lost the measured fact: $fact"
  done
  assert_grep 'never hardcode a port' "$SKILL" "SKILL.md must forbid a hardcoded Lavish port"
  pass "SKILL.md records the measured host facts the driver is built around"
}

test_skill_is_triggered_from_the_instruction_surface() {
  # A skill nothing loads is dead weight; firstmate-coding-guidelines requires
  # the trigger inline, and this one is captain-invocable so it lives in the
  # captain-etiquette section rather than section 13.
  # shellcheck disable=SC2016  # a literal instruction line, backticks and all.
  assert_grep 'load the `run-decisionboard` skill' "$ROOT/AGENTS.md" \
    "AGENTS.md must declare when to load run-decisionboard"
  pass "AGENTS.md declares the run-decisionboard load trigger"
}

test_driver_is_in_the_canonical_lint_set() {
  # A driver an agent is told to run is held to the same bar as bin/.
  assert_grep '.agents/skills/*/*.sh' "$ROOT/bin/fm-lint.sh" \
    "fm-lint.sh must lint skill drivers alongside bin/"
  pass "the driver is inside the canonical lint set"
}

test_driver_ships_beside_the_skill
test_help_lists_the_whole_loop
test_fixture_declares_the_documented_controls
test_build_writes_a_board_that_passes_the_guard
test_guard_check_proves_the_refusal
test_parser_survives_a_newline_inside_an_accessible_name
test_parser_ignores_the_editor_chrome
test_query_accepts_an_answerable_board
test_query_refuses_a_board_with_options_in_prose
test_query_refuses_a_board_with_no_way_to_submit
test_query_counts_a_decision_form_that_carries_nothing
test_query_reports_an_unlistened_board
test_shot_refuses_a_screenshot_that_wrote_nothing
test_shot_refuses_a_stale_staging_file
test_skill_records_the_measured_host_facts
test_skill_is_triggered_from_the_instruction_surface
test_driver_is_in_the_canonical_lint_set
