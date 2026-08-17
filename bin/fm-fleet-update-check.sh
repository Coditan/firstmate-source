#!/usr/bin/env bash
# Answer "is this vessel running current shared code?" across ALL THREE HOPS.
#
# WHAT THIS IS FOR
# On 2026-08-17 the captain said "update yourself". bin/fm-update.sh ran and
# reported "firstmate: already current". That was true and useless: it answers
# whether this home is level with ITS OWN ORIGIN, and says nothing about whether
# the pin that origin carries is current. Measured at that same moment, the
# vendored pin was 72 commits and 15 merged pull requests behind the pin source,
# carrying four fixes that landed that evening and were not running here.
#
# The class is already on record: pin FIDELITY is checked and pin AGE is not.
# The fleet drift gate proves the tree faithfully matches the pin and has no
# opinion on whether the pin is current, so a vessel days stale passes its own
# currency check with an "ok". This script is the missing reading.
#
# It never updates anything. It measures and reports.
#
# THE THREE HOPS, IN THE VOCABULARY docs/currency-round.md OWNS
#   released    the change is on the default branch of the source this
#               deployment updates from.
#   pinned      the fleet pin names a commit that contains it.
#   installed   this seat's own checkout has advanced to that pin.
# Reported bottom-up as hop 3 (installed), hop 2 (pinned), hop 1 (released), so
# the reading nearest the running code is read first and the hop that produced
# the incident is read last. Each hop is printed separately and they are NEVER
# collapsed into one word.
#
# BEHIND IS NOT THE SAME AS UNMEASURABLE
# A pin the source no longer carries, a fetch that fails, an unreadable lock, or
# an unresolvable branch all report UNMEASURABLE and exit non-zero. None of them
# report CURRENT. An instrument that cannot read must never be relayed as an
# all-clear - that is the whole defect this script exists to remove.
#
# WHY IT ADDRESSES THE PIN SOURCE BY URL AND NEVER BY NAME
# The measurement happens in a throwaway bare repository fetched straight from
# the source_url in this home's own firstmate.lock, the same shape
# bin/fm-firstmate-update-check.sh uses. It deliberately does NOT go looking for
# a local clone of the pin source under projects/ and match it by repository
# name: this fleet has already been bitten by a repository NAME being reclaimed
# and silently addressing a different repository, and a name-matched clone is
# exactly that hazard. Fetching the recorded URL also means the check works on a
# vessel that has no clone of the pin source at all, which is most of them, and
# it never runs a state-changing command under projects/ (AGENTS.md section 1).
#
# COUNTING
# Distances come from git rev-list --count and merged pull requests from a
# grep -c over the full range. Never a head -N: a truncated list is
# indistinguishable from a short one, and this seat has already reported "twelve
# commits, four pull requests" from a head -12 when the real figure was 72
# and 15. The merged-PR figure counts merge commits whose subject begins
# "Merge pull request"; a squash-merged pull request leaves no such commit, so
# that figure is a floor and the commit count is the authority.
#
# Usage:
#   fm-fleet-update-check.sh            print all three hops; exit 0 only when
#                                       every hop is measured and current
#   fm-fleet-update-check.sh --pin-age  print one "<state>|<detail>" line for the
#                                       pin-age reading only (ok, behind,
#                                       unmeasured, or skipped) and always exit
#                                       0. This is the seam bin/fm-currency-round.sh
#                                       consumes; it takes one network call, so
#                                       it stays inside that round's per-step
#                                       ceiling.
#   fm-fleet-update-check.sh --help
#
# Environment:
#   FM_HOME                          the home to measure (default: this code
#                                    root). Every seat measures ITSELF; there is
#                                    deliberately no flag for pointing this at
#                                    another vessel's home.
#   FM_FLEET_UPDATE_TIMEOUT          ceiling in seconds for each network step
#                                    (default 12).
#   FM_FLEET_UPDATE_COMPARE_REPO     a repository already holding the pin source
#                                    history, used instead of fetching (tests).
#   FM_FLEET_UPDATE_SOURCE_REF_NAME  the ref the compare repository holds the
#                                    source head under (tests, default
#                                    refs/heads/source).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
LOCK="$FM_HOME/firstmate.lock"

