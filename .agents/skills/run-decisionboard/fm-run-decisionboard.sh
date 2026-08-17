#!/usr/bin/env bash
# fm-run-decisionboard.sh - build a decision board, open it, DRIVE it, and prove
# an answer comes back.
#
# WHY THIS EXISTS
# On 2026-08-17 a seven-decision board went to the captain with no way to answer
# it: every decision carried its options in prose and nothing on the page could
# be clicked. He answered in chat instead. Nothing caught it, because nothing had
# ever driven a board programmatically - the boards were built and looked at, and
# "looked at" cannot tell you whether an answer would come back.
#
# This script is that missing test. It runs the whole loop against a built-in
# fixture board and asserts each hop, so "the captain can answer this" is a
# measurement rather than a hope.
#
# THE LOOP, and what each hop proves
#   build   the board exists and the no-network guard still refuses a body that
#           reaches out (proved by building one that must fail)
#   open    bin/fm-lavish.sh emitted a URL, and it is the reachable one
#   drive   Chrome is pointed at that URL through a bridge that was restarted
#   query   the rendered board carries answerable controls, inside its iframe
#   shot    a screenshot exists on disk, in this home, non-empty
#   answer  a choice and a note were entered and queued on the board
#   send    the queued answer left the board
#   poll    bin/fm-lavish.sh poll returned that answer - the acceptance criterion
#
# MEASURED HOST FACTS this script is built around. Each was hit on crew-hlr and
# each is re-measurable with `doctor`; none is inferred.
#
#   1. The browser bridge runs as a DIFFERENT UNIX ACCOUNT (`crew`, not the
#      account firstmate runs as). Two consequences, both load-bearing here:
#
#      a. `file://` under this home ALWAYS fails, with ERR_FILE_NOT_FOUND on a
#         file that demonstrably exists. It is a permission boundary wearing a
#         not-found error. The file mode is a red herring: /home/coditan is
#         drwxr-x---, so the bridge account cannot traverse into the home at all
#         and chmod 644 on the board changes nothing. Serve the board over HTTP
#         through fm-lavish.sh, which is the sanctioned path anyway.
#
#      b. `chrome-devtools-axi screenshot <path>` writes as that account. To a
#         path it cannot write, it EXITS 0, PRINTS THE PATH, AND WRITES NOTHING.
#         It does not fail; it lies. A `mktemp -d` scratch dir under /tmp is
#         enough to trigger it, because mktemp -d is mode 0700. So this script
#         shoots into /tmp itself (mode 1777), then copies the file back into
#         this home, and verifies the file exists, is non-empty, and CHANGED in
#         this run - because a stale file from an earlier run is what a silent
#         failure leaves behind. Never trust the exit status of a screenshot.
#
#   2. Lavish binds the TAILNET ADDRESS ONLY. http://127.0.0.1:<port>/... returns
#      ERR_CONNECTION_REFUSED. The working URL is the one bin/fm-lavish.sh prints,
#      and its port is claimed at runtime because neighbouring vessels hold
#      others. Never hardcode a port; read the printed URL.
#
#   3. The board renders inside a SANDBOXED IFRAME. The top document is the
#      Lavish editor chrome; the artifact is at /artifact/<id>/index.html. The
#      frame carries sandbox="allow-scripts allow-forms allow-popups
#      allow-downloads" with NO allow-same-origin, so it is an opaque origin:
#      `iframe.contentDocument` is null and no `eval` from the top document can
#      reach board content. Driving it therefore goes through the accessibility
#      snapshot and its uids, which DO cross the frame - not through JavaScript.
#
#   4. Accessibility uids are SNAPSHOT-GENERATION SCOPED. Every command returns a
#      new generation and invalidates the last one ("Stale ref @g1093:10_19: from
#      snapshot generation 1093, current is 1094"). So every single action here
#      re-snapshots and re-resolves its uid immediately before acting. A driver
#      that resolves once and then acts twice fails on the second action.
#
#   5. Stop the bridge before pointing it anywhere, or a process from an earlier
#      attempt is reused with its old environment.
#
#   6. `chromium-cli` is NOT on this host. google-chrome and chrome-devtools-axi
#      are. This script uses chrome-devtools-axi only.
#
#   7. A board with no armed poll SAYS SO on screen: "Your agent is not
#      listening" appears in the conversation panel. `query` reports it, because
#      a poll dies with the session that armed it and a board listening to nobody
#      looks exactly like a healthy one in a screenshot.
#
#   8. The bridge is SHARED across the vessels on this machine - which is the
#      same fact as gotcha 1, seen from the other side. Two consequences:
#      the viewport arrives at whatever size another vessel left it (one run here
#      screenshotted a 320px phone layout and looked like a rendering fault), so
#      `drive` sets it explicitly; and the `stop` in gotcha 5 can knock over a
#      neighbour's browser session, which is a cost this accepts rather than one
#      it avoids.
#
# Usage:
#   fm-run-decisionboard.sh selftest [--keep]      the whole loop on a fixture board
#   fm-run-decisionboard.sh doctor                 re-measure this host's facts
#   fm-run-decisionboard.sh guard-check            prove the no-network guard bites
#   fm-run-decisionboard.sh fixture                print the built-in body fragment
#   fm-run-decisionboard.sh parse < <snapshot>     the control inventory a snapshot yields
#   fm-run-decisionboard.sh build --out <p> [--body <f>] [--title <t>] [--subtitle <s>]
#   fm-run-decisionboard.sh open <board.html>      open it; prints the URL
#   fm-run-decisionboard.sh drive <url>            restart the bridge onto that URL
#   fm-run-decisionboard.sh query                  what the rendered board carries
#   fm-run-decisionboard.sh shot <dest.png>        screenshot, verified, copied back
#   fm-run-decisionboard.sh answer --option <label> [--note <t>] [--decision <n>]
#   fm-run-decisionboard.sh send                   send the queued answers
#   fm-run-decisionboard.sh poll <board.html>      wait for them to arrive
#   fm-run-decisionboard.sh end <board.html>       end the session
#
# Environment:
#   FM_RUN_DECISIONBOARD_SNAPSHOT  read this recorded accessibility snapshot
#                                  instead of asking a live browser. The test
#                                  seam that lets the readers below be pinned on
#                                  a machine with no browser bridge.
#   FM_RUN_DECISIONBOARD_NOTE_REQUIRED
#                                  report (default) names missing note fields but
#                                  does not refuse them; refuse makes query fail.
#                                  Change the default when PR 117 merges. No
#                                  machine-readable note requirement exists for
#                                  this driver to follow automatically.
#   FM_RUN_DECISIONBOARD_TMPDIR    the world-writable directory screenshots are
#                                  staged through (default /tmp). See `shot`.
#   FM_RUN_DECISIONBOARD_WIDTH     viewport `drive` sets, so evidence is
#   FM_RUN_DECISIONBOARD_HEIGHT    comparable across runs (default 1400x1600).
#   FM_HOME                        fallback root when this skill was installed
#                                  outside the firstmate repo it ships in.
#
# Exit status: 0 when every asserted hop held, non-zero on the first that did not.
set -eu

