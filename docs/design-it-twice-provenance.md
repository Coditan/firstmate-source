# design-it-twice provenance: DESIGN-IT-TWICE.md, adopted in part

`/design-it-twice` is an adoption of **`DESIGN-IT-TWICE.md`**, one file of the **codebase-design** skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, under the **MIT licence**.
It is not an internal invention.
This page is where the required notice is carried, and where the kept-changed-dropped accounting this fleet applies to every adoption from that upstream is written down.

It is the fourth such record, after [`sea-chart-provenance.md`](sea-chart-provenance.md), [`to-backlog-provenance.md`](to-backlog-provenance.md), and [`domain-modeling-provenance.md`](domain-modeling-provenance.md).
Read [`to-backlog-provenance.md`](to-backlog-provenance.md) first if you want the reason this fleet writes these pages at all: the first adoption from this upstream took half a design, kept the vocabulary of the whole, named no source, and reported the result as original work.

MIT permits what was done here - adopt, adapt, rename, and ship - and asks one thing in return: the copyright notice and the permission notice travel with the work.
That is a licence term being met below, not a courtesy being paid, and it lands in the same commit as the skill because an intention to attribute satisfies nothing.

## Why this is a partial adoption, which was a decision and not an oversight

The whole skill was on the table.
Three reasons put only its `DESIGN-IT-TWICE.md` half on our side of the line:

1. **This fleet already decided to load `codebase-design` rather than adopt it, and published that decision.**
   [`codebase-sweep-provenance.md`](codebase-sweep-provenance.md) records that the sweep loads the plugin skill and copies nothing from it.
   Copying the glossary here now would create a second owner of terms this fleet already reaches through the plugin, and two copies of a glossary drift the moment only one is edited, which is exactly what this repository's one-owner rule exists to prevent.
2. **Only the design-it-twice half has a fleet mechanism that is better than what upstream describes.**
   `bin/fm-model-panel.sh` and the `panel` skill do that file's fan-out with a guarantee ad-hoc sub-agents cannot make.
   The glossary has no fleet counterpart to wire to, so adopting it would buy a maintenance burden and no capability.
3. **The unit named in the instruction was the exercise, not the vocabulary.**
   The captain's words were that the skill "suggested a panel", which is about the step that fans out, and the fan-out is entirely inside this one file.

The cost of choosing the half is real and is not hidden: `/design-it-twice` cannot work without `codebase-design` installed on the seat.
The skill says so and stops rather than improvising the vocabulary from memory, which is the same refusal `codebase-sweep` already makes for the same dependency.
If the plugin is uninstalled, renamed, or restructured upstream, both instruments lose their vocabulary on the same day.

## What was inspected

| | |
| --- | --- |
| Source file | `skills/engineering/codebase-design/DESIGN-IT-TWICE.md` (43 lines) |
| Read for context | `skills/engineering/codebase-design/SKILL.md`, `skills/engineering/codebase-design/DEEPENING.md`, `skills/engineering/codebase-design/agents/openai.yaml`, `docs/engineering/codebase-design.md`, `CLAUDE.md`, `.agents/writing-docs.md`, `CHANGELOG.md` |
| Repository | `https://github.com/mattpocock/skills` |
| Version read | Plugin release **1.2.3**, installed on this seat at `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/`, read on 2026-08-20 |
| Commit read | None. The source was the installed plugin rather than a clone, so no git commit was read, and the version above is the only identifier this reading can honestly carry. `CHANGELOG.md` attributes 1.2.3 to upstream pull requests 779, 781, and 783. |
| Licence | MIT, `LICENSE` at that release's root |
| Our side | `.agents/skills/design-it-twice/SKILL.md`, new in this change |

The read was read-only, out of the plugin cache.
Nothing from upstream is vendored here, no file in this repository is a copy of one of theirs, and nothing under `~/.claude/plugins/` was modified: a change there would be invisible, unversioned, and lost on the next plugin update.
`DESIGN-IT-TWICE.md` ships no code, and `bin/fm-model-panel.sh` is wholly our own and predates this adoption by weeks.
The derivation is at the level of design, structure, and in places wording.

