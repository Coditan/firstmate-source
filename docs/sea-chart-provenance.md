# Sea chart provenance: Wayfinder, amended

`/sea-chart` and `bin/fm-sea-chart.sh` are an amendment of the **Wayfinder** skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, under the **MIT licence**.
They are not an internal invention.
The introducing commit `7eb063d` (2026-08-01) named no source, no author, and no licence, and it was reported onward as original design.
This document is that correction, and it is where the required notice is carried.

MIT permits exactly what was done here - amend, rename, and ship - and asks one thing in return: the copyright notice and the permission notice travel with the work.
Carrying them was the unmet condition, so this is a licence term being met, not a courtesy being paid.

## What was inspected

| | |
| --- | --- |
| Source skill | `skills/engineering/wayfinder/SKILL.md` (128 lines), plus `skills/engineering/wayfinder/agents/openai.yaml` and `docs/engineering/wayfinder.md` |
| Repository | `https://github.com/mattpocock/skills` |
| Commit read | `2ab9580` (2026-07-28), the repository head at fetch time on 2026-08-03 |
| Licence | MIT, `LICENSE` at that repository's root |
| Our side | `.agents/skills/sea-chart/SKILL.md` and `bin/fm-sea-chart.sh` at `8872ddf` |

The fetch was read-only, into a scratch location outside this repository.
Nothing from Wayfinder is vendored here, and no file in this repository is a copy of one of theirs.
The derivation is at the level of design, structure, and in a few places wording.
Wayfinder ships no code, and `bin/fm-sea-chart.sh` is wholly our own.

Two notes on the quotations below, so nothing here is mistaken for the original's own hand.
Wayfinder writes em dashes and this repository forbids them, so quoted em dashes are normalised to plain dashes; nothing else in a quotation is altered, and `...` marks every elision.
Bold and italics inside quotations are Wayfinder's own, with one exception that is flagged where it appears.

## Notice

    MIT License

    Copyright (c) 2026 Matt Pocock

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

This repository had no third-party notice location before this document.
The nearest convention in service is the provenance ledger held as a `docs/` page - `docs/admiralty-fleet-repo.md` for vendored material and `docs/fork-patches.md` for carried patches - so this page follows that rather than introducing a root `NOTICE` the repository has never had.
`README.md`'s License section points here, so the notice is reachable from the place a reader looks for licence terms.

## What we kept

Recognisably Wayfinder's, and load-bearing in our version:

- **The destination as the organising idea.**
  Wayfinder: "naming it is the first act of charting - it shapes every ticket."
  Ours refuses to draw at all without one.
- **The destination fixes the scope, and scope is what makes a boundary possible.**
  Wayfinder: "Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope**."
  Ours restates that reasoning almost intact: "there is no scope for anything to be outside of, and fog cannot be fog *towards* anything."
  The italicised *toward* / *towards* survives the copy.
- **Fog of war**, as deliberate incompleteness rather than a gap to be filled, and **out of scope** as a separate thing ruled out by scope rather than by sharpness.
- **Out-of-scope work never rises.**
  Wayfinder: "Out-of-scope work never graduates - the frontier stops at the destination."
  Ours says "these never rise", twice.
- **Sharpness as the fog vocabulary.**
  Wayfinder: "you can't yet phrase it that sharply."
  Ours: "a question an investigation could not yet make sharp" (`AGENTS.md` section 10), and "a fog patch that becomes sharp".
- **Done when the way is clear.**
  Wayfinder resolves tickets "until the way to the destination is clear".
  Our two-surface table gives the chart "Finished when: The way is clear" against the board's "Never."
- **The map body, section for section.**
  Wayfinder's `## Destination`, `## Decisions so far`, `## Not yet specified`, and `## Out of scope` map one-to-one onto our `destination`, `decided[]`, `fog[]`, and `out_of_course[]`.
  This is the clearest single piece of structural evidence.
- **The unblocked predicate.**
  Wayfinder: "A ticket is **unblocked** when every ticket blocking it is closed."
  Ours: an id is resolved only when every record carrying it is Done.
- **Not stored, assembled.**
  Wayfinder's map is "an **index**, not a store"; ours is built fresh per invocation and stores nothing.

## What we changed or added

Of the five items the comparison was asked about, two came with Wayfinder in concept and three are ours outright.

