#!/usr/bin/env bash
# Answer, ON DEMAND, what canonical upstream carries that this fork does not,
# and give every one of those changes a verdict that can be defended.
#
# WHAT THIS IS FOR
# On 2026-08-24 the captain refused a standing report he cannot act on ("i just
# dont want to get informed permanently that blabla commits behind source") and
# in the same breath asked for the acting ("you setup a cadence daily to check
# upstream and integrate upstream into our code"). Those read as opposite and
# are not: the objection is to a count that fires forever and produces no work.
# This script is therefore the reading and nothing else. It arms nothing, it
# registers no watcher check, it writes no diagnostic any startup sweep reads,
# and it speaks only when someone runs it. THAT SILENCE IS A REQUIREMENT OF THIS
# SCRIPT, not an accident of it; tests/fm-upstream-distance.test.sh proves the
# session-start digest gains no line from anything here.
#
# It measures and reports. It never fetches into the checkout, never merges,
# never writes under projects/, and changes no working tree.
#
# THE VERDICTS, AND WHY EACH ONE IS HONEST
# Four, applied to every upstream-only change, never to a sample of them:
#
#   absorbed     This fork already carries this change's effect, PROVEN by
#                patch equivalence (git cherry reports it as equivalent to a
#                commit the fork already has). Nothing weaker earns this word.
#   converged    Every path the change touches EXISTS ON BOTH SIDES and the two
#                default branches hold identical content for all of them. That
#                is evidence the effect may already be present, NOT proof that
#                this change is what put it there, so a converged change is
#                confirmed at content level before it is ever dropped.
#                docs/fork-patches.md rejects exactly this test as a registry
#                verdict; it is kept here, under its own name, as triage.
#   superseded   No path the change touches survives in UPSTREAM'S OWN default
#                branch, so there is nothing left to take. This is the fourth
#                category, and it exists because the other three are all lies
#                for this shape: absorbed claims the fork carries an effect
#                nobody carries, converged claims agreement between two absent
#                files, and needs-review sends a reader to a file that does not
#                exist. docs/fork-upstream-merge-assessment.md left the same
#                shape open for the patch registry ("a fork patch superseded
#                inside the fork"); this is the upstream-side twin of it, and
#                naming it here does not decide the registry's own column.
#   needs-review Everything else: still live upstream, not demonstrably carried
#                here. A human decides. This is the DEFAULT, and it is where a
#                change goes whenever the evidence is short of the above.
#
# THE DEFECT THIS REPLACES, AND WHY THE FOURTH VERDICT IS STRUCTURAL
# The retired bin/fm-fork-sync-check.sh labelled a change absorbed when
# `git diff --quiet <fork> <upstream> -- <files the commit touched>` was quiet.
# That comparison is quiet when a path is absent from BOTH tips, so a change
# whose file neither side still has read as absorbed - which accounted for 16 of
# the 17 patches it then labelled (docs/fork-upstream-merge-assessment.md).
# Absence cannot reach `absorbed` here, because `absorbed` rests only on patch
# equivalence, and it cannot reach `converged` either, because `converged`
# requires the path to be PRESENT on both sides before their content is
# compared. Absence is routed to `superseded` on purpose and by name.
#
# COUNTING, NOT SAMPLING
# Every upstream-only non-merge commit is enumerated and verdicted, so the
# totals and the per-verdict counts are counts of the whole range. The terminal
# detail list is windowed by --limit purely so a 250-change reading fits a
# screen, and it says how many of how many it is showing; the report file always
# carries every change. A truncated list is indistinguishable from a short one,
# and this fleet has already reported "twelve commits" from a head -12 when the
# real figure was 72 (docs/pin-age-check.md).
#
# WHICH TWO REPOSITORIES, ALWAYS NAMED
# Both sides are resolved explicitly and both resolved URLs are printed in every
# reading, because a comparison that does not say what it compared cannot be
# caught reading the wrong thing: a vessel deployed from a fleet repository once
# had that repository's own commits listed as fork-only patches.
#
# Usage:
#   fm-upstream-distance.sh [options]
#
# Options:
#   --upstream <url|path>  the upstream side (default: FM_UPSTREAM_DISTANCE_URL,
#                          then the canonical upstream this fork descends from).
#   --fork <url|path>      the fork side (default: this code root's origin
#                          remote, then this code root itself).
#   --limit <n>            how many changes to print in detail; 0 prints all
#                          (default 25). The report file is never windowed.
#   --out <path>           where to write the report (default:
#                          FM_HOME/data/upstream-distance.md).
#   --no-write             take the reading and print it, write no report file.
#   --help
#
# Exit status:
#   0  the reading was taken and nothing is outstanding.
#   1  the reading was taken and there are outstanding changes (converged,
#      needs-review, or both). This is a finding, not a failure.
#   2  usage error.
#   3  the reading COULD NOT BE TAKEN. Never confuse this with 0: an instrument
#      that cannot read must not be relayed as an all-clear.
#
# Environment:
#   FM_HOME                            home whose data/ receives the report.
#   FM_UPSTREAM_DISTANCE_URL           default upstream side.
#   FM_UPSTREAM_DISTANCE_TIMEOUT       ceiling in seconds per network step
#                                      (default 30).
#   FM_UPSTREAM_DISTANCE_COMPARE_REPO  a repository already holding both
#                                      histories, used instead of fetching
#                                      (tests).
#   FM_UPSTREAM_DISTANCE_FORK_HEAD     fork-side commit in that repository
#                                      (tests).
#   FM_UPSTREAM_DISTANCE_UPSTREAM_HEAD upstream-side commit in it (tests).
#   FM_UPSTREAM_DISTANCE_NOW           timestamp stamped on the report (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# The repository this fork descends from. It is a default, not an assertion:
# every reading prints the URL it actually resolved and where that came from.
CANONICAL_UPSTREAM_DEFAULT="https://github.com/kunchenguid/firstmate.git"

