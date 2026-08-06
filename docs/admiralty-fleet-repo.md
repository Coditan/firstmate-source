# admiralty: the fleet repository

`Freudator86/admiralty` is the fleet repository created on 2026-07-26.
It is private, under the same owner as this fork, and it holds firstmate vendored at the repository root under a version pin, with the fleet's own material in a namespace the pin source will never create.

This document records what was built and why, so a later session can work on it without archaeology.
The repository itself is the authority on its own mechanics: `fleet/README.md`, `fleet/doctrine/partition.md`, `fleet/doctrine/pin-and-bump.md`, and `fleet/doctrine/branch-protection.md`, plus each script's header and `--help`.

Creating the repository did not cut any vessel over to it.
No origin was re-pointed, no secondmate home was touched, and no running vessel's configuration changed.
Cutover stays sequenced behind proving a staged rollout, with this vessel as canary first and the privileged host-admin vessel last because it is the recovery lever.

## The property everything else depends on

`admiralty`'s `main` descends from this fork's `main` as it stood at `e52cc76`, the genesis base.
That property is permanent, and it is what makes the shared object store and the linked-worktree secondmate model work at all.

`bin/fm-ff-lib.sh` advances a checkout only when its `HEAD` is an ancestor of the new base.
When it is not, the advance is refused rather than failed: `ff_target` prints one `<label>: skipped: diverged from <base>` line for that target and returns success, and `bin/fm-update.sh` surfaces one such line per target, which is easy to miss in a longer sync report.
A fresh-history fleet repository would therefore have delivered nothing to any vessel, forever, while the sync kept reporting success overall, and secondmate homes are linked worktrees that depend on the shared object store for the same reason.

So `admiralty` was built from this history: one commit on top of the fork's `main` at `e52cc76`, transforming the tree into its vendored-plus-overlay shape.
That genesis commit is `2cbf8c7`; `492361e` on top of it corrects the branch-protection doctrine described below.
The proof is a run of firstmate's own `ff_target` rather than a hand-rolled `git merge`, in a throwaway clone of the fork made in a temporary directory for this purpose and discarded afterwards.
No vessel home was involved, so the re-pointing below simulates a cutover rather than performing one.

```
$ git rev-parse HEAD # a vessel at the fork's main
e52cc7642f495af2f0cae9cb8e28706faa2a3a6d
$ git remote set-url origin https://github.com/Freudator86/admiralty.git
$ . bin/fm-ff-lib.sh; ff_target "$PWD" vessel origin
vessel: updated e52cc76..492361e
FF_STATUS=updated
```

This fork's `main` has since advanced past `e52cc76`, so its tip is no longer an ancestor of `492361e`; it stood at `ce43899` when this document was written.
A vessel sitting at the fork's current `main` and pointed at `admiralty`'s `main` would therefore hit exactly the refused advance described above, and how that is repaired before cutover is still open; see "What is not built yet".

## The shape of the repository

| Path | Class | Holds |
| --- | --- | --- |
| `firstmate.lock` | fleet | the pin: source URL, source ref hint, and an immutable 40-character commit |
| `firstmate.vendor-manifest` | fleet | `<mode> <blob sha> <path>` for every vendored path, so drift is checked offline |
| `.fleet-overlay` | fleet | fleet-owned paths outside the fleet namespaces; empty on day one |
| `.fleet-excluded` | fleet | pin paths deliberately not materialized; empty on day one |
| `fleet/bin/` | fleet | ownership library, drift gate, pin check, importer |
| `fleet/doctrine/` | fleet | the partition, the pin and bump contract, branch protection |
| `fleet/decisions/`, `fleet/vessels/`, `fleet/roles/` | fleet | fleet-wide decisions, per-vessel material, and fleet-authored roles |
| `.github/workflows/fleet-ci.yml` | fleet | the gates |
| everything else, 308 paths at the genesis pin `e52cc76` | vendored | firstmate at the pin, byte for byte |

Ownership is decided by name, in a fixed order, by `fleet/bin/fmf-ownership.sh`.
The four control files, anything under `fleet/`, and `.github/workflows/fleet-*.yml` are fleet-owned; then the `.fleet-overlay` registry; then `.fleet-excluded`; then everything else is vendored.
The last rule is deny-by-default, so a new file at an unregistered path is classified vendored and the drift gate fails it until someone classifies it deliberately.

The initial pin is this fork's `main`, not the upstream template's.
Day one is a change of repository identity with zero behaviour delta, and the move toward upstream happens as reviewed pin bumps rather than a single cutover.

## The pin and bump contract

