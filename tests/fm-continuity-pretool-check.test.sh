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
    fm-wake-lib.sh fm-journal-lib.sh fm-harness-pid-lib.sh; do
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
  # A worker's own status line is never a fleet mutation, and the refusal itself
  # tells the worker to report through it, so it must be classified as recovery.
  expect_allow "own status line recovery" 'bin/fm-status.sh state/task.status working hi'
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
# The worker message states only the worker's own duty. It deliberately does not
# claim the gate forbids every fleet command against that home, because the
# recovery allowlist in bin/fm-continuity-command-policy.mjs does not.
WORKER_REPORT_TAIL='report the stalled supervision in your task status line and carry on with your own task in this worktree'
# The ordinary literal bin/fm-teardown.sh and bin/fm-wake-drain.sh stay allowed
# for every addressee, so only the two supervision-repair services are reserved.
# An unsafe-teardown refusal must therefore still name the literal retry.
WORKER_RESERVED_COMMANDS='bin/fm-watcher-service.sh bin/fm-delivery-service.sh'

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
  assert_contains "$message" "$WORKER_REPORT_TAIL" \
    "worker refusal must name reporting as the worker's own next action, and claim nothing the gate does not enforce"
  assert_contains "$message" "(blocked: fm-crew-state.sh)" "worker refusal must still name the command it refused"

  pass "continuity gate refuses a task worker without naming any command AGENTS.md reserves to firstmate"
}

# A forced teardown is refused for a different reason: not that supervision
# repair belongs to firstmate, but that only the ordinary literal invocation is
# allowed during recovery. That remedy is true for every addressee, so a worker
# must get it rather than a diagnosis that does not match why it was blocked.
test_worker_forced_teardown_gets_the_literal_retry_remedy() {
  local rc=0 message command
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"

  run_command_as_worker 'bin/fm-teardown.sh task --force' || rc=$?
  [ "$rc" -eq 2 ] || fail "a worker must still be refused a forced teardown"
  message=$(jq -r '.systemMessage' "$ERR")
  assert_contains "$message" 'in the home that launched this task' \
    "a worker must be told which home the refusal is about, not that it is its own"
  assert_contains "$message" 'only the ordinary literal bin/fm-teardown.sh is allowed' \
    "a worker refused a forced teardown must be told which invocation is allowed"
  assert_contains "$message" 'drop --force and any shell-expanded arguments and retry the literal invocation' \
    "a worker refused a forced teardown must get the actionable remedy, not the supervision-repair wording"
  assert_not_contains "$message" "$WORKER_REPORT_TAIL" \
    "a forced teardown is not a supervision-repair refusal, so it must not carry that diagnosis"
  assert_contains "$message" '(blocked: fm-teardown.sh)' "worker refusal must still name the command it refused"
  for command in $WORKER_RESERVED_COMMANDS; do
    case "$message" in
      *"$command"*) fail "worker forced-teardown refusal handed a task worker $command: $message" ;;
    esac
  done
  pass "continuity gate hands a task worker the literal-teardown remedy rather than a supervision-repair diagnosis"
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

# The lock records the ABSOLUTE path of the watcher that took it, which is the
# watcher of the CHECKOUT it was launched from, and the identity check compares
# that path as a string. A worker in a task worktree runs a byte-identical copy
# of this hook at a DIFFERENT path, so resolving the compared watcher from the
# hook's own SCRIPT_DIR compared the worktree's copy and could never match the
# record: every worker saw a permanent refusal no repair could clear. The gate
# resolves it from FM_ROOT instead, the checkout-derived root the recorded path
# resolves to, so a worker whose FM_ROOT_OVERRIDE names the launching home
# compares the right file.
test_worker_sees_the_homes_live_watcher_through_its_own_copy_of_the_gate() {
  local holder identity rc=0
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"

  run_command_as_worker 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a worker running its own copy of the gate must see the home's live watcher, got exit $rc: $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "worker live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate compares the watcher of the checkout FM_ROOT names, so a worker in a task worktree is not falsely refused"
}

