# Auditing merge gates: query both mechanisms, then prove the gate

`AGENTS.md` is the merge-authority owner.
Use its "Selected delivery path and approval authority" section for the current fleet merge contract, including the temporary ungated-fleet rule and its reversal condition.
Use this document only when auditing GitHub's enforcement mechanisms or updating a dated gate snapshot after that authority changes.

A GitHub required-status-check gate that blocks merges can live in either of two independent mechanisms.
An audit that queries one mechanism gets a confidently wrong answer about the other, and that wrong answer looks exactly like a clean result.
This doc records where a fleet's gates live, which endpoints an audit must query, and how to prove a gate actually blocks.

## The two mechanisms

- **Repository rulesets** at `GET /repos/<owner>/<repo>/rulesets` (then `GET .../rulesets/<id>` for the rules).
  A ruleset gate is a `required_status_checks` rule naming one or more contexts.
- **Classic branch protection** at `GET /repos/<owner>/<repo>/branches/<branch>/protection`.
  A classic gate is the `required_status_checks` block naming contexts.

Both genuinely block merges.
Neither is a defect.
GitHub also keeps a separate control, the push restriction (`restrictions`), only in classic branch protection, with no ruleset equivalent used in this fleet, so classic protection can be present purely to restrict who may push to the branch, carrying no required check at all.

## The both-endpoints rule

An audit MUST query both endpoints and combine the answers.
The reason is a measurement trap, not a preference.

- Querying `/rulesets` on a repo gated by classic branch protection returns `[]`, which reads exactly like "no gate" on a repo whose gate is active and proven blocking.
- Querying `/branches/main/protection` on a repo gated by a ruleset returns `Branch not protected (HTTP 404)`, which also reads like "no gate".

Treat an empty `/rulesets` array as "check classic protection", never as "unprotected".
Treat a `404` from `/branches/main/protection` as "check rulesets", never as "unprotected".

A ruleset being `enforcement: active` is not by itself a gate.
Confirm the ruleset actually contains a `required_status_checks` rule naming a context.
An active ruleset with no such rule requires nothing.

## Reading the check result

The GitHub Statuses API is the wrong endpoint for GitHub Actions results.
`GET /repos/<owner>/<repo>/commits/<ref>/status` returns `total_count: 0` for Actions checks, so an audit reading Statuses concludes "no checks ran" for a repo whose checks all ran.
Actions checks report through `GET /repos/<owner>/<repo>/commits/<ref>/check-runs`, which is where `conclusion: failure` lives.

When reading a pull request's own state, note that `GET /repos/<owner>/<repo>/pulls/<n>` can return a stale `head.sha` and stale check state for a short window after a push.
Poll `check-runs` against the head SHA you pushed, read from `git rev-parse HEAD` or `git ls-remote`, rather than trusting the pull request object's cached `head.sha`.

## The bypass dimension

A gate that the person most likely to be in a hurry can step around is worth knowing about explicitly.
Query the bypass posture of every gate, on whichever mechanism holds it.

- Ruleset: read `bypass_actors` and `current_user_can_bypass` on the ruleset.
  `bypass_actors: []` with `current_user_can_bypass: never` means no one, including an administrator, can merge past the required check.
- Classic branch protection: read `enforce_admins`.
  `enforce_admins.enabled: false` means an administrator can step around every protection on the branch, including the required check and the push restriction.

The two mechanisms differ here in a way that matters.
A ruleset with no bypass actors cannot be walked through by an administrator.
Classic branch protection with `enforce_admins: false` can.
So moving a required check from classic protection into a no-bypass ruleset closes the administrator bypass on that check as a side effect, and the change should be disclosed as such rather than treated as invisible.

## Proving a gate

A gate is not proven by reading its configuration.
A configuration that reads correct is exactly the evidence class that hides a gate which no longer blocks.
Prove a required-check gate by breaking a real invariant and watching the gate refuse the merge, then restoring it and watching the gate clear.

1. On a throwaway branch, change a source file so a genuine regression test fails, not a fabricated `assert False`.
2. Open a pull request and poll `check-runs` on its head until the required check reaches `conclusion: failure`.
3. Confirm the merge is refused by reading `mergeable_state: blocked` on the pull request.
   Do not call the merge endpoint to "test" this; a blocked `mergeable_state` with a red required check is the refusal, and calling merge risks landing it.
4. Restore the invariant, push, and poll `check-runs` on the new head until `conclusion: success` and `mergeable_state: clean`.
5. Close the pull request without merging, then delete its remote branch explicitly.
   `gh pr close --delete-branch` (and the `gh-axi` wrapper) accepts the flag but does not delete the remote branch, so run `git push origin --delete <branch>` and confirm `GET /repos/<owner>/<repo>/branches/<branch>` returns `404`.