STEP_TIMEOUT=${FM_FLEET_UPDATE_TIMEOUT:-12}
case "$STEP_TIMEOUT" in ''|*[!0-9]*) STEP_TIMEOUT=12 ;; esac

SOURCE_REF_NAME=${FM_FLEET_UPDATE_SOURCE_REF_NAME:-refs/heads/source}

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=report
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --pin-age) MODE=pin-age ;;
  *)
    printf 'fm-fleet-update-check: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--pin-age|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: %s [--pin-age|--help]\n' "$(basename "$0")" >&2
  exit 2
}

# shellcheck source=bin/fm-primary-scope-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

# Run "$@" under the per-step ceiling. With no timeout binary available the call
# runs unbounded rather than being skipped, so a home without coreutils still
# gets its readings.
bounded() {
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$STEP_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$STEP_TIMEOUT" "$@" ;;
    *) "$@" ;;
  esac
}

# --- hop 3: installed - this home against its own origin --------------------

# Sets HOP3_STATE (level, behind, unmeasurable, not-applicable) and HOP3_DETAIL.
read_own_origin() {
  local branch counts behind ahead
  HOP3_STATE=unmeasurable
  HOP3_DETAIL=''
  if ! git -C "$FM_HOME" rev-parse --git-dir >/dev/null 2>&1; then
    HOP3_DETAIL="$FM_HOME is not a git repository, so there is no origin to be level with"
    return 0
  fi
  # A secondmate home is a linked worktree leased at a detached HEAD and synced
  # from its primary's local commit, with no origin involved. Judging it by the
  # primary's rules would report every such home as permanently unmeasurable.
  if fm_root_is_secondmate_home "$FM_HOME"; then
    HOP3_STATE=not-applicable
    HOP3_DETAIL='this home takes its updates from its primary, not from an origin'
    return 0
  fi
  if ! git -C "$FM_HOME" remote get-url origin >/dev/null 2>&1; then
    HOP3_DETAIL='this home has no origin, so nothing can be delivered to it'
    return 0
  fi
  branch=$(git -C "$FM_HOME" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    HOP3_DETAIL='this home is on a detached HEAD, so it tracks no origin branch'
    return 0
  fi
  # A fetch that fails must never leave a stale remote-tracking ref reading as
  # LEVEL, so the failure ends the reading rather than falling through to it.
  if ! bounded git -C "$FM_HOME" fetch --quiet --no-tags origin 2>/dev/null; then
    HOP3_DETAIL="origin could not be reached, so the local view of origin/$branch may be stale"
    return 0
  fi
  if ! counts=$(git -C "$FM_HOME" rev-list --left-right --count "origin/$branch...HEAD" 2>/dev/null); then
    HOP3_DETAIL="origin/$branch cannot be resolved, so the distance cannot be counted"
    return 0
  fi
  behind=${counts%%	*}
  ahead=${counts##*	}
  if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
    HOP3_STATE=level
    HOP3_DETAIL="branch=$branch"
  else
    HOP3_STATE=behind
    HOP3_DETAIL="BEHIND $behind AHEAD $ahead   branch=$branch"
  fi
}

# --- hop 2 and hop 1: pinned and released -----------------------------------

# The pin as this home records it. Sets PIN, PIN_SOURCE, PIN_REF; returns 1 when
# there is no lock and 2 when there is one that cannot be used.
read_lock() {
  PIN=''
  PIN_SOURCE=''
  PIN_REF=''
  LOCK_PROBLEM=''
  [ -f "$LOCK" ] || return 1
  PIN=$(sed -n 's/^commit=//p' "$LOCK" | head -1)
  PIN_SOURCE=$(sed -n 's/^source_url=//p' "$LOCK" | head -1)
  PIN_REF=$(sed -n 's/^source_ref=//p' "$LOCK" | head -1)
  case "$PIN" in
    *[!0-9a-fA-F]*|'')
      LOCK_PROBLEM="firstmate.lock records no usable commit= pin"
      return 2
      ;;
  esac
  [ "${#PIN}" -eq 40 ] || {
    LOCK_PROBLEM="firstmate.lock records a commit= pin that is not a full 40-character commit"
    return 2
  }
  [ -n "$PIN_SOURCE" ] || {
    LOCK_PROBLEM="firstmate.lock records no source_url=, so the pin cannot be aged against anything"
    return 2
  }
  return 0
}

# Fetch the pin source history into a throwaway bare repository and leave the
# source head at SOURCE_REF_NAME. Sets COMPARE_REPO. Returns 1 with PIN_PROBLEM
# set when the reading cannot be taken.
prepare_compare_repo() {
  local refspec
  PIN_PROBLEM=''
  if [ -n "${FM_FLEET_UPDATE_COMPARE_REPO:-}" ]; then
    COMPARE_REPO=$FM_FLEET_UPDATE_COMPARE_REPO
    return 0
  fi
  COMPARE_REPO=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-update.XXXXXX") || {
    PIN_PROBLEM='a temporary comparison repository could not be created'
    return 1
  }
  COMPARE_TMP=$COMPARE_REPO
  if ! git -C "$COMPARE_REPO" init --bare -q 2>/dev/null; then
    PIN_PROBLEM='a temporary comparison repository could not be initialized'
    return 1
  fi
  if [ -n "$PIN_REF" ]; then refspec="$PIN_REF:$SOURCE_REF_NAME"; else refspec="HEAD:$SOURCE_REF_NAME"; fi
  # tree:0 keeps this to commit objects only - measured at 728K and under a
  # second against the pin source - and a server that refuses the filter falls
  # back to a plain fetch rather than to no reading at all.
  if ! bounded git -C "$COMPARE_REPO" fetch -q --no-tags --filter=tree:0 "$PIN_SOURCE" "$refspec" 2>/dev/null &&
     ! bounded git -C "$COMPARE_REPO" fetch -q --no-tags "$PIN_SOURCE" "$refspec" 2>/dev/null; then
    PIN_PROBLEM="the pin source could not be reached at $PIN_SOURCE (${PIN_REF:-its default branch})"
    return 1
  fi
  return 0
}

