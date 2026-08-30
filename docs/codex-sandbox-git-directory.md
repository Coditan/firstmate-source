# The Codex git-directory writable root

Why a Codex crewmate carries its worktree's git common directory as a second `sandbox_workspace_write.writable_roots` entry, what that grant admits, and what it deliberately leaves refused.
The network dimension is a separate grant with a separate rationale, documented in [`docs/codex-sandbox-network.md`](codex-sandbox-network.md); the per-task signal root is documented in [`docs/codex-status-signalling.md`](codex-status-signalling.md).
`bin/fm-spawn.sh` owns the composition and is the authority on the exact flags.

## 1. The defect

A Codex crewmate is launched into a treehouse worktree whose git common directory lives in the project's PRIMARY checkout: for a worktree of `projects/hlr-calc` that is `projects/hlr-calc/.git`.
Before this change the launch line named exactly one writable root, the task's own `state/.crew-signal/<id>/` directory, so the common directory was in neither writable root.
The first thing a ship worker does - create its branch - therefore crossed the sandbox boundary.
Observed live on 2026-08-24 on task `hlr-calc-deploy-for-phillip`:

```
fatal: cannot lock ref 'refs/heads/fm/hlr-calc-deploy-for-phillip':
unable to create directory for
/home/crew/firstmate/projects/hlr-calc/.git/refs/heads/fm/hlr-calc-deploy-for-phillip
```

The account has write permission on that directory, so this is the sandbox refusing, not the filesystem.

The defect was invisible because it degraded rather than failed.
`approval_policy = "on-request"` with `approvals_reviewer = "auto_review"` turns each refusal into an escalation, and the escalations were approved, so the work completed.
That also settles the question [`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 9 left open - how a Codex crewmate nevertheless commits in this layout - and it is not a reason to leave the grant unstated: every ref write, commit, and fetch crossed the same boundary, so the launch line did not describe what the worker could touch, and the real boundary was whatever the reviewer happened to approve.

## 2. The measurement, 2026-08-24

Taken against `codex-cli 0.145.0` with a repository and a linked worktree created for the probe, both outside `/tmp` (see section 5 for why that matters), using the same `codex sandbox` instrument as the network verification record.

```
$ git init -q repo && cd repo && git commit -qm init && git worktree add -q -b wtb ../wt && cd ../wt
$ git rev-parse --git-common-dir
/home/crew/.treehouse/firstmate-c22c88/1/firstmate/.probe/repo/.git

# signal root only - what every Codex crewmate had before this change
$ codex sandbox -c 'sandbox_mode="workspace-write"' \
    -c 'sandbox_workspace_write.writable_roots=["<...>/.probe/signal"]' \
    -- git checkout -b fm/probe-a
fatal: cannot lock ref 'refs/heads/fm/probe-a': unable to create directory for
  /home/crew/.treehouse/firstmate-c22c88/1/firstmate/.probe/repo/.git/refs/heads/fm/probe-a

# signal root plus the git common directory
$ codex sandbox -c 'sandbox_mode="workspace-write"' \
    -c 'sandbox_workspace_write.writable_roots=["<...>/.probe/signal", "<...>/.probe/repo/.git"]' \
    -- git checkout -b fm/probe-b
Switched to a new branch 'fm/probe-b'
```

The refusal reproduces the live message exactly, and the grant is what clears it.

## 3. What the grant admits, and what it does not

Measured in the same session, from inside the sandbox, with the git-directory root granted:

```
primary working tree write: Read-only file system   REFUSED
git config write:                                   WROTE
hooks write:                                        WROTE
other-ref write (refs/heads/main):                  WROTE
```

So the grant is not narrow, and it cannot be: git cannot create a branch without writing into the directory that holds every ref.
A Codex crewmate can now write anything inside that repository's git directory - any ref including the default branch's, `config`, and `hooks/`, which is executable content the next `git` invocation in that repository may run.
The refs and objects are shared with the project's primary checkout and with every other worktree of it, so the reach is the repository, not this task's branch.

What stays refused is the project's working tree.
`projects/<name>/` is not a writable root and must never become one: AGENTS.md hard rule 1 and the spawn-time isolation assertion both rest on a worker being unable to write there, and a grant that reached it would retire both silently.
The `<project>/.git` path has the working tree's path as its prefix, so a substring check on the launch line cannot tell the two apart; `tests/fm-spawn-dispatch-profile.test.sh` reads the composed array as a list for exactly that reason.

## 4. Scope

- A Codex ship or scout crewmate gets the grant, because it is the one that creates a branch, commits, and fetches.
- A Codex secondmate does not.
  It supervises rather than ships, its home holds no task branch, and its own crewmates receive the grant from its own call into the same path.
  Its blast radius would also be wider than a crewmate's: a secondmate home is a worktree of the FIRSTMATE repository, so its common directory is the primary checkout's own git directory.
- The path is resolved at spawn time from the worktree actually being launched into, never string-built from the project argument, and canonicalized with `pwd -P` so it matches the physically resolved path the sandbox compares against.
- A plain clone, whose common directory is inside its own working tree, gets no second root: `workspace-write` already covers it, and emitting it would duplicate a root.
- An unresolvable common directory refuses the launch.
  Emitting no root would restore the pre-grant behaviour with nothing on the launch line or in the output to say the grant was dropped, which is the failure mode section 1 describes.
- No other harness is affected: the grant lives entirely in the Codex branch of the composition.
- Like every other launch-line grant, it reaches a home only once that home's own copy of `bin/fm-spawn.sh` carries it (`docs/codex-sandbox-network.md` section 8).

## 5. Instrument limits

`/tmp` is writable inside a `codex sandbox` workspace-write sandbox unless `exclude_slash_tmp` is set, so a probe repository under `/tmp` does not reproduce this refusal.
A first attempt at section 2 was run there and reported a partial, misleading result: the branch ref was created and only the per-worktree `HEAD` update failed.
The measurement above was re-taken outside `/tmp` for that reason, and anyone repeating it should do the same.

`codex sandbox` is a weaker instrument than the interactive `codex` session `bin/fm-spawn.sh` actually launches, so a refusal measured through it may still understate what a real crewmate achieves through the approval path.
That understatement is the point of the grant rather than an objection to it: what the approval path allows is not what the launch line declares.

The no-mistakes gate repository refusal recorded in [`docs/codex-sandbox-network.md`](codex-sandbox-network.md) section 9 (`PROBE2`) is a different path and is NOT covered here.
It is closed by a separate third writable root, owned by [`docs/codex-sandbox-gate-repo.md`](codex-sandbox-gate-repo.md).
