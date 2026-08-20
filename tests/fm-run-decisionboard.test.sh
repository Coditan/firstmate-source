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

choice_only_snapshot() {
  cat <<'SNAP'
page:
  title: Auswahlbrett · Lavish
snapshot:
uid=g4:1_0 RootWebArea "Auswahlbrett · Lavish" url="http://example.invalid/session/x"
  uid=g4:1_5 Iframe
    uid=g4:1_6 RootWebArea "Auswahlbrett" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"
      uid=g4:1_7 form
        uid=g4:1_8 radio "Ja"
        uid=g4:1_9 radio "Nein"
        uid=g4:1_10 button "Antwort vormerken"
SNAP
}

generic_controls_snapshot() {
  cat <<'SNAP'
page:
  title: Generisches Brett · Lavish
snapshot:
uid=g5:1_0 RootWebArea "Generisches Brett · Lavish" url="http://example.invalid/session/x"
  uid=g5:1_5 Iframe
    uid=g5:1_6 RootWebArea "Generisches Brett" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"
      uid=g5:1_7 form
        uid=g5:1_8 radio "Ja"
        uid=g5:1_9 radio "Nein"
        uid=g5:1_10 textbox "Suche"
        uid=g5:1_11 button "Hilfe"
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
  pass "the executable driver ships beside its skill"
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
  out=$(FM_BOARD_VESSEL=testschiff "$DRIVER" build --out "$board" --title "Testbrett" 2>&1) \
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
  assert_contains "$QUERY_OUT" "with a button (role only): 2" "query must see both button roles"
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
  assert_contains "$QUERY_OUT" "no button at all" "query must name the missing button"
  pass "query refuses a board whose selection has nowhere to go"
}

test_query_distinguishes_note_evidence_from_button_shape() {
  query_with generic_controls_snapshot
  assert_contains "$QUERY_OUT" "with a note field: 0" \
    "query counted a single-line textbox as a note field"
  assert_contains "$QUERY_OUT" "FINDING:" \
    "query presented a board without a real note field as fully answerable"
  assert_contains "$QUERY_OUT" "role=button cannot distinguish submit from help or reset" \
    "query did not disclose the limit of button-role evidence"
  pass "query proves multiline notes and discloses button-role limits"
}

test_query_reports_missing_notes_without_refusing_them() {
  query_with choice_only_snapshot
  [ "$QUERY_STATUS" -eq 0 ] || fail "query rejected a valid choice-only answer"$'\n'"$QUERY_OUT"
  assert_contains "$QUERY_OUT" "FINDING:" "query must identify missing note fields as a defect"
  assert_contains "$QUERY_OUT" "does not fail today" \
    "query must explain why the missing note field remains report-only"
  pass "query reports missing note fields without rejecting choice-only answers"
}

