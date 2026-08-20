# Codex sandbox network dimension and the no-mistakes daemon socket

Why a Codex crewmate carries `sandbox_workspace_write.network_access=true` on its launch line, what that grant admits, and why it is not written into the tracked Codex profile.
Codex status-file filesystem signalling is a separate launch-line grant documented in [`docs/codex-status-signalling.md`](codex-status-signalling.md).

All measurements below were taken on 2026-08-10 against `codex-cli 0.145.0` (`codex --version`), installed standalone at `/home/coditan/.codex/packages/standalone/releases/0.145.0-x86_64-unknown-linux-musl`.
This is a verification record: it states what was run and what came back, and it marks the one claim that is inferred rather than measured.

The probe used throughout is a two-line AF_UNIX connect to the local no-mistakes daemon socket at `/home/coditan/.no-mistakes/socket`:

```python
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect("/home/coditan/.no-mistakes/socket")
    print("CONNECT OK")
except OSError as e:
    print("CONNECT FAIL", e)
```

## 1. The refusal is on the network dimension, not the filesystem one

Codex classes a unix-socket connect as NETWORK access.
A crewmate under a plain workspace-write sandbox is therefore refused the daemon socket, and every Codex-dispatched no-mistakes ship task stalls at the gate.

```
$ codex sandbox -c sandbox_mode='"workspace-write"' -- python3 probe.py
CONNECT FAIL [Errno 1] Operation not permitted

$ codex sandbox -c sandbox_mode='"workspace-write"' -c sandbox_workspace_write.network_access=true -- python3 probe.py
CONNECT OK
```

That a filesystem-shaped grant does not help - neither `writable_roots` naming the no-mistakes directory nor `danger-full-access` being an acceptable route - was established by the experiment that opened this work and is not re-derived here.
`danger-full-access` and `--dangerously-bypass-approvals-and-sandbox` are not used by any firstmate launch path, and `tests/fm-spawn-dispatch-profile.test.sh` asserts their absence from the composed Codex launch.

## 2. Codex 0.145.0 cannot scope the grant more narrowly than the whole dimension

This was checked against the installed binary rather than against documentation for another version.

A negative `-c` probe proves nothing on its own, because this version silently ignores an unknown override key:

```
$ codex sandbox -c sandbox_mode='"workspace-write"' -c sandbox_workspace_write.definitely_bogus_key=true -- python3 probe.py
CONNECT FAIL [Errno 1] Operation not permitted
```

So the schema in the binary is the evidence, and it closes every candidate:

- `sandbox_workspace_write` carries exactly `writable_roots`, `network_access`, `exclude_tmpdir_env_var`, and `exclude_slash_tmp`.
  There is no socket, host, or port field to scope.
- The permission-profile route reduces to the same boolean: `struct NetworkPermissions with 1 element`, that element being `enabled`.
- `default_permissions` is a string naming a profile, not an inline table - `-c default_permissions.network.enabled=true` returns `Error: invalid type: map, expected a string in \`default_permissions\``.
- The only socket- and host-scoping keys in the binary - `allow_unix_sockets`, `dangerously_allow_all_unix_sockets`, `denied_domains`, `managed_allowed_domains_only` - belong to `RawNetworkRequirementsToml`, which is reached through `/etc/codex/managed_config.toml`.
  That is a machine-wide administrative policy layer constraining what a user may select, not a per-spawn grant, and `/etc/codex` does not exist on this machine.

The conclusion is that the grant available to a launch command is the whole network dimension or nothing.

## 3. What the whole-dimension grant admits

It admits general outbound network from the crewmate, not only the local pipeline socket.

```
$ codex sandbox -c sandbox_mode='"workspace-write"' -c sandbox_workspace_write.network_access=true \
    -- bash -c 'curl -s -o /dev/null -w "example.com HTTP %{http_code}\n" --max-time 15 https://example.com'
example.com HTTP 200

$ codex sandbox -c sandbox_mode='"workspace-write"' \
    -- bash -c 'curl -s -o /dev/null -w "example.com HTTP %{http_code}\n" --max-time 15 https://example.com; echo "exit=$?"'
example.com HTTP 000
exit=6
```

A Codex crewmate can therefore reach the public internet, where before it could not.
It keeps every other configured boundary: the sandbox stays `workspace-write`, so writes remain confined to its own worktree, and `approval_policy = "on-request"` remains unchanged.
This is the captain-authorised trade of 2026-08-10, taken because the alternative is that the fleet's heaviest class of work cannot leave the expensive provider.

