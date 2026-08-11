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
{"timestamp":"2026-08-04T10:00:01Z","type":"assistant","requestId":"old-activity-1","message":{"usage":{"input_tokens":20},"content":[{"type":"tool_use","id":"inspect","input":{"command":"env -u FM_HOME nice -n 5 nohup stdbuf -o L grep -n fm-wake-drain.sh bin/fm-supervision-cost-engine.py"}}]}}
{"timestamp":"2026-08-04T10:00:02Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"inspect","content":"bin/fm-wake-drain.sh"}]}}
{"timestamp":"2026-08-04T10:00:03Z","type":"assistant","requestId":"old-activity-2","message":{"usage":{"input_tokens":5},"content":[{"type":"tool_use","id":"drain","input":{"command":"cd /tmp && env -u FM_HOME MODE=test nice -n 5 nohup stdbuf -o L timeout -s TERM -k 2 60 bin/fm-wake-drain.sh 2>&1 | head"}}]}}
{"timestamp":"2026-08-04T10:00:04Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"drain","content":""}]}}
EOF
cat > "$project/new.jsonl" <<'EOF'
{"timestamp":"2026-08-04T11:00:00Z","type":"assistant","requestId":"new-start","message":{"usage":{"input_tokens":30},"content":[{"type":"tool_use","id":"session-start","input":{"command":"bin/fm-session-start.sh"}}]}}
{"timestamp":"2026-08-04T11:00:01Z","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"session-start","content":"digest"}]}}
{"timestamp":"2026-08-04T11:00:02Z","type":"assistant","requestId":"new-work","message":{"usage":{"input_tokens":40},"content":[]}}
EOF

report=$(python3 "$ENGINE" --transcripts "$TMP_ROOT" --since 2026-08-04 --until 2026-08-04 --json) \
  || fail "engine rejected the activity-window fixture"
python3 - "$report" <<'PY' || fail "activity window or executable classification was wrong"
import json, sys
report = json.loads(sys.argv[1])
day = report["days"][0]
assert report["sessions"] == 2
assert day["session_starts"] == 1
assert day["fresh_tokens"] == 95
assert day["session_start_fresh"]["total"] == 30
assert day["startup_block_fresh"]["total"] == 30
assert day["drain_calls"] == 1
assert day["drain_calls_empty"] == 1
assert day["empty_deliveries"] == 1
assert "request timestamp" in report["window_semantics"]
PY
pass "date bounds measure activity while executable classification ignores mentions"

python3 - "$ENGINE" <<'PY' || fail "classifier outcomes were wrong"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
script = "fm-wake-drain.sh"
cases = [
    ("bin/fm-wake-drain.sh", engine.EXECUTES),
    ("env -u FM_HOME MODE=x nice -n 5 nohup stdbuf -o L timeout -s TERM -k 2 60 bin/fm-wake-drain.sh", engine.EXECUTES),
    ("bash bin/fm-wake-drain.sh", engine.EXECUTES),
    ("bash -n bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE),
    ("bash --norc -n bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE),
    ("sh -n bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE),
    ("shellcheck bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE),
    ("python -m py_compile bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE),
    *[(f"{tool} bin/fm-wake-drain.sh", engine.DOES_NOT_EXECUTE) for tool in
      ("grep", "sed", "awk", "cat", "head", "tail", "wc", "diff", "cmp", "less", "more", "ls", "stat", "cp", "mv", "rm", "chmod", "test", "[", "git add", "git diff", "git show", "git log")],
    ("command -v bin/fm-wake-drain.sh", engine.UNKNOWN),
    ("env -S 'bin/fm-wake-drain.sh'", engine.UNKNOWN),
]
for command, expected in cases:
    actual = engine.classify_script(command, script)
    assert actual == expected, (command, expected, actual)
PY
pass "classifier distinguishes executions, data references, and unknown forms"
