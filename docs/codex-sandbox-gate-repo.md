# The Codex gate-repository writable root

Why a Codex crewmate carries its project's no-mistakes gate repository as a third `sandbox_workspace_write.writable_roots` entry, what that grant admits, and what it deliberately leaves refused.
The network dimension is a separate grant with a separate rationale, documented in [`docs/codex-sandbox-network.md`](codex-sandbox-network.md); the git common directory is documented in [`docs/codex-sandbox-git-directory.md`](codex-sandbox-git-directory.md); the per-task signal root is documented in [`docs/codex-status-signalling.md`](codex-status-signalling.md).
`bin/fm-spawn.sh` owns the composition and is the authority on the exact flags.

This grant closes the `PROBE2` refusal that [`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 9 recorded as open on 2026-08-11 and left as a separate captain decision.
That decision was taken on 2026-08-29.

## 1. The defect

A Codex crewmate finishes its implementation commit, starts `no-mistakes axi run`, and the pipeline dies before it creates a gate at all.
Observed live, reproduced twice on the same commit:

```
error: "push \"fm/ak-cl-packs-repo-aufteilen\" to gate: git push ...
  remote unpack failed: unable to create temporary object directory
To /home/crew/.no-mistakes/repos/8ab137b36eb3.git
 ! [remote rejected] HEAD -> fm/ak-cl-packs-repo-aufteilen (unpacker error)"
```

The gate repository itself was healthy.
From an unsandboxed shell the same directory was writable, `objects/` held 258 clean entries with no leftover `tmp_objdir*` or `incoming-*` directories, no `objects/info/alternates`, disk at 53 percent and inodes at 25 percent, and the daemon answered `no-mistakes axi status` normally.

The decisive measurement is the probe run INSIDE the Codex crewmate's own sandbox:

```
$ mkdir -p /home/crew/.no-mistakes/repos/8ab137b36eb3.git/objects/tmp_probe_fm && rmdir ... && echo PROBE_OK
mkdir: Read-only file system
```

The same command from an unsandboxed shell prints `WRITE OK as crew`.
So this is the Codex workspace-write sandbox, not git, not permissions, and not the daemon.

The reason it is the crewmate's confinement to answer rather than the daemon's is that `git push` to a local path runs `git-receive-pack` as the PUSHING process.
The quarantine directory git wants to create under the gate's `objects/` is therefore created by the sandboxed crewmate, and refused.
Before this change the launch line named two writable roots, the task's own `state/.crew-signal/<id>/` directory and the worktree's git common directory, and the gate is in neither.

Unlike the git-directory defect, this one did not degrade into an approval escalation.
The worker had `approval_policy = "on-request"` and `approvals_reviewer = "auto_review"` available, did not escalate, and returned the error, which [`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 9 had already recorded as evidence against the inference that the approval path clears such a refusal.

## 2. The measurement, 2026-08-29

Taken against `codex-cli 0.145.0` with the same `codex sandbox` instrument as the two sibling verification records, run outside `/tmp` (see section 5 for why that matters) against the live `ak-content-line` gate named in the failure above.

```
# signal root only - what every Codex crewmate had before this change
$ codex sandbox -c 'sandbox_mode="workspace-write"' \
    -c 'sandbox_workspace_write.writable_roots=["<...>/.probe/signal"]' \
    -- sh -c "mkdir -p $GATE/objects/tmp_probe_fm_baseline && rmdir ... && echo PROBE_OK"
mkdir: Read-only file system

# signal root plus the gate repository
$ codex sandbox -c 'sandbox_mode="workspace-write"' \
    -c 'sandbox_workspace_write.writable_roots=["<...>/.probe/signal", "'$GATE'"]' \
    -- sh -c "mkdir -p $GATE/objects/tmp_probe_fm_granted && rmdir ... && echo PROBE_OK"
PROBE_OK
```

The refusal reproduces the live message exactly, and the grant is what clears it.
The gate was left as it was found: 258 entries under `objects/`, no probe leftovers.

## 3. What the grant admits, and what it does not

Measured in the same session, from inside the sandbox, with one gate repository granted:

```
own gate quarantine write:                        PROBE_OK
daemon directory write (.no-mistakes/bin/):       Read-only file system   REFUSED
another project's gate (b020faba9d74.git):        Read-only file system   REFUSED
new gate under .no-mistakes/repos/:               Read-only file system   REFUSED
```

So the grant reaches one bare repository and stops there.
Inside it the crewmate can write anything: objects, refs including the gate's own default branch, `config`, and `hooks/`, which is executable content the next push into that gate would run.
That reach is the price of the push, on the same terms as the git-directory grant: receive-pack cannot accept a push without writing into the repository that receives it.

What stays refused is everything the fleet actually needs kept out of a crewmate's hands.
The daemon's own `bin/` and runtime directory are outside the grant, so the prohibition on a crewmate touching the daemon is drawn in the capability and not only in a brief.
Every other project's gate is outside it too, which is the concrete reason the grant is the resolved gate repository and never the `/home/<user>/.no-mistakes/repos` root: that root would work equally well for the push and would hand every crewmate write access to every other project's gate, and to any gate created after launch.
The project's working tree also stays outside every writable root, unchanged by this grant, because AGENTS.md hard rule 1 and the spawn-time isolation assertion both rest on a worker being unable to write there.

The push needs nothing else outside the gate.
`git-receive-pack` writes the quarantine directory, the migrated objects, and the refs, all inside the gate.
The gate's `pre-receive` and `post-receive` hooks write only `<gate>/notify-push.log` and otherwise reach the daemon over its socket, which the separate network grant already covers.

## 4. Scope

- A Codex ship or scout crewmate gets the grant, because it is the one that runs the pipeline and pushes to the gate.
- A Codex secondmate does not.
  It supervises rather than ships and runs no pipeline of its own, and its own crewmates receive the grant from its own call into the same path.
  The exclusion is enforced both at the call site and inside the composition, so a caller that resolved a gate anyway cannot hand one to a secondmate.
- The path is resolved at spawn time from the worktree remote's effective push destination, which is the exact local path `git push` hands to `git-receive-pack`.
  Asking git for that destination honors a remote push URL override and configured push URL rewrites.
  That is deliberately obtained from git itself rather than a parallel oracle that could disagree with the push.
  `no-mistakes status` also prints the gate, and was checked first: it is human-formatted, it needs the daemon up to answer, and it resolves the primary repository rather than the worktree being launched into.
  A linked worktree shares its repository's config, so asking the worktree is correct.
  Plain paths, `file:///absolute/path`, and `file://localhost/absolute/path` are accepted as local destinations.
  Absolute paths and explicitly anchored `./` or `../` paths remain local when their names contain a colon.
  Other schemes, file URLs naming another host, and scp-style destinations with a colon before their first slash refuse because a filesystem writable root cannot grant them.
  It is canonicalized with `pwd -P` so it matches the physically resolved path the sandbox compares against.
- A project with no `no-mistakes` remote is not gated, so there is nothing to grant and no third root is emitted.
  Such a worker is exactly as capable as it was before this grant existed.
- A configured gate whose effective push destination cannot be obtained or does not resolve to a directory refuses the launch.
  Composing the launch line with the root silently dropped would strand the worker at the gate push with a message that names none of this, which is the failure mode section 1 describes.
- A configured gate with multiple effective push destinations refuses the launch.
  The authorized capability is one project gate, so the grant neither selects a subset that would still fail nor widens itself to several gates.
- The resolved destination must report itself as a bare Git repository whose canonical absolute Git directory is that destination itself.
  This rejects both ordinary worktrees and directories that merely sit inside another repository, so a misconfigured remote cannot make the project worktree or daemon data directory writable.
- No other harness is affected: the grant lives entirely in the Codex branch of the composition.
- Like every other launch-line grant, it reaches a home only once that home's own copy of `bin/fm-spawn.sh` carries it ([`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 8).

## 5. Instrument limits and what is not covered

`/tmp` is writable inside a `codex sandbox` workspace-write sandbox unless `exclude_slash_tmp` is set, so a probe under `/tmp` does not reproduce this refusal.
The measurements above were taken outside `/tmp` for that reason, and anyone repeating them should do the same.

`codex sandbox` is a weaker instrument than the interactive `codex` session `bin/fm-spawn.sh` actually launches, so a refusal measured through it may still understate what a real crewmate achieves through the approval path.
For this particular refusal the live evidence in section 1 runs the other way - a real worker did not escalate and simply failed - so the grant is what closes it.

Creating a gate that does not exist yet is NOT covered.
`no-mistakes init` in an ungated project would have to create a new directory under the `repos` root, and that root is deliberately not granted, as the section 3 measurement shows.
Whether `init` performs that mkdir in the calling process or through the daemon was not measured here, so this is stated as an untested boundary rather than a known failure.
A project is normally gated before a Codex crewmate ships in it, so this has not been observed in practice.
