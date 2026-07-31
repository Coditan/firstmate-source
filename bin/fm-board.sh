#!/usr/bin/env bash
# fm-board.sh - build a Firstmate review board on the shared standard layout.
#
# WHY THIS EXISTS
# Every board used to carry its own hand-written layout, so the layout drifted
# and the Lavish-recommended CDN snippet kept coming back with it. Eleven of the
# twelve boards under .lavish/ on 2026-07-31 pulled three files from
# cdn.jsdelivr.net, including @tailwindcss/browser - a runtime that recompiles
# the CSS in the reader's browser on every open. That is a measured load cost,
# not a matter of taste, and the captain asked for it to stop.
#
# So the layout became one versioned artifact that a generator INCLUDES:
#   bin/board-assets/layout.css   styling      (one owner)
#   bin/board-assets/board.js     behavior     (one owner)
# This script inlines both into the emitted board. Inlining rather than linking
# siblings is deliberate: a board must render when opened straight from disk with
# no Lavish server, and `lavish-axi export` must keep producing one portable
# file. A self-contained board satisfies both without any copying step.
#
# THE GUARD
# The no-network rule is enforced HERE, at the only choke point every board
# passes through, because a rule that lives in prose is the rule that regressed.
# A board whose body reaches out to the network is REFUSED and not written, so a
# regression fails loudly at generation instead of quietly costing load time in
# the captain's browser. `--check` runs the same guard against an existing file.
#
# Navigational links are NOT network requests: <a href="https://..."> is allowed
# and must stay allowed, because AGENTS.md section 9 requires boards to carry
# full PR URLs. What is refused is anything the browser FETCHES on load - a
# stylesheet, script, font, image, iframe, or a form that posts outward.
#
# Known limits of the guard, stated rather than papered over: it is a textual
# scan, so a remote URL assembled at runtime from fragments inside a script is
# not detected. It refuses the whole documented class of static remote
# references, which is the regression that actually happened; it is not a
# sandbox. tests/fm-board.test.sh pins the refusals.
#
# Usage:
#   fm-board.sh --title <title> --body <file|-> --out <path> [options]
#   fm-board.sh --check <html-file>...
#   fm-board.sh --print-assets
#   fm-board.sh -h | --help
#
# Options:
#   --title <t>      board title; used for <title> and the <h1>
#   --body <f>       HTML fragment for the board body, or - for stdin
#   --out <p>        file to write; refused if the composed board fails the guard
#   --subtitle <s>   one dim line under the title (optional)
#   --footer <s>     one dim line at the bottom, for provenance (optional)
#   --lang <code>    document language (default: de)
#   --check <f>...   run the no-network guard over existing files and exit
#   --print-assets   print the paths of the versioned layout assets
#
# The body fragment is inserted verbatim inside <div class="fm-wrap">. It gets
# the components documented in docs/board-layout.md; it must not carry its own
# <style>, <script>, or <html> scaffolding.
#
# Exit status: 0 on success, 1 on a guard refusal or a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/board-assets"
CSS="$ASSETS/layout.css"
JS="$ASSETS/board.js"

