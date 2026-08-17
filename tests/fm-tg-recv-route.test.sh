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

test_a_captain_message_keeps_the_legacy_output_and_inbox() {
  local home="$TMP_ROOT/captain" event="$TMP_ROOT/captain.json" out status=0
  new_home "$home"
  event_json "$event" 1001 41 TEXT 'approve the safe path'

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a captain Telegram event"
  assert_contains "$out" "CAPTAIN-TELEGRAM: approve the safe path" \
    "the captain text output changed"
  assert_not_contains "$out" "telegram-correspondent" \
    "a captain event was tagged as a correspondent event"
  assert_grep '"audience":"captain"' "$home/state/tg-recv.inbox.jsonl" \
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
  assert_grep '"audience":"third-party"' "$inbox" \
    "the correspondent inbox did not tag the audience"
  assert_grep '"lane":"requirements"' "$inbox" \
    "the correspondent inbox did not name the lane"
  assert_grep 'ja, bitte mit Umsatzsteuer' "$inbox" \
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

test_a_correspondent_media_event_uses_the_same_inbox_boundary() {
  local home="$TMP_ROOT/media" event="$TMP_ROOT/media.json" out status=0 inbox
  new_home "$home"
  register_correspondent "$home" requirements 2002
  event_json "$event" 2002 44 DOC 'Anforderungsskizze' "$home/state/tg-recv-media/brief.pdf"

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a registered correspondent media event"
  assert_contains "$out" "telegram-correspondent" \
    "the correspondent media event was not operationally tagged"
  inbox="$home/state/tg-correspondents/requirements/inbox.jsonl"
  assert_grep '"kind":"DOC"' "$inbox" \
    "the correspondent media kind did not land in the lane inbox"
  assert_grep "$home/state/tg-recv-media/brief.pdf" "$inbox" \
    "the correspondent media path did not land in the lane inbox"
  pass "a registered correspondent media event lands in the same third-party inbox"
}

test_a_captain_media_event_keeps_the_legacy_media_prefix() {
  local home="$TMP_ROOT/captain-media" event="$TMP_ROOT/captain-media.json" out status=0
  new_home "$home"
  event_json "$event" 1001 45 PHOTO 'caption text' "$home/state/tg-recv-media/photo.jpg"

  out=$(run_route "$home" "$event") || status=$?
  expect_code 10 "$status" "a captain media Telegram event"
  assert_contains "$out" "CAPTAIN-TELEGRAM-BILD: $home/state/tg-recv-media/photo.jpg | caption: caption text" \
    "the captain media output changed"
  pass "a captain media event keeps the legacy captain media prefix"
}

test_a_captain_message_keeps_the_legacy_output_and_inbox
test_a_registered_correspondent_message_is_tagged_and_spooled
test_an_unknown_sender_is_still_silently_dropped
test_a_correspondent_media_event_uses_the_same_inbox_boundary
test_a_captain_media_event_keeps_the_legacy_media_prefix

echo "# all fm-tg-recv-route tests passed"
