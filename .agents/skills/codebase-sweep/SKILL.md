---
name: codebase-sweep
description: >-
  Sweep one repository for codebase-design findings, classify each by what a wrong fix would cost and whether anyone would find out, sort them, and go ahead with the ones that are both reversible without the captain and contained inside one module.
  Use when the captain invokes /codebase-sweep, when a fleet notice tells this vessel to sweep its own repositories, before a repository is about to take a large amount of agent work, and before proposing that a module be restructured.
  It sweeps one repository at a time and never the fleet, because a sweep that reaches into homes this seat does not own is unauditable and spends quota nobody approved.
  The three risk tiers are the captain's own framing and never the talk's: the talk this sweep is grounded in defines no risk scale of any kind, measured against its full transcript.
  A finding whose fix grows past what its tier assumed stops and re-classifies rather than proceeding on the old label.
user-invocable: true
metadata:
  internal: true
---

# /codebase-sweep

A repository that is hard for a stranger to navigate is hard for every agent that will ever be pointed at it, because an agent arrives with no memory of it at all.
This sweep looks for that, one repository at a time, and it ends with three things: findings the captain can read in order, work already under way on the ones that are reversible without him and contained inside one module, and the questions that are his named as questions rather than dressed up as proposals.

## The obligation is here, and a cadence only fires

A timer that swept eleven repositories by itself would be unauditable, would spend quota nobody approved, and would reach into homes this seat does not own.
So the fleet notice tells each vessel to run this skill, and each vessel runs it on its own repositories and decides for itself.
This skill is that obligation.
It is not a scheduler, it registers no timer, and it never sweeps another vessel's repositories.

Firstmate does not read a whole repository itself and never writes to one.
Dispatch the sweep as an investigation, one per repository, under `AGENTS.md` section 7, and dispatch whatever comes out of it as ordinary work through that project's own delivery path.
Name the repository before the sweep starts; a sweep with no named repository has no scope and no report to write.

## Step 1 - sweep

Load `codebase-design` first.
On this seat it is a plugin skill (`mattpocock-skills:codebase-design`), not a directory inside any repository, so reach it through the harness skill mechanism rather than looking for it in the project.
If it is not installed here, say so in the report and stop rather than improvising its vocabulary from memory.
A sweep that silently drops the vocabulary it claims to use is an unmeasured claim wearing the clothes of a measured one, and that is the defect class this whole instrument exists to avoid.
Its `DEEPENING.md` and `DESIGN-IT-TWICE.md` are worth opening when a finding needs a proposed shape rather than only a diagnosis.

Then work the five subjects below.
Every one of them is in the talk, and the wording is kept close to it on purpose; `docs/codebase-sweep-provenance.md` carries the transcript's own words beside each.

1. **Could a stranger find the right module from folder names and public interface types alone?**
   Not "is it documented" and not "would you find it".
   An agent entering this repository has never seen it before, so the test is what the file names and the exported types tell someone with no memory of the place.
2. **Are the modules deep, with small interfaces, or is this a web of shallow ones?**
   Deep means a lot of behaviour behind a small interface.
   Shallow means the interface is nearly as large as the implementation, and a web of those is what the talk names as the thing to restructure.
3. **Is the interface where a person applies taste, while the implementation is the agent's?**
   A module whose implementation cannot be handed over without also renegotiating its interface has its seam in the wrong place.
4. **Does the file system match the mental map?**
   The grouping a maintainer holds in their head is worth nothing to an agent unless the directories say the same thing.
   Imports that reach across those groups without going through an interface are the evidence.
5. **Are the tests good enough to be the agent's feedback loop?**
   The question is not coverage.
   It is whether a change inside a module produces a red check quickly enough for the agent to learn from it before it has moved on.

Write each finding with four parts: the module, the subject it failed, what a reader can point at (a path, an exported name, a test name, an import), and the smallest change that would answer it.
A finding with nothing pointable is an opinion, and an opinion does not go in the report.

## Step 2 - classify

### Attribution, which is the constraint that must not slip

The three tiers below are **the captain's own framing**.
The talk defines no risk scale: no tiers, no severity ranking, and nothing at all about which findings are safe to act on without a human.
That was measured against the full transcript, and against all three talks this fleet was sent, before it was written down.
`docs/codebase-sweep-provenance.md` carries the measurement, the transcript source, and the captain's own words.

Never write, and never let a report imply, that the talk ranks findings or names these tiers.
Attributing an invented scale to a source is precisely the defect this fleet spent 2026-08-16 cataloguing: an explanation that fits, put where an observation belongs.

The one ordering the talk does give, and it may be cited as the talk's: **a web of shallow modules is the thing to restructure.**
That is a target, not a scale, and it must not be dressed up as three tiers.

### The axis

The axis is not "how bad is this code".
It is: **if the fix is wrong, what does that cost, and would anyone find out?**
How bad a smell is, is a judgement nobody can check.
Reversibility and detectability are properties you can point at, and they are what makes acting without asking either safe or reckless.

### LOW - reversible without the captain

His words, verbatim, 2026-08-17: **"low is everything reversible without me"**.
His separate clarification, given the same day: **"containment is the missing half"**.

**Both halves of the boundary are his, and this skill narrows neither.**
Reversibility is necessary for low and middle alike, so it cannot tell them apart; containment is what does.
Low is reversible without him and contained inside one module, while middle is reversible but its blast radius leaves the module.

