# The memory alarm

`bin/fm-memory-alarm.sh` wakes the fleet when `hlr-web-1` is running out of RAM headroom, or is already stalling on memory it has, and names the process responsible, its account, and the work it was serving.
It limits nothing, throttles nothing, and kills nothing.

This document owns how its thresholds were derived, what would have to happen to cross them, and what the alarm cannot see.
The script's own header owns its flags, its states, and its records; nothing here restates them.

## Why there is no ceiling under it

The design this replaced was a cgroup ceiling with an alarm on crossing it.
That was built as far as measuring it and then abandoned on the measurement, because a ceiling on this host is crossed thousands of times by ordinary file reading with 16 GB RAM headroom, and holding a cgroup at one generates memory-stall time on the very reading the alarm consumes.
`docs/memory-ceiling-caveat.md` owns that finding and `bin/fm-memory-ceiling-probe.sh` re-measures it.
That finding is now load-bearing in a second way, and it grew: the signal a ceiling was measured to manufacture is the same signal this alarm's stall condition would read, and ordinary work on this seat has since been measured driving that signal ten times higher than the probe did, with no ceiling anywhere.
That is a large part of why the stall condition decides on duration rather than on a level; see "Stall: gate 1.00, window 7200 seconds" below.

The captain's decision after that measurement was to build the alarm on RAM headroom and growth with no cgroup limit at all.
That remains true after the 32 GiB swapfile added on 2026-08-17.
Swap is a shock absorber: it gives anonymous memory somewhere to go and can turn an immediate kill into a slower host, but it does not stop page cache from expanding into a cgroup ceiling and it does not identify the worker that caused the pressure.
A container ceiling is now proposed for this seat, so `docs/memory-ceiling-caveat.md` is active evidence again rather than only history.
The figure in that proposal is 12 GB, which is hlr's proposal from one night's observation on their host and is **unmeasured here**; this seat has since named a different figure, and neither rests on a measurement, so no number in this document is evidence for a ceiling.
The measurement that would settle it is recorded per-pane peaks - what a pane actually reached, rather than what one happened to be watched reaching.
The ceiling must be re-measured before it is fitted, not inferred safe from the presence of swap.

Because nothing is limited, nothing can be throttled - so the requirement that the wake-delivery listener and the supervision watcher are never throttled is met by there being no mechanism here that could reach them, or anything else.
The reading's `protected` label on the wake-delivery listener is still carried into everything the alarm prints, so nothing downstream inherits a name without it.

## The three conditions

| Condition | Crosses when | What it is for |
| --------- | ------------ | -------------- |
| headroom | RAM headroom from `MemAvailable` is below the floor | a backstop, for memory going somewhere no tracked process is visibly growing into |
| horizon | total growth across tracked processes would consume that RAM headroom within the horizon | the primary trigger, and the one that warns rather than confirms |
| stall | host memory pressure-stall `full avg60` has stayed at or above the gate CONTINUOUSLY for longer than the window | the only one that can see a machine which is ALREADY unusable rather than about to become so |

Available memory here is `/proc/meminfo` `MemAvailable`, not RAM plus swap.
The local `proc_meminfo(5)` page defines `MemAvailable` as an estimate of memory available for new applications without swapping, while `SwapFree` is a separate field.
On this host on 2026-08-18, `bin/fm-memory-reading.sh --no-store --largest 3 --growing 3` reported `available 15395 MiB` and `swap 32768 MiB total, 32768 MiB free`.
The horizon therefore predicts loss of RAM headroom before swap is the main shock absorber, not final exhaustion of RAM plus swap.
That makes it early for a kernel-kill countdown on the post-swap host, but not wrong for the danger this alarm is meant to surface: the machine is entering reclaim or swap pressure, and firstmate still needs to know who is growing.

The horizon is measured on the **sum** of positive growth rather than the fastest single process.
Five workers growing at 500 MiB/min exhaust this machine exactly as fast as one growing at 2500 MiB/min, and no single one of those five looks alarming.
The process the alarm **names** is the largest contributor to that sum: the condition is about the machine, the name is about who to talk to.

The horizon self-tightens as RAM headroom goes, which is what lets one number work across the whole range.
At 16 GB RAM headroom it takes more than 1 GiB/min to trip; at 2 GB RAM headroom it takes 136 MiB/min.

### Why headroom and horizon alone cannot see a machine that is already drowning

Both of the conditions above divide by `MemAvailable`, and that is a shared blind spot rather than two independent ones.
`MemAvailable` is by definition an estimate of memory available to new applications **without swapping**, so once pressure has already been absorbed into swap it reads healthy while the machine is unusable.
The horizon has a second and separate blind spot in the same shape: it extrapolates growth, and a runaway that finished growing hours ago is not growing now, so there is nothing to extrapolate.
A machine can therefore sit with plenty of headroom, nothing growing, and no work getting done, and both conditions correctly report calm.

The stall condition measures the wait rather than the shortage that causes it.
`/proc/pressure/memory` reports two lines, and this condition reads the stricter one.
`some` is the share of a window in which **at least one** task was blocked waiting on memory - refaulting a page, swapping one in, or waiting on reclaim.
`full` is the share in which **every** runnable task was blocked, so nothing on the machine ran at all.

The condition crosses on `full`, and reports `some` beside it as evidence.
`some` can be driven up by one process refaulting on an otherwise healthy machine, and this fleet has measured exactly that.
`full` is lost machine throughput by definition, and it is the reading that matches the failure this condition exists for: in the 2026-08-27 incident, six processes sat in uninterruptible sleep and one of them was the seat's own agent, which is why the terminal read as frozen.
Neither can be argued with by arithmetic about what is nominally available, because both count time that work actually spent not running.

It reads the **60-second** average rather than the 10-second one.
The alarm polls every 300 seconds, so `avg60` covers six times more of the interval between polls than `avg10` does, and every seat the fleet has sampled measured the same 0.00 on both - so the longer average costs nothing measurable and rejects more.

