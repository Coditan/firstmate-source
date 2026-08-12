# Panel selection and validation: the rule behind five separate repairs

Five defects were found in `bin/fm-model-panel.sh` and `bin/fm-dispatch-select.sh` in one evening, each by a fresh reviewer, each patched alone.
Patched alone, each looked like a different mistake.
This document states the one rule they all break, the invariants that rule implies, and what still holds or does not hold at this checkout.

Subject boundary: `bin/fm-model-panel.sh` role resolution (`role_spec`, `filter_spec`, `resolve_role`, the configured-model-identity logic), the shared selector `bin/fm-dispatch-select.sh`, their tests, and their documentation.
Nothing outside role resolution and profile selection is in scope here.

## The rule

Resolving a panel seat is a pipeline with three stages that answer three different questions.

1. **Validate**: is every candidate this seat was configured with a legal dispatch profile?
2. **Filter**: which of those candidates does the panel prefer, given the model identities the panel has already spent?
3. **Select**: which one of the remaining candidates does this seat actually run?

All five defects are the same mistake made at five different joints:

> **A stage did work that belonged to another stage.**
> It narrowed the set the next stage was supposed to judge, changed the shape the next stage contracts on, enforced a prerequisite of a stage that had not been reached, or described an ordering that the code did not run.

Stated as the rule the code must hold:

> Each stage sees exactly its own concern, in one fixed order, for every seat.
> No stage may pre-empt, widen, reshape, or borrow the prerequisites of another, and the documentation states the order the code actually runs.

That is why they arrived one at a time.
A reviewer looking at one joint sees a local error and fixes it locally; the rule is only visible across joints, and each local fix leaves the next joint intact.

## The invariants

These are the properties the code must hold, derived from the rule.
Each is stated so it can fail visibly.

**I1 - One pipeline, one order, every seat.**
`analyst_a`, `analyst_b`, the judge, and both reduced-form seats resolve through the same three stages in the same order: validate, then filter, then select.
No seat may silently accept a candidate another seat rejects.

**I2 - Validation is total over the configured candidate set.**
The shared selector validates every candidate the seat was configured with, before any panel-local narrowing.
One invalid candidate invalidates the whole seat, with the seat named, rather than being quietly filtered out of the set the operator would have been told about.

**I3 - The filter narrows; it never reshapes.**
Panel-local identity preference may remove candidates from a set.
It may not turn a single profile object into an array, and it may not hand the select stage an empty set.
When it would remove everything, the configured set stands and the seat's own refusal or warning is what speaks.

**I4 - One candidate resolves to itself.**
Whenever exactly one candidate remains for a seat - because the seat was configured as one profile object, or because the identity filter left one survivor - that profile is the resolution.
No quota lookup and no randomness run when there is nothing to choose between.

**I5 - A stage's prerequisites belong to that stage.**
No resolution path may require a host utility it does not use.
`od` backs OS-backed random selection, so only a path that actually reaches random selection may require it.

**I6 - Documentation is checked against the artifact, not against memory.**
A documented sentence about this pipeline that the code contradicts is a defect of the same severity as a code bug, and is resolved the same way.
The ordering in I1 is documented where the pipeline lives, not only in the configuration reference.

## Status of the five described defects at this checkout