SELF=$(basename "${BASH_SOURCE[0]}")
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^# ?/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

step() { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }
good() { printf 'ok - %s\n' "$1"; }

# --- where the firstmate tooling is -----------------------------------------
#
# The skill lives at <repo>/.agents/skills/run-decisionboard/, so the repo root
# is three levels up. FM_HOME is the fallback for an install that moved the
# skill out of the repo it ships in.
resolve_root() {
  local candidate
  for candidate in "$SKILL_DIR/../../.." "${FM_HOME:-}"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate/bin/fm-board.sh" ] || continue
    [ -x "$candidate/bin/fm-lavish.sh" ] || continue
    (cd "$candidate" && pwd)
    return 0
  done
  die "found no firstmate root carrying bin/fm-board.sh and bin/fm-lavish.sh (looked beside this skill and under FM_HOME)"
}

ROOT=$(resolve_root)
BOARD_SH="$ROOT/bin/fm-board.sh"
LAVISH_SH="$ROOT/bin/fm-lavish.sh"

need_bridge() {
  command -v chrome-devtools-axi >/dev/null 2>&1 \
    || die "chrome-devtools-axi is not on PATH; it is the only browser tool this host has (chromium-cli is absent)"
}

# --- the built-in fixture board ---------------------------------------------
#
# A fixture rather than a real board on purpose: the loop has to be runnable from
# a clean start, with nothing waiting on the captain and nothing to disturb. Its
# markup is the shape docs/board-layout.md documents under "Decision controls",
# so exercising it exercises what a real board declares.
fixture_body() {
  cat <<'FIXTURE'
<p class="fm-note">Probebrett des run-decisionboard-Treibers. Keine echte Entscheidung.</p>
<div class="fm-grid">
  <div class="fm-card is-gate is-wide">
    <div class="fm-chead">
      <div class="fm-num">1</div>
      <div class="fm-ctitle">Probe-Entscheidung A</div>
      <div class="fm-tags"><span class="fm-tag is-gate">Tor für 2</span></div>
    </div>
    <p class="fm-stake">Diese Karte prüft, ob eine Antwort den Treiber wieder erreicht.</p>
    <p class="fm-ev">Sie steht für nichts und entscheidet nichts.</p>
    <form data-fm-question="probe-a" data-fm-label="Probe-Entscheidung A">
      <div class="fm-opts">
        <label class="fm-opt">
          <input type="radio" name="probe-a" value="option-eins">
          <span><b>Option eins</b><br><em>Die Option, die der Treiber wählt.</em></span>
        </label>
        <label class="fm-opt">
          <input type="radio" name="probe-a" value="option-zwei">
          <span><b>Option zwei</b><br><em>Bleibt ungewählt.</em></span>
        </label>
      </div>
      <textarea class="fm-free" data-fm-note placeholder="Begründung (optional)"></textarea>
      <button type="submit" class="fm-submit">Antwort vormerken</button>
      <div class="fm-queued"></div>
    </form>
    <details class="fm-variants">
      <summary>0 weitere Aufzeichnungen zu dieser Untersuchung</summary>
      <ul><li>keine - dies ist ein Probebrett</li></ul>
    </details>
  </div>
  <div class="fm-card">
    <div class="fm-chead">
      <div class="fm-num">2</div>
      <div class="fm-ctitle">Probe-Entscheidung B</div>
    </div>
    <p class="fm-stake">Eine zweite Karte, damit die Zählung etwas zu zählen hat.</p>
    <form data-fm-question="probe-b" data-fm-label="Probe-Entscheidung B">
      <div class="fm-opts">
        <label class="fm-opt"><input type="radio" name="probe-b" value="ja"><span><b>Ja</b></span></label>
        <label class="fm-opt"><input type="radio" name="probe-b" value="nein"><span><b>Nein</b></span></label>
      </div>
      <textarea class="fm-free" data-fm-note placeholder="Begründung (optional)"></textarea>
      <button type="submit" class="fm-submit">Antwort vormerken</button>
      <div class="fm-queued"></div>
    </form>
    <details class="fm-variants">
      <summary>0 weitere Aufzeichnungen zu dieser Untersuchung</summary>
      <ul><li>keine - dies ist ein Probebrett</li></ul>
    </details>
  </div>
</div>
<div class="fm-offline"></div>
FIXTURE
}

