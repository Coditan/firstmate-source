# First-mate absence: detection and restart

This is the one owner of what happens when a home's primary firstmate seat is gone.
Two components divide the job and the split is deliberate: `bin/fm-seat-alarm.sh` reports the absence outward, and `bin/fm-seat-respawner.sh` puts a seat back.
[seat-respawner.md](seat-respawner.md) owns the restart component's own mechanics; this file owns why there are two, what supervises each, and what is still not covered.

## The measured failure this exists to remove

On 2026-08-27 the seat process on `coditan-vessel` was simply gone.
43 wakes piled up undrained between roughly 02:27Z and 08:15Z, two crewmates waited on a supervisor that could not answer, and the captain found a bare shell behind his own terminal entry.
Another vessel restarted it by hand.

Nothing was broken except the one thing nobody was watching.
The watcher stayed alive throughout.
The delivery listener stayed alive throughout.
The container reported healthy, correctly, because everything it supervises was fine.
`bin/fm-seat-respawner.sh` was already in the tree and is the right shape for the restart, and it was not running.
It had never been installed on this home at all - no service environment file, no log - because until now it could only be supervised by a `systemd --user` unit and this container has no service manager.
The starting state was therefore "not installed", not "installed and refusing", which is why the fix is a new supervision tier rather than a repair of an existing one.

Two properties follow, and both are load-bearing.

**A restarter without a detector moves the silent failure one layer out.**
If the restart does not happen, or does not work, a fleet with only a restarter is exactly as blind as this one was.
That is why detection is the primary component here and not the trimming.

**The seat cannot report its own absence.**
Every other check in this fleet prints a line, the watcher wakes firstmate, and firstmate decides what reaches the captain - `bin/fm-memory-alarm.sh` says so explicitly and is right to.
That routing is exactly wrong for this one reading, because firstmate is its subject.
A line printed into the wake queue while the seat is gone joins the pile that is already not being read.
So this is the one alarm in the fleet that carries its own message out, through `bin/fm-tg-send.sh`, which needs no session to exist.
It takes no judgement firstmate could have taken instead.

## What the detector keys on, and what it must never key on

A process-name test cannot tell this seat from its crew.
During the outage both live `claude` processes in the container were crewmates in task worktrees, each carrying `--settings <worktree>/.claude/settings.fm-task.json`, while the seat itself was absent.
Anything counting processes by name, or reading `pane_current_command=claude`, would have called the vessel healthy while it was blind.

The seat's own tmux window is no better an anchor.
`/usr/local/bin/vessel-entrypoint` creates exactly one session, `vessel`, with one bare shell window, and nothing in it ever creates a first mate; the `firstmate` window the captain's shortcut targeted was made by hand once and is not reproducible by anything on the seat.
That window also survives the seat's death as a bare shell, and a respawn opens a new window rather than reviving it.

So the reading keys on the one artefact only a seat produces: this home's session lock, `state/.lock`, whose record names the harness pid **and** the pid table that pid came from.
`bin/fm-harness-pid-lib.sh` owns that record and the liveness decision.
`tests/fm-seat-alarm.test.sh` pins the crew-immunity property directly: a live harness-shaped process running while the lock names a dead pid must still read as absent.

## Five verdicts, because two would lie

| Verdict | Means | Notifies |
| --- | --- | --- |
| `present` | the lock names a live harness process | no |
| `absent` | a seat ran here and is not running now | yes |
| `standing-down` | `state/.seat-stay-down` exists, so the absence was declared | no |
| `unattended` | no lock and no published endpoint: no seat has ever run here | no |
| `unmeasured` | the reading could not be taken | **yes** |

`unmeasured` notifying is the point rather than a detail.
An alarm that goes quiet when its instrument breaks is indistinguishable from a healthy vessel, which is the defect this whole area exists to remove rather than to add another instance of.
Nothing in `bin/fm-seat-alarm.sh` converts a failed reading into a pass, and `--status` exits 3 rather than 0 for it.

`standing-down` reuses the respawner's existing marker instead of inventing a second one, so deliberate shutdown stays a single fact with a single owner in `bin/fm-seat-stay-down.sh`.

Two facts travel with an absence, because "the seat is down" alone does not tell the captain whether to get up: how much work is waiting, and whether anything is trying to bring the seat back.
The first is read from `state/.wake-queue`, whose records carry their own queued-at epoch as the first tab-separated field, so both the depth and the age of the oldest waiting item are readable.
Until this existed nothing read either as a symptom - `bin/fm-delivery-lib.sh` reads the depth only to fill in a verdict sentence, and reads no age at all.
The second is read from `bin/fm-seat-respawner-service.sh status`, and a reading that cannot be taken is reported as unreadable rather than as "a restart is under way".

It speaks on transition and then repeats while the condition lasts, deliberately uncapped.
A cap would produce an alarm that goes quiet exactly when the outage is longest.

## A launched seat is not yet a first mate

