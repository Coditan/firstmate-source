---
name: run-decisionboard
description: >-
  Run a decision board end to end on this host: build it, open it, drive it in a real browser, screenshot it, answer a decision programmatically, and prove the answer comes back through the poll.
  Use when the captain invokes /run-decisionboard, before handing him any board that carries decisions, when a board must be screenshotted or driven rather than only built, and whenever a board's controls, its rendering, or its answer path need to be checked rather than assumed.
  It proves a board can be answered; it never decides one, and it is not the skill that composes a real decision board.
user-invocable: true
metadata:
  internal: true
---

# Run a decision board

On 2026-08-17 a seven-decision board went to the captain with no way to answer it.
Every decision carried its options in prose and nothing on the page could be clicked, so he answered in chat instead - the channel this fleet has measured as having no memory.
Nothing caught it, because nothing had ever driven a board programmatically.
A board that is built and looked at proves it renders; only a board that is driven proves an answer comes back.

This skill is that missing check.
`.agents/skills/decisionboard` composes a real board and `docs/board-layout.md` owns its markup; this one exercises whatever board you hand it.

## The driver is the primary path

    .claude/skills/run-decisionboard/fm-run-decisionboard.sh selftest

That is the whole loop on a built-in fixture board, with every hop asserted: build, guard, open, drive, query, screenshot, answer, send, poll.
It ends with `all eight hops held` or it stops on the first hop that did not.
Run it before trusting a board on this host, and read its header for the measured host facts it is built around.

Re-measure the host itself with:

    .claude/skills/run-decisionboard/fm-run-decisionboard.sh doctor

Measured on `crew-hlr` on 2026-08-17, `doctor` reported the browser bridge running as `crew` while firstmate runs as `coditan`, and this home not traversable by that account.
Both facts are why the sections below exist.

## Driving a real board

The same subcommands, against a board you built yourself.
Every line below was run in the session that wrote this file.

    D=.claude/skills/run-decisionboard/fm-run-decisionboard.sh

    "$D" build --out /tmp/fm-manual-board.html --title "Probebrett" --subtitle "manueller Durchlauf"
    url=$("$D" open /tmp/fm-manual-board.html)
    "$D" drive "$url"
    "$D" query
    "$D" shot .lavish/run-decisionboard-evidence-2026-08-17.png
    "$D" answer --option "Ja" --note "Zweite Karte, manuell beantwortet"
    "$D" send
    "$D" poll /tmp/fm-manual-board.html
    "$D" end /tmp/fm-manual-board.html

`build` with no `--body` uses the built-in fixture; pass `--body <fragment>` to drive a real board instead.
`open` prints the URL and nothing else, so it can be captured.
`query` prints what the board carries and exits non-zero with a `FINDING:` line when a decision on it cannot be answered.
`poll` returned the answer that `answer` and `send` put in, which is the one hop that proves the loop closed:

    prompts[1]{uid,prompt,selector,tag,text}:
      "1","Entscheidung \"Probe-Entscheidung B\": ja - Anmerkung des Captains: ...",...,decision,"Probe-Entscheidung B: ja"

## Gotchas, each one measured here

Every item below was hit on this host, not inferred.
The driver already handles all of them; they are written down because an agent reaching past the driver will hit them again in the same order.

**The browser bridge runs as a different UNIX account.**
Two vessels share this machine, and `chrome-devtools-axi` drives Chrome as `crew`, not as the account firstmate runs as.

**So `file://` under this home always fails**, with `ERR_FILE_NOT_FOUND` on a file that demonstrably exists.
Do not chase a missing file - it is a permission boundary wearing a not-found error.
The board's mode is a red herring: `/home/coditan` is `drwxr-x---`, so that account cannot traverse into the home at all, and `chmod 644` on the board changes nothing.
The same board copied to `/tmp` opens immediately.
Serve boards over HTTP through `bin/fm-lavish.sh`, which is the sanctioned path anyway.