# --- build ------------------------------------------------------------------

cmd_build() {
  local out='' body='' title='Probebrett' subtitle='run-decisionboard fixture'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) out=${2:-}; shift 2 ;;
      --body) body=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --subtitle) subtitle=${2:-}; shift 2 ;;
      *) die "build: unknown argument '$1'" ;;
    esac
  done
  [ -n "$out" ] || die "build: --out is required"
  mkdir -p "$(dirname "$out")"
  if [ -n "$body" ]; then
    "$BOARD_SH" --title "$title" --subtitle "$subtitle" --body "$body" --out "$out" >/dev/null
  else
    fixture_body | "$BOARD_SH" --title "$title" --subtitle "$subtitle" --body - --out "$out" >/dev/null
  fi
  [ -s "$out" ] || die "build: fm-board.sh reported success but wrote no board at $out"
  printf 'board: %s\n' "$out"
}

# --- guard-check ------------------------------------------------------------
#
# The no-network guard is the reason boards are built rather than hand-written,
# and a guard nobody re-runs is a guard nobody knows still bites. This proves it
# on the regression that actually happened: the Tailwind browser runtime.
cmd_guard_check() {
  local tmp status=0 out
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-run-db-bad.XXXXXX")
  out="$tmp.html"
  printf '<p>Ein Brett, das ins Netz greift.</p>\n<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>\n' > "$tmp"
  "$BOARD_SH" --title "Muss abgelehnt werden" --body "$tmp" --out "$out" >/dev/null 2>&1 || status=$?
  rm -f "$tmp"
  if [ "$status" -eq 0 ]; then
    rm -f "$out"
    die "guard-check: the no-network guard ACCEPTED a board pulling @tailwindcss/browser from a CDN"
  fi
  [ ! -e "$out" ] || { rm -f "$out"; die "guard-check: the guard refused but still wrote $out"; }
  good "the no-network guard refused a CDN body (exit $status) and wrote nothing"
}

# --- open -------------------------------------------------------------------
#
# The URL is taken from what fm-lavish.sh PRINTS. The port is claimed at runtime
# against neighbouring vessels, so any hardcoded one is wrong sooner or later,
# and loopback is never served.
cmd_open() {
  local board=${1:-} out url
  [ -n "$board" ] || die "open: needs a board html file"
  [ -f "$board" ] || die "open: no such board: $board"
  out=$("$LAVISH_SH" "$board" 2>&1) || { printf '%s\n' "$out" >&2; die "open: fm-lavish.sh failed"; }
  url=$(printf '%s\n' "$out" | sed -n 's/.*url: "\([^"]*\)".*/\1/p' | head -1)
  [ -n "$url" ] || { printf '%s\n' "$out" >&2; die "open: fm-lavish.sh printed no session url"; }
  case "$url" in
    *127.0.0.1*|*localhost*)
      note "the emitted link is on loopback, so it opens nothing off this machine"
      ;;
  esac
  printf '%s\n' "$url"
}

# --- drive ------------------------------------------------------------------

