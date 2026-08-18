#!/usr/bin/env bash
# Behavior tests for the searchable session archive: bin/fm-transcript-reduce.py,
# bin/fm-transcript-search.sh, bin/fm-transcript-refresh.sh, and the two list
# files under bin/fm-transcript-patterns/.
#
# Three properties here are safety properties rather than ordinary behavior, and
# each one exists because its absence was measured rather than imagined:
#
#   1. A wrong --source must be LOUD. The two record shapes share no key, so a
#      Claude-shaped reader reads a Codex rollout as zero entries and raises
#      nothing at all. 32.9 MB of real Codex material through a Claude reader
#      produced an empty file with no error on 2026-08-18. An empty archive that
#      exits 0 is indistinguishable from a quiet fleet.
#   2. The pattern file must not match itself. A detector whose patterns appear
#      in plain text writes those patterns into the next session transcript, and
#      every later scan then inflates on its own tooling.
#   3. THIS FILE must not match the pattern file either. Property 2 closes the
#      pattern list; it does not close the fixtures. The first build of this tool
#      left five real redactions in its own session from fixtures typed in plain
#      form. Every credential-shaped fixture below is therefore assembled at run
#      time from parts, so the literal never appears in this file, and
#      test_tool_and_its_tests_do_not_match_the_patterns scans this file to prove
#      it. A test that proves the detector works must not itself become something
#      the detector finds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REDUCE="$ROOT/bin/fm-transcript-reduce.py"
SEARCH="$ROOT/bin/fm-transcript-search.sh"
REFRESH="$ROOT/bin/fm-transcript-refresh.sh"
PATTERNS="$ROOT/bin/fm-transcript-patterns/patterns.txt"
INJECTED="$ROOT/bin/fm-transcript-patterns/injected-prefixes.txt"

TMP=""
fm_test_tmproot TMP fm-transcript

# --- fixture builders -------------------------------------------------------

# A minimal Claude-shaped session: both conversation sides, one command, one
# tool result.
write_claude_session() {
  local dir=$1 name=${2:-sess}
  mkdir -p "$dir"
  cat >"$dir/$name.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-18T10:00:00Z","cwd":"/home/x/alpha","gitBranch":"main","version":"1.2.3","message":{"role":"user","content":"find the tugboat host"}}
{"type":"assistant","timestamp":"2026-08-18T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"looking now"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la /srv","description":"list"}}]}}
{"type":"user","timestamp":"2026-08-18T10:00:06Z","message":{"role":"user","content":[{"type":"tool_result","content":"total 0"}]}}
EOF
}

# A minimal Codex-shaped rollout. No key is shared with the Claude shape above:
# that is the whole reason --source cannot be inferred safely.
write_codex_session() {
  local dir=$1 name=${2:-rollout-2026-08-18T11-00-00-abc}
  mkdir -p "$dir"
  cat >"$dir/$name.jsonl" <<'EOF'
{"timestamp":"2026-08-18T11:00:00Z","type":"session_meta","payload":{"cwd":"/home/x/bravo","cli_version":"9.9","git":{"branch":"work"}}}
{"timestamp":"2026-08-18T11:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"where did the harbour report go"}}
{"timestamp":"2026-08-18T11:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"grep\",\"-r\",\"harbour\"]}"}}
{"timestamp":"2026-08-18T11:00:03Z","type":"response_item","payload":{"type":"function_call_output","output":"nothing found"}}
EOF
}

# Assemble the credential-shaped fixture values from parts, so no literal that
# patterns.txt matches is ever written into this file. See the header.
fixture_prefixed_token() {
  printf 'gh%s_%s' p ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
}

fixture_assigned_value() {
  printf 'Zq7%s' 4mNb2vXs9Lt
}

