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
pidns=pid:[4026531836]
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

On Linux, failure to read `/proc/self/ns/pid` is a refusal because a hostname cannot distinguish pid namespaces that share one machine identity.
The accepted cost is that such a home operates read-only until its pid namespace identity becomes readable.
Only where the kernel has no pid namespaces at all is the whole machine one table and the token names the machine.
The host name is deliberately part of it: two machines sharing one home over a network filesystem are two tables and must not be read as one.

## The handover, and the cost that was chosen

Before this, the lock freed only when its owner died, so ownership could be dropped but never passed.
`fm-lock.sh handover` issues a one-time ticket while the outgoing seat is STILL the recorded holder; the successor presents it and the record is replaced in one atomic rename.

The item this closes required the choice to be stated rather than left implicit.
It is this:

- There is never a moment when the record names nobody, and never a moment when it names two.
- The offer is the outgoing seat's standing-down, and it is enforced: that seat is refused a plain re-acquire afterwards and must run `handover --cancel` to take authority back deliberately.
- **The cost is a gap in which no seat is ACTING** - between the offer and the successor's acquisition, the home is owned and unsupervised.

That gap was chosen over the alternative because an unsupervised minute is recoverable and two seats both draining the wake queue, dispatching, and merging is not.
The gap is bounded by how long the successor takes to start, and it is visible: `fm-lock.sh status` says an offer stands.

## What this does not establish

- **The claim lock is still pid-based.**
  `bin/fm-wake-lib.sh` owns `state/.lock.acquire`, and its staleness test is `fm_pid_alive` plus a freshness window - the same reading that fails across a table boundary.
  Two acquisitions in different tables overlapping by longer than that window can therefore both take the claim.
  The consequence is bounded and it was left as it is on purpose: the claim only serialises the read-then-write, and the refusal that matters no longer depends on it.
  That primitive is also shared with the watcher, the delivery listener, batching, the journal, the bosun, and the urgency surface, so changing it is a fleet-wide blast radius rather than a lock fix.
- **A record written before this change names no table.**
  It is read the way it was written - as a pid in the reader's own table - and replaced by the first acquisition after it.
  That one transitional reading cannot tell a foreign holder from a dead one, so `bin/fm-lock.sh` says so on stderr when it takes such a record rather than upgrading it silently.
  The operational consequence is that the fix has to reach every seat before any seat moves inside, because the transition window is exactly the window in which the old defect still exists.
- **Nothing about supervision.**
  The monitoring loop and the wake listener are untouched by this change and remain outside the boundary a seat would move into.
  That half of the move is still open.
- **Nothing about survival.**
  A container restart and a host reboot are not exercised here.
