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
Since `bin/fm-watch-arm.sh` began holding rather than closing on that state, the wrapper itself no longer produces this close; the classification stays because a cheap attempt run straight against `bin/fm-wake-wait.sh` still does, and the section "Holding instead of closing" below owns why the wrapper differs.
An armed close is nevertheless the one healthy close that ends an arm cycle with delivery owned by a stub the adapter does not own, so it schedules one quiet re-attempt every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds (default 5) until an attempt wins the lock and becomes the delivery wait itself, which is the same cadence `bin/fm-watch-checkpoint.sh` runs.
The re-attempt runs `bin/fm-wake-wait.sh` directly rather than a whole new arm, exactly what the checkpoint re-runs, because the arm that opened the cycle already converged and verified the watcher service; re-running `bin/fm-watch-arm.sh` on every tick would repeat `bin/fm-watcher-service.sh ensure` instead, which means systemd probes and a sha256 over the tracked watcher sources every few seconds, and a unit restart every few seconds while the watcher is degraded.
Convergence is not dropped, only separated: a tick that finds more than `FM_WATCH_ARM_CONVERGE_INTERVAL` seconds (default 900) since the last full arm runs the full arm instead of the stub, so a cadence lasting hours costs one convergence per interval rather than one per tick.
Watcher health is still observed on the cheap path, because the stub itself reports `wake delivery: FAILED - watcher beacon stale ...` for a dead or wedged watcher and that line is classified as a failure like any other.
A stub that wins the lock prints nothing, so readiness for a cheap attempt settles on the evidence instead of on an arm header line: the stub lock recording that attempt's own pid, bounded by the same readiness timeout a full arm gets.
It borrows the failure retry's single timer slot but none of its semantics: an armed close never increments the failure count, never counts against `FM_WATCH_REARM_RETRY_LIMIT`, never surfaces a message, and rechecks session-lock ownership and single-flight at each launch exactly like any other arm, so the one-child-or-one-timer invariant is unchanged.
A clean child close with no actionable, armed, or failure marker recognized is classified as idle and absorbed silently: it is neither retried nor reported, since that cycle simply did not establish supervision.
OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` implements this contract; the Pi extension does not, and the section below owns why.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Re-arming a session that is already armed

Arming is idempotent for one session.
When `bin/fm-wake-wait.sh` cannot take `state/.wake-stub.lock` because a healthy stub of the same session already holds it, delivery is already armed - which is exactly what the caller asked for - so it prints `wake delivery: already armed pid=<N> (same session)` and exits 0.

That instant close is right for a caller that owns a re-attempt cadence and wrong for a caller whose close IS the wake, so `--hold` exists for the second kind and the section below owns it.
It decides that through `fm_wake_stub_armed` in `bin/fm-wake-lib.sh`, the same predicate `bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` already use, so one state cannot produce two verdicts.

Until that call existed, the arm path reported every lost acquisition other than an operational lock failure as `wake delivery: FAILED - another delivery stub already holds ...` and exited 1, including this one.
That was worse than noise: the operating instructions treat `FAILED` as an alarm to clear before the turn ends, this case has no remedy, and the obvious reaction - kill the holder and re-arm - destroys a working delivery path.
Under a background-task harness it also produced a stream of failed job notifications for a completely healthy fleet.

Everything the predicate rejects stays as loud as it was.
A live holder is not sufficient: the lock must also record this home, this stub executable, this session's lock pid, and a process identity that still matches the live pid, so another session, another home, and a lock surviving on pid reuse all still fail.
`tests/fm-wake-wait.test.sh` covers both branches - the healthy same-session re-arm, and a session takeover plus a stale recorded identity.

Of the callers that consume this close, OpenCode and the Codex checkpoint turn it into neither a spin nor a phantom wake, and each had to be given the rule explicitly rather than left to a default.
`bin/fm-watch-arm.sh` execs the stub, so the already-armed line reaches every consumer of an arm close whether or not that consumer has a rule for it, and its own header points here for the rule.

OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` matches the line in its close classifier and returns the `armed` classification the arm-layer contract above defines, including the quiet re-attempt cadence that contract owns.
Absorbing the close without that cadence would have been a different bug rather than a fix: the holder can only be a stub the adapter does not own, so an adapter that merely fell silent would stop owning delivery for the rest of the session.
Recognizing the line explicitly matters more than the absorption itself, because OpenCode would have absorbed it anyway through its clean-exit idle default and would then have gone quiet with nothing scheduled behind it.