# A Claude session carrying one prefix-anchored and one context-anchored value.
write_credential_session() {
  local dir=$1 tok assigned key
  tok=$(fixture_prefixed_token)
  assigned=$(fixture_assigned_value)
  key=API_KEY
  mkdir -p "$dir"
  python3 - "$dir/creds.jsonl" "$tok" "$assigned" "$key" <<'PY'
import json, sys
out, tok, assigned, key = sys.argv[1:5]
recs = [
    {"type": "user", "timestamp": "2026-08-18T12:00:00Z", "cwd": "/home/x/charlie",
     "message": {"role": "user", "content": "here is the token %s use it" % tok}},
    {"type": "assistant", "timestamp": "2026-08-18T12:00:01Z",
     "message": {"role": "assistant", "content": [
         {"type": "tool_use", "name": "Bash",
          "input": {"command": "%s=%s printf run\n" % (key, assigned)}}]}},
]
with open(out, "w", encoding="utf-8") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
PY
}

# --- the tool is where it belongs -------------------------------------------

test_tool_is_tracked_and_runnable() {
  local f
  for f in "$REDUCE" "$SEARCH" "$REFRESH"; do
    assert_present "$f" "missing tool file: $f"
    [ -x "$f" ] || fail "$f must be executable"
  done
  assert_present "$PATTERNS" "the detector's pattern list must ship with the tool"
  assert_present "$INJECTED" "the machine-injection marker list must ship with the tool"
  pass "the tool and its two list files live in tracked bin/ and run from there"
}

# The tool was written in one seat's private copy and carried that seat's home
# in a default. A vessel whose home is elsewhere would have searched a directory
# that does not exist and been told there were no matches.
test_no_home_path_is_hardcoded() {
  local f
  for f in "$REDUCE" "$SEARCH" "$REFRESH"; do
    if grep -nE '/home/[a-z]' "$f" >/dev/null 2>&1; then
      grep -nE '/home/[a-z]' "$f" >&2
      fail "$(basename "$f") hardcodes a home directory; resolve it from FM_HOME"
    fi
  done
  grep -q 'FM_HOME' "$SEARCH" || fail "fm-transcript-search.sh must resolve its archive from FM_HOME"
  grep -q 'FM_HOME' "$REFRESH" || fail "fm-transcript-refresh.sh must resolve its archive from FM_HOME"
  pass "every path resolves from FM_HOME rather than from the seat it was written on"
}

# --- self-scan properties ---------------------------------------------------

# scan_zero <label> <file>... - copy files into an isolated tree as .txt and run
# the detector over them, requiring zero hits.
scan_zero() {
  local label=$1 dir out rc=0 f i=0
  shift
  dir="$TMP/selfscan-$label"
  rm -rf "$dir"
  mkdir -p "$dir"
  for f in "$@"; do
    i=$((i + 1))
    cp "$f" "$dir/$i-$(basename "$f").txt"
  done
  out=$(python3 "$REDUCE" --verify-only --out "$dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail "$label: detector found hits in its own material"; }
  assert_contains "$out" '0 residual hits' "$label: expected a zero-hit verdict"
}

test_patterns_file_does_not_match_itself() {
  scan_zero patterns "$PATTERNS"
  pass "patterns.txt scanned against itself returns zero"
}

test_tool_and_its_tests_do_not_match_the_patterns() {
  scan_zero tool "$REDUCE" "$SEARCH" "$REFRESH" "$INJECTED" \
    "${BASH_SOURCE[0]}" "$ROOT/docs/session-archive.md"
  pass "the tool, its documentation, and this test file all scan to zero"
}

# --- the two readers --------------------------------------------------------

test_claude_reader_reads_claude_material() {
  local out rc=0 body
  write_claude_session "$TMP/claude-in/proj"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/claude-in" --out "$TMP/claude-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail "claude reader failed on claude material"; }
  body=$(cat "$TMP/claude-out/proj/sess.txt")
  assert_contains "$body" 'find the tugboat host' 'the user side must survive verbatim'
  assert_contains "$body" 'looking now' 'the assistant side must survive verbatim'
  assert_contains "$body" '$ ls -la /srv' 'the command must survive verbatim'
  assert_contains "$body" '# cwd      /home/x/alpha' 'the session header must carry the working directory'
  assert_present "$TMP/claude-out/_index.tsv" 'the per-store index must be written'
  pass "the claude reader recovers both sides, the command, the header, and the index"
}

