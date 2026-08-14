# Priority batching of supervision events

Events travel together instead of interrupting one at a time, held by class for a bounded time, and never discarded to do it.

`bin/fm-event-batch-lib.sh`'s header is the authoritative owner of the record formats, the never-dropped contract, and the classification rule.
`bin/fm-event-batch.sh --help` owns the commands.
This document owns why it exists in this shape, what is proven and how, and what was deliberately left unbuilt.

## The captain's numbers

| Class | Held at most | What lands here |
|---|---|---|
| `immediate` | no delay at all, never held, not tunable | a signal whose status verb is `blocked:`, `failed:`, or `needs-decision:` |
| `high` | 60 seconds | a signal whose verb is `done:`, a legacy bare line naming finished work, and a `stale` event |
| `normal` | 120 seconds | a `check` event, and any signal line nobody can classify |
| `low` | 600 seconds | a `heartbeat`, and a signal whose verb is `working:`, `paused:`, `resolved:`, or `captain-held:` |

These are the captain's values: no delay at all is a fixed property of `immediate`, while the high, normal, and low values are shipped defaults.
A home overrides the high, normal, and low delays in `config/batch-delays`; one run overrides those three in the environment.
`docs/configuration.md` "Event batching delays" owns the schema, and `fm-event-batch.sh delays` reports the fixed zero hold for `immediate` plus the resolved number and source for each configurable class.

An unrecognised line lands in `normal` rather than `low`, because a line nobody can classify must not be the one held longest.
The classes are read through `bin/fm-classify-lib.sh`'s own verb reader, so a progress line is never promoted by prose that happens to contain a terminal word: `working: rebased onto merged #76` is progress, not a merge.

## What this slice is, and what it is not

It is **timing and grouping only**.

It does not judge, suppress, drop, downgrade, dedupe, or reorder an event, it does not queue or drain a wake, and it does not write a task's status file.
Whether a batch's contents are worth a supervisor's attention is a later unit's question - a hosted model judging a bounded batch - and nothing here takes a position on it.
Nothing here is armed on anything: like `docs/bosun-observer.md`'s observer tier before it, this ships as a mechanism plus its record, and pointing a consumer at it is a separate unit on the captain's word.

Two of the captain's decisions from 2026-08-13 bind on it directly.
Duplicate re-checks are **kept**, and the noise they cause is the judging tier's problem rather than something this unit may "help" with by dropping them.
Second-mate liveness readings will eventually travel this path as well as events, which is why the classifier keys on the journal's own kinds and verbs rather than on anything task-shaped.

It reads `docs/event-journal.md`'s append-only journal, the same stream the bosun reads, and keeps its own cursor, so pointing it at that journal changes nothing about the bosun's reading of it.
Neither neighbour is duplicated: the journal owns the record of what arrived, the bosun owns the record of what was judged, and this owns the record of what was grouped.

## The budget runs from arrival

A batch's deadline is its **oldest member's journal arrival epoch** plus that class's delay, not the moment the batcher happened to notice the event.
The poll interval therefore comes out of the budget rather than being added on top of it, so "within one minute" is a statement about the event's own age.
The run loop also never sleeps past a deadline: it waits the poll interval or the time to the next due batch, whichever is shorter.

Two honest consequences follow, and both are stated rather than smoothed over.

**`immediate` means the batch is never held, not that the end-to-end wait is zero.**
Unlike the high, normal, and low delays, `immediate` is not tunable.
An immediate event is released by the pass that admits it, and that pass has to happen: with the default 5-second interval, noticing it costs up to 5 seconds.
That noticing is admission latency shared by every class, and it is the one delay this unit cannot remove.
`account` therefore always checks `immediate` by the close reason rather than by a duration - an immediate batch is closed by the admission that opened it, and only that close records the reason `immediate`.

**The other three budgets carry the same admission allowance.**
`account` flags a closed batch when its hold from arrival exceeds the class delay *plus one poll interval*, because the batcher cannot close a batch in a pass it is not running.

## Nothing is dropped, and the two halves of that are different claims

The bosun programme's premise is that nothing is discarded.
Batching delays; it must never drop.
A batching mechanism that lost one event under load would remove the guarantee the journal was built to provide, and it would do so invisibly, because a missing notification looks exactly like a quiet period.

So the drop test is not a box ticked at the end.
Of the two the brief asked for, **the first is achieved by construction and the second covers everything the first cannot reach**:

**A dropped event is impossible once an event reaches a batch.**
`members.tsv` is append-only.
No code path removes, rewrites, filters, or collapses a member record; closing a batch appends a record to a different file rather than touching the members; and the size cap on a batch **closes it early** rather than truncating it.
The open marker is the one file rewritten in place, and everything in it is derivable from `members.tsv`, so it is working state and not the record.
The cursor advances only **after** a member record reaches disk, so a process killed mid-admit re-admits that event and produces a duplicate rather than a hole - the same trade `docs/bosun-observer.md` made, for the same reason: one duplicate costs a repeated entry, and the other order costs a silently lost event.

**An event that reaches the journal and never reaches a batch is loudly visible.**
`fm-event-batch.sh account` reconciles every retained journal sequence against the member records and exits non-zero naming anything the batching cannot account for:

- `missing` - a journal event at or below the cursor that is in no batch. This is the drop.
- `aged_out` - events that fell below the journal's retention horizon before the batcher reached them.
- `duplicated` - the honest outcome of the cursor order above.
- `orphaned_batches` - members whose batch is neither closed nor open.
- `duplicate_closures` - a batch sequence with more than one close record.
- `open_closed_overlap` - a batch sequence that is both closed and still marked open.
- `count_mismatch` - a closed batch whose recorded count differs from its member records.
- `over_budget` - a closed batch held longer than its class allows.
- `immediate_held` - an immediate batch that was not released by the pass that opened it.
- `overdue_open` - a batch past its deadline that nothing has closed, which is what a stopped batcher looks like from outside.

