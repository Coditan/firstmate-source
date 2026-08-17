---
name: decisionboard
description: >-
  Lay the fleet's captain-actionable decisions out as a visual board, on the shared standard layout, and open it for the captain.
  Use when the captain invokes /decisionboard, asks to see the open decisions as a board, asks what is waiting on him visually, or asks for the decision backlog laid out rather than listed.
  For one named undertaking and where it stands against its own destination, use the sea chart instead.
  Presents only: it groups the per-member panel records by originating investigation and keeps the judge's record where a judge ruled, without verifying that the judge covered every question the analysts raised, shows what each decision gates, and never records an answer.
  Shows only what the captain-actionable surface returns, which is not every open captain decision: one blocked by another record never reaches that surface and so never reaches this board.
user-invocable: true
metadata:
  internal: true
---

# Decision board

Lay every captain-actionable decision out as one visual surface, so the captain can see what is waiting on him, what each answer unlocks, and which questions are really the same question asked three times.

This skill **presents**.
It never writes, resolves, reorders, or closes a decision.
`.agents/skills/decision-hold-lifecycle` owns the decision lifecycle and `bin/fm-decision-hold.sh resolve` owns recording an answer.
A board that quietly changed a record would put a second owner on that contract.

## This board, or a sea chart

This board is a **standing inbox**: everything waiting on the captain, across every project and investigation, with no destination and no end state.
It is never finished - it empties and refills.

`.agents/skills/sea-chart` is the other shape: **one undertaking, one destination**, finished when the way is clear.
Because this board has no scope, nothing can be outside it, so it carries no course boundary and no fog towards anything - that is what the chart is for.

If the captain names one investigation or undertaking and asks where it stands, load that skill instead of this one.
If he asks what is waiting on him, or what to answer next, this is the right surface.

## Why a board and not a list

A list understates two things that a board can show at a glance.

A model panel registers its holds per member, so one question arrives as up to three records.
On 2026-07-31 the open set was 26 records that collapsed to 12 - a list would have told the captain that more than twice as much was waiting on him as actually was.

And a list flattens the gate structure.
When one strategic answer settles five downstream questions, a flat list gives no reason to answer that one first, which is how these decisions sat unanswered for days.

## Sequence

1. **Read the structured inventory.**
   `bin/fm-decision-inventory.sh --summary` for a read, `--json` for the data to lay out.
   It reads the structured decision inventory through `bin/fm-bearings-snapshot.sh` and owns the collapse rule, its limits, and the output contract.
   Never assemble decisions from report prose, chat, or terminal output - the same rule the bearings header states for itself.

2. **Judge what each decision is actually about.**
   The inventory gives identity, grouping, and the recorded summary.
   What is at stake, what the options are, and which evidence makes one option obvious are yours to write, from the originating report and the hold's own reason.
   That part cannot be scripted, and it is most of a board's value.

3. **Establish the gate structure, and label how you know it.**
   See "Showing the gate structure" below.

4. **Write the body fragment and build the board.**
   `bin/fm-board.sh --title <t> --subtitle <s> --body <fragment> --out .lavish/<name>-<date>.html`
   The builder owns the standard layout and refuses a board that would reach the network.
   `docs/board-layout.md` lists the components and the markup each expects, and `docs/examples/board-body-decision.html` is the worked body to copy.
   **Every decision on the board carries selectable options and a note field**, per "A decision the captain cannot click is not on the board" below.
   Open the sheet with its reservation block, per "What the board must not claim" below.
   Every decision card carries its `.fm-variants` block, per "Every folded record stays visible" below.
   Do not hand-write a board's styling or scripting: that is exactly the drift this layout exists to stop.
   Do not hand-write the vessel name or the tally strip either: the builder writes the first into every board's header and `bin/board-assets/board.js` fills the second, and a body that types either one has made a second copy that can go stale.

5. **Open it.**
   `bin/fm-lavish.sh <file>`, never bare `lavish-axi`, which emits a link that opens nowhere but this machine.

6. **Poll for the captain's answers,** then route each one through `bin/fm-decision-hold.sh resolve` under the `decision-hold-lifecycle` contract.
   The board queues the captain's answers; it does not record them.

## Showing the gate structure

Show all three relationship kinds, and make clear on the board **how each one was established**.
Confidence that is not shown is confidence the captain cannot check.

- **Recorded gate** - a decision another item is genuinely blocked by, from the backlog's own dependency edges.
  Draw it as a solid edge. This is proven.
- **Same investigation** - decisions sharing an origin group, from the inventory.
  Draw it as a cluster. This is structural, and it is weaker than a gate: shared origin means related, not blocking.
- **Named gate** - your own reading that one decision decides others.
  Label it as your reading on the board itself, in the captain's own words, not as a recorded fact.

Pre-answer gating between decisions is **not** recorded structurally today.
`decision-hold-lifecycle` step 6 creates dependency edges only after the captain decides, which is deliberate: the edges exist to route an answer to dependent work.
So a named gate stays a named gate.
If you find that a gate ought to be durable, raise it with that skill's owner rather than inventing a second place to record it.

