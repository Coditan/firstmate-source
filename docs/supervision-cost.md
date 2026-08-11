# Supervision cost

What supervision costs this fleet, measured rather than argued, and what three repairs to it changed.

Every figure here was counted from the provider's own usage records with `bin/fm-supervision-cost.sh`, or produced by running the code on both sides of a change.
Nothing here is projected from a byte count, a turn count, or a rate card.
Where a number could not be measured, this document says so instead of supplying one that looks measured.

## The unit

FRESH tokens: `input_tokens + cache_creation_input_tokens` for one request, deduplicated by request id.

That is what a request newly writes into the provider's window.
Cache READS are carried context: they are counted separately here and never added in, because they are charged differently and because a change to firstmate's own machinery cannot move them the way it can move what a turn writes.
A number in the wrong unit is worse than no number, because it reads as authoritative and gets re-quoted.

`bin/fm-supervision-cost-engine.py`'s header owns the definition of every counted thing.

## What this does not cover

Only Claude Code keeps a local provider usage record, so only Claude Code sessions are measured.
Sessions run under codex, opencode, pi, or grok contribute nothing to any figure below, and their supervision spend remains unmeasured.

Retention is the provider's.
A day whose transcripts have rolled off is absent from the table rather than reported as zero, and no figure here is a complete ledger of any day.

Currency is not computed.
That needs a price list this repo has no business pinning, and a subscription window is not the same accounting as an API bill.

Two repairs below report their "after" from running the changed code against the unchanged code on the same input, not from re-measuring a week that has already happened.
That distinction is stated at each one rather than left for the reader to notice.

## Baseline, 2026-08-04 to 2026-08-10

Measured on 2026-08-11 on host `hlr-web-1`, over every Claude Code transcript retained under `/home/coditan/.claude/projects`, with:

```text
bin/fm-supervision-cost.sh --since 2026-08-04 --until 2026-08-10 --json
```

247 sessions were measured across all projects on this host.

```text
day          starts   fresh tokens   deliveries   empty   empty fresh   empty requests
2026-08-04       47     12,616,066          569     410     1,313,258            1,347
2026-08-05       18      3,177,839          203     164       169,726              516
2026-08-06       33      3,592,049            9       0             0                0
2026-08-07        6      2,735,671           18       1       272,773              113
2026-08-08       16      2,240,701           42       0             0                0
2026-08-09       35      5,989,121           43       0             0                0
2026-08-10       92     14,597,722          195      55       112,997              227
TOTAL           247     44,949,169        1,079     630     1,868,754            2,203
```

Three things follow directly.

**Session start.** The 247 starts wrote 7,738,271 fresh tokens between them, 17.22 percent of every freshly written token on the host that week, before any work happened.
The per-start median in the main home was 43,284 to 47,675 fresh tokens across 2026-08-04 to 2026-08-11.
That is roughly double the 25,000 the work was scoped against; the scoping figure is not reproduced by this measurement, and the higher one is what a later change should be judged against.

**Restart rate.** 47 to 92 starts a day on the two busiest days, across every project on this host.
The figure of 169 starts in a day that motivated this work is NOT reproduced here, and the counting rule behind it is unknown to this document.
What is reproduced is the shape: start count and start cost multiply, and 92 starts at 45,000 fresh tokens each is 4.1 million tokens of pure re-entry.

**Empty deliveries.** 630 of 1,079 deliveries that week, 58.4 percent, woke the model and carried nothing.
They cost 2,203 requests and 1,868,754 fresh tokens, 4.16 percent of the week's freshly written tokens.

The incident that named the defect is measurable on its own:

```text
bin/fm-supervision-cost.sh --session 20c57a94-cb85-42a7-a734-4220eadfa0a6
```

```text
requests: 261
fresh tokens: 374,879
deliveries: 45
  empty deliveries: 36
  requests spent on empty deliveries: 111
  fresh tokens spent on empty deliveries: 33,418
drain calls: 49
  returning no queue record: 39
requests per delivery: median 3, mean 5.8, max 45
```

