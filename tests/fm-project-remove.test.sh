#!/usr/bin/env bash
# Tests for bin/fm-project-remove.sh's guarded project-clone removal path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REMOVE="$ROOT/bin/fm-project-remove.sh"
fm_test_tmproot TMP_ROOT fm-project-remove-tests

make_home() {
  local name=$1 home seed
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  git init -q --bare "$home/origin.git"
  git -C "$home/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$home/origin.git" "$home/seed"
  printf 'base\n' > "$home/seed/README.md"
  git -C "$home/seed" add README.md
  git -C "$home/seed" commit -qm "initial"
  git -C "$home/seed" push -q origin main
  rm -rf "$home/seed"
  git clone -q "$home/origin.git" "$home/projects/alpha"
  git -C "$home/projects/alpha" remote set-head origin main
  printf '%s\n' '- alpha [direct-PR] - alpha fixture (added 2026-08-17)' > "$home/data/projects.md"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  seed="$home/projects/alpha"
  git -C "$seed" fetch -q origin
  printf '%s\n' "$home"
}

run_remove() {
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$REMOVE" "$@"
}

commit_branch() {
  local repo=$1 branch=$2 file=$3 content=$4
  git -C "$repo" switch -q -c "$branch"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -qm "add $file"
  git -C "$repo" switch -q main
}

fake_gh_axi_with_pr_head() {
  local fakebin=$1 number=$2 state=$3 head=$4
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "pr view $number" ]; then
  printf '%s\t%s\n' '$state' '$head'
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi"
}

test_requires_captain_approval() {
  local home rc=0
  home=$(make_home requires-captain-approval)
  run_remove "$home" alpha --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "missing captain approval"
  assert_grep "missing --captain-approved" "$home/err" \
    "project removal did not require explicit captain approval"
  [ -d "$home/projects/alpha" ] || fail "missing-approval refusal removed the clone"
  pass "project removal refuses without explicit captain approval"
}

test_dirty_primary_refuses() {
  local home rc=0
  home=$(make_home dirty-primary)
  printf 'dirty\n' > "$home/projects/alpha/dirty.txt"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "dirty primary"
  assert_grep "has uncommitted changes" "$home/err" \
    "dirty primary refusal did not explain uncommitted changes"
  [ -d "$home/projects/alpha" ] || fail "dirty-primary refusal removed the clone"
  pass "project removal refuses uncommitted changes in the primary clone"
}

test_unlanded_branch_refuses() {
  local home repo rc=0
  home=$(make_home unlanded-branch)
  repo="$home/projects/alpha"
  commit_branch "$repo" feature/not-landed feature.txt feature
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "unlanded branch"
  assert_grep "local branch feature/not-landed has no preservation" "$home/err" \
    "unlanded branch refusal did not name the branch"
  [ -d "$home/projects/alpha" ] || fail "unlanded-branch refusal removed the clone"
  pass "project removal refuses local branches without landed-content or remote preservation proof"
}

test_pr_named_branch_refuses_unrelated_merged_pr() {
  local home repo fakebin unrelated_head rc=0
  home=$(make_home pr-name-only)
  repo="$home/projects/alpha"
  fakebin=$(fm_fakebin "$home")
  unrelated_head=$(git -C "$repo" rev-parse HEAD)
  fake_gh_axi_with_pr_head "$fakebin" 123 MERGED "$unrelated_head"
  commit_branch "$repo" pr123 pr123.txt unlanded
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "pr name only"
  assert_grep "local branch pr123 has no preservation" "$home/err" \
    "PR-name-only refusal did not name the unproved branch"
  [ -d "$home/projects/alpha" ] || fail "pr-name-only refusal removed the clone"
  pass "project removal refuses branches named after unrelated merged PRs"
}

test_pr_named_squash_equivalent_branch_passes_by_content() {
  local home repo rc=0
  home=$(make_home pr-squash-equivalent)
  repo="$home/projects/alpha"
  git -C "$repo" switch -q -c pr33
  printf 'one\n' > "$repo/squashed.txt"
  git -C "$repo" add squashed.txt
  git -C "$repo" commit -qm "add first squash part"
  printf 'two\n' >> "$repo/squashed.txt"
  git -C "$repo" add squashed.txt
  git -C "$repo" commit -qm "add second squash part"
  git -C "$repo" switch -q main
  printf 'one\ntwo\n' > "$repo/squashed.txt"
  git -C "$repo" add squashed.txt
  git -C "$repo" commit -qm "squash pr33 content"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "pr squash equivalent"
  assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
    "squash-equivalent branch did not pass by landed content"
  [ -d "$home/projects/alpha" ] || fail "squash-equivalent dry-run removed the clone"
  pass "project removal accepts PR-named branches whose content landed by squash"
}