die() {
  printf 'fm-board.sh: %s\n' "$1" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^# ?/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# html_escape - escape text destined for HTML text or a quoted attribute.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# fold_open_constructs - print `<line-number>:<text>`, one logical construct per
# line, with newlines inside an unfinished tag, url(), or @import folded away.
#
# grep only ever sees one PHYSICAL line, so a scan written against
# `<link rel=... href="https://...">` says nothing about the same tag with its
# attributes wrapped across lines - which is ordinary generated HTML. Folding
# first makes attribute formatting irrelevant to the verdict.
#
# A `<` only opens a construct when a tag name follows it immediately, so
# `i < notes.length` in an inlined script does not swallow the rest of the file.
# The `[^>]*` bound inside the patterns below still stops a match from crossing
# out of one tag into the next, and the folded text carries the line number the
# construct STARTED on so a refusal still points at the right place.
fold_open_constructs() {  # <file>
  awk '
    function unfinished(s) {
      return (s ~ /<[[:alpha:]!\/][^>]*$/) || (s ~ /url\([^)]*$/) || (s ~ /@import[[:space:]]*$/)
    }
    {
      if (held == 0) { start = NR; buf = $0 } else { buf = buf " " $0 }
      held++
      if (unfinished(buf) && held < 200) { next }
      print start ":" buf
      held = 0; buf = ""
    }
    END { if (held > 0) { print start ":" buf } }
  ' "$1"
}

# scan_remote_refs - print one line per load-time remote reference found.
#
# Each pattern targets a reference the browser resolves by itself. `href` is
# refused only where it names a subresource (<link>, <base>, SVG <use>/<image>),
# never on <a>, so a board can and must still print full PR URLs.
scan_remote_refs() {  # <file>
  local file=$1 remote='(https?:)?//' folded
  folded=$(fold_open_constructs "$file")

  # Subresource attributes: the browser fetches these without any user action.
  # `data` carries a leading space so it matches <object data="..."> and not the
  # tail of an unrelated attribute name.
  printf '%s\n' "$folded" \
    | grep -Ei "(src|srcset|poster|data-src|action|formaction|background|manifest|xlink:href|[[:space:]]data)[[:space:]]*=[[:space:]]*[\"']?${remote}" \
    | sed 's/^/  remote subresource attribute: /' || true

  # <link>, <base>, and SVG <use>/<image> use href for a subresource.
  printf '%s\n' "$folded" \
    | grep -Ei "<(link|base|use|image)[^>]*href[[:space:]]*=[[:space:]]*[\"']?${remote}" \
    | sed 's/^/  remote href on a subresource element: /' || true

  # CSS: an @import rule, and any remote url() or image-set() - webfonts and
  # remote artwork arrive that way. @import is matched as real CSS syntax
  # (@import url(...) or @import "...") rather than on the bare word, so a board
  # that DISCUSSES this rule in prose or in a comment is not refused for saying
  # its name.
  printf '%s\n' "$folded" | grep -Ei "@import[[:space:]]*(url\(|[\"'])" \
    | sed 's/^/  @import rule (a board inlines its styling): /' || true
  printf '%s\n' "$folded" \
    | grep -Ei "(url|image-set|-webkit-image-set)\([[:space:]]*[\"']?${remote}" \
    | sed 's/^/  remote url() in CSS: /' || true

  # Absolute remote URLs inside script. Protocol-relative // is not matched here
  # because // opens a comment in JavaScript.
  printf '%s\n' "$folded" | awk '
    { at = index($0, ":"); num = substr($0, 1, at - 1); text = substr($0, at + 1) }
    /<script/ { inscript = 1 }
    inscript && text ~ /https?:\/\// { printf "  remote URL inside <script>: %s:%s\n", num, text }
    /<\/script>/ { inscript = 0 }
  ' || true
}

# guard - refuse a board that would reach the network on load.
guard() {  # <file> <label>
  local file=$1 label=$2 findings
  findings=$(scan_remote_refs "$file")
  if [ -n "$findings" ]; then
    printf 'fm-board.sh: REFUSED - %s makes external network requests.\n' "$label" >&2
    printf 'A board must be self-contained: inline the asset or drop it.\n' >&2
    printf '%s\n' "$findings" >&2
    return 1
  fi
  return 0
}

TITLE=""
BODY=""
OUT=""
SUBTITLE=""
FOOTER=""
LANG_CODE="de"
MODE="build"
CHECK_FILES=()

[ "$#" -gt 0 ] || { usage; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --print-assets) printf '%s\n%s\n' "$CSS" "$JS"; exit 0 ;;
    --check)
      MODE="check"
      shift
      [ "$#" -gt 0 ] || die "--check needs at least one file"
      while [ "$#" -gt 0 ]; do CHECK_FILES+=("$1"); shift; done
      ;;
    --title) [ "$#" -gt 1 ] || die "--title needs a value"; TITLE=$2; shift 2 ;;
    --body) [ "$#" -gt 1 ] || die "--body needs a value"; BODY=$2; shift 2 ;;
    --out) [ "$#" -gt 1 ] || die "--out needs a value"; OUT=$2; shift 2 ;;
    --subtitle) [ "$#" -gt 1 ] || die "--subtitle needs a value"; SUBTITLE=$2; shift 2 ;;
    --footer) [ "$#" -gt 1 ] || die "--footer needs a value"; FOOTER=$2; shift 2 ;;
    --lang) [ "$#" -gt 1 ] || die "--lang needs a value"; LANG_CODE=$2; shift 2 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

if [ "$MODE" = "check" ]; then
  status=0
  for f in "${CHECK_FILES[@]}"; do
    [ -f "$f" ] || die "no such file: $f"
    if guard "$f" "$f"; then
      printf '%s: no external network requests\n' "$f"
    else
      status=1
    fi
  done
  exit "$status"
fi

[ -n "$TITLE" ] || die "--title is required"
[ -n "$BODY" ] || die "--body is required"
[ -n "$OUT" ] || die "--out is required"
[ -f "$CSS" ] || die "missing layout asset: $CSS"
[ -f "$JS" ] || die "missing behavior asset: $JS"

BODY_FILE=$BODY
TMP_BODY=""
if [ "$BODY" = "-" ]; then
  TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/fm-board-body.XXXXXX")
  cat > "$TMP_BODY"
  BODY_FILE=$TMP_BODY
fi
[ -f "$BODY_FILE" ] || die "no such body fragment: $BODY_FILE"

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-board.XXXXXX")
cleanup() {
  rm -f "$TMP_OUT"
  [ -z "$TMP_BODY" ] || rm -f "$TMP_BODY"
}
trap cleanup EXIT

esc_title=$(html_escape "$TITLE")

{
  printf '<!doctype html>\n'
  printf '<html lang="%s">\n<head>\n' "$(html_escape "$LANG_CODE")"
  printf '<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
  printf '<title>%s</title>\n' "$esc_title"
  printf '<style>\n'
  cat "$CSS"
  printf '</style>\n</head>\n<body>\n<div class="fm-wrap">\n'
  printf '<h1>%s</h1>\n' "$esc_title"
  [ -z "$SUBTITLE" ] || printf '<p class="fm-sub">%s</p>\n' "$(html_escape "$SUBTITLE")"
  cat "$BODY_FILE"
  [ -z "$FOOTER" ] || printf '\n<div class="fm-foot">%s</div>\n' "$(html_escape "$FOOTER")"
  printf '</div>\n<script>\n'
  cat "$JS"
  printf '</script>\n</body>\n</html>\n'
} > "$TMP_OUT"

# Guard the COMPOSED board, not just the body: this is the last point at which a
# remote reference can still be stopped before it reaches the captain.
guard "$TMP_OUT" "the composed board" || exit 1

outdir=$(dirname "$OUT")
[ -d "$outdir" ] || mkdir -p "$outdir"
cp "$TMP_OUT" "$OUT"
printf '%s\n' "$OUT"
