# Stow, then clear: the context-reset mechanism

The primary firstmate session accumulates context all day.
The instrument for shedding it is the one this fleet already owns: `/stow` writes durable knowledge to disk, then `/clear` discards the conversation and the next session rebuilds from those records.
This is **not** compaction, and nothing here adds, enables, or recommends compaction.

What was broken was never the instrument.
It was the cadence: `/stow` typically fired at 600k-975k tokens against a decided ceiling of 300k, because a rule the model has to remember to apply has no failure surface at all - nothing anywhere reports a rule that was never applied.

This mechanism moves the observation into the watcher, which already polls, already writes a durable queue firstmate is structurally obliged to drain, and whose own death is already alarmed.
The captain's decision is recorded in `data/decisions/2026-08-02-stow-clear-mechanism.md`; the ceiling itself comes from `data/decisions/2026-08-02-supervision-cost-two-decisions.md` and is unchanged at 300k.

## The loop

```
watcher poll (every FM_CONTEXT_CHECK_INTERVAL)
  no live session holding this home's lock -> say nothing, there is nothing to measure
  read this session's recorded transcript -> context size
    over 300k, and the fleet is quiet?
      captain active, or away mode  -> queue wake: ASK
      captain not present           -> queue wake: RESET
    a session is running but cannot be measured
                                    -> queue wake: the ceiling is UNENFORCED

firstmate drains the wake (already obligatory)
  /stow                     the one step that needs judgement
  bin/fm-stow-receipt.sh    bind a receipt to the transcript position
  bin/fm-context-reset.sh   re-verify everything, then clear
                            -> refuses loudly on any failure, never proceeds

turn ends -> context clears -> SessionStart:clear fires the nudge
          -> the surviving wake-delivery task wakes the fresh session
          -> bin/fm-session-start.sh rebuilds from durable records
```

One firstmate turn per reset.
Everything except `/stow` is plain code: measuring, deciding the fleet is quiet, deciding whether the captain is present, writing and verifying the receipt, and typing the reset into the pane.
Choosing what durable knowledge to file is judgement, and it is the only step a script cannot do honestly.

## Who owns what

| Piece | Owner |
| --- | --- |
| Where this session's transcript is | `bin/fm-sessionstart-nudge.sh` writes `state/.primary-transcript` on every primary session start, including the one a clear creates |
| Ceiling, quiet, and captain-present predicates | `bin/fm-context-lib.sh` |
| The measurement and the reset/ask branch | `bin/fm-watch.sh`'s `context_ceiling_surface` |
| The receipt | `bin/fm-stow-receipt.sh` |
| The refusals and the clear | `bin/fm-context-reset.sh` |
| Typing into the pane | `bin/fm-send.sh` and `bin/fm-tmux-lib.sh`'s verified retried-Enter submit |

The watcher and the reset tool share one definition of every predicate, so the watcher can never enqueue a reset the tool would always refuse.

## What the receipt is, and what it is not

It is an **attestation, not a proof**.
Whether a semantic sweep caught every durable fact cannot be checked mechanically; `decision-hold-lifecycle` is explicit that the agent performs that inventory precisely because scripts must not infer decisions from prose.
A design that claimed otherwise would be lying.

What is structurally real:

- No receipt, no reset.
- A receipt older than `FM_CONTEXT_RECEIPT_MAX_AGE`, no reset.
- A receipt from a different session, bound to a different transcript, or written by a different session process, no reset.
- A transcript that has advanced more than `FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES` past the receipt, no reset.
- Anything the captain said after the receipt was written, no reset - the sweep cannot have covered it.

And the safety net that makes an imperfect sweep survivable: a cleared conversation is not destroyed.
`/clear` closes the transcript and opens a new session id; the old file stays on disk and `claude --resume <old-session-id>` restores it.
A missed finding is misplaced, not lost.

## The two conditions that are never traded away

**Never while the captain is in live conversation.**
The cost is proven, not estimated: the pane's scrollback is wiped, and a message queued during the clear is consumed by the old context and then discarded - the captain sees a reply firstmate does not remember giving.
A silent inconsistency of that kind costs more than the saving.
So the captain-present branch asks; it never acts.
Away mode takes the same branch, because a reset there is the captain's call rather than an autonomous one and the away daemon, not firstmate, owns wake delivery.

**Never before the receipt verifies.**
The receipt is the only claim that this session's knowledge reached disk.
Refusing loudly is always the correct failure.

## How captain presence is decided, without reading a word

Claude Code stamps every user record in the transcript with a structural origin, so provenance needs no text inspection:

| Record shape | Meaning |
| --- | --- |
| `origin.kind == "human"` | a genuine captain prompt (`promptSource` `typed`, `queued`, or `suggestion_accepted`) |
| `origin.kind == "task-notification"`, `promptSource == "system"` | a background-task wake delivery - this is how an unattended session keeps moving, and it must never read as the captain |
| `isMeta: true` | a hook or system injection |
| array content of `tool_result` | a tool result |
| string content, no origin, no promptSource | a slash-command expansion, which only ever follows real captain input, so it counts as human |

The watcher therefore reads exactly three things from the transcript: the last assistant record's token `usage` numbers, the timestamp of the last genuine captain prompt, and the file's byte size.
Message content is never read and never printed.
Every ambiguity resolves toward "the captain is here", because a false quiet costs a discarded conversation and a false busy costs one deferred reset.

## How it fails visibly

A silent non-fire is the defect class this whole line of work exists to remove, so there is no path where nothing happens and nothing shows:

