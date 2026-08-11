# Silent-turn attempts

`AGENTS.md` section 8 requires a no-change supervision wake to carry no state: no response where the harness permits it, or the prescribed minimum marker where it does not.
Some harnesses refuse a turn that produces no visible output at all and re-prompt until text is emitted, which makes the no-response form of that requirement unmeetable on them.
This file holds the evidence behind that statement, and it is the only place a harness joins or leaves the refusing list.

## Method, and it is binding

Do not collect claims about a harness.
Collect attempts.

An agent cannot report its own harness constraints from memory.
On 2026-08-03 a vessel was asked whether its harness forced visible output, and answered - honestly, introspectively, about its own tool - that it did not.
The fleet recorded that as a correction, and the correction retired the structural finding along with the excuse it had given that vessel.
Minutes later the same vessel tried to comply, its harness demanded text on the next empty turn, and it withdrew the withdrawal.

Both corrections stay on the record rather than being tidied into one clean statement, because the sequence is the evidence.
The first answer came from belief about its own tool and was wrong.
The second came from trying it.
A finding that quietly drops its own disproved premise is worse than one that was never made.

So a harness enters the table below only after someone deliberately ended a turn with no visible output and recorded, verbatim, what came back.
Anyone surveying the remaining harnesses must ask each seat to TRY ending a turn silently and report what happened, never to answer from what it believes about itself.

## Attempts on file

| Seat | Date | Ends a turn with no visible output? | Established by |
| --- | --- | --- | --- |
| hlr vessel | 2026-08-03 | Refused | Attempt, after a withdrawn claim to the contrary |
| The reporting vessel | 2026-08-03 | Refused | Attempt, repeated in the session that raised the finding |
| coditan seat, Claude Code | 2026-08-10 | Refused | Attempt |
| firstmate-fork worker seat, Claude Code 2.1.226 | 2026-08-10 | Refused | Attempt, recorded below |

The two 2026-08-03 seats are recorded by vessel rather than by harness name, so they establish that the refusal is not unique to Claude Code without naming which harnesses they ran.

### coditan seat, Claude Code, 2026-08-10

The seat ended a benign wake turn with tool calls and no text.
The harness injected:

```
[Your previous response had no visible output. Please continue and produce a user-visible response.]
```

### firstmate-fork worker seat, Claude Code 2.1.226, 2026-08-10T16:10:54Z

Ended a turn with no assistant text and no tool calls.
The harness injected the same line:

```
[Your previous response had no visible output. Please continue and produce a user-visible response.]
```

The refusal is self-recovering: the session continued with its full context, so measuring this costs one turn and loses nothing.

### The same seat, 2026-08-10T16:13:06Z - what clears the refusal

Ended a turn whose entire visible output was a single `.` character.
No refusal was injected and the turn ended normally.

So on this harness one character is enough to satisfy the check, and the floor on a refusing harness is one character rather than a sentence.
That is the whole basis for the marker `AGENTS.md` section 8 prescribes.

## A second cost, measured in the same pass

After the `.` turn ended, that seat's pane stopped changing and the watcher raised a stale wake on it.

The cost is not specific to the marker.
`bin/fm-watch.sh` judges a watched crew window by whether its pane hash changes, so any turn that ends without further pane activity - which is exactly what a correctly silent turn looks like - is indistinguishable from a wedge to that path.
Scope matters here and the finding is easy to overstate: this judges watched CREW windows.
The firstmate primary's own no-change turns are not judged that way, because its liveness is the armed delivery wait rather than a changing pane, so this does not weaken the contract change it was found alongside.

The remedy belongs to `fm-no-repeat-escalation-for-provably-working-crew`, which already owns stale alarms raised on a worker that is fine, and the watcher already carries absorb-only-when-provably-working machinery for that class.
It is recorded here because it was measured here, not because this is where it gets fixed.

## What is NOT established

- `codex`, `opencode`, `pi`, and `grok` have no attempt on file, in either direction.
  Their supervision snippets carry the same rule, so none of them may be described as refusing or as permitting an empty turn until someone runs the attempt and records it here.
- Whether the one-character marker clears the refusal on any harness other than Claude Code 2.1.226 is unmeasured.
  A harness that refuses the marker too raises the floor for that harness alone, to the shortest output it does accept, and that result belongs in this file next to the attempt that found it.

## Adding a harness

Run the attempt on the harness itself: end one turn with no visible output.
Record the date, the harness and its version, the exact action, and the verbatim response.
Then add the row above and update the snippet in `docs/supervision-protocols/` for that harness if the result changes what it must say.
`.agents/skills/harness-adapters/SKILL.md` points here from its adapter-verification procedure so a new adapter is not promoted without this measurement.