**And it decides on duration, not on level.**
Crossing the gate does not raise the alarm; it starts a clock.
The condition crosses only when the stall has stayed over that gate continuously for longer than the window.
The next section is why, and it is the single most important thing on this page.

### Two things the condition deliberately does not trigger on

**Not the cumulative counter.**
`/proc/pressure/*` also carries `total=`, monotonic microseconds of stall since boot, and it is the counter both vessels used to measure the incident after the fact.
It is **evidence only**.
It never falls, so a condition built on it would fire permanently after any past starvation and could never recover: `tugboat-cloud` still reads 37.7% on that counter at load 0.60, fully recovered, with every windowed value at zero.
That is the same recovery-must-be-earned trap this alarm already handles for its other conditions.
The counter is put to one use instead, below, where its never-falling property is exactly what is wanted.

**Not an instantaneous magnitude.**
No level separates the two states on this fleet's hosts - the measurement is below - so a condition that fired on a reading being high would fire on the linter.
The level is used only as a gate: it decides whether this machine counts as stalling at all, and the clock does the rest.

**Not swap volume.**
Measured on 2026-08-28: a 12-core seat carrying 3,032 MiB of swap in use and an 8-core seat carrying 2,929 MiB were both completely calm.
A condition on swap volume would have false-fired on two seats that day.
The crossing line still reports swap in use, because it is what a reader needs next - but as evidence beside the decision, never as part of it.

### A successful read is not a measurement

A kernel can expose `/proc/pressure/memory`, answer every field, and account nothing into it.
Measured on a WSL seat on 2026-08-28: every memory pressure average read `0.00` **and** the cumulative total read exactly zero over 3,526 seconds of uptime, while that same seat's io counter stood at 2,063,189.
Pressure accounting worked there; only the memory account was flat.
From a single read, that is indistinguishable from a genuinely quiet machine, and it looks exactly like calm.

So the memory account has to prove itself rather than merely answer, and `bin/fm-memory-reading.sh` applies a **positive readability test**: a memory account that has recorded exactly zero stall since boot, beside an io account that has recorded some, is reported as **unmeasured**.
The io counter is read purely as that control and is never reported as a stall.
Where both accounts are still at zero, nothing distinguishes a dead account from a machine that has genuinely not stalled yet, and the reading says so rather than guessing - that residual case is listed under what the alarm cannot see.

### Which pressure a containerised seat reads, and why

Measured on `coditan-vessel` on 2026-08-28, from inside the container:

| Source | `some` total | `full` total |
| ------ | ------------ | ------------ |
| `/proc/pressure/memory` | 368,018,330 us | 332,413,982 us |
| `/sys/fs/cgroup/memory.pressure` | 317,967,457 us | 292,192,753 us |

`/proc/pressure/*` inside this container reports **the host's** figures, not the container's own: `yacht`'s reading of the same host from outside at nearly the same moment gave 332.4 s of cumulative full stall against 1,840,829 s of uptime, and from inside we read the same still-climbing counter at the same uptime.
The cgroup file is also readable here and gives a lower total, consistent with being a subset of the host's.

They answer different questions, and the alarm reads **`/proc/pressure/memory`**, the host vantage.
The question this alarm exists to answer is whether work on this seat can proceed, and work stops whether the pressure came from inside this container or from a neighbour sharing the host - a seat starved by a neighbour is exactly the case only the host vantage can see, and it is no less unusable for not being at fault.
The cgroup file answers "am I the cause", which is an attribution question, and attribution already has an owner: the process the alarm names, and `docs/memory-attribution.md`.
It is not read today.
It is the obvious input for a later refinement that would tell a seat drowning in its own work apart from one drowning in a neighbour's, and it is recorded here so that refinement starts from a measurement rather than a guess.

The process this condition **names** is the largest **resident** process, not the largest grower.
In the shape it exists for, the memory was taken hours earlier and nothing is growing, so a growth ranking would name nobody at exactly the moment somebody needs naming.

## How the thresholds were chosen

All three come from measurement on this host, not from preference.

### The measured distribution

Sampled every 60 seconds while the fleet ran ordinary work - 10 live agents, plus lint, the test suite, repository-wide greps and git object churn driven deliberately - on 2026-08-13, on a machine with 23,456 MiB total and no swap:
That measurement predates the swapfile and calibrates ordinary RAM headroom, not swap exhaustion.

| Reading | Ordinary busy operation |
| ------- | ----------------------- |
| Available memory | min 14,656 MiB, median 16,066 MiB |
| Fastest single growing process | median 3.6 MiB/min, p90 15.3 MiB/min, **max 31.5 MiB/min** |
| Host memory stall (`some avg10`) | 0.00 throughout |

For contrast, from the same instrument while a runaway was deliberately driven: 451 to 1,326 MiB/min.

### Sampling window: 270 to 1,260 seconds

The sampling window was re-measured on this host on 2026-08-23 after four alarm readings within about ten minutes contradicted one another: 60, 0, 148, and about 7 MiB/min.
The 148 MiB/min reading extrapolated the whole machine's RAM headroom into an 81.9-minute horizon even though the sample interval was only seconds long.

Seven independent reads of `/proc/meminfo` every 45 seconds from 20:17:39 through 20:22:09 put `MemAvailable` between 12,164 and 12,200 MiB.
The full 270-second window gained 31 MiB and the entire low-to-high band was 36 MiB, or 0.30% of available memory.
The **270-second minimum** is that complete measured window: a shorter interval is scoped and can produce neither a rate nor a horizon.

The alarm's real invocation path is the authenticated `state/memory-alarm.check.sh` entry written by `bin/fm-memory-alarm.sh --arm` and run by `bin/fm-watch.sh`.
The watcher makes checks due after 300 seconds and observes that due time on its 15-second loop, so one base scheduling slot is at most 315 seconds before time spent in the sequential checks.
On the measured home the stored sample nevertheless reached 926 seconds, just short of three such 315-second slots, and the old 900-second ceiling reported the growth instrument blind.
The **1,260-second maximum** is four 315-second slots, leaving one further full slot beyond that measured delay without accepting a sample indefinitely.
A sample older than 1,260 seconds is never divided by, and the next section owns what happens to it instead.

