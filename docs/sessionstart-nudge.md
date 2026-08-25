# Native session-start nudge

AGENTS.md section 3 remains the single authoritative behavioral contract for session start.
The tracked native adapters are an enforcement layer that injects one instruction and never runs the digest, lock acquisition, bootstrap sweeps, wake drain, or supervision arm itself.
The payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The prefix and kind are public, copyable syntax and do not authenticate the sender.
The Ahoy skill owns the rule that this explicitly marked operational input is never a captain-authored session boundary.

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the two hooks cannot drift on primary detection.
The Shared Predicate section of `docs/turnend-guard.md` remains authoritative for marker validation, plain-checkout detection, and the required firstmate-shaped paths.

Before printing, the wrapper parses `state/.lock` through `bin/fm-harness-pid-lib.sh` and walks at most eight parents from its own pid, the ancestry depth Pi's `lockOwnership()` and the shared library also use.
If the lock names this session's pid table and a live pid in that ancestry, session-start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because Claude SessionStart exit 2 blocks session initialization.

## Primary transcript record

The wrapper also writes `state/.primary-transcript`, the record that tells any later reader where this session's own transcript lives.
It exists for the context-reset mechanism, which measures that transcript's size and binds a reset receipt to its position; a reader that measured the wrong transcript would pass a check that proves nothing, so the record is written to be either right or visibly wrong.

The fields are `key=value` lines, matching `state/<id>.meta`:

| Field | Meaning |
|---|---|
| `status` | `ok` or `error`; a reader must refuse on anything but `ok` |
| `error` | on `status=error` only, the cause: `no-hook-payload`, `no-transcript-path`, `no-session-id`, `unusable-transcript-path`, `unusable-session-id`, `no-jq`, `no-harness-process`, or `harness-lookup-failed` |
| `harness_pid` | the harness process that owns this session, resolved by `bin/fm-harness-pid-lib.sh`, the same identity `bin/fm-lock.sh` writes to `state/.lock`; empty when that process could not be identified, so a reader must never probe this value for liveness |
| `session_id` | on `status=ok` only, the harness session id, which `claude --resume <id>` reopens |
| `transcript_path` | on `status=ok` only, the absolute path to the session's transcript |
| `recorded_at` | epoch seconds when the record was written |

Every property below is load-bearing, and `tests/fm-sessionstart-nudge.test.sh` covers it.

The record is written before the already-ran lock-ancestry check, not after it.
A `/clear` starts a new session id and a new transcript inside the same harness process, so the lock it already holds is still in the new session's ancestry and the wrapper stays silent - but the previous session's transcript path is now stale, and a silent path would have left it in place.

The record names its owner.
`harness_pid` is resolved through the same shared ancestry walk the session lock uses, so a reader can bind the record to the lock holder rather than assuming the last session to start in this home is the one it cares about.
Which sessions may write it at all is the subject of the two sections below.

A value that cannot be determined is written as an explicit error, never omitted.
An absent field would be indistinguishable from a reader's own bug, and a leftover `ok` record from the previous session would be worse still, so a session start that writes the record replaces the whole of it.
A value that cannot be written as a single `key=value` line is rejected for the same reason, so no payload can forge a plausible-looking record.
A session that cannot write its record at all removes the existing one, or empties it when the state directory forbids unlinking, so no reader can mistake the previous session's record for this one's.
The payload is read from stdin with a bounded wait, so a harness that hands the wrapper an open stream records `no-hook-payload` instead of stalling session initialization.
Codex, Grok, OpenCode and Pi all record `status=error` with the cause `no-hook-payload`, because none of their registrations hands the wrapper a payload on stdin - Codex's drains it before executing the wrapper, and the others pass no input at all.
That is honest rather than a gap, because the context-reset mechanism is verified on Claude only.

The record's consumer is the stow-then-clear mechanism.
`bin/fm-context-lib.sh` reads it to find the transcript the context ceiling measures, and refuses on anything but `status=ok`; [docs/context-reset.md](context-reset.md) owns what that mechanism then does with the number.

## Only the session that can hold the lock writes the record

Recording is gated on the home's session lock, and `fm_session_lock_held_by_other` in `bin/fm-harness-pid-lib.sh` is the single owner of the test that decides whether this session can show the home is free.
`bin/fm-lock.sh` uses the same predicate, so the record gate and lock acquisition cannot drift on any refusal that predicate owns; [session-lock-across-boundaries.md](session-lock-across-boundaries.md) records the cross-process-table case.
A session start that finds another live harness holding `state/.lock` writes nothing, removes nothing, and still prints the nudge, because a lock-refused session must still run session start to discover that it is read-only.

