Mode: Pi extension wake delivery.

- Ordinary wake: the Pi extension already owns watcher continuity across every routine wake in this session; no repeated arm call is needed until a repair cycle is required.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions.
   If not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Arm delivery with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground wait can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts and awaits `bin/fm-watch-arm.sh`, keeps that lightweight delivery child attached to the live Pi process, and sends a follow-up user message when it exits with `wake: queued` or a failure.
6. An actionable close never starts a successor before drain because the durable queue remains non-empty.
   Drain and handle the queued wake, then call `fm_watch_arm_pi` before composing a reply or beginning long work.
7. A non-actionable child failure uses the extension's bounded retry path and surfaces a typed failure if continuity cannot be restored.
8. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
   One case behind that text is known and uncovered rather than a bug to chase: a close in which a healthy delivery stub of this session already held the lock is clean and non-actionable, and `__FM_PI_EXT__` is deliberately untouched, so its `classifyClose` falls through to the unconditional `watcher: FAILED - Pi extension arm cycle ended without an actionable reason`.
   That alarm is less specific than the `wake delivery: FAILED - another delivery stub already holds ...` it replaced, so read it as possibly meaning that instead of restarting on it alone.
   `docs/watcher-continuity.md` owns the rule for an already-armed close and why Pi is excluded from it.
9. Never use shell `&` for wake delivery.
   The arm mechanism above is extension-owned, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).
10. If nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
    Any other chat text on a no-change wake turn is a protocol violation, not politeness, and restating an unchanged wait stays a violation even on a turn the harness forced to speak.
    No attempt is on file for this harness in either direction; if you meet a refusal, record it in `docs/silent-turn-attempts.md` rather than leaving the next seat to rediscover it.

The external service owns the watcher loop.
The extension owns only the delivery stub and its cleanup when Pi exits.
The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted.