This is the requirement that makes the difference between a restart and a restoration, and it was missing from the first version of this work.

Measured on this fleet on 2026-08-27: with a working launch command, a keeper and a supervisor all in place, a launched seat **sits idle**.
An agent process starts and waits for input.
Session start has not run, so no endpoint is published, no session lock is taken, and the delivery listener has no address to submit to.
The observed result was a queue standing at 47 for four minutes with a healthy agent sitting in the window.
`bin/fm-sessionstart-nudge.sh` injects context into a session that starts and explicitly cannot run session start itself, so nothing on the vessel closed that gap.

So there are four requirements, not three: launch the seat, supervise the launcher, report the absence, **and give the fresh seat its first turn**.

`bin/fm-seat-respawner.sh` is the only component that can give it, because it is the only one that knows the pane it just created - `tmux new-window -P -F '#{pane_id}'` - and that pane id is the sole address of a seat which has not published one.
The delivery listener structurally cannot: the endpoint it would need is exactly what the idle seat has not written.

The submit reuses this fleet's owned primitives rather than raw keystrokes, so the safety rule holds identically to delivery's: `pane_is_busy` and `fm_backend_composer_state` from `bin/fm-pane-activity-lib.sh` and `bin/fm-backend.sh` decide whether the pane is a safe target, and only an affirmatively empty genuine agent composer is ever typed into.
That matters most in the failure case: a launch command that did not start an agent leaves a bare shell, which the classifier reports as `unknown`, and handing a shell that text is precisely what must not happen.
The message itself is built by `bin/fm-operational-input.sh` as a typed `session-start` operational input, and its body is the instruction only - what the seat then does is `AGENTS.md` section 3's, and a body summarising the fleet here would be a second copy of state that could disagree with the durable records the seat is about to read.

The pending first turn is recorded in `state/.seat-first-turn`, so it survives the respawner itself restarting, and it is bounded: a turn that never lands is abandoned out loud in `state/.seat-respawner.log` after `FM_SEAT_FIRST_TURN_DEADLINE` rather than retried forever in silence.

**The success test moved with it.**
A restart is not finished when the window exists.
It is finished when a seat holds this home's session lock, which only a session start does - and that is the same fact `bin/fm-seat-alarm.sh` reads.
The two halves therefore agree, by construction, that a launched-but-idle seat is still an absence: the alarm goes on reporting it, and `tests/fm-seat-absence-e2e.test.sh` pins that agreement directly by requiring the home to read `ABSENT` in the window between the process starting and its first turn landing.

## What supervises what, stated plainly

This is the question a restarter must answer about itself, and on this container the honest answer used to be circular.

Every keeper in this fleet - the watcher's, the delivery listener's - is started by `bin/fm-bootstrap.sh`, and `bin/fm-bootstrap.sh` runs at **seat session start**.
A restarter supervised that way is re-ensured by the very thing it exists to restart.
That circle cannot turn once the seat is the part that is gone, so shipping only a keeper for the respawner would have produced a restart path that works in every case except the one it was built for.

The arrangement that ships instead is a pair rather than a chain:

- `bin/fm-seat-respawner-service.sh --arm` installs a watcher check that converges the respawner's keeper tier **on every watcher sweep**.
  The watcher outlives the seat - it is the component that stayed alive through the outage - so the seat is no longer anywhere in the restart path.
- `bin/fm-seat-respawner.sh` revives a **provably dead** watcher in return, through `fm_watcher_healthy`, this fleet's one owner of that question.
  It is deliberately narrow: never on a recorded-version or recorded-PATH mismatch, which are convergence decisions belonging to a session holding the fleet lock, and rate-limited so a watcher that cannot start is retried rather than hammered.

So either process surviving restores both, and only the loss of **both** is unrecoverable without a seat.

## What is still not covered

**If the watcher and the respawner both die, nothing recovers either, and nothing reports it.**
The detector is hosted by the watcher, so it cannot report the watcher's own death; an alarm hosted by the thing it depends on is silent about that thing.
This is stated rather than hidden because it is the residual the design does not close, not a case nobody thought of.

No component inside this repository can close it.
Closing it needs an anchor outside every process a seat ever started, and this container has exactly one: PID 1, `/usr/local/bin/vessel-entrypoint`, which ends in `while :; do sleep 3600 & wait $!; done` and supervises nothing.
Measured on `coditan-vessel`, 2026-08-27, from inside the container:

```text
$ ps -p 1 -o args=
/sbin/docker-init -- /usr/local/bin/vessel-entrypoint
$ systemctl is-system-running
offline
$ ls -d /run/systemd/system
ls: cannot access '/run/systemd/system': No such file or directory
$ command -v crond cron crontab atd at supervisord runsvdir s6-svscan
(no output)
```

`systemctl` is installed at `/usr/bin/systemctl`, so a `command -v` probe would call systemd available here; every service in this fleet correctly probes `systemctl --user show-environment` instead, which fails.

