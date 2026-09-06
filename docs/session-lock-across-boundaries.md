# The session lock across a process boundary

This records why `state/.lock` names a pid table as well as a pid, why ownership can now be passed rather than only dropped, and what those two changes do NOT establish.
It is evidence, not narrative: every claim below names the command that produced it.

`bin/fm-harness-pid-lib.sh` owns the record's parse and the "another live session holds this home" decision.
`bin/fm-lock.sh` and its `--help` own the commands and their exact flags.
This document owns neither; it owns the measurement and the reasoning.

## The defect, measured rather than reasoned about

A pid means something only inside one process-id table.
`kill -0` resolves the number in the CALLER's table.
So a seat starting inside a container tests a host pid against the container's own table, finds nothing, and concludes the process is dead - while the host seat is still running and still supervising.

Measured on this fleet's own host, 2026-08-25, Linux 6.8.0-137-generic x86_64, bash 5.2.21(1)-release, unshare from util-linux 2.39.3:

```
host ns: pid:[4026531836]
host holder pid: 4117306
inside ns:  pid:[4026534852]
kill -0 host holder: 1 (not visible)
```

The inner shell was an unprivileged `unshare --user --pid --fork`, so this is a real pid namespace and not a simulation of one.
Two details are worth keeping, because both change what a fix has to do:

- The namespace was obtained with NO privilege and NO docker access, which is what lets the behaviour test stage the real case rather than reason about it.
- `/proc` was still the host's, so `ps -p <host pid>` still SAW the process while `kill -0` did not.
  A liveness test that consults both is still answered "dead" by the first of them, so "check `ps` as well" is not a fix.

## What the fix does, and what it deliberately does not do

The record now carries the identity of the table its holder pid came from:

```
<holder-pid>
pidns=linux:<machine-id>:pid:[4026531836]
handover=<ticket>          (present only while an offer stands)
```

Line one is unchanged, so every reader that already took the first line kept working; the fields below it are additive.
Three readers took the WHOLE file and were changed to read the holder from line one - `fm_context_session_live` in `bin/fm-context-lib.sh`, the endpoint publisher in `bin/fm-delivery-service.sh`, and endpoint validation in `bin/fm-delivery-lib.sh`.
They would otherwise have been handed a multi-line string where they expected a number, causing context and endpoint ownership checks to reject a live session.

The liveness test was NOT loosened, which was the trap this work was warned about.
A lock that stops refusing is not a lock.
What changed is that the test now knows when it cannot see:

- Same table recorded as the reader's own: probe liveness exactly as before.
- A DIFFERENT table: refuse, and say the holder's liveness is unmeasurable from here.
  Not "stale", not "held" - neither is a claim this reader is entitled to make.
- The reader cannot name its own table: refuse, for the same reason.

On Linux, the token combines `/etc/machine-id` with `/proc/self/ns/pid` because the namespace inode is unique only within one kernel and homes can be shared across machines.
The stable machine id is used instead of `/proc/sys/kernel/random/boot_id` because a boot-scoped token would make a pre-reboot record foreign and wedge the home rather than letting its dead holder free normally.
Failure to read either Linux identity component is a refusal, and the accepted cost is that such a home operates read-only until both become readable.
Only where the kernel has no pid namespaces at all is the whole machine one table and the token names the machine.
The host name is deliberately part of it: two machines sharing one home over a network filesystem are two tables and must not be read as one.

## The handover, and the cost that was chosen

Before this, the lock freed only when its owner died, so ownership could be dropped but never passed.
`fm-lock.sh handover` issues a one-time ticket while the outgoing seat is STILL the recorded holder; the successor presents it and the record is replaced in one atomic rename.

The item this closes required the choice to be stated rather than left implicit.
It is this:

- There is never a moment when the record names nobody, and never a moment when it names two.
- The offer is the outgoing seat's standing-down, it is final, and that seat is refused a plain re-acquire afterwards.
- **The cost is a gap in which no seat is ACTING** - between the offer and the successor's acquisition, the home is owned and unsupervised.

That gap was chosen over the alternative because an unsupervised minute is recoverable and two seats both draining the wake queue, dispatching, and merging is not.
The gap is bounded by how long the successor takes to start, and it is visible: `fm-lock.sh status` says an offer stands.

## Superseding a holder that died with its container

A container rebuild produced the one refusal a handover cannot clear: the outgoing holder is dead, so it can offer nothing, and its record is foreign, so no reader may judge it.
Measured in this home between 2026-09-02 and 2026-09-06, four times, the last of them recorded in the 2026-09-06 process review:

```
$ cat state/.lock.stale-2026-09-06
147
pidns=linux:76c1f44f...:pid:[4026532522]
$ cat /etc/machine-id
9157f31a...
$ ps -o lstart= -p 1   ->  container started 10:25Z; the stale record's mtime is Sep 4 14:01
```

Every one of those four was cleared by a person moving the file aside by hand, and until they did, the rebuilt seat ran read-only: no dispatch, no merges, no wake drain.

The captain allowed the takeover on 2026-09-06, on two readings and only together:

1. the record's machine-id half differs from the running `/etc/machine-id`, so the machine identity that table belonged to is gone;
2. the record's mtime precedes pid 1's start (`/proc/1/stat` field 22 against `btime` in `/proc/stat`), so no process of this container wrote it.

Neither reading alone is enough and the predicate requires both, because each alone describes something still alive: a differing machine id alone is what a genuinely foreign live seat sharing this home over a network filesystem looks like, and an older mtime alone is what any long-lived holder of this same container looks like.
Together they establish that the holder cannot be running in this container's pid namespace, and no more than that.
The known bound is that the two readings do not exclude ANY live seat that can reach this home from a pid namespace carrying a different `/etc/machine-id` - the host or a sibling container sharing the home through a bind mount or volume, or another machine over a network filesystem.
A record such a seat wrote before this container started has a differing machine id and an older mtime, so both readings hold for it, and neither excludes it.
The mtime reading only proves that no process of this container wrote the record; it says nothing about a writer elsewhere.
The supersede path prints that bound beside the two readings it acted on, so a seat that takes another record's place says what its readings did not establish.
The verdict also requires the record's machine-id half to differ, so it clears only a rebuild in which `/etc/machine-id` changed.
A container that restarts with the same image-provided or persisted machine id but a fresh pid namespace still reads as foreign, and still needs the hand clear this change was meant to retire.
`bin/fm-harness-pid-lib.sh` owns the test, `fm-lock.sh status` reports it as `dead-container`, and `fm-lock.sh acquire --supersede-dead-container` is the only path that acts on it.
`bin/fm-session-start.sh` takes that path itself on that verdict and prints the verdict, both readings and the name of the record it kept.
It then asks `bin/fm-sessionstart-nudge.sh --rebind-after-supersede` to rebind this home's context-ceiling transcript record to the holder the new lock names, because the SessionStart hook ran before the supersede and correctly wrote nothing for a foreign record; [sessionstart-nudge.md](sessionstart-nudge.md) owns that record and what the rebind can and cannot establish.

This is not a loosening of the liveness test, and the difference is worth stating exactly: nothing here probes a process in a table this session cannot see into.
It reads the RECORD, twice, and both readings are about the machine and the container rather than about a pid.
Every other refusal is unchanged - a live holder in this session's own table, a foreign holder whose machine identity is this one, an unreadable record, a record this container wrote.
The superseded record is kept beside the new lock as `.lock.superseded-<timestamp>` rather than deleted, because the operator who has to understand a superseded seat needs the record that was superseded, and because a supersede that leaves no trace is indistinguishable from the hand `rm` it replaced.

## What this does not establish

- **The claim lock is still pid-based.**
  `bin/fm-wake-lib.sh` owns `state/.lock.acquire`, and its staleness test is `fm_pid_alive` plus a freshness window - the same reading that fails across a table boundary.
  Two acquisitions in different tables overlapping by longer than that window can therefore both take the claim.
  That weakness is bounded for competing plain acquisitions because the losing side's publication read-back catches the overwritten record.
  It did not safely serialise two operations that both legitimately intended to write, so the withdrawal operation was removed and a handover offer is final.
  A residual race remains if ticket redemption overlaps a third seat's plain acquisition at the moment the offering process dies: the plain acquisition can read the same-table holder as dead while the ticket remains redeemable.
  That primitive is also shared with the watcher, the delivery listener, batching, the journal, the bosun, and the urgency surface, so changing it is a fleet-wide blast radius rather than a lock fix.
- **A record written before this change names no table.**
  It is read the way it was written - as a pid in the reader's own table - and replaced by the first acquisition after it.
  That one transitional reading cannot tell a foreign holder from a dead one, so `bin/fm-lock.sh` says so on stderr when it takes such a record rather than upgrading it silently.
  The operational consequence is that the fix has to reach every seat before any seat moves inside, because the transition window is exactly the window in which the old defect still exists.
- **Nothing about supervision.**
  The monitoring loop and the wake listener are untouched by this change and remain outside the boundary a seat would move into.
  That half of the move is still open.
- **Survival is handled for one shape only.**
  A rebuild that changes `/etc/machine-id` is the measured case the supersede above clears.
  A restart that keeps the machine id, and a host reboot, are not exercised here.