cmd_drive() {
  local url=${1:-}
  [ -n "$url" ] || die "drive: needs a url"
  need_bridge
  # Gotcha 5: a bridge left over from an earlier attempt is reused with its old
  # environment, so it is stopped rather than reconfigured.
  chrome-devtools-axi stop >/dev/null 2>&1 || true
  chrome-devtools-axi open "$url" >/dev/null 2>&1 \
    || die "drive: chrome-devtools-axi could not open $url"
  # Gotcha 8: the bridge is shared across the vessels on this machine, so the
  # viewport arrives at whatever size somebody else left it. A board screenshotted
  # at 320px is a phone-layout board, and reading one as the desktop layout is a
  # wrong conclusion drawn from real evidence. Fix the size rather than inherit it.
  chrome-devtools-axi resize "${FM_RUN_DECISIONBOARD_WIDTH:-1400}" \
    "${FM_RUN_DECISIONBOARD_HEIGHT:-1600}" >/dev/null 2>&1 \
    || note "could not set the viewport size; the screenshot will be at whatever size the shared browser was left"
  local title
  title=$(snapshot | grep -m1 'RootWebArea' | sed -n 's/.*RootWebArea "\([^"]*\)".*/\1/p')
  printf 'driving: %s\n' "${title:-<untitled>}"
}

# --- the accessibility snapshot ---------------------------------------------
#
# Everything below reads THIS, not the DOM. Gotcha 3: the artifact frame is an
# opaque origin, so JavaScript from the top document cannot see board content at
# all; the accessibility tree crosses the frame and is the only way in.
#
# FM_RUN_DECISIONBOARD_SNAPSHOT is a test seam: point it at a recorded snapshot
# and every reader below runs against that instead of a live browser. It exists
# so the finding this whole skill was written for - a board whose decisions carry
# no controls - can be pinned by a test without a browser on the machine.
snapshot() {
  if [ -n "${FM_RUN_DECISIONBOARD_SNAPSHOT:-}" ]; then
    [ -r "$FM_RUN_DECISIONBOARD_SNAPSHOT" ] \
      || die "FM_RUN_DECISIONBOARD_SNAPSHOT points at an unreadable file: $FM_RUN_DECISIONBOARD_SNAPSHOT"
    fold_snapshot < "$FM_RUN_DECISIONBOARD_SNAPSHOT"
    return 0
  fi
  need_bridge
  chrome-devtools-axi snapshot 2>&1 | fold_snapshot
}

# fold_snapshot - put every node back on ONE line.
#
# An accessible name can contain a literal newline, so one node can span several
# physical lines. A `<br>` inside an option label is enough to do it: the tree
# carries `LineBreak "` and closes the quote on the next line, at column zero.
# Line-oriented parsing then reads that stray `"` as a top-level node and walks
# straight back out of the artifact frame - which is how this parser first
# reported a two-decision board as carrying one decision, no note field and no
# submit button. Every real node line starts with optional spaces and `uid=`, so
# anything else is a continuation and is folded onto the node above it.
fold_snapshot() {
  awk '
    /^ *uid=/ {
      if (held) { print buf }
      buf = $0; held = 1; next
    }
    held { buf = buf " " $0; next }
    { print }
    END { if (held) { print buf } }
  '
}

# uid_in_chrome <fixed-string> - resolve a uid in the Lavish editor chrome, in
# the SAME breath as the snapshot that produced it. Gotcha 4: any other command
# in between invalidates it.
uid_in_chrome() {  # <needle>
  snapshot | grep -F -m1 -- "$1" | sed -n 's/.*uid=\([^ ]*\).*/\1/p'
}

# form_inventory - one line per decision form and per control inside the artifact
# frame:
#   <decision-number>\t<role>\t<uid>\t<accessible name>\t<properties>
#
# The form itself gets a row so a form carrying NO controls is still counted.
# Without it a decision whose options are prose would be invisible rather than
# reported, which is the exact defect this driver exists to catch.
#
# Decision numbers are document order and are stable across snapshots, which is
# what makes them a usable address when uids are not. Controls in the editor
# chrome (the Send buttons, the message box) are outside the artifact frame and
# are deliberately excluded.
form_inventory() {
  snapshot | parse_forms inventory
}

form_subtree() {  # <decision-number>
  snapshot | parse_forms subtree "$1"
}

queued_confirmation() {
  sed -n 's/.*"\(Vorgemerkt: [^"]*\)".*/\1/p' | head -1
}

