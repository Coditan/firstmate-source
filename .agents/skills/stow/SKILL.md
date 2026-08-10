---
name: stow
description: Sweep the current session for uncaptured durable knowledge and file it to disk before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset, before a context reset, before a compaction the harness is about to perform anyway (file ahead of one; a compaction is never the instrument that holds the context ceiling), on a context-ceiling wake that asks for this sweep before the receipt and reset commands it names, and periodically to keep operational memory current between those events.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is the firstmate-internal skill. The public, installer-facing counterpart lives at skills/stow/SKILL.md - deliberately a separate file with no shared code or environment branching. Keep them independent. -->

# stow

Sweep this session for durable knowledge that only exists in conversation right now, and write it to the disk locations firstmate already prints in the next session-start context digest.
The goal is a session that is safe to reset or destroy because everything durable has already been captured.

## When the context ceiling calls this sweep

The captain invokes `/stow` whenever they like, and that is still the ordinary case.
The other caller is the context ceiling.
`docs/context-reset.md` owns that mechanism in full: how the watcher measures the session, the four branches that measurement can take, the receipt, every refusal, and the evidence behind them.
This section adds only what the sweep owes the mechanism, because the sweep is the one step it cannot perform for itself.

Exactly one of those four branches orders this sweep: the reset branch, which fires when the session is over the ceiling, the fleet is quiet, the captain is not present, and the re-entry path is intact.
Only its wake names `/stow` and then, in the same turn, the receipt and reset commands.
The other three branches - a captain who is present or in away mode, a broken re-entry path, or a session that cannot be measured at all - carry a diagnosis, never that order, so a wake that does not name those commands is never authority to run them.

A captain who is asked and answers yes is a second caller, and the only one that is not a wake.
The ask branch reports a present captain; asking them is what section 8 requires, and their answer, not the wake, is the authority.
On that answer this sweep runs in the same turn as the receipt and then `bin/fm-context-reset.sh --captain-approved`, which is the only path that can complete a reset the captain asked for - the ordinary path applies an idle window measured from the moment they spoke to approve it, and refuses.
`docs/context-reset.md` owns that path, including what it can and cannot establish about what the captain meant, and the tool's own help owns its mechanics.
Nothing here lets the flag stand in for the answer: with no captain approval there is no approved path, only the wake's diagnosis.

- **The sweep is the only judgement in an otherwise mechanical path, so its thoroughness is what makes the reset honest.**
  Whether a semantic sweep caught every durable fact cannot be checked mechanically, so the receipt can only attest to this sweep, never verify it, and a thin sweep still produces a structurally valid receipt (`docs/context-reset.md`, "What the receipt is, and what it is not").
- **Run the sweep and its receipt in the single turn the wake asks for, and do not pause to report progress between them.**
  Anything the captain says in that gap voids the receipt, correctly, so a pause only re-earns the refusal; `docs/context-reset.md` owns why.
- **Take no action during the sweep that makes the fleet non-quiet.**
  Spawning a worker to land project-intrinsic knowledge would do exactly that and void the receipt after it is spent, so file such a finding as a queued backlog item for later routing instead (step 3).
- **On this caller the turn ends in the reset with no captain-facing message.**
  Section 8 makes benign wake handling end with tool calls and no message, and any text written here lands in a conversation the clear is about to discard; the next session rebuilding from the records this sweep filed is the report, so step 5's captain summary is for the interactive `/stow` caller only.
- **Sweep as though the conversation were about to be lost, even though a clear is resumable.**
  A missed finding is then misplaced rather than lost, but that safety net is not the plan.

The instrument is stow-then-clear, and `docs/context-reset.md` owns why it is never compaction; nothing in this skill adds, enables, or recommends compaction as a way to hold the ceiling.

## What it does