A bump is the only legitimate way a vendored path changes.
`fleet/bin/fmf-vendor-bump.sh` is deterministic and fail-closed: it refuses a dirty tree, refuses unless the current pin already verifies clean, refuses any collision between the new pin and a fleet-owned path, refuses a stale exclusion, writes only vendored paths, deletes only previously manifested vendored paths the new pin dropped, treats `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`, `graphify-out/`, and `.env` as structurally out of reach, and re-runs the drift gate against its own staged tree before reporting success.

It stages and stops; landing is the pull request's job.

Every run prints a BUMP REPORT, which is the bump pull request's body.
It names the source commits being absorbed, any commits the bump leaves behind if the lineage changed, which fleet-owned or excluded paths those commits touch, the added and removed vendored paths, and what the overlay still carries.

**First-run bootstrap.**
There is no previously manifested set on the very first run, so `--bootstrap` replaces the comparison with a stricter one-time assertion: the tree's vendored set must already equal the pin's tree minus the exclusions, byte for byte.
Nothing is materialized and nothing is deleted; the run only records a tree that already matches, and refuses otherwise.
That is what makes the genesis commit provably a copy rather than an approximation, and `--bootstrap` refuses once a manifest exists.
The genesis commit's manifest was produced this way rather than by hand.

## Why the pin-ownership check is not redundant with the drift gate

`Vendored drift gate` compares the tree to the manifest, offline.
`Pin ownership and disjointness` recomputes ownership from the pin's own `git ls-tree` and asserts that no pin path is fleet-owned, that every exclusion still names something the pin carries, and that the manifest still equals the pin's tree minus the exclusions.

The second check is not redundant, and it runs on every pull request rather than only at bump time.
Without it, a red drift gate can be turned green by editing a vendored file and then registering that file in `.fleet-overlay`.
That was demonstrated rather than argued: in the second evidence pull request, the drift gate reports green over 307 vendored paths while the pin check refuses with `OWNERSHIP COLLISION: README.md`.

Ownership in that check is computed from the pin, never from the manifest, because the manifest is a statement the repository makes about itself and the attack edits it.

## The partition's two deviations from the drafted plan

The drafted partition classified `README.md` and all of `.github/workflows/` as fleet-owned.
Both are vendored in the built repository, and `fleet/doctrine/partition.md` carries the reasoning and the measurements.

The load-bearing one: five vendored tests read `.github/workflows/ci.yml` and fail when it is absent (`fm-lint`, `fm-nm-test-contract`, `fm-test-isolation-proof`, `fm-install-herdr`, `fm-test-run`), so removing or rewriting the vendored workflows is a day-one behaviour delta in the vendored test suite.
The fleet's CI is therefore added alongside them at `.github/workflows/fleet-ci.yml`, which is fleet-owned by name, and the cost that classification was meant to avoid is handled as repository configuration: the vendored `CI` and `Require no-mistakes` workflows are **disabled** in `admiralty`'s Actions settings rather than deleted.
The consequence is recorded where it can bite - a pin bump must run firstmate's own suite deliberately, because nothing runs it automatically there.

`README.md` stays vendored simply because nothing yet requires it to differ.
Note that this architecture has no mechanism for overriding a vendored file: `.fleet-overlay` can only name paths the pin does not carry.
A fleet front page, when one is wanted, is a new fleet-owned file rather than an override.

## Branch protection: refused by the forge, and open

**`admiralty`'s `main` is currently unprotected.**
This is the one deliverable of the build that did not land, and it is a captain decision rather than something to work around.

GitHub refuses branch protection on a private repository on this account.
For the general audit rule that checks both APIs before calling a repository gated or ungated, see [merge-gate-audit.md](merge-gate-audit.md).
Both APIs return the same thing:

```
POST /repos/Freudator86/admiralty/rulesets
PUT  /repos/Freudator86/admiralty/branches/main/protection
-> 403 "Upgrade to GitHub Pro or make this repository public to enable this feature."
```

This fork carries its `fleet-main-signoff` ruleset only because the fork is public; `admiralty` is private by the captain's explicit approval, and the account has no paid plan.

Three ways out, none of them the agent's to choose:

- Pay for GitHub Pro on the owning account, then apply the ruleset unchanged.
- Make `admiralty` public, which reverses an explicit approval and exposes fleet material.
- Accept an unprotected `main` until cutover, relying on the fleet's own discipline and on the CI gates, which still run and still fail; they simply are not required to pass before a merge.

The intended ruleset, ready to apply the moment protection is available, is recorded in `fleet/doctrine/branch-protection.md`: pull request required, force pushes and deletion blocked, the fleet CI checks required, no bypass actors, and **zero** required approving reviews.