Upstream writes em dashes and this repository forbids them, so quoted em dashes are normalised to plain dashes; nothing else in a quotation is altered, and `...` marks every elision.
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

This is the same notice the three sibling pages carry, deliberately repeated in full rather than cross-referenced.
The one-owner rule exists to stop two copies of a contract drifting when only one is edited, and it does not reach a verbatim third-party licence text that no page here may edit.
A notice that only lives beside a different skill is one file move away from not travelling with this one, which is the failure the licence condition is about.
`README.md`'s License section points at all four pages.

## What we kept

Carried across whole, and load-bearing here:

- **The premise and its source.**
  "Based on 'Design It Twice' (Ousterhout) - your first idea is unlikely to be the best."
  Ours opens on the same rule and names the same author.
- **The four constraint shapes**, near-verbatim: "Minimize the interface - aim for 1-3 entry points max. Maximise leverage per entry point", "Maximise flexibility - support many use cases and extension", "Optimise for the most common caller - make the default case trivial", and the fourth, "Design around ports & adapters for cross-seam dependencies".
- **"Radically different"** as the bar for each design, rather than variations on one shape.
- **The five-part output per design**: the interface including "invariants, ordering, error modes"; a usage example showing how callers use it; "What the implementation hides behind the seam"; "Dependency strategy and adapters"; and trade-offs, "where leverage is high, where it's thin".
- **The three comparison axes**, verbatim: "Contrast by **depth** (leverage at the interface), **locality** (where change concentrates), and **seam placement**."
- **The demand for a strong read.**
  "give your own recommendation ... If elements from different designs would combine well, propose a hybrid. Be opinionated - the user wants a strong read, not a menu."
- **The problem-space framing written before the fan-out**: the constraints a new interface must satisfy, the dependencies and "which category they fall into", and "A rough illustrative code sketch to ground the constraints - not a proposal, just a way to make the constraints concrete."
- **The dependency category as a required part of the brief**, read from the same `DEEPENING.md` upstream points at, which we load rather than copy.
- **Both vocabularies in the brief**, so the designs name things consistently with the architecture language and the project's own domain language.
- **The technical brief kept separate from the user-facing framing.**

## What we changed

Each of these is a substitution with our own mechanism, not a capability dropped.

- **A file inside a skill became a skill.**
  Upstream reaches `DESIGN-IT-TWICE.md` from a "Going deeper" pointer at the end of `SKILL.md`.
  Nothing in a plugin skill can point at ours, so the trigger has to come from this fleet's own instruction surface: `AGENTS.md` section 7 and `.agents/skills/codebase-sweep/SKILL.md` step 1 both name it.
  The upstream file's own name is kept deliberately, so the lineage is visible and so a reader who has just met the phrase in the plugin skill meets the same phrase here.
- **Three or more sub-agents became exactly two analysts and a judge.**
  Ousterhout's word is twice, and `bin/fm-model-panel.sh` gives two designers on provably distinct pinned models plus a judge that re-verifies their load-bearing claims.
  Upstream's third and fourth sub-agent buy more shapes and no independence, because nothing in that formation pins a model: three designs that look independent can be one model's priors three times, and nothing tells the reader which happened.
  The four constraint shapes survive inside each analyst's own exercise instead of being one per agent.
- **Per-agent constraint briefs became one byte-identical question carrying every constraint.**
  The panel's evidentiary value is that both analysts were asked exactly the same thing, so two analysts given different constraints would disagree by construction and a judge could not tell that disagreement from a real one.
  Divergence moves inside each analyst; independence stays across them.
- **"Show this to the user, then immediately proceed" became an offer the captain can decline.**
  Upstream has the user read the problem space while the sub-agents already work.
  Firstmate does not work beside the captain, and two full investigations plus a judge is not something to start while he reads, so the problem space becomes the question file and reaches him as the offer, with `bin/fm-model-panel.sh start --dry-run` showing which models would argue before anything is spent.
