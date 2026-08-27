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
  a session is running but cannot be measured
                                    -> queue wake: the ceiling is UNENFORCED
  read this session's recorded transcript -> context size
    over 300k, and the fleet is quiet?
      re-entry path broken          -> queue wake: BLOCKED
      captain counts as present, or away mode
                                    -> queue wake: ASK
      captain not present           -> queue wake: RESET

firstmate drains the wake (already obligatory)
  RESET wake only:
    /stow                     the one step that needs judgement
    bin/fm-stow-receipt.sh    bind a receipt to the transcript position
    bin/fm-context-reset.sh   re-verify everything, then clear
                              -> refuses loudly on any failure, never proceeds
  ASK, BLOCKED, or UNENFORCED wake:
    report or repair the condition named in the wake; never run the reset order
  ASK wake, and the captain then answers yes:
    /stow, the receipt, then bin/fm-context-reset.sh --captain-approved
    the authority is the captain's answer, never the wake

after RESET succeeds:
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
| Where this session's transcript is | `bin/fm-sessionstart-nudge.sh` writes `state/.primary-transcript` on every primary session start this home's lock is not already held against, including the one a clear creates; [docs/sessionstart-nudge.md](sessionstart-nudge.md) owns that record's own contract, the lock gate, and what a session does when it cannot name its own process, and this mechanism only consumes the record |
| Ceiling, quiet, and captain-present predicates | `bin/fm-context-lib.sh` |
| The measurement and the reset, ask, blocked, or unenforced branch | `bin/fm-watch.sh`'s `context_ceiling_surface` |
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
- A receipt older than `FM_CONTEXT_RECEIPT_MAX_AGE`, no reset - on the autonomous path.
  On the captain-approved path that window is replaced by the condition it stood in for, that the receipt was filed after the approval; see "when the captain approves" below.
- A receipt from a different session, bound to a different transcript, or written by a different session process, no reset.
- A transcript that has advanced more than `FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES` past the receipt, no reset.
- Anything the captain said after the receipt was written, no reset - the sweep cannot have covered it.
- A captain timestamp that could not be established at all, no reset - the receipt records that state as `unknown` rather than as an empty field, so it refuses instead of matching itself.

And the safety net that makes an imperfect sweep survivable: a cleared conversation is not destroyed.
`/clear` closes the transcript and opens a new session id; the old file stays on disk and `claude --resume <old-session-id>` restores it.
A missed finding is misplaced, not lost.

## The two conditions that are never traded away

**Never while the captain is in live conversation, unless the captain is the one who asked for it.**
The cost is proven, not estimated: the pane's scrollback is wiped, and a message queued during the clear is consumed by the old context and then discarded - the captain sees a reply firstmate does not remember giving.
A silent inconsistency of that kind costs more than the saving.
So the captain-present branch asks; it never acts.
Away mode takes the same branch, because a reset there is the captain's call rather than an autonomous one and the away daemon, not firstmate, owns wake delivery.
What the captain may then answer is the subject of "when the captain approves" below.

**Never before the receipt verifies.**
The receipt is the only claim that this session's knowledge reached disk.
Refusing loudly is always the correct failure.

## When the captain approves

The captain-present branch asks, and asking is only worth doing if a yes can be acted on.
Until 2026-08-10 it could not be, and the reason was arithmetic rather than logical, which is why reading the code never found it.

`bin/fm-context-reset.sh` had two windows that both had to be open at the instant of the reset:

- the receipt had to be younger than `FM_CONTEXT_RECEIPT_MAX_AGE`, 900 seconds; and
- the captain had to have been silent for `FM_CONTEXT_CAPTAIN_IDLE_SECS`, 1800 seconds.

On the autonomous path those two agree by construction, because that path only ever runs when the captain is already quiet.
On the asking path the captain's approval is what starts the reset, so the idle window is measured from the moment the captain spoke and demands a silence twice as long as the receipt is allowed to live.
Both could never be open at once, on that path, ever.
Every reset this mechanism has ever completed came through the autonomous branch and none through the asking one - a count measured on 2026-08-08, before the cause was known, and explained by this arithmetic rather than by chance.

`--captain-approved` is the path for a reset the captain asked for:

