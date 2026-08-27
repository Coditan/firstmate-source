#!/usr/bin/env bash
# tests/fm-context-reset.test.sh - the stow-then-clear context-reset mechanism:
# the receipt (bin/fm-stow-receipt.sh), the reset tool (bin/fm-context-reset.sh),
# the shared predicates (bin/fm-context-lib.sh), and the watcher's ceiling branch
# (bin/fm-watch.sh's context_ceiling_surface).
#
# The contract under test is a refusal contract. Every way the mechanism can be
# wrong - a stale receipt, a receipt from another session, a fleet that stopped
# being quiet mid-flight, a captain who came back, a broken way of restarting
# afterwards - must REFUSE and discard nothing. The one success case exists to
# prove the refusals are not just an unconditional "no".
#
# docs/context-reset.md owns the mechanism narrative and the evidence.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESET="$ROOT/bin/fm-context-reset.sh"
RECEIPT_BIN="$ROOT/bin/fm-stow-receipt.sh"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"

# shellcheck source=bin/fm-operational-input.sh
. "$OPERATIONAL_INPUT"

fm_test_tmproot TMP_ROOT fm-context-reset-tests

CASE_N=0

iso_now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
iso_ago() {  # <seconds>
  local at=$(( $(date +%s) - $1 ))
  if [ "$(uname)" = Darwin ]; then
    date -u -r "$at" +%Y-%m-%dT%H:%M:%S.000Z
  else
    date -u -d "@$at" +%Y-%m-%dT%H:%M:%S.000Z
  fi
}

# The id the fixture's captain record carries. An approved reset has to name the
# exact record it treated as the approval, so tests assert on this value.
CAPTAIN_RECORD_ID=cap-record-0001

# write_transcript <path> <tokens> <human-ts-or-empty> [padding-bytes] [human-uuid]
# Three record shapes matter and all three appear here: a hook/meta injection, a
# background-task wake delivery, and (optionally) a genuine captain prompt. Only
# the last must ever read as captain activity.
# Passing an EMPTY fifth argument writes the captain record with no `uuid` key at
# all - a transcript an approved reset cannot cite, which must refuse rather than
# proceed unnamed.
write_transcript() {
  local path=$1 tokens=$2 human=$3 pad=${4:-0} uuid=${5-$CAPTAIN_RECORD_ID}
  {
    printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"session-start nudge"},"timestamp":"2020-01-01T00:00:00.000Z"}\n'
    printf '{"type":"user","origin":{"kind":"task-notification"},"promptSource":"system","message":{"role":"user","content":"wake: queued"},"timestamp":"%s"}\n' "$(iso_now)"
    if [ -n "$human" ] && [ -n "$uuid" ]; then
      printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","uuid":"%s","message":{"role":"user","content":"captain says something"},"timestamp":"%s"}\n' "$uuid" "$human"
    elif [ -n "$human" ]; then
      printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","message":{"role":"user","content":"captain says something"},"timestamp":"%s"}\n' "$human"
    fi
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"out"}]},"timestamp":"%s"}\n' "$(iso_now)"
    if [ "$pad" -gt 0 ]; then
      printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"%s"}]},"timestamp":"%s"}\n' \
        "$(head -c "$pad" /dev/zero | tr '\0' 'x')" "$(iso_now)"
    fi
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens"
  } > "$path"
}

write_transcript_with_unattributed_string_user() {
  local path=$1 tokens=$2 human=$3 content=$4 content_ts=$5 uuid=${6:-unattributed-record-0001}
  {
    printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"session-start nudge"},"timestamp":"2020-01-01T00:00:00.000Z"}\n'
    if [ -n "$human" ]; then
      printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","uuid":"%s","message":{"role":"user","content":"captain says something"},"timestamp":"%s"}\n' "$CAPTAIN_RECORD_ID" "$human"
    fi
    jq -cn --arg uuid "$uuid" --arg content "$content" --arg ts "$content_ts" \
      '{type:"user", uuid:$uuid, message:{role:"user", content:$content}, timestamp:$ts}'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens"
  } > "$path"
}

write_settings() {  # <home> <matcher> <command-suffix>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "$2",
        "hooks": [{ "type": "command", "command": "\\"\$CLAUDE_PROJECT_DIR\\"/bin/$3" }]
      }
    ]
  }
}
EOF
}

install_fake_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
# A hook for driving the check-to-send race deterministically: append records to a
# transcript on the FIRST tmux call of a run and no other. fm-context-reset.sh
# runs every one of its gates before it touches tmux at all, and types the clear
# after, so that first call lands squarely between the two.
if [ -n "${FM_FAKE_TMUX_APPEND_ONCE:-}" ] && [ ! -e "${FM_FAKE_TMUX_APPEND_ONCE}.done" ]; then
  : > "${FM_FAKE_TMUX_APPEND_ONCE}.done"
  cat "$FM_FAKE_TMUX_APPEND_ONCE" >> "$FM_FAKE_TMUX_APPEND_TO"
fi
case "${1:-}" in
  # list-panes takes a target-WINDOW, so it lists every pane of the window
  # containing $TMUX_PANE - here a SPLIT window whose active pane (%1) is not
  # this script's own (%9). That is the shape the resolver has to get right: a
  # gate that picked the active row would hand fm-context-reset.sh a neighbour's
  # pane and type the reset into it.
  list-panes) printf '%%1 1\n%%9 0\n'; exit 0 ;;
  display-message)
    case "$*" in
      *cursor_y*) printf '5\n' ;;
      *session_name*) printf '%s\n' "${FM_FAKE_TMUX_SESSION:-fmtest:0.0}" ;;
      *pane_id*) printf '%%9\n' ;;
      *) printf '\n' ;;
    esac
    ;;
  capture-pane) printf '%s\n' "${FM_FAKE_TMUX_PANE_LINE:-  esc to interrupt}" ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# make_case: a home whose session is over the ceiling, quiet, captain long gone,
# supervision healthy, re-entry hook intact, and holding a fresh receipt. Every
# test then breaks exactly one of those and asserts the refusal.
# Publishes: HOME_DIR STATE_DIR FAKEBIN TRANSCRIPT TMUX_LOG
make_case() {
  CASE_N=$((CASE_N + 1))
  HOME_DIR="$TMP_ROOT/case$CASE_N"
  STATE_DIR="$HOME_DIR/state"
  FAKEBIN=$(fm_fakebin "$HOME_DIR")
  TRANSCRIPT="$HOME_DIR/transcript.jsonl"
  TMUX_LOG="$HOME_DIR/tmux.log"
  mkdir -p "$STATE_DIR"
  : > "$TMUX_LOG"
  install_fake_tmux "$FAKEBIN"
  write_settings "$HOME_DIR" 'startup|resume|clear' 'fm-sessionstart-nudge.sh'
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  # The session lock names the same session process as the transcript record;
  # that agreement is what tells the watcher there is a live session to measure.
  printf '%s\n' "$$" > "$STATE_DIR/.lock"
  record_ok
  fm_test_record_supervision_healthy "$HOME_DIR" "$STATE_DIR"
  write_receipt
}

record_ok() {
  cat > "$STATE_DIR/.primary-transcript" <<EOF
status=ok
harness_pid=$$
session_id=sess-$CASE_N
transcript_path=$TRANSCRIPT
recorded_at=$(date +%s)
EOF
}

