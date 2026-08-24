# Großreinschiff: the incident record and the cadence decision

`.agents/skills/grossreinschiff/SKILL.md` owns what the weekly sweep does and how each item is tested.
`bin/fm-grossreinschiff-due.sh` owns the cadence mechanics.
This file owns the two things neither of those should carry: **why each checklist item is on the list**, and **why the reminder is a session-start item rather than a scheduler**.

It is written as evidence rather than narrative, so a later reader can re-measure instead of trusting it.
Every number below is a past measurement with a date on it.
Re-measure before repeating one - a doc that states a stale number as a present fact is checklist item 2, and this file is not exempt from the sweep it documents.

Decided by the captain on 2026-08-03. First fleet-wide run: Thursday 2026-08-06.

## Why the sweep exists

Every item was earned in the night of 2026-08-02/03, when several unrelated pieces of work each turned up the same shape of defect: **something that was true when it was written, is not true now, and nothing re-measures it.**

The nine items are not nine kinds of mess. They are nine places one kind of mess accumulates, and they were found separately by people who were not looking for it.

## The nine items and the incident behind each

### 1. Merged branches

`coditan-bridge` carried 154 branch entries. 146 were tombstones of landed work.

Measured 2026-08-03 from a disposable worktree at `origin/main` = `22aac2c0`; full classification in `data/bridge-branch-sprawl-classify/report.md` (captain-private).

- 146 landed (content proven present in `main`), 2 landed vacuously (empty commits), 5 not landed across 3 distinct pieces of work each with a written decision not to merge, 1 is `main` itself. Zero undetermined.
- The 154 counts two different things: 81 branches on GitHub, 73 in a local pipeline mirror repository that has never been on the forge.
- **Three separate producers would each have had to prune, and none does** (report §5): the forge's `delete_branch_on_merge` is `false`, which alone accounts for 77 of the 81 GitHub branches; `bin/fm-pr-merge.sh` never passes `--delete-branch`; and the pipeline binary contains no branch-deletion or merge code path at all, so it cannot prune its own mirror even in principle.
  - **Superseded 2026-08-04, for the second producer only:** `bin/fm-pr-merge.sh` now passes `--delete-branch`. The measurement above is left as it was taken on 2026-08-03; current producer status is owned by `docs/merged-branch-cleanup.md`.

That last point is why item 1 reports producers and not only tombstones. A sweep that deletes 146 branches and leaves three producers running has bought one week.

### 2. Records whose stated facts no longer hold

Two, both 2026-08-02/03:

- A hold reason still asserted that firstmate cannot clear its own context, after that had been disproven end to end. The hold gated a decision, so the disproven fact was blocking a real question.
- A backlog item claimed an account and a repository exist that do not.

### 3. No-op instructions

A prior `## Graphify` block in `AGENTS.md` instructed every session to run `graphify query` for codebase questions, gated on `graphify-out/graph.json`.

    $ ls /home/coditan/coditan-firstmate/graphify-out/
    ls: cannot access '/home/coditan/coditan-firstmate/graphify-out/': No such file or directory

Measured 2026-08-03. The file exists on no measured firstmate home, so the block has never fired there.
**It fails silently because it is cleanly written**: the gate is correct, so nothing errors and nothing is logged; the instruction is simply never reached.

Separately: fleet doctrine was classified as session-binding that no shipped instruction delivers.

### 4. Duplicate records for one defect

The false steer-failure was filed three times in six days by three separate sightings.
One of those filings was made by firstmate about an hour after it had read a text warning against exactly that.

That detail is the reason the item exists at all: knowing about a defect does not prevent filing it again, so the check has to be mechanical - group by the defect described, not by id or title.

`data/learnings.md`, 2026-08-01, records the constraint that makes the repair safe: consolidating eighteen duplicates left the open count at 45, because a consolidated record stays open and captain-owned until its canonical record is answered. The count fell to 7 only when the captain answered the underlying decisions. Consolidation buys readability, never closure - and an analyst question with no judge counterpart must never be consolidated, because that is exactly how it disappears.

