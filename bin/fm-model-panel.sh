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
#   fm-model-panel.sh advance <panel-id> [--accept-unfinished <task-id>]
#                                        [--rejudge]
#   fm-model-panel.sh status <panel-id>
#
#   start     resolve the three roles, write the question and both analyst
#             briefs, and dispatch the analysts concurrently. The judge is NOT
#             dispatched here: it is created only once every analyst has
#             finished, which `advance` enforces.
#   advance   idempotent next step, gated on the SAME two conditions for every
#             member, analysts and judge alike: the member wrote a terminal
#             status event (a `done:` or `failed:` line in state/<task-id>.status)
#             AND its data/<task-id>/report.md exists and is non-empty. With both
#             satisfied for every analyst it scaffolds and dispatches the judge;
#             with both satisfied for the judge it prints
#             `complete: <report path>` and records the panel complete, which is
#             the last thing it does. Until then it changes nothing and prints
#             one of four outcomes: a `waiting:` line naming which of the two
#             facts is missing for which member (exit 0); a `wedged:` block when a
#             member left a report and is GONE without ever declaring itself
#             finished, which is the one state that can never clear on its own
#             (exit 0); a `stood down:` block when an ANALYST stopped writing
#             with no report at all, which is the one state where the panel's
#             premise has failed (recorded as `stage=stood-down`, exit 1); or a
#             `verdict lost:` block when the JUDGE stopped writing with no report,
#             where the evidence is intact and only the adjudication is missing,
#             so `--rejudge` replaces it (exit 0). A member has stopped writing
#             once it wrote a terminal event or lost its runtime record.
#   status    print the panel record without changing anything.
#
#   --id <panel-id>       explicit panel id (default: derived from the question
#                         plus a random suffix). Task ids are <panel-id>-a,
#                         <panel-id>-b, <panel-id>-judge, and <panel-id>-judge<N>
#                         for a replacement judge, so the panel id is capped at 56
#                         characters: the longest suffix is `-judge99` at 8, which
#                         keeps every task id within the 64-character task-id
#                         limit.
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
#   --accept-unfinished <task-id>
#                         with `advance`, accept ONE named member's existing
#                         report as final even though that member never wrote a
#                         terminal status event. It is explicit and per-member: it
#                         names one task id and waives nothing for any other
#                         member, it is never on by default, and it refuses both
#                         a member that has no report to accept and one that was
#                         ever observed to finish properly. Repeat the flag to
#                         accept more than one member.
#   --rejudge             with `advance` at the judge stage, dispatch ONE
#                         replacement judge over the existing, unchanged analyst
#                         reports after the current judge ended without writing a
#                         verdict. Explicit and recorded, never automatic: the
#                         superseded judge task is written to the panel record
#                         after the replacement is dispatched, and no report is
#                         stamped incomplete by it. It refuses when the judge did
#                         leave a verdict, and while the judge still LOOKS LIVE:
#                         a runtime record with no terminal status event yet. A
#                         judge with a terminal event, or one whose runtime record
#                         is gone, can be replaced.
#   --dry-run             with `start`, resolve and print the lineup without
#                         writing or dispatching anything.
#
# Roles are pinned here; models are not. `config/model-panel.json` maps each
# role to a dispatch profile, and docs/configuration.md "Model panel roles" owns
# that schema, the configuration lookup order, and the degradation contract.
# Every role resolves through bin/fm-dispatch-select.sh, so panel profiles get
# the same validation and quota-aware array selection as crew dispatch profiles.
#
# Every seat - both analysts and the judge - resolves through THE SAME THREE
# STAGES IN THE SAME ORDER, which is what stops one seat from accepting a
# candidate another seat rejects:
#   1. VALIDATE  the shared selector checks every CONFIGURED candidate
#                (`--validate-only`), before any panel-local narrowing, so an
#                invalid candidate refuses the seat by name rather than being
#                filtered out of sight.
#   2. FILTER    panel-local identity preference narrows that validated set to
#                candidates whose model the panel is not already using. It
#                narrows only: it never reshapes the spec and never hands the
#                next stage an empty set, so when nothing survives the
#                configured set stands and the seat's own refusal or warning
#                speaks.
#   3. SELECT    the shared selector picks one of what remains. Whenever exactly
#                one candidate remains - one configured profile object, or one
#                survivor of the filter - it IS the resolution, and no quota
#                lookup or randomness runs to arrive at the only option.
# A stage's prerequisites belong to that stage: nothing on a resolution path may
# require a host utility that path does not run.
#
# Configured model identity for the distinctness test exists only when the
# resolved profile explicitly pins a model. It is that model name with any
# provider prefix and any `:suffix` removed (the normalization bin/fm-dispatch-
# select.sh already uses). A harness name identifies a launcher, not the model
# its mutable default will run, so an unpinned profile has UNKNOWN model identity
# rather than a `harness:<name>` placeholder. A full panel refuses an unpinned
# analyst, while an unpinned judge gets the same visible warning class as a known
# judge collision and proceeds under the existing judge-independence policy.
#
# This check establishes distinct configured model names, not distinct endpoints
# or weights: different names can still be aliases outside Firstmate's view. It
# never asks a running model to identify itself, because a model self-report is
# not evidence of the endpoint or weights that served it.
#
# Degradation is explicit, never silent: when either analyst has unknown model
# identity or both analysts resolve to the same identity, `start` refuses with
# exit 4 and names both the configuration fix and the `--reduced` alternative.
# Two analysts whose independence cannot be established are not a panel, and
# presenting them as one is worse than running none. When no third distinct
# model is available, the judge may share an analyst's model; that is a printed
# warning rather than a refusal, because the judge's independence comes from
# re-verifying against live state with both reports in hand.
#
# The two-condition judge gate is deliberate. A report file that EXISTS is not a
# report that is FINISHED, and dispatching the judge against a half-written
# analysis silently judges a truncated argument. The completion half is a status
# EVENT rather than a live crew-state read, because panel members are ordinary
# scouts that may be torn down before the judge is dispatched, and a gate with a
# fallback for that case would quietly become the fallback. `failed:`
# counts as terminal on purpose: the question is whether the analyst stopped
# writing, not whether it succeeded, and a failed analyst that still left a
# non-empty report is finished. The verbs are recognized through
# bin/fm-classify-lib.sh, this repo's owner of the status-event vocabulary, and
# the scan asks only whether such an event EVER appeared, which is monotonic -
# never what the last line currently says. The gate governs the judge's own
# report on exactly the same terms: the trap does not care which hop it is on,
# and handing the panel's final verdict out under a weaker rule than the one
# guarding its inputs would be absurd.
#
# ROOT CAUSE FOR ANY FUTURE CLASSIFICATION, stated once because it has already
# cost three separate repairs: bin/fm-teardown.sh removes a member's
# state/<id>.status and state/<id>.meta together, so the ABSENCE of either means
# TORN DOWN rather than NEVER EXISTED, and any new member classification must
# decide which of those two it is before it decides anything else.
#
# READINESS IS LATCHED, and the reason is a maintenance warning worth keeping.
# The gate was originally designed on the premise that the terminal status event
# is durable and survives cleanup. It is not: bin/fm-teardown.sh removes
# state/<id>.status and state/<id>.meta together, so a member that finished
# correctly and was then torn down became indistinguishable from one that
# vanished mid-write, and the only way past it stamped `accepted_unfinished` on a
# COMPLETE report and told the judge to distrust it. The premise was relayed and
# ruled on without anyone reading the code that deletes those files, which is
# exactly the verify-status-prose-against-live-state discipline the briefs below
# impose on every analyst; the capability's own design skipped it. So the FIRST
# time `advance` observes both conditions for a member, that readiness is written
# to `ready_members` in data/<panel-id>/panel.meta, which does survive teardown,
# and every later invocation trusts the latch. Do not re-derive readiness from
# state/ alone. A narrow window remains: a member torn down before any `advance`
# observed it is never latched, so it can still be classified `unsignalled-gone`
# and stamped `accepted_unfinished` on a complete report, which is an accepted
# bounded tradeoff of this design.
#
# That gate can WEDGE, and the escape from it is deliberately manual and
# deliberately narrow. Writing the report and appending the terminal line are two
# separate acts, and the gap between them is the ORDINARY window: a member that
# still has its runtime record may simply be revising, so `advance` prints the
# plain `waiting:` line there and does not mention the override at all. Offering
# the escape in that window would invite the operator to recreate the exact race
# this gate closes, at the one moment it looks most reasonable to accept.
#
# The `wedged:` block is therefore gated on the member being GONE with no latched
# readiness: it left a report, nothing ever recorded it as finished, and its
# runtime record is no longer there, so only an operator can decide. That block
# names the member, gives the exact
# `--accept-unfinished <task-id>` command, and says plainly that accepting means
# judging a possibly INCOMPLETE report. The acceptance is recorded in the panel
# record as `accepted_unfinished`, so the provenance of the verdict carries the
# caveat forever, the judge's brief names the report it must treat as possibly
# truncated, and EVERY `complete:` output for an accepted judge repeats the
# caveat rather than only the invocation that recorded it. The override itself
# stays usable against a member that still looks present, because a crashed
# member keeps its runtime record and a hard refusal there would rebuild the
# no-escape dead end; used that way it warns loudly, on that invocation, that the
# member may still be writing.
#
# An ANALYST that stops writing with NO report is a different fact again, whether
# it declared itself finished or simply went away: no report can arrive and the
# panel's premise has failed.
# That prints a `stood down:` block naming the member, records `stage=stood-down`
# so the panel record says honestly what happened, and exits 1. The override
# never waives it, because a verdict built on the one report that survived is not
# a panel. If that surviving analysis is still wanted, it is a NEW single-analyst
# review started deliberately with `--reduced` and labelled as such everywhere,
# never this panel converted in place.
#
# A JUDGE that stops writing with no report costs something else entirely: the
# evidence is complete and untouched, and only the adjudication is missing, so
# standing the panel down would discard two finished investigations because the
# third member crashed. That prints a `verdict lost:` block instead, and
# `--rejudge` dispatches ONE replacement judge over the same unchanged reports,
# recording the superseded task in `superseded_judges`. It is explicit and
# recorded exactly like `--accept-unfinished`, never automatic, and it stamps no
# incompleteness on reports that were complete.
#
# There is deliberately NO time-based, retry-count-based, or attempt-count-based
# path that advances a panel on its own, and none may be added. An automatic
# timeout would reinstate exactly the half-written-report failure this gate
# closes, only on a delay and with nobody watching. Waiting waits forever until a
# human decides.
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

