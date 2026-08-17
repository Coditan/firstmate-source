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
# THE VESSEL MARK
# Every board carries the name of the vessel that BUILT it, so the captain can
# see at a glance whose board he is reading. It is emitted here rather than
# written by each board body, so a board cannot be built without it.
#
# The name is resolved, never hard-coded, along the same path every other
# script in this repo uses for it: --vessel, then FM_BOARD_VESSEL, then
# FM_BRIDGE_VESSEL, then config/bridge-vessel (first field of the first line)
# under FM_HOME, FM_ROOT_OVERRIDE, and this script's own root, in that order.
#
# All three file locations are tried rather than one resolved location, because
# they cover each other's blind spots: a board built from a task worktree runs
# the worktree's copy of this script and config/ is home-private and gitignored,
# so only FM_HOME carries the name there; a board built from the primary
# checkout with no FM_HOME set has only the script root. The first real board on
# this layout shipped unmarked for exactly that reason.
#
# If none of those yields a name, the mark is omitted and a warning naming every
# file that was looked for goes to stderr - a missing config file must not stop
# the captain's decisions from reaching him over a nameplate, and the warning is
# loud so the gap gets closed rather than lived with.
#
# It marks WHO BUILT the board, not what it is about: a board this vessel
# builds concerning another vessel's work still carries this vessel's name.
#
# THE DECISION GUARD
# A board that asks the captain to decide must offer him something to CLICK.
# The rule exists because it was broken: a board carrying seven decisions put
# every option in prose with no control anywhere, so the answers had to come
# back through chat - the one channel this fleet has measured as having no
# memory. A decision on a board gets answered; a decision in chat gets lost.
#
# So the same choke point that refuses a board reaching the network also
# refuses a malformed decision, and it refuses on STRUCTURE the board itself
# declares rather than on a reading of its prose:
#
#   - every `<form data-fm-question=...>` must carry at least two radio
#     options, a `data-fm-note` field, and a `.fm-queued` box,
#   - `--kind decision` must carry at least one such form.
#
# Both tests fire only on something the board declared about itself, so
# neither can misfire on a report that merely DISCUSSES a decision. What is
# deliberately NOT attempted is detecting a decision posed in prose: no textual
# test can separate "here is a question for you" from a report describing one,
# and a guard that misfires would be worked around rather than fixed. That gap
# is covered by declaration instead - the /decisionboard skill passes
# --kind decision - and it is stated in docs/board-layout.md rather than
# papered over.
#
# The decision guard reads the BODY FRAGMENT, not the composed board: board.js
# carries the component's markup in its own header comment, and a scan of the
# composed file could not tell that documentation from a real form. This is the
# same distinction css_regions draws for @import, answered the same way.
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
#   --kind <k>       report (default) or decision; decision requires a control
#   --vessel <n>     override the vessel name shown in the header
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
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Where the vessel name may be recorded, in order. TWO candidates, not one,
# because the two are genuinely different places and each covers the other's
# blind spot. A board built from a task worktree runs the worktree's own copy of
# this script, and config/ is home-private and gitignored, so the script root
# has no name there - only FM_HOME does. A board built from the primary checkout
# with no FM_HOME in the environment has the opposite problem. Collapsing them
# into one candidate leaves whichever case the fallback did not pick unmarked,
# which is how the first real board on this layout shipped without its mark.
VESSEL_FILES=()
[ -z "${FM_HOME:-}" ] || VESSEL_FILES+=("$FM_HOME/config/bridge-vessel")
[ -z "${FM_ROOT_OVERRIDE:-}" ] || VESSEL_FILES+=("$FM_ROOT_OVERRIDE/config/bridge-vessel")
VESSEL_FILES+=("$SCRIPT_ROOT/config/bridge-vessel")

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

# resolve_vessel - print the name of the vessel building this board, or nothing.
#
# The name is READ, never written here: config/bridge-vessel is the one place
# this vessel's name is recorded, and a second copy would be a second thing to
# keep in step. The env names are the ones the rest of bin/ already honours.
resolve_vessel() {
  if [ -n "${FM_BOARD_VESSEL:-}" ]; then
    printf '%s\n' "${FM_BOARD_VESSEL%% *}"
    return 0
  fi
  if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
    printf '%s\n' "${FM_BRIDGE_VESSEL%% *}"
    return 0
  fi
  local file line
  for file in "${VESSEL_FILES[@]}"; do
    [ -f "$file" ] || continue
    line=""
    IFS= read -r line < "$file" || line=""
    line=${line%%[![:print:]]*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%% *}
    [ -z "$line" ] || { printf '%s\n' "$line"; return 0; }
  done
  return 0
}

