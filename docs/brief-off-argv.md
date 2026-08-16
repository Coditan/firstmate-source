# Keeping a worker's launch brief off the command line

A crewmate's launch command is world-readable in the host process table for as long as that agent runs.
Every launch template used to compose the whole encoded brief into that command, so the process table carried, continuously, the full instructions every agent on the host was working from: task, repository, acceptance criteria, internal paths, operating rules.

This document records what was measured, what changed, and which harnesses that change was verified on.
`bin/fm-spawn.sh`'s `launch_template()` owns the contract itself; `bin/fm-operational-input.sh`'s `fm_launch_brief_pointer` owns the construction.

## The two leaks

**Cross-account.**
Any account on this host reads any other account's command lines.
Persistent process-listing protection would close this half; it needs root and is tracked elsewhere.

**Same-account.**
Two workers under one account read each other's command lines.
Process-listing protection does not protect same-uid processes from the same uid, so only taking the brief off the command line closes this half.
The case was found against this fleet's own model panel, whose members ran under one account while being described as structurally independent.

Containerising the vessels was considered and rejected for this purpose: a container relocates the exposure rather than closing it, because the launch lands on the host's process table one layer up.

## Measurement, 2026-08-16, hlr-web-1

Two accounts share this host: `crew` (uid 1000) and `coditan` (uid 1002).
Each home directory is mode 750 owned by its own account, so neither account can read the other's `data/<id>/brief.md` from disk.
The process table was therefore the only channel through which a brief crossed the account boundary.

A sanitised scan of `/proc/*/cmdline` from `coditan`, printing only counts and byte lengths, found foreign and local briefs alike:

```
processes scanned: 495
processes whose command line carries a launch-brief marker: 4
  pid=3481371 uid=1000 comm=codex  cmdline_bytes=9820  same_uid_as_me=False
  pid=3542588 uid=1002 comm=claude cmdline_bytes=11511 same_uid_as_me=True
  pid=3704699 uid=1002 comm=claude cmdline_bytes=11348 same_uid_as_me=True
  pid=3724228 uid=1002 comm=bash   cmdline_bytes=1279  same_uid_as_me=True
```

The uid 1000 row is the cross-account half read from uid 1002.
Of the two uid 1002 `claude` rows, one was the reading process itself and the other was a sibling worker under the same account: the same-account half, read without any privilege at all.

### Before and after, by sentinel spawn

Each sentinel is a real worker spawned through `bin/fm-spawn.sh` on the ordinary supervised path, with a unique random token in its brief body and one instruction that proves receipt.
Every run used an isolated firstmate home, a private tmux server (`tmux -L fmsent-<label>`), and a real pooled worktree, so nothing touched the captain's fleet.
Both halves are required for a pass: a worker that never got its brief is not a pass.

| Harness | Run | Brief received and followed | Sentinel token found in any host command line |
| --- | --- | --- | --- |
| claude 2.1.233 | before | yes | yes - pid 3832468, `comm=claude`, 827-byte command line |
| claude 2.1.233 | after | yes | no - 0 of 474 processes |
| codex-cli 0.145.0 | before | yes | yes - pid 3881761, `comm=codex`, 960-byte command line |
| codex-cli 0.145.0 | after | yes | no - 0 of 480 processes |

What the process table shows after the change, read from an ordinary listing:

```
=== pid 4023281 (claude) ===
  claude
  --dangerously-skip-permissions
  --settings
  /home/coditan/.treehouse/project-1ba1fa/1/project/.claude/settings.fm-task.json
  <U+2063>FIRSTMATE_OP: v1 launch-brief: You are a crewmate: an autonomous worker agent
  managed by firstmate. Work on your own; do not wait for a human. Your launch brief is
  the file /tmp/fm-sentinel-after-claude-BNzMlJ/home/data/sent-after-claude/brief.md -
  read that entire file now, before anything else, and follow it as your instructions
  for this session. It is deliberately not on this command line, and nothing further
  will be sent.
```

Fixed prose and one path.
The codex sentinel's command line has the same shape alongside its profile flags.

### Verified, and not verified

Verified by sentinel spawn on this host: **claude** and **codex**.

Not verified here, individually and with the reason:

- **opencode** - UNVERIFIED.
  No `opencode` binary is installed on this host, so no worker could be launched to measure.
- **pi** - UNVERIFIED.
  No `pi` binary is installed on this host.
  The Pi calm-mode E2E in `tests/fm-calm-pi-extension.test.sh` also skips here for the same reason (`skip: installed @earendil-works/pi-coding-agent package not found`), so the Pi side rests on its static assertions and on the executed launch-composition test below.
