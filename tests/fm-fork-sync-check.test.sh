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

# The same real fetch path, but with the fork side left to the script's own
# resolution instead of handed in. These are the tests that can see WHICH
# repository the fork side actually resolved to.
run_resolving_check() {
  local repo=$1 state=$2 config=$3 now=$4
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" FM_FORK_SYNC_NOW="$now" \
    "$ROOT/bin/fm-fork-sync-check.sh"
}

# A curator seat as this fleet actually deploys one: upstream, the curated fork
# that tracks it, a fleet repository carrying the fork plus its own commits, and
# a vessel checkout whose ORIGIN is that fleet repository rather than the fork.
# Reading the fork side from origin here is exactly the defect - the fleet
# repository's own commits get reported as fork-only patches.
make_curator_seat() {
  local name=$1 upstream fork fleet seat config
  upstream="$TMP_ROOT/$name-upstream"
  fork="$TMP_ROOT/$name-fork"
  fleet="$TMP_ROOT/$name-fleet"
  seat="$TMP_ROOT/$name-seat"
  config="$TMP_ROOT/$name-config"
  fm_git_init_commit "$upstream"
  git clone -q "$upstream" "$fork"
  commit_file "$fork" fork.txt fork-only-patch >/dev/null
  commit_file "$upstream" upstream.txt upstream-only >/dev/null
  git clone -q "$fork" "$fleet"
  commit_file "$fleet" fleet.txt fleet-only-patch >/dev/null
  git clone -q "$fleet" "$seat"
  mkdir -p "$config"
  printf '%s\n' "$upstream" > "$config/fork-sync-upstream"
}

test_configured_fork_side_beats_this_homes_origin() {
  local seat state config out
  make_curator_seat curator
  seat="$TMP_ROOT/curator-seat"
  state="$TMP_ROOT/curator-state"
  config="$TMP_ROOT/curator-config"
  printf '%s\n' "$TMP_ROOT/curator-fork" > "$config/fork-sync-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5000000)
  assert_contains "$out" 'FORK_SYNC:' "the configured fork side was not compared at all"
  assert_contains "$out" "  compared: fork $TMP_ROOT/curator-fork (from config/fork-sync-fork)" \
    "the finding must name which repository it measured as the fork"
  assert_contains "$out" '  needs-review ' "the fork patch list was not produced"
  assert_contains "$out" 'fork-only-patch' "the configured fork's own patch was not listed"
  assert_not_contains "$out" 'fleet-only-patch' \
    "a commit that exists only in this home's origin was listed as a fork-only patch"
  pass "the configured fork side is measured instead of this home's origin"
}

test_fork_remote_outranks_origin_when_nothing_is_configured() {
  local seat state config out
  make_curator_seat remote
  seat="$TMP_ROOT/remote-seat"
  state="$TMP_ROOT/remote-state"
  config="$TMP_ROOT/remote-config"
  git -C "$seat" remote add fork "$TMP_ROOT/remote-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5100000)
  assert_contains "$out" "  compared: fork $TMP_ROOT/remote-fork (from the fork remote)" \
    "a remote named fork must outrank origin as the fork side"
  assert_not_contains "$out" 'fleet-only-patch' \
    "origin was measured even though this checkout names its fork explicitly"
  pass "a remote named fork is preferred over origin as the fork side"
}

test_origin_remains_the_last_resort_fork_side() {
  local seat state config out
  make_curator_seat plain
  seat="$TMP_ROOT/plain-seat"
  state="$TMP_ROOT/plain-state"
  config="$TMP_ROOT/plain-config"

  out=$(run_resolving_check "$seat" "$state" "$config" 5200000)
  assert_contains "$out" "  compared: fork $TMP_ROOT/plain-fleet (from the origin remote)" \
    "an unconfigured home with no fork remote must still fall back to origin"
  # The defect itself, pinned: with the fork side left to origin on a curator
  # seat, the origin repository's own commit IS reported as a fork-only patch.
  # The two tests above are what stop that happening on a seat that names its
  # fork; this one records what the fallback still does when nothing names it.
  assert_contains "$out" 'fleet-only-patch' \
    "the origin fallback must be visible in the finding, not silent"
  pass "origin remains the last-resort fork side for the plain topology"
}

