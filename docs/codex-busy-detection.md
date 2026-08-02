# Codex 0.145.0 busy-detection evidence

This doc records the empirical basis for the codex agent-liveness backstop in `bin/fm-watch.sh` (`codex_static_pane_upgrade`) and the related facts in `.agents/skills/harness-adapters/SKILL.md`.
It is evidence, not narrative: every claim below carries the date, version, exact command, and observed output.

## Why the backstop exists

Codex 0.145.0 renders its `esc to interrupt` busy row only during the pre-answer phase of a turn.
It drops the row while an answer streams and, depending on the tool, during a mid-turn tool call, so a healthy codex worker can sit on a pane that renders no busy text at all.
Firstmate's ordinary pane evidence still covers the phases where the pane carries a visible signal:

- streaming token bursts change pane content, so the pane hash moves and the watcher does not treat those changed samples as stale;
- the pre-answer phase renders the row, so `window_is_busy` reads busy.

The gap is a worker on a STATIC pane between visible updates, or in a static tool-call phase, with the row absent for longer than the two polls the non-terminal-stale path needs.
That worker reads idle to `window_is_busy` and would surface as a possible wedge.
The backstop adds a signal that does not read interface text at all: the codex agent PROCESS itself, via `fm_backend_agent_alive`.

## Environment

- Date: 2026-08-02
- `codex --version`: `codex-cli 0.145.0`
- Model in the running TUI: `gpt-5.6-sol` (the bundled default)
- Backend: tmux 3.4, on a scratch tmux socket (`tmux -L codexverify`) isolated from the fleet's server
- codex launched with `--dangerously-bypass-approvals-and-sandbox` in a scratch cwd for the streaming samples

## Fact 1 - the codex process stays the pane's foreground command for the whole turn

This is the load-bearing assumption of the backstop: `fm_backend_tmux_agent_alive` maps `*codex*` to `alive`, so if the foreground command drops to a bare shell mid-turn the backstop would misfire.

Method: sample `tmux display-message -p '#{pane_current_command}'` every 0.4s across a full turn that included a `sleep 18` shell tool call followed by a streamed answer.

Result: `codex` in 100/100 samples across a ~40s turn (and 90/90 in an earlier ~36s turn).
A bare idle shell reports `bash`, which the classifier maps to `dead`; codex exiting on Ctrl+C flipped the foreground command from `codex` to `bash` immediately (see Fact 3).

## Fact 2 - the busy row is absent for a long contiguous stretch, and the pane is STATIC within it

Method: sample every 0.4s, recording (a) whether `esc to interrupt` appears anywhere in the full pane capture and (b) whether the whole-pane content hash changed since the previous sample.

Turn 1 (`sleep 18` tool call then a 3-sentence answer), busy-row timeline relative to turn start:

- `+0.9s .. +25s`: `esc to interrupt` present (pre-answer plus this tool call)
- `+26.4s .. end` (38 consecutive samples, ~15s): row absent

Turn 2 (an 8-sentence explanation, more streaming), cross-tabulating pane-state against the busy row over 120 samples:

```
     10 pane=CHANGED busy=no
      6 pane=CHANGED busy=ROW
    102 pane=STATIC   busy=no
      2 pane=STATIC   busy=ROW
```

Every one of the 102 `STATIC busy=no` samples had `cmd=codex`.
The transitions show the exposure directly: from `+4.7s` to the end of the turn the row was absent, and the pane alternated STATIC/CHANGED as text streamed in bursts, e.g. STATIC/no at `+5.1s`, `+5.9s`, `+6.8s`, `+7.7s`, `+8.9s`, `+9.8s`, `+10.6s`, `+12.3s`.
Two consecutive watcher polls landing in such a stretch is exactly the false-wedge the backstop absorbs.
The row string itself is unchanged and still matches whenever it renders, which is why the busy-signature matching in `fm-watch.sh`/`fm-tmux-lib.sh` is left as-is.

## Fact 3 - exit and resume mechanics (re-confirmed)

Single Ctrl+C from an idle empty composer quit codex outright: the foreground command went from `codex` to `bash` after one press, with no confirmation.

On that clean quit codex printed:

```
To continue this session, run codex resume 019fc488-b6af-7353-a380-2d9b32b88db0
```

This confirms the `To continue this session, run <command>` form and that the runnable command for an unnamed session is `codex resume <uuid>`.
These match the facts already recorded in the harness-adapters codex section; they were re-observed here as a side effect of the busy-row runs and are noted for completeness.

## Carried-forward facts not re-verified here

The trust-dialog Escape-selects-QUIT fact and the `$`-popup settle were not re-exercised in this session (a non-git scratch cwd did not raise the trust dialog on 0.145.0).
They remain as recorded in the harness-adapters codex section from the 2026-07-26 re-verification.

## Maintaining this file

Keep this file as evidence for the codex busy-detection backstop.
If codex changes when it renders the busy row, or the pane's foreground command stops being `codex` mid-turn, re-run the two sampling methods above and update both the numbers here and `codex_static_pane_upgrade` in `bin/fm-watch.sh`.
