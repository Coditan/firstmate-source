# The pooled-worktree ownership guard

Evidence record for `bin/fm-slot-lib.sh`, `bin/fm-slot-guard.sh`, and the refusal they give `bin/fm-teardown.sh`.
Everything below was measured on 2026-08-17 with treehouse v2.1.0 on Linux 6.8.0-137-generic; the exact commands and their exact output are reproduced so a later reader can re-run them rather than trust this page.

## The incident

`fm-bosun-deploy` merged and was torn down.
Its `state/<id>.meta` recorded the pooled slot `.treehouse/firstmate-fork-c22c88/4/firstmate-fork`.
By then that slot had been re-handed to `fm-durable-captain-decisions`, which was live and mid-task.
Teardown returned it, and the live worker's window died; its state read `unknown / endpoint-unreadable / backend target gone`.

The work survived by timing alone.
That worker happened to be just past a commit, so `0788c06` was already in the shared object store and was recoverable.
Between edits it would have gone with no record it ever existed, and the task would simply have read `unknown` - indistinguishable from a window that died on its own.

## Which of two bugs this is

The two candidate causes have different fixes, so this was settled by measurement before anything was designed.

**It is a stale record, not a pool that hands one slot to two tasks by design.**

The pool's own state file records exactly one owner per slot:

```
$ cat ~/.treehouse/firstmate-fork-c22c88/treehouse-state.json
    { "name": "4", "path": ".../4/firstmate-fork",
      "owner_pid": 672003, "owner_started_at": 1786978623090 },
    { "name": "7", "path": ".../7/firstmate-fork" }        <- no owner: available
```

The re-handing was then reproduced end to end in a sandbox pool.
Task A acquires slot 1; A's window dies; task B spawns and is given slot 1, while A's meta still records it:

```
TASK A recorded worktree= .../sandbox-01bc48/1/sandbox
--- A's worker window closes; firstmate has NOT torn A down yet ---
1     available    .../sandbox-01bc48/1/sandbox
--- TASK B spawns: treehouse get ---
1     in-use       .../sandbox-01bc48/1/sandbox
                   bash (872030)
```

So the two owners of a slot are of different kinds, and they disagree in exactly one direction.
The pool's owner is a **process**: `treehouse status` calls a slot in-use only while something is alive inside it, and frees it the moment that dies.
firstmate's owner is a **task**: the meta records `worktree=` until teardown, which can be much later.
A task's window dying therefore converts a correct record into a stale one silently, with nothing anywhere comparing the two.

## What was missing was a question, not a refusal

Teardown already refuses on unlanded work, and had refused for this same task minutes earlier, correctly.
`validate_worktree_teardown_safety` inspects `$WT` for uncommitted changes, for commits on no remote, and for whether the branch landed.

Every one of those is scoped to the task teardown was told about.
None is scoped to the resource it is about to touch.
Nothing asked who else was standing in the slot, so the checks that did run were answering a question about the wrong task's work.

The damage is confirmed by reproducing the return against a live occupant:

```
--- firstmate tears down TASK A, using A's stale worktree= record ---
🌳 Terminated lingering processes: bash (872030)
🌳 Worktree returned to pool.
--- did B survive? ---
B pid 872030 -> GONE - worker killed
B uncommitted file -> DESTROYED
B commit reachable -> 1
```

That is the incident's damage profile exactly: the worker dies, uncommitted work is destroyed, and committed work survives only because it is already in the shared object store.

## What the pool tool can and cannot enforce

The captain's constraint was to prefer a guard that holds independently of who is calling, rather than a check the caller must remember to run, because firstmate was the caller that got this wrong.
How far that is achievable is a property of the pool tool, so it was measured rather than assumed.

**A lease durably reserves a slot against reallocation.** A later `get` skipped the leased slot and took the next one:

```
$ treehouse get --lease --lease-holder "fm:taskB"
1     leased       .../1/sandbox  (held by fm:taskB)
--- another task spawns (get) ---
1     leased       .../1/sandbox  (held by fm:taskB)
2     in-use       .../2/sandbox
```

**A lease does not survive a return, and no return mode is non-destructive.**
`treehouse return --force` released a lease held by a different holder without complaint, and plain `treehouse return` on a live slot reported `Terminated lingering processes: bash (903999)`.
There is therefore nothing for a watcher to interpose on: no daemon can veto a return another process has already issued.

