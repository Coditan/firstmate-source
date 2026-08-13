# Attributable memory pressure

`bin/fm-memory-reading.sh` answers "which process is running away with this machine's memory", not "is memory tight".
This document records why that distinction was worth a slice of its own, and the evidence the reading was proven against.
The script's own header owns its flags, its state, and its exact contracts; nothing here restates them.

## Why the reading comes before the ceiling and the alarm

Measured on `hlr-web-1` on 2026-08-12:

| Reading | Value |
| ------- | ----- |
| Swap | none at all |
| cgroup limit on the user slice and on every session | unlimited |
| Out-of-memory daemon (`systemd-oomd`, `earlyoom`, `nohang`) | all inactive |
| Cap on concurrent sessions | none |
| Out-of-memory kills already recorded against the user slice | 1 |
| Headroom at the time of reading | 23.4 GB total, 8.5 GB used, 14.9 GB available |

So the machine is comfortable and completely unbounded, and when that changes nothing on it can say which worker caused it.
An alarm that cannot name a culprit is not actionable, and a ceiling chosen without knowing who spends the memory is a guess.
Both later slices read this instrument, so this one is first.

This predates and is independent of the harness reaper question.

## The defect this reading exists to remove

A reading that found nothing wrong and a reading that failed to look both come back calm.
Anything downstream that cannot tell those apart will eventually report an all-clear it never measured, which is worse than no reading at all.

Every input is therefore named and reports a measured value, `unmeasured` with the concrete reason, or a declared scope reason.
The first line carries the verdict and so does the exit status: **a reading with any unmeasured input never exits 0**.
A zero is never substituted for a measurement that did not happen.

`bin/fm-currency-round.sh` holds the same rule for the same reason, and its header is worth reading alongside this one.

## Scope is a third state, and not the same as unmeasured

`hlr-web-1` has three user accounts - `coditan`, `crew`, `tugboat` - and two firstmate installations.
Accounts and installations do not correspond, so an account is never evidence that an installation exists under it, and a process is never handed an owner no record names.

A task is named only when an installation the run could actually read holds a matching record.
Every reading prints the installations it read, and anything they do not cover is reported unattributed with its reason.

That boundary is permanent and known in advance, so it is reported as declared scope rather than as an instrument failure.
Treating it as unmeasured would make incompleteness the permanent norm and destroy the signal the exit status carries.
The remedy is to run the reading from the other installation too, or to point `--home` at records this account can read.
The captain chose the same scope treatment for an account with no active session slice, an ordinary first run with no stored growth sample, and a stored sample younger than the minimum interval.
Those are known absences or operator cadence, not failed instruments.
If they forced exit 3, the next slice's alarm would learn to discount the failure status it must consume.
The wall-clock and peak-memory cost figures measure the reading itself rather than machine memory.
Their absence on a supported platform is scope, stays visibly unavailable, and does not make the memory reading incomplete.

## The three attribution layers

| Layer | Source | Reach |
| ----- | ------ | ----- |
| Account | the process table | every process when the table is readable; a failed read is unmeasured |
| Account slice total, limit, and stall | that account's own cgroup | every account on this host, across accounts; a blind cgroup tree is unmeasured |
| Task id, kind, and project | task records of the installations this run read | only what those records cover |

Only firstmate holds the third layer, which is why this reading lives here rather than in host configuration.
The first two are never silently promoted into the third.

## Evidence

All of the following was run on `hlr-web-1` on 2026-08-13 against the reading as it stands on this branch.

### Proven against a deliberately runaway process

A self-capping balloon grew to a hard 600 MiB ceiling at roughly 20 MiB/s inside this task's own worktree, held flat, and exited.
The host had ~15.9 GiB available throughout, and the balloon's own shell carried a `ulimit -v` guard, so the runaway was scoped rather than a load test.

During the growth phase:

```
$ ./bin/fm-memory-reading.sh --no-store --interval 12 --largest 4 --growing 4
FASTEST GROWING
   RSS MiB          GROWTH  SIZE TREND PID      COMMAND              ATTRIBUTION
       330 +1200.2 MiB/min  growing    22424    python3 balloon.py   coditan / task fleet-host-protection-after-reaper-panel-memory-attribution (ship, firstmate-fork)
       646   +76.1 MiB/min  growing    2469191  claude               coditan / firstmate home coditan-firstmate
       538   +31.5 MiB/min  growing    3452737  claude               coditan / task fleet-host-protection-after-reaper-panel-memory-attribution (ship, firstmate-fork)
       544   +16.6 MiB/min  growing    3333293  claude               coditan / task fm-delivery-listener-outside-harness (ship, firstmate-fork)
```

The runaway is named first by growth while ranking only fourth by size, which is the whole case for measuring growth: a size ranking alone would have put three ordinary workers above it.
It is attributed to the exact task it was started under, not merely to an account or a pid.

Twenty-two seconds later, the same process holding flat at its ceiling:

```
LARGEST TRACKED PROCESSES
   RSS MiB          GROWTH  SIZE TREND PID      COMMAND              ATTRIBUTION
       656    +9.8 MiB/min  growing    2469191  claude               coditan / firstmate home coditan-firstmate
       610    +0.0 MiB/min  steady     22424    python3 balloon.py   coditan / task fleet-host-protection-after-reaper-panel-memory-attribution (ship, firstmate-fork)
       599    +2.4 MiB/min  steady     294069   claude               crew / UNATTRIBUTED: runs under account crew, which no installation read by this run (from account coditan) covers
```

The same process, now the second largest on the machine, reads `steady` and has left the growth ranking entirely.
Large-but-stable and fast-growing are told apart by the reading, in both directions, on one process.

The third line is the honest case: a 599 MiB worker of another account, named and counted, with no owner invented for it.

### A calm reading and a blind one are not confusable

The sharpest pair, because both look calm:

```
$ FM_MEMORY_PRESSURE=<file with real zero averages> ./bin/fm-memory-reading.sh
memory-reading: complete - every input in scope was measured
  some  avg10=0.00  avg60=0.00
exit 0

$ FM_MEMORY_PRESSURE=<empty file> ./bin/fm-memory-reading.sh
memory-reading: INCOMPLETE - 1 input(s) unmeasured; the numbers below do not add up to an all-clear
  UNMEASURED - see the unmeasured section below
exit 3
```

Every deliberately bad input constructed, and what the reading said:

| Bad input | Exit | Reported as |
| --------- | ---- | ----------- |
| stall file empty | 3 | `stall`: carries no recognisable some/full averages |
| stall file holding unrelated text | 3 | `stall`: carries no recognisable some/full averages |
| stall file absent | 3 | `stall`: this kernel exposes no memory pressure metric |
| headroom file empty | 3 | `headroom`: no usable MemTotal/MemAvailable pair |
| headroom file with a non-numeric MemTotal | 3 | `headroom`: no usable MemTotal/MemAvailable pair |
| headroom file with MemTotal but no MemAvailable | 3 | `headroom`: no usable MemTotal/MemAvailable pair |
| headroom file with no usable SwapTotal | 3 | `headroom`: no usable SwapTotal |
| configured swap with no usable SwapFree | 3 | `headroom`: total shown, free unmeasured |
| process table command fails | 3 | `processes`: the configured process-table command failed |
| process table returns nothing | 3 | `processes`: came back empty, which no live machine produces |
| process table contains a malformed row | 3 | `processes`: the partial table cannot be trusted |
| cgroup tree absent | 3 | `account-slices`: no account's total, limit, or stall was read at all |
| account memory.max neither `max` nor bytes | 3 | named account slice and `memory.max` instrument |
| no installation's records readable | 3 | `task-attribution`: no process can be tied to the work it serves |
| a requested installation's records cannot be read | 3 | `task-attribution`, with the installation retained as an unmeasured source |

The cgroup case was found by constructing it.
A bogus cgroup root originally exited 0, because every account then reported "no active session slice" - the identical wording a genuinely logged-out account produces.
That is the same defect in miniature, so the reading now establishes once whether the tree was readable at all and separates the two.