# Write the receipt through the real bin/fm-stow-receipt.sh, so every test that
# needs a valid receipt also re-proves the receipt writer itself.
write_receipt() {
  local out status=0
  out=$(run_env "$RECEIPT_BIN" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "fixture receipt was refused: $out"
}

run_env() {  # <cmd...>
  env -u FM_ROOT_OVERRIDE \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    CLAUDECODE=1 \
    TMUX_PANE='%9' \
    FM_SEND_SETTLE=0 \
    FM_SEND_SLEEP=0.05 \
    FM_SEND_RETRIES=1 \
    "$@"
}

# run_reset [args...]: publishes RESET_OUT and RESET_CODE. Call it directly, never
# inside a command substitution - that would run it in a subshell and silently
# discard the exit code it is here to report.
RESET_OUT=
RESET_CODE=0
run_reset() {
  RESET_CODE=0
  RESET_OUT=$(run_env "$RESET" "$@" 2>&1) || RESET_CODE=$?
}

# assert_refuses <reason-fragment> <label> [reset-args...]
assert_refuses() {
  local fragment=$1 label=$2 out
  shift 2
  run_reset "$@"
  out=$RESET_OUT
  expect_code 1 "$RESET_CODE" "$label"
  assert_contains "$out" "REFUSED" "$label did not refuse loudly"
  assert_contains "$out" "$fragment" "$label refused for the wrong reason"
  assert_contains "$out" "nothing was discarded" "$label did not say the context was left alone"
  assert_grep 'refused' "$STATE_DIR/.context-reset.log" "$label left no durable record of the refusal"
  assert_no_grep 'send-keys' "$TMUX_LOG" "$label typed into the pane despite refusing"
  pass "$label"
}

# --- the one success path ---------------------------------------------------

test_reset_proceeds_when_everything_verifies() {
  local out
  make_case
  run_reset
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "a fully verified reset must proceed"
  assert_contains "$out" "reset submitted" "a verified reset did not report submitting"
  assert_grep 'send-keys' "$TMUX_LOG" "the reset never typed into the pane"
  assert_grep '/clear' "$TMUX_LOG" "the reset typed something other than the clear"
  assert_grep 'cleared' "$STATE_DIR/.context-reset.log" "a completed reset left no durable record"
  [ -f "$(printf '%s/.stow-receipt' "$STATE_DIR")" ] \
    && fail "the receipt survived a completed reset and could be replayed"
  # The pane the reset was ADDRESSED to must be this script's own ($TMUX_PANE =
  # %9), never the neighbour that happens to be active in the same split window
  # (%1). fm_tmux_resolve_pane's whole job here is that identity: it resolves
  # $TMUX_PANE and this script types into whatever the result names, so a gate
  # that answered with the window's active pane would send /clear next door -
  # exactly what "a reset must never be typed into a pane it cannot identify"
  # exists to prevent.
  assert_grep 'display-message -p -t %9 ' "$TMUX_LOG" \
    "the reset did not address its own pane (%9) when reading the target it types into"
  assert_no_grep 'display-message -p -t %1 ' "$TMUX_LOG" \
    "the reset addressed the active neighbouring pane (%1) instead of its own (%9)"
  pass "a verified reset clears through the shared submit path, addressing its own pane, and records that it did"
}

test_check_mode_verifies_without_clearing() {
  local out
  make_case
  run_reset --check
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "--check must pass on a verifiable session"
  assert_contains "$out" "all checks pass" "--check did not report its verdict"
  assert_no_grep 'send-keys' "$TMUX_LOG" "--check typed into the pane"
  assert_present "$STATE_DIR/.stow-receipt" "--check consumed the receipt"
  pass "--check proves the whole precondition chain without discarding anything"
}

# --- the receipt ------------------------------------------------------------

test_missing_receipt_refuses() {
  make_case
  rm -f "$STATE_DIR/.stow-receipt"
  assert_refuses "no stow receipt" "a reset with no receipt"
}

test_stale_receipt_refuses() {
  make_case
  sed -i.bak "s/^written_at=.*/written_at=$(( $(date +%s) - 5000 ))/" "$STATE_DIR/.stow-receipt"
  assert_refuses "limit 900s" "a reset on a receipt older than its freshness bound"
}

test_receipt_from_another_session_refuses() {
  make_case
  sed -i.bak 's/^session_id=.*/session_id=some-other-session/' "$STATE_DIR/.stow-receipt"
  assert_refuses "different session" "a reset on another session's receipt"
}

test_receipt_bound_to_another_transcript_refuses() {
  make_case
  sed -i.bak "s|^transcript_path=.*|transcript_path=$HOME_DIR/other.jsonl|" "$STATE_DIR/.stow-receipt"
  assert_refuses "different transcript" "a reset on a receipt bound to another transcript"
}

test_session_advanced_past_the_receipt_refuses() {
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)" 400000
  assert_refuses "moved on by" "a reset after the session advanced materially past its receipt"
}

test_captain_spoke_after_the_receipt_refuses() {
  make_case
  # The receipt was bound with the captain silent; the captain then speaks. The
  # sweep cannot have covered what arrived after it, so the discard must not run.
  write_transcript "$TRANSCRIPT" 900000 "$(iso_now)"
  assert_refuses "spoken since the receipt" "a reset after the captain spoke past the receipt"
}

test_receipt_refuses_off_session() {
  local out status=0
  make_case
  sed -i.bak 's/^harness_pid=.*/harness_pid=999999999/' "$STATE_DIR/.primary-transcript"
  out=$(run_env "$RECEIPT_BIN" 2>&1) || status=$?
  expect_code 1 "$status" "a receipt written from outside the recorded session"
  assert_contains "$out" "refusing" "the receipt writer did not refuse loudly"
  assert_contains "$out" "not the session running this command" "the receipt writer refused for the wrong reason"
  pass "a receipt can only be written from the session it describes"
}

test_receipt_refuses_without_a_transcript_record() {
  local out status=0
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  out=$(run_env "$RECEIPT_BIN" 2>&1) || status=$?
  expect_code 1 "$status" "a receipt written with no transcript recorded"
  assert_contains "$out" "no session transcript recorded" "the receipt writer refused for the wrong reason"
  pass "a receipt is refused when the session's transcript position is unknown"
}

# --- the captain ------------------------------------------------------------

test_captain_active_refuses() {
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  write_receipt
  assert_refuses "ask before resetting" "a reset while the captain is in live conversation"
}

test_away_mode_refuses() {
  make_case
  touch "$STATE_DIR/.afk"
  assert_refuses "away mode is active" "a reset while away mode owns wake delivery"
}

# --- the captain-approved path ----------------------------------------------
#
# The defect these cover is arithmetic rather than logical, which is why reading
# the code never found it. On the path where the captain APPROVES a reset, the
# approval is what starts it, so the idle window is measured from the moment the
# captain last spoke - and it is twice as long as the receipt is allowed to live.
# Both could never be open at once, so every reset this mechanism ever completed
# came through the autonomous branch and none through the asking one.
#
# approved_case: the shape of a real approval. The captain spoke INSIDE the idle
# window (the autonomous path's hard refusal), and the receipt was filed after
# that message. <seconds-ago> is when the captain spoke.
approved_case() {  # <seconds-ago>
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago "$1")"
  write_receipt
}

# The headline: the same session, at the same instant, refuses autonomously and
# completes on the approved path. Asserting both halves in one test is the point -
# it is the difference between the two paths that was broken, not either alone.
test_captain_approved_completes_where_the_idle_window_makes_it_impossible() {
  local out
  approved_case 60
  # First, autonomously. This is the refusal that made the approved path
  # unreachable: the captain's own approval counts as the captain being active.
  run_reset
  expect_code 1 "$RESET_CODE" "the autonomous path must still refuse a captain who just spoke"
  assert_contains "$RESET_OUT" "ask before resetting" \
    "the autonomous path refused for the wrong reason"
  # Now with the approval. Nothing about the session changed between the two runs.
  run_reset --captain-approved
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "an approved reset must complete where the idle window alone would refuse"
  assert_contains "$out" "reset submitted" "an approved reset did not report submitting"
  assert_grep 'send-keys' "$TMUX_LOG" "an approved reset never typed into the pane"
  assert_grep '/clear' "$TMUX_LOG" "an approved reset typed something other than the clear"
  [ -f "$STATE_DIR/.stow-receipt" ] \
    && fail "the receipt survived a completed approved reset and could be replayed"
  pass "a captain approval completes a reset the idle window alone can never allow"
}

# Auditability is the whole substitute for verification here, so the record it
# relied on has to be nameable afterwards by someone who was not in the room.
test_an_approved_reset_names_the_record_it_treated_as_the_approval() {
  local out
  approved_case 60
  run_reset --captain-approved
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "the approved reset under audit did not complete"
  assert_contains "$out" "$CAPTAIN_RECORD_ID" \
    "an approved reset did not say on stdout which captain record it relied on"
  assert_grep "cleared" "$STATE_DIR/.context-reset.log" "the approved reset left no durable outcome"
  assert_grep "path=captain-approved approval-record=$CAPTAIN_RECORD_ID" \
    "$STATE_DIR/.context-reset.log" \
    "the durable log does not name the captain record the approved reset relied on"
  pass "an approved reset records which captain record it treated as the approval"
}

# The wording is a requirement, not decoration: the agent invoking this reset is
# the same party claiming the approval exists, so a line that reads as
# confirmation would be the tool lending its authority to an unverifiable claim.
test_the_approved_path_states_what_it_cannot_prove() {
  local out
  approved_case 60
  run_reset --check --captain-approved
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "--check must pass on an approved session"
  assert_contains "$out" "whether it meant approval is not something this tool can check" \
    "the approved path let its output imply the tool confirmed the captain agreed"
  assert_grep "path=captain-approved approval-record=$CAPTAIN_RECORD_ID" \
    "$STATE_DIR/.context-reset.log" "an approved --check did not record the record it relied on"
  assert_no_grep 'send-keys' "$TMUX_LOG" "an approved --check typed into the pane"
  assert_present "$STATE_DIR/.stow-receipt" "an approved --check consumed the receipt"
  pass "the approved path says plainly that it verified a record exists, not that it meant yes"
}

# The AGE window is REPLACED on this path, not stretched: a receipt far past it
# still completes, provided the ordering below and the growth bound hold. Proving
# the replacement rather than a bigger constant is what stops the same deadlock
# reappearing one window-size later.
test_the_receipt_age_window_does_not_apply_on_the_approved_path() {
  approved_case 6000
  sed -i.bak "s/^written_at=.*/written_at=$(( $(date +%s) - 5000 ))/" "$STATE_DIR/.stow-receipt"
  run_reset
  expect_code 1 "$RESET_CODE" "the autonomous path must still refuse a receipt past its freshness bound"
  assert_contains "$RESET_OUT" "limit 900s" "the autonomous path refused for the wrong reason"
  run_reset --captain-approved
  expect_code 0 "$RESET_CODE" "the approved path must not apply the receipt's age window"
  pass "the age window is replaced on the approved path rather than stretched to a new constant"
}

# The condition the age window was standing in for, checked directly. A receipt
# that predates the approval cannot have covered it, whatever its age.
test_a_receipt_filed_before_the_approval_refuses() {
  approved_case 10
  sed -i.bak "s/^written_at=.*/written_at=$(( $(date +%s) - 30 ))/" "$STATE_DIR/.stow-receipt"
  assert_refuses "the receipt came first" \
    "an approved reset whose receipt predates the approval" --captain-approved
}

# The gate that carries the real safety property, and the one thing the approval
# may never buy: if the session moved on after filing, the sweep did not cover
# what came since, approval or not.
test_growth_past_the_receipt_still_refuses_on_the_approved_path() {
  approved_case 60
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)" 400000
  assert_refuses "moved on by" \
    "an approved reset after the session advanced materially past its receipt" --captain-approved
}

