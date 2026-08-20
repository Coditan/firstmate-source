# Fork-to-upstream merge assessment

This document records a measured attempt to merge canonical upstream into this curated fork, and the reasons the attempt stopped short of landing.
It is evidence, not narrative: every number below names the command that produced it and the commits it was measured against.
[`docs/fork-patches.md`](fork-patches.md) remains the authoritative patch registry, and this document does not replace it or re-stamp its pin.

## What was measured, and when

Measured 2026-08-18T15:39Z, in a disposable worktree of this repository.

- Fork side: `Coditan/firstmate-source`, resolved from `origin`, default branch `main` at `c1c10a8b1a01e0703c8183197e2a4429f6683f30`.
- Upstream side: `https://github.com/kunchenguid/firstmate.git`, from `config/fork-sync-upstream`, `main` at `d843712808658f26a7a3f248e632cb999864ca50`.
- Merge base: `bc1a21b2ccfcd500ae29181f82b28b6cf1075bfb` (`fix(bin): repair fm-brief.sh parse error and harden set -u array expansion (#205)`).

Divergence at those commits, from `git rev-list --count --no-merges`:

| Direction | Count |
| --- | --- |
| Upstream-only, not merged into the fork | 200 |
| Fork-only patches | 523 |

The 2026-08-17 reading recorded in `state/fork-sync.pending` was upstream `e518906`, 191 upstream-only, 377 fork-only.
Both sides moved: upstream advanced 9 commits, and the fork landed 160 commits in the 48 hours to 2026-08-18, so the fork side grew by 146.
Use the 2026-08-18 numbers above; the earlier ones are superseded.

## Why this is a merge and not a rebase

Nothing found in this measurement changes that.
This repository's history advances without rewriting because `firstmate.lock` in admiralty names a commit here, so a rewrite makes every pin a vessel currently carries point at a commit no longer on the default branch.
The merge attempt below was performed with `git merge --no-commit --no-ff` and then aborted; no history was rewritten and nothing was landed.

## Conflict surface

`git merge --no-commit --no-ff` of upstream `d843712` into fork `c1c10a8` produces:

- 148 unmerged paths, carrying 821 conflict hunks in total.
- 113 content conflicts, 26 add/add, 5 modified-here-deleted-upstream, 4 deleted-here-modified-upstream.
- 358 paths changed overall by the merge attempt.

By area: 54 in `tests/`, 44 in `bin/`, 26 in `docs/`, 11 in `.agents/`, 5 in `.pi/`, and one each in `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.gitignore`, `.github/`, `.claude/`, `.opencode/`, `.no-mistakes.yaml`.

The concentration matters more than the total.
The heaviest conflicts sit in the fleet's safety-critical supervision machinery: `bin/fm-test-run.sh` (42 hunks), `bin/fm-spawn.sh` (28), `bin/fm-watch.sh` (20), `bin/backends/herdr.sh` (20), `bin/fm-wake-lib.sh` (19), `bin/fm-teardown.sh` (15), `bin/fm-session-start.sh` (13), `AGENTS.md` (13), `docs/configuration.md` (19), `docs/architecture.md` (14).
Only 37 of the 148 conflicted files carry a single hunk.

### Structural conflicts, named

Both sides independently added these 26 paths, so they have no common ancestor to merge against and each one needs two implementations of the same feature reconciled by hand:

`.agents/skills/ahoy/SKILL.md`, `.pi/extensions/fm-calm.ts`, `.pi/extensions/lib/fm-calm-visibility.ts`, `.pi/extensions/lib/fm-operational-input.ts`, `bin/fm-operational-input.sh`, `bin/fm-pending-reply-lib.sh`, `bin/fm-subagent-pretool-check.sh`, `bin/fm-test-isolation-proof.sh`, `bin/fm-test-run.sh`, `docs/calm-mode-feasibility.md`, `docs/fm-test-isolation-proof.json`, `docs/fm-test-isolation-proof.md`, `docs/fm-test-portable-shards.md`, `docs/gitlab-merge-watch.md`, `docs/subagent-guard.md`, `docs/watcher-continuity.md`, and ten `tests/*.test.sh` counterparts.

Upstream deleted these five paths that the fork still modifies:

`bin/fm-dispatch-select.sh`, `tests/fm-captain-translation-contract.test.sh`, `tests/fm-dispatch-select.test.sh`, `tests/fm-instruction-owners.test.sh`, `tests/fm-stow-contract.test.sh`.

The fork deleted these four paths that upstream still modifies:

`.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`, `bin/fm-watch-arm.sh`, `tests/fm-pi-watch-extension.test.sh`.

## Silent interactions

These are the changes that merge without announcing themselves and still change fleet behavior.
Where an area was swept and nothing was found, that is stated as a finding of its own rather than left as silence.

### Found: the retired wake-delivery architecture returns

The fork retired arm-based wake delivery in `344178f supervision: host wake delivery outside the harness`, and `AGENTS.md` section 8 now states that a session holds no delivery object of any kind, so there is nothing to arm.
Upstream never took that turn and has continued building on the arm model.

- `bin/fm-watch-arm.sh` is deleted on the fork and modified upstream, so the merge leaves upstream's copy in the tree.
- `bin/fm-claude-stop-autoarm.sh` and `bin/fm-arm-command-policy.mjs` are new upstream files that arrive with no conflict at all.
- `.claude/settings.json` is a marked conflict, but git's automatic merge has already inserted a `Stop` hook invoking `bin/fm-claude-stop-autoarm.sh` outside any conflict region.
  Resolving only the marked hunks therefore leaves per-turn re-arming wired into a fleet whose contract says there is nothing to arm.
- All six `docs/supervision-protocols/*.md` files the fork ships are conflicted, and every one of them gains `fm-watch-arm` references from upstream.
  The fork carries zero such references today.
  These files are what `bin/fm-supervision-instructions.sh` renders into the session-start block, so an unexamined resolution changes the standing instructions every session reads.
- `docs/supervision-protocols/cursor.md` is a new upstream file that merges clean and carries two arm references.
  It is dormant unless the harness selector also gains upstream's `cursor` case, so it is a latent rather than an immediate effect.

`bin/fm-watch-checkpoint.sh` was checked for the same resurrection and does not occur: upstream did not touch it after the merge base, so the fork's deletion is honored and the merged tree does not contain it.

### Found: the dispatch selector upstream removed as vestigial

Upstream deleted `bin/fm-dispatch-select.sh` in `3f71cdd fix(bin): remove vestigial dispatch selector (#1026)` and carries no reference to it anywhere.
This fork has 18 files that reference it, including `AGENTS.md` section 4, which names it the owner of selector mechanics, plus `bin/fm-spawn.sh`, `bin/fm-bootstrap.sh`, `bin/fm-model-panel.sh`, `bin/fm-test-run.sh`, `docs/architecture.md`, `docs/configuration.md`, `docs/scripts.md`, and the `bootstrap-diagnostics` and `harness-adapters` skills.
The file itself surfaces as a marked conflict, so keeping it is a visible decision.
The silent part is its callers: every upstream rewrite of `bin/fm-spawn.sh` and `bin/fm-bootstrap.sh` was authored against a tree where the selector does not exist, and those rewrites merge into a tree where the fork still calls it.

### Found: teardown gains a public-followup obligation

Upstream added `bin/fm-public-followup.sh`, `bin/fm-public-followup-lib.sh`, and `bin/fm-public-followup-emit.sh`, and wired the promised-final reconciliation into `bin/fm-teardown.sh`, which is a 15-hunk conflict.
The fork's `AGENTS.md` section 14 describes only the `--final` completion follow-up.
This is contract drift rather than a break, but it changes what teardown owes before it may complete, and the fork's own instruction text does not describe it.

### Swept and found nothing

- **Renames.** `git diff -M --diff-filter=R` over the merge base to upstream reports no renames at all, so no fork call site is broken by a path move.
- **Operational-input wire format.** Both sides independently implemented `bin/fm-operational-input.sh` as an add/add conflict, and the wire contract is identical: same `U+2063` mark, same `FIRSTMATE_OP: ` prefix, same `v1` version, same header construction.
  The only divergence is additive on the fork side: the `telegram-correspondent` kind and the `launch-pointer` subcommand.
  A union resolution is safe here.
