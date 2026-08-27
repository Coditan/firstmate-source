---
name: captain-surfaces
description: >-
  Agent-only routing for every way something reaches the captain other than plain chat.
  Use before building or opening a review board, a decision board, or a sea chart, before sending him anything while he is out of session, and before producing a PDF deliverable.
  Owns which surface fits, the entry point each one must go through, and the rule that no surface is a second definition of what deserves his attention.
user-invocable: false
metadata:
  internal: true
---

# captain-surfaces

This skill is the single owner of surface choice and surface mechanics for captain-facing delivery.
It never widens what reaches him: `AGENTS.md` section 9's list of what to escalate is the only bar, and this skill only decides how something already on that list is carried.
Section 9's translation contract applies to every surface here, not only to chat.
`AGENTS.md` section 9 carries the trigger that loads this skill.

## Choosing the surface

Use plain chat for a yes-or-no decision and `bin/fm-lavish.sh` only when several options or a structured report benefit from a visual surface; it is the only sanctioned way to open a review board, because bare `lavish-axi` hands the captain a link that opens nowhere but this machine (`docs/lavish-access.md`).
Build every board with `bin/fm-board.sh` rather than hand-writing its layout, so it makes no network request and opens immediately (`docs/board-layout.md`).
Before handing the captain a board that carries decisions, and whenever the captain invokes `/run-decisionboard` or a board must be driven or screenshotted rather than only built, load the `run-decisionboard` skill: a board that was only looked at has never been shown to be answerable, which is how seven decisions once reached him with nothing on the page to click.
When the captain invokes `/decisionboard` or asks to see the open decisions laid out visually, load the `decisionboard` skill.
When the captain invokes `/sea-chart` or asks where one named undertaking stands against its own destination, load the `sea-chart` skill.
The board is the fleet-wide standing inbox with no destination and the chart is one undertaking with one; both skills state that boundary from their own side, so do not merge them.

## Reaching him out of session

When something on section 9's list must reach the captain while he is not in a session, send it with `bin/fm-tg-send.sh`, which carries one message, or one explicitly named file, to him and refuses rather than reporting a delivery nobody got; it is a delivery path and never a second definition of what deserves his attention, so that section remains the only bar (`docs/telegram-outbound.md`).
Send on the event, never on a schedule, and never discard that command's exit status, because a notification path that fails quietly gets trusted while it is dead.

## Documents

Generate a PDF deliverable only through `bin/fm-pdf-finish.sh`, which refuses to publish a file a real reader cannot read, because a browser-printed document looks correct on screen and fails at the recipient (`docs/pdf-output.md`).
