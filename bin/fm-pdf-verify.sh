#!/usr/bin/env bash
# Conformance gate for generated PDFs: refuse a file that a real PDF reader
# cannot read as a spec-conforming document.
#
# It exists because a browser-printed handover PDF reached the captain unusable
# while looking correct on screen (docs/pdf-output.md). Screen fidelity is not
# evidence of a readable file, so every generated PDF passes through here before
# it is delivered. bin/fm-pdf-finish.sh wires this in as the mandatory last step
# of generation; call this directly only to audit a file that already exists.
#
# The reader is Ghostscript, which interprets every page rather than only
# reading the trailer, so a structurally broken document is caught even when the
# page tree looks intact.
#
# THE EXIT CODE OF THE READER IS NOT THE VERDICT. Ghostscript exits 0 on a file
# it reports as non-conforming, and `-q` suppresses the report while still
# exiting 0, so an exit-code check here would silently wave through exactly the
# defect this gate exists to catch. The verdict comes from the reader's
# diagnostics, and this script fails closed in both directions: it refuses when
# the reader reports a problem, and it equally refuses when the reader is
# missing, errors out, or prints output this script does not recognize. A gate
# that passes when it could not actually check reads like an assurance and is
# not one.
#
# The two refusals are told apart on purpose. REJECTED means the reader's output
# positively named a document problem. CANNOT VERIFY means the check did not
# happen - no reader, a reader that could not run, or a reader that said nothing
# recognizable - and it carries the reader's own message so the failure is
# attributable. Nothing is published either way, so the only thing at stake is
# whose fault it is: calling a broken, missing-library, OOM-killed or sandboxed
# reader a bad document sends someone to debug a file that was fine.
#
# Usage: fm-pdf-verify.sh [--pages <n>] [--quiet] <pdf> [<pdf>...]
#   --pages <n>  also require every file to have exactly <n> pages, counted by
#                the reader itself, so a generation path cannot quietly drop or
#                duplicate content while staying conforming.
#   --quiet      print nothing on success; failures always print.
#
# Exit: 0 every file conforms; 1 a file was rejected; 2 usage error;
#       3 verification could not be performed (treat as a failure, not a pass).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDF_LIB="$SCRIPT_DIR/fm-pdf-lib.sh"
# shellcheck source=bin/fm-pdf-lib.sh
# shellcheck disable=SC1091
. "$PDF_LIB" || {
  echo "fm-pdf-verify: CANNOT VERIFY - helper library missing at $PDF_LIB" >&2
  exit 3
}

usage() {
  cat >&2 <<'EOF'
Usage: fm-pdf-verify.sh [--pages <n>] [--quiet] <pdf> [<pdf>...]

Verify that each PDF is readable and spec-conforming, using Ghostscript as a
real PDF reader that interprets every page.

  --pages <n>  require exactly <n> pages in every file
  --quiet      suppress the per-file success line

Exit codes: 0 all conform, 1 rejected, 2 usage, 3 could not verify.
EOF
}

fm_pdf_parse_options fm-pdf-verify usage "$@"
parse_rc=$?
case "$parse_rc" in
  0) ;;
  10) exit 0 ;;
  *) exit "$parse_rc" ;;
esac
set -- "${FM_PDF_ARGV[@]+"${FM_PDF_ARGV[@]}"}"
EXPECT_PAGES=$FM_PDF_EXPECT_PAGES
QUIET=$FM_PDF_QUIET

[ "$#" -ge 1 ] || { usage; exit 2; }

GS_BIN=$(fm_pdf_gs_bin)
if ! command -v "$GS_BIN" >/dev/null 2>&1; then
  # Fail closed: with no reader there is no verdict, and "unverified" must never
  # be reported as "conforming".
  echo "fm-pdf-verify: CANNOT VERIFY - no PDF reader found (looked for '$GS_BIN'; install ghostscript)" >&2
  exit 3
fi

# One rejection reason per file, printed by the caller loop.
REASON=""