# Sets HOP1_STATE (current, behind, off-lineage, unmeasurable) plus HOP1_DETAIL,
# SOURCE_HEAD, BEHIND_COMMITS, BEHIND_PRS, PIN_ONLY.
read_pin_age() {
  HOP1_STATE=unmeasurable
  HOP1_DETAIL=''
  SOURCE_HEAD=''
  BEHIND_COMMITS=0
  BEHIND_PRS=0
  PIN_ONLY=0
  if ! prepare_compare_repo; then
    HOP1_DETAIL=$PIN_PROBLEM
    return 0
  fi
  if ! SOURCE_HEAD=$(git -C "$COMPARE_REPO" rev-parse --short "$SOURCE_REF_NAME" 2>/dev/null); then
    HOP1_DETAIL="the head of ${PIN_REF:-the default branch} on the pin source could not be read"
    return 0
  fi
  if ! git -C "$COMPARE_REPO" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    # A pin the source's own history does not carry is the one case where a
    # confident number would be a lie, so it is named rather than counted.
    HOP1_DETAIL="the pinned commit is not reachable from ${PIN_REF:-the default branch} on the pin source - the pin names a commit that source no longer carries, or its history was rewritten"
    return 0
  fi
  local counts
  if ! counts=$(git -C "$COMPARE_REPO" rev-list --left-right --count "$PIN...$SOURCE_REF_NAME" 2>/dev/null); then
    HOP1_DETAIL='the distance between the pin and the pin source head could not be counted'
    return 0
  fi
  PIN_ONLY=${counts%%	*}
  BEHIND_COMMITS=${counts##*	}
  BEHIND_PRS=$(git -C "$COMPARE_REPO" log --format=%s "$PIN..$SOURCE_REF_NAME" 2>/dev/null |
    grep -c '^Merge pull request' || true)
  case "$BEHIND_PRS" in ''|*[!0-9]*) BEHIND_PRS=0 ;; esac
  if [ "$PIN_ONLY" != 0 ]; then
    HOP1_STATE=off-lineage
    HOP1_DETAIL="the pin carries $PIN_ONLY commit(s) that ${PIN_REF:-the default branch} does not, and is $BEHIND_COMMITS commit(s) behind it"
    return 0
  fi
  if [ "$BEHIND_COMMITS" = 0 ]; then
    HOP1_STATE=current
    HOP1_DETAIL="the pin names the head of ${PIN_REF:-the default branch}"
    return 0
  fi
  HOP1_STATE=behind
  HOP1_DETAIL="$BEHIND_COMMITS commit(s), $BEHIND_PRS merged PR(s)"
}

