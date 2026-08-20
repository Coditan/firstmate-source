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

This skill exists because a seven-decision board reached the captain with no clickable controls.
It drives the rendered board and proves an answer returns instead of assuming a board that renders can be answered.

Pointed at a copy of the real `decisions-2026-08-17.html`, `query` reported `decision cards: 0` and refused it from the rendered page alone.
The file agrees: seven `fm-card` decision cards, and its only `<form` and `<input type="radio">` are inside the doc comment of the inlined `board.js`.

## The driver is the primary path

    .agents/skills/run-decisionboard/fm-run-decisionboard.sh selftest

Run it before trusting a board on this host.
In a sandboxed worker, set `TMPDIR` to a writable scratch directory and `XDG_RUNTIME_DIR` to an owned mode-700 directory inside that worker's worktree before running it; an unreadable temp board makes the Lavish open step return HTTP 500.
Re-measure the host with:

    .agents/skills/run-decisionboard/fm-run-decisionboard.sh doctor

## Driving a real board

    D=.agents/skills/run-decisionboard/fm-run-decisionboard.sh

    "$D" build --out /tmp/fm-manual-board.html --title "Probebrett" --subtitle "manueller Durchlauf"
    url=$("$D" open /tmp/fm-manual-board.html)
    "$D" drive "$url"
    "$D" query
    "$D" shot .lavish/run-decisionboard-evidence-2026-08-17.png
    "$D" answer --option "Ja" --note "Zweite Karte, manuell beantwortet"
    "$D" send
    "$D" poll /tmp/fm-manual-board.html
    "$D" end /tmp/fm-manual-board.html

`build` without `--body` uses the fixture; pass `--body <fragment>` for a real board.

## Host constraints

- `file://` cannot work under this home.
- Take the URL from `bin/fm-lavish.sh` and never hardcode a port.
- Drive through the accessibility snapshot rather than `eval`.
- Re-resolve accessibility uids before every action.
- Never treat a screenshot's exit status as evidence.
- Never conclude from `query` alone that a long board is missing controls: a plain accessibility snapshot truncates around 21k characters, mid-form on a board with enough decisions, and `query` reads `snapshot --full` for exactly that reason.

The driver header owns the measured reasoning and implementation details behind these constraints.

## Follow-up when PR 117 merges

Missing note fields are report-only today because the current board contract permits choice-only answers.
When PR 117 merges, change the `FM_RUN_DECISIONBOARD_NOTE_REQUIRED` default from `report` to `refuse`.
The driver cannot track that requirement automatically because no machine-readable owner exists for it.

## What this skill does not do

It never answers a decision on the captain's behalf.
The fixture stands for nothing; a real answer belongs to the captain, and recording one belongs to `.agents/skills/decision-hold-lifecycle` and `bin/fm-decision-hold.sh resolve`.
It never edits `bin/board-assets/` or `bin/fm-board.sh`; it exercises them and reports findings.

## Maintaining this file

Keep it short and keep the driver first.
Every command block here must be one that was actually run and worked.
Mechanics and full reasoning belong in the driver header because that matches this repo's one-owner rule and the task's own must-stay-SHORT criterion.
