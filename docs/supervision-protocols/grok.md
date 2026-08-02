Mode: Grok background-notify wake delivery.

- Ordinary wake: after handling each wake, re-arm wake delivery with the same Grok tracked background task running `bin/fm-watch-arm.sh` before composing any reply or beginning long work.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Arm with Grok's tracked background tool, as its own call: `run_terminal_command` with `background: true` on `exec bin/fm-watch-arm.sh`.
3. Trust only the arm's one-line status.
4. `watcher: started ...` or `watcher: attached ...` means the watcher service is healthy and this session's delivery stub is armed.
5. `wake delivery: already armed pid=<N> (same session)` means a healthy delivery stub of this session already owns delivery, so this arm had nothing left to do; it is an attach, not a wake and not a failure.
   End the turn on it and do not arm again, because the stub that holds delivery is the one whose exit will notify you.
   Never kill that holder to clear the line; it is a working delivery path, and `bin/fm-turnend-guard.sh` judges the same state armed.
6. `watcher: FAILED ...` means either the service or delivery wait is down; follow the typed repair and re-arm.
7. After a successful start, attach, or already-armed status, end the turn.
8. Waiting is silent.
9. Never use shell `&` for firstmate wake delivery.
10. Never bundle the arm onto another command.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

Grok injects a synthetic user message with `synthetic_reason: task_completed` when the delivery stub exits.
When you see a background-task-completed system reminder for the arm:

1. Run `bin/fm-wake-drain.sh` first.
2. Handle the queued wakes.
3. Re-arm exactly one delivery wait with the same background `bin/fm-watch-arm.sh` call before composing any reply or beginning long work when work remains in flight or X mode still needs polling.
   The one exception is a re-arm that comes straight back with `wake delivery: already armed pid=<N> (same session)`: another healthy stub of this session owns delivery, so arming again only produces the same instant completion.
   End the turn instead and let the stub that holds delivery notify you when it exits.
4. Optionally fetch arm output with `get_command_or_subagent_output(<task_id>)`; `wake: queued` is the actionable delivery line.
5. If nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls only and send no chat text.

Any no-change wake turn that sends chat text is a protocol violation, not politeness.

The watcher loop runs outside Grok's background-task lifecycle.
Grok's tracked background process is only the safely killable delivery stub.

Grok Stop hooks are passive.
The primary project hook runs `bin/fm-turnend-guard-grok.sh`, which forces at most one same-session follow-up via `grok --resume` when a turn would end blind.
That is a backstop, not the normal wake path.
Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output.
