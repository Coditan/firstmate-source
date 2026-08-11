Mode: Codex foreground wake checkpoint.

- Ordinary wake: after handling each wake, start the next foreground checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
2. Run one foreground delivery checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
3. If the command prints `wake: queued`, drain and handle queued wakes, then start the next checkpoint.
4. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
   `checkpoint: delivery stayed armed by a same-session stub; no actionable wake within <n>s` is one of those quiet outcomes, not a failure: a healthy delivery stub of this session already owned the lock, and the checkpoint spent its full window re-attempting rather than returning early, so treat it exactly like any other 124 and start the next checkpoint.
   Never kill that holder to clear the line; it is a working delivery path, and `bin/fm-turnend-guard.sh` judges the same state armed.
5. Because the checkpoint blocks reasoning, make it the next tool call after wake handling and do not compose an idle reply before it.
6. Never use shell `&` or Codex background tasks for firstmate wake delivery.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal delivery command.
   If it is ever shelled as a repair probe, a backgrounded, piped, or bundled shape is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. After handling a wake, if nothing reaches `AGENTS.md` section 9's escalation bar, end the turn with tool calls and no chat text; where this harness refuses a turn with no visible output, send exactly one line holding the marker `.` and nothing else.
   Any other chat text on a no-change wake turn is a protocol violation, not politeness, and restating an unchanged wait stays a violation even on a turn the harness forced to speak.
   No attempt is on file for this harness in either direction; if you meet a refusal, record it in `docs/silent-turn-attempts.md` rather than leaving the next seat to rediscover it.

The external service owns the long-running watcher loop.
Each checkpoint runs only the lightweight queue delivery stub with a bounded foreground wait.
