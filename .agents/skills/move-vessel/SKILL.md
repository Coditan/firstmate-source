---
name: move-vessel
description: >-
  Move a Firstmate vessel into a container or between hosts from the moving vessel's side.
  Use when a vessel move is ordered, before releasing the vessel for cutover, and after cutover to verify that its seat, workers, supervision, credentials, and message path moved with it.
  Do not use it as the receiving side's container-build or host-deployment runbook.
user-invocable: true
metadata:
  internal: true
---

# Move a vessel

Own the moving vessel's half of a cutover.
Load this skill as soon as a move is ordered, while the original vessel is still running, and keep it loaded through release and post-cutover verification.
The destination's build and deployment runbook owns how the receiving side creates the environment.
This skill owns what the moving vessel preserves, what it states before cutover, and what it verifies after the move.

Do not copy host names, ports, account ids, installed version numbers, or other facts that will rot into this procedure.
Read those from the current vessel and the landed destination definition at move time.

## Land work before parking anything

**Land every in-flight change on a named branch before parking its worker or stopping its process.**
Stopping first is the ordering error that loses work, because landing cannot be reconstructed after the only process that knows about the work is gone.

Inventory every active and paused lane against all three places its work can exist:

- Inspect the working copy.
- Inspect the branch and its remote landing state.
- Inspect the validation service's own repository and run state.

A parked validation run's commits can exist only in the validation service's bare repository.
They can be invisible to every ordinary Git command, while the project working tree remains clean and gives no hint that the commits exist.
A cutover over that state loses real work without an error, refusal, or dirty-tree warning.

Use the validation service's own current-run inventory rather than inferring safety from a clean branch or quiet worker.
**Unmeasured is not clear.**
If the inventory tool returns no answer rather than an explicit empty result, the reading is `UNMEASURED`.
**A release must not be signed on an instrument that did not answer.**

Land or rescue every discovered change onto a named branch, verify the landing from a vantage that does not already hold the objects when a remote claim matters, and only then park the lane.
Do not remove the original home or use a project-removal tool as part of a move.

## Establish the cutover basis

Require the destination to deploy from the landed definition, never from a worker's current checkout.
A definition and a deployed working copy can disagree, and the deployed side wins silently unless the landed revision is the basis of the cutover.

Do not snapshot the moving seat's installed tool versions into an image or destination manifest.
Resolve pins from upstream released versions and record why each pin is chosen.
An installed version is an observation about the old seat, not a reason the next seat should inherit it.

Carry the whole vessel across the boundary:

- Carry the primary seat and its durable home.
- Carry every worker pane and the state needed to reconcile it.
- Carry the vessel's watcher and delivery listener.
- Carry vessel-owned validation state needed to recover active or parked runs.

Never move, stop, or restart a validation service shared by other homes.
Give the destination its own instance and carry only the moving vessel's required history from a named source.

Supervision must become the destination's own and live inside the same operational boundary as the seat and worker panes.
A seat inside a container with its watcher or delivery listener outside is a vessel nobody can wake.
Its silence is indistinguishable from a healthy quiet seat, so process presence outside the boundary is not a substitute.

## Supply effect checks, not plausible commands

Give the receiving runbook effect checks that prove the moving vessel's actual dependencies without changing external state.
For each check, state both what a zero exit proves and what it does not prove.
At minimum, cover the applicable current equivalents of these effects:

- Prove that the forge identity can perform a real authenticated read.
- Prove that the exact repository remote used to land work can perform an authenticated read.
- Prove that the destination has the network reach the vessel requires.
- Prove that the captain-message credential can make a read-only identity call without sending a message.
- Prove that the delivery listener can report its own state, followed after cutover by a wake that becomes a real turn.

Keep credentials out of output, logs, and `argv`.
When an API places a token in the URL path, pass the URL to `curl` through stdin with `--config -` and disable tracing inside the consuming subshell.
Do not simplify that check into a token-bearing command-line argument.

A listener report proves the listener answers and names its state.
It does not prove that a delivered wake becomes a model turn, so the post-cutover wake is a separate gate.

## Release once, as a fact

Release only after every lane is landed on a named branch, the parked-run inventory gave an explicit answer, and the workers are parked.

Send one Bridge envelope stating the facts on this side:

- State that the in-flight work is landed.
- State that the parked-run inventory is measured and clear.
- State that the workers are parked.
- State that the original home remains intact.

State these as facts, not as permission for the receiving vessel.
The receiving vessel already has the move authority; it lacks knowledge of the moving side's state.
One envelope is the release, with no polling and no second confirmation.
If the release is not ready, send the measured reason rather than silence or a premature release.

## Verify from inside after cutover

Enter the destination as the moved vessel and inspect the running thing rather than accepting an outside report or substituting values from the definition.
Read the running instance identity, build identity, home, seat, worker panes, watcher, delivery listener, and validation state from inside the destination.

Prove the message path in both directions.
For the read half, fetch a Bridge envelope already known to be present, because an unreachable or stale mailbox can read as empty rather than broken.
For the send half, publish an envelope and confirm it on the remote default branch, because an envelope id proves composition rather than delivery.
Deliver a wake from outside the destination and verify that it becomes a real turn inside it.

Treat any missing reading as unmeasured, never as a pass.
The move is complete only after the vessel has run inside the destination and the checks above have been observed from there.

## The way back is the original

Keep the source home untouched through the move.
The original is the way back, not a separate rollback procedure, provided nothing at the source is deleted.

The original becomes a snapshot when the move completes while the destination begins doing new work immediately.
The rollback window therefore narrows on its own from the moment the move completes.
State that timing fact when choosing whether to return, because a later return discards everything the destination did after the snapshot.
