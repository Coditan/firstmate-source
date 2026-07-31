#!/usr/bin/env bash
# Behavior tests for the shared board layout and its no-network guard.
#
# The guard is the reason this file exists. Boards used to carry a hand-written
# layout, and the Lavish-recommended CDN snippet kept coming back with it: on
# 2026-07-31, eleven of twelve boards under .lavish/ pulled three files from
# cdn.jsdelivr.net including the Tailwind browser runtime, which recompiles the
# CSS in the reader's browser on every open. These tests pin the refusal so that
# regression fails loudly instead of quietly costing load time again.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
fm_test_tmproot TMP_ROOT fm-board

# build <body-html> -> writes $TMP_ROOT/out.html; records exit and stderr.
BUILD_STATUS_FILE=$TMP_ROOT/build-status
BUILD_ERR_FILE=$TMP_ROOT/build-stderr
OUT=$TMP_ROOT/out.html

build() {  # <body-html>
  local status=0
  rm -f "$OUT"
  printf '%s\n' "$1" > "$TMP_ROOT/body.html"
  "$BOARD" --title "Testbrett" --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>"$BUILD_ERR_FILE" || status=$?
  printf '%s\n' "$status" > "$BUILD_STATUS_FILE"
}

build_status() { cat "$BUILD_STATUS_FILE"; }
build_stderr() { cat "$BUILD_ERR_FILE"; }

# --- the guard refuses every documented remote-reference form ----------------

