#!/usr/bin/env bash
# Behavior tests for Claude's narrowly scoped watcher-continuity PreToolUse gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
fm_test_tmproot TMP_ROOT fm-continuity-pretool-tests
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# The gate names recovery commands only for the session that OPERATES the home it
# just judged, which it reads from the checkout the running hook was loaded from.
# So a fixture that means "firstmate's own session" has to run the gate out of the
# fixture home's own bin/, exactly as the turn-end guard's fixtures already do.
# Running the repo's copy against a fixture home is the WORKER shape instead, and
# the worker tests below use precisely that.
install_check_scripts() {
  local dir=$1 file
  mkdir -p "$dir/bin"
  for file in fm-continuity-pretool-check.sh fm-continuity-command-policy.mjs \
    fm-arm-command-policy.mjs fm-supervision-lib.sh fm-primary-scope-lib.sh \
    fm-wake-lib.sh fm-journal-lib.sh; do
    cp "$ROOT/bin/$file" "$dir/bin/$file"
  done
  chmod +x "$dir/bin/fm-continuity-pretool-check.sh"
}

mkdir -p "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
install_check_scripts "$PRIMARY"
PRIMARY_CHECK="$PRIMARY/bin/fm-continuity-pretool-check.sh"
WATCH="$PRIMARY/bin/fm-watch.sh"

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$PRIMARY_CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 command=$2 rc=0
  run_command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 command=$2 blocked=$3 expected=${4:-} rc=0 actual
  run_command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  [ -n "$expected" ] || expected="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, and repair supervision through bin/fm-watcher-service.sh and bin/fm-delivery-service.sh before running other fleet commands (blocked: $blocked)"
  actual=$(jq -r '.systemMessage' "$ERR")
  [ "$actual" = "$expected" ] || fail "$label recovery guidance changed: $actual"
}

test_gate_scope_and_recovery_exceptions() {
  expect_allow "idle fleet command" 'bin/fm-crew-state.sh task'
  printf 'project=fixture\n' > "$STATE/task.meta"

  expect_allow "ordinary shell command" 'git status --short'
  expect_allow "fleet-script text as data" "rg -n 'bin/fm-send.sh' docs"
  expect_allow "wake drain recovery" 'bin/fm-wake-drain.sh'
  expect_allow "delivery repair recovery" 'bin/fm-delivery-service.sh restart'
  expect_allow "drain then delivery repair recovery" 'bin/fm-wake-drain.sh; bin/fm-delivery-service.sh restart'
  expect_allow "fail-closed teardown recovery" 'bin/fm-teardown.sh task'
  unsafe_teardown_reason='[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: fm-teardown.sh)'
  expect_deny "forced teardown is not recovery" 'bin/fm-teardown.sh task --force' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "nested forced teardown is not recovery" "bash -lc 'bin/fm-teardown.sh task --force'" 'fm-teardown.sh' "$unsafe_teardown_reason"
  # shellcheck disable=SC2016  # single quotes are deliberate: "$TEARDOWN_MODE" is literal test data (an unsafe shell-expanded arg the gate must deny), not an expansion here
  expect_deny "dynamic teardown mode is not recovery" 'bin/fm-teardown.sh task "$TEARDOWN_MODE"' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "unrelated fleet command" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  expect_deny "recovery bundled with unrelated fleet command" 'bin/fm-wake-drain.sh; bin/fm-send.sh task hi' 'fm-send.sh'
  expect_deny "literal nested fleet command" "bash -lc 'bin/fm-bootstrap.sh'" 'fm-bootstrap.sh'
  pass "continuity gate allows recovery and ordinary commands but denies only other fleet execution"
}

test_live_lock_allows_fleet_command_even_with_stale_beacon() {
  local holder identity rc=0
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
  touch -t 200001010000 "$STATE/.last-watcher-beat"

  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "identity-matched live lock must allow fleet command even when its beacon is stale"
  [ ! -s "$ERR" ] || fail "live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate classifies the lock by live PID identity rather than beacon age"
}

test_child_worktree_and_malformed_input_fail_open() {
  local child="$TMP_ROOT/child" rc=0
  rm -rf "$STATE/.watch.lock"
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --command 'bin/fm-send.sh task hi' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked child worktree must be out of continuity-gate scope"

  expect_allow "malformed dynamic shell" "bin/fm-send.sh 'unterminated"
  printf '%s' '{not-json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$PRIMARY_CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed Claude transport must fail open"
  pass "continuity gate excludes child worktrees and fails open on opaque input"
}

