---
name: scout-research
description: >-
  Answer a research question from evidence: this home's own record first, then primary sources, with every finding labelled measured, documented, or inferred, and an honest unknown wherever the evidence does not settle it.
  Load before dispatching an investigation whose deliverable is knowledge rather than a change, and when carrying one out as a scout.
  It is this fleet's fork of the `research` skill from mattpocock/skills, whose opening step - spin up a background agent - a firstmate primary cannot execute, because `bin/fm-subagent-pretool-check.sh` refuses harness delegation tools there.
  Choose the plugin's `mattpocock-skills:research` instead only for research inside an ordinary repository with no fleet dispatch behind it and no fleet record to search.
  Adapts the research skill by Matt Pocock (MIT); docs/scout-research-provenance.md carries the notice.
user-invocable: false
metadata:
  internal: true
---

# scout-research

A research question is answered here the way every other reading in this fleet is: from evidence that names where it came from, with the parts nobody measured left visibly unmeasured.
This skill owns that discipline and the shape of the report it lands in.
Firstmate loads it to brief such a task, and the scout loads it to carry one out.

The discipline is adapted from the `research` skill in [`mattpocock/skills`](https://github.com/mattpocock/skills), by Matt Pocock, under the MIT licence.
`docs/scout-research-provenance.md` carries the notice and the accounting of what was kept, changed, and dropped.

## Step 1 - dispatch it as a scout, which is the step upstream cannot give you

Upstream's first instruction is to spin up a background agent.
**In a firstmate primary home that instruction is refused before it runs.**
`bin/fm-subagent-pretool-check.sh` classifies a delegation-shaped tool name and denies it, because work started that way has no `state/<id>.meta` and no `data/<id>/brief.md`, leaves every firstmate guard inert, and dies with the session that started it.
Measured on 2026-08-25 from this repository: `bin/fm-subagent-pretool-check.sh --tool Task` exits 2 with that deny object when `FM_ROOT_OVERRIDE` names a primary home, and exits 0 silently inside a task worktree.
So the guard is not what makes the plugin unusable everywhere - a crewmate inside its own worktree may still delegate - it is what makes upstream's opening step unusable at the one place research is dispatched from.

The lifecycle is `AGENTS.md` section 7's, and this skill restates none of it: classify the request as a scout, scaffold with `bin/fm-brief.sh <id> <repo> --scout`, replace `{TASK}`, and spawn with `bin/fm-spawn.sh <id> <project-dir> --scout`.
What this skill owns is what goes into `{TASK}`, and a research brief that omits any of it produces a report nobody can act on:

- **The question in one sentence**, and what would count as having answered it.
- **What the answer will be used for**, because that decides how much of the evidence has to be first-hand.
- **The sources already known to be authoritative**, named by URL, repository, or path, and which of them has already been read.
- **An instruction to load this skill before starting.**

Do not restate the report location or the completion gate in `{TASK}`.
The scout scaffold already carries both: it names `data/<id>/report.md` as the deliverable and already requires the shared completion gate below.

## Step 2 - search this home's own record before anything outside it

**External search is the second move, never the first.**
A question this fleet has already measured has an answer that is better than anything a vendor page can give, and it is already carried in the vocabulary the report has to be written in.

Four places hold it, and a research brief that skips them is repeating work someone already paid for:

- `bin/fm-transcript-search.sh '<pattern>'` reads this home's own session archive, which holds what was actually typed rather than a later paraphrase of it.
- `data/learnings.md`, `data/captain.md`, and `data/captain-shared.md` hold curated fleet knowledge and the captain's own settled preferences.
- The backlog, through `tasks-axi`, holds open questions, fog records, and the decisions already answered.
- `docs/` and `config/` hold the measurements and the local operating choices, and a `docs/*-backend.md` page is a recorded reading with a date on it rather than a belief.

**Read the archive's build date before treating an empty result as absence.**
The archive is a rebuilt derivative, not a live feed, and a search of it answers only for the sessions the last rebuild reached.
Measured on 2026-08-25 on this seat, the newest indexed session was from 2026-08-18 and `--since 2026-08-20` searched 0 session files, so a week of material was outside every question the tool could be asked.
`docs/session-archive.md` owns what the store holds, how to rebuild it, and the bound every claim made from it must carry.
An empty result over a store whose build date precedes the period in question is unknown, not no.

The failure this step exists against has a date, and it is reported here rather than re-measured, because the build date above puts that day outside what this skill's own instrument could read back.
On 2026-08-25 three captain answers were reported unrecoverable by a check that could only see its own store, while all three sat in the session archive the whole time.
A search that starts outside reproduces that, and it reproduces it invisibly, because an external source will always return something.

## Step 3 - primary sources, and never a write-up of one

Investigate the question against primary sources - official documentation, source code, specifications, first-party APIs - not a secondary write-up of them.
Follow every claim back to the source that owns it.

A secondary write-up may be used to find the primary source and must never be cited as the fact.
Where the primary source is code, read the code rather than the release note about it, and cite it as `path:line` at a named version, tag, or commit.
Where the source is a running system, the reading is the evidence and the command that took it goes in the report beside it.

## Step 4 - label every finding measured, documented, or inferred

Every claim in the report carries one of three labels, and the label is set by how the claim was obtained rather than by how sure its author feels:

- **Measured.**
  This fleet ran something and read the result.
  The report carries the exact command, the date, and the output.
  It is evidence about this seat on that day, and never evidence about another vessel or about the tool in general.
- **Documented.**
  A primary source states it.
  The report carries that source and the version of it that was read.
- **Inferred.**
  Nobody measured it and no source states it; it follows from the two above.
  The report says what it follows from.

**A measured finding is never dressed as a documented one, and an inferred one is never dressed as either.**
This is the failure this fleet keeps hitting: a confident summary blurs the three, and a later reader acts on a local reading as though a vendor had guaranteed it.
Confidence upgrades nothing.
If a claim's label would change depending on how the sentence is phrased, it is inferred.

## Step 5 - unknown is a finding, and it is reported as one

Where the evidence does not settle the question, the report says so and says what would settle it.
An honest gap beats a tidy answer, and a gap left silent reads as an all-clear - which is how a reading nobody could take gets relayed as a reading that came back clean.
Say which source was unreachable, which command could not run, and which part of the question remains open.

A report whose every claim is confident and whose unknown section is empty is the shape to distrust, not the shape to aim at.

## Step 6 - one Markdown file, each claim cited

The deliverable is a single Markdown file at `data/<id>/report.md`, which is the scout convention and survives the worktree it was written in.
Nothing else survives, so anything worth keeping is in it.

Each claim carries its citation and its label.
The report stands alone: the question, what was done, the findings with their evidence, what remains unknown, and what is recommended.
A recommendation may propose implementation; it never authorizes it.

Where a finding is durable fleet knowledge rather than an answer to this question, route it under `AGENTS.md` section 6 rather than leaving it only in the report.

## Step 7 - the completion gate

A research question often exposes a choice that is the captain's.
Load `decision-hold-lifecycle` and pass its shared completion gate before the report is treated as complete; teardown enforces it.
That skill owns the gate in full and this one adds nothing to it.

## What this does not cover, stated because a silent gap reads as an all-clear

- It answers one question and produces knowledge.
  Whether the work it recommends should be done is the captain's, and dispatching that work is `AGENTS.md` section 7's.
- It does not make a stale archive current.
  Refreshing the store is `bin/fm-transcript-refresh.sh` and its own doc's business, and this skill only requires the build date to be read before an empty result is believed.
- It says nothing about which sources are trustworthy in a given domain.
  Primary is a test of provenance, not of correctness, and a first-party document can be wrong.
- A measured finding is one seat on one day.
  It is a reading with a date on it, and it goes stale exactly like every other record this fleet re-measures.