test_unusable_configured_fork_side_refuses_loudly() {
  local seat state config out
  make_curator_seat badfork
  seat="$TMP_ROOT/badfork-seat"
  state="$TMP_ROOT/badfork-state"
  config="$TMP_ROOT/badfork-config"
  printf 'not a url\n' > "$config/fork-sync-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5300000)
  assert_contains "$out" 'FORK_SYNC_STUCK: config/fork-sync-fork is unusable' \
    "an unusable configured fork side did not refuse loudly"
  assert_grep 'is unusable' "$state/fork-sync.stuck" "the refusal was not persisted"
  [ ! -f "$state/fork-sync.last-run" ] || fail "a refused check stamped a completed run"
  pass "an unusable configured fork side refuses instead of falling back to origin"
}

test_identical_comparison_sides_refuse_instead_of_reporting_absorbed() {
  local seat state config out
  make_curator_seat samesides
  seat="$TMP_ROOT/samesides-seat"
  state="$TMP_ROOT/samesides-state"
  config="$TMP_ROOT/samesides-config"
  printf '%s\n' "$TMP_ROOT/samesides-upstream" > "$config/fork-sync-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5400000)
  assert_contains "$out" 'FORK_SYNC_STUCK:' \
    "comparing a repository with itself must refuse, not report everything absorbed"
  assert_contains "$out" 'are the same repository (identity local:' "the refusal did not name the shared identity"
  [ ! -f "$state/fork-sync.last-run" ] || fail "a refused check stamped a completed run"
  pass "a fork side that resolves to the upstream refuses instead of reporting a quiet all-clear"
}

test_symlinked_local_alias_refuses_as_the_same_repository() {
  local seat state config alias out
  make_curator_seat aliased
  seat="$TMP_ROOT/aliased-seat"
  state="$TMP_ROOT/aliased-state"
  config="$TMP_ROOT/aliased-config"
  alias="$TMP_ROOT/aliased-upstream-link"
  ln -s "$TMP_ROOT/aliased-upstream" "$alias"
  printf '%s\n' "$alias" > "$config/fork-sync-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5500000)
  assert_contains "$out" 'FORK_SYNC_STUCK:' "two local spellings of one repository were compared"
  assert_contains "$out" 'are the same repository (identity local:' "the canonical local identity was not reported"
  pass "symlinked local aliases resolve to one repository identity"
}

test_distinct_local_identities_are_compared() {
  local seat state config out
  make_curator_seat distinct
  seat="$TMP_ROOT/distinct-seat"
  state="$TMP_ROOT/distinct-state"
  config="$TMP_ROOT/distinct-config"
  printf '%s\n' "$TMP_ROOT/distinct-fork" > "$config/fork-sync-fork"

  out=$(run_resolving_check "$seat" "$state" "$config" 5600000)
  assert_contains "$out" 'FORK_SYNC:' "two different repository identities did not proceed to comparison"
  assert_not_contains "$out" 'FORK_SYNC_STUCK:' "two different repository identities were refused"
  pass "different local repository identities proceed to comparison"
}

test_unestablishable_identity_refuses_before_comparison() {
  local seat state config out
  make_curator_seat unknown
  seat="$TMP_ROOT/unknown-seat"
  state="$TMP_ROOT/unknown-state"
  config="$TMP_ROOT/unknown-config"

  out=$(FM_FIRSTMATE_FORK_URL='https://example.invalid/owner/repo.git' run_resolving_check "$seat" "$state" "$config" 5700000)
  assert_contains "$out" 'FORK_SYNC_STUCK:' "an unestablishable identity did not refuse"
  assert_contains "$out" 'not a supported GitHub or local repository address' "the refusal did not explain the identity failure"
  [ ! -f "$state/fork-sync.last-run" ] || fail "an identity refusal stamped a completed comparison"
  pass "an unestablishable repository identity refuses before comparison"
}

