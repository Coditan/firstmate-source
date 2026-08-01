# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard implementation and adapters are unchanged.
They remain the final backstop rather than the normal continuity mechanism.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A `watcher: FAILED` or `wake delivery: FAILED` line, an unexpected signal, or a nonzero exit is a typed failure that drives the bounded retry described above.
A clean child close with no actionable or failure marker recognized is classified as idle and absorbed silently: it is neither retried nor reported, since that cycle simply did not establish supervision.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Surviving a host suspend

A machine suspend freezes the watcher along with everything else on the host, so on resume the beacon is necessarily as old as the sleep.
`bin/fm-wake-wait.sh` used to read the beacon once and exit, which meant every wake from sleep unarmed wake delivery until a human noticed - a silent supervision gap dressed as a loud warning.
The two states are distinguishable without any suspend detection, because `fm_watcher_healthy` in `bin/fm-wake-lib.sh` tests three independent conditions: a live pid, a lock whose recorded home, executable, and process identity still match that pid, and a beacon inside the grace.
A suspend fails only the third; a real death fails the first.
`fm_watcher_healthy` therefore classifies its own verdict in `FM_WATCHER_HEALTH` as `healthy`, `beacon-stale`, or `dead`, and is the single owner of that distinction.

When and only when the beacon age is the sole failing condition, the delivery stub opens one bounded beat-confirmation window of `FM_WAKE_BEAT_CONFIRM` seconds (default 90) and exits only if the beacon has not come back inside the grace by the time it closes.
The stub keeps polling the durable queue for the whole window, so delivery stays armed while it waits, and a beacon back inside the grace closes the window, announces the recovery on stderr, and returns the stub to ordinary waiting.
That closing line exists so a recovered suspend and a watcher that never came back cannot read the same way in the log.
A `dead` verdict never opens the window: no live identity-matched watcher can produce a beat, so that case still exits on the first reading past grace, exactly as before.

Recovery is defined as the beacon being back inside the grace, not as its mtime having moved at all.
A watcher that keeps beating but always slower than the grace would otherwise flap stale-window-beat-close indefinitely and never be reported, which would quietly remove a case that was loudly reportable before the window existed.
So an advanced but still-stale beacon neither closes the open window nor extends it, and the failure line says the beacon never came back inside the grace within the window rather than claiming no beat was produced.

Those `FM_WAKE_BEAT_CONFIRM` seconds are awake seconds, not wall-clock seconds.
A window can already be open when the host suspends, and wall clock keeps running while the stub does not, so a wall-clock deadline would expire unobserved and fail on the first post-resume reading - the exact bug the window exists to prevent, re-created inside the fix.
The stub sleeps `FM_WAKE_WAIT_POLL` between iterations, so an inter-iteration gap far larger than that poll is direct local evidence that the whole host was frozen; no `/proc`, `CLOCK_BOOTTIME`, or platform suspend detection is involved.
The threshold is derived from the poll interval rather than configured, and the whole measured gap is added back to an open deadline, because frozen time was never time the watcher had to prove itself in.
Erring long is safe here - it only lets a live, identity-matched watcher run a little further inside a still-bounded window - while erring short brings the suspend failure back.

One residual is accepted deliberately and stated here so it is not invisible: the credit has no cumulative bound, so on a host whose loop body itself consistently exceeds the freeze threshold - a stalled filesystem under `state/` blocking the `stat` and `/proc` reads, for instance - the deadline can advance as fast as wall clock and a wedged watcher would not be reported.
Bounding cumulative credit would close that but would break the primary case this exists for, a laptop that dark-wakes several times inside one open window; the bound that would preserve both is a cap on cumulative credit rather than on a single gap.

The window is bounded precisely so an alive-but-wedged watcher - one still holding the lock and no longer beating - is still reported rather than waited on forever.
That case is the one this costs: it is reported at grace plus the window instead of at grace, measured as 30s against a 10s grace and a 20s window, versus 10s before.
The genuinely dead case is unchanged, measured at exactly the grace both before and after (10s, 30s, and the production 300s default).
Raising `FM_GUARD_GRACE` is not an alternative fix: it would convert a visible false alarm into a silently longer blind window for every failure mode at once, including the real ones.

The window must also stay comfortably under `FM_CODEX_WATCH_CHECKPOINT` (180s), because the Codex foreground checkpoint is the one caller that gives the stub a bounded lifetime.
A window longer than that checkpoint would be restarted by every new checkpoint and would never reach its own deadline, which would turn that bounded delay into never reporting a wedged watcher at all under that harness.
That coupling holds by construction rather than by memory: `bin/fm-watch-checkpoint.sh` clamps the `FM_WAKE_BEAT_CONFIRM` it exports to the child so it is below the checkpoint length, covering both an ambient value and the stub's own default, and it says on stderr when it clamps.
The clamped value is floored at one second, because 0 is not a short window - the stub reads 0 as no window at all - so a clamp can shorten suspend survival but never switch it off.
The default itself lives in `bin/fm-wake-lib.sh` as `FM_WAKE_BEAT_CONFIRM_DEFAULT`, so the stub and the checkpoint read one number rather than two literals that can drift apart.
`tests/fm-wake-wait.test.sh` pins the ordering of the two defaults and proves the runtime clamp fires for a short `--seconds`, and `tests/fm-watch-checkpoint.test.sh` pins the floor at the small end of the range.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
`tests/fm-wake-wait.test.sh` proves the suspend contract by freezing rather than by reading the beacon: it SIGSTOPs a real `bin/fm-watch.sh` and the delivery stub together, resumes the stub first so it is forced to read an aged beacon before the watcher can beat, and requires the stub to still be armed and still deliver the next queued wake.
It also pins both sides of the latency trade - a live watcher that never beats is still reported once the confirmation window elapses, and a killed watcher is reported on the first reading past grace with a deliberately huge `FM_WAKE_BEAT_CONFIRM` that the dead path must never consult.
A second freeze test covers the dark-wake sequence the first cannot reach - resume, open the window, freeze again for longer than the window, resume - which fails on a wall-clock deadline and passes on an awake-time one, and both freeze tests assert the stub's identity lock still exists rather than trusting `kill -0`, which succeeds for a stub that already exited.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
