# The knowledge-file curation nudge

`bin/fm-curation-nudge.sh` is the 48-hour cadence behind the fleet's standing instruction to prune its knowledge files rather than append to them.
This document records the evidence that produced it, the timing contract it must hold, the boundary it must not cross, the health property it was built around, and what it deliberately does not do.
The script's own header owns its flags, state files, and exact mechanics.

## The gap this closes

`data/learnings.md` and `data/captain.md` are per-home, captain-private and gitignored.
Every vessel has a pair, no vessel can see another's, and nothing anywhere re-measured them.

Measured on this seat on 2026-08-17, when this work was commissioned: `data/learnings.md` had reached **5,445 lines / 417 KB**, and together with `data/captain.md` the pair was **86% of the entire session-start digest** - roughly 130,000 tokens read before any work began, against a 300,000-token context ceiling.
A fresh session finished its startup read at about 360,000 tokens, already over the ceiling, so that session's first context-ceiling wake fired on the startup read itself.

Re-measured on this seat a few hours later, while this script was being written: `data/learnings.md` was **250 lines / 19,438 bytes** and `data/captain.md` **2,021 lines / 151,636 bytes**, the pair 171,074 bytes with a `learnings.md` mtime inside that window.
A curation pass had run in between.
Both readings belong in this record rather than only the convenient one, and together they say more than either alone: the debt was real, a human sweep can clear it, and nothing scheduled that sweep or will schedule the next one.
They also move which half is the larger: after that pass `data/captain.md` is roughly eight times the size of `data/learnings.md`, so a sweep that only ever looks at learnings is looking at the smaller problem.
Neither reading is a claim about any other vessel, and this document makes none.

That is not a defect in the digest.
`AGENTS.md` section 10 already said to inspect and prune rather than append by default.
It is a curation debt, and the reason it accrued for weeks is that the instruction had no mechanism: a rule with no trigger is carried by memory, which is the same defect shape `docs/currency-round.md` records for the daily update duty.
This script is that trigger.

## The timing contract

**The period is 48 hours.**
Not daily: `bin/fm-currency-round.sh` already owns the daily slot, and a curation sweep at that rate stops being a prompt and becomes noise, which is how a check earns being ignored.

**The jitter is 180 to 420 seconds, drawn fresh at every firing.**
A fixed offset would lock the nudge to one wall-clock time forever; a fresh draw per firing makes successive fires drift.

**The drawn target's minute is never a multiple of five, and that is a refusal rather than a preference.**
Cron defaults, systemd timers, monitoring pollers and this fleet's own watcher sweep all cluster on five-minute boundaries, so a fleet-wide fire landing there stacks on top of everything the machines are already doing.
`draw_next_due` computes a target and *discards* one whose minute is on the grid, drawing again.
The jitter window spans five consecutive minutes, of which at most one is on the grid, so a draw refuses at most a handful of times.
Exhausting the attempt bound reports a failure to schedule rather than quietly accepting an on-grid target - a jitter that merely usually avoids the grid is not the property that was asked for, and `tests/fm-curation-nudge.test.sh` asserts it over 2,000 independent draws rather than over a few.

The minute is computed in UTC and the property survives every real local rendering.
Every civil UTC offset in use is a whole multiple of 15 minutes - `+05:30` and `+05:45` included - so a local rendering shifts the minute by a multiple of five and cannot move a target on or off the grid.

### What the target guarantees, and what it does not

The **target** is the scheduled firing instant, and it is off-grid by construction.
The **observation** is when the watcher's next `state/*.check.sh` sweep reaches it, which is the target plus however far that sweep has to travel.
That sweep's own phase belongs to `bin/fm-watch.sh` and is set by whenever this home's watcher service started, so it is per-home and arbitrary across the fleet.
This script owns the target, states it in its own report, and claims nothing about the sweep.

A deferral - hold the firing whenever the *observed* minute is on the grid - was considered and rejected.
`FM_CHECK_INTERVAL` defaults to exactly 300 seconds, so consecutive sweeps land on the same minute-mod-five offset: a deferral would either never trigger or never clear, depending on the phase the watcher happened to start with.
A guard that can starve the thing it guards is worse than the exposure it removes, and a second mechanism answering the same question would leave two owners of one property.

## The boundary: two hops, not one

**The daemon does not write to Bridge.**
`AGENTS.md` section 1 forbids firstmate from calling Bridge project automation directly, and a timer that broadcasts is exactly that with extra steps.
A timer holding the fleet's mailbox is also unauditable: nobody ever sees what it said.

So the notice takes two hops, and this script owns only the first:

1. The check fires and raises an ordinary `check:` wake naming what is due.
2. Firstmate reads that wake and dispatches a crewmate to send the All-Ships notice, exactly as `AGENTS.md` section 12 requires of any fleet notice.