# The equality check survives too, so the approval can only ever be the LAST thing
# the captain said - never an old yes with a newer message sitting behind it.
test_a_captain_message_after_the_approval_still_refuses_when_approved() {
  approved_case 60
  write_transcript "$TRANSCRIPT" 900000 "$(iso_now)"
  assert_refuses "spoken since the receipt" \
    "an approved reset after the captain spoke again past the receipt" --captain-approved
}

# A bare flag asserting approval with nothing behind it is exactly what this path
# must not become, so with no captain record to point at, it refuses.
test_an_approved_path_with_no_captain_record_refuses() {
  make_case
  write_transcript "$TRANSCRIPT" 900000 ""
  write_receipt
  assert_refuses "cannot name what it would be treating as the approval" \
    "an approved reset with no captain record behind it" --captain-approved
}

# A record the log cannot cite is a reset nobody can audit afterwards, which on
# this path is the same thing as a reset nobody can check at all.
test_an_approved_path_with_an_uncitable_captain_record_refuses() {
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)" 0 ""
  write_receipt
  assert_refuses "carries no id" \
    "an approved reset whose captain record cannot be cited" --captain-approved
}

# scan_published_fields: the three values fm_context_scan publishes, read straight
# out of the shared predicates rather than inferred from a refusal, so a test can
# see which value landed in which slot.
scan_published_fields() {  # <transcript>
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  env -u FM_ROOT_OVERRIDE bash -c '
      set -u
      . "$1"
      fm_context_scan "$2" >/dev/null 2>&1
      printf "tokens=[%s] ts=[%s] uuid=[%s]\n" \
        "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_LAST_HUMAN_TS" "$FM_CONTEXT_LAST_HUMAN_UUID"
    ' fm-context-reset-test "$ROOT/bin/fm-context-lib.sh" "$1"
}

# The scan publishes its three values out of ONE tab-separated line, and any of
# them can legitimately be empty - so the split has to be field-exact rather than
# whitespace-ish. A captain record carrying an id but no timestamp is the shape
# that proves it: the two tabs arrive adjacent, and a splitter that treats a run
# of them as one delimiter slides the id into the TIMESTAMP's slot. Nothing
# downstream can then tell the difference - the reset compares an id against a
# clock reading, and the approved path's entire audit claim is that the record it
# named is the record it relied on. So both halves are asserted here: the fields
# stay in their own slots, and the reset that follows refuses for the reason that
# is actually true of this transcript rather than for a shifted one.
test_a_captain_record_without_a_timestamp_keeps_its_id_out_of_the_timestamp() {
  local fields
  make_case
  {
    printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"session-start nudge"},"timestamp":"2020-01-01T00:00:00.000Z"}\n'
    printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","uuid":"%s","message":{"role":"user","content":"captain says something"}}\n' \
      "$CAPTAIN_RECORD_ID"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":900000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  } > "$TRANSCRIPT"
  write_receipt
  fields=$(scan_published_fields "$TRANSCRIPT")
  assert_contains "$fields" 'tokens=[900000]' \
    "the token figure did not survive a transcript whose captain record has no timestamp"
  assert_contains "$fields" 'ts=[]' \
    "a captain record with no timestamp published something as its timestamp anyway"
  assert_contains "$fields" "uuid=[$CAPTAIN_RECORD_ID]" \
    "the captain record's id did not reach the slot that names the record"
  assert_refuses "cannot name what it would be treating as the approval" \
    "an approved reset whose captain record carries an id but no timestamp" --captain-approved
}

# The gap the idle window used to cover. Every gate runs once, and the clear is
# typed later - after the backend probe, the pane resolution and the
# display-message round trips. On this path the captain is present by
# construction, so a follow-up typed into that gap is ordinary rather than
# exotic, and it would be answered into the context the clear then discards.
# The fake tmux stub appends the follow-up on its first call, which is the pane
# resolution: after the gates, before the send, deterministically.
test_a_captain_who_speaks_between_the_checks_and_the_send_refuses() {
  approved_case 60
  printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","uuid":"cap-record-late","message":{"role":"user","content":"one more thing"},"timestamp":"%s"}\n' \
    "$(iso_now)" > "$HOME_DIR/late-captain.jsonl"
  export FM_FAKE_TMUX_APPEND_ONCE="$HOME_DIR/late-captain.jsonl"
  export FM_FAKE_TMUX_APPEND_TO="$TRANSCRIPT"
  assert_refuses "SPOKE AFTER APPROVING" \
    "an approved reset whose captain spoke between the checks and the send" --captain-approved
  unset FM_FAKE_TMUX_APPEND_ONCE FM_FAKE_TMUX_APPEND_TO
  assert_contains "$RESET_OUT" "FRESH APPROVAL" \
    "the pre-send refusal did not say a fresh approval is what is needed"
  assert_contains "$RESET_OUT" "$CAPTAIN_RECORD_ID" \
    "the pre-send refusal did not name the record it had taken as the approval"
  assert_contains "$RESET_OUT" "cap-record-late" \
    "the pre-send refusal did not name the newer captain record"
  assert_present "$STATE_DIR/.stow-receipt" "the pre-send refusal consumed the receipt"
  pass "a captain who speaks between the approved path's checks and its send refuses the discard"
}

# And the re-check is the approved path's alone. The autonomous path meets the
# same race - it always has - and the idle window is what covers it there, so
# adding a second gate to it would be a behaviour change the flag must not make.
test_the_pre_send_recheck_does_not_reach_the_autonomous_path() {
  make_case
  printf '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","uuid":"cap-record-late","message":{"role":"user","content":"one more thing"},"timestamp":"%s"}\n' \
    "$(iso_now)" > "$HOME_DIR/late-captain.jsonl"
  export FM_FAKE_TMUX_APPEND_ONCE="$HOME_DIR/late-captain.jsonl"
  export FM_FAKE_TMUX_APPEND_TO="$TRANSCRIPT"
  run_reset
  unset FM_FAKE_TMUX_APPEND_ONCE FM_FAKE_TMUX_APPEND_TO
  expect_code 0 "$RESET_CODE" "the autonomous path gained a gate it never had"
  assert_contains "$RESET_OUT" "reset submitted" "the autonomous path stopped reporting its clear"
  pass "the pre-send re-check is the approved path's own and leaves the autonomous path alone"
}

test_away_mode_refuses_on_the_approved_path_too() {
  approved_case 60
  touch "$STATE_DIR/.afk"
  assert_refuses "away mode is still active" \
    "an approved reset while away mode still owns wake delivery" --captain-approved
}

# The autonomous path is the one that has always worked, so the flag must be
# inert without it. Both windows it relaxes are re-asserted here in one place,
# against a session that satisfies neither, and the durable log must carry no
# trace of the approved path.
test_the_autonomous_path_is_unchanged_by_the_approved_one() {
  # The idle window, still refusing on a captain who spoke inside it.
  approved_case 60
  run_reset
  expect_code 1 "$RESET_CODE" "the autonomous path stopped refusing a captain inside the idle window"
  assert_contains "$RESET_OUT" "within the last 1800s" "the idle window's bound moved"
  assert_no_grep 'path=captain-approved' "$STATE_DIR/.context-reset.log" \
    "an autonomous run marked itself as the approved path in the durable log"
  # The receipt's age window, still refusing on a receipt past it.
  make_case
  sed -i.bak "s/^written_at=.*/written_at=$(( $(date +%s) - 5000 ))/" "$STATE_DIR/.stow-receipt"
  run_reset
  expect_code 1 "$RESET_CODE" "the autonomous path stopped refusing a receipt past its age window"
  assert_contains "$RESET_OUT" "limit 900s" "the receipt's freshness bound moved"
  # And it still completes on the session it always completed on.
  make_case
  run_reset
  expect_code 0 "$RESET_CODE" "the autonomous path stopped completing on a session it always cleared"
  assert_contains "$RESET_OUT" "reset submitted" "the autonomous path stopped reporting its clear"
  assert_no_grep 'path=captain-approved' "$STATE_DIR/.context-reset.log" \
    "a completed autonomous reset was logged as an approved one"
  pass "the approved path leaves the autonomous path's two windows and its log lines exactly as they were"
}

# --- the quiet boundary, re-checked at the moment of the discard ------------

test_queued_wake_refuses() {
  make_case
  printf '%s\t1\tsignal\ta.status\tsignal: a\n' "$(date +%s)" > "$STATE_DIR/.wake-queue"
  assert_refuses "queued wake is still undrained" "a reset with an undrained wake"
}

test_worker_waiting_on_an_answer_refuses() {
  make_case
  printf 'working: started\nneeds-decision: which option\n' > "$STATE_DIR/alpha.status"
  assert_refuses "still waiting on an answer" "a reset while a worker waits on an answer"
}

test_resolved_decision_does_not_block() {
  local out
  make_case
  printf 'needs-decision: which option\nresolved: the captain chose the first\n' > "$STATE_DIR/alpha.status"
  run_reset --check
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "a closed decision must not block a reset"
  pass "a decision that was answered and closed no longer holds the reset"
}

test_pending_routed_reply_refuses() {
  make_case
  mkdir -p "$STATE_DIR/pending-replies"
  printf 'task_id=beta\n' > "$STATE_DIR/pending-replies/corr-1"
  assert_refuses "awaiting its reply" "a reset with a routed request still unanswered"
}

# --- the way back in --------------------------------------------------------

test_missing_clear_in_the_restart_matcher_refuses() {
  make_case
  write_settings "$HOME_DIR" 'startup|resume' 'fm-sessionstart-nudge.sh'
  assert_refuses "no longer runs fm-sessionstart-nudge.sh on a clear" \
    "a reset whose session-start hook no longer fires on a clear"
}

