# A memory ceiling on this host can manufacture the pressure it would detect

This slice was to fit a throttling memory ceiling on `hlr-web-1` and alarm on crossing it, naming the offender through `bin/fm-memory-reading.sh`.
It was stopped before any ceiling was fitted, because the hazard the task named up front turned out to be real and measurable rather than theoretical.

The instruction that governs this document was written into the task before the work began: check the hazard explicitly, and if it is real, stop and report rather than tune around it.
`bin/fm-memory-ceiling-probe.sh` is the instrument that answers it, so the finding can be re-measured on this host or any other rather than believed on the strength of this page.

## The hazard, stated before it was measured

A cgroup's memory charge includes its page cache.
Page cache is reclaimable and is still charged to the cgroup.
If page cache alone can reach the ceiling, the kernel holds the cgroup at that ceiling by reclaiming continuously, and that reclaim registers as memory-stall time on `/proc/pressure/memory` - the same reading the alarm above the ceiling would consume.
The first measurement was taken before swap was fitted, but swap changes anonymous-memory pressure more than this file-cache hazard.
Swap gives anonymous memory somewhere to go; it does not move page cache out of the cgroup charge.

The question is therefore not whether a ceiling can be set.
It is whether a ceiling, once set, becomes a permanent generator of the signal the alarm exists to read.

## What was measured

All of the following was run on `hlr-web-1` on 2026-08-13.
The host had no swap configured throughout, and never fell below 13 GB of RAM headroom during any arm.
That no-swap sentence is historical evidence about the run, not a current statement about the host.

### The paired probe

```
$ ./bin/fm-memory-ceiling-probe.sh --scratch <scratch>
memory-ceiling-probe: MANUFACTURED - a 2G ceiling generated memory pressure on a host that had memory to spare
taken 2026-08-13T19:14:43Z on hlr-web-1, no swap configured: correct, there is none

Both arms read a 2048 MiB cold corpus for 30 seconds and allocated almost nothing of their own.
The host never fell below 13053 MiB RAM headroom while they ran.

ARM        CEILING          PEAK_MiB  CROSSINGS   PEAK_STALL     REFAULTS
control    none                 2053          0         0.00            0
ceiling    2G                   2047      54113         4.45      6924685
$ echo $?
4
```

Both arms did the same thing: read a cold file, allocate nothing.
The control arm cached what it read and went quiet.
The ceiling arm was pinned at its limit, crossed that limit 54,113 times, refaulted 6.9 million pages, and drove its own stall reading to 4.45.
The only difference between the two arms is that one had a ceiling.

### The same result sustained, and visible on the host

A 60-second arm against a cold 6 GiB corpus, sampled every 5 seconds, with a 2 GiB ceiling:

```
host before: MemAvailable=16598152 kB  psi some avg10=0.00

    t      cg_MiB    cg_psi_avg10  host_psi_avg10     pgsteal/s     refault/s
    5        2047            0.72            0.54        159564             0
   15        2048            2.38            1.72        255488        255279
   25        2048            3.54            2.76        249804        249868
   35        2047            3.64            3.12        255513        255657
   45        2048            3.98            3.42        252544        252533
   60        2047            3.27            2.80        259430        259423

host after: MemAvailable=16425872 kB  psi some avg10=2.32
```

Pages stolen and pages refaulted run at the same rate, which is the definition of thrashing: every page reclaimed to stay under the ceiling is immediately needed again.
The host's own memory-stall reading went from `0.00` to `3.42` while more than 16 GB RAM headroom stayed available.

The identical workload with no ceiling, run minutes earlier on an equally cold corpus:

```
    t      cg_MiB    cg_psi_avg10  host_psi_avg10     pgsteal/s     refault/s
    5        5747            0.00            0.03         12057             0
   15        6160            0.00            0.25             0             0
   40        6159            0.00            0.01             0             0
```

It cached the corpus, stopped, and stalled for zero of the run.

### The manufactured stall arrives in the instrument the alarm would read

With no ceiling anywhere on the box, `bin/fm-memory-reading.sh` reported:

```
STALL (share of the last 10s/60s spent waiting on memory)
  some  avg10=0.00  avg60=0.05        (at least one task stalled)
```

With one 2 GiB ceiling on one cgroup reading files, and headroom unchanged:

```
HEADROOM
  total 23457 MiB   used 7352 MiB   available 16105 MiB (69%)

STALL (share of the last 10s/60s spent waiting on memory)
  some  avg10=1.32  avg60=0.33        (at least one task stalled)
```

That is the finding in one pair of readings.
The machine has the same 69% RAM headroom in both, and the stall exists only in the second.

### Ordinary file reading crosses the limit thousands of times

A single pass over a 4 GiB corpus inside a 2 GiB ceiling, with 16.4 GB RAM headroom on the host:

| Point | `memory.events` `high` |
| ----- | ---------------------- |
| start | 0 |
| after reading the corpus once | 4,115 |
| after a second pass | 12,306 |

The process allocated no meaningful anonymous memory.
It read a file.
"The limit was crossed" is the event the alarm was to fire on, and ordinary reading produces thousands of them per pass.

## Why a different number does not fix it

The ceiling was offered at four sizes against a corpus larger than each.
In every case `memory.current` settled at the ceiling and stayed there:

| Ceiling | Where `memory.current` settled |
| ------- | ------------------------------ |
| 64 MiB | 63 MiB |
| 256 MiB | 255 MiB |
| 1 GiB | 1023 MiB |
| 2 GiB | 2047 MiB |
| none | 1027 MiB, the size of the corpus, then it stopped |

Page cache expands into whatever ceiling exists.
A higher ceiling is therefore reached by the same ordinary file reading, just later.

The only ceiling page cache cannot reach is one set above what the machine would have let that cgroup hold anyway - at which point global reclaim binds first, the ceiling never binds at all, and it bounds nothing.
That is the second trap the task named: a limit set so high it is unreachable is indistinguishable from a healthy machine.

Both ends of the range are closed on this host, and they are closed by the same mechanism.
This is not a number that was chosen badly; it is a quantity that cannot be bounded usefully here.

The premise holds on this machine rather than being assumed.
At a routine moment `app.slice` held 9629 MiB, of which 5051 MiB was page cache against 2780 MiB of anonymous memory, with 16 GB RAM headroom still available.
More than half the charge a ceiling would bind against is already cache, and nothing but the ceiling itself would stop it growing further.

Swap does not resolve this.
Swap gives anonymous memory somewhere to go under pressure, which this host badly lacks for other reasons, but it does not stop page cache expanding into a ceiling.

## What changed since the measurement

On 2026-08-17, 32 GiB of swap was added to `hlr-web-1` and `vm.swappiness` was deliberately left at 60.
On 2026-08-18 from this seat, `swapon --show --bytes` reported `/swapfile` at 34359734272 bytes, used 0, priority -2, and `/proc/meminfo` reported `SwapTotal: 33554428 kB` and `SwapFree: 33554428 kB`.
The proposed next step is a 12 GB container ceiling for this seat, with its kill order below production services.

That proposal makes this finding current again.
The old probe does not prove the exact 12 GB container ceiling will manufacture pressure after swap was added, because that exact configuration has not been measured.
It does prove the page-cache failure mode is real on this host and that raising the number is not evidence by itself.
This correction did not re-run the probe: a meaningful 12 GB run would need a corpus large enough to exercise that ceiling and would deliberately create reclaim pressure on the live host.
Before the container ceiling is fitted, re-run `bin/fm-memory-ceiling-probe.sh` with a workload size that can actually reach the proposed ceiling, or treat the ceiling's pressure signal as unproven.

## What this does not say

It does not say the reading was wrong or wasted: `bin/fm-memory-reading.sh` is untouched by this and remains correct.
It does not say an alarm is impossible - only that a *cgroup ceiling* cannot be assumed to be the thing it fires on here.
It does not prove the proposed 12 GB container ceiling is bad without another run, because that exact ceiling was not measured after swap was added.
It does say the old page-cache failure mode is still a live risk and must be measured rather than inferred away from swap.

## What the next slice needs from the layout, whatever is decided

Measured while establishing where a ceiling could go, and worth keeping because the exemption requirement outlives this decision:

- The supervision watcher already runs in a slice of its own, `app-fm-watch.slice/fm-watch@<home>.service`, so nothing placed on a sibling can throttle it.
- Every agent runs in its own `tmux-spawn-<uuid>.scope` under `app.slice`.
  Those scopes are created by tmux, not by firstmate, and firstmate has no hook in their creation.
- The session-owned wake-delivery stub is a child of the agent process, so it shares that agent's scope.
  cgroup limits are inherited by descendants and cannot be escaped by one, so any ceiling covering an agent necessarily covers that session's own wake delivery.
  Exempting the fleet's wake delivery therefore means never fitting a ceiling to the primary session's scope, not exempting a process within it.

## Re-measuring

`bin/fm-memory-ceiling-probe.sh` runs both arms and issues one verdict, and its header owns its flags, its exit statuses, and its refusals.
It sets no lasting limit, kills nothing, and declines to run at all on a host that is already short of RAM headroom.

It reports `clear` and exits 0 when a ceiling genuinely is not reached, which was confirmed against an 8 GiB ceiling and a 512 MiB corpus on the same host in the same session.
That matters: an instrument that only ever returns the answer this page reports would be no evidence for it.