### A stored sample this run cannot use

A sample past the ceiling above, or corrupt, or dated in the future, is not a growth measurement.
It was also, until 2026-08-30, reported as a broken instrument: the reading marked `growth-sample` unmeasured, exited 3, and the alarm said it had gone blind.

That was measured to be wrong for the commonest cause of it.
A peer seat on a WSL2 laptop whose virtual machine freezes when idle recorded its own check ticks every 305 seconds broken by two holes, 03:51:01Z to 09:21:50Z and 09:32:04Z to 11:00:27Z, and the blind report fired on the first tick after each hole.
Its durable wake queue was empty across both holes and the watcher survived under the same process, so nothing was actually broken: the machine had simply not been running, and it came back holding a sample hours too old to divide by.
That reading is one seat on one host, and a laptop that suspends is not a machine that thrashes swap, so it is adjacent evidence rather than this fleet's own cause.
It also disproves the theory that seat's own 2026-08-20 records offered - that the per-check sweep pauses once a check produces a wake and does not resume until that wake is drained - as the cause of those two instances, because the holes predate their own wakes.
That mechanism is not disproved in general and that code path is still unexamined.

The captain's decision on 2026-08-30 was that **the blind path takes a fresh sample** rather than only reporting an absent or stale one.
Widening the freshness window was the other candidate and was rejected on the same evidence: no window that could span a multi-hour host freeze would still be short enough to divide a rate by.

So an unusable stored sample is now **discarded and replaced with this run's own**, and growth for that run is reported as **scope** rather than as blindness.
That is not a softer verdict for the same state.
It is the state a first run on a new home has always been in, which this reading has always reported as scope and exited 0 for: a known absence rather than a broken instrument.
The alarm still does not judge the horizon condition on such a run, still says in its verdict which conditions it actually judged, and still refuses to declare a shortage over on a poll whose growth it could not compare.

**It costs nothing and cannot hang.**
The fresh sample is the process table this run had already read and was already about to store.
There is no second read, no wait, and no new failure mode.

**A fresh sample that fails is still unmeasured**, held by three separate mechanisms rather than by the caller remembering to check:

- `--no-store` takes no fresh sample, so nothing replaces the unusable prior and the next run would be just as blind.
  The reason stays unmeasured there, which is also why `fm-memory-alarm.sh --status` and its detect mode can honestly disagree about the same machine: `--status` is deliberately forbidden from advancing the sample it is reading.
- A sample path that is not a regular file stays unmeasured whatever the mode.
  Storing writes aside and moves into place, and moving a file onto a directory lands it inside that directory, so such a prior would survive every replacement and the instrument would be blind for good while reporting itself merely scoped.
  It is reported under its own unmeasured input, `growth-sample-path`, and the alarm keys on that name: the horizon enters the watch set, and the poll says the machine is only partly watched.
  An aged, corrupt or future-dated prior keeps the input name `growth-sample` and stays scope, because a storing poll repairs it.
- A replacement that could not be written is reported as `sample-storage` and makes the whole reading incomplete.
  It also settles the growth verdict itself, which is the point: scope is earned by the NEXT run being better placed than this one, and only this run's sample landing makes it so.
  So the two scope verdicts that rest on that promise - an unusable prior this run meant to replace, and a first run with no sample at all - are provisional until the store has been attempted, and a store that did not land turns them into the unmeasured input `growth-sample-store`.
  The alarm keys on that name too: the horizon enters the watch set and the poll says the machine is only partly watched, rather than the alarm going silent for as long as the state directory stays unwritable.
  A run that stored keeps the scope verdict and its wording unchanged.

**What this does not cover.**
The gap itself is still not reported by this alarm.
A machine that was frozen for five hours comes back and reads healthy, and nothing here says it was gone, because while it was gone there was no seat to say it to.
`fm-memory-alarm.sh --armed` is the instrument for that, and it answers only at session start.

### Horizon: 15 minutes

The watcher sweeps `state/*.check.sh` every 300 seconds, so the alarm reads the machine every 5 minutes.
The horizon is **three times that cadence**, so a crossing is seen at least twice before the RAM headroom it predicts is gone.
A horizon at or below the sweep interval could take the machine from silent to reclaim or swap pressure between two polls without ever firing.

**What would have to happen to cross it:** at the lowest headroom ordinary work produced (14,656 MiB), sustained growth of **977 MiB/min** across everything running.
The fastest growth ordinary work produced was 31.5 MiB/min, so the bar sits **31 times above** measured ordinary behaviour - and the deliberately driven runaway cleared it comfortably.

### Stall: gate 1.00, window 7200 seconds

This condition is the only one of the three that does not decide on a level, and the reason is measured rather than preferred.

**It ships with this gate and this window in force, not switched off** - any statement that it ships unconfigured is stale and describes an earlier commit on this branch.
Host memory stall at or above `full avg60` 1.00 starts a clock, and only a run held continuously past 7,200 seconds crosses.
The level alone means nothing, which is the point: ordinary heavy work goes far over the gate and then **finishes**, so it never reaches the window, while the measured starvation ran 21h45m.
Both numbers are derived below from measurements taken on this seat and can be re-taken.
They are the captain's decision of 2026-08-28, "take yachts persistence route", answering a filed question that carried the measurements, three options and a recommendation.

A later record of 2026-08-30 named a different pair on a different averaging window - `full avg10` above 60 held for 30 continuous seconds - and it does **not** supersede the shipped pair: it was put back to the captain on 2026-09-01 and he confirmed them, "take the persistence route, the shipped numbers stand".
The measurement that makes that legible: this seat under nothing but this repository's own tooling peaked at `full avg10` 49.45 while never coming within 8.9 GB of the alarm's floor and recovering the moment the load stopped, so 60 on the ten-second window sits only 1.21 times above a measured healthy peak - and ordinary work here already held the much lower shipped gate for 216 continuous seconds, seven times the 30 seconds that pair would have required.