It is a command and not a comment precisely because the failure it looks for is invisible from anywhere else.

## What is proven, and how

`tests/fm-event-batch.test.sh` drives the real batcher.
Events reach the journal through the **real wake library** rather than as hand-written journal rows, and every timing assertion is read back from the batch **record** rather than from what the code says it did, so each number is a measurement of one run.

**The budgets are measured against the shipped defaults, at full size.**
The low class may be held for ten minutes, and a suite that waited it out would never be run, so `FM_BATCH_CLOCK_FILE` moves the batcher's clock instead.
The 60/120/600-second cases therefore exercise the real default constants and the real deadline arithmetic rather than shrunk stand-ins.
Each budget is checked in **both directions** - still open one second before, closed on the second - because a batcher that closed everything instantly would satisfy "within one minute" while doing no batching at all.

That seam is not a way around the measurement, and one case proves it: with no clock file at all, a batch is held and released on real elapsed wall time, so the controlled-clock cases are measuring the arithmetic the fleet runs on rather than a fiction.

Fourteen load-bearing assertions were mutation-checked on 2026-08-14 rather than trusted for being green:

| Mutation | Caught by |
|---|---|
| Ship `immediate` at 60 seconds | `immediate does not ship at no delay at all` |
| Never release an immediate batch in its own pass | `the immediate batch closed as 'deadline'` |
| Let an immediate arrival close nothing that is waiting | `the high batch was left waiting behind an immediate event` |
| Close every batch at half its budget | `the high batch closed at 59s; a batcher that never holds is not batching` |
| Advance the cursor before the member record | `the cursor advanced to 1 past an event whose record never reached disk` |
| Collapse same-key events on admission | `the re-admitted event appears 1 time(s); the record must never lose it` |
| Discard the overflow instead of closing a full batch | `expected 2 batches closed by the size bound, got 1` |
| Never report a missing event | `account reported a lossy record as clean` |
| Compare journal sequences as text rather than numbers | `the unreached remainder of the burst was not counted as pending` |
| Never report an overdue open batch | `a batch held past its deadline was reported as accountable` |
| Write one line to a task's status file | `a batching pass changed supervision state outside state/batches/` |
| Freeze the real clock | `the batch was not released after its real delay elapsed` |
| Ignore a home's config file | `a configured high delay was not used` |
| Let a mistyped delay become the shipped default | `an unusable configured delay was accepted` |

The drop test has its own control.
One case runs a mixed burst of twenty-two events across every class, with immediate events mid-stream so the bypass path runs inside the load rather than beside it, admits it in small passes so the burst crosses pass boundaries, and requires the batched sequences to equal the journal's own sequences exactly.
A second case then removes one member record - exactly as a filter or a collapse would have - and requires `account` to name that journal sequence and exit non-zero.
Without the control, "account reported clean" would only prove that `account` is capable of saying clean.

The burst is also reconciled **mid-admission**, with the cursor well behind a two-digit journal, and every unreached event must read as pending rather than missing.
That assertion is there because the first implementation compared sequences as text: under a string comparison `"10"` sorts below `"3"`, so every event past the ninth read as lost the moment the cursor fell behind, and a false drop report is as bad as a real one.

The no-authority claim is tested the same way the bosun's is: every file under the fixture's state directory outside `state/batches/` is hashed before and after a pass, and the hashes must be identical, with a separate assertion that the pass actually batched something.

## Deferred, and listed on purpose

Where speed and completeness conflicted this unit chose speed, so an unlisted shortcut would be a defect.

- **Every consumer.** Nothing reads a closed batch today. The judging tier that will read one, the path from a batch to what actually surfaces, and any arming of this on the watcher are separate units. `fm-event-batch.sh show <bseq>` exists so a consumer has a shape to read; nothing calls it.
- **Recovery of a lost open marker.** A stale marker left by a process killed between appending the batch record and removing the marker is detected at admission, discarded, and replaced with a fresh batch. Reconciliation fails on duplicate closures, open and closed overlap, and a mismatch between a closed batch's recorded count and its member records. What remains unbuilt is reconstructing a lost marker's running totals from `members.tsv`.
- **A real retention policy.** What ships is the same crude size bound the journal and the bosun use - two files of `FM_BATCH_MAX_BYTES` each - so a long-running batcher cannot fill a supervision host. It does not reason about age, event rate, or how far back a reconciliation needs to reach; `account` reports the horizon it can no longer see below rather than presenting a truncated reconciliation as a clean one.
- **A tuned classification table.** The verb-to-class mapping was written once against this fleet's existing status vocabulary. No variant was compared against another, and nothing measures whether an event a human would have wanted sooner was put in a slower class. The classes are overridable (`FM_BATCH_VERBS_IMMEDIATE`, `FM_BATCH_VERBS_LOW`) so that measurement can be acted on without editing code.
- **Batching across homes.** One batcher per home, one cursor per home. A fleet-wide batch spanning several homes is not built and is not implied by anything here.
- **Liveness readings as batch members.** The captain's 2026-08-13 direction that second-mate liveness readings surface through the bosun is a later slice. This path will carry them when it does; nothing here emits or classifies one.

## Related

- `docs/event-journal.md` - the stream this reads, and what it does and does not guarantee.
- `docs/bosun-observer.md` - the judging tier this sits beside, and the never-dropped discipline it set.
- `docs/supervision-cost.md` - what supervision actually costs, measured from the provider's own usage records.