test_codex_reader_reads_codex_material() {
  local out rc=0 body
  write_codex_session "$TMP/codex-in/2026/08/18"
  out=$(python3 "$REDUCE" --source codex --in "$TMP/codex-in" --out "$TMP/codex-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail "codex reader failed on codex material"; }
  body=$(cat "$TMP/codex-out/2026/08/18/rollout-2026-08-18T11-00-00-abc.txt")
  assert_contains "$body" 'where did the harbour report go' 'the user side must survive verbatim'
  assert_contains "$body" '$ grep -r harbour' 'the command must survive verbatim'
  assert_contains "$body" '# cwd      /home/x/bravo' 'session_meta must supply the header'
  pass "the codex reader recovers the message, the command, and the session header"
}

# --- a wrong --source is loud ------------------------------------------------

test_wrong_source_refuses_before_writing_anything() {
  local out rc=0
  write_codex_session "$TMP/wrong-a/2026/08/18"
  rc=0
  out=$(python3 "$REDUCE" --source claude --in "$TMP/wrong-a" --out "$TMP/wrong-a-out" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a claude reader pointed at codex material must not exit 0'
  assert_contains "$out" 'codex-shaped' 'the refusal must name the shape it actually found'
  assert_contains "$out" 'reports no error' 'the refusal must say why silence is the hazard'
  assert_absent "$TMP/wrong-a-out" 'the refusal must come before anything is written'
  pass "a claude reader on codex material refuses loudly and writes nothing"
}

# The reverse direction, with the shape mismatch reached through the pre-flight
# rather than through the filename filter: a claude-shaped session sitting under
# a rollout-*.jsonl name is discovered as codex input and caught on its content.
test_wrong_source_is_caught_on_content_not_on_the_filename() {
  local out rc=0
  write_claude_session "$TMP/wrong-b/2026/08/18" 'rollout-2026-08-18T09-00-00-zzz'
  out=$(python3 "$REDUCE" --source codex --in "$TMP/wrong-b" --out "$TMP/wrong-b-out" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a codex reader pointed at claude material must not exit 0'
  assert_contains "$out" 'claude-shaped' 'the refusal must name the shape it actually found'
  assert_absent "$TMP/wrong-b-out" 'the refusal must come before anything is written'
  pass "the shape check reads the records, so a misleading filename does not slip past"
}

test_an_input_with_no_transcripts_is_refused() {
  local out rc=0
  mkdir -p "$TMP/empty-in"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/empty-in" --out "$TMP/empty-out" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'an input tree with no transcripts must not report success'
  assert_contains "$out" 'nothing to reduce' 'the refusal must say nothing was read'
  pass "an empty input refuses rather than writing an archive that looks built"
}

test_a_run_that_recovers_no_entries_fails() {
  local out rc=0
  mkdir -p "$TMP/inert-in"
  # Valid JSON lines of neither shape: past the pre-flight, still nothing to read.
  printf '{"note":"neither shape"}\n{"note":"still neither"}\n' >"$TMP/inert-in/sess.jsonl"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/inert-in" --out "$TMP/inert-out" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a run that recovered zero entries must not exit 0'
  assert_contains "$out" 'zero entries' 'the failure must name the empty result'
  pass "a run that reads files but recovers nothing fails instead of exiting quietly"
}

# --- the redactor ------------------------------------------------------------

test_redactor_masks_a_synthetic_credential() {
  local out rc=0 body tok assigned
  tok=$(fixture_prefixed_token)
  assigned=$(fixture_assigned_value)
  write_credential_session "$TMP/creds-in/proj"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/creds-in" --out "$TMP/creds-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail 'the reducer failed on the credential fixture'; }
  assert_contains "$out" 'github-token' 'the run summary must count the prefix-anchored class'
  assert_contains "$out" 'assigned-secret' 'the run summary must count the context-anchored class'
  body=$(cat "$TMP/creds-out/proj/creds.txt")
  assert_contains "$body" 'REDACTED github-token' 'a removed value must leave a naming marker'
  case "$body" in
    *"$tok"*) fail 'the prefix-anchored value survived into the derivative' ;;
    *"$assigned"*) fail 'the context-anchored value survived into the derivative' ;;
  esac
  assert_contains "$body" 'API_KEY' 'the key name is context and must survive as context'
  pass "both detector classes fire, the values are gone, and the surrounding context stays"
}