test_restart_hook_pointing_elsewhere_refuses() {
  make_case
  write_settings "$HOME_DIR" 'startup|resume|clear' 'some-other-hook.sh'
  assert_refuses "no longer runs fm-sessionstart-nudge.sh on a clear" \
    "a reset whose session-start hook no longer runs the re-entry script"
}

test_missing_hook_settings_refuses() {
  make_case
  rm -f "$HOME_DIR/.claude/settings.json"
  assert_refuses "no hook settings" "a reset with no session-start hook configured at all"
}

# --- supervision survives ---------------------------------------------------

test_dead_supervision_refuses() {
  make_case
  rm -rf "$STATE_DIR/.watch.lock"
  assert_refuses "supervision is not running" "a reset with no live supervision to wake the next session"
}

test_down_delivery_with_work_recorded_refuses() {
  make_case
  fm_write_meta "$STATE_DIR/beta.meta" 'window=fmtest:fm-beta' 'harness=claude' 'kind=ship'
  rm -rf "$STATE_DIR/.delivery.lock"
  assert_refuses "wake-delivery listener is not running" "a reset that would strand recorded work with no way to wake"
}

test_down_delivery_with_no_work_proceeds() {
  local out
  make_case
  rm -rf "$STATE_DIR/.delivery.lock"
  run_reset --check
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "an idle home must not be blocked by a down delivery listener"
  pass "with nothing recorded to wake for, a down delivery listener does not block the reset"
}

# --- identity and harness ---------------------------------------------------

test_foreign_session_record_refuses() {
  make_case
  sed -i.bak 's/^harness_pid=.*/harness_pid=999999999/' "$STATE_DIR/.primary-transcript"
  assert_refuses "only a session may reset itself" "a reset driven from outside the recorded session"
}

test_read_only_session_refuses() {
  make_case
  # Another live process holds the home lock, so this session is read-only by
  # contract and must not file knowledge or discard any.
  sleep 60 &
  printf '%s\n' "$!" > "$STATE_DIR/.lock"
  assert_refuses "read-only" "a reset from a session that does not operate this home"
  kill "$!" 2>/dev/null || true
}

test_receipt_refuses_from_a_read_only_session() {
  local out status=0
  make_case
  sleep 60 &
  printf '%s\n' "$!" > "$STATE_DIR/.lock"
  out=$(run_env "$RECEIPT_BIN" 2>&1) || status=$?
  expect_code 1 "$status" "a receipt written from a read-only session"
  assert_contains "$out" "read-only" "the receipt writer refused for the wrong reason"
  kill "$!" 2>/dev/null || true
  pass "a read-only session cannot attest that it filed anything"
}

test_missing_transcript_record_refuses() {
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  assert_refuses "no session transcript recorded" "a reset with no recorded transcript"
}

test_errored_transcript_record_refuses() {
  make_case
  printf 'status=error\nerror=no-hook-payload\nharness_pid=%s\n' "$$" > "$STATE_DIR/.primary-transcript"
  assert_refuses "in error state" "a reset whose session never recorded a usable transcript"
}

test_undetected_backend_refuses() {
  local out status=0
  make_case
  # Neither TMUX_PANE nor herdr's markers: nothing is detected, and the detector
  # still prints its tmux default. Falling through to that default would run the
  # tmux-only clear on a session nobody proved is a tmux session.
  out=$(env -u FM_ROOT_OVERRIDE -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    -u FM_SUPERVISOR_BACKEND -u FM_SUPERVISOR_TARGET \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    CLAUDECODE=1 "$RESET" 2>&1) || status=$?
  expect_code 1 "$status" "a reset on a session with no detectable terminal backend"
  assert_contains "$out" "terminal backend could not be detected" \
    "the undetected backend refused for the wrong reason"
  assert_no_grep 'send-keys' "$TMUX_LOG" "an undetected backend still typed into the pane"
  pass "a backend that was guessed rather than detected refuses instead of clearing"
}

test_unverified_harness_refuses() {
  local out
  make_case
  out=$(env -u FM_ROOT_OVERRIDE -u CLAUDECODE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    TMUX_PANE='%9' PI_CODING_AGENT=true "$RESET" 2>&1) || RESET_CODE=$?
  expect_code 1 "$RESET_CODE" "a reset on an unverified harness"
  assert_contains "$out" "only verified for claude" "the harness refusal named the wrong reason"
  assert_no_grep 'send-keys' "$TMUX_LOG" "an unverified harness still typed into the pane"
  pass "self-clear is refused on any harness it was not proven on"
}

# --- the watcher's ceiling branch -------------------------------------------

# The watcher's own function, sourced from the real bin/fm-watch.sh (which
# returns before its lock and loop when sourced), so suppression and the branch
# are exercised as the watcher runs them. The watcher path is passed as $1, never
# as $0: its source guard compares BASH_SOURCE[0] against $0, so a $0 that names
# the watcher would make it start its real singleton loop instead of returning.
watch_reason() {  # [extra env assignments...]
  # shellcheck disable=SC2016 # The inner script's $1 is the child shell's, on purpose.
  env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    PATH="$FAKEBIN:$PATH" "$@" bash -c '
      set -u
      . "$1" >/dev/null 2>&1
      context_ceiling_surface
    ' fm-context-reset-test "$ROOT/bin/fm-watch.sh"
}

# The branch identity and the poll's resolution state, straight from the shared
# predicate. Asserting these rather than payload wording is the point: the class
# is the suppression key, so a reworded message must never quietly change which
# condition a wake counts as.
watch_class() {
  # shellcheck disable=SC2016 # The inner script's $1 is the child shell's, on purpose.
  env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    PATH="$FAKEBIN:$PATH" bash -c '
      set -u
      . "$1" >/dev/null 2>&1
      fm_context_ceiling_reason "$STATE" "$FM_HOME" "$FM_ROOT" >/dev/null
      printf "%s/%s\n" "$FM_CONTEXT_CEILING_CLASS" "$FM_CONTEXT_CEILING_STATE"
    ' fm-context-reset-test "$ROOT/bin/fm-watch.sh"
}

assert_class() {  # <expected-class/state> <label>
  local got
  got=$(watch_class)
  [ "$got" = "$1" ] || fail "$2: expected class/state '$1', got '$got'"
}

test_watcher_is_silent_under_the_ceiling() {
  local out
  make_case
  write_transcript "$TRANSCRIPT" 1000 ""
  out=$(watch_reason)
  [ -z "$out" ] || fail "the watcher reported a ceiling wake below the ceiling: $out"
  pass "a session under the ceiling produces no wake at all"
}

test_watcher_asks_when_the_captain_is_active() {
  local out
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  out=$(watch_reason)
  assert_contains "$out" "check: context-ceiling:" "the captain-present branch produced no check wake"
  assert_contains "$out" "ASK the captain" "the captain-present branch did not ask"
  assert_not_contains "$out" "fm-context-reset.sh" "the captain-present branch handed over a reset command"
  pass "over the ceiling with the captain present, the watcher asks instead of resetting"
}

test_watcher_asks_in_away_mode() {
  local out
  make_case
  touch "$STATE_DIR/.afk"
  out=$(watch_reason)
  assert_contains "$out" "ASK the captain" "away mode did not take the ask branch"
  pass "away mode takes the ask branch rather than resetting behind the captain's back"
}

test_watcher_hands_over_the_reset_when_the_captain_is_gone() {
  local out
  make_case
  out=$(watch_reason)
  assert_contains "$out" "the fleet is quiet and the captain is not present" \
    "the quiet branch did not report its condition"
  assert_contains "$out" "/stow" "the reset wake did not name the filing step"
  assert_contains "$out" "fm-stow-receipt.sh" "the reset wake did not name the receipt step"
  assert_contains "$out" "fm-context-reset.sh" "the reset wake did not name the reset step"
  pass "over the ceiling at a quiet boundary, one wake carries the whole reset procedure"
}

test_watcher_is_silent_while_the_fleet_is_busy() {
  local out
  make_case
  printf 'needs-decision: which option\n' > "$STATE_DIR/alpha.status"
  out=$(watch_reason)
  [ -z "$out" ] || fail "the watcher fired a ceiling wake while a worker waited: $out"
  pass "the ceiling waits for a quiet boundary rather than interrupting live work"
}

test_watcher_reports_when_it_cannot_measure() {
  local out
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  out=$(watch_reason)
  assert_contains "$out" "cannot be measured" "an unmeasurable ceiling was passed over silently"
  assert_contains "$out" "unenforced" "the unmeasurable case did not say the ceiling is not being applied"
  pass "a live session whose ceiling cannot be measured is reported, never silently skipped"
}

test_watcher_reports_a_record_from_a_finished_session() {
  local out
  make_case
  sed -i.bak 's/^harness_pid=.*/harness_pid=424242/' "$STATE_DIR/.primary-transcript"
  out=$(watch_reason)
  assert_contains "$out" "unenforced" "a transcript record from another session was measured as if it were this one"
  assert_not_contains "$out" "fm-context-reset.sh" "a reset was ordered off another session's transcript"
  pass "a transcript record that disagrees with the running session is reported, not measured"
}

test_watcher_is_silent_with_no_session_running() {
  local out
  make_case
  # No session lock: a fresh home, a home between sessions, and every non-primary
  # home look exactly like this, and none of them is a fault.
  rm -f "$STATE_DIR/.lock"
  rm -f "$STATE_DIR/.primary-transcript"
  out=$(watch_reason)
  [ -z "$out" ] || fail "a home with no session running raised a ceiling alarm: $out"
  pass "a home with no session running says nothing rather than alarming forever"
}

