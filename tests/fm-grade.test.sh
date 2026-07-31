#!/usr/bin/env bash
# Behavior tests for the review-quality scale (bin/fm-grade.sh).
#
# The load-bearing test here is rework detection: the scale's whole claim to
# independence is that git can show a correction undoing an earlier correction
# when the tool's own ledger records both as successes. That is proven against a
# synthetic repository with a known answer rather than against live history,
# so the assertion has a fixed expected value.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRADE="$ROOT/bin/fm-grade.sh"
ENGINE="$ROOT/bin/fm-grade-engine.py"
fm_test_tmproot TMP_ROOT fm-grade

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

CORPUS=$TMP_ROOT/corpus
mkdir -p "$CORPUS"

# --- a synthetic repo whose rework answer we know exactly -------------------
#
# work   writes five lines
# fix-1  replaces line two          -> deletes 1 author line, 0 pipeline lines
# fix-2  replaces what fix-1 wrote  -> deletes 1 pipeline line, 0 author lines
#
# So among follow-up fixes every deleted line is rework: 100%.

REPO=$TMP_ROOT/repo
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "Test"

printf 'one\ntwo\nthree\nfour\nfive\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm "work: author writes the file"

printf 'one\nTWO-fix1\nthree\nfour\nfive\n' > "$REPO/file.txt"
git -C "$REPO" commit -qam "no-mistakes(review): first correction"

printf 'one\nTWO-fix2\nthree\nfour\nfive\n' > "$REPO/file.txt"
git -C "$REPO" commit -qam "no-mistakes(review): second correction"

HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

# --- a synthetic run database matching that repo ----------------------------

DB=$TMP_ROOT/state.sqlite
python3 - "$DB" "$REPO" "$HEAD_SHA" <<'PY'
import sqlite3, sys
db, repo, head = sys.argv[1], sys.argv[2], sys.argv[3]
con = sqlite3.connect(db)
con.executescript("""
create table repos(id text primary key, working_path text, upstream_url text,
                   default_branch text, created_at integer);
create table runs(id text primary key, repo_id text, branch text, head_sha text,
                  base_sha text, status text, pr_url text, created_at integer,
                  updated_at integer);
create table step_results(id text primary key, run_id text, step_name text,
                          step_order integer, status text);
create table step_rounds(id text primary key, step_result_id text, round integer,
                         trigger_type text, findings_json text,
                         user_findings_json text, fix_summary text,
                         duration_ms integer, created_at integer);
""")
con.execute("insert into repos values('r1',?,'u','main',0)", (repo,))
con.execute("insert into runs values('run1','r1','b',?,?,'completed',null,1,1)",
            (head, "0" * 40))
con.execute("insert into step_results values('s1','run1','review',3,'completed')")
findings = ('{"findings":[{"id":"f1","severity":"error","action":"ask-user",'
            '"file":"file.txt","line":2,"description":"token=abcdefghijklmnop leaked"},'
            '{"id":"f2","severity":"warning","action":"auto-fix","file":"file.txt",'
            '"line":3,"description":"second claim"}]}')
con.execute("insert into step_rounds values('r1a','s1',1,'initial',?,null,'',0,1)",
            (findings,))
con.execute("insert into step_rounds values('r1b','s1',2,'auto_fix',null,null,"
            "'first correction',0,1)")
con.execute("insert into step_rounds values('r1c','s1',3,'auto_fix',null,null,"
            "'second correction',0,1)")
con.commit()
con.close()
PY

run_engine() {  # <args...>
  python3 "$ENGINE" --db "$DB" --corpus "$CORPUS" --quiet "$@"
}

# --- rework detection -------------------------------------------------------

OUT=$(run_engine --json report 2>/dev/null) || fail "engine report failed"

get_metric() {  # <tier> <key>
  printf '%s' "$OUT" | python3 -c '
import json, sys
tier, key = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
for m in d["tiers"][tier]["metrics"]:
    if m["key"] == key:
        print(m["value"])
        break
else:
    print("MISSING")
' "$1" "$2"
}

[ "$(get_metric git runs_git_resolved)" = "1" ] \
  || fail "git tier did not resolve the synthetic run (got $(get_metric git runs_git_resolved))"

