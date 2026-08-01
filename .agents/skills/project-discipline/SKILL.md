---
name: project-discipline
description: >-
  Agent-only procedure for running a project so its outcome can be evidenced rather than asserted; to add, create, clone, or remove a project itself, use `project-management` instead.
  Use at intake when the work will produce a change others depend on, and again before declaring that work complete; not for a question, a read-only check, or a single-file fix.
  Owns goal and measure definition, baseline capture, cause separation, smallest-change selection, and the controls that stop a fix from decaying.
user-invocable: false
metadata:
  internal: true
---

# project-discipline

**Where this file arrives without a trigger line, it is found rather than triggered.**
Firstmate declares in its own instruction file which skills load and at which points, so this skill loads automatically only where that file carries a trigger naming it.
Where `AGENTS.md` arrives vendored under a pin and cannot be changed, no such trigger can exist, and going looking is the only way anyone arrives.
One partial path works in either case: a harness that lists available skills will surface this one from its description, which is genuine and useful, and which depends on that harness rather than on firstmate's contract - so nothing that has to happen reliably should rest on it.
Read the instruction file you actually operate under rather than assuming either case, because which one holds is a property of the deployment and not of this skill.

Use this at intake when the work will produce a change others depend on, and again before declaring that work complete.
This skill is the single owner of Firstmate's project-execution discipline.
`diagnostic-reasoning` owns how to reason about a single defect's cause; this owns how a piece of work gets defined, evidenced, and held.

This discipline is reasoning, not delivery authority.
It never holds work for a manual clean verdict, never adds a check outside the selected delivery path, and never becomes an approval anyone has to collect.
The selected delivery path, its automated gates, and the captain keep every approval they already own, and a concern raised here is escalated through them rather than enforced here.

The stages below are a way of thinking about the work, not chapters to be read in order.
Each one ends by checking its own outputs against the list written here rather than against memory, and a stage whose outputs are absent is not finished because the work feels done.
Skipping a stage is allowed; skipping it silently is not, so name which one you skipped and why in the same message that reports the result.

## The rule above all others

**Every assurance must have a way to fail visibly.**

An assurance is any check, gate, test, review, alarm, or promise that something is true.
For each one, you must be able to answer two questions: what input would make this fail, and when did it last fail.
An assurance that cannot fail is not protection, and an assurance that fails without anyone seeing is worse than none, because it also spends the attention that would otherwise have gone to looking.

Apply this before trusting any assurance you did not just watch fail:

- Name the last time it failed, with the date or the run.
- If it has never failed, treat it as unproven rather than as strong. A check that has never failed has been shown to be quiet, not to work.
- Feed it an input you know is bad and require it to say so. If you cannot construct such an input, you do not yet understand what the assurance is checking.
- Run that proof where a real failure is affordable. Exercising the permitted path of a guard by performing it against the live system verifies the guard by committing the act it exists to bound.
- Check what it does when its subject is absent, when it runs in the wrong context, and when its dependency is missing. The dangerous failure is not the one that errors; it is the one whose failure is shaped exactly like its success.
- Prefer a check that answers your question directly over one that merely fails to complain. An absence of output is not evidence, because a working guard and a guard that was never consulted both produce nothing, and a quiet result is the single most over-trusted signal there is.

Design so that success and failure cannot look alike from the inside.
When a mechanism can only be confirmed from outside itself, say so plainly and arrange the outside check, rather than reporting the inside view as evidence.

## Define: name whose problem this is, and how you will know it is solved

Do this before any building, and record it where completion will later be judged.

- Name the person or role who has the problem, in their words rather than in system terms. Work whose owner you cannot name has no acceptance test and will be accepted on impression.
- State the problem as a size: the distance between what is happening and what should happen, with a unit. A problem that cannot be sized cannot be closed, only abandoned.
- Break the complaint into the specific conditions that must all hold for the result to be acceptable. The complaint is a symptom report, not a requirement list, and the gap between the two is where most rework is created.
- Name the process that actually produces the outcome, with its inputs, its owner, and its boundary. Until the complaint is attached to a process, no change has an address.
- State what leaving it alone costs. When that is smaller than the cost of the work, say so and stop; declining cheaply is a result.
- Write the success measure and its target number now, before building. A number chosen after the work is a description of what happened, not a target, and it will always be met.
- Match the method's weight to the problem: relieve the symptom when speed is the point and say that is what you did, work the cause when the cause is known, and run the full cycle only when the cause is unknown. Running the heavy procedure on a trivial defect discredits the procedure.

## Measure: take the baseline before you change anything