#### Why no level works

The quiet readings looked decisive at first.
`yacht` sampled cumulative full memory stall as a share of uptime across five vantages on 2026-08-28:

| Seat | Full memory stall / uptime | Share |
| ---- | -------------------------- | ----- |
| `tugboat-cloud`, during and after the starvation, 4 cores / 7,746 MiB | 31,352.1 s / 83,071.1 s | **37.7413%** |
| a 12-core / 23,456 MiB seat, 21.3 days uptime | 332.4 s / 1,840,829.2 s | 0.0181% |
| an 8-core / 15,604 MiB seat, 7.6 days uptime | 6.8 s / 652,629.9 s | 0.0010% |
| a WSL seat | 0.0 s / 3,525.9 s | 0.0000% - see the readability trap above |

**Windowed** `memory full` across every vantage at that moment read `avg10`, `avg60` and `avg300` all at **0.00**, except `tugboat`'s `avg300=0.02`.
That looked like a quiet band of 0.00 to 0.02 against an incident at 37.7%, and a threshold in the low single digits looked defensible.
Every one of those readings was taken at **low load**.

Then the load was applied.
Measured on `coditan-vessel` on 2026-08-28 - 12 cores, 23,456 MiB, 32 GiB swap - driving this repository's own tooling and nothing else: four concurrent `bin/fm-lint.sh` runs, the memory suites in a loop, repository-wide greps, and `git log -p` churn.
No balloon, no ceiling, no swap driver.

| Reading | Peak |
| ------- | ---- |
| `full avg60` | **29.30** |
| `full avg10` | 49.45 |
| `some avg60` | 33.32 |
| load, 12 cores | 25.68 |
| **minimum RAM headroom across the entire run** | **11,325 MiB** |

**29.30 against the incident's 37.74**, on a seat that never came within 8.9 GB of the alarm's own floor and recovered the moment the load stopped.
The bands overlap, so no level fires on one and not the other.
A draft of this condition shipped 2.00 on the low-load evidence alone; that value is measured false-firing here at fourteen times over.

#### What does separate them

Ordinary work **finishes**.
The healthy seat above went quiet the instant its load stopped.
The incident ran 21 hours 45 minutes and was still going when somebody intervened.
That is the discriminator, and it is `yacht`'s argument.

So the level is demoted to a **gate** - it decides only whether this machine counts as stalling at all - and the **window** decides whether that stalling means anything.

#### The gate: `full avg60` at or above 1.00

Fifty times the top of the measured windowed quiet band (0.02), and far below anything either a busy seat (29.30) or the incident (37.74) produced.
It is deliberately easy to cross: crossing it starts a clock and nothing more.

#### The window: 7,200 seconds, from two measurements

**The bound the captain named** - the longest continuous heavy job this repository can produce.
Measured on `coditan-vessel` on 2026-08-28, running the two jobs CI runs, back to back, which is also what a local validation run does:

```
$ time bin/fm-lint.sh              # rc=0
1080s
$ time bin/fm-test-run.sh --all    # 162 test scripts
3231s
                                   continuous total 4311s  (1h11m51s)
```

Host memory stall was sampled every 5 seconds throughout all 4,311 seconds of it.
**Peak `full avg60`: 0.43.**
The repository's own heaviest legitimate job, run end to end, never reached the gate at all.

**What did reach the gate**, in the four-way pile-up above that peaked at 29.30: the longest continuous stretch at or above 1.00 was **216 seconds**.

**7,200 seconds is 1.67 times the measured 4,311-second job, and 33 times the longest stretch any ordinary work was measured holding the gate.**
At the watcher's 300-second cadence it is 24 consecutive polls.

#### What the window costs, stated plainly

Two hours of a starvation before anything is said.
Against the incident that motivated this - 21 hours 45 minutes, with every instrument reporting ok throughout - that is 9% of it.
Against a starvation shorter than two hours, this condition says nothing at all, and that is a deliberate trade recorded under what the alarm cannot see.

#### What this still does not rest on

**The incident figure is a cumulative counter, not a windowed reading.**
`/proc/pressure/*`'s `total=` is monotonic since boot, and nothing on `tugboat-cloud` records pressure-stall over time, so **no `avg60` survives from any moment inside the incident** and there is no curve.
The 37.74% is an average over a whole 22.9-hour boot.

**Its attribution is reasoning, not measurement.**
The leak ran about 22 hours of a 22.9-hour boot, post-repair windowed readings are zero, and the recorded quiet baseline is 0.00 under deliberate heavy load, so no ordinary-operation source could have accumulated 34,627 seconds of stall on that boot.
`tugboat-cloud` is explicit that this is not a per-minute attribution they can make, and it is not claimed as one here.

**The duration side has one incident behind it, not an experiment.**
That ordinary work finishes and a starvation does not is measured on this seat and observed once on `tugboat`'s.
A deliberate swap-thrash reproduction, held long enough to produce a windowed curve, is still outstanding and is what would turn the loud end from an after-the-fact counter into a measurement.

### Floor: 10.2% of total RAM

**What ships is the share, not the number.**
The floor was measured at 2,400 MiB on the 23,456 MiB calibration host, which is 10.2% of that machine's RAM and **6.1 times below** the lowest headroom ordinary busy operation reached there.
The alarm reads `MemTotal` on every poll already, so it derives the floor as that same share of whatever machine it is actually on: 2,400 MiB on the calibration host, 793 MiB on a 7,746 MiB one.

**What would have to happen to cross it on the calibration host:** from that busy low, something would have to take a further **12,256 MiB** without the horizon condition having fired first - which is why the floor is a backstop rather than the primary trigger.
It exists for the shapes the horizon cannot see: memory taken by processes below the tracking floor, by many small processes at once, or by something that arrives and consumes it entirely between two samples.

