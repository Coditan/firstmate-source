# Firstmate portable test shards (Phase 4)

This document records how the two portable parallel CI shards were balanced from measured evidence.
Composition and execution are owned by `bin/fm-test-run.sh` (`--lane portable-parallel-1` / `portable-parallel-2` / `portable-serial`).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (30 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Phase 1 serial durations | CI timing artifacts `fm-test-timing` from main after #825 / #832 / #834 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

Phase 1 averages used for balance (mean of available serial `duration_ms` across those artifacts):

| duration_ms (avg) | script |
|---:|---|
| 29639 | `tests/fm-arm-pretool-check.test.sh` |
| 25402 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19428 | `tests/fm-x-mode.test.sh` |
| 14979 | `tests/fm-cd-pretool-check.test.sh` |
| 9339 | `tests/fm-backend-herdr.test.sh` |
| 6885 | `tests/fm-herdr-lab.test.sh` |
| 5127 | `tests/fm-crew-state.test.sh` |
| 4044 | `tests/fm-pr-merge.test.sh` |
| 3922 | `tests/fm-grok-harness.test.sh` |
| 2492 | `tests/fm-test-run.test.sh` |
| 1901 | `tests/fm-send-popup-settle.test.sh` |
| 1234 | `tests/fm-spawn-batch.test.sh` |
| 851 | `tests/fm-send-strict.test.sh` |
| 791 | `tests/fm-review-diff.test.sh` |
| 627 | `tests/fm-tmux-submit-busy.test.sh` |
| 525 | `tests/fm-brief.test.sh` |
| 321 | `tests/fm-composer-ghost.test.sh` |
| 283 | `tests/fm-dispatch-select.test.sh` |
| 276 | `tests/fm-send-settle.test.sh` |
| 189 | `tests/fm-ensure-agents-md.test.sh` |
| 175 | `tests/fm-supervision-instructions.test.sh` |
| 138 | `tests/fm-instruction-owners.test.sh` |
| 133 | `tests/fm-lint.test.sh` |
| 108 | `tests/fm-pi-primary-types.test.sh` |
| 106 | `tests/fm-nm-test-contract.test.sh` |
| 67 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-captain-translation-contract.test.sh` |
| 48 | `tests/fm-composer-lib.test.sh` |
| 36 | `tests/fm-stow-contract.test.sh` |
| 28 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing method

Longest-processing-time (LPT) assignment onto two workers using the Phase 1 averages above.
Do not rebalance alphabetically or by family intuition.
Shard execution order is longest-first so wall-clock tracks the balanced sum.

| Lane | Script count | Sum of Phase 1 averages |
|---|---:|---:|
| `portable-parallel-1` | 15 | 64579 ms (~64.6 s) |
| `portable-parallel-2` | 15 | 64579 ms (~64.6 s) |
| imbalance | | 0 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial remainder

`portable-serial` is every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in (default skip), GUI backends, and other stateful or unproven work serial.
The original Phase 1 artifacts measured the serial remainder at about **13 minutes**; current measurements and the cap derivation are recorded under [Timeouts](#timeouts).

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. Union of portable parallel shards + portable serial + real-Herdr family equals the complete `tests/*.test.sh` inventory.
4. Those four partitions are pairwise disjoint (no missing scripts, no duplicates).
5. `docs/scripts.md` names every `bin/*.sh`, names each one once, and names nothing that is gone (`FM_SCRIPT_INDEX ok`).
6. Every `tests/*.test.sh` carries a decided family (`FM_TEST_FAMILIES ok`); there is no catch-all family to fall into, so an unmapped test refuses here and at every selection rather than defaulting.
7. Every family states the boundary it claims, in the block above `family_for_basename`, so a classification the fleet has to live with cannot outlive its reasoning.

Every file set the guard compares is derived from the directory or the document itself.
What each family means, and the discriminator against the family it is most easily confused with, lives at the map in `bin/fm-test-run.sh` rather than here, so a reviewer meets the reasoning where the mapping is made.
That is deliberate: a hand-kept enumeration inside the gate would be the same ungated list the gate exists to catch, and the flat globs these checks rest on are also why a regroup of `bin/` would silently narrow them.

This is the repository's single zero-drift gate location, run in CI as the required `test-coverage` job.
New derived invariants belong here rather than in a second script or a second job, because a second location is a second thing to keep by hand.

## Timing artifacts

Every portable shard, the portable serial lane, and the Herdr lane upload their runner-generated timing JSON even when the behavior run reports failures.
The dependent aggregate job runs after all four lanes, combines every available lane JSON through `bin/fm-test-run.sh --aggregate-json`, and uploads one summary artifact for critical-path review.
The workflow in `.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | Measured shard sum ~1 min; hang tripwire with margin |
| portable serial | 40 | Completions measured 17m47s..19m56s over 17 runs on 2026-08-12..14, with every run reaching the old 20m cap cancelled at 20m03s..20m17s and zero failing assertions; 2x that censored >=20m ceiling |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
Do not raise them as a substitute for green results, retries, or weaker assertions.

## What this phase does not do

- Does not expand the proven-isolated set without a new concurrent isolation proof.
- Does not parallelize watcher, AFK, real Herdr, real tmux, or other stateful families.
- Does not start rollout verification; that waits until this PR is green and merged.