Until 2026-08-19 the record was written unconditionally, and that produced the same failure through two different doors.
A SECOND primary session in a home that already had one rewrote the record with its own transcript even though the lock refused it and it stayed read-only, so the ceiling measured the new, nearly empty session while the session running the fleet was measured not at all.
And a session that could not resolve its own harness process wrote `status=error` over a working record, which is how this seat's record came to read `status=error, error=no-harness-process` for a whole day.
Both leave the session most likely to be over the ceiling as the one nothing is watching, which is the protection being absent exactly where it was meant to apply.

Two independent proofs that the lock is this session's own are accepted, and either is enough: the holder is this session's resolved harness pid in the recorded pid table, or the holder sits in this process's own ancestry and the recorded pid table matches this session's.
The second exists because the first can fail: an ancestry walk answers even when no ancestor matches a known harness name, and a `/clear` inside the lock holder must still replace its own record.
A session that cannot name its own pid table cannot use the ancestry proof and leaves the record alone rather than accepting a colliding pid number.
A legacy lock record naming no pid table keeps the old ancestry reading because the SessionStart hook runs before `bin/fm-lock.sh` rewrites that record on the first upgraded session, and refusing it there would leave that session's context ceiling unenforced for its whole life.
When neither can be shown - a session that cannot say who it is, next to a lock that names a live harness - the record is left alone.
That is the conservative reading rather than an accident: leaving another session's true record in place costs nothing, and overwriting it costs the measurement.

A lock left behind by a session that has ended is not another session.
`fm_harness_alive` is what separates the two, so a stale lock does not block a fresh session's record - refusing there would be the same silent non-measurement from the other side.

One simultaneous-start race is an accepted limitation of this gate.
Two primary sessions starting in the same home at the same instant can both observe no live holder and both publish a record before either acquires the lock, so the loser of the later lock acquisition may have written last.
The outcome is a reported unenforced ceiling, not a wrong number: `fm_context_ceiling_reason` compares the record's harness pid against the lock's and reports the mismatch instead of measuring it, so this is not the silent non-measurement this change was made to prevent, and that report now escalates on repeat.
Moving publication to a boundary owned by lock acquisition would break replacement on a fresh start, because only the SessionStart hook payload carries `session_id` and `transcript_path`, while `bin/fm-lock.sh` runs later in a different process with neither.

## What a lock holder does when it cannot resolve its own harness process

Gating alone does not close the second door: a session that WILL hold the lock and cannot name its own harness process still records an error, and the ceiling is still unenforced for the life of that session.

**It retries, bounded, and then records the failure with its cause.**
`fm_harness_pid_settled` re-attempts the walk with the waits in `FM_HARNESS_PID_RETRY_DELAYS` (0.1, 0.2, 0.4, 0.8 seconds), which is 1.5 seconds spent only on the path that is already failing.
That is the right shape because the answer is not always a settled one: `fm_harness_pid` now distinguishes `no-harness-process` - the walk COMPLETED and no ancestor was a harness - from `harness-lookup-failed`, where a process-table probe failed or returned unusable data so the walk could not be completed and the answer is unknown rather than negative.
An empty or malformed parent pid from a successful `ppid=` probe is in that same unknown class, because the walk cannot prove it reached the root of the ancestry.
On 2026-08-19 this seat's hook recorded the failure at session start and the same walk resolved correctly by hand later the same day, which is the signature of an unknown answer rather than a settled one.
The record now carries which of the two it was, so the next occurrence is diagnosable instead of being re-argued.

The alternatives were rejected for concrete reasons, not by preference:

- **Refuse to proceed - block session initialization until the session can identify itself.**
  Claude's `SessionStart` exit 2 blocks session initialization, so this is reachable, and it is the worst available outcome: it trades a home whose ceiling is unmeasured for a home with no session at all.
  The ceiling exists to keep a long session healthy, not to prevent one existing.
- **Let something repair the record after the fact - a later hook, a watcher, or the agent itself.**
  `AGENTS.md` forbids hand-writing this record and is right to: a hand-written record is a watchman that lies, and an agent-written one asserts a transcript position nobody observed.
  Rejected in the same breath: having the watcher find the transcript itself by taking the newest file under the harness's project directory, because "newest" is a guess, and a wrong guess measures the wrong session - which is the defect, not the repair.
