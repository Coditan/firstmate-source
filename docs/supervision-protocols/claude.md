Mode: external wake delivery, Claude primary.

This session holds no wake-delivery object of any kind.
The listener that turns a queued wake into a turn here is a service outside this harness, supervised the way the watcher loop is, and there is no arm step, no re-arm step, and nothing for this session to keep alive.
`docs/wake-delivery.md` owns the contract; what follows is only what this seat does.

When this session owns supervision and away mode is not active:

1. A wake arrives as a message in your composer carrying the firstmate operational marker and saying records are pending.
   On it, run `bin/fm-wake-drain.sh` first, before reading anything else and before composing any reply, then handle what it returns.
2. Do not arm anything afterwards.
   A wake costs one model request now, not three, because nothing has to be re-established at the end of it.
3. Do not poll `bin/fm-wake-drain.sh` to check whether delivery is working.
   An empty drain costs a request and proves nothing; `bin/fm-delivery-service.sh status` answers that question in one line without one.
4. The session-start WAKE DELIVERY section states this home listener verdict.
   `idle`, `delivering`, and `away` are healthy.
   `down`, `stalled`, and `undeliverable` each name their own cause and each need the repair the guard prints before the turn ends.
5. If a queued wake never arrives, the listener is not the first thing to suspect and not the last: ask it directly with `bin/fm-delivery-service.sh status`, which distinguishes a listener that is down from one with nothing to deliver.
6. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
   Any other chat text on a no-change wake turn is a protocol violation, not politeness, and restating an unchanged wait stays a violation even on a turn the harness forced to speak.
   Claude Code refuses an empty turn and accepts the one-character marker; `docs/silent-turn-attempts.md` holds the attempts that measured both.

A background task reported stopped rather than completed no longer has anything to do with wake delivery.
The harness reaper can still take a background task this session starts for its own reasons, and that is now an ordinary tool event with no supervision consequence.
