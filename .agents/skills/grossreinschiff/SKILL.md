---
name: grossreinschiff
description: >-
  Sweep the fleet for records, instructions, branches, tools, and workspaces that have stopped being true, and report each finding with the test behind its verdict.
  Use when the session-start check reports GROSSREINSCHIFF, when the captain invokes /grossreinschiff or asks for the weekly cleanup, and before any fleet-wide claim that rests on records nobody has re-measured.
  It reports; it never deletes. Deletion is a separate authorised step, and inside a project it is a dispatched worker's task, never firstmate's own write.
  It never judges landedness by ancestry, because the fleet's history contains squash merges and callers can still request them; it states what it did not cover, because a sweep that implies completeness it does not have is the defect class it exists to clean.
user-invocable: true
metadata:
  internal: true
---

# Großreinschiff

*Reinschiff* is the seaman's word for cleaning the ship.
*Großreinschiff* is the intensive one - not the daily wipe-down, the scheduled sweep where the crew opens the lockers nobody has opened in a while.
One word, and the spelling matters: the directory and the script are ASCII (`grossreinschiff`), the prose keeps the ß, per the German-spelling rule in `docs/board-layout.md`.

This sweep looks for one thing in nine places: **a record, instruction, branch, tool, or workspace that was true when it was written and is not true now, and that nothing re-measures.**
Every item on the checklist was earned by a measured incident in the night of 2026-08-02/03.
None is hypothetical, and `docs/grossreinschiff.md` carries the incident behind each one, so a later reader can re-measure rather than trust this file.

**Cadence: weekly, on Thursday.**
`bin/fm-grossreinschiff-due.sh` owns it and nothing else - its header states the rule, the state file, and why there is no separate scheduler.
The sweep runs at the first session start on or after Thursday; a vessel that was dark on Thursday sweeps late rather than skipping the week.
The due line reports how far into the current window the sweep is, a count bounded to 0 through 6; its `last swept:` date is the field that shows how many weeks were missed.

## The five safety properties

These bind every item below. They are properties, not preferences: each one is a mistake somebody already made.

1. **It reports before it deletes.**
   A sweep produces a list, a verdict per entry, and the test behind each verdict.
   Deletion is a separate step that needs the captain's word, because deleting records or branches is destructive and irreversible in the sense `AGENTS.md` section 7 means: standing `yolo` authority does not cover it.
   Inside a project - and a project's remote branches are inside a project - firstmate never performs the deletion itself; it dispatches a worker, per `AGENTS.md` section 1 rule 1.

2. **It never tests landedness by ancestry.**
   The fleet's history contains squash merges, and callers can still request one, so ancestry reports "unmerged" for content that is fully landed.
   On `coditan-bridge`, 152 of 154 branches read as unmerged and 146 of them were tombstones of landed work; on this repo, ancestry settles 18 of 52 merged-PR branches and calls the other 34 unmerged.
   Use the ladder below. That single mistake would have deleted real work.

3. **It never touches unlanded work, and a refusal is a stop-and-investigate result.**
   `AGENTS.md` section 1 rule 3 is not relaxed for a cleanup sweep - a sweep is exactly when it is most tempting to relax it.
   An `undetermined` verdict is never promoted to a deletion candidate to make a number look tidier.

4. **Each finding names its evidence** - file and line, or command and output.
   The next sweep must be able to re-measure the claim, not inherit a belief from this one.
   A finding whose evidence is "a previous sweep said so" is not a finding.

5. **It states what it did NOT cover.**
   A sweep that implies completeness it does not have is itself the defect class it is cleaning.
   The report's closing section is mandatory, and "nothing was skipped" is only ever written when that has been checked.

## The landedness ladder

Item 1 turns entirely on this, and getting it wrong is the one mistake in this skill that destroys work.
Apply the tests in the table's order - **A**, **P**, **E**, **C**, **X** - and stop at the first that settles the branch.
The order is measured, not a matter of taste: the trap notes below say what moving a rung costs.
The technique is not this skill's invention: the worktree-scoped form is owned by `bin/fm-teardown.sh`, whose header is the authority on what "landed" means for a task's own work, and the per-branch form below was worked out and validated in `data/bridge-branch-sprawl-classify/report.md` §1.
That report is captain-private to the vessel that ran it, so a reader on another home cannot open it - `docs/grossreinschiff.md` carries the measurements and the reproduction, and is tracked.

