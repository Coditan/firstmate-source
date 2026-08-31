#!/usr/bin/env bash
# tests/fm-tg-recv-route.test.sh - direct Telegram receive audience routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-tg-recv-route.sh"
fm_test_tmproot TMP_ROOT fm-tg-recv-route-tests

new_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state" || fail "could not create fixture home"
}

register_correspondent() {
  local home=$1 name=$2 chat_id=$3
  {
    printf 'name=%s\n' "$name"
    printf 'chat_id=%s\n' "$chat_id"
  } > "$home/config/fm-tg-correspondent"
}

event_json() {  # <path> <chat-id> <update-id> <kind> <text> [media-path]
  local path=$1 chat_id=$2 update_id=$3 kind=$4 text=$5 media_path=${6:-}
  jq -cn \
    --arg chat_id "$chat_id" \
    --arg update_id "$update_id" \
    --arg kind "$kind" \
    --arg text "$text" \
    --arg media_path "$media_path" \
    '{chat_id:$chat_id, update_id:($update_id | tonumber), kind:$kind, text:$text, media_path:$media_path, timestamp:1700000000}' \
    > "$path"
}

run_route() {  # <home> <event-path>
  local home=$1 event=$2
  CHAT_ID=1001 FM_HOME="$home" "$ROUTE" < "$event" 2>&1
}

decode_frame() {
  python3 - "${1#FM_TG_EVENT_V1:}" <<'PY'
import base64
import sys

sys.stdout.buffer.write(base64.b64decode(sys.argv[1], validate=True))
PY
}

assert_inbox_record() {  # <jsonl-path> <jq-filter> <failure-message>
  local inbox=$1 filter=$2 message=$3
  [ -f "$inbox" ] || fail "$message: inbox missing at $inbox"
  jq -e "$filter" "$inbox" >/dev/null \
    || fail "$message: $(cat "$inbox")"
}

test_a_captain_message_keeps_the_legacy_output_and_inbox() {
  local home="$TMP_ROOT/captain" event="$TMP_ROOT/captain.json" out status=0
  new_home "$home"
  event_json "$event" 1001 41 TEXT 'approve the safe path'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a captain Telegram event"
  out=$(decode_frame "$out") || fail "the captain event frame was invalid"
  assert_contains "$out" "CAPTAIN-TELEGRAM: approve the safe path" \
    "the captain text output changed"
  assert_not_contains "$out" "telegram-correspondent" \
    "a captain event was tagged as a correspondent event"
  assert_inbox_record "$home/state/tg-recv.inbox.jsonl" \
    '.audience == "captain" and .lane == null and .kind == "TEXT" and .text == "approve the safe path"' \
    "the captain event was not recorded in the legacy inbox"
  pass "a captain Telegram message keeps the legacy full-standing path"
}

test_a_registered_correspondent_message_is_tagged_and_spooled() {
  local home="$TMP_ROOT/correspondent" event="$TMP_ROOT/correspondent.json" out status=0 inbox
  new_home "$home"
  register_correspondent "$home" requirements 2002
  event_json "$event" 2002 42 TEXT 'ja, bitte mit Umsatzsteuer'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a registered correspondent Telegram event"
  out=$(decode_frame "$out") || fail "the correspondent event frame was invalid"
  assert_contains "$out" "FIRSTMATE_OP: v1 telegram-correspondent:" \
    "the correspondent event was not emitted as typed operational input"
  assert_contains "$out" "third-party Telegram message from requirements" \
    "the correspondent output did not identify the third-party lane"
  assert_contains "$out" "no captain decision authority" \
    "the correspondent output did not carry the authority boundary"
  assert_not_contains "$out" "CAPTAIN-TELEGRAM" \
    "a correspondent event used the captain Telegram prefix"
  assert_not_contains "$out" "Umsatzsteuer" \
    "the correspondent's message body leaked into the operational prompt instead of the inbox"
  inbox="$home/state/tg-correspondents/requirements/inbox.jsonl"
  assert_inbox_record "$inbox" \
    '.audience == "third-party" and .lane == "requirements" and .kind == "TEXT" and .text == "ja, bitte mit Umsatzsteuer"' \
    "the correspondent message body did not land in the lane inbox"
  pass "a registered correspondent message is operationally tagged and lands in its own inbox"
}

test_an_unknown_sender_is_still_silently_dropped() {
  local home="$TMP_ROOT/unknown" event="$TMP_ROOT/unknown.json" out status=0
  new_home "$home"
  register_correspondent "$home" requirements 2002
  event_json "$event" 3003 43 TEXT 'unknown sender'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 0 "$status" "an unknown Telegram event"
  [ -z "$out" ] || fail "an unknown sender produced output: $out"
  [ ! -e "$home/state/tg-recv.inbox.jsonl" ] \
    || fail "an unknown sender wrote the captain inbox"
  [ ! -e "$home/state/tg-correspondents/requirements/inbox.jsonl" ] \
    || fail "an unknown sender wrote the correspondent inbox"
  pass "an unregistered Telegram sender remains silently dropped"
}

