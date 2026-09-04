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
That record is also what holds the next launch.
The delivery verdict stays undeliverable until the fresh seat finishes session start and publishes an endpoint, which outlasts the first backoff, so a respawner that kept launching on schedule would leave a live agent in a window nothing tracks - one per retry.
While the record stands the launch is withheld, but the wait is not free: each cycle that is otherwise due spends a hold, holds count toward the same bound as launches, and so a first turn that never lands reaches that bound, gives up, and says so rather than waiting forever in silence.
A hold is never counted as a launch, because an episode whose first turn never lands makes exactly one window call and reporting five would send the captain to a machine whose real state is an open pane with an agent that never reached session start.
Past the deadline the record is retired unless the turn was submitted *and* the pane is confidently still there - only a confident yes holds a launch, an unreachable backend still abandons - and a hold in that state is published by `bin/fm-seat-respawner-service.sh status` as its own `holding:` verdict, which the alarm renders as a seat that was started and never finished starting rather than as a restart under way.
Once the bound is spent the episode is over for that condition and the respawner returns at the bound test on every later cycle while its process keeps beating, so `status` answers `gave-up:` for as long as `state/.seat-respawn-giveup` names the condition key `state/.seat-respawn-attempts` is still counting against; the episode itself is cleared only by a changed delivery status, a seat taking this home's lock, or the stay-down marker.
A stand-down declared while a turn is pending settles that turn instead of racing it: `state/.seat-stay-down` is read first, and it drops the pending record rather than letting the next cycle type into the pane.

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
  "Every sweep" now means every sweep, and that is a property of the sweep rather than of the shim's name.
  `bin/fm-watch.sh` globs `$STATE/*.check.sh` in collation order and used to **stop the sweep at the first check that printed a line**, having already touched the cadence anchor - so every check behind that one did not run, and then waited a full `FM_CHECK_INTERVAL` for its next chance.
  The order is the plain glob order, so adding any watch anywhere could silently delay any watch behind it, and the delay was invisible: a starved sweep is indistinguishable from a sweep on which nothing had anything to say.
  Measured on coditan-vessel over the 50.3 hours ending 2026-08-30 22:13Z, reading `state/sweep-tick.log` against the wake journal: of 401 sweeps, 67 ended early on a check sorting ahead of the alarm, and **60 of those 67 were consecutive** - 5.3 hours, 16:57Z to 22:16Z on 2026-08-30, during which the alarm would not have run once while reporting itself armed and healthy.
  That is the length of the outage the alarm exists to catch, so this was the detector failing in exactly the shape it was built to remove, one layer further out.
  The sweep now runs every due check, queues each speaking check's wake as it goes, and delivers once the sweep is over; the durable queue is what firstmate drains, so nothing is lost by delivering late.
  It costs no extra model turns - the whole queue is drained in one turn either way - and no extra worst-case sweep time, because a sweep on which nothing spoke already ran every check, which was 83% of the 401 measured.
  `state/seat-restart.check.sh` still sorts before `state/seat-vacancy.check.sh` so the restarter is converged before the seat is read, but that ordering is now only an ordering: neither check can displace the other, and the convergence check remains silent while the restarter is healthy.
  A home armed under the old ids is migrated by `--arm` itself: each side removes its own superseded shim and `.check-trust` by exact name once the replacement is registered, because a shim left behind is one the watcher keeps running.
  Converging compares the running respawner's own lock record against what this home would start now, so a keeper left on pre-update bytes is restarted and said out loud rather than counted as healthy because something is alive.
  On a home with no systemd that is the only way a self-update reaches the restarter at all.
  The comparison is split by owner, and deliberately: the watcher-hosted check compares the recorded manager and source version, which are composed identically wherever they are asked, while the recorded service `PATH` is compared only by the session-side `ensure_keeper`.
  That field is composed from the asking process's own `PATH` by design (`bin/fm-service-path-lib.sh`), so two managers running in different environments would each read the other's recorded value as drift and stop-and-start the keeper on every sweep and every session start.
  One owner for it, and it is the session - which is also the only place a poorly-reaching `PATH` can be diagnosed and repaired.
- `bin/fm-seat-respawner.sh` revives a **provably dead** watcher in return, through `fm_watcher_healthy`, this fleet's one owner of that question.
  It is deliberately narrow: never on a recorded-version or recorded-PATH mismatch, which are convergence decisions belonging to a session holding the fleet lock, and rate-limited so a watcher that cannot start is retried rather than hammered.
  Narrow means the `dead` classification specifically, not the unhealthy return: `fm_watcher_healthy` also reports `beacon-stale`, which is a watcher that is **alive** and identity-matched whose beacon aged out, and which a machine suspend necessarily produces because a frozen host cannot touch a beacon.
  Reviving that one would stop and restart a running watcher, and the sweep it interrupts is the one that carries the seat alarm.
  **A wedged-but-live watcher is therefore left alone here on purpose**, for a session holding the fleet lock to decide - the one deliberate non-action in this pair.

