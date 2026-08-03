# Domain-modeling provenance: adopted from `mattpocock/skills`

`.agents/skills/domain-modeling/` is an adoption of the **domain-modeling** skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, under the **MIT licence**.
It is not an internal invention.

MIT permits exactly what was done here - adapt and ship - and asks one thing in return: the copyright notice and the permission notice travel with the work.
This page carries them, and it lands in the same commit as the skill, so the notice is never absent from a tree that contains the work.
That ordering is deliberate: the previous adoption from this same repository shipped without attribution and had to be corrected afterwards (`docs/sea-chart-provenance.md`).

## What was inspected

| | |
| --- | --- |
| Source skill | `skills/engineering/domain-modeling/SKILL.md` (74 lines), `skills/engineering/domain-modeling/CONTEXT-FORMAT.md` (60 lines), `skills/engineering/domain-modeling/ADR-FORMAT.md` (47 lines), `skills/engineering/domain-modeling/agents/openai.yaml`, and `docs/engineering/domain-modeling.md` |
| Repository | `https://github.com/mattpocock/skills` |
| Commit read | `2ab9580` (2026-07-28), the repository head at fetch time on 2026-08-03 |
| Licence | MIT, `LICENSE` at that repository's root |
| Our side | `.agents/skills/domain-modeling/SKILL.md`, `GLOSSARY-FORMAT.md`, `DECISION-RECORD-FORMAT.md`, and `agents/openai.yaml` |

The fetch was read-only, into a scratch location outside this repository.
No file here is a copy of one of theirs; the derivation is at the level of design, structure, and in places wording.
The skill ships no code, and neither does ours.

Two characters are normalised in the quotations below, and nothing else in a quotation is altered.
The source writes em dashes and this repository forbids them, so a quoted em dash becomes a plain dash.
The source writes the arrow in a relationship as `→` and no file in this repository does, so a quoted arrow becomes `->`.
`...` marks every elision.
Bold inside a quotation is the original's own.

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

This repository's convention for a third-party notice is a provenance page under `docs/`, established by `docs/sea-chart-provenance.md`.
`README.md`'s License section points here, so the notice is reachable from where a reader looks for licence terms.

## Why this skill was adopted

Four independent failures on the night of 2026-08-02/03 were one disease, and none of them was a coding error.

- A term meaning two different things in two runbooks, named outright by our own review-authority doctrine.
- A decision record drafted on the wrong referent of an ambiguous noun, after which a whole schema rested on it.
- A capability claim published to three parties, false only because the installed version was older than the documented one.
- A count that included something that was recorded but never ran.

Each was found by tripping over it.
The adopted skill is the instrument for catching them at the moment the term first wobbles, rather than at the moment the consequence lands.

## What we kept

Recognisably the original's, and load-bearing in ours.

- **The active/passive distinction, as the skill's reason for existing.**
  Source: "This is the *active* discipline ... (Merely *reading* `CONTEXT.md` for vocabulary is not this skill ... This skill is for when you're changing the model, not just consuming it.)"
  Ours restates the same boundary in its own words and puts it in the same position, immediately under the title.
- **The five live moves, one for one.**
  Challenge against the glossary, sharpen fuzzy language, discuss concrete scenarios, cross-reference with code, and update inline are the original's five headings.
  Ours keeps all five, in the same order, with the same job.
  This is the clearest single piece of structural evidence.
- **Write it down at the moment it crystallises.**
  Source: "Don't batch these up - capture them as they happen."
  Ours: "Do not batch it to the end of the session."
- **The contradiction, surfaced as a question rather than a correction.**
  Source: "Your code cancels entire Orders, but you just said partial cancellation is possible - which is right?"
  Ours keeps the shape and nearly the wording of that example.
- **The three-part bar for a decision record, and its failure analysis.**
  Hard to reverse, surprising without context, the result of a real trade-off, and no record if any one is missing.
  Source: "If a decision is easy to reverse, skip it - you'll just reverse it. If it's not surprising, nobody will wonder why. If there was no real alternative, there's nothing to record beyond 'we did the obvious thing.'"
  Ours compresses the same three clauses into one sentence and keeps all three.
- **The seven categories of what qualifies**, kept whole and lightly reworded: architectural shape, integration patterns, technology choices carrying lock-in, boundary and ownership decisions, deliberate deviations from the obvious path, constraints not visible in the code, and non-obvious rejected alternatives.
  The aphorisms inside them survive too, including "The explicit no-s are as valuable as the yes-s" and the observation that otherwise someone suggests the same alternative again in six months.
- **The one-paragraph record, and the argument for it.**
  Source: "An ADR can be a single paragraph. The value is in recording *that* a decision was made and *why* - not in filling out sections."
  Ours keeps the template, the sentence, and the three optional sections with the same "only when they add genuine value" gate.
- **The glossary rules**, kept whole: be opinionated with an `_Avoid_` list, keep definitions to one or two sentences, define what a thing IS rather than what it does, admit only project-specific terms, and group under subheadings when clusters appear.
  The `_Avoid_` convention and its markup are carried across unchanged.
- **Lazy creation.**
  Source: "Create files lazily - only when you have something to write."
  Ours applies it to the `## Language` section instead of to a file, for the reason given below.
- **The diary warning.**
  The source's docs page calls the bar "what keeps `docs/adr/` a record of consequential forks rather than a diary"; ours keeps the phrase and the point.

## What we changed or added

