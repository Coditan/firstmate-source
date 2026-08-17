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
# WHAT THE BUILDER WRITES THAT A BODY NEVER DOES
# Three things are emitted here rather than left to a board body, because each
# one is wrong exactly when nobody notices it is wrong:
#
#   - THE VESSEL NAME, in the header of every board. It says whose board this
#     is, and it is a property of the BUILDER: a board this vessel writes about
#     another vessel's work still carries this vessel's name. It is read from
#     the one place a vessel's name is already recorded rather than typed into a
#     second one, and the build is REFUSED when it cannot be resolved, because a
#     nameless board is exactly the board the rule exists to prevent.
#   - THE MARK SET, the seven symbols Tally draws states with, defined once per
#     board and referenced with <use href="#fm-mk-...">.
#   - THE TALLY STRIP CONTAINER, emitted empty and hidden. board.js fills it
#     from the board's own question forms and owns the count of what has not
#     been sent back. A body that typed that number could type it wrong, and a
#     wrong count of what reached the captain is the defect the strip exists to
#     make visible.
#
# docs/board-layout.md names the components; the design language behind them is
# recorded there too.
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
# WHAT THE GUARD COVERS, exactly:
#   - static remote references in HTML subresource attributes (src, the data-src
#     lazy-load handoff to one, srcset, poster, action, formaction, background,
#     manifest, xlink:href, object data), including a tag whose attributes are
#     split across lines,
#   - a remote href on a subresource element: <link>, <base>, SVG <use>/<image>,
#   - CSS constructs inside a <style> element and inside a style attribute:
#     @import, and a remote url() or image-set(),
#   - an absolute remote URL inside <script>.
#
# WHAT IT DOES NOT COVER, stated rather than papered over:
#   - a URL assembled at runtime from fragments inside a script; this is a
#     textual scan and cannot follow code,
#   - the words @import and url() outside a CSS region, which are DELIBERATELY
#     read as prose: a board explaining this rule is not a board breaking it,
#   - a style attribute written in a form this extractor does not recognise; it
#     reads a double-quoted, single-quoted, or unquoted value, and is not a
#     general HTML tokenizer.
#
# It is a guard against the regression that actually happened, not a sandbox.
# tests/fm-board.test.sh pins both directions.
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
#   --subtitle <s>   one dim line beside the title (optional)
#   --footer <s>     one dim line at the bottom, for provenance (optional)
#   --vessel <n>     the building vessel's name for the header; see below
#   --lang <code>    document language (default: de)
#   --check <f>...   run the no-network guard over existing files and exit
#   --print-assets   print the paths of the versioned layout assets
#
# THE VESSEL NAME is resolved, in this order:
#   1. --vessel <n>
#   2. $FM_BOARD_VESSEL
#   3. the first word of $FM_BRIDGE_VESSEL
#   4. the first word of the first readable bridge-vessel record, trying
#      $FM_HOME/config/bridge-vessel and then $FM_ROOT/config/bridge-vessel
# The first letter of each word is capitalised for display and nothing else is
# changed, so `coditan` prints as `Coditan`. When none of the four resolves, the
# build is REFUSED rather than writing an unattributed board.
#
# The body fragment is inserted verbatim inside <div class="fm-wrap">, after the
# header and the tally strip container. It gets the components documented in
# docs/board-layout.md; it must not carry its own <style>, <script>, or <html>
# scaffolding, and it must not write the vessel name or the tally strip itself.
#
# Exit status: 0 on success, 1 on a guard refusal or a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
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

# resolve_vessel - print the building vessel's display name, or nothing.
#
# The fleet already records a vessel's name for Bridge, and that is the name the
# captain knows this seat by. Reading it here rather than adding a board-only
# literal keeps one name in one place: a second copy is a name that can disagree
# with itself, and a header whose whole job is to say whose board this is must
# not be the copy that drifted.
resolve_vessel() {
  local raw="" candidate
  if [ -n "${FM_BOARD_VESSEL:-}" ]; then
    raw=${FM_BOARD_VESSEL}
  elif [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
    raw=${FM_BRIDGE_VESSEL}
  else
    # TWO candidate files, not one, because the two are different places and
    # each covers the other's blind spot. A board built from a task worktree
    # runs the WORKTREE's copy of this script, and config/ is home-private and
    # gitignored, so FM_ROOT has no name there - only FM_HOME does. A board
    # built from the primary checkout with no FM_HOME in the environment has
    # the opposite problem. Resolving one path and reading only that one leaves
    # whichever case it did not pick unresolvable, and since an unresolvable
    # name is REFUSED below, that is not a missing header - it is a build that
    # stops. Measured on this seat: a board built from a task worktree.
    for candidate in "$FM_HOME/config/bridge-vessel" "$FM_ROOT/config/bridge-vessel"; do
      [ -r "$candidate" ] || continue
      IFS= read -r raw < "$candidate" || raw=""
      [ -z "${raw%%[[:space:]]*}" ] || break
    done
  fi
  # A multi-vessel Bridge configuration is a space-separated list, and the first
  # entry is this seat's own; the rest are inboxes it also watches.
  raw=${raw%%[[:space:]]*}
  [ -n "$raw" ] || return 0
  vessel_display "$raw"
}

# vessel_display - capitalise the first letter of each word, change nothing else.
#
# The recorded name is a lowercase slug because Bridge paths are, and the header
# is prose. This is a rendering rule and not a second spelling: an already
# capitalised name comes back unchanged.
vessel_display() {  # <raw>
  printf '%s' "$1" | awk '
    {
      n = split($0, parts, /-/)
      out = ""
      for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w != "") { w = toupper(substr(w, 1, 1)) substr(w, 2) }
        out = (i == 1) ? w : out "-" w
      }
      printf "%s", out
    }'
}