- **Chart id bound to a backlog task - ours, as a substitution.**
  Wayfinder's map is a real issue labelled `wayfinder:map` whose tickets are its child issues, so membership is an explicit parent-child edge.
  Ours has no artefact at all: the chart id is the originating task id, and membership is a prefix rule over the backlog (`id == C` or `C-...`).
  The idea that an effort has one identity fixing its membership is Wayfinder's; the mechanism is ours.
  Ours is weaker in one named way - a prefix collision draws a longer undertaking's records in, which our own header discloses - where Wayfinder's edge cannot collide.
- **Three incompleteness numbers - ours entirely.**
  Wayfinder has no analogue and needs none, because its map is authored and there is no gap between what exists and what the surface returns.
  Ours is derived from a lossy upstream surface, and the numbers exist to measure that loss.
- **The withheld-records rule - ours entirely**, and for the same reason.
  A Wayfinder ticket cannot fall off its own map, because it is a child issue found by query.
  Our captain-gated records can leave `decisions_open` silently, which is the defect the reconciliation was built against.
- **Fog and out-of-course as backlog kinds - the concepts are Wayfinder's, the implementation is ours, and the change has a cost.**
  Wayfinder keeps both as free prose in the map body, coarse and unstructured on purpose: "Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none."
  We turned both into first-class records, one per patch, at the same granularity as everything else.
  Making fog a record is what makes fog sliceable, which Wayfinder explicitly warns against.
- **The unsupervised-work marking - ours entirely**, from `data/learnings.md` 2026-07-15.
  Nothing in Wayfinder resembles it.

Also ours and not Wayfinder's: the read-only rule, the verbatim `limits[]`, the two-surface split against the decision board, the reconciliation against `decisions_open`, the ageing probe, the stale-edge cause, and the Lavish rendering path.

## What we dropped

This is the half that matters, and every item below is a capability the original has.

1. **The instrument itself.**
   Wayfinder is a tool for breaking work down and setting a course, and ours kept only the half that shows the result.
   This is not one dropped feature among ten; it is the purpose, and the section below tests it properly because it also settles the grain question.
   The names already record it - theirs is named for an activity, ours for a document.
2. **The charting act.**
   Wayfinder's first mode *produces* the destination through a grilling session, then grills breadth-first to surface the decisions.
   Ours cannot produce a destination, only read one that already exists as a backlog title.
   Wayfinder calls naming it "the first act of charting"; in our version that act happens somewhere else entirely, owned by nobody.
3. **The self-limiting clause.**
   Wayfinder: "**If this surfaces no fog** ... you don't need a map. Stop and ask the user how they'd like to proceed."
   Ours refuses only a missing destination, and will happily draw a chart for an undertaking too small to deserve one.
4. **Ticket types, and with them the human-in-the-loop distinction.**
   Wayfinder types every open question as research, prototype, grilling, or task, and marks each as worked with a human or by the agent alone.
   Our fog rows carry no type, so nothing on the chart says whether a dark patch clears by reading documentation or only by asking the captain.
   Wayfinder fires `/research` subagents in parallel to burn the frontier down; this fleet spawns scouts all day and the chart is wired to none of them.
5. **The task type's reason for existing.**
   Wayfinder's `task` "earns its place by unblocking a decision, not by delivering the destination."
   Our `takeable[]` is derived by subtraction - open, unblocked, unheld, and not a decision, fog, or boundary - and carries no edge naming the decision it unblocks.
   What an entry costs to leave undone is exactly what the captain's own critique asks for, and Wayfinder had it.
6. **Dependency structure as a rendered thing.**
   Wayfinder makes native blocking mandatory and says why: "essential because it renders the frontier _visually_ ... so the human sees what's takeable without opening the map."
   We kept the predicate and dropped the rendering.
   Our summary prints no edge anywhere except a withheld record's blocker name.
7. **Claiming.**
   Wayfinder: "That assignee _is_ the claim: an open, unassigned ticket is unclaimed."
   We have no claim, and the omission is live: `takeable[]` selects `open_state`, which is `queued` **or** `in_flight`, so work somebody is already doing is listed under "TAKEABLE NOW".
8. **Refer by name, never by bare id.**
   Wayfinder devotes a section to it: "A wall of `#42, #43, #44` is illegible; names read at a glance."
   Our `--summary` leads every line with an id - `! <id>`, `* <id>`, `+ <id>`, `> <id>` - and the decided list prints no title at all.