1. **Sweep the session for uncaptured durable knowledge.**
   Read back over this conversation and look for:
   - Operational learnings: fleet-local facts and gotchas discovered while operating firstmate (a script's sharp edge, a harness quirk, a recurring false alarm and its real cause).
   - Captain preferences expressed in passing: a working-style or approval preference the captain stated conversationally rather than through the destination selected by AGENTS.md's knowledge-routing table.
   - Project-intrinsic facts discovered: build, test, release, or architecture facts about a project that belong in that project's own `AGENTS.md`.
   - Decisions made: a standing choice the captain made this session that should outlive it.
   - Undone next steps: anything left open that has not yet been filed as backlog work.

2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md (section 6, "Knowledge routing") is the single source of truth for where each kind of knowledge belongs.
   Read that table and route each finding there instead of re-deriving the mapping here.

3. **Write within firstmate's existing write boundaries.**
   This skill does not grant any new write permission; it only prompts firstmate to use the boundaries that already exist (AGENTS.md section 1):
   - Captain preferences and fleet-local operational facts: hand-write directly to the destination selected by AGENTS.md's knowledge-routing table, using inspect-then-update every time.
     Before writing, inspect the destination, find the existing bullet or section the finding duplicates or supersedes, and rewrite it in place rather than adding a new trailing entry.
     `data/learnings.md` may not exist yet; create it on first local learning, in the same dated, evidence-backed, curated style as the captain-preference files.
   - Project-intrinsic knowledge: never hand-write a project's `AGENTS.md`.
     Route it through a normal ship task so a crewmate records it via `bin/fm-ensure-agents-md.sh` and commits it through that project's delivery pipeline, exactly as section 6 describes.
     If the fleet is live, delegate this to a crewmate rather than doing it inline.
     On the context-ceiling caller this routing must not happen during the sweep: spawning a worker makes the fleet non-quiet and voids the receipt the reset depends on, so file the finding as a queued backlog item now and let it be routed on an ordinary turn after the reset.
   - Knowledge generalizable to every firstmate user: this repo's own `AGENTS.md` (or other shared, tracked material), shipped through the normal branch -> no-mistakes -> PR -> captain-merge pipeline for this repo (section 1), never hand-committed straight to `main`.
   - Task-scoped notes: inspect the relevant backlog item with `tasks-axi show <id> --full`, judge whether the new note is new, duplicate, superseding, or obsolete, then write a considered replacement body with `tasks-axi update <id> --body-file <path>`.
     When the replacement intentionally supersedes prior state that should remain recoverable, add `--archive-body` to that update command so the prior body stays recoverable without copying it into the replacement.
     Never append.
     If hand-editing `data/backlog.md` per the active backend, make the same inspect-then-update edit in place.
   - Undone next steps: file each as a queued backlog item (section 10), with `blocked-by` recorded if it genuinely depends on something else.

4. **Curate with inspect-then-update.**
   Every write starts by reading the current destination and deciding how the finding changes what is already there.
   Use this checklist before writing:
   - Which existing bullet, section, or task body does this supersede?
   - Can this be a one-sentence rewrite instead of a new entry?
   - Should an older bullet or note be deleted, retired, or archived because it is now obsolete?
   When a finding overlaps or supersedes something already on disk, rewrite or prune the existing entry instead of piling on a new one.
   Graduation moves are limited to exactly three: promote a learning to the shared `AGENTS.md` via PR, fold it into the captain-preference destination selected by AGENTS.md, or delete a stale entry.
   Do not invent other graduation paths.

5. **Report to the captain (interactive caller only).**
   This step is for a `/stow` the captain invoked; the context-ceiling reset caller ends its turn in the reset with no captain-facing message, as the ceiling section above and section 8 both require.
   For an interactive `/stow`, summarize in plain outcome language (section 9): what was stowed and where, what was filed to the backlog, and whether the session is now safe to reset or destroy - i.e. whether every durable finding from this sweep now lives on disk rather than only in this conversation.
   If something could not be captured yet (for example, project-intrinsic knowledge waiting on a crewmate to land it), say so explicitly rather than reporting the session fully safe.

## Scope exclusion: no skill storage

`/stow` must **never** store, create, or edit a skill as a destination for any finding.
There is no "graduate this to a skill" move in this skill's routing.
This is a deliberate, standing exclusion, not an oversight: even with the two-tier skill layout, a stow sweep is a memory-routing operation, not a way to author or mutate skills.
Writing learnings into either `.agents/skills/` or public `skills/` would still risk mixing fleet-local material with shared firstmate behavior or standalone installer-facing behavior.
Until a human deliberately scopes a skill change as firstmate repo work, route generalizable knowledge to the shared `AGENTS.md` (or other shared, tracked material) via the pipeline, and fleet-local knowledge to `data/`, never to a skill.