## A decision the captain cannot click is not on the board

A board that asks the captain to decide something **must** present selectable options, with a free-text note beside them, for every decision on it.
Stating the options in the card's prose and leaving him to answer in chat does not count, and it is not a lesser version of the same thing.

This is measured, not a preference.
The board built on 2026-08-17 was presentation-only: seven decisions, every one with its options written out in the text, and no control anywhere to choose one.
He answered in chat, which is the one channel with no memory - the fleet has already measured that decisions asked in conversation get lost while ones asked on a board get answered.
So a board that lays the decisions out beautifully and offers nothing to press has moved the question into the channel this whole surface exists to get it out of.

Three things this obligation includes, each for its own reason.

- **The note field is not optional decoration, and it is read.**
  Measured on the board of 2026-08-16, two of twenty answers carried a note that contradicted the selected option, and the note held what the captain actually meant both times.
  Read the note against the selection before routing an answer to `bin/fm-decision-hold.sh resolve`, and when the two disagree, the note is the evidence and the selection is not.
- **A settled option stays on the sheet, struck.**
  An option ruled out by an earlier decision is rendered with `is-void` rather than dropped, because a sheet that silently removes an answered option hides that it was ever asked.
- **What is queued is not what is sent.**
  The tally strip counts the decisions that have not been sent back, and it counts a chosen-but-unsent answer as still outstanding.
  `docs/board-layout.md` owns those semantics; nothing on the board may report a chosen answer as delivered.

`lavish-axi playbook input` owns the mechanics, `docs/board-layout.md` owns the markup, and `bin/board-assets/board.js` implements the submit path once so a body never repeats it.

## Every board says whose board it is

Every board carries the building vessel's name in its header.
It is a property of the **builder**, not of the board's subject: a board this vessel builds about another vessel's work still reads this vessel's name.
`bin/fm-board.sh` writes it from the name the fleet already records for this seat, and refuses to build a board it cannot resolve one for, so there is nothing to do here except not write it into the body by hand.

Both of these rules are fleet-wide, and each vessel applies them with **its own** design language and **its own** name.
Do not carry this vessel's design language to another one.

## What the board must not claim

The collapse keeps the judge's record for a judged group and folds the other members' records away.
That rests on an assumption the tool cannot check: that the judge raised one hold per distinct question the analysts raised.
Nothing verifies it, so the count is what the collapse kept, not a proven count of distinct questions.
Say that on the board rather than presenting the number as exact.

Pairing a specific folded record to a specific decision is separately best-effort, and the inventory marks which pairings it is confident about.
Render a confident pairing under its decision; render everything else at group level as further variants of the same investigation.
Never assert which question an unpaired variant restates.

A decision blocked by another record is not on this board at all, and nothing on the board marks that it is missing.
Captain-actionability is a single predicate in `bin/fm-fleet-snapshot.sh` and a record blocked by anything fails it, so that decision leaves `decisions_open` entirely; real blockers land it in `gates`, while a dangling target found nowhere is surfaced separately through bearings `integrity[]`.
Measured on a two-decision fixture, adding one `blocked-by` edge takes the reported inventory from "records: 2 decisions kept: 2" to "records: 1 decisions kept: 1", with no footnote anywhere.
So this is the captain-actionable set, not the open set: say that on the board in the same breath as the unverified fold, and never present it as everything waiting on him.

These sentences have a component and a position, and both matter.
They go in `.fm-reserve`, the reservation block, **above the entries** - a declaration of what the sheet does not show, printed under the entries, is one he reads after he has already decided.
`docs/board-layout.md` owns its markup.

For one named undertaking, `.agents/skills/sea-chart` reconciles its own records against the backlog and reports each withheld one by name with its cause - fleet-wide there is no such count yet.
The blocker is the only shape of this loss left, and it belongs to the snapshot rather than to this board: the predicate reads the hold kind alone, so a captain hold carried on a record of any other kind does reach here.

## Every folded record stays visible

Because the fold is unverified, no record may vanish from the board.
Each decision renders the records folded into it as a collapsed list, and each group renders its unpaired variants the same way, so a question only an analyst raised is discoverable by eye instead of silently absent.

Use `.fm-variants`, the details/summary block `docs/board-layout.md` documents for exactly this.
Do not invent another component, and do not omit the block when a decision folded nothing in - an empty fold is itself worth seeing.

## Language

Give the captain his board in the language the task was set in.
A German request gets a German board.
A German board is written with real umlauts - ä, ö, ü, and ß - never ae, oe, ue, or ss transliteration.
That applies to the board's own text; code identifiers, attribute names, and CSS values keep their spelling.

## Scope

One board, from the current inventory, opened for the captain.
It is read-only with respect to every decision on it.
If the inventory is empty, say so plainly in chat and do not build a board for nothing.