9. **The gist, and the two reading resolutions.**
   Wayfinder's map holds "one line per closed ticket: enough to judge relevance", and you zoom into the ticket for the detail.
   Ours has one resolution and prints everything at it.
   Our `decided[]` is strictly less informative than Wayfinder's Decisions-so-far: it shows an id and a date where Wayfinder shows the name and a one-line gist of the answer.
   The answer is not even missing from our data - `fm-decision-hold.sh resolve --decision-file` writes it into the hold body - the chart simply never reads it.
10. **Per-effort Notes.**
    Wayfinder's map body carries "domain; skills every session should consult; standing preferences for this effort", recorded once.
    Ours has no per-chart context, so our skill's step 3 asks each session to re-derive that judgment from the report and each hold's reason, every single build.

## Planning instrument or status display: both readings, tested

Our skill states of itself: "This skill **presents**. It never writes, files, resolves, or closes anything."
Two readings of that were put to the original.
Reading A: Wayfinder is a planning instrument that sets a course, and we kept only the presenting half, which is a capability loss.
Reading B: read-only is a deliberate and well-reasoned fleet amendment, because a chart that quietly changed a record would put a second owner on the decision-lifecycle contract.

**Reading A is what the original's own text and behaviour establish.**

- Its frontmatter says what it is for: "Plan a huge chunk of work ... as a shared map of decision tickets on your issue tracker, and resolve them one at a time until the way to the destination is clear."
  The verbs are plan and resolve; the frontmatter carries no emphasis of its own, and none is added here.
- It has exactly two invocation modes, "Chart the map" and "Work through the map", and there is no third.
  Neither is a viewing mode.
- Every step of both modes is a mutation: create the map, create the tickets, wire the blocking edges, fire the research subagents, claim by assignment, post the resolution comment, close the issue, append to Decisions-so-far, graduate fog into new tickets, rule a ticket out of scope, update or delete invalidated tickets.
  The single read step - "Load the **map** - the low-res view" - exists to serve the next write, and is never an output for a human to look at.
- It says outright that it produces: "absent that, produce decisions, not deliverables."

One passage looks like support for Reading B and is not.
The section headed "Plan, don't do" contrasts planning against **building the deliverable**, not against writing: "produce decisions, not deliverables."
Wayfinder writes constantly; what it declines to do is implement the thing the decisions are about.
Reading that heading as a warrant for a read-only skill inverts it.

**Reading B is sound for one step and over-applied to the rest.**

The concern behind it is real.
`bin/fm-decision-hold.sh` and `.agents/skills/decision-hold-lifecycle` genuinely own recording a captain's answer, and this repository's one-owner rule genuinely forbids a second owner for that contract.
For the answering step specifically, "the chart queues answers; it does not record them" is a good boundary, and a rendering surface that mutated records while the captain read it would be worse than one that does not.

But the argument does not reach the things we actually lost, for two reasons.

First, Wayfinder is not a second owner either.
It does not implement issue state; it calls the tracker, which owns it - assign, comment, close, native blocking.
Calling an owner is not becoming one.
Our own step 6 already routes answers through `bin/fm-decision-hold.sh` by hand, which is the same relationship, performed by a human instead of by the skill.

Second, and decisively: almost nothing Wayfinder writes is a decision *resolution*.
Creating the map, sizing and creating tickets, claiming, graduating fog, and ruling work out of scope are acts of **authoring the questions**, not of answering them.
`decision-hold-lifecycle` owns the answer.
It does not own the question, and no contract in this repository does.
So the stated rationale forbids one write it was right to forbid, and the skill generalised it into a blanket property that silently removed the authoring half it never argued against.

**Verdict: a capability loss, carrying one well-reasoned exception.**
The read-only rule should have covered recording the captain's answer.
Applied to the whole instrument, it turned a course-setting tool into a status display while keeping the vocabulary of navigation - destination, fog, course boundaries - on a surface that does no navigating.
That mismatch is the thing the captain saw when he said the chart looks like an ordinary decision board.

## The grain question, answered

Firstmate held `fleet-sea-chart-wrong-unit` because it could not tell whether the wrong grain was our amendment departing from a working original, or the original's own shape inherited unexamined.

**It is ours.**
Wayfinder does not have this defect, and it avoids it by three mechanisms we dropped.