## Historical heavyliftrental fleet state (2026-08-05)

On 2026-08-05, thirteen fleet repositories carried a required-check merge gate: `hlr-certsync`, `hlr-vat-steward`, `hlr-adsbot`, `hlr-einkauf`, `hlr-engineering-vault`, `hlr-knowledge`, `hlr-infra`, `hlr-librechat`, `hlr-tank-cad`, `hlr-reporting`, `hlr-dms`, `hlr-pim`, and `hlr-research`.

The chosen fleet standard for the required-check gate was the repository ruleset with no bypass actors.
The reasons are that twelve of the thirteen were already there, that rulesets are the newer mechanism, that the admiralty branch-protection doctrine already prescribes a ruleset with no bypass actors (see [admiralty-fleet-repo.md](admiralty-fleet-repo.md)), and that a no-bypass ruleset closes the administrator walk-through that classic protection leaves open.

`hlr-research` was the one repository on the classic path.
The reason was a rollout artifact, not a property of the repository: during the 2026-08-04 rollout a ruleset could not be activated until its workflow had already run on `main` and produced its check, or the repository would lock (the `hlr-reporting` bootstrap deadlock), and `hlr-research` correctly refused to activate until its `pr-tests.yml` existed on `main`.
By 2026-08-05 that workflow existed on `main` and produced the `Research regression tests` check on every pull request, so the blocker was gone and the classic path was no longer required.

On 2026-08-05 `hlr-research` was converted:
its required-check gate then lived in ruleset `Research required PR tests` (id `20456354`), with `strict_required_status_checks_policy: true`, context `Research regression tests`, `bypass_actors: []`, `current_user_can_bypass: never`, matching the other twelve.
Its classic branch protection was reduced to the push restriction only (`restrictions.users: [Freudator86]`, no required check), matching the ten peers that keep a push restriction.
The gate was re-proven after conversion: a broken WLL-classification invariant drove `Research regression tests` to `conclusion: failure` and the pull request to `mergeable_state: blocked`; restoring the invariant drove the check to `conclusion: success` and the pull request to `mergeable_state: clean`; the throwaway pull request was closed unmerged and its branch deleted and confirmed `404`.

After that 2026-08-05 change, the required-check gate was uniformly on rulesets for all thirteen, so a required-check-only audit had a single home in that snapshot.
The both-endpoints rule still stands, for two durable reasons:
a push restriction lives only in classic branch protection and exists on ten of the thirteen repositories (`hlr-certsync`, `hlr-engineering-vault`, and `hlr-knowledge` have no classic protection at all), and a repository added before its ruleset is safe to activate will sit on classic protection exactly as `hlr-research` and `hlr-reporting` did during rollout.

### Where each control lived, and which endpoint answered for it

| Control | Mechanism | Endpoint to query |
| --- | --- | --- |
| Required-check merge gate (all 13) | Repository ruleset | `/repos/<r>/rulesets` then `/rulesets/<id>` |
| Push restriction (10 of 13) | Classic branch protection | `/repos/<r>/branches/main/protection` |
| Actions check result on a commit | Checks API | `/repos/<r>/commits/<ref>/check-runs` |

### Bypass picture

- At the time, all thirteen required-check ruleset gates: `bypass_actors: []`, `current_user_can_bypass: never`.
  No one, including the administrator, could merge past a red required check.
- The ten classic push restrictions: `enforce_admins.enabled: false`.
  An administrator can push directly to `main`, stepping around the push restriction.
  In that single-maintainer snapshot the sole administrator (`Freudator86`) was also the sole user the push restriction allowed, so the bypass granted that user nothing extra; it would matter if another administrator were added.
- Before conversion, `hlr-research`'s required check sat in classic protection with `enforce_admins: false`, so it was administrator-bypassable, unlike the other twelve.
  The conversion to a no-bypass ruleset closed that one hole and is the only bypass state this task changed.

Whether to set `enforce_admins: true` on the ten push restrictions is a separate decision, deliberately not taken here, and is recorded so it can be decided rather than discovered later.

## Maintaining this file

Keep this file to the durable method (query both mechanisms, read `check-runs`, prove the gate) plus a dated snapshot of any fleet gate map it records.
When the fleet's gate configuration changes, update the dated snapshot rather than appending a second one, and re-run the both-endpoints survey before trusting any claim that a repository is or is not gated.
