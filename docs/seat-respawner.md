# Seat respawner

This is the mechanism that brings one home primary firstmate seat back after the agent process is gone while the machine and background services stay up.
It is intentionally home-scoped and does not scan for other seats.

## Design

`bin/fm-seat-respawner.sh` runs as a per-home `systemd --user` unit through `systemd/fm-seat-respawner@.service` where a systemd user manager works, and as a detached home-scoped tmux keeper where one does not, exactly as the watcher and the delivery listener already do.
The unit instance is keyed by `systemd-escape --path "$FM_HOME"`, matching the watcher and delivery service shape.
Bootstrap reports `RESPAWNER_UNIT:` when the unit is missing, disabled, stale, or unavailable, and `bin/fm-bootstrap.sh install seat-respawner-unit` is the only install path on the systemd tier; the keeper tier needs no install.

Which tier supervises the keeper, and why it is not a seat session start, is owned by [seat-absence.md](seat-absence.md) along with the detection half.
Read it before changing anything here: this component restarts a seat and deliberately does not report that one is missing, and it does not consider a restart finished until a seat holds the session lock.

The respawner does not probe panes itself.
It reads `bin/fm-delivery-service.sh status`, whose verdicts are owned by [wake-delivery.md](wake-delivery.md).
An `undeliverable:` verdict is what opens a relaunch, which keeps the reachability reading in the existing delivery component instead of creating a second source of truth for it.

**Revised on new evidence: an `undeliverable:` verdict is no longer sufficient on its own.**
A seat that is merely mid-turn produces exactly that verdict - the delivery listener's own busy-pane branch blocks the submit and `fm_delivery_report` therefore prints `undeliverable:` - so relaunching on that verdict alone opened a second agent window beside a first mate that was working, once per retry attempt.
The respawner therefore asks a PRESENCE question first, and only an absence opens a launch.
That is not a second reachability reading, so the rationale above survives: there is still exactly one owner of "can the seat be reached" and exactly one of "is a seat here".

**The presence reading is one shared verdict, not a local predicate.**
`bin/fm-seat-presence-lib.sh` classifies the session-lock record `present` / `absent` / `unmeasured`, and both `bin/fm-seat-alarm.sh` and this script consume it, so the two halves share the DECISION and not merely the parse.
That correction replaced a boolean `seat_holds_lock` here, which answered "no seat" to every reading that was not a confident yes - including a record it could not read and a holder in a pid table it cannot see into, both of which the alarm calls `unmeasured` and refuses to report as an absence.
Four review findings on this branch were that one conversion arriving through different doors, so the conversion was removed rather than guarded door by door.
`present` refuses the launch and clears the retry episode; `unmeasured` refuses it and leaves the episode untouched, silently, because reporting an unmeasured home is the alarm's and it does so on its own uncapped cadence; only `absent` reaches the delivery verdict at all.
`standing-down` and `unattended` stay with the alarm: they are read from the stay-down marker and the published endpoint rather than from the lock, and this script reads the marker itself.

Deliberate shutdown is declared, not inferred.
`bin/fm-seat-stay-down.sh down` writes `state/.seat-stay-down`, and `bin/fm-seat-stay-down.sh up` clears it.
While that marker exists, the respawner clears its current retry episode and leaves the seat down.

The fresh launch command is configured through `config/seat-launch-command`, or `FM_SEAT_LAUNCH_COMMAND` for tests and specialized service environments.
[`docs/configuration.md`](configuration.md#seat-launch-command-configseat-launch-command--fm_seat_launch_command) owns that file's format and the fresh-start restriction.

## Trade

A seat whose pane or window is closed by hand without first setting the stay-down marker will come back.
That is deliberate.
A mistaken restart is recoverable by running `bin/fm-seat-stay-down.sh down`, while an unnoticed dead seat with queued work is the measured failure this closes.

## Loop Bound

Respawns are bounded by `FM_SEAT_RESPAWNER_MAX_ATTEMPTS`, default `5`.
Attempts back off from `FM_SEAT_RESPAWNER_BACKOFF`, default `30` seconds, up to `FM_SEAT_RESPAWNER_MAX_BACKOFF`, default `900` seconds.
When the attempt bound is reached for the same delivery condition, the respawner stops retrying that episode and emits a high-severity evidence record through `bin/fm-finding.sh`.

## Limits

`tests/fm-seat-respawner.test.sh` covers the portable properties: honoring the stay-down marker, reporting the give-up path, refusing to relaunch beside a live first mate or on a lock it could not read, holding the next launch while a first turn is owed, still reaching the retry bound and giving up while held, reporting a held first turn as `holding:` rather than `up:`, composing no `PATH` for the fresh seat, refusing a resume-style launch command, and the keeper convergence's place in the watcher's sweep.
The real tmux effect is proved end to end by `tests/fm-seat-absence-e2e.test.sh`, on a throwaway `FM_HOME` with a private tmux socket, a stand-in delivery status that first reports `undeliverable:`, a harmless configured launch command, and a stand-in seat that is really killed; [seat-absence.md](seat-absence.md) owns what that run establishes and what it still cannot.
Do not test this by killing the live firstmate seat.

The fresh seat is given one typed first turn, because a launched agent otherwise sits idle and publishes nothing; [seat-absence.md](seat-absence.md) owns that requirement and its measurement.

This does not replace the watcher or delivery listener.
It also does not repair a missing delivery listener, a broken findings surface, a missing launch command, or a non-tmux endpoint.
Those failures are logged under `state/.seat-respawner.log` and remain operator-visible rather than being guessed past.
