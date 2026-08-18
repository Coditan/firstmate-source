#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-sessionstart-nudge

NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

# make_fake_ps_holder <fakebin> <holder-pid>: report the given pid as a live
# `claude` harness and every other pid as a plain shell whose parent is that
# holder, so the shared ancestry walk in bin/fm-harness-pid-lib.sh resolves to
# exactly one known pid the test can assert on.
make_fake_ps_holder() {
  local fakebin=$1 holder_pid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    if [ "\$pid" = "$holder_pid" ]; then printf '/usr/local/bin/claude\n'; else printf '/bin/bash\n'; fi
    exit 0 ;;
  *"args="*)
    if [ "\$pid" = "$holder_pid" ]; then printf 'claude\n'; else printf 'bash\n'; fi
    exit 0 ;;
  *"ppid="*) printf '%s\n' "$holder_pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_ps_no_harness <fakebin>: no ancestor is ever a harness and the walk
# terminates at pid 1.
make_fake_ps_no_harness() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/bin/bash\n'; exit 0 ;;
  *"args="*) printf 'bash\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# run_nudge_with_payload <root> <fakebin> <payload>: drive the wrapper the way a
# harness hook does, with the payload on stdin. An empty payload means the
# harnesses that hand the wrapper nothing.
run_nudge_with_payload() {
  local root=$1 fakebin=$2 payload=$3
  printf '%s' "$payload" | env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

record_field() {
  local record=$1 key=$2 line
  while IFS= read -r line; do
    case "$line" in "$key="*) printf '%s\n' "${line#"$key"=}"; return 0 ;; esac
  done < "$record"
  return 1
}

CLAUDE_PAYLOAD='{"session_id":"11111111-2222-3333-4444-555555555555","transcript_path":"/home/cap/.claude/projects/-home-cap-fm/11111111-2222-3333-4444-555555555555.jsonl","cwd":"/home/cap/fm","hook_event_name":"SessionStart","source":"startup"}'

test_records_transcript_position() {
  local root="$TMP_ROOT/record-ok" fakebin record status=0 out
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 424242
  out=$(run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD") || status=$?
  expect_code 0 "$status" "record run"
  [ "$out" = "$NUDGE_LINE" ] || fail "recording changed the nudge output: $out"
  record="$root/state/.primary-transcript"
  [ -f "$record" ] || fail "no transcript record was written"
  [ "$(record_field "$record" status)" = ok ] || fail "record status is not ok: $(cat "$record")"
  [ "$(record_field "$record" transcript_path)" = \
    "/home/cap/.claude/projects/-home-cap-fm/11111111-2222-3333-4444-555555555555.jsonl" ] \
    || fail "record has the wrong transcript path: $(cat "$record")"
  [ "$(record_field "$record" session_id)" = 11111111-2222-3333-4444-555555555555 ] \
    || fail "record has the wrong session id: $(cat "$record")"
  [ "$(record_field "$record" harness_pid)" = 424242 ] \
    || fail "record is not bound to the owning harness process: $(cat "$record")"
  case "$(record_field "$record" recorded_at)" in
    ''|*[!0-9]*) fail "record has no epoch stamp: $(cat "$record")" ;;
  esac
  pass "fm-sessionstart-nudge: a primary records its transcript path, session id, and owning harness pid"
}

test_record_binds_to_the_same_pid_as_the_session_lock() {
  local root="$TMP_ROOT/record-lock-parity" fakebin out status=0
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 515151
  run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD" >/dev/null
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$ROOT/bin/fm-lock.sh") || status=$?
  expect_code 0 "$status" "lock acquisition next to a transcript record"
  assert_contains "$out" "lock acquired: harness pid 515151" "fm-lock.sh stopped reporting the shared harness pid"
  [ "$(record_field "$root/state/.primary-transcript" harness_pid)" = "$(cat "$root/state/.lock")" ] \
    || fail "the transcript record and the session lock disagree about which session owns this home"
  pass "fm-sessionstart-nudge: the transcript record and the session lock name the same harness process"
}

test_record_is_rewritten_after_a_clear() {
  local root="$TMP_ROOT/record-after-clear" fakebin record
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  # A clear keeps the harness process, so the lock it already holds is still in
  # this session's ancestry: the wrapper stays silent, and the record must be
  # rewritten anyway. The holder must be a live pid for that ancestry check.
  make_fake_ps_holder "$fakebin" "$$"
  record="$root/state/.primary-transcript"
  printf 'status=ok\nharness_pid=%s\nsession_id=old-session\ntranscript_path=/tmp/old-session.jsonl\nrecorded_at=1\n' \
    "$$" > "$record"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "post-clear nudge" run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD"
  [ "$(record_field "$record" session_id)" = 11111111-2222-3333-4444-555555555555 ] \
    || fail "a cleared session kept the previous session's transcript record: $(cat "$record")"
  pass "fm-sessionstart-nudge: a post-clear session start replaces the superseded transcript record"
}