- **The recommendation gained a verification step in front of it.**
  Upstream compares the designs and recommends.
  Ours re-checks each shape's load-bearing claims against the code first: whether the second adapter actually exists, whether the named callers actually call it, whether the deletion test holds.
  In the panel form the judge already does this and `panel` owns it; the skill states it for the one-head default, which is where nobody else would.
- **`CONTEXT.md` became the project's `AGENTS.md`**, the same substitution [`to-backlog-provenance.md`](to-backlog-provenance.md) records, and `bin/fm-ensure-agents-md.sh` already owns creating it.
  One shade does not survive: upstream assumes that file exists as a precondition of the exercise, and ours does not always exist, so a project without one hands the analysts no domain vocabulary and they will name things inconsistently.

Ours outright, added rather than adapted:

- **An entry test in front of the fan-out.**
  Upstream has none, and its own docs page records the consequence as an open issue: an agent pointed at `codebase-design` "reached for the most action-shaped content it could find - the parallel sub-agents in `DESIGN-IT-TWICE.md`", re-explored code an earlier session had already mapped, "and ran a long way before asking anything".
  Ours defers the whole worth-it judgement to `panel`'s own section and narrows nothing in it, then makes the reading concrete with two facts this fleet already holds: `codebase-sweep`'s low tier is not a panel question, and an interface you can change again next week fails panel's own would-you-act-differently test.
- **The boundary that the exercise does not decide.**
  A seam move is a middle-tier finding and therefore the captain's, so the verdict is evidence for that decision and never the decision, and the shape choice is registered through `decision-hold-lifecycle` before the exercise is complete.
- **The section stating what the exercise does not cover**, on the same reasoning `codebase-sweep` carries one: a silent gap reads as an all-clear.

## What we dropped

Every item below is a capability the original has and this adoption does not.

1. **Three or more independently authored designs in one round.**
   We get two authors.
   Cost: the real one on this list.
   If both analysts converge on the minimise-the-interface shape, the maximise-flexibility shape exists only as each analyst's own strawman of it, written by someone who had already decided against it.
   Upstream's fan-out gives that shape an author who was told to win with it.
2. **The user reading while the agents work.**
   Upstream deliberately overlaps the two, so the framing costs no wall-clock.
   Ours makes the captain's answer a gate in front of the spend.
   Cost: latency the original hides, we expose, and the captain waits with nothing in front of him unless he opens the question file.
3. **Sequential presentation of every design.**
   "Present designs sequentially so the user can absorb each one, then compare them in prose."
   Ours relays the judge's verdict under `AGENTS.md` section 9 instead.
   Cost: the captain does not see the shapes that lost; he sees the recommendation, the contested facts, and what stayed unverified.
4. **Portability.**
   Upstream's version runs in any harness that can spawn sub-agents, and 1.2.3 deliberately dropped one harness's tool names to keep it that way.
   Ours needs a live firstmate home, a configured panel lineup, and the plugin installed.
   Cost: none inside the fleet, total outside it, which is why the skill carries `metadata.internal: true`.

## The offer back upstream

The entry test and the independence warning are not fleet-specific, and this adoption is the reason we know they are missing.
[`docs/design-it-twice-upstream-offer.md`](design-it-twice-upstream-offer.md) holds the prepared contribution: the proposed prose, the covering note, the exact command that would open it, and the captain's decisions on it.
It is written to stay implementation-neutral, because an upstream skill cannot depend on one fleet's script, and its covering note is written to make no public claim about who operates what.
On 2026-08-21 he settled the channel and the identity and ordered that second rewrite; his read of the final text is the one gate left.
It is **not sent**.

## Repeating this comparison

    git clone --depth 1 https://github.com/mattpocock/skills.git
    # read skills/engineering/codebase-design/DESIGN-IT-TWICE.md, SKILL.md,
    # DEEPENING.md, docs/engineering/codebase-design.md, and LICENSE

Read-only, and outside this repository.
Re-read this page against their head when `DESIGN-IT-TWICE.md` changes; the release this adoption rests on is recorded above, and a clone will give the commit identifier this reading could not.
