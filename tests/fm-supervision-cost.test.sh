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

arms="$TMP_ROOT/arms"
mkdir -p "$arms"
cat > "$arms/session.jsonl" <<'EOF'
{"timestamp":"2026-08-04T12:00:00Z","type":"assistant","requestId":"arm-alone","message":{"usage":{"input_tokens":50},"content":[{"type":"tool_use","id":"arm-1","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
{"timestamp":"2026-08-04T12:00:01Z","type":"assistant","requestId":"arm-alone","message":{"usage":{"input_tokens":50},"content":[{"type":"tool_use","id":"arm-1-retry","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
{"timestamp":"2026-08-04T12:00:02Z","type":"assistant","requestId":"arm-paired","message":{"usage":{"input_tokens":60},"content":[{"type":"tool_use","id":"drain-1","input":{"command":"bin/fm-wake-drain.sh"}},{"type":"tool_use","id":"arm-2","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
{"timestamp":"2026-08-04T12:00:03Z","type":"assistant","requestId":"arm-paired","message":{"usage":{"input_tokens":60},"content":[{"type":"tool_use","id":"drain-1-retry","input":{"command":"bin/fm-wake-drain.sh"}},{"type":"tool_use","id":"arm-2-retry","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
{"timestamp":"2026-08-04T12:00:04Z","type":"assistant","requestId":"arms-alone","message":{"usage":{"input_tokens":70},"content":[{"type":"tool_use","id":"arm-3","input":{"command":"bin/fm-watch-arm.sh --hold"}},{"type":"tool_use","id":"arm-4","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
{"timestamp":"2026-08-04T12:00:05Z","type":"assistant","requestId":"arms-paired","message":{"usage":{"input_tokens":80},"content":[{"type":"tool_use","id":"drain-2","input":{"command":"bin/fm-wake-drain.sh"}},{"type":"tool_use","id":"arm-5","input":{"command":"bin/fm-watch-arm.sh --hold"}},{"type":"tool_use","id":"arm-6","input":{"command":"bin/fm-watch-arm.sh --hold"}}]}}
EOF

report=$(python3 "$ENGINE" --transcripts "$arms" --since 2026-08-04 --until 2026-08-04 --json) \
  || fail "engine rejected the duplicate-request fixture"
python3 - "$report" <<'PY' || fail "delivery-arm measurements were not deduplicated by request id"
import json, sys
day = json.loads(sys.argv[1])["days"][0]
assert day["arm_calls"] == 6
assert day["arm_calls_paired_with_drain"] == 3
assert day["unpaired_arm_requests"] == 2
assert day["unpaired_arm_fresh"] == 120
PY
pass "delivery-arm measurements count duplicated request records once"

output=$(python3 "$ENGINE" --transcripts "$arms" --since 2026-08-04 --until 2026-08-04) \
  || fail "engine could not print the multi-arm report"
[[ "$output" == *"delivery arm calls: 6"* ]] \
  || fail "printed total did not identify its unit as arm calls"
[[ "$output" == *"arm calls issued beside the drain: 3"* ]] \
  || fail "printed paired count did not identify its unit as arm calls"
[[ "$output" == *"requests containing only arm calls: 2"* ]] \
  || fail "printed own-arm count did not identify its unit as requests"
pass "delivery-arm report distinguishes arm-call and request units"

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
