# The off-grid fleet nudges

`bin/fm-nudge.sh` is the cadence behind the fleet's standing duties that are periodic re-measures rather than reactions to a change.
It carries two subjects today: the 48-hour **curation** subject behind the instruction to prune the knowledge files rather than append to them, and the 52-hour **codebase-sweep** subject behind the instruction to sweep a repository's design before it takes a large amount of agent work.
This document records the evidence that produced them, the timing contract they must hold, why they ride one check rather than one unit each, the boundary they must not cross, the health property they were built around, and what they deliberately do not do.
The script's own header owns its flags, subjects, state files, and exact mechanics.

## The gap this closes

### The curation subject

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

### The codebase-sweep subject

A repository that is hard for a stranger to navigate is hard for every agent that will ever be pointed at it, because an agent arrives with no memory of it at all.
The `codebase-sweep` skill owns that obligation and runs on one named repository at a time.
It had the same shape of gap: `AGENTS.md` section 6 says to sweep before a project takes a large amount of agent work and before proposing that one of its modules be restructured, and nothing measured whether any vessel ever did.

The cadence added here does not close that gap by sweeping.
It closes it by asking, on a period, which is the whole of the Commodore's own refinement: *"add that to the skill and have the daemon tell the fleet to use the skill."*
A timer that itself swept eleven repositories would be unauditable, would spend quota nobody approved, and would reach into homes this seat does not own.

## One check, several subjects

The second subject was registered on the existing check rather than given a check of its own, and that is the whole shape of the change.

Two near-identical units on one host is a trap this fleet has already measured.
`bridge-notify-poll.timer` on this machine reported `Loaded: loaded (...; enabled; preset: enabled)` and `Active: active (elapsed) since Fri 2026-08-07 03:45:02 UTC` with `Trigger: n/a` on 2026-08-17 - ten days dead, with every surface but one reporting health.
Sibling units that behave differently are worse than one unit with several subjects, because the difference between them is invisible until one of them is the one that stopped.

So there is one armed shim, `state/nudge.check.sh`; one arming path; one scheduling function; one health-reading shape; and one place where the cadence rules are written.
A subject brings only its own period, its own `state/<subject>-nudge.report`, and its own payload and diagnostic code.
`tests/fm-nudge.test.sh` asserts the single shim by counting `state/*.check.sh` after arming, and enumerates the registry rather than naming subjects wherever a property must hold for all of them - so a third subject inherits the proofs instead of being able to skip them.

The shim bakes in no subject.
A subject added upstream therefore starts being scheduled on the next session start of an already-armed home, with no second arming path that could fall out of step with the first.

### Retiring the predecessor

The single-subject predecessor was `state/curation-nudge.check.sh`, execing `bin/fm-curation-nudge.sh`.
`--arm` deletes that shim and its trust record after the replacement is armed and registered, never before.
Leaving it would be the quiet failure this check exists to refuse: the watcher discards a check's standard error, so a shim pointing at a script that moved fails silently forever while every surface still reports a registered, trusted check.

## The timing contract

**The curation period is 48 hours. The codebase-sweep period is 52 hours.**
Neither is daily: `bin/fm-currency-round.sh` already owns the daily slot, and a re-measure at that rate stops being a prompt and becomes noise, which is how a check earns being ignored.

**No two subjects share a period, and that is the contract rather than a coincidence.**
`tests/fm-nudge.test.sh` reads the registry and fails if two subjects are given the same one.

**The jitter is 180 to 420 seconds, drawn fresh at every firing, per subject.**
A fixed offset would lock a subject to one wall-clock time forever; a fresh draw per firing makes successive fires drift.

**The drawn target's minute is never a multiple of five, and that is a refusal rather than a preference.**
Cron defaults, systemd timers, monitoring pollers and this fleet's own watcher sweep all cluster on five-minute boundaries, so a fleet-wide fire landing there stacks on top of everything the machines are already doing.
`draw_next_due` computes a target and *discards* one whose minute is on the grid, drawing again.
The jitter window spans five consecutive minutes, of which at most one is on the grid, so a draw refuses at most a handful of times.
Exhausting the attempt bound reports a failure to schedule rather than quietly accepting an on-grid target - a jitter that merely usually avoids the grid is not the property that was asked for, and `tests/fm-nudge.test.sh` asserts it over 2,000 independent draws for the curation subject and 500 for every registered subject, rather than over a few.

The minute is computed in UTC and the property survives every real local rendering.
Every civil UTC offset in use is a whole multiple of 15 minutes - `+05:30` and `+05:45` included - so a local rendering shifts the minute by a multiple of five and cannot move a target on or off the grid.

### Two subjects that do not travel together

The periods differ by four hours, so after any shared firing the two separate by a further four hours each cycle and stay apart for the whole cycle.
Because 13 curation periods and 12 codebase-sweep periods are both exactly 624 hours, the two re-approach at that common multiple - about 26 days - and nowhere else.