So either process surviving restores the other from the dead, and what is unrecoverable without a seat is the loss of **both** - or a watcher that is alive but wedged, which neither half will restart.

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

**The unbounded starvation this section used to record is closed, and the record of it lives in the supervision section above rather than here.**
The watcher no longer stops its check sweep at the first check that speaks, so no watch can delay the alarm by sorting ahead of it.
What remains is the settled two-sweep latency documented below, which is bounded at two sweeps.

**A watcher that is alive but wedged is deliberately never revived, and during an outage there is nobody to make the decision that non-action defers to.**
`fm_watcher_healthy` separates `dead` from `beacon-stale`, and only `dead` opens a revival, because restarting a live watcher stops it mid-sweep and the sweep it interrupts is the one carrying this alarm.
The bullet above leaves `beacon-stale` to a session holding the fleet lock - and a seat outage is precisely when no such session exists.
So a watcher stuck in that state stays stuck, with the respawner running beside it and correctly declining to touch it, and nothing reports the standoff.
Machine suspend necessarily produces `beacon-stale`, so this is a reachable state rather than a theoretical one.
The trade was taken knowingly: a false revival during a slow sweep kills the very sweep that pages the captain, which is worse than a wedged watcher nobody restarts.

**On a host with no GNU `timeout`, the captain is never paged, and nothing says so.**
`notify()` bounds the outward send as `printf ... | timeout "$SEND_TIMEOUT" "$SEND"`, with no `command -v` guard in front of it.
Where neither `timeout` nor `gtimeout` is on `PATH` the shell cannot find it, the send fails with `rc=127`, and a failed send is deliberately not counted as a notification - so `notified` is never set, the message is due again on the next sweep, and the same 127 repeats for as long as the absence lasts.
The captain gets nothing.
`--armed` stays silent throughout, because it keys off the mtime of `data/seat-alarm.state`, which every sweep rewrites; `--status` still answers `ABSENT` correctly, but only to a human who runs it, which is the shortcut this alarm exists to remove the need for.
On that class of home the primary deliverable of this change does not exist at all.
The printed line is not silent - it repeats once per sweep, through exactly the mechanism the broken-channel residual below describes - but it is the outward page that never lands.

Scope, measured rather than assumed: **this vessel is not affected**, `command -v timeout` answers `/usr/bin/timeout` here.
The exposure is hosts without GNU coreutils, which this fleet does support: `bin/fm-watch.sh` - the loop that hosts this very check - falls back `timeout` to `gtimeout` to a perl alarm, and `fm_path_mtime` in `bin/fm-wake-lib.sh` and the tmux probe in `bin/fm-backend.sh` both branch on `uname = Darwin`.
It is also pre-existing rather than introduced by review: the unguarded call was in this branch's first commit, `2595c24`. The bounded probe added later degrades honestly to `RESTARTER=unknown` and is not the call that matters.

The fix is known and was deliberately not taken, under a standing decision that nothing further changes in `bin/fm-seat-alarm.sh`: resolve `timeout`/`gtimeout` once into a variable and skip the wrapper when neither exists, exactly as `bin/fm-currency-round.sh` already does with `HAVE_TIMEOUT`.
Whoever picks this up does not have to rediscover it.

**A pane the respawner launched can be left running with nothing tracking it, and this does not report that either.**
The sequence is reachable and is the one this vessel already lived through.
The respawner launches a pane and records the first turn owed to it; that pane's composer never becomes affirmatively empty within the poll window, which a trust prompt or an update screen is enough to cause, so nothing is typed into it; the alarm pages the captain; a human then starts a seat by hand and it takes `state/.lock` - literally the 2026-08-27 sequence recorded at the top of this file.
The next cycle reads the home as held, settles the pending record and clears the episode, and the agent in the launched pane goes on running with nothing watching it.
The log is honest about what it established - it says a seat holds this home and that the recorded pane's turn is settled, and claims nothing about the pane - but nothing probes that window afterwards and nothing reports it.
Closing it would mean the respawner probing and judging a pane it no longer has a claim on, which is a larger decision than this change is making.