test_treehouse_worktree_refuses_unpreserved_head() {
  local home repo wt rc=0
  home=$(make_home treehouse-worktree)
  repo="$home/projects/alpha"
  wt="$home/.treehouse/alpha-test/1/alpha"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q --detach "$wt" main
  printf 'wip\n' > "$wt/wip.txt"
  git -C "$wt" add wip.txt
  git -C "$wt" commit -qm "treehouse wip"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "treehouse worktree"
  assert_grep "attached treehouse worktree" "$home/err" \
    "treehouse worktree refusal did not identify the attached worktree"
  [ -d "$home/projects/alpha" ] || fail "treehouse-worktree refusal removed the clone"
  pass "project removal refuses attached treehouse worktrees with unpreserved work"
}

test_treehouse_worktree_refuses_preserved_head() {
  local home repo wt rc=0
  home=$(make_home treehouse-worktree-preserved)
  repo="$home/projects/alpha"
  wt="$home/.treehouse/alpha-test/1/alpha"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q --detach "$wt" main
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "treehouse worktree preserved"
  assert_grep "attached treehouse worktree" "$home/err" \
    "treehouse preserved-head refusal did not identify the attached worktree"
  assert_grep "detach or prune" "$home/err" \
    "treehouse preserved-head refusal did not require detaching the worktree"
  [ -d "$home/projects/alpha" ] || fail "treehouse-worktree-preserved refusal removed the clone"
  pass "project removal refuses live treehouse worktrees even when HEAD is preserved"
}

test_treehouse_worktree_refuses_dirty_preserved_head() {
  local home repo wt rc=0
  home=$(make_home treehouse-worktree-dirty-preserved)
  repo="$home/projects/alpha"
  wt="$home/.treehouse/alpha-test/1/alpha"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q --detach "$wt" main
  printf 'dirty\n' > "$wt/dirty.txt"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "treehouse worktree dirty preserved"
  assert_grep "attached treehouse worktree" "$home/err" \
    "treehouse dirty refusal did not identify the attached worktree"
  assert_grep "has uncommitted changes" "$home/err" \
    "treehouse dirty refusal did not explain dirty work"
  [ -d "$home/projects/alpha" ] || fail "treehouse-worktree-dirty refusal removed the clone"
  pass "project removal inspects dirty external treehouse worktrees before refusing"
}

test_claude_worktree_refuses_dirty_slot() {
  local home repo wt rc=0
  home=$(make_home claude-worktree-dirty)
  repo="$home/projects/alpha"
  wt="$repo/.claude/worktrees/agent-1"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q --detach "$wt" main
  printf 'dirty\n' > "$wt/dirty.txt"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "claude worktree dirty"
  assert_grep "attached claude worktree" "$home/err" \
    "claude worktree refusal did not identify the attached slot"
  assert_grep "has uncommitted changes" "$home/err" \
    "claude worktree refusal did not explain dirty work"
  [ -d "$home/projects/alpha" ] || fail "claude-worktree refusal removed the clone"
  pass "project removal refuses dirty .claude/worktrees agent slots"
}

test_unregistered_claude_worktree_content_refuses_as_primary_dirty() {
  local home repo rc=0
  home=$(make_home unregistered-claude-worktree-content)
  repo="$home/projects/alpha"
  mkdir -p "$repo/.claude/worktrees/orphan"
  printf 'orphan\n' > "$repo/.claude/worktrees/orphan/note.txt"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "unregistered claude worktree content"
  assert_grep "has uncommitted changes" "$home/err" \
    "unregistered .claude/worktrees content was not treated as dirty primary state"
  [ -d "$home/projects/alpha" ] || fail "unregistered-claude refusal removed the clone"
  pass "project removal refuses unregistered .claude/worktrees contents as dirty"
}