# scan_decision_defects - print one line per malformed declared question.
#
# Reads the BODY FRAGMENT with its newlines flattened, so a form whose markup is
# wrapped across lines reads exactly like a one-line one. Every test below fires
# only on a form the body itself marked with data-fm-question, so a report that
# merely writes about a decision is never mistaken for one that poses it.
scan_decision_defects() {  # <body-file> <kind>
  tr '\n' ' ' < "$1" | awk -v kind="$2" '
    function unquote(s,   sq) {
      sq = sprintf("%c", 39)
      gsub(/"/, "", s)
      gsub(sq, "", s)
      return s
    }

    {
      doc = $0; low = tolower(doc); pos = 1
      while (1) {
        s = index(substr(low, pos), "<form")
        if (s == 0) { break }
        fstart = pos + s - 1
        e = index(substr(low, fstart), "</form")
        if (e == 0) { seg = substr(doc, fstart); pos = length(doc) + 1 }
        else { seg = substr(doc, fstart, e - 1); pos = fstart + e }

        lowseg = tolower(seg)
        if (lowseg !~ /data-fm-question/) { continue }
        found++

        key = "(unnamed)"
        if (match(seg, /data-fm-question[[:space:]]*=[[:space:]]*[^[:space:]>]+/)) {
          key = unquote(substr(seg, RSTART, RLENGTH))
          sub(/^[^=]*=[[:space:]]*/, "", key)
        }

        # Quotes are stripped before counting so a double-quoted, a
        # single-quoted, and a bare attribute all count the same.
        opts = 0; rest = unquote(lowseg)
        while (match(rest, /type[[:space:]]*=[[:space:]]*radio/)) {
          opts++
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (opts < 2) {
          printf "  the question \"%s\" offers %d selectable option(s): a decision needs at least two, and they have to be real alternatives rather than one recommendation plus filler\n", key, opts
        }
        if (lowseg !~ /<textarea([[:space:]][^>]*)?[[:space:]]data-fm-note([[:space:]=\/>]|$)/) {
          printf "  the question \"%s\" has no note control: every option set needs a textarea carrying data-fm-note beside it, because a note that contradicts the chosen option is what the captain actually meant\n", key
        }
        if (lowseg !~ /fm-queued/) {
          printf "  the question \"%s\" has no .fm-queued box, so neither a queued answer nor an empty one could be shown\n", key
        }
      }
    }

    END {
      if (kind == "decision" && found == 0) {
        print "  --kind decision, but no part of this board carries a form with data-fm-question: it asks the captain to decide and gives him nothing to choose"
      }
    }
  '
}

# decision_guard - refuse a board that asks for a decision it cannot receive.
decision_guard() {  # <body-file> <kind>
  local findings
  findings=$(scan_decision_defects "$1" "$2")
  if [ -n "$findings" ]; then
    printf 'fm-board.sh: REFUSED - this board asks the captain to decide without giving him a control to decide with.\n' >&2
    printf 'A decision must be selectable, with a note field beside it. See docs/board-layout.md.\n' >&2
    printf '%s\n' "$findings" >&2
    return 1
  fi
  return 0
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
KIND="report"
VESSEL=""
VESSEL_SET=0
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
    --kind)
      [ "$#" -gt 1 ] || die "--kind needs a value"
      case "$2" in
        report|decision) KIND=$2 ;;
        *) die "unknown --kind '$2' (report or decision)" ;;
      esac
      shift 2
      ;;
    --vessel)
      [ "$#" -gt 1 ] || die "--vessel needs a value"
      VESSEL=$2
      VESSEL_SET=1
      shift 2
      ;;
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

# Refuse an unanswerable decision before anything is composed or written.
decision_guard "$BODY_FILE" "$KIND" || exit 1

if [ "$VESSEL_SET" = 0 ]; then
  VESSEL=$(resolve_vessel)
fi
if [ -z "$VESSEL" ]; then
  printf 'fm-board.sh: no vessel name found, so this board carries no mark saying who built it.\n' >&2
  printf 'Looked for --vessel, FM_BOARD_VESSEL, FM_BRIDGE_VESSEL, and:\n' >&2
  printf '  %s\n' "${VESSEL_FILES[@]}" >&2
fi

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
  [ -z "$VESSEL" ] || printf '<div class="fm-mark">%s</div>\n' "$(html_escape "$VESSEL")"
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
