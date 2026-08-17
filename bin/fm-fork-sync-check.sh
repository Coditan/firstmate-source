#!/usr/bin/env bash
# Detect whether the curated fork lacks upstream content and bound both sides
# of the commit review with mechanical absorption hints.
#
# This script never changes the checkout or merges history. It fetches into a
# temporary bare repository and writes only FM_HOME/state/fork-sync.*. The daily
# currency round invokes it on a curator home; fork-sync.last-run gates completed
# checks to one every three days.
#
# State contract:
#   fork-sync.last-run  epoch of the last completed comparison
#   fork-sync.pending   FORK_SYNC diagnostic and commit review lists
#   fork-sync.stuck     FORK_SYNC_STUCK diagnostic for an incomplete check
#
# BOTH SIDES OF THE COMPARISON ARE RESOLVED EXPLICITLY, and the resolved URLs are
# named in every diagnostic this script writes. The upstream side comes from
# FM_FIRSTMATE_UPSTREAM_URL, then config/fork-sync-upstream, then the canonical
# default; the fork side from FM_FIRSTMATE_FORK_URL, then config/fork-sync-fork,
# then a "fork" remote, then origin. See bin/fm-currency-base-lib.sh for the full
# precedence of each and for why these bases are separate from
# config/firstmate-update-base. A present but unusable config file records
# FORK_SYNC_STUCK rather than silently comparing against the wrong repository.
#
# The fork side used to be taken from origin alone, which is the fork only in the
# plain topology. A curator vessel deployed from a fleet repository has origin
# pointing at that fleet repository, so the check compared upstream against it
# and reported ITS commits as fork-only patches - a confident reading of the
# wrong repository. The URLs are printed for the same reason: a comparison that
# does not say what it compared cannot be caught reading the wrong thing.
#
# Usage: fm-fork-sync-check.sh
# Environment:
#   FM_FIRSTMATE_UPSTREAM_URL overrides the configured upstream URL.
#   FM_FIRSTMATE_FORK_URL overrides the fork URL.
#   FM_FORK_SYNC_COMPARE_REPO uses an existing repository (tests only).
#   FM_FORK_SYNC_UPSTREAM_HEAD and FM_FORK_SYNC_FORK_HEAD name commits already
#     present in that repository (tests only).
#   FM_FORK_SYNC_NOW overrides the current epoch (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PENDING="$STATE/fork-sync.pending"
STUCK="$STATE/fork-sync.stuck"
LAST_RUN="$STATE/fork-sync.last-run"
INTERVAL=$((3 * 24 * 60 * 60))
NOW=${FM_FORK_SYNC_NOW:-$(date +%s)}

mkdir -p "$STATE" 2>/dev/null || {
  echo "FORK_SYNC_STUCK: cannot create state directory $STATE"
  exit 0
}

record_stuck() {
  printf 'FORK_SYNC_STUCK: %s\n' "$1" > "$STUCK"
  cat "$STUCK"
  exit 0
}

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

bounded() {
  case $HAVE_TIMEOUT in
    timeout) timeout "${FM_CHECK_TIMEOUT:-30}" "$@" ;;
    gtimeout) gtimeout "${FM_CHECK_TIMEOUT:-30}" "$@" ;;
    *) "$@" ;;
  esac
}

