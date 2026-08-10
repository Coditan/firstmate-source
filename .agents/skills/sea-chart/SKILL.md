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

> **This skill amends [Wayfinder](https://github.com/mattpocock/skills/tree/main/skills/engineering/wayfinder), by Matt Pocock, from [`mattpocock/skills`](https://github.com/mattpocock/skills), used under the MIT licence.**
> It is not an original design.
> Wayfinder's destination, fog of war, out-of-scope boundary, and four of the five sections of its map body are its own.
> This version keeps them, and then diverges: it reads records rather than authoring them, adds the incompleteness numbers and the withheld-records reconciliation that a lossy source surface forces, and drops Wayfinder's ticket types, its claim, and its low-resolution-then-zoom reading.
> **The largest divergence is that Wayfinder is a planning instrument that sets a course, with two write modes and no viewing mode, and this version kept only the half that shows the result.**
> The read-only rule below is sound for recording the captain's answer and was over-applied to the rest.
> Authoring and sizing the units has an owner again in `/to-backlog`, adopted from the same repository's to-tickets skill, and a unit filed there lands on this chart by its id prefix; the chart's own authoring acts, graduating fog and bounding the course, still collide with no owner.
> That remainder is a filed defect, not a licence to write: until it is decided and fixed, the read-only rule below binds in full.
> `docs/sea-chart-provenance.md` carries the copyright notice, the full licence text, the comparison, that test, and the defects it exposed.

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
   It owns the membership rule, the reconciliation against the backlog, the ageing probe, the incompleteness numbers, and the reports of what it could not place or found misfiled.
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

**The incompleteness numbers, on the chart itself and not in a footnote.**
Use `fm-stats`.
They are the reason this is worth building, and a chart that drops them is worse than no chart:

- how many decision records this chart owns, how many of those reached the actionable surface, and how many were folded away
- how many are **not carried by any decision section**, and how many of those (`counts.withheld_folded`) the fold dropped rather than the surface never returning them
- how many are **possibly already answered**

The second number covers two different situations and its wording has to stay true of both: a record the actionable surface never returned at all, and one it did return before the fold dropped it.
Print `withheld_folded` beside it, or the same record is counted once as folded and once here with nothing on the page saying they are one record.
A withheld or possibly-answered count above zero is not a footnote.
Render those records in full, with the blocker or the closed twin named, near the top.
Withheld records do not all carry the same news, and each one says which it is in `cause` with the reason in `why`.
A `blocked` record is a decision the fleet has lost track of and belongs at the top with its blocker named; an `in-flight` one is simply being worked right now, and `no-hold` or `other-hold` mean the record never asked the captain anything in the first place.
A `stale-edge` or `dangling-edge` record belongs at the top too, for the opposite reason: nothing is holding it, the blocker it names is either Done in the archive or a real record nowhere, and the captain can answer it now once somebody clears the edge.
An `unpaired-variant` record is one the surface did return and the fold then dropped, because no judge ruling in its group carries its decision key - it is a question only an analyst raised, and the rule below about folded records is exactly why it is listed here rather than left between the two surfaces.
A `folded-elsewhere` record is the other one the surface returned: the fold hung it as a variant under a ruling of a DIFFERENT undertaking, so no section of this chart can carry it without drawing a record this chart does not own.
Those two causes together are what `counts.withheld_folded` counts, and the second one arises only for a record a member list assigned, because the fold groups by the id such a record kept from before this undertaking was named.
Print each `why` beside its record so the difference is on the page rather than in the reader's head, and never let the milder causes crowd a `blocked` record down the list or off it.
The whole point is that a chart which quietly omits an open decision is more harmful than no chart at all.

**Anything in `unplaced[]`, rendered before the sections it is missing from.**
These are members the chart counted and could not put anywhere, and they are the one report that must never be dropped in rendering, because dropping it restores exactly the fault it exists to catch.
An empty section is read as a statement about the course - "there is no fog here" - so a member the chart could not recognise turns into a claim nobody made.
Each entry names its `kind` and `hold_kind` beside the `why`, because those two fields are what get confused, and a `no-kind` cause means the record was filed without the kind that `AGENTS.md` section 10 requires rather than that the course is clear.
A `marker-kind-mismatch` cause means the id and the kind disagree - the id claims a dark patch or a boundary and the kind does not - so one of the two is a typo, and the record is deliberately kept out of `takeable[]` until they agree rather than offered as work to pick up on a kind nobody can trust.
The entries arrive `kind_defect` first and must be rendered in that order, under headings that keep the two apart: a kind the chart cannot classify can leave a whole section reading empty, while held or blocked ordinary work is only work this chart has no section for, and letting the second crowd out the first is how the empty sections went unnoticed in the first place.

**Anything in `membership_defects[]`, directly under the member count.**
These are member-list lines the assembler could not honour, and the member count is the number they call into question: a refused line is a record somebody wrote down as belonging here that the chart is not drawing.
Render the `cause` beside the `why`, because the causes are different news and only one of them is about the record.
A `contested` entry is the loud one and arrives first: two undertakings both claim that record, no record owns it by prefix to break the tie, so the chart draws it on neither and `claimed_by` names the other one so the collision can be found from either chart.
`owned-elsewhere` and `claimed-elsewhere` are the two sides of the same wrong line, and they are the ones to read together.
`owned-elsewhere` means this chart's own list named a record another undertaking already owns by its id: the entry is refused and the record is NOT drawn here.
`claimed-elsewhere` is the only cause that is not about a line of this chart's list at all - another chart's list named a record this chart owns by construction - and it withdraws nothing: **the record is still drawn here**, and the foreign line is the one to delete.
Render it as a wrong line elsewhere rather than as a doubt about the record, and never take it as a reason to leave the record out.
`qualified` and `malformed` entries were refused at the boundary - one home, bare ids - and `unresolvable` means the record is not in this home at all, which may equally mean it was deleted, renamed, or never lived here.
A `redundant` entry costs nothing: the prefix rule already draws that record and the line merely says so twice.
Never render a refused entry as a member, and never drop any of these: a member named and missing is invisible, while a member named and wrong is visible by eye.

**Anything in `misfiled[]`, above the sections it calls into question.**
These members carry an id marker and a record kind that disagree, and unlike an unplaced member most of them ARE drawn - a boundary filed with the fog kind sits under FOG, while OUT OF COURSE, which is where its id says to look for it, is drawn without it.
Render the `marker` found and the `kind` found side by side, because the chart does not know which of the two is the typo and the reader has to decide.
Never quietly correct one to match the other while rendering; the disagreement is the finding.
Each row carries its own `why` naming the section that drew it and the section left short, both computed per record; a heading over these rows must not restate either, because what is true of one row is not true of the next.

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

## When an undertaking is named over work that already exists

A chart draws a record whose id is the chart id or begins with it, so work filed under an undertaking after that undertaking exists needs nothing further.
Work that existed BEFORE the undertaking was named carries its own historical id and the prefix rule cannot see it - and it must not be renamed to fix that, because the backlog tool has no rename and renaming by hand breaks every reference that has already left this vessel.
Such a chart draws zero members while its assignment is settled and written down, which is what this path exists for.

Assign it in place instead: one bare record id per line in `data/<chart>/members`, beside the `question.md` and `report.md` the assembler already reads from that directory.
`#` starts a comment and blank lines are ignored.
Three rules bind, and the assembler enforces all three:

- **One home, bare ids.**
  A qualified or cross-home id is refused and named, never resolved.
  Cross-vessel dependency is a blocker edge or a routed request.
- **Exclusive.**
  A record belongs to at most one undertaking.
  Counted in two "what is left" views it leaves neither chart able to say whether it is finished for its own purposes.
  Where the prefix rule already owns a record, it wins and keeps drawing there - a claim made by an id cannot be edited away from another file - and the list line that tried to take it is refused, so the record is drawn exactly once.
  Where nothing owns it by prefix, the chart picks no winner and draws it on neither.
  A record that genuinely fits two undertakings is evidence that one of them is cut too coarsely, or that it is really two pieces of work - fix it by re-cutting the work, never by listing it twice.
- **Retrofit only.**
  Anything created after the undertaking exists is named under the chart at creation, `/to-backlog` included.
  Adding such a record to the list assigns nothing, and the chart says so.

The list is a hand-maintained second source and it rots, so read `membership_defects[]` on every chart - including a chart with no list of its own, which is where another chart's wrong line about it shows up.
An unreadable list is refused outright rather than read as empty, because a list quietly treated as empty shrinks the page and stops the exclusivity check firing at all.

What counts as an undertaking already owning a record is **structural evidence only**, never a judgement about what looks important: records filed beneath it, a member list of its own, or its own panel question.
It deliberately does not include merely having a `data/<id>/` directory, which most records that were ever dispatched have, and which is exactly what retrofit material looks like.
So one overlap remains uncatchable from the reaching side and the chart discloses it: an owner that is a bare record, with nothing filed beneath it and no chart files of its own, is indistinguishable from ordinary work an undertaking was named over.
Such a case still surfaces, as `claimed-elsewhere` on the page of the chart that owns the record - which is why that row speaks only for its own page and never promises what the other one does.

## Filing fog and course boundaries

The chart reads them; it never files them.
They are ordinary backlog records, owned by the backlog contract in `AGENTS.md` section 10, which is where their spelling and their meaning live.
Follow it exactly on the record kind rather than the hold: `hold --kind` refuses both names, and reading that refusal as "these cannot be stored" is what once left every chart's fog and boundaries permanently empty.
Neither can ever be mistaken for a captain decision, because captain-actionability requires `hold-kind: captain` and both are held as `future` - structure, not a rule in prose.

A fog patch that becomes sharp is not promoted in place: close it, then register the real decision through `bin/fm-decision-hold.sh`, which already accepts later keys on a live or torn-down origin.
A course boundary never rises at all.

## Scope

One chart, for one named undertaking, from the current records, opened for the captain.
It is read-only with respect to every record on it.
If the undertaking has no destination, say so plainly and do not build a chart for nothing.