**Why the share rather than the poll-cadence distance.**
The record holds two candidate derivations and only one of them is measured.
The distance a poll cadence must cover is the better argument, but the number it needs - how much memory ordinary work takes between two 300-second polls - has never been measured in this fleet on any host, so a floor derived from it would be a preference wearing a derivation's clothes.
The share is measured: it is exactly the relationship the 2,400 MiB stood in to its own host, carried across unchanged.

**What the share does not establish**, and the crossing line says so rather than leaving it to be assumed: that this fleet's ordinary busy headroom is itself proportional to machine size.
Only one host has an ordinary-operation baseline.
The share transfers the calibration honestly; it does not verify it anywhere else.

**`FM_MEMORY_ALARM_FLOOR_MIB` still wins.**
A home that sets it gets that floor, and every verdict says the floor was configured rather than derived and names what the derivation would have given.
A value that is not a positive number of MiB is a typo rather than a choice, so it falls back to the derivation and every verdict says that too - the same way an unusable stall gate does.

**When the total cannot be read**, the floor cannot be derived from it.
`MemAvailable` is readable independently, so the condition keeps working on the 2,400 MiB calibration figure - and names it as **inherited here rather than derived**, because a margin nobody restates after a host move is the exact failure this derivation replaced.

### Recovery margin: 1.25

Leaving the crossed state requires clearing **all three** conditions by a quarter, so a machine sitting at the line reports once instead of alternating.
Headroom and horizon clear it by beating their thresholds by that multiple.
The stall condition clears it in the other arithmetic direction, because it crosses on duration rather than on a level: the run multiplied by the margin must still fit inside the window.
Recovery is deliberately harder than crossing.

## What these numbers are worth on a different machine

Every threshold above was measured on one host.
Which of the three conditions is actually carrying the warning depends on the machine, and until 2026-08-30 the alarm did not know which machine it was on.

**With swap**, a shortage degrades.
`MemAvailable` counts only memory available without swapping, so it reads healthy while the machine thrashes.
Failure is slow and silent, and the stall condition is the only one of the three that can see it.
That is the whole finding this document's 2026-08-27 evidence section records.

**Without swap**, there is no degrading stretch at all.
The machine runs, and then the kernel kills something.
Headroom is honest there and the distance to the floor is the entire warning, because there is no thrashing stretch for the stall condition to see and nothing left to extrapolate once the kill lands.

So one set of numbers cannot be right for both shapes, and the floor is where that bites.
The floor was derived twice over as a property of **its** host: 2,400 MiB is 10.2% of that machine's 23,456 MiB, and 6.1 times below the lowest RAM headroom ordinary busy work reached there.
The absolute figure does not travel.
The same 2,400 MiB is **31.0%** of a 7,746 MiB host, where it stops being a backstop below ordinary operation and becomes a line ordinary operation may sit near.

This was measured happening rather than predicted.
On 2026-09-04, across roughly four hours on a 7,746 MiB seat with 12 GiB of swap, the headroom condition crossed and self-recovered six times - shortages of 33m8s, 5m15s, 12m4s, 5m19s and 5m6s among them - while `memory.events` reported `oom_kill 0` throughout, every lane kept working, and every crossing cleared on its own.
A single code check on this repository routinely takes 1-3 GB and was measured at 3,860 MiB, half that machine in one process, so ordinary validation lanes cross a 31% floor as a matter of course.
The condition this document calls a backstop had become the one that fired most.

**The share is what travels, so that is what ships**, and the "Floor" section above owns the derivation.
The margin also has to be *stated* on every machine, not only the swapless one: the inherited 2,400 MiB sat unremarked on this host precisely because the note that would have named it fired only where there was no swap.

### What ships, and what deliberately does not

The alarm now reads `MemTotal` and `SwapTotal` from the same reading it already takes, and states in its own voice what its margin is worth on the machine it is on.
On a machine with swap it says that healthy RAM headroom is not evidence the machine is healthy and that the stall condition is the one that answers that.
On a machine with no swap it says there is no degrading stretch below the floor, gives the floor's share of **this** machine's RAM, and says plainly that no ordinary-headroom baseline has been measured at that size.
Every crossing, on every shape, states where its own floor came from.
A `SwapTotal` that could not be read is reported as unread, never as a machine with no swap; those are opposite findings and collapsing them would be the substituted zero this alarm exists to refuse.

**No threshold moved, and no condition changed when it fires.**
`test_reading_the_shape_moves_no_threshold` in `tests/fm-memory-alarm.test.sh` holds that: the same headroom, growth and stall figures must produce the same crossing and the same silence on both shapes.

**A swapless-specific floor is still not invented, because the evidence still does not support one.**
The floor now derives from total RAM on every machine, whatever its shape.
That was originally set aside on the grounds that 10.2% of 7,746 MiB is 793 MiB, which is *looser in absolute terms* on the machine with the least warning.
What the four hours above settled is that the alternative is not a tighter warning but a permanent one: a floor that sits inside ordinary operation fires during ordinary work and stops being read at all, which is less warning rather than more.

The other derivation, **the floor as a distance the poll cadence must cover**, remains the better argument and remains unmeasured: the number it needs is how much memory ordinary work on a small host consumes between two 300-second polls, and that has never been measured on such a host in this fleet.
A floor derived from it today would be a preference wearing a derivation's clothes.

What the record does hold is one reading from a 7,746 MiB host: `MemAvailable` sat at 3,575 to 3,578 MiB throughout the 2026-08-27 incident, while that machine was unusable.
That is 4.5 times the 793 MiB the share derives there - and it was 1.49 times the 2,400 MiB that used to be applied there, against the 6.1 times the floor sits below ordinary busy headroom on the calibration host.
It is a single reading from a degraded machine and not an ordinary-operation baseline, so it does not set a floor either - but it is enough to say the floor's stated safety property is unverified at that host size rather than merely untested.

