# Codex status signalling

Why Codex direct reports receive a per-task writable signal directory, how `state/<id>.status` stays the public channel, and what evidence led to the split.

This is a verification and incident record for the 2026-08-18 worker-signalling gap.
The mechanism here is separate from the no-mistakes socket network grant recorded in [`docs/codex-sandbox-network.md`](codex-sandbox-network.md).
The same per-task directory later became the home of the completion-gate attestation, for the same reason and with the same evidence discipline; [`docs/codex-completion-gate.md`](codex-completion-gate.md) owns that record.

## Observed spread

The live Codex status attempts with the same launch shape split across approval outcomes.
Some workers wrote status successfully.
Some workers were refused when writing to the same firstmate home's `state/<id>.status`, across two project clones and both medium and xhigh effort.
One refusal cited `AGENTS.md` state-machinery ownership text despite the brief requiring the terminal status append.
Another refusal described the same write as an external write.
That variation is evidence that the approval reviewer is making per-run model judgements, not that a fixed policy bit deterministically permits or denies every worker.

The refused set included a worker in this firstmate repository, this task's own xhigh first append, and a worker in the separate `hlr-reporting` project clone.
That rules out a cause tied only to firstmate-repo worktrees or to effort level.

The strongest discriminator arrived in the same repository, same model, same medium effort tier, same file shape, and same authorization level.
One worker's `blocked:` append was approved because the reviewer treated the designated task status file as a bounded local workflow update required by the task process.
Another worker's `done:` append was denied because the reviewer treated `state/<id>.status` as state machinery that only the owning script may mutate.
That removes the environmental variables and leaves the reviewer's own judgement as the unstable layer.
It also means the status channel can be least reliable for terminal lines, not only for optional progress.

## The ordinary external append fails before review

`codex-cli 0.145.0` under `workspace-write` cannot append directly to the firstmate home state file from a task worktree unless that state path is inside a writable root.

The representative probe was:

```sh
codex sandbox -c 'sandbox_mode="workspace-write"' -- \
  bash -lc 'printf "probe\n" >> "$1"' bash /home/crew/firstmate/state/.probe-no-root.status
```

It returned:

```text
/bin/bash: line 1: /home/crew/firstmate/state/.probe-no-root.status: Read-only file system
```

Adding only `FM_HOME=/home/crew/firstmate` did not change that result.
Granting a writable root for the exact file path also did not change that result in the measured `codex sandbox` probe.
Granting a writable directory root and writing a file inside that directory did work.

The smallest reliable filesystem grant was therefore a directory, not the status file itself.

## The approval fallback is not reliable

Before this change, a worker could try to recover from the sandbox refusal by requesting an escalated external append.
That worked for some live workers and was denied for others.
The denial rationale in one live worker was:

```text
Although the brief explicitly requires a terminal done status, directly appending to state/<id>.status violates AGENTS.md's rule that this machinery may only be mutated by its owning script.
```

That made the instruction surface part of the bug.
`AGENTS.md` now states explicitly that a worker appending its own sparse line to the status file named in its brief is the authorized status protocol.
Since the composing writer landed, the brief hands that append as `bin/fm-status.sh`, and the section "The writer through the symlink" below records that the writer reaches the signal directory from inside the sandbox.
The wording fix alone is still not enough, because another live refusal described the same append as an external write.
The runtime fix removes the external write from the normal path.
The runtime fix also stops success from depending on which way the same reviewer happens to reason about an otherwise identical status append.

## Instance B, the silent no-status shape

The live evidence file recorded Instance B, the worse shape where a status write reported success with no output but the real `state/<id>.status` still did not exist.
The raw Codex transcript available for `fm-remove-gate-assumption` did not confirm that exact second status command.
It did confirm the initial sandbox `Read-only file system` failure, the reviewer denial of the escalated status append, and a later zero-output `git status --short` command.
So this repository records the silent write as an operator-observed live symptom, not as a raw-transcript-confirmed filesystem overlay finding.

The fix still treats the class as first-order.
The public append command remains the worker's status path, but `fm-spawn.sh` makes that public path a symlink into the per-task writable signal directory, so the write that reports success has one real writable target instead of relying on an external append or approval fallback.
`fm-crew-state.sh` now reports `cause: no-status-after-turn-end` when a turn-end marker exists and no status event landed.
That makes a completed turn with no status line distinguishable from a generic missing run or idle pane.

## The chosen channel

For a Codex direct report, `fm-spawn.sh` creates:

```text
state/.crew-signal/<id>/
state/<id>.status -> .crew-signal/<id>/status
state/<id>.turn-ended -> .crew-signal/<id>/turn-ended
```

