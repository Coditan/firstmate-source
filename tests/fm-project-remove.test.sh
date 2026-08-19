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

fake_gh_axi_human_pr_view() {
  local fakebin=$1 number=$2 state=$3
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "pr view $number" ]; then
  cat <<'EOF'
pull_request:
  number: $number
  state: $state
EOF
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi"
}

fake_gh_with_pr_state_and_commit() {
  local fakebin=$1 number=$2 state=$3 head=$4 repo=$5 commit=$6
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "pr view $number" ]; then
  printf '%s\t%s\n' '$state' '$head'
  exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "repos/$repo/commits/$commit" ]; then
  printf '%s\n' '$commit'
  exit 0
fi
printf 'unexpected gh call: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$fakebin/gh"
}

# A `git` shim that records every invocation before handing off to the real git,
# so a test can assert HOW MANY times the default history was enumerated rather
# than timing it.
fake_git_call_logger() {
  local fakebin=$1 log=$2 real_git
  real_git=$(command -v git) || fail "no git on PATH to wrap"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"
}

# An `awk` shim that signals the removal helper the instant it reaches the
# registry rewrite - the one command between moving the clone aside and putting
# the registry back in agreement with it. Keyed on the rewrite program's own
# text so the earlier registry-count and backlog awk calls run untouched, which
# makes the interrupt land inside that window deterministically instead of by
# timing.
fake_awk_signals_registry_rewrite() {
  local fakebin=$1 signal=$2 real_awk
  real_awk=$(command -v awk) || fail "no awk on PATH to wrap"
  cat > "$fakebin/awk" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'!(\$1=="-"'*) kill -$signal "\$PPID" 2>/dev/null ;;
  esac
done
exec "$real_awk" "\$@"
SH
  chmod +x "$fakebin/awk"
}

