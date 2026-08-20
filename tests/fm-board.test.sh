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

# Every board carries the building vessel's name, and the builder refuses to
# write one it cannot resolve. Pin it for the suite so each case exercises the
# behavior it is actually about; test_board_carries_the_vessel_name owns the
# resolution order and the refusal.
export FM_BOARD_VESSEL=testschiff

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
css import with a quoted target|<style>@import "https://cdn.jsdelivr.net/x.css";</style>
css import behind a comment|<style>/* c */@import "https://cdn.jsdelivr.net/x.css";</style>
css url in a style attribute|<div style="background:url(https://example.com/a.png)">x</div>
css url in a single-quoted style attribute|<div style='background:url(https://example.com/a.png)'>x</div>
css url in an unquoted style attribute|<div style=background:url(https://example.com/a.png)>x</div>
css url in a style attribute with no space before its name|<div class="a"style="background:url(https://example.com/a.png)">x</div>
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
css import behind a comment on its own line|<style>\n/* eine Bemerkung */\n@import "https://cdn.jsdelivr.net/x.css";\n</style>
css import behind a comment spanning lines|<style>\n/* eine Bemerkung,\n   die weitergeht */\n@import "https://cdn.jsdelivr.net/x.css";\n</style>
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

test_guard_allows_prose_that_names_a_css_construct() {
  # CSS runs inside a <style> element and inside a style attribute, and nowhere
  # else in an HTML document. So the word @import in a paragraph, a list item or
  # a comment is text, and text can never be an import rule. Every entry here is
  # a board that EXPLAINS the rule, which the captain requires to stay buildable.
  local label case_html
  while IFS='|' read -r label case_html; do
    [ -n "$label" ] || continue
    build "$(printf '%b' "$case_html")"
    expect_code 0 "$(build_status)" \
      "the guard refused prose: $label"$'\n'"$(build_stderr)"
  done <<'EOF'
@import named mid-sentence|<p>Kein CDN, kein @import, keine externe Schrift.</p>
@import as the last token on its line|<p>Kein @import\n"und kein CDN".</p>
@import ending a paragraph|<p>Wir nennen es @import</p>\n<p>"und meinen die Regel".</p>
@import opening a paragraph|<p>@import "https://example.com/x.css" wäre ein Fehler.</p>
@import opening a list item|<ul><li>@import "https://example.com/x.css" ist verboten</li></ul>
@import opening a heading|<h2>@import "https://example.com/x.css"</h2>
@import and url() named in a comment|<!-- Ein Kommentar, der @import\n     und url("https://example.com/x.css") nur benennt. -->\n<p>Inhalt</p>
url() named in prose|<p>Eine externe url("https://example.com/a.png") gehört nicht auf ein Brett.</p>
url() parked in a data attribute, which no browser fetches|<div data-style="background:url(https://example.com/a.png)">x</div>
EOF
  pass "prose that names a CSS construct is not mistaken for the construct"
}

test_guard_allows_the_stylesheet_that_documents_itself() {
  # Every board inlines layout.css, whose own header names @import and url() in
  # prose. If that could be mistaken for the rule, no board would build at all.
  local status=0
  assert_grep '@import' "$ROOT/bin/board-assets/layout.css" \
    "this test is pointless unless the stylesheet still names the rule"
  rm -f "$OUT"
  "$BOARD" --title "Beispiel" --body "$ROOT/docs/examples/board-body-report.html" \
    --out "$OUT" >/dev/null 2>"$BUILD_ERR_FILE" || status=$?
  expect_code 0 "$status" \
    "the pinned example board must build although its stylesheet names @import"$'\n'"$(build_stderr)"
  pass "a stylesheet whose comments name the rule still builds every board"
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

test_board_carries_the_vessel_name() {
  # The captain asked for one thing at a glance: whose board is this. It is a
  # property of the BUILDER, not of the subject, so it is written here and never
  # by a board body. The resolution order and the refusal are both pinned,
  # because a board that quietly came out unattributed is exactly the failure.
  local status=0 out
  build '<p>Inhalt</p>'
  expect_code 0 "$(build_status)" "a clean body must build"
  assert_grep 'class="fm-vessel">Testschiff<' "$OUT" \
    "the vessel name is missing from the header"

  # --vessel beats the environment.
  rm -f "$OUT"
  "$BOARD" --title T --vessel eigenname --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "--vessel must be accepted"
  assert_grep 'class="fm-vessel">Eigenname<' "$OUT" "--vessel did not reach the header"

  # A lowercase recorded slug prints capitalised, and a hyphenated one keeps its
  # parts. This is a rendering rule, not a second spelling of the name.
  rm -f "$OUT"
  "$BOARD" --title T --vessel zweite-wache --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>&1 || status=$?
  assert_grep 'class="fm-vessel">Zweite-Wache<' "$OUT" \
    "a hyphenated vessel name lost a capital"

  # The Bridge vessel record is the fallback, so there is no second place a
  # vessel's name is written down.
  mkdir -p "$TMP_ROOT/home/config"
  printf 'dritteswache extra-inbox\n' > "$TMP_ROOT/home/config/bridge-vessel"
  rm -f "$OUT"
  status=0
  ( unset FM_BOARD_VESSEL FM_BRIDGE_VESSEL
    FM_HOME=$TMP_ROOT/home "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" \
      >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" "the recorded Bridge vessel must resolve the header"
  assert_grep 'class="fm-vessel">Dritteswache<' "$OUT" \
    "the header did not fall back to the recorded Bridge vessel name"
  assert_no_grep 'Extra-Inbox' "$OUT" \
    "a multi-vessel record must yield this seat's own name, not the inboxes it watches"

  # A board built from a TASK WORKTREE runs the worktree's own copy of this
  # script, and config/ is home-private and gitignored, so the script root
  # carries no name there - only FM_HOME does. Reading one resolved path would
  # leave this case unresolvable, and an unresolvable name is refused, so it is
  # not a missing header but a build that stops. Measured on this seat.
  rm -f "$OUT"
  status=0
  ( unset FM_BOARD_VESSEL FM_BRIDGE_VESSEL
    FM_ROOT_OVERRIDE=$TMP_ROOT/empty-home FM_HOME=$TMP_ROOT/home \
      "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" \
    "a board built where only FM_HOME carries the record must still resolve the name"
  assert_grep 'class="fm-vessel">Dritteswache<' "$OUT" \
    "the name did not resolve through FM_HOME when the script root had no record"

  # The mirror case: no FM_HOME in the environment, the record beside the
  # script. Both are tried, so neither placement is the one that fails.
  rm -f "$OUT"
  status=0
  ( unset FM_BOARD_VESSEL FM_BRIDGE_VESSEL FM_HOME
    FM_ROOT_OVERRIDE=$TMP_ROOT/home "$BOARD" --title T --body "$TMP_ROOT/body.html" \
      --out "$OUT" >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" "a board built beside the record must resolve the name"
  assert_grep 'class="fm-vessel">Dritteswache<' "$OUT" \
    "the name did not resolve from the script root when FM_HOME was unset"

  # The actual fallback edge: FM_HOME exists but carries no record, while the
  # script root does. This is where reading only the already-collapsed FM_HOME
  # path silently misses the second candidate.
  mkdir -p "$TMP_ROOT/script-root/config"
  printf 'viertewache\n' > "$TMP_ROOT/script-root/config/bridge-vessel"
  rm -f "$OUT"
  status=0
  ( unset FM_BOARD_VESSEL FM_BRIDGE_VESSEL
    FM_ROOT_OVERRIDE=$TMP_ROOT/script-root FM_HOME=$TMP_ROOT/empty-home \
      "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" \
    "a board built with an empty FM_HOME and recorded script root must still resolve the name"
  assert_grep 'class="fm-vessel">Viertewache<' "$OUT" \
    "the name did not fall back to the script root when FM_HOME had no record"

  # And when nothing resolves it, the board is refused rather than written
  # unattributed. Both candidate roots are isolated here: this repository's own
  # config/ is gitignored and so absent from a worktree but present in a real
  # home, and a test whose verdict depends on which one it runs in is a test
  # that reports the checkout rather than the behavior.
  rm -f "$OUT"
  status=0
  out=$( unset FM_BOARD_VESSEL FM_BRIDGE_VESSEL
    FM_ROOT_OVERRIDE=$TMP_ROOT/empty-home FM_HOME=$TMP_ROOT/empty-home \
      "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" 2>&1 ) || status=$?
  [ "$status" != 0 ] || fail "the builder wrote a board with no vessel name"
  assert_absent "$OUT" "the builder refused but still wrote the board"
  assert_contains "$out" "vessel" "the refusal did not name what is missing"
  pass "every board carries the building vessel's name, and an unresolvable one is refused"
}

test_board_emits_the_tally_container_and_the_mark_set() {
  # Both are the builder's to write. A count typed into a body can be wrong, and
  # a wrong count of what reached the captain is the whole defect the strip
  # exists to make visible.
  build '<p>Inhalt</p>'
  expect_code 0 "$(build_status)" "a clean body must build"
  assert_grep '<div class="fm-tally" hidden></div>' "$OUT" \
    "the tally container is missing, so board.js has nothing to fill"
  assert_grep 'symbol id="fm-mk-pencil"' "$OUT" \
    "the pencil mark is missing, so a chosen-but-unsent square cannot be drawn"
  assert_grep 'symbol id="fm-mk-struck"' "$OUT" \
    "the struck mark is missing, so a sent square cannot be drawn"
  pass "the builder writes the tally container and the mark set into every board"
}

test_the_decision_shape_offers_choices_and_a_note() {
  # The gap this exists to close: a board that asks the captain to decide and
  # gives him nothing to click forces the answer into chat, the one channel with
  # no memory. The worked example is what an agent copies, so it is the thing
  # that has to keep carrying both controls.
  local decision=$ROOT/docs/examples/board-body-decision.html status=0 semantic_status=0
  assert_present "$decision" "the worked decision-shape example is missing"
  rm -f "$OUT"
  "$BOARD" --title "Entscheidungen" --body "$decision" --out "$OUT" \
    >/dev/null 2>"$BUILD_ERR_FILE" || status=$?
  expect_code 0 "$status" \
    "the decision-shape example must build"$'\n'"$(build_stderr)"
  python3 - "$OUT" <<'PY' || semantic_status=$?
from html.parser import HTMLParser
import sys

class BoardModel(HTMLParser):
    def __init__(self):
        super().__init__()
        self.position = 0
        self.reserve_at = None
        self.forms = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        self.position += 1
        attrs = dict(attrs)
        classes = set(attrs.get("class", "").split())
        if "fm-reserve" in classes and self.reserve_at is None:
            self.reserve_at = self.position
        if tag == "form" and "data-fm-question" in attrs:
            self.current = {
                "key": attrs["data-fm-question"],
                "at": self.position,
                "radio": False,
                "note": False,
            }
            self.forms.append(self.current)
        if self.current is not None:
            if tag == "input" and attrs.get("type", "").lower() == "radio":
                self.current["radio"] = True
            if "data-fm-note" in attrs:
                self.current["note"] = True

    def handle_endtag(self, tag):
        if tag == "form":
            self.current = None

model = BoardModel()
with open(sys.argv[1], encoding="utf-8") as board:
    model.feed(board.read())

errors = []
if not model.forms:
    errors.append("the composed board declares no questions")
if model.reserve_at is None:
    errors.append("the composed board has no reservation block")
elif model.forms and model.reserve_at >= model.forms[0]["at"]:
    errors.append("the reservation block does not precede the first question")
for form in model.forms:
    if not form["radio"]:
        errors.append(f'question {form["key"]} has no selectable option set')
    if not form["note"]:
        errors.append(f'question {form["key"]} has no note field')
if errors:
    raise SystemExit("; ".join(errors))
PY
  [ "$semantic_status" = 0 ] || \
    fail "the composed decision board has an invalid decision shape"
  pass "the worked decision shape offers selectable options plus a note per decision"
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

test_default_appearance_is_visible_and_usable() {
  local clean_home=$TMP_ROOT/default-home
  mkdir -p "$clean_home"
  rm -f "$OUT"
  FM_HOME=$clean_home "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>&1 || fail "a seat with no local appearance could not build a board"
  assert_grep 'data-fm-board-appearance="default"' "$OUT" \
    "the neutral fallback was not inlined"
  assert_grep 'Default board appearance - no local vessel design is active.' "$OUT" \
    "the neutral fallback is not visibly identified as a default"
  assert_grep 'symbol id="fm-mk-open"' "$OUT" \
    "the neutral fallback does not carry the required marks"
  pass "a seat with no local design gets a visibly labelled usable default"
}

test_local_appearance_replaces_the_default() {
  local local_home=$TMP_ROOT/local-home mark
  mkdir -p "$local_home/config"
  {
    printf '<style data-test-local-appearance>.fm-wrap{outline:7px double}</style>\n'
    printf '<svg width="0" height="0"><defs>\n'
    for mark in open pencil struck gate held run void; do
      printf '<symbol id="fm-mk-%s" viewBox="0 0 20 20"><circle cx="10" cy="10" r="5"/></symbol>\n' "$mark"
    done
    printf '</defs></svg>\n'
  } > "$local_home/config/board-appearance.html"
  rm -f "$OUT"
  FM_HOME=$local_home "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>&1 || fail "a valid vessel-local appearance was refused"
  assert_grep 'data-test-local-appearance' "$OUT" \
    "the vessel-local appearance was not inlined"
  assert_no_grep 'data-fm-board-appearance="default"' "$OUT" \
    "the neutral fallback was still inlined beneath a vessel-local appearance"
  assert_no_grep 'Default board appearance - no local vessel design is active.' "$OUT" \
    "a locally designed board was still labelled as the default"
  pass "a vessel-local appearance replaces the neutral fallback"
}

test_incomplete_local_appearance_is_refused() {
  local bad_home=$TMP_ROOT/bad-home status=0
  mkdir -p "$bad_home/config"
  printf '<style>body{display:block}</style>\n' > "$bad_home/config/board-appearance.html"
  rm -f "$OUT"
  FM_HOME=$bad_home "$BOARD" --title T --body "$TMP_ROOT/body.html" --out "$OUT" \
    >/dev/null 2>"$BUILD_ERR_FILE" || status=$?
  [ "$status" != 0 ] || fail "an appearance without the semantic marks was accepted"
  assert_contains "$(build_stderr)" "missing mark fm-mk-open" \
    "the incomplete appearance refusal did not name its first missing mark"
  assert_absent "$OUT" "an incomplete appearance was refused but still wrote a board"
  pass "an incomplete vessel appearance is refused instead of breaking a board"
}

test_local_appearance_contract_and_notice_are_shipped() {
  local layout=$ROOT/docs/board-layout.md
  local configuration=$ROOT/docs/configuration.md
  local notice=$ROOT/docs/board-appearance-broadcast.md
  assert_grep "\$FM_HOME/config/board-appearance.html" "$layout" \
    "the board reference does not name the vessel-private appearance file"
  assert_no_grep 'Boards are set in **Tally**' "$layout" \
    "the shared board reference still claims this vessel's design for every reader"
  assert_grep '## Board appearance (config/board-appearance.html)' "$configuration" \
    "the configuration owner does not record the vessel-local appearance file"
  assert_present "$notice" "the All-Ships notice is missing from the change"
  assert_grep 'defect in the shared code, not a failure by any seat' "$notice" \
    "the notice does not assign the defect to shared code"
  assert_grep 'sets no deadline and asks for no reply' "$notice" \
    "the notice does not preserve the no-deadline, no-reply instruction"
  assert_grep 'Ours is named Tally, and it is ours only' "$notice" \
    "the notice does not name this vessel's design as this vessel's only"
  pass "the local-appearance contract and bounded All-Ships notice ship together"
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
  # A report asks nothing, so its strip stays hidden. The container is still
  # emitted, because the builder does not read the body to decide.
  assert_grep '<div class="fm-tally" hidden></div>' "$OUT" \
    "the report shape lost the tally container"
  # Asserted against the BODY, not the composed board: every board inlines
  # board.js, whose header comment shows the decision-control markup, so a
  # composed-board grep can never tell the two apart.
  assert_no_grep 'class="fm-opt"' "$report" "the report shape should carry no decision controls"
  pass "two structurally different boards build from the one shared layout"
}

test_layout_lives_in_one_place() {
  # The point of the whole change: the layout is an artifact agents INCLUDE, not
  # one they retype. If the assets stop existing, boards would drift again.
  local css fallback js
  css=$("$BOARD" --print-assets | sed -n '1p')
  fallback=$("$BOARD" --print-assets | sed -n '2p')
  js=$("$BOARD" --print-assets | sed -n '3p')
  assert_present "$css" "the versioned layout stylesheet is missing"
  assert_present "$fallback" "the neutral fallback appearance is missing"
  assert_present "$js" "the versioned board behavior is missing"
  assert_grep '.fm-wrap' "$css" "shared layout lost the board container"
  assert_no_grep 'font-family' "$css" "shared layout still chooses vessel typography"
  ! grep -Eq '#[0-9A-Fa-f]{3,8}' "$css" \
    || fail "shared layout still carries a literal palette"
  assert_grep 'data-fm-board-appearance="default"' "$fallback" \
    "fallback asset is not visibly identifiable as the default"
  assert_grep 'queueKey' "$js" "board behavior lost the per-question queueKey"
  pass "shared structure, neutral fallback, and behavior have distinct owners"
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
  # Both directions of the tally semantics, named here so a future edit that
  # drops one of them fails at this level too.
  assert_contains "$out" "choosing an option does NOT decrement" \
    "the behavior checks no longer prove that selecting leaves the count alone"
  assert_contains "$out" "a completed submit DOES decrement" \
    "the behavior checks no longer prove that submitting decrements the count"
  pass "board decision controls behave per the Lavish input playbook (logic, not rendering)"
}

test_guard_refuses_remote_references
test_guard_refuses_a_tag_whose_attributes_span_lines
test_guard_allows_navigational_links
test_guard_allows_a_navigational_link_split_across_lines
test_guard_allows_prose_that_names_a_css_construct
test_guard_allows_the_stylesheet_that_documents_itself
test_board_is_self_contained
test_board_carries_the_vessel_name
test_board_emits_the_tally_container_and_the_mark_set
test_the_decision_shape_offers_choices_and_a_note
test_board_escapes_its_title
test_check_mode_reports_both_verdicts
test_missing_required_arguments_are_refused
test_default_appearance_is_visible_and_usable
test_local_appearance_replaces_the_default
test_incomplete_local_appearance_is_refused
test_local_appearance_contract_and_notice_are_shipped
test_layout_lives_in_one_place
test_two_different_board_shapes_share_the_layout
test_board_behavior_contract
