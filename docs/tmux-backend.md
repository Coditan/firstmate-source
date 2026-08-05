# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

### Firstmate keeps its own window (`fm_tmux_ensure_own_window`)

Firstmate and its crews share one tmux session, so a resume with `tmux new -A -s <session>` can attach the primary firstmate process INTO a crew's `fm-<id>` window.
That was observed on 2026-07-06: `fm-crew-state.sh` and the watcher then read firstmate's own pane as that crew's pane (a busy firstmate reads as a "working" crew, an idle one as a stalled crew), and a respawn of `<id>` collides on the duplicate window name.
To prevent it, `bin/fm-session-start.sh` calls `fm_tmux_ensure_own_window` (in `bin/fm-tmux-lib.sh`) at the top of every session start: when running inside tmux and the current window is named like a crew window (`fm-*`), it renames that window to the reserved name `firstmate`.
The rename targets the caller's own window, needs no lock, is idempotent, is a no-op outside tmux, and never touches a window the operator named anything other than `fm-*` (a deliberate cockpit name is kept).
This is why crew spawning is already safe on this backend even though firstmate shares the session: `fm-spawn.sh` always creates crew windows detached and named (`tmux new-window -d -n fm-<id>`), so the only remaining hazard was firstmate's own window identity, which this guard fixes.
The real-tmux coverage is in `tests/fm-backend-tmux-smoke.test.sh`.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Target resolution: `display-message` answers for the wrong window

`tmux display-message -p -t <target>` does not refuse a target that does not resolve.
It answers for a different window and still returns 0, so any check built on its exit status passes for a window that does not exist.
Reported by Tugboat 2026-07-28 and reproduced here 2026-08-05 on tmux 3.4 (Linux 6.8.0), with three invented window names against a live session:

```sh
$ for t in firstmate:zzz-nope firstmate:also-not-real coditan:zzz-nope; do
    tmux display-message -p -t "$t" '#{pane_id} #{session_name}:#{window_name} #{pane_current_command}'; done
%89 firstmate:bash bash
%89 firstmate:bash bash
%0 coditan:claude claude
```

Every invented shape behaves this way, and the exit status never signals it:

```sh
$ for t in firstmate:zzz-nope 'firstmate:@9999' 'coditan:claude.99' '%9999' '@9999' nosuchsession:win zzz-bare-nope; do
    out=$(tmux display-message -p -t "$t" '#{pane_id}' 2>&1); printf '%-22s rc=%s -> %s\n' "$t" "$?" "$out"; done
firstmate:zzz-nope     rc=0 -> %89
firstmate:@9999        rc=0 -> %89
coditan:claude.99      rc=0 -> %0
%9999                  rc=0 ->
@9999                  rc=0 ->
nosuchsession:win      rc=0 ->
zzz-bare-nope          rc=0 ->
```

The fallback is the target session's current window, or the active client's, and it falls back to an empty format expansion only when the session itself cannot be resolved.

**Why the symptom differs by host, and why that made it worse.**
On Tugboat's host the fallback window was running `claude`, so an invented name returned `alive`.
On this host it was running `bash`, so the same name returned `dead`.
Neither is a reading of the target.
A fleet-wide defect whose symptom depends on what the operator's own pane happens to be doing gets diagnosed as a local environment quirk on whichever host reports it second.

**`display-message` is the only offender among the commands this backend uses.**
Measured the same day, on the same server:

```sh
$ tmux capture-pane -p -t firstmate:zzz-nope -S -1 >/dev/null 2>&1; echo $?
1
$ tmux send-keys -t "$S:zzz-nope-window" 'echo MISDELIVERED_KEYSTROKE' Enter; echo $?
can't find window: zzz-nope-window
1
$ tmux list-panes -t firstmate:zzz-nope >/dev/null 2>&1; echo $?
1
$ tmux list-panes -t firstmate:bash -F '#{pane_id} #{pane_active}'
%89 1
```