Pi's adapter is unchanged, but its full arm runs through `bin/fm-watch-arm.sh` and therefore inherits holding mode.
An already-armed same-session stub no longer closes that child, so it never reaches Pi's close classifier as a false failure.

`bin/fm-watch-checkpoint.sh` cannot simply absorb the close, because Codex starts the next checkpoint after every one: an instant return would collapse the bounded 180s foreground wait that is Codex's whole delivery mechanism into a busy loop of instant tool calls - the same spin the old typed failure caused, only silent.
So the checkpoint keeps its own cadence instead of passing the close up: it re-attempts delivery every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds (default 5) across the remaining window, taking delivery over the moment the holder lets go, which is also the moment a wake the holder saw becomes visible again, because the durable queue outlives the stub that reported it.
A checkpoint that ends still already-armed prints the stub's own `wake delivery: already armed ...` line followed by `checkpoint: delivery stayed armed by a same-session stub; no actionable wake within <n>s` and exits 124 - the quiet-checkpoint code the protocol already defines, so the next step is unchanged while the diagnosis is distinct.
Its exit-0 wake path stays gated on the literal `wake: queued` line, so an already-armed close is never passed off as a delivered wake, and `tests/fm-watch-checkpoint.test.sh` pins the exit code, both output lines, the preserved cadence, and the takeover.

Measured on 2026-08-02 with `bash tests/fm-watch-checkpoint.test.sh`, which reported `ok - an already-armed same-session stub is reported distinctly without collapsing the checkpoint`, `ok - checkpoint takes delivery over from a released holder within its own window`, and `ok - checkpoint rejects a delivery stub belonging to another session`.
The first of those asserts the checkpoint spent at least 4 of its 5 seconds rather than returning early, which is the property the spin would have broken.

The OpenCode adapter cadence was measured the same day with `bash tests/fm-pi-watch-extension.test.sh`, which reported `ok - OpenCode watcher plugin re-attempts an already-armed close cheaply and stops once it owns delivery`.
That test pins the whole shape: the repeats run the stub rather than the full arm, the full arm runs again only at its convergence interval, delivery is taken over on the attempt after the holder releases, the cadence then stops, and nothing reaches the model.
That run was on Node v20.20.2, where every Pi behavior test in the file prints `skip: node lacks native .ts import support (needs Node 22.6+ --experimental-strip-types or 23.6+)`, so this change makes no claim that Pi's adapter classifier itself changed.

`docs/supervision-protocols/codex.md` owns the model-driven rule for the direct, non-holding checkpoint result.
Grok uses the full arm wrapper as a tracked background task, so holding mode now keeps an already-armed attempt open until a wake or a failure instead of asking the model to pace another attempt.

## Holding instead of closing, for the harnesses whose close is the wake

The paragraph above this section used to end "Claude re-arms only on `wake: queued` and needs no new rule", and the provider records disprove it.
A background-notify harness cannot see WHY a tracked task closed.
It sees that the task finished and it wakes the model, so the instant already-armed close reads as a wake carrying nothing: the model drains an empty queue, re-arms as its protocol requires, and that re-arm closes instantly for the same reason.
In session `20c57a94-cb85-42a7-a734-4220eadfa0a6` each `bin/fm-watch-arm.sh` background task enqueued its completion notification inside one second of launch and each notification produced one drain that returned nothing, 30 of them between 17:23:18Z and 17:32:04Z.
The model never saw `wake: queued`; it saw a finished task, which is all the harness had to give it.
`docs/supervision-cost.md` owns that measurement and what the loop cost.

So `bin/fm-wake-wait.sh` takes `--hold`, and `bin/fm-watch-arm.sh` execs it with that flag.
A holding attempt that finds delivery already armed stays alive rather than closing: it polls the durable queue exactly as the holder does, and retries `state/.wake-stub.lock` every `FM_WATCH_CHECKPOINT_REARM_POLL` seconds until the holder releases it, at which point it publishes its own identity into the lock and becomes the delivery wait itself.
Every close of the wrapper is therefore a real wake or a real failure, which is the one property that makes a close safe to treat as a delivery.
It announces the wait on stderr and writes nothing to stdout, because a caller that reads stdout as the close reason must not be handed one before there is one.