test_query_can_refuse_missing_notes_when_the_contract_flips() {
  local snap="$TMP_ROOT/choice-only.txt" out status=0
  choice_only_snapshot > "$snap"
  out=$(FM_RUN_DECISIONBOARD_SNAPSHOT="$snap" FM_RUN_DECISIONBOARD_NOTE_REQUIRED=refuse \
    "$DRIVER" query 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "strict note mode accepted a decision without a note field"$'\n'"$out"
  assert_contains "$out" "FM_RUN_DECISIONBOARD_NOTE_REQUIRED=refuse" \
    "strict note mode did not explain its refusal"
  pass "strict note mode refuses decisions without note fields"
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

test_query_requests_the_full_snapshot_on_a_long_board() {
  # Measured 2026-08-19: a real seven-decision board's plain snapshot cut off
  # mid-way through card 6, and cmd_query reported "decision cards: 5". A
  # two-card fixture never exercises that call shape at all, so this test
  # fakes chrome-devtools-axi to behave the same way the real one does: the
  # plain `snapshot` call truncates, `snapshot --full` does not.
  local q_tmp fakebin full_file truncated_file out status=0 i
  fm_test_tmproot q_tmp fm-run-db-full-snapshot
  fakebin=$(fm_fakebin "$q_tmp")
  full_file="$q_tmp/full.txt"
  truncated_file="$q_tmp/truncated.txt"

  {
    printf 'uid=g1:1_0 RootWebArea "Board · Lavish" url="http://example.invalid/session/x"\n'
    printf '  uid=g1:1_1 Iframe\n'
    printf '    uid=g1:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"\n'
    for i in 1 2 3 4 5 6 7; do
      printf '      uid=g1:1_%s0 form\n' "$i"
      printf '        uid=g1:1_%s1 radio "Option eins Karte %s"\n' "$i" "$i"
      printf '        uid=g1:1_%s2 radio "Option zwei Karte %s"\n' "$i" "$i"
      printf '        uid=g1:1_%s3 textbox "Begründung (optional)" multiline\n' "$i"
      printf '        uid=g1:1_%s4 button "Antwort vormerken"\n' "$i"
    done
  } > "$full_file"

  # The un-full snapshot chrome-devtools-axi actually returns on this shape:
  # five complete cards, then the byte budget runs out mid-way through card
  # 6's own form line - not even that line survives intact - and card 7 never
  # appears at all. This is what the wire looked like on 2026-08-19.
  {
    printf 'uid=g1:1_0 RootWebArea "Board · Lavish" url="http://example.invalid/session/x"\n'
    printf '  uid=g1:1_1 Iframe\n'
    printf '    uid=g1:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html?artifact_revision=1"\n'
    for i in 1 2 3 4 5; do
      printf '      uid=g1:1_%s0 form\n' "$i"
      printf '        uid=g1:1_%s1 radio "Option eins Karte %s"\n' "$i" "$i"
      printf '        uid=g1:1_%s2 radio "Option zwei Karte %s"\n' "$i" "$i"
      printf '        uid=g1:1_%s3 textbox "Begründung (optional)" multiline\n' "$i"
      printf '        uid=g1:1_%s4 button "Antwort vormerken"\n' "$i"
    done
    printf '      uid=g1:1_60 fo'
  } > "$truncated_file"

  # Pin that the truncated fixture itself undercounts, through the existing
  # snapshot test seam - otherwise this test would prove nothing about the
  # fixture actually being long enough to expose the defect.
  local truncated_out
  truncated_out=$(FM_RUN_DECISIONBOARD_SNAPSHOT="$truncated_file" "$DRIVER" query 2>&1) || true
  assert_contains "$truncated_out" "decision cards: 5" \
    "the truncated fixture must itself undercount, or this test cannot tell --full from plain"

  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = snapshot ]; then
  if [ "${2:-}" = --full ]; then
    cat "$FULL_SNAP"
  else
    cat "$TRUNCATED_SNAP"
  fi
fi
SH
  chmod +x "$fakebin/chrome-devtools-axi"

  out=$(PATH="$fakebin:$PATH" FULL_SNAP="$full_file" TRUNCATED_SNAP="$truncated_file" \
    "$DRIVER" query 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "query rejected a fully-populated seven-card board"$'\n'"$out"
  assert_contains "$out" "decision cards: 7" \
    "query undercounted a long board - it is reading the plain snapshot, not --full"
  assert_contains "$out" "with selectable options: 7" \
    "query undercounted the option sets on a long board"
  pass "query reads the full snapshot and counts every card on a long board"
}

test_selftest_arms_the_poll_before_answering() {
  local selftest_tmp fakebin fake_root fake_driver out first_event second_event third_event
  fm_test_tmproot selftest_tmp fm-run-db-selftest
  fakebin=$(fm_fakebin "$selftest_tmp")
  fake_root="$selftest_tmp/root"
  fake_driver="$fake_root/.agents/skills/run-decisionboard/fm-run-decisionboard.sh"
  mkdir -p "$fake_root/bin" "$(dirname "$fake_driver")"
  cp "$DRIVER" "$fake_driver"
  chmod +x "$fake_driver"
  cat > "$fake_root/bin/fm-board.sh" <<'SH'
#!/usr/bin/env bash
out=''
body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$body" != - ] && [ -n "$body" ] && grep -q '@tailwindcss/browser' "$body"; then
  exit 7
fi
mkdir -p "$(dirname "$out")"
if [ "$body" = - ]; then
  cat > "$out"
else
  printf '<html><body>probe</body></html>\n' > "$out"
fi
SH
  cat > "$fake_root/bin/fm-lavish.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  poll)
    printf 'poll\n' >> "$EVENT_LOG"
    if [ "${FM_FAKE_LAVISH_LISTEN:-yes}" = yes ]; then
      : > "$STATE_DIR/listening"
    fi
    while [ ! -e "$STATE_DIR/sent" ]; do
      sleep 0.05
    done
    printf 'Probe-Entscheidung A option-eins Vom run-decisionboard-Treiber gesetzt\n'
    ;;
  end)
    printf 'end\n' >> "$EVENT_LOG"
    ;;
  *)
    printf 'url: "http://example.invalid/session/fake"\n'
    ;;
esac
SH
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  snapshot)
    checked=''
    queued=''
    listening='      uid=g:14 StaticText "Your agent is not listening. If this persists, ask your agent to poll for updates from Lavish."'
    [ ! -e "$STATE_DIR/listening" ] || listening=''
    [ ! -e "$STATE_DIR/selected" ] || checked=' checked'
    if [ -e "$STATE_DIR/submitted" ]; then
      queued='        uid=g:13 StaticText "Vorgemerkt: option-eins"'
    fi
    cat <<SNAP