**What would settle it** is the same measurement the floor already rests on, taken again on the destination: `MemAvailable` sampled every 60 seconds through a deliberately driven busy period of this fleet's own work on the 7,746 MiB host, giving the minimum and median ordinary headroom there.
The floor then follows from the same rule that produced 2,400 MiB, rather than from a share carried across.
Until that exists, the alarm derives the share, reports the shape, and states the gap in its own crossing line.

### The container's own cap, which is not in this branch

The alarm reports on the **host**.
Inside a container with its own memory cap, the number that matters is the cgroup's: this seat runs capped at 8.00 GiB inside a 23,456 MiB host and can exhaust its own cap while the host reads perfectly fine.

That is left out of this branch deliberately, and it is its own piece of work.
A cap-relative headroom condition is a **fourth condition** with its own floor, and it would need its own ordinary-operation baseline measured inside the cap, which does not exist.
Adding it on one datapoint is the same invented number this section just refused for the swapless floor.
The vantage question also already has a measured owner: "Which pressure a containerised seat reads, and why" above records the cgroup pressure file as the obvious input for a later refinement, and this seat's separate container blindness is filed as `fm-memory-alarm-blind-forever-in-container`.
Both belong together, and neither belongs here.

## What the alarm cannot see

Stated because a limit nobody wrote down is one somebody will later assume away.

- **A brand-new runaway is invisible to the horizon on its first poll.**
  Growth is measured between two stored samples, so a process that did not exist at the previous sample has no growth yet, however fast it is climbing.
  At a 300-second cadence that is up to 5 minutes of blindness to the growth of something that just appeared, and it is the main reason the headroom floor exists.
  `tests/fm-memory-alarm-crossing-e2e.test.sh` reproduces this deliberately rather than hiding it: the first poll that sees the runaway is required to stay silent.
- **It sees only what the reading attributes.**
  A process under an account whose firstmate installation this run cannot read is named and reported as unattributed with the reason, never given an owner no record names.
  That boundary belongs to `bin/fm-memory-reading.sh` and `docs/memory-attribution.md`.
- **It does not predict when swap will be exhausted.**
  The reader reports `SwapTotal` and `SwapFree`, and it fails visibly when configured swap lacks a free reading.
  The alarm deliberately does not add `SwapFree` to the horizon, because waiting for RAM plus swap exhaustion would turn an early warning into a late kill countdown.
  It still sets no threshold on swap-in/out or swap-free rates, because no ordinary baseline has been measured for those; the stall condition reads the wait those rates produce instead, and the crossing line reports swap in use as evidence beside it rather than as a trigger.
- **The stall condition does not say what the machine is stalling on.**
  Pressure-stall counts time spent waiting on memory, and page-cache refault and swap-in both land in the same number.
  A crossing therefore means work is blocked on memory, not specifically that swap is thrashing - which is why the line reports the swap figure separately for the reader to weigh rather than asserting it as the cause.
- **It reads a sixty-second window every five minutes, so a short starvation can fall between two polls.**
  The incident it was built for lasted 21 hours 45 minutes, so this costs nothing there.
  An episode shorter than the gap between polls is a real blind spot.
- **It says nothing about a starvation shorter than the window.**
  The stall condition needs two hours of continuous stalling before it crosses, because no level separates a busy machine from a starving one and duration is what does: see "Stall: gate 1.00, window 7200 seconds".
  A machine that is unusable for an hour and then recovers passes this condition in silence, and that is the price of not firing every time somebody runs the linter.
- **A home can switch the stall condition off, and one that has is told so.**
  Setting the gate to the empty string leaves the condition unconfigured; it then fires nothing, and every verdict says this machine is not being watched for memory stall rather than leaving the gap silent.
- **A memory account that is flat while nothing else has accounted pressure either is taken at face value.**
  The positive readability test needs a live io counter as its control.
  On a machine where both accounts are still at zero - a fresh boot, or a container with no disk activity - a dead memory account and a genuinely quiet one are indistinguishable, and the reading reports the zeros.
  A control that could not be read at all is a third state and not the same as one that read zero, so the reading names which of the three it was in `stall.io_control` (`live`, `flat`, or `unreadable`) rather than letting an instrument nobody could read pass for a counter that answered.
  It still reports the zeros in the `unreadable` case, because a control it could not consult is not evidence against the account it was meant to check.
- **A host that has genuinely never stalled on memory is reported as unmeasured rather than calm.**
  The positive readability test condemns the memory account when its cumulative some and full totals are both zero beside a live io counter.
  A host with pressure accounting enabled that has truly never stalled on memory - no eviction, no refault, no direct reclaim - while doing ordinary disk IO reads exactly the same as a kernel that accounts pressure but not memory pressure, so the reading calls that account unmeasured and the alarm says on every poll that it cannot judge stall on that machine.
  This is a deliberate accepted trade rather than an oversight: it never produces a false crossing, and it self-heals on the first microsecond of real memory stall the host ever records, after which the alarm announces that it can see the machine again.
  The alternative - reading a zero beside a live disk counter as calm - is the substituted zero this alarm exists to refuse.
- **The stall condition is host-wide, and so is the process it names.**
  It reads `/proc/pressure/memory`, so a stall generated inside one container or cgroup is reported as the machine stalling.
  The process it names is the largest resident one the reading can see, which is the best available answer to who to talk to and not proof of who caused the wait.
- **It does not report that the machine was gone.**
  A host that was suspended or frozen for hours comes back, replaces the stored sample it could no longer use, and reads healthy.
  Nothing in the alarm says it was away, because while it was away there was no seat to say it to.
  `--armed` is the instrument for that and it answers only at session start.
- **Its floor is calibrated for one host size, and it says so rather than adjusting.**
  See "What these numbers are worth on a different machine" above.
  On a small host with no swap the floor is a much larger share of RAM than the share it was derived at, no ordinary-headroom baseline has been measured at that size, and the alarm reports that gap instead of inventing a number to close it.
- **It measures the host, not this container's own cap.**
  A seat can exhaust its own cgroup limit while the host reads healthy, and no condition here sees that.
