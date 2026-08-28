# The memory alarm

`bin/fm-memory-alarm.sh` wakes the fleet when `hlr-web-1` is running out of RAM headroom, or is already stalling on memory it has, and names the process responsible, its account, and the work it was serving.
It limits nothing, throttles nothing, and kills nothing.

This document owns how its thresholds were derived, what would have to happen to cross them, why the third condition has no threshold yet, and what the alarm cannot see.
The script's own header owns its flags, its states, and its records; nothing here restates them.

## Why there is no ceiling under it

The design this replaced was a cgroup ceiling with an alarm on crossing it.
That was built as far as measuring it and then abandoned on the measurement, because a ceiling on this host is crossed thousands of times by ordinary file reading with 16 GB RAM headroom, and holding a cgroup at one generates memory-stall time on the very reading the alarm consumes.
`docs/memory-ceiling-caveat.md` owns that finding and `bin/fm-memory-ceiling-probe.sh` re-measures it.
That finding is now load-bearing in a second way, and it grew: the signal a ceiling was measured to manufacture is the same signal this alarm's stall condition would read, and ordinary work on this seat has since been measured driving that signal ten times higher than the probe did, with no ceiling anywhere.
That is a large part of why the stall condition has no threshold; see "Stall: no threshold, and why there is none" below.

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
| stall | host memory pressure-stall `full avg60` is at or above the stall threshold - **no threshold is chosen, so this condition is unconfigured and evaluates nothing** | it is the only reading that could see a machine which is ALREADY unusable rather than about to become so, and it does not yet separate one from a busy one |

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

It reads the **60-second** window rather than the 10-second one.
The alarm polls every 300 seconds, so `avg60` covers six times more of the interval between polls than `avg10` does, and every seat the fleet has sampled measured the same 0.00 on both - so the longer window costs nothing measurable and rejects more.

### Two things the condition deliberately does not trigger on

**Not the cumulative counter.**
`/proc/pressure/*` also carries `total=`, monotonic microseconds of stall since boot, and it is the counter both vessels used to measure the incident after the fact.
It is **evidence only**.
It never falls, so a condition built on it would fire permanently after any past starvation and could never recover: `tugboat-cloud` still reads 37.7% on that counter at load 0.60, fully recovered, with every windowed value at zero.
That is the same recovery-must-be-earned trap this alarm already handles for its other conditions.
The counter is put to one use instead, below, where its never-falling property is exactly what is wanted.

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
A sample older than 1,260 seconds remains unmeasured and forces the alarm's existing blindness path rather than becoming an all-clear.

### Horizon: 15 minutes

The watcher sweeps `state/*.check.sh` every 300 seconds, so the alarm reads the machine every 5 minutes.
The horizon is **three times that cadence**, so a crossing is seen at least twice before the RAM headroom it predicts is gone.
A horizon at or below the sweep interval could take the machine from silent to reclaim or swap pressure between two polls without ever firing.

**What would have to happen to cross it:** at the lowest headroom ordinary work produced (14,656 MiB), sustained growth of **977 MiB/min** across everything running.
The fastest growth ordinary work produced was 31.5 MiB/min, so the bar sits **31 times above** measured ordinary behaviour - and the deliberately driven runaway cleared it comfortably.

### Stall: no threshold, and why there is none

The condition is built, tested and shipped **unconfigured**.
It evaluates nothing until `FM_MEMORY_ALARM_STALL` is set, and while it is unset every verdict says so rather than letting the silence read as cover.
That is not caution about a number somebody could refine later.
On the evidence this fleet now holds, **no threshold on this reading separates a busy machine from a starving one**, and the measurement that shows it was taken here.

#### What the quiet end looked like before it was measured under load

`yacht` sampled cumulative full memory stall as a share of uptime across five vantages on 2026-08-28:

| Seat | Full memory stall / uptime | Share |
| ---- | -------------------------- | ----- |
| `tugboat-cloud`, during and after the starvation, 4 cores / 7,746 MiB | 31,352.1 s / 83,071.1 s | **37.7413%** |
| a 12-core / 23,456 MiB seat, 21.3 days uptime | 332.4 s / 1,840,829.2 s | 0.0181% |
| an 8-core / 15,604 MiB seat, 7.6 days uptime | 6.8 s / 652,629.9 s | 0.0010% |
| a WSL seat | 0.0 s / 3,525.9 s | 0.0000% - see the readability trap above |

**Windowed** `memory full` across every vantage at that moment read `avg10`, `avg60` and `avg300` all at **0.00**, except `tugboat`'s `avg300=0.02`.
The 2026-08-13 fleet survey read `some avg10` 0.00 at every sample under ten live agents plus lint, the test suite, repository-wide greps and git churn.

On that evidence the quiet band looked like 0.00 to 0.02, the incident looked like 37.7%, and a threshold in the low single digits looked defensible - about 100x above quiet and about 19x below the incident.
Every one of those readings was taken at **low load**, and the survey that was not is the only one, on one 23 GiB host, reported at `avg10` only.

#### The measurement that removed the gap