FOLLOWUP=$(get_metric git fix_rework_rate_followups)
[ "$FOLLOWUP" = "100.0" ] \
  || fail "follow-up rework rate should be 100.0 for the synthetic repo, got $FOLLOWUP"

REWORKED=$(get_metric git fixes_that_reworked_a_prior_fix)
[ "$REWORKED" = "100.0" ] \
  || fail "every follow-up fix reworked a prior fix here, got $REWORKED"

# The first correction deletes only author code, so the all-fixes rate must be
# strictly lower than the follow-up-only rate. If these ever match, the
# denominator stopped including first fixes and the headline number silently
# became less conservative.
ALL=$(get_metric git fix_rework_rate)
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' \
  "$ALL" "$FOLLOWUP" || fail "all-fix rework rate ($ALL) must be below follow-up rate ($FOLLOWUP)"

# --- one run must not adopt another run's corrections -----------------------
#
# Two runs on the same branch with no author commit between them leave one
# contiguous block of pipeline commits. Walking back until a non-pipeline
# subject would make the SECOND run swallow the first run's correction and then
# treat it as "an earlier fix in the same run" - which is the exact invariant
# every rework metric is defined on. The recorded head of the earlier run is the
# boundary, so here each run owns exactly one correction and nothing reworks
# anything.

DB2=$TMP_ROOT/two-runs.sqlite
python3 - "$DB2" "$REPO" "$(git -C "$REPO" rev-parse HEAD~1)" "$HEAD_SHA" <<'PY'
import sqlite3, sys
db, repo, first, second = sys.argv[1:5]
con = sqlite3.connect(db)
con.executescript("""
create table repos(id text primary key, working_path text, upstream_url text,
                   default_branch text, created_at integer);
create table runs(id text primary key, repo_id text, branch text, head_sha text,
                  base_sha text, status text, pr_url text, created_at integer,
                  updated_at integer);
create table step_results(id text primary key, run_id text, step_name text,
                          step_order integer, status text);
create table step_rounds(id text primary key, step_result_id text, round integer,
                         trigger_type text, findings_json text,
                         user_findings_json text, fix_summary text,
                         duration_ms integer, created_at integer);
""")
con.execute("insert into repos values('r1',?,'u','main',0)", (repo,))
zero = "0" * 40
con.execute("insert into runs values('runA','r1','b',?,?,'completed',null,1,1)", (first, zero))
con.execute("insert into runs values('runB','r1','b',?,?,'completed',null,2,2)", (second, zero))
for run, sid, summary in (("runA", "sA", "first correction"),
                          ("runB", "sB", "second correction")):
    con.execute("insert into step_results values(?,?,'review',3,'completed')", (sid, run))
    con.execute("insert into step_rounds values(?,?,1,'auto_fix',null,null,?,0,1)",
                (sid + "r", sid, summary))
con.commit()
con.close()
PY

TWO=$(python3 "$ENGINE" --db "$DB2" --corpus "$CORPUS" --quiet --json report 2>/dev/null) \
  || fail "two-run report failed"
printf '%s' "$TWO" | python3 -c '
import json, sys
vals = {m["key"]: m for m in json.load(sys.stdin)["tiers"]["git"]["metrics"]}
if vals["runs_git_resolved"]["value"] != 2:
    print("both runs should resolve, got %s" % vals["runs_git_resolved"]["value"]); sys.exit(1)
if "fixes_that_reworked_a_prior_fix" in vals or "fix_rework_rate_followups" in vals:
    print("a run absorbed the other runs correction and counted it as a follow-up")
    sys.exit(1)
if vals["fix_rework_rate"]["value"] != 0.0:
    print("cross-run rework leaked into the rate: %s" % vals["fix_rework_rate"]["value"])
    sys.exit(1)
' || fail "a run adopted an earlier run's fix commits as its own"

# --- two run rows that ended at the same commit are one measurement ---------
#
# A run cancelled or failed without adding a commit and then retried leaves two
# run rows recording the identical head. The unit this tier measures is the
# COMMIT, so letting both contribute would feed the same deleted and added lines
# into every aggregate twice - bookkeeping counted as evidence, which is the
# contamination the whole tier exists to avoid.

