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
A `wake delivery: already armed pid=<N> (same session)` line is a recognized healthy close, classified armed: a stub of this session already owns delivery, so nothing is retried and nothing is reported, and arm readiness settles as armed.
An armed close is nevertheless the one healthy close that ends an arm cycle with delivery owned by a stub the adapter does not own, so it schedules one quiet re-attempt every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds (default 5) until an attempt wins the lock and becomes the delivery wait itself.
That is deliberately the same cadence `bin/fm-watch-checkpoint.sh` runs, so every adapter takes delivery back at the moment the holder releases it rather than waiting for the next turn end.
It borrows the failure retry's single timer slot but none of its semantics: an armed close never increments the failure count, never counts against `FM_WATCH_REARM_RETRY_LIMIT`, never surfaces a message, and rechecks session-lock ownership and single-flight at each launch exactly like any other arm, so the one-child-or-one-timer invariant is unchanged.
A clean child close with no actionable, armed, or failure marker recognized is classified as idle and absorbed silently: it is neither retried nor reported, since that cycle simply did not establish supervision.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Re-arming a session that is already armed

Arming is idempotent for one session.
When `bin/fm-wake-wait.sh` cannot take `state/.wake-stub.lock` because a healthy stub of the same session already holds it, delivery is already armed - which is exactly what the caller asked for - so it prints `wake delivery: already armed pid=<N> (same session)` and exits 0.
It decides that through `fm_wake_stub_armed` in `bin/fm-wake-lib.sh`, the same predicate `bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` already use, so one state cannot produce two verdicts.

Until that call existed, the arm path reported every lost acquisition other than an operational lock failure as `wake delivery: FAILED - another delivery stub already holds ...` and exited 1, including this one.
That was worse than noise: the operating instructions treat `FAILED` as an alarm to clear before the turn ends, this case has no remedy, and the obvious reaction - kill the holder and re-arm - destroys a working delivery path.
Under a background-task harness it also produced a stream of failed job notifications for a completely healthy fleet.

Everything the predicate rejects stays as loud as it was.
A live holder is not sufficient: the lock must also record this home, this stub executable, this session's lock pid, and a process identity that still matches the live pid, so another session, another home, and a lock surviving on pid reuse all still fail.
`tests/fm-wake-wait.test.sh` covers both branches - the healthy same-session re-arm, and a session takeover plus a stale recorded identity.