# Print the raw spec (profile object or profile array) for one role, walking the
# SAME dispatch precedence bin/fm-spawn.sh walks, all the way to its end: the
# panel config's entry, then config/crew-dispatch.json's default profile set,
# then the static crewmate harness bin/fm-harness.sh resolves. The crew-dispatch
# fallback is what lets a home that already declares which runtimes it dispatches
# on run a panel with no extra configuration; the static-harness hop is what
# every home has BY CONSTRUCTION, because both profile files are optional, and
# stopping before it left a home that dispatches crew perfectly well unable to
# start a panel at all.
# That last hop carries a harness and no model, so it can never invent an
# identity: a full panel still lands on the honest exit-4 unpinned-analyst
# refusal, and what it actually lets run is the reduced form and the judge seat.
role_spec() {
  local role=$1 spec='' harness=''
  if [ -f "$PANEL_CONFIG" ]; then
    jq . "$PANEL_CONFIG" >/dev/null 2>&1 || die "$PANEL_CONFIG is not valid JSON"
    spec=$(jq -c --arg role "$role" '.roles[$role] // empty' "$PANEL_CONFIG")
  fi
  if [ -z "$spec" ] && [ -f "$CREW_DISPATCH" ]; then
    jq . "$CREW_DISPATCH" >/dev/null 2>&1 || die "$CREW_DISPATCH is not valid JSON"
    spec=$(jq -c '.default // empty' "$CREW_DISPATCH")
  fi
  if [ -z "$spec" ]; then
    harness=$("$FM_ROOT/bin/fm-harness.sh" crew 2>/dev/null || true)
    # `unknown` is fm-harness.sh's own sentinel for a harness it could not
    # detect, so it names no runtime and fills no seat. Anything else it prints
    # goes to the shared selector, which owns which harnesses are verified and
    # refuses an unverified one by name.
    [ -z "$harness" ] || [ "$harness" = unknown ] \
      || spec=$(jq -cn --arg harness "$harness" '{harness: $harness}')
  fi
  [ -n "$spec" ] || die "no profile for panel role '$role': add roles.$role to $PANEL_CONFIG (see docs/examples/model-panel.json), a default profile set in $CREW_DISPATCH, or a crewmate harness in $CONFIG/crew-harness"
  printf '%s\n' "$spec"
}