# Both GitHub tools, each behaving the way the real one does. This fixture is
# the regression itself: gh returns the raw value, gh-axi wraps every answer in
# its own envelope, and identity resolution only succeeds if the check reads the
# raw-producing tool. The earlier fixture stubbed gh-axi with raw output, so it
# agreed with the parser no matter which tool was called - CI stayed green while
# the check refused on the first real repository it met.
make_github_identity_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/bin/sh
[ -z "${FM_TEST_EXPECT_API:-}" ] || [ "$2" = "$FM_TEST_EXPECT_API" ] || exit 1
printf '12345\nowner/repo\n'
SH
  # Verbatim gh-axi shape, including under --jq: the value is inside the
  # envelope, so its FIRST line is never the value a raw parser wants.
  cat > "$fakebin/gh-axi" <<'SH'
#!/bin/sh
printf 'api_response:\n  body: "12345\\nowner/repo"\n  truncated: false\n'
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
}

run_github_alias_check() {
  local fork_url=$1 upstream_url=$2 state=$3 fakebin=$4
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT" FM_HOME="$TMP_ROOT" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    FM_FIRSTMATE_FORK_URL="$fork_url" FM_FIRSTMATE_UPSTREAM_URL="$upstream_url" \
    FM_FORK_SYNC_NOW=5800000 "$ROOT/bin/fm-fork-sync-check.sh"
}

test_github_ssh_forms_share_numeric_identity() {
  local fakebin state url out
  fakebin="$TMP_ROOT/github-ssh-fakebin"
  make_github_identity_fakebin "$fakebin"
  for url in \
    'ssh://github.com/owner/repo.git' \
    'ssh://git@github.com:22/owner/repo.git' \
    'git+ssh://github.com/owner/repo.git' \
    'git+ssh://git@github.com:22/owner/repo.git' \
    'git@github.com:owner/repo.git'; do
    state="$TMP_ROOT/github-ssh-$(printf '%s' "$url" | tr '/:@+' '_____')"
    out=$(run_github_alias_check "$url" 'https://github.com/owner/repo.git' "$state" "$fakebin")
    assert_contains "$out" 'are the same repository (identity github:12345)' \
      "supported GitHub SSH URL did not resolve through forge identity: $url"
  done
  pass "GitHub SSH URL forms resolve by host to one numeric identity"
}

test_github_host_is_case_insensitive_without_changing_repo_path() {
  local fakebin state out
  fakebin="$TMP_ROOT/github-case-fakebin"
  state="$TMP_ROOT/github-case-state"
  make_github_identity_fakebin "$fakebin"

  out=$(FM_TEST_EXPECT_API='repos/Owner/Repo' run_github_alias_check \
    'ssh://git@GitHub.com/Owner/Repo.git' \
    'https://GITHUB.COM/Owner/Repo.git' "$state" "$fakebin")
  assert_contains "$out" 'are the same repository (identity github:12345)' \
    "mixed-case GitHub hosts did not resolve while preserving repository path case"
  pass "GitHub host matching is case-insensitive without changing repository path case"
}

# The other half of the same defect: if a wrapper-producing command is ever
# wired into the identity lookup again, its envelope must be REFUSED rather than
# misread. "api_response:" is not a numeric id, and accepting it would hand the
# comparison an identity that no repository ever produced.
test_wrapped_api_output_is_never_read_as_an_identity() {
  local fakebin state out
  fakebin="$TMP_ROOT/github-wrapped-fakebin"
  state="$TMP_ROOT/github-wrapped-state"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/bin/sh
printf 'api_response:\n  body: "12345\\nowner/repo"\n  truncated: false\n'
SH
  chmod +x "$fakebin/gh"

  out=$(run_github_alias_check 'https://github.com/owner/repo.git' \
    'https://github.com/owner/other.git' "$state" "$fakebin")
  assert_contains "$out" 'FORK_SYNC_STUCK:' "a wrapped API answer did not refuse"
  assert_contains "$out" 'returned no numeric id' \
    "the refusal did not name the unusable identity answer"
  assert_not_contains "$out" 'are the same repository' \
    "an envelope line was accepted as a repository identity"
  [ ! -f "$state/fork-sync.last-run" ] || fail "a refused identity stamped a completed comparison"
  pass "a wrapped API answer refuses instead of being read as an identity"
}