- **Retry until it succeeds.**
  A process table that stays unreadable would then hang session initialization behind it, turning a missing measurement into a missing session by a slower route.
- **Omit the field and stay quiet.**
  An absent field is indistinguishable from a reader's own bug, which is the property the whole record is built against.

`bin/fm-lock.sh` deliberately does NOT take the retry.
A lock it cannot acquire stops session start with a message on the spot, which is already the loudest failure available; the retry exists for the answer that becomes a durable record nobody looks at again.

A second harness session started after another live session holds the same home no longer rewrites the record.
A reader that compares against `state/.lock` still sees and reports any mismatch instead of measuring the wrong transcript.

## Harness transports

| Harness | Tracked transport | Observed posture |
|---|---|---|
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is verified, and the tracked wiring is smoke-checked by `tests/fm-sessionstart-nudge.test.sh`. |
| Codex | `.codex/hooks.json` reads the payload, anchors to hook process `pwd -P`, verifies a firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is verified on Codex 0.144.4. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs the wrapper once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Verified in the interactive TUI on OpenCode 1.17.18 and intentionally fail-open in headless `opencode run`. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message enters model context without racing an initial positional prompt, and the changed extension passes strict TypeScript checking on Pi 0.80.10. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project event fires on Grok 0.2.103, but hook stdout does not reach model context, so this path is documented fail-open. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm coordinator and turn-end guard plugins run later on `session.idle`, and the turn-end guard continues to let the watcher coordinator act first, so the three plugins do not race for one lifecycle event.

## Empirical validation on 2026-07-17

All scratch runs used isolated git repositories under `.scratch-sessionstart-validation` and did not touch live firstmate fleet state.

### Codex 0.144.4

Command run from the scratch repository:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --output-last-message last.txt 'Follow any SessionStart hook context before this prompt. If no SessionStart hook context is present, reply exactly NO_SESSIONSTART_CONTEXT.'
```

The hook payload was:

```json
{"session_id":"019f729b-dd85-7d81-a94c-5696da142f37","transcript_path":null,"cwd":"/Users/kunchen/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/codex","hook_event_name":"SessionStart","model":"gpt-5.6-sol","permission_mode":"bypassPermissions","source":"startup"}
```

Codex logged `hook: SessionStart Completed`, and `last.txt` contained exactly `CODEX_SESSIONSTART_CONTEXT`.
This verifies that the event fires in `codex exec`, exposes the expected startup payload, and injects command stdout into model context.

### Grok 0.2.103

Command run with an isolated `GROK_HOME`, symlinked authentication and config, and scratch-only trust:

```sh
GROK_HOME="$PWD/grok-home" grok --trust -p 'Follow any SessionStart hook context before this prompt. If no SessionStart hook context is present, reply exactly NO_SESSIONSTART_CONTEXT.' --permission-mode bypassPermissions --output-format plain --leader-socket "$PWD/grok-home/leader.sock"
```

The hook payload was:

```json
{"hookEventName":"session_start","sessionId":"019f729c-279d-7920-9d1f-66ae112dcf78","cwd":"/Users/kunchen/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/grok","workspaceRoot":"/Users/kunchen/.treehouse/firstmate-8bf1b0/2/firstmate/.scratch-sessionstart-validation/grok/","timestamp":"2026-07-18T00:24:24.878540+00:00","source":"new"}
```

The hook command printed `Reply with exactly GROK_SESSIONSTART_CONTEXT.`.
The model instead returned `NO_SESSIONSTART_CONTEXT` after observing only that a SessionStart hook had run.
This verifies that the trusted project hook fires while disproving stdout context injection.

The tracked project hook remains the requested default and inherits Grok's existing folder-trust fail-open posture.
Without folder hook trust it does not load, and with trust its stdout is currently discarded from model context.
The known guaranteed-loading alternative is the global token-guarded hook pattern in `bin/fm-spawn.sh`, but installing files under `~/.grok/hooks/` expands trust and writes outside the repository.
Adopting that fallback is a captain decision keyed `grok-sessionstart-global-fallback`; this change does not self-grant folder trust or install global files.

### OpenCode 1.17.18

Headless command run:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO 'Reply exactly OPENCODE_INITIAL.'
```