# The ONE definition of a profile's configured model identity, interpolated by
# every jq program below so the exit-4 distinctness check and the exclusion
# filter cannot disagree about what counts as one known model. An unpinned
# profile returns null because its harness default is runtime state, not identity.
# Keep this normalization in step with
# bin/fm-dispatch-select.sh's model_name normalization.
# shellcheck disable=SC2016  # $m is a jq binding, deliberately not shell-expanded
PANEL_CONFIGURED_IDENT_JQ='def ident:
  (.model // "") as $m
  | if ($m | length) > 0 then ($m | split("/") | last | split(":") | first | ascii_downcase)
    else null
    end;'

profile_configured_identity() {
  printf '%s\n' "$1" | jq -r "$PANEL_CONFIGURED_IDENT_JQ"' ident // empty'
}

profile_field() {
  printf '%s\n' "$1" | jq -r --arg field "$2" '.[$field] // ""'
}

# The FILTER stage. Keep only candidates with a known configured model identity
# outside the newline-separated exclusion list, so an array prefers a known
# unused model over both a duplicate and an unpinned harness default. When none
# remain, resolve_role falls back to the original spec so the selected concrete
# profile reaches the caller's role-specific refusal or warning.
# resolve_role calls this only with the array form; the coercion below is what
# is left of a version that reshaped a single profile object into an array and
# sent it through selection instead of resolving it to itself.
filter_spec() {
  local spec=$1 excluded=$2
  printf '%s\n' "$spec" | jq -c --arg excluded "$excluded" "$PANEL_CONFIGURED_IDENT_JQ"'
    ($excluded | split("\n") | map(select(length > 0))) as $ex
    | (if type == "array" then . else [.] end)
    | map(select((ident) as $i | ($i != null) and (($ex | index($i)) == null)))
  '
}

# Resolve one role to a concrete profile through the shared dispatch selector,
# in three stages that answer three different questions and never do each
# other's work. VALIDATE asks the shared selector whether every candidate this
# seat was CONFIGURED with is legal, so one bad candidate refuses the seat by
# name instead of being quietly filtered out of the set the operator would have
# been told about. FILTER narrows that validated set to the identities the panel
# has not already spent, and narrows only: when nothing survives, the configured
# set stands and the caller's own refusal or warning speaks. SELECT picks one of
# what remains. The order is the same for every seat, analysts and judge alike,
# so no seat can accept what another rejects.
resolve_role() {
  local role=$1 excluded=${2:-} spec filtered count profile errors status=0
  # role_spec runs in a command substitution, so its refusal exits THAT subshell
  # and not this function: without this check an empty spec walked on into the
  # shared selector, which printed its own internal parse error over the
  # actionable one and turned a missing configuration into a mechanical failure.
  spec=$(role_spec "$role") || exit 1
  errors=$(mktemp "${TMPDIR:-/tmp}/fm-model-panel-select.XXXXXX")
  "$FM_ROOT/bin/fm-dispatch-select.sh" --validate-only "$spec" 2>"$errors" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'error: panel role %s could not be resolved:\n' "$role" >&2
    cat "$errors" >&2
    rm -f "$errors"
    exit 1
  fi
  if [ "$(printf '%s\n' "$spec" | jq -r 'type')" = array ]; then
    filtered=$(filter_spec "$spec" "$excluded")
    count=$(printf '%s\n' "$filtered" | jq 'length')
    if [ "$count" -eq 0 ]; then
      filtered=$spec
      count=$(printf '%s\n' "$spec" | jq 'length')
    fi
    spec=$filtered
    # One candidate is not a choice. Hand the selector that profile rather than
    # a one-element array, so a seat with nothing left to choose between never
    # enters quota lookup or random selection to arrive at its only option.
    [ "$count" -ne 1 ] || spec=$(printf '%s\n' "$spec" | jq -c '.[0]')
  fi
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

refuse_unpinned_analyst() {
  local role=$1
  printf 'error: this would not be a panel: %s resolves to a profile with no explicit model pin.\n' "$role" >&2
  printf '  A harness name identifies a launcher, not the runtime model selected by its mutable default.\n' >&2
  printf '  Pin roles.%s.model in %s so the two analyst identities can be compared,\n' "$role" "$PANEL_CONFIG" >&2
  printf '  or re-run with --reduced for the single-analyst review, which is labelled as such everywhere it appears.\n' >&2
  exit 4
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
  local out=$1 question_file=$2 report_path=$3 form=$4 report_a=$5 report_b=$6 unfinished=${7:-}
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
    if [ -n "$unfinished" ]; then
      cat <<'EOF'

## Reports accepted without their author finishing

EOF
      printf '%s\n' "$unfinished"
      cat <<'EOF'

Each report listed above was accepted although its author never signalled that it had finished, so it may be truncated or incomplete.
Treat what is absent from it as missing rather than as evidence that there was nothing to find, and say plainly in your own report which report was incomplete and what that cost the verdict.
This discloses the report's completeness only; which model wrote it is still withheld, and blind judging is unchanged.
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
  [ "${#panel_id}" -le 56 ] || die "panel id '$panel_id' is too long; task ids append up to -judge99 and must stay within 64 characters" 2

  # Resolve the lineup. analyst-b excludes analyst-a's model so an array-backed
  # role picks a second model rather than duplicating the first, and the judge
  # excludes both.
  local profile_a identity_a profile_judge identity_judge excluded
  local profile_b='' identity_b=''
  profile_a=$(resolve_role analyst_a)
  identity_a=$(profile_configured_identity "$profile_a")
  if [ "$form" = panel ] && [ -z "$identity_a" ]; then
    refuse_unpinned_analyst analyst_a
  fi
  excluded=$identity_a
  if [ "$form" = panel ]; then
    profile_b=$(resolve_role analyst_b "$identity_a")
    identity_b=$(profile_configured_identity "$profile_b")
    if [ -z "$identity_b" ]; then
      refuse_unpinned_analyst analyst_b
    fi
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
  identity_judge=$(profile_configured_identity "$profile_judge")
  if [ "$form" != panel ] && { [ -z "$identity_a" ] || [ -z "$identity_judge" ]; }; then
    warn "at least one reduced-form seat has no explicit model pin, so whether the judge shares the analyst's runtime model is unknown; it still re-verifies against live state with the report in hand"
  elif [ -z "$identity_judge" ]; then
    warn "the judge has no explicit model pin, so its runtime model identity is unknown and may be the same model as one analyst; it still re-verifies against live state with every report in hand"
  else
    case "$identity_judge" in
      "$identity_a"|"${identity_b:-$identity_a}")
        warn "no third distinct model is available, so the judge runs on $identity_judge, the same model as one analyst; it still re-verifies against live state with every report in hand"
        ;;
    esac
  fi

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

# 0 when this member's terminal status event was explicitly waived by an operator.
member_accepted_unfinished() {  # <task-id> <accepted-list>
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# 0 when this member was ALREADY observed to satisfy both gate conditions and
# that observation was latched into the panel record. The latch is the durable
# half of the gate: state/<id>.status does not survive teardown, so without it a
# member that finished correctly and was then cleaned up is indistinguishable
# from one that vanished mid-write.
member_ready_latched() {  # <task-id> <latched-list>
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# 0 when both gate conditions are observable RIGHT NOW from live signals. True
# only while state/<id>.status still exists, which is why the result is latched
# the first time it is seen.
member_observed_ready() {  # <task-id>
  [ -s "$DATA/$1/report.md" ] || return 1
  status_has_finished_event "$STATE/$1.status"
}

# 0 while the fleet still tracks this task. Its absence does NOT prove the member
# died without declaring itself: teardown removes state/<id>.meta and
# state/<id>.status together, so this only separates a member that is still
# around from one that is not, and the latch above is what keeps a finished
# member from being misread as a vanished one.
member_still_present() {  # <task-id>
  [ -f "$STATE/$1.meta" ]
}

# One member's position against the two gate conditions. The same predicate
# serves every member, analysts and judge alike, because the judge is an ordinary
# scout that appends `done:` exactly as they do. status_has_finished_event comes
# from bin/fm-classify-lib.sh and asks only whether a terminal event EVER
# appeared.
#   ready             both conditions hold, now or at a latched earlier moment
#                     (or the terminal event was explicitly waived)
#   finished-empty    ended terminal with no report; nothing further can arrive
#   gone-empty        gone with no report and no terminal event; same fact
#   unsignalled-gone  a report is there, its author is gone and never declared
#   unsignalled-live  a report is there and its author is still present
#   working           still present and nothing written yet
member_state() {  # <task-id> <accepted-list> <latched-list>
  local id=$1 accepted=$2 latched=$3 finished=0
  if member_ready_latched "$id" "$latched"; then
    printf 'ready\n'
    return 0
  fi
  if status_has_finished_event "$STATE/$id.status" \
    || member_accepted_unfinished "$id" "$accepted"; then
    finished=1
  fi
  if [ -s "$DATA/$id/report.md" ]; then
    if [ "$finished" -eq 1 ]; then
      printf 'ready\n'
    elif member_still_present "$id"; then
      printf 'unsignalled-live\n'
    else
      printf 'unsignalled-gone\n'
    fi
  else
    if [ "$finished" -eq 1 ]; then
      printf 'finished-empty\n'
    elif member_still_present "$id"; then
      printf 'working\n'
    else
      printf 'gone-empty\n'
    fi
  fi
}

# The two conditions are different facts and the operator needs to know which one
# is missing, so each names itself.
member_wait_reason() {  # <task-id> <accepted-list> <latched-list>
  local id=$1
  case "$(member_state "$id" "$2" "$3")" in
    finished-empty)
      printf '%s has finished but its report %s is empty or absent\n' "$id" "$DATA/$id/report.md" ;;
    gone-empty)
      printf '%s is gone without ever writing a terminal status event or a report at %s\n' \
        "$id" "$DATA/$id/report.md" ;;
    unsignalled-gone)
      printf '%s left a report but is gone without ever writing a terminal status event\n' "$id" ;;
    unsignalled-live)
      printf '%s left a report but has not written its terminal status event yet\n' "$id" ;;
    working)
      printf '%s has written no terminal status event yet (no done: or failed: line in %s) and no report\n' \
        "$id" "$STATE/$id.status" ;;
  esac
}