COMPARE_TMP=''
trap 'if [ -n "$COMPARE_TMP" ]; then rm -rf -- "$COMPARE_TMP"; fi' EXIT

# --- --pin-age: the one line bin/fm-currency-round.sh consumes ---------------

if [ "$MODE" = pin-age ]; then
  read_lock
  case "$?" in
    1)
      printf 'skipped|this home carries no firstmate.lock, so it is not pin-delivered and has no pin to age\n'
      exit 0
      ;;
    2)
      printf 'unmeasured|%s\n' "$LOCK_PROBLEM"
      exit 0
      ;;
  esac
  read_pin_age
  case "$HOP1_STATE" in
    current)
      printf 'ok|the pin %s names the head of %s on %s\n' \
        "${PIN:0:7}" "${PIN_REF:-the default branch}" "$PIN_SOURCE"
      ;;
    behind)
      printf 'behind|the pin %s is %s commit(s) and %s merged PR(s) behind %s on %s (source head %s)\n' \
        "${PIN:0:7}" "$BEHIND_COMMITS" "$BEHIND_PRS" "${PIN_REF:-the default branch}" "$PIN_SOURCE" "$SOURCE_HEAD"
      ;;
    off-lineage)
      printf 'behind|the pin %s is not on the current lineage of %s on %s - %s\n' \
        "${PIN:0:7}" "${PIN_REF:-the default branch}" "$PIN_SOURCE" "$HOP1_DETAIL"
      ;;
    *)
      printf 'unmeasured|%s\n' "$HOP1_DETAIL"
      ;;
  esac
  exit 0
fi

# --- the full three-hop report ----------------------------------------------

rc=0
say() { printf '%s\n' "$*"; }

say "fleet-update-check  home=$FM_HOME"
say ""

read_own_origin
case "$HOP3_STATE" in
  level)          say "hop 3  installed  own origin      LEVEL          $HOP3_DETAIL" ;;
  behind)         say "hop 3  installed  own origin      $HOP3_DETAIL"; rc=1 ;;
  not-applicable) say "hop 3  installed  own origin      NOT APPLICABLE $HOP3_DETAIL" ;;
  *)              say "hop 3  installed  own origin      UNMEASURABLE   $HOP3_DETAIL"; rc=1 ;;
esac

read_lock
lock_status=$?
case "$lock_status" in
  1)
    say "hop 2  pinned     vendored pin    NONE           this home carries no firstmate.lock, so it is not pin-delivered"
    say "hop 1  released   pin age         NOT PIN-DELIVERED  nothing pins this home's shared code, so there is no pin to age"
    ;;
  2)
    say "hop 2  pinned     vendored pin    UNREADABLE     $LOCK_PROBLEM"
    say "hop 1  released   pin age         UNMEASURABLE   the pin cannot be read, so its age cannot be measured"
    rc=1
    ;;
  *)
    say "hop 2  pinned     vendored pin    $PIN"
    say "                  pin source      $PIN_SOURCE ref=${PIN_REF:-<default branch>}"
    read_pin_age
    case "$HOP1_STATE" in
      current)
        say "hop 1  released   pin age         CURRENT        source head=$SOURCE_HEAD"
        ;;
      behind)
        say "hop 1  released   pin age         BEHIND $HOP1_DETAIL   source head=$SOURCE_HEAD"
        rc=1
        ;;
      off-lineage)
        say "hop 1  released   pin age         OFF LINEAGE    $HOP1_DETAIL   source head=$SOURCE_HEAD"
        rc=1
        ;;
      *)
        say "hop 1  released   pin age         UNMEASURABLE   $HOP1_DETAIL"
        rc=1
        ;;
    esac
    ;;
esac

say ""
if [ "$rc" = 0 ]; then
  say "VERDICT: current across every hop measured."
else
  say "VERDICT: NOT current, or not measurable, on at least one hop above."
fi
say "Note: 'level with your own origin' answers hop 3 ONLY. It says nothing about hops 1-2."
say "Note: UNMEASURABLE is not an all-clear. A reading that could not be taken is reported as unmeasurable and never as current."
exit $rc