- **The idle window does not apply.**
  It exists to INFER the captain's absence from silence, and an explicit approval is the consent that silence was only ever a proxy for.
  Approval is stronger evidence than silence, not weaker, so it replaces the inference rather than sitting beside it; applying both does not make the path strict, it makes it unreachable.
- **The receipt's age window is replaced by the condition it stood in for**: the receipt was filed AFTER the approval.
  That needs no constant, cannot deadlock - filing follows approval by construction here - and states the requirement directly.
  Stretching 900 seconds to a larger number would pick a constant that is wrong for some other session and leave the same class of deadlock waiting.
- **The transcript-growth bound is untouched.**
  It carries the real safety property, measured directly from the transcript against the receipt's own `transcript_bytes`, and no approval buys past it: if this session moved on since its knowledge was filed, the reset refuses.
- **The captain-equality check is untouched**, so the approval can only ever be the LAST thing the captain said.
  An older yes with a newer message behind it refuses on the ordinary "the captain has spoken since the receipt was written".
- **Away mode still refuses.**
  A captain present enough to approve a reset has returned, and away mode should be exited first.
- **The approval is re-read immediately before the clear is typed**, and that check exists only on this path.
  Every other check runs once, well before the harness probe, the pane resolution, and the `tmux display-message` round trips that follow it; the captain can type in that gap, and here the captain is present by construction, so it is an ordinary occurrence rather than an edge case.
  The idle window is what covered that gap on the autonomous path, so dropping it is what opened it, and closing it belongs to the same change.
  As the last act before the send, the last captain record is read again and compared against both the id and the timestamp of the record taken as the approval.
  Anything else refuses and names both records; a transcript that can no longer be read refuses too, because nothing then shows the captain stayed silent.
  The message says plainly that the captain spoke after approving and that a fresh approval is needed, so the answer is to go back and ask rather than to guess.

### What this path proves, and what it cannot

It proves a real captain record exists in the transcript, when it arrived, and that this session's knowledge was filed after it.
It cannot prove that record MEANT approval.
Semantic consent is not machine-checkable, and the party invoking the reset is the same party claiming the approval exists, so a flag that implied otherwise would be theatre.

The path is therefore built for verification where verification is possible and for AUDIT where it is not:

- The approval is derived from an actual human record in the transcript, never from the flag alone.
  With no such record the reset refuses rather than proceeding on an unbacked assertion.
- Every approved run names the exact record it relied on - its `uuid` and its timestamp - on stdout and in `state/.context-reset.log`, as `path=captain-approved approval-record=<uuid> approval-ts=<ts>`.
  A record the log could not cite refuses too, because a reset nobody can check afterwards is a reset nobody checked.
- The wording says as much.
  The tool's help and its stdout state that it verified the record exists and that the filing followed it, never that the captain agreed.

The log marker is written as `path=` fields rather than prose because the autonomous idle refusal names the flag in its own text - pointing at the path from the one place it becomes relevant - and a marker that a message can imitate is not a marker.

The watcher's ask branch still carries no reset command, deliberately.
The wake is a diagnosis; the authority for this path is the captain's answer, and nothing the watcher writes can stand in for it.

## How captain presence is decided

Two tests decide it, in this order, and the order is the whole point.

**First the marker, then the provenance.**
Any string-content user record that `bin/fm-operational-input.sh` classifies is a Firstmate delivery and is dropped, whatever provenance it carries.
Only what survives that is read for its structural origin fields.

| Record shape | Meaning |
| --- | --- |
| classified by `bin/fm-operational-input.sh`, on any provenance at all | a Firstmate delivery: current `FIRSTMATE_OP` kinds, `from-firstmate`, and the legacy operational forms. Never captain activity |
| `origin.kind == "human"`, unmarked | a genuine captain prompt (`promptSource` `typed`, `queued`, or `suggestion_accepted`) |
| `origin.kind == "task-notification"`, `promptSource == "system"` | a background-task wake delivery - this is how an unattended session keeps moving, and it must never read as the captain |
| `isMeta: true` | a hook or system injection |
| array content of `tool_result` | a tool result |
| string content, no origin, no promptSource, unmarked | an unattributed but unmarked user message, including slash-command expansion output; it still counts as human so ambiguity blocks autonomous reset |