Only one thing here is ours, and it is neither half.
An earlier draft on this seat paired containment with a second requirement of its own invention: that a check would go red if the change were wrong.
He has since supplied containment himself, so containment is his; what was this seat's invention is the detectability requirement alone, and that was stricter than what he asked for.
Presenting it as his boundary would have been substituting our caution for his instruction, so it survives below as a confidence aid, clearly labelled as ours, and never as a third gate.
Do not quietly re-narrow the tier back to it, and do not drop containment in the belief that it is ours.

**Entry test: can this change be undone without him, and is it contained inside one module?**
Undone means undone in practice, not undone in principle: a revert that anyone on the crew can raise, land, and be finished with.
A change is not reversible without him if undoing it needs his decision, needs another project to move, or leaves something behind that a revert does not take back.

Typical: extracting an implementation detail, naming, moving a file into the folder its module already implies, adding a test that pins behaviour that already exists because the new test is the check that would go red, deleting genuinely dead code.

Go ahead with these, through the project's selected delivery path, and report them afterwards rather than asking first.

#### The detectability flag, which is ours and is not a demotion

Reversibility buys nothing if nobody ever learns there is something to reverse: **a change nobody can tell went wrong is one nobody will know to reverse.**
So beside every low finding, name the check that would go red if the change were wrong.

If you cannot name one, **write that beside the finding in the report and do the work anyway.**
It is a flag on the record, never a demotion to middle.
Demoting on our own test would be overriding him, and where his boundary and our aid genuinely conflict - a reversible change whose failure would be silent - the work goes ahead per his boundary and the silence is named in the report.
He can tighten the rule if he wants it tightened; pre-empting that is not ours.

### MIDDLE - the blast radius leaves the module

Reversible, but something outside has to change, or someone would have a view about the shape.
The talk's own position is that the interface is where a human applies taste and the implementation is the agent's, so a change to an interface is not the agent's to settle alone.

Typical: changing an exported signature, splitting one module into two, moving a seam, introducing a new boundary, changing what a module is for.

**Entry test: would a caller outside this module change, or would a person have a view on the shape?**
Either yes puts it here.

These are sorted and brought to the captain with the proposed shape, not only the finding.

### HIGH - not provable by tests, or not cheaply undone

Typical: restructuring a web of shallow modules, which is the talk's own thing to restructure and therefore also the largest and least reversible thing it recommends; anything touching identity, credentials, or stored data; modifying or deleting an existing test, since the instrument and the subject are then the same and you can no longer state what would prove the change wrong; anything where nobody can state what correct looks like without him.

**Entry test: can you state the observation that would prove this change wrong?**
If you cannot, it is high.
The inability to name a disproof is the classification, not a reason to keep looking for a gentler label.

These are his, with the question named rather than the work proposed.

### The rule that keeps the tiers honest

**A finding whose fix grows past what its tier assumed stops and re-classifies.**
A low fix that turns out to need an interface change is a middle finding discovered late, not a low one already in progress.
Stop the work, file it again at its real tier, and carry both the original classification and the reason it moved into the report, because a tier that only ever gets easier is a tier nobody is enforcing.
That is the ask-user boundary applied to a class rather than to a single finding; load `ask-user-authority` before deciding one of these yourself.

## Step 3 - sort

Sort by **tier first, then by how many other findings each one unblocks.**
A web of shallow modules usually holds several findings that stop being separate the moment it is untangled, and that is what the second key is measuring.

What reaches the captain is ordered, not listed.
Give each entry the module, the tier, the one-line finding, its unblock count, and for a low entry either its named check or the flag saying no check was nameable.

## Step 4 - act on the low tier

"Go ahead with the low risk ones" is standing authority to do that work without asking each time.
It is not authority to skip the delivery path, not authority for anything destructive or irreversible, not authority over a finding that turns out to be mis-classified, and not authority to merge.

**Read the project's posture at the time and never carry one in your head.**
`bin/fm-project-mode.sh <project>` prints the project's delivery mode and its yolo flag from the registry, and that reading at that moment is the only correct one.
Never hardcode today's merge authority into a plan, a brief, a report, or this skill.
The captain said on 2026-08-17 that he will alter the standing merge order, and anything that bakes in the posture of the day it was written will be wrong the moment he changes it, and wrong silently, which is worse than wrong loudly.

Then it is ordinary lifecycle and this skill adds nothing to it.
Load `to-backlog` before filing more than one item, dispatch the work under `AGENTS.md` section 7, let the project's selected delivery path take it to a pull request, and let the merge authority be whatever the posture says when the pull request is ready.

## Step 5 - report, and route the decisions

The middle and high findings are captain decisions, and a decision does not live in a report alone.
Load `decision-hold-lifecycle` before treating the sweep as complete: it owns registering each unresolved decision durably and completing the inventory, and cleanup enforces that gate.

Relay the sort to the captain in the language of `AGENTS.md` section 9: the module, what it costs him, and the decision, never the internal labels this skill uses to get there.

## What this sweep does not cover, stated because a silent gap reads as an all-clear

- It measures design shape.
  It is not a correctness review, a security review, or a performance review, and a clean sweep says nothing about any of those.
- It sees one repository.
  Eleven are registered on this seat and other vessels have their own, so a clean sweep of one repository is never a statement about a vessel, and a clean sweep of a vessel is never a statement about the fleet.
- It reads the code as it is on the day it runs.
  A finding is a reading with a date on it, and it goes stale exactly like every other record this fleet re-measures.
- The tiers rank what a wrong fix costs.
  They do not rank how much the fix is worth, so a repository with only low findings is not thereby in good shape.