- **It is a call for a decision, not a decision taken.**
  Nothing is limited or killed, so a crossing that nobody acts on ends in exactly the state it would have ended in without the alarm.
- **A reading it could not take is reported as blindness, never as an all-clear**, and a shortage is never declared over by a poll that could not re-evaluate the condition that raised it.
  Pressure-stall is not present on every kernel or in every container, and where it is present it is not always accounted.
  Where `/proc/pressure/memory` is absent, unreadable, or provably not accounting, the reader marks it unmeasured, the reading is incomplete, and the alarm reports that it could not see rather than that the machine is fine.
  A calm verdict names the conditions it actually judged, so "all three read clear" can be told apart from "one of them was never evaluated", and a stall that could not be read is never printed as `0.00`.
  Which conditions the alarm is not watching is itself carried in `state/memory-alarm.state` as a third field and in every `data/memory-alarm.log` line as `watch=`, so a change in that set is a transition and is spoken once on the watcher's channel, exactly as a crossing or a recovery is.
  A condition enters that set because its instrument could not be read or because the home deliberately left its gate unconfigured, and for no other reason - those are the two ways a condition stops being watched and does not start again by itself.
  A condition the alarm is watching but could not judge this run is not in it: growth the alarm could not compare because the stored sample was absent, too young, too old or unreadable is scope rather than blindness, is repaired by the next poll that stores a sample, and never enters it.
  The exception is the growth failure no later poll repairs - a sample path no replacement can be written over, and a replacement that could not be written at all - which is blindness and does enter the set; "A stored sample this run cannot use" above owns which is which.
  So an empty set says every condition is being watched, which is a narrower claim than every condition having been judged on that poll, and the alarm says only the narrower thing.
  A home whose memory-stall account can never be read therefore says so once when it starts and then goes quiet about it, rather than either nagging on every poll or passing a partly watched machine off as a watched one.
  A recovery, by contrast, is held back only by the conditions that RAISED the crossing, and each of them holds it until a poll re-reads it and finds it clear of its threshold by the recovery margin.
  An unmeasured input no condition uses never holds one back - a container with no cgroup tree recovers as any other host does - and neither does a condition that is blind but never crossed, so a host whose memory-stall account can never be read still reports a headroom shortage as ended, with the duration it lasted.
  The set of conditions that raised the crossing is carried in `state/memory-alarm.state` as a fourth field for exactly that reason, and the shortage's clock keeps running across a poll that could not re-judge it, because a shortage nobody could measure did not thereby end.
  That set empties on exactly one poll: the one whose outcome announces the recovery, which is the first to reach calm with every raiser re-read and found clear of its threshold by the recovery margin.
  Releasing a raiser and announcing the recovery are one decision rather than two, so a poll that says nothing - a machine merely hovering back under the line, a change of watch, a lapse into "cannot tell" - cannot end a shortage quietly and leave a later poll with nothing to recognise.
  The one exception runs the other way: a stall raiser recorded while a gate was configured can never be re-read once the gate is emptied, so it stops holding the recovery back rather than pinning the home in "cannot tell" for ever.
  It is let go rather than cleared, and it keeps appearing in the watch set, so nothing about it passes for calm.
  Blindness is per-condition and never blanket, though: an incomplete reading still yields the verdict of every condition whose own input was present, names every input it could not read alongside that verdict, and says on the same line that it is not a full all-clear.
  RAM headroom is the single exception, because the floor measures it and the horizon divides by it: a reading without it leaves nothing to judge at all.
  So `fm-memory-alarm.sh --status` exits 3 only when NO condition could be judged, 0 when at least one was judged and none crossed, and 4 when one crossed.
  This did make recovery easier in one direction and harder in another, and both halves are worth stating.
  Easier: a headroom or horizon crossing can now be declared over on a host where an unrelated condition is permanently blind, which before this change could never happen at all, because the old guard blocked recovery from ANY crossing whenever growth could not be compared.
  Harder: the crossing is now carried in the state record and survives every poll that does not announce its end, so a raiser is cleared only by the reading that actually looked at it again, found it clear of its threshold by the recovery margin, and said so, however many polls that takes.
  The justification for the first half is the second: a condition that never raised the alarm says nothing about whether the shortage is over, while one that did says everything, and it is now held to that for as long as the shortage lasts.

## Evidence

### It fires on a real crossing

Driven on 2026-08-13 by a process allocating at roughly 20 MiB/s to a hard 2,200 MiB cap, with 16 GB RAM headroom available on the host throughout:

```
--- poll A (first sighting) ---
(silent)
--- poll B ---
MEMORY_ALARM: this machine is running out of RAM headroom - growth across the
running work totals 1185 MiB/min, which would use up the 14628 MiB RAM headroom
still available without swapping in about 12.3 minutes. Largest grower: python3
balloon.py (pid 1256767), account coditan, serving task
fleet-host-protection-after-reaper-panel-memory-ceiling-alarm (ship,
firstmate-fork), growing 1184 MiB/min. Nothing has been limited or killed.
--- poll C (still crossed) ---
(silent)
--- poll D (runaway gone) ---
MEMORY_ALARM: recovered - 16080 MiB RAM headroom available, growth 8 MiB/min. The shortage lasted 2m28s.
--- poll E ---
(silent)
```

Both transitions were recorded in `data/memory-alarm.log`, each carrying the evidence it was decided on.
Quoted as they were written on 2026-08-13, before the stall condition and its `watch=` field existed:

```
2026-08-13T20:10:39Z  ok -> crossed  14628 MiB RAM headroom available  1185 MiB/min growth  12.3 minutes left  python3 balloon.py (pid 1256767), account coditan, serving task ... (ship, firstmate-fork), growing 1184 MiB/min
2026-08-13T20:13:07Z  crossed -> ok  16080 MiB RAM headroom available     8 MiB/min growth               ...
```

A record written today carries two further fields between the growth figures and the named process: the stall reading with the run behind it, and `watch=`, which is `watch=all` when the alarm was watching all three conditions and `watch=unjudged stall` on a host whose memory-stall account cannot be read.