**Provenance cannot separate Firstmate from the captain, because Firstmate speaks through the captain's own input channel.**
Until 2026-08-20 the marker test ran only on the last row - records with no origin and no promptSource - on the belief that a structural origin was enough for everything above it.
It is not.
A wake reaches the session by being TYPED into its pane, so the harness stamps it `origin.kind == "human"`, `promptSource == "typed"`: byte for byte the provenance of a captain prompt.
The structural test matched first, the classifier was never consulted, and every delivered wake re-dated the captain to the moment of its own delivery.

That made the mechanism defeat itself, and the shape is worth stating plainly because nothing about it is specific to this seat.
The watcher picked the reset branch at the moment it EMITTED the wake, and the act of delivering that wake wrote the record that made `bin/fm-context-reset.sh` refuse the very order it had just given.
The reset branch could not be carried out on any seat that receives wakes, which is every seat.
Measured on this home 2026-08-20: four such cycles over three hours, with the ask branch interleaving.

The same fact killed the widening rule below without anyone being able to see it.
The bounded tail of a busy session always holds a delivered wake, every wake counted as a captain record, so a record was always "found" and the widen never ran.
Fixing the classification is what makes that path load-bearing for the first time.

The shared scan publishes exactly four things from the transcript: the last assistant record's token `usage` numbers, the timestamp of the last genuine captain prompt, that same record's own `uuid`, and the file's byte size.
The id is there because the captain-approved path has to NAME the record it treated as the approval, and a clock reading cannot name one.
Message content is inspected only for `bin/fm-operational-input.sh`'s syntactic operational-input classification and is never printed; a record id is the same structural metadata as the origin fields above, not content.
Every ambiguity resolves toward "the captain is here", because a false quiet costs a discarded conversation and a false busy costs one deferred reset.

**What this costs, stated rather than hidden.**
`bin/fm-operational-input.sh` says plainly that a successful parse proves syntax and never sender identity: the marker is copyable and authenticates nobody.
Running it ahead of provenance therefore means a captain message that happens to match one of those forms exactly would not count as captain activity.
That is accepted rather than overlooked, for two reasons.
It is unreachable by accident - the current forms open with U+2063, and the legacy ones require an exact full-string or long multi-line match - and there is no third option available: a delivered wake and a captain prompt are identical in every structural field, so either the marker decides or nothing does.
The cost of getting it wrong in that direction is one captain message not blocking a reset that still has to pass the receipt, the quiet check and the growth bound; the cost of the alternative was a mechanism that could not fire at all.

Only Claude reaches any of this.
The transcript path comes solely from `state/.primary-transcript`, and `bin/fm-sessionstart-nudge.sh` records `status=error`, `error=no-hook-payload` on Codex, Grok, OpenCode and Pi, because none of their registrations hands the wrapper a payload on stdin - Codex drains it before executing the wrapper, the other three pass no input at all.
`fm_context_record_read` refuses an error record, so `fm_context_scan` never runs there.
`bin/fm-operational-input.sh` itself is unchanged and its other consumers on every harness are unaffected.

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
- **A session is running here and cannot be measured** - no transcript recorded, an unreadable one, a record naming a different session process than the one holding the home lock, or a missing `jq` or `perl` (the bounded tail read needs both). That is reported as its own wake saying the ceiling is unenforced, and every repeat of it says how long that has been true; see "an absent protection is not routine traffic" below.
  The live session lock is what makes this an alarm rather than noise: with no session running, there is genuinely nothing to measure, and a fresh home, a home between sessions, and every non-primary home would otherwise carry a permanent false alarm.
  The record and the lock are keyed on the same session process on purpose, so a disagreement means the record does not describe the current lock holder - measuring it would report the wrong number rather than no number, which is why that case is reported instead of used.
- **The way back in is broken.** If `clear` ever leaves the `SessionStart` matcher, or the nudge script goes missing, the wake reports the blocker instead of ordering a reset, and the reset tool refuses. That check proves the hook is still wired and its script is still there; what carries the fresh session's rebuild instruction after a self-clear is `AGENTS.md` section 3, for the reason in "the way back in, precisely" below.
- **A reset is attempted and refused.** Every refusal prints its concrete reason and appends one line to `state/.context-reset.log`.