**A slot already in use cannot be leased retroactively.**
`treehouse get --lease` allocates a free slot, and the command set (`destroy`, `enter`, `get`, `init`, `prune`, `return`, `status`, `update`) offers no way to place a lease on an occupied one.
So a watcher cannot convert the pool's process-based hold into a durable lifecycle-based hold for work already running.

**But the tool will refuse a return conditionally, and it fails closed.**
`treehouse return --if-lease-holder <h>` refuses in both directions, exits 1, and changes nothing:

```
$ treehouse return --force --if-lease-holder "fm:A" .../1/sandbox    # leased to fm:B
failed to return worktree: lease precondition failed: lease holder does not match worktree .../1/sandbox
rc=1     lease still held: 1

$ treehouse return --force --if-lease-holder "fm:A" .../2/sandbox    # not leased at all
failed to return worktree: lease precondition failed: worktree .../2/sandbox is not leased
rc=1     (the live process in slot 2 survived)
```

The `is not leased` case is why this flag cannot simply be passed unconditionally: on today's unleased task slots it would refuse every ordinary teardown.

## What was built, and where each part binds

This change is containment for the measured stale-holder incident, not an unconditional ownership invariant.
It detects and refuses a different holder that is already represented by a lease or a live task record when an ownership decision is taken.
On an unleased slot, a holder that arrives after the final decision but before the return is not detected because those are separate operations and the return is unconditional.

**`bin/fm-slot-lib.sh`** states the missing question once, so every caller asks it the same way.
It answers from two independent witnesses, because either alone has a blind spot: the pool's own lease, and every `state/<id>.meta` that names the path filtered to tasks whose window is still alive.
A conflict from either is a real conflict, so the two are unioned rather than required to agree.
A task whose liveness cannot be read counts as live, because the cost of guessing wrong is destroying a running worker's work while the cost of a false hold is a refusal someone can inspect.
The same fail-safe asymmetry applies at the treehouse return boundary: a readable pool with no lease permits an otherwise uncontested return, while an unreadable pool refuses because it cannot distinguish that ordinary state from a holder outside the local home's metadata.

### Backend target-existence caller audit

The shared target-existence probe returns 0 for present, 1 for confidently absent, and 2 when the backend could not be asked; an unknown backend returns 2 because no adapter can establish absence.

- `bin/fm-delivery.sh` defers delivery on unreadable just as it does on absent, but records that verification failed rather than claiming the pane is gone.
- `bin/fm-send.sh` refuses an explicit target on unreadable and reports that the backend could not verify it, because sending without a verified endpoint is unsafe.
- `bin/fm-slot-lib.sh` treats unreadable as live, because a false absence can destroy another task's worktree.
- `bin/fm-supervise-daemon.sh` injection defers on unreadable, startup reports unreadable distinctly, and the run loop preserves queued work while retrying an unreadable target.
- `bin/fm-fleet-snapshot.sh` leaves `endpoint_exists` null on unreadable, because false is reserved for confident absence.
- `bin/fm-crew-state.sh` preserves its existing unreadable-pane presentation by treating unreadable as not readable without claiming confident absence.
- `bin/fm-session-start.sh` reports an unreadable endpoint as unknown rather than dead, because recovery decisions must not be based on a transport failure.

**`bin/fm-slot-guard.sh`** is the watcher half, armed at bootstrap like the memory alarm and the currency round.
It sweeps this home's recorded slots on the ordinary watcher cadence and, when a slot is claimed by a task other than the live one standing in it, writes a durable `state/<id>.slot-disputed` marker and wakes firstmate once.
Once written, the marker preserves that measured dispute before teardown runs and survives a caller that never asks.

**`bin/fm-teardown.sh`** asks the complete ownership question at one early gate as soon as each recorded pool-backed target is known, before any cleanup path can mutate or descend into it.
Every later return, lock mutation, or child cleanup rechecks ownership immediately before acting, using the owning home's state directory for nested secondmate cleanup, translating the pool's own lease-precondition failures into terminal ownership refusals, propagating refusal through every parent cleanup without deleting its records, relying on the return's reset to remove hooks, and performing best-effort branch-ref cleanup through the project repository without touching the released worktree path.
The pool question binds only to treehouse-backed paths; Orca and other non-pool cleanup retain their backend-specific safety checks and never refuse because treehouse status is unavailable.
When the slot is leased to the task being torn down it also passes `--if-lease-holder`, so for those slots the refusal is enforced by the pool itself rather than by firstmate's memory.