parse_forms() {  # <inventory|subtree> [decision-number]
  local mode=$1 target=${2:-}
  awk -v mode="$mode" -v target="$target" '
    {
      line = $0
      indent = match(line, /[^ ]/) - 1
      if (indent < 0) { next }
      body = substr(line, indent + 1)
    }
    # The artifact frame announces itself as a RootWebArea served from /artifact/.
    body ~ /^uid=[^ ]+ RootWebArea/ && body ~ /\/artifact\// {
      in_art = 1; art_indent = indent; form_indent = -1; next
    }
    in_art && indent <= art_indent { in_art = 0 }
    !in_art { next }
    {
      uid = body; sub(/^uid=/, "", uid); sub(/ .*/, "", uid)
      rest = body; sub(/^uid=[^ ]+ */, "", rest)
      role = rest; sub(/ .*/, "", role)
      name = ""
      if (match(rest, /"[^"]*"/)) { name = substr(rest, RSTART + 1, RLENGTH - 2) }
    }
    role == "form" {
      forms++; form_indent = indent
      if (mode == "inventory") {
        printf "%d\t%s\t%s\t%s\n", forms, role, uid, name
      } else if (forms == target) {
        print line
      }
      next
    }
    form_indent >= 0 && indent <= form_indent { form_indent = -1 }
    form_indent >= 0 && mode == "subtree" && forms == target {
      print line
      next
    }
    form_indent >= 0 && mode == "inventory" && (role == "radio" || role == "textbox" || role == "button" || role == "checkbox") {
      properties = (body ~ /(^| )multiline( |$)/ ? "multiline" : "")
      printf "%d\t%s\t%s\t%s\t%s\n", forms, role, uid, name, properties
    }
  '
}

parse_inventory() {
  parse_forms inventory
}

# --- query ------------------------------------------------------------------

cmd_query() {
  local inv snap decisions with_options with_note with_button listening note_policy
  note_policy=${FM_RUN_DECISIONBOARD_NOTE_REQUIRED:-report}
  case "$note_policy" in
    report|refuse) ;;
    *) die "query: FM_RUN_DECISIONBOARD_NOTE_REQUIRED must be 'report' or 'refuse', not '$note_policy'" ;;
  esac
  inv=$(form_inventory)
  snap=$(snapshot)
  decisions=$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "form" {print $1}' | sort -un | wc -l | tr -d ' ')
  [ -n "$inv" ] || decisions=0
  with_options=$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "radio" {print $1}' | sort -un | wc -l | tr -d ' ')
  with_note=$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "textbox" && $5 == "multiline" {print $1}' | sort -un | wc -l | tr -d ' ')
  with_button=$(printf '%s\n' "$inv" | awk -F'\t' '$2 == "button" {print $1}' | sort -un | wc -l | tr -d ' ')
  listening=yes
  case "$snap" in
    *"agent is not listening"*) listening=no ;;
  esac

  printf 'board:\n'
  printf '  decision cards: %s\n' "$decisions"
  printf '  with selectable options: %s\n' "$with_options"
  printf '  with a note field: %s\n' "$with_note"
  printf '  with a button (role only): %s\n' "$with_button"
  printf '  button evidence: necessary shape only; role=button cannot distinguish submit from help or reset. Only answer proves submission by clicking it and reading the queued confirmation.\n'
  printf '  poll listening: %s\n' "$listening"
  if [ -n "$inv" ]; then
    printf 'options:\n'
    printf '%s\n' "$inv" | awk -F'\t' '$2 == "radio" { printf "  %s: %s\n", $1, $4 }'
  fi
  # Gotcha 7: an unlistened board looks healthy in a screenshot, so say it here.
  if [ "$listening" = no ]; then
    printf 'FINDING: no poll is armed on this board - the captain would see "Your agent is not listening".\n'
  fi
  # The defect this whole skill exists for: a board that cannot be answered.
  if [ "$decisions" -eq 0 ]; then
    printf 'FINDING: this board carries no decision form at all; nothing on it can be answered.\n'
    return 1
  fi
  if [ "$with_options" -lt "$decisions" ]; then
    printf 'FINDING: %s of %s decision cards carry no selectable options; those can only be answered in chat.\n' \
      "$((decisions - with_options))" "$decisions"
    return 1
  fi
  if [ "$with_note" -lt "$decisions" ]; then
    printf 'FINDING: %s of %s decision cards carry no note field; a choice alone can record a decision the captain did not make. On the 2026-08-16 board, two of twenty answers carried a note that contradicted the selected option, and both notes carried what the captain actually meant.\n' \
      "$((decisions - with_note))" "$decisions"
    if [ "$note_policy" = refuse ]; then
      printf 'FINDING: FM_RUN_DECISIONBOARD_NOTE_REQUIRED=refuse, so missing note fields are refused.\n'
      return 1
    fi
    printf 'FINDING: this does not fail today because the current board tooling permits choice-only answers; set FM_RUN_DECISIONBOARD_NOTE_REQUIRED=refuse when that contract changes.\n'
  fi
  if [ "$with_button" -lt "$decisions" ]; then
    printf 'FINDING: %s of %s decision cards have no button at all, so a selection has nowhere to go.\n' \
      "$((decisions - with_button))" "$decisions"
    return 1
  fi
}