That is measured rather than asserted.
Driving both subjects from one common base through their first 13 and 12 firings, the closest approach between any pair *other than* the common-multiple pair stayed above two hours; across a longer 82-day run the closest approach overall was **99 seconds**, and it fell exactly on the 13th curation firing against the 12th codebase-sweep firing, where the arithmetic says it must.
`tests/fm-nudge.test.sh` pins both halves of that: the two-hour floor before the common multiple, and that the excluded pair is the common-multiple pair rather than a hole in the measurement.

**The re-approach is not defended against, and that is deliberate.**
Refusing a target that lands near another subject's target would be a guard that can starve the thing it guards: the jitter window is only 240 seconds wide, so a blocked window would exhaust the draw and stall the cadence, which is the same objection this document already records against deferring an on-grid *observation*.
Instead the coincidence is made harmless.
Each subject keeps its own record and its own wake line, so a sweep carrying both prints two lines, each naming its own code and its own record; `tests/fm-nudge.test.sh` asserts that shape directly.
The watcher joins a multi-line check result into one wake payload, which is the same shape a firing plus a refusal diagnostic has always produced.

### What the target guarantees, and what it does not

The **target** is the scheduled firing instant, and it is off-grid by construction.
The **observation** is when the watcher's next `state/*.check.sh` sweep reaches it, which is the target plus however far that sweep has to travel.
That sweep's own phase belongs to `bin/fm-watch.sh` and is set by whenever this home's watcher service started, so it is per-home and arbitrary across the fleet.
This script owns the target, states it in its own report, and claims nothing about the sweep.

A deferral - hold the firing whenever the *observed* minute is on the grid - was considered and rejected.
`FM_CHECK_INTERVAL` defaults to exactly 300 seconds, so consecutive sweeps land on the same minute-mod-five offset: a deferral would either never trigger or never clear, depending on the phase the watcher happened to start with.
A guard that can starve the thing it guards is worse than the exposure it removes, and a second mechanism answering the same question would leave two owners of one property.

## The boundary: two hops, not one

**The check does not write to Bridge.**
`AGENTS.md` section 1 forbids firstmate from calling Bridge project automation directly, and a timer that broadcasts is exactly that with extra steps.
A timer holding the fleet's mailbox is also unauditable: nobody ever sees what it said.

So the notice takes two hops, and this script owns only the first:

1. The check fires and raises an ordinary `check:` wake naming what is due.
2. Firstmate reads that wake and dispatches a crewmate to send the All-Ships notice, exactly as `AGENTS.md` section 12 requires of any fleet notice.

The wording of that notice is firstmate's, not this script's.
An ordinary detect sweep and ordinary firing exit successfully, while a state-persistence failure exits non-zero after printing its actionable diagnostic; one subject's failure never stops another subject being evaluated on the same sweep.
The watcher captures a registered check's standard output and surfaces any non-empty result even when that check exits non-zero, so the diagnostic is not discarded or converted into silence.
A firing whose successor draw refuses atomically publishes that outcome, then prints the firing wake and refusal diagnostic.
If a subject's single authoritative record cannot be published, the prior state remains byte-for-byte intact, the wake is withheld, and the persistence diagnostic makes the retry visible.
`--draw` and `--status` are read-only and do not create the state directory when it is absent.

The boundary is asserted rather than intended, in three ways.
No executable line in the script reaches for a Bridge script, a forge client, a network client, or `git`.
A tripwire fixture puts executables named `fm-bridge-relay.sh`, `bridge-axi`, `gh`, `gh-axi`, `git`, `curl`, `wget`, `nc`, `ssh`, and `scp` first on `PATH`, runs every mode for every subject, and fails if any of them was ever invoked.
The generated watcher shim carries no call path of its own either; it is a seam that execs the script and nothing more.

## What each nudge asks for

Both payloads are prompts to act, never claims about any vessel's state.
This seat cannot see another's files or repositories, so each vessel measures its own.

**Curation** asks every vessel for:

- the line count and byte size of its own `data/learnings.md` and `data/captain.md`
- what share of its own session-start digest those two are
- whether that share is worth what it costs

It carries this seat's own two readings, explicitly marked as this vessel's own, and disclaims any reading of another.
It does not compute the digest share, even for itself.
Modelling what the session-start digest contains would be a second model of `bin/fm-session-start.sh` that drifts silently the moment that script's inputs change, and the share is exactly the thing each vessel is being asked to measure for itself.

**Codebase-sweep** asks every vessel to load the `codebase-sweep` skill and run it on its own repositories, one named repository at a time, deciding for itself which findings it may take without the captain.

It carries no reading at all, and says so in its record rather than leaving the absence to be noticed.
What that sweep measures is inside each repository, and only a dispatched sweep can measure it; this cadence reads no repository, here or anywhere.
Inventing a cheap proxy - a count of registered projects, a file size - would be a number that looks like a measurement of the thing and is not one.

## The health property

This fleet keeps building timers that lie.
Measured on this host on 2026-08-17, and re-measured while writing this: `bridge-notify-poll.timer` reports `Loaded: loaded (...; enabled; preset: enabled)` and `Active: active (elapsed) since Fri 2026-08-07 03:45:02 UTC` with `Trigger: n/a`.
Ten days dead, with every surface but one reporting health, and the one that gives it away is the missing next trigger.