- **The store, substituted rather than dropped.**
  The original writes a `CONTEXT.md` glossary at the repository root and numbered records under `docs/adr/`.
  Ours writes into stores this fleet already has: a `## Language` section in a project's committed `AGENTS.md`, `data/learnings.md` for fleet-operational terms, and the existing dated decision records under `data/decisions/`.
  The captain's condition on adoption was explicit: do not build a third store.
  The formats and the bar cross over intact; only the location changes.
- **Cross-referencing widened from code to any checkable artifact - ours.**
  The original says "check whether the code agrees".
  Three of the four failures that motivated the adoption were not in code: an installed version older than the documented one, a record counting something that never ran, and a name resolving to a different file on disk than in the speaker's head.
  Ours therefore reads the artifact, whatever it is, and names those three shapes explicitly, with the rule that a claim must have been looked at before it is published outside the conversation.
  This is the single largest addition, and it is the one the motivating incidents demanded.
- **The terminology rule - ours**, set by the captain on 2026-08-03 after firstmate wrote Werkbank for workbench in a skill assessment, and corrected as a category rather than as a slip.
  A domain's proper nouns are never translated in any language, because a translated proper noun is unfindable; German is written per DU, never Sie.
  Nothing in the original addresses translation at all.
- **The boundary against `AGENTS.md` section 9 - ours, and necessary.**
  Section 9 requires translating firstmate's own internal machinery out of captain-facing text, so a rule forbidding translation reads as its contradiction until the categories are separated.
  Ours states the discriminator: section 9 covers a word firstmate invented for its own operation, where plain English is better; the terminology rule covers somebody's name for a thing, where any rendering is worse.
  The test given is whether the word would appear in a search of the code, the repository list, or the tool's own documentation.
- **The handoff for a decision that is not ours to make - ours, forced by an existing owner.**
  `decision-hold-lifecycle` is this repository's single owner of unresolved captain decisions.
  The original has no such separation, because its author decides and records in one motion.
  Ours records only decisions already made and hands an open one to that owner, so the skill does not become a second owner of the captain-decision lifecycle.
- **The project-write reinforcement - ours.**
  The original's writer owns the repository it writes to.
  Firstmate does not, so a skill whose whole purpose is "write it down where the next reader will meet it" needed an explicit line that a project-side entry is written by a crewmate through that project's delivery path, never by firstmate.
- **Dated records rather than sequential numbering - ours, as a substitution**, matching the existing store.
  The cost is named in the skill: a dated record has no short handle, so a decision discussed by number is not findable by that number, and the handle has to be carried in the title.

## What we dropped

Every item below is a capability the original has and ours does not.

1. **`CONTEXT-MAP.md`, and with it the whole multi-context model.**
   This is the largest loss and it is worth stating plainly, because it is the loss most relevant to why the skill was adopted.
   The original supports a repository holding several bounded contexts, with a root map listing where each one lives and, importantly, how they relate: "**Ordering -> Fulfillment**: Ordering emits `OrderPlaced` events".
   The map is what makes a cross-context term collision visible, and a cross-context term collision is exactly the failure that produced the wrong-referent decision record.
   We dropped it because a fleet-wide map of which repository owns which term would be a third store, which the adoption condition forbids.
   Ours substitutes a weaker mechanism - write the disambiguation into both repositories' `AGENTS.md`, each naming the other - which works when somebody already knows there is a collision, and does nothing to discover one.
   The original's map does not discover collisions automatically either, but it puts every context's vocabulary in one reachable place, which ours does not.
2. **The glossary's structural purity.**
   Source: "`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else."
   A dedicated file can carry that guarantee structurally.
   Our target is a project's committed `AGENTS.md`, which is a mixed memory file by design, so the guarantee degrades to a stated discipline inside one section of it.
   Ours keeps the rule and says why it is weaker there, which is the most that can be done without the file.
3. **Inference of which context a topic belongs to.**
   Source: "When multiple contexts exist, infer which one the current topic relates to. If unclear, ask."
   With no map there is nothing to infer against, so this step has no analogue in ours.
4. **Automatic numbering by scanning the store.**
   Source: "Scan `docs/adr/` for the highest existing number and increment by one."
   Dated names need no scan, so the step is gone along with the stable short handle it produced.
5. **The skill as a shared dependency of other skills.**
   The original's docs page describes it as "the **single source of truth** for building the project's ubiquitous language, split out as its own model-invoked skill so any other skill can reach it", and names three skills that reach it while they run.
   Ours is reachable in principle and reached by nothing in practice: no other skill in this repository loads it at a fixed step.
   That is a live gap rather than a deliberate exclusion, and it is the first thing to fix if the skill turns out not to fire on its own.

## Candidate follow-ups this adoption exposed

Recorded as findings, not fixed here.

1. **Nothing loads this skill at a fixed step**, so it depends entirely on model invocation and on the two trigger lines in `AGENTS.md`.
   Dropped item 5.
   The most natural fixed points would be a scout report's completion and a brief that is about to publish a claim outward.
2. **Cross-repository term collisions have no discovery mechanism**, only a manual disambiguation once somebody notices.
   Dropped item 1.
3. **No test proves the third-party notice survives** for the earlier `sea-chart` adoption.
   This adoption adds one for itself in `tests/fm-instruction-owners.test.sh`; the same protection does not yet cover `docs/sea-chart-provenance.md`.

## Repeating this comparison

    git clone --depth 1 https://github.com/mattpocock/skills.git
    # read skills/engineering/domain-modeling/ and LICENSE

Read-only, and outside this repository.
Re-read this page against their head when the source skill changes; the commit this comparison rests on is recorded above.
