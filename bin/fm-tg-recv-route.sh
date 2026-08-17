#!/usr/bin/env bash
# fm-tg-recv-route.sh - route one normalized Telegram receiver event.
#
# This is the tracked authority boundary for direct Telegram receive after the
# private receiver has already fetched Telegram updates and downloaded any media.
# The local receiver still owns the bot credential, Telegram polling, offset
# mechanics, and media download.
# This script owns only audience classification, local inbox placement, and the
# exact output shape handed back to the tracked arm wrapper.
#
# Input on stdin is one JSON object:
#   {
#     "chat_id": "1234",
#     "update_id": 42,
#     "kind": "TEXT|PHOTO|DOC",
#     "text": "message or caption",
#     "media_path": "/local/path/for/media",
#     "timestamp": 1700000000
#   }
#
# Environment:
#   CHAT_ID              captain Telegram chat id, already sourced by the local
#                        receiver from config/telegram.env
#   FM_HOME              home whose config and state are used
#   FM_CONFIG_OVERRIDE   relocate the config directory
#   FM_STATE_OVERRIDE    relocate the state directory
#   INBOX                optional captain inbox path compatibility override
#
# Output and exit:
#   captain event        prints the legacy CAPTAIN-TELEGRAM line and exits 10
#   correspondent event  records it under state/tg-correspondents/<name>/,
#                        prints a FIRSTMATE_OP telegram-correspondent line, and
#                        exits 10
#   unknown event        prints nothing and exits 0
#
# Exit 10 mirrors the private receiver's existing "hit" convention so a local
# receiver can adopt this router without changing its outer polling loop.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-tg-correspondent-lib.sh
. "$SCRIPT_DIR/fm-tg-correspondent-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-tg-recv-route.sh < normalized-event.json

Routes one already-fetched Telegram event from the private receiver.
The captain lane keeps the legacy CAPTAIN-TELEGRAM output.
A registered correspondent lane writes state/tg-correspondents/<name>/inbox.jsonl
and emits a typed FIRSTMATE_OP telegram-correspondent wake.
Unknown senders are silently dropped.
EOF
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

diag() {
  printf 'telegram receiver route: %s\n' "$*" >&2
}

die() {
  diag "FAILED - $*"
  exit 1
}

[ -n "${CHAT_ID:-}" ] || die 'CHAT_ID is not set, so the captain lane cannot be identified'

event_file=$(mktemp "${TMPDIR:-/tmp}/fm-tg-recv-route.XXXXXX") \
  || die 'could not create event staging file'
trap 'rm -f "$event_file"' EXIT
cat > "$event_file" || die 'could not read the normalized receiver event'
[ -s "$event_file" ] || die 'normalized receiver event is empty'

json_field() {  # <field>
  python3 - "$event_file" "$1" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)

value = data.get(field, "")
if value is None or isinstance(value, (dict, list)):
    sys.exit(1)
if field in {"chat_id", "kind"} and str(value) == "":
    sys.exit(1)
sys.stdout.write(str(value))
PY
}

append_event_json() {  # <inbox-path> <audience> <lane-name>
  local inbox=$1 audience=$2 lane=${3:-}
  mkdir -p "$(dirname "$inbox")" || die "could not create inbox directory for $audience"
  FM_TG_ROUTE_INBOX="$inbox" \
  FM_TG_ROUTE_AUDIENCE="$audience" \
  FM_TG_ROUTE_LANE="$lane" \
    python3 - "$event_file" <<'PY'
import json
import os
import sys

event_path = sys.argv[1]
inbox = os.environ["FM_TG_ROUTE_INBOX"]
audience = os.environ["FM_TG_ROUTE_AUDIENCE"]
lane = os.environ.get("FM_TG_ROUTE_LANE") or None

with open(event_path, "r", encoding="utf-8") as handle:
    event = json.load(handle)

record = {
    "source": "telegram",
    "audience": audience,
    "lane": lane,
    "update_id": event.get("update_id"),
    "kind": event.get("kind"),
    "text": event.get("text") or "",
    "media_path": event.get("media_path") or "",
    "ts": event.get("timestamp") or event.get("ts"),
}
with open(inbox, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

print_captain_line() {
  python3 - "$event_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    event = json.load(handle)

kind = str(event.get("kind") or "")
text = str(event.get("text") or "")
media_path = str(event.get("media_path") or "")
if kind == "TEXT":
    sys.stdout.write(f"CAPTAIN-TELEGRAM: {text}\n")
elif kind in {"PHOTO", "DOC"}:
    if not media_path:
        media_path = "<download-fehlgeschlagen>"
    sys.stdout.write(f"CAPTAIN-TELEGRAM-BILD: {media_path} | caption: {text}\n")
else:
    sys.exit(1)
PY
}

chat_id=$(json_field chat_id) || die 'normalized receiver event has no readable chat_id'
kind=$(json_field kind) || die 'normalized receiver event has no readable kind'
case "$kind" in
  TEXT|PHOTO|DOC) ;;
  *) die 'normalized receiver event kind must be TEXT, PHOTO, or DOC' ;;
esac

if [ "$chat_id" = "$CHAT_ID" ]; then
  captain_inbox=${INBOX:-$STATE/tg-recv.inbox.jsonl}
  append_event_json "$captain_inbox" captain ''
  print_captain_line || die 'could not format the captain Telegram event'
  exit 10
fi

correspondent_loaded=0
if fm_tg_correspondent_load "$CONFIG"; then
  correspondent_loaded=1
else
  load_rc=$?
  if [ "$load_rc" -ne 1 ]; then
    die "$FM_TG_CORRESPONDENT_CONFIG_ERROR"
  fi
fi

if [ "$correspondent_loaded" -eq 1 ] \
  && [ "$chat_id" = "$FM_TG_CORRESPONDENT_CHAT_ID" ]; then
  inbox=$(fm_tg_correspondent_inbox_path "$STATE" "$FM_TG_CORRESPONDENT_NAME")
  append_event_json "$inbox" third-party "$FM_TG_CORRESPONDENT_NAME"
  body="third-party Telegram message from $FM_TG_CORRESPONDENT_NAME recorded at $inbox; this correspondent has no captain decision authority"
  fm_operational_input_encode telegram-correspondent "$body" output \
    || die 'could not encode the correspondent Telegram event'
  printf '%s\n' "$output"
  exit 10
fi

exit 0