## 4. The grant works from a real Codex worker, not just from `codex sandbox`

Run with exactly the override set `bin/fm-spawn.sh` composes for a Codex ship task, with this repository's own `.codex/config.toml` stashed so the grant could only come from the launch line:

```
$ codex exec --skip-git-repo-check \
    -c sandbox_mode='"workspace-write"' -c approval_policy='"on-request"' \
    -c approvals_reviewer='"auto_review"' -c sandbox_workspace_write.network_access=true \
    "Run the single command: python3 .fm-probe.py . Reply with only the exact line it printed."
CONNECT OK

$ codex exec --skip-git-repo-check \
    -c sandbox_mode='"workspace-write"' -c approval_policy='"on-request"' \
    -c approvals_reviewer='"auto_review"' \
    "Run the single command: python3 .fm-probe.py . Reply with only the exact line it printed. Do not retry or escalate."
CONNECT FAIL [Errno 1] Operation not permitted
```

The agent itself ran the connect through its own shell tool and reported the line back, so this is the reading a spawned crewmate gets rather than an assertion about one.

## 5. Why the grant is not written into the tracked `.codex/config.toml`

Codex reads this repository's own `.codex/config.toml` as configuration for a Codex session running inside it.
Toggling only the `sandbox_workspace_write.network_access` line in that file, with no CLI grant at all, flips the probe deterministically:

```
$ cd <the firstmate worktree>
# .codex/config.toml WITHOUT the line, three consecutive runs
codex sandbox -c sandbox_mode='"workspace-write"' -- python3 probe.py
  1 -> CONNECT FAIL [Errno 1] Operation not permitted
  2 -> CONNECT FAIL [Errno 1] Operation not permitted
  3 -> CONNECT FAIL [Errno 1] Operation not permitted
# .codex/config.toml WITH the line, three consecutive runs
  1 -> CONNECT OK
  2 -> CONNECT OK
  3 -> CONNECT OK
# the same file content, renamed away from config.toml
$ mv .codex/config.toml .codex/config.toml.bak && codex sandbox -c sandbox_mode='"workspace-write"' -- python3 probe.py
CONNECT FAIL [Errno 1] Operation not permitted
```

Twelve alternating runs held perfectly, and the rename is the negative control that identifies the file by name rather than by anything else in `.codex/`.
So a grant placed in that file would reach every Codex session whose working directory is inside this repository, including a supervising firstmate session and any Codex worker on a firstmate-repo task, no matter how the launch path gates it.
That is why `bin/fm-spawn.sh` emits the flag on the launch line and `tests/fm-spawn-dispatch-profile.test.sh` asserts the tracked profile does not carry it.

One part of this is inferred rather than measured.
A freshly created scratch git repository carrying an identical `.codex/config.toml` does NOT reproduce the effect, so some project-registration or trust condition gates it; this worktree's git root resolves to `/home/coditan/coditan-firstmate/projects/firstmate-fork`, which the operator's Codex config records with `trust_level = "trusted"` and whose `.codex/hooks.json` entries Codex has already registered.
Isolating that condition exactly would have required writing to the operator's own Codex configuration, which is outside the task worktree, so it was not done.
The placement decision does not depend on the missing detail: the behaviour is reproduced in the repository the decision is about, which is the repository whose profile would have carried the grant.

## 6. Scope of the grant in firstmate

`bin/fm-spawn.sh` owns the composition and is the authority on the exact flags.

- A Codex ship or scout crewmate gets the grant, because it is the one that runs the pipeline and needs the daemon socket.
- A Codex secondmate does not.
  A secondmate is a supervising firstmate home: it routes work rather than running the pipeline, and its own crewmates receive the grant from its own call into the same path.
- The supervising primary session never receives it, because `fm-spawn` only ever composes launch commands for direct reports.
- No other harness is affected.
  The grant lives entirely in the Codex branch of the composition, and a Claude launch line is byte-identical to what it was before.

## 7. The pipeline client reaches the daemon, measured 2026-08-11

Sections 1 to 4 prove a raw AF_UNIX connect.
This section proves the thing the grant exists for: the `no-mistakes` client itself completing a daemon round trip from inside the sandbox.
Measured against `no-mistakes` v1.45.4 and `codex-cli 0.145.0`, in a task worktree, with the same override set `bin/fm-spawn.sh` composes for a Codex crewmate.

