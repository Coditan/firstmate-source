---
name: updatefirstmate
description: >-
  Fast-forward this running firstmate home and every secondmate home to whatever their own origin already carries, then re-read instructions and nudge each updated secondmate.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  It answers one hop - whether this home is level with its own origin - and on a pin-delivered home that hop stops at the pin, so never call a vessel current on the strength of it; /run-fleet-update owns the three-hop reading and this skill never re-derives it.
  It names when a pin bump is the real next step and whose reviewed work that is, and it never bumps a pin as a side effect of updating a home.
  Fast-forward only: never forced, never stashed, nothing under projects/ touched.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `roles/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, `roles/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## The hop this answers, and the ones it does not

A fast-forward advances this home to whatever **its own origin already carries**, and that is the whole of what it establishes.
It is the `installed` hop and nothing else.

On a home delivered from the fleet repository, that origin carries firstmate **vendored at a pin**, so a completely successful update leaves this home exactly as current as the pin is - and a pin can be arbitrarily old.
A run of this skill that reports every target updated or already current is therefore not evidence that this vessel is running current shared code, and reading it that way is a recorded incident rather than a hypothetical: a vessel answered only this question, was told it was current, and was many commits and many merged pull requests behind the shared code at that moment ([`docs/pin-age-check.md`](../../../docs/pin-age-check.md)).

**Never report a vessel current on the strength of this skill.**
When the currency question is being asked, take the reading rather than inferring one: [`../run-fleet-update/SKILL.md`](../run-fleet-update/SKILL.md) owns all three hops - level with own origin, what pin this home carries, and how far that pin lags its own recorded source - and reports each separately.
Do not restate its numbers, its hop table, or its verdict here; run it.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then fast-forwards every registered secondmate home (each a treehouse worktree of this same repo, leased at a detached HEAD on the default branch) the same way.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, `roles/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Say what "the latest" was in that sentence - on a pin-delivered home it is the shared code the pin names, which is not the same as the newest shared code, and a summary that lets the two be read as one is the incident above.
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## The pin, and the repositories that move together

These are not independent repositories that each happen to hold firstmate.
A change moves through them in one direction, and the fast-forward above is only the last step of it.

1. **The work lands in firstmate's own repository first.**
   That repository is the pin source, it tracks no `firstmate.lock`, and nothing pins it: shared material is authored, reviewed, and merged there through this repo's own pipeline and pull-request path.
2. **The fleet repository vendors it at a pin.**
   `firstmate.lock` names a source URL, a source-ref hint, and one immutable 40-character commit; `firstmate.vendor-manifest` records `<mode> <blob sha> <path>` for every vendored path, so the match can be verified offline on every pull request ([`docs/admiralty-fleet-repo.md`](../../../docs/admiralty-fleet-repo.md)).
   The commit is the authority; the ref hint carries none.
3. **A pin-delivered home fast-forwards onto the vendored tree of that pin.**
   That is step 1 of this skill, and it is the end of the line.

So a change is only as delivered as the pin is current, and **this fast-forward cannot move the pin.**
When a home is level with its origin and shared code is still missing from it, the step that has not happened is the pin bump, not this update.

**Never edit a vendored path in the receiving repository.**
Ownership there is decided by name, deny-by-default - a file at an unregistered path is classified vendored - and the drift gate fails any commit that changes a vendored path.
A separate pin-ownership check runs on every pull request precisely so that a vendored edit cannot be laundered green by registering the edited file as fleet-owned; it recomputes ownership from the pin's own tree listing rather than from the manifest.
The only legitimate way a vendored path changes is a bump.

**A bump is reviewed work, not an edit.**
The fleet repository's own importer is the only thing permitted to rewrite the lock, and it is deterministic and fail-closed: it refuses a dirty tree, refuses unless the current pin already verifies clean, refuses a collision with a fleet-owned path, writes only vendored paths, holds the private operational directories structurally out of reach, and re-runs the drift gate against its own staged tree before reporting success.
It then **stages and stops** - landing the change is a pull request's job, and the importer's BUMP REPORT is that pull request's account of itself, ending in boxes a human ticks.
`fleet/doctrine/pin-and-bump.md` in the fleet repository owns that procedure in full, including the source-only re-pin and the report's contents; read it there rather than reconstructing it.

**A pin bump lands as a true merge commit - never a squash, never a rebase.**
Ancestry is a property of the commit graph, not of tree content, so a flattened bump copies the newer tree without adding the source's commits to the fleet repository's ancestor set.
`bin/fm-ff-lib.sh` advances a checkout only when its `HEAD` is an ancestor of the new base, and a refused advance prints one `skipped: diverged from <base>` line **while still returning success**.
A squashed or rebased bump therefore produces a repository whose tree looks correct and whose vessels can never fast-forward onto it again - permanently, once per vessel, with nothing in any exit status to show it.
That same property is why such a pull request is raised directly rather than through no-mistakes, whose rebase would flatten the very ancestry the merge exists to create, and why it is authorised on the captain's word instead.

**This skill never bumps a pin.**
Not as a step, not as a repair, and not as a side effect of updating a home.
When the reading shows the pin behind, report the measured distance and let the bump be its own authorised piece of work.

## A home with no pin

A home whose root carries no `firstmate.lock` is not pin-delivered.
That is a fact about the home rather than a fault, and the three-hop reading reports it as such instead of as a failure.

For that seat, "update" means something different: its origin carries firstmate's own history directly, so step 1 takes **whatever is at the head of that default branch at the moment it runs**.
There is no pin to be behind, no bump to wait for, and nothing between the merge and this home that could explain a change that has not arrived.

Say plainly what that cuts both ways.
Anything merged reaches such a seat at its very next update **with nothing in between** - no pin, no vendoring step, no second review, and no staging window in which a bad change could be caught before it is running there.
The whole of its currency question is therefore when it last updated, and a change that landed minutes ago is already on its way to it.
Nothing holds it back and nothing holds it up.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A secondmate gets a tracked-files fast-forward (safe while it is mid-task, since its work lives in gitignored operational dirs and separate project worktrees) plus a gentle re-read nudge.
  It is never torn down, interrupted, or forced.
- **No pin is written here.**
  This skill reads a home's pin only to know which question its update answered; changing one is the fleet repository's reviewed work, above.
