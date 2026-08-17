---
name: run-curate-knowledge
description: >-
  Prune and curate a knowledge file that loads at every session start - data/learnings.md, data/captain.md, AGENTS.md - by measuring it in bytes, splitting each entry's hot rule from its cold incident, and proving the archived half is still reachable.
  Use when the captain invokes /run-curate-knowledge, asks to prune, split, curate, measure, trim or shrink a learnings or captain or AGENTS.md file, asks why session start costs so much, or when a startup file has grown past the point where a session can carry it.
  Also use before declaring any such prune finished, because the check is what separates a curation from a file that merely changed address.
user-invocable: true
metadata:
  internal: true
---

# run-curate-knowledge

A session-start knowledge file grows because correct changes add and nothing subtracts.
Measured on this vessel's vendored `AGENTS.md`, by commit: 584, 593, 594, 597, 606, 609 lines over six days.
Monotonic, about four lines a day, and **every one of those commits was a legitimate improvement** - a real supervision fix, the outbound Telegram path, the currency round.
Nothing was wrong with any of them.
That is why this is a repeatable operation with a driver rather than a cleanup task: a one-off prune is a step function that gets eaten back within the week.

## Why there is a program

This was run by hand on this seat on 2026-08-16, and the hand version failed in a way a program does not.
The backlog audit's verdict was one sentence: **the split executed, nothing was curated.**
Headings went 232 to 252, content moved wholesale, ten entries out of 254 vanished with no record of why.
Startup cost fell 96 percent, which was worth having and is a different job from the one that was asked for.

Every item on that list is mechanically detectable, so the driver detects it instead of leaving it to an agent's care.
Run the driver.
Do not reproduce its judgement from memory - it will pass you and you will not notice.

## The split criterion, and it is not age

Split by whether a fact must be in hand **before the problem appears**.

- An agent would go looking once it hits the problem, so the trigger arrives **with** the problem: archive it.
- It must already be known to avoid the problem: it stays loaded, because by the time an agent thinks to look it up it has already done the thing.

Age is the obvious axis and it is the wrong one.
Sorting by age puts permanent safety facts in the archive and last week's trivia in the loaded half.

## Two shapes, and conflating them produces a bad prune

**Shape `private`** - `data/learnings.md`, `data/captain.md`.
Not tracked, no other owner.
It splits into a loaded half plus a real archive file the session never reads.

**Shape `shared`** - `AGENTS.md` and the rest of firstmate's tracked material.
It gets **no archive**.
It is under a one-owner contract - the phrase "owns" or "single owner" appears 34 times in it - so its detail moves to the file that already owns it (a skill, a doc, a script header) and an inline stub points there.
A second file full of `AGENTS.md` prose would be a second owner, which is the defect rather than the fix.
Load `firstmate-coding-guidelines` and read its inline-stub pattern before curating anything of this shape.

The driver detects the shape from git tracking and enforces the boundary in both directions.
It refuses an archive for a shared file, and it refuses a private run with no archive.

## Four rules, adopted from hlr

1. **Where an entry holds both a hot rule and a cold incident, split the entry.**
   Do not file it whole to one side.
   The rule stays loaded in a sentence or two; the incident goes to the archive.
   This is why our heading count went up in the hand run: whole entries moved because nothing forced a decision inside them.
   The driver makes this the default verdict on every entry, so keeping one whole is the deviation and costs a written reason.
2. **The route back lives inside the loaded half.** It is the only part read.
3. **Prove the route, do not assert it.**
   The driver executes the documented route once and requires its output to recover every archived entry occurrence using only what stays loaded.
   It prints a bounded worked transcript; describe the realistic situation needing each printed example.
4. **Every deleted entry is listed with the evidence that killed it.**
   The bar for archiving is judgement; the bar for deleting is proof.
   An unlisted entry deletion is the defect this exercise exists to prevent.

The proof and ledger unit is the entry at the selected heading level.
Nested headings travel inside their parent entry, and the structural check rejects any deeper archive heading outside every entry span.
On the real archive, all eight level-3 headings were inside returned parent entries, with zero orphans; spot checks recovered the injected-TUI, repair-family, and Bridge company-scope facts by reading their parent bounds.
The ledger accounts for entries appearing and disappearing, while edits inside a retained entry - including a nested heading, bullet, sentence, or paragraph - remain curator judgement recorded by the split verdict rather than something the driver mechanically polices.
A smaller promise that is actually kept beats a larger one the accounting cannot honour, and verdicts at every heading level would multiply the operator's work at every prune.

## Never report lines

Bytes per line is a house style, not a cost.
Measured across three seats: 77 here, 211 at hlr, 638 in hlr's `captain.md`, because that home writes one sentence per line in prose.
A vessel that compares line counts against ours exonerates itself while carrying the identical token cost.
Report **bytes** and **share of the startup surface**.
The driver refuses to print a line count rather than printing one with a caveat nobody reads.

## The operation

