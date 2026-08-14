# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Continuity lives above that process boundary rather than depending on the model remembering anything.

Wake DELIVERY is no longer part of this document.
It moved out of the harness entirely on 2026-08-13 and `docs/wake-delivery.md` owns it: the listener, its verdicts, the endpoint record, and the evidence.
What remains here is the watcher loop's own continuity and the Claude PreToolUse gate that protects a session whose watcher is down.

## Ownership

`bin/fm-watcher-service.sh` owns the watcher loop's lifetime: a systemd user unit per home with `Restart=always`, or a detached tmux keeper where the user manager is unusable.
No adapter, plugin, or extension owns any part of supervision continuity any more.
That is the whole change: the arm layer this document used to describe existed because delivery was a session object with a lifetime the session had to manage, and there is no longer such an object.

## Actionable wake ordering

The watcher enqueues every actionable reason into `state/.wake-queue` before it closes its cycle, so the durable record exists before anything downstream can observe it.
Whether a listener is up at that moment is irrelevant to whether the record survives: a wake queued with nothing listening is delivered as soon as a listener returns, because the queue is the only store.

## The Claude continuity gate

Claude's PreToolUse continuity gate allows the wake drain, the supervision-repair commands, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.

The turn-end guard remains the final backstop rather than the normal mechanism.
Its own predicate is documented in `docs/turnend-guard.md`; since the delivery move it asks `fm_delivery_healthy` about this home's listener instead of asking whether the session armed a waiter.

## Surviving a host suspend

A frozen host cannot touch a beacon while the processes it names stay alive, so a suspend leaves a live, identity-matched process with an aged beacon behind.
Both the watcher predicate (`fm_watcher_healthy`) and the delivery predicate (`fm_delivery_healthy`) classify that state as `beacon-stale` rather than `dead`, and both keep the live pid available so a caller can name the process it is waiting on.
Collapsing the two would report every resume from sleep as a death.

The bounded beat-confirmation window that the old session-held waiter used to open around a stale beacon is gone with the waiter.
Nothing now exits on a single stale reading, because nothing is a one-shot wait: the watcher and the listener are both supervised loops that a service manager restarts, and a stale beacon is reported rather than acted on.

## Regression coverage

`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination, and the guard's three states with work in flight.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
`tests/fm-watcher-service.test.sh` covers backend selection, consent, the keeper fallback, and source-version convergence.
`tests/fm-delivery.test.sh` and `tests/fm-watcher-systemd-smoke.test.sh` own delivery's own coverage; `docs/wake-delivery.md` states what they prove.

The suites that covered the arm layer are gone with it: `tests/fm-wake-wait.test.sh`, `tests/fm-watch-checkpoint.test.sh`, and `tests/fm-pi-watch-extension.test.sh` tested the lifetime management of a session-held delivery object, and there is no such object to manage.

## Historical live evidence, 2026-07-17

The five-harness live evidence this section used to carry described the per-harness arm layer.
It is retained as history, not as a current description: every harness-specific delivery mechanism it measured - Claude's tracked background arm, Codex's foreground checkpoint, OpenCode's plugin child, Pi's `fm_watch_arm_pi` tool, Grok's background task - was removed on 2026-08-13.

Harness versions at that measurement:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

What that round still evidences, and what remains true, is narrower than what it recorded:

- Claude's continuity gate refused the unrelated fleet command before its body executed, with the exact typed system message.
  `tests/fm-claude-continuity-live-e2e.test.sh` still covers that, updated for the current recovery-command set.
- The turn-end backstop fired at most once per turn on every harness, and not at all on turns with no work in flight.
- OpenCode and Pi both loaded their tracked project files after a one-time trust approval, which is still how the turn-end guard reaches those seats.

Everything else in that round measured a mechanism that no longer exists.
`docs/wake-delivery.md` holds the current evidence.
