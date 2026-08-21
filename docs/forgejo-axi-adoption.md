# forgejo-axi adoption, 2026-08-19

The captain ruled on 2026-08-19 to adopt `forgejo-axi` and contribute the gaps upstream, rather than fork it.
This record carries the licence and provenance that adoption rests on, what was and was not verified against a real Forgejo host, the contributions offered upstream, and the one thing adoption could not complete.

The measurement the ruling rests on is `data/fm-forgejo-axi-dissect/report.md`, which is private to this home.
This document does not restate it; it records what was established afterwards while making the adoption real.

**Updated 2026-08-21**, under the three conditions the closing section allows: the contributions were answered, the declaration question was answered, and the version the licence and provenance evidence describes moved.
What was true on 2026-08-19 is kept below rather than rewritten, and the new material is marked by its own date.

## 2026-08-19: provenance and licence

Every row below is what a local artefact or a named upstream pointer establishes, and nothing further.

| Field | Value | Evidence |
| --- | --- | --- |
| Package | `forgejo-axi` | `npm view forgejo-axi@1.2.0` |
| Version | `1.2.0` | same |
| Published | 2026-08-16T13:24:56.782Z | `npm view forgejo-axi time` |
| Licence | MIT | `npm view forgejo-axi@1.2.0 license` returns `MIT`; the repository's `LICENSE` at the pinned commit reads `MIT License / Copyright (c) 2026 Evelyn Scidmore` |
| Copyright holder | Evelyn Scidmore, 2026 | repository `LICENSE` at the pinned commit |
| Author field | `Evelyn Scidmore` | package metadata |
| Source | `https://github.com/escidmore/forgejo-axi` | package `repository.url` |
| Commit read | `3b28d0917eb5745eb679484a285f1d78f53db0d7`, tag `v1.2.0` | `git rev-list -n 1 v1.2.0` in a scratch clone |
| Published tarball | `sha512-7/F3/Z66JH9RnDlwY53ibDiDbmjJMtNIKdkc3X7e1o/dQiUxDWjbqvJpeVvA26wPPLQH4DhDAu4LBEjnzTA0vA==` | `npm view forgejo-axi@1.2.0 dist.integrity` |
| Runtime dependencies | `@toon-format/toon` 4.1.0, `axi-sdk-js` 0.1.9 | package metadata |
| Node requirement | `>=20` | package `engines` |

Two things are deliberately not asserted.

The published tarball was not byte-compared against the pinned commit, so the integrity hash above evidences what npm serves and not that it was built from that commit.
Nothing in either repository evidences a relationship between `forgejo-axi` and the AXI project beyond building on the published SDK and following the published skill, and the dissection already corrected the opposite assumption: the AXI contract and SDK are Kun Chen's, this tool is Evelyn Scidmore's, and they are different parties.

## 2026-08-19: what was verified against a real Forgejo, and how

The instance is the fleet's disposable test host, reporting `15.0.6+gitea-1.22.0` at `/api/v1/version`.

**The client refuses to talk to it directly, and that is the client behaving correctly.**
It declines plaintext HTTP to any non-loopback host before issuing a request, with code `INSECURE_TRANSPORT`, and names the remedy itself: forward the host to loopback.
That instance serves plain HTTP on port 4488 and answered nothing on TLS, so every verification below ran through a local TCP forward, with the client pointed at `http://127.0.0.1:4488`.
The bytes are the live server's; only the socket address differs.
Anyone repeating this should expect the same refusal and should not read it as a defect.

Verified by effect against that host, unauthenticated:

- `status` reports the server version and a probed capability map.
- `repo view`, `pr list`, `pr view`, `pr checks`, `pr merged` all return real data for the public `axitest/axi-demo` repository and its pull request 1.
- `pr checks` computed `state: success`, `passes: true` from that host's two real commit statuses against the pull request's own head SHA, which is the reading `AGENTS.md` section 7 requires and a whole-branch aggregate cannot give.