The wording of that notice is firstmate's, not this script's.
An ordinary detect sweep and ordinary firing exit successfully, while a state-persistence failure exits non-zero after printing its actionable diagnostic.
The watcher captures a registered check's standard output and surfaces any non-empty result even when that check exits non-zero, so the diagnostic is not discarded or converted into silence.
A firing whose successor draw refuses prints the firing wake and the refusal diagnostic; a firing whose successor cannot be persisted prints the firing wake and the persistence diagnostic.
`--draw` and `--status` are read-only and do not create the state directory when it is absent.

The boundary is asserted rather than intended, in three ways.
No executable line in the script reaches for a Bridge script, a forge client, a network client, or `git`.
A tripwire fixture puts executables named `fm-bridge-relay.sh`, `bridge-axi`, `gh`, `gh-axi`, `git`, `curl`, `wget`, `ssh`, and `scp` first on `PATH`, runs every mode, and fails if any of them was ever invoked.
The generated watcher shim carries no call path of its own either; it is a seam that execs the script and nothing more.

## What the nudge asks for

The payload is a prompt to measure, never a claim about any vessel's state.
This seat cannot see another's files, so each vessel measures its own:

- the line count and byte size of its own `data/learnings.md` and `data/captain.md`
- what share of its own session-start digest those two are
- whether that share is worth what it costs

The nudge carries this seat's own two readings, explicitly marked as this vessel's own, and disclaims any reading of another.
It does not compute the digest share, even for itself.
Modelling what the session-start digest contains would be a second model of `bin/fm-session-start.sh` that drifts silently the moment that script's inputs change, and the share is exactly the thing each vessel is being asked to measure for itself.

## The health property

This fleet keeps building timers that lie.
Measured on this host on 2026-08-17, and re-measured while writing this: `bridge-notify-poll.timer` reports `Loaded: loaded (...; enabled; preset: enabled)` and `Active: active (elapsed) since Fri 2026-08-07 03:45:02 UTC` with `Trigger: n/a`.
Ten days dead, with every surface but one reporting health, and the one that gives it away is the missing next trigger.

So `--armed` never asks this check whether it is fine.
It reads what the *work* produced:

| Reading | What it is taken from | What it catches |
| --- | --- | --- |
| Is a check armed and registered at all? | `state/curation-nudge.check.sh` and its trust record | a home where the nudge was never installed, or the arm failed |
| Does a next sweep exist? | `state/curation-nudge.next-due` | the `Trigger: n/a` shape - armed, loaded, and scheduling nothing |
| Is anything executing the one there is? | `next-due` against now, plus `state/curation-nudge.last-fire` | a home whose checks stopped running while every surface still reports armed |

A freshly armed home has not yet scheduled anything, and that is not a fault; the missing-target reading only speaks once the shim has been sitting there longer than a sweep could plausibly take.

The failing case is proved, not assumed.
`tests/fm-curation-nudge.test.sh` fires the nudge, then stops it the way a dead timer stops - the schedule stays, the shim stays, and nothing executes it - and asserts the reading goes bad rather than staying quiet.
It also removes the check and asserts the unarmed reading, and holds a live, scheduled home to silence, so the healthy verdict is a measurement and not a default.

## What this deliberately does not do

- It never prunes anything, and never decides any vessel's split between what to keep and what to drop.
  It measures its own two files, records them, and raises one wake.
- It never touches another vessel's files, and never claims a reading of one.
  Each home curates its own; firstmate never reaches into another vessel's home.
- It does not write the All-Ships notice or decide its wording.
  That is the second hop, and it belongs to firstmate and a dispatched crewmate.
- It does not measure the session-start digest share, for itself or anyone.
- It does not set a size threshold below which the nudge stays silent.
  The sweep is fleet-wide, so whether it is due has nothing to do with how large this one seat's files happen to be, and a threshold here would be this seat deciding another's split.
- It does not introduce a scheduler.
  It extends the seam `bin/fm-currency-round.sh` already uses - the watcher's `state/*.check.sh` sweep, armed from bootstrap and kept alive by the watcher's own service - so it inherits a supervisor the fleet already trusts.
  `docs/currency-round.md` "Why the watcher, and not the three alternatives" records why an external cron or systemd timer was rejected there, and the same evidence binds here.

## Cost

The wake is one line, at most once per 48 hours.
Every other watcher sweep is one file read and one integer comparison, which is the same discipline `docs/currency-round.md` "Cost, and why the model is woken so rarely" records: on this fleet a surfaced notification costs a median of roughly 171,000 fresh tokens while the mechanical poll that decides whether to raise one costs about 207.

The nudge fires on cadence rather than on a change, because the thing being asked for is the periodic re-measure itself; `AGENTS.md` section 8's "never restate an unchanged state" governs reports of state, and this is a prompt to take a reading, not a report of one.