# --- shot -------------------------------------------------------------------
#
# Gotcha 1b in full. The screenshot is taken into /tmp itself - mode 1777, the
# one place the bridge account can certainly write - then copied back into this
# home, and BOTH ends are verified, because the exit status of a screenshot
# means nothing here.
#
# The staging path is STABLE rather than unique per run, which is deliberate.
# The file lands owned by the bridge account in a sticky directory, so this
# account cannot delete it and a unique name would leave one orphan per run
# forever. A stable name is one the bridge overwrites itself, so /tmp carries at
# most one. What a stable name costs is the ability to treat "the file is there"
# as proof, so freshness is checked instead: a screenshot that wrote nothing
# leaves the previous run's file behind, and that is exactly the stale pass this
# whole script exists to refuse.
#
# FM_RUN_DECISIONBOARD_TMPDIR overrides the staging DIRECTORY. It defaults to
# /tmp because that is the world-writable directory the bridge account is known
# to reach here; a host whose scratch directory is elsewhere sets it, and the
# tests set it to reach both refusal branches without depending on what an
# earlier run left in /tmp.
shot_staging_path() {
  printf '%s/fm-run-decisionboard-shot.%s.png' "${FM_RUN_DECISIONBOARD_TMPDIR:-/tmp}" "$(id -un)"
}

SCREENSHOT_EXIT_STATUS=0
capture_staged_screenshot() {
  local staging=$1 before='' after
  SCREENSHOT_EXIT_STATUS=0
  [ ! -e "$staging" ] || before=$(sha256sum "$staging" 2>/dev/null | awk '{print $1}')
  chrome-devtools-axi screenshot "$staging" >/dev/null 2>&1 || SCREENSHOT_EXIT_STATUS=$?
  [ -s "$staging" ] || return 1
  after=$(sha256sum "$staging" 2>/dev/null | awk '{print $1}') || return 1
  [ -z "$before" ] || [ "$before" != "$after" ] || return 2
  return 0
}

cmd_shot() {
  local dest=${1:-} staging capture_result=0
  [ -n "$dest" ] || die "shot: needs a destination path"
  need_bridge
  staging=$(shot_staging_path)
  capture_staged_screenshot "$staging" || capture_result=$?
  case "$capture_result" in
    1) die "shot: chrome-devtools-axi exited $SCREENSHOT_EXIT_STATUS but wrote no screenshot at $staging (a screenshot's exit status is not evidence; the file is)" ;;
    2) die "shot: chrome-devtools-axi exited $SCREENSHOT_EXIT_STATUS and left $staging unchanged, so this run captured nothing (the file there is from an earlier run)" ;;
  esac
  mkdir -p "$(dirname "$dest")"
  cp "$staging" "$dest" || die "shot: could not copy $staging to $dest"
  [ -s "$dest" ] || die "shot: $dest is empty after the copy"
  printf 'screenshot: %s (%s bytes)\n' "$dest" "$(wc -c < "$dest" | tr -d ' ')"
}

# resolve_radio <option-label> [decision-number] - print "<decision>\t<uid>" for
# the one option that matches, or refuse. Exact name first; a substring only when
# it identifies exactly one option, because guessing here answers the wrong
# decision on the captain's behalf.
resolve_radio() {  # <option> [decision]
  local want=$1 only=${2:-} inv hits count
  inv=$(form_inventory)
  hits=$(printf '%s\n' "$inv" | awk -F'\t' -v want="$want" -v d="$only" \
    '$2 == "radio" && (d == "" || $1 == d) && $4 == want { print $1 "\t" $3 "\t" $4 }')
  if [ -z "$hits" ]; then
    hits=$(printf '%s\n' "$inv" | awk -F'\t' -v want="$want" -v d="$only" \
      '$2 == "radio" && (d == "" || $1 == d) && index($4, want) { print $1 "\t" $3 "\t" $4 }')
  fi
  if [ -z "$hits" ]; then
    printf 'answer: no option matching "%s" on this board. It carries:\n' "$want" >&2
    printf '%s\n' "$inv" | awk -F'\t' '$2 == "radio" { printf "  decision %s: %s\n", $1, $4 }' >&2
    exit 1
  fi
  count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  if [ "$count" -gt 1 ]; then
    printf 'answer: "%s" matches %s options; name one exactly or pass --decision <n>:\n' "$want" "$count" >&2
    printf '%s\n' "$hits" | awk -F'\t' '{ printf "  decision %s: %s\n", $1, $3 }' >&2
    exit 1
  fi
  printf '%s\n' "$hits"
}