# The one state that can never clear on its own: the member is gone, so the
# terminal line will never arrive and only an operator can decide. This advice is
# deliberately NOT printed for a member that is still present, because the gap
# between writing a report and declaring done is the ordinary write-then-declare
# window, and offering the override there would invite the operator to recreate
# the exact race this gate exists to close.
member_unsignalled_advice() {  # <panel-id> <task-id>
  local panel_id=$1 id=$2
  printf 'panel:   %s left a non-empty report at %s but never wrote a terminal status event, and it has no runtime record left, so it was torn down or died and that line will never arrive.\n' \
    "$id" "$DATA/$id/report.md"
  printf 'panel:   To accept its report as final, naming that one member explicitly:\n'
  printf 'panel:     %s advance %s --accept-unfinished %s\n' "$0" "$panel_id" "$id"
  printf 'panel:   That accepts a report which may be INCOMPLETE: it is recorded permanently in %s, and the judge is told to treat that report as possibly truncated.\n' \
    "$(panel_meta_path "$panel_id")"
  printf 'panel:   There is no timeout and nothing advances on its own; this panel waits until you decide.\n'
}

# The panel's premise has failed: a member stopped writing without leaving the
# report the formation is built on, so no report can arrive and there is nothing
# to judge.
panel_stood_down_block() {  # <panel-id> <task-id>...
  local panel_id=$1 id
  shift
  printf 'stood down: panel %s cannot be completed.\n' "$panel_id"
  for id in "$@"; do
    printf 'panel:   %s has stopped writing and left no report at %s, so no report can arrive.\n' \
      "$id" "$DATA/$id/report.md"
  done
  printf 'panel:   --accept-unfinished deliberately refuses to waive a report that does not exist: a verdict built on what survives is not a panel.\n'
  printf 'panel:   Stand this panel down and tell the captain it produced no verdict.\n'
  # shellcheck disable=SC2016  # the backticks are markdown emphasis in the printed block, not a command substitution
  printf 'panel:   If the surviving analysis is still wanted, that is a NEW single-analyst review started deliberately with `start --reduced`, which is labelled as such everywhere, never this panel converted in place.\n'
}