# --- addressee: firstmate's own session vs a task worker ---------------------
# The tracked hooks ride in EVERY worktree of this repo, so a crewmate or scout
# working on firstmate itself runs this very gate out of its task worktree while
# FM_ROOT_OVERRIDE still names the home that launched it. The gate then judges the
# launching home - correctly, and this test keeps that refusal - but used to hand
# the worker that home's recovery commands. Reproduced live on 2026-08-30 on
# three separate runtimes, each told to "repair supervision through
# bin/fm-watcher-service.sh and bin/fm-delivery-service.sh" while ten tasks were
# in flight in a home none of them could see. AGENTS.md section 1 reserves those
# to firstmate: obeying does damage, refusing leaves the worker stuck.
WORKER_FORBIDDEN_COMMANDS='bin/fm-watcher-service.sh bin/fm-delivery-service.sh bin/fm-wake-drain.sh bin/fm-teardown.sh'

make_worker_worktree() {
  local dir="$TMP_ROOT/worker-wt"
  [ ! -d "$dir" ] || { printf '%s\n' "$dir"; return 0; }
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" diff --cached --quiet || git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b continuity-worker "$dir"
  install_check_scripts "$dir"
  printf '%s\n' "$dir"
}

run_command_as_worker() {
  local command=$1 wt rc=0
  wt=$(make_worker_worktree)
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$wt/bin/fm-continuity-pretool-check.sh" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

test_worker_refusal_names_no_command_reserved_to_firstmate() {
  local rc=0 message command
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"

  run_command_as_worker 'bin/fm-crew-state.sh task' || rc=$?
  [ "$rc" -eq 2 ] || fail "a worker must still be refused: the launching home's supervision is genuinely down"
  message=$(jq -r '.systemMessage' "$ERR")
  for command in $WORKER_FORBIDDEN_COMMANDS; do
    case "$message" in
      *"$command"*) fail "worker refusal handed a task worker $command, which AGENTS.md reserves to firstmate: $message" ;;
    esac
  done
  assert_contains "$message" "repairing that home's supervision belongs to firstmate and not to a task worker" \
    "worker refusal must name firstmate as the one who repairs it"
  assert_contains "$message" "report the stalled supervision in your task status line" \
    "worker refusal must name reporting as the worker's own next action"
  assert_contains "$message" "(blocked: fm-crew-state.sh)" "worker refusal must still name the command it refused"

  # A forced teardown reaches the gate through the other reason code, and its
  # operator wording tells the reader to retry the literal bin/fm-teardown.sh.
  # A worker may not run that one either, so this branch must not leak it.
  run_command_as_worker 'bin/fm-teardown.sh task --force' || rc=$?
  [ "$rc" -eq 2 ] || fail "a worker must still be refused a forced teardown"
  message=$(jq -r '.systemMessage' "$ERR")
  for command in $WORKER_FORBIDDEN_COMMANDS; do
    case "$message" in
      *"$command"*) fail "worker forced-teardown refusal handed a task worker $command: $message" ;;
    esac
  done
  pass "continuity gate refuses a task worker without naming any command AGENTS.md reserves to firstmate"
}

# The other half of the pair: the session that operates this home must keep the
# recovery commands. The fix is an addressee split, not a quietening.
test_operator_refusal_still_names_the_recovery_commands() {
  local rc=0 message
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"
  run_command 'bin/fm-crew-state.sh task' || rc=$?
  [ "$rc" -eq 2 ] || fail "the operator must still be refused when its own supervision is down"
  message=$(jq -r '.systemMessage' "$ERR")
  assert_contains "$message" 'repair supervision through bin/fm-watcher-service.sh and bin/fm-delivery-service.sh' \
    "the session operating this home must still be handed the supervision repair commands"
  assert_contains "$message" 'drain wakes with bin/fm-wake-drain.sh' \
    "the session operating this home must still be handed the drain"
  pass "continuity gate still hands the session operating this home its full recovery instruction"
}

test_claude_hook_registration_preserves_stop_backstop() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
      | any(contains("fm-continuity-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude settings omit the continuity PreToolUse hook"
  jq -e '
    .hooks.Stop == [{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh"}]}]
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude Stop turn-end backstop changed"
  pass "Claude wires the continuity gate while preserving the existing Stop backstop byte-for-byte"
}

test_gate_scope_and_recovery_exceptions
test_live_lock_allows_fleet_command_even_with_stale_beacon
test_child_worktree_and_malformed_input_fail_open
test_worker_refusal_names_no_command_reserved_to_firstmate
test_operator_refusal_still_names_the_recovery_commands
test_claude_hook_registration_preserves_stop_backstop