### 5. Consolidation pointers into nothing

Two decisions are marked consolidated into judge records that are not open anywhere (2026-08-02/03).

A pointer to a record that does not exist is worse than no pointer: the original question reads as handled, so nobody asks it again.

### 6. Counts that include something that never existed

Six records counted a vessel that never ran once.
One of them gates a captain decision on the answers of five ships when only four could ever receive - so that decision waits forever.

The general error is recorded in `data/learnings.md`, 2026-08-03, one of three variants of the same mistake found in a single day: mail was sent to one address for twenty days and the silence was counted as participation. At the approval-chain negotiation it would have entered doctrine as "no objection".

**A recipient that never answers is not a participant.** That is why item 6's test is "confirm each member ran or received", not "confirm each member was addressed".

### 7. Tool currency outside the managed suite

`graphify` sat 22 releases behind on two homes and 20 on a third, measured 2026-08-02/03.
The cause is scope: `bin/fm-axi-suite.sh` checks currency inside the managed per-vessel npm prefix, and `graphify` is not in it.

A capability claim published to the Commodore was false purely through age - nothing about it was wrong when written.

Related, and a trap for the measurement itself: `data/learnings.md`, 2026-07-29 records that since AXI installs moved to a per-vessel prefix, a bare shell resolves the *shared* copy rather than the managed one. A version read without `export PATH="$FM_HOME/.local/axi/bin:$PATH"` may not be the version firstmate's own scripts use. Measured that day: `quota-axi` 0.1.16 in the vessel prefix, 0.1.14 on `PATH`, 0.1.16 in the registry.

### 8. Borrowed material without attribution

