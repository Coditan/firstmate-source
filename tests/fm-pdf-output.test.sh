#!/usr/bin/env bash
# Behavior tests for the PDF conformance gate (bin/fm-pdf-verify.sh) and the
# gated generation step (bin/fm-pdf-finish.sh).
#
# The defect these guard against shipped once already: a browser-printed
# handover PDF was assembled with poppler's `pdfunite`, whose trailer declared a
# cross-reference size that did not match the objects it wrote. It rendered
# correctly on screen and could not be opened by the recipient
# (docs/pdf-output.md).
#
# A gate is only worth its cost if it is proven in BOTH directions, so this
# suite asserts that a non-conforming file is refused, that a conforming file
# passes, and - the part that is easy to get wrong - that the gate refuses
# rather than passes whenever it could not actually perform the check.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-pdf-verify.sh"
FINISH="$ROOT/bin/fm-pdf-finish.sh"
fm_test_tmproot TMP_ROOT fm-pdf-output

# Ghostscript is this suite's only proof of the conformance gate, so CI must
# never report green without it. The portable-serial lane owns that: it installs
# Ghostscript, requires it, and passes --fail-on-gate-skip for this exact token,
# which turns the skip below into a lane failure. A developer run without
# Ghostscript skips.
command -v gs >/dev/null 2>&1 || { echo "skip: ghostscript not found"; exit 0; }

# --- one owner for the shared option surface --------------------------------

# Both scripts parse --pages and --quiet and resolve the reader the same way.
# They must do it through bin/fm-pdf-lib.sh rather than each carrying a copy,
# because two copies drift apart the first time only one gets corrected.
PDF_LIB="$ROOT/bin/fm-pdf-lib.sh"
assert_present "$PDF_LIB" "the shared PDF option library must exist"
assert_grep 'fm-pdf-lib.sh' "$VERIFY" "the gate must source the shared option library"
assert_grep 'fm-pdf-lib.sh' "$FINISH" "the generation step must source the shared option library"
pass "both PDF scripts share one option library"

# --- fixtures ---------------------------------------------------------------

# make_good <out.pdf> <pages> - a conforming PDF written by a conforming producer.
make_good() {
  local out=$1 pages=$2 ps="$TMP_ROOT/src-$2.ps" i
  : > "$ps"
  printf '/Helvetica findfont 24 scalefont setfont\n' >> "$ps"
  for ((i = 1; i <= pages; i++)); do
    printf '72 700 moveto (Page %d) show showpage\n' "$i" >> "$ps"
  done
  gs -dBATCH -dNOPAUSE -dQUIET -sDEVICE=pdfwrite -sOutputFile="$out" "$ps" >/dev/null 2>&1
}

# make_broken <good.pdf> <out.pdf> - reproduce the field defect exactly: a
# trailer whose /Size no longer matches the highest object number in the file
# (PDF 32000-1 section 7.5.5). The body is copied byte-for-byte with `head -c`
# and only the trailing ASCII trailer is rewritten, so no binary stream is
# disturbed and the fixture is deterministic without needing poppler.
make_broken() {
  local src=$1 out=$2 off
  off=$(grep -abo 'trailer' "$src" | tail -n 1 | cut -d: -f1)
  [ -n "$off" ] || fail "fixture: no trailer found in $src"
  head -c "$off" "$src" > "$out"
  tail -c "+$((off + 1))" "$src" | sed 's|/Size [0-9][0-9]*|/Size 3|' >> "$out"
}

GOOD="$TMP_ROOT/good.pdf"
BROKEN="$TMP_ROOT/broken.pdf"
make_good "$GOOD" 5 || fail "fixture: could not build a conforming PDF"
[ -s "$GOOD" ] || fail "fixture: conforming PDF is empty"
make_broken "$GOOD" "$BROKEN"

# --- direction 1: a non-conforming file is REFUSED --------------------------

