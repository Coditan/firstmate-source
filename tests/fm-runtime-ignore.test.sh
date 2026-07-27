#!/usr/bin/env bash
# Regression tests for checkout-local harness artifacts that must never make a
# freshly cloned firstmate home dirty and block its tracked-files fast-forward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-runtime-ignore

runtime_artifacts() {
  cat <<'PATHS'
.claude/settings.local.json
.claude/scheduled_tasks.lock
.claude/scheduled_tasks.json
.claude/routines/.state/runtime.json
.claude/worktrees/runtime
.claude/checkpoints/runtime
.claude/mailbox/runtime
.claude/agent-registry.json
.claude/agent-memory-local
.claude/first-run
.claude/assistant-daemon-state.json
.claude/settings.fm-task.json
PATHS
}

tracked_claude_paths() {
  cat <<'PATHS'
.claude/settings.json
.claude/skills
PATHS
}

# The shared rule has to be the one doing the ignoring: check-ignore succeeds for
# a clone-private .git/info/exclude or a developer's global core.excludesFile
# too, and those are exactly the sources a fresh vessel does not inherit.
assert_ignored_by_tracked_gitignore() {
  local repo=$1 path=$2 match
  match=$(git -C "$repo" check-ignore -v --no-index -- "$path") \
    || fail "runtime artifact has no shared ignore rule: $path"
  case "$match" in
    .gitignore:*) ;;
    *) fail "runtime artifact is ignored by a private or global exclude, not the tracked .gitignore: $match" ;;
  esac
}

test_runtime_artifacts_leave_a_fresh_clone_clean() {
  local seed clone path skills_target status
  seed="$TMP_ROOT/seed"
  clone="$TMP_ROOT/fresh-clone"

  mkdir -p "$seed/.claude" || fail "could not create the seed checkout under $TMP_ROOT"
  cp "$ROOT/.gitignore" "$seed/.gitignore" \
    || fail "could not seed .gitignore: is $ROOT/.gitignore still the tracked ignore file?"
  cp "$ROOT/.claude/settings.json" "$seed/.claude/settings.json" \
    || fail "could not seed .claude/settings.json: has the tracked shared settings file moved?"
  skills_target=$(readlink "$ROOT/.claude/skills") \
    || fail "could not read $ROOT/.claude/skills: has the tracked skills symlink moved or become a directory?"
  ln -s "$skills_target" "$seed/.claude/skills" \
    || fail "could not seed the .claude/skills symlink pointing at $skills_target"
  fm_git_identity
  git -C "$seed" init -q || fail "could not init the seed repository at $seed"
  git -C "$seed" add --force .gitignore .claude/settings.json .claude/skills \
    || fail "could not stage the tracked fixture files in $seed"
  git -C "$seed" commit -qm baseline || fail "could not commit the seed baseline in $seed"
  git clone --quiet "$seed" "$clone" || fail "could not clone $seed into $clone"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$(dirname "$clone/$path")" || fail "could not create the fixture parent for $path"
    : > "$clone/$path" || fail "could not create the runtime artifact fixture $path"
    assert_ignored_by_tracked_gitignore "$clone" "$path"
  done < <(runtime_artifacts)

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -n "$(git -C "$clone" ls-files -- "$path")" ] \
      || fail "fixture is broken: $path is not tracked in the fresh clone"
    ! git -C "$clone" check-ignore -q --no-index -- "$path" \
      || fail "the shared ignore is too broad and hides tracked $path from git add"
  done < <(tracked_claude_paths)

  status=$(git -C "$clone" status --porcelain --untracked-files=all) \
    || fail "could not read the fresh clone status at $clone"
  [ -z "$status" ] \
    || fail "runtime artifacts dirty a fresh clone and would block self-update: $status"
  pass "all repository-local runtime artifact classes leave a fresh clone clean"
}

test_local_settings_can_never_become_tracked_accidentally() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- .claude/settings.local.json) \
    || fail "could not query the tracked file list in $ROOT"
  [ -z "$tracked" ] \
    || fail ".claude/settings.local.json is tracked and would freeze fleet self-update"
  assert_ignored_by_tracked_gitignore "$ROOT" .claude/settings.local.json
  pass "Claude's runtime-rewritten local settings remain untracked and shared-ignored"
}

test_runtime_artifacts_leave_a_fresh_clone_clean
test_local_settings_can_never_become_tracked_accidentally

echo "# all fm-runtime-ignore tests passed"