Growth has its own set, because an unmeasurable growth rate is the easiest thing in the reading to report as zero:

| Condition | Reported as |
| --------- | ----------- |
| no prior sample | scope, "nothing to compare against" - never `+0.0 MiB/min`; exit 0 remains possible |
| stored sample has no usable epoch | `unmeasured` input `growth-sample`; exit 3 |
| stored sample body cannot be read | `unmeasured` input `growth-sample`; never converted into first sightings; exit 3 |
| stored sample contains a malformed process record | `unmeasured` input `growth-sample`; exit 3 |
| stored sample has a valid epoch and no process records | measured empty baseline; current processes are first sightings; exit 0 remains possible |
| stored sample is future-dated | `unmeasured` input `growth-sample`; exit 3 |
| prior sample older than the growth window | `unmeasured` input `growth-sample`, with the age and window; exit 3 |
| interval shorter than the divide-by floor | scope, with the interval and floor; exit 0 remains possible |
| second process-table read fails during `--interval` | `unmeasured` input `growth-sample`; exit 3 |
| the pid now belongs to a later process | per-process `unmeasured`, "different, later process" - never counted as growth |
| the process exited during the reading | reported as `exited`, never silently dropped |

### Cost

Measured over 20 back-to-back runs on the live, busy host:

```
20 runs: wall 6.26 s, user 1.62 s, sys 5.51 s, peak rss 5632 kB
single run: wall 0.34 s, user 0.09 s, sys 0.29 s, peak rss 5504 kB
```

Machine-wide `some` stall accumulated 6698 microseconds across those 20 runs, on a 12-core host, and the 10-second and 60-second stall averages stayed at 0.00 throughout.
One run costs about 0.38 s of CPU and 5.5 MB, against workers that hold hundreds of MB each.

Every reading prints its own wall time and peak memory, so this claim is re-measured on each run rather than asserted once here.

The first draft cost 0.77 s of CPU per run, spent almost entirely on forks: one `awk` per column per row, and one process-table scan per account.
Collapsing the render loops and the per-account totals into single passes halved it.

### Wake delivery is labelled, not ranked

The per-session wake-delivery listener is what makes every other reading arrive at all, and it is small enough to look like cheap prey.
It is labelled `protected` wherever it appears, across both installations on this host:

```
$ ./bin/fm-memory-reading.sh --json | jq -r '.processes[] | select(.protected) | "\(.pid) \(.account) \(.rss_kb)kB \(.attribution.detail)"'
470414  crew    3564kB  wake delivery
2007382 coditan 9456kB  wake delivery
3837804 coditan 4428kB  wake delivery for coditan-firstmate
...
```

Two properties matter and both are tested.

The label is matched against the executed command's own first two argv tokens, not against the command line as a whole.
Workers routinely carry instructions that *mention* these script names - this task's own worker did - and matching anywhere in the command line would label an ordinary 500 MB worker as delivery infrastructure.

The label is positive only.
Its absence is never a licence, because this reading does not know every process that must not be touched, and nothing downstream may read a missing label as permission.

## What this slice deliberately is not

The reading sets no limit, ceiling, or throttle; raises no alarm; kills nothing; and contains no path that could.
The ceiling and its alarm are the next slice, and the escalation to a kill is the last, both separately decided.

`tests/fm-memory-reading.test.sh` enforces that boundary through the executable interface: a sentinel process must survive and fixture control files must remain byte-for-byte unchanged.

It is also not a replacement for the disabled background-shell reaper.
The panel ruled that unjustified at measured load: it only ever killed a 3.8-4.4 MiB helper while real sessions run at hundreds of MiB, and it self-disarms while work is active.

## Portability

The reading is shaped for a Linux host with `/proc` and a systemd cgroup v2 user slice, which is what this fleet runs on.
On a host without them it does not degrade into a confident-looking answer: the missing sources are reported as unmeasured by name and the reading exits non-zero, which is the same contract as any other failed input.