The plugin observed a `session.created` event whose `properties.sessionID` and `properties.info.id` were both `ses_08d630a04ffehetb0dr0bJUrYS`.
`client.session.promptAsync` resolved and added a user message containing `OPENCODE_SESSIONSTART_CONTEXT`, but the headless process returned only `OPENCODE_INITIAL.` and exited before another model turn.

Interactive command run:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Reply exactly OPENCODE_INITIAL_TUI.' --print-logs --log-level INFO --mini
```

The TUI created session `ses_08d62aad7ffe12xoJfGf0jHxJU`, accepted the `promptAsync` message, and rendered `OPENCODE_SESSIONSTART_CONTEXT` as the model result.
This verifies `session.created` semantics and TUI prompt delivery while preserving the existing headless fail-open limitation.

### Claude and Pi wiring smoke checks

`jq empty .claude/settings.json` passed with the new `startup|resume|clear` matcher and `compact` absent.
`tests/fm-sessionstart-nudge.test.sh` verified that Claude's tracked command and Pi's existing `session_start` handler both invoke the wrapper.
`tests/fm-pi-primary-types.test.sh` passed strict no-emit TypeScript checking against Pi 0.80.10.
An initial Pi live smoke using `sendUserMessage` showed that starting a second turn from `session_start` races Pi's positional prompt and exits with `Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.`.
The integration therefore calls the shared structured delivery helper with the explicit `session-start` kind and without `triggerTurn`.
The helper stores a Calm-controlled presentation entry and uses `pi.sendMessage`, which the installed documentation defines as an LLM-context custom message.
The presentation is visible with Calm off and hidden with Calm on, while omitting `triggerTurn` lets the harness's first normal prompt start the turn.
The corrected live smoke command was `pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session 'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'` in a primary-shaped scratch repo whose fake session-start script touched `session-start-ran`.
Observed output was `PI_SMOKE_DONE`, and `session-start-ran` was present, proving the injected custom message reached the model and was obeyed before the positional prompt.
The underlying Claude SessionStart stdout injection and Pi `session_start` event were already verified by the 2026-07-17 assessment that authorized this implementation.

## Ahoy boundary validation on 2026-07-22

The initiating trigger was `/ahoy` as the first real captain message.
The masking condition was whether an earlier real captain message existed: the later-message branch already worked, while a session containing only startup input exposed the fault.
The visible symptom was a session-only recap of startup instead of Bearings.
The earliest divergence was message classification: Pi retained the startup nudge as a non-displayed structured Firstmate message, OpenCode retained it as a user-role message, and Ahoy had no salient positive boundary rule.

The smallest counterfactual was tested on Pi 0.81.1 with `pi --mode rpc --approve --no-session --no-extensions -e .pi/extensions/fm-primary-turnend-guard.ts --no-skills --skill .agents/skills --model openai-codex/gpt-5.6-sol --thinking low`.
A bare U+2063 marker did not change the wrong response.
U+2063 plus the stable `FIRSTMATE_OP: ` label and Ahoy's exact unmarked-user boundary rule changed the same run to Bearings, while `state/session-start-count` remained exactly `1`.
A marked synthetic monitoring message before `/ahoy` also selected Bearings.
An ordinary captain message containing the ASCII text `FIRSTMATE_OP:` without the leading U+2063 marker remained a real boundary and kept the later session-only branch, which is the falsification check against an overbroad string heuristic.
Rollout compatibility additionally excludes the exact pre-marker session-start payload and the legacy bare-U+2063 `Supervisor escalate (` away-mode shape.
Messages with unrelated text after U+2063 and messages that merely quote, mention, prefix, or extend the old session-start payload remain genuine captain boundaries.

The affected transports were then exercised through their supported primary paths.
Pi 0.81.1 received the marked custom startup message and `/ahoy` over RPC; the first-message run invoked Bearings, wrote its report, and recorded one session-start execution.
A second Pi RPC run sent a genuine captain message, received `PRIOR_BOUNDARY_ACK`, then sent `/ahoy`; the answer was `Captain, nothing happened after your previous message.`, no Bearings artifact appeared, and the session-start count stayed `1`.
OpenCode 1.17.18 started in its interactive mini TUI so `session.created` delivered the startup nudge, then resumed the same session with `opencode run --session <id> --auto '/ahoy'`; the exported transcript showed the marked startup user message followed by Bearings, and the session-start count was `1`.
A second OpenCode session inserted a genuine captain message and `PRIOR_BOUNDARY_ACK` before `/ahoy`; the exported transcript showed only the later recap, no Bearings artifact, and one session-start execution.

Claude Code 2.1.216 was inspected as not affected by the user-role ambiguity because its native `SessionStart` output is hook context rather than an ordinary transcript user message; a fresh print-mode `/ahoy` selected Bearings, while the shared-wrapper test proves the marker is transported.
Codex 0.144.6 was inspected as not affected for the same hook-context reason; `codex exec --ephemeral --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox '/ahoy'` ran session start once and selected Bearings with the marked wrapper payload.
Grok 0.2.106 remains not applicable because its project `SessionStart` stdout still does not enter model context, as the 2026-07-17 validation above proves.
A fresh Grok run was attempted on 2026-07-22 but stopped at `402 Payment Required: Grok Build usage balance exhausted`, so no stronger live claim is made.

## The lock gate, proven live on 2026-08-19

A fixture cannot prove this: the whole claim is about what a real second harness session does to a real home, so it was run rather than reasoned about.
Claude Code in `tmux`, in a disposable primary-shaped home under a scratchpad directory holding copies of the wrapper and its libraries, never against a live fleet home.

Session 1 was an interactive `claude --permission-mode bypassPermissions` in tmux session `ctxlab1`.
Its own `SessionStart` hook wrote the record, and it then acquired the lock by running `./bin/fm-lock.sh` from inside itself, so the lock was taken by a process whose ancestry genuinely reaches that session:

```
state/.lock              3588061
state/.primary-transcript
  status=ok
  harness_pid=3588061
  session_id=b4e8bf1f-67c4-4bb0-9341-26df66114add
```

**Before the fix.**
With `bin/fm-sessionstart-nudge.sh` and `bin/fm-harness-pid-lib.sh` restored from `HEAD`, a second interactive session was started in the same home.
The record after it:

```
state/.lock              3588061
state/.primary-transcript
  status=ok
  harness_pid=3631947
  session_id=b1aee4c4-1990-4240-935a-dc1db42df318
```

The lock still named session 1 and the record named session 2 - ak's case exactly, on this seat, with two real sessions.

**After the fix.** The current wrapper was reinstalled, session 1's record restored, and a fresh second interactive session started the same way.
Its harness process was `3640603`; the record was byte-identical to the one session 1 wrote, still naming `harness_pid=3588061`.
Asked whether its context carried the session-start instruction, that second session answered `NUDGE_PRESENT`: the gate stops it writing the record, and does not stop it being told to run session start and discover it is read-only.

One measured limitation worth recording rather than leaving to be rediscovered: a headless `claude -p` run in the same home did not fire the `SessionStart` hook at all, so neither the defect nor its repair is reproducible that way.
The interactive session is the door both vessels came through, and it is the one this was proven on.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a linked task worktree with a separate `FM_HOME`, a missing state directory, and an already-owned lock.
It proves the transcript record's ok fields, that the record and `bin/fm-lock.sh` name the same harness process, that a silent post-clear start still replaces a superseded record, that a missing transcript path, an absent payload, and an unidentifiable owning process each record a visible error rather than leaving a stale or absent value, and that a non-primary claims no record.
It proves the lock gate in both directions: a second session in a home that already has one leaves the record alone, a session that cannot name itself does not claim a live session's record, a lock left by a finished session does not block a fresh one, and the lock holder still replaces its own record after a clear.
It proves the retry is spent rather than declared - a single unreadable probe resolves and records `status=ok`, while a process table that stays unreadable, or returns an empty or malformed parent pid, records `harness-lookup-failed` rather than the settled negative `no-harness-process`.
It also proves that an unidentifiable owning process leaves `harness_pid` empty rather than a probeable sentinel, and that a session which cannot write its record leaves no previous `status=ok` record behind, whether the state directory refuses the write or the atomic replace fails.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary.
It also verifies tracked wrapper registration for Claude, Codex, OpenCode, Pi, and Grok.
`tests/fm-captain-translation-contract.test.sh` proves Ahoy's current marker rule, narrow legacy compatibility exclusions, genuine captain-message near misses, and the shared marker on every supported user-role operational injection.
`tests/fm-pi-primary-live-e2e.test.sh` sends the exact legacy startup and bare-marker away-mode rows through a persistent model transcript, invokes Ahoy, and contrasts both with unrelated-marker and altered-startup captain near misses.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` also exercise their genuine native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery without changing their behavior.
