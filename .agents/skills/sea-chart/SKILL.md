---
name: sea-chart
description: >-
  Lay out one undertaking as a sea chart: its destination, what is already decided, what is takeable now, its fog, and its course boundaries.
  Use when the captain invokes /sea-chart, names one investigation or undertaking and asks where it stands, asks what is still unclear on a specific piece of work, or asks what is deliberately out of scope for it.
  For everything waiting on the captain across the whole fleet, with no single destination, use the decision board instead.
  Presents only: it reads the backlog and never files, answers, or closes anything, and it prints its own incompleteness rather than implying it is a full picture.
user-invocable: true
metadata:
  internal: true
---

# Sea chart

Lay one undertaking out as a chart: where it is going, what has been settled, what can be picked up now, where the fog is, and where the course deliberately ends.

This skill **presents**.
It never writes, files, resolves, or closes anything.
`bin/fm-decision-hold.sh` owns recording an answer and `.agents/skills/decision-hold-lifecycle` owns the decision lifecycle; a chart that quietly changed a record would put a second owner on that contract.

## Which of the two surfaces this is

The fleet has two, they look similar at a glance, and choosing wrong is silent.
The difference is the destination.

| | Decision board | Sea chart |
| --- | --- | --- |
| Question it answers | What is waiting on me right now? | Where does this one undertaking stand? |
| Scope | The whole fleet, every project | One undertaking |
| Destination | None. It is a standing inbox. | One, and it is the point of the thing. |
| Finished when | Never. It empties and refills. | The way is clear. |
| Can carry "out of course" | No | Yes |

**A fleet-wide surface cannot carry a course boundary at all**, because there is no scope for anything to be outside of, and fog cannot be fog *towards* anything.
That is why these are two artefacts and not one renamed: merging them would have damaged both.

If the captain asks what is waiting on him, or what to answer next, that is the board - load `decisionboard` instead.
If he names one investigation or undertaking, that is this.

## Sequence

1. **Resolve which undertaking.**
   The chart id is the originating undertaking's own task id, the same id its decision holds are already named after.
   If the captain named it in prose, match it against the backlog before drawing anything, and say which one you picked.

2. **Assemble the chart.**
   `bin/fm-sea-chart.sh <chart-id> --summary` for a read, `--json` for the data to lay out.
   It owns the membership rule, the reconciliation against the backlog, the ageing probe, and the three incompleteness numbers.
   Never assemble a chart from report prose, chat, or terminal output - the same rule the bearings header states for itself.
   If it refuses for want of a destination, that refusal is the answer: file the undertaking first, and do not draw a chart with a blank cover.

3. **Judge what the undertaking is actually about.**
   The assembler gives identity, structure, and the recorded wording.
   What is at stake and which evidence makes an option obvious are yours to write, from the originating report and each hold's own reason.
   That part cannot be scripted, and it is most of a chart's value.

4. **Write the body fragment and build it.**
   `bin/fm-board.sh --title <t> --subtitle <s> --body <fragment> --out .lavish/sea-chart-<chart>-<date>.html`
   The builder owns the standard layout and refuses a chart that would reach the network.
   `docs/board-layout.md` lists the components and the markup each expects, and owns the German-umlaut rule for any chart written in German.
   Do not hand-write styling or scripting: that is exactly the drift this layout exists to stop.

5. **Open it.**
   `bin/fm-lavish.sh <file>`, never bare `lavish-axi`, which emits a link that opens nowhere but this machine.

6. **Route anything the captain answers** through `bin/fm-decision-hold.sh resolve` under the `decision-hold-lifecycle` contract.
   The chart queues answers; it does not record them.

## What must appear on the chart

**The destination, at the top, in the captain's own words.**
It is read, never invented: the undertaking's own title, or the one question a panel gave every member, or its surviving report.
A chart whose destination came from the panel question or the report says which, because that is weaker than a titled undertaking.

**The three incompleteness numbers, on the chart itself and not in a footnote.**
Use `fm-stats`.
They are the reason this is worth building, and a chart that drops them is worse than no chart:

- how many decision records this chart owns, how many of those reached the actionable surface, and how many were folded away
- how many were **withheld** from the actionable surface
- how many are **possibly already answered**

A withheld or possibly-answered count above zero is not a footnote.
Render those records in full, with the blocker or the closed twin named, near the top.
Withheld records do not all carry the same news, and each one says which it is in `cause` with the reason in `why`.
A `blocked` record is a decision the fleet has lost track of and belongs at the top with its blocker named; an `in-flight` one is simply being worked right now, and `no-hold` or `other-hold` mean the record never asked the captain anything in the first place.
A `stale-edge` record belongs at the top too, for the opposite reason: nothing is holding it, the blocker it names is Done in the archive, and the captain can answer it now once somebody clears the edge.
Print each `why` beside its record so the difference is on the page rather than in the reader's head, and never let the milder causes crowd a `blocked` record down the list or off it.
The whole point is that a chart which quietly omits an open decision is more harmful than no chart at all.

**Every folded record stays visible.**
Use `.fm-variants`, exactly as the decision board does, for the same reason: the fold rests on an assumption nothing verifies, so a question only an analyst raised must be discoverable by eye rather than silently absent.

**Fog, smaller than decisions.**
A row in an `fm-panel` table, not a card with stakes and evidence.
Fog is a signpost for where the investigation still has to go, not a question for the captain, and nothing ever promotes it to one.

**Out of course, set quietly at the bottom, in its own section.**
These never rise.
Showing them is the whole point of having a scope.

**The limits, verbatim.**
The assembler emits `limits[]`.
Print every one of them on the chart, in the chart's language, without softening.
Do not drop the one about unverified judge coverage because the chart has a nicer name than the board: that honesty is the pattern being copied, not a wart to grow out of.

## The marking for unsupervised work is never a badge

Work that may be run unsupervised is marked in **two steps**, never with one plaque, using `fm-statusline`:

    [✓ may be worked unsupervised] -- [2 supervised review, then the pipeline]

The second step stands next to the first and is never reached.
A single badge reads as "cleared", which is the one thing this marking must never promise, and the eye reads a lone plaque as done.

In the legend, with its source:

> A marked stretch may be **worked** unsupervised.
> It may never **land** unsupervised.
> A `gnhf` branch is never delivered from its own worktree: a supervised worker branches from the tip commit, reviews the work as first reader, and drives it commit by commit through the pipeline.
> Two earlier overnight runs turned up real defects at exactly this step. - `data/learnings.md`, 2026-07-15

The assembler emits `navigation` as a pair for this reason, never as a boolean: there is no scalar for a renderer to turn into a lone badge.
Whether a piece of work is destructive, irreversible, security-sensitive, or outward-facing is recorded nowhere per record and is not derived - that judgment stays the always-loaded rule in `AGENTS.md` sections 7 and 9.

## Filing fog and course boundaries

The chart reads them; it never files them.
They are ordinary backlog records, owned by the backlog contract in `AGENTS.md` section 10, which is where their spelling and their meaning live.
Neither can ever be mistaken for a captain decision, because captain-actionability requires `kind: captain` and neither kind is that - structure, not a rule in prose.

A fog patch that becomes sharp is not promoted in place: close it, then register the real decision through `bin/fm-decision-hold.sh`, which already accepts later keys on a live or torn-down origin.
A course boundary never rises at all.

## Scope

One chart, for one named undertaking, from the current records, opened for the captain.
It is read-only with respect to every record on it.
If the undertaking has no destination, say so plainly and do not build a chart for nothing.
