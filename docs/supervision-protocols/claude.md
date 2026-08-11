Mode: Claude background-notify wake delivery.

- Ordinary wake: after handling each wake, re-arm wake delivery with `bin/fm-watch-arm.sh` as a fresh Claude Code background task, issued in the same message as the drain, before composing any reply or beginning long work.

When this session owns supervision and away mode is not active:

1. Issue `bin/fm-wake-drain.sh` and `bin/fm-watch-arm.sh` as two tool blocks of ONE message: the drain as an ordinary call, the arm as its own Claude Code background task.
   One message, two separate tool calls, two separate commands - never one command containing both.
   The arm is the only one of a wake's three model requests that need not have a request of its own, so pairing it with the drain is what makes a wake cost two requests instead of three.
   It is safe in either execution order: an arm that starts beside a drain defers queue content that was already there by a few seconds, so the drain reports it and the arm stays open (`bin/fm-wake-wait.sh`).
2. Never bundle the arm command with other commands.
   Two sibling tool blocks are not bundling; one shell command line containing both is.
3. Never use shell `&` for wake delivery.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
4. Treat `watcher: started ...` and `watcher: attached ...` as proof that the watcher service is healthy and this session's delivery stub is armed.
5. Treat `watcher: FAILED ...` as an alarm and follow its daemon or delivery repair before ending the turn.
6. When the background task completes with `wake: queued`, drain and start exactly one fresh background task before composing any reply or beginning long work, both as the one message of step 1, and handle the drained wakes after that message returns.
   The arm never completes merely because delivery was already armed: it waits behind a healthy same-session stub and takes delivery over when that stub releases.
   So a background task that has not completed is delivery working, and a completion is always a real wake or a real failure.
   Never poll `bin/fm-wake-drain.sh` to check on a live arm; an armed wait is exactly what an absent completion means.
   A background task reported stopped rather than completed, carrying nothing, is the harness reaping it under memory pressure; re-arm exactly as for any other completion and do not investigate it as a fault (`docs/supervision-cost.md`).
7. `wake delivery: replaced a dead delivery record (pid=<N> no longer exists)` means the arm found a record of a waiter that was already gone and became the waiter itself.
   Nothing is broken and nothing needs repair, but the session was covered by nothing for as long as that record stood, so it is worth noticing when it repeats.
8. If a forced watcher-loop restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
9. Do not send idle progress while the delivery stub is waiting.
10. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
    Any other chat text on a no-change wake turn is a protocol violation, not politeness, and restating an unchanged wait stays a violation even on a turn the harness forced to speak.
    Claude Code refuses an empty turn and accepts the one-character marker; `docs/silent-turn-attempts.md` holds the attempts that measured both.

Claude Code's background task completion delivers the wake to the model.
The external service owns `bin/fm-watch.sh`; the background task owns only `bin/fm-wake-wait.sh` through the verified `bin/fm-watch-arm.sh` wrapper.
Killing that background task loses no queued wake and requires only one re-arm.