### What firstmate repairs, and what it must not

Only a missing or unreadable `state/.primary-transcript` record, or one whose recorded session pid differs from the lock pid, has no in-session repair: `bin/fm-sessionstart-nudge.sh` re-records it only on a fresh primary session start, so never hand-write that record.
A blocked wake means the re-entry hook or its `.claude/settings.json` needs repair, and both are the firstmate repo's shared tracked material: fix them through the `AGENTS.md` section 1 pipeline and PR path, delegating to a worker while the fleet is live, never by editing them in place.
Either condition is reported to the captain in `AGENTS.md` section 9 language.

### An absent protection is not routine traffic

The wake above is only half of the job, and the other half was measured failing.
On 2026-08-19 this home's ceiling was unenforced from one session start onward; the wake fired once an hour for the whole day, word-for-word identical every time, and nothing was repaired.
Two vessels found the underlying defect, both because the wake said precisely what was wrong - so the diagnosis was never the problem.
The repeat was.
An identical line read as a line that had already been read, and what no report could say was that it was not the first.

The branches divide on one question the predicate now publishes as `FM_CONTEXT_CEILING_PROTECTION`: is the ceiling being applied at all?

| Class | Protection | Why |
|---|---|---|
| `unenforced` | absent | no number can be read from this session |
| `blocked` | absent | a number can be read, but the reset it would order cannot run |
| `ask` | present | the ceiling is working; a captain who is present is a reason to wait |
| `reset` | present | the ceiling is working, and this is it working |

Only the absent classes report differently on a repeat.
The first report of one states the condition and nothing more.
Every later report keeps that diagnosis verbatim and adds what only a repeat can know: when the protection went, how long it has been gone, and how many reports it has survived.
It closes by naming the only two things left to do with an absence nobody has repaired - repair it through its owner, or tell the captain plainly that it stands unrepaired - which is what `AGENTS.md` section 8 already requires of a ceiling wake that names a condition rather than a next step.

Three things are deliberately not done here.
The cadence is untouched, so nothing is made louder - `FM_CONTEXT_ERROR_RESURFACE` still governs every class, and the volume of the working classes is not raised to carry the absent one.
The diagnosis is never rewritten, shortened, or generalised, because making a warning louder by making it vaguer would remove the property that let both vessels find this at all.
And there is no threshold to tune: the second report IS the escalation, since one resurface period has passed with a protection missing and nothing done, which is the definition of not routine.

`state/.context-ceiling-absent-since` carries `<class> <first-report-epoch> <reports>` as content rather than as an mtime, because the mtime moves on every rewrite and the whole value of the record is the moment that did not move.
A change of class restarts it - a ceiling that stopped being unmeasurable and started being unresettable is a different absence, and dating the new one from the old would report an age that never happened.
A resolved condition clears it, so the next outage reports as a first one.

Every wake the watcher raises here - `reset`, `ask`, `blocked`, and `unenforced` alike - is reported at most once per `FM_CONTEXT_ERROR_RESURFACE` while the condition behind it is unchanged.
Every branch here describes a condition rather than an event - a present captain stays present, a broken hook stays broken, an unmeasurable transcript stays unmeasurable - so repeating any of them on the poll cadence would spend a model turn every five minutes on news that has not changed, which is the opposite of what this mechanism is for.
The throttle is keyed on a branch class the predicate publishes as a stable token, never on the payload's wording, so rewording a message can never quietly merge two conditions under one key.
The ask payload names which condition took that branch - a captain who spoke, away mode, or a presence that could not be established - and that clause is deliberately not part of the key: all three mean the same thing to do, so moving between them is not a change worth a fresh wake.
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
They are listed in the order they are evaluated, which is the order they fire in when more than one is true.