github_repo_slug() {
  local url=$1 rest authority host path
  GITHUB_REPO_SLUG=""
  case $url in
    https://*|http://*)
      rest=${url#*://}
      authority=${rest%%/*}
      path=${rest#*/}
      host=${authority#*@}
      host=${host%%:*}
      ;;
    ssh://*|git+ssh://*)
      rest=${url#*://}
      authority=${rest%%/*}
      path=${rest#*/}
      host=${authority#*@}
      host=${host%%:*}
      ;;
    *:*)
      authority=${url%%:*}
      path=${url#*:}
      host=${authority#*@}
      ;;
    *) return 1 ;;
  esac
  [ "$host" = github.com ] || return 1
  path=${path%/}
  path=${path%.git}
  case $path in ''|/*|*/*/*|*'/../'*|../*|*/..) return 1 ;; esac
  case $path in *[!A-Za-z0-9_.\/-]*) return 1 ;; esac
  GITHUB_REPO_SLUG=$path
}

repository_identity() {
  local side=$1 url=$2 path=$2 repo_slug result id name
  REPOSITORY_IDENTITY=""
  REPOSITORY_NAME=""
  REPOSITORY_IDENTITY_REASON=""
  case $url in
    file://*) path=${url#file://} ;;
    *://*|*:*)
      github_repo_slug "$url" || {
        REPOSITORY_IDENTITY_REASON="$side URL is not a supported GitHub or local repository address"
        return 1
      }
      repo_slug=$GITHUB_REPO_SLUG
      command -v gh-axi >/dev/null 2>&1 || {
        REPOSITORY_IDENTITY_REASON="gh-axi is unavailable for the $side GitHub repository"
        return 1
      }
      result=$(bounded gh-axi api "repos/$repo_slug" --jq '.id, .full_name' 2>&1) || {
        REPOSITORY_IDENTITY_REASON="$side GitHub repository lookup failed: $result"
        return 1
      }
      id=$(printf '%s\n' "$result" | sed -n '1p')
      name=$(printf '%s\n' "$result" | sed -n '2p')
      case $id in *[!0-9]*|'') REPOSITORY_IDENTITY_REASON="$side GitHub repository lookup returned no numeric id"; return 1 ;; esac
      [ -n "$name" ] || {
        REPOSITORY_IDENTITY_REASON="$side GitHub repository lookup returned no full name"
        return 1
      }
      REPOSITORY_IDENTITY="github:$id"
      REPOSITORY_NAME=$name
      return 0
      ;;
  esac
  path=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || {
    REPOSITORY_IDENTITY_REASON="$side local path is not a git repository"
    return 1
  }
  path=$(realpath "$path" 2>/dev/null) || {
    REPOSITORY_IDENTITY_REASON="$side git directory cannot be canonicalized"
    return 1
  }
  REPOSITORY_IDENTITY="local:$path"
  REPOSITORY_NAME=$path
}

# shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-currency-base-lib.sh"
fm_currency_base_resolve "$CONFIG" "$FM_CURRENCY_BASE_FORK_ITEM" ||
  record_stuck "config/$FM_CURRENCY_BASE_FORK_ITEM is unusable - $FM_CURRENCY_BASE_REASON"
UPSTREAM_URL=$FM_CURRENCY_BASE_VALUE
upstream_source=$FM_CURRENCY_BASE_SOURCE

case $NOW in *[!0-9]*|'') record_stuck "current epoch is invalid" ;; esac
if [ -f "$LAST_RUN" ]; then
  last=$(cat "$LAST_RUN" 2>/dev/null || true)
  case $last in
    *[!0-9]*|'') ;;
    *) [ $((NOW - last)) -ge "$INTERVAL" ] || exit 0 ;;
  esac
fi

tmp=""
compare_repo=${FM_FORK_SYNC_COMPARE_REPO:-}
if [ -z "$compare_repo" ]; then
  fm_currency_base_fork_repo "$CONFIG" "$FM_ROOT" || record_stuck "$FM_CURRENCY_BASE_REASON"
  fork_url=$FM_CURRENCY_BASE_VALUE
  fork_source=$FM_CURRENCY_BASE_SOURCE
  repository_identity fork "$fork_url" || record_stuck "$REPOSITORY_IDENTITY_REASON ($fork_url, from $fork_source)"
  fork_identity=$REPOSITORY_IDENTITY
  fork_name=$REPOSITORY_NAME
  repository_identity upstream "$UPSTREAM_URL" || record_stuck "$REPOSITORY_IDENTITY_REASON ($UPSTREAM_URL, from $upstream_source)"
  upstream_identity=$REPOSITORY_IDENTITY
  upstream_name=$REPOSITORY_NAME
  [ "$fork_identity" != "$upstream_identity" ] ||
    record_stuck "fork $fork_name (from $fork_source) and upstream $upstream_name (from $upstream_source) are the same repository (identity $fork_identity)"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-sync.XXXXXX") || record_stuck "temporary comparison repository cannot be created"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init --bare -q || record_stuck "temporary comparison repository cannot be initialized"
  git -C "$tmp" fetch -q --no-tags "$fork_url" HEAD:refs/heads/fork || record_stuck "fork default-branch lookup failed ($fork_url, from $fork_source)"
  git -C "$tmp" fetch -q --no-tags "$UPSTREAM_URL" HEAD:refs/heads/upstream || record_stuck "upstream default-branch lookup failed ($UPSTREAM_URL, from $upstream_source)"
  compare_repo=$tmp
  fork=$(git -C "$tmp" rev-parse --verify refs/heads/fork)
  upstream=$(git -C "$tmp" rev-parse --verify refs/heads/upstream)
else
  fork_url=$compare_repo
  fork_source="FM_FORK_SYNC_COMPARE_REPO"
  fork=${FM_FORK_SYNC_FORK_HEAD:-}
  upstream=${FM_FORK_SYNC_UPSTREAM_HEAD:-}
  [ -n "$fork" ] && [ -n "$upstream" ] || record_stuck "test comparison repository requires fork and upstream heads"
fi

git -C "$compare_repo" cat-file -e "$fork^{commit}" 2>/dev/null || record_stuck "fork comparison commit is unavailable"
git -C "$compare_repo" cat-file -e "$upstream^{commit}" 2>/dev/null || record_stuck "upstream comparison commit is unavailable"

if git -C "$compare_repo" merge-base --is-ancestor "$upstream" "$fork" 2>/dev/null; then
  rm -f "$PENDING" "$STUCK"
  printf '%s\n' "$NOW" > "$LAST_RUN"
  exit 0
fi
git -C "$compare_repo" merge-base "$fork" "$upstream" >/dev/null 2>&1 || record_stuck "fork and upstream histories have no merge base"