python3 - "$DB2" "$HEAD_SHA" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("insert into runs values('runC','r1','b',?,?,'cancelled',null,3,3)",
            (sys.argv[2], "0" * 40))
con.execute("insert into step_results values('sC','runC','review',3,'completed')")
con.execute("insert into step_rounds values('sCr','sC',1,'auto_fix',null,null,"
            "'second correction',0,1)")
con.commit()
con.close()
PY

DUP=$(python3 "$ENGINE" --db "$DB2" --corpus "$CORPUS" --quiet --json report 2>/dev/null) \
  || fail "duplicate-head report failed"
printf '%s' "$TWO$(printf '\036')$DUP" | python3 -c '
import json, sys
before, after = sys.stdin.read().split("\036")
b = {m["key"]: m for m in json.loads(before)["tiers"]["git"]["metrics"]}
a = {m["key"]: m for m in json.loads(after)["tiers"]["git"]["metrics"]}
if a["runs_git_resolved"]["value"] != 3:
    print("the third run row should still resolve, got %s"
          % a["runs_git_resolved"]["value"]); sys.exit(1)
if a["distinct_fix_chains_measured"]["value"] != 2:
    print("identical chains must collapse to 2, got %s"
          % a["distinct_fix_chains_measured"]["value"]); sys.exit(1)
for key in ("fix_rework_rate", "fix_line_survival"):
    if (a[key]["value"], a[key]["n"]) != (b[key]["value"], b[key]["n"]):
        print("%s changed when a duplicate run row was added: %s n=%s -> %s n=%s"
              % (key, b[key]["value"], b[key]["n"], a[key]["value"], a[key]["n"]))
        sys.exit(1)
' || fail "a duplicate run row contributed its chain to the aggregates twice"

# --- deleted files are blamed against the file that was deleted -------------
#
# git emits `--- a/<path>` then `+++ /dev/null` for a deletion, so keying hunks
# off the `+++` side leaves the PREVIOUS file's path in place and blames that
# unrelated file's lines. A correction that removes a dead file is ordinary, so
# this has to hold before the git tier can be trusted.

DELREPO=$TMP_ROOT/delrepo
mkdir -p "$DELREPO"
git -C "$DELREPO" init -q -b main
git -C "$DELREPO" config user.email test@example.invalid
git -C "$DELREPO" config user.name "Test"
printf 'a1\na2\na3\n' > "$DELREPO/gone.txt"
printf 'b1\nb2\nb3\n' > "$DELREPO/kept.txt"
git -C "$DELREPO" add gone.txt kept.txt
git -C "$DELREPO" commit -qm "work: two files"
git -C "$DELREPO" rm -q gone.txt
printf 'b1\nCHANGED\nb3\n' > "$DELREPO/kept.txt"
git -C "$DELREPO" commit -qam "no-mistakes(review): drop the dead file"

python3 - "$ENGINE" "$DELREPO" "$(git -C "$DELREPO" rev-parse HEAD)" <<'PY' \
  || fail "deleted-file hunks were attributed to the wrong file"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("eng", sys.argv[1])
eng = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eng)
git = eng.Git(sys.argv[2])
by_path = {}
for h in git.hunks(sys.argv[3]):
    by_path.setdefault(h["old_path"], 0)
    by_path[h["old_path"]] += h["old_count"]
if by_path.get("gone.txt") != 3:
    print("deleted file's 3 lines not attributed to gone.txt: %r" % by_path)
    sys.exit(1)
if by_path.get("kept.txt") != 1:
    print("modified file should contribute exactly its own 1 deleted line: %r" % by_path)
    sys.exit(1)
info = git.deleted_line_sources(sys.argv[3])
if info["total"] != 4:
    print("expected 4 blame-resolvable deleted lines, got %r" % info)
    sys.exit(1)
PY

# --- every number carries provenance ---------------------------------------

printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = []
for tier, body in d["tiers"].items():
    for m in body["metrics"]:
        if not m.get("source") or m.get("n") is None or not m.get("method"):
            bad.append("%s/%s" % (tier, m["key"]))
if bad:
    print("metrics without provenance: " + ", ".join(bad))
    sys.exit(1)
