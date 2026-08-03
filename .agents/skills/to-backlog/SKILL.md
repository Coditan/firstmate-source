---
name: to-backlog
description: >-
  Break a plan, spec, scout report, or the current conversation into backlog items: each a tracer bullet through every layer, each sized to one crewmate session, each declaring the items that must land before it.
  Use when the captain invokes /to-backlog, hands over a plan or report and asks for it broken into work, or asks how a large undertaking should be split up.
  Also load before filing more than one backlog item out of a single plan, report, or panel outcome, because that is the moment unsized work reaches the queue.
  Authors and sizes the questions; it never answers a captain decision and never dispatches a worker.
user-invocable: true
metadata:
  internal: true
---

# To backlog

Break a plan, a spec, a scout report, or the conversation into **backlog items**: tracer-bullet slices, each sized to one crewmate session, each declaring the items that must land before it can start.

> **This skill adopts [to-tickets](https://github.com/mattpocock/skills/tree/main/skills/engineering/to-tickets), by Matt Pocock, from [`mattpocock/skills`](https://github.com/mattpocock/skills), used under the MIT licence.**
> It is not an original design.
> The tracer bullet, the one-session size rule, prefactoring first, the blocking edges, the wide-refactor exception, the quiz, the frontier, and the item body shape are all its own.
> What is ours: the backlog item as the unit, the id bound to the originating undertaking, and `bin/fm-to-backlog.sh`.
> What we left out is written down rather than quietly omitted, item by item with its cost.
> `docs/to-backlog-provenance.md` carries the copyright notice, the full licence text, and that accounting.

This is the authoring half of the instrument whose display half is `/sea-chart`.
A unit filed here lands on the originating undertaking's chart with no further wiring, because both use the same id prefix.
Read `docs/sea-chart-provenance.md` if you want why the fleet had one half and not the other.

## The backlog is the tracker

There is one, `data/backlog.md`, reached through `tasks-axi`.
`AGENTS.md` section 10 owns what belongs in it, `.tasks.toml` and `tasks-axi --help` own its schema and commands.
Do not build a second store, a scratch issue directory, or a parallel plan file.

## Sequence

1. **Gather the source.**
   Work from what is already in the conversation.
   If the captain passed a reference, read its full body rather than its title: a scout report at `data/<id>/report.md`, the one question a panel gave every member at `data/<id>/question.md`, an existing backlog item, a spec path, or a PR or issue URL fetched with `gh-axi`.

2. **Read the project.**
   Understand the current state of the code before slicing it.
   Use the project's own vocabulary and respect the decisions its `AGENTS.md` records, so an item reads like the project rather than like this conversation.
   Look for prefactoring that makes the change easy, and order it first: **make the change easy, then make the easy change.**

3. **Draft the slices.**
   Each one is a **tracer bullet**:

   - it cuts a narrow but **complete** path through every layer the change touches - schema, API, interface, tests - never a horizontal slice of one layer
   - it is demoable or verifiable on its own when it is done
   - it is **sized to one crewmate session**: one worker, one isolated copy, one set of instructions, from first read to a green delivery
   - prefactoring comes first

   Then give each one its **blocking edges**: the other items that must land before it can start.
   An item with no blockers can start immediately.

   **The size rule is the point of this skill, not a detail of it.**
   Nothing else in this fleet sizes a unit, so without this step a unit ends up as coarse or as fine as discovery happened to emit it - one record per panel member, per finding, per sub-question.
   A slice that cannot be held in one session is too big; a slice that delivers no observable behaviour on its own is too small and belongs merged into its neighbour.

4. **Handle a wide refactor as the exception it is.**
   A **wide refactor** is one mechanical change - rename a column, retype a shared symbol - whose **blast radius** fans across the whole codebase, so a single edit breaks every call site at once and no vertical slice can land green.
   Do not force it into a tracer bullet.
   Sequence it as **expand, migrate, contract**:

   - **expand**: add the new form beside the old so nothing breaks
   - **migrate**: move the call sites over in batches sized by blast radius - per package, per directory - each batch its own item blocked by the expand, with checks green batch to batch because the old form still exists
   - **contract**: delete the old form once no caller remains, in an item blocked by every migrate batch

   When even the batches cannot stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify item, and promise green only there.
   That shared branch is not the ordinary delivery path, so raise it with the captain before slicing it that way rather than assuming it.

5. **Quiz the captain, and iterate until he approves.**
   Present the breakdown as a numbered list, in his nouns and not in this fleet's internal ones (`AGENTS.md` section 9).
   Per item: its **title**, **what it delivers** end to end, and **what has to land first**.
   Then ask him three things:

   - does the granularity feel right, too coarse or too fine
   - is each dependency real, or is an item waiting on something that does not actually gate it
   - should anything be merged or split further

   **Nothing is filed before he approves.**
   This step is the sizing discipline; skipping it leaves nothing sizing the units, which is the exact defect this skill was adopted to fix.

6. **File the approved breakdown.**
   Write it as a breakdown file and run `bin/fm-to-backlog.sh` - its header and `--help` own the format, the flags, and every refusal.
   It files in dependency order so each edge names an item that already exists, composes each id under the originating undertaking, and refuses a cycle, a missing origin, a missing acceptance criterion, or a kind that belongs to another owner.
   Check it first with `check`, which writes nothing.

   **Never close or modify the originating item.**
   It is the destination the units are slices of, and the chart reads it.

7. **Work the frontier.**
   The frontier is every item whose blockers are all done: `tasks-axi ready` fleet-wide, or `bin/fm-sea-chart.sh <origin> --summary` for this undertaking alone.
   Dispatch from it under `AGENTS.md` section 7, which owns intake, briefs, and delivery paths.
   We have no claim on an item, so two workers can be pointed at one: check what is already under way before dispatching, and do not treat the frontier as a queue workers take from unsupervised.

## What goes in an item

**What to build**: the end-to-end behaviour this item makes work, from the user's perspective.
Not a layer-by-layer implementation list, and not a restatement of the title.

**Acceptance criteria**: at least one, each independently checkable.

**Its origin**: the undertaking this is a slice of, named in prose as well as carried by the id.

**No file paths and no code snippets.**
They go stale faster than the item is worked, and `AGENTS.md` section 10 already forbids temporary paths and moving versions in a backlog note.
One exception: where a prototype produced a snippet that encodes a decision more precisely than prose can - a state machine, a reducer, a schema, a type shape - inline it, trim it to the decision-rich part, and say it came from a prototype.
That is the decision, not a working demo.

## What this skill does not do

It authors and sizes **questions and work**.
It never answers a captain decision: `bin/fm-decision-hold.sh` and `.agents/skills/decision-hold-lifecycle` own that, and this skill refuses to file a captain-actionable record so it cannot become a second owner by accident.
It never files fog or a course boundary either - those are the sea chart's own markers, spelled by `bin/fm-chart-kinds-lib.sh` and filed under `AGENTS.md` section 10.
It never dispatches a worker, opens a branch, or writes code.

## Scope

One approved breakdown of one undertaking, filed into the one backlog, with its dependency edges intact.
If there is no undertaking to slice against, file that first: a breakdown with no origin has no destination, and `bin/fm-to-backlog.sh` refuses it for the same reason the chart refuses to draw one.
