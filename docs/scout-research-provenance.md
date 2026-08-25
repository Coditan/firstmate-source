# scout-research provenance: research, forked

`.agents/skills/scout-research/` is a fork of the **research** skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, under the **MIT licence**.
It is not an internal invention.
This page is where the required notice is carried, and where the kept-changed-dropped accounting this fleet applies to every adoption from that upstream is written down.

It is the fifth such record, after [`sea-chart-provenance.md`](sea-chart-provenance.md), [`to-backlog-provenance.md`](to-backlog-provenance.md), [`domain-modeling-provenance.md`](domain-modeling-provenance.md), and [`design-it-twice-provenance.md`](design-it-twice-provenance.md).
Read [`to-backlog-provenance.md`](to-backlog-provenance.md) first if you want the reason this fleet writes these pages at all: the first adoption from this upstream took half a design, kept the vocabulary of the whole, named no source, and reported the result as original work.

MIT permits what was done here - adopt, adapt, rename, and ship - and asks one thing in return: the copyright notice and the permission notice travel with the work.
That is a licence term being met below, not a courtesy being paid, and it lands in the same commit as the skill because an intention to attribute satisfies nothing.

## Why this one was forked rather than loaded

[`codebase-sweep-provenance.md`](codebase-sweep-provenance.md) records the other available outcome: keep loading the plugin skill and copy nothing from it.
That outcome was on the table here and was rejected on a measurement rather than a preference.

**Upstream's first instruction cannot be executed at the place this fleet dispatches research from.**
The whole skill opens with "Spin up a **background agent** to do the research, so you keep working while it reads."
In a firstmate primary home a delegation-shaped tool name is denied by `bin/fm-subagent-pretool-check.sh` before it runs, because work started that way has no `state/<id>.meta` and no `data/<id>/brief.md`, leaves every firstmate guard inert, and dies with the session that started it.

Measured on 2026-08-25, from a task worktree of this repository:

```
$ bash bin/fm-subagent-pretool-check.sh --tool Task
exit=0

$ FM_ROOT_OVERRIDE=/home/coditan/coditan-firstmate FM_HOME=/home/coditan/coditan-firstmate \
    /home/coditan/coditan-firstmate/bin/fm-subagent-pretool-check.sh --tool Task
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[subagent-dispatch] the firstmate primary dispatches through the fleet, not the harness's own delegation tools: ... Instead, investigation and ship work both go to bin/fm-brief.sh then bin/fm-spawn.sh (blocked tool: Task, delegation-shaped on \"task\"). ..."}
exit=2
```

Both readings matter, and the second one alone would have overstated the case.
The guard is scoped to a genuine primary home and is inert inside a task worktree, so a crewmate may still delegate; what is refused is the one place a research question is actually dispatched from.
A skill whose opening step is refused there is worse than no skill, because it reads as usable right up to the moment it is followed.

Loading the plugin unchanged would also have left three of this fleet's own measured disciplines with no owner at the moment they are most needed - searching the internal record first, labelling how each finding was obtained, and reporting an unknown as a finding.
Those are additions rather than adaptations and are listed as such below.

## The dispatch step, followed rather than described

The defect this fork fixes is an opening step that reads as usable and is refused when followed, so the replacement step was executed rather than written down and trusted.

Run on 2026-08-25 from this task worktree, against a scratch `FM_HOME` so no fleet record was created:

```
$ FM_HOME=<scratch> bash bin/fm-brief.sh probe-research firstmate-fork --scout
scaffolded: <scratch>/data/probe-research/brief.md (scout; replace {TASK})
```

The rendered brief carries, in its own words, the two things this skill relies on and therefore does not repeat:

> Write your findings to `<scratch>/data/probe-research/report.md`.

> Before reporting done, read and follow `.../decision-hold-lifecycle/SKILL.md` and pass its shared completion gate for the report and any visual review.

`bin/fm-transcript-search.sh` was run the same day against this home's real archive and returned matching session paths, so step 2's first instrument is a tool that answers rather than a name in a list.

**What was not executed, and why.**
`bin/fm-spawn.sh` was not run.
Running it would have created a live fleet task with a durable record that no one had asked for and that this task has no authority to own, which is the same reason the brief was scaffolded into a scratch home rather than the real one.
`bin/fm-spawn.sh --supported-harnesses` was run and printed the five verified adapters, which proves the script is reachable and nothing more.
The spawn half of the step therefore rests on `tests/fm-spawn-*.test.sh` and on every dispatch this fleet has already made through it, not on a reading taken here.
Under this skill's own step 4 that is an inferred claim, and it is labelled as one rather than folded into the measured half above.

## The name, and how a reader chooses between the two

The plugin is reachable on this seat as `mattpocock-skills:research`.
A local skill named `research` would sit beside it in the same harness listing under a bare name that says nothing about which one the reader is looking at, so the fork is named **`scout-research`**.

