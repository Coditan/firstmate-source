# Merging on the self-hosted forge through the sanctioned helper

Empirical record for the second slice of the captain's decision to replace GitHub with the fleet's own Forgejo instance.
The first slice taught `bin/fm-pr-lib.sh` which forge an address belongs to and recorded that in [`docs/forgejo-pr-identity.md`](forgejo-pr-identity.md); this one teaches `bin/fm-pr-merge.sh` to merge one.
Every command below was run on 2026-08-22 and its output is reproduced exactly.

The reason it is the helper rather than a new command is that every task merge in this fleet goes through that helper so the merge metadata is recorded and its guards run.
A merge made around it is unrecorded and ungated, so the forge does not become usable by anyone learning a second command; it becomes usable when the existing helper speaks to it.

## Versions

```
$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
$ node --version
v20.20.2
$ jq --version
jq-1.7
$ forgejo-axi --version
1.3.0
```

`forgejo-axi` 1.3.0 is the floor [`docs/forgejo-axi-adoption.md`](forgejo-axi-adoption.md) sets, installed for this run into a scratch prefix from npm rather than into this seat's own toolchain.

## What could not be exercised, said first

**No merge in this record touched a real Forgejo.**
Three separate things stand between this seat and the fleet's own instance, and none of them is this slice's to remove.

1. The instance serves plaintext HTTP over the tailnet, and the client refuses plaintext to a non-loopback host with `INSECURE_TRANSPORT`.
   TLS on that host is somebody else's work and is not done.
2. No Forgejo credential is reachable from this account; the adoption record established that on 2026-08-19 and nothing has changed it.
3. This home names no instance at all, so `bin/fm-pr-lib.sh` correctly refuses every Forgejo address here outside a fixture.

So everything below runs against a **Forgejo-shaped stand-in**: a small HTTP server that answers the pull request route and the merge route.
Its merge route was written from the request the client actually sends, read out of the client's own source: `POST .../pulls/<n>/merge` with `{"Do": <method>, "head_commit_id": <sha>}`.
That the real Forgejo honours `head_commit_id` the way the stand-in does is **not** established here.
The client's own capability probe reports `expected_head_merge`, and an earlier proof recorded in the adoption document did merge a pull request on a real instance, but neither is this task's evidence and neither is treated as such.

Three further things are consequently untested: authentication, branch protection, and required checks on a real forge.

## The seam, and why it is exactly one substitution

The helper derives its base URL from the pull request's own host, which is the property that keeps a merge from being sent to whatever instance the surrounding environment happens to name.
A derived `https://forge.example` implies port 443, and this seat can bind neither:

```
$ cat /proc/sys/net/ipv4/ip_unprivileged_port_start
1024
$ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",443))'
PermissionError: [Errno 13] Permission denied
$ unshare --user --map-root-user --net -- true
unshare: write failed /proc/self/uid_map: Operation not permitted
```

So the full-chain runs below put one shim on `PATH` in front of the real client, and it changes **only the socket address**: it rewrites `https://forge.example` to `http://127.0.0.1:8788` and passes every other argument through untouched, printing both argv lines so the substitution is visible in the transcript.
Everything else in those runs is real - the real `bin/fm-pr-merge.sh`, the real `bin/fm-pr-check.sh` recording, the real `forgejo-axi` 1.3.0 - and only the forge behind the socket is a stand-in.
This is the same seam the adoption record accepted for its own live readings, in the same words: the bytes are the server's, only the socket address differs.

## A merge on this forge, through the helper

The forge holds an open pull request at head `1111…1111`:

```
$ ./bin/fm-pr-merge.sh task-live https://forge.example/team/tools/pulls/7
recorded: state/task-live.meta
note: no merge watch was armed, because --no-watch was requested. Nothing will
      report PR 7 in team/tools on forge.example being merged; whoever asked
      for that owns the outcome.
note: this merge deletes no branch. On GitHub the forge deletes the merged head
      branch as part of the merge; this forge's client has no branch deletion,
      and this path will not delete one through a separate call and present it
      as part of the merge. The head branch stays.
      docs/merged-branch-cleanup.md owns merged-branch cleanup.
HELPER ARGV: pr merge 7 --repo team/tools --base-url https://forge.example --expected-head 1111111111111111111111111111111111111111 --method merge --json
SHIM   ARGV: pr merge 7 --repo team/tools --base-url http://127.0.0.1:8788 --expected-head 1111111111111111111111111111111111111111 --method merge --json
merged: PR 7 in team/tools on forge.example, method merge, head 1111111111111111111111111111111111111111
{"proof":{"merged":true,"number":7,"url":"http://127.0.0.1:8788/team/tools/pulls/7","head_sha":"1111111111111111111111111111111111111111","merge_commit_sha":"9999999999999999999999999999999999999999","merged_at":"2026-08-22T00:00:00Z","merged_by":"fmtest"}}
```

The metadata is the same metadata a GitHub merge records, and nothing was armed:

```
$ cat state/task-live.meta
window=fm-task-live
worktree=.../live/wt
project=.../live/project
kind=ship
mode=no-mistakes
pr=https://forge.example/team/tools/pulls/7
pr_head=1111111111111111111111111111111111111111
$ ls -1 state/
task-live.meta
```

And the forge moved:

```
merged=True state=closed merge_commit=9999999999999999999999999999999999999999 method=merge
```

What the forge was actually asked, from its own log:

```
GET  /api/v1/repos/team/tools/pulls/7
POST /api/v1/repos/team/tools/pulls/7/merge
BODY {"Do": "merge", "head_commit_id": "1111111111111111111111111111111111111111"}
GET  /api/v1/repos/team/tools/pulls/7
```

## The guard, watched refusing

The head commit is the one guarantee this forge demands that GitHub does not, and it is refused in two independent places.
Both were caused rather than described.

**The client refuses one that moved before the merge.**
The stand-in advances the branch after the helper's read, so the head the merge names is no longer the head:

```
$ ./bin/fm-pr-merge.sh task-live https://forge.example/team/tools/pulls/7
...
{"error":"Pull request head changed","code":"HEAD_CHANGED","details":{"expected":"1111111111111111111111111111111111111111","actual":"2222222222222222222222222222222222222222"},"help":[]}
exit=1
forge: merged=False state=open
```

**The forge-side check refuses one that moved after that.**
The branch advances later, so the client's own comparison passes and the `head_commit_id` in the request is the one that is now stale.
This is the stand-in refusing, on the request shape read out of the client's source; that the real Forgejo refuses the same request the same way is the thing named as unestablished above, and this run does not establish it:

```
$ ./bin/fm-pr-merge.sh task-live https://forge.example/team/tools/pulls/7
...
{"error":"Forgejo API request failed: head has moved","code":"CONFLICT","details":{"status":409},"help":[]}
exit=1
forge: merged=False state=open
```

**And the merge is refused outright with no head at all**, which is the guarantee stated as the client's own requirement rather than as a convention:

```
$ forgejo-axi pr merge 7 --repo team/tools --base-url http://127.0.0.1:8788 --method merge
error: "--expected-head is required"
code: VALIDATION_ERROR
exit=2
```

## A success that was not earned, watched being refused

The stand-in answers `200` to the merge and then still reports the pull request open - success claimed for work not done, which is the shape this fleet kept finding the week this was written:

```
$ ./bin/fm-pr-merge.sh task-live https://forge.example/team/tools/pulls/7
...
{"error":"Forgejo accepted the merge but did not report merged state","code":"MERGE_NOT_PROVEN","details":{},"help":[]}
exit=1
```

That refusal is the client's.
`bin/fm-pr-merge.sh` carries its own second reading of the same proof - it requires the proof to say merged and to name the head it merged - which fires only if the client itself ever reports a merge its proof does not support.
`tests/fm-pr-merge.test.sh` causes both of those conditions directly, because a client that misreports cannot be provoked from outside it.