test_watcher_reports_a_measurement_failure_once_until_it_changes() {
  local first second
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  first=$(watch_reason)
  assert_contains "$first" "cannot be measured" "the first measurement failure was not reported"
  touch -t 202001010000 "$STATE_DIR/.context-ceiling-surfaced"
  second=$(watch_reason)
  [ -z "$second" ] || fail "an unchanged measurement failure raised a second wake: $second"
  pass "a standing measurement failure raises one wake and stays quiet until it changes"
}

# The ask branch is the one a captain who is present would otherwise hear every
# CONTEXT_CHECK_INTERVAL for as long as they are around, so it is suppressed on
# exactly the same terms as the unmeasurable one.
test_watcher_reports_an_unchanged_ask_once() {
  local first second
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  first=$(watch_reason)
  assert_contains "$first" "ASK the captain" "the first ask was not reported"
  touch -t 202001010000 "$STATE_DIR/.context-ceiling-surfaced"
  second=$(watch_reason)
  [ -z "$second" ] || fail "an unchanged ask raised a second wake: $second"
  pass "a still-true ask raises one wake and stays quiet until it changes"
}

test_watcher_surfaces_a_changed_branch_immediately() {
  local first second
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  first=$(watch_reason)
  assert_contains "$first" "ASK the captain" "the ask branch did not report first"
  # The captain leaves. The condition has CHANGED, so waiting out the ask branch's
  # quiet period would delay the reset it now hands over by up to an hour.
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  second=$(watch_reason)
  assert_contains "$second" "the captain is not present" \
    "a changed ceiling branch inherited suppression from the previous class"
  assert_contains "$second" "fm-context-reset.sh" "the reset branch surfaced without its commands"
  pass "a ceiling branch that changes surfaces on the next poll instead of waiting out the old one"
}

test_watcher_clears_suppression_when_the_condition_resolves() {
  local out
  make_case
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" "the reset branch did not report first"
  assert_present "$STATE_DIR/.context-ceiling-surfaced" "a reported ceiling branch left no suppression marker"
  # Back under the ceiling: the condition is genuinely gone, not merely quiet.
  write_transcript "$TRANSCRIPT" 1000 ""
  assert_class "/resolved" "a session back under the ceiling"
  out=$(watch_reason)
  [ -z "$out" ] || fail "a session back under the ceiling still reported: $out"
  [ -e "$STATE_DIR/.context-ceiling-surfaced" ] \
    && fail "a resolved condition left the ceiling suppression marker in place"
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" \
    "the ceiling report did not return immediately after suppression was cleared"
  pass "a condition that genuinely resolves clears suppression, so the next one reports at once"
}

test_watcher_clears_suppression_when_the_session_ends() {
  make_case
  watch_reason >/dev/null
  assert_present "$STATE_DIR/.context-ceiling-surfaced" "a reported ceiling branch left no suppression marker"
  rm -f "$STATE_DIR/.lock"
  assert_class "/resolved" "a home with no session running"
  watch_reason >/dev/null
  [ -e "$STATE_DIR/.context-ceiling-surfaced" ] \
    && fail "a home whose session ended kept the previous session's ceiling suppression marker"
  pass "a session that ends clears the suppression marker it left behind"
}

# --- an absent protection is not routine traffic ----------------------------
#
# The defect these exist for was not the diagnosis, which was exact, but the
# REPEAT: the unenforced wake arrived once an hour for a whole day on 2026-08-19,
# word-for-word identical every time, and was absorbed every time. The durable
# record must carry what the repeated model turns used to carry.

test_a_first_absent_report_carries_only_its_diagnosis() {
  local out
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  out=$(watch_reason)
  assert_contains "$out" "cannot be measured" "the first unenforced report lost its diagnosis"
  assert_not_contains "$out" "no working protection since" \
    "a first report claimed a history it does not have"
  pass "the first report of an absent protection states the condition and nothing more"
}

test_an_unchanged_absence_updates_its_record_without_another_wake() {
  local out record since
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  watch_reason >/dev/null
  since=$(( $(date +%s) - 25200 ))
  printf 'unenforced %s 1\n' "$since" > "$STATE_DIR/.context-ceiling-absent-since"
  touch -t 202001010000 "$STATE_DIR/.context-ceiling-surfaced"
  out=$(watch_reason)
  [ -z "$out" ] || fail "an unchanged absent protection raised a second wake: $out"
  record=$(cat "$STATE_DIR/.context-ceiling-absent-since")
  [ "$record" = "unenforced $since 2" ] \
    || fail "the quiet absence did not retain its age and advance its observation count: $record"
  pass "an unchanged absence stays quiet while its durable age and observation count advance"
}

test_an_absence_record_failure_repeats_the_wake() {
  local out
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  watch_reason >/dev/null
  rm -f "$STATE_DIR/.context-ceiling-absent-since"
  mkdir "$STATE_DIR/.context-ceiling-absent-since"

  out=$(watch_reason 2>/dev/null)

  assert_contains "$out" "cannot be measured" \
    "a failed absence-record update left the unenforced ceiling silent"
  pass "an unenforced ceiling repeats its wake when its durable record cannot be updated"
}

# The other half of the same rule: nothing about a protection that is WORKING
# gets louder. The ask branch fires whenever the captain is present, which is
# most of the day, and turning that into an escalation would bury the class this
# change exists to raise.
test_an_unchanged_ask_gains_no_escalation() {
  local first second
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  first=$(watch_reason)
  assert_contains "$first" "ASK the captain" "the first ask was not reported"
  touch -t 202001010000 "$STATE_DIR/.context-ceiling-surfaced"
  second=$(watch_reason)
  [ -z "$second" ] || fail "an unchanged working ceiling was escalated: $second"
  [ -e "$STATE_DIR/.context-ceiling-absent-since" ] \
    && fail "a working ceiling started an absence clock"
  pass "a ceiling that is working, and merely waiting for the captain, stays quiet unchanged"
}

# A different absence is a different occurrence. Dating an unresettable ceiling
# from the moment an unmeasurable one started would report an age that never
# happened, which is the same defect as reporting no age at all.
test_a_changed_absent_class_restarts_the_clock() {
  local out record_class record_since record_observations old_since
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  watch_reason >/dev/null
  old_since=$(( $(date +%s) - 25200 ))
  printf 'unenforced %s 4\n' "$old_since" > "$STATE_DIR/.context-ceiling-absent-since"
  # The transcript comes back and the re-entry hook goes away: measurable again,
  # but the reset it would order cannot run.
  record_ok
  write_settings "$HOME_DIR" 'startup|resume' 'fm-sessionstart-nudge.sh'
  out=$(watch_reason)
  assert_contains "$out" "cannot run safely" "the blocked branch did not report its own condition"
  read -r record_class record_since record_observations \
    < "$STATE_DIR/.context-ceiling-absent-since"
  [ "$record_class" = blocked ] \
    || fail "the absence record kept the old class after the condition changed: $record_class"
  [ "$record_since" -gt "$old_since" ] \
    || fail "the changed absence inherited the previous class's first-observed time"
  [ "$record_observations" -eq 1 ] \
    || fail "the changed absence inherited the previous class's observation count"
  pass "an absence of a different kind is dated from itself, not from the one before it"
}

test_a_resolved_condition_clears_the_absence_clock() {
  local out
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  watch_reason >/dev/null
  assert_present "$STATE_DIR/.context-ceiling-absent-since" "an absent protection left no absence record"
  # The session records its transcript again: the protection is back.
  record_ok
  write_transcript "$TRANSCRIPT" 1000 ""
  watch_reason >/dev/null
  [ -e "$STATE_DIR/.context-ceiling-absent-since" ] \
    && fail "a repaired ceiling kept the absence clock of the outage before it"
  # It goes away again: this is a new outage and must report as a first one.
  rm -f "$STATE_DIR/.primary-transcript"
  out=$(watch_reason)
  assert_contains "$out" "cannot be measured" "the new outage was not reported"
  assert_not_contains "$out" "no working protection since" \
    "a new outage was reported with the previous outage's history"
  pass "a protection that comes back clears its own absence clock, so the next outage is a first report"
}

# The regression this exists for: the ceiling wake is appended to
# state/.wake-queue, and an undrained queue is the first thing fm_context_quiet
# tests, so the very next poll after a ceiling wake finds the fleet busy. Reading
# that as "the condition is gone" let each wake erase its own suppression marker
# and come back once per drain cycle.
test_watcher_keeps_suppression_while_its_own_wake_is_undrained() {
  local first second third
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  first=$(watch_reason)
  assert_contains "$first" "ASK the captain" "the first ask was not reported"
  # T=0 enqueued the wake this poll just produced; firstmate has not drained it.
  printf '%s\t1\tcheck\tcontext-ceiling\t%s\n' "$(date +%s)" "$first" > "$STATE_DIR/.wake-queue"
  assert_class "/suppressed" "a poll taken while the ceiling wake is still queued"
  second=$(watch_reason)
  [ -z "$second" ] || fail "a busy poll reported a second ceiling wake: $second"
  assert_present "$STATE_DIR/.context-ceiling-surfaced" \
    "an undrained wake erased the suppression marker it had just set"
  # Firstmate drains, and the captain is still there: nothing has changed.
  rm -f "$STATE_DIR/.wake-queue"
  third=$(watch_reason)
  [ -z "$third" ] || fail "the ask re-fired after its own wake was drained: $third"
  pass "a ceiling wake sitting undrained does not clear its suppression marker"
}

