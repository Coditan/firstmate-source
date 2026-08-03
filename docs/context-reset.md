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

turn ends -> context clears -> SessionStart:clear fires (the nudge itself stays
                              silent on a self-clear, see below)
          -> the surviving wake-delivery task wakes the fresh session
          -> AGENTS.md section 3 tells the fresh session to run
             bin/fm-session-start.sh, which rebuilds from durable records
```

One firstmate turn per reset.
Everything except `/stow` is plain code: measuring, deciding the fleet is quiet, deciding whether the captain is present, writing and verifying the receipt, and typing the reset into the pane.
Choosing what durable knowledge to file is judgement, and it is the only step a script cannot do honestly.
What that sweep owes this mechanism when a ceiling wake calls it is owned by the `stow` skill.

## Who owns what

| Piece | Owner |
| --- | --- |
| Where this session's transcript is | `bin/fm-sessionstart-nudge.sh` writes `state/.primary-transcript` on every primary session start, including the one a clear creates; [docs/sessionstart-nudge.md](sessionstart-nudge.md) owns that record's own contract, and this mechanism only consumes it |
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
- A captain timestamp that could not be established at all, no reset - the receipt records that state as `unknown` rather than as an empty field, so it refuses instead of matching itself.

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

**An absent record is not evidence of absence.**
The read is bounded to the last `FM_CONTEXT_TAIL_BYTES` so that one watcher poll can never become an unbounded read of a multi-hundred-megabyte transcript.
That bound is also the one thing that can hide a captain prompt: the captain types, the session answers them with more than one whole tail of tool output, and the bounded read finds no captain record at all.
Reading that as silence would put a reset in the middle of a live conversation, which is the single outcome this mechanism forbids, so it is not a cost to trade against a probability.

The rule, in three steps:

1. Read the bounded tail, and publish whether that read covered the whole file (`FM_CONTEXT_SCAN_TRUNCATED`).
2. If the bounded read found no captain record **and** did not cover the whole file, widen once to the whole file and use whatever that finds (`FM_CONTEXT_SCAN_WIDENED`).
   Never widen when the bounded read already covered everything, because there is nothing further to find and the cost would be paid on every poll of an idle session.
3. If a complete read still finds no captain record, fail closed: the captain counts as **present**.
   The honest reading of that state is not "the captain is gone", it is "this transcript cannot say", and only one of those two is safe to act on.

The receipt carries the same distinction rather than flattening it.
`bin/fm-stow-receipt.sh` records an unestablished captain timestamp as `unknown`, never as an empty field, because the reset tool's captain check is an equality and two empty fields would compare equal and pass it while proving nothing at all.

## How it fails visibly

A silent non-fire is the defect class this whole line of work exists to remove, so there is no path where nothing happens and nothing shows:

- **It fires and firstmate does not act.** The wake is durable. An enqueued wake that is never drained is already an alarm.
- **The observation stops running.** The watcher's own death is already alarmed by the liveness guard.
- **A session is running here and cannot be measured** - no transcript recorded, an unreadable one, a record naming a different session process than the one holding the home lock, or a missing `jq` or `perl` (the bounded tail read needs both). That is reported as its own wake saying the ceiling is unenforced.
  The live session lock is what makes this an alarm rather than noise: with no session running, there is genuinely nothing to measure, and a fresh home, a home between sessions, and every non-primary home would otherwise carry a permanent false alarm.
  The record and the lock are keyed on the same session process on purpose, so a disagreement between them means the record describes a session that has finished - measuring it would report the wrong number rather than no number, which is why that case is reported instead of used.
- **The way back in is broken.** If `clear` ever leaves the `SessionStart` matcher, or the nudge script goes missing, the wake reports the blocker instead of ordering a reset, and the reset tool refuses. That check proves the hook is still wired and its script is still there; what carries the fresh session's rebuild instruction after a self-clear is `AGENTS.md` section 3, for the reason in "the way back in, precisely" below.
- **A reset is attempted and refused.** Every refusal prints its concrete reason and appends one line to `state/.context-reset.log`.

Every wake the watcher raises here - `reset`, `ask`, `blocked`, and `unenforced` alike - is reported at most once per `FM_CONTEXT_ERROR_RESURFACE` while the condition behind it is unchanged.
Every branch here describes a condition rather than an event - a present captain stays present, a broken hook stays broken, an unmeasurable transcript stays unmeasurable - so repeating any of them on the poll cadence would spend a model turn every five minutes on news that has not changed, which is the opposite of what this mechanism is for.
The throttle is keyed on a branch class the predicate publishes as a stable token, never on the payload's wording, so rewording a message can never quietly merge two conditions under one key.
A condition that *changes* surfaces on the very next poll: a captain who goes away does not have to wait out the ask throttle before the reset branch can fire.

The throttle is cleared only when the condition genuinely resolves - nothing is running in this home, or the session is back under the ceiling.
A poll that finds the fleet busy is a different thing entirely, and leaves the throttle alone.
This distinction is load-bearing rather than pedantic: the ceiling wake is appended to `state/.wake-queue`, an undrained queue is the first thing that makes a poll non-quiet, and only firstmate drains it from inside a turn.
Treating "nothing to say this poll" as "the condition is gone" would let every ceiling wake erase its own throttle and come back once per drain cycle.

## The way back in, precisely

The re-entry check proves one thing: the `SessionStart` hook still matches `clear`, still runs `bin/fm-sessionstart-nudge.sh`, and that script is still present and executable.
It does not prove a rebuild instruction is delivered, and on the self-clear this mechanism performs, none is.
`bin/fm-sessionstart-nudge.sh` exits silently whenever the pid in `state/.lock` is an ancestor of the hook process, and `state/.lock` holds the harness process pid, which a self-clear does not restart - the same fact the reset tool relies on when it refuses unless that lock pid is in its own ancestry.
So the hook fires and injects nothing.

What the fresh session rebuilds from instead is `AGENTS.md` section 3, which is always loaded and already says to run `bin/fm-session-start.sh` before anything else.
That is the weaker of the two paths: an always-loaded instruction the model must follow, rather than an injected one placed at the top of a fresh context.
It is why the wiring check stays a hard precondition even though it cannot prove delivery - unwiring the hook or deleting the script would leave that fallback with nothing behind it at all.
Repairing the nudge so it emits when the hook payload's `source` is `clear` is filed as separate work on that script.

## Every refusal the reset tool makes

Run `bin/fm-context-reset.sh --check` to evaluate all of them and clear nothing.

1. This home's `state/` directory is missing, or the recorded transcript is missing, in its error state, or unreadable.
2. No live session holds this home's lock, that lock belongs to another session, or the recorded session is not the session running the command - only the session operating this home may reset itself.
3. No receipt, a receipt not in its `ok` state, or one whose session, process, or transcript does not match.
4. The receipt is older than its freshness bound, or its write time is unreadable or in the future.
5. The transcript has moved on past the receipt, shrunk below it, or the receipt records no readable position at all.
6. The captain has spoken since the receipt was written.
7. The captain's last message could not be established at all, from the receipt or from the transcript. Two unknowns must refuse rather than compare equal; see "an absent record is not evidence of absence" above.
8. Away mode is active.
9. The captain has been active within `FM_CONTEXT_CAPTAIN_IDLE_SECS`.
10. The fleet is no longer quiet: an undrained wake, a routed request awaiting its reply, or a worker waiting on an answer.
11. The re-entry hook is no longer wired: it no longer runs `bin/fm-sessionstart-nudge.sh` on a clear, or that script is gone. This checks the wiring, not that anything is injected; see "the way back in, precisely" above.
12. Supervision is not running.
13. Wake delivery is not armed while this home has recorded work or an X-mode relay - with nothing to wake for, an unarmed delivery wait does not block.
14. The harness is not `claude`, or the terminal backend is not `tmux` - including a backend that could not be detected at all, because the clear must never be typed on a guess.
15. This session's own pane cannot be identified, or its target cannot be resolved.
16. This session's own pane is in a tmux session whose name begins with `fm-`. That prefix is reserved: `bin/fm-send.sh` reads any such target as a recorded worker-task selector and looks for its metadata instead of resolving a live tmux endpoint, so the clear could never be typed. The refusal names that cause so an operator can rename the terminal session; it is a limitation of this mechanism on such homes, not a fault in the send path.

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
| `SessionStart` fires with `source=clear` and the injected instruction is obeyed | The fresh session ran the injected command before answering anything else. Proven in a lab session that held no home lock, which is why it does not carry over to a locked primary: there the nudge sees its own lock pid in its ancestry and exits silently, so nothing is injected and `AGENTS.md` section 3 carries the rebuild instead |
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

All read from the environment, all with working defaults.
`bin/fm-context-lib.sh` defines the measurement bounds - `FM_CONTEXT_CEILING`, `FM_CONTEXT_CAPTAIN_IDLE_SECS`, `FM_CONTEXT_RECEIPT_MAX_AGE`, `FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES`, `FM_CONTEXT_TAIL_BYTES` - and `bin/fm-watch.sh` defines the observation cadence, `FM_CONTEXT_CHECK_INTERVAL` and `FM_CONTEXT_ERROR_RESURFACE`.
[docs/configuration.md](configuration.md) lists all seven with their defaults, alongside every other runtime variable.

## State this mechanism owns

All under `state/`, all gitignored:

| File | Written by | Meaning |
| --- | --- | --- |
| `.stow-receipt` | `bin/fm-stow-receipt.sh` | knowledge filed, bound to a transcript position; removed on a completed reset |
| `.context-reset.log` | `bin/fm-context-reset.sh` | one durable line per refusal, `--check` pass, or completed reset |
| `.last-context-check` | `bin/fm-watch.sh` | ceiling-read cadence, as an mtime, so it survives a watcher restart |
| `.context-ceiling-surfaced` | `bin/fm-watch.sh` | the branch class last reported (`reset`, `ask`, `blocked`, `unenforced`), as content, and when it was reported, as an mtime; throttles an unchanged condition, and is cleared only when the condition genuinely resolves |
