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

That last point is why item 1 reports producers and not only tombstones. A sweep that deletes 146 branches and leaves three producers running has bought one week.

### 2. Records whose stated facts no longer hold

Two, both 2026-08-02/03:

- A hold reason still asserted that firstmate cannot clear its own context, after that had been disproven end to end. The hold gated a decision, so the disproven fact was blocking a real question.
- A backlog item claimed an account and a repository exist that do not.

### 3. No-op instructions

The `## Graphify` block in `AGENTS.md` instructs every session to run `graphify query` for codebase questions, gated on `graphify-out/graph.json`.

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

**Whether anything else came from that repository is still open.** It is carried forward deliberately as an open item rather than closed by assumption.

The generalisation, from `data/learnings.md`, 2026-08-03, where the same error appeared three times in one day: **the channel something arrives through says nothing about where it came from.** Our own pin, our own commit, and a source line that names nobody proves authorship of the *file*, not of the *idea*. Checking one's own home answers a question about one's own home, not about the fleet.

A related note from the same day: a source with no licence file, no versions, and no history - a gist, for instance - is adopted as an undated text snapshot, and a later reader cannot tell whether it has moved. That belongs written down beside the adoption.

### 9. Leftover workspaces and state

Worktrees held by closed tasks, parked markers for tasks that are done, stale check registrations.

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

`data/learnings.md`, 2026-08-03 adds the trap for this item: re-running `bin/fm-pr-check.sh` on a task silently drops that task's `state/.parked-*` marker. A missing marker is therefore not proof the task is finished.

## The landedness ladder, and why ancestry is banned

Measured on `Freudator86/firstmate` at `origin/main` = `d126ea61`, 2026-08-03, over the 52 branches of merged pull requests that still exist on `origin`.

The ladder, applied in order A → P → C, stopping at the first test that settles a branch:

    === A(ancestry)=18  P(patch-id)=33  C(content)=1  undetermined=0

**Ancestry alone would have called 34 of 52 landed branches unmerged.** On `coditan-bridge` the same reading was worse: 152 of 154 read as unmerged, because PR #1 is the only pull request in that repository's history merged with a real merge commit - the only merge commit in 7,724 commits on `main`. Everything else was squashed, so branch tips are unreachable from `main` by construction. "152 not merged" is a restatement of "we squash", nothing more.

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
| **Scheduled wake** (a watcher `check:` poll) | Rejected. The watcher's check mechanism is per-task: a poll is registered against a task id by `bin/fm-check-register.sh`, bound to that task's bytes, and removed at teardown. A fleet-level weekly sweep has no task to hang off, so this would mean a new registration class and a new trust binding - a second scheduler - for something that needs no sub-minute latency. |
| **External timer** (cron or systemd, as `bin/fm-firstmate-update-check.sh` and `bin/fm-fork-sync-check.sh` use) | Rejected. Those two make network calls that must not sit in the session-start path, which is what earns them a timer. The due check makes none: it reads one file and compares two integers. A timer would add a per-home install step that nothing verifies, so a home that never installed it would silently never sweep - checklist item 3, built into the thing meant to find item 3. |
| **Fleet-wide notice** | Not a cadence. A notice is read once and cannot make anything recur. It is the right instrument for the announcement, and it is used for exactly that. |

The rule, owned by the script's header: **due when the last recorded sweep predates the most recent Thursday 00:00 local.**

- An absent record means never swept, which is due. A home that has never swept is the one most likely to have accumulated something, and it joins the Thursday rhythm after its first sweep.
- A home that ran no session on Thursday sweeps at its next session start rather than skipping the week, and the line says how many days into the window it is.
- A corrupt or unparseable record reads as never swept, so it makes the sweep due rather than silently skipping it.
- The week boundary is today's local midnight minus whole days, so a daylight-saving change inside the preceding week moves it by an hour twice a year. An hour of drift cannot make a weekly sweep fire twice or skip a week.

### How it reaches the vessels

Through the pin, like every other instruction-surface change: it lands on the default branch, homes fast-forward, and the loaded surface (`AGENTS.md`, `bin/`, `roles/`, `.agents/skills/`) changes. `AGENTS.md` section 12 owns that path.

One All-Ships notice announces the day and what the sweep covers. That is an announcement, not the mechanism - a vessel that never reads the notice still gets the due line from its own session start, and a vessel that reads the notice but never pins never sweeps.

## Known limits

Stated here because the skill requires every sweep to state its own, and the mechanism should hold itself to the same rule.

- **A vessel that starts no session in a given week does not sweep that week.** It sweeps late at its next session start. Nothing wakes a dark vessel for this, deliberately.
- **The due line is per-home.** It says this home has not swept; it says nothing about whether the fleet has.
- **In a session that did not get the fleet lock the line is advisory.** The sweep mutates records, so the session holding the lock owns it. The line still prints, because a read-only session should know the sweep is outstanding.
- **The check verifies that a sweep was recorded, never that it was any good.** `--record` is called by the skill after a report exists; nothing inspects the report. A thorough sweep and a shallow one leave the same marker.
