#!/usr/bin/env bash
# Run a model panel: two analysts answer one question independently on
# DIFFERENT models without seeing each other's work, then a third model judges
# both reports and re-verifies their load-bearing claims itself.
# Every panel member is an ordinary firstmate scout, so the panel adds a
# formation on top of the existing brief/spawn/report lifecycle and invents no
# second one. The `panel` skill owns when a panel is worth its cost.
#
# Usage:
#   fm-model-panel.sh start [--id <panel-id>] [--project <name-or-path>]
#                           [--reduced] [--dry-run]
#                           (<question> | --question-file <path>)
#   fm-model-panel.sh advance <panel-id>
#   fm-model-panel.sh status <panel-id>
#
#   start     resolve the three roles, write the question and both analyst
#             briefs, and dispatch the analysts concurrently. The judge is NOT
#             dispatched here: it is created only once every analyst has
#             finished, which `advance` enforces.
#   advance   idempotent next step. The judge is created only when BOTH of these
#             hold for EVERY analyst: the analyst wrote a terminal status event
#             (a `done:` or `failed:` line in state/<task-id>.status), and its
#             data/<task-id>/report.md exists and is non-empty. Until then it
#             prints one `waiting:` line naming which of the two facts is missing
#             for which analyst and changes nothing; with both satisfied for
#             every analyst it scaffolds and dispatches the judge; with the judge
#             report present it prints `complete: <report path>`.
#   status    print the panel record without changing anything.
#
#   --id <panel-id>       explicit panel id (default: derived from the question
#                         plus a random suffix). Task ids are <panel-id>-a,
#                         <panel-id>-b, and <panel-id>-judge, so the panel id is
#                         capped so every task id stays within the 64-character
#                         task-id limit.
#   --project <name-or-path>
#                         the repo the scouts get a worktree of: an existing
#                         directory, or a name resolved under the home's
#                         projects/. Defaults to the firstmate repo itself,
#                         which is what a question about the fleet needs.
#   --reduced             run the NAMED REDUCED FORM: one analyst plus the
#                         judge, recorded and labelled everywhere as a
#                         single-analyst review rather than a panel. This is the
#                         honest degradation for a home with only one model, and
#                         it is never selected implicitly.
#   --question-file <path>
#                         read the question from a file instead of the
#                         positional argument. Exactly one of the two is
#                         required; a long question belongs in a file.
#   --dry-run             with `start`, resolve and print the lineup without
#                         writing or dispatching anything.
#
# Roles are pinned here; models are not. `config/model-panel.json` maps each
# role to a dispatch profile, and docs/configuration.md "Model panel roles" owns
# that schema, the resolution order, and the degradation contract. Every role
# resolves through bin/fm-dispatch-select.sh, so panel profiles get the same
# validation and quota-aware array selection as crew dispatch profiles.
#
# Model identity for the distinctness test is the profile's model name with any
# provider prefix and any `:suffix` removed (the normalization bin/fm-dispatch-
# select.sh already uses), or `harness:<name>` when the profile pins no model.
# Two profiles naming the same model through different harnesses are therefore
# correctly treated as ONE model, not two.
#
# Degradation is explicit, never silent: when the two analysts would resolve to
# the same model identity, `start` refuses with exit 4 and names both the
# configuration fix and the `--reduced` alternative. Two identical analysts are
# not a panel, and presenting one as a panel is worse than running none. When no
# third distinct model is available, the judge may share an analyst's model; that
# is a printed warning rather than a refusal, because the judge's independence
# comes from re-verifying against live state with both reports in hand.
#
# The two-condition judge gate is deliberate. A report file that EXISTS is not a
# report that is FINISHED, and dispatching the judge against a half-written
# analysis silently judges a truncated argument. The completion half is a durable
# status EVENT rather than a live crew-state read, because panel members are
# ordinary scouts that may be torn down before the judge is dispatched, and a
# gate with a fallback for that case would quietly become the fallback. `failed:`
# counts as terminal on purpose: the question is whether the analyst stopped
# writing, not whether it succeeded, and a failed analyst that still left a
# non-empty report is finished. The verbs are recognized through
# bin/fm-classify-lib.sh, this repo's owner of the status-event vocabulary, and
# the scan asks only whether such an event EVER appeared, which is monotonic -
# never what the last line currently says.
#
# Panel record: data/<panel-id>/panel.meta (key=value), with the question at
# data/<panel-id>/question.md. Both are durable and survive scout teardown, as do
# the reports at data/<task-id>/report.md.
#
# Retry safety: `start` refuses an existing panel id rather than clobbering a
# live panel. `advance` regenerates the judge brief only when the judge task was
# never dispatched (no state/<id>.meta), so a failed dispatch can be retried
# without hand-editing, and never touches a brief whose agent is live.
#
# Exit status: 0 success (including `waiting:`), 2 usage error, 3 no-mistakes
# gate refusal (bin/fm-gate-refuse-lib.sh), 4 refused because the panel would not
# be a panel, 1 any other failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# The owner of the status-event vocabulary the judge gate reads.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PANEL_CONFIG="$CONFIG/model-panel.json"
CREW_DISPATCH="$CONFIG/crew-dispatch.json"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
warn() { printf 'panel: %s\n' "$1" >&2; }