- **It fires and firstmate does not act.** The wake is durable. An enqueued wake that is never drained is already an alarm.
- **The observation stops running.** The watcher's own death is already alarmed by the liveness guard.
- **A session is running here and cannot be measured** - no transcript recorded, an unreadable one, a record naming a different session process than the one holding the home lock, or no `jq`. That is reported as its own wake saying the ceiling is unenforced, throttled to `FM_CONTEXT_ERROR_RESURFACE` so a standing defect reports periodically rather than once or never.
  The live session lock is what makes this an alarm rather than noise: with no session running, there is genuinely nothing to measure, and a fresh home, a home between sessions, and every non-primary home would otherwise carry a permanent false alarm.
  The record and the lock are keyed on the same session process on purpose, so a disagreement between them means the record describes a session that has finished - measuring it would report the wrong number rather than no number, which is why that case is reported instead of used.
- **The way back in is broken.** If `clear` ever leaves the `SessionStart` matcher, or the nudge script goes missing, the wake reports the blocker instead of ordering a reset, and the reset tool refuses. Without that check a reset would be a silent decapitation: context discarded, no rebuild instruction, a live fleet and an idle firstmate.
- **A reset is attempted and refused.** Every refusal prints its concrete reason and appends one line to `state/.context-reset.log`.

## Every refusal the reset tool makes

Run `bin/fm-context-reset.sh --check` to evaluate all of them and clear nothing.

1. The recorded transcript is missing, in its error state, or unreadable.
2. The recorded session is not the session running the command - only a session may reset itself.
3. No receipt, a receipt not in its `ok` state, or one whose session, process, or transcript does not match.
4. The receipt is older than its freshness bound.
5. The transcript has moved on past the receipt, or shrunk below it.
6. The captain has spoken since the receipt was written.
7. Away mode is active.
8. The captain has been active within `FM_CONTEXT_CAPTAIN_IDLE_SECS`.
9. The fleet is no longer quiet: an undrained wake, a routed request awaiting its reply, or a worker waiting on an answer.
10. The re-entry hook no longer runs `bin/fm-sessionstart-nudge.sh` on a clear, or that script is gone.
11. Supervision is not running.
12. Wake delivery is not armed while this home has recorded work or an X-mode relay - with nothing to wake for, an unarmed delivery wait does not block.
13. The harness is not `claude`, or the terminal backend is not `tmux`.
14. This session's own pane cannot be identified.

There is no force flag.

## Scope, and what is deliberately not covered

Self-clear is proven end to end on **claude over tmux** and nowhere else.

- **grok**: its `SessionStart` output does not reach model context at all, so a clear there would decapitate the session rather than restart it. The reset tool refuses.
- **codex**: `/new` and `/clear` exist in codex-cli 0.145.0, but whether its `SessionStart` hook fires on them, and with what source, is unverified. The reset tool refuses.
- **opencode, pi**: untested. The reset tool refuses.

Extending this to another harness means proving that harness's re-entry path first, then widening the check in `bin/fm-context-reset.sh` - never the other way round.

## Verified behaviour

Recorded during the design investigation (`data/fm-stow-clear-mechanism-design/report.md`, 2026-08-02, Claude Code 2.1.220 on tmux), in a disposable lab session, never against a primary:

| Link | Result |
| --- | --- |
| A session can clear itself from inside | 4/4 clears, memory verifiably gone each time |
| The clear lands at a turn boundary, not mid-turn | The triggering turn completed first; work in progress is never truncated |
| The old conversation survives and is resumable | `claude --resume <id>` recalled a pre-clear codeword |
| `SessionStart` fires with `source=clear` and the injected instruction is obeyed | The fresh session ran the injected command before answering anything else |
| Supervision survives the reset | A background task survived the clear, completed, and woke the new session |
| The session lock survives | Same harness pid before and after; the lock is keyed on the harness process, which a clear does not restart |

Measured on 2026-08-03 against the live primary transcript, with the bounded tail reader this mechanism uses:

```
$ fm_context_scan "$transcript"
tokens=947650   (full-file jq parse: 947650 - identical)
```

947,650 tokens against a 300,000 ceiling, read in 78 ms from a 7.4 MB transcript.
That overshoot, sitting there unremarked, is the drift this mechanism exists to end.

## Tunables

All read from the environment, all with working defaults; `bin/fm-context-lib.sh` owns them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FM_CONTEXT_CEILING` | `300000` | the captain's decided ceiling, in tokens |
| `FM_CONTEXT_CAPTAIN_IDLE_SECS` | `1800` | silence after which the captain is not in live conversation |
| `FM_CONTEXT_RECEIPT_MAX_AGE` | `900` | how long a receipt stays fresh |
| `FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES` | `262144` | how far the transcript may advance under a receipt |
| `FM_CONTEXT_TAIL_BYTES` | `2097152` | bounded trailing read of the transcript |
| `FM_CONTEXT_CHECK_INTERVAL` | `300` | seconds between watcher ceiling reads |
| `FM_CONTEXT_ERROR_RESURFACE` | `3600` | quiet period before an unmeasurable ceiling reports again |

## State this mechanism owns

All under `state/`, all gitignored:

| File | Written by | Meaning |
| --- | --- | --- |
| `.primary-transcript` | `bin/fm-sessionstart-nudge.sh` | where this session's transcript is and which session process owns it |
| `.stow-receipt` | `bin/fm-stow-receipt.sh` | knowledge filed, bound to a transcript position; removed on a completed reset |
| `.context-reset.log` | `bin/fm-context-reset.sh` | one durable line per refusal, `--check` pass, or completed reset |
| `.last-context-check` | `bin/fm-watch.sh` | ceiling-read cadence, as an mtime, so it survives a watcher restart |
| `.context-measure-error` | `bin/fm-watch.sh` | throttle for the "cannot measure" report; cleared as soon as a poll can measure |