Which of the six contributions that covers, stated per contribution rather than as one blanket claim:

- Contributions 1, 2 and 3 change what the client asks a host and what it reports back, and each was run against that live host before its pull request was opened.
  For contribution 3 the exception in the next section applies: only the empty `review_decision` was reachable.
- Contributions 4 and 5 reach no host at all.
  The version fast path was measured locally against a bare-node floor, and `setup hooks` was exercised against a temporary home directory, never the real one.
  Neither has live-host evidence because neither has a live-host behaviour to have evidence about.
- Contribution 6 changes a catalogue file in a different repository and touches no code.

## 2026-08-19: what could not be verified, and why

**No Forgejo credential is reachable from this account.**
The credential for that instance was placed under another vessel's account on a shared host; nothing exists for this one, and asking another vessel to loosen its own credential store was out of scope.
Everything above is therefore read-only and unauthenticated.

Three consequences, stated rather than left to be discovered:

1. **Neither upstream live lane was run.**
   `npm run test:live -- 15` and `-- 16` require a token and mutate the repository they point at.
   Every upstream pull request says so in its own body, which is what that project's `CONTRIBUTING.md` asks for.
2. **No mutating verb was exercised against a live host by this work.**
   `pr create`, `pr update`, `pr merge`, and the whole label and issue write surface were not run here.
   The dissection records that an earlier proof did open and merge a pull request on this instance with the branch actually moving, so that evidence exists; it is not this task's.
3. **`review_decision` was exercised live only for the empty case.**
   That repository has no reviews, so `none` is the only value a live host produced.
   Every other value, including the `stale` case, rests on unit tests and fixtures.

## 2026-08-19: contributions offered upstream

The outcome of every one of these is in the 2026-08-21 section above; this section is what was true when they were sent.

All six gaps went upstream as pull requests under each project's own contribution process, none is carried as a local patch, and none had been reviewed at the time of writing.

| # | Change | Where |
| --- | --- | --- |
| 1 | `--fields` on `pr view`, `issue view`, `run view` | https://github.com/escidmore/forgejo-axi/pull/38 |
| 2 | Address a pull request by its URL as well as its number | https://github.com/escidmore/forgejo-axi/pull/39 |
| 3 | Check and review state as `pr list` fields | https://github.com/escidmore/forgejo-axi/pull/42 |
| 4 | Answer a bare version flag without loading the command graph | https://github.com/escidmore/forgejo-axi/pull/40 |
| 5 | `setup hooks` for agent session integration | https://github.com/escidmore/forgejo-axi/pull/41 |
| 6 | Catalogue entry proposing the tool | https://github.com/kunchenguid/axi/pull/150 |

Five of the six are the AXI contract's own requirements, which is the argument for contributing rather than carrying patches.

Upstream CI has not run on any of them.
GitHub holds workflow runs from a first-time contributor's fork at `action_required` until a maintainer approves them, so that approval is theirs to give and nothing here can force it.
What was done instead is to run that project's own CI gate locally on every branch: `npm ci`, `npm audit --audit-level=high`, `npm run check`, and `npm pack --dry-run` all pass on each.
That was Node 20 only, while their matrix is 20, 22 and 24, so it is not a substitute for their run.

Two of them carry a judgement the maintainers may reverse, and both are flagged in their own pull request rather than buried.
Contribution 3 deliberately keeps `--fields all` from expanding to the new per-row fields, because expanding it would silently turn an existing one-request call into one request per row.
Contribution 5 asks the SDK's own predicate whether a session hook may be installed before claiming it was, because the SDK declines silently and a thin wrapper would have reported an install that never happened.

Contribution 6 is different in kind and was handled differently.
This fleet is not the tool's author, `CONTRIBUTING.md` there says to add an entry for *your* AXI, and `VISION.md` requires an independent pinned-source admission review that a contributor's own review does not satisfy.
So that pull request proposes the entry, records the evidence and the principles that do not hold at `v1.2.0`, asserts no verdict, and the author was told about it on their own pull request so they can object.

