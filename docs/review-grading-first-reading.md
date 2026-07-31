# First reading of the review-quality scale

Evidence record for the first run of `bin/fm-grade.sh` over the recorded `no-mistakes` history.
Method, tier definitions, and the falsifiability argument live in [review-grading.md](review-grading.md); this file records what the scale actually read.

## Provenance

- Date: 2026-07-31
- Run database: `~/.no-mistakes/state.sqlite`, opened `mode=ro`, 174 runs, 621 finding objects, latest run 2026-07-31
- Repositories blamed: the 7 clones the run database names, all reachable
- Commands:

```
bin/fm-grade.sh corpus --verify
bin/fm-grade.sh report --out grade.md
```

The finding count differs from the 605, 612, and 614 quoted earlier the same week because runs kept landing while those figures were taken.
That drift is the reason a report defends its own snapshot and nothing else.

Re-running the report reproduced every git-tier figure exactly, which is the property that lets a challenger be compared later.

## What the scale read

### Tier L - the tool's own ledger (SELF-REPORTED)

| metric | value | n |
|---|---|---|
| `findings_total` | 621 | 621 |
| `abstention_rate` | 35.9% | 621 |
| `autofix_share` | 40.1% | 621 |
| `error_severity_share` | 7.1% | 621 |
| `review_rounds_median` | 2.0 | 169 |
| `runs_needing_3plus_review_rounds` | 21.9% | 169 |
| `run_completion_rate` | 84.5% | 174 |

### Tier G - what actually happened to the code (INDEPENDENT)

| metric | value | n |
|---|---|---|
| `runs_git_resolved` | 137 | 174 |
| `fix_rework_rate` | 28.8% | 4067 deleted lines |
| `fix_rework_rate_followups` | 64.7% | 1808 deleted lines |
| `fixes_that_reworked_a_prior_fix` | 55.3% | 150 fix commits |
| `fix_line_survival` | 88.9% | 19467 added lines |

37 runs were excluded because no fix-commit chain could be verified against the recorded fix summaries.
They are excluded rather than assumed clean, so every git figure above is over the 137 runs that could be checked.

### Tier B - blind replay

| metric | value | n |
|---|---|---|
| `corpus_cases_admissible` | 1 | 1 |
| `blind_detection_rate` | UNADJUDICATED | 1 |

### Tier M - materiality

| metric | value | n |
|---|---|---|
| `material_finding_rate` | UNADJUDICATED | 0 |

## How to read this

**The incumbent's own headline is not refuted; it is shown to be counting the wrong thing.**
A fix rate counts corrections attempted.
Of the lines a follow-up correction removed, 64.7% had been written by the pipeline's own earlier correction rather than by the author, and 55.3% of follow-up corrections removed at least one such line.
Both of those were counted as fixes by the ledger, and the second one exists only because the first did not hold.

**The case that prompted this work is typical, not exceptional.**
Run `01KYV7KGTWSB0HCSX8YT67KH74` - where rounds 2, 3, and 4 each caught a regression the previous round's correction had introduced - sits tenth on the rework table at 55%.
Nine runs did worse, two of them at 83%.
Reading that case as a rare bad night would have been wrong.

**Corrections are not mostly wasted.**
88.9% of the lines corrections added still stand at the branch head, and the first correction in a run reworks nothing by construction.
The pattern is not a tool that fails; it is a tool whose first pass does real work and whose later passes spend most of their edits on its own earlier passes.
The extra rounds are where the cost sits, and no self-reported number made that visible.

**A third of findings were never decided by the tool at all.**
35.9% are `ask-user`, which is human workload no fix rate prices.

## What this reading cannot yet say

Two of the four tiers are built but not scored, and neither gap is hidden inside an average.

- **The false-positive rate is still unknown.** Tier M reports `UNADJUDICATED` because no human has voted. The instrument exists: `bin/fm-grade.sh sample` draws a seeded, stratified, blind ballot with the tool's severity and action labels withheld. Until someone signs one, this scale has no honest false-positive number, and neither did anything before it.
- **The blind corpus holds one case.** It is admissible - the defect was re-proven by executing the shipped script at both commits - but a detection rate over n=1 would be theatre, so none is reported. The corpus grows by dropping a file in `bin/fm-grade-corpus`; the most valuable additions are defects the review MISSED, which is the region no self-report can ever cover.
- **No candidate has been replayed, including the incumbent.** The scale is fixed and the score is simply not taken yet.

The rework metric shows that an earlier correction did not stand.
It does not by itself prove that correction was harmful, and it spans steps within a run, so a `document` correction editing a `review` correction counts.

## Where this leaves the decision

The recommendation to keep `no-mistakes` rested on the tool's own bookkeeping, and that objection is now answerable in one direction: there is an external measurement, it is reproducible, and it says the incumbent's later rounds are substantially self-correction.

It is not yet answerable in the other direction.
Nothing here says a challenger would do better, because no challenger has run and because the corpus is one case deep.
What has changed is that the comparison is now possible without either tool grading itself.