The refusal holds under `--force` deliberately.
The captain's authority to discard work is authority over *this* task's work; it is never authority to destroy a third party's work he was never told was there.
`FM_TEARDOWN_SLOT_OVERRIDE=<holder>` is the deliberate escape hatch, and it is harder to give than `--force` precisely because it cannot be given without first learning who is being displaced.

## Where a watcher genuinely cannot hold the property, and why

Stated plainly rather than papered over, because a guard whose limits are not written down gets trusted past them.

- **A return issued outside firstmate cannot be stopped.**
  `treehouse return` honours no lease by default and is unconditionally destructive, so a human or another tool can still destroy any slot by path.
  Nothing in this design changes that.
- **An unleased slot has a check-to-return race.**
  After the fresh lease and record witnesses report no holder, another task can acquire the slot before `treehouse return` runs, and empty `lease_args` makes that return unconditional.
  No watcher can close this race because the ownership decision and return are two operations and treehouse offers no atomic check-and-return.
  Leasing at acquisition makes `lease_args` non-empty and moves the final refusal into the pool itself.
- **Live processes can be invisible to both witnesses.**
  Measured on 2026-08-17, pool slot `firstmate-fork-c22c88/1` still held four processes aged 2h20m to 2h55m, one idle Claude agent and three orphaned shells, with working directories inside that worktree after its tmux window was gone and the owning task's record had moved to slot 2.
  This change judges recorded-task liveness by whether its window exists, so those processes had neither a live recorded window nor a task record naming their slot.
  The lease witness was also blind because the slot was unleased.
  Refusing on treehouse's in-use process reading would not solve this safely because that reading cannot distinguish the torn-down task's own lingering processes, which teardown legitimately terminates and normally encounters, from a third party's processes, so it would refuse ordinary teardown.
- **There is a window the watcher does not cover.**
  A dispute marker exists only after a watcher sweep has observed the conflicting records.
  Between a window dying and the next sweep, a teardown still depends on the live check in `teardown_treehouse_return` rather than on a durable marker.

The single follow-up that closes both the check-to-return race and the unrecorded-process blind spot is **leasing every task worktree at acquisition**, with `--lease-holder fm:<id>`, exactly as `bin/fm-home-seed.sh` has always done for secondmate homes.
A lease is durable, is not tied to a window or task record, reserves the slot for the task lifecycle, and makes `--if-lease-holder` hand the final refusal to the pool itself.
It is deliberately not in this change: `bin/fm-spawn.sh` acquires by sending `treehouse get` into the worker's pane across four backends and then reading the pane's cwd back, so moving to a firstmate-side lease changes the spawn path for every backend and adds a durable lease that must be released on every spawn failure path.
That is a spawn-safety change and deserves its own reproduction and its own tests, rather than riding along with a teardown fix.

## What a worker still loses if it is killed between edits

Unchanged by this guard, and worth stating because the guard is necessary rather than sufficient.

If a worker is killed between edits, everything not committed is gone, silently.
`treehouse return` resets the worktree, so uncommitted work leaves no trace; the task's own record would read `unknown`, which is indistinguishable from a window that died on its own.
Committed work survives because it is in the repository's shared object store, which is why `0788c06` was recoverable - that was the worker's commit timing, not a property of the system.

What this guard changes is that the measured stale-holder condition is named and refused when its holder is visible at the ownership decision, instead of being discovered afterwards, or never.
That is containment of the incident sequence, not a guarantee against a holder arriving during the unleased check-to-return race or processes invisible to both witnesses.
It does not make a killed worker's uncommitted work recoverable, and nothing here should be read as if it did.

## Tests

`tests/fm-slot-guard.test.sh` holds the reproduction and the fix, including the original stale-slot sequence and the teardown paths that can mutate pooled worktrees and homes.
Case (a) is the incident sequence - a stale record plus a different live task in the slot - and it fails against the pre-fix behaviour and passes with the guard in place, which is the check that the test is testing the fix rather than agreeing with it.