test_watcher_publishes_a_stable_class_per_branch() {
  make_case
  assert_class "reset/surfaced" "over the ceiling, quiet, captain gone"
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  assert_class "ask/surfaced" "over the ceiling with the captain present"
  write_settings "$HOME_DIR" 'startup|resume' 'fm-sessionstart-nudge.sh'
  assert_class "blocked/surfaced" "over the ceiling with the re-entry hook unwired"
  write_settings "$HOME_DIR" 'startup|resume|clear' 'fm-sessionstart-nudge.sh'
  rm -f "$STATE_DIR/.primary-transcript"
  assert_class "unenforced/surfaced" "a live session that cannot be measured"
  record_ok
  printf 'needs-decision: which option\n' > "$STATE_DIR/alpha.status"
  assert_class "/suppressed" "over the ceiling while a worker waits on an answer"
  pass "every ceiling branch publishes its own stable class token, independent of payload wording"
}

test_watcher_refuses_to_hand_over_a_reset_with_a_broken_restart_path() {
  local out
  make_case
  write_settings "$HOME_DIR" 'startup|resume' 'fm-sessionstart-nudge.sh'
  out=$(watch_reason)
  assert_contains "$out" "cannot run safely" "a broken re-entry path was not reported"
  assert_not_contains "$out" "fm-context-reset.sh" "a reset was handed over with no way back in"
  pass "with the re-entry hook broken, the wake reports the blocker instead of ordering a reset"
}

# The function above is only useful if the loop actually calls it, so drive a real
# fm-watch.sh process and assert the durable queue - the record firstmate is
# already obliged to drain - carries the ceiling wake.
test_watcher_process_enqueues_the_ceiling_wake() {
  local out status=0
  make_case
  # The fixture's recorded supervision locks belong to the test shell, which would
  # make a real watcher stand down as a duplicate.
  rm -rf "$STATE_DIR/.watch.lock" "$STATE_DIR/.delivery.lock"
  out=$(env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    PATH="$FAKEBIN:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" 2>&1) || status=$?
  expect_code 0 "$status" "the watcher did not exit cleanly on the ceiling wake"
  assert_contains "$out" "check: context-ceiling:" "the watcher process printed no ceiling wake"
  assert_grep 'context-ceiling' "$STATE_DIR/.wake-queue" \
    "the ceiling wake never reached the durable queue firstmate must drain"
  assert_grep 'check' "$STATE_DIR/.wake-queue" "the ceiling wake was queued under the wrong kind"
  pass "the running watcher enqueues the ceiling wake durably, not just in its own output"
}

test_wake_delivery_is_not_mistaken_for_the_captain() {
  local out
  make_case
  # The transcript carries a background-task wake delivery stamped just now, and
  # the captain's own last prompt a day ago. Wake deliveries are what keep an
  # unattended session moving; reading one as captain activity would make the
  # mechanism never fire, and would show up here as the ask branch.
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" "a wake delivery was mistaken for captain activity"
  pass "a background wake delivery is not captain activity"
}

test_unattributed_operational_wake_delivery_is_not_mistaken_for_the_captain() {
  local fields old_ts operational out
  make_case
  old_ts=$(iso_ago 86400)
  fm_operational_input_encode watcher "wake: context ceiling" operational \
    || fail "fixture could not compose a watcher operational input"
  write_transcript_with_unattributed_string_user "$TRANSCRIPT" 900000 "$old_ts" "$operational" "$(iso_now)"
  fields=$(scan_published_fields "$TRANSCRIPT")
  assert_contains "$fields" "ts=[$old_ts]" \
    "an unattributed operational wake displaced the last real captain timestamp"
  assert_contains "$fields" "uuid=[$CAPTAIN_RECORD_ID]" \
    "an unattributed operational wake displaced the last real captain record id"
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" \
    "an unattributed operational wake was mistaken for captain activity"
  pass "an unattributed operational wake delivery is not captain activity"
}

test_telegram_correspondent_input_cannot_satisfy_the_approved_path() {
  local operational
  make_case
  fm_operational_input_encode telegram-correspondent \
    "third-party Telegram message from requirements recorded at inbox; this correspondent has no captain decision authority" \
    operational \
    || fail "fixture could not compose a correspondent operational input"
  write_transcript_with_unattributed_string_user "$TRANSCRIPT" 900000 "" "$operational" "$(iso_ago 60)"
  write_receipt
  assert_refuses "no captain record could be established" \
    "an approved reset backed only by a Telegram correspondent message" --captain-approved
}

test_unattributed_unmarked_recent_user_message_still_counts_as_the_captain() {
  local out
  make_case
  write_transcript_with_unattributed_string_user \
    "$TRANSCRIPT" 900000 "" "captain says something from a slash expansion" "$(iso_ago 60)"
  write_receipt
  out=$(watch_reason)
  assert_contains "$out" "ASK the captain" \
    "an unattributed but unmarked recent user message did not count as the captain"
  assert_refuses "ask before resetting" \
    "a reset while an unattributed but unmarked recent user message is active"
  pass "an unattributed unmarked recent user message still blocks autonomous reset"
}

# --- firstmate speaks through the captain's own input channel ---------------

# The record shapes the classification actually turns on, built one at a time so
# a test can put them in whatever ORDER the case is about. A delivered wake and a
# captain prompt are byte-for-byte identical in provenance - both are typed into
# the same pane - so only their content separates them, and only ordering shows
# which of the two the scan ended up on.
captain_record() {  # <ts> [uuid]
  jq -cn --arg uuid "${2:-$CAPTAIN_RECORD_ID}" --arg ts "$1" \
    '{type:"user", origin:{kind:"human"}, promptSource:"typed", uuid:$uuid,
      message:{role:"user", content:"captain says something"}, timestamp:$ts}'
}

typed_operational_record() {  # <content> <ts> [uuid]
  jq -cn --arg uuid "${3:-typed-operational-record-0001}" --arg content "$1" --arg ts "$2" \
    '{type:"user", origin:{kind:"human"}, promptSource:"typed", uuid:$uuid,
      message:{role:"user", content:$content}, timestamp:$ts}'
}

write_records() {  # <path> <tokens> <record-json...>
  local path=$1 tokens=$2
  shift 2
  {
    printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"session-start nudge"},"timestamp":"2020-01-01T00:00:00.000Z"}\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens"
  } > "$path"
}

# The defect this whole change exists for, in its exact measured shape.
# Firstmate's wake delivery is TYPED into the session's pane, so the harness
# stamps it `origin.kind == "human"`, `promptSource == "typed"` - the provenance
# of a captain prompt, because it arrived through the captain's own input
# channel. The structural test matched it first and the operational classifier
# was never consulted, so every delivered wake re-dated the captain to the moment
# of its own delivery: the watcher chose the reset branch, the wake carrying that
# order became the newest "captain" record, and the reset tool then refused the
# order the watcher had just given. Four times over three hours on this seat,
# 2026-08-20. The mechanism could not fire on any seat that receives wakes,
# which is every seat.
test_a_typed_wake_delivery_is_not_mistaken_for_the_captain() {
  local fields out old_ts operational
  make_case
  old_ts=$(iso_ago 86400)
  fm_operational_input_encode watcher \
    "Wake delivery: 1 wake record(s) are pending in the durable queue." operational \
    || fail "fixture could not compose a watcher operational input"
  write_records "$TRANSCRIPT" 900000 \
    "$(captain_record "$old_ts")" \
    "$(typed_operational_record "$operational" "$(iso_now)")"
  fields=$(scan_published_fields "$TRANSCRIPT")
  assert_contains "$fields" "ts=[$old_ts]" \
    "a typed wake delivery displaced the last real captain timestamp"
  assert_contains "$fields" "uuid=[$CAPTAIN_RECORD_ID]" \
    "a typed wake delivery displaced the last real captain record id"
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" \
    "a typed wake delivery was mistaken for captain activity, so the reset branch was unreachable"
  pass "a wake delivery typed into the pane is not captain activity, whatever provenance the harness stamped on it"
}

# The other direction, and it is the one that matters more. A scan that skips too
# much silently disables the guard protecting the captain from a reset landing
# mid-conversation - a far worse outcome than the bug above. So: the newest
# record is a genuine captain prompt sitting BEHIND a typed wake delivery, in the
# order a real conversation produces it, and it must still win.
test_a_captain_prompt_behind_a_typed_wake_delivery_still_blocks_the_reset() {
  local fields out recent_ts operational
  make_case
  recent_ts=$(iso_ago 60)
  fm_operational_input_encode watcher \
    "Wake delivery: 1 wake record(s) are pending in the durable queue." operational \
    || fail "fixture could not compose a watcher operational input"
  write_records "$TRANSCRIPT" 900000 \
    "$(typed_operational_record "$operational" "$(iso_ago 120)")" \
    "$(captain_record "$recent_ts")"
  write_receipt
  fields=$(scan_published_fields "$TRANSCRIPT")
  assert_contains "$fields" "ts=[$recent_ts]" \
    "the captain's own prompt was skipped along with the wake delivery in front of it"
  assert_contains "$fields" "uuid=[$CAPTAIN_RECORD_ID]" \
    "the captain's own record id was skipped along with the wake delivery in front of it"
  out=$(watch_reason)
  assert_contains "$out" "ASK the captain" \
    "the watcher offered an autonomous reset while the captain was mid-conversation"
  assert_not_contains "$out" "fm-context-reset.sh" \
    "the watcher handed over a reset command while the captain was mid-conversation"
  assert_refuses "the captain has been active within the last" \
    "a reset while the captain has spoken since the last wake delivery"
  pass "a captain prompt is still the captain when a typed wake delivery sits in front of it"
}