# Every non-terminal outcome names the next command, so one entry point carries a
# panel from its question to its answer without the operator tracking stages.
panel_next_hint() {
  # shellcheck disable=SC2016  # the backticks are markdown emphasis in the printed hint, not a command substitution
  printf 'panel: next step is `%s advance %s` %s\n' "$0" "$1" "$2"
}

command -v jq >/dev/null 2>&1 || die "jq is required to resolve panel roles"

# --- role resolution --------------------------------------------------------

# Print the raw spec (profile object or profile array) for one role: the panel
# config's entry first, then config/crew-dispatch.json's default profile set.
# The crew-dispatch fallback is what lets a home that already declares which
# runtimes it dispatches on run a panel with no extra configuration.
role_spec() {
  local role=$1 spec=''
  if [ -f "$PANEL_CONFIG" ]; then
    jq . "$PANEL_CONFIG" >/dev/null 2>&1 || die "$PANEL_CONFIG is not valid JSON"
    spec=$(jq -c --arg role "$role" '.roles[$role] // empty' "$PANEL_CONFIG")
  fi
  if [ -z "$spec" ] && [ -f "$CREW_DISPATCH" ]; then
    jq . "$CREW_DISPATCH" >/dev/null 2>&1 || die "$CREW_DISPATCH is not valid JSON"
    spec=$(jq -c '.default // empty' "$CREW_DISPATCH")
  fi
  [ -n "$spec" ] || die "no profile for panel role '$role': add roles.$role to $PANEL_CONFIG (see docs/examples/model-panel.json) or a default profile set in $CREW_DISPATCH"
  printf '%s\n' "$spec"
}

