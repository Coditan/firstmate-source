---
name: axi-tool-intake
description: >-
  This fleet's four rules for acquiring an agent-ergonomic CLI, carrying no design guidance of its own - the `axi` skill owns the design contract in full and this one never restates it.
  Use before filing, scoping, or briefing work that would build, adopt, derive, or extend such a tool for this fleet, and before telling the captain that none exists for a domain.
  Covers checking both indexes because they disagree, the credential rule, the licence and provenance rules for deriving from someone else's tool, and the open question of how a finished tool reaches every seat rather than one.
user-invocable: false
metadata:
  internal: true
---

# axi-tool-intake

**This skill contains no design guidance and never will.**
The `axi` skill in this repo owns the AXI contract in full - all ten principles, worked examples, and the `--version` fast path - and it is vendored verbatim from upstream, so nothing here may restate, summarize, or paraphrase it.
Load `axi` for how a tool should behave; load this for what this fleet does before and around building one.
`docs/axi-skill-provenance.md` records where that skill came from and carries its licence notice.

Verified 2026-08-19 against its text: the AXI specification covers none of the four rules below.

## 1. Check both indexes before building, and state which you checked

This is the first step, before any design work and before a build task is filed at all.

There are two indexes and **neither is a superset of the other**, so check both:

- The **axi.md catalogue**: `catalog.yaml` in <https://github.com/kunchenguid/axi>, which the published catalogue page is generated from.
- The **package registry**, by exact name first: `npm view <domain>-axi`, then `npm search <domain>` for tools not named to the pattern.

Also check this home's own installed set under `.local/axi/bin` and the self-updating list in `bin/fm-axi-suite.sh`, since a tool the fleet already carries is the cheapest answer of all.
A forge repository search for `<domain>-axi` is a useful third pass when both indexes come back empty.

Then **state the result and name which indexes you checked, in the record that drives the decision.**
"Absent from the catalogue and absent from npm, checked <date>" is a finding and belongs in the task note exactly as much as "one exists and covers two thirds of what we call".
An unrecorded search is indistinguishable from no search, and a result that does not say what was searched cannot be re-checked later.

### Why one index is not enough, measured 2026-08-19

The two indexes disagree in **both** directions:

- `forgejo-axi` is on npm at 1.2.0 and is **not** in the axi.md catalogue.
- `docker-axi` and `jj-axi` are **in** the axi.md catalogue and return a flat 404 on npm under those names.

So checking one index and finding nothing proves nothing at all.

Absence from the catalogue means only that nobody added an entry to `catalog.yaml`.
It is not evidence that a tool is unofficial, unmaintained, or unsuitable: `forgejo-axi` is MIT, at its third release, and absent purely because no one filed the pull request.

### What it cost, both directions

- A task to write a Forgejo client was filed 2026-08-17, when `forgejo-axi` 1.0.0 had been on npm since 2026-08-03, fourteen days earlier, reaching 1.2.0 on 2026-08-16.
  Nobody looked.
- The same day, a plan said "adopt sc1's archive tool, do not rebuild" - and that tool had never been persisted at all.
  That is the opposite error, from the same missing habit.

This fleet's own note recorded the Forgejo miss as one day late; the registry says fourteen, and the registry is the authority.

### A tool's description is not its coverage

Never decide build, adopt, or derive from a candidate's one-sentence description.
Enumerate the verbs this fleet actually calls - grep the real call sites, do not recall them - then check each against the candidate's own `--help` output, and report the delta as a number before the decision is made.

`forgejo-axi` describes itself around pull request lifecycles and in fact also carries issues, labels, and a raw `api` path, while omitting review submission entirely.
It was both narrower and wider than its own sentence, in ways that only an enumeration surfaces.

## 2. Credentials: this fleet's rule, not the specification's

The AXI specification is silent on secret handling.
This fleet is not, and a tool built or derived here carries this rule regardless:

- **A credential is never accepted as a value on the command line and never emitted.**
  Resolve it from an environment variable or a configuration file inside the process.
- **A credential is verified by its effect** - a successful authenticated read - never by displaying it.

`forgejo-axi` already does exactly this, so it is a worked example rather than a theory.

An argument value is readable by any account on the host through the process listing; `fm-axi-nomistakes-guidance-off-argv` in the backlog is this fleet's own live instance of that defect.
Load `secrets-handling` for the mechanics; this section states only that the rule binds tools we build, and does not restate it.

## 3. Deriving from an existing tool

When the decision is to start from someone else's tool rather than from nothing:

- **Read the actual licence file of that specific upstream.**
  Do not infer it from the ecosystem, from a sibling project, or from the catalogue.
  This fleet shipped a fix on 2026-08-19 for exactly this defect: licensing asserted beyond what was evidenced.
- **The copyright notice travels with the derived work.**
  MIT requires it, and a derivation that drops it is broken in a way nothing at runtime will ever reveal.
- **The provenance record names the upstream, its version, its commit, and what changed.**
  A derivation whose parent cannot be identified cannot be updated when the parent fixes something.

Build on `packages/axi-sdk-js` from the AXI repository rather than hand-rolling the contract's primitives.
It is MIT and maintained, and a hand-written copy of what it already provides drifts the first time the specification moves.

## 4. How a finished tool reaches every seat - OPEN

Publishing to the public catalogue is a solved question, and not this one: it is a pull request adding one entry to `catalog.yaml`, with the generated tables regenerated in the same commit, per `CONTRIBUTING.md` in <https://github.com/kunchenguid/axi>.
Read that procedure there rather than from memory.

**How a tool reaches every seat in this fleet has no settled answer, and inventing one is worse than naming the gap.**

Who owns this fleet's AXI suite, and what the accepted route is for adding a tool to it, remains tracked as `fm-axi-nomistakes-guidance-off-argv`.
`fleet-forgejo-axi` settled the separate adopt-or-fork question for `forgejo-axi`; [`docs/forgejo-axi-adoption.md`](../../../docs/forgejo-axi-adoption.md) owns that ruling and the unresolved declaration question it inherited.

Two things follow while it is open.
A tool that exists only on the seat that built it is not what was asked for, so "it works here" is not a completed deliverable.
And the route out - upstream contribution, fleet-local package, vendored copy - is a captain decision, not a builder's; escalate it rather than choosing by default.
