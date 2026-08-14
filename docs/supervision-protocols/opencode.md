Mode: external wake delivery, OpenCode primary.

This session holds no wake-delivery object of any kind.
The TUI plugin that used to arm delivery after idle is gone: the listener that turns a queued wake into a turn is a service outside this harness, supervised the way the watcher loop is.
`docs/wake-delivery.md` owns the contract; what follows is only what this seat does.

When this session owns supervision and away mode is not active:

1. A wake arrives as a message in your composer carrying the firstmate operational marker and saying records are pending.
   On it, run `bin/fm-wake-drain.sh` first, before reading anything else and before composing any reply, then handle what it returns.
2. Do not arm anything afterwards, and do not wait for a plugin to arm anything.
3. Do not poll `bin/fm-wake-drain.sh` to check whether delivery is working.
   `bin/fm-delivery-service.sh status` answers that in one line and costs no turn.
4. The session-start WAKE DELIVERY section states this home listener verdict.
   `idle`, `delivering`, and `away` are healthy.
   `down`, `stalled`, and `undeliverable` each name their own cause and each need the repair the guard prints before the turn ends.
5. Firstmate primary supervision targets persistent OpenCode TUI sessions; a headless `opencode run` has no composer for the listener to submit into.
6. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
   Any other chat text on a no-change wake turn is a protocol violation, not politeness, and restating an unchanged wait stays a violation even on a turn the harness forced to speak.
   No attempt is on file for this harness in either direction; if you meet a refusal, record it in `docs/silent-turn-attempts.md` rather than leaving the next seat to rediscover it.