The zero is deliberate and is documented in the repository rather than left a silent omission.
The fleet pushes under a single identity, so an author cannot approve their own pull request and no second identity exists to clear it; requiring one approval would deadlock every merge.
What stands in for it is the captain's merge authority, mechanical required checks, and blocked force pushes.

The genesis commit was pushed directly to `main`, because a branch must exist before anything can protect it.

## Never tracked

`.claude/settings.local.json` must never be tracked in `admiralty`.
Claude Code writes to it at runtime, and `dirty_status` in `bin/fm-ff-lib.sh` skips a fast-forward for any dirty checkout, so a tracked copy of a file the harness rewrites would freeze self-update fleet-wide, one vessel at a time.
`fleet-ci.yml` asserts it is untracked on every pull request, alongside the tracked symlinks `.claude/skills` and `CLAUDE.md` and the private operational directories.

A related interaction used to bite even without tracking: `dirty_status` reads `git status --porcelain`, which reports untracked files too, so an untracked `.claude/settings.local.json` in a home blocked that home's fast-forward on its own.
The fork's tracked root `.gitignore` now ignores it along with the other checkout-local harness runtime artifacts, so it no longer does; [configuration.md](configuration.md) "Operational home layout and state" owns that contract.
Because `.gitignore` is a vendored path, `admiralty` picks the rule up with the next pin bump rather than needing fleet-owned material of its own.

## Measuring divergence against admiralty

`admiralty` carries firstmate vendored under a pin whose source is this same fork, so a bump lands this fork's content as a single import commit carrying its own patch id.
`git cherry admiralty/main HEAD` compares patch ids and cannot see across that vendor-import boundary, so it reports commits as missing even when they are byte-identical on `admiralty`.
The right test for a single commit is `git merge-base --is-ancestor <commit> <pin>` against the pin, and for a whole tree it is the mode, blob and path triples from `git ls-tree -r` on both sides, minus the fleet-owned paths.
Measured on 2026-08-01 UTC: the pin's tree holds 353 paths, all 353 are present on `admiralty` as vendored paths, and all 353 are identical in mode, blob and path, with none differing and none missing.
Of the 37 lines `git cherry` reported as missing, 27 were already there, and the fleet recomputed this independently.
None of that means the canonical upstream template absorbed those patches: the verdicts in [fork-patches.md](fork-patches.md) measure against that template, which this evidence leaves untouched, and that document owns the absorption rule.

## What is not built yet

- Cutover is not finished, and this document does not track where any individual vessel stands.
  A vessel's own `origin` is the authority on whether that vessel has been cut over; read it there.
- Restoring the ancestry as this fork's `main` advances past `e52cc76` is an open captain decision, not a solved problem.
  Ancestry is a property of the commit graph and not of tree content, so a pin bump alone does not restore it: a bump commit on `admiralty` copies the fork's newer tree, but it does not add the fork's newer commits to `admiralty`'s ancestor set.
  Absorbing that history so an already-updated vessel stays fast-forwardable needs a true merge of the fork's `main` into `admiralty`'s `main`, which is consistent with the standing rule that upstream-sync pull requests land as true merge commits rather than squashes.
  How such a merge interacts with the drift gate is no longer the open part: `admiralty`'s own `fleet/doctrine/pin-and-bump.md` owns the merge-bump procedure, including regenerating the manifest in that same commit and the verification to put in the pull request.
  What remains open is that the procedure has not been applied.
  The 2026-08-01 pin bump to `de0b95b` landed as an ordinary single-parent commit rather than a merge, so it copied the tree without absorbing the history, and even a vessel sitting exactly at the current pin cannot fast-forward onto `admiralty`.
  Measured on 2026-08-01 UTC in a throwaway clone of `Freudator86/admiralty` whose `main` was `285289c24be625f5b27d5ae846dd09024114534c`, with this fork fetched into it so both sides are present: `git merge-base --is-ancestor de0b95b7a13e72256089707aeab6aac83d00e90d 285289c24be625f5b27d5ae846dd09024114534c` exits 1, and the newest fork commit that is still an ancestor of that `admiralty` `main` is `bbf0023` of 2026-07-30.
  Name the `admiralty` commit rather than a bare `origin/main`, because in this repository `origin/main` is the fork itself, where `de0b95b` is an ancestor and the same command exits 0.
  That merge bump cannot be raised through no-mistakes, because its rebase would flatten the ancestry the merge exists to create, so it is authorized on the captain's word instead.
- The Bridge extraction, the fork-maintenance tooling retirement, and the Bucket-A upstreaming are unstarted; the fork-first ratchet prices each as its own reviewed pin bump.