Two things would close the residual, and neither is this repository's to take:

- The container image's entrypoint supervising the watcher, which would make the anchor real.
  That belongs to whoever owns the image.
- User lingering for this account, so a `systemd --user` manager exists.
  That was disabled by the captain's own decision of 2026-08-26 and walks back the standing rule that nothing of this vessel's runs outside the container, so it is his call and is named here as an option rather than proposed as the answer.
  Whether it is currently enabled **could not be measured from inside the container**: `loginctl` answers `System has not been booted with systemd as init system (PID 1). Can't operate.`

One further dependency of the restart path is worth naming because it is invisible until it bites.
The respawner launches into the tmux server recorded in `state/.primary-endpoint`, and refuses when that server is gone.
On the real vessel the server outlives the seat only because the entrypoint's bare `vessel:0` window keeps it alive; if the seat's window were the only one, the server would exit with the seat and the respawner would correctly refuse to launch.
`tests/fm-seat-absence-e2e.test.sh` reproduces that dependency deliberately rather than papering over it.

## The seat's environment is the launch command's, not the launcher's

`bin/fm-seat-respawner.sh` used to compose `export ... PATH=<the respawner's own PATH>` into the fresh seat, so a respawned seat never read `~/.profile` and silently ran whatever tool set the launcher happened to have.
It now composes no PATH at all, and `config/seat-launch-command` owns environment resolution.

The measurement behind that, on `coditan-vessel`, 2026-08-27:

```text
$ env -i HOME=/home/coditan /bin/bash -lc 'command -v claude; claude --version'
/usr/local/bin/claude
2.1.234 (Claude Code)
$ env -i HOME=/home/coditan TERM=xterm /bin/bash -lic 'command -v claude; claude --version'
/home/coditan/.npm-global/bin/claude
2.1.247 (Claude Code)
```

The difference is `~/.bashrc`'s own guard:

```text
$ sed -n '5,9p' ~/.bashrc
# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac
```

`~/.profile` sources `~/.bashrc` for any bash, but that guard returns before the line adding the npm prefix to `PATH`, so a **login shell alone fixes the tool suite and not the agent binary**; only an interactive login shell reaches the newer one.
No value composed outside that chain can reproduce it, and pinning one can only contradict it.
`/bin/sh` on this host is `dash`, which matters for anything ever appended to `~/.profile`: it is read by non-bash login shells too.

`tests/fm-seat-respawner.test.sh` asserts the absence of the pin rather than its presence, because the defect was invisible - a pinned PATH produces a seat that runs perfectly, on the wrong binary.

## Verified

Recorded from the machine this landed on, 2026-08-27.

`tests/fm-seat-absence-e2e.test.sh` is the acceptance proof, and it is deliberately not a service reporting itself active.
It starts a real tmux server on a private socket, runs a stand-in seat that behaves like a real agent - it draws the composer glyph the shared classifier accepts, waits for a line, and only then does what a session start does - gives that first seat its turn by hand exactly as a human once did on this vessel, `kill -KILL`s it, and then requires five separate observations back:

1. the absence left the home while it was still absent, and carried the waiting work and its age with it;
2. a replacement seat process was started with no human in the loop;
3. **the home still reads `ABSENT` at that point**, because the process exists and has not yet had a turn;
4. the fresh seat was given a typed first turn telling it to run its session start, after which it holds the lock under a **different pid**;
5. the returned seat is told it was away.

A second case sets the stay-down marker and requires the same real kill to be left alone.

The stand-in deliberately does NOT take the lock on startup.
One that did would hide the idle-seat failure, and the suite was checked against that: with `deliver_first_turn` disabled, the run fails at observation 4 rather than passing anyway.

```text
$ bash tests/fm-seat-absence-e2e.test.sh
ok - a deliberately killed seat is reported outward, comes back, and is given its first turn
ok - a deliberately stood-down seat is left down and not reported as missing
```

The standing rule in [seat-respawner.md](seat-respawner.md) still holds: this is never tested by killing a live firstmate seat.

## What firstmate must run on the live home

The suite above proves the machinery on a throwaway home.
It does not prove this home's own configured launch command, its own Telegram sender, or its own keeper, and those are per-home facts a worktree cannot establish.
From the live home, with the captain present, in this order:

```text
bin/fm-seat-alarm.sh --status
bin/fm-seat-respawner-service.sh select
bin/fm-seat-respawner-service.sh --arm
bin/fm-seat-respawner-service.sh status
```

`select` must answer `keeper` on this container and `status` must answer `up:` after the arm.
Then, and only with the captain watching, the real end-to-end: note the seat's recorded pid from `bin/fm-lock.sh status`, close the seat, and confirm a message arrives on the captain's channel within one watcher sweep and that `bin/fm-lock.sh status` afterwards names a **different** live pid.
`bin/fm-seat-stay-down.sh down` cancels the restart first if the seat is being closed on purpose.