The driver is beside this file.
Every command below was run in the session that authored this skill, against this home's real files, and the output shown is real.
Use the driver's own `--help` for flags; this skill owns the sequence and the judgement, never the mechanics.

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py --help
```

### 1. Measure, and pick the target from what you see

With no file argument it measures the whole startup surface.
The denominator's file list is extracted from `bin/fm-session-start.sh` at run time rather than restated, so it cannot drift away from what actually loads.

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py measure \
  --home /home/coditan/coditan-firstmate
```

Real output from this home, abridged:

```
DENOMINATOR: startup surface = 250641 bytes
  AGENTS.md                       71354 B    28.5%  harness project instructions
  data/projects.md                 6238 B     2.5%  bin/fm-session-start.sh context digest
  data/secondmates.md              ABSENT        -  bin/fm-session-start.sh context digest
  data/captain.md                151636 B    60.5%  bin/fm-session-start.sh context digest
  data/captain-shared.md           ABSENT        -  bin/fm-session-start.sh context digest
  data/learnings.md               21413 B     8.5%  bin/fm-session-start.sh context digest
```

Read that as a ranking, not a scoreboard.
`data/captain.md` is 60 percent of this surface and has never been curated.
Expect your own numbers to be larger than the ones printed here: `data/learnings.md` grew from 19,438 bytes to 22,393 across the single session that authored this skill, which is the argument for the operation rather than a defect in the capture.

The share is a floor against a stated denominator, not a share of the whole session start: bootstrap diagnostics, the supervision block and the fleet-state digest are excluded because measuring them means running the locked session start.
Every run prints that exclusion.
If you have a captured digest, pass `--against <file>` and the denominator becomes its real byte size.

### 2. Snapshot the baseline

`check` and `report` both read this.
Take it before you edit anything; there is no way to reconstruct it afterwards.

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py measure \
  /home/coditan/coditan-firstmate/data/learnings.md \
  --home /home/coditan/coditan-firstmate \
  --save /tmp/before.json --top 8
```

### 3. Inventory, then fill in the verdicts yourself

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py inventory \
  /home/coditan/coditan-firstmate/data/learnings.md \
  --out /tmp/worksheet.md \
  --home /home/coditan/coditan-firstmate
```

Real inventory output from this home, abridged:

```
INVENTORY: 8 entries from .../data/learnings.md (shape private, level 2) -> /tmp/worksheet.md
  every verdict is pre-filled `split`. Change one only with a `why:` of at least 16 characters.
```

The worksheet carries one block per entry with its byte size and a pre-filled verdict.
**The driver never guesses hot from cold.**
There is no keyword heuristic anywhere in it, deliberately: no string match can answer "must this be in hand before the problem appears".
You judge; the driver records the judgement and then refuses a run that contradicts it.

For shape `private` the verdicts are `split` (default), `hot`, `cold`, `fold`, `delete`.
For shape `shared` they are `stub` (default), `hot`, `fold`, `delete` - `cold` and `split` are refused there because both presuppose an archive.
The worksheet prints the full definition of each; read it there rather than from memory.

Two things about the arithmetic, because they are in tension on purpose:

- A `split` is heading-neutral.
  Either half may keep the heading: the rule can stay loaded under it while the incident moves out, or the heading can go with the incident and the rule become a bullet under a broader heading.
  The `why` names wherever the other half landed, because that is the half the driver cannot find on its own.
- So the only things that make a heading count fall are **folds and deletions**.
  A worksheet left entirely at its `split` default will fail the check.
  That is the design: the default makes you look for the rule inside every entry, and the heading gate makes you consolidate as much as you divide.

### 4. Do the prose surgery

The driver does not rewrite knowledge files, and should not: prose surgery is judgement, and a program that guessed at it would reintroduce the failure it exists to catch.

Write the loaded half and the archive yourself, following the worksheet.
Put the route back **inside the loaded half**, and make it a command rather than a filename.
This is loaded-half content from this home's real `data/learnings.md`, not a shell command:

```
Reach it with `grep -n '^## ' data/learnings-longterm.md` and read the one section.
```

A filename alone is a location.
The check rejects it, because a reader who has to invent the search has no route.

### 5. Check - the part that would have caught us

Steps 5 and 6 below are shown against a completed worked example copied from the real "Cost and quota" section of this home's archive, with one split and one fold.
Substitute your own baseline, worksheet and pair.

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py check \
  --before .curate-proof/cost-before.json \
  --worksheet .curate-proof/cost-worksheet.md \
  --loaded .curate-proof/cost-loaded.md \
  --archive .curate-proof/cost-archive.md \
  --home /home/coditan/coditan-firstmate
```

It asserts, and exits non-zero on any of:

- the total heading count did not fall (private), or rose (shared);
- the loaded half did not get smaller in bytes;
- an entry disappeared that no verdict accounts for;
- a `delete` carries a label instead of evidence;
- a `split` left its rule nowhere, or a `fold` names no surviving heading;
- a `stub` names no owner path that exists, or the file never points at it;
- the loaded half does not name the archive, or names it with no runnable search;
- the documented route command fails to recover every archived entry occurrence;
- a nested archive heading lies outside every entry span.

Then it executes the documented command once against a protected copy and asserts that its output reaches every archived entry.
The `--prove-route` value limits only the printed example, never the assertion.

The passing output below came from a current run over a copy of the first two real entries under `Cost and quota` in `/home/coditan/coditan-firstmate/data/learnings-longterm.md`.
The source home was read only; the baseline, loaded half, archive, worksheet, and snapshot were worktree-local copies under `.curate-proof/`.

Real output from that worked copy:

```
HEADINGS  before 3  ->  after 2 (loaded 1 + archive 1)
BYTES     before 2174  ->  loaded 196 (9.0% of the original still loads)