```
# without the grant
$ codex sandbox -c sandbox_mode='"workspace-write"' -c approval_policy='"on-request"' \
    -c approvals_reviewer='"auto_review"' -- no-mistakes status
  daemon:  ○ stopped

# with the grant, same worktree, seconds apart
$ codex sandbox -c sandbox_mode='"workspace-write"' -c approval_policy='"on-request"' \
    -c approvals_reviewer='"auto_review"' -c sandbox_workspace_write.network_access=true \
    -- no-mistakes status
  daemon:  ● running

# outside the sandbox, as the same user, as the control
$ no-mistakes status
  daemon:  ● running
```

The daemon was running throughout, so `stopped` is the refusal, not the daemon's state.
The socket itself was confirmed the same day from a real `codex exec` worker carrying the full crewmate profile, which reported `PROBE3 socket OK`, so the granted dimension does not rest on the `codex sandbox` reading alone.

That reading is the hazard worth carrying out of this section.
A Codex crewmate denied the socket is not told it was denied: the client reports the shared daemon as **stopped** rather than surfacing the `EPERM` that section 1 shows at the raw socket layer.
A worker that believes the daemon is down is one step from trying to start or reset it, and that daemon is a single shared instance serving every lane and home, so acting on the misreading would disrupt other lanes' in-flight runs.
Anyone diagnosing a Codex worker that reports the daemon stopped should suspect this grant before touching the daemon.

## 8. The grant reaches a home only when that home's own copy carries it

`bin/fm-spawn.sh` composes the launch line, so a firstmate home grants the socket only once its own copy of that script includes it.
A home running an older vendored or unsynced copy keeps composing the pre-grant launch line and keeps measuring the original refusal, no matter what this repository's default branch holds.
That is a deployment fact rather than a defect, and it is recorded here because the symptom is indistinguishable from the fix being absent: the worker fails exactly as it did before.
Check the spawning home's own `bin/fm-spawn.sh` for the grant before concluding the change is missing or ineffective.

## 9. What the grant does not cover

The network grant covers the network dimension and nothing else.
A separate per-task signal writable root is documented in [`docs/codex-status-signalling.md`](codex-status-signalling.md), with completion-gate attestation evidence owned by [`docs/codex-completion-gate.md`](codex-completion-gate.md).
A pipeline run also writes in two places outside the workspace, and the sandbox refuses both.
Measured 2026-08-11 from a real `codex exec` worker carrying the full crewmate profile, network grant included:

```
PROBE1 common-dir-write REFUSED   # the git common dir of a linked worktree
PROBE2 gate-write REFUSED         # /home/coditan/.no-mistakes/repos/<hash>.git
PROBE3 socket OK                  # the granted dimension
```

The gate-repository refusal is load-bearing, because it stops a Codex-driven pipeline one step past the socket.
Starting a run from a Codex worker the same day reached the daemon, cleared intent handling, and then failed:

```
push "<branch>" to gate: exit status 1: error: remote unpack failed: unable to create temporary object directory
 ! [remote rejected] HEAD -> <branch> (unpacker error)
error: failed to push some refs to '/home/coditan/.no-mistakes/repos/<hash>.git'
```

The gate repository itself was healthy, so this is not a broken gate.
Another lane's run pushed to that same repository successfully the same day, and the directory is owned and writable by the same user.
The refusal is the sandbox.

So the grant is necessary but not sufficient for an end-to-end Codex pipeline run.
Closing that gap would need `writable_roots` extended to cover the no-mistakes data directory, which is a second confinement dimension on the filesystem axis rather than a wider setting of this one.
That is a separate captain decision, and it is deliberately not taken here.

An earlier draft of this section inferred that the approval path, `approval_policy = "on-request"` with `approvals_reviewer = "auto_review"`, is what clears such a filesystem refusal, reasoning from the fact that Codex crewmates do commit in this linked-worktree layout.
The run above is evidence against that inference for the gate push: the worker had both settings available, did not escalate, and returned the error.
How a Codex crewmate nevertheless commits here is therefore unexplained rather than settled, and the next reader should treat it as an open question rather than a mechanism to rely on.

One instrument limit remains.
`codex sandbox` and `codex exec` are both weaker instruments than the interactive `codex` session `bin/fm-spawn.sh` actually launches, so a refusal measured through them may still understate what a real crewmate achieves.