test_secondmate_clone_refuses() {
  local home sub rc=0
  home=$(make_home secondmate-clone)
  sub="$home/secondmate"
  mkdir -p "$sub/projects"
  git clone -q "$home/origin.git" "$sub/projects/alpha"
  printf '%s\n' "- mate - fixture secondmate (home: $sub; scope: fixture; projects: alpha; added 2026-08-17)" \
    > "$home/data/secondmates.md"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "secondmate clone"
  assert_grep "secondmate mate" "$home/err" \
    "secondmate refusal did not name the registered secondmate"
  [ -d "$home/projects/alpha" ] || fail "secondmate-clone refusal removed the clone"
  pass "project removal refuses registered secondmate clones of the same project"
}

test_backlog_reference_refuses() {
  local home rc=0
  home=$(make_home backlog-reference)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha-live - active work (repo: alpha) (kind: ship)

## Queued

## Done
EOF
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "backlog reference"
  assert_grep "alpha-live" "$home/err" \
    "backlog refusal did not name the conflicting work"
  [ -d "$home/projects/alpha" ] || fail "backlog-reference refusal removed the clone"
  pass "project removal refuses in-flight or queued backlog work naming the project"
}

test_backlog_reference_with_repo_metadata_refuses() {
  local home rc=0
  home=$(make_home backlog-reference-metadata)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha-live - active work (repo: alpha, since 2026-08-17) (kind: ship)

## Queued
- [ ] beta-live - unrelated work (repo: beta, since 2026-08-17) (kind: ship)

## Done
EOF
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "backlog reference metadata"
  assert_grep "alpha-live" "$home/err" \
    "backlog metadata refusal did not name the conflicting work"
  assert_no_grep "beta-live" "$home/err" \
    "backlog metadata refusal matched an unrelated repo"
  [ -d "$home/projects/alpha" ] || fail "backlog-reference-metadata refusal removed the clone"
  pass "project removal refuses backlog repo metadata that names the project"
}

test_registry_must_have_one_entry() {
  local home rc=0
  home=$(make_home registry-duplicate)
  printf '%s\n' '- alpha [direct-PR] - duplicate fixture (added 2026-08-17)' \
    >> "$home/data/projects.md"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "registry duplicate"
  assert_grep "expected exactly one data/projects.md entry" "$home/err" \
    "registry refusal did not explain duplicate entry"
  [ -d "$home/projects/alpha" ] || fail "registry-duplicate refusal removed the clone"
  pass "project removal refuses when the registry entry is not exactly one line"
}

test_pass_removes_clone_and_registry_entry_together() {
  local home repo rc=0
  home=$(make_home pass-removal)
  repo="$home/projects/alpha"
  commit_branch "$repo" feature/preserved preserved.txt preserved
  git -C "$repo" push -q origin feature/preserved
  git -C "$repo" fetch -q origin
  run_remove "$home" alpha --captain-approved > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "passing removal"
  [ ! -e "$home/projects/alpha" ] || fail "passing removal left the clone on disk"
  assert_no_grep "- alpha " "$home/data/projects.md" \
    "passing removal did not remove the registry entry"
  assert_grep "removed project alpha" "$home/out" \
    "passing removal did not print the removal outcome"
  pass "project removal removes the clone and registry entry in the same guarded operation"
}

test_dry_run_pass_keeps_clone_and_registry() {
  local home rc=0
  home=$(make_home dry-run-pass)
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "dry-run pass"
  [ -d "$home/projects/alpha" ] || fail "dry-run removed the clone"
  assert_grep "- alpha " "$home/data/projects.md" \
    "dry-run removed the registry entry"
  assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
    "dry-run pass verdict was not printed"
  pass "project removal dry-run prints a pass verdict without removing the clone or registry entry"
}

test_requires_captain_approval
test_dirty_primary_refuses
test_unlanded_branch_refuses
test_pr_named_branch_refuses_unrelated_merged_pr
test_pr_named_squash_equivalent_branch_passes_by_content
test_treehouse_worktree_refuses_unpreserved_head
test_treehouse_worktree_refuses_preserved_head
test_treehouse_worktree_refuses_dirty_preserved_head
test_claude_worktree_refuses_dirty_slot
test_unregistered_claude_worktree_content_refuses_as_primary_dirty
test_secondmate_clone_refuses
test_backlog_reference_refuses
test_backlog_reference_with_repo_metadata_refuses
test_registry_must_have_one_entry
test_pass_removes_clone_and_registry_entry_together
test_dry_run_pass_keeps_clone_and_registry
