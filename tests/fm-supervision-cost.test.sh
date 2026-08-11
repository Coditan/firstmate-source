#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/bin/fm-supervision-cost-engine.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervision-cost.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "not ok - $*"; exit 1; }
pass() { echo "ok - $*"; }

project="$TMP_ROOT/project"
mkdir -p "$project"
cat > "$project/old.jsonl" <<'EOF'
{"timestamp":"2026-08-03T10:00:00Z","type":"assistant","requestId":"old-start","message":{"usage":{"input_tokens":10},"content":[]}}
{"timestamp":"2026-08-04T10:00:00Z","type":"user","message":{"content":"<task-notification>real wake</task-notification>"}}
{"timestamp":"2026-08-04T10:00:01Z","type":"assistant","requestId":"old-activity-1","message":{"usage":{"input_tokens":20},"content":[{"type":"tool_use","id":"inspect","input":{"command":"grep -n fm-wake-drain.sh bin/fm-supervision-cost-engine.py"}}]}}
{"timestamp":"2026-08-04T10:00:02Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"inspect","content":"bin/fm-wake-drain.sh"}]}}
{"timestamp":"2026-08-04T10:00:03Z","type":"assistant","requestId":"old-activity-2","message":{"usage":{"input_tokens":5},"content":[{"type":"tool_use","id":"drain","input":{"command":"cd /tmp && timeout 60 bin/fm-wake-drain.sh 2>&1 | head"}}]}}
{"timestamp":"2026-08-04T10:00:04Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"drain","content":""}]}}
EOF
cat > "$project/new.jsonl" <<'EOF'
{"timestamp":"2026-08-04T11:00:00Z","type":"assistant","requestId":"new-start","message":{"usage":{"input_tokens":30},"content":[{"type":"tool_use","id":"inspect-start","input":{"command":"sed -n 1,20p bin/fm-session-start.sh"}}]}}
{"timestamp":"2026-08-04T11:00:01Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"inspect-start","content":"text"}]}}
EOF

report=$(python3 "$ENGINE" --transcripts "$TMP_ROOT" --since 2026-08-04 --until 2026-08-04 --json) \
  || fail "engine rejected the activity-window fixture"
python3 - "$report" <<'PY' || fail "activity window or executable classification was wrong"
import json, sys
report = json.loads(sys.argv[1])
day = report["days"][0]
assert report["sessions"] == 2
assert day["session_starts"] == 1
assert day["fresh_tokens"] == 55
assert day["session_start_fresh"]["total"] == 30
assert day["drain_calls"] == 1
assert day["drain_calls_empty"] == 1
assert day["empty_deliveries"] == 1
assert "request timestamp" in report["window_semantics"]
PY
pass "date bounds measure activity while executable classification ignores mentions"