ROUTE BACK
  the loaded half names cost-archive.md
  it hands the reader 1 documented search(es):
    grep -n '^## ' cost-archive.md

COMPLETE ROUTE ASSERTION
  route reaches 1 of 1 archived entries
PRINTED EXAMPLE (3 output lines maximum)
  $ (protected copy && /usr/bin/grep -n '^## ' cost-archive.md)
    1:## Das Abrechnungsmass der Flotte zaehlt frische Token, nicht gelesenen Kontext (2026-08-10, gemessen)

CHECK PASSED: headings 3 -> 2, bytes 2174 -> 196, every entry deletion is declared, and the archive is reachable from the loaded half.
```

### 6. Report

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py report \
  --before .curate-proof/cost-before.json \
  --loaded .curate-proof/cost-loaded.md \
  --archive .curate-proof/cost-archive.md \
  --worksheet .curate-proof/cost-worksheet.md \
  --home /home/coditan/coditan-firstmate
```

It prints before and after in bytes and share, the verdict counts, the fold list, and the deletion ledger with each entry's evidence verbatim.

Real output from that worked copy:

```
STARTUP COST
  before       2174 B      0.8% of a 256483 B surface
  after         196 B      0.1% of a 254505 B surface
  change      -1978 B   9.0% of the original still loads
  archived     2049 B   not loaded at session start
  retained     2245 B   loaded + archived, against 2174 B before (103.3%)

HEADINGS
  before 3  ->  after 2  (loaded 1 + archive 1)
  entries at level 2: 2 -> 0 loaded, 1 archived

VERDICTS
  split    1
  fold     1

DELETION LEDGER (0)
  none

FOLDED INTO ANOTHER ENTRY (1)
  - Fable wiegt am gemeinsamen Sitzungsmass ungefaehr 9 bis 20 Opus (2026-08-10, kontrolliertes Experiment)
    into: merged under Das Abrechnungsmass der Flotte zaehlt frische Token, nicht gelesenen Kontext
```

`retained` above 100 percent is not a bug and not a claim that more survived than existed: it is `loaded + archived` against the original, and a curation that writes a fresh rules summary over a fully retained archive lands there.

Relay the ledger to the captain in full.
A prune that deleted things is a prune he is entitled to audit, and the ledger is the only place that record exists.

## The direct-invocation path

An agent fixing one entry does not drive the whole operation.
`measure` takes a file and answers on its own:

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py measure \
  /home/coditan/coditan-firstmate/data/captain.md \
  --home /home/coditan/coditan-firstmate --top 5
```

That is the right call before adding to a startup file, when a session-start cost question comes up, and when deciding whether a new fact belongs inline at all.
`inventory` is likewise standalone: run it on one file to see the entry sizes laid out with a slot for a verdict, without committing to a full run.

## Shape `shared`, in practice

The same four steps, with `--shape shared` and no `--archive`.

```
.claude/skills/run-curate-knowledge/fm-curate-knowledge.py inventory \
  /home/coditan/coditan-firstmate/AGENTS.md \
  --shape shared --out /tmp/agents-worksheet.md \
  --home /home/coditan/coditan-firstmate
```

Each `stub` verdict's `why` must name the owner path the detail moved to.
The check requires that path to exist and requires the pruned file to actually point at it, so a stub that quietly drops its detail cannot pass.

Passing a `--archive` here is refused outright:

Real refusal output from this home, abridged:

```
fm-curate-knowledge: refused: --archive with --shape shared.
  A shared tracked file is under a one-owner contract. Its detail moves to the
  file that already owns it and an inline stub points there. An archive of its
  prose would be a second owner, which is the defect this exercise exists to
  prevent.
```

## Safety

`data/` is not version-controlled.
A body destroyed there is gone, and this has permanently destroyed considered records on this seat before.
Write the new loaded half and the new archive to fresh paths, run `check` against them, and only then move them into place.
Never edit a knowledge file in place and check afterwards - the baseline you need is the file you just overwrote.

When curating another home's files, or when the run is a rehearsal, work on copies and say plainly in the report which you did.

`AGENTS.md` and everything else on `AGENTS.md` section 1's shared tracked list goes through this repo's pipeline and PR path like any other change.
Firstmate does not hand-write it.

## What this does not cover

It measures a floor against a denominator it can compute without touching the fleet.
The whole session-start digest is larger, and this run does not measure it: pass `--against <captured-digest>` when you have one, and say which denominator you used whenever you quote a share.
A denominator it could not compute is reported as unmeasured, never as zero.