1. This home's `state/` directory is missing, or the recorded transcript is missing, in its error state, or unreadable.
2. No live session holds this home's lock, that lock belongs to another session, or the recorded session is not the session running the command - only the session operating this home may reset itself.
3. No receipt, a receipt not in its `ok` state, or one whose session, process, or transcript does not match.
4. The receipt is older than its freshness bound, or its write time is unreadable or in the future. The freshness bound is not applied on the captain-approved path; refusal 8 replaces it there.
5. The transcript has moved on past the receipt, shrunk below it, or the receipt records no readable position at all. This one applies identically on both paths.
6. The captain's last message could not be established at all, from the receipt or from the transcript. Two unknowns must refuse rather than compare equal; see "an absent record is not evidence of absence" above. On the captain-approved path this is also the refusal for having no record to cite as the approval.
7. The captain has spoken since the receipt was written.
8. On the captain-approved path only: the captain record carries no id the log could cite, its timestamp is unreadable, or the receipt was filed before it rather than after. A same-second filing reads as not-after and refuses, which biases the one ambiguous case toward refusing and costs at most a second.
9. Away mode is active - on either path.
10. The captain counts as present. Not applied on the captain-approved path, where the approval replaces the inference; see "when the captain approves" above.
    Three different conditions reach this refusal and it names which one it hit: the captain has been active within `FM_CONTEXT_CAPTAIN_IDLE_SECS`, the captain's last timestamp could not be read, or the current time could not be read.
    The last two are the fail-safe in "an absent record is not evidence of absence" working as intended - unknown keeps meaning present - and the refusal says so rather than asserting activity nothing established.
    Refusal 6 above catches the fourth condition, no captain record at all, before this one is reached.
11. The fleet is no longer quiet: an undrained wake, a routed request awaiting its reply, or a worker waiting on an answer.
12. The re-entry hook is no longer wired: it no longer runs `bin/fm-sessionstart-nudge.sh` on a clear, or that script is gone. This checks the wiring, not that anything is injected; see "the way back in, precisely" above.
13. Supervision is not running.
14. Wake delivery is not armed while this home has recorded work or an X-mode relay - with nothing to wake for, an unarmed delivery wait does not block.
15. The harness is not `claude`, or the terminal backend is not `tmux` - including a backend that could not be detected at all, because the clear must never be typed on a guess.
16. This session's own pane cannot be identified, or its target cannot be resolved.
17. This session's own pane is in a tmux session whose name begins with `fm-`. That prefix is reserved: `bin/fm-send.sh` reads any such target as a recorded worker-task selector and looks for its metadata instead of resolving a live tmux endpoint, so the clear could never be typed. The refusal names that cause so an operator can rename the terminal session; it is a limitation of this mechanism on such homes, not a fault in the send path.
18. On the captain-approved path only, and evaluated last, immediately before the clear is typed: the last captain record is no longer the record taken as the approval, or the transcript can no longer be read at all. The captain spoke after approving, so the reset refuses and a fresh approval is needed; see "when the captain approves" above.

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

### The captain-approved path, demonstrated end to end

Measured on 2026-08-10, Claude Code 2.1.226 on tmux, in a disposable lab and never against a primary.
A green read of the code is not evidence here: the whole finding is that this path looked correct and had never once worked, so it was run.

The lab was a real `claude` session in its own tmux session (`ctxlab`) and its own scratch project directory, holding a scratch `FM_HOME` with a real `bin/fm-watch.sh` running against it.
The transcript measured was that session's own real transcript; the captain's messages were real typed input delivered through `bin/fm-send.sh`; the receipt and the reset were run by the lab session itself, which is what makes the ancestry checks meaningful.
`FM_CONTEXT_CEILING` was lowered to 1000 so a young lab session would register as over the ceiling.
The only conversation any of this could discard was the lab's own, created seconds earlier for the purpose.

The watcher's branch, off that real transcript:

```
check: context-ceiling: 36831 tokens is over the 1000 ceiling and the fleet is quiet,
but the captain has been active - ASK the captain before resetting; never reset
autonomously during a live conversation
```

The captain then approved, and the lab session filed its receipt and ran the reset.
The autonomous path, on exactly that session:

```
fm-context-reset: REFUSED: the captain has been active within the last 1800s; ask before
resetting instead of resetting during a live conversation, and re-run with
--captain-approved only once the captain has actually approved
```

The same session, seconds later, on the approved path:

```
fm-context-reset: reset submitted at 37526 tokens; it takes effect when this turn ends.
fm-context-reset: the approval was taken to be captain record
27d05873-0cc3-40e8-9d14-01da03f9f05c at 2026-08-10T03:08:12.123Z.
fm-context-reset: that record exists and this session filed its knowledge after it;
whether it meant approval is not something this tool can check.
```

