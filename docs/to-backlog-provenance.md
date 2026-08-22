# to-backlog provenance: to-tickets, adopted

`/to-backlog` and `bin/fm-to-backlog.sh` are an adoption of the **to-tickets** skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, under the **MIT licence**.
They are not an internal invention.
This page is where the required notice is carried, and where the whole-versus-half accounting the captain asked for is written down.

This is the sibling of [`sea-chart-provenance.md`](sea-chart-provenance.md), which covers the same repository's Wayfinder skill.
The two are one instrument split in half: Wayfinder authors the units and shows the result, and our amendment of it kept only the showing.
to-tickets is the authoring step done properly, so adopting it is what puts the missing half back.
Read that page's "The grain question, answered" first if you want the reason this adoption exists at all.

## Why this adoption had a condition attached

The Wayfinder amendment took half a design, kept the vocabulary of the whole, named no source, and reported the result as original work.
The captain's condition on this task was therefore explicit: adopt to-tickets whole, or write down exactly which half is being left out and why.
"What we dropped" below is that accounting, and every item in it is a capability the original has and we do not.

MIT permits what was done here - adopt, adapt, rename, and ship - and asks one thing in return: the copyright notice and the permission notice travel with the work.
That is a licence term being met below, not a courtesy being paid, and it lands in the same commit as the skill because an intention to attribute satisfies nothing.

## What was inspected

| | |
| --- | --- |
| Source skill | `skills/engineering/to-tickets/SKILL.md` (105 lines), plus `skills/engineering/to-tickets/agents/openai.yaml` and `docs/engineering/to-tickets.md` |
| Read for context | `skills/engineering/setup-matt-pocock-skills/SKILL.md`, for the tracker and triage-label configuration to-tickets depends on |
| Repository | `https://github.com/mattpocock/skills` |
| Commit read | `2ab9580` (2026-07-28), the repository head at fetch time on 2026-08-03, and the same commit the Wayfinder comparison rests on |
| Licence | MIT, `LICENSE` at that repository's root |
| Our side | `.agents/skills/to-backlog/SKILL.md` and `bin/fm-to-backlog.sh`, new in this change |

The fetch was read-only, into a scratch location outside this repository.
Nothing from to-tickets is vendored here, and no file in this repository is a copy of one of theirs.
to-tickets ships no code, and `bin/fm-to-backlog.sh` is wholly our own.
The derivation is at the level of design, structure, and in places wording.

to-tickets writes em dashes and this repository forbids them, so quoted em dashes are normalised to plain dashes; nothing else in a quotation is altered, and `...` marks every elision.
Bold and italics inside quotations are the original's own.

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

This is the same notice `docs/sea-chart-provenance.md` carries, deliberately repeated in full rather than cross-referenced.
The repository's one-owner rule exists to stop two copies of a contract drifting when only one is edited, and it does not reach a verbatim third-party licence text that neither page may edit.
A notice that only lives beside a different skill is one file move away from not travelling with this one, which is the failure the licence condition is about.
`README.md`'s License section points at both pages.

## What we kept

Carried across whole, and load-bearing here:

- **The tracer bullet as the unit.**
  "Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) - vertical, NOT a horizontal slice of one layer", and "A completed slice is demoable or verifiable on its own."
- **The size rule, which is the reason this adoption happened.**
  "Each slice is sized to fit in a single fresh context window."
  Ours reads one crewmate session, because that is what a single fresh context window is in this fleet: one worker, one isolated copy, one brief, from first read to a green delivery.
- **Prefactor first.**
  "Look for opportunities to prefactor the code to make the implementation easier. 'Make the change easy, then make the easy change.'"
  With it, "Any prefactoring should be done first."
- **Blocking edges declared per unit**, and the definition that follows from them: a unit with no blockers can start immediately.
- **The wide-refactor exception, in full**, including its reasoning and its fallback.
  "A **wide refactor** is one mechanical change ... whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green."
  Expand, then migrate in batches sized by blast radius, then contract; and where even the batches cannot stay green alone, a shared integration branch that all block a final integrate-and-verify unit, "green is promised only there."
- **The quiz, and iterating until approved.**
  Granularity, whether each edge genuinely gates, and what to merge or split.
  This is not decoration: the original's granularity discipline is procedural, and this step is the procedure.