test_guard_refuses_remote_references() {
  local case_html label
  # Each entry is <label>|<body html>. Every one of these makes the browser
  # fetch something on load.
  while IFS='|' read -r label case_html; do
    [ -n "$label" ] || continue
    build "$case_html"
    [ "$(build_status)" != 0 ] || fail "guard let a remote reference through: $label"
    assert_absent "$OUT" "guard refused '$label' but still wrote the board"
    assert_contains "$(build_stderr)" "REFUSED" "refusal for '$label' did not say REFUSED"
  done <<'EOF'
tailwind browser cdn|<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
daisyui stylesheet|<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
remote image|<p>x</p><img src="https://example.com/logo.png">
protocol-relative iframe|<iframe src="//example.com/x"></iframe>
remote webfont|<style>@font-face{font-family:X;src:url(https://f.example/x.woff2)}</style>
css import rule|<style>@import url("https://example.com/x.css");</style>
outward form post|<form action="https://example.com/collect"><button>go</button></form>
fetch inside script|<script>fetch("https://api.example.com/x")</script>
remote srcset|<img srcset="https://example.com/a.png 1x" alt="a">
svg use from remote|<svg><use href="https://example.com/i.svg#x"></use></svg>
object data attribute|<object data="https://example.com/x.svg"></object>
css image-set|<style>.x{background-image:image-set("https://example.com/a.png" 1x)}</style>
EOF
  pass "the guard refuses every documented remote-reference form and writes nothing"
}

test_guard_refuses_a_tag_whose_attributes_span_lines() {
  # grep sees one PHYSICAL line at a time, and wrapping attributes across lines
  # is ordinary generated HTML - so a line-anchored scan would let exactly the
  # CDN stylesheet this guard exists to refuse back in. The wrapped form is the
  # same regression and must be refused the same way.
  local label case_html
  while IFS='|' read -r label case_html; do
    [ -n "$label" ] || continue
    # \n in the fixture stands for a real newline inside the tag.
    build "$(printf '%b' "$case_html")"
    [ "$(build_status)" != 0 ] || fail "guard let a line-wrapped reference through: $label"
    assert_absent "$OUT" "guard refused '$label' but still wrote the board"
    assert_contains "$(build_stderr)" "REFUSED" "refusal for '$label' did not say REFUSED"
  done <<'EOF'
wrapped daisyui stylesheet|<link\n  rel="stylesheet"\n  href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
wrapped tailwind script|<script\n  src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
wrapped remote image|<img\n  alt="x"\n  src="https://example.com/logo.png">
wrapped svg use|<svg><use\n  href="https://example.com/i.svg#x"></use></svg>
wrapped css import url|<style>\n@import\n  url("https://example.com/x.css");\n</style>
wrapped css import quoted|<style>\n@import\n  "https://example.com/x.css";\n</style>
EOF
  pass "a reference wrapped across lines is refused exactly like the one-line form"
}

# --- the guard does not refuse what a board legitimately needs ---------------

test_guard_allows_navigational_links() {
  # AGENTS.md section 9 requires boards to carry FULL PR URLs. A hyperlink is
  # not a network request: nothing is fetched until the captain clicks it. A
  # guard that refused this would make correct boards unbuildable.
  build '<p>PR: <a href="https://github.com/Freudator86/admiralty/pull/1355">1355</a></p>'
  expect_code 0 "$(build_status)" "a full PR hyperlink must be allowed"
  assert_grep 'https://github.com/Freudator86/admiralty/pull/1355' "$OUT" \
    "the PR URL did not survive into the board"
  pass "a full PR hyperlink is allowed and preserved"
}

test_guard_allows_a_navigational_link_split_across_lines() {
  # Folding tag lines together must not cost the <a> exemption: a hyperlink is
  # still not a network request, however its attributes are formatted.
  build "$(printf '%b' '<p>PR:\n  <a\n    href="https://github.com/Freudator86/admiralty/pull/1355">1355</a></p>')"
  expect_code 0 "$(build_status)" "a line-wrapped PR hyperlink must still be allowed"
  assert_grep 'https://github.com/Freudator86/admiralty/pull/1355' "$OUT" \
    "the PR URL did not survive into the board"
  pass "a navigational link stays allowed when its attributes span lines"
}

test_guard_allows_prose_naming_the_rule() {
  # @import is refused as a STATEMENT, not as a word, so a board that explains
  # this very rule is not refused for naming it.
  build '<p>Kein CDN, kein @import, keine externe Schrift.</p>'
  expect_code 0 "$(build_status)" "prose naming @import must not be refused"
  build "$(printf '%b' '<!-- Ein Kommentar, der @import\n     und url() nur benennt. -->\n<p>Inhalt</p>')"
  expect_code 0 "$(build_status)" "a comment naming @import across lines must not be refused"
  pass "prose that names the rule is not mistaken for the rule being broken"
}

test_guard_allows_prose_that_ends_a_line_on_the_rule_name() {
  # The worst position for the word: last token on its line, with a quote
  # opening the next one. Nothing here starts a statement with @import, so
  # nothing here is a rule - however aggressively the two lines are joined.
  build "$(printf '%b' '<p>Kein @import\n"und kein CDN".</p>')"
  expect_code 0 "$(build_status)" "prose ending a line on @import must not be refused"
  build "$(printf '%b' '<p>Wir nennen es @import</p>\n<p>"und meinen die Regel".</p>')"
  expect_code 0 "$(build_status)" "prose ending a paragraph on @import must not be refused"
  pass "prose whose line ends on the rule name is not folded into a rule"
}

# --- what the builder actually produces --------------------------------------

test_board_is_self_contained() {
  build '<p>Inhalt</p>'
  expect_code 0 "$(build_status)" "a clean body must build"
  assert_present "$OUT" "no board written"
  # The layout and behavior must be INLINE, not linked as siblings: a board is
  # opened straight from disk with no server, and `lavish-axi export` must keep
  # producing one portable file.
  assert_grep '<style>' "$OUT" "layout css was not inlined"
  assert_grep '.fm-card' "$OUT" "layout css content is missing"
  assert_grep 'data-fm-question' "$OUT" "board behavior was not inlined"
  # No sibling asset may be REFERENCED. Match the reference form, not the bare
  # filename: the inlined files name themselves in their own header comments.
  assert_no_grep 'href="layout.css"' "$OUT" "board links its stylesheet instead of inlining it"
  assert_no_grep 'src="board.js"' "$OUT" "board links its script instead of inlining it"
  assert_no_grep 'board-assets/' "$OUT" "board points at the asset directory instead of inlining it"
  pass "a built board carries its layout and behavior inline"
}

test_board_escapes_its_title() {
  build '<p>x</p>'
  local status=0
  "$BOARD" --title 'A & B <danger>' --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "title with markup characters must still build"
  assert_grep 'A &amp; B &lt;danger&gt;' "$OUT" "title was not escaped"
  pass "the title is escaped rather than injected as markup"
}

test_check_mode_reports_both_verdicts() {
  local status=0 out
  build '<p>sauber</p>'
  out=$("$BOARD" --check "$OUT" 2>&1) || status=$?
  expect_code 0 "$status" "--check must accept a clean board"
  assert_contains "$out" "no external network requests" "--check did not confirm a clean board"

  printf '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">\n' \
    > "$TMP_ROOT/dirty.html"
  status=0
  out=$("$BOARD" --check "$TMP_ROOT/dirty.html" 2>&1) || status=$?
  [ "$status" != 0 ] || fail "--check accepted a board with a CDN stylesheet"
  assert_contains "$out" "cdn.jsdelivr.net" "--check did not name the offending reference"

  # The same stylesheet with its attributes wrapped is the same defect.
  printf '<link\n  rel="stylesheet"\n  href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">\n' \
    > "$TMP_ROOT/dirty-wrapped.html"
  status=0
  out=$("$BOARD" --check "$TMP_ROOT/dirty-wrapped.html" 2>&1) || status=$?
  [ "$status" != 0 ] || fail "--check accepted a line-wrapped CDN stylesheet"
  assert_contains "$out" "cdn.jsdelivr.net" "--check did not name the wrapped reference"
  pass "--check reports a clean board and names the reference in a dirty one"
}

test_missing_required_arguments_are_refused() {
  local status=0
  "$BOARD" --title T --out "$OUT" >/dev/null 2>&1 || status=$?
  [ "$status" != 0 ] || fail "builder accepted a call with no --body"
  pass "the builder refuses an incomplete invocation"
}

# --- the versioned layout is genuinely shared --------------------------------

test_two_different_board_shapes_share_the_layout() {
  # The layout is only reusable if it carries a board that is NOT a decision
  # board. This builds both shapes from the same versioned assets - a decision
  # card with answer controls, and a report with a distribution bar, status line
  # and wide table - and requires both to come out clean.
  local decision report status=0
  decision='<div class="fm-grid"><div class="fm-card is-gate"><div class="fm-chead">
    <div class="fm-num">1</div><div class="fm-ctitle">Eine Frage</div></div>
    <form data-fm-question="f" data-fm-label="Eine Frage"><div class="fm-opts">
    <label class="fm-opt"><input type="radio" name="f" value="ja"><span>Ja</span></label></div>
    <button type="submit" class="fm-submit">Antwort vormerken</button>
    <div class="fm-queued"></div></form></div></div>'
  build "$decision"
  expect_code 0 "$(build_status)" "the decision shape must build"
  # Match the MARKUP form, not the bare class name: every board inlines the full
  # stylesheet, so grepping `fm-opt` alone would pass on any board at all.
  assert_grep 'class="fm-opt"' "$OUT" "decision controls missing from the decision shape"

  # The report shape is kept as a worked example so it cannot silently rot.
  report=$ROOT/docs/examples/board-body-report.html
  assert_present "$report" "the worked report-shape example is missing"
  rm -f "$OUT"
  "$BOARD" --title "Bericht" --body "$report" --out "$OUT" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "the report shape must build from the same layout"
  assert_grep 'class="fm-dist"' "$OUT" "report shape lost its distribution bar"
  assert_grep 'class="fm-statusline"' "$OUT" "report shape lost its status line"
  assert_grep 'class="fm-scroll"' "$OUT" "a wide table must scroll in its own container"
  # Asserted against the BODY, not the composed board: every board inlines
  # board.js, whose header comment shows the decision-control markup, so a
  # composed-board grep can never tell the two apart.
  assert_no_grep 'class="fm-opt"' "$report" "the report shape should carry no decision controls"
  pass "two structurally different boards build from the one shared layout"
}

test_layout_lives_in_one_place() {
  # The point of the whole change: the layout is an artifact agents INCLUDE, not
  # one they retype. If the assets stop existing, boards would drift again.
  local css js
  css=$("$BOARD" --print-assets | sed -n '1p')
  js=$("$BOARD" --print-assets | sed -n '2p')
  assert_present "$css" "the versioned layout stylesheet is missing"
  assert_present "$js" "the versioned board behavior is missing"
  assert_grep 'prefers-color-scheme' "$css" "layout lost its dark-mode support"
  assert_grep 'queueKey' "$js" "board behavior lost the per-question queueKey"
  pass "the layout and behavior live in one versioned place"
}

# --- board behavior, exercised as logic rather than rendering ----------------

test_board_behavior_contract() {
  # This vessel has no working browser (an open captain decision), so the
  # decision controls are checked as LOGIC against a DOM stand-in. That proves
  # what the script does on a served board and on one opened straight from disk;
  # it proves nothing about how a board looks, and does not pretend to.
  local behavior=$ROOT/tests/fm-board-behavior.test.mjs
  assert_present "$behavior" "the board behavior checks are missing"
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  local out status=0
  out=$(node "$behavior" 2>&1) || status=$?
  [ "$status" = 0 ] || fail "board behavior checks failed:"$'\n'"$out"
  assert_contains "$out" "queueKey" "the behavior checks no longer cover queueKey"
  pass "board decision controls behave per the Lavish input playbook (logic, not rendering)"
}

test_guard_refuses_remote_references
test_guard_refuses_a_tag_whose_attributes_span_lines
test_guard_allows_navigational_links
test_guard_allows_a_navigational_link_split_across_lines
test_guard_allows_prose_naming_the_rule
test_guard_allows_prose_that_ends_a_line_on_the_rule_name
test_board_is_self_contained
test_board_escapes_its_title
test_check_mode_reports_both_verdicts
test_missing_required_arguments_are_refused
test_layout_lives_in_one_place
test_two_different_board_shapes_share_the_layout
test_board_behavior_contract