test_missing_transcript_path_is_recorded_as_an_error() {
  local root="$TMP_ROOT/record-no-path" fakebin record
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 727272
  record="$root/state/.primary-transcript"
  printf 'status=ok\nharness_pid=727272\nsession_id=old-session\ntranscript_path=/tmp/old-session.jsonl\nrecorded_at=1\n' \
    > "$record"
  run_nudge_with_payload "$root" "$fakebin" \
    '{"session_id":"abc","transcript_path":null,"hook_event_name":"SessionStart"}' >/dev/null
  [ "$(record_field "$record" status)" = error ] \
    || fail "a payload without a transcript path left a usable-looking record: $(cat "$record")"
  [ "$(record_field "$record" error)" = no-transcript-path ] \
    || fail "the recorded failure does not name its cause: $(cat "$record")"
  assert_not_contains "$(cat "$record")" "/tmp/old-session.jsonl" \
    "the superseded transcript path survived a failed determination"
  pass "fm-sessionstart-nudge: a payload without a transcript path records a visible error, not the stale path"
}

test_absent_payload_is_recorded_as_an_error() {
  local root="$TMP_ROOT/record-no-payload" fakebin record
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 838383
  run_nudge_with_payload "$root" "$fakebin" '' >/dev/null
  record="$root/state/.primary-transcript"
  [ -f "$record" ] || fail "a harness that hands over no payload left no record at all"
  [ "$(record_field "$record" error)" = no-hook-payload ] \
    || fail "an absent payload was not recorded as such: $(cat "$record")"
  pass "fm-sessionstart-nudge: a harness that delivers no payload records a visible error"
}

test_unwritable_transcript_path_is_recorded_as_an_error() {
  local root="$TMP_ROOT/record-forged-path" fakebin record body
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 848484
  run_nudge_with_payload "$root" "$fakebin" \
    '{"session_id":"abc","transcript_path":"/tmp/a.jsonl\nstatus=ok\ntranscript_path=/tmp/forged.jsonl"}' >/dev/null
  record="$root/state/.primary-transcript"
  body=$(cat "$record")
  [ "$(record_field "$record" error)" = unusable-transcript-path ] \
    || fail "a multi-line transcript path was not recorded as unusable: $body"
  assert_not_contains "$body" "/tmp/forged.jsonl" "a transcript path forged extra record lines"
  assert_not_contains "$body" "status=ok" "a transcript path forged a usable-looking status"
  pass "fm-sessionstart-nudge: a value that cannot be written as one record line is an error, not a record"
}

test_absent_harness_process_is_recorded_as_an_error() {
  local root="$TMP_ROOT/record-no-harness" fakebin record
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_no_harness "$fakebin"
  run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD" >/dev/null
  record="$root/state/.primary-transcript"
  [ "$(record_field "$record" error)" = no-harness-process ] \
    || fail "an unidentifiable session owner was not recorded as such: $(cat "$record")"
  assert_not_contains "$(cat "$record")" "transcript_path=" \
    "an unowned record still published a transcript path"
  pass "fm-sessionstart-nudge: a session whose owning process cannot be identified records a visible error"
}

test_absent_harness_process_records_an_empty_harness_pid() {
  local root="$TMP_ROOT/record-empty-pid" fakebin record body
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_no_harness "$fakebin"
  run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD" >/dev/null
  record="$root/state/.primary-transcript"
  body=$(cat "$record")
  grep -qx 'harness_pid=' "$record" \
    || fail "an unidentified session owner did not leave harness_pid empty: $body"
  assert_not_contains "$body" "harness_pid=0" \
    "an unidentified owner was recorded as pid 0, which a liveness check would report as alive"
  pass "fm-sessionstart-nudge: an unidentified session owner leaves harness_pid empty, not a probeable sentinel"
}

test_unwritable_state_leaves_no_stale_ok_record() {
  local root="$TMP_ROOT/record-unwritable" fakebin record body status=0
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 949494
  record="$root/state/.primary-transcript"
  printf 'status=ok\nharness_pid=949494\nsession_id=old-session\ntranscript_path=/tmp/old-session.jsonl\nrecorded_at=1\n' \
    > "$record"
  chmod 500 "$root/state"
  run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD" >/dev/null 2>&1 || status=$?
  chmod 700 "$root/state"
  expect_code 0 "$status" "session start with an unwritable state directory"
  body=$(cat "$record" 2>/dev/null || printf '')
  assert_not_contains "$body" "status=ok" \
    "a state directory that refused the record kept the previous session's ok record"
  assert_not_contains "$body" "/tmp/old-session.jsonl" \
    "a state directory that refused the record kept the previous session's transcript path"
  pass "fm-sessionstart-nudge: a session start that cannot write its record leaves no stale ok record"
}

