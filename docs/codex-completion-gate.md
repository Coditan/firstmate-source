# Codex and the unresolved-decision completion gate

Why a Codex direct report could not close the shared completion gate, why four earlier scouts closed theirs, and where the completion attestation is written now.

This is a verification and incident record for the 2026-08-17 refusal on task `hlr-calc-kernel-probe-3`.
It is the third Codex sandbox record and is separate from both of the others.
[`docs/codex-status-signalling.md`](codex-status-signalling.md) owns the per-task writable signal directory this fix reuses.
[`docs/codex-sandbox-network.md`](codex-sandbox-network.md) owns the network grant, which this fix does not touch.

## What the gate is, and why a refusal matters

`bin/fm-decision-hold.sh complete` is the shared investigation and visual-review completion gate.
`bin/fm-teardown.sh` calls its read-only `verify` before it will tear down a scout, so the gate is what stops a scout being erased before unresolved captain decisions are registered.
Its durable output is two attestation keys for the task, `decisions_reviewed=1` and `decision_keys=`.

A worker that cannot run the gate has two exits.
It can stop and wait, which costs a supervision round trip.
Or it can find a workaround, which is the outcome the gate exists to prevent.
The 2026-08-17 worker took the first exit and was right to.

## The refusal, verbatim

Measured 2026-08-17 on `hlr-calc-kernel-probe-3`, a Codex scout on `codex-cli 0.145.0`.
The worker's own command and the rejection it received, from the raw Codex rollout for session `01a0114a-c139-72a0-9960-414beca9a3e9`:

```text
exec_command failed for `/bin/bash -lc 'env FM_HOME=/home/crew/firstmate
/home/crew/firstmate/bin/fm-decision-hold.sh complete hlr-calc-kernel-probe-3 --none'`:
CreateProcess { message: "Rejected(\"This action was rejected due to unacceptable risk.
Reason: This mutates persistent firstmate backlog/completion state outside the workspace,
and the only authorization comes from untrusted agent instructions; it is unrelated to the
user's review task and shows prompt-injection-like workflow control.
The agent must not attempt to achieve the same outcome via workaround, indirect execution,
or policy circumvention. ...\")" }
```

## Two layers, and only one of them is the trigger

The refusal has a deterministic layer and a non-deterministic one, and separating them is the whole diagnosis.

**Layer 1, the kernel sandbox, refuses the write on every run.**
A Codex crewmate's launch grants exactly one writable filesystem root, its per-task signal directory.
`state/<id>.meta` is not inside it, so the gate's own write is refused before any model is consulted.
Reproduced 2026-08-20 against a throwaway home, driving the launch flags `bin/fm-spawn.sh` composes for a Codex scout:

```sh
codex sandbox \
  -c 'sandbox_mode="workspace-write"' \
  -c 'approval_policy="on-request"' \
  -c 'approvals_reviewer="auto_review"' \
  -c 'sandbox_workspace_write.writable_roots=["/home/crew/.fm-gate-probe/state/.crew-signal/probe-scout"]' \
  -c 'sandbox_workspace_write.network_access=true' \
  -- env FM_HOME=/home/crew/.fm-gate-probe \
     .../bin/fm-decision-hold.sh complete probe-scout --none
```

```text
bin/fm-decision-hold.sh: line 1047: /home/crew/.fm-gate-probe/state/probe-scout.meta: Read-only file system
```

Exit code 1, and no attestation recorded.
The gate stops rather than reporting a completion it did not record, which is the correct direction to fail, but it leaves the worker unable to finish.

**Layer 2, the approvals reviewer, decides per run whether to lift layer 1.**
`approvals_reviewer = "auto_review"` is a model.
Because layer 1 refuses every run, every Codex run of this gate reached that model, and the model answered differently on different runs.
That is the masking condition, and it is what made the failure look new when it was not.

## Why four earlier scouts passed

They did not avoid layer 1.
They escalated exactly as `hlr-calc-kernel-probe-3` did, and were approved.
From the raw rollout for `hlr-calc-mathcad-surface`, session `01a01104-53a9-7283-9014-e80379a29d9f`:

```json
{"cmd":"bin/fm-decision-hold.sh complete hlr-calc-mathcad-surface --none",
 "workdir":"/home/crew/firstmate","sandbox_permissions":"require_escalated",
 "justification":"Allow the firstmate decision-hold completion gate to write its required task metadata outside the workspace?"}