# --- answer -----------------------------------------------------------------
#
# Three actions, three fresh snapshots. Gotcha 4 makes that mandatory, not
# careful: the click that selects the option invalidates the uid of the submit
# button resolved beside it.
cmd_answer() {
  local option='' note_text='' decision=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --option) option=${2:-}; shift 2 ;;
      --note) note_text=${2:-}; shift 2 ;;
      --decision) decision=${2:-}; shift 2 ;;
      *) die "answer: unknown argument '$1'" ;;
    esac
  done
  [ -n "$option" ] || die "answer: --option <label> is required (the option's label as it reads on the board)"
  need_bridge

  # An option's accessible name is its WHOLE label text, so a label carrying an
  # explanatory line reads as "Option eins Die Option, die der Treiber wählt."
  # Match the given text exactly first, then as a substring, and refuse an
  # ambiguous one rather than answering a decision nobody asked about.
  local match target_decision resolved_name uid before_confirmation
  match=$(resolve_radio "$option" "$decision")
  target_decision=$(printf '%s\n' "$match" | cut -f1)
  resolved_name=$(printf '%s\n' "$match" | cut -f3-)
  # That inventory is now one generation stale (gotcha 4), so resolve the uid
  # again immediately before the click that uses it.
  uid=$(form_inventory | awk -F'\t' -v want="$resolved_name" -v d="$target_decision" \
    '$1 == d && $2 == "radio" && $4 == want { print $3; exit }')
  [ -n "$uid" ] || die "answer: the option '$option' vanished between snapshots"
  chrome-devtools-axi click "@$uid" >/dev/null 2>&1 \
    || die "answer: could not select the option '$option'"

  if [ -n "$note_text" ]; then
    uid=$(form_inventory | awk -F'\t' -v d="$target_decision" \
      '$2 == "textbox" && $5 == "multiline" && $1 == d { print $3; exit }')
    [ -n "$uid" ] || die "answer: decision $target_decision carries no note field"
    chrome-devtools-axi fill "@$uid" "$note_text" >/dev/null 2>&1 \
      || die "answer: could not write the note"
  fi

  before_confirmation=$(form_subtree "$target_decision" | queued_confirmation)
  uid=$(form_inventory | awk -F'\t' -v d="$target_decision" \
    '$2 == "button" && $1 == d { print $3; exit }')
  [ -n "$uid" ] || die "answer: decision $target_decision has no submit button, so the selection has nowhere to go"
  chrome-devtools-axi click "@$uid" >/dev/null 2>&1 \
    || die "answer: could not submit decision $target_decision"

  # board.js reports what it queued in the form's own .fm-queued box, and says so
  # in is-warn colour when it queued nothing. Read that back rather than assuming
  # the click landed.
  local subtree after_confirmation queued_choice_value
  subtree=$(form_subtree "$target_decision")
  case "$subtree" in
    *"Nichts vorgemerkt"*)
      die "answer: the board reports it queued nothing for decision $target_decision" ;;
  esac
  after_confirmation=$(printf '%s\n' "$subtree" | queued_confirmation)
  queued_choice_value=${after_confirmation#Vorgemerkt: }
  [ -n "$after_confirmation" ] && [ -n "$queued_choice_value" ] \
    || die "answer: the board shows no queued option value for decision $target_decision"
  [ "$before_confirmation" != "$after_confirmation" ] \
    || die "answer: the confirmation already named this option before the click, so this run did not prove the answer was queued"
  good "decision $target_decision queued '$queued_choice_value'${note_text:+ with a note}"
}

# --- send -------------------------------------------------------------------
#
# The queue lives in the Lavish editor chrome, outside the artifact frame. A
# queued answer has not left the board until this is clicked; the poll will wait
# forever otherwise.
cmd_send() {
  local uid
  need_bridge
  uid=$(uid_in_chrome 'button "Send to Agent"')
  [ -n "$uid" ] || die "send: no 'Send to Agent' button on this page - is the bridge pointed at the Lavish session url rather than the artifact url?"
  chrome-devtools-axi click "@$uid" >/dev/null 2>&1 || die "send: could not click 'Send to Agent'"
  good "queued answers sent"
}

# --- poll / end -------------------------------------------------------------

cmd_poll() {
  local board=${1:-}
  [ -n "$board" ] || die "poll: needs the board html file"
  "$LAVISH_SH" poll "$board"
}

cmd_end() {
  local board=${1:-}
  [ -n "$board" ] || die "end: needs the board html file"
  "$LAVISH_SH" end "$board" >/dev/null 2>&1 || true
  good "session ended"
}

# --- doctor -----------------------------------------------------------------

