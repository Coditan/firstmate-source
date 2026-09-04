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
The rules of that episode, the attempt record, the doubling backoff, and the single give-up finding, live once in `bin/fm-retry-episode-lib.sh` and are sourced by both supervisors, so neither can drift from the other.
Where each episode's record lives, and how long it outlives its process, stays with the supervisor that owns it.

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
That rule is enforced at startup rather than only asserted: when `$TMUX` says the keeper was hand-started on the terminal server hosting the target socket it refuses to run, and it names both the mistake and the fix.
A keeper started outside a terminal server, or on any other one, is unaffected by that refusal.
It restores a session and its windows on a target server that survived, and it deliberately refuses to create a new target server: total server loss is not what this stopgap covers.
Restoring is otherwise additive, with one exception an operator can lose work to: on the composer-unknown verdict the keeper kills the existing window named `firstmate` before relaunching it, because that verdict says the seat's own composer row is a bare prompt rather than an agent.
It kills that window only when an independent reading of the pane confirms a dead shell, `#{pane_dead}` or a shell as `#{pane_current_command}`, and refuses otherwise, because the same verdict is also emitted for a pane that could not be read, and a live agent must not be killed on an inconclusive reading.
The refusal is logged once per onset, naming what was read, and the delivery verdict remains the seat-death detector: that reading only corroborates the kill and never triggers one.

The keeper obeys the same declarations the respawner obeys, because a home running it as the stand-in for the unit must not lose them.
While `state/.seat-stay-down` exists it clears its retry episode and leaves the seat down.
Restores are bounded the same way too: `FM_SEAT_KEEPER_MAX_ATTEMPTS` attempts for one delivery condition, backing off from `FM_SEAT_KEEPER_RETRY_SEC` up to `FM_SEAT_KEEPER_MAX_BACKOFF`, then a give-up marker and one high-severity evidence record through `bin/fm-finding.sh` instead of relaunching a seat that can never come up forever.
The condition a restore episode counts is the delivery verdict's stable key, owned by `bin/fm-delivery-lib.sh` and shared with the respawner, so a wake arriving between two readings cannot look like a different condition.
One keeper runs per state directory: a second hand-started keeper finds the live one's identity-matched lock record and refuses rather than racing it.
The state directory it is given must be the state directory of the home it is given, and it refuses to start otherwise; the script header owns that rule and the reason for it.
Restarting the keeper by hand lifts an exhausted bound: at startup it clears a give-up episode left in its state directory and logs which condition it lifted, because a hand-start is an operator deciding to try again.
What makes an episode exhausted is its attempt count reaching the bound, not the give-up marker existing, so an episode whose finding could never be filed because the findings surface was unreachable is lifted too, and its log line names it exhausted but unfiled so the operator learns of a give-up that never reached him.
An episode still below the bound is mid-episode and survives the hand-start with its count and its backoff spacing intact, because lifting it would hand an unattended loop a fresh set of attempts every time the keeper is started.
The respawner does not lift its own bound that way, because a unit restarting itself is not that decision.

Two limits of this stopgap are known, deliberate, and not fixed here.
The keeper does not read `config/seat-launch-command`, and its default relaunch command starts `claude`.
A home whose primary seat is Codex, OpenCode, Pi, Grok, or any other tool must set `FM_SEAT_KEEPER_SEAT_COMMAND`, or the keeper brings back the wrong seat.
The keeper also assumes the target terminal server uses `base-index 0`.
On a server configured with `base-index 1` the created session's only window lands where the keeper expects the firstmate window, so it logs `launch refused: <session>:1 exists as 'bash', not firstmate` and does not restore the seat.
That refusal is a failed restore like any other, so the attempt bound above ends it: an operator sees at most `FM_SEAT_KEEPER_MAX_ATTEMPTS` of those lines, spaced by the doubling backoff, five over roughly seven and a half minutes at the defaults, and then a give-up marker and one high-severity evidence record through `bin/fm-finding.sh`.
The log goes quiet after that until the keeper is hand-started again, so this condition reaches an operator as a finding rather than as a line repeating forever.

Its arguments and environment are owned by the script's own header, which states the launch-command limit again where someone reading the script meets it and points here for the base-index one.
`tests/fm-seat-keeper.test.sh` covers the behaviour: that a named dead-seat verdict restores the seat, that one reading is not enough, that a wake count changing between two readings is still one condition, that a healthy verdict and a listener restart both leave the seat alone, that an unrecognised verdict is refused and logged, that a declared stay-down is honoured and released, that the attempt bound gives up with a finding, that a state directory which is not the home's own is refused, and that a second keeper refuses to run.
It covers the rest of this account too: that the delivery verdict is read for the home the keeper was given rather than the environment's, that a keeper started on the target socket's own server is refused while any other start is untouched, that the composer-unknown verdict kills and relaunches over a dead shell but is refused over a live pane and over a pane that could not be read, that the refusal is logged again on a second onset after a healthy reading between them, that a hand-start lifts an exhausted bound and an exhausted-but-unfiled one while carrying a mid-episode record, and that a dead keeper's lock is taken over rather than refusing every later keeper.

This is a stopgap, not a replacement for the respawner.
A home that gains a working per-user service manager should install the unit above and stop hand-starting the keeper.