STEP_TIMEOUT=${FM_UPSTREAM_DISTANCE_TIMEOUT:-30}
case "$STEP_TIMEOUT" in ''|*[!0-9]*) STEP_TIMEOUT=30 ;; esac

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die_usage() {
  printf 'fm-upstream-distance: %s\n' "$1" >&2
  printf 'usage: %s [--upstream <url>] [--fork <url>] [--limit <n>] [--out <path>] [--no-write]\n' \
    "$(basename "$0")" >&2
  exit 2
}

# Every path out of this script that could not complete the reading goes through
# here, so "could not read" can never be mistaken for "nothing to report".
unmeasurable() {
  printf 'UNMEASURABLE: %s\n' "$1" >&2
  exit 3
}

UPSTREAM_URL=${FM_UPSTREAM_DISTANCE_URL:-}
UPSTREAM_SOURCE=FM_UPSTREAM_DISTANCE_URL
[ -n "$UPSTREAM_URL" ] || {
  UPSTREAM_URL=$CANONICAL_UPSTREAM_DEFAULT
  UPSTREAM_SOURCE="the built-in canonical default"
}
FORK_URL=""
FORK_SOURCE=""
LIMIT=25
OUT=""
WRITE=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --upstream)
      [ "$#" -ge 2 ] || die_usage "--upstream needs a value"
      UPSTREAM_URL=$2
      UPSTREAM_SOURCE="--upstream"
      shift 2
      ;;
    --fork)
      [ "$#" -ge 2 ] || die_usage "--fork needs a value"
      FORK_URL=$2
      FORK_SOURCE="--fork"
      shift 2
      ;;
    --limit)
      [ "$#" -ge 2 ] || die_usage "--limit needs a value"
      case "$2" in ''|*[!0-9]*) die_usage "--limit takes a non-negative integer" ;; esac
      LIMIT=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || die_usage "--out needs a value"
      OUT=$2
      shift 2
      ;;
    --no-write) WRITE=0; shift ;;
    *) die_usage "unknown argument $1" ;;
  esac