# read_pdf <file> - interpret every page and echo the reader's combined output.
# Deliberately runs without -q so the conformance diagnostics survive, and with
# -dSAFER like the producer in bin/fm-pdf-finish.sh, because this script is also
# pointed at files this repo did not make and the reader interprets whatever it
# is handed. -dSAFER does not change the diagnostics the verdict is taken from.
# Ghostscript reads a leading `-` as an option and `--` as "run this file as a
# program", so the path is always passed absolute and never bare.
read_pdf() {
  local abs=$1
  case "$abs" in
    /*) : ;;
    *) abs="$PWD/$abs" ;;
  esac
  "$GS_BIN" -o /dev/null -sDEVICE=nullpage -dNOPAUSE -dBATCH -dSAFER "$abs" 2>&1
}

# check_file <file> - 0 conforming, 1 rejected (REASON set), 3 unverifiable.
check_file() {
  local file=$1 out rc pages last_page complaint

  if [ ! -f "$file" ]; then
    REASON="not a file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    REASON="not readable"
    return 1
  fi
  if [ ! -s "$file" ]; then
    REASON="empty file"
    return 1
  fi

  out=$(read_pdf "$file")
  rc=$?

  # The reader's own complaint comes first - before its exit status and before
  # any proof-of-work check - so that a file the reader positively condemned is
  # reported as rejected rather than as merely unverifiable. A badly truncated
  # file, for instance, draws the banner without ever reaching a page report,
  # and it is a bad file, not an unchecked one. Ghostscript prints this banner
  # while still exiting 0; `****` prefixes its error and repair notices.
  case "$out" in
    *"does not conform"*)
      REASON="does not conform to the PDF specification"
      printf '%s\n' "$out" >&2
      return 1
      ;;
    *"had errors that were repaired or ignored"*)
      REASON="contains errors the reader had to repair or ignore"
      printf '%s\n' "$out" >&2
      return 1
      ;;
    *"were encountered at least once"*)
      REASON="the PDF reader raised structural errors or warnings"
      printf '%s\n' "$out" >&2
      return 1
      ;;
    *"Unrecoverable error"*|*"**** Error"*)
      REASON="the PDF reader hit an unrecoverable error"
      printf '%s\n' "$out" >&2
      return 1
      ;;
  esac

  # Only the reader's output condemns a document. A non-zero exit that named no
  # document problem is a reader that could not run - a missing library, an OOM
  # kill, a sandbox denial - so it is reported as an unperformed check with the
  # reader's own message attached, not as a bad file. It still fails closed.
  if [ "$rc" -ne 0 ]; then
    complaint=$(printf '%s\n' "$out" | awk 'NF { print; exit }')
    REASON="the PDF reader failed (exit $rc) without naming a document problem: ${complaint:-no output}"
    printf '%s\n' "$out" >&2
    return 3
  fi

  # Proof of work. The reader announces its page range before interpreting, so
  # its absence - with no complaint either - means the tool did not do what this
  # gate assumes it did: a changed, wrapped, or stubbed reader. Refuse rather
  # than infer success from silence.
  pages=$(printf '%s\n' "$out" \
    | sed -n 's/^[Pp]rocessing pages [0-9][0-9]* through \([0-9][0-9]*\).*$/\1/p' \
    | tail -n 1)
  if [ -z "$pages" ]; then
    REASON="the PDF reader produced no recognizable page report - cannot verify"
    printf '%s\n' "$out" >&2
    return 3
  fi

  # And proof it reached the end: the last page must actually have been
  # interpreted, not just announced.
  last_page=$(printf '%s\n' "$out" | grep -c "^Page ${pages}[[:space:]]*$")
  if [ "$last_page" -eq 0 ]; then
    REASON="the PDF reader stopped before page $pages - document truncated or corrupt"
    printf '%s\n' "$out" >&2
    return 1
  fi

  if [ -n "$EXPECT_PAGES" ] && [ "$pages" != "$EXPECT_PAGES" ]; then
    REASON="has $pages pages, expected $EXPECT_PAGES"
    return 1
  fi

  VERIFIED_PAGES=$pages
  return 0
}

VERIFIED_PAGES=""
status=0

for file in "$@"; do
  REASON=""
  VERIFIED_PAGES=""
  if check_file "$file"; then
    [ "$QUIET" -eq 1 ] || echo "fm-pdf-verify: OK $file ($VERIFIED_PAGES pages, conforming)"
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "fm-pdf-verify: CANNOT VERIFY $file - $REASON" >&2
      [ "$status" -eq 0 ] && status=3
    else
      echo "fm-pdf-verify: REJECTED $file - $REASON" >&2
      status=1
    fi
  fi
done

exit "$status"