' || fail "a metric was emitted without a named source and sample size"

# A Metric must be impossible to construct without provenance, not merely
# discouraged, or the guarantee is only a convention.
python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("eng", sys.argv[1])
eng = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eng)
for args in ((None, 1, 1, "src", "method"), ("k", 1, None, "src", "method"),
             ("k", 1, 1, "", "method"), ("k", 1, 1, "src", "")):
    try:
        eng.Metric(*args)
    except ValueError:
        continue
    print("Metric accepted missing provenance: %r" % (args,))
    sys.exit(1)
' "$ENGINE" || fail "Metric did not refuse to construct without provenance"

# --- the ledger tier is labelled as self-reported ---------------------------

LEDGER_SRC=$(printf '%s' "$OUT" | python3 -c '
import json, sys
print(json.load(sys.stdin)["tiers"]["ledger"]["metrics"][0]["source"])')
assert_contains "$LEDGER_SRC" "SELF-REPORTED" "ledger metrics must be marked self-reported"

# --- materiality refuses to invent a number ---------------------------------

MAT=$(get_metric materiality material_finding_rate)
[ "$MAT" = "None" ] \
  || fail "materiality must report no value without adjudication, got $MAT"

BALLOT=$TMP_ROOT/ballot.json
run_engine --out "$BALLOT" --sample-size 2 sample >/dev/null 2>&1 \
  || fail "sample command failed"
assert_grep '"adjudicator": ""' "$BALLOT" "ballot must ask for a named adjudicator"
assert_grep '"verdict": ""' "$BALLOT" "ballot must carry empty verdicts to fill in"

# The tool's own severity and action labels must not reach the ballot: judging
# them would re-import the self-assessment this scale exists to replace.
assert_no_grep '"severity"' "$BALLOT" "blind ballot must not leak the tool's severity label"
assert_no_grep '"action"' "$BALLOT" "blind ballot must not leak the tool's action label"

# Secret-shaped text in a finding must be redacted before it is written out.
assert_no_grep 'abcdefghijklmnop' "$BALLOT" "ballot must redact secret-shaped finding text"
assert_grep 'REDACTED' "$BALLOT" "redaction must be visible, not silent"

# An unsigned ballot is not a verdict.
python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["ballots"][0]["verdict"] = "harmful"
json.dump(b, open(sys.argv[1], "w"))
PY
if run_engine --ballots "$BALLOT" report >/dev/null 2>&1; then
  fail "engine accepted adjudication with no named adjudicator"
fi

# A signed ballot produces a number, with n and an interval.
python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["adjudicator"] = "Test Adjudicator"
json.dump(b, open(sys.argv[1], "w"))
PY
SIGNED=$(run_engine --ballots "$BALLOT" --json report 2>/dev/null) \
  || fail "signed ballot report failed"
printf '%s' "$SIGNED" | grep -q 'Test Adjudicator' \
  || fail "adjudicator must be named in the metric source"
printf '%s' "$SIGNED" | grep -q 'Wilson interval' \
  || fail "adjudicated rate must ship its uncertainty interval"

# The sample is allocated equally across strata, so its composition is not the
# population's. Rates are therefore reported per stratum and a single pooled
# headline must NOT exist: collapsing the strata would have to weight them by
# the graded tool's own severity labels, which is the dependence this scale
# exists to remove.
printf '%s' "$SIGNED" | python3 -c '
import json, sys
keys = [m["key"] for m in json.load(sys.stdin)["tiers"]["materiality"]["metrics"]]
pooled = [k for k in keys if k in ("material_finding_rate", "minor_finding_rate",
                                   "false_positive_rate")]
if pooled:
    print("pooled rate emitted as a headline: " + ", ".join(pooled)); sys.exit(1)
if not any(k.startswith("material_finding_rate[severity=") for k in keys):
    print("no per-stratum rate emitted: " + ", ".join(keys)); sys.exit(1)
' || fail "adjudicated materiality must report per-stratum rates and no pooled headline"

# The reader has to be told the strata come from the tool under test, or the
# sampling frame looks independent when it is not.
printf '%s' "$SIGNED" | grep -q "GRADED TOOL'S OWN severity labels" \
  || fail "per-stratum rates must disclose that the sampling frame is the graded tool's labels"

# A signed ballot on which everyone abstained has adjudicated nothing. It must
# say UNADJUDICATED plainly rather than rendering an empty table, which is the
# one thing this tier exists to do.
python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
for entry in b["ballots"]:
    entry["verdict"] = ""
json.dump(b, open(sys.argv[1], "w"))
PY
ABSTAINED=$(run_engine --ballots "$BALLOT" --json report 2>/dev/null) \
  || fail "all-abstained ballot report failed"
printf '%s' "$ABSTAINED" | python3 -c '
import json, sys
ms = json.load(sys.stdin)["tiers"]["materiality"]["metrics"]
if not ms:
    print("all-abstained ballot emitted no metric at all"); sys.exit(1)
rate = [m for m in ms if m["key"] == "material_finding_rate"]
if not rate:
    print("expected material_finding_rate, got " + ", ".join(m["key"] for m in ms))
    sys.exit(1)
if rate[0]["value"] is not None:
    print("abstentions must not become a number: %s" % rate[0]["value"]); sys.exit(1)
if "UNADJUDICATED" not in rate[0]["source"]:
    print("source must say UNADJUDICATED, got %s" % rate[0]["source"]); sys.exit(1)
' || fail "an all-abstained signed ballot must report UNADJUDICATED, not an empty table"

ABSTAINED_MD=$(run_engine --ballots "$BALLOT" report 2>/dev/null) \
  || fail "all-abstained markdown report failed"
assert_contains "$ABSTAINED_MD" "UNADJUDICATED" \
  "the rendered Tier M table must carry an UNADJUDICATED row, not be empty"

python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["ballots"][0]["verdict"] = "harmful"
json.dump(b, open(sys.argv[1], "w"))
PY

# A verdict outside the closed vocabulary would count into n while contributing
# to no rate, so every published share would silently read low.
python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["ballots"][0]["verdict"] = "harmfull"
json.dump(b, open(sys.argv[1], "w"))
PY
if run_engine --ballots "$BALLOT" report >/dev/null 2>&1; then
  fail "engine accepted a verdict outside the harmful|minor|wrong vocabulary"
fi
python3 - "$BALLOT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["ballots"][0]["verdict"] = "harmful"
json.dump(b, open(sys.argv[1], "w"))
PY

# The report prints the seed as the recipe for redrawing the sample. Reporting a
# ballot under a seed it was not drawn with would print a recipe that does not
# reproduce it.
if run_engine --ballots "$BALLOT" --seed some-other-seed report >/dev/null 2>&1; then
  fail "engine reported a ballot under a seed it was not drawn with"
fi

# A mistyped ballot path must be loud. Falling through to UNADJUDICATED would
# assert that no human has voted at an operator who believes they just supplied
# signed verdicts.
if run_engine --ballots "$TMP_ROOT/no-such-ballot.json" report >/dev/null 2>&1; then
  fail "a nonexistent --ballots path must be refused, not reported as unadjudicated"
fi
if run_engine --submission "$TMP_ROOT/no-such-submission.json" report >/dev/null 2>&1; then
  fail "a nonexistent --submission path must be refused"
fi

# --out and --json are documented together, so the combination must write the
# file rather than silently printing to stdout and creating nothing.
JSON_OUT=$TMP_ROOT/grade.json
run_engine --json --out "$JSON_OUT" report >/dev/null 2>&1 \
  || fail "report --json --out failed"
[ -s "$JSON_OUT" ] || fail "--json --out must write the JSON to the file"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON_OUT" \
  || fail "--json --out must write valid JSON"

# --- corpus admissibility ---------------------------------------------------

cat > "$CORPUS/asserted-case.json" <<'JSON'
{
  "case_id": "asserted-case",
  "repo": "nowhere",
  "defect_commit": "0000000000000000000000000000000000000001",
  "defect_paths": ["a.txt"],
  "detection": {"must_match_any": ["something"]},
  "proof": {"kind": "asserted", "evidence": "a reviewer thought so"}
}
JSON
OUT2=$(run_engine --json report 2>/dev/null) || fail "report with corpus failed"
ADMISSIBLE=$(printf '%s' "$OUT2" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]:
    if m["key"] == "corpus_cases_admissible":
        print(m["value"])')
[ "$ADMISSIBLE" = "0" ] \
  || fail "an asserted-proof case must not count as admissible, got $ADMISSIBLE"

CORPUS_OUT=$(run_engine corpus 2>&1)
assert_contains "$CORPUS_OUT" "tier2" "asserted case must be listed at tier 2"

# A malformed case is reported, not silently skipped.
printf '{ not json' > "$CORPUS/broken.json"
if run_engine corpus >/dev/null 2>&1; then
  fail "corpus validation must fail on a malformed case"
fi
rm -f "$CORPUS/broken.json"

# --- executable answer key --------------------------------------------------
#
# A case that declares a reproduce block must actually reproduce: the subject
# must show the defect at defect_commit and not show it at fixed_commit.

cat > "$CORPUS/repro-case.json" <<JSON
{
  "case_id": "repro-case",
  "repo": "synthetic",
  "repo_path": "$REPO",
  "defect_commit": "$(git -C "$REPO" rev-parse HEAD~2)",
  "fixed_commit": "$(git -C "$REPO" rev-parse HEAD~1)",
  "defect_paths": ["file.txt"],
  "detection": {"must_mention_paths": ["file.txt"], "must_match_any": ["two"]},
  "proof": {
    "kind": "executed-reproduction",
    "evidence": "synthetic",
    "reproduce": {
      "extract": [{"path": "file.txt", "as": "file.txt"}],
      "command": ["grep", "-c", "^two$", "file.txt"],
      "defect_expect": {"exit": 0, "output_matches": "1"},
      "fixed_expect": {"exit": 1}
    }
  }
}
JSON
rm -f "$CORPUS/asserted-case.json"
VERIFY=$(run_engine --verify corpus 2>&1) || fail "corpus --verify failed: $VERIFY"
assert_contains "$VERIFY" "RE-PROVEN" "a sound reproduce block must re-prove the case"

# Break the expectation and the case must fail rather than pass on trust.
python3 - "$CORPUS/repro-case.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["proof"]["reproduce"]["defect_expect"] = {"exit": 99}
json.dump(c, open(sys.argv[1], "w"))
PY
if run_engine --verify corpus >/dev/null 2>&1; then
  fail "corpus --verify must fail when the declared reproduction does not hold"
fi
rm -f "$CORPUS/repro-case.json"

# --- blind scoring ----------------------------------------------------------

cat > "$CORPUS/score-case.json" <<'JSON'
{
  "case_id": "score-case",
  "repo": "synthetic",
  "defect_commit": "0000000000000000000000000000000000000002",
  "defect_paths": ["bin/thing.sh"],
  "detection": {
    "must_mention_paths": ["bin/thing.sh"],
    "must_match_any": ["(?i)line.?wrap"]
  },
  "proof": {"kind": "executed-reproduction", "evidence": "synthetic"}
}
JSON

SUB=$TMP_ROOT/submission.json
cat > "$SUB" <<'JSON'
{"score-case": {"findings": [
  {"file": "bin/thing.sh", "description": "the guard misses a line-wrapped tag"},
  {"file": "bin/other.sh", "description": "unrelated remark"}
]}}
JSON
SCORED=$(run_engine --submission "$SUB" --json report 2>/dev/null) || fail "scoring failed"
DETECT=$(printf '%s' "$SCORED" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]:
    if m["key"] == "blind_detection_rate":
        print(m["value"])')
[ "$DETECT" = "100.0" ] || fail "a matching finding must score as detected, got $DETECT"

# A candidate that reports the right words about the wrong file has not found it.
cat > "$SUB" <<'JSON'
{"score-case": {"findings": [
  {"file": "bin/elsewhere.sh", "description": "something line-wrapped here"}
]}}
JSON
MISSED=$(run_engine --submission "$SUB" --json report 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]:
    if m["key"] == "blind_detection_rate":
        print(m["value"])')
[ "$MISSED" = "0.0" ] || fail "wrong-file finding must not count as detection, got $MISSED"

# The scored rule reads the finding's own `file` field, not its prose. A finding
# that points somewhere else while quoting the expected path in its argument
# sends a reader to the wrong place, so it is a MISS - but the lenient rate must
# still record it, because the gap between the two rates is the measurement of
# how precisely the candidate localised what it found.
cat > "$SUB" <<'JSON'
{"score-case": {"findings": [
  {"file": "bin/elsewhere.sh",
   "description": "unlike bin/thing.sh, this guard misses a line-wrapped tag"}
]}}
JSON
BOTH=$(run_engine --submission "$SUB" --json report 2>/dev/null | python3 -c '
import json, sys
vals = {m["key"]: m["value"] for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]}
print("%s %s" % (vals.get("blind_detection_rate"),
                 vals.get("blind_detection_rate_lenient")))')
[ "$BOTH" = "0.0 100.0" ] \
  || fail "prose quoting the path must be a strict MISS and a lenient HIT, got $BOTH"

# Strictness rejects the wrong FILE, not the wrong SPELLING. A challenger whose
# path convention is absolute or './'-prefixed must not lose a point it earned,
# because penalising an unknown convention would flatter the incumbent - the one
# bias this scale cannot carry.
detection_rate() {  # <file-field>
  cat > "$SUB" <<JSON
{"score-case": {"findings": [
  {"file": "$1", "description": "the guard misses a line-wrapped tag"}
]}}
JSON
  run_engine --submission "$SUB" --json report 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]:
    if m["key"] == "blind_detection_rate":
        print(m["value"])'
}

