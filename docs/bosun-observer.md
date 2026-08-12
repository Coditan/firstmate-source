# The bosun, in its observer-only form

The cheap judging tier between the mechanical watcher and the supervising session, built first as a thing that **decides nothing**.

`bin/fm-bosun-lib.sh`'s header is the authoritative owner of the verdict record format, the escalation bias, and the health record's fields.
`bin/fm-bosun.sh --help` owns the commands and the health vocabulary they report.
This document owns why it exists in this shape, what is proven, what the model choice is and is not, and what was deliberately left unbuilt.

## What it is

A loop that reads `docs/event-journal.md`'s append-only event journal, asks a judge about each event, and writes down what it concluded.

```text
bin/fm-bosun.sh run                # judge continuously; one line per verdict as it lands
bin/fm-bosun.sh run --once         # exactly one pass, for a test or a cron
bin/fm-bosun.sh status             # health, ending in one word from the vocabulary owned by --help
bin/fm-bosun.sh verdicts           # read the judgements back
bin/fm-bosun.sh watch              # follow a live run from another terminal
```

## It has authority over nothing

This is the whole shape of the unit and not a caveat on it.

Nothing the bosun concludes changes what surfaces to a supervising session.
It does not queue a wake, drain one, suppress one, reorder one, or write a task's status file.
It reads the journal and writes its own record under `state/bosun/`, and the only thing that reads that record today is a human looking at it.

That boundary is tested rather than asserted: `tests/fm-bosun.test.sh` hashes every file under a fixture's state directory outside `state/bosun/`, runs a pass that judges two events, and requires the hashes to be identical afterwards.
The case also asserts the pass actually judged something, because a bosun that does nothing would pass a no-change test trivially.
Making a pass append one line to a task's status file fails it.

A judging tier is worth nothing until its judgements can be read back and disagreed with.
So the judgements come first, in a form the captain can audit against his own opinion, and authority is a separate unit on his word.

## Quiet is not dead

A run was found on 2026-08-12 with its process alive, its log growing, and no work produced for seventeen hours.
"The process is up" is exactly the evidence that does not settle whether a tier is working, so this one is built to answer the question its own health record cannot self-report.

Every pass writes the health record, **including a pass that judged nothing** - a beacon that only ticks when there is work cannot prove a quiet bosun is alive.
The record carries both that the pass happened and whether the cursor moved, plus `backlog_since`: the epoch at which the cursor first sat below the journal's head *without moving*, cleared the moment it moves again.

`status` resolves those against the clock and against the journal into one word, and `bin/fm-bosun.sh --help` owns that vocabulary and its exit codes.
Two of its distinctions are the reason this unit is shaped the way it is.

The health vocabulary and exit behavior are owned by `bin/fm-bosun.sh --help`, including the distinct state for a journal the bosun cannot read.

`QUIET` against `STALLED` is the one it exists for: a bosun that judged nothing because nothing arrived is healthy, and one whose cursor has sat still while the journal grew is not, and no process-liveness check can tell those two apart.
A cursor that is behind and *advancing* is `WORKING`, not stalled - being behind is not a fault, and freezing is.

`STOPPED` against `DEAD` keeps a clean shutdown from reading as a fault, so the reading that deserves attention is not buried under the routine one.

`status` also reports the journal's own gap count, so a bosun judging a truncated stream says so rather than letting a reader mistake it for a whole one.

## Failing toward escalation

A bosun that cannot be reached, cannot judge, or is unsure must cause the event to be treated as if it needed a human.
In this observer form that is a **recorded verdict of `escalate`**, never a dropped row.

Every failure shape returns escalate with the failure itself as the reason, and each has its own case in the suite: a judge that is not on disk, one that exits non-zero, one that never answers within the timeout, one that prints prose instead of JSON, and one that returns a verdict value nobody defined.
A judge that answers `routine` with **low confidence** is also recorded as escalate, with its own answer preserved in the reason, because unsure is not the same as safe.
The `judge` field names which of those produced each verdict, so a verdict a model reached and one the failure path reached are never confused.

Nothing is ever skipped:

- The cursor advances only **after** a verdict record reaches disk. A pass that dies between judging and recording re-judges that event next pass. That costs one duplicate judgement; the other order costs a silently unjudged event, which is the failure this tier exists against.
- Events that fell below the journal's retention horizon before the bosun reached them are recorded as one escalation naming the range, rather than stepped over in silence.

## What is proven, and how

`tests/fm-bosun.test.sh` drives the real run loop, and events reach the journal through the real wake library rather than as hand-written journal rows.
Judges are fakes on purpose: this suite tests the bosun's handling of every judge outcome, and a real model cannot be made to time out on demand.

Six load-bearing assertions were mutation-checked on 2026-08-12 rather than trusted for being green:

| Mutation | Caught by |
|---|---|
| Never detect a stall | `a bosun that keeps passing but stops judging reports STALLED` |
| Always report STALLED | `an idle bosun with an empty journal reports QUIET` |
| Let an unsure judge's "routine" stand | `judge-is-unsure: expected escalate, got 'routine'` |
| Let an unparseable answer be routine | `judge-prints-garbage: expected escalate, got 'routine'` |
| Skip aged-out events silently | `events below the retention horizon were skipped without a record` |
| Write one line to a task's status file | `a bosun pass changed supervision state outside its own directory` |

Both directions of the quiet/stalled discrimination are checked against the same fixture, because a check that only ever reports one of the two proves nothing about its ability to tell them apart.

Separately, a live run against the real judge and the real journal on 2026-08-12 judged three events correctly: ordinary progress as `routine`, a revoked deploy key as `escalate`, and a PR awaiting review as `escalate`, at 3.5-7.7 seconds each.

## The model, which is provisional

`data/fm-bosun-model-survey/report.md` recommends **NVIDIA Nemotron 3 Nano on DeepInfra** as the pilot, on latency, enforced schemas, and reversible open weights.
The same survey found **no ranked third-party endpoint proven authenticated from this fleet**: only Claude and Codex are reachable today.

This unit judges nothing that has any effect, so it uses what is already reachable rather than asking the captain for a credential it does not yet need.
The default judge is `bin/fm-bosun-judge-codex.sh`, and Codex rather than Claude for two reasons the survey establishes:

- **Meter.** The survey's criterion 2 excludes this fleet's Anthropic subscription window, after three exhaustion events on 2026-08-10, and explicitly does not exclude Codex. Spending the protected window on an observer that decides nothing is the wrong meter to spend.
- **Enforced schema.** `codex exec --output-schema` constrains the response server-side, which is the survey's criterion 3. The Claude CLI path here would be prompt-only JSON, which the survey rules insufficient.

**What this choice is not.** It is not the survey's answer, and it is **not evidence for the latency programme**.
Measured on this machine on 2026-08-12, one judgement takes roughly 3.5-7.7 seconds end to end, against the survey's sub-two-second gate.
That is an agent CLI's startup and turn overhead, not a model's time to first token; a direct schema-constrained call to a ranked endpoint would not carry it.
An observer that decides nothing can afford that latency.
A tier with authority cannot, and must not inherit this choice by default.

The model is a **seam, not a decision**.
`FM_BOSUN_JUDGE_CMD`, or a home's `config/bosun-judge`, points the bosun at any command that reads one event on stdin and prints one JSON object on stdout.
Swapping in a ranked endpoint is a few lines of curl and changes no code in the bosun.

**Cost is reported, never claimed as a benefit.**
The captain settled on 2026-08-12 (`fleet-bosun-vs-fable-verdict`) that this is a latency-and-attention programme, not a cost programme.
For the record: one judgement through the Codex CLI carries roughly 13,000 tokens of agent-turn overhead against a verdict of about 50 tokens, which a direct API call would not.
No acceptance criterion here is a saving.

## Deferred, and listed on purpose

Where speed and completeness conflicted this unit chose speed, so an unlisted shortcut would be a defect.
These are recorded as unbuilt rather than described as built:

- **Every live effect.** Batching, deferral classes, urgency promotion, latency budgets, and any path from a verdict to what actually surfaces are separate filed units. Nothing here takes a position on their decisions. `FM_BOSUN_PASS_MAX` bounds one pass so a long backlog cannot run unboundedly; it is not a batching policy and must not be read as one.
- **A real retention policy.** What ships is the same crude size bound the journal uses - two files of `FM_BOSUN_MAX_BYTES` - so a long-running observer cannot fill a supervision host. It does not reason about age, judgement rate, or how far back an audit needs to reach.
- **Per-gap escalation.** Events that aged out below the horizon are escalated. Events that took a journal sequence and never reached disk (the journal's `gaps`) are **reported** by `status` but do not each get their own escalation record. Both are events that will never be judged, and they deserve the same treatment; only the horizon case is built.
- **Accuracy against a labelled set.** Nothing here measures whether the judge is *right*. The survey's recommended false-deferral test against a captain-labelled fleet notification set is exactly what this record now makes possible, and it is not run. Until it is, the verdicts are worth reading and not worth trusting.
- **Prompt and schema tuning.** The judging prompt is one short paragraph, written once. No variant was compared against another.
- **A duplicate-judgement guard.** A pass that dies after judging but before recording re-judges that event, on purpose. Nothing dedupes the two verdicts if both eventually land; the record simply carries both, which is the honest outcome and the cheap one.
- **Restart-safety of a long backlog.** A bosun restarted against a large unjudged backlog will work through it `FM_BOSUN_PASS_MAX` at a time. That is bounded but not prioritised: the oldest events are judged first, and a fresh escalation waits behind them.

## Related

- `docs/event-journal.md` - the stream this reads, and what it does and does not guarantee.
- `docs/supervision-cost.md` - what supervision actually costs, measured from the provider's own usage records.
- `data/fm-bosun-model-survey/report.md` - the model survey, its ranked field, and its unanswered data-residency question.