The Codex launch line's `writable_roots` array carries this per-task signal root for every Codex direct report.
A ship or scout crewmate's array additionally carries its worktree's git common directory and, in a gated project, its no-mistakes gate repository; [`docs/codex-sandbox-git-directory.md`](codex-sandbox-git-directory.md) owns that second root and [`docs/codex-sandbox-gate-repo.md`](codex-sandbox-gate-repo.md) the third.
A secondmate receives the one-element form shown here:

```text
-c 'sandbox_workspace_write.writable_roots=["<FM_HOME>/state/.crew-signal/<id>"]'
```

The worker still writes to the public path named in its brief, `state/<id>.status`, through `bin/fm-status.sh`.
The write lands through the symlink into the private per-task directory that Codex is allowed to modify.
This preserves the public status-file contract for firstmate, watcher, wake-drain, brief text, and any existing reader.
A symlinked public status path is a fleet-wide contract change, so reviewers should judge it as a change to every reader and cleaner that touches `state/<id>.status` or `state/<id>.turn-ended`, not as a Codex-only launch detail.

The successful representative probe was:

```sh
ln -s .fm-signal-symlink-probe/status /home/crew/firstmate/state/.fm-signal-symlink-probe.status
codex sandbox -c 'sandbox_mode="workspace-write"' \
  -c 'sandbox_workspace_write.writable_roots=["/home/crew/firstmate/state/.fm-signal-symlink-probe"]' \
  -- bash -lc 'printf "probe\n" >> "$1"' bash /home/crew/firstmate/state/.fm-signal-symlink-probe.status
```

It returned success, and the target file contained:

```text
probe
```

The hardlink variant was rejected with `Read-only file system`, so the implementation uses symlinks.

## The writer through the symlink

The brief now hands the worker `bin/fm-status.sh` instead of a bare append, and that script lives in the vendored `bin/`, which the sandbox never grants write access to.
The question was whether a writer executed from a read-only root still reaches the per-task signal directory through the public symlink, and whether its refusal path writes nothing there.
Measured 2026-09-03 on `codex-cli 0.147.0`, with the fixture home under the source worktree and the sandbox's cwd a separate empty directory, so nothing but the listed root was writable.

```sh
mkdir -p "$P/home/state/.crew-signal/probe"
ln -s .crew-signal/probe/status "$P/home/state/probe.status"
# control: no writable root
codex sandbox -c 'sandbox_mode="workspace-write"' \
  -- bash -lc "FM_HOME='$P/home' '$W/bin/fm-status.sh' '$P/home/state/probe.status' done 'control'"
# accept
codex sandbox -c 'sandbox_mode="workspace-write"' \
  -c "sandbox_workspace_write.writable_roots=[\"$P/home/state/.crew-signal/probe\"]" \
  -- bash -lc "FM_HOME='$P/home' '$W/bin/fm-status.sh' '$P/home/state/probe.status' needs-decision --key route 'pick north or south'"
# refuse
codex sandbox -c 'sandbox_mode="workspace-write"' \
  -c "sandbox_workspace_write.writable_roots=[\"$P/home/state/.crew-signal/probe\"]" \
  -- bash -lc "FM_HOME='$P/home' '$W/bin/fm-status.sh' '$P/home/state/probe.status' needs-decision --key 'route choice' 'pick'"
```

The three runs returned, in order:

```text
bin/fm-status.sh: line 129: .../home/state/probe.status: Read-only file system
exit=1
appended: needs-decision [key=route]: pick north or south
exit=0
fm-status: decision key must be a privacy-safe slug: route choice
exit=2
```

After the three runs the signal directory's `status` file held exactly one line, `needs-decision [key=route]: pick north or south`.
So the writer reaches the signal root through the symlink exactly as the bare append did, the sandbox still refuses it without that root, and a refused key leaves the file untouched.
A `codex sandbox` run whose cwd is the home directory or `/tmp` proves nothing about the root, because that sandbox leaves the whole cwd and `/tmp` writable; the control above was only meaningful once the fixture sat outside both.

## Watcher implication

GNU `stat` does not follow symlinks by default.
A plain `stat -c '%s:%Y' state/<id>.status` sees the symlink object, whose size and mtime do not change when the target file receives an append.
`fm-watch.sh` therefore uses `stat -L` only for signal scans.
Metadata, parked markers, and other watcher signatures keep their existing non-dereferenced behavior.

## Scope

The signal writable root is given to Codex ship, scout, and secondmate direct reports.
The network grant remains crewmate-only and is still documented separately, as do the crewmate-only git-directory and gate-repository roots that share this same `writable_roots` array ([`docs/codex-sandbox-git-directory.md`](codex-sandbox-git-directory.md), [`docs/codex-sandbox-gate-repo.md`](codex-sandbox-gate-repo.md)).
No non-Codex harness receives a Codex sandbox writable-root override.
Teardown removes the public symlinks and the private `state/.crew-signal/<id>` directory with the rest of the task's volatile state.
