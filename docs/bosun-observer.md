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
A retained journal that exists but cannot be read produces a stream-level escalation and the distinct `BLIND` health state rather than being mistaken for an empty stream.
The `judge` field names which of those produced each verdict, so a verdict a model reached and one the failure path reached are never confused.

Nothing is ever skipped:

- The cursor advances only **after** a verdict record reaches disk. A pass that dies between judging and recording re-judges that event next pass. That costs one duplicate judgement; the other order costs a silently unjudged event, which is the failure this tier exists against.
- Events that fell below the journal's retention horizon before the bosun reached them are recorded as one escalation naming the range, rather than stepped over in silence.

## What is proven, and how

`tests/fm-bosun.test.sh` drives the real run loop, and events reach the journal through the real wake library rather than as hand-written journal rows.
Judges are fakes on purpose: this suite tests the bosun's handling of every judge outcome, and a real model cannot be made to time out on demand.

Eight load-bearing assertions were mutation-checked on 2026-08-12 rather than trusted for being green:

| Mutation | Caught by |
|---|---|
| Never detect a stall | `a bosun that keeps passing but stops judging reports STALLED` |
| Always report STALLED | `an idle bosun with an empty journal reports QUIET` |
| Never detect an unreadable retained journal | `an unreadable retained journal reports BLIND` |
| Always report a journal unreadable | `a genuinely absent journal reports QUIET` |
| Let an unsure judge's "routine" stand | `judge-is-unsure: expected escalate, got 'routine'` |
| Let an unparseable answer be routine | `judge-prints-garbage: expected escalate, got 'routine'` |
| Skip aged-out events silently | `events below the retention horizon were skipped without a record` |
| Write one line to a task's status file | `a bosun pass changed supervision state outside its own directory` |

Both directions of the quiet/stalled discrimination are checked against the same fixture, because a check that only ever reports one of the two proves nothing about its ability to tell them apart.

The journal seam was mutation-checked the same way on 2026-08-16, one reach at a time, by hard-wiring each back to `bin/fm-journal.sh` and rerunning the suite:

| Mutation | Caught by |
|---|---|
| Read the retention horizon from the real journal | `the horizon read did not go through the journal seam` |
| Read the batch from the real journal | `the batch read did not go through the journal seam` |
| Read the journal head from the real journal | `the health record's journal head came from the real journal, not the seam` |
| Read the gap count from the real journal | `the reported journal gap count came from the seam` |

Each reach is caught by its own assertion, which is what makes partial adoption impossible to land: a seam honoured by the pass and not by `status` would leave the two halves of the module reporting against different journals, and that is worse than uniform hard-wiring.

Separately, a live run against the real judge and the real journal on 2026-08-12 judged three events correctly: ordinary progress as `routine`, a revoked deploy key as `escalate`, and a PR awaiting review as `escalate`, at 3.5-7.7 seconds each.

## Keeping it running

A judging tier that stops when whoever started it walks away is not a tier.
`bin/fm-bosun-service.sh` and `systemd/fm-bosun@.service` give it a per-home lifetime; [`docs/configuration.md`](configuration.md) "Bosun observer service" owns the opt-in, the consent gate, the recorded environment, and the convergence rules.
Two things about it belong here, because they follow from what this unit is.

**Its health is read from its own work, never from the unit's state.**
On this host `bridge-notify-poll.timer` reported loaded, enabled and active for nine days after it last fired.
"The process is up" was already the evidence this unit was built not to accept, and "the unit says active" is the same evidence one layer out, so the service reads `bin/fm-bosun.sh status` and never `systemctl is-active`.
That reading was checked against the failure it exists for on 2026-08-16: with the observer's own process frozen under `SIGSTOP`, `systemctl --user show` reported `ActiveState=active` and `SubState=running` while the reading returned `DEAD - no pass for 105s, past 3 missed passes of a 30s interval` at exit 1.
Both surfaces were asked the same question at the same moment and only one of them was right.

**A stall is reported and not restarted.**
`STOPPED` and `DEAD` mean nothing is consuming the journal and are converged automatically; `STALLED` and `BLIND` mean something is running and has stopped consuming, and bouncing the service would clear the symptom while hiding the fault.

The rest was proven end to end on this seat the same day, against the real judge and a real journal: the unit started and read `WORKING` at exit 0 with two events outstanding, the cursor advanced 0 to 2 as `codex:gpt-5.6-luna` judged both in about 4.2 seconds each, the reading settled to `QUIET`, `systemctl --user stop` produced `STOPPED` at exit 1, locked convergence brought it back, and a `SIGKILL` of the main process was recovered by the unit on its own - reclaiming the run lock the killed process never released and judging a newly arrived event.

The stall clock deliberately survives a restart, which is why a crash loop cannot hide inside it: a run that restarts, writes its start beacon, judges nothing and dies would otherwise reset the clock every time and never reach `STALLED`.
The beacon itself is written before the first pass, because without it a bosun working through a long backlog reads from outside as whatever the previous run left on disk for as long as that pass takes.

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

The journal command is a seam on the same pattern.
`FM_BOSUN_JOURNAL_CMD` is the module's only route to the journal command interface, and every command query it makes - the retention horizon, the batch, and both queries `status` makes - goes through that one command prefix, so a caller substituting a stream substitutes it for the whole module rather than for half of it.
The retained-file readability guard remains a direct filesystem check and runs before the substituted command, because it diagnoses whether the stream files the bosun is responsible for retaining are readable rather than querying the journal interface.
It carries no configuration file, because unlike the model this is not a live choice a home makes.

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
- **A crash loop against an empty journal.** A bosun that starts, writes its beacon, dies, and is restarted reads as `STALLED` once events are waiting, because the stall clock survives the restart and the cursor never moves. With nothing waiting it reads `QUIET`, which is the same word a healthy idle bosun gets. The window closes on its own the moment an event arrives and the stall bound elapses, and nothing narrower is built.
- **Restart-safety of a long backlog.** A bosun restarted against a large unjudged backlog will work through it `FM_BOSUN_PASS_MAX` at a time. That is bounded but not prioritised: the oldest events are judged first, and a fresh escalation waits behind them.

## Related

- `docs/configuration.md` "Bosun observer service" - how a home opts in, and how the unit is installed and converged.
- `docs/event-journal.md` - the stream this reads, and what it does and does not guarantee.
- `docs/supervision-cost.md` - what supervision actually costs, measured from the provider's own usage records.
- `data/fm-bosun-model-survey/report.md` - the model survey, its ranked field, and its unanswered data-residency question.
