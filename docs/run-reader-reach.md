# Run-state reader reach

The run-state reader, `bin/fm-crew-state.sh`, answers what a crew is actually doing.
Its authoritative source is a no-mistakes run-step, so it needs the no-mistakes CLI.
This document records how that dependency stopped being reachable, what was measured, what was changed, and which other tools were checked for the same shape.

## The defect

Measured on the coditan vessel, 2026-08-13.
The CLI resolved from an interactive shell and from nothing else:

```
$ command -v no-mistakes
/home/coditan/.no-mistakes/bin/no-mistakes

$ env -i HOME=/home/coditan bash -lc 'command -v no-mistakes'
(nothing)
$ env -i HOME=/home/coditan bash -lc 'echo $PATH'
/home/coditan/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
```

The login PATH did not reach it because the installer's link step never ran on this seat: `docs/install.sh` links into `$HOME/.local/bin` only when that directory is already on the installing shell's PATH, and otherwise tries `/usr/local/bin` with `sudo`.
The binary landed at the install default and nothing pointed at it but an interactive profile.

The same two tasks, read the same second, two ways:

```
$ FM_HOME=... bin/fm-crew-state.sh fleet-pin-bump-6ef0e3e
state: working · source: run-step · validating (running)

$ env -i HOME=/home/coditan bash -lc 'FM_HOME=... bin/fm-crew-state.sh fleet-pin-bump-6ef0e3e'
state: degraded · source: missing-dependency · cause: run-reader-missing · no-mistakes CLI not
on PATH: the run-step state was never read and its 'done' event was never reconciled against the run

$ env -i HOME=/home/coditan bash -lc 'FM_HOME=... bin/fm-crew-state.sh fm-telegram-send-documents'
state: degraded · source: missing-dependency · cause: run-reader-missing · no-mistakes CLI not
on PATH: the run-step state was never read and its 'needs-decision' event was never reconciled
against the run
```

Every context that inherits nothing read the second answer: the monitoring service, the hooks, a fresh login, and an independent reviewer sweeping the fleet.

The consequence was not missing information but MANUFACTURED information.
A reviewer that cannot read the run cannot observe a decision being resolved, so it re-reported the same finding as outstanding after each answer; the captain answered one question four times in a day.

## What was NOT wrong

The `degraded` verdict.
The reader refused to answer and named its cause rather than falling back to a weaker source and presenting that as authoritative, which is the only reason this was diagnosable at all.
`bin/fm-crew-state.sh`'s header owns the full cause vocabulary and the reasoning behind it.
The dependency was the defect; the honest report about it was the instrument working.

## The fix, and why this one

`bin/fm-nm-path-lib.sh` resolves the CLI from the seat's own install location instead of asking the caller's environment for it, and `bin/fm-crew-state.sh` calls it before its first lookup.
The location is the installer's own contract, read from `docs/install.sh` at `kunchenguid/no-mistakes` on 2026-08-13:

```
INSTALL_DIR="${NO_MISTAKES_INSTALL_DIR:-$HOME/.no-mistakes/bin}"
```

The alternative was to place the binary somewhere the world inherits - a link in `/usr/local/bin`.
That was rejected on three counts.
Three accounts run agents on this machine and each has its own install with its own `state.sqlite` and daemon socket, so one shared system-wide entry would point some seat at another seat's pipeline state.
It needs root, which this repository cannot assume.
And it is a machine fact no checkout can carry or verify, so a new seat would be silently blind again.
Deriving the location from `HOME` is correct for all three accounts at once, needs no privilege, and no seat has to edit a shell profile.

Two properties are deliberate and are pinned by `tests/fm-run-reader-reach.test.sh`:

- It never wins.
  `fm_axi_prepend_path` prepends, because a home is meant to run the AXI copies it maintains.
  This library appends, and only when the CLI is unreachable at all, because firstmate does not own the no-mistakes install and has no standing to change which binary an environment that already resolves one runs.
  Where `command -v no-mistakes` already answers, it is a no-op.
- It never invents an all-clear.
  With no CLI on PATH and none at the install location, nothing is added and the `degraded · cause: run-reader-missing` verdict stands unchanged.

## The detection

A dependency that only surfaces when somebody happens to read a task's state is not detected, it is stumbled upon.
`bin/fm-bootstrap.sh`'s `run_reader_reach_check` asserts at every session start that a context inheriting no shell setup would reach the CLI, and prints `RUN_READER:` when it would not.