done

[ -n "$OUT" ] || OUT="$FM_HOME/data/upstream-distance.md"
NOW=${FM_UPSTREAM_DISTANCE_NOW:-$(date -u +%Y-%m-%dT%H:%MZ)}

# Field separator for the collected detail. A commit subject can hold any
# printable character including the pipe this report renders with, so the
# internal record separator is one git can never produce in a subject.
FS=$'\x1f'

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

# Run "$@" under the per-step ceiling. With no timeout binary available the call
# runs unbounded rather than being skipped, so a host without coreutils still
# gets its reading.
bounded() {
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$STEP_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$STEP_TIMEOUT" "$@" ;;
    *) "$@" ;;
  esac
}

# --- resolve both sides ------------------------------------------------------

resolve_fork_side() {
  local url
  [ -z "$FORK_URL" ] || return 0
  if url=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null) && [ -n "$url" ]; then
    FORK_URL=$url
    FORK_SOURCE="this code root's origin remote"
    return 0
  fi
  git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    unmeasurable "$FM_ROOT is not a git repository and no --fork was given, so the fork side cannot be resolved"
  FORK_URL=$FM_ROOT
  FORK_SOURCE="this code root itself (it has no origin remote)"
}

COMPARE_REPO=${FM_UPSTREAM_DISTANCE_COMPARE_REPO:-}
TMP_REPO=""
SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-distance-work.XXXXXX") ||
  unmeasurable "temporary working storage cannot be created"
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() {
  [ -z "$TMP_REPO" ] || rm -rf "$TMP_REPO"
  rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

if [ -n "$COMPARE_REPO" ]; then
  FORK=${FM_UPSTREAM_DISTANCE_FORK_HEAD:-}
  UPSTREAM=${FM_UPSTREAM_DISTANCE_UPSTREAM_HEAD:-}
  [ -n "$FORK" ] && [ -n "$UPSTREAM" ] ||
    unmeasurable "a compare repository was supplied without both comparison heads"
  # Both sides came out of this one repository, so that is what the reading
  # names. Reporting the URL it would otherwise have fetched would describe a
  # comparison that never happened, which is the exact failure the naming
  # requirement exists to catch.
  [ -n "$FORK_URL" ] || { FORK_URL=$COMPARE_REPO; FORK_SOURCE="FM_UPSTREAM_DISTANCE_COMPARE_REPO"; }
  case $UPSTREAM_SOURCE in
    --upstream|FM_UPSTREAM_DISTANCE_URL) ;;
    *) UPSTREAM_URL=$COMPARE_REPO; UPSTREAM_SOURCE="FM_UPSTREAM_DISTANCE_COMPARE_REPO" ;;
  esac
else
  resolve_fork_side
  TMP_REPO=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-distance.XXXXXX") ||
    unmeasurable "a temporary comparison repository cannot be created"
  git -C "$TMP_REPO" init --bare -q ||
    unmeasurable "the temporary comparison repository cannot be initialized"
  bounded git -C "$TMP_REPO" fetch -q --no-tags "$FORK_URL" HEAD:refs/heads/fork ||
    unmeasurable "the fork side cannot be read ($FORK_URL, from $FORK_SOURCE)"
  bounded git -C "$TMP_REPO" fetch -q --no-tags "$UPSTREAM_URL" HEAD:refs/heads/upstream ||
    unmeasurable "the upstream side cannot be read ($UPSTREAM_URL, from $UPSTREAM_SOURCE)"
  COMPARE_REPO=$TMP_REPO
  FORK=$(git -C "$COMPARE_REPO" rev-parse --verify refs/heads/fork) ||
    unmeasurable "the fetched fork head cannot be resolved"
  UPSTREAM=$(git -C "$COMPARE_REPO" rev-parse --verify refs/heads/upstream) ||
    unmeasurable "the fetched upstream head cannot be resolved"
fi

git -C "$COMPARE_REPO" cat-file -e "$FORK^{commit}" 2>/dev/null ||
  unmeasurable "the fork comparison commit is unavailable"