## 2026-08-21: what upstream did with the contributions

All five code contributions were **merged** and shipped as `forgejo-axi` **1.3.0**, published 2026-08-20T10:25:41Z, four days after the ruling.

| # | Change | Pull request | Outcome |
| --- | --- | --- | --- |
| 1 | `--fields` on `pr view`, `issue view`, `run view` | https://github.com/escidmore/forgejo-axi/pull/38 | merged, in 1.3.0 |
| 2 | Address a pull request by its URL as well as its number | https://github.com/escidmore/forgejo-axi/pull/39 | merged, in 1.3.0 |
| 3 | Check and review state as `pr list` fields | https://github.com/escidmore/forgejo-axi/pull/42 | merged, in 1.3.0 |
| 4 | Answer a bare version flag without loading the command graph | https://github.com/escidmore/forgejo-axi/pull/40 | merged, in 1.3.0 |
| 5 | `setup hooks` for agent session integration | https://github.com/escidmore/forgejo-axi/pull/41 | merged, in 1.3.0 |
| 6 | Catalogue entry proposing the tool | https://github.com/kunchenguid/axi/pull/150 | **still open, one red check** |

That settles the route: contributing was cheaper than carrying patches, and nothing was forked.

**Contribution 6 is the one loose end, and its blocker is named rather than guessed.**
The catalogue maintainer reviewed it on 2026-08-19 and gave two reasons, only one of which still stands.
The first was that principle 7 was not held at the pinned `v1.2.0`; 1.3.0 holds it, and holds the version fast path they also asked for, so a re-pin answers that half.
The second is the blocking check, `PR must be raised via no-mistakes`, which their `CONTRIBUTING.md` requires and which this fleet's installed pipeline can satisfy.
Resubmitting through that gate at a `v1.3.0` pin is the whole remaining work, and it happens in a clone of *their* repository rather than in this one, so it is left as its own dispatched task rather than done sideways from here.
Nothing about it is a reason to fork.

## 2026-08-21: the six gaps, re-verified against the released version

Re-measured against 1.3.0 by running it, not by reading the release notes.
The last column is the one that decides work, and it has the same answer for every row today for one reason stated once below the table.

| Gap | State at 1.3.0 | Evidence |
| --- | --- | --- |
| **G1** no field selector on detail views | **closed** | `pr view --help`, `issue view --help`, `run view --help` all carry `--fields LIST\|all`; live: `pr view <url> --fields state,head_sha,merged` returned exactly those three fields |
| **G2** no pull-request-URL addressing | **closed** | usage is `pr view [--repo OWNER/REPO] NUMBER\|URL`; live: a full `https://.../pulls/13995` resolved. One nuance: the URL supplies owner, repository and number, **not** the base URL, which is still required from configuration or `--base-url` |
| **G3** no check or review state in a list | **closed** | `pr list --fields number,state,checks_state,checks_passes,review_decision` returned all five for real rows, with a `field_info` block naming the per-row fields, the rows fetched, and an empty failure list. `--fields all` deliberately still does **not** expand to those three, so an existing call keeps costing one request |
| **G4** `pr merge` requires `--expected-head` | **stands, by design** | `pr merge --repo o/r 1` returns `error: "--expected-head is required"`, `VALIDATION_ERROR`. This is a safety property being demanded of the caller, not a defect; a caller must resolve the head SHA before merging |
| **G5** no `--field k=v` form on `api` | **stands** | `api PATCH repos/o/r --field k=v` returns `Unknown flag --field for \`api\``, and lists the accepted flags. `--data '<json>'` is the whole write path |
| **G6** the validation pipeline has no Forgejo path | **not this client's gap, and not settled here** | a separate investigation owns it; see the boundary below |