make_identity_minimal_path() {
  local fakebin=$1 tool source
  make_github_identity_fakebin "$fakebin"
  for tool in bash dirname mkdir cat sed tr; do
    source=$(command -v "$tool")
    ln -s "$source" "$fakebin/$tool"
  done
}

test_github_identity_runs_without_timeout_binary() {
  local fakebin state out
  fakebin="$TMP_ROOT/no-timeout-fakebin"
  state="$TMP_ROOT/no-timeout-state"
  make_identity_minimal_path "$fakebin"

  out=$(PATH="$fakebin" FM_ROOT_OVERRIDE="$TMP_ROOT" FM_HOME="$TMP_ROOT" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    FM_FIRSTMATE_FORK_URL='ssh://github.com/owner/repo.git' \
    FM_FIRSTMATE_UPSTREAM_URL='https://github.com/owner/repo.git' \
    FM_FORK_SYNC_NOW=5900000 "$ROOT/bin/fm-fork-sync-check.sh")
  assert_contains "$out" 'are the same repository (identity github:12345)' \
    "a home without timeout or gtimeout did not establish GitHub identity"
  pass "GitHub identity lookup runs unbounded when no timeout binary exists"
}

test_github_identity_uses_gtimeout_fallback() {
  local fakebin state log out
  fakebin="$TMP_ROOT/gtimeout-fakebin"
  state="$TMP_ROOT/gtimeout-state"
  log="$TMP_ROOT/gtimeout.log"
  make_identity_minimal_path "$fakebin"
  cat > "$fakebin/gtimeout" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$FM_TEST_GTIMEOUT_LOG"
shift
exec "$@"
SH
  chmod +x "$fakebin/gtimeout"

  out=$(PATH="$fakebin" FM_TEST_GTIMEOUT_LOG="$log" FM_CHECK_TIMEOUT=17 \
    FM_ROOT_OVERRIDE="$TMP_ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    FM_FIRSTMATE_FORK_URL='git+ssh://git@github.com:22/owner/repo.git' \
    FM_FIRSTMATE_UPSTREAM_URL='https://github.com/owner/repo.git' \
    FM_FORK_SYNC_NOW=6000000 "$ROOT/bin/fm-fork-sync-check.sh")
  assert_contains "$out" 'are the same repository (identity github:12345)' \
    "the gtimeout fallback did not preserve identity lookup"
  [ "$(wc -l < "$log")" -eq 2 ] || fail "gtimeout did not bound both forge lookups"
  assert_grep '17' "$log" "gtimeout did not receive the configured bound"
  pass "GitHub identity lookup uses gtimeout when GNU timeout is absent"
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
test_configured_fork_side_beats_this_homes_origin
test_fork_remote_outranks_origin_when_nothing_is_configured
test_origin_remains_the_last_resort_fork_side
test_unusable_configured_fork_side_refuses_loudly
test_identical_comparison_sides_refuse_instead_of_reporting_absorbed
test_symlinked_local_alias_refuses_as_the_same_repository
test_distinct_local_identities_are_compared
test_unestablishable_identity_refuses_before_comparison
test_github_ssh_forms_share_numeric_identity
test_github_host_is_case_insensitive_without_changing_repo_path
test_wrapped_api_output_is_never_read_as_an_identity
test_github_identity_runs_without_timeout_binary
test_github_identity_uses_gtimeout_fallback
