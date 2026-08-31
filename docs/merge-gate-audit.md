# Auditing merge gates: query both mechanisms, then prove the gate

`AGENTS.md` is the merge-authority owner.
Use its "Selected delivery path and approval authority" section for the current fleet merge contract, including the dated enforcement map and its revision condition.
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

## Current fleet gate reading (2026-08-31)

This reading covers the active registered GitHub merge targets in `/home/crew/firstmate/data/projects.md` plus this repository's `origin`, `Coditan/firstmate-source`.
It excludes `heavyliftrental/hlr-tank-cad`, which the registry marks retired and not dispatchable.
Every listed repository reported `main` as its default branch through `gh-axi api repos/<repo> --jq .default_branch`.

`Coditan/firstmate-source` is enforced by a readable repository ruleset.
`GET /repos/Coditan/firstmate-source/rulesets` returned active branch ruleset `fleet-main-signoff` id `19750697`.
`GET /repos/Coditan/firstmate-source/rulesets/19750697` returned `conditions.ref_name.include: ~DEFAULT_BRANCH`, `enforcement: active`, `bypass_actors: []`, `current_user_can_bypass: never`, and a `required_status_checks` rule requiring `Repo invariants`, `Lint shell scripts`, `Test coverage guard`, `Behavior portable serial`, and `PR must be raised via no-mistakes`.
`GET /repos/Coditan/firstmate-source/branches/main/protection` returned exactly `error: "gh: Branch not protected (HTTP 404)"` and `code: UNKNOWN`, which is the expected empty classic-protection half for a ruleset-gated repository.

No registered GitHub merge target was measured as unenforced in this reading.
The remaining registered merge targets were unreadable for enforcement rather than known ungated, because both `gh-axi api repos/<repo>/rulesets --full` and `gh-axi api repos/<repo>/branches/main/protection --full` returned exactly `error: Insufficient permissions for this action` and `code: FORBIDDEN`.
The unreadable Coditan repositories were `Coditan/coditan`, `Coditan/coditan-bridge`, and `Coditan/coditan-secret-store`.
The unreadable HLR infrastructure and application repositories were `heavyliftrental/hlr-access-portal`, `heavyliftrental/hlr-adsbot`, `heavyliftrental/hlr-certsync`, `heavyliftrental/hlr-dms`, `heavyliftrental/hlr-einkauf`, `heavyliftrental/hlr-infra`, `heavyliftrental/hlr-librechat`, `heavyliftrental/hlr-odoo-interocopy`, `heavyliftrental/hlr-pim`, `heavyliftrental/hlr-reporting`, and `heavyliftrental/hlr-vat-steward`.
The unreadable HLR calculation, simulation, and spreader repositories were `heavyliftrental/hlr-calc`, `heavyliftrental/hlr-hyls-1250`, `heavyliftrental/hlr-hyls-sim`, `heavyliftrental/hlr-loadmeasuring`, `heavyliftrental/hlr-loadmeasuring-manual`, `heavyliftrental/hlr-spreader-admin`, `heavyliftrental/hlr-spreader-calc`, `heavyliftrental/hlr-spreader-core`, and `heavyliftrental/hlr-spreader-tools`.
The unreadable HLR knowledge and publishing repositories were `heavyliftrental/hlr-design-system`, `heavyliftrental/hlr-engineering-vault`, `heavyliftrental/hlr-knowledge`, `heavyliftrental/hlr-onboarding`, `heavyliftrental/hlr-presentations`, `heavyliftrental/hlr-research`, and `heavyliftrental/hlr-sling-physics`.

The merge contract therefore keeps the hand-check rule everywhere, including the enforced and unreadable repositories: before merging, read every required check against the pull request's own head commit, never a whole-branch aggregate view.
The dated map in `AGENTS.md` must be revised whenever a registered merge target moves repository, account, plan, or forge, or when either GitHub endpoint starts returning a different answer.

## Maintaining this file

Keep this file to the durable method (query both mechanisms, read `check-runs`, prove the gate) plus a dated snapshot of any fleet gate map it records.
When the fleet's gate configuration changes, update the dated snapshot rather than appending a second one, and re-run the both-endpoints survey before trusting any claim that a repository is or is not gated.