## Repair 1: the arm that closed instantly

### What it was

`bin/fm-watch-arm.sh` exec'd `bin/fm-wake-wait.sh`, which returned at once with `wake delivery: already armed pid=<N> (same session)` whenever a healthy stub of the same session already held the delivery lock.

That is the correct answer to the question "is delivery armed".
It is a ruinous way to close a process, because under a background-notify harness the CLOSE is the wake.
The harness cannot see why a tracked task finished; it sees that it finished, and it wakes the model.
So an instant close reads as a wake carrying nothing, the model drains an empty queue and re-arms per its protocol, and that re-arm closes instantly for exactly the same reason.

The loop is visible in the transcript of session `20c57a94-cb85-42a7-a734-4220eadfa0a6`.
Each `bin/fm-watch-arm.sh` background task enqueued its completion notification within a second of launch (17:23:21.711 launched, 17:23:22.330 notification enqueued; 17:23:47.935 launched, 17:23:48.653 enqueued; 17:24:04.601 launched, 17:24:05.121 enqueued), and each notification produced one drain that returned nothing, from 17:23:18Z through 17:32:04Z.
`docs/watcher-continuity.md` had recorded "Claude re-arms only on `wake: queued` and needs no new rule", which the records above disprove: the model never saw `wake: queued`, it saw a finished task.

### What changed

`bin/fm-wake-wait.sh` gained `--hold`, and `bin/fm-watch-arm.sh` execs it with that flag.
A holding attempt that finds delivery already armed stays alive instead of closing: it polls the durable queue exactly as the holder does, and retries the lock every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds until the holder releases it, at which point it becomes the delivery wait itself.
Every close of the wrapper is therefore a real wake or a real failure.