`tests/fm-memory-alarm-crossing-e2e.test.sh` is that proof as a test: it drives a real runaway, sized from the host's own RAM headroom rather than a fixed number, and requires the alarm to fire, name the process and account, record both transitions, and leave the process running.
It refuses to run on a host without generous headroom rather than adding pressure to a machine already under it.

### It does not fire on ordinary busy operation

The same alarm, polled every 30 seconds through a deliberately driven busy period of this fleet's own work - lint, the test suite, repository-wide greps, git object churn, alongside 10 live agents:

Twenty-two consecutive polls at 30-second intervals on 2026-08-13, load between 2.0 and 3.8:

```
  silent avail=16037 MiB load=1.99  memory-alarm: ok - 16041 MiB RAM headroom available, growth 0 MiB/min
  silent avail=16047 MiB load=2.59  memory-alarm: ok - 16049 MiB RAM headroom available, growth 24 MiB/min
  silent avail=16083 MiB load=2.50  memory-alarm: ok - 16095 MiB RAM headroom available, growth 1 MiB/min
  silent avail=15998 MiB load=2.35  memory-alarm: ok - 15999 MiB RAM headroom available, growth 20 MiB/min
  ...
  silent avail=16105 MiB load=2.41  memory-alarm: ok - 16102 MiB RAM headroom available, growth 3 MiB/min
  silent avail=16104 MiB load=2.20  memory-alarm: ok - 16102 MiB RAM headroom available, growth 10 MiB/min

RESULT: the alarm stayed silent through the whole busy period
```

Across those polls: RAM headroom 15,998-16,117 MiB, total growth 0-24 MiB/min.
The horizon condition needed roughly 1,070 MiB/min at that headroom to fire, so the busiest moment of the run sat about 44 times below the bar - and the alarm said nothing, which is the whole point of the margin.
The separate 28-sample survey behind the threshold table above reached the same conclusion from a longer window.

### It sees the shape the other two conditions cannot

On 2026-08-27 a headless browser on `tugboat-cloud` was still alive 21 hours 45 minutes after it started.
One renderer held 2.9 GB resident plus 3.6 GB of swap on a 7.7 GB four-core host, and its 18 processes read about 155 MB/s off disk continuously, roughly 90% of all disk traffic on that machine.
Readings during the incident: load 18.20/18.52/18.92 on 4 cores, iowait 56-71%, 4,245 MiB of swap in use, and six processes in uninterruptible sleep - including the seat's own agent, which is why the terminal read as frozen.

**The alarm was armed, running, and correct not to fire**, and the reason is worth stating exactly because it is a property of the two conditions rather than a bug in either:

- `headroom` compares `MemAvailable` against the floor, which was the shipped 2,400 MiB at the time and would be 793 MiB on that 7,746 MiB host today.
  It read **3,575-3,578 MiB throughout** - comfortably above either.
- `horizon` extrapolates growth across tracked processes.
  The runaway had finished growing 21 hours earlier and was stable, so there was **no growth to extrapolate**.

`MemAvailable` is an estimate of memory available to new applications *without swapping*, so once the pressure had been absorbed into swap it read healthy while the machine was unusable.
A seat could therefore sit at load 18 with 71% iowait and its own agent blocked, and every instrument this fleet owned reported ok - for 22 hours, which is what happened.

That the two conditions cannot see this shape is **derived** from their definitions plus the readings above; it was not established by deliberately reproducing the starvation.
What makes it more than an argument is that the derivation is now asserted rather than asserted-about: `test_the_two_original_conditions_stay_silent_on_that_same_reading` in `tests/fm-memory-alarm.test.sh` feeds the incident's own headroom, growth, swap and stall figures to the alarm with the stall condition disabled and requires it to produce no line at all, while `test_a_machine_already_drowning_in_swap_is_seen` requires the same reading to fire once the condition is enabled.

Both tests drive a run of consecutive polls rather than a single reading, because a single reading is exactly what this condition refuses to decide on.
The stall figures in them are `tugboat-cloud`'s cumulative counters: a 22-hour average rather than a poll-time reading, since no windowed reading survives from inside the incident.
`test_ordinary_heavy_work_goes_over_the_gate_and_never_crosses` is the other half of the pair, holding this seat's own measured 29.30 over the gate for twenty polls and requiring silence.

### An alarm that cannot fail visibly is not an assurance

Both failure directions are exercised rather than argued.
`tests/fm-memory-alarm.test.sh` holds the alarm to the properties that would let it lie.
Each was then removed from the script, one at a time, to confirm the suite actually catches its absence rather than merely passing alongside it.
The positive readability test and the two stored-sample rows are removed from `bin/fm-memory-reading.sh` and caught by `tests/fm-memory-reading.test.sh`; the rest are in the alarm and its own suite:

| Behaviour removed | Caught |
| ----------------- | ------ |
| an incomplete reading reported as ok | yes |
| edge triggering, so a continuing shortage reports on every poll | yes |
| the guard against declaring recovery on growth nobody could compare | yes |
| uncomparable growth printed as a measured zero | yes |
| the `protected` label dropped from the named process | yes |
| the stall condition, so a machine already thrashing reports ok | yes |
| a stall the instrument could not read printed as a measured zero | yes |
| the run reset, so a busy stretch that ended still counted toward the window | yes |
| the polling-continuity guard, so a gap nobody watched was credited as a run | yes |
| the window, so the condition crossed on a level the way the draft did | yes |
| the positive readability test, so a kernel accounting nothing reads calm | yes |
| the replacement rule, so an unusable sample nobody replaced still reads as scope | yes |
| the guard on a sample path no replacement can overwrite, so a permanently blind instrument reads as scope | yes |
| the unread-swap guard, so a machine whose swap could not be read reads as a machine with none | yes |

The suite also asserts the boundary the captain drew around this slice: the alarm contains no path that limits, throttles, or kills, checked against the code with its commentary stripped out, so prose about killing cannot satisfy or break it.