# A dead JUDGE is a different failure from a dead analyst: the evidence is
# complete and intact, only the adjudication is missing, so re-judging the same
# unchanged reports preserves the formation's property exactly rather than
# salvaging around it.
panel_rejudge_block() {  # <panel-id> <judge-task-id>
  local panel_id=$1 id=$2
  printf 'verdict lost: panel %s has every analyst report but no verdict.\n' "$panel_id"
  printf 'panel:   %s has stopped writing and left no verdict at %s, so the adjudication is missing while the evidence is untouched.\n' \
    "$id" "$DATA/$id/report.md"
  printf 'panel:   Every analyst report is complete and unchanged, so a fresh judge can adjudicate exactly the same evidence:\n'
  printf 'panel:     %s advance %s --rejudge\n' "$0" "$panel_id"
  printf 'panel:   That dispatches ONE replacement judge over those same reports, records %s as superseded in %s, and stamps no incompleteness on any report.\n' \
    "$id" "$(panel_meta_path "$panel_id")"
  printf 'panel:   Nothing re-dispatches on its own; this panel waits until you decide.\n'
}

# Print the gate outcome for these members and return:
#   0 the panel must not advance yet; a `waiting:` or `wedged:` outcome was printed
#   1 every member is ready
#   2 a member ended terminal with no report; the caller owns that outcome,
#     because it costs a panel its premise but costs a judge only its verdict
# Every non-terminal outcome names the next command. Members observed ready for
# the first time are reported in PANEL_NEWLY_READY for the caller to latch.
PANEL_STOOD_DOWN=''
PANEL_NEWLY_READY=''
panel_gate_wait() {  # <panel-id> <gate-sentence> <hint-tail> <accepted-list> <latched-list> <task-id>...
  local panel_id=$1 sentence=$2 hint=$3 accepted=$4 latched=$5
  shift 5
  local id state reasons=''
  local -a gone=() empty=()
  PANEL_NEWLY_READY=''
  for id in "$@"; do
    if ! member_ready_latched "$id" "$latched" && member_observed_ready "$id"; then
      PANEL_NEWLY_READY="${PANEL_NEWLY_READY:+$PANEL_NEWLY_READY }$id"
    fi
    state=$(member_state "$id" "$accepted" "$latched")
    [ "$state" != ready ] || continue
    [ "$state" != unsignalled-gone ] || gone+=("$id")
    [ "$state" != finished-empty ] || empty+=("$id")
    [ "$state" != gone-empty ] || empty+=("$id")
    reasons="${reasons:+$reasons; }$(member_wait_reason "$id" "$accepted" "$latched")"
  done
  [ -n "$reasons" ] || return 1
  if [ "${#empty[@]}" -gt 0 ]; then
    PANEL_STOOD_DOWN="${empty[*]}"
    return 2
  fi
  if [ "${#gone[@]}" -gt 0 ]; then
    printf 'wedged: %s; %s\n' "$sentence" "$reasons"
    for id in "${gone[@]}"; do
      member_unsignalled_advice "$panel_id" "$id"
    done
  else
    printf 'waiting: %s; %s\n' "$sentence" "$reasons"
  fi
  panel_next_hint "$panel_id" "$hint"
  return 0
}