- Take the before-reading first, and take it yourself. After the change, the prior state is no longer observable, and every improvement claim made without one is unfalsifiable.
- Make the baseline window include the period the fault actually occurred. A window chosen for convenience usually excludes the failure and shows a healthy process.
- Prove the measurement before trusting its output: resolution fine enough to see the effect you care about, no constant offset, no drift over the window, and the same answer twice on the same input.
- **For any pass/fail gate, prove it against a known-bad input before you rely on it.** Run it against inputs you know should pass and inputs you know should fail, and require it to separate them. A gate tested only on good inputs has an unmeasured ability to detect anything.
- Hold a new assurance to a stricter standard than an inherited one. An inherited one at least has history; a new one has only its author's intent.
- Separate the outcome you promised from the inputs you can change. Report movement in the outcome as the result, and never present an input you adjusted as though it were the outcome improving.
- One reading is an anecdote. Where the measure varies at all, collect enough of it to tell a change from noise, and say which you are looking at.

## Analyse: separate the root cause from the first plausible explanation

This is the stage most often skipped, because the first explanation arrives with a feeling of completion attached.

- List candidate causes with evaluation explicitly forbidden. Do not argue any candidate up or down while listing, because judging during generation is precisely the mechanism by which the first plausible explanation wins.
- Require at least two candidates per outcome before scoring any of them. If only one comes to mind, you have not finished listing, and confidence at this point is a report on how quickly you stopped.
- Use fixed categories to force breadth rather than free recall: the actor, the method, the tooling, the inputs, and the surrounding environment, or the process steps in order.
- Score each candidate against each outcome for strength of influence, then keep only the ones that clear a stated bar. Write the bar down before scoring.
- Read the totals for shape, not just for rank. One dominant cause and several shared contributors call for different fixes, and assuming a single cause is itself the common error.
- Screen widely and cheaply first; spend the expensive proof only on what survives. Wide-and-cheap then narrow-and-rigorous costs less than proving the first idea thoroughly and being wrong.
- Validate any new measurement you introduce here on its own terms. Proving the outcome measure sound says nothing about the instruments you just added to observe the inputs.
- Name what observation would prove your leading explanation wrong, then go and look for it.
- Do not let the leading hypothesis become the item's recorded name. A title is read later as a finding, so a guess written into one is believed by everyone who arrives after you, and it suppresses the very re-examination that would correct it.

## Improve: the smallest change that moves the measure

- Change the fewest inputs that move the measure. The goal is movement in the number you defined, not coverage of everything you noticed, and every extra change bought here is paid for in the next investigation.
- State the safe range around the new setting: how far it may drift before the outcome degrades. A value with no stated tolerance is a guess that will be treated as a constant.
- Prove it on a pilot before widening. A short scoped trial that shows the measure move is evidence; a full rollout that feels right is not.
- When one option is irreversible and another is not, take the reversible one unless the irreversible one buys an advantage you actually need. This is not a tie-breaker for when the risk looks large: the size of the risk is the thing you are least able to judge in advance, which is the whole reason to prefer the option that keeps the judgement revisable. Publishing, deleting, sending and merging are irreversible; staying private, keeping a copy, drafting and holding are not, and the reversible side can be spent later at no loss.
- Keep containment and cure as separate, separately reported steps. Stopping the harm and removing the cause are different work, and reporting the first as the second is how a cause survives its own fix.
- Re-measure the same thing the same way and compare against the recorded baseline. A different metric, a different window, or a different method makes the comparison decorative.

## Control: what stops it drifting back

An improvement with no control is a temporary result with a permanent claim attached.

Choose the strongest control the situation allows, in this order:

1. **Eliminate** the possibility, so the error cannot be expressed at all.
2. **Replace** the fragile step with a mechanism that does not depend on anyone remembering.
3. **Make the correct path easier than the incorrect one**, so effort flows the right way by default.
4. **Detect** the error at the moment it happens, before it becomes a defect downstream.
5. **Limit the damage** when it does happen.

A written rule appears nowhere on that list, and neither does a note, a reminder, or a documented convention.
Prose changes the reader's knowledge, not the system's behaviour, and knowledge is not present at the moment the error is made.
Treat every "we should remember to" as an unfinished control and record which of the five rungs it is going to become.
A repair written in prose can commit the same defect inside the repair itself: an explicitly instructed and reviewed correction of one stale restatement in this repository introduced three fresh stale restatements in the same pass.
The claim that rots is the one restating a present state - a count, an inventory, an emptiness - where the invariant that governs that state would have held instead, because the state is falsified by the very next change and the rule that produced it is not.

The remaining control work:

- Write down what is watched, what the limit is, what happens when the limit is crossed, and who acts. A control with no named response is an observation.
- Make the standard visible where the work happens, so a deviation is noticeable without anyone auditing for it.
- Verify over time rather than at a moment, and keep the three questions apart: is it stable, does it meet the requirement, and is the change from baseline real.
- Compare the actual result against the number promised at Define, and state the difference explicitly, including when you exceeded it.
- Route a failure back to the stage that owns it: not holding means the control is wrong, and holding but not improving means the cause was wrong.
- Ask what else has the same shape. Carrying a proven fix to its siblings is the cheapest work available, and finding none is worth one line of report.

## The Lean layer

- Go and look at the thing itself before designing from its description. A report of a system and the system differ in exactly the places that matter.
- Treat as waste anything the outcome's owner would not pay for: waiting, rework, handoffs, work produced before it is needed, work finished past what was asked, and unfinished work held in queues.
- Optimise flow, not occupancy. Many things in progress and few things landing is a stalled system, and busyness is the most convincing evidence of progress that is not evidence of progress.
- Establish standard work before trying to improve: a process that differs every run has no baseline, so any improvement to it cannot be measured or kept.
- Standard work is what makes an improvement stick, and it is also what makes the next deviation visible. Both effects are lost the moment the standard exists only as a description of what people usually do.

## Five cases worth carrying

These are failures from this project's own record, kept specific on purpose.
A general statement of them would be easier to publish and would carry nothing: the point of each is that it was committed by people who already knew the rule.

**The verification step that never once worked.**
A pipeline's CI-checking step invoked the forge's check command while relying on working-directory inference to resolve which repository and pull request it meant.
The daemon running it had a working directory that was not a git repository, so the command could not resolve a repository and exited non-zero every time, independently of the actual check state.
It emitted `warning: could not check CI` on every poll and retried on a week-long timeout, so it presented as patient rather than broken; the pane was quiet, the run state read as validating, and the supervisor correctly absorbed it as work in progress.
Nothing anywhere reported a problem, and it had never succeeded once.
Two further details are the instructive ones.
The failure was never silent - it printed a warning on every single attempt - and was invisible anyway, because a warning that always appears is indistinguishable from the system's normal noise.
And the item recording the defect was titled with the first plausible explanation, which was wrong; that title stood as the accepted account for four days until a three-way counterfactual replaced it, and naming the repository and pull request explicitly from the same failing directory succeeded, proving the inference was the cause.

**The ambient default that acked another party's mail.**
A message-inbox tool defaulted its identity argument to an environment variable, and the shared shell profile on the machine exported that variable to a different vessel's name.
Any listing or acknowledgement run without the explicit identity flag therefore operated on another vessel's mailbox and acknowledged mail addressed to someone else, and listing was itself the acknowledging action, so there was no safe way to look first.
The recorded fix was "always pass the identity flag explicitly" - a written rule, which is not on the control ladder at all - in a case where elimination was available, because a tool that refuses to run without an explicit identity cannot express the error.
The defect was documented, and documenting it did not prevent it, because the record and the moment of the error are in different places and the command runs in a shell that never reads the record.

**The rule that drifted stricter on its first copy.**
A role overlay restated one of the project's own hard rules and dropped its exception clause, making the copy stricter than the original.
Because a narrower overlay rule wins, four operations the original rule explicitly permits would have been refused in any home selecting that role.
The copy was wrong on the first write rather than after months of erosion, and wrong in the direction that quietly removes capability, which is the harder direction to notice: nothing breaks loudly, work simply starts being refused.
It originated in a correct instruction - that the hard rule must stay unnarrowed - which the writer reasonably discharged by restating the rule in the overlay.
So the correction is not "restate it accurately"; it is do not restate it at all.
State each contract once and make every other mention a pointer, because "we will keep the copies in sync" is a written rule about written rules.

**The safeguard that was verified and had never worked.**
Extracting licensed material for this task, the author excluded the scratch directory by writing it into a linked git worktree's own `info/exclude`, then confirmed it with `git status`, which reported clean.
Git does not read a linked worktree's private exclude file; it reads the shared one in the common directory, and `git check-ignore` reports the path as not ignored.
`git status` was clean only because the directory was still empty at that moment, and git does not list empty directories.
The check could not distinguish a working exclusion from a broken one and returned the same answer either way, so material sat unprotected for the whole task behind an assurance that had been explicitly verified.
This one was committed by the author of the three cases above, in the session that wrote them down, which is the calibration to take from it: knowing the rule does not exempt you.
`git check-ignore` asks the question directly and can answer no; `git status` on an empty directory cannot.

**The unbaselined claim, made by the person commissioning the fix.**
The order that commissioned this procedure named one stage as the most common failure class - a ranking asserted with no count behind it, in the sentence that asked for a discipline against unevidenced claims.
The person who wanted it most made the error it exists to prevent, and then said so first, which is the part worth copying.
A confident ranking of your own weaknesses is a claim requiring a baseline like any other, and it is the claim you are least likely to ask for evidence on.