# mark_set - the seven marks Tally draws every state with, defined once.
#
# Referenced from anywhere on the board as <use href="#fm-mk-open">. Two of the
# seven - run and void - are drawn in ink and carry no hue at all, which is the
# language's own rule that under way, landed and failed are never coloured.
mark_set() {
  cat <<'SVG'
<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false">
<defs>
<symbol id="fm-mk-open" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"/></symbol>
<symbol id="fm-mk-pencil" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"/><path d="M4.6 15.4 L15.4 4.6" stroke="currentColor" stroke-width="1.4" stroke-dasharray="2.4 1.8" fill="none"/></symbol>
<symbol id="fm-mk-struck" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M4 16 L16 4" stroke="currentColor" stroke-width="2.4" fill="none"/></symbol>
<symbol id="fm-mk-gate" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"/><rect x="3.5" y="3.5" width="6.5" height="13" fill="currentColor"/></symbol>
<symbol id="fm-mk-held" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="10" cy="10" r="3.1" fill="currentColor"/></symbol>
<symbol id="fm-mk-run" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="4.5" y="8.8" width="11" height="2.4" fill="currentColor"/></symbol>
<symbol id="fm-mk-void" viewBox="0 0 20 20"><rect x="2.5" y="2.5" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.4 5.4 L14.6 14.6 M14.6 5.4 L5.4 14.6" stroke="currentColor" stroke-width="2" fill="none"/></symbol>
</defs>
</svg>
SVG
}

# fold_open_tags - print `<line-number>:<text>` with the newlines inside an
# unclosed tag folded away, so attribute formatting cannot change a verdict.
#
# grep only ever sees one PHYSICAL line, so a scan written against
# `<link rel=... href="https://...">` says nothing about the same tag with its
# attributes wrapped across lines - which is ordinary generated HTML.
#
# Only an unclosed tag folds here. A `<` opens one just when a tag name follows
# it immediately, so `i < notes.length` in an inlined script does not swallow the
# rest of the file. The `[^>]*` bound inside the patterns below still stops a
# match from crossing out of one tag into the next, and the folded text carries
# the line number the tag STARTED on so a refusal still points at the right
# place. CSS is not folded here: css_regions carries its own wrapped constructs,
# and one question answered by two mechanisms is how this drifted before.
fold_open_tags() {  # <file>
  awk '
    {
      if (held == 0) { start = NR; buf = $0 } else { buf = buf " " $0 }
      held++
      if (buf ~ /<[[:alpha:]!\/][^>]*$/ && held < 200) { next }
      print start ":" buf
      held = 0; buf = ""
    }
    END { if (held > 0) { print start ":" buf } }
  ' "$1"
}