**Does any of them block a call site this fleet actually has? No - and the honest reason is that this fleet has no Forgejo call site at all.**
GitHub is still the working surface and no call site was re-pointed by this work or the last.
So the useful form of the question is what each would cost *when* a site is re-pointed, and only two have a cost: G4 makes every merge resolve a head SHA first, which is a change to a guarded script and must be planned rather than discovered at the first merge, and G5 is a one-line rewrite of a documented operator step whose payload key also differs between the two forges.

Live evidence above was taken against `https://codeberg.org`, a public Forgejo 16 instance that needs no credential, so any reader can rerun it.
The client's own `status` reported that host as `16.0.0-dev-694-33ae492b+gitea-1.22.0` with a probed capability map.
Nothing here was run against this fleet's own forge and nothing here is authenticated.

## 2026-08-21: the second verb surface, which is larger than this fleet's own

The floor is not chosen against this fleet's scripts alone, and that matters because the larger caller is not us.
The parallel pipeline investigation established that the validation pipeline drives nine invocations of this client, of which eight are verbs this fleet's own scripts never call: `status`, `pr find`, `pr create`, `pr update`, `pr checks`, `pr mergeability`, `pr merged`, and `run view --log-failed`.

All nine were checked against 1.3.0 with the flag shapes the pipeline uses - `pr find --repo --head --base --state`, `pr create --repo --head --base --title --body`, `pr update --repo NUMBER --title --body`, `run view --repo RUN_ID --log-failed` - before the floor was set, rather than inferred from the fleet's half.
All nine are present, and presence was not treated as coverage on its own.
Two further things were checked at the floor, because a verb that exists can still fail a caller.

Every one of the nine accepts the connection flags the pipeline appends to all of them: a deliberately invalid flag on `pr merged` reports its accepted set as `--base-url, --ca-file, --help, --json, --repo, --timeout-ms, --token-env`, which contains the three the pipeline relies on.

The two response fields whose absence would decode to a zero value instead of failing loudly were read back live at 1.3.0, since those are the two the pipeline investigation named as the dangerous ones:

```
$ forgejo-axi status --json           -> capabilities.probe = {"source":"swagger","complete":true}
$ forgejo-axi pr find ... --json      -> search_info = {"complete":true,"pages":3,"fetched":130,"total":130}
```

The floor is therefore 1.3.0 for the fleet's own reasons (G1, G2 and G3 all close there) and 1.3.0 covers the pipeline's surface as well; none of the pipeline's verbs is newer than the client's 1.2.0 surface, so no pipeline verb pushed the floor up.

**What a version floor cannot cover, said plainly.**
The coupling between the pipeline and this client is a JSON shape across a process boundary, and nothing upstream pins it: the pipeline has no minimum version, no `--version` check, and its `doctor` does not look for the binary at all.
A future release that renames a field inside a version range this floor accepts would still break the decode - loudly where a strict validator catches it, silently where a missing field decodes to a zero value.
The floor buys a known-good starting point and a visible diagnostic; it does not buy shape stability, and nobody should read it as though it did.

## 2026-08-21: the declaration route, and what it deliberately does not decide

The 2026-08-19 record below closes by saying this fleet had no accepted route for depending on a third-party agent CLI, and named three choices the captain would have to make.
Only the first is answered by construction now; the second remains with the captain, and the third is moot while the second remains untaken.

**Answered: a tool is declared by being required, and the condition is a configured forge instance.**
`bin/fm-bootstrap.sh` requires `forgejo-axi` at or above the floor exactly where this home names a Forgejo instance under `config/forgejo-host` or `FM_FORGEJO_HOST`, and says nothing at all where it does not.
So nothing is declared before it is required, and no seat is told to install a client it has nothing to point at.
`docs/configuration.md` "Forge client" owns the route; `bin/fm-bootstrap.sh` owns the constants and the mechanics.