**And a screenshot to a path the bridge cannot write EXITS 0, PRINTS THE PATH, AND WRITES NOTHING.**
It does not fail; it lies, and a `mktemp -d` scratch dir under `/tmp` is enough to trigger it because `mktemp -d` is mode 0700.
Screenshot into `/tmp` itself, then copy the file back, and verify it exists, is non-empty, and changed in this run.
Never treat a screenshot's exit status as evidence that a screenshot exists.

**Lavish binds the tailnet address only.**
`http://127.0.0.1:<port>/...` returns `ERR_CONNECTION_REFUSED`; the same path on the tailnet hostname returns 200.
Take the URL from what `bin/fm-lavish.sh` prints and never hardcode a port - it is claimed at runtime because neighbouring vessels hold others, and a previous board went out on 4387 and 4388 for exactly that reason.

**The board renders inside a sandboxed iframe.**
The top document is the Lavish editor chrome; the artifact is at `/artifact/<id>/index.html?artifact_revision=N&artifact_load_token=...`.
The frame carries `sandbox="allow-scripts allow-forms allow-popups allow-downloads"` with no `allow-same-origin`, so it is an opaque origin: `iframe.contentDocument` is `null` and no `eval` from the top document can read board content at all.
Drive it through the accessibility snapshot instead, whose uids do cross the frame.
An `eval` against the top document finds zero decision forms and makes a healthy board look broken.

**Accessibility uids are snapshot-generation scoped.**
Every bridge command mints a new generation and invalidates the last one: `Stale ref @g1093:10_19: from snapshot generation 1093, current is 1094.`
Re-snapshot and re-resolve immediately before every single action.
Resolving a radio and its submit button from one snapshot and then clicking both fails on the second click.

**An accessible name can contain a literal newline.**
A `<br>` inside an option label puts `LineBreak "` and its closing quote on separate lines, so one node spans two.
A line-oriented parser then reads that stray quote as a top-level node and walks out of the artifact frame - which is how this driver first reported a two-decision board as one decision with no note field and no submit button.
Fold every line that does not start with `uid=` onto the node above it.

**Stop the bridge before pointing it anywhere.**
`chrome-devtools-axi stop` first, or a process from an earlier attempt is reused with its old environment.

**The bridge is shared with the other vessels on this machine**, which is the same fact as the different UNIX account, seen from the other side.
The viewport arrives at whatever size somebody else left it: one run here screenshotted a 320px phone layout, which reads as a rendering fault and is not one.
`drive` therefore sets the size explicitly rather than inheriting it.
The `stop` above is the other half of this - it can knock over a neighbour's browser session, and that is a cost this driver accepts rather than one it avoids.

**`chromium-cli` is not on this host.**
`google-chrome` and `chrome-devtools-axi` are.

**The poll reports the board's own health, and a fatal report there outranks a successful answer.**
`artifact_failures[1]{kind,detail,severity}: artifact-unavailable,the artifact document responded with HTTP 500,fatal` came back once here alongside an answer that had arrived perfectly.
It did not reproduce in three further runs, so it is transient rather than understood - but the captain would have met a broken page, and an answer arriving anyway does not make the surface sound.
`selftest` fails on it deliberately; read the poll's own output, never only the answer you were hoping for.

**A board with no armed poll says so on screen.**
"Your agent is not listening. If this persists, ask your agent to poll for updates from Lavish." appears in the conversation panel, and `query` reports it as `poll listening: no`.
It is worth asserting because a poll dies with the session that armed it, and a board listening to nobody is indistinguishable from a healthy one in a screenshot.

## What this skill does not do

It never answers a decision on the captain's behalf.
The fixture board it drives stands for nothing and decides nothing; a real answer belongs to the captain, and recording one belongs to `.agents/skills/decision-hold-lifecycle` and `bin/fm-decision-hold.sh resolve`.
It never edits `bin/board-assets/` or `bin/fm-board.sh` - it exercises them, and a board that fails `query` is a finding to report, not a file to patch from here.

## Maintaining this file

Keep it short and keep the driver first.
Every command block here must be one that was actually run and that worked; a line copied from a README is exactly how this surface stopped matching the host before.
Mechanics, flags, and the full reasoning behind each gotcha belong in the driver's own header, not here.