git -C "$COMPARE_REPO" cat-file -e "$UPSTREAM^{commit}" 2>/dev/null ||
  unmeasurable "the upstream comparison commit is unavailable"
# Reading one repository against itself would report a distance of zero and look
# exactly like a fork that is fully current, so it refuses instead.
[ "$FORK" != "$UPSTREAM" ] ||
  unmeasurable "both sides resolve to the same commit $FORK, so there is no comparison to take"
MERGE_BASE=$(git -C "$COMPARE_REPO" merge-base "$FORK" "$UPSTREAM" 2>/dev/null) ||
  unmeasurable "the two sides share no history, so nothing can be compared across them"

# --- the tips, read once each ------------------------------------------------

# Path -> blob id for a whole tree, so presence and content are both O(1) per
# path afterwards. PRESENCE IS THE LOAD-BEARING PART: the retired check inferred
# agreement from `git diff --quiet` being silent, which it also is when a path
# is on neither side. Here a path that is not a key is absent, full stop.
declare -A FORK_BLOB=()
declare -A UPSTREAM_BLOB=()

load_tree() {
  local rev=$1 name=$2 record head type blob path tree_file
  tree_file="$SCRATCH_DIR/${name}.tree"
  git -C "$COMPARE_REPO" ls-tree -r -z "$rev" > "$tree_file" ||
    unmeasurable "the $name side's tree cannot be listed"
  # -z, so a path holding a space, a quote, or a newline is read as itself
  # rather than as git's quoted rendering of itself.
  while IFS= read -r -d '' record; do
    head=${record%%	*}
    path=${record#*	}
    [ -n "$path" ] || continue
    # shellcheck disable=SC2086  # deliberate split of git's fixed three fields.
    set -- $head
    type=$2
    blob=$3
    [ "$type" = blob ] || continue
    if [ "$name" = fork ]; then FORK_BLOB["$path"]=$blob; else UPSTREAM_BLOB["$path"]=$blob; fi
  done < "$tree_file"
}
load_tree "$FORK" fork
load_tree "$UPSTREAM" upstream
[ "${#FORK_BLOB[@]}" -gt 0 ] || unmeasurable "the fork side's tree could not be listed"
[ "${#UPSTREAM_BLOB[@]}" -gt 0 ] || unmeasurable "the upstream side's tree could not be listed"

# Commits upstream holds that are patch-equivalent to something the fork already
# has. This is the ONLY evidence that earns the word absorbed.
declare -A EQUIVALENT=()
CHERRY_FILE="$SCRATCH_DIR/cherry"
git -C "$COMPARE_REPO" cherry "$FORK" "$UPSTREAM" > "$CHERRY_FILE" ||
  unmeasurable "patch equivalence between the two sides cannot be computed"
while read -r mark sha; do
  [ "$mark" = "-" ] || continue
  EQUIVALENT["$sha"]=1
done < "$CHERRY_FILE"

# --- verdict every upstream-only change --------------------------------------

verdict_for() {
  local commit=$1 path files=0 present_upstream=0 present_both=0 same=0 paths_file
  VERDICT=needs-review
  VERDICT_WHY=""
  if [ -n "${EQUIVALENT[$commit]:-}" ]; then
    VERDICT=absorbed
    VERDICT_WHY="patch-equivalent to a commit this fork already carries"
    return 0
  fi
  paths_file="$SCRATCH_DIR/paths"
  git -C "$COMPARE_REPO" diff-tree --no-commit-id --name-only -r -z "$commit" > "$paths_file" ||
    unmeasurable "the paths touched by change $commit cannot be read"
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    files=$((files + 1))
    if [ -n "${UPSTREAM_BLOB[$path]:-}" ]; then
      present_upstream=$((present_upstream + 1))
      if [ -n "${FORK_BLOB[$path]:-}" ]; then
        present_both=$((present_both + 1))
        [ "${FORK_BLOB[$path]}" = "${UPSTREAM_BLOB[$path]}" ] && same=$((same + 1))
      fi
    fi
  done < "$paths_file"
  # Stated rather than reached by vacuous truth: with no paths at all, "no path
  # survives upstream" would be true of nothing, which is how the defect above
  # was built. A change that touches nothing is called out as touching nothing.
  if [ "$files" -eq 0 ]; then
    VERDICT=superseded
    VERDICT_WHY="the change touches no path at all"
    return 0
  fi
  if [ "$present_upstream" -eq 0 ]; then
    VERDICT=superseded
    VERDICT_WHY="none of its $files path(s) survive in upstream's own default branch"
    return 0
  fi
  if [ "$present_both" -eq "$files" ] && [ "$same" -eq "$files" ]; then
    VERDICT=converged
    VERDICT_WHY="all $files path(s) exist on both sides and hold identical content; evidence, not proof"
    return 0
  fi
  VERDICT_WHY="upstream still carries it and this fork does not demonstrably have its effect"
}

TOTAL=$(git -C "$COMPARE_REPO" rev-list --count --no-merges "$FORK..$UPSTREAM" 2>/dev/null) ||
  unmeasurable "the upstream-only change count cannot be computed"
MERGES=$(git -C "$COMPARE_REPO" rev-list --count --merges "$FORK..$UPSTREAM" 2>/dev/null) ||
  unmeasurable "the upstream-only merge count cannot be computed"
FORK_ONLY=$(git -C "$COMPARE_REPO" rev-list --count --no-merges "$UPSTREAM..$FORK" 2>/dev/null) ||
  unmeasurable "the fork-only patch count cannot be computed"

n_absorbed=0
n_converged=0
n_superseded=0
n_needs_review=0
seen=0
DETAIL=""
LOG_FILE="$SCRATCH_DIR/upstream-only.log"
git -C "$COMPARE_REPO" log --no-merges --format='%H %s' "$FORK..$UPSTREAM" > "$LOG_FILE" ||
  unmeasurable "the upstream-only changes cannot be enumerated"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  commit=${line%% *}
  summary=${line#* }
  [ "$summary" != "$line" ] || summary=""
  verdict_for "$commit"
  case $VERDICT in
    absorbed) n_absorbed=$((n_absorbed + 1)) ;;
    converged) n_converged=$((n_converged + 1)) ;;
    superseded) n_superseded=$((n_superseded + 1)) ;;
    *) n_needs_review=$((n_needs_review + 1)) ;;
  esac
  seen=$((seen + 1))
  DETAIL="${DETAIL}${VERDICT}${FS}${commit:0:12}${FS}${summary}${FS}${VERDICT_WHY}