out=$("$VERIFY" "$BROKEN" 2>&1); rc=$?
expect_code 1 "$rc" "a non-conforming PDF must be rejected"
assert_contains "$out" "REJECTED" "rejection must be stated plainly"
assert_contains "$out" "does not conform" "rejection must name the conformance failure"
pass "non-conforming PDF is rejected"

# --- direction 2: a conforming file PASSES ----------------------------------

out=$("$VERIFY" "$GOOD" 2>&1); rc=$?
expect_code 0 "$rc" "a conforming PDF must pass"
assert_contains "$out" "OK" "a passing file must be reported as OK"
assert_contains "$out" "5 pages" "the page count must come from the reader"
pass "conforming PDF passes"

# A gate that rejects everything is as useless as one that accepts everything:
# prove the pass is real by asserting the correct page count is accepted.
out=$("$VERIFY" --pages 5 "$GOOD" 2>&1); rc=$?
expect_code 0 "$rc" "a conforming PDF with the expected page count must pass"
pass "page-count assertion accepts the correct count"

out=$("$VERIFY" --pages 4 "$GOOD" 2>&1); rc=$?
expect_code 1 "$rc" "a wrong page count must be rejected"
assert_contains "$out" "expected 4" "a page-count mismatch must say what was expected"
pass "page-count assertion rejects a wrong count"

# --- fail closed: an unperformed check is never a pass ----------------------

out=$(FM_PDF_GS=fm-no-such-pdf-reader "$VERIFY" "$GOOD" 2>&1); rc=$?
expect_code 3 "$rc" "a missing PDF reader must not report success"
assert_contains "$out" "CANNOT VERIFY" "a missing reader must say the check did not happen"
assert_not_contains "$out" "OK $GOOD" "a missing reader must never print a pass"
pass "missing reader fails closed"

# A reader that runs but tells us nothing is the dangerous case: exit 0 with no
# diagnostics looks exactly like success. It must not be treated as one.
STUB_BIN="$TMP_ROOT/stub"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/gs"
chmod +x "$STUB_BIN/gs"
out=$(FM_PDF_GS="$STUB_BIN/gs" "$VERIFY" "$GOOD" 2>&1); rc=$?
expect_code 3 "$rc" "a silent reader must not report success"
assert_contains "$out" "CANNOT VERIFY" "a silent reader must say the check did not happen"
pass "silent reader fails closed"

# A reader that could not run is not a verdict on the document. Both refuse and
# nothing is published either way, so the only thing at stake is attribution:
# calling a broken, missing-library, OOM-killed or sandboxed reader a bad
# document sends someone to debug a file that was fine.
cat > "$STUB_BIN/gs" <<'STUB'
#!/bin/sh
echo "gs: error while loading shared libraries: libgs.so.10: cannot open shared object file" >&2
exit 127
STUB
out=$(FM_PDF_GS="$STUB_BIN/gs" "$VERIFY" "$GOOD" 2>&1); rc=$?
expect_code 3 "$rc" "a reader that could not run must not report success"
assert_contains "$out" "CANNOT VERIFY" "a reader that could not run must say the check did not happen"
assert_contains "$out" "error while loading shared libraries" "the reader's own message must be attributable"
assert_not_contains "$out" "REJECTED" "a broken reader must not be reported as a bad document"
pass "a reader that could not run fails closed as unverifiable"

# The other direction: a non-zero exit whose output DOES name a document problem
# is a verdict on the file and stays a rejection.
cat > "$STUB_BIN/gs" <<'STUB'
#!/bin/sh
echo "Processing pages 1 through 5."
echo "   **** This file had errors that were repaired or ignored."
exit 4
STUB
out=$(FM_PDF_GS="$STUB_BIN/gs" "$VERIFY" "$GOOD" 2>&1); rc=$?
expect_code 1 "$rc" "a reader that names a document problem must reject the file"
assert_contains "$out" "REJECTED" "a condemned document must be reported as rejected"
assert_not_contains "$out" "CANNOT VERIFY" "a condemned document must not be downgraded to unverifiable"
pass "a failing reader that names a document problem still rejects"