**A seat that holds the lock and cannot be reached is owned by neither half. This is a known hole, not an oversight.**
`bin/fm-session-start.sh` acquires the fleet lock before it publishes the endpoint, and that publish is `|| true`, so a seat that takes the lock and then fails to publish - a crash in that window, or a publish the session continues past - leaves the lock naming a live harness while the endpoint reads absent.
`fm_delivery_report` then prints `undeliverable:` for as long as it lasts; `one_cycle` refuses to launch for as long as it lasts, because presence reads `present` and a home with a first mate is not missing one; and the alarm stays silent for as long as it lasts, for exactly the same reason.
Wakes pile up undrained with nobody saying so - the 2026-08-27 shape reached through a seat that is there rather than through one that is gone.
Neither half acts on it and neither reports it.
It is milder than the outage this change was written for only because a present seat still reads its own session-start digest, which an absent one cannot.
Closing it is a design question rather than a patch - it needs either a sixth verdict or a named owner for "present but unreachable" - and adding a reachability reading to the respawner would recreate the second source of truth [seat-respawner.md](seat-respawner.md) deliberately refuses, so it is left to separate work rather than widened into this change.

**A state directory that has been DELETED mostly cannot be reported, because the alarm goes with it.**
The alarm runs only from `state/seat-vacancy.check.sh`, and `bin/fm-watch.sh` finds checks by globbing `$STATE/*.check.sh`, so when `state/` is removed the shim is removed too and nothing invokes the alarm at all.
Re-arming happens at session start on the vessel the alarm watches, which needs the seat that is by definition the thing missing.
A secondmate home is never armed at all - it inherits no outbound sender, so every send from one would fail, be uncounted, and reprint the transition line on every sweep - and `--arm` there retires any shim an earlier version installed instead of installing one.
The `unmeasured` reading for unreachable records is still right and still taken - what reaches it on a real vessel is a `state/` that exists and is not a usable directory, a symlink being the realistic form, whose target can still hold the shim.
Read the code and its test for that case, not for a deleted directory handled end to end.

**An alarm that cannot write its own records cannot pace itself, and says so rather than going quiet.**
The grace and the repeat cadence are both read out of `data/seat-alarm.state`, so a `data/` that cannot be written leaves neither available: every sweep would measure an age of zero, a nonzero grace would never open, and the instrument would be permanently silent on the one reading it exists to shout about - which is the failure of 2026-08-27 arriving through the alarm's own bookkeeping.
So when the memory cannot be kept the grace is not applied at all, the outward message drops the duration it cannot measure and says plainly that this vessel cannot remember having sent it, and the printed line is withheld until the memory returns rather than growing the durable wake queue once per sweep on a "first sweep of this episode" nothing can establish.
That reading is taken by writing, and by writing the whole of what the record write does - create, fill, rename over a target, remove - because a full or over-quota filesystem lets the create succeed and then refuses the content or the rename, and a probe that stopped at the create would call such a home persistable and hand the grace an age it can never measure.
The outward repeat is then per sweep, deliberately: no bound is available to an alarm with no memory, and silence is the worse of the two failures.

**A return is never announced, so the captain learns of one by the repeats stopping.**
This alarm reports that the vessel has lost its first mate and says nothing when it has one again; the return is written to `data/seat-alarm.log` and nowhere else.
It was announced once and the announcement was removed rather than repaired, because announcing once requires a memory the alarm cannot always keep: with `data/` unwritable the previous verdict never advances, so every later sweep re-entered the transition and re-sent, each message naming a longer absence than the last and every one of them describing an absence that had already ended.
Reporting a return with a length of time that was never true was judged worse than not reporting the return, so the trade is deliberate and this is the cost of it.

**While the captain's channel is refusing, the printed line repeats once per sweep instead of once per episode.**
The once-per-episode guard is derived from an empty `notified` field, and since a failed send is deliberately NOT counted as a notification - so the next sweep tries again rather than falling silent on a message nobody got - that field means "no send has succeeded yet" rather than "this is the first sweep of this episode".
So for as long as `bin/fm-tg-send.sh` keeps refusing - a revoked token, a sustained outage, repeated send-timeout expiry - every sweep recomputes the guard as true and re-emits both the transition line and its `entered verdict=` log line: measured, six sweeps at the 300s default produced five printed lines and five log entries for one absence.
`bin/fm-watch.sh` enqueues a durable wake for any non-empty check line and `fm_wake_append` does not deduplicate by kind or key, so that grows the queue once per sweep during exactly the window in which nobody is draining it, and an investigator reads one episode as five.
This is a known residual rather than an oversight: separating the two facts needs another field in the alarm's own record, and that record is one of the things this file has already had to move out of the directory it measures.

**The `gave-up:` verdict rests on a record three defects can make wrong, and all three are known and unfixed.**
The verdict answers "has this restarter stopped retrying" out of `state/.seat-respawn-giveup`, and the alarm renders it to the captain as a restart that has stopped and will not start another without him.
Three things about that record do not hold, and each is reachable rather than theoretical.