`scout` is this fleet's own word for an investigation whose deliverable is a report rather than a change (`AGENTS.md` section 7), and `AGENTS.md` section 9 lists it among the house nouns that need no translation.
The name therefore states the discriminator rather than requiring a reader to remember it: research that this fleet dispatches and lands at `data/<id>/report.md` is `scout-research`, and research inside an ordinary repository with no fleet dispatch behind it and no fleet record to search is the plugin's.
Our description carries that sentence and names the plugin by its exact reachable name, so the choice is answerable from the skill listing alone without opening either file.
The plugin's own description says nothing about the fork, and cannot: it is upstream's wording, not ours to edit, and editing the installed copy would be invisible, unversioned, and lost on the next plugin update.
The `research` half of the name is kept deliberately so the lineage stays visible, the same reason `/to-backlog` kept `to-` and `/design-it-twice` kept its upstream file's whole name.

## What was inspected

| | |
| --- | --- |
| Source skill | `skills/engineering/research/SKILL.md` (12 lines including frontmatter), plus `skills/engineering/research/agents/openai.yaml` |
| Read for context | `.claude-plugin/plugin.json`, `LICENSE`, and the plugin root listing, for the author, version, licence, and the skill inventory the fork sits in |
| Repository | `https://github.com/mattpocock/skills` |
| Version read | Plugin release **1.2.3**, installed on this seat at `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/`, read on 2026-08-25 |
| Commit read | None. The source was the installed plugin rather than a clone, so no git commit was read, and the version above is the only identifier this reading can honestly carry. |
| Licence | MIT, `LICENSE` at that release's root, `Copyright (c) 2026 Matt Pocock` |
| Our side | `.agents/skills/scout-research/SKILL.md` and `tests/fm-scout-research.test.sh`, new in this change |

The read was read-only, out of the plugin cache.
Nothing from upstream is vendored here, no file in this repository is a copy of one of theirs, and nothing under `~/.claude/plugins/` was modified: a change there would be invisible, unversioned, and lost on the next plugin update.
The `research` skill ships no code, and every script this fork names - `bin/fm-brief.sh`, `bin/fm-spawn.sh`, `bin/fm-subagent-pretool-check.sh`, `bin/fm-transcript-search.sh` - is wholly our own and predates it.
The derivation is at the level of design, structure, and in places wording.

Upstream writes em dashes and this repository forbids them, so quoted em dashes are normalised to plain dashes; nothing else in a quotation is altered, and `...` marks every elision.
Bold inside quotations is the original's own.

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

This is the same notice the four sibling pages carry, deliberately repeated in full rather than cross-referenced.
The one-owner rule exists to stop two copies of a contract drifting when only one is edited, and it does not reach a verbatim third-party licence text that no page here may edit.
A notice that only lives beside a different skill is one file move away from not travelling with this one, which is the failure the licence condition is about.
`README.md`'s License section points at all five pages.

## What we kept

The original is twelve lines - four of frontmatter, an opening instruction, and three numbered ones.
Numbered instructions 1 and 2 are the part worth having and are carried across whole; the third became a fleet convention and is under "What we changed".

- **Primary sources, and the chain back to them.**
  "Investigate the question against **primary sources** - official docs, source code, specs, first-party APIs - not a secondary write-up of them. Follow every claim back to the source that owns it."
  Ours opens step 3 on that instruction and adds only the two concrete forms this fleet meets most: a claim about code is cited as `path:line` at a named version, and a claim about a running system carries the command that read it.
- **One Markdown file, each claim cited.**
  "Write the findings to a single Markdown file, citing each claim's source."
  Ours is step 6, unchanged in substance.
- **The deliverable is knowledge, not a change.**
  The original never implements what it finds, and neither does ours; `AGENTS.md` section 7 already states that a report may recommend implementation and does not authorize it.

## What we changed

Each of these is a substitution with our own mechanism, not a capability dropped.

- **The background agent became the fleet's scout dispatch.**
  This is the fork's whole reason, and the refusal that forces it is measured above.
  Ours names the path `AGENTS.md` section 7 already owns - `bin/fm-brief.sh <id> <repo> --scout`, replace `{TASK}`, then `bin/fm-spawn.sh <id> <project-dir> --scout` - and restates none of that lifecycle.
  What the skill adds is the four things a research `{TASK}` must carry, because that is the part the generic scaffold cannot know.
  The upstream property this preserves is that the researcher is a separate agent rather than the dispatcher: ours is a separate worker with its own isolated copy, its own durable record, and its own life beyond the dispatching session, which is strictly more than a background agent gives.
  The property it does not preserve is listed under "What we dropped", item 1.