So `--armed` never asks this check whether it is fine.
It reads what the *work* produced, once per subject:

| Reading | What it is taken from | What it catches |
| --- | --- | --- |
| Is the one check armed and registered at all? | `state/nudge.check.sh` and its trust record | a home where the check was never installed, or the arm failed |
| Does a next sweep exist for this subject? | the scheduling outcome in `state/<subject>-nudge.report` | the `Trigger: n/a` shape - armed, loaded, and scheduling nothing |
| Is anything executing the one there is? | the next-target and last-firing epochs in that same record | a home whose checks stopped running while every surface still reports armed |
| Can an overdue target be updated now? | a representative report write and same-directory atomic rename between distinct scratch paths | separates a current persistence failure from a supervision outage without trusting unit state |

The armed reading is taken **first**, and for every subject.
One shim serves them all, so an unarmed shim means nothing will run any of them; reading a subject's record first would let a still-plausible schedule speak for a check that is not there, and a schedule can stay plausible for a whole period.
That is the same "surface reports health while nothing executes" shape the rest of this reading exists to refuse.

`state/<subject>-nudge.report` is both the human-readable report named by that subject's wake and its only authoritative scheduling record.
It carries the subject, its diagnostic code, the last firing epoch, the current next-target or refusal outcome, the effective cadence parameters, and that subject's readings, and every transition replaces all of those bytes with one atomic rename.
A failed publication cannot durably record its own failure because publication is the operation that failed, so `--armed` takes a fresh state-path reading before every conclusion that supervision has stopped, whether a target is overdue or the first authoritative record is still missing.
An unusable path reports `state persistence failure`, a usable path with missing work reports `supervision outage`, and a probe whose result cannot be determined reports `state health indeterminate`, names both candidate causes, and asserts neither.
The probe never targets the authoritative record, removes both scratch paths after the write and rename, and never advances or consumes the authoritative due event.
If it cannot run, complete, or clean up non-destructively, the reading is indeterminate rather than a confident diagnosis.

A freshly armed home has not yet scheduled anything, and that is not a fault; the missing-target reading only speaks once the shim has been sitting there longer than a sweep could plausibly take.

The failing case is proved, not assumed.
`tests/fm-nudge.test.sh` fires the check, then stops it the way a dead timer stops - every schedule stays, the shim stays, and nothing executes it - and asserts the reading goes bad for **every registered subject** rather than staying quiet.
It also removes the check and asserts the unarmed reading, holds a live, scheduled home to silence so the healthy verdict is a measurement and not a default, and asserts that one subject going bad neither drags a healthy subject into the report nor stops the subjects after it being evaluated.

## What this deliberately does not do

- It never prunes anything, never sweeps a repository, and never decides any vessel's split or findings.
  It measures its own two knowledge files, records what each subject can honestly state, and raises one wake per due subject.
- It never touches another vessel's files or repositories, and never claims a reading of one.
  Each home curates and sweeps its own; firstmate never reaches into another vessel's home.
- It does not write the All-Ships notice or decide its wording.
  That is the second hop, and it belongs to firstmate and a dispatched crewmate.
- It does not measure the session-start digest share, for itself or anyone.
- It does not set a size or staleness threshold below which a nudge stays silent.
  Both sweeps are fleet-wide, so whether one is due has nothing to do with this one seat's numbers, and a threshold here would be this seat deciding another's split.
- It does not defend against the 26-day re-approach between subjects, because the only available defence can starve the cadence it guards.
- It does not introduce a scheduler.
  It extends the seam `bin/fm-currency-round.sh` already uses - the watcher's `state/*.check.sh` sweep, armed from bootstrap and kept alive by the watcher's own service - so it inherits a supervisor the fleet already trusts.
  `docs/currency-round.md` "Why the watcher, and not the three alternatives" records why an external cron or systemd timer was rejected there, and the same evidence binds here.

## Cost

An ordinary firing emits one wake line, at most once per period per subject: roughly one curation line every 48 hours and one codebase-sweep line every 52.
A firing whose successor draw refuses emits that wake plus a refusal diagnostic because the second line names a scheduling condition the wake cannot carry; if the successor cannot be persisted, its persistence diagnostic replaces the withheld wake so the due event remains queued for retry.
Every other watcher sweep is one file read and one integer comparison per subject, which is the same discipline `docs/currency-round.md` "Cost, and why the model is woken so rarely" records: on this fleet a surfaced notification costs a median of roughly 171,000 fresh tokens while the mechanical poll that decides whether to raise one costs about 207.

Adding a subject to this check therefore costs one extra file read per sweep, and adding a second check would have cost a second shim, a second arming path, a second health reading, and a second thing that can die quietly.

Both subjects fire on cadence rather than on a change, because the thing being asked for is the periodic re-measure itself; `AGENTS.md` section 8's "never restate an unchanged state" governs reports of state, and these are prompts to take a reading, not reports of one.
