# The append-only event journal

The durable record of every notification event, captured at arrival and never collapsed.

`bin/fm-journal-lib.sh`'s header is the authoritative owner of the record format, the retention bound, and the privacy contract.
`bin/fm-journal.sh --help` owns the read commands.
This document owns why the journal exists, what it is proven to do, and what was deliberately left unbuilt.

## What was wrong

The fleet's never-discard guarantee was a claim the code did not honour, in two separate ways.

**Same-key history was dropped at read time.**
`fm_wake_print_deduped` in `bin/fm-wake-lib.sh` collapses every queue record sharing one `(kind, key)` to the last one.
Of two events about the same task, the first is gone by the time anything reads the queue.

**A payload could be resolved from state that had since moved.**
`fm_wake_print_annotations` reads `state/<id>.status` at DRAIN time and reports its last line.
The annotation says so in its own prefix - "latest wake-EVENT observed at drain, not current state" - and saying so does not make it a record of what arrived.

Neither is a defect in the wake queue.
The queue is a delivery structure, and both behaviours are right for delivery: one wake per task per turn, and the freshest text available when the supervisor finally looks.
They are the reason a separate record has to exist, not something to repair in place.
The captain chose to build that record rather than weaken the guarantee.

## What the journal is

One line per event, seven tab-separated fields, written once and never rewritten, under `state/journal/`.

It is bash and files.
Writing it and reading it cost no model call, and neither requires a supervising session to be awake - which is the whole point of it, because the measured cost of supervision is dominated by the size of the conversation a notification lands in, not by the number of notifications.
`docs/supervision-cost.md` records that measurement: a median 171,216 fresh tokens for a surfaced wake against roughly 207 for the mechanical arm that waits for one.
A consumer that can read this file can therefore make and record a judgement without paying the former.

The journal's cost effect on the provider bill is small, and it is not offered as a justification for anything.
This is a latency-and-attention change.

Every path that queues a wake records one, because `bin/fm-wake-lib.sh` sources the journal itself rather than leaving each of its two dozen producers to remember.

## The two properties, and how they are proven

`tests/fm-journal.test.sh` drives the REAL watcher (`bin/fm-watch.sh`) and the REAL drain (`bin/fm-wake-drain.sh`) over one live sequence: two captain-relevant events about one task, with the task's status file moving between them.
Neither side of the comparison is written by the test, which is what stops it from being a fixture shaped to match the implementation.

**Two events sharing one key are both retained, in arrival order.**
The drain delivers one record for that key; the journal holds both, at ascending sequence numbers.

**A payload is captured at arrival, not resolved later.**
The first event's record carries the line its status file held when that event arrived.
The drain's own annotation, over the same file and the same key in the same run, reports the later line - and the test asserts that contrast in both directions, so the two are distinguishable rather than merely both present.

Both assertions were mutation-checked on 2026-08-12 rather than trusted because they were green.
Making the reader collapse same-key records failed the first (`journal kept 1 of the 2 events sharing one key`).
Making the reader resolve the captured state from the current status file failed the second (`first event's captured state was 'done: second line'`).

## Pointing a consumer at it

An observer reads with `bin/fm-journal.sh`, manages no lock, and writes nothing:

```text
bin/fm-journal.sh status                 # horizon, last sequence, record count, gaps
bin/fm-journal.sh read --since <seq>     # every record above one already handled
```

Tailing is `read --since <last seq you handled>`, keeping that number yourself.
`--limit` takes the oldest matches, so a consumer advances rather than skipping ahead.

`status` reports what the stream cannot account for as well as what it holds.
A **horizon** above 1 means older records fell below the retention bound.
A **gap** means one or more records took a sequence number and never reached disk - a failed write, or a crash between allocation and append - including when the missing record is newer than every retained record or is the only allocation.
Both are reported rather than smoothed over, because a consumer that mistakes a truncated stream for a complete one will judge on it.

A wake that cannot be journalled is still delivered.
Delivery outranks the record of it, the failure is reported on stderr, and the gap it leaves in the sequence is what tells a later reader the stream is incomplete.

## Deferred, on the captain's 2026-08-12 direction

The shape of this unit was cut mid-build to the smallest journal that lets an observer-only bosun run and be watched.
These are recorded as unbuilt rather than described as built:

- **A real retention policy.** What ships is a crude size bound - two files of `FM_JOURNAL_MAX_BYTES` (8 MiB default) - chosen so an unbounded file cannot fill a supervision host. It is not a policy: it does not reason about age, event rate, or what a replay window needs to reach back to. Records below the horizon are gone, and `status` says so.
- **Replay proven against a full recorded live sequence.** The `origin` field carries each record's wake-queue sequence number precisely so a later unit can reconstruct a drain's delivered view and diff it against the real drain's output. That reconstruction, and the drain-boundary records it would need, are not built. The format carries the field now because changing the format after a consumer is pointed at it is expensive.
- **Arm-cycle records.** An arm cycle and a queued notification are different events and neither is derivable from the other - one seat measured 391 arms against 354 queued in the same window. `FM_JOURNAL_KINDS` is the place a later unit adds `arm` as its own kind. Nothing is written from `bin/fm-wake-wait.sh` today, which also keeps this change out of the most safety-critical script in the delivery path.
- **Every consumer past the observer.** The judging tier, the batching, the deferral classes, and the trial are separate filed units that read from here. None of them is started here, and this unit takes no position on their decisions.

## Related

- `docs/supervision-cost.md` - what supervision actually costs, measured from the provider's own usage records.
- `docs/architecture.md` - where the wake queue sits in the supervision loop.