test_verification_is_zero_on_clean_and_loud_on_dirty() {
  local out rc=0 tok
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/creds-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail 'the redacted derivative must verify to zero'; }
  assert_contains "$out" '0 residual hits' 'verification must state the residual count'

  # A verification that can only ever say zero proves nothing, so plant one.
  mkdir -p "$TMP/dirty"
  tok=$(fixture_prefixed_token)
  printf 'a line carrying %s in it\n' "$tok" >"$TMP/dirty/planted.txt"
  rc=0
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/dirty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'verification must fail on a derivative that still carries a value'
  assert_contains "$out" 'HIT' 'a residual hit must be reported with its file'
  case "$out" in
    *"$tok"*) fail 'verification must report classes and counts, never the matched value' ;;
  esac
  pass "verification returns zero on the clean derivative and fails loudly on a planted one"
}

# Zero hits over zero files is not an all-clear; it is a reading the detector
# could not take, and reporting it as clean is the same silent emptiness a wrong
# --source produces one step earlier.
test_verification_over_nothing_is_not_an_all_clear() {
  local out rc=0
  mkdir -p "$TMP/nothing-to-verify"
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/nothing-to-verify" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'verifying an empty directory must not report an all-clear'
  assert_contains "$out" 'nothing to verify' 'the refusal must say the reading could not be taken'
  case "$out" in
    *'0 residual hits'*) fail 'an unverifiable directory must not print a zero-hit verdict' ;;
  esac
  pass "verifying a directory with no derivative in it refuses instead of reporting zero"
}

# --- search ------------------------------------------------------------------

# Build a fixture home so search is exercised the way a vessel that is not this
# one would run it: FM_HOME elsewhere, archive under its own data/.
setup_fixture_home() {
  local home="$TMP/home"
  mkdir -p "$home/data"
  write_claude_session "$TMP/home-src/claude/alpha"
  write_codex_session "$TMP/home-src/codex/2026/08/18"
  FM_HOME="$home" FM_CLAUDE_SESSIONS="$TMP/home-src/claude" \
    FM_CODEX_SESSIONS="$TMP/home-src/codex" "$REFRESH" >"$TMP/refresh.log" 2>&1 \
    || { cat "$TMP/refresh.log" >&2; fail 'refresh failed against a fixture home'; }
  printf '%s\n' "$home"
}

test_refresh_builds_verifies_and_lands_the_bound() {
  local home archive log
  home=$(setup_fixture_home)
  archive="$home/data/transcripts"
  log=$(cat "$TMP/refresh.log")
  assert_present "$archive/claude-redacted/_index.tsv" 'refresh must build the claude store'
  assert_present "$archive/codex-redacted/_index.tsv" 'refresh must build the codex store'
  assert_contains "$log" '0 residual hits' 'refresh must verify what it built'
  assert_present "$archive/README.md" 'refresh must leave the honest bound on the artefact'
  assert_grep 'never examined for credentials at all' "$archive/README.md" \
    'the archive README must carry the discarded-remainder bound'
  assert_grep 'not one bit better' "$archive/README.md" \
    'the archive README must carry the as-good-as-the-patterns bound'
  pass "refresh builds both stores from a foreign home, verifies them, and lands the bound"
}

