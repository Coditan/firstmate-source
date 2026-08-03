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

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid, the ancestry depth Pi's `lockOwnership()` and the shared `bin/fm-harness-pid-lib.sh` also use.
If the lock names a live pid in that ancestry, session-start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because Claude SessionStart exit 2 blocks session initialization.

## Primary transcript record

The wrapper also writes `state/.primary-transcript`, the record that tells any later reader where this session's own transcript lives.
It exists for the context-reset mechanism, which measures that transcript's size and binds a reset receipt to its position; a reader that measured the wrong transcript would pass a check that proves nothing, so the record is written to be either right or visibly wrong.

The fields are `key=value` lines, matching `state/<id>.meta`:

| Field | Meaning |
|---|---|
| `status` | `ok` or `error`; a reader must refuse on anything but `ok` |
| `error` | on `status=error` only, the cause: `no-hook-payload`, `no-transcript-path`, `no-session-id`, `unusable-transcript-path`, `unusable-session-id`, `no-jq`, or `no-harness-process` |
| `harness_pid` | the harness process that owns this session, resolved by `bin/fm-harness-pid-lib.sh`, the same identity `bin/fm-lock.sh` writes to `state/.lock`; empty when that process could not be identified, so a reader must never probe this value for liveness |
| `session_id` | the harness session id, which `claude --resume <id>` reopens |
| `transcript_path` | absolute path to the session's transcript |
| `recorded_at` | epoch seconds when the record was written |

Four properties are load-bearing, and `tests/fm-sessionstart-nudge.test.sh` covers each.

The record is written before the already-ran lock-ancestry check, not after it.
A `/clear` starts a new session id and a new transcript inside the same harness process, so the lock it already holds is still in the new session's ancestry and the wrapper stays silent - but the previous session's transcript path is now stale, and a silent path would have left it in place.

The record names its owner.
`harness_pid` is resolved through the same shared ancestry walk the session lock uses, so a reader can bind the record to the lock holder rather than assuming the last session to start in this home is the one it cares about.
A second harness session started in the same home rewrites the record with its own pid; a reader that compares against `state/.lock` sees the mismatch instead of measuring the wrong session.

A value that cannot be determined is written as an explicit error, never omitted.
An absent field would be indistinguishable from a reader's own bug, and a leftover `ok` record from the previous session would be worse still, so every primary session start replaces the whole record.
A value that cannot be written as a single `key=value` line is rejected for the same reason, so no payload can forge a plausible-looking record.
A session that cannot write its record at all removes the existing one, or empties it when the state directory forbids unlinking, so no reader can mistake the previous session's record for this one's.
Codex, Grok, OpenCode and Pi all record `status=error` with the cause `no-hook-payload`, because none of their registrations hands the wrapper a payload on stdin - Codex's drains it before executing the wrapper, and the others pass no input at all.
That is honest rather than a gap, because the context-reset mechanism is verified on Claude only.

Nothing consumes the record yet.
It is the first step of the stow-then-clear mechanism, built alone so the steps that measure, receipt, and reset have an unambiguous transcript to work from.

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

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves the transcript record's ok fields, that the record and `bin/fm-lock.sh` name the same harness process, that a silent post-clear start still replaces a superseded record, that a missing transcript path, an absent payload, and an unidentifiable owning process each record a visible error rather than leaving a stale or absent value, and that a non-primary claims no record.
It also proves that an unidentifiable owning process leaves `harness_pid` empty rather than a probeable sentinel, and that a session which cannot write its record leaves no previous `status=ok` record behind, whether the state directory refuses the write or the atomic replace fails.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary.
It also verifies tracked wrapper registration for Claude, Codex, OpenCode, Pi, and Grok.
`tests/fm-captain-translation-contract.test.sh` proves Ahoy's current marker rule, narrow legacy compatibility exclusions, genuine captain-message near misses, and the shared marker on every supported user-role operational injection.
`tests/fm-pi-primary-live-e2e.test.sh` sends the exact legacy startup and bare-marker away-mode rows through a persistent model transcript, invokes Ahoy, and contrasts both with unrelated-marker and altered-startup captain near misses.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` also exercise their genuine native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery without changing their behavior.