# The pid half of the check is untouched, so the case the check exists for - a
# dead process still holding the home lock, reproduced 2026-08-30 - still refuses
# from a worker's copy as well.
test_dead_pid_holding_the_home_lock_still_refuses_a_worker() {
  local holder identity rc=0
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify continuity fixture before killing it"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"

  run_command_as_worker 'bin/fm-crew-state.sh task' || rc=$?
  rm -rf "$STATE/.watch.lock"
  [ "$rc" -eq 2 ] || fail "a dead pid holding the home lock must still refuse, got exit $rc"
  pass "continuity gate still refuses when a dead process holds the home lock"
}

# The channel the refusal names must itself be usable, from either addressee.
test_status_writer_is_classified_recovery() {
  local classification
  # Any executed bin/fm-*.sh that is NOT in the recovery set prints a deny line,
  # so silence here is the proof that the status writer is in that set.
  classification=$(node "$ROOT/bin/fm-continuity-command-policy.mjs" \
    --command 'bin/fm-status.sh state/task.status working hi' --root "$ROOT") \
    || fail "policy could not classify the status writer"
  [ -z "$classification" ] || fail "the status writer must classify as recovery, got: $classification"
  classification=$(node "$ROOT/bin/fm-continuity-command-policy.mjs" \
    --command 'bin/fm-crew-state.sh task' --root "$ROOT") \
    || fail "policy could not classify the contrast command"
  case "$classification" in
    deny*fm-crew-state.sh*) ;;
    *) fail "contrast command must still deny, so silence above means recovery: $classification" ;;
  esac
  pass "the command policy classifies the status writer as a recovery command"
}

# The status writer must stay reachable for a worker whatever the launching
# home's DELIVERY listener is doing, and the delivery predicate must stay out of
# this gate entirely. On 2026-09-06 task
# fleet-process-inventory-review-seat-keeper-presence-giveup finished green and
# could not write its completion line, because this gate was refusing the very
# channel its own refusal told the worker to report through; firstmate read the
# finished work off the pane three days later. This case pins the outcome rather
# than the line: with the launching home's supervision down AND no live listener
# for it, a worker's own status line is still allowed while an ordinary fleet
# command is still refused.
test_worker_status_line_survives_a_dead_home_listener() {
  local rc=0 dead
  rm -rf "$STATE/.watch.lock"
  printf 'project=fixture\n' > "$STATE/task.meta"
  ( exit 0 ) & dead=$!
  wait "$dead" 2>/dev/null || true
  mkdir -p "$STATE/.delivery.lock"
  printf '%s\n' "$dead" > "$STATE/.delivery.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.delivery.lock/fm-home"
  printf '%s\n' "$PRIMARY/bin/fm-delivery.sh" > "$STATE/.delivery.lock/delivery-path"
  printf '%s\n' "dead listener identity" > "$STATE/.delivery.lock/pid-identity"
  rm -f "$STATE/.last-delivery-beat"

  run_command_as_worker "bin/fm-status.sh state/task.status done 'PR green'" || rc=$?
  [ "$rc" -eq 0 ] || fail "a worker's own status line must survive a dead listener in the launching home, got exit $rc: $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "the status writer was gated on supervision health: $(cat "$ERR")"

  rc=0
  run_command_as_worker 'bin/fm-crew-state.sh task' || rc=$?
  [ "$rc" -eq 2 ] || fail "the contrast command must still be refused, so the allow above is the recovery classification and not a fail-open"
  rm -rf "$STATE/.delivery.lock"
  pass "continuity gate lets a worker report while the launching home has neither a watcher nor a listener"
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
test_worker_forced_teardown_gets_the_literal_retry_remedy
test_operator_refusal_still_names_the_recovery_commands
test_worker_sees_the_homes_live_watcher_through_its_own_copy_of_the_gate
test_dead_pid_holding_the_home_lock_still_refuses_a_worker
test_status_writer_is_classified_recovery
test_worker_status_line_survives_a_dead_home_listener
test_claude_hook_registration_preserves_stop_backstop