| Code | Test | Settles |
|:-:|---|---|
| **A** | `git merge-base --is-ancestor <branch> <default>` | landed. Only ever a *positive* result - a negative one means nothing here. |
| **P** | Patch-id equality: `git diff $(git merge-base <default> <branch>) <branch> \| git patch-id --stable` against `git diff <merge_sha>^ <merge_sha> \| git patch-id --stable`, where `<merge_sha>` is the forge's recorded merge commit for that branch's PR *and* is itself an ancestor of the default branch. | landed. This is the test that handles the squash flow, and it does most of the work. |
| **E** | The branch tip's tree equals its merge-base tree. Only meaningful *after* **A** and **P**: for a branch that is already an ancestor of the default branch the merge base **is** the branch, so this holds trivially and would relabel every ordinarily landed branch. | landed vacuously - the branch has commits but changes nothing against its fork point, so there is nothing to land. |
| **C** | `git merge-tree --write-tree <default> <branch>` exits 0 **and** its first line equals `git rev-parse <default>^{tree}`. | landed - the branch adds nothing the default branch does not already have. |
| **X** | **Precondition: the branch adds at least one path.** A branch that adds none - a modify-only or delete-only branch, the ordinary shape of a small fix - falls through to `undetermined`, never to `not landed`. With that precondition met: every path the branch adds is absent from the default branch's tree **and** `git log <default> -- <path>` is empty, so it never existed there at any point. | not landed. |
| - | none of the above | **undetermined**. Never a deletion candidate. |

Four traps.
The first two were hit in practice; the last two were caught by applying this skill's own checklist to this skill before it shipped, and `docs/grossreinschiff.md` records that.

- **C is inconclusive far more often than it looks.**
  `git merge-tree` exits non-zero on a conflict, and an old branch whose files the default branch has since edited conflicts routinely.
  A caller that reads only the tree hash and drops the exit status reads a conflict as "adds content" - which reads as "not landed" - and that is a delete-real-work bug.
  Measured on this repo, 2026-08-03: over 52 merged-PR branches the ladder settled 18 by **A**, 33 by **P**, 1 by **C**, and 0 undetermined. In the same session, **C** applied alone with its exit status dropped reported "adds content" for all six ancestry-unmerged branches it was tried on - and for the three of those six that are branches of merged pull requests, the full ladder settles every one as landed.
- **P needs the merge commit verified as an ancestor of the default branch**, not merely recorded by the forge.
  A recorded merge commit that is not on the default branch proves nothing about the default branch.
- **A vacuous universal is a false certainty.**
  **X** is quantified over the paths the branch adds, so a branch that adds none satisfies both of its conjuncts on zero evidence and would be handed the definitive verdict `not landed`.
  That state is reachable exactly where this ladder is routine: **A** fails on any squash-merged branch, **P** fails when no forge merge commit is recorded or it is not an ancestor of the default branch, and **C** goes inconclusive on the conflict above.
  Safety property 3 bars promoting an unsettled branch to a definitive verdict, so the precondition in the **X** row is the rule and has no exception.
- **E's place in the order is load-bearing in both directions.**
  It must come after **A**, because a branch that is already an ancestor has itself as its merge base and would be relabelled `landed (vacuous)` on a triviality.
  It must come before **C**, because a content-free branch cannot make `merge-tree` conflict, so **C** would absorb it as plain `landed` and **E** would never fire at all.

Patch-id is safe for rename-only branches - it hashes the `diff --git a/… b/…` header paths, so a pure rename still produces a distinct hash rather than an empty one.
Before trusting a P result across a large set, check for patch-id collisions across the whole set, as §1 of the sprawl report does; a hash shared by two different pieces of work invalidates every P verdict in the batch.

## The checklist

Nine items, in the captain's own numbering so a later reader can map them back.
Each names the surface it lives on, the test, and the incident that put it there.
Where the incident is dated, it is a past measurement and is written as one - re-measure before repeating it, or the sweep commits item 2 itself.

### 1. Merged branches