"
# %H, the FULL commit id, because the patch-equivalence set above is keyed on
# full ids: an abbreviated key would match nothing there and report a change the
# fork demonstrably carries as needing review. The id is shortened for display
# only, after the lookup.
done < "$LOG_FILE"

# The enumeration and the count are taken by two different git invocations, so
# they are compared rather than assumed equal: a silent shortfall here is the
# sampled-instead-of-counted failure this script exists to avoid.
[ "$seen" = "$TOTAL" ] ||
  unmeasurable "counted $TOTAL upstream-only changes but could only enumerate $seen of them"

OUTSTANDING=$((n_converged + n_needs_review))

# --- report ------------------------------------------------------------------

print_detail() {
  local shown=0 verdict commit summary
  while IFS="$FS" read -r verdict commit summary _; do
    [ -n "$verdict" ] || continue
    if [ "$LIMIT" -ne 0 ] && [ "$shown" -ge "$LIMIT" ]; then break; fi
    printf '  %-12s %s %s\n' "$verdict" "$commit" "$summary"
    shown=$((shown + 1))
  done <<< "$DETAIL"
  if [ "$LIMIT" -ne 0 ] && [ "$TOTAL" -gt "$LIMIT" ]; then
    printf '  ... showing %s of %s; every change is listed in the report, and the counts above are of all %s\n' \
      "$LIMIT" "$TOTAL" "$TOTAL"
  fi
}