- **Status verb vocabulary.** `bin/fm-classify-lib.sh` carries the identical `FM_CLASSIFY_CAPTAIN_RE_DEFAULT` on both sides and the same `working`/`paused`/`blocked` semantics, so status classification does not silently change meaning.
- **X mode state surface.** Both sides ship `bin/fm-x-lib.sh`, `bin/fm-x-poll.sh`, `bin/fm-x-reply.sh`, and `bin/fm-x-dismiss.sh`, and both use the same `FMX_PAIRING_TOKEN` consent token and the same `x-mode`, `x-mode.env`, and `x-mode-error` state names.
  Upstream renames the concept to Relay in prose only; the activation and state surface does not move.
- **Skill inventory.** No skill is lost by the merge.
  The merged tree carries all 30 skills: 11 that only this fork has (`codebase-sweep`, `decisionboard`, `domain-modeling`, `grossreinschiff`, `panel`, `project-discipline`, `run-decisionboard`, `run-fleet-update`, `sea-chart`, `secrets-handling`, `to-backlog`) and 2 that only upstream has (`process-event-sources`, `quota-array-dispatch`).

## The check's `absorbed` prefilter is worse than a filename shortcut

`docs/fork-patches.md` already rejects the prefilter as a verdict because it is filename-level.
Measured against this merge, the defect is sharper than that: for 16 of the 17 patches it labels absorbed, it fires on a path that exists on **neither** side.

`git cherry d843712 c1c10a8` reports zero patch-equivalent commits, so the prefilter's first branch never fires and every label comes from its second branch, `git diff --quiet upstream fork -- <files touched by the commit>`.
That comparison is quiet when a path is absent from both tips, so a fork patch whose file the fork itself later deleted is labelled absorbed even though upstream never carried the file at any point in the range.

| Patch | Files it touched | Verdict | Evidence |
| --- | --- | --- | --- |
| `3f02bfb` | `.agents/skills/ask-user-authority/SKILL.md` | **absorbed** | Upstream `d843712` carries that exact path at blob `38761e6`, byte-identical to the fork's, and the commit touches nothing else. |
| `4656306`, `5c416a3`, `d06a359`, `95e438d`, `679375e`, `068c99c`, `e42f9b3`, `56bc6d4`, `f9fd7f7`, `562b476`, `0761786`, `b97f844` | `bin/fm-curation-nudge.sh`, `docs/curation-nudge.md`, `tests/fm-curation-nudge.test.sh` | **not absorbed** | Upstream has never carried any of those three paths. The fork deleted them itself in `cf862a4 feat(nudge): register the codebase-design sweep on the existing nudge cadence`. |
| `434d9f6`, `2b0ed47`, `2e89d1f` | `PANEL-VALIDATION-FINDINGS.md` | **not absorbed** | Upstream has never carried that file. It was created and retired entirely inside the fork. |
| `ae05f61` | `bin/fm-wake-wait.sh`, `tests/fm-wake-wait.test.sh` | **not absorbed** | Upstream has never carried either path. The fork deleted them in `344178f supervision: host wake delivery outside the harness`. |

Those 16 need a verdict the registry's vocabulary does not have.
They are not `absorbed`, because upstream carries nothing of their effect.
They are not `keep` or `upstream-candidate` either, because the thing each one edits no longer exists in this fork's tree; they contribute nothing to the current code and travel only as history.
Whether to add a fourth verdict for a fork patch superseded inside the fork, or to exclude such commits from the registry entirely, is a decision for the registry's owner and is deliberately left open here.

## Suite result

The merge was not landed, so there is no merged tree to run the suite against, and the categorised merged-tree result cannot be produced until a resolution exists.
What was produced instead is the pre-merge baseline that any later merged-tree result has to be read against, so that "was this caused by the merge" is answerable without re-deriving it.

`bin/fm-test-run.sh --all`, run 2026-08-18 15:44Z to 16:21Z on fork `c1c10a8` in this worktree, reports `total=146 failed=16 skipped_gate=9 duration_ms=2198424`.
Every one of the 16 is pre-existing on the unmerged fork and none can be attributed to upstream.
They categorise as follows.