`/sea-chart` amended [Wayfinder](https://github.com/mattpocock/skills/tree/main/skills/engineering/wayfinder) by Matt Pocock for weeks with the MIT licence condition unmet. The captain had to correct the claim. `docs/sea-chart-provenance.md` carries the copyright notice, the licence text, and the comparison.

The broader 2026-08-17 provenance sweep found no other tracked firstmate artefact with evidence of direct derivation from that repository.
It also confirmed that the installed `mattpocock-skills` plugin at commit `2ab958093e83e0ec752e6c1c5932da465bf23e0c` carries its own MIT `LICENSE`, so the installed plugin's condition is met.

The generalisation, from `data/learnings.md`, 2026-08-03, where the same error appeared three times in one day: **the channel something arrives through says nothing about where it came from.** Our own pin, our own commit, and a source line that names nobody proves authorship of the *file*, not of the *idea*. Checking one's own home answers a question about one's own home, not about the fleet.

A related note from the same day: a source with no licence file, no versions, and no history - a gist, for instance - is adopted as an undated text snapshot, and a later reader cannot tell whether it has moved.
That belongs written down beside the adoption.

### 9. Leftover workspaces and state

Worktrees held by closed tasks, stale check registrations, and script-owned state markers whose producers do not clean up after task teardown.

Live instance on this home, 2026-08-03:

    $ ls state/graph-freshness* state/*.meta
    state/graph-freshness.check.sh
    state/graph-freshness.check-trust
    state/bridge-branch-sprawl-classify.meta
    state/fleet-grossreinschiff.meta
    state/fleet-prune-producer-fix.meta
    state/fm-adopt-domain-modeling.meta
    state/fm-adopt-to-tickets.meta
    state/fm-context-ceiling-300k.meta

A check registration and its trust binding for `graph-freshness`, with no `state/graph-freshness.meta` - the task is gone and the check is still armed for the watcher.

Superseded 2026-08-24 for per-task watcher and away-supervisor markers: their owning long-lived loops now prune orphaned markers through `bin/fm-state-marker-prune-lib.sh` after the task metadata, status, and recorded window are gone, while preserving global buffers and append-only history.
The stale check registration case remains on the weekly sweep because custom checks are separate watcher inputs, not per-task suppression markers.

## The landedness ladder, and why ancestry is banned

Measured on `Freudator86/firstmate` at `origin/main` = `d126ea61`, 2026-08-03, over the 52 branches of merged pull requests that still exist on `origin`.
(Historical record: at measurement time that address was this repository's home. Since the 2026-08 move this repository lives at `Coditan/firstmate-source`, and the old address hosts a **different, unrelated repository** — do not resolve it when re-running this measurement; use `origin`.)

**The applied order is A → P → E → C → X**, stopping at the first test that settles a branch.

The published measurement below ran A → P → C, before E and X were placed in the order.
Inserting E between P and C does not change it: none of the 34 non-ancestor branches was content-free, so E fires on none of them and these counts stand as measured.

    === A(ancestry)=18  P(patch-id)=33  C(content)=1  undetermined=0

E must never be placed before A.
For a branch that is already an ancestor of the default branch, `merge-base(default, branch)` **is** the branch, so E's tree-equality condition holds trivially for every ordinarily landed branch: placed first, it would have relabelled all 18 ancestry-settled branches above as `landed (vacuous)`.
Placed after A it sees only the 34 non-ancestor branches, and fires on none of them.
It must still come before C, because a content-free branch cannot make `merge-tree` conflict, so C would settle it as plain `landed` and E would never fire at all.

**Ancestry alone would have called 34 of 52 landed branches unmerged.** On `coditan-bridge` the same reading was worse: 152 of 154 read as unmerged, because PR #1 is the only pull request in that repository's history merged with a real merge commit - the only merge commit in 7,724 commits on `main`. Everything else measured there was squashed, so those branch tips are unreachable from `main` by construction. "152 not merged" was a restatement of the fleet's historical squash behavior, nothing more.

### The content test is inconclusive far more often than it looks

`bin/fm-teardown.sh` uses `git merge-tree --write-tree` for its worktree-scoped landedness check and correctly treats a non-zero exit as inconclusive, refusing rather than guessing.

A per-branch caller that keeps the tree hash and drops the exit status gets a different, dangerous answer. Measured on this repo the same day:

    $ git merge-tree --write-tree origin/main origin/fm/codex-graphify-approval; echo "exit=$?"
    c6ae09800b945966a8767ce65bbb47eb6bfc4eb6
    100644 337bd0a683f7a2d5e1e13f4ce142416220549b78 1	.codex/hooks.json
    100644 ff6d2f4b75c3ed3699982bf2df145163323e9a12 2	.codex/hooks.json
    100644 e51d59dd87716dfb3a0d1068b1fd980900f055ef 3	.codex/hooks.json
    [...]
    exit=1

The branch landed as PR #1. `merge-tree` conflicts because `main` has edited those files repeatedly in the two weeks since. A caller comparing only the printed tree against `origin/main^{tree}` reads the conflict tree as "adds content", which reads as "not landed", which puts landed work in a deletion set.

That is why the ladder puts **P** before **C**, and why **C** counts only when `merge-tree` exits 0.

The per-branch form of **P** - and the checks that make it trustworthy, patch-id's behaviour on rename-only branches and the collision check across the whole set - was worked out in `data/bridge-branch-sprawl-classify/report.md` §1. This is stated because item 8 applies to this sweep too: the technique is not this skill's invention.

### The recovery path is what makes deletion reversible

Every one of the 80 GitHub branches in the bridge inventory had a `refs/pull/<n>/head` on `origin` pointing at exactly its current tip, verified for all 80 with zero mismatches. GitHub retains those refs permanently, including for closed-unmerged pull requests.

The sweep states the recovery path per entry and **verifies** it rather than assuming it. A local pipeline mirror has no equivalent, which is one more reason the two populations are never counted as one.

## The cadence decision

**Chosen: a session-start item.** `bin/fm-bootstrap.sh` runs `bin/fm-grossreinschiff-due.sh` in the detect pass that already happens once per session start, and prints one `GROSSREINSCHIFF:` line when the sweep is due. `bootstrap-diagnostics` owns the response to that line.

Three options were considered.

| Option | Verdict |
|---|---|
| **Scheduled wake** (a watcher `check:` poll) | Rejected. The watcher can carry a home-scoped check, as the daily currency round now demonstrates, but this weekly due check makes no network calls and already runs cheaply at every session start. Giving it a background cadence would add machinery without catching a due sweep sooner on a home where nobody is present to perform it. |
| **External timer** (cron or systemd) | Rejected. Networked currency checks run through the existing watcher as [`currency-round.md`](currency-round.md) owns, while this due check makes no network calls: it reads one file and compares two integers. A separate timer would add a per-home install step that nothing verifies, so a home that never installed it would silently never sweep - checklist item 3, built into the thing meant to find item 3. |
| **Fleet-wide notice** | Not a cadence. A notice is read once and cannot make anything recur. It is the right instrument for the announcement, and it is used for exactly that. |

The rule, owned by the script's header: **due when the last recorded sweep predates the most recent Thursday 00:00 local.**

- An absent record means never swept, which is due. A home that has never swept is the one most likely to have accumulated something, and it joins the Thursday rhythm after its first sweep.
- A home that ran no session on Thursday sweeps at its next session start rather than skipping the week, and the line says how many days into the *current* window it is.
  That count is `days_back`, bounded to 0 through 6, so it is a window position and never a measure of lateness: a home three weeks dark that wakes on a Thursday reads 0.
  The line's `last swept:` date is the field that carries the staleness, and it is what the reader judges by.
- A corrupt or unparseable record reads as never swept, so it makes the sweep due rather than silently skipping it.
- The week boundary is today's local midnight minus whole days, so a daylight-saving change inside the preceding week moves it by an hour twice a year. An hour of drift cannot make a weekly sweep fire twice or skip a week.

### How it reaches the vessels

Through the pin, like every other instruction-surface change: it lands on the default branch, homes fast-forward, and the loaded surface (`AGENTS.md`, `bin/`, `roles/`, `.agents/skills/`) changes. `AGENTS.md` section 12 owns that path.

One All-Ships notice announces the day and what the sweep covers. That is an announcement, not the mechanism - a vessel that never reads the notice still gets the due line from its own session start, and a vessel that reads the notice but never pins never sweeps.

## The sweep's own checklist, applied to the sweep

Before this skill shipped, its own nine-item checklist was run against its own prose.
It got three hits, all the same defect class the sweep exists to clean, and all three were fixed before delivery.

- **The due line's window-open count is bounded to 0 through 6 by construction**, so it can never report a home dark for weeks: a home three weeks behind that wakes on a Thursday reads 0, while one merely four days late reads 4.
  The handling guidance told the reader to escalate on a large number, which is an instrument that never fires - checklist item 3.
  The `last swept:` date already carried the signal, and the guidance now points there.
- **Ladder rung X returned a definitive `not landed` for a branch that adds no paths**, because a universal over an empty set is vacuously true.
  A verdict on zero evidence is a false certainty, and it is exactly what safety property 2 warns about when it bans judging by ancestry - and property 3, which bars promoting an unsettled branch to a definitive verdict.
  X now carries the precondition in its own row.
- **Ladder rung E could never be reached** in the A → P → C → X → E order it was first written in, because C absorbs every content-free branch first.
  An unreachable rung is dead text - item 3 again.
  E now sits between P and C, and the order caveat is recorded above because moving it either way is measurably wrong.

This is recorded plainly because it is evidence the checklist works, not an embarrassment to soften.
The night of 2026-08-02/03 produced the checklist from other people's surfaces; the first thing it was pointed at was its own, and it found three.

## Known limits

Stated here because the skill requires every sweep to state its own, and the mechanism should hold itself to the same rule.

- **A vessel that starts no session in a given week does not sweep that week.** It sweeps late at its next session start. Nothing wakes a dark vessel for this, deliberately.
- **The due line is per-home.** It says this home has not swept; it says nothing about whether the fleet has.
- **In a session that did not get the fleet lock the line is advisory.** The sweep mutates records, so the session holding the lock owns it. The line still prints, because a read-only session should know the sweep is outstanding.
- **The check verifies that a sweep was recorded, never that it was any good.** `--record` is called by the skill after a report exists; nothing inspects the report. A thorough sweep and a shallow one leave the same marker.