- **The record is written only when the outward finding could be filed.**
  `emit_giveup_finding` writes `state/.seat-respawn-giveup` inside the success branch of the `bin/fm-finding.sh emit`, and `one_cycle` swallows the failure, so an emit that fails leaves no record at all.
  `status_report` then falls through to `up:` and the captain is told an automatic restart is running and should bring the seat back on its own, for an episode that will never launch again.
  The door is one this file has already measured: a home whose `data/` cannot be written cannot take the finding either - and on exactly that home the alarm's memory-unpersistable path forces the grace pass and sends every sweep, so the wrong sentence is repeated once per sweep rather than once per repeat cadence.
  A keeper `PATH` without `jq` produces the same result, because the emit needs it.
- **The give-up condition is tested ahead of the held-pane condition.**
  An episode that is both holding a confirmed-open pane and past its bound therefore reports only `gave-up:`, and the open pane - the one fact the captain could act on - is dropped from the message he gets.
  That combination is reachable on the shipped defaults, not only on tuned ones: a held episode paces on the same backoff as a launching one, so the cycle that marks the record `held` past the deadline is also the cycle that meets the bound.
  The give-up finding does carry the pane, but findings are drained by a seat and there is no seat, so while the vessel is absent the alarm is the only outward channel and that sentence reaches nobody.
  Neither sentence is false; this is information loss rather than a false claim, which is why it is recorded here rather than treated as the overclaim class this area otherwise refuses.
- **The equality the verdict reads is not maintained by anything.**
  `gave_up_on_current_condition` takes `state/.seat-respawn-giveup` naming the same condition key as `state/.seat-respawn-attempts` to mean the episode being counted is spent, but `clear_episode` is the record's only remover and it fires on the stay-down marker, presence turning `present`, or a status that is no longer undeliverable - never on a condition key that merely changes.
  A dead seat's blocked reason is not stable, so an A-to-B-to-A change of that reason retires one episode and starts another under the first key: a fresh episode that is actively launching is then reported as having stopped retrying, and its own give-up is silenced, because the emit returns early on the record the first episode left.

The repair for the third of these was written and is not in this branch: it was reverted, because the attempt introduced a further defect of the same class - the cleanup it added decided whether the launch proceeded, so a cleanup that failed persisted a counted launch that was never made and the give-up would have reported launches that never happened.
Three successive attempts in this corner each produced another finding of this class, which is why it is documented here rather than patched a fourth time.
All three defects above are known and unfixed; whoever picks this up starts from them rather than rediscovering them.

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
5. the restored seat reads as `present` and **nothing is said on either channel** - no outward message and no printed line - with only `recovered from=absent` written to the alarm's own history.

A second case sets the stay-down marker and requires the same real kill to be left alone, and a third stands the keeper tier up on a private socket and requires it to converge without a seat.

The stand-in deliberately does NOT take the lock on startup.
One that did would hide the idle-seat failure, and the suite was checked against that: with `deliver_first_turn` disabled, the run fails at observation 4 rather than passing anyway.

```text
$ bash tests/fm-seat-absence-e2e.test.sh
ok - a deliberately killed seat is reported outward, comes back, and is given its first turn
ok - a deliberately stood-down seat is left down and not reported as missing
ok - the restarter is supervised without a service manager and without a seat
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
`up:` is the whole reading and not merely a live pid: it requires this home's own respawner lock, a beacon inside `FM_SEAT_RESPAWNER_GRACE`, and the process alive.
A respawner whose process is alive but has stopped cycling answers `stalled:` instead, and the alarm turns that into "whether anything is trying to bring it back could not be read" rather than into an assurance - so `stalled:` is a failed arm for this runbook's purposes, not a pass.
A respawner that is cycling normally but is holding a first turn that never landed answers `holding:`, which the alarm renders as waiting on a seat that never finished starting and will not start another by itself; that is also not a pass for this runbook.
A respawner that has spent its attempt bound for the absence standing now answers `gave-up:`, which the alarm renders as a restart that has stopped retrying and will not start another without the captain; that is not a pass either.
Then, and only with the captain watching, the real end-to-end: note the seat's recorded pid from `bin/fm-lock.sh status`, close the seat, and confirm a message arrives on the captain's channel and that `bin/fm-lock.sh status` afterwards names a **different** live pid.

**Expect that message on the SECOND watcher sweep, not the first.**
`SINCE` is reset on the verdict transition, so `AGE` is 0 on the sweep that first observes the absence: that sweep records the state and sends nothing, and the message goes out on the next one.
The page therefore lands between one and two sweep intervals after the seat actually died - 5 to 10 minutes at the `FM_CHECK_INTERVAL` default of 300.
Worth knowing before anyone tunes it: any `FM_SEAT_ALARM_GRACE` below the sweep interval is indistinguishable from any other, so the default `60` and a value of `299` behave identically, and only `0` pages on the observing sweep.
A message on the second sweep is the alarm working, not the alarm being late.
`bin/fm-seat-stay-down.sh down` cancels the restart first if the seat is being closed on purpose.