```

```text
Process exited with code 0
Output:
complete: hlr-calc-mathcad-surface decision inventory reviewed
```

`sandbox_permissions: require_escalated` is the same escalation the refused run needed.
So the gate never worked unaided on Codex; its success was decided per run by a model.
This was not a regression on 2026-08-17 and not a change of policy: the gate has required that metadata write since it was introduced on 2026-07-15 in `feat: add durable captain decision holds (#593)`.

The two commands differ in shape - the approved one is repo-relative with `workdir` set, the refused one carries an `env` prefix and absolute paths - and the rejection text reads like a reaction to that shape.
This record does not claim the shape caused the verdict.
One approval and one rejection cannot separate the shape from the reviewer's own per-run judgement, and `docs/codex-status-signalling.md` already measured the same reviewer reaching opposite verdicts on identical status appends.
The fix therefore removes the escalation instead of trying to word a command the reviewer will reliably accept.

## The fix, and why it is not a widening

The sandbox is unchanged: no new writable root, no new grant, no profile change.
`bin/fm-spawn.sh` is unchanged.

`decisions_reviewed` and `decision_keys` are private to `bin/fm-decision-hold.sh`; nothing else in `bin/` reads or writes them.
That is what lets them move without touching the metadata contract every other script depends on.
The attestation now lands in the task's own per-task signal directory when `fm-spawn` created one, and in `state/<id>.meta` otherwise:

```text
state/.crew-signal/<id>/decisions
```

This is one record, not two.
A metadata file is a last-wins `key=value` log, and the gate reads the overlay as if it were appended to the metadata, which is exactly what it replaces.
Both halves are read together, so no caller can see one without the other, and a task attested in its metadata before this change keeps verifying afterwards.
`bin/fm-teardown.sh` removes the signal directory well after it runs `verify`, so the attestation is still readable at the moment the gate is checked.

Same probe as above, after the fix:

```text
complete: probe-scout decision inventory reviewed
rc=0
```

```text
$ cat /home/crew/.fm-gate-probe/state/.crew-signal/probe-scout/decisions
decisions_reviewed=1
decision_keys=
```

The metadata file was not written, and `verify` run outside the sandbox accepted the result.

## Why the public metadata path was not symlinked instead

Symlinking `state/<id>.meta` into the signal directory would have matched the status fix exactly, and it was rejected on measurement rather than on taste.
`bin/fm-watch.sh` takes a non-dereferenced change signature of the metadata file at `meta_sig=$(stat_sig "$meta")` and uses it to invalidate parked-marker tracking.
A symlink's own size and mtime do not change when its target is appended to, so a symlinked metadata file would freeze that signature and a parked task whose metadata changed would never clear its tracking.
The status path could take a symlink because `fm-watch.sh` dereferences deliberately for signal scans only.

## Scope, and what this does not fix

The status half of the same 2026-08-17 incident was already fixed separately on 2026-08-18 by the per-task signal directory, and is confirmed still working:
appending to the public `state/<id>.status` path inside the sandbox succeeds through the symlink with no escalation.

Two limits are worth stating plainly.

This removes the *need* to escalate; it cannot stop a worker from choosing to ask anyway.
A worker that requests escalation for a command it could simply have run still meets the same per-run model judgement.
What changed is that the gate now succeeds when the worker just runs it.

Nothing here measures the reviewer itself.
This record deliberately makes no claim about which command shapes `auto_review` accepts, because the evidence available - one approval, one rejection - cannot support one.