**Surface:** each project's repository, plus any local mirror the pipeline pushes to.
**Look for:** branches whose work has landed and which nothing prunes.
**Test:** the ladder above, per branch. Report `landed` / `landed (vacuous)` / `not landed` / `undetermined` with the code that settled it.
**Also report the producers**, not only the tombstones: a sweep that deletes 146 branches and leaves the three producers running has bought one week.
**Who acts:** a scout per project for the inventory (read-only); deletion is a separate authorised task.
**Evidence:** `coditan-bridge` carried 154 branch entries, 146 of them tombstones of landed work, and three separate producers would each have had to prune - the forge's `delete_branch_on_merge`, the merge helper's flags, and the pipeline's own mirror. Measured 2026-08-03; `docs/grossreinschiff.md` item 1 carries it, from the captain-private report's §5. Of the three, the merge helper now prunes: `bin/fm-pr-merge.sh` passes `--delete-branch`. The forge setting and the pipeline mirror still do not. Producer status is owned by `docs/merged-branch-cleanup.md`.

### 2. Records whose stated facts no longer hold

**Surface:** the fleet's own records - backlog items, hold reasons, learnings, briefs, reports.
**Start with the captain decisions:** `bin/fm-decision-ledger.sh --premises` lists every open one with the premise it was filed on and when that premise was last re-measured, oldest first. That list never claims a premise still holds, only when it was last looked at, so it is a work list rather than an answer.
**Look for:** a record that *asserts* something about the world, where the assertion can be re-run.
**Test:** re-run the assertion. Not "does this record look current" but "is the thing it claims still true, checked now."
Prioritise records that gate something: a hold reason blocks a decision, so a hold resting on a disproven fact blocks it for nothing.
**Verdict:** `holds` / `no longer holds` / `not checkable` - and `not checkable` is itself a finding, because an assertion nothing can re-run will never be corrected.
Record each captain-decision reading with `bin/fm-decision-hold.sh recheck --outcome holds|broken|unmeasurable`, so the next sweep can tell a re-measured record from an untouched one.
**`unmeasurable` is never a quiet `broken`.** A seat re-measured a record saying a validation gate pushed to the wrong public repository, found the registry empty, and would have folded it - but that seat had moved, and the wrong registration may still stand on the machine where it was found, which the seat cannot see. Folding it there would have closed a live finding with nobody left who could see it. A premise you cannot reach is reported unmeasurable and left open; only a premise you actually measured false is a `no longer holds`, and even then folding it is a separate act.
**Who acts:** firstmate maintains its own private records directly; a claim inside shared tracked material goes through the pipeline.
**Evidence:** a hold reason still asserted that firstmate cannot clear its own context after that had been disproven end to end, and a backlog item claimed an account and a repository exist that do not. Both 2026-08-02/03.

### 3. No-op instructions

**Surface:** the shared instruction surface - `AGENTS.md`, `roles/`, `.agents/skills/`, and any project `AGENTS.md`.
**Look for:** an instruction that names a precondition, where the precondition holds on no measured home. It fails silently *because* it is cleanly written; nothing errors, the instruction simply never fires.
**Test:** for each instruction with a precondition, check the precondition on this home and say which homes were checked. One home answers a question about one home - never report it as a fleet answer.
**Verdict:** `fires` / `never fires here` / `unmeasured elsewhere`.
**Who acts:** report from firstmate; any edit to shared tracked material is a dispatched task through the pipeline, and while crew is live firstmate delegates rather than competing with supervision (`AGENTS.md` section 1).
**Evidence:** a prior `## Graphify` block in `AGENTS.md` instructed every session to query a knowledge graph, gated on `graphify-out/graph.json`, which existed on no measured firstmate home - verify with `ls graphify-out/graph.json`.
Separately, fleet doctrine was classified as session-binding that no shipped instruction delivers.
Both 2026-08-02/03.

### 4. Duplicate records for one defect