uid=g:0 RootWebArea "Probebrett · Lavish" url="http://example.invalid/session/fake"
  uid=g:1 Iframe
    uid=g:2 RootWebArea "Probebrett" url="http://example.invalid/artifact/fake/index.html"
      uid=g:3 StaticText "Probe-Entscheidung A"
      uid=g:4 form
        uid=g:5 radio "Option eins Die Option, die der Treiber wählt."$checked
        uid=g:6 textbox "Begründung (optional)" multiline
        uid=g:7 button "Antwort vormerken"
$queued
  uid=g:8 complementary
$listening
    uid=g:15 button "Send to Agent"
SNAP
    ;;
  click)
    case "${2:-}" in
      @g:5)
        printf 'answer\n' >> "$EVENT_LOG"
        : > "$STATE_DIR/selected"
        ;;
      @g:7)
        : > "$STATE_DIR/submitted"
        ;;
      @g:15)
        printf 'send\n' >> "$EVENT_LOG"
        : > "$STATE_DIR/sent"
        ;;
    esac
    ;;
  fill)
    printf '%s\n' "${3:-}" > "$STATE_DIR/note"
    ;;
  screenshot)
    printf 'fake screenshot\n' > "$2"
    ;;
esac
SH
  chmod +x "$fake_root/bin/fm-board.sh" "$fake_root/bin/fm-lavish.sh" "$fakebin/chrome-devtools-axi"
  mkdir -p "$selftest_tmp/state" "$selftest_tmp/staging"
  mkdir -m 700 "$selftest_tmp/runtime"
  : > "$selftest_tmp/events"
  out=$(PATH="$fakebin:$PATH" EVENT_LOG="$selftest_tmp/events" STATE_DIR="$selftest_tmp/state" \
    XDG_RUNTIME_DIR="$selftest_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$selftest_tmp/staging" \
    "$fake_driver" selftest 2>&1) \
    || fail "selftest failed with faked dependencies"$'\n'"$out"
  assert_contains "$out" "poll listening: yes" \
    "selftest did not assert the listener precondition through query output"
  first_event=$(sed -n '1p' "$selftest_tmp/events")
  second_event=$(sed -n '2p' "$selftest_tmp/events")
  third_event=$(sed -n '3p' "$selftest_tmp/events")
  [ "$first_event" = poll ] && [ "$second_event" = answer ] && [ "$third_event" = send ] \
    || fail "selftest did not arm poll before answer/send; events were:"$'\n'"$(cat "$selftest_tmp/events")"
  pass "selftest proves the answer path only after arming the poll"
}