# The completion output, which must carry the accepted-unfinished caveat every
# time it is printed rather than only on the invocation that recorded it: a
# caveat the operator learns second-hand is not a caveat.
panel_complete_output() {  # <report-judge> <judge-task-id> <accepted-list>
  printf 'complete: %s\n' "$1"
  if member_accepted_unfinished "$2" "$3"; then
    printf 'panel: CAVEAT: this verdict was accepted without %s ever writing a terminal status event, so the report may be INCOMPLETE; say so when you relay it.\n' "$2"
  fi
  printf 'panel: read that report, relay its findings, and pass the shared completion gate before standing the panel down\n'
}

# Record the dead panel durably, so the record says honestly what happened
# instead of reading like a panel still waiting on a report.
panel_stand_down() {  # <meta-path>
  panel_meta_set "$1" stood_down "$PANEL_STOOD_DOWN"
  panel_meta_set "$1" stage stood-down
  exit 1
}

# Move the readiness just observed into the panel record, which lives under
# data/ and genuinely survives teardown, and echo the updated list.
panel_latch_ready() {  # <meta-path> <latched-list>
  local meta=$1 latched=$2
  if [ -n "$PANEL_NEWLY_READY" ]; then
    latched="${latched:+$latched }$PANEL_NEWLY_READY"
    panel_meta_set "$meta" ready_members "$latched"
  fi
  printf '%s\n' "$latched"
}