**Surface:** the backlog and the decision records.
**Start with** `bin/fm-decision-ledger.sh --audit`, whose `duplicate-suspect` and `open-but-settled` classes name what structure can prove: several open records under one investigation, one decision key open under several, and an open record whose question is already answered by a settled one.
If that audit answers `baseline absent`, this home is still re-reporting losses that predate the mechanism and can never be repaired - read them once, and if they are genuinely lost, record that with `bin/fm-decision-ledger.sh --record-baseline` so later sweeps read the records that can still be fixed rather than the same wall every week.
**That list is a floor, not a count.** It is blind to one question re-asked in different words, and that is measured: a seat held two open records asking whether a named company counts as a customer and which parties count as intra-group - one question, no shared wording, no shared key, no shared origin. Reading only the audit and reporting the duplicate count as complete is the error this section exists against.
**Look for:** several open records describing one defect, filed by different sightings.
**Test:** group open records by **the defect they describe**, never by id, title, or filing date. Two records naming the same file and the same wrong behaviour are one record.
**Fold what you confirm** with `bin/fm-decision-hold.sh supersede <id> --by <successor> --reason <line>`, which closes the folded record as superseded, moves its gated work to the successor, and never claims the captain answered it.
**Care:** consolidating does not lower the open count and is not meant to - a consolidated record stays open and captain-owned until its canonical record is actually answered (`data/learnings.md`, 2026-08-01). Consolidation buys readability, never closure.
**Never consolidate an analyst question that has no judge counterpart.** That is exactly how a question only one analyst raised disappears. `bin/fm-decision-inventory.sh` owns the panel-duplicate collapse rule and states this limit itself.
**Who acts:** firstmate, on its own backlog.
**Evidence:** the false steer-failure was filed three times in six days by three separate sightings - one of them by firstmate an hour after reading a text that warned against exactly that.

### 5. Consolidation pointers into nothing

**Surface:** the decision records.
**Look for:** a record marked "consolidated into X" where X is not open anywhere.
**Test:** resolve every such pointer against the structured inventory - `bin/fm-bearings-snapshot.sh --json --all-decisions`, never report prose or chat - and check the named canonical record is actually present and open.
**Verdict:** `pointer resolves` / `pointer dangles`. A dangling pointer is worse than no pointer: the original question reads as handled and is not.
**Who acts:** firstmate. Re-open the question against a real record; do not repair the pointer by inventing a target.
**Evidence:** two decisions are marked consolidated into judge records that are not open anywhere, 2026-08-02/03.

### 6. Counts that include something that never existed

**Surface:** any record that states a number of vessels, ships, homes, or recipients.
**Look for:** a count whose members were assumed rather than confirmed.
**Test:** enumerate the members and confirm each one **ran** or **received** - not that it was addressed, not that it was configured, and never that it stayed silent. Silence is not participation.
**Verdict:** report the corrected count and every record that carries the old one, because the wrong number propagates.
**Escalate immediately** when the count gates a captain decision: a decision waiting on five answers when only four recipients could ever answer waits forever.
**Who acts:** firstmate; a gated captain decision goes to the captain the same turn it is found.
**Evidence:** six records counted a vessel that never ran once, and one of them gates a captain decision on the answers of five ships when only four could ever receive. Related: mail was sent to one address for twenty days and the silence was counted as participation (`data/learnings.md`, 2026-08-03).

### 7. Tool currency outside the managed suite

**Surface:** this host.
**Look for:** a tool the fleet depends on that no currency check covers.
**Test:** list the tools actually used, subtract those the managed AXI-suite check covers (`bin/fm-axi-suite.sh`, `docs/configuration.md` "AXI-suite self-update"), and for each remainder compare the installed version against its registry version. Report the gap in releases, not just "outdated".
**Second, sharper test:** find every published claim that rests on one of those tools, and check whether age alone has made it false.
**Care:** a bare shell resolves the *shared* copy, not this vessel's managed prefix, so a version read without `export PATH="$FM_HOME/.local/axi/bin:$PATH"` may not be the version firstmate's own scripts use (`data/learnings.md`, 2026-07-29).
**Who acts:** firstmate measures; an upgrade that changes fleet behaviour is a dispatched task.
**Evidence:** `graphify` sat 22 releases behind on two homes and 20 on a third, because the currency check only looks inside the managed prefix - and a capability claim published to the Commodore was false purely through age. Measured 2026-08-02/03; re-measure before repeating either number.

### 8. Borrowed material without attribution

