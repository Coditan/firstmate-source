---
name: domain-modeling
description: >-
  Sharpen the terms a piece of work runs on and record its decisions in passing: challenge a word the moment it wobbles, invent scenarios that force a boundary to be precise, check a claim against the thing itself rather than against memory, and write the resolution down where the next reader will meet it.
  Use whenever a term looks like it is doing two jobs, a vague or overloaded word needs a canonical form, a claim about how something works or what a tool can do is about to be published, or a hard-to-reverse decision has just been made.
  Also use before translating any term into another language, because a domain's proper nouns are never translated.
user-invocable: true
metadata:
  internal: true
---

# Domain modeling

Build and sharpen the vocabulary a piece of work runs on, while the work is happening.

> **This skill adopts [domain-modeling](https://github.com/mattpocock/skills/tree/main/skills/engineering/domain-modeling), by Matt Pocock, from [`mattpocock/skills`](https://github.com/mattpocock/skills), used under the MIT licence.**
> It is not an original design.
> The five live moves below, the three-part bar a decision must clear, and the glossary rules are its own.
> This version keeps them and diverges most visibly in three ways: it writes into the stores this fleet already has instead of creating a `CONTEXT.md` and a `docs/adr/` tree, it widens cross-referencing from code to any checkable artifact, and it carries the terminology rule below.
> [`docs/domain-modeling-provenance.md`](../../../docs/domain-modeling-provenance.md) carries the copyright notice and records the rest in full: what was kept, what else changed, and which capabilities were left behind.

This is the active discipline, not the passive one.
Reading a project's vocabulary before using it is a one-line habit any task can perform and is not this skill.
This skill is for when the model is being changed: coining a canonical term, catching a word that has quietly acquired a second meaning, checking a claim against the thing it describes, recording a decision that will be expensive to revisit.

It creates no store of its own.
Everything it resolves is routed into a home that already exists, under `AGENTS.md` section 6.

## The five moves

### Challenge against the vocabulary already in use

When a term conflicts with how the same project, document, or runbook already uses it, say so at once rather than proceeding on the reading that happens to be in front of you.
"This runbook defines review authority as X, but the other one uses it for Y; which is meant here?"
A term that means two things in two documents is not a wording problem, it is two different pieces of work wearing one name.

### Sharpen a fuzzy term

When a word is vague or doing several jobs, propose one precise canonical term and name the jobs it was covering.
"You are saying roster; do you mean the roster of vessels or the roster the knowledge graph is built from? Those are different files."
Resolve it before anything is designed on top of it.
A schema built on the wrong noun is not repairable by renaming afterwards.

### Invent scenarios that force the boundary

When two concepts are being related, stress-test the relationship with a specific case rather than accepting the general statement.
Choose the case that sits closest to the boundary, because that is where the two concepts are actually distinguished.
A definition that survives an ordinary example and fails an edge case has not been tested.

### Check the claim against the thing itself

When a statement is made about how something works or what something can do, verify it against the artifact rather than against memory or documentation.
Read the code, the actual file, the installed version, the real run.
Then surface the contradiction plainly: "the code cancels whole orders, but partial cancellation was just described as possible; which is right?"

Three failure shapes make this the highest-value move, and none of them is a coding error:

- A capability claim that is true of the tool and false of the version actually installed.
- A count that includes something that was recorded but never ran.
- A name that resolves to one file in the speaker's head and a different file on disk.

Each is caught by looking, and by nothing else.
Before a claim is published to anyone outside the conversation, it has to have been looked at.

### Write it down where the next reader will meet it

When a term is resolved or a decision is made, record it immediately.
Do not batch it to the end of the session; the resolution is cheapest to write exactly when it crystallises and is usually lost otherwise.
Where it goes is owned by `AGENTS.md` section 6, which this skill applies rather than restates:

- A term that almost every contributor to one project needs is knowledge about that project, so it belongs in that project's committed `AGENTS.md`.
  [`GLOSSARY-FORMAT.md`](./GLOSSARY-FORMAT.md) owns how the entry is written.
- A term or fact about how this fleet itself operates belongs in the home's `data/learnings.md`.
- A decision that clears the bar in [`DECISION-RECORD-FORMAT.md`](./DECISION-RECORD-FORMAT.md) belongs in a durable decision record, which that file locates.
- A captain's own preference about wording or register belongs in `data/captain.md`.

Firstmate never writes a project file itself.
A project-side glossary or decision entry is written by a crewmate through that project's selected delivery path, using `bin/fm-ensure-agents-md.sh`, exactly as section 6 requires.
This skill decides what to record and where; it does not relax the project-write boundary in `AGENTS.md` section 1.

## Terminology rules in force

### A domain's proper nouns are never translated

What a tool, a repository, or a product is actually called is its name, in every language.
workbench stays workbench and is never Werkbank.
Treehouse stays Treehouse and is never Baumhaus.
The same holds for Wayfinder, no-mistakes, Bridge, Lavish, graphify, and tasks-axi.

Translating a proper noun does not make it clearer, it makes it unfindable.
Nobody searching for Werkbank finds anything, because nothing anywhere is called that.
The cost lands on the next reader, who now cannot connect the sentence to the thing.

### The boundary against the captain-facing translation contract

These two rules point in opposite directions and are easy to confuse, so hold the boundary explicitly.

`AGENTS.md` section 9 requires translating firstmate's own internal machinery out of captain-facing text, such as worktree, teardown, harness, wake, stale, brief, and crewmate.
Section 9 owns that list in full and is unchanged by this rule.

This rule protects the opposite category.
Section 9 covers a word firstmate invented to describe its own operation, and a plain-English rendering of it is strictly better for the reader.
This rule covers a word that is somebody's name for a thing, where any rendering is strictly worse.
When unsure which applies, ask whether the word would appear in a search of the code, the repository list, or the tool's own documentation.
If it would, it is a name, and it stays.

### Register

German is written per DU, never Sie.
A home whose `data/captain.md` records a different preference follows that instead; `data/captain.md` is where a captain's register preference lives, and it is the full record behind this line.

## Deciding whether something earns a record

A decision earns a durable record only when all three of these hold.

1. **Hard to reverse.** Changing your mind later carries a real cost.
2. **Surprising without context.** A future reader will look at the result and wonder why it was done this way.
3. **The result of a real trade-off.** Genuine alternatives existed and one was chosen for stated reasons.

Miss any one and there is no record.
An easy-to-reverse decision will simply be reversed, an unsurprising one prompts no question, and a decision with no alternative records nothing beyond doing the obvious thing.
[`DECISION-RECORD-FORMAT.md`](./DECISION-RECORD-FORMAT.md) owns what qualifies, where the record goes, and its shape.

A decision that is not yours to make is a different thing entirely.
It goes to `decision-hold-lifecycle`, which is the single owner of unresolved captain decisions.
This skill records decisions that have already been made; it never records, answers, or closes one that is still open.
