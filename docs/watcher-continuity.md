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

### Who the refusal is addressed to

Three emitters carry this contract: the PreToolUse gate, the turn-end guard, and `bin/fm-guard.sh`, the advisory banner every supervision script and `bin/fm-send.sh` invoke.
All of them ship in tracked files, so every worktree of this repo carries them, including the disposable task worktree a crewmate or scout gets when the work is on firstmate itself.
Such a worker runs the identical hook while `FM_ROOT_OVERRIDE` still names the home that launched it, so the guard evaluates that home - and on 2026-08-30 it was right to: the home lock was held by a dead process while several unlocked watcher loops kept every beacon current, and the refusal was correct even though firstmate first read it as a false alarm.
What was wrong was the addressee.
Three separate runtimes were each handed `bin/fm-watcher-service.sh restart` against a home with ten tasks in flight that none of them could see, and `AGENTS.md` section 1 reserves supervision repair to firstmate: a worker that obeys does damage and a worker that refuses is stuck, so both outcomes were the guard's fault rather than the worker's.

`fm_session_operates_home` in `bin/fm-primary-scope-lib.sh` decides the addressee by asking whether the checkout the running hook was loaded from is the checkout-derived firstmate root, which all three emitters resolve as `FM_ROOT`.
So the addressee is decided from where the guard was loaded, and deliberately not from the home whose supervision was judged, which derives from `FM_HOME`.
The two are not interchangeable: they diverge whenever `FM_HOME` names a home other than the checkout, which `docs/configuration.md` documents as the normal meaning of `FM_HOME`.
An `FM_HOME` comparison was tried in `bin/fm-guard.sh` and reverted: `FM_HOME` selects the operational home while scripts still run from this checkout's `bin/` (`docs/configuration.md`), and `docs/cmux-backend.md` records `FM_HOME=<scratch> bin/fm-spawn.sh` run from the primary checkout, so comparing `FM_HOME` addresses firstmate itself as a worker and withholds its own repair command.
Firstmate's own session matches, a secondmate in its own home matches, and a task worktree does not.
It decides only wording: which home is evaluated and whether that home's supervision is unhealthy are computed identically for both addressees, so a wrong answer here can misaddress a message but can never suppress a refusal.
An operator keeps the recovery commands verbatim; a worker is told that repairing that home belongs to firstmate and is asked to report the stalled supervision in its task status line.
On the PreToolUse gate and the turn-end guard that worker message names no command at all, with one deliberate exception: a forced teardown is refused because only the ordinary literal `bin/fm-teardown.sh` is allowed during recovery, and that remedy holds for every addressee, so a worker gets it rather than a supervision-repair diagnosis that does not match why it was blocked.
`bin/fm-guard.sh` splits three ways rather than two, because its existing `FM_GUARD_READ_ONLY` branch answers whether the session may write and not who it is; its worker branch keeps the border, the headline, the in-flight and beacon line, and the continuation line, and drops only the `Daemon repair:` line and the delivery repair tail.
That delivery warning keeps its `WARNING: wake delivery listener ` prefix for every addressee, because `bin/fm-bridge-relay.sh` classifies the line by that prefix.
`bin/fm-guard.sh` is therefore not command-free for a worker: its queued-wakes warning is still gated only on `FM_GUARD_READ_ONLY`, so a worker is still told to drain them with `bin/fm-wake-drain.sh`.
That branch was left alone on purpose, because `bin/fm-wake-drain.sh` is on the continuity gate's worker allowlist and draining a queue is not the supervision repair `AGENTS.md` section 1 reserves to firstmate.

One limit of this design is accepted rather than fixed.
The addressee is decided from the checkout the running script was LOADED FROM, so it is only correct when the session runs its own copy.
Seven callers invoke `"$FM_ROOT/bin/fm-guard.sh"` rather than `"$SCRIPT_DIR/fm-guard.sh"` - `bin/fm-teardown.sh`, `bin/fm-pr-check.sh`, `bin/fm-review-diff.sh`, `bin/fm-merge-local.sh`, `bin/fm-promote.sh`, `bin/fm-fleet-sync.sh` and `bin/fm-spawn.sh` - and when a worker inherits `FM_ROOT_OVERRIDE` naming the launching home those run that home's copy, which reads as the operator and still prints the repair.
A worker whose environment carries no `FM_ROOT_OVERRIDE` at all also reads as an operator, because `FM_ROOT` then falls back to the checkout the script was loaded from.
Repointing them is scope resolution, which is a separate open captain decision; the gap is tracked as backlog item `fm-guard-addressee-fm-root-callers`.
`bin/fm-turnend-guard-grok.sh` and `.opencode/plugins/fm-primary-turnend-guard.js` each prepend their own instruction to the shared banner, so both read the same predicate rather than carrying a second answer.
The OpenCode plugin resolves the predicate natively in JavaScript against `FM_ROOT_OVERRIDE`, and any unresolvable path answers "not the operator" there too.

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
It also pairs the two addressees: a worker running the gate from a task worktree is still refused but is handed none of the commands reserved to firstmate, while the session operating the home still gets its full recovery instruction.
`tests/fm-turnend-guard.test.sh` pairs them the same way for the turn-end banner, for the grok adapter's prepended instruction, and for the OpenCode plugin's prepended headline.
`tests/fm-guard-stale-banner.test.sh` pairs them for the advisory daemon banner and the delivery warning, and its operator cases now run the guard out of the fixture home's own `bin/` so that shape is real rather than implied.
Both worker tests were run against the pre-fix code first and reproduced the defect verbatim.
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