# The ONE definition of a profile's model identity, interpolated by every jq
# program below so the exit-4 distinctness check and the exclusion filter cannot
# disagree about what counts as one model. Keep it in step with
# bin/fm-dispatch-select.sh's model_name normalization.
# shellcheck disable=SC2016  # $m is a jq binding, deliberately not shell-expanded
PANEL_IDENT_JQ='def ident:
  (.model // "") as $m
  | if ($m | length) > 0 then ($m | split("/") | last | split(":") | first | ascii_downcase)
    else "harness:" + (.harness // "")
    end;'

profile_identity() {
  printf '%s\n' "$1" | jq -r "$PANEL_IDENT_JQ"' ident'
}

profile_field() {
  printf '%s\n' "$1" | jq -r --arg field "$2" '.[$field] // ""'
}

# Drop every candidate whose identity is in the newline-separated exclusion
# list, so a role backed by an array picks a model the panel is not already
# using instead of duplicating one.
filter_spec() {
  local spec=$1 excluded=$2
  printf '%s\n' "$spec" | jq -c --arg excluded "$excluded" "$PANEL_IDENT_JQ"'
    ($excluded | split("\n") | map(select(length > 0))) as $ex
    | (if type == "array" then . else [.] end)
    | map(select((ident) as $i | ($ex | index($i)) == null))
  '
}

# Resolve one role to a concrete profile through the shared dispatch selector,
# preferring a candidate whose model the panel is not already using.
resolve_role() {
  local role=$1 excluded=${2:-} spec filtered count profile errors status=0
  spec=$(role_spec "$role")
  if [ -n "$excluded" ]; then
    filtered=$(filter_spec "$spec" "$excluded")
    count=$(printf '%s\n' "$filtered" | jq 'length')
    if [ "$count" -gt 0 ]; then
      spec=$filtered
    fi
  fi
  errors=$(mktemp "${TMPDIR:-/tmp}/fm-model-panel-select.XXXXXX")
  profile=$("$FM_ROOT/bin/fm-dispatch-select.sh" "$spec" 2>"$errors") || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'error: panel role %s could not be resolved:\n' "$role" >&2
    cat "$errors" >&2
    rm -f "$errors"
    exit 1
  fi
  rm -f "$errors"
  printf '%s\n' "$profile"
}

# --- panel record -----------------------------------------------------------

panel_dir() { printf '%s\n' "$DATA/$1"; }
panel_meta_path() { printf '%s\n' "$DATA/$1/panel.meta"; }

# A `start` that fails before it attempts any dispatch must leave nothing
# behind, so a retry of the same panel id is not blocked by debris from a run
# that never reached a worker. Once a dispatch has been ATTEMPTED, nothing is
# rolled back: a failed spawn may still have left a live agent, and live work is
# never torn down as a side effect.
PANEL_TMP_FILES=()
PANEL_ROLLBACK_DIRS=()
PANEL_DISPATCH_STARTED=0

panel_rollback_register() {
  case "$1" in
    "$DATA"/?*) PANEL_ROLLBACK_DIRS+=("$1") ;;
    *) die "refusing to register '$1' for rollback: it is not under $DATA" ;;
  esac
}

# shellcheck disable=SC2317,SC2329 # invoked through the EXIT trap
panel_cleanup() {
  local status=$? path
  for path in ${PANEL_TMP_FILES[@]+"${PANEL_TMP_FILES[@]}"}; do
    rm -f "$path"
  done
  if [ "$status" -ne 0 ] && [ "$PANEL_DISPATCH_STARTED" -eq 0 ]; then
    for path in ${PANEL_ROLLBACK_DIRS[@]+"${PANEL_ROLLBACK_DIRS[@]}"}; do
      case "$path" in
        "$DATA"/?*) rm -rf "$path" ;;
      esac
    done
  fi
  return "$status"
}

panel_mktemp() {
  local path
  path=$(mktemp "${TMPDIR:-/tmp}/fm-model-panel.XXXXXX")
  PANEL_TMP_FILES+=("$path")
  printf '%s\n' "$path"
}

# Values can contain '=' (a resolved profile is JSON), so split on the FIRST
# separator only and never re-join fields.
panel_meta_get() {
  local file=$1 want=$2 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$want"=*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  printf '\n'
}

panel_meta_set() {
  local file=$1 want=$2 new=$3 tmp line found=0
  tmp="$file.tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$want"=*) printf '%s=%s\n' "$want" "$new" >> "$tmp"; found=1 ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$file"
  [ "$found" -eq 1 ] || printf '%s=%s\n' "$want" "$new" >> "$tmp"
  mv "$tmp" "$file"
}

# --- brief composition ------------------------------------------------------

# The discipline that made the hand-run panels pay for themselves. Both runs
# were given a concrete example of a stale record misleading firstmate, and both
# found further stale records because of it, so this is a load-bearing section
# of the brief rather than decoration.
verify_prose_block() {
  cat <<'EOF'
## Verify status prose, never trust it

Written state in this fleet goes stale silently, and a stale record that still reads as current is the most reliable way to be confidently wrong here.
Backlog notes, task notes, status lines, earlier reports, code comments, and documentation are all claims about some past moment, not the current truth.
This is not a hypothetical: a hand-run of this panel was handed a backlog note describing work as still in flight long after it had landed, and only caught it by checking.
So for every load-bearing claim in your report, verify it yourself against the live source - the actual command output, the actual file at the actual path, the actual process or API state - and cite that evidence with the command you ran or the `file:line` you read.
Where prose and live state disagree, live state wins, and the disagreement is itself a finding worth reporting.
Where you could not verify something, say so explicitly instead of inheriting the claim.

## Check your vantage point

Confirm where you are actually running before concluding anything about the environment.
You are in a disposable worktree, which may sit on a different machine, container, network position, or account than the subject of the question.
A test run from the wrong vantage point returns a real result about the wrong system, and both analysts in one hand-run made exactly that mistake together.
EOF
}

