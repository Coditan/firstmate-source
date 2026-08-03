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

# write_transcript <path> <tokens> <human-ts-or-empty> [padding-bytes]
# Three record shapes matter and all three appear here: a hook/meta injection, a
# background-task wake delivery, and (optionally) a genuine captain prompt. Only
# the last must ever read as captain activity.
write_transcript() {
  local path=$1 tokens=$2 human=$3 pad=${4:-0}
  {
    printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"session-start nudge"},"timestamp":"2020-01-01T00:00:00.000Z"}\n'
    printf '{"type":"user","origin":{"kind":"task-notification"},"promptSource":"system","message":{"role":"user","content":"wake: queued"},"timestamp":"%s"}\n' "$(iso_now)"
    if [ -n "$human" ]; then
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
case "${1:-}" in
  display-message)
    case "$*" in
      *cursor_y*) printf '5\n' ;;
      *session_name*) printf 'fmtest:0.0\n' ;;
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

# assert_refuses <reason-fragment> <label>
assert_refuses() {
  local fragment=$1 label=$2 out
  run_reset
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
  pass "a verified reset clears through the shared submit path and records that it did"
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
  assert_refuses "is 5" "a reset on a receipt older than its freshness bound"
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
  sed -i.bak 's/^harness_pid=.*/harness_pid=2/' "$STATE_DIR/.primary-transcript"
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

test_unarmed_delivery_with_work_recorded_refuses() {
  make_case
  fm_write_meta "$STATE_DIR/beta.meta" 'window=fmtest:fm-beta' 'harness=claude' 'kind=ship'
  rm -rf "$STATE_DIR/.wake-stub.lock"
  assert_refuses "wake delivery is not armed" "a reset that would strand recorded work with no way to wake"
}

test_unarmed_delivery_with_no_work_proceeds() {
  local out
  make_case
  rm -rf "$STATE_DIR/.wake-stub.lock"
  run_reset --check
  out=$RESET_OUT
  expect_code 0 "$RESET_CODE" "an idle home must not be blocked by an unarmed delivery wait"
  pass "with nothing recorded to wake for, an unarmed delivery wait does not block the reset"
}

# --- identity and harness ---------------------------------------------------

test_foreign_session_record_refuses() {
  make_case
  sed -i.bak 's/^harness_pid=.*/harness_pid=2/' "$STATE_DIR/.primary-transcript"
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
# returns before its lock and loop when sourced), so the throttle and the branch
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

test_watcher_throttles_but_does_not_silence_the_measurement_failure() {
  local first second third
  make_case
  rm -f "$STATE_DIR/.primary-transcript"
  first=$(watch_reason)
  assert_contains "$first" "cannot be measured" "the first measurement failure was not reported"
  second=$(watch_reason)
  [ -z "$second" ] || fail "the measurement failure repeated on the very next poll: $second"
  third=$(watch_reason FM_CONTEXT_ERROR_RESURFACE=0)
  assert_contains "$third" "cannot be measured" "the measurement failure never came back after its quiet period"
  pass "a standing measurement failure reports periodically instead of once or forever"
}

# The ask branch is the one a captain who is present would otherwise hear every
# CONTEXT_CHECK_INTERVAL for as long as they are around, so it is throttled on
# exactly the same terms as the unmeasurable one.
test_watcher_throttles_an_unchanged_ask() {
  local first second third
  make_case
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 60)"
  first=$(watch_reason)
  assert_contains "$first" "ASK the captain" "the first ask was not reported"
  second=$(watch_reason)
  [ -z "$second" ] || fail "an unchanged ask repeated on the very next poll: $second"
  third=$(watch_reason FM_CONTEXT_ERROR_RESURFACE=0)
  assert_contains "$third" "ASK the captain" "the ask never came back after its quiet period"
  pass "a still-true ask is held quiet for its resurface period rather than nagging every poll"
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
    "a changed ceiling branch was suppressed by the previous branch's throttle"
  assert_contains "$second" "fm-context-reset.sh" "the reset branch surfaced without its commands"
  pass "a ceiling branch that changes surfaces on the next poll instead of waiting out the old one"
}

test_watcher_clears_the_throttle_when_the_poll_goes_quiet() {
  local out
  make_case
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" "the reset branch did not report first"
  assert_present "$STATE_DIR/.context-ceiling-surfaced" "a reported ceiling branch left no throttle marker"
  # Back under the ceiling: there is nothing to say, and nothing to keep throttled.
  write_transcript "$TRANSCRIPT" 1000 ""
  out=$(watch_reason)
  [ -z "$out" ] || fail "a session back under the ceiling still reported: $out"
  [ -e "$STATE_DIR/.context-ceiling-surfaced" ] \
    && fail "a silent poll left the ceiling throttle marker in place"
  write_transcript "$TRANSCRIPT" 900000 "$(iso_ago 86400)"
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" \
    "the ceiling report did not return immediately after the throttle was cleared"
  pass "a poll with nothing to say clears the throttle, so the next real condition reports at once"
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
  rm -rf "$STATE_DIR/.watch.lock" "$STATE_DIR/.wake-stub.lock"
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
  # The transcript carries a background-task wake delivery stamped just now and
  # no captain prompt at all. Wake deliveries are what keep an unattended session
  # moving; reading one as captain activity would make the mechanism never fire.
  write_transcript "$TRANSCRIPT" 900000 ""
  out=$(watch_reason)
  assert_contains "$out" "the captain is not present" "a wake delivery was mistaken for captain activity"
  pass "a background wake delivery is not captain activity"
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
test_queued_wake_refuses
test_worker_waiting_on_an_answer_refuses
test_resolved_decision_does_not_block
test_pending_routed_reply_refuses
test_missing_clear_in_the_restart_matcher_refuses
test_restart_hook_pointing_elsewhere_refuses
test_missing_hook_settings_refuses
test_dead_supervision_refuses
test_unarmed_delivery_with_work_recorded_refuses
test_unarmed_delivery_with_no_work_proceeds
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
test_watcher_throttles_but_does_not_silence_the_measurement_failure
test_watcher_throttles_an_unchanged_ask
test_watcher_surfaces_a_changed_branch_immediately
test_watcher_clears_the_throttle_when_the_poll_goes_quiet
test_watcher_refuses_to_hand_over_a_reset_with_a_broken_restart_path
test_watcher_process_enqueues_the_ceiling_wake
test_wake_delivery_is_not_mistaken_for_the_captain
