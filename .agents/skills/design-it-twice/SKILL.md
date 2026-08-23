---
name: design-it-twice
description: >-
  Design one module's interface more than once, compare the shapes on depth, locality, and seam placement, and decide whether the question is contested enough to spend a real model panel on rather than settling it in one head.
  Use when a codebase-design exercise reaches the point of exploring alternative interfaces for a module, when a sweep finding needs a proposed shape rather than only a diagnosis, and before recommending an interface that callers outside the module would have to change for.
  It never substitutes ad-hoc parallel sub-agents for the panel, because sub-agents on one harness default all run the same model: their agreement is one model's priors repeated, and nothing in that formation tells you.
  Adapts DESIGN-IT-TWICE.md from the codebase-design skill by Matt Pocock (MIT); docs/design-it-twice-provenance.md carries the notice.
user-invocable: true
metadata:
  internal: true
---

# /design-it-twice

Ousterhout's rule is that your first idea for an interface is unlikely to be the best one, so design it twice.
The exercise is producing a second and a third shape and comparing them, and it is worth doing almost every time an interface is in question.
What is not free is how the shapes get produced.
This skill owns that choice: the exercise itself by default, and this fleet's real model panel when the question is genuinely contested.

The exercise is adapted from `DESIGN-IT-TWICE.md` in the `codebase-design` skill from [`mattpocock/skills`](https://github.com/mattpocock/skills), by Matt Pocock, under the MIT licence.
`docs/design-it-twice-provenance.md` carries the notice and the accounting of what was kept, changed, and dropped.

Load the vocabulary before anything else.
On this seat `codebase-design` is a plugin skill (`mattpocock-skills:codebase-design`), not a directory inside any repository, so reach it through the harness skill mechanism.
If it is not installed here, say so and stop rather than improvising module, interface, depth, seam, adapter, leverage, and locality from memory.
Its `DEEPENING.md` owns the dependency categories, and the brief below has to name one of them.

## Step 1 - design it twice yourself, which is the default

Write three shapes for the same module, and a fourth where a dependency crosses a seam, each under a different constraint and each radically different rather than a variation of the last:

- Minimise the interface: one to three entry points, maximum leverage per entry point.
- Maximise flexibility: many use cases and room to extend.
- Optimise for the most common caller: make the default case trivial.
- Where a dependency crosses a seam, a fourth: ports and adapters.

Each shape carries the interface (types, params, invariants, ordering constraints, error modes), a usage example showing how a caller uses it, what the implementation hides behind the seam, the dependency strategy and its adapters, and the trade-offs, including where the leverage is thin.

Then compare them on depth, locality, and seam placement, and be opinionated.
Recommend one, and propose a hybrid where elements from two combine well.
A menu is not a result.

**Before the recommendation, re-check each shape's load-bearing claims against the code rather than against your own design note.**
Does the second adapter actually exist, or is the seam hypothetical and therefore just indirection?
Do the callers you named actually call it?
Does the deletion test hold for this module: if it vanished, would complexity reappear across those callers?
A comparison settled on how the three designs read is rhetoric, and the shape that reads best is the one whose author wrote the most confident prose.

Most interface questions end here.

## Step 2 - decide whether this one is worth a panel

This step is firstmate's, not a worker's.
A worker that reaches this point finishes step 1 and reports its shapes with the recommendation; the panel is dispatched by firstmate, and a crewmate never puts the question to the captain itself.

The bar belongs to `panel`, and this skill narrows nothing in it: load that skill and apply its "Is this question worth a panel" section as written.
A skill that offered a panel for every interface decision would be worse than one that never offered it, because the offer would stop carrying information.

Two facts already recorded in this fleet make that reading concrete for an interface question:

- **Tier.**
  A finding in `codebase-sweep`'s low tier is reversible without the captain and contained inside one module, and that is not a panel question: design it twice, pick one, and do the work.
  Only a middle finding can be one, where a caller outside the module would change or a person would have a view on the shape.
- **Consequence.**
  Panel's own killer test is whether you would act the same way whatever the judge concluded.
  An interface you can change again next week the first time a caller complains fails it.

Enjoying the exercise is not the bar either.
Upstream's own docs page records an open issue in which an agent pointed at `codebase-design` reached for the most action-shaped content it could find, the parallel sub-agents in `DESIGN-IT-TWICE.md`, re-explored code an earlier session had already mapped, and ran a long way before asking anything.
A fan-out with no entry test in front of it is that failure waiting to happen again.

**Offer it, never assume it.**
When the question does clear the bar, put the choice to the captain before spending anything, in his own nouns: the module, the shapes already on the table, what a second independent reading would buy, and roughly what it costs.
`bin/fm-model-panel.sh start --dry-run` resolves and prints the lineup without writing or dispatching anything, so he can see which models would argue before he decides.

## Step 3 - carry a question the panel can actually take

Both analysts receive byte-identical text, and the panel cannot carry a different constraint per analyst.
So the constraint list moves inside the question: ask each analyst for three or more radically different shapes under those constraints, and one recommendation.
Divergence then happens inside each analyst, and independence happens across them.

**Do not try to make the constraint the difference between the analysts.**
Two analysts asked different questions disagree by construction, and a judge cannot tell that disagreement from a real one.
The entire evidentiary value of the formation is that both were asked exactly the same thing.

Two designers, not three or more.
Ousterhout's word is twice, and the panel gives exactly two independent designers plus a judge that re-verifies their claims.
Upstream's third and fourth sub-agent buy more shapes and no independence.

The question has to carry all of this, so put it in a file and pass `--question-file`:

- the module, and where its seam is today, named by path and exported name
- the constraints any new interface has to satisfy
- the dependency category from `DEEPENING.md`, and what sits behind the seam
- the callers, and which of them is the common one
- an illustrative code sketch that grounds the constraints, marked as not a proposal
- the constraint shapes above, as the shapes to design under
- the required output for each shape, as listed in step 1
- the comparison axes: depth, locality, and seam placement
- both vocabularies: `codebase-design`'s terms, and the project's own domain language from its `AGENTS.md`, so the shapes name things consistently

The question is the technical brief, and it is not the framing the captain answered in step 2.
Keep the two separate: he decided whether to spend the panel, and the analysts need the paths, the couplings, and the category he does not.

Everything after that is `panel`'s: starting, supervising the members, advancing, the named reduced form when this home cannot prove two distinct configured models, and the relay.
Do not restate any of it here.

## What the panel adds over parallel sub-agents, and what it does not

It adds a guarantee the ad-hoc formation cannot make.
`bin/fm-model-panel.sh` refuses to start unless it can prove two distinct pinned model identities, so a panel that ran was argued by two different models.
Parallel sub-agents inherit one harness default: three designs that look independent can be one model's priors three times, their agreement reads as corroboration, and nothing in that formation tells you which happened.
It also adds a judge that re-verifies the load-bearing claims against the code with both reports in hand, rather than refereeing which design reads better.

It does not decide.
A seam move is a middle-tier finding and therefore the captain's, so the verdict is evidence for that decision and never the decision.
Load `decision-hold-lifecycle` and register the shape choice before treating the exercise as complete.

## What this does not cover, stated because a silent gap reads as an all-clear

- It designs one module's interface.
  Which module is worth redesigning at all is `codebase-sweep`'s question, and this skill answers none of it.
- It compares shapes on depth, locality, and seam placement.
  It is not a correctness, security, or performance review of the shape it recommends, and a confident recommendation says nothing about any of those.
- A panel verdict is two analysts and a judge reading the code on one day.
  It is a reading with a date on it, and it goes stale exactly like every other record this fleet re-measures.
- It cannot make a home that can field only one model produce two independent designs.
  `panel` owns that degradation, and its reduced form is a single-analyst review that must never be relayed as a second opinion.