`capture-pane` and `send-keys` refuse correctly, so no pane content was ever misread and no keystroke was ever misdelivered.
`list-panes` refuses every invented shape above and resolves every real one - window names, window ids (`@N`), pane ids (`%N`), and `session:window.pane` - which makes it the correct primitive and needs no target-shape parsing of firstmate's own.

**The gate.**
`fm_tmux_resolve_pane` (`bin/fm-tmux-lib.sh`) is the one sanctioned way to turn a caller-supplied target into something readable: it resolves through `list-panes` and prints the pane id, or refuses.
Callers then read the resolved pane id rather than the original target, so the read is exact rather than subject to tmux's own prefix matching, and a pane that disappears between the resolve and the read degrades to an empty format expansion that every caller already treats as unreadable.
`tests/fm-tmux-target-resolve.test.sh` enforces that no `bin/` script reads `display-message -p -t` against an unresolved caller-supplied target, and self-checks that the rule still detects a known offender.
The hazard had been documented in a comment beside `bin/fm-spawn.sh`'s worktree poll since that poll was written, while `fm_backend_target_exists`, `fm_backend_tmux_current_command`, and `fm-crew-state.sh`'s `pane_readable` kept using the unguarded form.
A comment next to one caller is not enforcement, which is why the rule is now a test.

**Adjacent sites not changed, recorded rather than silently permitted.**
`fm_backend_tmux_container_ensure` (`bin/backends/tmux.sh`) reads `#{session_name}` with a bare `display-message -p` and no `-t`, which resolves against the caller's own current window rather than an arbitrary target.
`bin/fm-supervise-daemon.sh`'s away-mode status-line flash calls `display-message` without `-p` to display a message rather than to produce a verdict.
Neither was measured to answer wrongly during this work, so neither was changed on assumption.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.
The same probe is also used by the codex-only stale-path backstop in `bin/fm-watch.sh`, because codex-cli 0.145.0 can drop its rendered busy row while the agent process is still alive.

Both probes read through the resolve gate above, so a target that does not resolve is refused rather than answered for.
A target that does not resolve reports `unknown`, never `dead`: `dead` means "this pane exists and confidently holds no agent", which is a reading of the target, while whether the endpoint exists at all is `fm_backend_target_exists`'s question and a gone endpoint routes to the recovery path instead.
The secondmate-liveness sweep turns `unknown` into a reported skip and gates a respawn on `dead` only, so under the defect that gate could be satisfied or starved for reasons unrelated to the target: a dead secondmate never respawned on one host, or a live one at risk of duplication on another.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

## Submit acknowledgement: "landed" is empty (with one busy-queue exception)

The shared `fm_tmux_submit_enter_core` (`bin/fm-tmux-lib.sh`) types the message once, then retries Enter (Enter only, never a retype) until the composer clears.
The submit is reported `empty` iff the composer cleared, which is the same corrected, border-aware detector the composer guard uses, so a bordered-but-empty composer is correctly seen as the positive acknowledgement of a delivered submit.
A genuine swallowed Enter leaves the typed text in the composer and the function reports `pending`; `fm-send` fails on `pending` so the captain learns the steer did not land instead of leaving it unsubmitted.

**Exception (opencode 1.18.4, on the tmux backend):** while the agent is mid-turn, opencode accepts Enter as a "send when the turn ends" keystroke but does not clear the composer until then, so the typed text stays visible the whole time.
After the Enter-retry budget is spent and the composer still reads `pending`, the submit core falls back to `fm_pane_is_busy`:
a busy pane means the harness accepted and queued the Enter (reported as `empty`, so the caller does not re-send), and an idle pane keeps `pending` as a genuine swallow.
This is the only place that exception lives; the herdr adapter observes the same opencode behavior but needs a separate fix (see the opencode note in [harness-adapters](../.agents/skills/harness-adapters/SKILL.md) and the opencode-busy gap recorded in [herdr-backend.md](herdr-backend.md)).
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four scenarios (busy pane + pending composer -> `empty`, idle pane + pending composer -> `pending`, busy pane + cleared composer -> `empty`, idle pane + cleared composer -> `empty`).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
