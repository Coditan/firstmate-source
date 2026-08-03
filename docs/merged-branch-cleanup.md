# Why a merged branch survives its own pull request

A firstmate fleet that ships every task on its own branch accumulates one branch per task forever unless something prunes them.
An audit of one fleet repository on 2026-08-03 found 154 remote branches, of which 146 were provably landed in `main` and only 5 carried work that was not.
Nothing had pruned any of them, because three independent mechanisms would each have had to and none did.

This document names all three, records which one firstmate's own code owns, and states plainly which one is deliberately not built.

## The three producers

| # | Producer | Owner | Status |
|:-:|---|---|---|
| 1 | The forge does not delete the head branch on merge | Per-repository setting | Not code; see below |
| 2 | Firstmate's merge path never asked the forge to delete it | `bin/fm-pr-merge.sh` | Fixed |
| 3 | The validation pipeline cannot delete its own mirror branch | The `no-mistakes` binary | Not fixed, and deliberately not half-built |

Fixing one does not fix the others.
Producer 1 governs branches on the forge that are merged through any route at all, including the web UI.
Producer 2 governs the route firstmate itself takes.
Producer 3 governs branches that were never on the forge in the first place.

## 1. The forge setting

`delete_branch_on_merge` is a per-repository setting, and it is `false` by default on GitHub.
While it is false, every merged pull request leaves its head branch behind no matter who merged it or how.

Read it, for any repository:

```
gh-axi api repos/<owner>/<repo> --jq '.delete_branch_on_merge'
```

Change it, which is the captain's call and not firstmate's, since it affects every future merge by every contributor to that repository:

```
gh-axi api -X PATCH repos/<owner>/<repo> --field delete_branch_on_merge=true
```

The same switch is **Settings - General - Pull Requests - "Automatically delete head branches"**.
It applies only to future merges: turning it on cleans up nothing that already exists.
Every repository firstmate merges into needs it separately, so a fleet that adds a project also adds a repository where this is false until someone sets it.
Set it one repository at a time, on the captain's word for that repository, and report the others rather than sweeping them: the setting changes how every future merge by every contributor behaves, so a decision about one repository is not authority over the rest.

## 2. Firstmate's merge path

`bin/fm-pr-merge.sh` is the one path firstmate uses to merge a task's pull request, and it now asks the forge to delete the head branch as part of the merge.
Its header owns the exact flags and the caller's opt-out; do not restate them here.

The safety properties that matter are properties of the merge command itself, verified against `gh` 2.96.0 by reading `pkg/cmd/pr/merge/merge.go` at tag `v2.96.0`:

- A failed merge returns before either deletion step runs, so a branch is never deleted when its merge did not land.
- Only the head branch of the pull request being merged is deleted, because that is the only ref the command knows.
- A head branch the forge already deleted under `delete_branch_on_merge` is tolerated as success (404 and 422 are treated as the goal already achieved), so producers 1 and 2 do not fight.
- No local branch is touched, because `CanDeleteLocalBranch` is set to `!cmd.Flags().Changed("repo")` and this path always passes `--repo`.

Firstmate issues no branch-delete command of its own anywhere in this path.
That is the whole reason the properties above are sufficient: there is no second code path that could delete a branch when the merge did not happen.

This is worth having in addition to producer 1, not instead of it.
It covers repositories where the setting cannot be changed, and it makes the intent visible at the call site rather than resting on a forge preference nobody can see from the code.

## 3. The validation pipeline's mirror, and why it is not fixed here

Projects that ship through the `no-mistakes` pipeline get a second copy of every task branch.
The pipeline pushes each branch into a local bare repository under `~/.no-mistakes/repos/<id>.git`, which never reaches the forge and is invisible to `gh`.
In the audited fleet these mirror branches were 73 of the 154, roughly half the sprawl and 73 MB of local disk.

### What the pipeline would need

It would need to learn that the pull request merged, and it never does.
Measured against the installed binary on 2026-08-03:

```
$ B=~/.no-mistakes/bin/no-mistakes
$ for p in 'delete-branch' 'push --delete' ':refs/heads/' 'gh pr merge' 'mergedAt' 'merged_at'; do
    printf '[%s] ' "$p"; grep -a -c -F "$p" "$B"
  done
[delete-branch] 0
[push --delete] 0
[:refs/heads/] 0
[gh pr merge] 0
[mergedAt] 0
[merged_at] 0
```

It has `gh pr view`, `list`, `edit`, `create`, and `checks`; it opens the pull request and watches its checks, and the merge happens outside it entirely.
It never queries merge state, and it has no branch-deletion code path of any kind.
Its cleanup verbs concern worktrees, backups, and daemon state, and `config.yaml` exposes no retention or branch-cleanup key.
So the answer is not a configuration change: the capability does not exist in the binary.

Three routes could supply it:

1. An upstream `no-mistakes` feature that deletes the mirror ref when it observes its pull request merged, hooking the CI step that already polls pull request state.
2. An external reaper on the host that walks `refs/heads/*` in the mirror repository, asks the forge whether a merged pull request exists for that head ref, and deletes the ones that do.
3. Deletion added to firstmate's merge path, which already knows the branch name and could know the mirror path at merge time.

### Why none of them ships with this change

Route 3 looks cheapest and is the one to resist.
Firstmate's merge path sees only the task it merges, so it would prune the mirror for tasks firstmate merged and leave every other mirror branch standing: the ones from tasks that were merged by hand, closed unmerged, abandoned mid-pipeline, or run before the change landed.
A mirror that is pruned sometimes is worse than one that is never pruned, because a surviving mirror branch stops meaning anything.
Today "the mirror still exists" means nothing at all and everyone knows it; half-pruned, it would read as "this work did not land," and that reading would be wrong most of the time.

Routes 1 and 2 are both real work with an owner problem.
The mirror repository is shared by every lane and every home on the host, and the `no-mistakes` daemon is a single shared instance serving all of them, so a reaper is fleet-wide infrastructure rather than a cleanup script, and it must never race the daemon or require stopping it.

The mirror is therefore a separate piece of work with its own decision behind it, and it stays unbuilt rather than half-built.
A one-time manual sweep of the mirror repository is a different question again, and does not depend on any of this.

## What else does not delete branches

`bin/fm-teardown.sh` prunes remote-tracking refs in a project clone, which is a local operation and deletes nothing on any remote.
It was built to tolerate a branch the forge deleted at merge, not to perform the deletion.
Nothing else in `bin/` deletes a remote branch.

## Recovering a deleted branch

GitHub keeps `refs/pull/<n>/head` permanently, for merged and closed-unmerged pull requests alike, and it points at the head commit the branch had.
`git fetch origin refs/pull/<n>/head` restores the tip of any branch that belonged to a pull request, which is what makes deleting a merged head branch a safe default rather than a judgement call.
A branch that never belonged to a pull request has no such backstop, so it is not covered by this and is not deleted by anything described here.
