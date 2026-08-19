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
#   3. A DOCUMENTED SEARCH MUST NOT SILENTLY RETURN NOTHING. The store is
#      compressed, and plain grep reads a compressed file as no matches with no
#      error - the same silent emptiness as 1, arriving through the
#      documentation instead of through the reader. So the search path is
#      exercised over a compressed store here.
#   4. THIS FILE must not match the pattern file either. Property 2 closes the
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
ZCAT="$ROOT/bin/fm-transcript-zcat.sh"
PATTERNS="$ROOT/bin/fm-transcript-patterns/patterns.txt"
INJECTED="$ROOT/bin/fm-transcript-patterns/injected-prefixes.txt"

TMP=""
fm_test_tmproot TMP fm-transcript

# --- reading the store ------------------------------------------------------

# Every session in the store is one zstd file, so a test reads it the way a
# search does - through the decompressor - and never by opening it as text.
read_session() {
  zstd -dcq -- "$1"
}

# Session files in a store, both shapes, so a test that expects only one shape
# has to say so.
store_files() {
  find "$1" \( -name '*.txt.zst' -o -name '*.txt' \) -type f | sort
}

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
  for f in "$REDUCE" "$SEARCH" "$REFRESH" "$ZCAT"; do
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
  assert_present "$TMP/claude-out/proj/sess.txt.zst" 'the session must be written compressed'
  body=$(read_session "$TMP/claude-out/proj/sess.txt.zst")
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
  body=$(read_session "$TMP/codex-out/2026/08/18/rollout-2026-08-18T11-00-00-abc.txt.zst")
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
  body=$(read_session "$TMP/creds-out/proj/creds.txt.zst")
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
  printf 'a line carrying %s in it\n' "$tok" |
    zstd -q -o "$TMP/dirty/planted.txt.zst"
  rc=0
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/dirty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'verification must fail on a compressed derivative that still carries a value'
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

# --- the store is compressed, wholly ----------------------------------------

test_the_store_is_written_compressed_and_leaves_nothing_plain() {
  local out rc=0 plain
  write_claude_session "$TMP/zst-in/proj"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/zst-in" --out "$TMP/zst-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail 'the reducer failed writing a compressed store'; }
  assert_present "$TMP/zst-out/proj/sess.txt.zst" 'the session must land as one compressed file'
  assert_absent "$TMP/zst-out/proj/sess.txt" 'no plain copy of a written session may be left behind'
  plain=$(find "$TMP/zst-out" -name '*.txt' -type f | wc -l)
  [ "$plain" -eq 0 ] || fail "the store must hold no plain session files, found $plain"
  assert_contains "$out" 'on disk' 'the summary must state what the store actually costs on disk'
  assert_grep 'sess.txt.zst' "$TMP/zst-out/_index.tsv" \
    'the index must name the file that exists, not the one that used to'
  pass "a build writes one compressed file per session and leaves no plain copy"
}