## The guarantees that are absent, and are reported rather than emulated

| Guarantee on GitHub | On this forge | What this path does |
| --- | --- | --- |
| The forge deletes the merged head branch as part of the merge | The client has no branch deletion at all | Says the branch stays, and refuses `--delete-branch` rather than issuing a separate delete and presenting it as part of the merge |
| Arming records the pull request and starts a merge watch | `bin/fm-pr-poll.sh` reads GitHub and GitLab only | Records through `fm-pr-check.sh --no-watch`, which records the same metadata and says no watch exists |
| gh-shaped merge flags | A different flag language | Translates `--merge`, `--squash`, `--rebase` and `--delete-branch=false`; refuses anything else instead of forwarding it |
| Nothing on either forge reads check state before merging | Same | Unchanged, and named here so it is not mistaken for something this slice added: `AGENTS.md` section 7 makes reading the required checks against the head commit the control, and the fleet's own gate slices own the rest |

The branch deletion is the one worth stating twice.
Deleting it through a second call is an action that can fail on its own while the merge stands, and a half-done thing reported as part of a merge reads as done.
`docs/merged-branch-cleanup.md` owns merged-branch cleanup, and a merged branch on this forge is now one more producer for it.

## A credential that is set and still not read

Passing the instance as a flag is what keeps a merge on the right server, and it is also what makes the client ignore a bare `FORGEJO_TOKEN`.
That is not read out of the client's source and repeated here; it was measured by whether the request carried an `Authorization` header at all, with the stand-in logging presence and never a value:

```
--- bare FORGEJO_TOKEN with an explicit --base-url ---
GET /api/v1/repos/team/tools/pulls/7 auth=absent
--- host-scoped token with the same explicit --base-url ---
GET /api/v1/repos/team/tools/pulls/7 auth=present
```

So the helper says so whenever a bare token is set, regardless of whether another credential source may also be available:

```
note: FORGEJO_TOKEN is set, and this merge names the instance as a flag, which
      is exactly the case where that client reads a token only from a
      host-scoped FORGEJO_TOKEN_<HOST> variable or from its own hosts.json.
      The bare FORGEJO_TOKEN will not be read on this path.
```

It is a note and never a check.
It says only that the bare credential is not read on this path; it does not claim that no other credential will be used or whether any credential would be accepted, because only the client and forge can answer those questions.
This fleet has already been bitten once by a credential check that passed while the credential was absent, and a check that implies more than it measured is that defect wearing a different coat.

Whoever wires this fleet's own credential should therefore set `FORGEJO_TOKEN_<HOST>` or write the client's `hosts.json`, not `FORGEJO_TOKEN`.

## The merge method, and why the default matters more here

The default is a real merge commit, as it is on GitHub, and `--squash` is translated where a caller asks for it deliberately.
That default matters for ancestry-preserving flows such as vendored pin merges: a squashed tip is never an ancestor of the default branch, so a version pin's ancestry would claim a lineage that does not exist.
The helper's default is what holds that property when nobody passes a method.

## What this deliberately did not change

GitHub merges are byte-identical to before, proven by their own cases in `tests/fm-pr-merge.test.sh` passing unchanged.
A GitLab merge request still parses and is still refused by this path.

Two sibling slices of the same undertaking own what this one does not:

- Arming a Forgejo watch and reading the merged state from this forge belongs to the watch slice; `fm-pr-check.sh` still refuses to arm one, and `--no-watch` is a separate door rather than that refusal being lifted.
- Proving that work landed on this forge before cleanup belongs to the landed-work slice, which is itself sequenced behind a defect in that proof.

## Maintaining this file

This is an evidence record, so it changes only when something in it is re-measured.
Replace the stand-in sections when a merge is run against a real Forgejo instance, and say which of the three blockers above was removed to make that possible.
Re-measure rather than reason about it: the point of this file is that every claim in it was produced by running something.
