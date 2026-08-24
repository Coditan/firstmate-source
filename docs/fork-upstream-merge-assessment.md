# Fork-to-upstream merge assessment

This document records measured attempts to merge canonical upstream into this curated fork, and the reasons they stopped short of landing.
It is evidence, not narrative: every number below names the command that produced it and the commits it was measured against.
[`docs/fork-patches.md`](fork-patches.md) remains the authoritative patch registry, and this document does not replace it or re-stamp its pin.

The plan those attempts kept asking for now exists as its own document: [`docs/upstream-integration-plan.md`](upstream-integration-plan.md) owns what gets taken, in what order, and why each boundary sits where it does, re-derived against the tips of 2026-08-24.
It also answers the four things the closing section of this document said a successor would need.
Read it before proposing any further merge, because its governing decision is that a merge is no longer the instrument.

The 2026-08-18 attempt below is kept as taken.
A second attempt on 2026-08-23 re-measured both tips and stopped short of landing for reasons the first attempt had not measured; that reading is in [The 2026-08-23 re-measurement](#the-2026-08-23-re-measurement) and supersedes every number in the 2026-08-18 sections it contradicts.

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

## The 2026-08-23 re-measurement

Measured 2026-08-23, in a disposable worktree of this repository, as step 2 of the split above.
Step 2 did not land either, and this section records what was measured and why it stopped.
Where a number here contradicts the 2026-08-18 sections above, this one governs; the earlier reading is left as it was taken.

### Both tips had moved again

- Fork side: `Coditan/firstmate-source`, resolved from `origin`, `main` at `24af217126afd95dcd3ea15fedd6b9291b4006ba` (2026-08-23), from `git rev-parse origin/main`.
- Upstream side: `https://github.com/kunchenguid/firstmate.git`, `main` at `822a9902494b628ef92c538f40112bd79757271e` (2026-08-23), from `git rev-parse upstream/main`.
- Merge base: `bc1a21b2ccfcd500ae29181f82b28b6cf1075bfb`, unchanged since 2026-08-18, from `git merge-base upstream/main origin/main`.

There is no `config/fork-sync-upstream` in this home, so the upstream URL was taken from the canonical address rather than from configuration; `git remote -v` confirms the fork side came from `origin` and not from a written-down name.

Divergence, from `git rev-list --count --no-merges`:

| Direction | 2026-08-18 | 2026-08-23 |
| --- | --- | --- |
| Upstream-only, not merged into the fork | 200 | 238 |
| Fork-only patches | 523 | 671 |

The step-2 instructions were written against upstream `1cb900c` and fork `23a658b`, with 214 and 614.
Both are ancestors of the tips measured here, from `git merge-base --is-ancestor`, so they were simply older readings rather than a different repository.
Fork `24af217` is `Merge pull request #177 ...fork-sync-upstream-and-remotes-after-move`, two merges ahead of `23a658b`.
`origin/main` was re-fetched after this reading was taken and still resolved to `24af217`, so nothing landed on the fork underneath the measurement.

### Conflict surface

Measured without touching the working tree, with `git merge-tree --write-tree --name-only origin/main upstream/main`, whose conflicted-file list and per-file blobs carry the markers the equivalent `git merge` would write.

| Reading | 2026-08-18 | 2026-08-23 | Command |
| --- | --- | --- | --- |
| Unmerged paths | 148 | 154 | conflicted-file section of `git merge-tree` |
| Conflict hunks | 821 | 922 | `grep -c '^<<<<<<< '` over each conflicted blob |
| Content conflicts | 113 | 116 | `grep -c 'CONFLICT (content)'` |
| add/add | 26 | 27 | `grep -c 'CONFLICT (add/add)'` |
| modify/delete | 9 | 11 | `grep -c 'CONFLICT (modify/delete)'` |
| Paths changed overall | 358 | 377 | `git diff --name-only origin/main <merge-tree oid>` |

By area, from the conflicted-file list: 57 `tests/`, 46 `bin/`, 26 `docs/`, 12 `.agents/`, 5 `.pi/`, and one each in `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.gitignore`, `.github/`, `.claude/`, `.opencode/`, `.no-mistakes.yaml`.

The total that decides feasibility is not the hunk count but the volume inside the markers.
Counting the lines between `<<<<<<<` and `>>>>>>>` in every conflicted blob gives **35,837 lines in 922 conflict regions**: 263 regions of four lines or fewer, 307 of five to fifteen, 208 of sixteen to fifty, and 144 longer than fifty lines.
The heaviest files are `bin/fm-test-run.sh` (56 hunks), `tests/fm-calm-pi-extension.test.sh` (45), `bin/fm-watch.sh` (36), `tests/fm-backend-herdr-presentation-e2e.test.sh` (32), `bin/fm-spawn.sh` (28), and `bin/fm-pending-reply-lib.sh` (22).

For each conflicted path, `git rev-list --count --no-merges <base>..<side> -- <path>` was run for both sides.
**99 of the 154 conflicted paths carry three or more post-base commits on each side**, so most of this surface is a two-way reconciliation between two independently evolved implementations rather than a one-sided take.
`git diff --shortstat` over the same range gives 128,471 insertions on the upstream side and 119,898 on the fork side, and 21,370 upstream insertions fall in the 46 conflicted `bin/` files alone.

### Corrections to the earlier record

- **`bin/fm-arm-command-policy.mjs` is not an incoming upstream file.**
  The fork already carries it, and `bin/fm-arm-pretool-check.sh` with it, from `git ls-tree origin/main bin/`.
  Both are the fork's own pretool command guard and are unrelated to wake arming, so neither is something a resolution has to keep out.
  `bin/fm-claude-stop-autoarm.sh` genuinely is an incoming file and genuinely arrives with no conflict.
- **`bin/fm-spawn.sh` and `bin/fm-bootstrap.sh` do not call `bin/fm-dispatch-select.sh`.**
  On fork `24af217` each mentions it once, in a comment, from `git show origin/main:bin/fm-spawn.sh | grep -n fm-dispatch-select`.
  Its only production caller is `bin/fm-model-panel.sh`, at lines 373 and 393, and that file does not conflict, so keeping the fork's selector remains correct - but for the panel, not for spawn or bootstrap.
  Any check written as "spawn and bootstrap still call the selector" cannot pass, because it is not true of the fork before the merge either.
- **The modify/delete split is 7 and 4, not 5 and 4.**
  Upstream deleted and the fork still modifies `bin/fm-dispatch-select.sh`, `docs/decision-hold-lifecycle.md`, `tests/fm-captain-translation-contract.test.sh`, `tests/fm-decision-hold-lifecycle.test.sh`, `tests/fm-dispatch-select.test.sh`, `tests/fm-instruction-owners.test.sh`, and `tests/fm-stow-contract.test.sh`.
  The fork deleted and upstream still modifies `.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`, `bin/fm-watch-arm.sh`, and `tests/fm-pi-watch-extension.test.sh`.

### Confirmed on the current tips

- `.claude/settings.json` gains the `bin/fm-claude-stop-autoarm.sh` `Stop` hook at line 59 of the merged blob, while its only conflict region spans lines 24 to 36.
  The insertion is outside the markers, so resolving the marked hunks alone leaves per-turn re-arming wired into a fleet whose contract says there is nothing to arm.
- All six `docs/supervision-protocols/*.md` files carry zero arm references on the fork and gain them from the merge: `claude.md` 6, `opencode.md` 3, `pi.md` 3, `grok.md` 2, `codex.md` 1, `unknown.md` 1, plus 2 in the new `cursor.md`.
- Across the whole tree, files carrying `watch-arm`, `autoarm`, `auto-arm`, or `arm-command-policy` go from **24 on the fork to 67 in the merged tree**, from `git grep -l -I -E`.

### Found: teardown's public-followup wiring is mostly outside the conflict

`bin/fm-teardown.sh` conflicts in 17 hunks, but of the 64 `public-followup` references in the merged blob only 2 sit inside a conflict region.
The remaining 62, including the guard that refuses cleanup with `Deliver it with bin/fm-public-followup.sh deliver <obligation-id>`, are auto-merged in.
The fork's `bin/fm-teardown.sh` carries none of them today.
So this is not a hunk to decide; it is a mechanism that lands unless it is removed on purpose, and it changes what cleanup refuses on.

### Found: 168 upstream paths land with no conflict marker at all

`git diff --name-only <base> upstream/main --diff-filter=A` lists 201 paths upstream added since the base.
Removing the ones the fork also has, with `comm -23` against `git ls-tree -r --name-only origin/main`, leaves **168 paths that arrive with nothing to resolve**: 65 in `bin/`, 73 in `tests/`, 18 in `docs/`, 4 in `.agents/`, 3 in `.pi/`, and `VISION.md`, `GROK_BOT.md`, `.greptile/rules.md`, `.cursor/hooks.json`, and `.github/workflows/windows-herdr-spike.yml`.
They are whole subsystems, not stragglers: thirteen `fm-remote-*` scripts, five `fm-procevent-*`, four voice-interface scripts, two `fm-control*`, two `fm-busy-*`, and the three `fm-public-followup*` scripts.

Two of those arrivals are load-bearing against the fork's own gates.

- `family_for_script` in `bin/fm-test-run.sh` calls `die "no test family for ...: add it to family_for_basename in bin/fm-test-run.sh (there is no catch-all family)"`.
  So each of the 73 incoming test scripts either gets a hand-decided family or the suite refuses to select.
- `--check-coverage` proves that `docs/scripts.md` names every `bin/*.sh` once and nothing that is gone, so each of the 65 incoming scripts either gets a hand-written index entry or the gate fails.

That is **138 hand decisions that sit entirely outside the 922 conflict hunks**, each needing the incoming script read to make it.
The 2026-08-18 assessment did not measure this surface, and the step-2 instructions named two silent arrivals where there are 168.

### Found: the conflicts are architectural, not textual

The arm question is not confined to the files that mention arming.
Upstream's factoring of shared code is built to serve the arm model, so files with no arm reference still conflict on it.

- `bin/fm-lock.sh` conflicts in 2 hunks.
  The fork sources `bin/fm-harness-pid-lib.sh` because the session lock and the primary transcript record must refuse on exactly the same condition.
  Upstream sources `bin/fm-session-lock-lib.sh`, and its own comment gives the reason: "so the Claude Stop auto-arm applies the exact same identity contract".
  The same hunk also carries upstream's write-probe and claim-lock hardening, which is real robustness the fork lacks and which cannot be taken without taking the arm-serving lib split with it.
- `bin/fm-guard.sh` conflicts in 4 hunks.
  The fork's supervision verdict is daemon-based.
  Upstream's is model-aware, with an explicit branch for the Claude Stop auto-arm model and another for the Pi extension model, and its episode key is derived from the failing condition rather than the beacon mtime.

Upstream has not slowed on that architecture: 17 of its 238 post-base commits touch `bin/fm-watch-arm.sh`, `bin/fm-claude-stop-autoarm.sh`, `bin/fm-arm-command-policy.mjs`, `.opencode/plugins/fm-primary-watch-arm.js`, or `.pi/extensions/fm-primary-pi-watch.ts`, the newest of them `4d2cb0ca` on 2026-08-21.
The fork retired arm-based delivery in `344178f` on 2026-08-13.

This is why "decide the arm question first" does not shrink the merge.
Deciding it settles which side wins where the two architectures disagree, but upstream's genuine fixes are interleaved with arm-serving refactors inside the same hunks, so each one still has to be separated by hand.

### Found: merging upstream in increments does not help

`git merge-tree --write-tree --name-only origin/main <waypoint>` was run against the 10th, 25th, 50th, and 100th commit of `git rev-list --reverse --first-parent <base>..upstream/main`.

| Upstream commits merged | Conflicted files |
| --- | --- |
| 10 | 51 |
| 25 | 81 |
| 50 | 114 |
| 100 | 132 |
| 238 (tip) | 154 |

The first ten upstream commits alone produce 51 conflicted files, 149 hunks, and 4,864 lines inside markers - about a seventh of the full surface for a twenty-fourth of the commits.
The divergence is structural rather than cumulative, so there is no small first increment to land, and splitting the merge into increments multiplies the number of times the same machinery has to be reconciled.

### Why an ancestry-only merge must not be landed

`bin/fm-fork-sync-check.sh` measures upstream-only work with `git rev-list --oneline --no-merges "$fork..$upstream"` at line 217.
That is ancestry, not content.
Any merge of upstream's tip - including one resolved wholly in the fork's favour - takes that count to zero and keeps it there.
A merge that records the ancestry while declining the content would therefore switch off this fork's own upstream-drift detector permanently and silently, and the 238 declined commits would never be listed for review again.
So "merge for ancestry, keep our content" is available, cheap, and specifically the wrong answer here.

### Pre-merge baseline on the current fork tip

`bin/fm-test-run.sh --all`, run 2026-08-23 on fork `24af217` in this worktree, before any merge and with no conflict markers in the tree.

`FM_TEST_SUMMARY total=152 failed=4 skipped_gate=17 duration_ms=2531261`, a 42-minute run finishing 2026-08-23T20:19Z.
The 2026-08-18 baseline on fork `c1c10a8` was `total=146 failed=16 skipped_gate=9`, so the fork's own suite has improved by twelve failures in five days and this reading replaces it.

Nine of that improvement is the `real-herdr-gated` family.
Those nine scripts failed on 2026-08-18 with some spelling of `could not prepare isolated Herdr lab session`; they now declare a `herdr` gate skip and are counted as skips, which is why `skipped_gate` rose from 9 to 17.
`tests/fm-journal.test.sh`, `tests/fm-wake-daemon-lifecycle-e2e.test.sh`, and `tests/fm-pr-merge.test.sh` now pass.

The four remaining failures, from the run's timing artifact:

| Script | Family | Assertion |
| --- | --- | --- |
| `tests/fm-arm-pretool-check.test.sh` | `pure-contract-unit` | `A13 via codex must allow, got exit 2`, denied by `[watcher-bundled] a protected watcher command must be the sole final command after approved setup nodes` |
| `tests/fm-wake-queue.test.sh` | `watcher-wake-lock` | `drain warned with identity-matched daemon and delivery locks`, with `last beat: 0s ago, grace 300s` |
| `tests/fm-watch-triage.test.sh` | `watcher-wake-lock` | `watcher exited for a working: signal whose crew is provably working (should absorb)`, on `check: bridge-inbox: bridge-inbox hlr pending=1 highest=high` |
| `tests/fm-watcher-lock.test.sh` | `watcher-wake-lock` | `guard warned with a fresh watcher and no queued wakes` |

Three of the four are the watcher and wake timing scripts the split flagged as most likely to move under a merge that touches `bin/fm-watch.sh` and `bin/fm-wake-lib.sh`, so a later merged-tree run has to be read against these three specifically rather than against a total.
`tests/fm-watch-triage.test.sh` again absorbs a live Bridge inbox signal from this home, naming vessel `hlr` where the 2026-08-18 run named `coditan`.
That is now two independent runs on two vessels showing ambient fleet state reaching the fixture, which raises the 2026-08-18 hypothesis to a repeated observation - though it is still an observation about the fixture and not a verdict on `bin/fm-watch.sh`.

There is no merged-tree run to compare against, because no merge was landed, so no failure here is attributed to upstream and none is claimed to be unaffected by it.

### Why step 2 did not land

Resolving this honestly means separating 35,837 lines inside 922 conflict regions, 99 of whose files were substantially rewritten on both sides, in spawn, watch, wake, teardown, guard, lock, and session start; deciding 168 unmarked arrivals; and closing the 138 index and family entries the fork's own gates require before the suite can even run.
None of that is one worker session, and a partial merge presented as done is the worst available outcome.
Nothing was landed: no merge commit was created, and `docs/fork-patches.md` was not touched - no verdict changed and its pin not re-stamped.

A successor needs to know four things this measurement adds to the split above.

1. Step 1 is answered - the fork keeps hosted delivery - and answering it did not make step 2 smaller, for the reason in "the conflicts are architectural, not textual".
2. Step 2 as scoped is still too large for one session, and the honest unit is smaller than "`bin/` plus the instruction surface".
   The one grouping the measurement supports is by architecture: resolve the supervision spine (`fm-watch.sh`, `fm-wake-lib.sh`, `fm-guard.sh`, `fm-lock.sh`, `fm-turnend-guard.sh`, `fm-supervision-*`, the six protocol documents, and `.claude/settings.json`) as one decision against the hosted-delivery contract, and leave everything else for later passes.
3. The 168 unmarked arrivals and the 138 gate entries are step-2 work that no conflict marker will remind anyone about.
4. Whether this fork should keep tracking upstream at all is now a question the numbers raise on their own, and it belongs to the captain rather than to a merge session.
   671 fork-only patches against 238 upstream-only, 27 features implemented independently on both sides, and a supervision architecture upstream is still building on and this fork retired ten days ago are the shape of two products, not one product and its fork.
   [`docs/admiralty-fleet-repo.md`](admiralty-fleet-repo.md) already describes the vendored-pin arrangement meant to end this maintenance tax, so the alternative to a repeated merge is not "stay behind forever".
