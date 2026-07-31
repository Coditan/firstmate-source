# Sealed defect corpus

This directory is the answer key for `bin/fm-grade.sh`'s blind benchmark.
Each `*.json` file records one defect that was really in the code, the commit that contained it, and how a reviewer would be judged to have found it.
A candidate reviewer is pointed at the commit and told nothing else, so what it reports is a detection rather than a confirmation.

Every file here is discovered automatically.
Dropping a new case in this directory adds it to the scale with nothing to register and nothing to remember.

## Why a case needs proof

A corpus whose cases rest on someone's recollection is the same self-assessment problem one level down.
So each case carries a `proof` block naming the evidence that the defect was real, and the engine sorts cases by how strong that evidence is:

- **Tier 1** - the proof is an event that was observed: `executed-reproduction`, `failing-test`, `ci-failure`, or `revert-commit`.
- **Tier 2** - the proof is `asserted`, meaning a reviewer concluded it.

Only tier 1 cases are scored in the headline detection rate.
Tier 2 cases are reported separately and never blended in, so a weaker answer key cannot quietly inflate a score over time.

A model's opinion that a finding looks correct is never admissible proof, at any tier.
That is the whole point of the corpus: it exists because model judgement about model output is not independent evidence.

## Keeping the key honest

A case may carry a `reproduce` block, and `fm-grade.sh corpus --verify` then executes it.
The subject is extracted at `defect_commit` and must exhibit the defect, then extracted at `fixed_commit` and must not.
Both directions are required, because a fixture that passes at both commits was never testing anything.

Run `--verify` when adding a case and whenever the corpus is doubted.
A case that stops reproducing is reported as failed rather than silently carried, so the key cannot rot into folklore.

## Case format

```json
{
  "case_id": "short-stable-slug",
  "repo": "clone directory name, resolved against FM_HOME/projects and siblings",
  "class": "guard-bypass",
  "added": "YYYY-MM-DD",
  "summary": "what was wrong, in one paragraph",
  "defect_commit": "40-char sha containing the defect",
  "fixed_commit": "40-char sha that removed it",
  "defect_paths": ["path/that/held/the/defect"],
  "why_material": "what merging it would actually have cost",
  "detection": {
    "must_mention_paths": ["path/that/held/the/defect"],
    "must_match_any": ["regex", "alternative regex"]
  },
  "proof": {
    "kind": "executed-reproduction",
    "evidence": "pointer to the log, test, or CI run that recorded it",
    "independently_reproduced": "who re-ran it, when, and what they saw",
    "reproduce": {
      "extract": [{"path": "bin/thing.sh", "as": "subject.sh", "mode": "0755"}],
      "fixture": {"input.html": "file body written into the scratch directory"},
      "command": ["./subject.sh", "--check", "input.html"],
      "defect_expect": {"exit": 0, "output_matches": "regex proving the defect"},
      "fixed_expect": {"exit": 1, "output_matches": "regex proving the fix"}
    }
  }
}
```

`detection` is deliberately generous about wording and strict about location.
A candidate should not lose a point for describing the defect differently than we did, but pointing at the wrong file is not a detection.
Keep `must_match_any` broad enough that an independent reviewer who genuinely found the defect will match at least one alternative.

The scored rule matches `must_mention_paths` against the finding's own `file` field and nothing else.
A finding that names the wrong file does not count however its prose reads, because acting on it sends a reader to the wrong place.
Both sides are normalised first and compared on their shared path suffix, so an absolute path, a `./` prefix, or a path written relative to a different root still names the same file.
The rule rejects wrong files, not wrong formatting: a challenger whose path convention differs from the incumbent's must not lose points for that alone.
The report also prints `blind_detection_rate_lenient`, which additionally accepts the path appearing anywhere in the finding's text.
That figure is never the score; it is printed beside the score so the gap between them is visible, because the distance between the two is exactly how precisely the candidate localised what it found.

`repo` is a directory name rather than a path because these files are shared.
The engine tries the explicit `repo_path`, then `FM_GRADE_REPO_<NAME>`, then `FM_HOME/projects/<repo>`, then the firstmate checkout and its siblings, and accepts the first clone that actually contains `defect_commit`.

## Adding a case

Good candidates are defects that reached a review at all and were caught, or defects that reached further and had to be reverted.
The second kind is more valuable, because a defect the incumbent missed is the part of the scale its own numbers can never cover.

1. Find the commit that contained the defect and the commit that fixed it.
2. Write the case file, including a `reproduce` block whenever the defect can be shown by running something.
3. Run `bin/fm-grade.sh corpus --verify` and confirm the case reports `RE-PROVEN`.
4. Commit it.

The corpus is small on purpose.
One case with executed proof is worth more than twenty asserted ones, and the detection rate is always reported with its sample size so nobody reads more precision into it than the corpus supports.
