#!/usr/bin/env python3
"""Measurement engine for bin/fm-grade.sh: the review-quality scale.

WHY THIS EXISTS
---------------
A review tool that reports its own finding counts is a student grading their
own exam. Every headline number we had for `no-mistakes` - findings reported,
percent fixed, percent of corrections from the review step - came out of the
tool's own ledger. None of it says whether a finding was real, and none of it
says whether a correction improved anything. Without an outside scale, a
challenger could only be compared self-report against self-report, so the
decision to keep the incumbent was not honestly revisable.

THE TRAP THIS ENGINE HAS TO AVOID
---------------------------------
A grading system that asserts its own accuracy has the same disease one level
up, and looks more respectable while having it. So this engine refuses to be
the judge. It carries NO model in its scoring path and it never rates a
finding's merit by reading the finding's own argument.

Instead every number is tagged with the evidence that produced it, and numbers
from different evidence classes are never blended into one score:

  ledger      The tool's own SQLite bookkeeping. Structural facts only - how
              many, how often, how many rounds. Audits the ledger, NOT the
              review's quality. Labelled self-reported wherever it appears.
  git         What actually happened to the code. A fix lands as a real commit;
              its diff is a fact, not a claim. `git blame` can therefore answer
              a question the tool cannot self-report: did this correction undo
              a line that an EARLIER correction in the same run just wrote?
              This is the load-bearing tier.
  bench       A sealed corpus of known-real defects. A candidate is pointed at
              the pre-fix commit and never told what is there, so it cannot
              pattern-match to the answer key. Each case must carry proof that
              the defect was real, and that proof may not be a model's opinion.
  materiality Whether a finding would really have hurt at merge. There is no
              honest way to compute this, so the engine does not compute it. It
              draws a reproducible blind sample and emits a ballot for a NAMED
              human. Until ballots come back it reports UNADJUDICATED rather
              than a number.

WHY NOT LET A MODEL JUDGE THE FINDINGS
--------------------------------------
That is the obvious shortcut and it is not independent. A finding's text was
written to persuade. A model reading that text is scoring how convincing the
argument is, not whether the defect exists, and a model from the same family as
the one that wrote it shares its blind spots, so the errors correlate instead of
cancelling. It would produce a confident false-positive rate - the exact artifact
this engine was built to abolish. What is genuinely more independent is evidence
the finder did not control: executing the code, what git says survived, a sealed
answer key the candidate cannot see, and a human reading the diff with the tool's
own labels stripped off. Those four are the only sources here.

MANDATORY PROVENANCE
--------------------
`Metric` will not construct without a sample size and a named source. A number
that cannot say where it came from and over how much cannot be emitted by this
engine at all. That is enforced in code, not in review discipline.

SAFETY
------
The run database belongs to a live pipeline: it is opened `mode=ro` and never
written. Finding text can quote command lines, so anything secret-shaped is
redacted before it reaches a ballot or a report. This engine measures and never
decides - it gates nothing, blocks no delivery, and returns no pass/fail verdict.

Mechanics, flags, and output layout are owned by bin/fm-grade.sh --help.
"""

import argparse
import collections
import hashlib
import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import time

DEFAULT_DB = os.path.expanduser("~/.no-mistakes/state.sqlite")
FIX_SUBJECT_RE = re.compile(r"^no-mistakes\(([a-z]+)\):\s*(.*)$")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")

# The verdicts a ballot may carry. A hand-filled ballot is exactly where a typo
# lands, and an unrecognised string would inflate every denominator while
# contributing to no numerator, so the vocabulary is closed and enforced.
BALLOT_VERDICTS = ("harmful", "minor", "wrong")

# Secret shapes are redacted before any finding text is shown. The list is
# deliberately broad: a false redaction costs a reader some context, while a
# missed one puts a live credential into a tracked report.
SECRET_PATTERNS = [
    (re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{16,})"), "gh-token"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "gh-pat"),
    (re.compile(r"\bAKIA[0-9A-Z]{12,}"), "aws-key-id"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"), "slack-token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}"), "api-key"),
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{20,}"), "bearer"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private-key"),
    (re.compile(r"(?i)(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*"
                r"[\"']?([A-Za-z0-9._~+/=-]{12,})[\"']?"), "kv-secret"),
]


def redact(text):
    """Replace secret-shaped substrings with a named placeholder.

    Named, not deleted: a reader must be able to see that something was removed
    and what kind of thing it was, per the never-print-a-secret-value rule.
    """
    if not text:
        return text
    out = text
    for pattern, label in SECRET_PATTERNS:
        out = pattern.sub("[REDACTED:%s]" % label, out)
    return out


class Metric:
    """A number that cannot exist without provenance.

    `n` is the sample the value was computed over and `source` names the
    evidence class that produced it. Both are required positionally so no
    caller can drift into emitting a bare figure.
    """

    def __init__(self, key, value, n, source, method, unit="", caveat=""):
        if not key:
            raise ValueError("metric needs a key")
        if n is None:
            raise ValueError("metric %s needs a sample size" % key)
        if not source:
            raise ValueError("metric %s needs a named source" % key)
        if not method:
            raise ValueError("metric %s needs a method" % key)
        self.key = key
        self.value = value
        self.n = n
        self.source = source
        self.method = method
        self.unit = unit
        self.caveat = caveat

    def as_dict(self):
        d = {
            "key": self.key,
            "value": self.value,
            "n": self.n,
            "source": self.source,
            "method": self.method,
        }
        if self.unit:
            d["unit"] = self.unit
        if self.caveat:
            d["caveat"] = self.caveat
        return d

    def render(self):
        if self.value is None:
            shown = "UNADJUDICATED"
        elif isinstance(self.value, float):
            shown = "%.1f%s" % (self.value, self.unit)
        else:
            shown = "%s%s" % (self.value, self.unit)
        return shown


def wilson_interval(successes, total, z=1.96):
    """Wilson score interval - honest at the small samples this tool produces.

    The normal approximation collapses near 0 and 1 and at low n, which is
    exactly where a blind sample lives, so reporting it would understate
    uncertainty precisely where the reader most needs it.
    """
    if total == 0:
        return (None, None)
    p = successes / total
    denom = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denom
    margin = (z * ((p * (1 - p) / total + z * z / (4 * total * total)) ** 0.5)) / denom
    return (max(0.0, centre - margin), min(1.0, centre + margin))