test_selftest_refuses_to_answer_without_a_listening_poll() {
  local selftest_tmp fakebin fake_root fake_driver out status=0
  fm_test_tmproot selftest_tmp fm-run-db-selftest-no-listener
  fakebin=$(fm_fakebin "$selftest_tmp")
  fake_root="$selftest_tmp/root"
  fake_driver="$fake_root/.agents/skills/run-decisionboard/fm-run-decisionboard.sh"
  mkdir -p "$fake_root/bin" "$(dirname "$fake_driver")"
  cp "$DRIVER" "$fake_driver"
  chmod +x "$fake_driver"
  cat > "$fake_root/bin/fm-board.sh" <<'SH'
#!/usr/bin/env bash
out=''
body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$body" != - ] && [ -n "$body" ] && grep -q '@tailwindcss/browser' "$body"; then
  exit 7
fi
mkdir -p "$(dirname "$out")"
printf '<html><body>probe</body></html>\n' > "$out"
SH
  cat > "$fake_root/bin/fm-lavish.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  poll)
    printf 'poll\n' >> "$EVENT_LOG"
    while [ ! -e "$STATE_DIR/sent" ]; do
      sleep 0.05
    done
    ;;
  end) ;;
  *) printf 'url: "http://example.invalid/session/fake"\n' ;;
esac
SH
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  snapshot)
    cat <<'SNAP'
uid=g:0 RootWebArea "Probebrett · Lavish" url="http://example.invalid/session/fake"
  uid=g:1 Iframe
    uid=g:2 RootWebArea "Probebrett" url="http://example.invalid/artifact/fake/index.html"
      uid=g:3 StaticText "Probe-Entscheidung A"
      uid=g:4 form
        uid=g:5 radio "Option eins Die Option, die der Treiber wählt."
        uid=g:6 textbox "Begründung (optional)" multiline
        uid=g:7 button "Antwort vormerken"
  uid=g:8 complementary
      uid=g:14 StaticText "Your agent is not listening. If this persists, ask your agent to poll for updates from Lavish."
    uid=g:15 button "Send to Agent"
SNAP
    ;;
  click)
    printf '%s\n' "${2:-}" >> "$EVENT_LOG"
    ;;
  screenshot)
    printf 'fake screenshot\n' > "$2"
    ;;
esac
SH
  chmod +x "$fake_root/bin/fm-board.sh" "$fake_root/bin/fm-lavish.sh" "$fakebin/chrome-devtools-axi"
  mkdir -p "$selftest_tmp/state" "$selftest_tmp/staging"
  mkdir -m 700 "$selftest_tmp/runtime"
  : > "$selftest_tmp/events"
  out=$(PATH="$fakebin:$PATH" EVENT_LOG="$selftest_tmp/events" STATE_DIR="$selftest_tmp/state" \
    XDG_RUNTIME_DIR="$selftest_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$selftest_tmp/staging" \
    FM_RUN_DECISIONBOARD_LISTEN_TIMEOUT=0 "$fake_driver" selftest 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "selftest answered even though query never observed a listening poll"$'\n'"$out"
  assert_contains "$out" "poll listening: no" \
    "selftest did not show the failed listener precondition"
  [ "$(sed -n '1p' "$selftest_tmp/events")" = poll ] \
    || fail "selftest did not start the poll before checking the listener precondition"
  [ "$(wc -l < "$selftest_tmp/events" | tr -d ' ')" -eq 1 ] \
    || fail "selftest clicked answer/send despite the missing listener:"$'\n'"$(cat "$selftest_tmp/events")"
  pass "selftest refuses to answer before query observes a listening poll"
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
  mkdir -m 700 "$shot_tmp/runtime"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot reported success for a screenshot that was never written"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot wrote a destination file with no screenshot behind it"
  assert_contains "$out" "wrote no screenshot" "shot must say the file is missing, not that it failed vaguely"
  pass "shot refuses a screenshot that exited 0 and wrote nothing"
}

test_shot_refuses_a_stale_staging_file() {
  # The staging path is unique by default, but a collision or a caller-provided
  # shot id can still present an old file. The freshness refusal must stay in
  # place for that case instead of trusting the screenshot command's exit status.
  local shot_tmp fakebin out status=0
  fm_test_tmproot shot_tmp fm-run-db-stale
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging"
  mkdir -m 700 "$shot_tmp/runtime"
  printf 'the previous run left this behind\n' \
    > "$shot_tmp/staging/fm-run-decisionboard-shot.$(id -un).stale.png"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    FM_RUN_DECISIONBOARD_SHOT_ID=stale \
    "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot passed on a staging file this run never touched"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot copied a stale staging file to the destination"
  assert_contains "$out" "unchanged" "shot must say the staging file is from an earlier run"
  pass "shot refuses a staging file this run did not refresh"
}