# Missing and empty inputs are rejected, not skipped.
out=$("$VERIFY" "$TMP_ROOT/does-not-exist.pdf" 2>&1); rc=$?
expect_code 1 "$rc" "a missing file must be rejected"
: > "$TMP_ROOT/empty.pdf"
out=$("$VERIFY" "$TMP_ROOT/empty.pdf" 2>&1); rc=$?
expect_code 1 "$rc" "an empty file must be rejected"
assert_contains "$out" "empty file" "an empty file must say so"
pass "missing and empty inputs are rejected"

# Damaged real files must be REFUSED, and nothing may be published from them.
# Which refusal class they land in is decided by the installed reader's own
# wording, and no Ghostscript version is pinned anywhere in this repo, so
# pinning the exact class here would fail on a correct gate the day the runner
# image moves. The stub cases above own the class distinction, because there the
# reader's output is controlled byte for byte.
#
# refuses_damaged <file> <label> - the gate refuses with a non-zero status and
# never prints a pass, and the damaged content cannot reach a destination that
# declares the length it was supposed to have.
refuses_damaged() {
  local file=$1 label=$2 dest="$TMP_ROOT/from-damaged.pdf" verdict rc
  verdict=$("$VERIFY" "$file" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$label must be refused, got exit 0"
  assert_not_contains "$verdict" "OK $file" "$label must never be reported as conforming"
  rm -f "$dest"
  "$FINISH" --pages 5 "$dest" "$file" >/dev/null 2>&1
  assert_absent "$dest" "$label must not publish a document of the declared length"
}

head -c 900 "$GOOD" > "$TMP_ROOT/truncated.pdf"
refuses_damaged "$TMP_ROOT/truncated.pdf" "a truncated file"
pass "a truncated file is refused and cannot ship as a full document"

printf 'this is not a PDF at all\n' > "$TMP_ROOT/not-a-pdf.pdf"
refuses_damaged "$TMP_ROOT/not-a-pdf.pdf" "a non-PDF file"
pass "a non-PDF file is refused and cannot ship as a full document"

# A batch is only as good as its worst file.
out=$("$VERIFY" "$GOOD" "$BROKEN" 2>&1); rc=$?
expect_code 1 "$rc" "a batch containing a bad file must fail"
pass "a batch fails when any file fails"

# --- the generation step publishes only what passes -------------------------

OUT="$TMP_ROOT/finished.pdf"
out=$("$FINISH" --pages 5 "$OUT" "$BROKEN" 2>&1); rc=$?
expect_code 0 "$rc" "finishing a broken input must produce a conforming document"
assert_present "$OUT" "the finished document must exist"
pass "the generation step repairs the field defect"

# Exit 0 means published, and the success line must come from the step that
# published rather than from a second reader pass whose status would leak into
# the caller's - which would report "nothing published" about a live file.
assert_contains "$out" "fm-pdf-finish: published $OUT" "publication must be announced by the publishing step"
assert_contains "$out" "5 pages" "the success line must carry the page count the reader counted"
pass "a published document reports success and exits 0"

# --quiet still publishes, still exits 0, and still says nothing on success.
QUIET_OUT="$TMP_ROOT/quiet.pdf"
out=$("$FINISH" --quiet --pages 5 "$QUIET_OUT" "$BROKEN" 2>&1); rc=$?
expect_code 0 "$rc" "--quiet must publish and exit 0"
[ -z "$out" ] || fail "--quiet must print nothing on success, got: $out"
assert_present "$QUIET_OUT" "--quiet must still publish the document"
pass "--quiet publishes silently and exits 0"

# And the repaired output really is conforming, checked independently.
out=$("$VERIFY" --pages 5 "$OUT" 2>&1); rc=$?
expect_code 0 "$rc" "the published document must pass the gate on its own"
pass "the published document is independently verified as conforming"

# Content is preserved, not truncated: the page count survives the repair. This
# is the guard against "fixing" a document by dropping what would not parse.
out=$("$VERIFY" "$OUT" 2>&1)
assert_contains "$out" "5 pages" "the repair must preserve every page"
pass "the repair preserves page count"

# Merging several parts is the real assembly case, and it must stay conforming.
MERGED="$TMP_ROOT/merged.pdf"
PART_A="$TMP_ROOT/part-a.pdf"
PART_B="$TMP_ROOT/part-b.pdf"
make_good "$PART_A" 2
make_good "$PART_B" 3
out=$("$FINISH" --pages 5 "$MERGED" "$PART_A" "$PART_B" 2>&1); rc=$?
expect_code 0 "$rc" "merging parts must produce a conforming document"
out=$("$VERIFY" --pages 5 "$MERGED" 2>&1); rc=$?
expect_code 0 "$rc" "the merged document must be conforming with all pages"
pass "multi-part assembly stays conforming"

# --- nothing non-conforming can reach the destination -----------------------

# The gate refuses (here via a page-count mismatch, the one rejection a caller
# can force deterministically), and the previous deliverable must survive
# untouched rather than being replaced by a file that failed.
KEEP="$TMP_ROOT/keep.pdf"
cp "$GOOD" "$KEEP"
before=$(cksum < "$KEEP")
out=$("$FINISH" --pages 99 "$KEEP" "$BROKEN" 2>&1); rc=$?
expect_code 1 "$rc" "a rejected result must fail the generation step"
assert_contains "$out" "nothing published" "a rejected result must say nothing was published"
after=$(cksum < "$KEEP")
[ "$before" = "$after" ] || fail "a rejected result must not overwrite the previous document"
pass "a rejected result never reaches the destination"

# A destination that did not exist must still not exist after a rejection.
NEVER="$TMP_ROOT/never.pdf"
"$FINISH" --pages 99 "$NEVER" "$BROKEN" >/dev/null 2>&1
assert_absent "$NEVER" "a rejected result must not create the destination"
pass "a rejected result creates no destination file"

# No temporary artifacts are left beside the destination.
leftovers=$(find "$TMP_ROOT" -maxdepth 1 -name '.fm-pdf-finish.*' -print -quit)
[ -z "$leftovers" ] || fail "the generation step left a temporary file behind: $leftovers"
pass "no temporary artifacts are left behind"

# When the gate itself cannot run, the step publishes nothing.
GATED="$TMP_ROOT/gated.pdf"
out=$(FM_PDF_GS=fm-no-such-pdf-reader "$FINISH" "$GATED" "$GOOD" 2>&1); rc=$?
expect_code 3 "$rc" "an unrunnable gate must not publish"
assert_absent "$GATED" "an unrunnable gate must not create the destination"
pass "an unrunnable gate publishes nothing"

# --- the original field defect, when poppler is available -------------------

if command -v pdfseparate >/dev/null 2>&1 && command -v pdfunite >/dev/null 2>&1; then
  SPLIT_DIR="$TMP_ROOT/split"
  mkdir -p "$SPLIT_DIR"
  if pdfseparate "$GOOD" "$SPLIT_DIR/p-%d.pdf" >/dev/null 2>&1 &&
     pdfunite "$SPLIT_DIR"/p-*.pdf "$TMP_ROOT/united.pdf" >/dev/null 2>&1; then
    out=$("$VERIFY" "$TMP_ROOT/united.pdf" 2>&1); rc=$?
    expect_code 1 "$rc" "the real pdfunite output must be rejected"
    pass "the original pdfunite defect is caught"

    out=$("$FINISH" --pages 5 "$TMP_ROOT/repaired.pdf" "$TMP_ROOT/united.pdf" 2>&1); rc=$?
    expect_code 0 "$rc" "the generation step must repair real pdfunite output"
    pass "the original pdfunite defect is repaired"
  else
    echo "ok - skip: poppler split/unite unavailable for the field-defect check"
  fi
else
  echo "ok - skip: poppler not found, field-defect check not run"
fi

echo "ok - fm-pdf-output"