**Implemented invariant: both an agent session and the validation pipeline's daemon must run the same client.**
Those are different execution environments on this seat and the difference is not theoretical.
The pipeline's daemon is one shared unit for the whole host and pins its own `PATH`, which reaches neither the npm global prefix nor any home's vessel prefix.
So the check reads that daemon's environment, requires the same executable to resolve from both its `PATH` and the session's `PATH`, and reads the version from the executable the daemon would run - one mechanism and one install location rather than separate session-side and pipeline-side declarations.
Measured on this seat on 2026-08-21, with a 1.3.0 client on the session's own `PATH`:

```
FORGE_CLIENT: forgejo-axi is not installed where both this session and the validation pipeline can run it, and <this fleet's forge> is this home's forge (install: npm install -g --prefix /home/coditan/.local 'forgejo-axi@^1.3.0' && PATH=/home/coditan/.local/bin:$PATH forgejo-axi setup hooks)
```

A `command -v forgejo-axi` in that same session answered yes throughout.
That is the whole reason the line does not say `MISSING:`.

The considered alternative was the pipeline's own `forgejo_axi_path` configuration key, which points it at an absolute binary.
It was not taken: that key exists only in the pipeline release that carries a Forgejo path at all, which is not the one installed here, and using it would make the answer depend on a second file this fleet does not own.
Putting the binary where the daemon already looks needs no agreement from either side and stays true if that key is ever renamed.

**What a silent check does and does not mean.**
It means the same client resolves for both an agent session and the validation pipeline's daemon, and the executable the daemon would run is at or above the floor.
It does not mean the pipeline can ship to a Forgejo repository: that additionally needs a pipeline release with a Forgejo path, and a base URL and credential in the daemon's own environment, none of which this check reads and none of which are this record's to claim.

**Not answered, and left to the captain: whether a third party's package may enter the auto-updating suite boundary.**
It has not been put there.
`FM_AXI_SUITE_TOOLS` installs patch and minor releases on a cadence, and this is Evelyn Scidmore's package rather than the kunchenguid suite, so that remains a supply-chain decision rather than an inherited default - and while the client stays outside that boundary, the third question, whether its own self-updating `update` verb is acceptable inside it, does not arise.

## 2026-08-21: the risk this dependency carries

**Bus factor 1, and adopting did not change it.**
Re-measured on 2026-08-21 against the upstream repository: **zero issues, open or closed**; contributors are `escidmore` and `dependabot[bot]`; five external pull requests have now been merged, and every one of them is this fleet's.
So the only outside party that has ever exercised this project is us, which is the same exposure the dissection recorded and not an improvement on it.
The engineering discipline remains unusually high - three releases in the fourteen days to 1.2.0, a fourth four days later, a live test matrix against real Forgejo 15 and 16 hosts, and a written compatibility contract - and quality was never the risk.
The risk is that one person is the whole project, that this fleet would sit a token-holding client between itself and its own source of truth, and that if upstream goes quiet the fleet inherits maintenance it did not plan for.

Adopting makes that something to watch rather than something we own, which was the ruling's own trade.
What watching it concretely means: the client's releases are worth a look whenever the fleet's forge work moves, and a quiet upstream is a signal to re-open the fork question with the captain rather than a reason to fork quietly.

**Licence and provenance at the adopted version**, on the same evidence standard as the 2026-08-19 table:

| Field | Value | Evidence |
| --- | --- | --- |
| Version | `1.3.0` | `npm view forgejo-axi version` |
| Published | 2026-08-20T10:25:41.305Z | `npm view forgejo-axi time` |
| Licence | MIT, `Copyright (c) 2026 Evelyn Scidmore` | `npm view forgejo-axi@1.3.0 license`; the `LICENSE` file in the published tarball |
| Published tarball | `sha512-AlIw2yLxstORP1QTuUVdB1KUD59NI/yCNX4e/VyqpBGgozs7Iythu92AnDqfjhyzPN3OZyIRxENMJ8n7dhcbLQ==` | `npm view forgejo-axi@1.3.0 dist.integrity` |
| Runtime dependencies | `@toon-format/toon` 4.1.0, `axi-sdk-js` **0.1.10** | package metadata; the SDK pin moved with contribution 4 |
| Node requirement | `>=20` | package `engines` |

