# Grading review quality

`bin/fm-grade.sh` grades how good a code review actually is, on a scale the reviewed tool does not control.

## The problem it exists for

Every figure we had for `no-mistakes` came out of `no-mistakes`.
Findings reported, share fixed, share of corrections attributable to the review step, rescue rate - all of it is the tool's own bookkeeping about its own work.
None of those numbers establishes that a finding was real, and none of them establishes that a correction improved anything.

That is not a complaint about the tool; it is a gap in the evidence.
Its practical cost is that the decision to keep the incumbent is not honestly revisable.
Comparing a challenger would set one tool's self-report against another's, with no common scale, so whichever tool counted more generously would appear better.

This produces the common scale, and fixes it in advance so a later challenger meets the same one without anybody adjusting the rules after seeing the result.

## The trap, and the decision taken

A grading system that certifies its own accuracy has exactly the disease it was built to cure, one level up, and looks more respectable while having it.
So this system does not judge.
It carries no model in its scoring path, and it never rates a finding's merit by reading the finding's own description.

The tempting shortcut is to have a model read each finding and label it real or spurious.
That was rejected, and the reasoning matters more than the conclusion:

- A finding's description was written to persuade.
  A model reading it is scoring how convincing the argument is, which is not the same question as whether the defect exists.
- A model from the same family as the one that wrote the finding shares its blind spots.
  Its errors correlate with the original's instead of cancelling them, so agreement is not corroboration.
- The output would be a confident false-positive rate with no better provenance than the numbers it replaced.
  That is the precise artifact this work exists to abolish.

What is genuinely more independent is evidence the finder did not control.
Four such sources exist here, and they are the only ones used:

1. **Execution.** Running the code and observing what it does.
2. **Time.** What git shows survived, and what had to be undone.
3. **Blindness.** An answer key sealed before the candidate runs, which it cannot see and therefore cannot tune to.
4. **A human reading the diff**, on a sample, with the tool's own labels stripped off.

## How falsification actually works

Each tier can be attacked, and the way to attack it is stated up front.

- The git tier is recomputable by anyone with the clones.
  Disagree with a number and you can re-derive it; the inputs are commits, not our records.
- The corpus is executable.
  `fm-grade.sh corpus --verify` extracts the subject at the defect commit and at the fixing commit and requires the defect to appear in the first and be gone in the second.
  A case that stops reproducing is reported as failed, so the answer key cannot decay into folklore.
- The materiality sample is seeded and the seed is printed in the report.
  Anyone can redraw the identical sample and re-adjudicate it.
- Every number is emitted with its sample size and its evidence class, and `Metric` in `bin/fm-grade-engine.py` refuses to construct without both.
  A figure that cannot say where it came from and over how much cannot be produced by this engine at all.

## The four tiers

They are reported separately and never combined into one score, because they are not the same kind of evidence and averaging them would hide which parts are load-bearing.

### Tier L - the tool's own ledger

Source: the `no-mistakes` SQLite run database, opened read-only.

Structural facts about the bookkeeping only: how many findings, how they were labelled, how many rounds a step needed.
This tier is labelled SELF-REPORTED everywhere it appears, because none of it establishes that a finding was real.
It is still worth printing: abstention rate is human workload the fix rate never priced, and the round distribution shows how often a correction failed to settle its own step.

### Tier G - what actually happened to the code

Source: git history of the reviewed repositories.

The pipeline lands each correction as a real commit, subject-prefixed `no-mistakes(<step>):`.
A commit's diff is a fact about the repository, not a claim the tool makes about itself, which is what makes this tier able to contradict the ledger.

The load-bearing metric is **fix rework**: of the lines a correction deleted, how many had been written by an *earlier correction in the same run*, according to `git blame` of the parent commit.
Every such line is a correction that had to be corrected, while the ledger counted both as fixes.
This is the measurement the tool cannot make about itself, and it is what requirement "a correction that introduces a new fault must not count as a gain" reduces to in data that already exists.

