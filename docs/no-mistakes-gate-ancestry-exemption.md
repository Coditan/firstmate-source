# The ancestry-restoring merge exemption

`.github/workflows/no-mistakes-required.yml` requires every pull request to carry the deterministic signature `no-mistakes` writes into a pull request body.
This document owns the one exemption to that rule, the reason it exists, the reason it lives here rather than downstream, and the residual it accepts.
The workflow is the implementation; this file is the contract.

## The collision

An ancestry-restoring merge is a pull request whose deliverable is the commit graph itself.
A downstream repository that vendors firstmate under a pin needs the pin source's commits to become genuine ancestors of its own `main`, because `bin/fm-ff-lib.sh` advances a checkout only when its `HEAD` is an ancestor of the new base, and skips silently rather than failing when it is not.
Copying the source's tree does not do that.
Only a true merge does.

`no-mistakes` rebases.
A rebase replays a merge commit as a linear one, which leaves the tree matching byte for byte while `git merge-base --is-ancestor` turns false.
`data/learnings.md` records a real instance of exactly this during a fork sync: the shipped content was correct and complete, and the original upstream commit objects were no longer reachable as ancestors.

So the pipeline cannot raise this one pull request without destroying what it delivers, and it destroys it invisibly.
Before this exemption the only resolutions were to merge past a red required check or to fake the signature, and the second is a lie in a provenance check.

## Where the rule lives, and why

It lives in firstmate, the pin source, and reaches a fleet repository as vendored content through a pin bump.

`fleet/doctrine/partition.md` in a fleet repository classifies both CI workflows as vendored, and `fleet/doctrine/pin-and-bump.md` states the consequence directly: a vendored path may only change through `fleet/bin/fmf-vendor-bump.sh`, so to change one you change it in the pin source and bump.
Patching the workflow inside the fleet repository is what the drift gate exists to refuse.

Reclassifying that one workflow as fleet-owned is not an available alternative.
`.fleet-overlay` is kept disjoint from the pin's tree by `fleet/bin/fmf-pin-check.sh` on every pull request, so registering a path the pin already carries is itself the failure the check reports.
The remaining route is exclusion plus a replacement `fleet-*.yml`, but exclusion deletes the file rather than keeping a local edit to it, and it would fork the gate's definition permanently for one repository.
The partition already states the principle for this case: the honest move is a fleet-owned file the pin does not carry, not an override of a vendored one, because overriding a vendored path is not possible in this architecture by design.

The need is also not specific to one repository.
Any repository that vendors firstmate under a pin hits the identical collision the first time it has to stay fast-forwardable.
A rule about how firstmate's own tree is absorbed belongs where that tree is authored.

## The rule

The exemption is decided entirely from the commit graph.
It never reads the pull request title, the branch name, or any text in the body, because anything the author controls turns the gate into an honour system.

A pull request that carries no pipeline signature passes only when all three hold.

1. Some commit in `base..head` is a real merge, with two or more parents.
2. That merge has a parent which is **not** already an ancestor of the base branch, and **is** an ancestor of the pin source's declared branch.
   The source is read from `firstmate.lock` **as it exists on the base branch**, so a pull request cannot nominate its own trusted source.
3. Every commit in `base..head` that is not itself published in the pin source may only touch files the base branch already carries **and** the pin source does not track.
   For a merge, the content judged here is the content that differs from every one of its parents, which is exactly an evil merge's payload.

Condition 3 is the narrow part, and it reduces to one sentence: **an exempt pull request can add no new file, and can hand-edit no file the pin source tracks.**
Everything genuinely new arrives through the merge, from a repository where it was already gated when it was authored.
What is left for the pull request itself is the downstream's own bookkeeping, such as a regenerated pin and manifest or a doctrine note, on files that already exist and that the pin source has never carried.

## What it does not grant

The exemption grants ancestry and source-carried content.
It does not grant a way to introduce new code, and it does not relax any other check.
In a fleet repository the drift gate, the pin ownership and disjointness check, the repo invariants, and lint all still run and still have to pass.

The exemption is unavailable in a repository whose base branch has no `firstmate.lock`.
That is every ordinary firstmate checkout, so for ordinary firstmate contributors this workflow behaves exactly as it did before the exemption existed, and the failure names the absent pin rather than pretending to evaluate a graph.

## Residual, stated rather than hidden

Two things are accepted deliberately.

The exemption inherits the pin source's own gate.
Content merged in was reviewed where it was authored, not here, which is the same trust a vendored tree already rests on.

A commit riding on an exempt merge may still modify a file that already exists in the base branch and is absent from the pin source, such as a fleet-owned doctrine document.
Bounding that further would forbid the regenerated pin and manifest that a merge bump has to carry in the same commit, so the bound stops at "no new files, nothing the source tracks".

Neither of these lets an ordinary change reach `main` without the pipeline, which is the property the gate exists for.

## Verification

`tests/no-mistakes-required-workflow.test.sh` extracts the workflow's own inline script and replays it against purpose-built commit graphs, proving acceptance of a merge bump and rejection of a pipeline-skipping pull request, a merge of a local branch, a rider commit adding a file, a rider commit hand-editing a vendored file, an evil merge carrying a vendored edit, and the same graph in a repository with no pin.

Replayed against real pull requests on 2026-07-27, unmodified, with `GH_TOKEN` empty:

```
Freudator86/admiralty#3   exit 0   merge parent 356cd5250a83e21ad91b96c8bdd57964e1e2103f is published
                                   in https://github.com/Freudator86/firstmate.git (main)
Freudator86/admiralty#1   exit 1   no merge commit here brings in ancestry from
                                   https://github.com/Freudator86/firstmate.git (main)
Freudator86/admiralty#2   exit 1   no merge commit here brings in ancestry from
                                   https://github.com/Freudator86/firstmate.git (main)
kunchenguid/firstmate#1092 exit 1  the base branch declares no vendoring pin (firstmate.lock),
                                   so no external source is trusted here
```

Pull requests 1 and 2 are ordinary changes in the same repository, under the same pin, that skip the pipeline.
They stay red.
