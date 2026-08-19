# forgejo-axi adoption, 2026-08-19

The captain ruled on 2026-08-19 to adopt `forgejo-axi` and contribute the gaps upstream, rather than fork it.
This record carries the licence and provenance that adoption rests on, what was and was not verified against a real Forgejo host, the contributions offered upstream, and the one thing adoption could not complete.

The measurement the ruling rests on is `data/fm-forgejo-axi-dissect/report.md`, which is private to this home.
This document does not restate it; it records what was established afterwards while making the adoption real.

## Provenance and licence

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

## What was verified against a real Forgejo, and how

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
- Each contributed change below was exercised against that host before its pull request was opened, except where the next section says otherwise.

## What could not be verified, and why

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

## Contributions offered upstream

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

## The dependency is not declared, because there is no route that fits it

**This is the part of adoption that could not be completed, and it is reported here rather than improvised around.**

This fleet declares a tool in exactly three places, and `forgejo-axi` fits none of them today.

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

Until then `forgejo-axi` is evaluated, contributed to, and unlisted, which is a true state rather than a half-installed one.

## Maintaining this file

This record is closed as evidence: it says what was true on 2026-08-19 and is not a status page.
Update it only when the contributions are accepted or refused, when the declaration question is answered, or when the licence or provenance evidence itself changes.
If a Forgejo host becomes this fleet's working surface, the call-site migration is its own authorised step and belongs in its own record, not appended here.
