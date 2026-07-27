#!/usr/bin/env bash
# fm-pdf-lib.sh - single owner of the option surface the PDF scripts share.
#
# bin/fm-pdf-verify.sh and bin/fm-pdf-finish.sh accept the same --pages and
# --quiet options with the same integer validation, and both resolve the same
# Ghostscript binary through FM_PDF_GS. Two copies of that drift apart the first
# time only one of them is corrected, so the parsing lives here and both scripts
# source it. Each script keeps its own usage text, its own message prefix, and
# its own exit codes, because their contracts and their audiences differ.
#
# No side effects on source. set -u safe.

FM_PDF_EXPECT_PAGES=""
FM_PDF_QUIET=0
FM_PDF_ARGV=()

# fm_pdf_gs_bin - the Ghostscript binary this repo drives, honoring FM_PDF_GS.
fm_pdf_gs_bin() {
  printf '%s\n' "${FM_PDF_GS:-gs}"
}

# fm_pdf_parse_options <prefix> <usage-fn> "$@" - parse the shared options.
#
# Sets FM_PDF_EXPECT_PAGES, FM_PDF_QUIET, and FM_PDF_ARGV to the operands that
# follow the options. Returns 0 to continue, 2 on a usage error the caller must
# exit with, and 10 when --help was handled and the caller should exit 0.
# shellcheck disable=SC2034 # The three globals are read by the sourcing script.
fm_pdf_parse_options() {
  local prefix=$1 usage_fn=$2
  shift 2
  FM_PDF_EXPECT_PAGES=""
  FM_PDF_QUIET=0
  FM_PDF_ARGV=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pages)
        [ "$#" -ge 2 ] || { echo "$prefix: --pages needs a value" >&2; "$usage_fn"; return 2; }
        FM_PDF_EXPECT_PAGES=$2
        case "$FM_PDF_EXPECT_PAGES" in
          ''|*[!0-9]*)
            echo "$prefix: --pages must be a positive integer, got '$FM_PDF_EXPECT_PAGES'" >&2
            return 2
            ;;
        esac
        [ "$FM_PDF_EXPECT_PAGES" -gt 0 ] || {
          echo "$prefix: --pages must be a positive integer" >&2
          return 2
        }
        shift 2
        ;;
      --quiet) FM_PDF_QUIET=1; shift ;;
      -h|--help) "$usage_fn"; return 10 ;;
      --) shift; break ;;
      -*) echo "$prefix: unknown option '$1'" >&2; "$usage_fn"; return 2 ;;
      *) break ;;
    esac
  done
  FM_PDF_ARGV=("$@")
  return 0
}