{
  printf 'upstream distance, read %s\n' "$NOW"
  printf '  compared: fork %s (from %s) at %.12s\n' "$FORK_URL" "$FORK_SOURCE" "$FORK"
  printf '            against upstream %s (from %s) at %.12s\n' "$UPSTREAM_URL" "$UPSTREAM_SOURCE" "$UPSTREAM"
  printf '            common history ends at %.12s\n' "$MERGE_BASE"
  printf '  %s upstream-only changes this fork does not carry; %s local patches; %s upstream merge commits not measured\n' \
    "$TOTAL" "$FORK_ONLY" "$MERGES"
  printf '  verdicts over all %s: %s absorbed, %s converged, %s superseded, %s needs-review\n' \
    "$TOTAL" "$n_absorbed" "$n_converged" "$n_superseded" "$n_needs_review"
  [ "$n_converged" -eq 0 ] ||
    printf '  note: converged means the two default branches hold identical content for every path a change touches - evidence, not proof that this change is what put it there, so confirm at content level before dropping one.\n'
  [ "$TOTAL" -eq 0 ] || print_detail
}

if [ "$WRITE" = 1 ]; then
  outdir=$(dirname "$OUT")
  mkdir -p "$outdir" 2>/dev/null ||
    unmeasurable "the report directory $outdir cannot be created"
  # shellcheck disable=SC2016  # the backticks below are markdown code spans in
  # the written report, not command substitutions.
  {
    printf '# Upstream distance\n\n'
    printf 'Read %s by `bin/fm-upstream-distance.sh`, on demand.\n' "$NOW"
    printf 'This file is a reading, not a queue: it is overwritten by the next reading and nothing reports it on its own.\n'
    printf 'The verdict vocabulary and the evidence each verdict rests on are owned by that script'"'"'s header.\n\n'
    printf '## What was compared\n\n'
    printf -- '- Fork side: `%s`, from %s, at `%s`.\n' "$FORK_URL" "$FORK_SOURCE" "$FORK"
    printf -- '- Upstream side: `%s`, from %s, at `%s`.\n' "$UPSTREAM_URL" "$UPSTREAM_SOURCE" "$UPSTREAM"
    printf -- '- Common history ends at `%s`.\n\n' "$MERGE_BASE"
    printf '## Counts\n\n'
    printf 'Counted over the whole range, never over the terminal window.\n\n'
    printf '| Reading | Count |\n| --- | --- |\n'
    printf '| Upstream-only changes this fork does not carry | %s |\n' "$TOTAL"
    printf '| Local patches upstream does not carry | %s |\n' "$FORK_ONLY"
    printf '| Upstream merge commits, not measured | %s |\n' "$MERGES"
    printf '| absorbed | %s |\n' "$n_absorbed"
    printf '| converged | %s |\n' "$n_converged"
    printf '| superseded | %s |\n' "$n_superseded"
    printf '| needs-review | %s |\n\n' "$n_needs_review"
    printf '## Every upstream-only change\n\n'
    if [ "$TOTAL" -eq 0 ]; then
      printf 'None.\n'
    else
      printf '| Verdict | Change | Summary | On what evidence |\n| --- | --- | --- | --- |\n'
      while IFS="$FS" read -r verdict commit summary why; do
        [ -n "$verdict" ] || continue
        # A commit subject may hold a pipe, which would otherwise open a column
        # this table does not have and shift every later cell one to the left.
        printf '| %s | `%s` | %s | %s |\n' "$verdict" "$commit" "${summary//|/\\|}" "$why"
      done <<< "$DETAIL"
    fi
  # Deliberately NOT silenced: a write that fails for a reason nobody sees is
  # how the report once lost three lines to a printf reading a leading dash as
  # an option while the reading around it still looked complete.
  } > "$OUT" || unmeasurable "the report cannot be written to $OUT"
  printf '  report: %s\n' "$OUT"
fi

[ "$OUTSTANDING" -eq 0 ] || exit 1
exit 0
