# A host that cannot start a sandbox

Measured 2026-09-05 on the vessel `crew-hlr`, codex-cli 0.152.1.

## What happens

Codex's `workspace-write` sandbox needs an unprivileged user namespace.
On a host whose kernel refuses to create one, the sandbox fails to initialize and **every** sandboxed action fails before it does anything.
Two walls follow from that, and a Codex ship task meets both:

1. **Running a command.**
   The worktree-isolation assertion every generated ship brief demands as its first action is a shell command.
   A worker that cannot run it correctly reports blocked and changes nothing.
2. **Editing a file.**
   `apply_patch` routes through the same sandbox even on an approved uncontained path, so a worker that clears wall 1 still writes zero files.
   Clearing only wall 1 is what made this look fixed once already, on 2026-09-05, an hour before the second worker blocked with nothing changed.

A read-only Codex scout does not meet either wall, because its escalation to approved unsandboxed execution is auto-approved.
It is the ship contract's hard-stop rule that turns a degraded sandbox into a full stop.

## Cause, and the message that misleads

The cause here is AppArmor, not the sysctl bubblewrap's error message names.

```
$ cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns
1
$ sysctl kernel.unprivileged_userns_clone
kernel.unprivileged_userns_clone = 1
$ cat /proc/sys/user/max_user_namespaces
26835
$ unshare --user --map-root-user true
unshare: unshare failed: Operation not permitted
```

bwrap reports `No permissions to create a new namespace` and suggests enabling `kernel.unprivileged_userns_clone`, which is **already** enabled on this host.
Anyone following that message changes a correct setting and concludes the fix failed.
Detection therefore probes the capability itself - `unshare --user --map-root-user true` - and never that sysctl.

The host restriction itself stays as it is; the captain ruled on 2026-09-05 that lifting it gains nothing.

## What firstmate does

`bin/fm-spawn.sh` probes the host once per spawn and composes the Codex launch accordingly:

| probe | launched `sandbox_mode` | announced |
| --- | --- | --- |
| a sandbox starts | the shipped `workspace-write` | no |
| a sandbox does not start | `danger-full-access` | yes, once on stderr |
| the probe could not be taken (a Linux host with no `unshare(1)`) | the shipped `workspace-write` | yes, once on stderr |
| the host is Darwin (no probe taken) | the shipped `workspace-write` | no |

On Darwin the question does not apply: Codex sandboxes there through Seatbelt and never needs a user namespace, and macOS ships no `unshare(1)`, so taking the probe would announce an unreadable reading on every spawn of every Mac - a permanent false alarm that trains people to ignore the real one.

`danger-full-access` is level with how this fleet's Claude workers already launch, and is the posture the captain ruled on for this host.
It is a launch with no sandbox, so on such a host the boundaries the three crewmate grants are scoped against - the project working tree, the daemon, every other project's gate - hold only by AGENTS.md hard rule 1 and the brief's isolation assertion, exactly as they do for a Claude worker.
`approval_policy` and `approvals_reviewer` are not host-conditional and are passed exactly as configured in either case.

Three properties are deliberate:

- **The tracked `.codex/config.toml` is never rewritten.**
  It ships to hosts whose sandbox starts perfectly, and weakening it there would impose one host's kernel policy on everybody else.
  The degradation is a per-launch override on a host that fails the probe, and nothing else.
- **A probe nobody could take is not a failure.**
  It keeps the shipped sandbox and says it could not be read, because an unreadable reading must never silently buy a weaker launch.
- **The degradation is announced.**
  A weaker launch says so once on stderr, where firstmate and any later reader of the spawn output can see it.

`bin/fm-brief.sh` covers the worker's own reading of the wall: every ship brief now states, in the same breath as the isolation stop rule, that the rule forbids **skipping** the isolation check and never forbids running it outside a sandbox.
The worker that stopped on 2026-09-05 had no way to know that and needed a steer to move.

## Evidence

Both walls, and the counterfactual, measured on this host with the same prompts the regression uses.

Under `--sandbox danger-full-access`, a command runs and a file edit lands:

```
$ FM_CODEX_SANDBOX_LIVE_E2E=1 bash tests/fm-codex-sandbox-walls-live-e2e.test.sh
ok - wall 1: a shell command runs under the sandbox mode a degraded host launches with
ok - wall 2: a file edit actually lands under the sandbox mode a degraded host launches with
# all fm-codex-sandbox-walls-live-e2e tests passed
```

Under `--sandbox workspace-write` on the same host, the file edit does not land:

```
$ codex exec --skip-git-repo-check --sandbox workspace-write 'Create a file named wall2.txt ...'
Failed to write file /tmp/tmp.5YwqPt8BoL/wall2.txt
patch: failed
I couldn't create `wall2.txt` because the workspace sandbox failed to initialize
(`bwrap: No permissions to create a new namespace`). No file was written.
$ ls /tmp/tmp.5YwqPt8BoL
(empty)
```

## Coverage

- `tests/fm-spawn-dispatch-profile.test.sh` pins the launch line for all three probe results and for a Darwin host, including the host whose sandbox works keeping `workspace-write` and the tracked profile staying untouched.
  Every case in that suite pins the probe, so its `workspace-write` expectations mean "on a host whose sandbox starts" rather than "on whatever host CI ran on".
  `tests/fm-secondmate-harness.test.sh` pins it the same way, because the degradation is not kind-conditional and a secondmate launch degrades exactly as a crewmate launch does.
- `tests/fm-codex-sandbox-walls-live-e2e.test.sh` asks a real Codex on this host whether the composed mode actually clears both walls.
  It is opt-in (`FM_CODEX_SANDBOX_LIVE_E2E=1`) because it costs a model call, and it skips on a host that can sandbox, which meets neither wall.
- `tests/fm-brief.test.sh` pins the sentence the ship brief carries.