- **Blockers first**, so each edge can reference an identifier that already exists.
- **The frontier**: "any ticket whose blockers are all done."
- **Do not close or modify the parent.**
- **The body shape**: what to build as end-to-end behaviour "from the user's perspective - not a layer-by-layer implementation list", plus acceptance criteria as checkboxes.
- **No file paths, no code snippets**, "they go stale fast", with the prototype exception intact: a snippet that "encodes a decision more precisely than prose can (state machine, reducer, schema, type shape)", trimmed to the decision-rich parts and marked as coming from a prototype.
- **Gather context first**, including fetching the full body and comments of a passed reference rather than working from its title.
- **Use the project's own vocabulary** and respect its recorded architecture decisions.
- **Human-invoked, not agent-initiated**, as a property; see "What we changed" for how that property is preserved by a different mechanism.
- **The edges live in the unit regardless of medium.**
  The docs page states it directly: "The edges live in the ticket regardless of medium; the medium only decides whether anything acts on them in parallel."

## What we changed

Each of these is a substitution with our own mechanism, not a capability dropped.

- **The name.**
  `to-tickets` became `/to-backlog`, because this fleet has no tickets: it has backlog items, and a skill named for a noun the reader cannot find would invite exactly the confusion about grain this adoption exists to end.
  The `to-` form is kept deliberately so the lineage is visible in the name itself, and the attribution is carried in the skill, in the script, in `README.md`, in `docs/scripts.md`, and here.
  Renaming is what let the Wayfinder amendment lose its source; renaming without disclosing is.
- **Two publication shapes became one.**
  The original branches on what `/setup-matt-pocock-skills` configured: local markdown files under `.scratch/<feature-slug>/issues/`, or a real tracker with native blocking links.
  We have exactly one tracker for the whole fleet - `data/backlog.md`, reached through `tasks-axi` - and it carries native edges already.
  So the branch collapses onto the tracker arm, which is the arm the original prefers where it exists: "Use the platform's native blocking / sub-issue relationship where it has one; otherwise set each ticket's 'Blocked by'".
  `config/backlog-backend=manual` is a degraded medium, not a second store.
- **The ticket became the backlog item, and its id is bound to the originating undertaking.**
  The original mints ids in the tracker and carries the parent relationship as a real link.
  Ours composes the id as `<origin>-<slug>`, which is the prefix rule `bin/fm-sea-chart.sh` already uses to decide chart membership.
  That is deliberate and is the point of the adoption: a unit authored here lands on the originating undertaking's own sea chart with no further wiring, so the authoring half feeds the display half.
  The body still names its origin in prose, standing in for the original's `## Parent` section, because an id prefix is not readable at a glance.
- **`disable-model-invocation: true` became captain-invocable plus one named firstmate trigger.**
  The original keeps the agent from reaching for the skill because it publishes into a tracker unasked.
  In this fleet the captain speaks to firstmate rather than to a tracker, so a flag that stopped the agent reaching for it would stop it being reached at all.
  The protection the flag provides is preserved at a different point instead, and structurally rather than by a flag: the quiz is mandatory and nothing is filed before the captain approves the breakdown.
- **`ready-for-agent` became a computed state rather than a label.**
  We have no triage-label vocabulary, and the frontier here is `tasks-axi ready` - queued, unblocked, unheld - which is the original's own definition of the frontier with nothing to keep in sync.
  One shade of meaning does not survive: the label is the author asserting up front that a ticket is agent-grabbable, where our dispatchability is firstmate's judgement at intake under `AGENTS.md` section 7.
  That residue is recorded under "What we dropped", item 2.
- **The domain glossary and ADRs became the project's `AGENTS.md`.**
  Same instruction, our file, and `bin/fm-ensure-agents-md.sh` already owns creating it.
- **The quiz is put to the captain in the captain's own nouns**, because `AGENTS.md` section 9 forbids internal vocabulary in captain-facing text.
  The substance of the three questions is unchanged.

Ours outright, added rather than adapted:

- **`bin/fm-to-backlog.sh`.**
  The original has no code; its publish step is prose an agent executes by hand.
  Ours makes the mechanical part deterministic, because agent memory is unreliable at exactly this step: dependency order, cycles, the id prefix, and whether each unit actually carries a what-it-delivers line and at least one acceptance criterion.
  It enforces what the skill already says and decides nothing.
  It is not a second backlog: every write is a `tasks-axi` call.