# The task id for a replacement judge. The panel id is capped so that every id
# this can generate stays within the 64-character task-id limit.
panel_next_judge_id() {  # <panel-id> <superseded-list>
  local panel_id=$1 n=2 id
  for id in $2; do
    n=$((n + 1))
  done
  [ "$n" -le 99 ] || die "panel '$panel_id' has already replaced its judge $((n - 2)) times; stand it down rather than replacing it again"
  printf '%s-judge%s\n' "$panel_id" "$n"
}

cmd_status() {
  local panel_id=${1:-}
  [ -n "$panel_id" ] || die "status requires a panel id" 2
  local meta
  meta=$(require_panel "$panel_id")
  cat "$meta"
}

cmd_advance() {
  local panel_id='' want_value='' arg rejudge=0
  local -a accept=()
  for arg in "$@"; do
    if [ -n "$want_value" ]; then
      accept+=("$arg")
      want_value=
      continue
    fi
    case "$arg" in
      --accept-unfinished) want_value=accept ;;
      --accept-unfinished=*) accept+=("${arg#--accept-unfinished=}") ;;
      --rejudge) rejudge=1 ;;
      --*) die "unknown option $arg" 2 ;;
      *)
        [ -z "$panel_id" ] || die "advance takes exactly one panel id" 2
        panel_id=$arg
        ;;
    esac
  done
  [ -z "$want_value" ] || die "--accept-unfinished requires a task id" 2
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

  local accepted latched
  accepted=$(panel_meta_get "$meta" accepted_unfinished)
  latched=$(panel_meta_get "$meta" ready_members)

  # The stage is settled before any acceptance is recorded, so the panel record
  # never carries verdict provenance for a panel that cannot use it.
  case "$stage" in
    incomplete)
      die "panel '$panel_id' never finished dispatching; decide whether to retry it or stand it down before advancing"
      ;;
    stood-down)
      # shellcheck disable=SC2046  # the recorded member list is a space-separated field, deliberately split
      panel_stood_down_block "$panel_id" $(panel_meta_get "$meta" stood_down)
      exit 1
      ;;
    complete)
      panel_complete_output "$report_judge" "$id_judge" "$accepted"
      return 0
      ;;
    judge|analysts) ;;
    *) die "panel '$panel_id' has an unknown stage '$stage'" ;;
  esac

  if [ "${#accept[@]}" -gt 0 ]; then
    local want
    for want in "${accept[@]}"; do
      case "$want" in
        "$id_a"|"$id_judge") : ;;
        "${id_b:-$id_a}") : ;;
        *) die "'$want' is not a member of panel '$panel_id' (its members are $id_a${id_b:+, $id_b}, and $id_judge)" 2 ;;
      esac
      [ -s "$DATA/$want/report.md" ] \
        || die "$want has no report at $DATA/$want/report.md, so there is nothing to accept; a missing report is never waived" 2
      if member_ready_latched "$want" "$latched" || member_observed_ready "$want"; then
        die "$want finished and left a report at $DATA/$want/report.md, so there is nothing to waive; the caveat is only for a report whose author never declared it finished" 2
      fi
      if member_still_present "$want"; then
        warn "$want still has a runtime record, so it may STILL BE WRITING $DATA/$want/report.md; accepting it now risks judging a report that is not finished"
      fi
      member_accepted_unfinished "$want" "$accepted" \
        || accepted="${accepted:+$accepted }$want"
    done
    panel_meta_set "$meta" accepted_unfinished "$accepted"
    printf 'panel: recorded %s as accepted without a terminal status event; that report may be incomplete and the panel record now says so permanently\n' \
      "${accept[*]}"
  fi

  local gate=0 superseded='' superseded_of=''
  if [ "$rejudge" -eq 1 ]; then
    [ "$stage" = judge ] \
      || die "--rejudge replaces a judge that was dispatched and left no verdict, but panel '$panel_id' is at stage '$stage'" 2
    [ ! -s "$report_judge" ] \
      || die "$id_judge left a verdict at $report_judge, so there is nothing to re-judge; discarding a written verdict is not this command's job" 2
    # Refused only while the judge still LOOKS live. Requiring a terminal event
    # outright would make a torn-down judge unreplaceable forever, because
    # teardown removes the status file that would prove it.
    if member_still_present "$id_judge" && ! status_has_finished_event "$STATE/$id_judge.status"; then
      printf 'error: %s still has a runtime record and has written no terminal status event, so it appears to be running and may still be writing its verdict.\n' "$id_judge" >&2
      printf '  Wait for it to append done: or failed:, and re-run --rejudge if it finishes without a verdict.\n' >&2
      printf '  If you know it is dead, tear it down first; a judge with no runtime record can be replaced immediately.\n' >&2
      exit 2
    fi
    superseded=$(panel_meta_get "$meta" superseded_judges)
    local replacement
    replacement=$(panel_next_judge_id "$panel_id" "$superseded")
    # A directory left by a failed replacement dispatch is ours to reuse, on the
    # same terms as the judge path below: only a report or a runtime record means
    # the id is genuinely taken.
    [ ! -s "$DATA/$replacement/report.md" ] \
      || die "the replacement judge task $replacement already has a report at $DATA/$replacement/report.md; reconcile it before re-judging"
    printf 'panel: replacing %s with %s over the same unchanged analyst reports\n' "$id_judge" "$replacement"
    superseded_of=$id_judge
    id_judge=$replacement
    report_judge="$DATA/$id_judge/report.md"
  elif [ "$stage" = judge ]; then
    panel_gate_wait "$panel_id" \
      'the panel is complete only once the judge has finished AND left a non-empty report' \
      "once the judge reports done" "$accepted" "$latched" "$id_judge" || gate=$?
    latched=$(panel_latch_ready "$meta" "$latched")
    case "$gate" in
      0) return 0 ;;
      2)
        panel_rejudge_block "$panel_id" "$id_judge"
        return 0
        ;;
    esac
    panel_meta_set "$meta" stage complete
    panel_complete_output "$report_judge" "$id_judge" "$accepted"
    return 0
  else
    panel_gate_wait "$panel_id" \
      'the judge is created only once every analyst has finished AND left a non-empty report' \
      "after the next analyst finishes" "$accepted" "$latched" "$id_a" ${id_b:+"$id_b"} || gate=$?
    latched=$(panel_latch_ready "$meta" "$latched")
    case "$gate" in
      0) return 0 ;;
      2)
        # shellcheck disable=SC2086  # the member list is space-separated, deliberately split
        panel_stood_down_block "$panel_id" $PANEL_STOOD_DOWN
        panel_stand_down "$meta"
        ;;
    esac
  fi

  # The judge task was never dispatched if it has no runtime record, so a brief
  # left behind by a failed dispatch is ours to regenerate.
  if [ -f "$STATE/$id_judge.meta" ]; then
    die "the judge task $id_judge already has a runtime record but the panel stage is '$stage'; reconcile that task before advancing"
  fi
  rm -f "$DATA/$id_judge/brief.md"

  local unfinished='' label_a='Analyst A'
  [ "$form" = panel ] || label_a='Analyst'
  if member_accepted_unfinished "$id_a" "$accepted"; then
    unfinished="- $label_a: \`$report_a\`"
  fi
  if [ -n "$id_b" ] && member_accepted_unfinished "$id_b" "$accepted"; then
    unfinished="${unfinished:+$unfinished
}- Analyst B: \`$report_b\`"
  fi

  local task_judge
  trap panel_cleanup EXIT
  task_judge=$(panel_mktemp)
  compose_judge_task "$task_judge" "$question_path" "$report_judge" "$form" "$report_a" "$report_b" "$unfinished"
  scaffold_scout_brief "$id_judge" "$(basename "$project")" "$task_judge"
  dispatch_scout "$id_judge" "$project" "$profile_judge" \
    || die "could not dispatch the judge ($id_judge); every analyst report is still in place, so this is safe to retry"
  if [ -n "$superseded_of" ]; then
    panel_meta_set "$meta" superseded_judges "${superseded:+$superseded }$superseded_of"
    panel_meta_set "$meta" judge_task "$id_judge"
  fi
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