Callers that own their own re-attempt cadence run `bin/fm-wake-wait.sh` directly without `--hold` and are unchanged: `bin/fm-watch-checkpoint.sh` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` both still get the instant close they are built around.

A holding attempt watches the queue as well as the lock, deliberately.
Waiting for the lock alone would be silent if the holder were alive but wedged, and a wake nobody hears is the one failure this fleet does not accept.

Watching it naively would have replaced one problem with a smaller one.
A wake arriving during a hold closes the holder and the attempt behind it within the same second, so one wake is delivered twice, and because the model arms once per delivery the doubling then sustains itself rather than settling.
So content already queued when a holding attempt starts is INHERITED: it belongs to the holder to report, and the attempt behind it waits one `FM_WATCH_CHECKPOINT_REARM_POLL` before it will report the same content itself.
The moment the queue drains, nothing is inherited any more and the attempt is an ordinary delivery wait.
A working holder reports well inside that window, so one wake produces one delivery; a holder that was killed or wedged never reports, and the attempt behind it delivers a few seconds late.
Latency, never silence.

### Before and after

Measured on 2026-08-11 by running both versions against the same state: a healthy fake watcher, an empty queue, and one healthy same-session stub already holding the delivery lock.

```text
BEFORE  redundant arm closes in 30s: 385 (exit 0 each time)
AFTER   redundant arm closes in 30s: 0 (held for 30s, timeout exit 124)
AFTER   a real wake arriving during a hold: delivered in 0s, exit 0, output: wake: queued
```

385 closes in 30 seconds is the rate the mechanism can produce; the model turn is what throttled it to roughly one every 12 to 25 seconds in the live incident.
Either way the class of close is now zero.

The fresh-token figure for this repair is the measured cost of the class it removes, not a re-measured week: 630 empty deliveries, 2,203 requests, and 1,868,754 fresh tokens over 2026-08-04 to 2026-08-10.
Not every empty delivery in that window is proven to come from this mechanism, so that figure is an upper bound on what this repair recovers, and the 33,418 fresh tokens in session `20c57a94` are the part traced to it line by line.

`tests/fm-wake-wait.test.sh` covers all five properties: a holding attempt must not close while another stub owns delivery, must still deliver a wake that arrives while it holds, must take delivery over once the holder releases, must let the holder report an inherited wake rather than reporting it a second time, and must still report a wake a wedged holder never reported.
The first of those fails on the unchanged code with `a holding delivery attempt closed while another stub of this session still owned delivery`.
The last two are the pair that keeps the deferral honest: drop either and the fix trades a loop for a doubling, or a doubling for a lost wake.

## Repair 2: the unbounded echo

### What it was

The annotation half of a drain has been bounded since it was written: 2,048 bytes per annotation, 8,192 bytes in total, at most 8 status reads.
The raw half, which carries the notification itself, had no bound at all.
Its size is the product of two uncapped things: how many distinct `(kind,key)` pairs the queue accumulated, and how long each payload the watcher composed happens to be.

A wake turn pays for that text twice, once to read it and again as freshly written context for every request that follows in the turn, so an unbounded echo is an unbounded price on an event whose importance has nothing to do with its length.

The measured distribution over 3,592 drain results retained in this host's transcripts: median 342 bytes, p99 2,339 bytes, maximum 10,738 bytes, at most 7 queue rows in any one drain.
So the defect was latent rather than routine, which is exactly the kind that is cheap to fix now and expensive to meet later.

### What changed

`fm_wake_bound_echo` in `bin/fm-wake-lib.sh` caps the raw echo at `FM_WAKE_ECHO_BYTES` bytes in total (default 8,192), with a `FM_WAKE_ECHO_ROW_BYTES` per-row cap (default 1,024) underneath so one pathological payload cannot consume the whole budget and hide every other record behind it.
The defaults are set from the distribution above, well clear of every drain this fleet has actually produced.

Withheld is not discarded.
`bin/fm-wake-drain.sh` keeps the drained queue file under `state/.wake-drain-overflow.<epoch>.<pid>` whenever anything was withheld or shortened, and prints the count and the path, so one read recovers every record in full.
The drain never deletes preserved overflow files because no state records that their full contents have been read.

The stated bound: a drain's stdout is at most 8,192 bytes of raw records, plus one marker line under 256 bytes, plus the annotation half's existing 8,192 bytes, so at most roughly 16.6 KiB regardless of how large the queue got.

### Before and after

Measured on 2026-08-11 by draining a synthetic queue of N stale records, once with the unchanged code and once with the change, on the same input:

```text
rows    before (bytes)   after (bytes)
1                  108             108
8                  864             864
64               6,967           6,967
512             56,212           8,344
4096           459,743           8,345
```

Below the cap the two are byte-identical, which is the property that matters most: nothing changes for any drain this fleet has ever actually produced.
Above it, the old output grows linearly at about 110 bytes a record with no ceiling, and the new output saturates.

This repair's effect is measured in bytes, not in fresh tokens, and the two are not interchangeable.
Tokenization is the provider's, and no local measurement converts one to the other; claiming a token saving here would be exactly the estimate-dressed-as-measurement this work exists to stop.
Regressing a request's fresh tokens against the drain bytes that preceded it was considered and rejected for the same reason: the request that reads a drain result also carries everything else that turn wrote, so the fit would describe the confound rather than the drain.
What can be said in tokens is the ceiling this removes: at 4,096 queued records the old echo wrote 459,743 bytes into a context the turn then pays to carry, and the new one writes 8,345.

`tests/fm-wake-queue.test.sh` pins the bound at its exact edge: rows that exactly fill the budget are all echoed with nothing set aside, one byte over withholds exactly one record, names it, and preserves all five in the overflow file.
A second test proves one oversized row is shortened to exactly the per-row cap rather than costing a whole record, and that the shortened payload survives in full in the preserved file.

## Repair 3: requests per wake

The brief asked for a wake handled in one request rather than the measured 6.5, or the remaining requests named and justified.
They are named and justified, because one is not reachable under a background-notify harness and three is.

Measured distribution of requests per delivery in the main home over 2026-08, from the same instrument:

```text
 3 requests:  651 deliveries   <- the mode; 91 of them carried a record
 4 requests:  142              <- 110 carried a record
 5 requests:  104              <- 94 carried a record
 6 requests:   41
 7+        :  the long tail, up to 252