compose_analyst_task() {
  local out=$1 label=$2 question_file=$3 report_path=$4 sibling_report=$5 form=$6
  {
    if [ "$form" = panel ]; then
      cat <<EOF
You are analyst $label on a firstmate model panel.
Two analysts answer the same question independently, on different models, and a third model then judges both answers and re-verifies their claims.
Your report is one half of that input, and its whole value is that it was reached independently.
EOF
    else
      cat <<EOF
You are the analyst on a firstmate single-analyst review.
This is the reduced form of the model panel: there is no second analyst, so a judge model will re-verify your report on its own.
Its output must never be presented as an independent panel result, and your report is the only analysis feeding it.
EOF
    fi
    cat <<'EOF'

## The question

EOF
    cat "$question_file"
    if [ -n "$sibling_report" ]; then
      cat <<EOF

## Independence - hard rule

Another analyst is answering this exact question right now, on a different model, in a different worktree.
Do not read their report at \`$sibling_report\`, and do not read their worktree, pane, status file, or brief.
Do not coordinate with them in any way; if you encounter their work incidentally, stop reading it and say so in your report.
Reaching the same conclusion independently is a strong signal, and copying it destroys the only thing this formation buys.
EOF
    fi
    printf '\n'
    verify_prose_block
    cat <<EOF

## Report contract

Write the report to \`$report_path\` as the scout definition of done below requires, and end it with these two sections.

### Highest-conviction calls

Three to five claims you are most confident in, most important first.
Each one gets the claim in one sentence, the evidence you verified it against, and what changes if you are wrong.
These are scored individually against the other work in this formation, so put your real convictions here rather than the safe ones.

### Unresolved captain decisions

Every choice your investigation surfaced that belongs to the captain rather than to you, each with its options.
An empty list is a valid answer; a missing list is not.
EOF
  } > "$out"
}

compose_judge_task() {
  local out=$1 question_file=$2 report_path=$3 form=$4 report_a=$5 report_b=$6
  {
    if [ "$form" = panel ]; then
      cat <<'EOF'
You are the judge on a firstmate model panel.
Two analysts answered the same question independently, on different models, with no access to each other's work.
Your job is not to referee their rhetoric, split the difference, or pick a winner wholesale.
It is to re-verify what they claim against live state and produce the answer the captain should act on.
EOF
    else
      cat <<'EOF'
You are the judge on a firstmate single-analyst review, the reduced form of the model panel.
One analyst answered the question, so there is no second independent report and no disagreement to adjudicate.
That makes your own re-verification more important, not less: you are the only independent check in this formation.
State in your report's first line that this was a single-analyst review rather than a panel, so its output is never presented as an independent panel result.
EOF
    fi
    cat <<'EOF'

## The question every analyst was given

EOF
    cat "$question_file"
    if [ "$form" = panel ]; then
      cat <<EOF

## The reports

- Analyst A: \`$report_a\`
- Analyst B: \`$report_b\`

They are labelled A and B deliberately, and the models behind them are deliberately withheld from you.
Judge the work, not the runtime.
EOF
    else
      cat <<EOF

## The report

- Analyst: \`$report_a\`

The model behind it is deliberately withheld from you; judge the work, not the runtime.
EOF
    fi
    cat <<'EOF'

## Re-verify, do not referee

For every load-bearing claim the answer rests on, check it yourself against the live source before you accept it.
Agreement is not evidence: the most valuable thing this formation produces is the mistake made for the same reason on both sides, which neither could have caught alone.
Look specifically for a shared assumption, a shared wrong vantage point, and shared reliance on the same stale written record.
EOF
    printf '\n'
    verify_prose_block
    cat <<EOF

## Report contract

Write the report to \`$report_path\` as the scout definition of done below requires, covering these sections in order.

1. The answer to the question, stated so the captain can act on it.
2. Every point where the reports disagreed on fact, and what the live evidence you checked actually shows.
3. Shared mistakes: anything wrong on both sides for the same reason, and why it was missed.
4. Scored highest-conviction calls: mark each one correct, partly correct, or wrong, name the evidence you checked it against, and say which analysis was stronger on which specific question.
   "Both were fine" is acceptable only where you verified it.
5. What remains unverified or unknown, stated plainly rather than smoothed over.
6. Unresolved captain decisions surfaced by either report or by your own verification, each with its options.
   An empty list is a valid answer; a missing list is not.
EOF
  } > "$out"
}

# Scaffold a scout brief through the shared scaffold, then replace its {TASK}
# placeholder with the composed panel task text. Failing loudly when the
# placeholder is absent keeps this honest if the scaffold ever changes shape.
scaffold_scout_brief() {
  local id=$1 repo=$2 task_file=$3 brief
  brief="$DATA/$id/brief.md"
  "$FM_ROOT/bin/fm-brief.sh" "$id" "$repo" --scout >/dev/null \
    || die "could not scaffold the brief for $id"
  awk -v taskfile="$task_file" '
    $0 == "{TASK}" && !filled {
      while ((getline line < taskfile) > 0) print line
      close(taskfile)
      filled = 1
      next
    }
    { print }
  ' "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief"
  # Only a WHOLE line of "{TASK}" is the placeholder; the scaffold's Herdr
  # declaration mentions the token inline and must not count as unfilled.
  ! grep -Fxq '{TASK}' "$brief" \
    || die "the scout scaffold for $id still has an unfilled {TASK} line; the brief scaffold changed shape"
}

dispatch_scout() {
  local id=$1 project=$2 profile=$3 harness model effort
  local -a args
  harness=$(profile_field "$profile" harness)
  model=$(profile_field "$profile" model)
  effort=$(profile_field "$profile" effort)
  args=("$id" "$project" --harness "$harness" --scout)
  [ -z "$model" ] || args+=(--model "$model")
  [ -z "$effort" ] || args+=(--effort "$effort")
  "$FM_ROOT/bin/fm-spawn.sh" "${args[@]}" >/dev/null \
    || return 1
  printf 'dispatched: %s harness=%s model=%s effort=%s\n' \
    "$id" "$harness" "${model:-default}" "${effort:-default}"
}

# --- start ------------------------------------------------------------------

derive_panel_id() {
  local question_file=$1 slug suffix
  slug=$(LC_ALL=C tr '[:upper:]' '[:lower:]' < "$question_file" \
    | LC_ALL=C tr -c 'a-z0-9' '-' \
    | LC_ALL=C tr -s '-' \
    | cut -c1-28)
  slug=${slug#-}
  slug=${slug%-}
  [ -n "$slug" ] || slug=question
  suffix=$(printf '%02x%02x' "$((RANDOM % 256))" "$((RANDOM % 256))")
  printf 'panel-%s-%s\n' "$slug" "$suffix"
}

resolve_project() {
  local want=$1
  if [ -z "$want" ]; then
    printf '%s\n' "$FM_ROOT"
    return 0
  fi
  if [ -d "$want" ]; then
    (cd "$want" && pwd)
    return 0
  fi
  if [ -d "$PROJECTS/$want" ]; then
    (cd "$PROJECTS/$want" && pwd)
    return 0
  fi
  die "no such project '$want': pass an existing directory or a name under $PROJECTS"
}

cmd_start() {
  local reduced=0 dry_run=0
  local panel_id='' project_arg='' question='' question_file=''
  local arg
  local want_value=''
  for arg in "$@"; do
    if [ -n "$want_value" ]; then
      case "$want_value" in
        id) panel_id=$arg ;;
        project) project_arg=$arg ;;
        question-file) question_file=$arg ;;
      esac
      want_value=
      continue
    fi
    case "$arg" in
      --id) want_value=id ;;
      --id=*) panel_id=${arg#--id=} ;;
      --project) want_value=project ;;
      --project=*) project_arg=${arg#--project=} ;;
      --question-file) want_value='question-file' ;;
      --question-file=*) question_file=${arg#--question-file=} ;;
      --reduced) reduced=1 ;;
      --dry-run) dry_run=1 ;;
      --*) die "unknown option $arg" 2 ;;
      *)
        [ -z "$question" ] || die "pass exactly one question (quote it, or use --question-file)" 2
        question=$arg
        ;;
    esac
  done
  [ -z "$want_value" ] || die "--$want_value requires a value" 2

  if [ -n "$question_file" ]; then
    [ -z "$question" ] || die "pass either a question argument or --question-file, not both" 2
    [ -r "$question_file" ] || die "cannot read question file: $question_file" 2
  else
    [ -n "$question" ] || die "a question is required (as an argument or --question-file <path>)" 2
  fi

  local project form
  project=$(resolve_project "$project_arg")
  form=panel
  [ "$reduced" -eq 0 ] || form=single-analyst-review

  # Stage the question first so the panel id can be derived from it and both
  # analysts provably receive byte-identical text.
  local staged_question
  trap panel_cleanup EXIT
  staged_question=$(panel_mktemp)
  if [ -n "$question_file" ]; then
    cat "$question_file" > "$staged_question"
  else
    printf '%s\n' "$question" > "$staged_question"
  fi
  [ -s "$staged_question" ] || die "the question is empty" 2

  [ -n "$panel_id" ] || panel_id=$(derive_panel_id "$staged_question")
  case "$panel_id" in
    ''|.*|*[!A-Za-z0-9._-]*) die "invalid panel id '$panel_id'" 2 ;;
  esac
  [ "${#panel_id}" -le 58 ] || die "panel id '$panel_id' is too long; task ids append -judge and must stay within 64 characters" 2

  # Resolve the lineup. analyst-b excludes analyst-a's model so an array-backed
  # role picks a second model rather than duplicating the first, and the judge
  # excludes both.
  local profile_a identity_a profile_judge identity_judge excluded
  local profile_b='' identity_b=''
  profile_a=$(resolve_role analyst_a)
  identity_a=$(profile_identity "$profile_a")
  excluded=$identity_a
  if [ "$form" = panel ]; then
    profile_b=$(resolve_role analyst_b "$identity_a")
    identity_b=$(profile_identity "$profile_b")
    if [ "$identity_b" = "$identity_a" ]; then
      printf 'error: this would not be a panel: both analysts resolve to the model %s.\n' "$identity_a" >&2
      printf '  Two identical analysts are not independent, and presenting them as a panel is worse than running none.\n' >&2
      printf '  Configure a second distinct model as roles.analyst_b in %s (see docs/examples/model-panel.json),\n' "$PANEL_CONFIG" >&2
      printf '  or re-run with --reduced for the single-analyst review, which is labelled as such everywhere it appears.\n' >&2
      exit 4
    fi
    excluded="$identity_a
$identity_b"
  fi
  profile_judge=$(resolve_role judge "$excluded")
  identity_judge=$(profile_identity "$profile_judge")
  case "$identity_judge" in
    "$identity_a"|"${identity_b:-$identity_a}")
      warn "no third distinct model is available, so the judge runs on $identity_judge, the same model as one analyst; it still re-verifies against live state with every report in hand"
      ;;
  esac

  local id_a="$panel_id-a" id_b="$panel_id-b" id_judge="$panel_id-judge"
  local report_a="$DATA/$id_a/report.md" report_b="$DATA/$id_b/report.md"
  local report_judge="$DATA/$id_judge/report.md"

  if [ "$dry_run" -eq 1 ]; then
    printf 'panel: %s form=%s project=%s\n' "$panel_id" "$form" "$project"
    printf 'panel: analyst-a %s\n' "$profile_a"
    [ "$form" != panel ] || printf 'panel: analyst-b %s\n' "$profile_b"
    printf 'panel: judge %s\n' "$profile_judge"
    exit 0
  fi

  [ ! -e "$(panel_dir "$panel_id")" ] || die "panel '$panel_id' already exists at $(panel_dir "$panel_id")"
  panel_rollback_register "$(panel_dir "$panel_id")"
  # A task directory that already existed is NOT ours to roll back: reports
  # survive teardown, so an earlier task's durable report can be sitting there.
  # Only what this run creates is registered.
  [ -e "$DATA/$id_a" ] || panel_rollback_register "$DATA/$id_a"
  if [ "$form" = panel ] && [ ! -e "$DATA/$id_b" ]; then
    panel_rollback_register "$DATA/$id_b"
  fi
  mkdir -p "$(panel_dir "$panel_id")"
  cat "$staged_question" > "$DATA/$panel_id/question.md"
  local question_path="$DATA/$panel_id/question.md"
  local meta
  meta=$(panel_meta_path "$panel_id")
  {
    printf 'panel=%s\n' "$panel_id"
    printf 'form=%s\n' "$form"
    printf 'project=%s\n' "$project"
    printf 'question=%s\n' "$question_path"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'stage=analysts\n'
    printf 'analyst_a_task=%s\n' "$id_a"
    printf 'analyst_a_profile=%s\n' "$profile_a"
    if [ "$form" = panel ]; then
      printf 'analyst_b_task=%s\n' "$id_b"
      printf 'analyst_b_profile=%s\n' "$profile_b"
    fi
    printf 'judge_task=%s\n' "$id_judge"
    printf 'judge_profile=%s\n' "$profile_judge"
  } > "$meta"

  local repo_label
  repo_label=$(basename "$project")
  local task_a task_b
  task_a=$(panel_mktemp)
  if [ "$form" = panel ]; then
    task_b=$(panel_mktemp)
    compose_analyst_task "$task_a" A "$question_path" "$report_a" "$report_b" "$form"
    compose_analyst_task "$task_b" B "$question_path" "$report_b" "$report_a" "$form"
    scaffold_scout_brief "$id_a" "$repo_label" "$task_a"
    scaffold_scout_brief "$id_b" "$repo_label" "$task_b"
  else
    compose_analyst_task "$task_a" A "$question_path" "$report_a" "" "$form"
    scaffold_scout_brief "$id_a" "$repo_label" "$task_a"
  fi

  printf 'panel: %s form=%s project=%s\n' "$panel_id" "$form" "$project"
  PANEL_DISPATCH_STARTED=1
  if ! dispatch_scout "$id_a" "$project" "$profile_a"; then
    panel_meta_set "$meta" stage incomplete
    die "could not dispatch analyst A ($id_a); no other panel member was dispatched"
  fi
  if [ "$form" = panel ]; then
    if ! dispatch_scout "$id_b" "$project" "$profile_b"; then
      panel_meta_set "$meta" stage incomplete
      die "could not dispatch analyst B ($id_b) while analyst A ($id_a) is already running; decide whether to retry the dispatch or stand the panel down"
    fi
  fi
  panel_next_hint "$panel_id" "once every analyst reports done"
}

# --- advance / status -------------------------------------------------------

require_panel() {
  local panel_id=$1 meta
  meta=$(panel_meta_path "$panel_id")
  [ -f "$meta" ] || die "no panel record at $meta"
  printf '%s\n' "$meta"
}

# Print why one analyst is not ready for the judge yet, or nothing when it is.
# The two conditions are different facts and the operator needs to know which one
# is missing, so each names itself. status_has_finished_event comes from
# bin/fm-classify-lib.sh and asks only whether a terminal event EVER appeared.
analyst_not_ready() {  # <task-id>
  local id=$1 status_file report
  status_file="$STATE/$id.status"
  report="$DATA/$id/report.md"
  if ! status_has_finished_event "$status_file"; then
    printf '%s has written no terminal status event yet (no done: or failed: line in %s)\n' "$id" "$status_file"
    return 0
  fi
  if [ ! -s "$report" ]; then
    printf '%s has finished but its report %s is empty or absent\n' "$id" "$report"
    return 0
  fi
}

cmd_status() {
  local panel_id=${1:-}
  [ -n "$panel_id" ] || die "status requires a panel id" 2
  local meta
  meta=$(require_panel "$panel_id")
  cat "$meta"
}

cmd_advance() {
  local panel_id=${1:-}
  [ -n "$panel_id" ] || die "advance requires a panel id" 2
  local meta form stage project id_a id_b id_judge profile_judge question_path
  meta=$(require_panel "$panel_id")
  form=$(panel_meta_get "$meta" form)
  stage=$(panel_meta_get "$meta" stage)
  project=$(panel_meta_get "$meta" project)
  id_a=$(panel_meta_get "$meta" analyst_a_task)
  id_b=$(panel_meta_get "$meta" analyst_b_task)
  id_judge=$(panel_meta_get "$meta" judge_task)
  profile_judge=$(panel_meta_get "$meta" judge_profile)
  question_path=$(panel_meta_get "$meta" question)
  local report_a="$DATA/$id_a/report.md" report_judge="$DATA/$id_judge/report.md"
  local report_b=''
  [ -z "$id_b" ] || report_b="$DATA/$id_b/report.md"

  case "$stage" in
    incomplete)
      die "panel '$panel_id' never finished dispatching; decide whether to retry it or stand it down before advancing"
      ;;
    complete)
      printf 'complete: %s\n' "$report_judge"
      printf 'panel: read that report, relay its findings, and pass the shared completion gate before standing the panel down\n'
      return 0
      ;;
    judge)
      if [ -f "$report_judge" ]; then
        panel_meta_set "$meta" stage complete
        printf 'complete: %s\n' "$report_judge"
        printf 'panel: read that report, relay its findings, and pass the shared completion gate before standing the panel down\n'
      else
        printf 'waiting: the judge has not written %s yet\n' "$report_judge"
        panel_next_hint "$panel_id" "once the judge reports done"
      fi
      return 0
      ;;
    analysts) ;;
    *) die "panel '$panel_id' has an unknown stage '$stage'" ;;
  esac

  local waiting reason
  waiting=''
  reason=$(analyst_not_ready "$id_a")
  [ -z "$reason" ] || waiting="$reason"
  if [ -n "$id_b" ]; then
    reason=$(analyst_not_ready "$id_b")
    [ -z "$reason" ] || waiting="${waiting:+$waiting; }$reason"
  fi
  if [ -n "$waiting" ]; then
    printf 'waiting: the judge is created only once every analyst has finished AND left a non-empty report; %s\n' "$waiting"
    panel_next_hint "$panel_id" "after the next analyst finishes"
    return 0
  fi

  # The judge task was never dispatched if it has no runtime record, so a brief
  # left behind by a failed dispatch is ours to regenerate.
  if [ -f "$STATE/$id_judge.meta" ]; then
    die "the judge task $id_judge already has a runtime record but the panel stage is '$stage'; reconcile that task before advancing"
  fi
  rm -f "$DATA/$id_judge/brief.md"

  local task_judge
  trap panel_cleanup EXIT
  task_judge=$(panel_mktemp)
  compose_judge_task "$task_judge" "$question_path" "$report_judge" "$form" "$report_a" "$report_b"
  scaffold_scout_brief "$id_judge" "$(basename "$project")" "$task_judge"
  dispatch_scout "$id_judge" "$project" "$profile_judge" \
    || die "could not dispatch the judge ($id_judge); every analyst report is still in place, so this is safe to retry"
  panel_meta_set "$meta" stage judge
  panel_next_hint "$panel_id" "once the judge reports done"
}

# --- dispatch ---------------------------------------------------------------

COMMAND=${1:-}
[ "$#" -eq 0 ] || shift
case "$COMMAND" in
  start) cmd_start "$@" ;;
  advance) cmd_advance "$@" ;;
  status) cmd_status "$@" ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command '$COMMAND' (start, advance, status)" 2 ;;
esac