fake_tasks_axi_listing() {
  local fakebin=$1 body=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\$1" = "list" ] && [ "\$2" = "--file" ]; then
cat <<'EOF'
$body
EOF
  exit 0
fi
printf 'unexpected tasks-axi call: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
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

test_pr_named_branch_passes_when_human_gh_axi_and_github_has_tip() {
  local home repo fakebin tip rc=0
  home=$(make_home pr-human-view)
  repo="$home/projects/alpha"
  git -C "$repo" remote set-url origin git@github.com:owner/alpha.git
  fakebin=$(fm_fakebin "$home")
  commit_branch "$repo" pr123 pr123.txt preserved-remotely
  tip=$(git -C "$repo" rev-parse pr123)
  fake_gh_axi_human_pr_view "$fakebin" 123 merged
  fake_gh_with_pr_state_and_commit "$fakebin" 123 MERGED unrelated owner/alpha "$tip"
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "human gh-axi PR view"
  assert_grep "merged PR 123 records this branch tip" "$home/out" \
    "human gh-axi PR proof did not fall back to exact GitHub commit preservation"
  [ -d "$home/projects/alpha" ] || fail "human-gh-axi dry-run removed the clone"
  pass "project removal accepts PR-named branches proved by supported gh output and exact remote commit preservation"
}

test_pr_named_squash_equivalent_branch_passes_by_content() {
  local home repo squash_commit rc=0
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
  squash_commit=$(git -C "$repo" rev-parse --short HEAD)
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "pr squash equivalent"
  assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
    "squash-equivalent branch did not pass by landed content"
  assert_grep "landed as $squash_commit" "$home/out" \
    "squash-equivalent branch did not name the default-history landed-as commit"
  [ -d "$home/projects/alpha" ] || fail "squash-equivalent dry-run removed the clone"
  pass "project removal accepts PR-named branches whose content landed by squash"
}

test_patch_equivalent_branch_names_landed_as_commit() {
  local home repo landed_commit rc=0
  home=$(make_home patch-equivalent-audit)
  repo="$home/projects/alpha"
  git -C "$repo" switch -q -c feature/replayed
  printf 'replayed\n' > "$repo/replayed.txt"
  git -C "$repo" add replayed.txt
  git -C "$repo" commit -qm "add replayed content"
  git -C "$repo" switch -q main
  printf 'replayed\n' > "$repo/replayed.txt"
  git -C "$repo" add replayed.txt
  git -C "$repo" commit -qm "land replayed content independently"
  landed_commit=$(git -C "$repo" rev-parse --short HEAD)
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "patch equivalent audit"
  assert_grep "landed as $landed_commit" "$home/out" \
    "patch-equivalent branch did not name the default-history landed-as commit"
  [ -d "$home/projects/alpha" ] || fail "patch-equivalent dry-run removed the clone"
  pass "project removal names the default-history commit for patch-equivalent work"
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
  local home fakebin rc=0
  home=$(make_home backlog-reference)
  fakebin=$(fm_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha-live - active work (repo: alpha) (kind: ship)

## Queued

## Done
EOF
  fake_tasks_axi_listing "$fakebin" 'count: 1
tasks[1]{id,state,kind,repo,title}:
  alpha-live,in_flight,ship,alpha,active work'
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "backlog reference"
  assert_grep "alpha-live" "$home/err" \
    "backlog refusal did not name the conflicting work"
  [ -d "$home/projects/alpha" ] || fail "backlog-reference refusal removed the clone"
  pass "project removal refuses in-flight or queued backlog work naming the project"
}

test_backlog_reference_with_repo_metadata_refuses() {
  local home fakebin rc=0
  home=$(make_home backlog-reference-metadata)
  fakebin=$(fm_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha-live - active work (repo: alpha, since 2026-08-17) (kind: ship)

## Queued
- [ ] beta-live - unrelated work (repo: beta, since 2026-08-17) (kind: ship)

## Done
EOF
  fake_tasks_axi_listing "$fakebin" 'count: 2
tasks[2]{id,state,kind,repo,title}:
  alpha-live,in_flight,ship,"alpha, since 2026-08-17",active work
  beta-live,queued,ship,"beta, since 2026-08-17",unrelated work'
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "backlog reference metadata"
  assert_grep "alpha-live" "$home/err" \
    "backlog metadata refusal did not name the conflicting work"
  assert_no_grep "beta-live" "$home/err" \
    "backlog metadata refusal matched an unrelated repo"
  [ -d "$home/projects/alpha" ] || fail "backlog-reference-metadata refusal removed the clone"
  pass "project removal refuses backlog repo metadata that names the project"
}

test_backlog_reference_uses_tasks_axi_for_bold_rows() {
  local home fakebin rc=0
  home=$(make_home backlog-reference-bold)
  fakebin=$(fm_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- **bold-task** - active work (repo: alpha, since 2026-08-17) (kind: ship)

## Queued

## Done
EOF
  fake_tasks_axi_listing "$fakebin" 'count: 1
tasks[1]{id,state,kind,repo,title}:
  bold-task,in_flight,ship,"alpha, since 2026-08-17",active work'
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "backlog reference bold"
  assert_grep "bold-task" "$home/err" \
    "tasks-axi-backed backlog refusal did not name the bold-row work"
  [ -d "$home/projects/alpha" ] || fail "backlog-reference-bold refusal removed the clone"
  pass "project removal asks tasks-axi for active backlog rows"
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

# --- work-bearing refs beyond refs/heads -------------------------------------
#
# Only refs/heads used to be enumerated, so each fixture below passed with PASS
# and would have been deleted. They are one bug with one fix, so they are kept
# together: any of them passing again means the enumeration narrowed.

test_stashed_work_refuses() {
  local home repo rc=0
  home=$(make_home stashed-work)
  repo="$home/projects/alpha"
  printf 'stashed\n' > "$repo/stashed.txt"
  git -C "$repo" add stashed.txt
  git -C "$repo" stash push -q -m wip
  [ -n "$(git -C "$repo" stash list)" ] || fail "stash fixture did not create a stash entry"
  [ -z "$(git -C "$repo" status --porcelain)" ] \
    || fail "stash fixture left the working tree dirty, so it would not test the stash"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "stashed work"
  assert_grep "stashed change stash@{0} has no preservation" "$home/err" \
    "stashed work was not reported as unproved"
  assert_no_grep "PASS:" "$home/out" "a clone holding a stash still printed a pass verdict"
  [ -d "$home/projects/alpha" ] || fail "stashed-work refusal removed the clone"
  pass "project removal refuses a clone whose only unlanded work is stashed"
}

test_older_stash_entry_refuses() {
  local home repo rc=0
  home=$(make_home older-stash-entry)
  repo="$home/projects/alpha"
  printf 'older\n' > "$repo/older.txt"
  git -C "$repo" add older.txt
  git -C "$repo" stash push -q -m older
  printf 'newer\n' > "$repo/newer.txt"
  git -C "$repo" add newer.txt
  git -C "$repo" stash push -q -m newer
  [ "$(git -C "$repo" stash list | wc -l)" -eq 2 ] \
    || fail "older-stash fixture did not create two stash entries"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "older stash entry"
  assert_grep "stashed change stash@{1} has no preservation" "$home/err" \
    "the older stash entry, which refs/stash does not point at, was not inspected"
  [ -d "$home/projects/alpha" ] || fail "older-stash refusal removed the clone"
  pass "project removal inspects every stash entry, not only the one refs/stash names"
}

test_reflogless_stash_ref_refuses() {
  local home repo rc=0
  home=$(make_home reflogless-stash)
  repo="$home/projects/alpha"
  printf 'stashed\n' > "$repo/stashed.txt"
  git -C "$repo" add stashed.txt
  git -C "$repo" stash push -q -m wip
  rm -f "$repo/.git/logs/refs/stash"
  git -C "$repo" rev-parse --verify --quiet refs/stash >/dev/null \
    || fail "reflogless-stash fixture lost refs/stash itself"
  [ -z "$(git -C "$repo" stash list)" ] \
    || fail "reflogless-stash fixture still lists stashes, so it would not test the reflog-less tip"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "reflogless stash ref"
  assert_grep "stashed change refs/stash has no preservation" "$home/err" \
    "a refs/stash with no reflog behind it was enumerated nowhere"
  [ -d "$home/projects/alpha" ] || fail "reflogless-stash refusal removed the clone"
  pass "project removal inspects a refs/stash tip even when its reflog is gone"
}

test_detached_head_commit_refuses() {
  local home repo tip rc=0
  home=$(make_home detached-head-commit)
  repo="$home/projects/alpha"
  git -C "$repo" checkout -q --detach main
  printf 'detached\n' > "$repo/detached.txt"
  git -C "$repo" add detached.txt
  git -C "$repo" commit -qm "detached commit"
  tip=$(git -C "$repo" rev-parse --short HEAD)
  [ -z "$(git -C "$repo" for-each-ref --contains HEAD --format='%(refname)' refs/heads)" ] \
    || fail "detached fixture left the commit on a branch, so refs/heads would already see it"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "detached head commit"
  assert_grep "detached HEAD HEAD has no preservation" "$home/err" \
    "a commit no branch points at was not reported as unproved"
  assert_grep "$tip" "$home/err" "the refusal did not name the commit that would be lost"
  [ -d "$home/projects/alpha" ] || fail "detached-head refusal removed the clone"
  pass "project removal refuses a detached-HEAD commit no branch points at"
}

test_local_only_tag_refuses() {
  local home repo rc=0
  home=$(make_home local-only-tag)
  repo="$home/projects/alpha"
  git -C "$repo" checkout -q --detach main
  printf 'tagged\n' > "$repo/tagged.txt"
  git -C "$repo" add tagged.txt
  git -C "$repo" commit -qm "tagged commit"
  git -C "$repo" tag keepsake
  git -C "$repo" checkout -q main
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "local only tag"
  assert_grep "local tag keepsake has no preservation" "$home/err" \
    "a local-only tag holding the only copy of a commit was not reported as unproved"
  [ -d "$home/projects/alpha" ] || fail "local-only-tag refusal removed the clone"
  pass "project removal refuses commits held only by a local-only tag"
}

test_paused_rebase_replay_refuses() {
  local home repo rc=0
  home=$(make_home paused-rebase)
  repo="$home/projects/alpha"
  git -C "$repo" switch -q -c feature/rebasing
  printf 'first\n' > "$repo/first.txt"
  git -C "$repo" add first.txt
  git -C "$repo" commit -qm "first replayed commit"
  printf 'second\n' > "$repo/second.txt"
  git -C "$repo" add second.txt
  git -C "$repo" commit -qm "second replayed commit"
  git -C "$repo" push -q origin feature/rebasing
  git -C "$repo" switch -q main
  printf 'moved on\n' > "$repo/moved.txt"
  git -C "$repo" add moved.txt
  git -C "$repo" commit -qm "main moved on"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  GIT_SEQUENCE_EDITOR='sed -i 2i\break' git -C "$repo" rebase -i main feature/rebasing >/dev/null 2>&1
  [ -d "$repo/.git/rebase-merge" ] || {
    pass "SKIP: this git could not park a rebase at a break, so the paused-rebase case is untested here"
    return 0
  }
  [ -z "$(git -C "$repo" status --porcelain)" ] \
    || fail "paused-rebase fixture left the tree dirty, so the dirty check would refuse first"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "paused rebase"
  assert_grep "detached HEAD HEAD has no preservation" "$home/err" \
    "a rebase's already-replayed commits were not reported as unproved"
  [ -d "$home/projects/alpha" ] || fail "paused-rebase refusal removed the clone"
  pass "project removal refuses a clone parked mid-rebase over its replayed commits"
}

test_prunable_worktree_head_refuses() {
  local home repo wt lost rc=0
  home=$(make_home prunable-worktree-head)
  repo="$home/projects/alpha"
  wt="$home/.treehouse/alpha-test/1/alpha"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q --detach "$wt" main
  printf 'wip\n' > "$wt/wip.txt"
  git -C "$wt" add wip.txt
  git -C "$wt" commit -qm "worktree wip"
  lost=$(git -C "$wt" rev-parse --short HEAD)
  rm -rf "$wt"
  git -C "$repo" worktree list --porcelain | grep -q '^prunable' \
    || fail "prunable fixture did not leave a prunable worktree entry"
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "prunable worktree head"
  assert_grep "worktree HEAD $wt has no preservation" "$home/err" \
    "a pruned worktree's recorded HEAD was accepted without inspecting its commits"
  assert_grep "$lost" "$home/err" "the refusal did not name the commit the pruned worktree still holds"
  assert_no_grep "PASS:" "$home/out" "a pruned worktree holding an unpushed commit still printed a pass verdict"
  [ -d "$home/projects/alpha" ] || fail "prunable-worktree refusal removed the clone"
  pass "project removal proves a prunable worktree entry's commits instead of treating the entry as proof"
}

test_remote_tags_do_not_block_removal() {
  local home repo rc=0
  home=$(make_home remote-tags)
  repo="$home/projects/alpha"
  printf 'second\n' > "$repo/second.txt"
  git -C "$repo" add second.txt
  git -C "$repo" commit -qm "second landed commit"
  git -C "$repo" push -q origin main
  git -C "$repo" tag v1.0 main
  git -C "$repo" tag -a v1.1 -m "annotated release" main~
  git -C "$repo" push -q origin v1.0 v1.1
  git -C "$repo" fetch -q origin --tags
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "remote tags"
  assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
    "widening the enumeration to tags refuses ordinary clones whose tags sit on the default branch"
  assert_grep "local tag v1.1: remote-tracking ref contains" "$home/out" \
    "the annotated tag was not peeled to its commit and proved"
  assert_no_grep "local tag v1.1 has no preservation" "$home/err" \
    "the annotated tag object was treated as unproved instead of being peeled to its commit"
  pass "project removal still passes a clone whose tags, annotated included, sit on preserved history"
}

test_prefetch_refs_do_not_block_removal() {
  local home repo ahead rc=0
  home=$(make_home prefetch-refs)
  repo="$home/projects/alpha"
  printf 'prefetched\n' > "$repo/prefetched.txt"
  git -C "$repo" add prefetched.txt
  git -C "$repo" commit -qm "commit only the prefetch ref has seen"
  ahead=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/prefetch/origin/main "$ahead"
  git -C "$repo" reset -q --hard origin/main
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "prefetch refs"
  assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
    "a git-maintenance prefetch ref, which only ever holds remote content, refused the removal"
  pass "project removal ignores git-maintenance prefetch refs, which carry no local work"
}

# --- remote refresh ----------------------------------------------------------

test_unreachable_remote_still_removes() {
  local home rc=0
  home=$(make_home unreachable-remote-removes)
  rm -rf "$home/origin.git"
  run_remove "$home" alpha --captain-approved > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "unreachable remote removal"
  [ ! -e "$home/projects/alpha" ] || fail "removal with an unreachable remote left the clone on disk"
  assert_no_grep "- alpha " "$home/data/projects.md" \
    "removal with an unreachable remote did not remove the registry entry"
  assert_grep "could not refresh remotes" "$home/err" \
    "removal with an unreachable remote did not say the proofs rest on unrefreshed state"
  pass "project removal still removes a clone whose remote no longer answers"
}

test_unreachable_remote_still_refuses_unlanded_work() {
  local home repo rc=0
  home=$(make_home unreachable-remote-refuses)
  repo="$home/projects/alpha"
  commit_branch "$repo" feature/not-landed feature.txt feature
  rm -rf "$home/origin.git"
  run_remove "$home" alpha --captain-approved > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "unreachable remote with unlanded work"
  assert_grep "local branch feature/not-landed has no preservation" "$home/err" \
    "an unreachable remote refused on the fetch instead of on the unlanded work"
  [ -d "$home/projects/alpha" ] || fail "unreachable-remote refusal removed the clone"
  pass "project removal with an unreachable remote refuses on the landed-work evidence, not on the fetch"
}

test_refused_run_does_not_prune_remote_tracking_refs() {
  local home repo rc=0
  home=$(make_home refused-run-no-prune)
  repo="$home/projects/alpha"
  commit_branch "$repo" feature/short-lived short.txt short
  git -C "$repo" push -q origin feature/short-lived
  git -C "$repo" fetch -q origin
  git -C "$repo" branch -q -D feature/short-lived
  git -C "$home/origin.git" branch -q -D feature/short-lived
  git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/feature/short-lived >/dev/null \
    || fail "fixture did not leave a remote-tracking ref for a branch the remote no longer has"
  printf '%s\n' '- alpha [direct-PR] - duplicate fixture (added 2026-08-17)' \
    >> "$home/data/projects.md"
  run_remove "$home" alpha --captain-approved > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "refused run must not prune"
  assert_grep "expected exactly one data/projects.md entry" "$home/err" \
    "the refused run did not refuse on the registry"
  git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/feature/short-lived >/dev/null \
    || fail "a run refused by a read-only check still pruned the clone's remote-tracking refs"
  pass "project removal runs its read-only checks before touching the clone's remote-tracking refs"
}

# --- landed-content proof cost ------------------------------------------------

test_landed_content_naming_scans_default_history_once() {
  local home repo fakebin call_log scans rc=0
  home=$(make_home landed-naming-once)
  repo="$home/projects/alpha"
  fakebin=$(fm_fakebin "$home")
  call_log="$home/git-calls.log"
  : > "$call_log"
  git -C "$repo" switch -q -c feature/replayed-one
  printf 'one\n' > "$repo/one.txt"
  git -C "$repo" add one.txt
  git -C "$repo" commit -qm "replay one"
  git -C "$repo" switch -q main
  git -C "$repo" switch -q -c feature/replayed-two
  printf 'two\n' > "$repo/two.txt"
  git -C "$repo" add two.txt
  git -C "$repo" commit -qm "replay two"
  git -C "$repo" switch -q main
  printf 'one\n' > "$repo/one.txt"
  printf 'two\n' > "$repo/two.txt"
  git -C "$repo" add one.txt
  git -C "$repo" commit -qm "land one independently"
  git -C "$repo" add two.txt
  git -C "$repo" commit -qm "land two independently"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  fake_git_call_logger "$fakebin" "$call_log"
  PATH="$fakebin:$PATH" \
    run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 0 "$rc" "landed naming scan count"
  scans=$(grep -c -E ' log .* origin/main$' "$call_log" || true)
  [ "$scans" -le 1 ] \
    || fail "naming landed content walked the whole default history $scans times; it must be indexed once per run"
  assert_grep "landed as " "$home/out" "the landed-content proofs stopped naming the commit that landed them"
  pass "project removal indexes the default history once per run instead of rescanning it per commit"
}

# --- refusal evidence ---------------------------------------------------------

test_refusal_evidence_excludes_default_branch_commits() {
  local home repo i rc=0
  home=$(make_home refusal-evidence)
  repo="$home/projects/alpha"
  git -C "$repo" remote remove origin
  for i in 1 2 3 4 5; do
    printf 'landed %s\n' "$i" > "$repo/landed$i.txt"
    git -C "$repo" add "landed$i.txt"
    git -C "$repo" commit -qm "landed commit $i"
  done
  commit_branch "$repo" feature/unlanded unlanded.txt unlanded
  run_remove "$home" alpha --captain-approved --dry-run > "$home/out" 2> "$home/err" || rc=$?
  expect_code 1 "$rc" "refusal evidence"
  assert_grep "add unlanded.txt" "$home/err" \
    "the refusal evidence did not list the one commit actually at risk"
  assert_no_grep "landed commit 5" "$home/err" \
    "the refusal evidence listed the default branch's own landed commits and overstated the risk"
  [ -d "$home/projects/alpha" ] || fail "refusal-evidence refusal removed the clone"
  pass "project removal's refusal evidence excludes the default branch instead of listing it as at risk"
}

# --- interrupted removal window -----------------------------------------------

test_interrupted_removal_restores_clone_and_registry() {
  local home repo fakebin leftovers rc=0
  home=$(make_home interrupted-removal)
  repo="$home/projects/alpha"
  fakebin=$(fm_fakebin "$home")
  fake_awk_signals_registry_rewrite "$fakebin" TERM
  PATH="$fakebin:$PATH" run_remove "$home" alpha --captain-approved > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" != 0 ] || fail "an interrupted removal reported success"
  [ -d "$repo" ] \
    || fail "a removal interrupted between moving the clone and rewriting the registry did not restore the clone"
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 \
    || fail "the restored clone is not an inspectable git worktree"
  assert_grep "- alpha " "$home/data/projects.md" \
    "an interrupted removal left the registry disagreeing with the restored clone"
  leftovers=$(find "$home/projects" -maxdepth 1 -name '.fm-removing-*' 2>/dev/null | wc -l)
  [ "$leftovers" -eq 0 ] \
    || fail "an interrupted removal left the clone at a hidden removal path"
  pass "an interrupted removal restores the clone and its registry entry instead of hiding the clone"
}

# --- documented invocations ---------------------------------------------------

test_documented_dry_run_invocation_is_accepted() {
  local skill invocation args_text home rc found=0 index=0
  local -a args
  skill="$ROOT/.agents/skills/project-management/SKILL.md"
  [ -f "$skill" ] || fail "the project-management skill is no longer at $skill"
  while IFS= read -r invocation; do
    [ -n "$invocation" ] || continue
    found=1
    index=$((index + 1))
    args_text=${invocation#bin/fm-project-remove.sh }
    args_text=${args_text//<project-name>/alpha}
    read -r -a args <<< "$args_text"
    home=$(make_home "documented-invocation-$index")
    rc=0
    run_remove "$home" "${args[@]}" > "$home/out" 2> "$home/err" \
      || rc=$?
    [ "$rc" = 0 ] \
      || fail "documented invocation refused: $invocation"
    case " ${args[*]} " in
      *" --dry-run "*)
        assert_grep "PASS: project alpha removal safety checks passed." "$home/out" \
          "documented dry-run invocation did not produce a verdict: $invocation"
        [ -d "$home/projects/alpha" ] \
          || fail "documented dry-run invocation removed the clone: $invocation"
        assert_grep "- alpha " "$home/data/projects.md" \
          "documented dry-run invocation removed the registry entry: $invocation"
        ;;
      *)
        [ ! -d "$home/projects/alpha" ] \
          || fail "documented removal invocation left the clone in place: $invocation"
        assert_no_grep "- alpha " "$home/data/projects.md" \
          "documented removal invocation left the registry entry in place: $invocation"
        ;;
    esac
  done < <(awk 'match($0, /`bin\/fm-project-remove\.sh [^`]+`/) { print substr($0, RSTART + 1, RLENGTH - 2) }' "$skill")
  [ "$found" = 1 ] || fail "project-management skill documents no fm-project-remove.sh invocation"
  pass "documented project-removal invocations are accepted by the helper"
}

test_requires_captain_approval
test_dirty_primary_refuses
test_unlanded_branch_refuses
test_pr_named_branch_refuses_unrelated_merged_pr
test_pr_named_branch_passes_when_human_gh_axi_and_github_has_tip
test_pr_named_squash_equivalent_branch_passes_by_content
test_patch_equivalent_branch_names_landed_as_commit
test_treehouse_worktree_refuses_unpreserved_head
test_treehouse_worktree_refuses_preserved_head
test_treehouse_worktree_refuses_dirty_preserved_head
test_claude_worktree_refuses_dirty_slot
test_unregistered_claude_worktree_content_refuses_as_primary_dirty
test_secondmate_clone_refuses
test_backlog_reference_refuses
test_backlog_reference_with_repo_metadata_refuses
test_backlog_reference_uses_tasks_axi_for_bold_rows
test_registry_must_have_one_entry
test_pass_removes_clone_and_registry_entry_together
test_dry_run_pass_keeps_clone_and_registry
test_stashed_work_refuses
test_older_stash_entry_refuses
test_reflogless_stash_ref_refuses
test_detached_head_commit_refuses
test_local_only_tag_refuses
test_paused_rebase_replay_refuses
test_prunable_worktree_head_refuses
test_remote_tags_do_not_block_removal
test_prefetch_refs_do_not_block_removal
test_unreachable_remote_still_removes
test_unreachable_remote_still_refuses_unlanded_work
test_refused_run_does_not_prune_remote_tracking_refs
test_landed_content_naming_scans_default_history_once
test_refusal_evidence_excludes_default_branch_commits
test_interrupted_removal_restores_clone_and_registry
test_documented_dry_run_invocation_is_accepted
