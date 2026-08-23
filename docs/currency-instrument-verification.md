# Re-measuring the two currency instruments after the fleet move

The daily round runs two comparisons that speak about other repositories: `bin/fm-fork-sync-check.sh` compares the curated fork against the template it tracks, and `bin/fm-firstmate-update-check.sh` compares this deployment against the source it updates from.
A model panel established on 2026-08-17 that on a seat deployed from the fleet repository both were publishing confident readings of things they had not measured.
[currency-round.md](currency-round.md) owns the round's design and [fork-patches.md](fork-patches.md) owns the fork-only patch registry; this file records what was re-measured on 2026-08-23, with the commands and the output, so a later reader can tell a checked instrument from an assumed one.

Every reading below was taken on the coditan seat, whose `origin` is the fleet repository `Freudator86/admiralty`, whose `fork` remote is the curated fork `Coditan/firstmate-source`, and whose `upstream` remote is the template `kunchenguid/firstmate`.
It speaks for that seat only, exactly as the round itself does.

## The defect class, stated once

Each defect below is a check whose predicate is satisfied by a wider set of world-states than the claim it publishes.

- "`origin` has commits the base does not" was published as "the fork has local patches".
- "the output was empty" was published as "absorption is current".
- "grep found nothing" was read as "nothing is there".
- "the configured base has instruction-surface commits we lack" was published as "upstream instruction update", with no way to see which repository the base was.

The remedy in every case is the same: make the published claim name the world-states the predicate actually covers, and make a reading nobody took say so.

## The fork side: fixed on 2026-08-17, re-proved on 2026-08-23

The fork side is now resolved explicitly through `bin/fm-currency-base-lib.sh` rather than from whatever `origin` happens to be.
The old hop is still reachable deliberately, as the last resort and through `FM_FIRSTMATE_FORK_URL`, so the wrong reading can be produced on purpose and compared with the right one.

```
$ FM_FIRSTMATE_FORK_URL=https://github.com/Freudator86/admiralty.git \
    FM_ROOT_OVERRIDE=<home> FM_STATE_OVERRIDE=<scratch> FM_CONFIG_OVERRIDE=<scratch> \
    bin/fm-fork-sync-check.sh | head -2
FORK_SYNC: upstream f170ced not merged into fork (234 upstream-only commits); 763 local patches to re-evaluate (17 provably absorbed): dispatch a fork-sync crewmate
  compared: fork https://github.com/Freudator86/admiralty.git (from FM_FIRSTMATE_FORK_URL) against upstream https://github.com/kunchenguid/firstmate.git (from config/fork-sync-upstream)

$ FM_ROOT_OVERRIDE=<home> FM_STATE_OVERRIDE=<scratch> FM_CONFIG_OVERRIDE=<scratch> \
    bin/fm-fork-sync-check.sh | head -2
FORK_SYNC: upstream f170ced not merged into fork (234 upstream-only commits); 659 local patches to re-evaluate (16 provably absorbed): dispatch a fork-sync crewmate
  compared: fork https://github.com/Coditan/firstmate-source.git (from the fork remote) against upstream https://github.com/kunchenguid/firstmate.git (from config/fork-sync-upstream)
```

104 commits separate the two counts, and the wrong side's list is headed by fleet-repository commits that were never fork patches - `d24bd1e fleet: prove the guard by installing it, not by reading source` is the third row of its `fork-only patches:` section.
The corrected side's first rows are fork commits (`05400b9`, `c1c1f08`, `a8aff14`).
The live finding on this seat, written by the round on 2026-08-20, already carries `compared: fork https://github.com/Coditan/firstmate-source.git (from the fork remote)`, so the instrument is reading the right two repositories in production and not only under test.

A seat that genuinely curates a fork therefore reports as it always did: with nothing configured, the `fork` remote is what the resolver finds, and `tests/fm-fork-sync-check.test.sh` pins that hop order in `test_fork_remote_outranks_origin_when_nothing_is_configured` and `test_origin_remains_the_last_resort_fork_side`.

## The suppressed reading: fixed on 2026-08-17, re-proved by causing it

The fork comparison prints nothing both when it found nothing and when its own three-day gate stopped it looking.
Running the pre-fix round and the current round over identical state - an open `FORK_SYNC` finding on disk, a completed comparison stamped two days ago, and a check that produces no output this round - separates them:

```
--- pre-fix round (a8158977^) ---
reading: fork-absorption hop=released state=ok detail=the curated fork has absorbed real upstream content, or the three-day cadence has not reopened
surfaced to the supervisor: 0
--- current round ---
reading: fork-absorption hop=released state=behind detail=FORK_SYNC: upstream aaaaaaa not merged into fork (214 upstream-only commits); 614 local patches [recorded 2026-08-21T17:00:20Z, not re-measured this round]
surfaced to the supervisor: 1
```

The pre-fix detail text names both worlds in one sentence and then grades them `ok`, which is the whole defect in one line.
With no finding on disk and no comparison ever completed, the same pair reads `state=ok` before and `state=unmeasured detail=the fork comparison has never completed a run, so nothing about fork absorption has ever been measured on this home` after.

The wording is deliberate: `unmeasured` is the round's existing first-class state for a reading nobody took, and `behind` is reserved for a finding that a completed comparison actually recorded.
A suppressed round with a clean recent record is recorded `unmeasured` and does not surface, because a declared cadence is a scheduled interval rather than blindness; past twice that cadence it surfaces.
`docs/currency-round.md` owns that rule and `tests/fm-currency-round.test.sh` holds all five branches.

## The two configuration files, checked against post-move reality

Addresses were measured rather than read, for the reason this home's learnings record under the reclaimed-name incident of 2026-08-12: a URL that looks plausible can address a different repository, and ownership on both ends removes the error that would have told you.

| File | Value | Measured | Verdict |
| --- | --- | --- | --- |
| `config/fork-sync-upstream` | `https://github.com/kunchenguid/firstmate.git` | `gh api repos/kunchenguid/firstmate` -> id `1266884317`, not a fork, and the recorded parent of `Coditan/firstmate-source` | Correct as-is. It names the template the curated fork tracks, which is what this check's upstream side must be. |
| `config/firstmate-update-base` | `https://github.com/Freudator86/admiralty.git` | `gh api repos/Freudator86/admiralty` -> id `1312500697`, not a fork, created 2026-07-26; `git ls-remote` HEAD `36949ec6`, which is also this home's own default-branch commit | Correct as-is. It names the fleet repository this deployment is deployed from and updates from, which is what this check's base must be after the 2026-07-28 cutover. |

The fork side needs no `config/fork-sync-fork` on this seat: the `fork` remote already names `Coditan/firstmate-source` (id `1305017182`, a fork of `kunchenguid/firstmate`), and that hop outranks `origin`.

The vacated-name sweep that the same work item asked for is clean.
`Freudator86/firstmate` - since 2026-08-12 a different repository (id `1331576769`) - survives in this repository only as history and as the hazard's own documentation: a dated measurement in `docs/grossreinschiff.md`, the warning in `docs/fork-patches.md`, and a fixture URL in `tests/fm-tg-send.test.sh`.
No remote, no configuration file, and no pin text addresses it.
The search method was validated against a known hit before any zero was believed, because an earlier sweep of this same question was measured returning zero from the home root while the same search one level down found matches: `grep -rn 'kunchenguid/firstmate'` over the same tree returned 28 hits in the same invocation style that returned 4 for the old address.

## The gap this pass closed

`bin/fm-firstmate-update-check.sh` published its finding without naming the source it compared or the hop that source came from, while its sibling check names both.
That is the same class one instrument over: a base pointing at a repository this deployment never updates from produces a finding indistinguishable from a correct one, which is exactly the failure the configuration check above exists to rule out.
Pointed deliberately at a repository this seat does not update from, the two versions read:

```
# before
FIRSTMATE_UPDATE_AVAILABLE: upstream instruction update 36949ec6... -> c0376625...; dispatch a crewmate to broadcast via Bridge All-Ships

# after
FIRSTMATE_UPDATE_AVAILABLE: instruction update 36949ec6... -> c0376625... on the source this deployment updates from; dispatch a crewmate to broadcast via Bridge All-Ships
  compared: this deployment against https://github.com/Coditan/firstmate-source.git (from FM_FIRSTMATE_UPSTREAM_URL)
```

The word `upstream` left the first line on purpose.
On a fleet-deployed seat the source this deployment updates from is the fleet repository, while `upstream` in the sibling fork check names the template the fork tracks - one word for two repositories, in two findings a reader sees side by side in the same digest.
The refusal for an unreachable base names its hop for the same reason.

## What this pass deliberately did not do

- It did not bring the fork current with the template.
  That is a separate standing duty, and the 234 upstream-only commits above are its input, not its result.
- It did not bump the fleet pin.
  Pin age is reported by the round and the bump is the fleet repository's own reviewed step.
- It did not touch the absorption prefilter's known weakness, which `docs/fork-upstream-merge-assessment.md` owns.