Checkout: `12d7169` (merge of PR #94), branch `gnhf/you-work-unattended-17ac1f`.
Both suites pass at this checkout before any change in this run.

**(1) An analyst array could randomly refuse instead of preferring a pinned candidate. DOES NOT REPRODUCE.**
`resolve_role` filters an array-backed seat to candidates with a known configured identity outside the exclusion list, and uses the filtered set whenever it is non-empty.
Pinned by `test_analyst_a_array_prefers_a_pinned_identity` and `test_judge_array_prefers_a_known_unused_identity_over_unpinned_default`.

**(2) Identity filtering ran before shared-selector validation. DOES NOT REPRODUCE.**
`resolve_role` invokes the selector with `--validate-only` on the configured spec before it filters.
Pinned by `test_invalid_array_candidate_refuses_in_every_seat`, which drives all three seats.

**(3) Documentation claimed there was no second selector invocation. DOES NOT REPRODUCE in `docs/configuration.md`.**
That file now states that role resolution invokes the shared selector twice, first with `--validate-only` and then to select from the identity-preferred subset.
It is however NOT stated in `bin/fm-model-panel.sh`'s own header, which owns this pipeline and currently describes only that "every role resolves through `bin/fm-dispatch-select.sh`".
I6 is therefore only half held: the ordering is documented in the configuration reference and absent from the script that runs it.

**(4) `filter_spec` coerces a pinned single-object role into an array. PARTIALLY REPRODUCES, in a different place than described.**
The coercion `if type == "array" then . else [.] end` is still inside `filter_spec`, but `resolve_role` now calls it only when the configured spec is an array, so a seat configured as one profile object is no longer coerced.
That path is pinned by `test_pinned_object_lineup_needs_no_random_source`.
What still reproduces is the same violation of I4 one step later: when the identity filter leaves exactly ONE survivor, that survivor is handed to the selector as a one-element ARRAY, which is array semantics - quota lookup, then random selection among the winners.

Reproduction, mixed analyst-A array (one unpinned candidate, one pinned) with an unreadable random source:

```
FM_DISPATCH_RANDOM_SOURCE=/nonexistent bin/fm-model-panel.sh start --dry-run "..."
error: panel role analyst_a could not be resolved:
error: OS-backed random source is unavailable
```

There is nothing to choose between, and the seat refuses.

**(5) Validation required the `od` utility before validating anything. DOES NOT REPRODUCE for validation; REPRODUCES for resolution.**
`bin/fm-dispatch-select.sh` checks `od` after the validation block and after `--validate-only` exits, which is what `test_validate_only_does_not_require_od` pins.
The check is still a global prerequisite of the whole selection path, ahead of the branch that returns a single profile object without ever randomizing.
So a fully pinned three-object panel lineup - the configuration the documentation calls correct - cannot resolve on a host without `od`:

```
PATH=<no od> bin/fm-model-panel.sh start --dry-run "..."
error: panel role analyst_a could not be resolved:
error: od is required for OS-backed random selection
```

That violates I5 exactly as the original defect did, one branch further down.

## What this run changed

Two live violations, each pinned by a test written to fail before its change and pass after.

- **I4** is enforced in `resolve_role`: a set narrowed to one candidate is unwrapped to that profile before selection, so a seat with nothing left to choose between never enters quota lookup or random selection.
  Pinned by `test_single_surviving_candidate_resolves_to_itself` in `tests/fm-model-panel.test.sh`, which drives the mixed analyst-A array with an unreadable random source and a quota command that records being called, and asserts the resolved profile, no random-source failure, and no quota call.
  Verified failing before the change with `error: OS-backed random source is unavailable`.
- **I5** is enforced in `bin/fm-dispatch-select.sh`: `od` is checked immediately before each path that randomizes, rather than once globally ahead of the branch that returns a single profile object.
  Pinned by `test_od_is_required_only_where_selection_randomizes` in `tests/fm-dispatch-select.test.sh`, which asserts that a single profile object resolves with no `od` on `PATH` and that a multi-candidate array still exits 2 naming `od`.
  Verified failing before the change with `expected exit 0, got 2`.

And the documentation repair:

- **I6**: `bin/fm-model-panel.sh`'s header now states the validate/filter/select ordering it runs, including the one-candidate rule and that a stage's prerequisites belong to that stage.
  `docs/configuration.md` states the same ordering and names the script header as its owner, so the two agree and neither is the only place it is written.

I1, I2 and I3 hold at this checkout and are already pinned by the existing tests named above; this run adds no test for them because a test that passes before and after pins nothing new.
Both suites pass after these changes, and `bin/fm-lint.sh` is clean.

## Observations recorded rather than fixed

These are real and in subject, but they are not among the five, and fixing them would be hunting a sixth defect rather than establishing the rule.

**A role configured as a rule object skips identity preference entirely.**
`docs/configuration.md` defines a role's value as one profile object or a non-empty array of them.
`bin/fm-dispatch-select.sh` additionally accepts a rule object with a `use` key, and `resolve_role` tests the configured spec's own type, so a role written as `{"use": [...]}` resolves and selects but never has the panel's identity preference applied to its candidates.
Every seat behaves identically here, so I1 holds; the gap is that the panel accepts a shape wider than the one it documents.
Recorded, not changed.

**`filter_spec`'s object coercion is unreachable but still present.**
It is guarded by `resolve_role`'s array test rather than removed, so the trap that produced defect (4) still sits in the function.
Removing it safely means either an unreachable loud assertion, which cannot be pinned by a behavioural test, or moving the array decision into `filter_spec` itself, which is a restructure of the seam between the two functions.
Recorded, not changed; I4's enforcement above is what makes the live path correct regardless.

**One-element arrays remain quota-aware at the SELECTOR.**
`test_single_profile_and_one_element_array` asserts that `bin/fm-dispatch-select.sh` given a literal `[{...}]` invokes quota-axi and logs a random-fallback basis.
That is the selector's own documented contract and this run does not weaken it.
I4 is therefore enforced in the panel, which is the layer that knows a seat has one candidate left: the panel hands the selector a profile object rather than a one-element array.