Taken on `coditan-vessel` on 2026-08-28: 12 cores, 23,456 MiB, 32 GiB swap.
The load is this repository's own tooling and nothing else - four concurrent `bin/fm-lint.sh` runs, the memory test suites in a loop, repository-wide greps, and `git log -p` churn.
Nothing allocated deliberately; no balloon, no ceiling, no swap driver.
`/proc/pressure/memory` was sampled every 3 seconds for 330 seconds.

| Reading | Peak |
| ------- | ---- |
| `full avg60` | **29.30** |
| `full avg10` | 49.45 |
| `some avg60` | 33.32 |
| `some avg10` | 57.95 |
| load, 12 cores | 25.68 |
| **minimum RAM headroom across the entire run** | **11,325 MiB** |

The load and the sampling, so this can be run again rather than believed:

```
for n in 1 2 3 4; do ( ./bin/fm-lint.sh >/dev/null 2>&1 ) & done
( for i in $(seq 1 16); do bash tests/fm-memory-alarm.test.sh   >/dev/null 2>&1; done ) &
( for i in $(seq 1 16); do bash tests/fm-memory-reading.test.sh >/dev/null 2>&1; done ) &
( for i in $(seq 1 200); do grep -rI 'memory' . >/dev/null 2>&1; done ) &
( for i in $(seq 1 100); do git log -p -120  >/dev/null 2>&1; done ) &

while :; do
  awk '$1=="full"{print substr($2,7), substr($3,7)}' /proc/pressure/memory
  awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo
  sleep 3
done
```

The peak of the run, `t` seconds from the start of sampling:

```
t       some10   some60   full10   full60   availMiB  load1
297s    14.71    24.59    13.31    21.73    11598     21.83
300s    46.13    31.05    40.87    27.49    11552     25.68
303s    47.19    33.32    40.85    29.30    13206     24.58
306s    31.64    31.18    27.39    27.42    12171     23.17
309s    25.90    30.16    22.43    26.52    12310     23.17
```

The seat was never in trouble.
It never came within 8.9 GB of the alarm's own 2,400 MiB floor, nothing was killed, and every reading fell back to zero when the load stopped.

**29.30 against the incident's 37.74.**
A healthy machine running this fleet's ordinary heavy work reached the same magnitude of memory stall as a machine that was unusable for 22 hours.
The two bands overlap, so there is no value that fires on one and not the other:

- Anything low enough to catch a starvation early fires on a busy afternoon - **2.00 was measured firing here**, at 14x over.
- Anything high enough to clear ordinary work sits at the incident's own magnitude, where it is no longer an early warning of anything and is still not shown to separate.

An earlier draft of this condition shipped 2.00 on exactly the reasoning in the section above.
It is recorded here because the reasoning was sound and the conclusion was wrong, and the only thing that separated them was running the load.

#### Why this is a property of the reading rather than of the threshold

Pressure-stall counts time spent waiting on memory.
It does not distinguish a page-cache refault under heavy file work from a swap-in under starvation, and this fleet's ordinary work is heavy file work: shellcheck across `bin/`, repeated repository-wide greps, git object churn.
`docs/memory-ceiling-caveat.md` recorded the same instrument being driven to 2.76-3.42 by page-cache reclaim alone on a host with 16 GB to spare.
This measurement is that finding at ten times the magnitude, with no ceiling involved.

#### What would have to be measured to settle it

Not a bigger sample of the same thing.
The open question is whether any reading available here separates the two states, and these are the candidates, none of them measured:

- **Duration.** The episodes above decayed within minutes; the incident ran 21 hours 45 minutes. A condition on stall *sustained across consecutive polls* might separate them - but nothing has measured how long an ordinary-work episode can persist, and the run above held stall high for its whole five minutes, which is already two polls apart.
- **Swap-in rate alongside stall.** Stall plus sustained `pswpin` would distinguish refault-from-disk from swap thrash. No ordinary baseline exists for that rate, which is why the alarm never adopted one.
- **The cgroup vantage.** `/sys/fs/cgroup/memory.pressure` is readable here and answers "am I drowning" rather than "is this machine drowning". Whether it separates better is unmeasured.
- **A deliberate swap-thrash reproduction**, which is still outstanding and is the only thing that would give the loud end a windowed curve rather than an after-the-fact counter.

Until one of those is measured, this condition stays unconfigured, and the alarm says on every poll that this machine is not being watched for memory stall.
That is worse than a working condition and better than a number that would have woken the fleet every time somebody ran the linter.

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
  It still sets no threshold on swap-in/out or swap-free rates, because no ordinary baseline has been measured for those; the stall condition reads the wait those rates produce instead, and the crossing line reports swap in use as evidence beside it rather than as a trigger.
- **The stall condition does not say what the machine is stalling on.**
  Pressure-stall counts time spent waiting on memory, and page-cache refault and swap-in both land in the same number.
  A crossing therefore means work is blocked on memory, not specifically that swap is thrashing - which is why the line reports the swap figure separately for the reader to weigh rather than asserting it as the cause.
- **It reads a sixty-second window every five minutes, so a short starvation can fall between two polls.**
  The incident it was built for lasted 21 hours 45 minutes, so this costs nothing there.
  An episode shorter than the gap between polls is a real blind spot.