- **"Somewhere sensible" became `data/<id>/report.md`.**
  The original says to "Save it where the repo already keeps such notes; match the existing convention, and if there is none, put it somewhere sensible and say where."
  We have the convention, it is not a matter of judgement, and `bin/fm-brief.sh --scout` already writes that path into the brief.
  So the skill states the location once and explicitly tells the author not to repeat it in `{TASK}`, because a scaffold and a brief that both name the deliverable are two copies of one contract.
- **A finished report became a report plus a completion gate.**
  Upstream has no such concept.
  Here a research question routinely exposes a choice that is the captain's, and an investigation may not be treated as complete until `decision-hold-lifecycle`'s shared gate has passed; teardown enforces it.
  The skill points at that owner and adds nothing to it.
- **"Keep working while it reads" was dropped as a stated benefit.**
  It is the original's reason for the background agent, and it is true here too - firstmate supervises other work while a scout reads - but it is a property of section 8's supervision loop rather than something this skill arranges, so restating it would put a second owner on it.

Ours outright, added rather than adapted.
Each is a discipline this fleet measured the absence of:

- **Search the internal record before anything external (step 2).**
  Upstream begins outside, because it assumes a repository with no institutional memory to search.
  This home has four stores that routinely already hold the answer - the session archive through `bin/fm-transcript-search.sh`, the curated knowledge files, the backlog, and `docs/` - and an external source will always return something, so a search that starts outside repeats work invisibly.
  The failure has a date: on 2026-08-25 three captain answers were reported unrecoverable by a check that could only see its own store, while all three sat in the session archive the whole time.
  That incident reached this fork as a statement in its own task instructions rather than as something this task re-measured, and it is recorded here as such - which is step 4's rule applied to this page.
- **The archive's build date, read before an empty result is believed.**
  This is ours and is not in upstream at all, because upstream has no archive.
  It is also a measured finding rather than a precaution: on 2026-08-25 on this seat the newest indexed session was from 2026-08-18, and `bin/fm-transcript-search.sh 'unrecoverable' --since 2026-08-20` reported `# searching 0 session files`.
  A week of material was outside every question the tool could be asked, and nothing in the empty answer said so.
  [`session-archive.md`](session-archive.md) owns the store and the bound; the skill only requires the date to be read.
- **The three labels: measured, documented, inferred (step 4).**
  Upstream asks for a citation, which answers where a claim came from but not how it was obtained.
  Those are different questions, and the gap between them is where a local reading gets relayed as a vendor guarantee.
  The rule that the label is set by how the claim was obtained rather than by how sure its author feels is the same discipline `AGENTS.md` section 3 already binds the currency round and the quota reading to, applied to research.
- **Unknown as a finding (step 5).**
  Upstream is silent on what to do when the sources do not settle the question, which in practice means the gap closes over.
  A gap left silent reads as an all-clear, which is the same reason `codebase-sweep` and `design-it-twice` each carry a what-this-does-not-cover section, and this skill carries one too.
- **A routing line for durable knowledge.**
  A finding that is fleet knowledge rather than an answer to this question goes to its owner under `AGENTS.md` section 6, instead of living only in a report that will not be read again.

## What we dropped

Every item below is a capability the original has and this adoption does not.

1. **Concurrency the dispatcher can start in one action.**
   Upstream's "so you keep working while it reads" is one tool call, and ours is a scaffold, a brief, and a spawn, with a supervision relationship attached to the result.
   Cost: real.
   The fleet path is heavier, and for a small question - one page to read, one fact to confirm - it is heavier than the question deserves, which will tempt a future session to answer it inline and skip the discipline entirely.
   Nothing here prevents that, and it should not be pretended away.
2. **Portability.**
   Upstream's version runs in any repository and any harness that can spawn a background agent.
   Ours needs a live firstmate home, this fleet's scout path, and the internal stores it searches first.
   Cost: none inside the fleet, total outside it, which is why the skill carries `metadata.internal: true` and why the plugin stays installed for exactly that case.
3. **Reaching the skill by name.**
   The plugin's is user-invocable and its description is written for someone typing it.
   Ours is agent-only: the captain speaks to firstmate in plain language, firstmate classifies the request as a scout at intake, and the brief tells the worker to load this skill.
   Cost: a captain cannot invoke it directly, and if firstmate misclassifies a research request as a ship task the discipline is never reached.
4. **`agents/openai.yaml`.**
   The original ships a per-agent interface manifest carrying a display name and a short description.
   Our skills carry both in `SKILL.md` frontmatter, so there is no second file.
   Cost: none.

## Repeating this comparison

    git clone --depth 1 https://github.com/mattpocock/skills.git
    # read skills/engineering/research/SKILL.md and LICENSE

Read-only, and outside this repository.
Re-read this page against their head when the research skill changes; the release this adoption rests on is recorded above, and a clone will give the commit identifier this reading could not.
