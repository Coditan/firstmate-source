#!/usr/bin/env bash
# Behavior tests for bin/fm-status.sh, the composing status writer every brief
# hands its worker in place of a bare shell append.
#
# The writer exists because bin/fm-classify-lib.sh reads a decision key only
# from the verb prefix, and a hand-typed line could put it anywhere: the scout
# report behind this writer measured seven hand-written shapes that lost the
# decision silently and four that never woke firstmate at all. The writer takes
# the parts, composes the one readable shape, and refuses at the write what the
# fold would have dropped. Each test below asserts the refusal by name and that
# nothing was written, or that the accepted line reads back through the real
# classifier as the event the worker meant.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

fm_test_tmproot TMP_ROOT fm-status

WRITER="$ROOT/bin/fm-status.sh"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$TMP_ROOT/elsewhere"

# Run the writer against the fixture home; capture stdout, stderr, and exit code.
run_writer() {  # <args...>
  OUT=$(FM_HOME="$HOME_DIR" "$WRITER" "$@" 2>"$TMP_ROOT/err"); RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

test_help_renders_entire_header() {
  local help
  help=$("$WRITER" --help)
  assert_contains "$help" "fm-status.sh <status-file> <verb> [--key <slug>] <note...>" \
    "--help omitted the usage line"
  assert_contains "$help" "Nothing here alters any line already on disk." \
    "--help omitted its header terminator"
  pass "fm-status.sh: --help renders the complete header"
}

test_accepted_bare_line() {
  local f="$STATE/bare.status"
  run_writer "$f" "done" "PR https://example.invalid/pr/1 checks green"
  expect_code 0 "$RC" "bare done line should be accepted"
  assert_contains "$OUT" "appended: done: PR https://example.invalid/pr/1 checks green" \
    "writer did not echo the line it appended"
  [ "$(cat "$f")" = "done: PR https://example.invalid/pr/1 checks green" ] \
    || fail "file holds something other than the composed line: $(cat "$f")"
  status_is_terminal_verb "$(last_status_line "$f")" \
    || fail "the classifier does not read the written line as a terminal verb"
  status_has_finished_event "$f" \
    || fail "the classifier does not read the written line as a finished event"
  pass "fm-status.sh: a bare <verb>: <note> line is appended and reads back as that event"
}

test_accepted_lines_append_in_order() {
  local f="$STATE/order.status"
  run_writer "$f" working "setup done"
  expect_code 0 "$RC" "first working line"
  run_writer "$f" working "fix implemented"
  expect_code 0 "$RC" "second working line"
  [ "$(wc -l < "$f" | tr -d ' ')" = 2 ] || fail "expected two lines, got: $(cat "$f")"
  [ "$(last_status_line "$f")" = "working: fix implemented" ] \
    || fail "last line is not the latest append: $(last_status_line "$f")"
  pass "fm-status.sh: successive writes append, never overwrite"
}

test_keyed_needs_decision_opens_that_key() {
  local f="$STATE/keyed.status" open
  run_writer "$f" needs-decision --key api-shape "REST or RPC for the new endpoint"
  expect_code 0 "$RC" "keyed needs-decision should be accepted"
  [ "$(cat "$f")" = "needs-decision [key=api-shape]: REST or RPC for the new endpoint" ] \
    || fail "keyed line was not composed in the verb prefix: $(cat "$f")"
  open=$(status_open_decisions "$f")
  [ "$open" = "api-shape"$'\t'"needs-decision"$'\t'"REST or RPC for the new endpoint" ] \
    || fail "the fold does not open the key the worker asked for: [$open]"
  pass "fm-status.sh: --key lands in the verb prefix and the fold opens that key"
}

test_keyed_resolved_closes_that_key_only() {
  local f="$STATE/close.status" open
  run_writer "$f" needs-decision --key first "one"
  run_writer "$f" needs-decision --key second "two"
  run_writer "$f" resolved --key first "captain chose one"
  expect_code 0 "$RC" "keyed resolved should be accepted"
  open=$(status_open_decisions "$f")
  [ "$open" = "second"$'\t'"needs-decision"$'\t'"two" ] \
    || fail "keyed resolved did not close exactly its own key: [$open]"
  pass "fm-status.sh: resolved --key closes its own decision and leaves the other open"
}

test_keyed_working_phase_reads_back() {
  local f="$STATE/phase.status" open
  run_writer "$f" working --key alpha-audit "audit under way"
  expect_code 0 "$RC" "keyed working should be accepted"
  open=$(status_open_activities "$f")
  [ "$open" = "alpha-audit"$'\t'"working"$'\t'"audit under way" ] \
    || fail "the activity fold does not read the keyed working phase: [$open]"
  pass "fm-status.sh: a charter's keyed working phase reads back through the activity fold"
}

test_configured_pause_and_resolve_verbs_are_accepted() {
  local f="$STATE/override.status"
  OUT=$(FM_HOME="$HOME_DIR" FM_CLASSIFY_PAUSED_VERB=awaiting "$WRITER" "$f" awaiting "vendor reset at 09:00" 2>&1); RC=$?
  expect_code 0 "$RC" "the configured pause verb should be accepted: $OUT"
  OUT=$(FM_HOME="$HOME_DIR" "$WRITER" "$f" awaiting "vendor reset at 09:00" 2>&1); RC=$?
  expect_code 2 "$RC" "an unconfigured verb must be refused"
  pass "fm-status.sh: the vocabulary follows the configured pause verb"
}

test_refused_verb_writes_nothing() {
  local f="$STATE/verb.status"
  run_writer "$f" finished "all good"
  expect_code 2 "$RC" "unknown verb must exit 2"
  assert_contains "$ERR" "fm-status: unknown status verb 'finished'" "refusal did not name the verb"
  assert_contains "$ERR" "working needs-decision blocked failed done resolved paused" \
    "refusal did not list the vocabulary"
  assert_absent "$f" "a refused verb must write nothing"
  run_writer "$f" captain-held "tracked by someone"
  expect_code 2 "$RC" "captain-held is not a worker verb"
  assert_absent "$f" "captain-held must write nothing"
  pass "fm-status.sh: an unknown verb is refused by name and nothing is written"
}

test_refused_key_writes_nothing() {
  local f="$STATE/key.status" bad
  for bad in "route choice" "api/shape" "key=x" ""; do
    run_writer "$f" needs-decision --key "$bad" "pick"
    expect_code 2 "$RC" "key [$bad] must be refused"
    assert_contains "$ERR" "fm-status: decision key must be a privacy-safe slug: $bad" \
      "refusal for [$bad] did not name the key"
    assert_absent "$f" "a refused key must write nothing (key [$bad])"
  done
  run_writer "$f" needs-decision --key
  expect_code 2 "$RC" "--key without a value must be refused"
  assert_contains "$ERR" "fm-status: --key needs a slug value" "bare --key refusal did not say so"
  assert_absent "$f" "bare --key must write nothing"
  pass "fm-status.sh: a key that is not a privacy-safe slug is refused by name and nothing is written"
}

test_refused_note_shapes_write_nothing() {
  local f="$STATE/note.status"
  run_writer "$f" "done" "first line
second line"
  expect_code 2 "$RC" "a multi-line note must be refused"
  assert_contains "$ERR" "fm-status: note must be one line" "multi-line refusal did not say so"
  assert_absent "$f" "a multi-line note must write nothing"
  run_writer "$f" "done" "   "
  expect_code 2 "$RC" "a blank note must be refused"
  assert_contains "$ERR" "fm-status: note must not be empty" "blank-note refusal did not say so"
  run_writer "$f" "done"
  expect_code 2 "$RC" "a missing note must be refused"
  assert_absent "$f" "a blank or missing note must write nothing"
  pass "fm-status.sh: a note that is not one non-empty line is refused and nothing is written"
}

test_refused_path_outside_state_writes_nothing() {
  local f="$TMP_ROOT/elsewhere/task.status"
  run_writer "$f" "done" "escaped"
  expect_code 2 "$RC" "a path outside state/ must be refused"
  assert_contains "$ERR" "fm-status: refusing to write outside this home's state/: $f" \
    "refusal did not name the path"
  assert_absent "$f" "a refused path must write nothing"
  # A sibling of state/ reached through a relative hop is still outside it.
  f="$STATE/../elsewhere/task.status"
  run_writer "$f" "done" "escaped sideways"
  expect_code 2 "$RC" "a relative escape from state/ must be refused"
  assert_absent "$TMP_ROOT/elsewhere/task.status" "a relative escape must write nothing"
  # Another file kind under state/ is state machinery, never a status stream.
  run_writer "$STATE/task.meta" "done" "wrong file"
  expect_code 2 "$RC" "a non-.status name must be refused"
  assert_contains "$ERR" "fm-status: status file must be named <id>.status" \
    "non-.status refusal did not say so"
  assert_absent "$STATE/task.meta" "a refused name must write nothing"
  pass "fm-status.sh: only <id>.status directly under this home's state/ is written"
}

test_state_override_selects_the_home() {
  local other="$TMP_ROOT/other-state" f
  mkdir -p "$other"
  f="$other/task.status"
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$other" "$WRITER" "$f" "done" "override" 2>&1); RC=$?
  expect_code 0 "$RC" "FM_STATE_OVERRIDE must select the state dir: $OUT"
  [ "$(cat "$f")" = "done: override" ] || fail "override write missing: $(cat "$f")"
  OUT=$(FM_HOME="$HOME_DIR" "$WRITER" "$f" "done" "no override" 2>&1); RC=$?
  expect_code 2 "$RC" "without the override the same path is outside the home"
  pass "fm-status.sh: the state directory follows FM_STATE_OVERRIDE, then FM_HOME"
}

# The Codex direct-report shape (docs/codex-status-signalling.md): the public
# state/<id>.status is a symlink into a per-task signal directory. The writer
# checks the public path's directory and lets the append follow the link.
test_codex_public_symlink_is_written_through() {
  local target="$STATE/.crew-signal/codex-task/status"
  mkdir -p "$STATE/.crew-signal/codex-task"
  ln -s .crew-signal/codex-task/status "$STATE/codex-task.status"
  run_writer "$STATE/codex-task.status" needs-decision --key route "pick north or south"
  expect_code 0 "$RC" "a symlinked public status path must be accepted: $ERR"
  [ "$(cat "$target")" = "needs-decision [key=route]: pick north or south" ] \
    || fail "the append did not land through the symlink: $(cat "$target" 2>&1)"
  [ -L "$STATE/codex-task.status" ] || fail "the writer replaced the public symlink with a file"
  pass "fm-status.sh: a Codex public symlink is written through into its signal directory"
}

test_note_is_opaque() {
  local f="$STATE/opaque.status"
  run_writer "$f" "done" 'audit clean corr=0123456789abcdef [key=not-a-key] (via nothing)'
  expect_code 0 "$RC" "note text must never be inspected"
  [ "$(cat "$f")" = 'done: audit clean corr=0123456789abcdef [key=not-a-key] (via nothing)' ] \
    || fail "note was rewritten: $(cat "$f")"
  [ "$(_fm_decision_key "$(cat "$f")")" = default ] \
    || fail "a bracket in the note must not become a key"
  pass "fm-status.sh: the note reaches the file verbatim and never becomes grammar"
}

test_help_renders_entire_header
test_accepted_bare_line
test_accepted_lines_append_in_order
test_keyed_needs_decision_opens_that_key
test_keyed_resolved_closes_that_key_only
test_keyed_working_phase_reads_back
test_configured_pause_and_resolve_verbs_are_accepted
test_refused_verb_writes_nothing
test_refused_key_writes_nothing
test_refused_note_shapes_write_nothing
test_refused_path_outside_state_writes_nothing
test_state_override_selects_the_home
test_codex_public_symlink_is_written_through
test_note_is_opaque