# Narrowing the exclusion to the one payload that caused the incident would leave
# every other delivery still re-dating the captain, so each form firstmate can
# put on that channel is asserted on the shape it actually arrives in: typed,
# with a captain prompt's provenance.
test_every_operational_form_stays_excluded_when_typed() {
  local kind old_ts operational fields forms=()
  make_case
  old_ts=$(iso_ago 86400)
  for kind in session-start watcher turn-end-guard away-supervisor launch-brief telegram-correspondent; do
    fm_operational_input_encode "$kind" "operational body for $kind" operational \
      || fail "fixture could not compose a $kind operational input"
    forms+=("$operational")
  done
  fm_operational_input_construct from-firstmate "routed instruction" operational \
    || fail "fixture could not compose a from-firstmate input"
  forms+=("$operational")
  forms+=(
    "$FM_LEGACY_SESSIONSTART"
    "${FM_LEGACY_AWAY_PREFIX}context ceiling)"
    "${FM_LEGACY_WATCHER_PREFIX}context ceiling${FM_LEGACY_WATCHER_SUFFIX}"
    "${FM_LEGACY_TURNEND_PREFIX}recover supervision"
    "${FM_OPERATIONAL_PREFIX}an untyped legacy operational body"
  )
  for operational in "${forms[@]}"; do
    write_records "$TRANSCRIPT" 900000 \
      "$(captain_record "$old_ts")" \
      "$(typed_operational_record "$operational" "$(iso_now)")"
    fields=$(scan_published_fields "$TRANSCRIPT")
    assert_contains "$fields" "ts=[$old_ts]" \
      "a typed operational input was read as captain activity: $(printf '%s' "$operational" | head -c 40)"
  done
  pass "every operational form the classifier recognises stays excluded when it arrives with a captain prompt's provenance"
}

# --- one return value, four conditions, four sentences ----------------------

# fm_context_captain_active answers "present" for three genuinely different
# reasons, and its fail-safe for the unknown ones is correct and stays. What was
# wrong is that the callers printed the same sentence for all of them: on
# 2026-08-20 "the captain has been active within the last 1800s" was printed on a
# seat where the captain had not spoken for hours, and it read as a timing race
# for three attempts because the sentence named a cause rather than the condition.
presence_facts() {  # <last-human-ts>
  # FAKEBIN is on PATH so a test can put a deliberately broken tool in front of
  # the real one for the condition that needs it.
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  env -u FM_ROOT_OVERRIDE PATH="$FAKEBIN:$PATH" bash -c '
      set -u
      . "$1"
      if fm_context_captain_active "$2"; then v=present; else v=absent; fi
      printf "%s/%s/%s\n" "$v" "$FM_CONTEXT_CAPTAIN_PRESENCE" "$FM_CONTEXT_CAPTAIN_PRESENCE_WHY"
    ' fm-context-reset-test "$ROOT/bin/fm-context-lib.sh" "$1"
}

# A date that cannot produce the comparison instant, so nothing can be placed
# inside or outside the window. `date +%s` still answers, because the failure
# under test is the ISO conversion the comparison needs, not the clock itself.
install_failing_iso_date() {  # <fakebin>
  cat > "$1/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%s) exec /bin/date "$@" ;;
esac
exit 1
EOF
  chmod +x "$1/date"
}

test_each_reason_the_captain_counts_as_present_names_itself() {
  local spoke unreadable unrecorded unmeasurable idle
  make_case
  spoke=$(presence_facts "$(iso_ago 60)")
  unreadable=$(presence_facts "not-an-instant")
  unrecorded=$(presence_facts "")
  idle=$(presence_facts "$(iso_ago 86400)")
  install_failing_iso_date "$FAKEBIN"
  unmeasurable=$(presence_facts "$(iso_ago 86400)")
  rm -f "$FAKEBIN/date"

  assert_contains "$spoke" "present/spoke/" "a captain who genuinely spoke was not reported as having spoken"
  assert_contains "$spoke" "the captain has been active within the last" "the spoke condition lost its own sentence"
  assert_contains "$unreadable" "present/unreadable/" "an unreadable captain timestamp was not reported as unreadable"
  assert_contains "$unreadable" "unreadable timestamp" "the unreadable condition did not say the timestamp could not be read"
  assert_contains "$unrecorded" "present/unrecorded/" "an absent captain record was not reported as absent"
  assert_contains "$unrecorded" "was found anywhere" "the unrecorded condition did not say nothing was found"
  assert_contains "$unmeasurable" "present/unmeasurable/" "an unreadable clock was not reported as unmeasurable"
  assert_contains "$unmeasurable" "current time could not be read" "the unmeasurable condition did not say the clock could not be read"
  assert_contains "$idle" "absent/idle/" "a long-silent captain was not reported as idle"

  # The point of the tokens is that they are DIFFERENT. Four conditions that all
  # mean "present" must not collapse back into one indistinguishable answer.
  [ "${spoke%%/*}" = present ] || fail "the spoke condition stopped counting as present"
  [ "$spoke" != "$unreadable" ] || fail "a captain who spoke and an unreadable timestamp produced the same answer"
  [ "$spoke" != "$unrecorded" ] || fail "a captain who spoke and an absent record produced the same answer"
  [ "$unreadable" != "$unrecorded" ] || fail "an unreadable timestamp and an absent record produced the same answer"
  [ "$unmeasurable" != "$spoke" ] || fail "an unreadable clock and a captain who spoke produced the same answer"
  pass "each reason the captain counts as present names itself instead of all four claiming the captain spoke"
}

# The same distinction where an operator actually meets it: the tool's refusal.
# `unrecorded` refuses earlier, on the receipt's captain equality, and that
# refusal already says what it is - what matters is that the three sentences are
# three sentences.
test_a_refusal_names_which_captain_condition_it_hit() {
  local spoke_out unreadable_out unrecorded_out

  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  write_receipt
  run_reset
  spoke_out=$RESET_OUT
  expect_code 1 "$RESET_CODE" "a reset while the captain is in live conversation must refuse"
  assert_contains "$spoke_out" "the captain has been active within the last" \
    "a genuinely active captain was not named as the cause"

  make_case
  write_records "$TRANSCRIPT" 900000 "$(captain_record "not-an-instant")"
  write_receipt
  run_reset
  unreadable_out=$RESET_OUT
  expect_code 1 "$RESET_CODE" "a reset whose captain timestamp cannot be read must refuse"
  assert_contains "$unreadable_out" "unreadable timestamp" \
    "an unreadable captain timestamp was not named as the cause"
  assert_contains "$unreadable_out" "counts as present rather than absent" \
    "the refusal did not say that an unestablished presence is treated as present"
  assert_not_contains "$unreadable_out" "the captain has been active within the last" \
    "an unreadable timestamp still claimed the captain had been active"

  make_case
  write_transcript "$TRANSCRIPT" 900000 ""
  write_receipt
  run_reset
  unrecorded_out=$RESET_OUT
  expect_code 1 "$RESET_CODE" "a reset with no captain record at all must refuse"
  assert_contains "$unrecorded_out" "could not be established" \
    "a transcript with no captain record was not named as the cause"
  assert_not_contains "$unrecorded_out" "the captain has been active within the last" \
    "a transcript with no captain record still claimed the captain had been active"
  pass "three conditions that all refuse produce three refusals an operator can tell apart"
}

# The watcher's ask branch carries the same three conditions plus away mode, and
# it is the sentence firstmate actually reads.
test_the_ask_wake_names_which_condition_it_hit() {
  local out
  make_case
  write_records "$TRANSCRIPT" 900000 "$(captain_record "not-an-instant")"
  out=$(watch_reason)
  assert_contains "$out" "unreadable timestamp" \
    "the ask wake did not say the captain's timestamp could not be read"
  assert_not_contains "$out" "the captain has been active" \
    "the ask wake claimed the captain had been active when nothing established that"

  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  : > "$STATE_DIR/.afk"
  out=$(watch_reason)
  assert_contains "$out" "away mode is active" \
    "the ask wake did not say away mode was what took this branch"
  assert_not_contains "$out" "the captain has been active" \
    "the away-mode ask wake claimed the captain had been active instead"
  assert_class "ask/surfaced" "an ask branch whose cause is away mode rather than a captain who spoke"
  rm -f "$STATE_DIR/.afk"
  pass "the ask wake names the condition it hit rather than always naming the captain"
}

# --- an absent captain record is not evidence of an absent captain ----------

# The read is bounded so one poll can never become an unbounded read, and that
# bound is exactly what can hide a captain prompt behind later tool output. The
# bound is shrunk here instead of generating megabytes of padding: the shape under
# test is "the captain's prompt sits further back than the bound", and that shape
# is the same at 1 KiB as it is at 2 MiB.
TAIL_BYTES=1024

# scan_facts: "<truncated>/<widened>/<last-human-ts-or-none>/<captain-verdict>",
# straight from the shared predicates, so a test can see which read path was taken
# rather than inferring it from a wake payload.
scan_facts() {
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  env -u FM_ROOT_OVERRIDE FM_CONTEXT_TAIL_BYTES="$TAIL_BYTES" bash -c '
      set -u
      . "$1"
      fm_context_scan "$2" || { printf "scan-failed: %s\n" "$FM_CONTEXT_SCAN_ERROR"; exit 0; }
      if fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS"; then v=present; else v=absent; fi
      printf "%s/%s/%s/%s\n" "$FM_CONTEXT_SCAN_TRUNCATED" "$FM_CONTEXT_SCAN_WIDENED" \
        "${FM_CONTEXT_LAST_HUMAN_TS:-none}" "$v"
    ' fm-context-reset-test "$ROOT/bin/fm-context-lib.sh" "$TRANSCRIPT"
}