The assertion is asked against `FM_SERVICE_PATH_BASE_DEFAULT` - systemd's user-manager default, and the least reach any unattended shape has - so a line means every unattended shape is blind, not only the strictest one.
It is deliberately NOT `command -v no-mistakes`: that asks whether the OPERATOR can run it, and that answer stayed true through every week of the blindness.

Absence keeps its existing owner.
When nothing anywhere resolves the CLI, `MISSING: no-mistakes` already says so and the repair is to install it; `RUN_READER:` stays quiet for that case and adds only the sentence `MISSING:` cannot say.
The same split, for one recorded service rather than for the seat, is `WATCHER_UNIT: the watcher's recorded PATH cannot reach ...` (`docs/configuration.md` "Watcher service").
A repair on one side does not clear the other.

The assertion was seen to fail before it was trusted.
`tests/fm-run-reader-reach.test.sh` drives the real `bin/fm-bootstrap.sh` over a seat whose CLI sits only on a profile-style PATH entry and asserts the line appears, over a seat whose install an unattended context reaches and asserts it does not, and over a seat with no CLI at all and asserts `MISSING:` owns it.
Removing `run_reader_reach_check` from bootstrap fails the first case alone; removing `fm_nm_ensure_reachable` from the reader fails the resolution cases alone.

## Verification

Against live tasks on the vessel, after the change:

```
$ env -i HOME=/home/coditan bash -lc 'FM_HOME=... bin/fm-crew-state.sh fleet-pin-bump-6ef0e3e'
state: working · source: run-step · validating (running)
```

Identical to the interactive read, for every live ship task.
`bin/fm-bearings-snapshot.sh`, which reads every crew through the same helper, produced byte-identical crew rows interactively and under the stripped base PATH after the change, and disagreed on four of five rows before it.

The genuine-absence case still refuses:

```
$ env -i HOME=/home/coditan NO_MISTAKES_INSTALL_DIR=<empty dir> bash -lc '... fm-crew-state.sh ...'
state: degraded · source: missing-dependency · cause: run-reader-missing · ...
```

## Other tools with the same shape

Measured on the coditan vessel, 2026-08-13, by comparing `command -v` on an interactive PATH against the same lookup on systemd's user-manager default.
Reachable interactively, absent unattended: the six AXI-suite tools, `no-mistakes`, `gh`, and `treehouse`.
`node` and `npm` differ too, but as a version shift (`~/.nvm/.../v20.20.2` against `/usr/bin`) rather than an absence.

Two mechanisms already cover part of that surface.
`fm_axi_prepend_path` resolves the AXI suite from `$FM_HOME/.local/axi/bin` in the fifteen scripts that call it, and `bin/fm-service-path-lib.sh` composes a PATH for background services that lists every tool above, so watcher children reach them - subject to that library's own documented limit, that a converging session with poor reach records poor reach.

What neither covers is a script invoked DIRECTLY by an unattended context.
Six scripts invoke one of these tools in command position without resolving it:

| script | tool | assessed |
| --- | --- | --- |
| `bin/fm-backlog-lint.sh` | `tasks-axi` | confirmed below |
| `bin/fm-bearings-snapshot.sh` | `gh` | only on the opt-in PR read |
| `bin/fm-home-seed.sh` | `no-mistakes`, `treehouse` | run by firstmate; fails loudly |
| `bin/fm-pr-check.sh` | `gh` | run by firstmate |
| `bin/fm-pr-poll.sh` | `gh`, `glab` | run by the watcher, so covered by the composed service PATH |
| `bin/fm-tasks-axi-lib.sh` | `tasks-axi` | sourced by resolving callers |

A library or a script whose only callers already resolve is not itself a defect; what matters is whether an unattended caller exists.
One confirmed second instance:

```
$ FM_HOME=... bin/fm-backlog-lint.sh
BACKLOG_STALE: task fleet-host-protection-... ; fix: run tasks-axi unblock ...

$ PATH=<systemd user default> HOME=/home/coditan FM_HOME=... bin/fm-backlog-lint.sh
fm-backlog-lint: tasks-axi not found
```

It is a MILDER instance of the same defect than the reader's, and the difference is worth keeping straight.
It says something rather than answering blind, so it cannot be mistaken for a clean backlog by a reader.
But it exits 0 while saying it, so a caller that switches on exit status alone still reads it as clean.

This survey covers `bin/*.sh` and `bin/backends/*.sh` invocations in command position.
It does not cover tools reached from inside a project's own tooling, from a registered custom `state/<id>.check.sh`, or through a harness hook's own environment, and it measured one seat on one machine.