cmd_doctor() {
  printf 'root: %s\n' "$ROOT"
  printf 'board builder: %s\n' "$([ -x "$BOARD_SH" ] && echo present || echo MISSING)"
  printf 'board opener: %s\n' "$([ -x "$LAVISH_SH" ] && echo present || echo MISSING)"
  printf 'browser bridge: %s\n' "$(command -v chrome-devtools-axi || echo MISSING)"
  printf 'chrome: %s\n' "$(command -v google-chrome || echo MISSING)"
  printf 'chromium-cli: %s\n' "$(command -v chromium-cli || echo 'absent (expected on this host)')"
  printf 'this account: %s\n' "$(id -un)"

  # Gotcha 1: measure the bridge's account rather than believing this comment.
  # It shares cmd_shot's staging path for cmd_shot's reason - a file this account
  # cannot delete must not multiply - so it reports the owner only of a file this
  # run actually refreshed.
  local probe capture_result=0
  probe=$(shot_staging_path)
  if command -v chrome-devtools-axi >/dev/null 2>&1; then
    capture_staged_screenshot "$probe" || capture_result=$?
    if [ "$capture_result" -eq 0 ]; then
      printf 'bridge account: %s (from the owner of a screenshot it just wrote)\n' "$(stat -c '%U' "$probe")"
    else
      printf 'bridge account: unmeasured (screenshot exited %s and wrote nothing; open a page first)\n' "$SCREENSHOT_EXIT_STATUS"
    fi
  fi
  printf 'home traversable by others: %s\n' \
    "$(stat -c '%A' "$HOME" | grep -q '.......r.x$' && echo yes || echo 'no - file:// under this home can never work')"
}

# --- selftest ---------------------------------------------------------------

cmd_selftest() {
  local keep=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep) keep=1; shift ;;
      *) die "selftest: unknown argument '$1'" ;;
    esac
  done
  need_bridge

  local workdir board shot url poll_out
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-run-decisionboard.XXXXXX")
  board="$workdir/probe-board.html"
  shot="$workdir/probe-board.png"

  step "1/8 build the fixture board"
  cmd_build --out "$board" --title "Probebrett" --subtitle "run-decisionboard selftest"
  good "board built"

  step "2/8 the no-network guard still bites"
  cmd_guard_check

  step "3/8 open it"
  url=$(cmd_open "$board")
  note "$url"
  case "$url" in
    http://127.0.0.1:*|http://localhost:*)
      die "selftest: the emitted link is on loopback and opens nothing off this machine" ;;
  esac
  good "the board is served on a reachable address"

  step "4/8 drive a browser to it"
  cmd_drive "$url"

  step "5/8 what the rendered board carries"
  note "'poll listening: no' is expected here - nothing is polling yet; step 8 is what arms it"
  cmd_query || die "selftest: the board cannot be answered - see the finding above"

  step "6/8 screenshot it"
  cmd_shot "$shot"

  step "7/8 answer one decision"
  cmd_answer --option "Option eins" --note "Vom run-decisionboard-Treiber gesetzt"
  cmd_send

  step "8/8 prove the answer comes back"
  poll_out=$(cmd_poll "$board" 2>&1) || true
  case "$poll_out" in
    *"Probe-Entscheidung A"*option-eins*"Vom run-decisionboard-Treiber gesetzt"*)
      good "the poll returned the decision, option, and note" ;;
    *)
      printf '%s\n' "$poll_out" >&2
      die "selftest: the poll did not return the decision, option, and note that were sent" ;;
  esac
  printf '%s\n' "$poll_out" | sed -n 's/^  "[0-9]*",/   answer: /p' | head -3

  # The poll reports the board's own health alongside the answer. A fatal
  # artifact failure means the reviewer's page could not be used at some point in
  # this run - seen once here as `artifact-unavailable ... HTTP 500`, not
  # reproduced in three further runs, so it is transient rather than understood.
  # Reporting it is the point: the captain would have met a broken page, and an
  # answer arriving anyway does not make the surface sound.
  local failed=0
  case "$poll_out" in
    *artifact_failures*)
      failed=1
      printf 'FINDING: the board reported a fatal problem with its own surface during this run:\n'
      printf '%s\n' "$poll_out" | sed -n 's/^  \(.*fatal\)$/   \1/p' | head -3
      ;;
  esac

  cmd_end "$board"
  if [ "$keep" -eq 1 ]; then
    printf '\nkept: %s\n' "$workdir"
  else
    rm -rf "$workdir"
  fi
  if [ "$failed" -eq 1 ]; then
    printf '\nthe answer came back, but the board reported its own surface as broken during the run - do not hand this board over on that evidence.\n'
    return 1
  fi
  printf '\nall eight hops held: a decision board built here can be answered, and the answer comes back.\n'
}

# --- dispatch ---------------------------------------------------------------

cmd=${1:-}
[ "$#" -gt 0 ] && shift || true
case "$cmd" in
  selftest) cmd_selftest "$@" ;;
  doctor) cmd_doctor "$@" ;;
  guard-check) cmd_guard_check "$@" ;;
  fixture) fixture_body ;;
  parse) fold_snapshot | parse_inventory ;;
  build) cmd_build "$@" ;;
  open) cmd_open "$@" ;;
  drive) cmd_drive "$@" ;;
  query) cmd_query "$@" ;;
  shot) cmd_shot "$@" ;;
  answer) cmd_answer "$@" ;;
  send) cmd_send "$@" ;;
  poll) cmd_poll "$@" ;;
  end) cmd_end "$@" ;;
  -h|--help|help|'') usage ;;
  *) die "unknown command '$cmd'; run --help" ;;
esac