# css_regions - print `<line-number>:<css>` for the CSS a browser executes.
#
# Whether an occurrence of `@import` is a rule or the word `@import` sitting in
# prose is a STRUCTURAL question, and it is answered structurally: CSS runs
# inside a <style> element and inside a style attribute, and nowhere else in an
# HTML document. So those two regions are extracted first and the CSS patterns
# are matched against nothing else. A board that EXPLAINS the rule in a
# paragraph, a list item, a heading, or a code comment is prose, and prose is
# never mistaken for the rule it names.
#
# Two liberties are safe INSIDE a region and would not be outside one. A
# `/* ... */` span is genuinely a comment, so comments are stripped before
# matching. And a construct left unfinished at a line end is genuinely
# unfinished, so a trailing `@import` or an unclosed `url(` joins the line that
# continues it.
css_regions() {  # reads the folded stream on stdin
  awk '
    function decomment(s,   out, p) {
      out = ""
      while (s != "") {
        if (incomment) {
          p = index(s, "*/")
          if (p == 0) { return out }
          s = substr(s, p + 2); incomment = 0
        } else {
          p = index(s, "/*")
          if (p == 0) { return out s }
          out = out substr(s, 1, p - 1)
          s = substr(s, p + 2); incomment = 1
        }
      }
      return out
    }

    function flush() {
      if (held > 0) { print start ":" buf }
      buf = ""; held = 0
    }

    function css_chunk(s, num) {
      s = decomment(s)
      if (s ~ /^[[:space:]]*$/) { return }
      if (held == 0) { start = num; buf = s } else { buf = buf " " s }
      held++
      if (held < 200 && (buf ~ /(url|image-set)\([^)]*$/ || buf ~ /@import[[:space:]]*$/)) { return }
      flush()
    }

    function style_attrs(s, num,   low, p, m, q, ch, r, val) {
      low = tolower(s); p = 1
      while (p <= length(s)) {
        m = match(substr(low, p), /[^-_[:alnum:]]style[[:space:]]*=[[:space:]]*/)
        if (m == 0) { return }
        q = p + m + RLENGTH - 1
        ch = substr(s, q, 1)
        if (ch == "\"" || ch == "\047") {
          r = index(substr(s, q + 1), ch)
          if (r == 0) { return }
          val = substr(s, q + 1, r - 1)
          p = q + r
        } else {
          r = match(substr(s, q), /[[:space:]>]/)
          if (r == 0) { val = substr(s, q); p = length(s) + 1 }
          else { val = substr(s, q, r - 1); p = q + r - 1 }
        }
        if (val != "") { print num ":" val }
      }
    }

    {
      at = index($0, ":"); num = substr($0, 1, at - 1); text = substr($0, at + 1)
      low = tolower(text); n = length(text); pos = 1
      while (pos <= n) {
        if (instyle) {
          e = index(substr(low, pos), "</style")
          if (e == 0) { css_chunk(substr(text, pos), num); pos = n + 1 }
          else {
            if (e > 1) { css_chunk(substr(text, pos, e - 1), num) }
            flush(); instyle = 0; incomment = 0
            pos = pos + e + 6
          }
        } else {
          s = index(substr(low, pos), "<style")
          if (s == 0) { style_attrs(substr(text, pos), num); pos = n + 1 }
          else {
            if (s > 1) { style_attrs(substr(text, pos, s - 1), num) }
            g = index(substr(text, pos + s - 1), ">")
            if (g == 0) { pos = n + 1 }
            else { instyle = 1; pos = pos + s + g - 1 }
          }
        }
      }
    }
    END { flush() }
  '
}

# scan_remote_refs - print one line per load-time remote reference found.
#
# Each pattern targets a reference the browser resolves by itself. `href` is
# refused only where it names a subresource (<link>, <base>, SVG <use>/<image>),
# never on <a>, so a board can and must still print full PR URLs.
scan_remote_refs() {  # <file>
  local file=$1 remote='(https?:)?//' folded css
  folded=$(fold_open_tags "$file")
  css=$(printf '%s\n' "$folded" | css_regions)

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
  # remote artwork arrive that way. Both are matched against the CSS regions
  # only, never against the rest of the document, so the guard cannot mistake a
  # board that names these constructs for one that uses them.
  if [ -n "$css" ]; then
    printf '%s\n' "$css" | grep -Ei "@import[[:space:]]*(url\(|[\"'])" \
      | sed 's/^/  @import rule (a board inlines its styling): /' || true
    printf '%s\n' "$css" \
      | grep -Ei "(url|image-set)\([[:space:]]*[\"']?${remote}" \
      | sed 's/^/  remote url() in CSS: /' || true
  fi

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
VESSEL=""
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
    --vessel) [ "$#" -gt 1 ] || die "--vessel needs a value"; VESSEL=$(vessel_display "$2"); shift 2 ;;
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

[ -n "$VESSEL" ] || VESSEL=$(resolve_vessel)
[ -n "$VESSEL" ] || die "cannot resolve the building vessel's name for the header.
Every board says whose board it is, so this is refused rather than written unattributed.
Set one of: --vessel <name>, FM_BOARD_VESSEL, FM_BRIDGE_VESSEL, $FM_HOME/config/bridge-vessel, or $FM_ROOT/config/bridge-vessel."

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
  printf '</style>\n</head>\n<body>\n'
  mark_set
  printf '<div class="fm-wrap">\n'
  printf '<header class="fm-issue">\n<div>\n'
  printf '<p class="fm-vessel">%s</p>\n' "$(html_escape "$VESSEL")"
  printf '<h1>%s</h1>\n' "$esc_title"
  printf '</div>\n'
  [ -z "$SUBTITLE" ] || printf '<p class="fm-sub">%s</p>\n' "$(html_escape "$SUBTITLE")"
  printf '</header>\n'
  # Emitted empty and hidden. board.js fills it from the board's own question
  # forms and owns the count; a board that asks nothing leaves it hidden.
  printf '<div class="fm-tally" hidden></div>\n'
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