**First, Wayfinder's unit is authored and sized; ours is harvested.**
Wayfinder's tickets come into being during the charting session - "Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread" - and each one is deliberately bounded: "Its body is the question, sized to one 100K token agent session."
Nothing reaches a Wayfinder map without a human choosing it and sizing it first.
Our chart authors nothing.
It collects whatever already carries `kind: captain` under the id prefix, so its unit is whatever the discovering process happened to emit - one record per panel member, per finding, per sub-question.
That is precisely the critique's diagnosis, and it follows from removing the authoring loop rather than from anything Wayfinder does.

**Second, Wayfinder has a coarse-to-fine ladder; we flattened it.**
Wayfinder holds one effort at three resolutions: the map body at low resolution, the ticket as one sized question, and the resolution comment with its linked assets as the detail.
Sessions "load the map at low resolution and zoom into individual tickets on demand."
Our chart has one resolution.
The critique's proposal - introduce a coarser unit and hang the findings under it - is a request to restore the map-and-ticket layering Wayfinder already had and we did not carry across.

**Third, Wayfinder's frontier is a structure; ours is a filter.**
Wayfinder requires native blocking so that the dependency graph renders in the tracker's own interface, where the human sees it without opening the map.
The captain's second complaint, that without course, obstacles, and dependencies the chart is indistinguishable from the standard board, names that dropped capability exactly.

One qualification, in fairness to both sides.
The critique's proposed fix - that the chart's unit be the decision *in the captain's own formulation* - goes beyond Wayfinder rather than back to it.
Wayfinder's unit is the decision as a well-sized question, not as the sponsor's own sentence, and its protection against fine granularity is procedural (a human sizes each ticket in conversation) rather than structural (a named coarser tier).
So the defect is ours, but restoring the original would not by itself deliver what the critique asks for.

The causal chain in one sentence: we took the map and left the wayfinding, and with the authoring loop gone nothing sizes a unit, so the unit defaults to the granularity that discovery happened to produce.

**Why the read-only finding settles this rather than merely explaining it.**
An instrument that sets a course and a surface that reports status are held to different standards on grain, and the difference is not taste.
A course-setting instrument must be grained by the decision somebody will actually act on, because its output is a route to be walked, and a route made of sub-questions nobody walks is not a route.
A status display can survive being grained by whatever it found, because its output is only a list to read, and a list is allowed to be long.
So the wrong grain is not an incidental side effect of dropping the loop.
It is what a course-setting design necessarily degrades into once the course-setting is removed and only the display remains.
Wayfinder's granularity discipline is not a rule written anywhere in its text - it is a property of being the thing that creates the units.
Take that away and no rule survives to replace it, which is exactly what happened here.

This also disposes of the last honest doubt.
The critique's proposed fix goes beyond Wayfinder, as noted above, but the reason it has to is now clear: it is reconstructing structurally what the original got procedurally, because the procedure is the part we removed.

## Candidate defects this comparison exposed

Recorded as findings for filing, not fixed here; this task made no functional change to the chart.

1. **`takeable[]` lists work that is already in flight.**
   `open_state` admits `in_flight` and there is no claim concept, so two workers can be pointed at one item.
   Dropped item 7.
2. **The chart leads with ids where the original insists on names**, and `decided[]` prints no title at all.
   Dropped item 8.
3. **`decided[]` records no answer**, though `fm-decision-hold.sh resolve` already writes one into the hold body.
   Dropped item 9.
4. **No chart entry says what it blocks, or what leaving it open costs.**
   Dropped items 5 and 6, and the substance of `fleet-sea-chart-wrong-unit`.
5. **Fog carries no type**, so the chart cannot separate a patch a scout could clear from one only the captain can.
   Dropped item 4.
6. **Making fog a per-patch record invites the pre-slicing Wayfinder warns against.**
   Ours, under "What we changed or added".
7. **The read-only rule is applied to the whole skill where its own argument only covers recording the captain's answer.**
   Authoring, sizing, claiming, graduating fog, and setting boundaries have no second-owner problem, and dropping them is what removed the course-setting half.
   This is the root finding, and items 1 to 5 are largely its symptoms; see "Planning instrument or status display".

## Repeating this comparison

    git clone --depth 1 https://github.com/mattpocock/skills.git
    # read skills/engineering/wayfinder/SKILL.md and LICENSE

Read-only, and outside this repository.
Re-read this page against their head when Wayfinder changes; the commit this comparison rests on is recorded above.
Whether anything else in this fleet came from that repository unattributed is a separate question, held by another vessel, and is deliberately not answered here.
