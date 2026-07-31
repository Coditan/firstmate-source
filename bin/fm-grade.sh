#!/usr/bin/env bash
# fm-grade.sh - grade how good a code review actually is, on a scale the
# reviewed tool does not control.
#
# WHY: every figure we had for `no-mistakes` came out of `no-mistakes` - how
# many findings it reported, how many it fixed, how much of that came from the
# review step. None of it establishes that a finding was real or that a
# correction improved anything, so a challenger could only ever be compared
# self-report against self-report. This produces the outside scale, and it is
# built so a later challenger meets exactly the same one without anybody
# adjusting the rules afterwards.
#
# The engine keeps four evidence classes apart and never blends them:
#   Tier L  the tool's own ledger, always labelled self-reported
#   Tier G  git history - a correction's diff is a fact, not a claim
#   Tier B  a sealed corpus replayed blind against a candidate
#   Tier M  materiality, adjudicated by a named human over a seeded sample
#
# There is no model anywhere in the scoring path. A model reading a finding's
# own description would be scoring how persuasive the text is, and a model from
# the same family as the one that wrote it shares its blind spots, so its
# errors correlate instead of cancelling. bin/fm-grade-engine.py's header
# argues that in full.
#
# This tool MEASURES and never decides. It gates nothing, blocks no delivery,
# cancels no run, and returns no pass/fail verdict; a human reads its output.
# It opens the live run database read-only and never writes to it.
#
# Metric definitions and the honest limits of each tier live in
# docs/review-grading.md. Corpus case format lives in
# bin/fm-grade-corpus/README.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/fm-grade-engine.py"
CORPUS="${FM_GRADE_CORPUS:-$SCRIPT_DIR/fm-grade-corpus}"
DB="${FM_GRADE_DB:-$HOME/.no-mistakes/state.sqlite}"

note() { printf 'fm-grade: %s\n' "$1" >&2; }
die() { note "$1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
fm-grade.sh - grade review quality on a scale the reviewed tool does not control.

USAGE
  fm-grade.sh report   [--out FILE] [--json] [--no-git] [--ballots FILE]
                       [--submission FILE] [--seed S] [--sample-size N] [--quiet]
  fm-grade.sh sample   [--out FILE] [--seed S] [--sample-size N]
  fm-grade.sh corpus   [--verify]
  fm-grade.sh replay   [--tier1-only]

COMMANDS
  report      Score the recorded run history and write the graded report.
              Every number is printed with its evidence class and sample size.
              The git tier blames each pipeline fix commit and is the slow part;
              --no-git skips it and says so in the output.
  sample      Draw a reproducible, stratified, BLIND ballot of findings for a
              human to adjudicate. The tool's own severity and action labels are
              withheld on purpose. Fill in `adjudicator` and each `verdict`
              (harmful | minor | wrong), then feed it back via
              `report --ballots FILE`.
  corpus      List and validate the sealed defect corpus. A case is admissible
              at tier 1 only when its proof that the defect was real is an
              OBSERVED event - an executed reproduction, a failing test, a CI
              failure, or a revert - never a reviewer's assertion. Add --verify
              to re-prove each case by execution instead of on trust.
  replay      Emit the blind task list for a candidate reviewer: the commit to
              inspect and nothing else. It is not told whether a defect is
              present, what kind, where, or how many. Score its answers with
              `report --submission FILE`.

OPTIONS
  --out FILE        Write output to FILE instead of stdout.
  --json            Machine-readable report, each metric carrying source and n.
  --no-git          Skip the git tier (fast, but drops the independent evidence).
  --ballots FILE    Completed adjudication ballots; without one the materiality
                    tier reports UNADJUDICATED rather than inventing a number.
  --submission FILE A candidate's blind corpus answers, as printed by `replay`.
  --seed S          Sampling seed, recorded in the report so the draw is
                    reproducible and therefore contestable (default fm-grade-v1).
  --sample-size N   Findings to draw for adjudication (default 40).
  --verify          (corpus) Re-prove each case by executing its declared
                    reproduction: the subject is extracted at defect_commit and
                    must show the defect, then at fixed_commit and must not.
                    Runs in a throwaway directory under a 60s timeout, and a
                    case that stops reproducing is reported FAILED, not carried.
  --quiet           Suppress progress on stderr.

ENVIRONMENT
  FM_GRADE_DB       Run database (default ~/.no-mistakes/state.sqlite, read-only).
  FM_GRADE_CORPUS   Corpus directory (default bin/fm-grade-corpus).

ADDING A CASE TO THE SCALE
  Drop a JSON case in the corpus directory and it is picked up automatically;
  nothing has to be registered or remembered. `corpus` refuses a case that has
  no observed proof at tier 1, so the answer key cannot quietly weaken over time.
  See bin/fm-grade-corpus/README.md.
EOF
}

[ $# -gt 0 ] || { usage; exit 2; }

case "$1" in
  -h|--help|help) usage; exit 0 ;;
esac

CMD="$1"
shift

case "$CMD" in
  report|sample|corpus|replay) ;;
  *) note "unknown command: $CMD"; usage; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "$ENGINE" ] || die "engine missing: $ENGINE"
[ -d "$CORPUS" ] || die "corpus directory missing: $CORPUS"

# The run database belongs to a pipeline that may be mid-run. Report its
# absence plainly rather than letting the engine fail deeper down, and never
# create it.
if [ "$CMD" = "report" ] || [ "$CMD" = "sample" ]; then
  [ -f "$DB" ] || die "no run database at $DB (set FM_GRADE_DB)"
  [ -r "$DB" ] || die "run database not readable: $DB"
fi

exec python3 "$ENGINE" --db "$DB" --corpus "$CORPUS" "$@" "$CMD"
