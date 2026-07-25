#!/usr/bin/env bash
# Network-free behavior tests for curated-fork synchronization detection.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-fork-sync-check-tests

commit_file() {
  local repo=$1 path=$2 content=$3
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$content"
  git -C "$repo" rev-parse HEAD
}

run_check() {
  local repo=$1 state=$2 fork=$3 upstream=$4 now=$5
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_FORK_SYNC_COMPARE_REPO="$repo" FM_FORK_SYNC_FORK_HEAD="$fork" \
    FM_FORK_SYNC_UPSTREAM_HEAD="$upstream" FM_FORK_SYNC_NOW="$now" \
    "$ROOT/bin/fm-fork-sync-check.sh"
}

test_pending_lists_and_cadence_gate() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/pending"
  state="$TMP_ROOT/pending-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" fork.txt fork-only)
  git -C "$repo" reset -q --hard "$base"
  upstream=$(commit_file "$repo" upstream.txt upstream-only)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 1000000)
  assert_contains "$out" 'FORK_SYNC:' "divergence was not reported"
  assert_contains "$out" '1 upstream-only commits' "upstream count was wrong"
  assert_contains "$out" '1 local patches to re-evaluate (0 provably absorbed)' "fork review count was wrong"
  assert_grep '  needs-review ' "$state/fork-sync.pending" "fork patch was not classified"
  [ "$(cat "$state/fork-sync.last-run")" = 1000000 ] || fail "completed check did not stamp last-run"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 1000001)
  [ -z "$out" ] || fail "three-day cadence gate emitted output: $out"
  pass "divergence is persisted with bounded review detail and gated for three days"
}

test_content_convergence_prefilters_absorbed_patch() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/absorbed"
  state="$TMP_ROOT/absorbed-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" reset -q --hard "$base"
  upstream=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -m upstream-summary
  upstream=$(commit_file "$repo" upstream.txt upstream-only)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2000000)
  assert_contains "$out" '1 provably absorbed' "content-converged patch was not prefiltered"
  assert_grep '  absorbed ' "$state/fork-sync.pending" "absorbed detail was not persisted"
  pass "tip content convergence mechanically prefilters an absorbed fork patch"
}

test_content_convergence_clears_absorbed_upstream_commit() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/upstream-absorbed"
  state="$TMP_ROOT/upstream-absorbed-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" reset -q --hard "$base"
  upstream=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -m upstream-summary
  upstream=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$state"
  printf 'old\n' > "$state/fork-sync.pending"
  printf 'old\n' > "$state/fork-sync.stuck"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2500000)
  [ -z "$out" ] || fail "absorbed upstream commit emitted a diagnostic: $out"
  [ ! -f "$state/fork-sync.pending" ] || fail "absorbed upstream check did not clear pending"
  [ ! -f "$state/fork-sync.stuck" ] || fail "absorbed upstream check did not clear stuck"
  [ "$(cat "$state/fork-sync.last-run")" = 2500000 ] || fail "absorbed upstream check did not stamp last-run"
  pass "content-equivalent upstream history clears persisted diagnostics"
}

test_mixed_upstream_commits_report_corrected_count() {
  local repo state base fork upstream absorbed_upstream out
  repo="$TMP_ROOT/upstream-mixed"
  state="$TMP_ROOT/upstream-mixed-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  fork=$(commit_file "$repo" shared.txt shared-content)
  git -C "$repo" reset -q --hard "$base"
  commit_file "$repo" shared.txt shared-content >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -m upstream-summary
  absorbed_upstream=$(git -C "$repo" rev-parse HEAD)
  upstream=$(commit_file "$repo" new.txt genuinely-new)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2750000)
  assert_contains "$out" 'FORK_SYNC:' "mixed upstream divergence was not reported"
  assert_contains "$out" '1 upstream-only commits' "absorbed upstream commit was included in the count"
  assert_contains "$out" "  absorbed ${absorbed_upstream:0:7} upstream-summary" "absorbed upstream detail was not persisted"
  assert_contains "$out" "  needs-review ${upstream:0:7} genuinely-new" "new upstream detail was not persisted"
  pass "mixed upstream history reports only genuinely new commits"
}

test_absorbed_upstream_merge_commit_clears_diagnostics() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/upstream-merge"
  state="$TMP_ROOT/upstream-merge-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "$repo" alpha.txt alpha-content >/dev/null
  fork=$(commit_file "$repo" beta.txt beta-content)
  git -C "$repo" checkout -q -b upstream-line "$base"
  commit_file "$repo" alpha.txt alpha-content >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --amend -m upstream-alpha
  git -C "$repo" checkout -q -b upstream-side
  commit_file "$repo" beta.txt beta-content >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --amend -m upstream-beta
  git -C "$repo" checkout -q upstream-line
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    merge -q --no-ff --no-edit -m upstream-merge upstream-side
  upstream=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$state"
  printf 'old\n' > "$state/fork-sync.pending"
  printf 'old\n' > "$state/fork-sync.stuck"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2900000)
  [ -z "$out" ] || fail "absorbed upstream merge commit emitted a diagnostic: $out"
  [ ! -f "$state/fork-sync.pending" ] || fail "absorbed upstream merge check did not clear pending"
  [ ! -f "$state/fork-sync.stuck" ] || fail "absorbed upstream merge check did not clear stuck"
  [ "$(cat "$state/fork-sync.last-run")" = 2900000 ] || fail "absorbed upstream merge check did not stamp last-run"
  pass "an upstream merge over absorbed content clears persisted diagnostics"
}

test_up_to_date_clears_diagnostics() {
  local repo state upstream fork out
  repo="$TMP_ROOT/current"
  state="$TMP_ROOT/current-state"
  fm_git_init_commit "$repo"
  upstream=$(commit_file "$repo" upstream.txt upstream)
  fork=$(commit_file "$repo" fork.txt fork)
  mkdir -p "$state"
  printf 'old\n' > "$state/fork-sync.pending"
  printf 'old\n' > "$state/fork-sync.stuck"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 3000000)
  [ -z "$out" ] || fail "up-to-date fork emitted a diagnostic: $out"
  [ ! -f "$state/fork-sync.pending" ] || fail "up-to-date check did not clear pending"
  [ ! -f "$state/fork-sync.stuck" ] || fail "up-to-date check did not clear stuck"
  pass "a fork containing upstream clears persisted diagnostics"
}

test_pending_lists_and_cadence_gate
test_content_convergence_prefilters_absorbed_patch
test_content_convergence_clears_absorbed_upstream_commit
test_mixed_upstream_commits_report_corrected_count
test_absorbed_upstream_merge_commit_clears_diagnostics
test_up_to_date_clears_diagnostics