`state/.context-reset.log` for the two clears the lab performed, both through the asking path:

```
2026-08-10T03:06:32Z	refused	the captain has been active within the last 1800s; ...
2026-08-10T03:06:56Z	cleared	path=captain-approved approval-record=6f4cb861-decb-43bb-a802-f58220f6b160 approval-ts=2026-08-10T03:06:48.509Z; 37996 tokens; submitted to ctxlab:0.0
2026-08-10T03:08:24Z	cleared	path=captain-approved approval-record=27d05873-0cc3-40e8-9d14-01da03f9f05c approval-ts=2026-08-10T03:08:12.123Z; 37526 tokens; submitted to ctxlab:0.0
```

| Link | Result |
| --- | --- |
| The captain spoke inside the idle window | Approval stamped `03:06:48.509Z`, reset completed `03:06:56Z` - 8 seconds later, against a 1800-second window |
| The receipt was filed after the approval | The receipt was written by the same turn the approval started, and the ordering gate passed; a receipt hand-dated before the approval refuses (`tests/fm-context-reset.test.sh`) |
| The autonomous path still refuses that session | Refused on the idle window, nothing discarded, one durable line |
| The approved path completes it | Cleared, twice, on two independently approved cycles |
| The named record is a real captain record | `27d05873-...` is an `origin.kind == "human"` record in that transcript, and its last one |
| The memory is verifiably gone | Asked for a codeword given before the reset, the lab session answered "I don't have any codeword - this conversation was just cleared" |
| The harness process survives | Pane pid `1559658` before the clear and after it, as the 2026-08-02 evidence above also found |

The refusal text quoted in that block is what the tool printed on 2026-08-10.
The autonomous refusal was reworded on 2026-08-20, in the change below, so that it names which of its conditions it hit; the block is left as recorded, because it is evidence of a moment rather than a statement of current wording.

### A delivered wake was counting as the captain

Measured on this home 2026-08-20, Claude Code on tmux, against the primary session's own real transcript.
No reset was attempted and nothing was discarded: every reading below is the shared predicates run directly, read-only.

The wake record's own structure, which is the whole finding - it is stamped exactly as a captain prompt is:

```
$ jq -c 'select(.type=="user") | {origin, promptSource, isMeta}' <the 04:27:14.510Z record>
{"origin":{"kind":"human"},"promptSource":"typed","isMeta":null}

$ jq -r '.message.content' <the same record> | bin/fm-operational-input.sh classify
watcher
```

The classifier recognised it all along.
The scan never asked it, because `.origin.kind == "human"` matched first.

Against a copy of the transcript cut off immediately after that record, so the newest user record is the delivered wake:

| Reading | Before | After |
|---|---|---|
| `FM_CONTEXT_LAST_HUMAN_TS` | `2026-08-20T04:27:14.510Z` - the wake itself | `2026-08-19T23:35:04.049Z` - the prior genuine captain record, `origin.kind == "human"`, unmarked |
| `fm_context_captain_active` | present; 62 seconds old at the moment of the incident, which is what refused the reset | absent |
| `FM_CONTEXT_SCAN_WIDENED` | `false` - a record was always "found", so the widen never ran | `false` at the 2 MiB bound, `true` at a 200 KB bound, where the tail holds only operational records |

And the direction that matters more, on the live transcript at the time of the fix, whose newest user record is a real captain message:

```
$ fm_context_scan "$transcript"; fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS"
TS=2026-08-20T07:36:10.654Z  ->  ACTIVE (spoke)
```

The guard still refuses.
A fix that made the scan skip too much would silently disable the protection that keeps a reset out of a live conversation, which is worse than the defect it repairs, so both directions are asserted in `tests/fm-context-reset.test.sh` rather than only the one that was broken.

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
| `.context-ceiling-absent-since` | `bin/fm-watch.sh` | `<class> <first-report-epoch> <reports>` for the current absent-protection condition, so a repeat can say how long the ceiling has had no protection and how many reports that has survived; cleared when the condition resolves or the protection comes back |