test_an_unknown_sender_stays_silent_when_correspondent_config_is_malformed() {
  local home="$TMP_ROOT/unknown-malformed" event="$TMP_ROOT/unknown-malformed.json" out status=0
  new_home "$home"
  {
    printf '%s\n' 'name=bad name'
    printf '%s\n' 'chat_id=2002'
  } > "$home/config/fm-tg-correspondent"
  event_json "$event" 3003 46 TEXT 'unknown sender'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 0 "$status" "an unknown Telegram event with malformed correspondent config"
  [ -z "$out" ] || fail "an unknown sender saw correspondent config diagnostics: $out"
  [ ! -e "$home/state/tg-recv.inbox.jsonl" ] \
    || fail "an unknown sender wrote the captain inbox"
  [ ! -e "$home/state/tg-correspondents" ] \
    || fail "an unknown sender wrote a correspondent inbox"
  pass "an unknown sender stays silent when correspondent config is malformed"
}

test_a_registered_correspondent_gets_a_visible_diagnostic_when_config_is_malformed() {
  local home="$TMP_ROOT/correspondent-malformed" event="$TMP_ROOT/correspondent-malformed.json" out status=0
  new_home "$home"
  {
    printf '%s\n' 'name=bad name'
    printf '%s\n' 'chat_id=2002'
  } > "$home/config/fm-tg-correspondent"
  event_json "$event" 2002 47 TEXT 'requirements note'

  out=$(run_route "$home" "$event") || status=$?
  [ "$status" -ne 0 ] || fail "a registered correspondent with malformed config was silently dropped"
  assert_contains "$out" "telegram receiver route: FAILED - config/fm-tg-correspondent has an invalid name" \
    "the registered correspondent lane did not produce a visible malformed-config diagnostic"
  [ ! -e "$home/state/tg-correspondents" ] \
    || fail "a malformed correspondent config wrote a correspondent inbox"
  pass "a registered correspondent gets a visible malformed-config diagnostic"
}

test_a_correspondent_media_event_uses_the_same_inbox_boundary() {
  local home="$TMP_ROOT/media" event="$TMP_ROOT/media.json" out status=0 inbox
  new_home "$home"
  register_correspondent "$home" requirements 2002
  event_json "$event" 2002 44 DOC 'Anforderungsskizze' "$home/state/tg-recv-media/brief.pdf"

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a registered correspondent media event"
  out=$(decode_frame "$out") || fail "the correspondent media event frame was invalid"
  assert_contains "$out" "telegram-correspondent" \
    "the correspondent media event was not operationally tagged"
  inbox="$home/state/tg-correspondents/requirements/inbox.jsonl"
  assert_inbox_record "$inbox" \
    ".audience == \"third-party\" and .lane == \"requirements\" and .kind == \"DOC\" and .media_path == \"$home/state/tg-recv-media/brief.pdf\"" \
    "the correspondent media event did not land in the lane inbox"
  pass "a registered correspondent media event lands in the same third-party inbox"
}

test_a_captain_media_event_keeps_the_legacy_media_prefix() {
  local home="$TMP_ROOT/captain-media" event="$TMP_ROOT/captain-media.json" out status=0
  new_home "$home"
  event_json "$event" 1001 45 PHOTO 'caption text' "$home/state/tg-recv-media/photo.jpg"

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a captain media Telegram event"
  out=$(decode_frame "$out") || fail "the captain media event frame was invalid"
  assert_contains "$out" "CAPTAIN-TELEGRAM-BILD: $home/state/tg-recv-media/photo.jpg | caption: caption text" \
    "the captain media output changed"
  pass "a captain media event keeps the legacy captain media prefix"
}

test_a_multiline_captain_message_is_one_complete_event() {
  local home="$TMP_ROOT/captain-multiline" event="$TMP_ROOT/captain-multiline.json" out status=0 expected
  new_home "$home"
  expected=$'CAPTAIN-TELEGRAM: first line\nsecond line\nthird line'
  event_json "$event" 1001 46 TEXT $'first line\nsecond line\nthird line'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a multiline captain Telegram event"
  out=$(decode_frame "$out") || fail "the multiline captain event frame was invalid"
  [ "$out" = "$expected" ] || fail "the multiline captain event changed: $out"
  pass "a multiline captain message remains one complete framed event"
}

test_a_captain_message_keeps_the_legacy_output_and_inbox
test_a_registered_correspondent_message_is_tagged_and_spooled
test_an_unknown_sender_is_still_silently_dropped
test_an_unknown_sender_stays_silent_when_correspondent_config_is_malformed
test_a_registered_correspondent_gets_a_visible_diagnostic_when_config_is_malformed
test_a_correspondent_media_event_uses_the_same_inbox_boundary
test_a_captain_media_event_keeps_the_legacy_media_prefix
test_a_multiline_captain_message_is_one_complete_event

echo "# all fm-tg-recv-route tests passed"