- **Refusals with no counterpart upstream.**
  The origin must already exist in the backlog, so a breakdown cannot be filed against a destination nobody named - the same refusal `bin/fm-sea-chart.sh` makes for the same reason.
  A unit may never be filed as `kind: captain`, `fog`, or `out-of-course`, because those records belong to `bin/fm-decision-hold.sh` and to the sea chart's own markers.
  Nor may a slug compose the reserved `-decision-` marker into its id, because `bin/fm-sea-chart.sh` reads that marker positionally rather than by kind, so an ordinary unit carrying it would leave the chart's takeable work and later read as a settled captain decision - the same hole as the kind refusal, reached through the id instead of the kind.
  And no unit may be blocked by its own origin, an edge that could never clear because a breakdown may never close the undertaking it is a slice of.
  Without the kind and id refusals this skill could manufacture records that read as captain decisions as a side effect of slicing work, which is the one write the read-only argument was right about.
  Captain-actionability itself is read off the hold, not the record kind (`bin/fm-fleet-snapshot.sh`), and this script never calls `tasks-axi hold`, so the refusals guard ownership and the chart's reading rather than that surface.

## What we dropped

Every item below is a capability the original has and this adoption does not.

1. **The `/setup-matt-pocock-skills` prerequisite.**
   The original requires a setup pass that records which tracker a repo uses, its label vocabulary, and its domain-doc layout, and to-tickets refuses to guess without it.
   This repository now carries the per-repository configuration surface under `docs/agents/`, but `/to-backlog` does not require or consume the setup skill because the fleet-wide backlog and `config/backlog-backend` already settle its publication target.
   Cost: none that we can see, but the prerequisite remains a real dependency of the original that this adaptation does not enforce, and a future second tracker would expose the gap.
2. **The triage label vocabulary.**
   The original applies `ready-for-agent` as it publishes, out of a five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) shared with its `triage` skill.
   `docs/agents/issue-tracker.md` owns why this repository omits that vocabulary without treating the skill's per-seat reachability as a standing fleet fact.
   We have no label surface at all.
   Cost: an author cannot mark one unit as ready for a worker and another as still needing information; every filed unit looks alike until firstmate judges it at intake.
3. **The local-file publication shape.**
   `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` in dependency order, one file per unit.
   Deliberate: it is the original's fallback for a repo with no tracker, and we always have one.
   Cost: none here, but it means a breakdown cannot be drafted somewhere the backlog is not reachable.
4. **The sub-issue relationship.**
   On a real tracker the original uses native sub-issues where they exist, which renders the parent-child tree in the tracker's own interface.
   Our backlog has one edge type, `blocked-by`, and the parent relationship is carried by the id prefix instead.
   Cost: the same weakness `docs/sea-chart-provenance.md` already records for the chart - when one undertaking's id is a prefix of another's, the shorter one draws the longer one's units in, where a real edge cannot collide.
5. **A frontier several workers may grab from at once.**
   The docs page is explicit that this is what the tracker arm buys: "Any ticket whose blockers are all done is on the **frontier** and can be grabbed - so several agents can run at once."
   We have no claim concept, so our frontier is a list firstmate dispatches from one at a time, not a queue workers take from.
   Cost: named and already filed as `sea-chart-takeable-admits-inflight`; until it exists, two workers can be pointed at one unit.
6. **The surrounding chain.**
   The original is one step of `grill-with-docs -> to-spec -> to-tickets -> implement -> code-review`, and it assumes a settled spec with user stories to slice against: "If the change hasn't been written up as a spec yet, produce one first."
   We adopted this step only.
   Our upstream is a scout report, a panel question, or a plan in conversation, and our downstream is `AGENTS.md` section 7's dispatch plus the project's selected delivery path.
   Cost: the real one on this list.
   A breakdown taken from loose conversation gets materially weaker input than the original assumes, and nothing in this fleet plays the part `to-spec` plays.
   That is not fixed here and should not be pretended away.
7. **`agents/openai.yaml`.**
   The original ships a per-agent interface manifest carrying the display name, a short description, and `allow_implicit_invocation: false`.
   Our skills carry all three in `SKILL.md` frontmatter, so there is no second file.
   Cost: none.

## Repeating this comparison

    git clone --depth 1 https://github.com/mattpocock/skills.git
    # read skills/engineering/to-tickets/SKILL.md, docs/engineering/to-tickets.md, and LICENSE

Read-only, and outside this repository.
Re-read this page against their head when to-tickets changes; the commit this adoption rests on is recorded above.