for SPELLING in "./bin/thing.sh" "/home/somebody/checkout/bin/thing.sh" "bin//thing.sh"; do
  GOT=$(detection_rate "$SPELLING")
  [ "$GOT" = "100.0" ] \
    || fail "path spelling $SPELLING must still locate the file, got $GOT"
done

# Normalisation must not blur two genuinely different files into one. A bare
# filename is the case that matters: it is a less specific locator rather than
# another spelling, and accepting it would let `README.md` match every README in
# the tree - an error that flatters the graded tool, the one direction this
# scale must never lean.
for WRONG in "bin/other.sh" "bin/thing.sh.bak" "docs/thing.sh" "thing.sh"; do
  GOT=$(detection_rate "$WRONG")
  [ "$GOT" = "0.0" ] \
    || fail "$WRONG is not a location for this case and must not score, got $GOT"
done

# Prose ends in a full stop constantly, and the lenient rate promises to accept
# the path appearing anywhere in the text. A path-shaped word must therefore be
# compared without its sentence punctuation, or the strict-vs-lenient gap - the
# whole point of reporting both - reads narrower than it is.
cat > "$SUB" <<'JSON'
{"score-case": {"findings": [
  {"file": "bin/elsewhere.sh",
   "description": "a line-wrapped tag slips past the guard in bin/thing.sh."}
]}}
JSON
PUNCT=$(run_engine --submission "$SUB" --json report 2>/dev/null | python3 -c '
import json, sys
vals = {m["key"]: m["value"] for m in json.load(sys.stdin)["tiers"]["bench"]["metrics"]}
print("%s %s" % (vals.get("blind_detection_rate"),
                 vals.get("blind_detection_rate_lenient")))')
[ "$PUNCT" = "0.0 100.0" ] \
  || fail "a sentence-final path must still count as a lenient mention, got $PUNCT"

# --- the wrapper never writes to the run database ---------------------------

BEFORE=$(md5sum "$DB" | awk '{print $1}')
FM_GRADE_DB="$DB" FM_GRADE_CORPUS="$CORPUS" "$GRADE" report --quiet >/dev/null 2>&1
AFTER=$(md5sum "$DB" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "grading modified the run database"

# --- wrapper surface --------------------------------------------------------

HELP=$("$GRADE" --help 2>&1)
assert_contains "$HELP" "fm-grade.sh report" "help must document the report command"
assert_contains "$HELP" "corpus" "help must document the corpus command"

FM_GRADE_DB=$TMP_ROOT/absent.sqlite "$GRADE" report >/dev/null 2>&1 \
  && fail "missing run database must be refused, not invented"

"$GRADE" bogus-command >/dev/null 2>&1 && fail "unknown command must be refused"

pass "fm-grade grades review quality on git-derived evidence and refuses to grade itself"
