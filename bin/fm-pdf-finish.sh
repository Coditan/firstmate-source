#!/usr/bin/env bash
# Mandatory last step of any PDF generation path: produce the deliverable from
# one or more rendered parts, then refuse to publish it unless it passes the
# conformance gate.
#
# Why this exists rather than a merge command called by hand: browser-printed
# documents were being assembled with poppler's `pdfunite`, which writes a
# trailer whose declared cross-reference size does not match the objects it
# actually wrote. The result opens in some viewers and fails in others, and it
# looks perfect on screen right up to the moment the recipient cannot open it.
# docs/pdf-output.md carries the evidence and the exact diagnosis.
#
# The fix is at the source: Ghostscript's pdfwrite device rebuilds the document
# and emits a conforming cross-reference table, so it both merges the parts and
# normalizes them in one pass. Ghostscript is then run a second time, as a
# reader, to check the result - a producer's own claim about its output is not
# evidence, so the file is read back before it is trusted.
#
# Publication is atomic and gated: the work happens on a temporary file beside
# the destination and is moved into place only after bin/fm-pdf-verify.sh
# passes. A failed gate leaves any previous <out> untouched and creates no new
# one, so a non-conforming file has no path to a recipient.
#
# Usage: fm-pdf-finish.sh [--pages <n>] [--quiet] <out.pdf> <in.pdf> [<in.pdf>...]
#   --pages <n>  require the finished document to have exactly <n> pages; use it
#                whenever the expected length is known, so a silently dropped
#                page fails the gate instead of shipping.
#   --quiet      print nothing on success.
#
# Inputs are concatenated in the order given. Passing a single input is the
# normal "normalize one rendered file" case.
#
# Exit: 0 published; 1 the gate rejected the result (nothing published);
#       2 usage error; 3 the gate could not run (nothing published).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/fm-pdf-verify.sh"

usage() {
  cat >&2 <<'EOF'
Usage: fm-pdf-finish.sh [--pages <n>] [--quiet] <out.pdf> <in.pdf> [<in.pdf>...]

Merge and normalize the input PDFs into <out.pdf> through a conforming
producer, verify the result with a real PDF reader, and publish it only if the
verification passes.

  --pages <n>  require exactly <n> pages in the finished document
  --quiet      suppress the success line

Exit codes: 0 published, 1 rejected, 2 usage, 3 could not verify.
EOF
}

EXPECT_PAGES=""
QUIET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pages)
      [ "$#" -ge 2 ] || { echo "fm-pdf-finish: --pages needs a value" >&2; usage; exit 2; }
      EXPECT_PAGES=$2
      case "$EXPECT_PAGES" in
        ''|*[!0-9]*) echo "fm-pdf-finish: --pages must be a positive integer, got '$EXPECT_PAGES'" >&2; exit 2 ;;
      esac
      [ "$EXPECT_PAGES" -gt 0 ] || { echo "fm-pdf-finish: --pages must be a positive integer" >&2; exit 2; }
      shift 2
      ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "fm-pdf-finish: unknown option '$1'" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done

[ "$#" -ge 2 ] || { usage; exit 2; }

OUT=$1
shift

for src in "$@"; do
  [ -f "$src" ] || { echo "fm-pdf-finish: input not found: $src" >&2; exit 2; }
  [ -s "$src" ] || { echo "fm-pdf-finish: input is empty: $src" >&2; exit 2; }
done

[ -x "$VERIFY" ] || { echo "fm-pdf-finish: CANNOT VERIFY - gate script missing at $VERIFY" >&2; exit 3; }

GS_BIN=${FM_PDF_GS:-gs}
command -v "$GS_BIN" >/dev/null 2>&1 || {
  echo "fm-pdf-finish: no PDF producer found (looked for '$GS_BIN'; install ghostscript)" >&2
  exit 3
}

OUT_DIR=$(dirname "$OUT")
[ -d "$OUT_DIR" ] || { echo "fm-pdf-finish: output directory does not exist: $OUT_DIR" >&2; exit 2; }

# The template ends at the X's: BSD/macOS mktemp rejects a suffix after them.
# The producer and the gate both go by content, not by file extension.
TMP_OUT=$(mktemp "$OUT_DIR/.fm-pdf-finish.XXXXXX") || {
  echo "fm-pdf-finish: could not create a temporary file in $OUT_DIR" >&2
  exit 3
}
trap 'rm -f "$TMP_OUT"' EXIT

# Absolute input paths: Ghostscript reads a leading `-` as an option.
ABS_INPUTS=()
for src in "$@"; do
  case "$src" in
    /*) ABS_INPUTS+=("$src") ;;
    *) ABS_INPUTS+=("$PWD/$src") ;;
  esac
done

# /prepress keeps images and fonts at delivery quality; the size reduction this
# step produces comes from rebuilding the document, not from discarding content.
if ! gs_out=$("$GS_BIN" \
    -dBATCH -dNOPAUSE -dQUIET -dSAFER \
    -sDEVICE=pdfwrite \
    -dPDFSETTINGS=/prepress \
    -dCompatibilityLevel=1.7 \
    -dEmbedAllFonts=true \
    -dSubsetFonts=true \
    -dDetectDuplicateImages=true \
    -sOutputFile="$TMP_OUT" \
    "${ABS_INPUTS[@]}" 2>&1); then
  echo "fm-pdf-finish: the PDF producer failed - nothing published" >&2
  printf '%s\n' "$gs_out" >&2
  exit 1
fi

VERIFY_ARGS=()
[ -n "$EXPECT_PAGES" ] && VERIFY_ARGS+=(--pages "$EXPECT_PAGES")
VERIFY_ARGS+=(--quiet)

"$VERIFY" "${VERIFY_ARGS[@]}" "$TMP_OUT"
verdict=$?

if [ "$verdict" -ne 0 ]; then
  # The gate refused, so nothing reaches <out>. A previous <out> stays as it was.
  if [ "$verdict" -eq 3 ]; then
    echo "fm-pdf-finish: CANNOT VERIFY the finished document - nothing published to $OUT" >&2
  else
    echo "fm-pdf-finish: the finished document was rejected - nothing published to $OUT" >&2
  fi
  exit "$verdict"
fi

mv -f "$TMP_OUT" "$OUT" || {
  echo "fm-pdf-finish: could not publish to $OUT" >&2
  exit 3
}
trap - EXIT

chmod 644 "$OUT" 2>/dev/null || true

if [ "$QUIET" -eq 0 ]; then
  "$VERIFY" "$OUT"
fi