```

Three is the floor, and 91 deliveries that actually carried a record were handled in exactly three requests, so it is a reached floor rather than a theoretical one.
The other 560 three-request deliveries carried no queue record at all: a wake carrying nothing is the cheapest possible wake to handle and still costs three requests, which is why removing the wake beats optimising the handling.
Each of the three is irreducible under this harness:

1. **The drain.**
   `bin/fm-wake-drain.sh` is the sole model-invoked atomic drain, and its print-before-delete boundary is what makes consumption at-least-once.
   Moving it into a background task would mean deleting records whose output no request is guaranteed to have read.
2. **The arm.**
   The next delivery only reaches the model if the wait is a harness-TRACKED background task, because a process started any other way completes into nothing.
   Starting it is therefore a tool call the model must make.
3. **The close.**
   A tool call requires a following assistant message.
   The turn cannot end in the same request that starts the arm.

Bundling the drain and the arm into one shell command does not help and is refused by design: `bin/fm-arm-pretool-check.sh` denies a protected watcher command inside a compound, because a truncating pipe or a bundled failure silently unarms delivery.

What this unit actually removes is not requests per wake but wakes: the 630 empty deliveries above were 2,203 requests spent on wakes that carried nothing, and repair 1 removes the mechanism that produced them.
The long tail above 3 requests is model-chosen inspection - pane reads, crew state, backlog updates - and is not protocol overhead; nothing in this unit touched it, and no claim is made about it.

## Found here, owned elsewhere

This unit closed measured waste and deliberately built no judging tier, no event ledger, and no source-specific batching.
Five things surfaced while measuring that belong to those units rather than this one, recorded here so they are not rediscovered from scratch.

**Not every empty delivery is the arm loop.**
630 empty deliveries were counted that week, and only session `20c57a94`'s 36 are traced to the arm mechanism line by line.
Attributing the rest needs the origin tagging that the event-ledger unit owns, so until then the 1,868,754 fresh tokens is an upper bound on what repair 1 recovers.

**Session start is the larger number.**
17.22 percent of the week's freshly written tokens went on session starts, against 4.16 percent on empty deliveries.
Nothing in this unit touched it.
Reducing it means changing what a session must load before it can work, which is a different decision carrying a different risk.

**The 169-starts-a-day figure is unreproduced.**
This instrument measures 47 to 92 across all projects on this host on the two busiest days.
Whoever owns restart-rate work should re-derive that figure rather than inherit it.

**The queue row is still not replay-complete.**
`fm_wake_print_deduped` keeps the last row per `(kind,key)`, annotations read the latest status line at drain time rather than the triggering one, and Bridge rows carry only `pending=N highest=P`.
A deferred judgment cannot be replayed from a queue row today, which is the gap the event-ledger unit exists to close.

**The Bridge decreasing-count wake is still open.**
`bin/fm-bridge-inbox-lib.sh` wakes on any tree-signature change with a non-empty inbox, so a count going DOWN still wakes the model.
It was already filed before this unit started and belongs to the Bridge batching unit.

## Reproducing any of this

```text
bin/fm-supervision-cost.sh --since 2026-08-04 --until 2026-08-10
bin/fm-supervision-cost.sh --session <session-id>
bin/fm-supervision-cost.sh --project <substring> --json
```

The two before-and-after experiments are a stash and a re-run: both compare the changed scripts with the unchanged ones on identical fixture state, and both are reproduced by the tests named above.