As on 2026-08-19, the published tarball was not byte-compared against the tagged commit, so the integrity hash evidences what npm serves and not that it was built from that tag.

## What this still does not solve

The validation pipeline installed on this seat has **no Forgejo path at all**, so a Forgejo-hosted project still cannot use the fleet's default delivery path, and adopting a client does not change that.
A separate investigation owns that question and its two captain decisions.
Nothing in this record should be read as saying a Forgejo project can be shipped through the pipeline today.

## 2026-08-19: the dependency was not declared, because no route fitted it

**Superseded on 2026-08-21: the route now exists and is described above.**
**This section is kept because it states the constraints that route had to satisfy, and those still bind.**

This was the part of adoption that could not be completed then, and it was reported rather than improvised around.

At that time this fleet declared a tool in exactly three places, and `forgejo-axi` fit none of them.

- **`COMMON_TOOLS` in `bin/fm-bootstrap.sh`**, the universal toolchain, whose single documentation owner is `docs/configuration.md` "Toolchain".
  Every entry there is *required*, and an absent one prints `MISSING:` at every session start.
  Nothing in this fleet calls `forgejo-axi`: GitHub remains the working surface on the captain's own clarification, and no call site was re-pointed by this work.
  Declaring it here would print a missing-tool diagnostic on every seat for a tool nothing uses.
- **`fm_backend_required_tools` in `bin/fm-backend.sh`**, the per-backend delta, which is the fleet's one *conditional* requirement route.
  It is keyed to the resolved runtime backend, and a forge client is not a runtime backend, so there is no condition there to hang this on.
- **`FM_AXI_SUITE_TOOLS` in `bin/fm-axi-suite.sh`**, whose own header scopes it to "the npm-distributed kunchenguid AXI CLI suite".
  `forgejo-axi` is a third party's package.
  Putting it inside that boundary would auto-install its patch and minor releases into every home on a cadence, which is a supply-chain decision rather than a declaration.
  The dissection separately noted that the SDK gives the tool a built-in `update` verb that self-upgrades from npm, which is worth a deliberate decision inside that boundary rather than an inherited default.

So the honest position is that **this fleet has no accepted route for depending on a third-party agent CLI that is not yet required by any configuration**, and inventing one inside this task would have been exactly the improvisation the dispatch forbade.

That is not a new question.
`fm-axi-nomistakes-guidance-off-argv` already asks who owns this fleet's tool suite and what the accepted route is for adding or depending on a tool, and it remains open.
This work inherits that question rather than settling it, and a dependency that lived only on this seat is not what was asked for.

What the captain would have to choose, when he takes it:

1. Whether a tool may be *declared* before it is *required*, and if so where that declaration lives.
2. Whether a third party's package may enter the auto-updating suite boundary at all, and with what review.
3. Whether `forgejo-axi`'s own `update` verb is acceptable inside that boundary or must be suppressed.

Of those three, only the first is answered above; the second remains with the captain, and the third is moot while the second remains untaken.

## Maintaining this file

This record is evidence with dated layers, not a status page: each section says what was true on the date it names, and a later layer supersedes an earlier one in place rather than rewriting it.
Add a layer only when the remaining catalogue contribution is accepted or refused, when the auto-updating-suite question is answered, when the version floor moves, or when the licence or provenance evidence itself changes.
Re-measure the bus-factor figures before repeating them; they are counts on a live repository and go stale silently.
If a Forgejo host becomes this fleet's working surface, the call-site migration is its own authorised step and belongs in its own record, not appended here.