test_failed_record_replace_leaves_no_stale_ok_record() {
  local root="$TMP_ROOT/record-replace-fails" fakebin record status=0
  make_primary "$root"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 959595
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/mv"
  chmod +x "$fakebin/mv"
  record="$root/state/.primary-transcript"
  printf 'status=ok\nharness_pid=959595\nsession_id=old-session\ntranscript_path=/tmp/old-session.jsonl\nrecorded_at=1\n' \
    > "$record"
  run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "session start whose record replace fails"
  [ ! -e "$record" ] \
    || fail "a failed atomic replace kept the previous session's record: $(cat "$record")"
  ls "$root"/state/.primary-transcript.* >/dev/null 2>&1 \
    && fail "a failed atomic replace left its temp file behind"
  pass "fm-sessionstart-nudge: a record whose atomic replace fails is removed, not left superseded"
}

test_non_primary_records_nothing() {
  local base="$TMP_ROOT/record-linked-base" root="$TMP_ROOT/record-linked" fakebin
  fm_git_worktree "$base" "$root" fm/sessionstart-record-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  fakebin=$(fm_fakebin "$root")
  make_fake_ps_holder "$fakebin" 939393
  expect_silent_zero "linked worktree record" run_nudge_with_payload "$root" "$fakebin" "$CLAUDE_PAYLOAD"
  [ ! -e "$root/state/.primary-transcript" ] \
    || fail "an unmarked linked task worktree claimed the home's transcript record"
  pass "fm-sessionstart-nudge: only a genuine primary claims the home's transcript record"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

test_tracked_harness_registration() {
  local command pi_plugin opencode_plugin
  jq -e '.hooks.SessionStart | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart hook is not registered exactly once"
  jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear"' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart matcher must include startup/resume/clear and exclude compact"
  jq -e 'any(.hooks.SessionStart[]?.hooks[]?.command?; contains("fm-sessionstart-nudge.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null || fail "Claude SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.codex/hooks.json")
  # shellcheck disable=SC2016
  assert_contains "$command" 'payload=$(cat' "Codex SessionStart hook does not read its payload"
  # shellcheck disable=SC2016
  assert_contains "$command" 'root=$(pwd -P)' "Codex SessionStart hook is not pwd-anchored"
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Codex SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.grok/hooks/fm-primary-sessionstart-nudge.json")
  # shellcheck disable=SC2016
  assert_contains "$command" '${GROK_WORKSPACE_ROOT:-}' "Grok SessionStart hook lacks an inline-default workspace root"
  # shellcheck disable=SC2016
  assert_not_contains "$command" '${GROK_WORKSPACE_ROOT}' "Grok SessionStart hook contains a bare variable expansion"
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Grok SessionStart hook does not invoke the wrapper"

  pi_plugin=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  assert_contains "$pi_plugin" '["startup", "new", "resume"]' "Pi SessionStart handler has the wrong reason allowlist"
  assert_contains "$pi_plugin" 'fm-sessionstart-nudge.sh' "Pi SessionStart handler does not invoke the wrapper"
  assert_contains "$pi_plugin" 'deliverFirstmateSyntheticInput(pi, nudge, "session-start")' "Pi SessionStart handler does not inject through trusted structured delivery"

  opencode_plugin=$(cat "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js")
  assert_contains "$opencode_plugin" 'session.created' "OpenCode plugin does not listen for session.created"
  assert_contains "$opencode_plugin" 'fm-sessionstart-nudge.sh' "OpenCode plugin does not invoke the wrapper"
  assert_contains "$opencode_plugin" 'promptAsync' "OpenCode plugin does not prompt the nudge turn"

  pass "all five verified harnesses register the shared session-start nudge"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_records_transcript_position
test_record_binds_to_the_same_pid_as_the_session_lock
test_record_is_rewritten_after_a_clear
test_missing_transcript_path_is_recorded_as_an_error
test_absent_payload_is_recorded_as_an_error
test_unwritable_transcript_path_is_recorded_as_an_error
test_absent_harness_process_is_recorded_as_an_error
test_absent_harness_process_records_an_empty_harness_pid
test_unwritable_state_leaves_no_stale_ok_record
test_failed_record_replace_leaves_no_stale_ok_record
test_non_primary_records_nothing
test_opencode_plugin_delivers_exact_nudge_once
test_tracked_harness_registration