test_shot_uses_a_unique_default_staging_target() {
  local shot_tmp fakebin first_path second_path out
  fm_test_tmproot shot_tmp fm-run-db-unique-shot
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$SHOT_PATH_LOG"
printf 'fresh image bytes\n' > "$2"
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging"
  mkdir -m 700 "$shot_tmp/runtime"
  : > "$shot_tmp/paths"
  out=$(PATH="$fakebin:$PATH" SHOT_PATH_LOG="$shot_tmp/paths" \
    XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    "$DRIVER" shot "$shot_tmp/first.png" 2>&1) \
    || fail "first default staging shot failed"$'\n'"$out"
  out=$(PATH="$fakebin:$PATH" SHOT_PATH_LOG="$shot_tmp/paths" \
    XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    "$DRIVER" shot "$shot_tmp/second.png" 2>&1) \
    || fail "second default staging shot failed"$'\n'"$out"
  first_path=$(sed -n '1p' "$shot_tmp/paths")
  second_path=$(sed -n '2p' "$shot_tmp/paths")
  [ -n "$first_path" ] && [ -n "$second_path" ] && [ "$first_path" != "$second_path" ] \
    || fail "default staging targets were not unique: '$first_path' and '$second_path'"
  pass "shot uses a unique default staging target per driver invocation"
}

test_shot_accepts_a_same_size_refresh() {
  local shot_tmp fakebin out staging
  fm_test_tmproot shot_tmp fm-run-db-refresh
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'new image bytes\n' > "$2"
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging"
  mkdir -m 700 "$shot_tmp/runtime"
  staging="$shot_tmp/staging/fm-run-decisionboard-shot.$(id -un).refresh.png"
  printf 'old image bytes\n' > "$staging"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    FM_RUN_DECISIONBOARD_SHOT_ID=refresh \
    "$DRIVER" shot "$shot_tmp/out.png" 2>&1) \
    || fail "shot rejected changed same-size content"$'\n'"$out"
  assert_contains "$(cat "$shot_tmp/out.png")" "new image bytes" \
    "shot did not copy the refreshed screenshot"
  pass "shot recognizes changed content even when its size is unchanged"
}

test_shot_refuses_an_unacquirable_capture_lock() {
  local shot_tmp fakebin out status=0
  fm_test_tmproot shot_tmp fm-run-db-locked
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'fresh image bytes\n' > "$2"
SH
  cat > "$fakebin/flock" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/chrome-devtools-axi" "$fakebin/flock"
  mkdir -p "$shot_tmp/staging"
  mkdir -m 700 "$shot_tmp/runtime"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$shot_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" \
    FM_RUN_DECISIONBOARD_LOCK_TIMEOUT=0 "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot proceeded without acquiring its capture lock"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot produced evidence after its capture lock was refused"
  assert_contains "$out" "could not serialise the screenshot capture" \
    "shot did not identify the unacquirable capture lock"
  pass "shot refuses evidence it cannot serialise against other runs"
}