test_refresh_does_not_overwrite_an_existing_readme() {
  local home archive
  home=$(setup_fixture_home)
  archive="$home/data/transcripts"
  printf 'captain notes here\n' >"$archive/README.md"
  FM_HOME="$home" FM_CLAUDE_SESSIONS="$TMP/home-src/claude" \
    FM_CODEX_SESSIONS="$TMP/home-src/codex" "$REFRESH" >/dev/null 2>&1 \
    || fail 'second refresh failed'
  assert_grep 'captain notes here' "$archive/README.md" \
    'a rebuild must not overwrite an archive README someone edited'
  pass "a rebuild leaves an existing archive README alone"
}

test_search_resolves_the_archive_from_fm_home() {
  local home out
  home=$(setup_fixture_home)
  out=$(FM_HOME="$home" "$SEARCH" 'tugboat host' 2>/dev/null) \
    || fail 'search found nothing in a fixture home it should have matched'
  assert_contains "$out" 'tugboat host' 'the matching line must be printed'
  assert_contains "$out" 'claude-redacted' 'the hit must name the store it came from'
  out=$(FM_HOME="$home" "$SEARCH" 'harbour report' --files-only 2>/dev/null) \
    || fail 'search did not reach the codex store in a fixture home'
  assert_contains "$out" 'codex-redacted' 'one query must reach both stores'
  pass "search resolves its archive from FM_HOME and reaches both stores"
}

test_search_narrows_the_file_set_by_index() {
  local home out
  home=$(setup_fixture_home)
  out=$(FM_HOME="$home" "$SEARCH" 'tugboat host' --cwd zulu 2>&1 >/dev/null)
  assert_contains "$out" 'searching 0 session files' \
    'a --cwd that matches no session must narrow the file set to nothing'
  out=$(FM_HOME="$home" "$SEARCH" 'tugboat host' --cwd alpha 2>&1 >/dev/null)
  assert_contains "$out" 'searching 1 session files' \
    'a --cwd that matches one session must narrow to exactly that one'
  out=$(FM_HOME="$home" "$SEARCH" 'tugboat host' --cwd alpha 2>/dev/null) \
    || fail 'a --cwd that matches the session must still find it'
  assert_contains "$out" 'tugboat host' 'index narrowing must not lose a real hit'
  pass "--cwd narrows the file set through the index before grep runs"
}

test_search_reports_a_missing_archive_rather_than_no_matches() {
  local out rc=0
  mkdir -p "$TMP/bare-home/data"
  out=$(FM_HOME="$TMP/bare-home" "$SEARCH" 'anything' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing archive must be reported as absent, got exit $rc"
  assert_contains "$out" 'no session archive under' 'the message must name the missing archive'
  pass "an archive that is not there reads as absent, never as no matches"
}

test_tool_is_tracked_and_runnable
test_no_home_path_is_hardcoded
test_patterns_file_does_not_match_itself
test_tool_and_its_tests_do_not_match_the_patterns
test_claude_reader_reads_claude_material
test_codex_reader_reads_codex_material
test_wrong_source_refuses_before_writing_anything
test_wrong_source_is_caught_on_content_not_on_the_filename
test_an_input_with_no_transcripts_is_refused
test_a_run_that_recovers_no_entries_fails
test_redactor_masks_a_synthetic_credential
test_verification_is_zero_on_clean_and_loud_on_dirty
test_verification_over_nothing_is_not_an_all_clear
test_refresh_builds_verifies_and_lands_the_bound
test_refresh_does_not_overwrite_an_existing_readme
test_search_resolves_the_archive_from_fm_home
test_search_narrows_the_file_set_by_index
test_search_reports_a_missing_archive_rather_than_no_matches
