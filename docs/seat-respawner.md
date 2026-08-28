# Seat respawner

This is the mechanism that brings one home primary firstmate seat back after the agent process is gone while the machine and background services stay up.
It is intentionally home-scoped and does not scan for other seats.

## Design

`bin/fm-seat-respawner.sh` runs as a per-home `systemd --user` unit through `systemd/fm-seat-respawner@.service`.
The unit instance is keyed by `systemd-escape --path "$FM_HOME"`, matching the watcher and delivery service shape.
Bootstrap reports `RESPAWNER_UNIT:` when the unit is missing, disabled, stale, or unavailable, and `bin/fm-bootstrap.sh install seat-respawner-unit` is the only install path.

The respawner does not probe panes itself.
It reads `bin/fm-delivery-service.sh status`, whose verdicts are owned by [wake-delivery.md](wake-delivery.md).
Only an `undeliverable:` verdict is a relaunch condition.
That keeps the reachability reading in the existing delivery component instead of creating a second source of truth.

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

The portable tests cover honoring the stay-down marker and reporting the give-up path.
The real tmux effect proof should use a throwaway `FM_HOME`, a private tmux socket, a fake delivery-status command that first reports `undeliverable:`, and a harmless configured launch command.
Do not test this by killing the live firstmate seat.

This does not replace the watcher or delivery listener.
It also does not repair a missing delivery listener, a broken findings surface, a missing launch command, or a non-tmux endpoint.
Those failures are logged under `state/.seat-respawner.log` and remain operator-visible rather than being guessed past.

## Container stopgap: `bin/fm-seat-keeper.sh`

The respawner above needs a per-user service manager to run it.
A home inside a container often has none: `systemctl --user` reports `offline`, so nothing survives to notice a dead seat, and a restart comes up with a healthy-looking terminal and no seat at all.
`bin/fm-seat-keeper.sh` is the stopgap for exactly that home, hosted in a terminal instead of a unit.

It reads the same source of truth: `bin/fm-delivery-service.sh status`, whose verdicts are owned by [wake-delivery.md](wake-delivery.md).
It never uses a socket pathname or a process-name match as its seat-death detector, because a name match has already reported another account's unrelated process as this fleet's wedged run.
Two readings of the same guarded condition are required before it acts, and an unrecognised verdict resets that evidence and is logged rather than guessed past.
A `down:` verdict alone is not seat death: it becomes one only when an independent terminal reading also says the target session is absent, because a listener restart looks identical from the verdict alone.

Two operating constraints bind wherever it is started.
The keeper must run on a terminal socket separate from the one it watches, because a keeper sharing that socket dies with the thing it revives.
It restores a session and its windows on a target server that survived, and it deliberately refuses to create a new target server: total server loss is not what this stopgap covers.

Its arguments and environment are owned by the script's own header.
`tests/fm-seat-keeper.test.sh` covers the detector: that a named dead-seat verdict restores the seat, that one reading is not enough, that a healthy verdict and a listener restart both leave the seat alone, and that an unrecognised verdict is refused and logged.

This is a stopgap, not a replacement for the respawner.
A home that gains a working per-user service manager should install the unit above and stop hand-starting the keeper.