No caller turns that success into a spin or into a phantom wake, and each one had to be given the rule explicitly rather than left to a default.
`bin/fm-watch-arm.sh` execs the stub, so the already-armed line reaches every adapter that consumes an arm close, and its own header records that contract.

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` both match the line in their close classifier and return the `armed` classification the arm-layer contract above defines, including the quiet re-attempt cadence that contract owns.
Absorbing the close without that cadence would have been a different bug rather than a fix: the holder can only be a stub the adapter does not own, so an adapter that merely fell silent would stop owning delivery for the rest of the session, and Pi in particular has no other automatic trigger that would ever start it again.
Recognizing the line explicitly matters more than the absorption itself.
OpenCode would have absorbed it anyway through its clean-exit idle default, but Pi's classifier ends in an unconditional failure, so an unrecognized already-armed close became `watcher: FAILED - Pi extension arm cycle ended without an actionable reason`, then the bounded retry storm, then `watcher: FAILED - Pi extension could not restore watcher continuity after 5 retries` - the exact alarm this change removes, reappearing one layer up and less diagnosable than the line it replaced.
Pi keeps that unconditional default for genuinely unrecognized closes; only this line no longer reaches it.

`bin/fm-watch-checkpoint.sh` cannot simply absorb the close, because Codex starts the next checkpoint after every one: an instant return would collapse the bounded 180s foreground wait that is Codex's whole delivery mechanism into a busy loop of instant tool calls - the same spin the old typed failure caused, only silent.
So the checkpoint keeps its own cadence instead of passing the close up: it re-attempts delivery every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds (default 5) across the remaining window, taking delivery over the moment the holder lets go, which is also the moment a wake the holder saw becomes visible again, because the durable queue outlives the stub that reported it.
A checkpoint that ends still already-armed prints the stub's own `wake delivery: already armed ...` line followed by `checkpoint: delivery stayed armed by a same-session stub; no actionable wake within <n>s` and exits 124 - the quiet-checkpoint code the protocol already defines, so the next step is unchanged while the diagnosis is distinct.
Its exit-0 wake path stays gated on the literal `wake: queued` line, so an already-armed close is never passed off as a delivered wake, and `tests/fm-watch-checkpoint.test.sh` pins the exit code, both output lines, the preserved cadence, and the takeover.

Measured on 2026-08-02 with `bash tests/fm-watch-checkpoint.test.sh`, which reported `ok - an already-armed same-session stub is reported distinctly without collapsing the checkpoint`, `ok - checkpoint takes delivery over from a released holder within its own window`, and `ok - checkpoint rejects a delivery stub belonging to another session`.
The first of those asserts the checkpoint spent at least 4 of its 5 seconds rather than returning early, which is the property the spin would have broken.

The adapter cadence was measured the same day with `bash tests/fm-pi-watch-extension.test.sh`, which reported `ok - OpenCode watcher plugin re-attempts an already-armed close and stops once it owns delivery`.
That run was on Node v20.20.2, where every Pi behavior test in the file prints `skip: node lacks native .ts import support (needs Node 22.6+ --experimental-strip-types or 23.6+)`, including the mirrored Pi case, so the OpenCode adapter is the one proven there and the Pi adapter's identical code path is asserted by reading rather than by execution.

`docs/supervision-protocols/codex.md` and `docs/supervision-protocols/grok.md` state the rule for the two harnesses that consume this result as a model-driven loop rather than through an adapter process.
Grok is the one harness that cannot hold the cadence itself, and the limit is worth naming rather than papering over: its re-arm step fires on every background-task-completed reminder, it has no timer of its own, and pacing the re-arm in-shell would mean bundling a sleep onto the arm, which the PreToolUse seatbelt denies by design.
So its protocol re-arms exactly once against an already-armed completion, which is what takes delivery back if the holder released in the meantime, and ends the turn if that re-arm reports already armed again, because a second identical answer means the holder is still delivering and chaining another arm would only produce the same instant completion.
Under Grok the holder is normally that session's own previous tracked background arm, whose completion still notifies; an untracked orphan is the residual case, and there `bin/fm-turnend-guard.sh` remains the backstop it always was rather than the mechanism.
Claude re-arms only on `wake: queued` and needs no new rule.

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

Both production numbers were re-measured end to end at the shipped defaults on 2026-08-02, after the same-session arm change above, by stopping a fake watcher's beacon and timing the stub's report from that last beat.
A killed watcher was reported at 300s with `wake delivery: FAILED - watcher beacon stale for 300s (grace 300s)`, and a live watcher that stopped beating opened its window at 300s and was reported at 390s with `... pid <N> is alive but its beacon never came back inside the grace within the 90s confirmation window`.
Both matched the values recorded when the window landed, so the arm-path change moves neither.

The fix is deliberately scoped to the delivery stub, so a resumed host is not silently supervision-free everywhere else.
`bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` still read a post-resume stale beacon as unhealthy and warn or block until the next beat lands, because loosening a Stop gate that deliberately errs toward supervision is its own decision rather than a ride-along here; `docs/turnend-guard.md` owns that gate.
`bin/fm-watch.sh` is untouched, the watcher never being the defect, and `bin/fm-watch-arm.sh` can still restart a healthy watcher when an arm lands in the seconds between resume and the next beat - a repair rather than a silent gap, and one a suspend no longer reaches now that the stub does not exit on resume.

The window must also stay comfortably under `FM_CODEX_WATCH_CHECKPOINT` (180s), because the Codex foreground checkpoint is the one caller that gives the stub a bounded lifetime.
A window longer than that checkpoint would be restarted by every new checkpoint and would never reach its own deadline, which would turn that bounded delay into never reporting a wedged watcher at all under that harness.
That coupling holds by construction rather than by memory: whenever the window it would pass down does not fit inside the delivery attempt it is about to start, `bin/fm-watch-checkpoint.sh` clamps the `FM_WAKE_BEAT_CONFIRM` it exports to the child to half that length, covering both an ambient value and the stub's own default.
The clamp is recomputed per delivery attempt against the window that attempt actually has, so the first attempt is clamped against the whole `--seconds` and a re-attempt inside a shortened remainder is clamped against that remainder, and each recomputation starts from the requested value rather than from the previous clamp, so the window cannot ratchet downward across attempts.
Only the first clamp is announced on stderr, which is why a checkpoint that re-attempts many times prints that diagnostic once rather than dozens of times.
The clamped value is floored at one second, because 0 is not a short window - the stub reads 0 as no window at all - so a clamp can shorten suspend survival but never switch it off; only a one-second checkpoint, far below any production value, leaves that floor as long as the checkpoint itself.
The default itself lives in `bin/fm-wake-lib.sh` as `FM_WAKE_BEAT_CONFIRM_DEFAULT`, so the stub and the checkpoint read one number rather than two literals that can drift apart.
`tests/fm-wake-wait.test.sh` pins the ordering of the two defaults and proves the runtime clamp fires for a short `--seconds`, and `tests/fm-watch-checkpoint.test.sh` pins the floor at the small end of the range.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
It also covers the armed close on both adapters with one fixture: an arm that reports `wake delivery: already armed ...` while a holder marker exists and becomes a long-lived delivery wait once that marker is removed, asserting the adapter re-attempts while the holder owns delivery, takes delivery over on the attempt after it is released, stops re-attempting once it does, and surfaces nothing to the model throughout.
The Pi half of that pair, like every other Pi behavior test in the file, skips on a Node without native `.ts` import support (below 22.6), so on such a host only the OpenCode half actually runs and the Pi adapter's copy of this behavior is unproven there.
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
