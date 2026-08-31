---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
   The one standing exception is the class in "Claims that outrun what the run measured" below, which the captain made standing on 2026-08-31.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
7. Examine the causal theme across prior findings and fix rounds.
   Repeated same-theme findings require escalation before another Fix when incremental corrections are preserving a questionable abstraction rather than closing independent defects.
8. Apply the existing stronger captain boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless of whether they also expand the contract.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Claims that outrun what the run measured

A message, comment, help text, or document sentence that asserts more than its own run measured is a defect in the same class as a wrong result, because a reader acts on it.
By firstmate's own count in this fleet's decision records for 2026-08-31, the captain was asked to rule on that class six times that day and gave the same answer each time, so he made the answer standing rather than pay a decision per instance.

Bringing such a sentence back to what was measured is a correction inside accepted intent, not a question about it.
It does not reach the captain under either `yolo` posture, and it is covered only when the correction is inside the module already under change and alters only what the code says, not what it does.

**The boundary is which side of the disagreement moves.**
Correcting the sentence so it claims only what the run measured is covered.
Changing what the code does so the claim becomes true is not covered, because that is deciding what the right behaviour is, and it stays the captain's under the same rules as any other contract question.
This rule is never a licence to make a claim true by altering behaviour.

Escalate when any one of these holds:

- the correction would change what the code does rather than what it says;
- the correction reaches outside the module already under change;
- what the sentence ought to say cannot be settled without first deciding what the right behaviour is.

The worker-facing half of this rule is the generated ship brief's rule 6, which is where a worker meets it without loading this skill.
The two say the same thing on purpose; a rule contradicted one file over is not landed.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
- Help text asserting that a sweep runs every check once per interval, when the sweep stops at the first check that reports, is a claim that outruns its run and is corrected rather than escalated.
- A refusal saying every candidate failed with a named error code, when the probe stops at the first answer and that code is one of several, is the same class and is corrected the same way.
- A reading that renders an unreadable clock as a successful zero is corrected in what it says; changing the timing code so the zero becomes true is the escalation.
