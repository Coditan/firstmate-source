# Cross-vessel service-port registry - proposal

**Status: proposal, not binding.**
This changes a schema other vessels depend on, so it is written to be put to them through Bridge before it means anything.
Nothing in firstmate reads or writes this registry today, and nothing should be made to depend on it landing.

The vessel-local half of this work - address resolution, port allocation, the entry point, honest degradation - is implemented and needs nobody's agreement, because it is entirely local to one vessel.
See `docs/lavish-access.md`.
This document covers only the part that is shared.

## The problem

Several vessels run on one physical machine as separate UNIX accounts.
They cannot see each other's private state and cannot coordinate through it, so today they avoid each other's ports by luck.

Measured on `crew-hlr`, 2026-07-30: three UNIX accounts exist on this machine, and in the Lavish port band there were three listeners of which only one belonged to this vessel.
`lavish-axi`'s compiled-in default port 4387 was held by a different account, by something that is not an HTTP server, and another account held 4392 with an all-interfaces bind.
A vessel that assumes a fixed port on this machine is already wrong.

## Position 1: the registry is a published record, never a lock

Correctness does not depend on this registry and must not be allowed to.

No file can stop another UNIX account's process from taking a port.
A registry entry claiming a port is free would be one more instrument reporting success while being wrong, which is the failure class this whole piece of work exists to remove.
The only proof a port is available is a successful bind, and `bin/fm-service-port.sh` already treats it that way.

The registry exists so a human or an agent can see who holds what and can spot a collision after the fact.
The schema says so in its own comment, so no later reader mistakes it for an allocator.

## Position 2: the current host field cannot detect a co-host collision

`doctrine/roster.yaml` in `coditan-bridge` (schema `bridge-roster.v1`) records a `host:` per vessel:

| vessel | host |
| --- | --- |
| captain | `windows-wsl-local` |
| tugboat | `local-wsl` |
| sc1 | `local-wsl` |
| sc2 | `local-wsl` |
| hlr | `crew-hlr` |
| ak | `crew-allesknut` |
| coditan | `crew-hlr` |

Two problems, and the second is the one that settles it:

1. `local-wsl` is claimed by three vessels, so it is a label rather than an identity.
   A registry keyed on it cannot distinguish "three vessels on one machine" from "three vessels on three machines, all badly named" - which is exactly the distinction a collision report needs.
2. There is a UNIX account named `tugboat` on `crew-hlr`, while the roster places tugboat on `local-wsl`.
   That does not by itself prove the tugboat vessel runs here, and it is not asserted as proof; it does show the field cannot be trusted to answer the co-host question either way.

So the machine key has to be self-reported by each vessel from something the vessel can observe, not inherited from the current field or guessed centrally.

## Position 3: the machine key is the tailnet node name

Proposal: add `machine:`, keyed on the tailnet node name (`tailscale status --json`, `Self.HostName`).

It is already unique across the fleet, it is already how vessels reach each other, and two rows (`hlr`, `coditan`) already carry exactly that value in `host:`.
No new naming authority has to be invented, and no vessel has to be told what its machine is called.

A vessel with no tailnet writes `machine: unknown-<vessel-id>` and is excluded from co-host reasoning.
Honest degradation applies to the registry too: a machine that cannot be identified must never be silently treated as a distinct one.

## Position 4: this outlives Lavish

Any vessel-local service has this problem, so the allocator is a general mechanism that Lavish is merely the first consumer of.
The registry follows: `services:` is a list, keyed by service name, not a `lavish_port:` field.

## Proposed block

Inside the per-vessel manifest that `fleet-repo-vessel-manifests` already plans:

```yaml
# fleet/vessels/coditan.yaml (excerpt)
#
# PUBLISHED RECORD, NOT A LOCK.
# Nothing may treat these ports as reserved, and no allocator may consult this
# file to decide whether a port is free. A vessel's only proof that a port is
# available is its own successful bind. This block exists so a human or an
# agent can see who holds what, and can spot a collision after the fact.
machine: crew-hlr          # tailnet node name; the machine key
account: coditan           # UNIX account on that machine
services:
  - name: lavish
    port: 4413
    bind: tailnet          # the record's own reachability value
    observed: 2026-07-30   # when this vessel last bound it, not a claim about now
```

Each vessel reads those values straight out of its own `FM_HOME/state/service-port.<service>`, which `bin/fm-service-port.sh` already writes in exactly this shape.
That script's header is the one owner of what every field means, including the full `reachability` and `route` vocabularies and which of `addr`, `tailaddr`, and `dnsname` a consumer binds and which it links.
`reachability` describes the host and `route` describes what one run did, so a vessel reachable by proxy keeps its `bind:` value even on a run that published no route.
`untested` is one of its values and is not the same as `loopback`, which is a tested negative, so a row must record it as it stands rather than flattening it to loopback-only.
Read it there rather than inferring the set from the example above, which shows one row and not the contract.

## Migration, without central guessing

1. Add `machine:` as a new **optional** field.
   Nothing breaks; `host:` stays as a free-text human label through the transition.
2. Each vessel self-reports its own `Self.HostName` on its next push.
   No vessel writes another vessel's key, and no central pass rewrites the wrong values - they are wrong precisely because they were not self-reported.
3. A vessel with no tailnet writes `machine: unknown-<vessel-id>`.
4. Once every row carries `machine:`, `host:` is either dropped or explicitly demoted to a human comment.

## What each vessel must do

1. Run `bin/fm-service-port.sh <service>` once and read its record.
2. Add `machine:`, `account:`, and the `services:` block to its own manifest in its next fleet-repo PR.
3. Nothing else.

No coordination, no ordering, no cutover window.
A vessel that never adopts this loses the published record and keeps working, because correctness never depended on it.

## The collision check is advisory

A `fmf-`style check can report duplicate `(machine, port)` pairs as an advisory collision report.
It must never gate.
A gate would make CI depend on a record that is, by construction, allowed to be stale - and would hand a false green to whichever vessel happened to update last.

## Where it lands, and when

Inside `fleet-repo-vessel-manifests`, not beside it.
That item already plans `fleet/vessels/<name>.yaml` per vessel carrying host, account, scope, projects, harness, toolset, role, and capabilities, and already plans to move the roster into the fleet repo as the identity source with `coditan-bridge` consuming rather than owning it.
A ports block is one more declarative section of the same manifest; a parallel registry beside it would be exactly the divergence that item exists to end.

Sequencing, stated rather than buried: `fleet-repo-vessel-manifests` is `blocked-by: fleet-repo-migration`.
The vessel-local half ships independently and immediately.
This half queues behind that migration, and must not be used as an argument for accelerating it.
