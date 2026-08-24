# The memory alarm

`bin/fm-memory-alarm.sh` wakes the fleet when `hlr-web-1` is running out of RAM headroom and names the process responsible, its account, and the work it was serving.
It limits nothing, throttles nothing, and kills nothing.

This document owns how its two thresholds were derived, what would have to happen to cross them, and what the alarm cannot see.
The script's own header owns its flags, its states, and its records; nothing here restates them.

## Why there is no ceiling under it

The design this replaced was a cgroup ceiling with an alarm on crossing it.
That was built as far as measuring it and then abandoned on the measurement, because a ceiling on this host is crossed thousands of times by ordinary file reading with 16 GB RAM headroom, and holding a cgroup at one generates memory-stall time on the very reading the alarm consumes.
`docs/memory-ceiling-caveat.md` owns that finding and `bin/fm-memory-ceiling-probe.sh` re-measures it.

The captain's decision after that measurement was to build the alarm on RAM headroom and growth with no cgroup limit at all.
That remains true after the 32 GiB swapfile added on 2026-08-17.
Swap is a shock absorber: it gives anonymous memory somewhere to go and can turn an immediate kill into a slower host, but it does not stop page cache from expanding into a cgroup ceiling and it does not identify the worker that caused the pressure.
A container ceiling is now proposed for this seat, so `docs/memory-ceiling-caveat.md` is active evidence again rather than only history.
The figure in that proposal is 12 GB, which is hlr's proposal from one night's observation on their host and is **unmeasured here**; this seat has since named a different figure, and neither rests on a measurement, so no number in this document is evidence for a ceiling.
The measurement that would settle it is recorded per-pane peaks - what a pane actually reached, rather than what one happened to be watched reaching.
The ceiling must be re-measured before it is fitted, not inferred safe from the presence of swap.

Because nothing is limited, nothing can be throttled - so the requirement that the wake-delivery listener and the supervision watcher are never throttled is met by there being no mechanism here that could reach them, or anything else.
The reading's `protected` label on the wake-delivery listener is still carried into everything the alarm prints, so nothing downstream inherits a name without it.

## The two conditions

| Condition | Crosses when | What it is for |
| --------- | ------------ | -------------- |
| headroom | RAM headroom from `MemAvailable` is below the floor | a backstop, for memory going somewhere no tracked process is visibly growing into |
| horizon | total growth across tracked processes would consume that RAM headroom within the horizon | the primary trigger, and the one that warns rather than confirms |

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

## How the thresholds were chosen

Both come from measurement on this host, not from preference.

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
A sample older than 1,260 seconds remains unmeasured and forces the alarm's existing blindness path rather than becoming an all-clear.

### Horizon: 15 minutes

The watcher sweeps `state/*.check.sh` every 300 seconds, so the alarm reads the machine every 5 minutes.
The horizon is **three times that cadence**, so a crossing is seen at least twice before the RAM headroom it predicts is gone.
A horizon at or below the sweep interval could take the machine from silent to reclaim or swap pressure between two polls without ever firing.

**What would have to happen to cross it:** at the lowest headroom ordinary work produced (14,656 MiB), sustained growth of **977 MiB/min** across everything running.
The fastest growth ordinary work produced was 31.5 MiB/min, so the bar sits **31 times above** measured ordinary behaviour - and the deliberately driven runaway cleared it comfortably.

### Floor: 2,400 MiB

10.2% of this machine's RAM, and **6.1 times below** the lowest headroom ordinary busy operation reached.

**What would have to happen to cross it:** from that busy low, something would have to take a further **12,256 MiB** without the horizon condition having fired first - which is why the floor is a backstop rather than the primary trigger.
It exists for the shapes the horizon cannot see: memory taken by processes below the tracking floor, by many small processes at once, or by something that arrives and consumes it entirely between two samples.

### Recovery margin: 1.25

Leaving the crossed state requires clearing **both** thresholds by a quarter, so a machine sitting at the line reports once instead of alternating.
Recovery is deliberately harder than crossing.

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
  It also does not add a swap-in/out or swap-free threshold in this change: no ordinary baseline has been measured for those rates, and the reading already carries pressure-stall information to inspect when the alarm fires.
- **It is a call for a decision, not a decision taken.**
  Nothing is limited or killed, so a crossing that nobody acts on ends in exactly the state it would have ended in without the alarm.
- **A reading it could not take is reported as blindness, never as an all-clear**, and a shortage is never declared over by a poll that could not re-evaluate the condition that raised it.

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

Both transitions in `data/memory-alarm.log`, each carrying the evidence it was decided on:

```
2026-08-13T20:10:39Z  ok -> crossed  14628 MiB RAM headroom available  1185 MiB/min growth  12.3 minutes left  python3 balloon.py (pid 1256767), account coditan, serving task ... (ship, firstmate-fork), growing 1184 MiB/min
2026-08-13T20:13:07Z  crossed -> ok  16080 MiB RAM headroom available     8 MiB/min growth               ...
```

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

### An alarm that cannot fail visibly is not an assurance

Both failure directions are exercised rather than argued.
`tests/fm-memory-alarm.test.sh` holds the alarm to the properties that would let it lie.
Each was then removed from the script, one at a time, to confirm the suite actually catches its absence rather than merely passing alongside it:

| Behaviour removed | Caught |
| ----------------- | ------ |
| an incomplete reading reported as ok | yes |
| edge triggering, so a continuing shortage reports on every poll | yes |
| the guard against declaring recovery on growth nobody could compare | yes |
| uncomparable growth printed as a measured zero | yes |
| the `protected` label dropped from the named process | yes |

The suite also asserts the boundary the captain drew around this slice: the alarm contains no path that limits, throttles, or kills, checked against the code with its commentary stripped out, so prose about killing cannot satisfy or break it.