# The archive keeps sessions the raw store no longer has, and a rebuild cannot
# reach them. Left alone they would stay plain forever - half a compressed
# archive and half not - so a rebuild compresses them where they lie, without
# removing the one thing they carry, which is their content.
test_a_rebuild_compresses_a_retained_session_it_cannot_rebuild() {
  local out rc=0 body
  write_claude_session "$TMP/keep-in/proj"
  python3 "$REDUCE" --source claude --in "$TMP/keep-in" --out "$TMP/keep-out" >/dev/null 2>&1 \
    || fail 'the first build failed'
  mkdir -p "$TMP/keep-out/gone"
  printf '# session gone/old.jsonl\n# cwd      /home/x/gone\n\nan older answer worth keeping\n' \
    >"$TMP/keep-out/gone/old.txt"
  out=$(python3 "$REDUCE" --source claude --in "$TMP/keep-in" --out "$TMP/keep-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail 'the rebuild failed'; }
  assert_absent "$TMP/keep-out/gone/old.txt" 'the retained plain session must not be left uncompressed'
  assert_present "$TMP/keep-out/gone/old.txt.zst" 'the retained session must survive as a compressed file'
  body=$(read_session "$TMP/keep-out/gone/old.txt.zst")
  assert_contains "$body" 'an older answer worth keeping' \
    'compressing a retained session must not cost a word of it'
  assert_contains "$out" 'converged' 'the run must say what it converged rather than doing it silently'
  pass "a rebuild converges a retained plain session into the compressed store, content intact"
}

test_verification_reads_the_compressed_store_it_verifies() {
  local out rc=0
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/zst-out" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; fail 'verification failed over a compressed store'; }
  assert_contains "$out" '1 files scanned' \
    'verification must count the compressed session it read, not skip it as an unknown file'
  assert_contains "$out" '0 residual hits' 'verification must state the residual count'
  pass "verification opens the compressed store and counts what it scanned"
}

# A store file the decompressor cannot read is not a clean file; it is a file
# nobody read. Counting it as verified is the silent all-clear this tool exists
# to refuse.
test_verification_refuses_a_store_file_it_cannot_read() {
  local out rc=0
  mkdir -p "$TMP/corrupt"
  printf 'not a compressed file at all\n' >"$TMP/corrupt/broken.txt.zst"
  out=$(python3 "$REDUCE" --verify-only --out "$TMP/corrupt" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a store file that cannot be decompressed must not verify clean'
  assert_contains "$out" 'could not be read' 'the refusal must say the file was never verified'
  pass "an unreadable store file is reported as unread rather than counted as clean"
}

test_a_build_without_a_compressor_refuses_before_writing() {
  local out rc=0
  write_claude_session "$TMP/nozstd-in/proj"
  out=$(FM_ZSTD="$TMP/no-such-zstd" python3 "$REDUCE" --source claude \
        --in "$TMP/nozstd-in" --out "$TMP/nozstd-out" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a build with no compressor must not exit 0'
  assert_contains "$out" 'not on PATH' 'the refusal must name the missing tool'
  assert_contains "$out" 'half compressed and half plain' 'the refusal must say what it is avoiding'
  assert_absent "$TMP/nozstd-out" 'nothing may be written when the compressor is missing'
  pass "a missing compressor refuses the build instead of writing a store nobody can search"
}

test_refresh_without_a_compressor_leaves_no_archive() {
  local home out rc=0
  home="$TMP/refresh-nozstd-home"
  write_claude_session "$TMP/refresh-nozstd-src/claude/project"
  out=$(FM_HOME="$home" FM_CLAUDE_SESSIONS="$TMP/refresh-nozstd-src/claude" \
        FM_CODEX_SESSIONS="$TMP/refresh-nozstd-src/codex" FM_ZSTD="$TMP/no-such-zstd" \
        "$REFRESH" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'refresh with no compressor must not exit 0'
  assert_contains "$out" 'half compressed and half plain' \
    'refresh must preserve the reducer refusal message'
  assert_absent "$home/data/transcripts" \
    'refresh must not create an archive before the compressor prerequisite passes'
  pass "refresh with no compressor refuses before creating the archive"
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

test_search_reads_the_compressed_store() {
  local home out plain
  home=$(setup_fixture_home)
  plain=$(find "$home/data/transcripts" -name '*.txt' -type f | wc -l)
  [ "$plain" -eq 0 ] || fail "the fixture archive must be wholly compressed, found $plain plain files"
  out=$(FM_HOME="$home" "$SEARCH" 'tugboat host' 2>/dev/null) \
    || fail 'search found nothing in a compressed archive it should have matched'
  assert_contains "$out" 'tugboat host' 'the matching line must come back out of the compressed file'
  assert_contains "$out" '.txt.zst' 'the hit must name the compressed session file it came from'
  assert_contains "$out" 'cwd      /home/x/alpha' \
    'the session header must be read through the decompressor too, not skipped'
  pass "search reads the compressed store and still reports the session header with the hit"
}

test_search_does_not_depend_on_ripgrep_implicit_decompression() {
  local home out wrapper real_rg
  home=$(setup_fixture_home)
  wrapper="$TMP/rg-without-z"
  real_rg=$(command -v rg)
  cat >"$wrapper" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    -z|-*z*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_RG" "$@"
EOF
  chmod +x "$wrapper"
  out=$(FM_HOME="$home" FM_RG="$wrapper" FM_TEST_REAL_RG="$real_rg" \
        "$SEARCH" 'tugboat host' 2>/dev/null) \
    || fail 'search depended on ripgrep implicit decompression instead of the required zstd tool'
  assert_contains "$out" 'tugboat host' \
    'explicit zstd preprocessing must return the compressed hit'
  pass "search uses its required zstd tool rather than ripgrep's version-dependent implicit decompressor"
}

test_search_reads_plain_sessions_during_migration() {
  local home out plain
  home=$(setup_fixture_home)
  plain="$home/data/transcripts/claude-redacted/migration.txt"
  printf '# cwd      /home/x/migration\n# span     2026-08-18T10:00:00Z\nplain migration session\n' >"$plain"
  out=$(FM_HOME="$home" "$SEARCH" 'plain migration session' 2>/dev/null) \
    || fail 'search did not read a plain session during migration'
  assert_contains "$out" 'plain migration session' \
    'a plain migration-era session must remain searchable'
  pass "search reads plain sessions that remain during migration"
}

# The reason the documentation had to change, stated as a test rather than as a
# claim: over this store the old documented command answers "nothing here" and
# exits as though that were true. Worse than nothing, it half answers - the
# index is the one plain file left, so a phrase that happens to sit in its
# first-user-message column still matches and the emptiness looks selective
# rather than total.
test_plain_grep_does_not_read_the_sessions() {
  local home rc=0 out
  home=$(setup_fixture_home)
  out=$(grep -r 'looking now' "$home/data/transcripts" 2>/dev/null) || rc=$?
  [ "$rc" -eq 1 ] || fail "plain grep was expected to report no matches over a compressed store, got exit $rc"
  [ -z "$out" ] || fail 'plain grep unexpectedly read a compressed session'
  out=$(FM_HOME="$home" "$SEARCH" 'looking now' 2>/dev/null) \
    || fail 'the wrapper must find what plain grep could not'
  assert_contains "$out" 'looking now' 'the same phrase must come back through the wrapper'
  pass "plain grep reports no matches on material the wrapper finds, which is why it is no longer documented"
}

# A caller that scripts this tool reads its exit status, and the file set is
# handed to the scanner in batches: a batch with no hit must not make a search
# that matched look like a search that failed.
test_search_status_says_matched_or_not_matched() {
  local home rc=0
  home=$(setup_fixture_home)
  FM_HOME="$home" "$SEARCH" 'tugboat host' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a search that matched must exit 0, got $rc"
  rc=0
  FM_HOME="$home" "$SEARCH" 'tugboat host' --files-only >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a --files-only search that matched must exit 0, got $rc"
  rc=0
  FM_HOME="$home" "$SEARCH" 'nothing here says this at all' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a search that matched nothing must exit 1, got $rc"
  pass "the exit status states whether the search matched, not how a batch of it ended"
}

test_search_reports_scanner_failures_as_errors() {
  local home rc=0
  home=$(setup_fixture_home)
  FM_HOME="$home" "$SEARCH" '[' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed regex must be reported as a scanner error, got exit $rc"
  rc=0
  FM_HOME="$home" "$SEARCH" '[' --files-only >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed --files-only regex must be reported as a scanner error, got exit $rc"
  rc=0
  FM_HOME="$home" "$SEARCH" 'nothing here says this at all' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "an ordinary no-match must remain exit 1, got $rc"
  pass "scanner failures are errors while an ordinary no-match remains distinct"
}

test_search_without_its_tool_refuses_rather_than_finding_nothing() {
  local home out rc=0
  home=$(setup_fixture_home)
  out=$(FM_HOME="$home" FM_RG="$TMP/no-such-rg" "$SEARCH" 'tugboat host' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing search tool must be reported as such, got exit $rc"
  assert_contains "$out" 'not installed' 'the refusal must name the missing tool'
  case "$out" in
    *'tugboat host'*) fail 'a refused search must not look like a search that ran' ;;
  esac
  pass "a missing decompressing search tool refuses instead of reporting no matches"
}

# An archive built before compression carries a README that still promises plain
# grep. The rebuild must not overwrite what someone wrote there, and must not
# leave the stale command standing unremarked either.
test_refresh_names_a_readme_that_still_promises_plain_grep() {
  local home out tick='`'
  home=$(setup_fixture_home)
  printf 'captain notes\n\nPlain %sgrep -r%s works too - grep is the index.\n' \
    "$tick" "$tick" \
    >"$home/data/transcripts/README.md"
  out=$(FM_HOME="$home" FM_CLAUDE_SESSIONS="$TMP/home-src/claude" \
        FM_CODEX_SESSIONS="$TMP/home-src/codex" "$REFRESH" 2>&1 >/dev/null) \
    || fail 'refresh failed against an archive with an older README'
  assert_contains "$out" 'still points readers at plain' \
    'a README promising plain grep must be named as stale'
  assert_grep 'captain notes' "$home/data/transcripts/README.md" \
    'naming the stale sentence must not overwrite what someone wrote'
  pass "a rebuild names a README that still promises plain grep instead of silently keeping it"
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
test_the_store_is_written_compressed_and_leaves_nothing_plain
test_a_rebuild_compresses_a_retained_session_it_cannot_rebuild
test_verification_reads_the_compressed_store_it_verifies
test_verification_refuses_a_store_file_it_cannot_read
test_a_build_without_a_compressor_refuses_before_writing
test_refresh_without_a_compressor_leaves_no_archive
test_refresh_builds_verifies_and_lands_the_bound
test_refresh_does_not_overwrite_an_existing_readme
test_search_resolves_the_archive_from_fm_home
test_search_narrows_the_file_set_by_index
test_search_reports_a_missing_archive_rather_than_no_matches
test_search_reads_the_compressed_store
test_search_does_not_depend_on_ripgrep_implicit_decompression
test_search_reads_plain_sessions_during_migration
test_plain_grep_does_not_read_the_sessions
test_search_status_says_matched_or_not_matched
test_search_reports_scanner_failures_as_errors
test_search_without_its_tool_refuses_rather_than_finding_nothing
test_refresh_names_a_readme_that_still_promises_plain_grep
