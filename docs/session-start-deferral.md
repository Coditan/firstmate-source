# Taking the network out of the session-start wait

Session start waited for its own network before it would produce a first turn.
This is the record of what that cost, what changed, and what was measured afterwards.
The mechanism itself is owned by `bin/fm-deferred-check.sh`; this file is evidence, not a second copy of the contract.

## What it cost

Measured on tugboat-cloud, 2026-09-04, from that home's own `state/session-start-timing.log`:

```
2026-09-01T20:57:16Z total=26272ms bootstrap=23702ms
2026-09-02T11:47:06Z total=36932ms bootstrap=34612ms
2026-09-03T12:51:30Z total=37412ms bootstrap=35044ms
2026-09-04T14:24:51Z total=45709ms bootstrap=43454ms
```

Every one of those numbers scales with a quantity that only grows: that seat carries 14 project clones, and the refresh fetches them one after another.
This is vendored code, so every vessel pays it.

## What changed

The two network sweeps - the project-clone refresh and the AXI-suite currency check - no longer block.
`bin/fm-bootstrap.sh` starts each one, carries on with the rest of the run, and collects at the end without waiting.
A check that has not answered by then prints its own PENDING line naming what the digest does not yet know, and the run itself queues a `check` wake carrying its complete result when it finishes.

Two things were deliberately NOT deferred.

The self-drift `git fetch` stays synchronous, because it runs on the read-only path too, and a lock-refused session must leave the wake queue untouched: a finding it deferred would be delivered to a different session than the one that asked.
The AXI-suite SHADOWING report stays synchronous, because it answers a question about the caller's own process tree, and the record it reads is honoured only for the process that made it and that process's descendants.
A detached runner has been orphaned to init by the time it looks, so deferring that report turned every `AXI_SUITE_SHADOWED` line into `AXI_SUITE_SHADOW_UNKNOWN` - measured, not predicted, which is why `fm-axi-suite.sh` now has `--shadow-only` and `--no-shadow` and bootstrap uses both.

## What it costs now

Measured 2026-09-04 on this machine, in a stand-in home holding 14 clones of the same repositories the tugboat-cloud seat carries, running `bin/fm-session-start.sh` and reading its own `state/session-start-timing.log`.
Three consecutive runs each way, no other change:

```
before  total=15823ms bootstrap=15062ms
        total=14369ms bootstrap=13717ms
        total=14357ms bootstrap=13703ms
after   total=4555ms  bootstrap=3852ms
        total=4562ms  bootstrap=3853ms
        total=4434ms  bootstrap=3738ms
```

The same comparison with the network denied - every client pointed at an unroutable proxy, verified by a `git ls-remote` that reached its 20s timeout with no output - run as `bin/fm-bootstrap.sh` alone:

```
before  112.2s
after    34.4s
```

Neither offline run hung, and both delivered the same diagnostics: the refresh reported `FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=47s elapsed=47s)` and the suite reported six `AXI_SUITE_STUCK: ... latest version lookup failed` lines.
After the change those lines arrived as `check` wakes rather than in the digest, which is the whole of the difference.

The 34s that remain offline are not this path: `gh auth status` is still synchronous, and it is what an unreachable network spends them on.
That is the next thing to look at, and it was left alone here.

## What a pending one looks like

Constructed 2026-09-04 by giving a home one clone whose origin does not answer, then running `bin/fm-session-start.sh`.
The digest came back in 5.2 seconds carrying these two lines, and the finding arrived 17 seconds later:

```
FLEET_SYNC: fleet: pending: the project-clone refresh is still running, so this digest does not yet say
  whether any clone is stuck, behind, or unreachable; its result arrives as a check wake
AXI_SUITE_PENDING: the suite currency check is still running, so this digest does not yet say whether a
  vessel copy is outdated or stuck; its result arrives as a check wake

state/.wake-queue:
check  fleet-sync  check: fleet-sync: finished after session start: FLEET_SYNC: fleet: skipped: bootstrap
  refresh timed out (timeout=20s elapsed=20s) (full output: .../state/.deferred/fleet-sync/out)
```

## The rule this was built around

A deferred check must never be able to finish silently.
An absent line reads as an all-clear, and a check whose silence is indistinguishable from a clean result is the defect class this fleet keeps recording.
So a clean late result queues a wake saying it found nothing, exactly as loudly as a finding does, and the pending line it answers names what was unknown rather than being omitted.
`tests/fm-deferred-check.test.sh` holds that, along with the one property the whole mechanism rests on: `start` must not hold its caller's stdout, because `bin/fm-session-start.sh` reads bootstrap through a command substitution and a runner that inherited the pipe would make the digest wait for exactly the work being deferred.
