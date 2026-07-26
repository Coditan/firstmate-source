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

commit_lines() {
  local repo=$1 path=$2 message=$3
  shift 3
  printf '%s\n' "$@" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$message"
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
  git -C "$repo" checkout -q -b upstream-side "$base"
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
  pass "a conflict-free upstream merge over absorbed content clears persisted diagnostics"
}

test_same_file_automerge_over_fork_patch_clears_diagnostics() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/upstream-automerge"
  state="$TMP_ROOT/upstream-automerge-state"
  fm_git_init_commit "$repo"
  commit_lines "$repo" shared.txt shared-base l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  commit_lines "$repo" shared.txt fork-head l1-upstream l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 >/dev/null
  commit_lines "$repo" shared.txt fork-tail l1-upstream l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12-upstream >/dev/null
  fork=$(commit_lines "$repo" shared.txt fork-patch l1-upstream l2 l3 l4 l5 l6-fork l7 l8 l9 l10 l11 l12-upstream)
  git -C "$repo" checkout -q -b upstream-line "$base"
  commit_lines "$repo" shared.txt upstream-head l1-upstream l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 >/dev/null
  git -C "$repo" checkout -q -b upstream-side "$base"
  commit_lines "$repo" shared.txt upstream-tail l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12-upstream >/dev/null
  git -C "$repo" checkout -q upstream-line
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    merge -q --no-ff --no-edit -m upstream-automerge upstream-side >/dev/null 2>&1 \
    || fail "fixture same-file automerge did not apply cleanly"
  upstream=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" diff --quiet "$fork" "$upstream" -- shared.txt \
    && fail "fixture did not leave a fork-only patch on the auto-merged path"
  mkdir -p "$state"
  printf 'old\n' > "$state/fork-sync.pending"
  printf 'old\n' > "$state/fork-sync.stuck"

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2920000)
  [ -z "$out" ] || fail "conflict-free same-file automerge emitted a diagnostic: $out"
  [ ! -f "$state/fork-sync.pending" ] || fail "same-file automerge check did not clear pending"
  [ ! -f "$state/fork-sync.stuck" ] || fail "same-file automerge check did not clear stuck"
  [ "$(cat "$state/fork-sync.last-run")" = 2920000 ] || fail "same-file automerge check did not stamp last-run"
  pass "a mechanical same-file automerge over a fork patch is not counted as drift"
}