class Git:
    """Read-only git access with a blame cache.

    Blame dominates the runtime, so each (commit, path) pair is blamed once in
    full and indexed by line rather than re-blamed per hunk.
    """

    def __init__(self, root):
        self.root = root
        self._blame = {}
        self.available = os.path.isdir(os.path.join(root, ".git")) or os.path.isdir(root)

    def run(self, *args):
        try:
            proc = subprocess.run(
                ["git", "-C", self.root] + list(args),
                capture_output=True, text=True, timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if proc.returncode != 0:
            return None
        return proc.stdout

    def has_commit(self, sha):
        return self.run("cat-file", "-e", sha + "^{commit}") is not None

    def subject(self, sha):
        out = self.run("log", "-1", "--format=%s", sha)
        return out.strip() if out else None

    def blame_map(self, commit, path):
        """Return {line_number: introducing_sha} for path at commit."""
        key = (commit, path)
        if key in self._blame:
            return self._blame[key]
        out = self.run("blame", "--porcelain", "-M", "-C", commit, "--", path)
        mapping = {}
        if out:
            for line in out.splitlines():
                m = re.match(r"^([0-9a-f]{40}) (\d+) (\d+)", line)
                if m:
                    mapping[int(m.group(3))] = m.group(1)
        self._blame[key] = mapping
        return mapping

    def hunks(self, sha):
        """Parse a commit's diff into hunks carrying BOTH sides' paths.

        Deleted lines have to be blamed against the path they lived at in the
        parent, which is not always the path they land at: a deletion emits
        `+++ /dev/null` and a rename emits a different path on each side. Keying
        everything off the `+++` side would leave the previous file's path in
        place for a deletion and blame that file's lines by mistake, so each
        side is tracked separately and only inside a real file header - a
        removed line of content can itself begin with `---`.
        """
        diff = self.run("show", "--format=", "--unified=0", "-M", sha)
        if diff is None:
            return None
        out = []
        old_path = new_path = None
        in_header = False
        for line in diff.splitlines():
            if line.startswith("diff --git "):
                old_path = new_path = None
                in_header = True
                continue
            if in_header and line.startswith("--- "):
                m = re.match(r"^--- a/(.*)$", line)
                old_path = m.group(1) if m else None
                continue
            if in_header and line.startswith("+++ "):
                m = re.match(r"^\+\+\+ b/(.*)$", line)
                new_path = m.group(1) if m else None
                continue
            m = HUNK_RE.match(line)
            if m:
                in_header = False
                out.append({
                    "old_path": old_path,
                    "new_path": new_path,
                    "old_start": int(m.group(1)),
                    "old_count": int(m.group(2)) if m.group(2) is not None else 1,
                    "new_start": int(m.group(3)),
                    "new_count": int(m.group(4)) if m.group(4) is not None else 1,
                })
        return out

    def deleted_line_sources(self, sha):
        """Which commit wrote each line this commit deletes?

        This is the question the tool cannot answer about itself. A correction
        that deletes lines an earlier correction in the same run wrote is
        rework: the earlier correction was wrong or incomplete, whatever the
        ledger recorded for it.
        """
        parent = self.run("rev-parse", sha + "^")
        if not parent:
            return None
        parent = parent.strip()
        hunks = self.hunks(sha)
        if hunks is None:
            return None
        ranges = collections.defaultdict(list)
        for h in hunks:
            if not h["old_path"] or h["old_count"] <= 0:
                continue
            start = h["old_start"]
            ranges[h["old_path"]].append((start, start + h["old_count"] - 1))
        sources = collections.Counter()
        total = 0
        for path, spans in ranges.items():
            blame = self.blame_map(parent, path)
            for (lo, hi) in spans:
                for ln in range(lo, hi + 1):
                    origin = blame.get(ln)
                    if origin:
                        sources[origin] += 1
                        total += 1
        return {"total": total, "sources": sources}

    def added_line_survival(self, sha, head):
        """How many lines this commit added still stand at head?

        A correction whose lines were all overwritten before the branch was
        finished left nothing behind, however the ledger counted it.
        """
        hunks = self.hunks(sha)
        if hunks is None:
            return None
        added = collections.defaultdict(int)
        for h in hunks:
            if not h["new_path"] or h["new_count"] <= 0:
                continue
            added[h["new_path"]] += h["new_count"]
        total_added = sum(added.values())
        if total_added == 0:
            return {"added": 0, "surviving": 0}
        surviving = 0
        for path in added:
            blame = self.blame_map(head, path)
            for origin in blame.values():
                if origin == sha:
                    surviving += 1
        # Blame follows moved and copied lines, so attribution at head can
        # exceed what the diff counted as added. Clamp rather than report a
        # survival rate above 100%, which would be an artifact, not a finding.
        return {"added": total_added, "surviving": min(surviving, total_added)}


def open_db(path):
    """Open the live run database strictly read-only.

    It is the operating state of a pipeline that may be mid-run, so this must
    never write, never migrate, and never hold a write lock.
    """
    if not os.path.exists(path):
        return None
    uri = "file:%s?mode=ro" % path
    con = sqlite3.connect(uri, uri=True, timeout=10)
    con.row_factory = sqlite3.Row
    return con


def parse_findings(blob):
    if not blob:
        return []
    try:
        data = json.loads(blob)
    except (ValueError, TypeError):
        return []
    items = data.get("findings") if isinstance(data, dict) else data
    if not isinstance(items, list):
        return []
    return [f for f in items if isinstance(f, dict)]


def load_runs(con):
    cur = con.cursor()
    repos = {r["id"]: r["working_path"] for r in cur.execute("select id, working_path from repos")}
    runs = []
    for r in cur.execute("select * from runs order by created_at"):
        runs.append({
            "id": r["id"],
            "repo": repos.get(r["repo_id"], ""),
            "branch": r["branch"],
            "head": r["head_sha"],
            "base": r["base_sha"],
            "status": r["status"],
            "pr_url": r["pr_url"],
            "created_at": r["created_at"],
        })
    return runs


def load_rounds(con):
    cur = con.cursor()
    rows = []
    for r in cur.execute(
        "select sr.run_id, sr.step_name, sr.step_order, srd.round, srd.trigger_type,"
        " srd.findings_json, srd.fix_summary"
        " from step_rounds srd join step_results sr on sr.id = srd.step_result_id"
        " order by sr.run_id, sr.step_order, srd.round"
    ):
        rows.append({
            "run_id": r["run_id"],
            "step": r["step_name"],
            "step_order": r["step_order"],
            "round": r["round"],
            "trigger": r["trigger_type"],
            "findings": parse_findings(r["findings_json"]),
            "fix_summary": (r["fix_summary"] or "").strip(),
        })
    return rows


def tier_ledger(runs, rounds):
    """Structural audit of the tool's own bookkeeping.

    Every metric here is self-reported. It is included because the SHAPE of the
    ledger is still informative - how much the tool declined to decide, how many
    rounds it needed to go quiet - but none of it establishes that a finding was
    real, and it is labelled accordingly everywhere it is printed.
    """
    src = "no-mistakes state.sqlite (SELF-REPORTED by the tool under test)"
    metrics = []
    findings = [f for r in rounds for f in r["findings"]]
    total = len(findings)

    actions = collections.Counter(f.get("action") or "(unset)" for f in findings)
    severities = collections.Counter(f.get("severity") or "(unset)" for f in findings)

    metrics.append(Metric(
        "findings_total", total, total, src,
        "count of finding objects across every step round",
    ))
    ask = actions.get("ask-user", 0)
    metrics.append(Metric(
        "abstention_rate", 100.0 * ask / total if total else 0.0, total, src,
        "findings marked action=ask-user, i.e. the tool declined to decide and "
        "handed the judgement back to a human",
        unit="%",
        caveat="High abstention is not itself a fault; it is unpriced human "
               "workload that no self-reported fix rate accounts for.",
    ))
    metrics.append(Metric(
        "autofix_share", 100.0 * actions.get("auto-fix", 0) / total if total else 0.0,
        total, src, "findings the tool elected to fix itself", unit="%",
        caveat="Counts corrections ATTEMPTED, not corrections that helped. The "
               "git tier is what tests whether they helped.",
    ))
    metrics.append(Metric(
        "error_severity_share", 100.0 * severities.get("error", 0) / total if total else 0.0,
        total, src, "findings the tool labelled severity=error", unit="%",
        caveat="Severity is the tool's own label for its own finding.",
    ))

    # Rounds-to-quiescence: how many review passes before the step stopped
    # producing findings. Long tails mean corrections kept reopening the step.
    review_rounds = collections.defaultdict(int)
    for r in rounds:
        if r["step"] == "review":
            review_rounds[r["run_id"]] = max(review_rounds[r["run_id"]], r["round"])
    if review_rounds:
        vals = sorted(review_rounds.values())
        metrics.append(Metric(
            "review_rounds_median", float(vals[len(vals) // 2]), len(vals), src,
            "median highest review round number reached per run",
            caveat="Each extra round is a correction that did not settle the step.",
        ))
        metrics.append(Metric(
            "runs_needing_3plus_review_rounds",
            100.0 * sum(1 for v in vals if v >= 3) / len(vals), len(vals), src,
            "runs where review ran three or more times", unit="%",
        ))

    statuses = collections.Counter(r["status"] for r in runs)
    metrics.append(Metric(
        "run_completion_rate",
        100.0 * statuses.get("completed", 0) / len(runs) if runs else 0.0,
        len(runs), src, "runs with status=completed", unit="%",
    ))
    return {
        "metrics": metrics,
        "detail": {
            "actions": dict(actions),
            "severities": dict(severities),
            "run_statuses": dict(statuses),
        },
    }


def map_fix_commits(run, git, boundaries=frozenset()):
    """Find the pipeline's own fix commits for a run, and verify the mapping.

    The pipeline lands each correction as a real commit subject-prefixed
    `no-mistakes(<step>):`. Walking back from the recorded head and stopping at
    the first non-pipeline commit recovers the contiguous block of corrections
    that run appended. The mapping is only used when the recovered subjects
    actually match the fix summaries the database recorded, so an unverified
    guess is dropped rather than silently counted.

    A non-pipeline subject is NOT the only boundary. When two runs execute on
    the same branch with no author commit between them, the later run's walk
    runs straight into the earlier run's corrections and adopts them - which
    would make an earlier RUN's fix look like an earlier fix in THIS run, the
    exact invariant the rework metrics are defined on. `boundaries` carries the
    head commits other runs recorded in the same repository; the walk stops
    there, because that commit and everything behind it belongs to that run.
    """
    if not run["head"] or set(run["head"]) == {"0"}:
        return None
    if not git.has_commit(run["head"]):
        return None
    out = git.run("log", "--format=%H%x1f%s", "-n", "40", run["head"])
    if not out:
        return None
    chain = []
    for line in out.splitlines():
        if "\x1f" not in line:
            continue
        sha, subject = line.split("\x1f", 1)
        if chain and sha in boundaries:
            break
        m = FIX_SUBJECT_RE.match(subject)
        if not m:
            break
        chain.append({"sha": sha, "step": m.group(1), "summary": m.group(2).strip()})
    chain.reverse()
    return chain


def tier_git(runs, rounds, repo_roots, progress=None):
    """What actually happened to the code, independent of the tool's ledger.

    A fix commit's diff is not a claim the tool makes; it is the state of the
    repository. That makes it the only evidence here that can contradict the
    tool's own account of its usefulness.
    """
    src = "git history of the reviewed repositories (EXTERNAL to the tool)"
    metrics = []

    summaries = collections.defaultdict(set)
    for r in rounds:
        if r["fix_summary"]:
            summaries[r["run_id"]].add(r["fix_summary"])

    # Every other run's recorded head, per repository, bounds this run's walk so
    # one run cannot adopt another's corrections as its own.
    heads_by_repo = collections.defaultdict(set)
    for run in runs:
        if run["head"] and set(run["head"]) != {"0"}:
            heads_by_repo[run["repo"]].add(run["head"])

    mapped, unmapped_no_repo, unmapped_no_match = [], 0, 0
    for run in runs:
        root = repo_roots.get(run["repo"])
        if root is None or not root.available:
            unmapped_no_repo += 1
            continue
        boundaries = heads_by_repo[run["repo"]] - {run["head"]}
        chain = map_fix_commits(run, root, boundaries)
        if not chain:
            unmapped_no_match += 1
            continue
        # Verify against the ledger: at least one recovered subject must be a
        # fix summary the database recorded for this run.
        recorded = summaries.get(run["id"], set())
        if recorded and not any(c["summary"] in recorded for c in chain):
            unmapped_no_match += 1
            continue
        mapped.append({"run": run, "git": root, "chain": chain})

    metrics.append(Metric(
        "runs_git_resolved", len(mapped), len(runs), src,
        "runs whose pipeline fix commits were located in git AND matched the "
        "fix summaries the database recorded",
        caveat="Unresolved runs are excluded from every git metric rather than "
               "assumed clean. %d had no reachable clone, %d had no verifiable "
               "commit chain. Each chain also stops at any commit another run "
               "in the same repository recorded as its head, so a run that "
               "followed another on the same branch cannot absorb its "
               "corrections." % (unmapped_no_repo, unmapped_no_match),
    ))

    rework_num = rework_den = 0
    followup_num = followup_den = 0
    per_run_rework = []
    survival_num = survival_den = 0
    reworked_fixes = 0
    considered_fixes = 0
    step_rework = collections.defaultdict(lambda: [0, 0])

    for i, entry in enumerate(mapped):
        if progress:
            progress(i + 1, len(mapped), entry["run"]["id"])
        git = entry["git"]
        chain = entry["chain"]
        seen = set()
        run_num = run_den = 0
        for c in chain:
            info = git.deleted_line_sources(c["sha"])
            # Every non-first fix commit enters the denominator, including one
            # that deleted nothing or whose deletions had no resolvable blame
            # origin. Counting only the resolvable ones would quietly narrow the
            # denominator to a strictly smaller set than the stated method names.
            is_followup = bool(seen)
            if is_followup:
                considered_fixes += 1
            if info and info["total"]:
                # Only lines written by an EARLIER fix in this same run count as
                # rework. Deleting the author's own code is the review doing its
                # job, not correcting itself.
                prior = sum(n for sha, n in info["sources"].items() if sha in seen)
                rework_num += prior
                rework_den += info["total"]
                run_num += prior
                run_den += info["total"]
                step_rework[c["step"]][0] += prior
                step_rework[c["step"]][1] += info["total"]
                if is_followup:
                    followup_num += prior
                    followup_den += info["total"]
                    if prior:
                        reworked_fixes += 1
            surv = git.added_line_survival(c["sha"], entry["run"]["head"])
            if surv and surv["added"]:
                survival_num += surv["surviving"]
                survival_den += surv["added"]
            seen.add(c["sha"])
        if run_den:
            per_run_rework.append((entry["run"]["id"], 100.0 * run_num / run_den, run_den))

    if rework_den:
        metrics.append(Metric(
            "fix_rework_rate", 100.0 * rework_num / rework_den, rework_den, src,
            "share of all lines deleted by pipeline fix commits that an EARLIER "
            "fix commit in the same run had written (git blame of the parent)",
            unit="%",
            caveat="This is the measurement the tool cannot make about itself. "
                   "Every such line is a correction that had to be corrected, "
                   "yet the ledger counted both as fixes. The denominator "
                   "includes each run's FIRST fix, which by definition can "
                   "rework nothing, so this understates the rate among the "
                   "follow-up fixes where the effect actually lives.",
        ))
    if followup_den:
        metrics.append(Metric(
            "fix_rework_rate_followups", 100.0 * followup_num / followup_den,
            followup_den, src,
            "same measurement restricted to fix commits that had an earlier fix "
            "in the same run to rework", unit="%",
            caveat="The sharp version of the number above: of the lines a "
                   "follow-up correction removed, this share was written by the "
                   "pipeline's own earlier correction rather than by the author.",
        ))
    if considered_fixes:
        metrics.append(Metric(
            "fixes_that_reworked_a_prior_fix",
            100.0 * reworked_fixes / considered_fixes, considered_fixes, src,
            "share of non-first fix commits that deleted at least one line an "
            "earlier fix in the same run wrote", unit="%",
            caveat="The denominator is EVERY non-first fix commit, including "
                   "ones that deleted nothing and ones whose deleted lines had "
                   "no resolvable blame origin. Those cannot rework anything "
                   "that can be shown, so they count against the rate rather "
                   "than being dropped from it.",
        ))
    if survival_den:
        metrics.append(Metric(
            "fix_line_survival", 100.0 * survival_num / survival_den, survival_den, src,
            "share of lines added by fix commits that still stand at the run's "
            "final head (git blame of head)", unit="%",
            caveat="Lines that did not survive were overwritten before the "
                   "branch finished, so that correction left nothing behind.",
        ))

    detail = {
        "per_run_rework": sorted(per_run_rework, key=lambda t: -t[1])[:15],
        "step_rework": {k: v for k, v in step_rework.items()},
        "unmapped_no_repo": unmapped_no_repo,
        "unmapped_no_match": unmapped_no_match,
        "mapped_runs": len(mapped),
    }
    return {"metrics": metrics, "detail": detail}


def load_corpus(corpus_dir):
    cases = []
    if not os.path.isdir(corpus_dir):
        return cases
    for name in sorted(os.listdir(corpus_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(corpus_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                case = json.load(fh)
        except (OSError, ValueError) as exc:
            cases.append({"case_id": name, "_error": str(exc)})
            continue
        case["_path"] = path
        cases.append(case)
    return cases


# A case is admissible at tier 1 only if its proof is something that was
# observed happening, not something a reviewer concluded. Anything else is
# reported separately so a weaker answer key can never quietly inflate a score.
EXECUTED_PROOF_KINDS = {"executed-reproduction", "failing-test", "ci-failure", "revert-commit"}


def validate_case(case):
    problems = []
    for field in ("case_id", "repo", "defect_commit", "defect_paths", "detection", "proof"):
        if not case.get(field):
            problems.append("missing %s" % field)
    proof = case.get("proof") or {}
    kind = proof.get("kind")
    if kind and kind not in EXECUTED_PROOF_KINDS and kind != "asserted":
        problems.append("unknown proof kind %s" % kind)
    if kind in EXECUTED_PROOF_KINDS and not proof.get("evidence"):
        problems.append("executed proof needs an evidence pointer")
    det = case.get("detection") or {}
    if det and not (det.get("must_match_any") or det.get("must_mention_paths")):
        problems.append("detection needs must_match_any or must_mention_paths")
    for pattern in (det.get("must_match_any") or []):
        try:
            re.compile(pattern)
        except re.error as exc:
            problems.append("bad regex %r: %s" % (pattern, exc))
    return problems


def case_tier(case):
    kind = ((case.get("proof") or {}).get("kind")) or "asserted"
    return 1 if kind in EXECUTED_PROOF_KINDS else 2


def resolve_case_repo(case):
    """Find a clone that actually contains this case's commits.

    Corpus files are shared and tracked, so they cannot hardcode one machine's
    paths. Candidates are tried in order and accepted only when the defect
    commit is really present, which makes the resolution self-checking instead
    of a guess that fails confusingly later.
    """
    name = case.get("repo") or ""
    sha = case.get("defect_commit") or ""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = []
    if case.get("repo_path"):
        candidates.append(os.path.expanduser(case["repo_path"]))
    env = os.environ.get("FM_GRADE_REPO_%s" % re.sub(r"[^A-Za-z0-9]", "_", name).upper())
    if env:
        candidates.append(os.path.expanduser(env))
    fm_home = os.environ.get("FM_HOME")
    if fm_home:
        candidates.append(os.path.join(fm_home, "projects", name))
    candidates.append(here)
    candidates.append(os.path.join(os.path.dirname(here), name))
    for cand in candidates:
        if cand and os.path.isdir(cand):
            git = Git(cand)
            if sha and git.has_commit(sha):
                return cand
    return None


def verify_case_repro(case, tmpdir):
    """Re-prove a corpus case by executing it, instead of trusting its writeup.

    An answer key nobody re-checks decays into folklore: someone eventually
    disputes a case and there is only a paragraph to argue with. So a case may
    carry a `reproduce` block, and this runs it end to end - the subject is
    extracted at the defect commit and must exhibit the defect, then extracted
    at the fixing commit and must not. Proving both directions is what rules out
    a fixture that never tested anything.

    The corpus is tracked repository material reviewed like any other code, and
    the declared command is run in a throwaway directory under a timeout.
    """
    rep = (case.get("proof") or {}).get("reproduce")
    if not rep:
        return None
    repo = resolve_case_repo(case)
    if not repo:
        return {"ok": False, "why": "no clone found containing %s"
                                    % (case.get("defect_commit") or "?")[:12]}
    git = Git(repo)
    results = {}
    for phase, ref_key in (("defect", "defect_commit"), ("fixed", "fixed_commit")):
        expect = rep.get("%s_expect" % phase)
        if not expect:
            continue
        ref = case.get(ref_key)
        if not ref or not git.has_commit(ref):
            return {"ok": False, "why": "commit %s unavailable" % ref}
        work = os.path.join(tmpdir, "%s-%s" % (case["case_id"], phase))
        os.makedirs(work, exist_ok=True)
        for item in rep.get("extract", []):
            blob = git.run("show", "%s:%s" % (ref, item["path"]))
            if blob is None:
                return {"ok": False, "why": "cannot extract %s at %s" % (item["path"], ref)}
            dest = os.path.join(work, item["as"])
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write(blob)
            if item.get("mode"):
                os.chmod(dest, int(item["mode"], 8))
        for name, body in (rep.get("fixture") or {}).items():
            with open(os.path.join(work, name), "w", encoding="utf-8") as fh:
                fh.write(body)
        try:
            proc = subprocess.run(rep["command"], cwd=work, capture_output=True,
                                  text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"ok": False, "why": "command failed to run: %s" % exc}
        combined = (proc.stdout or "") + (proc.stderr or "")
        ok = True
        why = []
        if "exit" in expect and proc.returncode != expect["exit"]:
            ok = False
            why.append("%s exit %d, expected %d" % (phase, proc.returncode, expect["exit"]))
        pattern = expect.get("output_matches")
        if pattern and not re.search(pattern, combined):
            ok = False
            why.append("%s output did not match %r" % (phase, pattern))
        results[phase] = {"ok": ok, "why": "; ".join(why), "exit": proc.returncode}
        if not ok:
            return {"ok": False, "why": "; ".join(why), "phases": results}
    if not results:
        return {"ok": False, "why": "reproduce block declares no expectations"}
    return {"ok": True, "why": "defect reproduces at the defect commit and is "
                               "absent at the fixing commit", "phases": results}


def score_submission(case, findings):
    """Did a blind candidate report this case's defect?

    Detection is deliberately generous on wording and strict on location: a
    candidate should not lose a point for phrasing, but pointing at the wrong
    file is not a detection. The candidate never sees this file, so it cannot
    tune to the oracle.

    STRICT is the scored rule and it matches the finding's own `file` field. A
    finding that names the wrong file is wrong however its prose reads, because
    acting on it sends a reader to the wrong place; prose that happens to quote
    the expected path somewhere in an argument is not a location.

    LENIENT also accepts the path appearing anywhere in the finding's text. It
    is computed and reported alongside the strict figure rather than folded into
    it, because the gap between the two is itself the measurement of how
    precisely the candidate localises what it found. Burying that gap inside a
    scoring choice would hide it; only the strict number is scored.

    Returns {"strict": finding|None, "lenient": finding|None}. A strict hit is
    always a lenient hit, so lenient >= strict by construction.
    """
    det = case.get("detection") or {}
    paths = set(det.get("must_mention_paths") or [])
    patterns = [re.compile(p) for p in (det.get("must_match_any") or [])]
    if not paths and not patterns:
        return {"strict": None, "lenient": None}
    strict = lenient = None
    for f in findings:
        text = " ".join(str(f.get(k, "")) for k in ("file", "id", "description", "summary", "title"))
        if patterns and not any(p.search(text) for p in patterns):
            continue
        if paths:
            fpath = str(f.get("file") or "")
            located = any(p == fpath for p in paths)
            mentioned = located or any(p in text for p in paths)
        else:
            located = mentioned = True
        if located and strict is None:
            strict = f
        if mentioned and lenient is None:
            lenient = f
        if strict is not None and lenient is not None:
            break
    return {"strict": strict, "lenient": lenient}


def tier_bench(corpus, submission_path):
    src = "sealed defect corpus (bin/fm-grade-corpus) scored against a BLIND candidate run"
    metrics = []
    valid = [c for c in corpus if not c.get("_error") and not validate_case(c)]
    invalid = [c for c in corpus if c.get("_error") or validate_case(c)]
    tier1 = [c for c in valid if case_tier(c) == 1]
    tier2 = [c for c in valid if case_tier(c) == 2]

    metrics.append(Metric(
        "corpus_cases_admissible", len(tier1), len(corpus), src,
        "cases whose proof that the defect was real is an OBSERVED event "
        "(executed reproduction, failing test, CI failure, or revert), not a "
        "reviewer's assertion",
        caveat="%d further case(s) rest on assertion and are scored separately; "
               "%d case(s) are malformed." % (len(tier2), len(invalid)),
    ))

    if not submission_path:
        metrics.append(Metric(
            "blind_detection_rate", None, len(tier1), "no candidate submitted",
            "share of admissible cases the candidate found without being told "
            "they existed", unit="%",
            caveat="No candidate has been run against this corpus yet. The scale "
                   "exists and is fixed; the score is simply not taken.",
        ))
        return {"metrics": metrics, "detail": {"tier1": len(tier1), "tier2": len(tier2),
                                               "invalid": [c.get("case_id") for c in invalid]}}

    with open(submission_path, "r", encoding="utf-8") as fh:
        submission = json.load(fh)
    results = []
    hits = 0
    lenient_hits = 0
    noise_total = 0
    for case in tier1:
        reported = submission.get(case["case_id"]) or {}
        findings = reported.get("findings") or []
        scored = score_submission(case, findings)
        hit = scored["strict"]
        if hit:
            hits += 1
        if scored["lenient"]:
            lenient_hits += 1
        noise_total += max(0, len(findings) - (1 if hit else 0))
        results.append({"case_id": case["case_id"], "detected": bool(hit),
                        "detected_lenient": bool(scored["lenient"]),
                        "findings_emitted": len(findings)})
    lo, hi = wilson_interval(hits, len(tier1))
    metrics.append(Metric(
        "blind_detection_rate", 100.0 * hits / len(tier1) if tier1 else None,
        len(tier1), src + " | candidate: " + os.path.basename(submission_path),
        "share of admissible cases the candidate found without being told they "
        "existed, matching the finding's own `file` field against the case's "
        "path (STRICT - this is the scored rule)", unit="%",
        caveat="95%% Wilson interval %.0f-%.0f%%. At n=%d this interval is wide; "
               "it is reported so the number is not read as precision it does "
               "not have. A finding that names the wrong file does not count "
               "however its prose reads, because acting on it sends a reader to "
               "the wrong place." % ((lo or 0) * 100, (hi or 0) * 100, len(tier1)),
    ))
    llo, lhi = wilson_interval(lenient_hits, len(tier1))
    metrics.append(Metric(
        "blind_detection_rate_lenient",
        100.0 * lenient_hits / len(tier1) if tier1 else None,
        len(tier1), src + " | candidate: " + os.path.basename(submission_path),
        "the same replay scored LENIENTLY, accepting the case's path anywhere "
        "in the finding's text rather than in its `file` field", unit="%",
        caveat="95%% Wilson interval %.0f-%.0f%%. NOT the score - reported "
               "alongside it so the gap is visible rather than buried in a "
               "scoring choice. The distance from `blind_detection_rate` (%d vs "
               "%d of %d cases) measures how precisely the candidate localises "
               "what it found."
               % ((llo or 0) * 100, (lhi or 0) * 100, lenient_hits, hits, len(tier1)),
    ))
    if tier1:
        metrics.append(Metric(
            "findings_alongside_per_case", noise_total / len(tier1), len(tier1),
            src, "findings the candidate emitted per case beyond the one that "
                 "matched the answer key",
            caveat="Not a false-positive rate. These are unadjudicated; only the "
                   "materiality tier can say whether they were wrong.",
        ))
    return {"metrics": metrics, "detail": {"results": results, "tier1": len(tier1),
                                           "tier2": len(tier2)}}


def build_pool(rounds):
    """Every finding that could be sampled, with a stable ballot identity.

    The identity is derived from the finding's own coordinates rather than its
    position in a query result, so a ballot drawn today can still be joined back
    to its stratum after the pipeline has kept running.
    """
    pool = []
    for r in rounds:
        for idx, f in enumerate(r["findings"]):
            pool.append({
                "ballot_id": hashlib.sha1(
                    ("%s|%s|%d|%d|%s" % (r["run_id"], r["step"], r["round"], idx,
                                         f.get("id", ""))).encode("utf-8")
                ).hexdigest()[:12],
                "run_id": r["run_id"],
                "step": r["step"],
                "round": r["round"],
                "severity": f.get("severity") or "(unset)",
                "action": f.get("action") or "(unset)",
                "file": f.get("file") or "",
                "line": f.get("line"),
                "description": redact(str(f.get("description") or "")),
            })
    return pool


def build_sample(rounds, size, seed):
    """Draw a reproducible, stratified, blind sample of findings.

    Stratified by severity so the rare error-severity findings are actually
    represented; seeded so anyone can redraw the identical sample and check the
    adjudication rather than take it on trust.

    The stratification is why results are reported PER STRATUM and never pooled:
    equal allocation makes the ballot's composition differ from the population's
    on purpose, and the only way to collapse it back would be to weight by the
    graded tool's own severity labels, which is the dependence this scale exists
    to remove.
    """
    pool = build_pool(rounds)
    strata = collections.defaultdict(list)
    for item in pool:
        strata[item["severity"]].append(item)
    rng = random.Random(seed)
    chosen = []
    leftover = []
    names = sorted(strata)
    per = max(1, size // max(1, len(names)))
    for name in names:
        # Sort before shuffling so the draw depends only on the seed, not on
        # the order sqlite happened to return rows in.
        bucket = sorted(strata[name], key=lambda x: x["ballot_id"])
        rng.shuffle(bucket)
        chosen.extend(bucket[:per])
        leftover.extend(bucket[per:])
    # Even strata rarely divide the requested size exactly; top up from the
    # remainder so the sample the reader was promised is the sample drawn.
    if len(chosen) < size:
        rng.shuffle(leftover)
        chosen.extend(leftover[:size - len(chosen)])
    rng.shuffle(chosen)
    return chosen[:size], len(pool)


def tier_materiality(rounds, ballots_path, seed):
    """Whether a finding would really have hurt. Not computed - adjudicated.

    There is no evidence in the run database that answers this, and asking a
    model to read the finding's own argument would measure how persuasive the
    text is rather than whether the defect is real. So the engine produces the
    instrument and refuses to produce the number.
    """
    metrics = []
    pool = build_pool(rounds)
    pool_size = len(pool)
    if ballots_path and not os.path.exists(ballots_path):
        # Falling through to UNADJUDICATED here would print "Deliberately
        # absent" at an operator who believes they just supplied signed
        # verdicts - a false provenance claim in the one tier whose whole
        # purpose is refusing to assert what it cannot source.
        raise SystemExit("fm-grade: --ballots file not found: %s" % ballots_path)
    if not ballots_path:
        metrics.append(Metric(
            "material_finding_rate", None, 0,
            "UNADJUDICATED - requires a named human adjudicator",
            "share of sampled findings a blind human adjudicator rated as "
            "would-have-caused-real-damage-at-merge", unit="%",
            caveat="Deliberately absent. Population is %d findings; run "
                   "`fm-grade.sh sample` to draw the blind ballot. No number is "
                   "produced from the tool's own severity labels, because those "
                   "are the self-assessment this scale exists to replace."
                   % pool_size,
        ))
        return {"metrics": metrics, "detail": {"pool": pool_size, "status": "unadjudicated"}}

    with open(ballots_path, "r", encoding="utf-8") as fh:
        ballots = json.load(fh)
    adjudicator = ballots.get("adjudicator") or ""
    if not adjudicator:
        raise SystemExit("fm-grade: ballot file has no `adjudicator` - a verdict "
                         "without a named judge is exactly what this replaces")
    # Provenance is checked, not asserted. Printing `--seed` as the recipe for
    # redrawing a ballot that was drawn under a different seed would send a
    # reader after a sample that cannot be reconciled with this one.
    drawn_seed = ballots.get("seed")
    if drawn_seed is not None and str(drawn_seed) != str(seed):
        raise SystemExit(
            "fm-grade: ballot records seed %r but --seed is %r - the report "
            "would print an unreproducible recipe. Re-run with --seed %s, or "
            "redraw and re-adjudicate." % (drawn_seed, seed, drawn_seed))
    drawn_population = ballots.get("population")

    verdicts = [b for b in ballots.get("ballots", []) if b.get("verdict")]
    unknown = sorted({str(b["verdict"]) for b in verdicts} - set(BALLOT_VERDICTS))
    if unknown:
        raise SystemExit(
            "fm-grade: ballot has unrecognised verdict(s) %s - accepted values "
            "are %s, and an empty verdict abstains. An unrecognised string would "
            "count into n while contributing to no rate."
            % (", ".join(repr(u) for u in unknown), ", ".join(BALLOT_VERDICTS)))

    # Rejoin each verdict to the stratum it was drawn from. The stratum is NOT
    # carried in the ballot on purpose - showing the adjudicator the tool's own
    # severity label would re-import the self-assessment this scale replaces -
    # so it is recovered here from the finding's stable ballot identity.
    stratum_of = {item["ballot_id"]: item["severity"] for item in pool}
    by_stratum = collections.defaultdict(collections.Counter)
    for b in verdicts:
        by_stratum[stratum_of.get(b.get("ballot_id"), "(no longer in pool)")][b["verdict"]] += 1

    n = len(verdicts)
    src = "blind human adjudication by %s (labels stripped)" % adjudicator
    frame_note = (
        "The strata are the GRADED TOOL'S OWN severity labels, so the sampling "
        "FRAME is not independent of the tool under test even though each "
        "verdict is. Rates are therefore reported per stratum and never pooled "
        "into one headline: pooling would have to weight by those same labels.")
    for stratum in sorted(by_stratum):
        counts = by_stratum[stratum]
        sn = sum(counts.values())
        for verdict, label in (("harmful", "material_finding_rate"),
                               ("minor", "minor_finding_rate"),
                               ("wrong", "false_positive_rate")):
            k = counts.get(verdict, 0)
            lo, hi = wilson_interval(k, sn)
            metrics.append(Metric(
                "%s[severity=%s]" % (label, stratum),
                100.0 * k / sn if sn else None, sn, src,
                "blind verdict `%s` among sampled findings the tool had "
                "labelled severity=%s" % (verdict, stratum), unit="%",
                caveat="95%% Wilson interval %.0f-%.0f%%. Ballot drawn with seed "
                       "%s from a population of %s findings (%d in the pool now); "
                       "redraw and re-adjudicate to challenge it. %s"
                       % ((lo or 0) * 100, (hi or 0) * 100, seed,
                          drawn_population if drawn_population is not None else "?",
                          pool_size, frame_note),
            ))
    return {"metrics": metrics,
            "detail": {"pool": pool_size, "adjudicated": n,
                       "adjudicator": adjudicator,
                       "drawn_seed": drawn_seed,
                       "drawn_population": drawn_population,
                       "counts_by_stratum": {k: dict(v) for k, v in by_stratum.items()},
                       "pooled_rate_withheld":
                           "Deliberately not computed. " + frame_note}}


def render_report(snapshot, tiers, out):
    w = out.write
    w("# Review-quality grade\n\n")
    w("Produced by `bin/fm-grade.sh report`.\n")
    w("Every number below carries the evidence class it came from and the sample it was computed over.\n")
    w("Numbers from different evidence classes are reported separately and are never combined into a single score.\n\n")
    w("- Snapshot taken: %s\n" % snapshot["taken"])
    w("- Run database: %s (opened read-only)\n" % snapshot["db"])
    w("- Runs in snapshot: %d, finding objects: %d, latest run: %s\n"
      % (snapshot["runs"], snapshot["findings"], snapshot["latest"]))
    w("- Counts drift as the pipeline keeps running, so this snapshot is the "
      "only figure this report defends.\n\n")

    order = [
        ("ledger", "Tier L - the tool's own ledger (SELF-REPORTED)",
         "These are structural facts about the bookkeeping, not evidence that any "
         "finding was real.\nThey are listed first so they are read as what they "
         "are: the incumbent's own account of itself."),
        ("git", "Tier G - what actually happened to the code (INDEPENDENT)",
         "Every correction lands as a real commit, so its diff is a fact rather "
         "than a claim.\n`git blame` can therefore answer the question the tool "
         "cannot answer about itself: did this correction delete a line an "
         "earlier correction in the same run wrote?"),
        ("bench", "Tier B - blind replay against known-real defects (INDEPENDENT)",
         "The answer key is sealed before the candidate runs and the candidate is "
         "never told what it is looking for.\nA case counts only if the proof "
         "that its defect was real is something that was observed, not something "
         "a reviewer concluded."),
        ("materiality", "Tier M - materiality (HUMAN, SAMPLED)",
         "Whether a finding would really have hurt at merge cannot be computed "
         "from this data.\nThe engine draws a reproducible blind sample and "
         "reports UNADJUDICATED until a named human returns verdicts.\nThe "
         "sample is stratified by the graded tool's own severity labels, so "
         "rates are reported per stratum with their own n and interval.\nThere "
         "is deliberately no pooled headline rate: collapsing the strata would "
         "have to weight them by those same labels, which is the dependence "
         "this scale exists to remove."),
    ]
    for key, title, blurb in order:
        tier = tiers.get(key)
        if not tier:
            continue
        w("## %s\n\n%s\n\n" % (title, blurb))
        w("| metric | value | n | judgement source |\n|---|---|---|---|\n")
        for m in tier["metrics"]:
            w("| `%s` | %s | %s | %s |\n" % (m.key, m.render(), m.n, m.source))
        w("\n")
        for m in tier["metrics"]:
            if m.caveat:
                w("- **%s** - %s %s\n" % (m.key, m.method + ".", m.caveat))
            else:
                w("- **%s** - %s.\n" % (m.key, m.method))
        w("\n")

    git_detail = (tiers.get("git") or {}).get("detail") or {}
    worst = git_detail.get("per_run_rework") or []
    if worst:
        w("### Runs where corrections most undid earlier corrections\n\n")
        w("Rework share is git-derived, so it does not depend on the tool agreeing that it happened.\n\n")
        w("| run | rework share of deleted lines | deleted lines examined |\n|---|---|---|\n")
        for run_id, pct, den in worst[:10]:
            w("| `%s` | %.0f%% | %d |\n" % (run_id, pct, den))
        w("\n")

    w("## What this grade does not claim\n\n")
    w("- It does not certify that any individual finding was correct; only the materiality tier can, and only for a sample.\n")
    w("- It does not measure defects the review never reported, except through the blind corpus.\n")
    w("- It gates nothing. It produces a reading a human interprets, and it is wired to no pipeline decision.\n")


def cmd_report(args):
    # A mistyped path must be loud. Silently reporting UNADJUDICATED or an
    # unscored corpus at an operator who believes they just supplied evidence
    # would be a false provenance claim, which is the one thing this engine
    # must never make.
    for flag, path in (("--ballots", args.ballots), ("--submission", args.submission)):
        if path and not os.path.exists(path):
            raise SystemExit("fm-grade: %s file not found: %s" % (flag, path))
    con = open_db(args.db)
    if con is None:
        raise SystemExit("fm-grade: no run database at %s" % args.db)
    runs = load_runs(con)
    rounds = load_rounds(con)
    con.close()
    snapshot = {
        "taken": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()),
        "db": args.db,
        "runs": len(runs),
        "findings": sum(len(r["findings"]) for r in rounds),
        "latest": time.strftime("%Y-%m-%d", time.localtime(max((r["created_at"] for r in runs), default=0))),
    }
    roots = {}
    for run in runs:
        if run["repo"] and run["repo"] not in roots:
            roots[run["repo"]] = Git(run["repo"])

    def progress(i, total, run_id):
        if not args.quiet:
            sys.stderr.write("\rfm-grade: git tier %d/%d (%s)" % (i, total, run_id[:12]))
            sys.stderr.flush()

    tiers = {"ledger": tier_ledger(runs, rounds)}
    if not args.no_git:
        tiers["git"] = tier_git(runs, rounds, roots, progress=progress)
        if not args.quiet:
            sys.stderr.write("\r" + " " * 60 + "\r")
    tiers["bench"] = tier_bench(load_corpus(args.corpus), args.submission)
    tiers["materiality"] = tier_materiality(rounds, args.ballots, args.seed)

    out = open(args.out, "w", encoding="utf-8") if args.out else sys.stdout
    try:
        if args.json:
            payload = {"snapshot": snapshot,
                       "tiers": {k: {"metrics": [m.as_dict() for m in v["metrics"]],
                                     "detail": v.get("detail", {})} for k, v in tiers.items()}}
            json.dump(payload, out, indent=2, default=str)
            out.write("\n")
        else:
            render_report(snapshot, tiers, out)
    finally:
        if args.out:
            out.close()
            sys.stderr.write("fm-grade: wrote %s\n" % args.out)
    return 0


def cmd_sample(args):
    con = open_db(args.db)
    if con is None:
        raise SystemExit("fm-grade: no run database at %s" % args.db)
    rounds = load_rounds(con)
    con.close()
    chosen, pool = build_sample(rounds, args.sample_size, args.seed)
    ballot = {
        "adjudicator": "",
        "seed": args.seed,
        "population": pool,
        "drawn": len(chosen),
        "instructions": (
            "Blind adjudication. The tool's own severity and action labels have "
            "been withheld on purpose - judging them would re-import the "
            "self-assessment this scale replaces. For each entry read the cited "
            "code at the given file and line, then set `verdict` to exactly one "
            "of: `harmful` (merging without this fixed would have caused real "
            "damage), `minor` (correct but cosmetic or stylistic), `wrong` (the "
            "finding is mistaken). Leave `verdict` empty to abstain; abstentions "
            "are excluded from n rather than counted as agreement. Put your name "
            "in `adjudicator` - an unsigned verdict is not accepted."
        ),
        "ballots": [
            {
                "ballot_id": c["ballot_id"],
                "run_id": c["run_id"],
                "step": c["step"],
                "round": c["round"],
                "file": c["file"],
                "line": c["line"],
                "claim": c["description"],
                "verdict": "",
                "note": "",
            }
            for c in chosen
        ],
    }
    out = open(args.out, "w", encoding="utf-8") if args.out else sys.stdout
    try:
        json.dump(ballot, out, indent=2)
        out.write("\n")
    finally:
        if args.out:
            out.close()
            sys.stderr.write("fm-grade: wrote blind ballot %s (%d of %d findings, seed %s)\n"
                             % (args.out, len(chosen), pool, args.seed))
    return 0


def cmd_corpus(args):
    corpus = load_corpus(args.corpus)
    if not corpus:
        sys.stderr.write("fm-grade: no cases in %s\n" % args.corpus)
        return 1
    bad = 0
    for case in corpus:
        cid = case.get("case_id", case.get("_path", "?"))
        if case.get("_error"):
            print("INVALID  %s: %s" % (cid, case["_error"]))
            bad += 1
            continue
        problems = validate_case(case)
        if problems:
            print("INVALID  %s: %s" % (cid, "; ".join(problems)))
            bad += 1
            continue
        proof = case.get("proof", {})
        line = "tier%d    %-38s %-22s" % (case_tier(case), cid, proof.get("kind", "?"))
        if args.verify:
            import tempfile
            with tempfile.TemporaryDirectory(prefix="fm-grade-verify-") as tmp:
                res = verify_case_repro(case, tmp)
            if res is None:
                line += "  repro: NONE DECLARED"
            elif res["ok"]:
                line += "  repro: RE-PROVEN"
            else:
                line += "  repro: FAILED (%s)" % res["why"]
                bad += 1
        print(line)
    if bad:
        sys.stderr.write("fm-grade: %d case(s) invalid or unproven\n" % bad)
    return 1 if bad else 0


def cmd_replay(args):
    """Emit the blind task list a candidate is given.

    It carries the commit to inspect and nothing else. Withholding the file,
    the class of defect, and the count is what makes the result a detection
    rather than a confirmation.
    """
    corpus = [c for c in load_corpus(args.corpus) if not c.get("_error") and not validate_case(c)]
    tasks = []
    for case in corpus:
        if args.tier1_only and case_tier(case) != 1:
            continue
        tasks.append({
            "case_id": case["case_id"],
            "repo": case["repo"],
            "inspect_commit": case["defect_commit"],
            "task": ("Review this commit as you normally would and report every "
                     "defect you find. You are not told whether this commit "
                     "contains a known defect, what kind, where, or how many."),
        })
    json.dump({"cases": tasks,
               "submission_format": {
                   "<case_id>": {"findings": [{"file": "path", "description": "text"}]}
               }}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="fm-grade-engine", add_help=True)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-git", action="store_true")
    ap.add_argument("--seed", default="fm-grade-v1")
    ap.add_argument("--sample-size", type=int, default=40)
    ap.add_argument("--ballots", default="")
    ap.add_argument("--submission", default="")
    ap.add_argument("--tier1-only", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("command", choices=("report", "sample", "corpus", "replay"))
    args = ap.parse_args(argv)
    return {
        "report": cmd_report,
        "sample": cmd_sample,
        "corpus": cmd_corpus,
        "replay": cmd_replay,
    }[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