Every harness that arms through `bin/fm-watch-arm.sh` therefore takes the start-up deferral too - claude, grok, pi, and OpenCode's full arm - because the wrapper always passes `--hold`.
For the four of them the effect is bounded and small: each protocol drains before it arms, so the queue is normally empty when the arm opens its eyes, and a queue that is not empty is reported one `FM_WATCH_CHECKPOINT_REARM_POLL` later instead of at once.
The pairing itself is stated only in `docs/supervision-protocols/claude.md`, because Claude Code is the only harness whose two-tool-blocks-in-one-message behavior has been measured here; codex arms nothing from a model request at all (its checkpoint is foreground), and OpenCode and pi arm from a plugin and an extension rather than from a model request, so none of the three has an arm request to pair away.
Grok is background-notify and does have one, but no measurement of its message shape is on file, so its protocol is left unchanged rather than changed on an assumption.

The instant close is unchanged for every caller that runs `bin/fm-wake-wait.sh` directly without the flag.
`bin/fm-watch-checkpoint.sh` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` both own a cadence built around that close and both keep it.
The plugin's full arm goes through the wrapper and now holds instead of returning armed, which its readiness path already tolerates: it settles readiness on the wrapper's `watcher: started|attached` header line, printed before the hold begins, not on the close.

A holding attempt watches the queue as well as the lock, deliberately.
Waiting for the lock alone would be silent if the holder were alive but wedged, and a wake nobody hears is the one failure this fleet does not accept.

Watching it naively would have replaced one problem with a smaller one.
A wake arriving during a hold closes the holder and the attempt behind it within the same second, so one wake is delivered twice, and because the model arms once per delivery the doubling then sustains itself rather than settling.
So queue content already present when a holding attempt starts is inherited: it belongs to the holder to report, and the attempt behind it defers it for one `FM_WATCH_CHECKPOINT_REARM_POLL` before reporting it itself.
Nothing is inherited once the queue drains, and the attempt is an ordinary delivery wait from then on.
A working holder reports well inside that window, so one wake produces one delivery; a killed or wedged holder never reports, and the attempt behind it delivers a few seconds late.
Latency, never silence.

The same deferral covers a `--hold` arm's very first look at the queue, and that half exists for the paired protocol rather than for holding.
`docs/supervision-protocols/claude.md` issues the drain and the arm as two tool blocks of one message, which is what takes a wake from three model requests to two, and nothing guarantees the harness runs the two in order.
An arm that closed at once on the queue its sibling drain is about to take would spend the request the pairing saved, so content already there when it starts is inherited exactly like a holder's, on the same bound.
`docs/supervision-cost.md` owns that measurement.

An acquisition that REPLACED a dead delivery record announces it: `wake delivery: replaced a dead delivery record (pid=<N> no longer exists); this process is the delivery wait now`.
Taking a free lock and stealing a lock whose owner is gone are one lock operation and opposite facts - delivery was already covered, against a record that outlived its process while the session was covered by nothing - and the caller cannot tell them apart from silence.
The harness's own memory-pressure reaper leaves exactly that record behind, so it is not a rare shape (`docs/supervision-cost.md`, repair 5).

While holding, the attempt does not re-run `bin/fm-watcher-service.sh ensure` on any interval, and that is not a loss: the holder never re-converged either, and a dead or wedged watcher still reaches the model as the stub's own `wake delivery: FAILED - watcher beacon stale ...`, which every consumer already classifies as a failure.

`tests/fm-wake-wait.test.sh` covers the five properties that matter: a holding attempt does not close while another stub of this session owns delivery, it still delivers a wake that arrives while it holds, it takes delivery over once the holder releases the lock, it lets the holder report an inherited wake rather than reporting the same wake a second time, and it still reports a wake that a wedged holder never reported.
The last two are a pair on purpose, because dropping either one turns this fix into a different defect: without the deferral a single wake is delivered twice for as long as the session runs, and without the bound on that deferral a wedged holder swallows the wake entirely.
It also pins that `bin/fm-watch-arm.sh` execs the stub with `--hold`, because nothing else in the file would notice if that one word were dropped and the loop would come straight back.
Four further cases pin the two additions above: a paired arm must not close on the queue its sibling drain is about to take, that queue must still be delivered when no drain takes it, a delivery wait without `--hold` must still report already-queued content at once, and a dead delivery record must be replaced by a real waiter and said to be replaced rather than reported as armed.

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
It also covers the armed close on OpenCode with a fixture that logs the full arm and the delivery stub as separate entry points: the stub reports `wake delivery: already armed ...` while a holder marker exists and becomes a long-lived delivery wait once that marker is removed, so the test can assert which entry point each re-attempt used as well as that ownership returns.
There is deliberately no Pi counterpart, because the Pi adapter carries no armed-close behavior to cover and a test that skips on this host would only look like coverage.
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
