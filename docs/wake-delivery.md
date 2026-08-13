# Wake delivery

This is the one owner of how a queued wake becomes a model turn.
`AGENTS.md` section 8 states the operating rule inline and points here; each supervision-protocol snippet states only what its own seat does.
The mechanics of each script live in that script's header and `--help`.

## What changed, and the size of the problem it removes

Wake delivery used to be an object the primary session held: a Claude background task, a Codex foreground checkpoint, an OpenCode plugin child, a Pi extension child.
Both measured causes of delivery death destroyed exactly that class of object.
The harness reaper's kill was measured at 101 of 101 observed kills matching its idle precondition, and an independent keystroke channel killed the same object by hand.
When delivery died, supervision stopped and nothing noticed until a human looked.

The proof of the answer was already running: the watcher service has never been reaped, because systemd owns it rather than the harness.
Only the per-session waiter was exposed.
So delivery moved into the same domain, as a companion unit beside the watcher, and **the session now holds no delivery object at all**.
That is the whole point: making the waiter more robust, or keeping a small one as a fallback, would leave the failure class intact, because the class is "the session holds a killable object" and it is only removed by the session holding none.

The panel that authorised this considered folding delivery into the watcher's own process and preferred a companion unit; this implementation follows that preference.
The reason to keep it separate is fault isolation in both directions: a listener that wedges typing into a pane must not stop the loop that detects wakes, and a watcher restart must not interrupt a submit.

## The pieces

| Piece | Owns |
| --- | --- |
| `bin/fm-delivery.sh` | the per-home listener loop: observe, submit, retry until drained |
| `bin/fm-delivery-lib.sh` | the records, the health predicate, the endpoint, and the one-line verdict |
| `bin/fm-delivery-service.sh` | install, converge, restart, publish the endpoint, report status |
| `bin/fm-delivery-keeper.sh` | the tmux keeper tier for a home whose systemd user manager is unusable |
| `systemd/fm-delivery@.service` | the unit template, one instance per home, `Restart=always` |
| `bin/fm-pane-activity-lib.sh` | the pre-typing pane reads, shared with the away daemon |

Every instance is per-home, exactly like the watcher: the systemd instance name and the tmux keeper name are both derived from `FM_HOME` alone, so nothing can reach across homes.
The keeper name keeps a bounded sanitized home basename for recognition and uses a truncated SHA-256 digest of the complete home path for identity.
On upgrade, each service checks the former checksum-based name once and stops it only when that home's keeper pid and lock record prove ownership, leaving an unprovable legacy session untouched.

## The loop

1. Touch `state/.last-delivery-beat` at the top of every cycle, before that cycle's work, so a fresh beacon proves the loop is turning rather than that it finished.
2. If `state/.afk` exists, stand down: the away daemon owns delivery under the `/afk` contract, and two processes typing into one composer is the doubling failure that contract already learned.
3. If `state/.wake-queue` is empty, do nothing.
4. Otherwise resolve `state/.primary-endpoint`, take the pre-typing reads, and submit one canonical typed `watcher` operational input built by `bin/fm-operational-input.sh`.
5. Wait `FM_DELIVERY_RETRY` seconds (45 by default) and look again.
   If the queue is still not empty, submit again.

Step 5 is why this is a retry-until-drained loop rather than a fire-and-forget send: **the queue emptying is the only evidence a submit actually became a turn.**
A submit that was typed into a pane whose Enter was swallowed leaves no other trace, and a wake that was never handled looks exactly like one that was.

The retry interval is not tunable downward without cost.
A submitted wake becomes a model turn that has to run before it can drain, so resubmitting faster than a turn takes types a second message into a composer whose first message is still being worked.

## The durable queue is the only source of truth

`state/.wake-queue` is the single store of what is pending.
The listener only observes it: it never appends, never consumes, and keeps no copy.
Only a model turn running `bin/fm-wake-drain.sh` removes a record.

That is what makes every other property hold.
A wake queued while no listener is running is delivered when one returns, because the record was never anywhere else.
A wake survives the session exiting and restarting for the same reason.
`tests/fm-delivery.test.sh` asserts it directly, including a sweep for any copy of a queue record written anywhere else under `state/`.

## The endpoint, and why the session publishes it

The listener runs under a service manager with no session context, so unlike the away daemon it cannot discover the captain's pane from its own environment.
The locked session publishes it once at session start through `bin/fm-delivery-service.sh publish-endpoint`, which records the backend, the target, the harness, and the pid in `state/.lock`.

Recording the publishing session is what makes a stale record detectable.
A record left behind by an exited session names a pane that is now somebody else's or nobody's, and typing into an unverified address is worse than reporting that there is none - so `publish-endpoint` refuses a guessed pane and a session with no recorded lock, rather than writing an address nobody verified.

## Every state says which one it is

A listener that is not running and a listener with nothing to deliver both produce silence.
If the only observable were "no wake arrived", the fleet could not tell a healthy quiet home from a dead listener, and the failure this work removes would have moved house rather than gone.

So the outside view is never a boolean.
`bin/fm-delivery-service.sh status` prints one line whose first word is the verdict:

| Verdict | Means |
| --- | --- |
| `idle` | listening, nothing pending - the only healthy silence |
| `delivering` | listening, wakes pending, and no last attempt is recorded as blocked |
| `undeliverable` | listening, wakes pending, and the line names the endpoint or last-attempt cause that blocks the submit |
| `away` | up and standing down because the away daemon owns delivery |
| `stalled` | a live, identity-matched listener whose beacon aged out |
| `down` | no live, identity-matched listener at all |

`undeliverable` always names its own cause: no endpoint published, a malformed record, an endpoint from a session that no longer holds the lock, a pane that no longer exists, a pane mid-turn, a composer holding unsubmitted text, a composer that could not be confirmed empty, or a backend this listener has no verified composer primitives for.