Two rates are reported.
The headline includes each run's first correction in the denominator even though it can rework nothing by definition, which makes it deliberately conservative.
The follow-up-only rate restricts to corrections that had a predecessor to undo, and is the sharper figure.

**Fix line survival** asks the complementary question: of the lines a correction added, how many still stand at the branch head.
Lines that did not survive were overwritten before the branch finished, so that correction left nothing behind whatever the ledger recorded.

Runs whose commit chain cannot be located and verified against the recorded fix summaries are excluded and counted, never assumed clean.

### Tier B - blind replay against known-real defects

Source: the sealed corpus in `bin/fm-grade-corpus`, scored against a candidate that never saw it.

A candidate is given a commit and told nothing else - not whether a defect is present, what kind, where, or how many.
What it reports is therefore a detection rather than a confirmation.

A case is scored in the headline rate only if the proof that its defect was real is an observed event: an executed reproduction, a failing test, a CI failure, or a revert.
Cases resting on a reviewer's assertion are reported separately and never blended in.
A model's opinion that a finding looks correct is not admissible proof at any tier.

New cases are picked up automatically from the corpus directory, so growing the scale needs nothing registered and nothing remembered.
`bin/fm-grade-corpus/README.md` owns the case format.

### Tier M - materiality

Source: a named human, over a seeded stratified sample, adjudicating blind.

Whether a finding would really have hurt at merge cannot be computed from the run history, so the engine does not compute it.
It draws a reproducible sample, strips the tool's own severity and action labels - judging those would re-import the self-assessment this scale replaces - and emits a ballot.
Until a signed ballot comes back it reports `UNADJUDICATED`.

An unsigned ballot is refused.
Adjudicated rates ship with a Wilson interval, which is honest at small samples where the normal approximation collapses, and abstentions are excluded from `n` rather than counted as agreement.

## Using it

```
bin/fm-grade.sh report --out grade.md   # the graded reading
bin/fm-grade.sh corpus --verify         # re-prove every case in the answer key
bin/fm-grade.sh sample --out ballot.json    # draw a blind materiality ballot
bin/fm-grade.sh report --ballots ballot.json    # fold adjudicated verdicts in
```

`bin/fm-grade.sh --help` owns the flags.

### Running a challenger against the same scale

1. `bin/fm-grade.sh replay --tier1-only` prints the blind task list: a commit per case and nothing else.
2. Run the challenger over those commits and collect its findings in the printed submission format.
3. `bin/fm-grade.sh report --submission answers.json` scores it.

The corpus is fixed before the challenger runs, so the comparison does not depend on anyone's restraint afterwards.
Grading the incumbent the same way requires pointing it at the same commits blind, which has not been done yet; the scale is built and the reading is simply not taken.

## What this does not claim

- It does not certify that any individual finding was correct.
  Only the materiality tier can speak to that, and only for a sample, and only once a human has voted.
- It does not measure defects the review never reported, except through the blind corpus.
  A corpus of one case bounds how much that can currently say, and the detection rate is always printed with its sample size for that reason.
- The git tier's rework metric shows that a correction removed an earlier correction's lines.
  It does not prove the earlier correction was harmful, only that it did not stand.
- Run counts drift while the pipeline keeps running, so a report defends its own snapshot and nothing else.
- It gates nothing.
  It blocks no delivery, cancels no run, feeds no decision automatically, and returns no pass/fail verdict.
  It produces a reading a human interprets.

## Safety

The run database is the operating state of a live pipeline and is opened `mode=ro`; the tool never writes to it, and `tests/fm-grade.test.sh` asserts the file is unchanged after a full report.
Finding text can quote command lines, so anything secret-shaped is replaced by a named placeholder before it reaches a ballot or a report - visible as a redaction rather than silently dropped.
`corpus --verify` executes each case's declared reproduction in a throwaway directory under a timeout; corpus files are tracked repository material and are reviewed like any other code.