test_upstream_merge_resolution_content_reports_drift() {
  local repo state base fork upstream out
  repo="$TMP_ROOT/upstream-merge-resolution"
  state="$TMP_ROOT/upstream-merge-resolution-state"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "$repo" alpha.txt alpha-content >/dev/null
  fork=$(commit_file "$repo" beta.txt beta-content)
  git -C "$repo" checkout -q -b upstream-line "$base"
  commit_file "$repo" alpha.txt alpha-content >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --amend -m upstream-alpha
  git -C "$repo" checkout -q -b upstream-side "$base"
  commit_file "$repo" beta.txt beta-content >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --amend -m upstream-beta
  git -C "$repo" checkout -q upstream-line
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    merge -q --no-ff --no-edit -m upstream-merge upstream-side
  printf 'alpha-resolved\n' > "$repo/alpha.txt"
  git -C "$repo" add alpha.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --amend --no-edit
  upstream=$(git -C "$repo" rev-parse HEAD)

  out=$(run_check "$repo" "$state" "$fork" "$upstream" 2950000)
  assert_contains "$out" 'FORK_SYNC:' "merge-only resolution drift was not reported"
  assert_contains "$out" '1 upstream-only commits' "merge-only resolution drift was miscounted"
  assert_contains "$out" "  needs-review ${upstream:0:7} upstream-merge" "unabsorbed merge detail was not persisted"
  [ ! -f "$state/fork-sync.stuck" ] || fail "merge-resolution check recorded a stuck diagnostic"
  pass "content carried only by an upstream merge resolution still reports drift"
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

# Real fetch path (no FM_FORK_SYNC_COMPARE_REPO), so the resolved comparison
# base is actually the repository git reads from. Both sides are local paths, so
# these stay network-free.
run_fetching_check() {
  local repo=$1 state=$2 config=$3 fork_url=$4 now=$5
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" FM_FIRSTMATE_FORK_URL="$fork_url" \
    FM_FORK_SYNC_NOW="$now" \
    "$ROOT/bin/fm-fork-sync-check.sh"
}

# Fork and upstream clones that diverge by one commit on each side.
make_fork_and_upstream() {
  local name=$1 upstream fork
  upstream="$TMP_ROOT/$name-upstream"
  fork="$TMP_ROOT/$name-fork"
  fm_git_init_commit "$upstream"
  git clone -q "$upstream" "$fork"
  commit_file "$fork" fork.txt fork-only >/dev/null
  commit_file "$upstream" upstream.txt upstream-only >/dev/null
}

test_configured_upstream_base_is_the_repository_compared() {
  local repo state config out
  make_fork_and_upstream configured
  repo="$TMP_ROOT/configured-fork"
  state="$TMP_ROOT/configured-state"
  config="$TMP_ROOT/configured-config"
  mkdir -p "$config"
  printf '%s\n' "$TMP_ROOT/configured-upstream" > "$config/fork-sync-upstream"

  out=$(run_fetching_check "$repo" "$state" "$config" "$repo" 4000000)
  assert_contains "$out" 'FORK_SYNC:' "the configured upstream base was not compared against"
  assert_contains "$out" '1 upstream-only commits' "the configured upstream base produced the wrong comparison"
  [ ! -f "$state/fork-sync.stuck" ] || fail "a usable configured base recorded a stuck diagnostic"
  pass "a configured fork-sync upstream base is the repository actually compared"
}

test_environment_override_beats_the_configured_base() {
  local repo state config out
  make_fork_and_upstream envwins
  repo="$TMP_ROOT/envwins-fork"
  state="$TMP_ROOT/envwins-state"
  config="$TMP_ROOT/envwins-config"
  mkdir -p "$config"
  printf '%s\n' "$TMP_ROOT/envwins-absent-upstream" > "$config/fork-sync-upstream"

  out=$(FM_FIRSTMATE_UPSTREAM_URL="$TMP_ROOT/envwins-upstream" \
    run_fetching_check "$repo" "$state" "$config" "$repo" 4100000)
  assert_contains "$out" 'FORK_SYNC:' "the environment override was not used as the comparison base"
  assert_not_contains "$out" 'FORK_SYNC_STUCK:' "the environment override did not beat the configured base"
  pass "an explicit environment base outranks the configured fork-sync base"
}

test_unusable_configured_base_refuses_loudly() {
  local repo state config out
  repo="$TMP_ROOT/badconfig"
  state="$TMP_ROOT/badconfig-state"
  config="$TMP_ROOT/badconfig-config"
  fm_git_init_commit "$repo"
  mkdir -p "$config"
  printf 'not a url\n' > "$config/fork-sync-upstream"

  out=$(run_fetching_check "$repo" "$state" "$config" "$repo" 4200000)
  assert_contains "$out" 'FORK_SYNC_STUCK: config/fork-sync-upstream is unusable' \
    "an unusable configured base did not refuse loudly"
  assert_grep 'is unusable' "$state/fork-sync.stuck" "the refusal was not persisted"
  [ ! -f "$state/fork-sync.last-run" ] || fail "a refused check stamped a completed run"
  pass "an unusable configured fork-sync base refuses instead of comparing against the default"
}

test_pending_lists_and_cadence_gate
test_content_convergence_prefilters_absorbed_patch
test_content_convergence_clears_absorbed_upstream_commit
test_mixed_upstream_commits_report_corrected_count
test_absorbed_upstream_merge_commit_clears_diagnostics
test_same_file_automerge_over_fork_patch_clears_diagnostics
test_upstream_merge_resolution_content_reports_drift
test_up_to_date_clears_diagnostics
test_configured_upstream_base_is_the_repository_compared
test_environment_override_beats_the_configured_base
test_unusable_configured_base_refuses_loudly