test_staging_aliases_share_one_capture_lock() {
  local shot_tmp fakebin real_dir alias_dir first_lock second_lock status=0
  fm_test_tmproot shot_tmp fm-run-db-alias-lock
  fakebin=$(fm_fakebin "$shot_tmp")
  real_dir="$shot_tmp/staging"
  alias_dir="$shot_tmp/staging-alias"
  mkdir -p "$real_dir"
  ln -s "$real_dir" "$alias_dir"
  mkdir -m 700 "$shot_tmp/runtime"
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/flock" <<'SH'
#!/usr/bin/env bash
fd=${!#}
readlink "/proc/$$/fd/$fd" >> "$LOCK_LOG"
exit 1
SH
  chmod +x "$fakebin/chrome-devtools-axi" "$fakebin/flock"
  : > "$shot_tmp/locks"
  PATH="$fakebin:$PATH" LOCK_LOG="$shot_tmp/locks" XDG_RUNTIME_DIR="$shot_tmp/runtime" \
    FM_RUN_DECISIONBOARD_TMPDIR="$real_dir/" FM_RUN_DECISIONBOARD_LOCK_TIMEOUT=0 \
    FM_RUN_DECISIONBOARD_SHOT_ID=alias-lock \
    "$DRIVER" shot "$shot_tmp/first.png" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "first aliased staging capture unexpectedly acquired the fake lock"
  status=0
  PATH="$fakebin:$PATH" LOCK_LOG="$shot_tmp/locks" XDG_RUNTIME_DIR="$shot_tmp/runtime" \
    FM_RUN_DECISIONBOARD_TMPDIR="$alias_dir" FM_RUN_DECISIONBOARD_LOCK_TIMEOUT=0 \
    FM_RUN_DECISIONBOARD_SHOT_ID=alias-lock \
    "$DRIVER" shot "$shot_tmp/second.png" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "second aliased staging capture unexpectedly acquired the fake lock"
  first_lock=$(sed -n '1p' "$shot_tmp/locks")
  second_lock=$(sed -n '2p' "$shot_tmp/locks")
  [ -n "$first_lock" ] && [ "$first_lock" = "$second_lock" ] \
    || fail "equivalent staging paths used different locks: '$first_lock' and '$second_lock'"
  pass "equivalent staging paths share one capture lock"
}

test_shot_refuses_an_unsafe_lock_directory() {
  local shot_tmp fakebin out status=0
  fm_test_tmproot shot_tmp fm-run-db-unsafe-lock
  fakebin=$(fm_fakebin "$shot_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'fresh image bytes\n' > "$2"
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$shot_tmp/staging" "$shot_tmp/runtime"
  chmod 770 "$shot_tmp/runtime"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$shot_tmp/runtime" \
    FM_RUN_DECISIONBOARD_TMPDIR="$shot_tmp/staging" "$DRIVER" shot "$shot_tmp/out.png" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shot used a group-writable lock directory"$'\n'"$out"
  [ ! -e "$shot_tmp/out.png" ] || fail "shot produced evidence with an unsafe lock directory"
  assert_contains "$out" "lock base is group- or world-writable" \
    "shot did not identify the unsafe lock directory"
  pass "shot refuses a lock directory other accounts can write"
}

test_doctor_accepts_a_same_size_refresh() {
  local doctor_tmp fakebin out staging
  fm_test_tmproot doctor_tmp fm-run-db-doctor
  fakebin=$(fm_fakebin "$doctor_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'new image bytes\n' > "$2"
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  mkdir -p "$doctor_tmp/staging"
  mkdir -m 700 "$doctor_tmp/runtime"
  staging="$doctor_tmp/staging/fm-run-decisionboard-shot.$(id -un).doctor.png"
  printf 'old image bytes\n' > "$staging"
  out=$(PATH="$fakebin:$PATH" XDG_RUNTIME_DIR="$doctor_tmp/runtime" FM_RUN_DECISIONBOARD_TMPDIR="$doctor_tmp/staging" \
    FM_RUN_DECISIONBOARD_SHOT_ID=doctor \
    "$DRIVER" doctor 2>&1) || fail "doctor failed to re-measure the bridge"$'\n'"$out"
  assert_not_contains "$out" "bridge account: unmeasured" \
    "doctor treated a changed same-size screenshot as stale"
  assert_contains "$out" "bridge account:" "doctor did not report the measured bridge account"
  pass "doctor recognizes changed content even when its size is unchanged"
}

test_answer_reresolves_the_exact_option_name() {
  local answer_tmp fakebin out first_click
  fm_test_tmproot answer_tmp fm-run-db-answer
  fakebin=$(fm_fakebin "$answer_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  snapshot)
    if [ "$(wc -l < "$CLICK_LOG" 2>/dev/null || printf 0)" -ge 2 ]; then
      cat <<'SNAP'
uid=g3:2_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g3:2_1 Iframe
    uid=g3:2_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g3:2_3 form
        uid=g3:2_4 radio "Not Yes"
        uid=g3:2_5 radio "Yes" checked
        uid=g3:2_6 button "Antwort vormerken"
        uid=g3:2_7 StaticText "VORGEMERKT: yes-value"
SNAP
    else
      cat <<'SNAP'
uid=g3:1_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g3:1_1 Iframe
    uid=g3:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g3:1_3 form
        uid=g3:1_4 radio "Not Yes"
        uid=g3:1_5 radio "Yes"
        uid=g3:1_6 button "Antwort vormerken"
SNAP
    fi
    ;;
  click)
    printf '%s\n' "$2" >> "$CLICK_LOG"
    ;;
esac
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  : > "$answer_tmp/clicks"
  out=$(CLICK_LOG="$answer_tmp/clicks" PATH="$fakebin:$PATH" \
    "$DRIVER" answer --option "Yes" 2>&1) \
    || fail "answer failed to select the exact option"$'\n'"$out"
  first_click=$(sed -n '1p' "$answer_tmp/clicks")
  [ "$first_click" = '@g3:1_5' ] \
    || fail "answer clicked '$first_click' instead of the exact Yes option"
  assert_contains "$out" "queued 'yes-value'" \
    "answer assumed the accessible label and queued HTML value must match"
  pass "answer preserves the exact option name across fresh snapshots"
}

test_answer_refuses_a_changed_confirmation_for_a_different_checked_option() {
  local answer_tmp fakebin snap selected submitted out status=0
  fm_test_tmproot answer_tmp fm-run-db-wrong-checked
  fakebin=$(fm_fakebin "$answer_tmp")
  snap="$answer_tmp/current.txt"
  selected="$answer_tmp/selected.txt"
  submitted="$answer_tmp/submitted.txt"
  cat > "$snap" <<'SNAP'
uid=g8:1_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g8:1_1 Iframe
    uid=g8:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g8:1_3 form
        uid=g8:1_4 radio "No"
        uid=g8:1_5 radio "Yes"
        uid=g8:1_6 button "Antwort vormerken"
SNAP
  cat > "$selected" <<'SNAP'
uid=g8:2_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g8:2_1 Iframe
    uid=g8:2_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g8:2_3 form
        uid=g8:2_4 radio "No"
        uid=g8:2_5 radio "Yes" checked
        uid=g8:2_6 button "Antwort vormerken"
SNAP
  cat > "$submitted" <<'SNAP'
uid=g8:3_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g8:3_1 Iframe
    uid=g8:3_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g8:3_3 form
        uid=g8:3_4 radio "No" checked
        uid=g8:3_5 radio "Yes"
        uid=g8:3_6 button "Antwort vormerken"
        uid=g8:3_7 StaticText "Vorgemerkt: changed-value"
SNAP
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = click ]; then
  clicks=$(wc -l < "$CLICK_LOG" 2>/dev/null || printf 0)
  printf '%s\n' "$2" >> "$CLICK_LOG"
  if [ "$clicks" -eq 0 ]; then
    cp "$SELECTED_SNAPSHOT" "$SNAPSHOT_FILE"
  else
    cp "$SUBMITTED_SNAPSHOT" "$SNAPSHOT_FILE"
  fi
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  : > "$answer_tmp/clicks"
  out=$(PATH="$fakebin:$PATH" CLICK_LOG="$answer_tmp/clicks" \
    SNAPSHOT_FILE="$snap" SELECTED_SNAPSHOT="$selected" SUBMITTED_SNAPSHOT="$submitted" \
    FM_RUN_DECISIONBOARD_SNAPSHOT="$snap" "$DRIVER" answer --option "Yes" 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "answer accepted a changed confirmation for a different checked option"$'\n'"$out"
  assert_contains "$out" "checked 'No' instead of the selected option 'Yes'" \
    "answer did not identify the checked-state mismatch"
  pass "answer requires the selected radio to remain checked after submission"
}

test_answer_ignores_a_neighbours_queued_confirmation() {
  local answer_tmp fakebin snap out status=0
  fm_test_tmproot answer_tmp fm-run-db-neighbour
  fakebin=$(fm_fakebin "$answer_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  snap="$answer_tmp/neighbour.txt"
  cat > "$snap" <<'SNAP'
uid=g6:1_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g6:1_1 Iframe
    uid=g6:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g6:1_3 form
        uid=g6:1_4 radio "Yes"
        uid=g6:1_5 button "Hilfe"
      uid=g6:1_6 form
        uid=g6:1_7 radio "No"
        uid=g6:1_8 button "Antwort vormerken"
        uid=g6:1_9 StaticText "Vorgemerkt: neighbour-value"
SNAP
  out=$(PATH="$fakebin:$PATH" FM_RUN_DECISIONBOARD_SNAPSHOT="$snap" \
    "$DRIVER" answer --option "Yes" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "answer accepted another decision's queued confirmation"$'\n'"$out"
  assert_contains "$out" "decision 1" "answer did not scope its failure to the target decision"
  pass "answer ignores queued confirmation from another decision"
}

answer_with_stale_confirmation() {  # <queued-value>
  local queued_value=$1 answer_tmp fakebin snap
  fm_test_tmproot answer_tmp fm-run-db-stale-answer
  fakebin=$(fm_fakebin "$answer_tmp")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  snap="$answer_tmp/stale.txt"
  cat > "$snap" <<SNAP
uid=g7:1_0 RootWebArea "Editor" url="http://example.invalid/session/x"
  uid=g7:1_1 Iframe
    uid=g7:1_2 RootWebArea "Board" url="http://example.invalid/artifact/x/index.html"
      uid=g7:1_3 form
        uid=g7:1_4 radio "Yes"
        uid=g7:1_5 button "Hilfe"
        uid=g7:1_6 StaticText "Vorgemerkt: $queued_value"
SNAP
  ANSWER_STATUS=0
  ANSWER_OUT=$(PATH="$fakebin:$PATH" FM_RUN_DECISIONBOARD_SNAPSHOT="$snap" \
    "$DRIVER" answer --option "Yes" 2>&1) || ANSWER_STATUS=$?
}

test_answer_refuses_a_stale_different_option_confirmation() {
  answer_with_stale_confirmation other-value
  [ "$ANSWER_STATUS" -ne 0 ] \
    || fail "answer accepted a stale confirmation for another option"$'\n'"$ANSWER_OUT"
  pass "answer refuses a stale confirmation for another option"
}

test_answer_refuses_a_stale_same_option_confirmation() {
  answer_with_stale_confirmation yes-value
  [ "$ANSWER_STATUS" -ne 0 ] \
    || fail "answer accepted a stale confirmation for the same option"$'\n'"$ANSWER_OUT"
  assert_contains "$ANSWER_OUT" \
    "the confirmation already named this option before the click, so this run did not prove the answer was queued" \
    "answer did not explain why an unchanged same-option confirmation proves nothing"
  pass "answer refuses an unchanged same-option confirmation"
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
test_query_distinguishes_note_evidence_from_button_shape
test_query_reports_missing_notes_without_refusing_them
test_query_can_refuse_missing_notes_when_the_contract_flips
test_query_counts_a_decision_form_that_carries_nothing
test_query_reports_an_unlistened_board
test_query_requests_the_full_snapshot_on_a_long_board
test_selftest_arms_the_poll_before_answering
test_selftest_refuses_to_answer_without_a_listening_poll
test_shot_refuses_a_screenshot_that_wrote_nothing
test_shot_refuses_a_stale_staging_file
test_shot_uses_a_unique_default_staging_target
test_shot_accepts_a_same_size_refresh
test_shot_refuses_an_unacquirable_capture_lock
test_staging_aliases_share_one_capture_lock
test_shot_refuses_an_unsafe_lock_directory
test_doctor_accepts_a_same_size_refresh
test_answer_reresolves_the_exact_option_name
test_answer_refuses_a_changed_confirmation_for_a_different_checked_option
test_answer_ignores_a_neighbours_queued_confirmation
test_answer_refuses_a_stale_different_option_confirmation
test_answer_refuses_a_stale_same_option_confirmation