# The reported hole, reproduced exactly: the captain typed 300s ago - well inside
# FM_CONTEXT_CAPTAIN_IDLE_SECS - and the session then wrote more than one whole
# bounded tail of tool output answering them, so the bounded read alone finds no
# captain record at all. Before the widening, that read as "captain gone" and made
# the reset branch eligible five minutes after the captain spoke.
test_a_captain_beyond_the_bounded_tail_is_still_the_captain() {
  local facts out
  make_case
  export FM_CONTEXT_TAIL_BYTES=$TAIL_BYTES
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 300)" $(( TAIL_BYTES * 3 ))
  write_receipt
  facts=$(scan_facts)
  assert_contains "$facts" "true/true/" \
    "a bounded read that covered only part of the file and found no captain record did not widen"
  assert_contains "$facts" "/present" \
    "a captain prompt sitting beyond the bounded tail did not read as the captain being present"
  out=$(watch_reason FM_CONTEXT_TAIL_BYTES="$TAIL_BYTES")
  assert_contains "$out" "ASK the captain" "the watcher did not take the ask branch for a captain beyond the tail"
  assert_not_contains "$out" "fm-context-reset.sh" "the watcher handed over a reset while the captain was mid-conversation"
  assert_refuses "ask before resetting" "a reset while the captain's prompt sits beyond the bounded tail"
  unset FM_CONTEXT_TAIL_BYTES
  pass "a captain prompt pushed past the bounded tail is found by widening once, and still counts as the captain"
}

# The other half of the same rule: once the WHOLE file has been read and there is
# still no captain record, the answer is not "the captain is gone", it is "this
# transcript cannot say". That fails closed to captain-present.
test_a_complete_read_with_no_captain_record_fails_closed() {
  local facts
  make_case
  write_transcript "$TRANSCRIPT" 900000 ""
  facts=$(scan_facts)
  assert_contains "$facts" "false/false/none/present" \
    "a complete read that found no captain record did not fail closed to captain-present"
  assert_class "ask/surfaced" "a live session whose transcript holds no captain record at all"
  pass "a transcript that cannot say where the captain last spoke fails closed to the captain being present"
}

# The widen-once path was DEAD on any seat that receives wakes, and nobody could
# see it: the bounded tail always held a delivered wake, every wake counted as a
# captain record, so a record was always "found" and the widen never ran. Fixing
# the classification is what makes this load-bearing for the first time, so it is
# exercised on the shape that now reaches it - a truncated transcript whose whole
# tail is operational traffic and whose only captain prompt sits behind the bound.
test_a_captain_behind_a_tail_of_only_operational_records_is_still_the_captain() {
  local facts out operational records=() i
  make_case
  export FM_CONTEXT_TAIL_BYTES=$TAIL_BYTES
  fm_operational_input_encode watcher \
    "Wake delivery: 1 wake record(s) are pending in the durable queue. $(head -c 600 /dev/zero | tr '\0' 'x')" \
    operational \
    || fail "fixture could not compose a watcher operational input"
  records+=("$(captain_record "$(iso_ago 300)")")
  for i in 1 2 3 4 5; do
    records+=("$(typed_operational_record "$operational" "$(iso_now)" "typed-operational-record-000$i")")
  done
  write_records "$TRANSCRIPT" 900000 "${records[@]}"
  write_receipt
  facts=$(scan_facts)
  assert_contains "$facts" "true/true/" \
    "a bounded read whose tail held only operational records did not widen to find the captain"
  assert_contains "$facts" "/present" \
    "a captain prompt behind a tail of operational records did not read as the captain being present"
  out=$(watch_reason FM_CONTEXT_TAIL_BYTES="$TAIL_BYTES")
  assert_contains "$out" "ASK the captain" \
    "the watcher did not take the ask branch for a captain behind a tail of operational records"
  assert_not_contains "$out" "fm-context-reset.sh" \
    "the watcher handed over a reset while the captain was mid-conversation"
  assert_refuses "the captain has been active within the last" \
    "a reset while the captain's prompt sits behind a tail of operational records"
  unset FM_CONTEXT_TAIL_BYTES
  pass "a tail carrying only operational records widens once and still finds the captain behind it"
}

# The receipt's captain check is an EQUALITY, so two unknowns would compare equal
# and pass it while proving nothing at all.
test_receipt_refuses_when_the_captain_timestamp_is_unknown() {
  make_case
  write_transcript "$TRANSCRIPT" 900000 ""
  write_receipt
  assert_grep 'last_human_ts=unknown' "$STATE_DIR/.stow-receipt" \
    "the receipt recorded an unknown captain timestamp as an empty field that would later match"
  assert_refuses "captain's last message could not be established" \
    "a reset whose receipt records an unknown captain timestamp"
  pass "an unknown captain timestamp refuses instead of matching itself"
}

# --- the pane the send path will not resolve --------------------------------

test_a_pane_the_send_path_reserves_refuses() {
  make_case
  export FM_FAKE_TMUX_SESSION='fm-ctx-home:0.0'
  assert_refuses "begins with fm-" "a reset whose own tmux session name is one bin/fm-send.sh reserves"
  unset FM_FAKE_TMUX_SESSION
  pass "a home whose terminal session begins with fm- is refused by name rather than by an opaque send error"
}

test_reset_proceeds_when_everything_verifies
test_check_mode_verifies_without_clearing
test_missing_receipt_refuses
test_stale_receipt_refuses
test_receipt_from_another_session_refuses
test_receipt_bound_to_another_transcript_refuses
test_session_advanced_past_the_receipt_refuses
test_captain_spoke_after_the_receipt_refuses
test_receipt_refuses_off_session
test_receipt_refuses_without_a_transcript_record
test_captain_active_refuses
test_away_mode_refuses
test_captain_approved_completes_where_the_idle_window_makes_it_impossible
test_an_approved_reset_names_the_record_it_treated_as_the_approval
test_the_approved_path_states_what_it_cannot_prove
test_the_receipt_age_window_does_not_apply_on_the_approved_path
test_a_receipt_filed_before_the_approval_refuses
test_growth_past_the_receipt_still_refuses_on_the_approved_path
test_a_captain_message_after_the_approval_still_refuses_when_approved
test_an_approved_path_with_no_captain_record_refuses
test_an_approved_path_with_an_uncitable_captain_record_refuses
test_a_captain_record_without_a_timestamp_keeps_its_id_out_of_the_timestamp
test_a_captain_who_speaks_between_the_checks_and_the_send_refuses
test_the_pre_send_recheck_does_not_reach_the_autonomous_path
test_away_mode_refuses_on_the_approved_path_too
test_the_autonomous_path_is_unchanged_by_the_approved_one
test_queued_wake_refuses
test_worker_waiting_on_an_answer_refuses
test_resolved_decision_does_not_block
test_pending_routed_reply_refuses
test_missing_clear_in_the_restart_matcher_refuses
test_restart_hook_pointing_elsewhere_refuses
test_missing_hook_settings_refuses
test_dead_supervision_refuses
test_down_delivery_with_work_recorded_refuses
test_down_delivery_with_no_work_proceeds
test_foreign_session_record_refuses
test_read_only_session_refuses
test_receipt_refuses_from_a_read_only_session
test_missing_transcript_record_refuses
test_errored_transcript_record_refuses
test_undetected_backend_refuses
test_unverified_harness_refuses
test_watcher_is_silent_under_the_ceiling
test_watcher_asks_when_the_captain_is_active
test_watcher_asks_in_away_mode
test_watcher_hands_over_the_reset_when_the_captain_is_gone
test_watcher_is_silent_while_the_fleet_is_busy
test_watcher_reports_when_it_cannot_measure
test_watcher_reports_a_record_from_a_finished_session
test_watcher_is_silent_with_no_session_running
test_watcher_reports_a_measurement_failure_once_until_it_changes
test_watcher_reports_an_unchanged_ask_once
test_watcher_surfaces_a_changed_branch_immediately
test_watcher_clears_suppression_when_the_condition_resolves
test_watcher_clears_suppression_when_the_session_ends
test_watcher_keeps_suppression_while_its_own_wake_is_undrained
test_a_first_absent_report_carries_only_its_diagnosis
test_an_unchanged_absence_updates_its_record_without_another_wake
test_an_absence_record_failure_repeats_the_wake
test_an_unchanged_ask_gains_no_escalation
test_a_changed_absent_class_restarts_the_clock
test_a_resolved_condition_clears_the_absence_clock
test_watcher_publishes_a_stable_class_per_branch
test_watcher_refuses_to_hand_over_a_reset_with_a_broken_restart_path
test_watcher_process_enqueues_the_ceiling_wake
test_wake_delivery_is_not_mistaken_for_the_captain
test_unattributed_operational_wake_delivery_is_not_mistaken_for_the_captain
test_telegram_correspondent_input_cannot_satisfy_the_approved_path
test_unattributed_unmarked_recent_user_message_still_counts_as_the_captain
test_a_typed_wake_delivery_is_not_mistaken_for_the_captain
test_a_captain_prompt_behind_a_typed_wake_delivery_still_blocks_the_reset
test_every_operational_form_stays_excluded_when_typed
test_each_reason_the_captain_counts_as_present_names_itself
test_a_refusal_names_which_captain_condition_it_hit
test_the_ask_wake_names_which_condition_it_hit
test_a_captain_beyond_the_bounded_tail_is_still_the_captain
test_a_complete_read_with_no_captain_record_fails_closed
test_a_captain_behind_a_tail_of_only_operational_records_is_still_the_captain
test_receipt_refuses_when_the_captain_timestamp_is_unknown
test_a_pane_the_send_path_reserves_refuses