**Surface:** anything adopted from outside the fleet.
**Look for:** material in the fleet's own surfaces whose provenance is not recorded.
**Test:** for each adopted artefact, name the source, the licence, and the condition. **Never infer provenance from the delivery path** - arriving through our own pin, in our own commit, proves authorship of the file and not of the idea (`data/learnings.md`, 2026-08-03, where the same error appeared three times in one day). If the source cannot be named, the honest verdict is `provenance not recorded`, never `ours`.
**Care:** a source with no licence file, no versions, and no history - a gist, say - is adopted as an undated text snapshot, and that belongs written down beside it.
**Who acts:** firstmate reports; carrying a notice into shared tracked material is a dispatched task.
**Evidence:** the sea chart amended [Wayfinder](https://github.com/mattpocock/skills) for weeks with the MIT licence condition unmet, and the captain had to correct the claim.
`docs/sea-chart-provenance.md` carries the resolution.
The broader 2026-08-17 provenance sweep found no other tracked firstmate artefact with evidence of direct derivation from that repository, and confirmed the installed `mattpocock-skills` plugin at commit `2ab958093e83e0ec752e6c1c5932da465bf23e0c` carries its own MIT `LICENSE`.

### 9. Leftover workspaces and state

**Surface:** this home's `state/`, and the worktree pool.
**Look for:** artefacts outliving the task that created them.
**Test:** reconcile each artefact against live task metadata (`state/<id>.meta`) and the pool (`treehouse status`):
- worktrees held by tasks that are closed;
- `state/<id>.check.sh` and `state/<id>.check-trust` with no `state/<id>.meta`.
Per-task watcher and away-supervisor markers are pruned by their owning loops; `bin/fm-state-marker-prune-lib.sh`'s header owns that pruning boundary.
**Never reclaim a worktree the sweep cannot prove is clean.** `bin/fm-teardown.sh` owns the complete test and its refusal is the correct answer, not an obstacle - property 3.
**Who acts:** firstmate, on its own state; worktree return goes through `bin/fm-teardown.sh`.
**Evidence:** `state/graph-freshness.check.sh` and `state/graph-freshness.check-trust` exist on this home with no `state/graph-freshness.meta` - a check registration outliving its task, still armed for the watcher. Observed 2026-08-03.

## The report

Write it to `data/grossreinschiff-<YYYY-MM-DD>.md`.
It is a private evidence report, so it keeps exact identifiers, paths, commands, and output; the captain-facing summary that points at it still follows the plain-English rule in `AGENTS.md` section 9.

Required structure:

1. **Conclusion first** - what was found, per item, in numbers.
2. **One section per checklist item that produced a finding**, each entry carrying its verdict, the test code or command that settled it, and the evidence line.
3. **The proposed deletion set**, ordered most-safe-first, with the recovery path for each entry stated - for a GitHub branch that is `refs/pull/<n>/head`, which the forge retains permanently, including for closed-unmerged PRs. **Verify the recovery path rather than assuming it**: the sprawl report checked all 80 refs and got 80 matches, 0 mismatches.
4. **What this sweep did not cover** - mandatory, see below.

Then tell the captain, in plain language: what was found, what it means, and what needs their word before anything is removed.
Use plain chat. Build a board with `bin/fm-board.sh` and open it with `bin/fm-lavish.sh` only when the deletion set genuinely needs option-by-option approval.

## What this sweep did not cover

Write this section every time, and write it from what actually happened, not from this list.
It exists because a sweep that implies completeness it does not have is item 3 with a nicer name.

Always state at least:

- **Which homes were measured.** Checking this home answers a question about this home. Item 3 and item 7 both span the fleet, and a single-home reading is not a fleet reading.
- **Which projects were inventoried** for item 1, and which were not.
- **Every `undetermined` verdict**, in full. These are the entries most likely to be quietly dropped, and they are the ones a deletion must never touch.
- **Every item that produced no finding because it was not run**, distinguished from an item that was run and found nothing. Those two are not the same result and must never be reported as the same.
- **Anything still open from a previous sweep**, carried forward by name.

## Recording a completed sweep

When the report exists and the "did not cover" section is written, run:

    bin/fm-grossreinschiff-due.sh --record

Record only a sweep that produced a report. An abandoned sweep must stay due - the next session-start check is the only thing that will bring it back.

Unresolved decisions this sweep exposes follow `decision-hold-lifecycle`, exactly as an investigation's do; filing them is part of finishing, not follow-up.

## Scope

One sweep, over this home and the projects it can read, reported with the test behind every verdict.
It removes nothing.
If an item cannot be measured this week, that belongs in the report as an uncovered item - not as a clean result.