- **Unrunnable on this host, 9 scripts, all of family `real-herdr-gated`.**
  `tests/fm-afk-inject-herdr-e2e.test.sh`, `tests/fm-backend-autodetect-smoke.test.sh`, `tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-backend-herdr-presentation-e2e.test.sh`, `tests/fm-backend-herdr-prune-safety-e2e.test.sh`, `tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, `tests/fm-backend-herdr-smoke.test.sh`, `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`, and `tests/fm-afk-launch.test.sh` all fail on some spelling of `could not prepare isolated Herdr lab session`.
  No isolated Herdr lab can be provisioned here, so these measure the host and not the code.
- **Watcher and wake timing, 4 scripts.**
  `tests/fm-wake-daemon-lifecycle-e2e.test.sh`, `tests/fm-wake-queue.test.sh`, `tests/fm-watch-triage.test.sh`, and `tests/fm-watcher-lock.test.sh` fail on `watcher did not surface the first event`, `watcher did not report the routine signal`, `watcher did not print first signal`, and a guard warning raised with a fresh watcher and no queued wakes.
  One of them absorbs a live Bridge inbox signal (`check: bridge-inbox: bridge-inbox coditan pending=1 highest=normal`), which points at ambient fleet state leaking into the fixture rather than at a code defect, but that is a hypothesis and not a verdict.
  These are the scripts most likely to move under a merge that touches `bin/fm-watch.sh` and `bin/fm-wake-lib.sh`, so they need re-reading against this baseline rather than being dismissed.
- **Pre-existing contract failures, 3 scripts.**
  `tests/fm-arm-pretool-check.test.sh` fails `A13 via codex must allow, got exit 2` with `[watcher-bundled] a protected watcher command must be the sole final command after approved setup nodes`.
  `tests/fm-pr-merge.test.sh` fails `records-before-merge: fm-pr-merge should succeed: expected exit 0, got 1`.
  **Superseded 2026-08-20, for `tests/fm-pr-merge.test.sh` only:** that failure was the fixture, not the code. `bin/fm-pr-merge.sh` prepends `$FM_HOME/.local/axi/bin` to its own PATH, and a session exporting a real `FM_HOME` put the operator's own `gh-axi` ahead of the test's fakebin, so the real forge CLI ran against an invented repository. The fixture now pins `FM_HOME` to a per-case directory and the script passes. The measurement above is left as it was taken.
  `tests/fm-journal.test.sh` fails without a Herdr or watcher explanation.
  These three are real and unrelated to upstream; they are already failing on what the fleet runs today.

Nine further scripts reported a declared gate skip and did not run.

## Why this did not land, and the split it needs

Landing this honestly means resolving 821 conflict hunks across 148 files, of which the heaviest sit in spawn, watch, wake, teardown, and session-start, and reconciling 26 independently-written duplicate implementations that have no common ancestor.
It also means re-evaluating 523 fork patches against the merged tree at content level, against a registry that currently holds 94 rows.
Both the conflict resolution and the patch re-evaluation are individually larger than one worker session, and the task's own instruction is that a partial merge presented as done is the worst available outcome.

The proposed split that fits the material is below in dependency order, but whether to approve it remains an open decision for the captain.

1. **Retire or reconcile the arm architecture first, as its own change, before any merge.**
   Decide whether this fork keeps hosted delivery, and record that decision where the merge can be resolved against it.
   Without this, every supervision-protocol and `.claude/settings.json` resolution is an unanchored guess, and it is the one area where a wrong resolution silently changes what every session is told to do.
2. **Merge upstream in one branch, resolving only `bin/` and the shared instruction surface.**
   That is roughly 44 `bin/` conflicts plus `AGENTS.md`, `docs/`, `.agents/`, and the harness config files.
   Resolve `tests/` mechanically to whichever side each `bin/` decision implies, and let the suite prove the pairing.
3. **Reconcile the 26 add/add duplicates as a distinct pass**, since each is a design decision between two working implementations rather than a merge choice.
4. **Re-evaluate `docs/fork-patches.md` against the merged tree**, in patch-class batches rather than commit by commit, and re-stamp its pin only at the end of that pass.
5. **Rebuild the registry's coverage separately.** The registry holds 94 rows against 523 fork-only commits, so about 429 commits have never been recorded at all, and that gap predates this merge.

## What was deliberately not done

- `docs/fork-patches.md`'s pinned fork commit was **not** re-stamped.
  Re-stamping it would assert a review against the merged tree that did not happen.
- No registry row's verdict was changed, because no row can be judged against a merged tree that does not exist.
- The merge was aborted, not committed. Nothing was landed.