- **grok** - UNVERIFIED.
  No `grok` binary is installed on this host.

All three have their launch templates converted and exercised by the executed composition test, but that is not the same evidence as a sentinel spawn and is not reported as such.

## What changed

Each installed CLI was checked for a native prompt-file flag on its supervised interactive path, against the installed version rather than documentation:

- `claude --help` (2.1.233) offers a positional `prompt` and system-prompt flags.
  There is no flag that reads the first user turn from a file, and piping stdin switches Claude Code to non-interactive print mode, which is not the supervised path.
- `codex --help` (0.145.0) offers a positional `[PROMPT]`.
  There is no prompt-file flag; `-c`/`--image` do not carry one.

So no harness can be handed a brief file directly, and the one mechanism all five share is the first candidate on the list: a file pointer the worker reads.
The brief's bytes now travel filesystem to worker, and only its address travels argv to worker.

`bin/fm-operational-input.sh launch-pointer <brief-path>` builds that launch input.
It takes the path and never opens the brief, and refuses a path that is not a readable file rather than launching a worker at a brief that is not there.
The wire kind is still `launch-brief`, so every consumer that classifies a launch input keeps working.

`.pi/extensions/fm-calm.ts` reconstructs the value it expects a launch to arrive with, and now derives it from the brief's path through that same command instead of reading the brief and encoding its body.
The TypeScript side shells out to the shell owner, so the two cannot drift.

### The half-converted shape

Pi's adapter already set `FM_FIRSTMATE_PI_LAUNCH_BRIEF` to the brief's path while the full encoded brief still rode the same command line.
That variable feeds calm-mode visibility; it was never a delivery mechanism.
A brief-path variable next to a brief-carrying command reads as done and is not, so `tests/fm-spawn-brief-off-argv.test.sh` asserts the two independently rather than letting the presence of the variable stand in for the fix.

### What this does not close

The brief file exists on disk either way - `data/<id>/brief.md` is the durable record - so no delivery mechanism could have removed it, and none of the three candidates differ on that point.
What the change closes is the process-table channel: a brief is no longer handed to every account on the host, and to every same-account sibling, in every listing anyone runs.
A same-uid process can still deliberately open another task's brief file, because a same-uid file read is closable only by separating the uids, not by anything a launch command can do.

The raw-launch escape hatch in `bin/fm-spawn.sh` - the unverified-adapter path where the caller supplies a whole command - is also outside the contract, because its command is authored by the caller rather than by a template.
Refusing a brief-reading shape there would remove a launch that works today, so that path warns instead, naming the pointer form to use.
`AGENTS.md` already forbids dispatching on an unverified adapter, so this is a narrow boundary rather than an open one.

## Enforcement

`tests/fm-spawn-brief-off-argv.test.sh` is the regression gate.
For every harness, and for the separate secondmate template shapes, it spawns through `bin/fm-spawn.sh` with a fake tmux that captures the literal launch command, then **executes** that command with the harness replaced by a recorder that writes its own argv, and fails if a sentinel that exists only in the brief body appears there.
Executing it is the point: a `$(cat brief)` and a `$(... launch-pointer path)` are equally innocent as strings, and only the shell can say which one puts a brief on a command line.

It also asserts the launch still delivers - the argv names the brief and carries the `launch-brief` kind - so a launch that leaks nothing because it delivers nothing cannot pass.
`test_every_launch_template_is_covered` enumerates the harnesses `launch_template()` accepts and fails if one has no case, so an adapter added later cannot ship unmeasured under a green suite.

With the templates reverted to their pre-change shape, every case fails on the argv measurement:

```
claude_launch_keeps_the_brief_off_argv         not ok - claude-ship: the brief body reached the harness argv, ...
codex_launch_keeps_the_brief_off_argv          not ok - codex-ship: the brief body reached the harness argv, ...
opencode_launch_keeps_the_brief_off_argv       not ok - opencode-ship: the brief body reached the harness argv, ...
pi_launch_keeps_the_brief_off_argv             not ok - pi-ship: the brief body reached the harness argv, ...
grok_launch_keeps_the_brief_off_argv           not ok - grok-ship: the brief body reached the harness argv, ...
secondmate_launches_keep_the_charter_off_argv  not ok - claude-secondmate: the brief body reached the harness argv, ...
pi_brief_path_binding_is_not_mistaken_for_the_fix  not ok - pi sets a brief-path variable AND still puts the brief body on the command line
no_launch_template_reads_the_brief_into_the_command not ok - a launch template composes the brief body into the command again
```