The listener publishes the last resolved submit attempt as one bounded, single-line outcome record.
A blocked attempt records its concrete cause, a confirmed submit clears it, and an empty durable queue clears it so stale failure cannot mask a healthy home.
The reporting boundary reads that file after validating the endpoint and performs no pane capture or backend probe of its own.

`stalled` and `down` are deliberately separate.
A frozen host cannot touch the beacon while the process stays alive, so a suspend leaves exactly the stalled state behind; collapsing the two would report every resume as a death.

Each of those conditions is created on purpose in `tests/fm-delivery.test.sh` and the matching verdict is required back.
Asserting only the healthy path would let the whole distinguishability property rot without a single test failing, which is the defect this section exists to prevent.

## Refusing an unsafe pane

Only an affirmatively empty genuine agent composer is typed into.
`pane_is_busy` and the shared composer classifier report `pending` for real unsubmitted text - a captain's half-typed line, or a previous submit whose Enter was swallowed - and `unknown` for a bare dead-shell prompt or an unreadable pane.
Neither is a safe target: the first would merge with the captain's text, the second would hand a shell a command.
Both defer, and both are named in the verdict.

Those two reads are shared with `bin/fm-supervise-daemon.sh` through `bin/fm-pane-activity-lib.sh`, because both processes type into the captain's pane and both have to be wrong in the same direction.

## Away mode

While `state/.afk` exists the away daemon owns delivery and the listener stands down.
It keeps beating while standing down, so standing down still reads as up from outside and is reported as `away` rather than as silence.

## Verified

Recorded from the machine this landed on, 2026-08-13.

Real systemd, both units, in `tests/fm-watcher-systemd-smoke.test.sh` with `FM_SYSTEMD_LIVE=1`:

```text
$ FM_SYSTEMD_LIVE=1 bin/fm-test-run.sh tests/fm-watcher-systemd-smoke.test.sh
Running as unit: fm-watch-smoke-...service
Running as unit: fm-delivery-smoke-...service
ok - real systemd user units keep both the watcher and the delivery listener external,
     restart each after a kill, and lose no queued wake
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

That run covers three of the acceptance conditions directly: a wake queued while nothing was listening is still pending when a listener returns, `kill -TERM` on the listener is followed by a systemd-started replacement with a different pid, and the queue holds exactly one record throughout.

`tests/fm-delivery.test.sh` covers the session-exit boundary the smoke does not: a wake pending while the session exits must be neither lost nor delivered to the pane that session left behind, so the listener reports the stale endpoint by name, and the wake is delivered to the new session's own pane once it publishes one.

The portable suite in `tests/fm-delivery.test.sh` covers the rest, including a real tmux end-to-end: a stand-in agent pane that draws the agent composer glyph and reads one line receives the canonical typed `watcher` input and the drain instruction, while the durable queue record stays untouched for the drain.

The reaper's own precondition - roughly thirty minutes of terminal idleness plus a host memory-pressure event - cannot be produced on demand, so the reaper-survival condition is proven by the stronger property instead.
`test_destroying_the_whole_session_process_group_leaves_delivery_running` starts the listener in its own process group the way a service manager does, starts a stand-in session with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP` explicitly empty (the reaper enabled) and background jobs of its own, then `kill -KILL`s that entire process group - everything a reaper could reach, and more - and requires the listener to be alive and still `delivering` afterwards.
The test first asserts the two process groups differ, so it cannot pass vacuously by having put the listener in the group it then spares.

## How "no session-held delivery object" was verified

Not by having declined to add one.
The claim is that none remains, so it was checked against the tree rather than against intent:

1. Every tracked harness integration file was enumerated and read: `.claude/settings.json`, `.codex/config.toml`, `.codex/hooks.json`, the five `.grok/hooks/*.json`, the five `.opencode/plugins/*.js` plus its library, and the three `.pi/extensions/*.ts`.
   Every child process any of them starts is a short synchronous checker that exits within the hook - the turn-end guard, the cd guard, the lavish guard, the session-start nudge, and the operational-input encoder.
   None starts, awaits, or registers a long-lived process.
2. The five scripts that were the delivery objects are gone from the tree, not merely unreferenced: `bin/fm-watch-arm.sh`, `bin/fm-wake-wait.sh`, `bin/fm-watch-checkpoint.sh`, `.opencode/plugins/fm-primary-watch-arm.js`, and `.pi/extensions/fm-primary-pi-watch.ts` were deleted, along with the suites that tested their lifetimes.
3. `tests/fm-supervision-instructions.test.sh` asserts the property rather than trusting it: for all six rendered blocks, each must state that the session holds no wake-delivery object, must contain the drain instruction, must contain "Do not arm anything", and must not name any of the four removed entry points.
   A snippet that quietly reintroduced an arm step would fail that test.
4. `state/.wake-stub.lock` - the record a session-held waiter published - has no writer and no reader left; `bin/fm-wake-lib.sh` no longer defines the predicates that judged it.

The one background job a primary session still holds is the optional Telegram receiver arm, which is not wake delivery and is stated as such in the operating block.

## What is not covered

A credentialed per-harness regression that drives a real Claude, Codex, Grok, OpenCode, or Pi composer end to end is not in the suite.
The old per-harness live regressions tested the arm mechanism, which no longer exists, so their subject went with it; what replaced them is the real-tmux injection above, which exercises the same submit path against a real pane but not a real agent's composer rendering.
The gap that leaves is per-harness: whether each harness's composer is classified correctly by the shared classifier under its own rendering.
That classifier is unchanged by this work and is already covered by `tests/fm-composer-lib.sh` and the away daemon's own suite, so the risk is narrow - but it is a gap, not a covered case.