- **It is not watching for memory stall at all.**
  The stall condition ships unconfigured because no threshold on that reading separates a busy machine from a starving one on the evidence measured so far: see "Stall: no threshold, and why there is none".
  The shape the 2026-08-27 incident took is therefore still unwatched, and the alarm says so on every poll rather than leaving the gap silent.
- **A memory account that is flat while nothing else has accounted pressure either is taken at face value.**
  The positive readability test needs a live io counter as its control.
  On a machine where both accounts are still at zero - a fresh boot, or a container with no disk activity - a dead memory account and a genuinely quiet one are indistinguishable, and the reading reports the zeros.
- **The stall condition is host-wide, and so is the process it names.**
  It reads `/proc/pressure/memory`, so a stall generated inside one container or cgroup is reported as the machine stalling.
  The process it names is the largest resident one the reading can see, which is the best available answer to who to talk to and not proof of who caused the wait.
- **It is a call for a decision, not a decision taken.**
  Nothing is limited or killed, so a crossing that nobody acts on ends in exactly the state it would have ended in without the alarm.
- **A reading it could not take is reported as blindness, never as an all-clear**, and a shortage is never declared over by a poll that could not re-evaluate the condition that raised it.
  Pressure-stall is not present on every kernel or in every container, and where it is present it is not always accounted.
  Where `/proc/pressure/memory` is absent, unreadable, or provably not accounting, the reader marks it unmeasured, the reading is incomplete, and the alarm reports that it could not see rather than that the machine is fine.
  A calm verdict names the conditions it actually judged, so "all three read clear" can be told apart from "one of them was never evaluated", and a stall that could not be read is never printed as `0.00`.

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

### It sees the shape the other two conditions cannot

On 2026-08-27 a headless browser on `tugboat-cloud` was still alive 21 hours 45 minutes after it started.
One renderer held 2.9 GB resident plus 3.6 GB of swap on a 7.7 GB four-core host, and its 18 processes read about 155 MB/s off disk continuously, roughly 90% of all disk traffic on that machine.
Readings during the incident: load 18.20/18.52/18.92 on 4 cores, iowait 56-71%, 4,245 MiB of swap in use, and six processes in uninterruptible sleep - including the seat's own agent, which is why the terminal read as frozen.

**The alarm was armed, running, and correct not to fire**, and the reason is worth stating exactly because it is a property of the two conditions rather than a bug in either:

- `headroom` compares `MemAvailable` against the 2,400 MiB floor.
  It read **3,575-3,578 MiB throughout** - comfortably above it.
- `horizon` extrapolates growth across tracked processes.
  The runaway had finished growing 21 hours earlier and was stable, so there was **no growth to extrapolate**.

`MemAvailable` is an estimate of memory available to new applications *without swapping*, so once the pressure had been absorbed into swap it read healthy while the machine was unusable.
A seat could therefore sit at load 18 with 71% iowait and its own agent blocked, and every instrument this fleet owned reported ok - for 22 hours, which is what happened.

That the two conditions cannot see this shape is **derived** from their definitions plus the readings above; it was not established by deliberately reproducing the starvation.
What makes it more than an argument is that the derivation is now asserted rather than asserted-about: `test_the_two_original_conditions_stay_silent_on_that_same_reading` in `tests/fm-memory-alarm.test.sh` feeds the incident's own headroom, growth, swap and stall figures to the alarm with the stall condition disabled and requires it to produce no line at all, while `test_a_machine_already_drowning_in_swap_is_seen` requires the same reading to fire once the condition is enabled.

Both tests set a stall threshold explicitly, because the shipped alarm has none.
They prove the condition works when a threshold exists; they do not make one defensible, and "Stall: no threshold, and why there is none" above records why none is.
The stall figures in them are `tugboat-cloud`'s cumulative counters: a 22-hour average rather than a poll-time reading, since no windowed reading survives from inside the incident.

### An alarm that cannot fail visibly is not an assurance

Both failure directions are exercised rather than argued.
`tests/fm-memory-alarm.test.sh` holds the alarm to the properties that would let it lie.
Each was then removed from the script, one at a time, to confirm the suite actually catches its absence rather than merely passing alongside it.
The last row is removed from `bin/fm-memory-reading.sh` and caught by `tests/fm-memory-reading.test.sh`; the rest are in the alarm and its own suite:

| Behaviour removed | Caught |
| ----------------- | ------ |
| an incomplete reading reported as ok | yes |
| edge triggering, so a continuing shortage reports on every poll | yes |
| the guard against declaring recovery on growth nobody could compare | yes |
| uncomparable growth printed as a measured zero | yes |
| the `protected` label dropped from the named process | yes |
| the stall condition, so a machine already thrashing reports ok | yes |
| a stall the instrument could not read printed as a measured zero | yes |
| the positive readability test, so a kernel accounting nothing reads calm | yes |

The suite also asserts the boundary the captain drew around this slice: the alarm contains no path that limits, throttles, or kills, checked against the code with its commentary stripped out, so prose about killing cannot satisfy or break it.