upstream_list=$(git -C "$compare_repo" rev-list --oneline --no-merges "$fork..$upstream") || record_stuck "upstream-only commit list cannot be computed"
upstream_merge_list=$(git -C "$compare_repo" rev-list --oneline --merges "$fork..$upstream") || record_stuck "upstream merge commit list cannot be computed"
fork_list=$(git -C "$compare_repo" rev-list --oneline --no-merges "$upstream..$fork") || record_stuck "fork-only commit list cannot be computed"
upstream_cherry=$(git -C "$compare_repo" cherry "$fork" "$upstream") || record_stuck "upstream patch equivalence cannot be computed"
cherry=$(git -C "$compare_repo" cherry "$upstream" "$fork") || record_stuck "patch equivalence cannot be computed"
fork_count=$(printf '%s\n' "$fork_list" | awk 'NF { count++ } END { print count+0 }')
upstream_count=0
absorbed_count=0
upstream_review_detail=""
review_detail=""

while IFS=' ' read -r commit summary; do
  [ -n "$commit" ] || continue
  verdict=needs-review
  if printf '%s\n' "$upstream_cherry" | grep -q "^- $commit"; then
    verdict=absorbed
  else
    mapfile -t files < <(git -C "$compare_repo" diff-tree --no-commit-id --name-only -r "$commit")
    if [ "${#files[@]}" -gt 0 ] && git -C "$compare_repo" diff --quiet "$fork" "$upstream" -- "${files[@]}"; then
      verdict=absorbed
    fi
  fi
  [ "$verdict" = absorbed ] || upstream_count=$((upstream_count + 1))
  upstream_review_detail="${upstream_review_detail}  $verdict $commit $summary
"
done <<EOF
$upstream_list
EOF

merge_authored_files() {
  local merge=$1 reconstructed parents
  mapfile -t parents < <(git -C "$compare_repo" rev-parse "$merge^@" 2>/dev/null)
  if [ "${#parents[@]}" -eq 2 ]; then
    reconstructed=$(git -C "$compare_repo" merge-tree --write-tree "${parents[0]}" "${parents[1]}" 2>/dev/null)
    reconstructed=${reconstructed%%$'\n'*}
    if [ -n "$reconstructed" ] && git -C "$compare_repo" rev-parse --verify -q "$reconstructed^{tree}" >/dev/null 2>&1; then
      git -C "$compare_repo" diff --name-only "$reconstructed" "$merge^{tree}"
      return 0
    fi
  fi
  git -C "$compare_repo" diff-tree -c --no-commit-id --name-only -r "$merge"
}

while IFS=' ' read -r commit summary; do
  [ -n "$commit" ] || continue
  mapfile -t files < <(merge_authored_files "$commit")
  [ "${#files[@]}" -gt 0 ] || continue
  git -C "$compare_repo" diff --quiet "$fork" "$upstream" -- "${files[@]}" && continue
  upstream_count=$((upstream_count + 1))
  upstream_review_detail="${upstream_review_detail}  needs-review $commit $summary
"
done <<EOF
$upstream_merge_list
EOF

if [ "$upstream_count" -eq 0 ]; then
  rm -f "$PENDING" "$STUCK"
  printf '%s\n' "$NOW" > "$LAST_RUN"
  exit 0
fi

while IFS=' ' read -r commit summary; do
  [ -n "$commit" ] || continue
  verdict=needs-review
  if printf '%s\n' "$cherry" | grep -q "^- $commit"; then
    verdict=absorbed
  else
    mapfile -t files < <(git -C "$compare_repo" diff-tree --no-commit-id --name-only -r "$commit")
    if [ "${#files[@]}" -gt 0 ] && git -C "$compare_repo" diff --quiet "$upstream" "$fork" -- "${files[@]}"; then
      verdict=absorbed
    fi
  fi
  [ "$verdict" != absorbed ] || absorbed_count=$((absorbed_count + 1))
  review_detail="${review_detail}  $verdict $commit $summary
"
done <<EOF
$fork_list
EOF

{
  printf 'FORK_SYNC: upstream %.7s not merged into fork (%s upstream-only commits); %s local patches to re-evaluate (%s provably absorbed): dispatch a fork-sync crewmate\n' "$upstream" "$upstream_count" "$fork_count" "$absorbed_count"
  # Which two repositories produced these numbers. Without this line a reading of
  # the wrong repository is indistinguishable from a reading of the right one,
  # which is how a fleet repository's own commits were once listed below as
  # fork-only patches.
  printf '  compared: fork %s (from %s) against upstream %s (from %s)\n' "$fork_url" "$fork_source" "$UPSTREAM_URL" "$upstream_source"
  printf '  note: "provably absorbed" counts only patches this check could prove absorbed by patch-id or by tip-content convergence; the remainder are unproven, not proven unabsorbed.\n'
  printf '  upstream-only commits:\n'
  printf '%s' "$upstream_review_detail"
  printf '  fork-only patches:\n'
  printf '%s' "$review_detail"
} > "$PENDING"
printf '%s\n' "$NOW" > "$LAST_RUN"
rm -f "$STUCK"
cat "$PENDING"
