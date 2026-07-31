#!/usr/bin/env bash
# Regression tests for checkout-local harness artifacts that must never make a
# freshly cloned firstmate home dirty and block its tracked-files fast-forward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-runtime-ignore

runtime_artifacts() {
  cat <<'PATHS'
.local/axi/bin/gh-axi
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

# tests/lib.sh owns the fresh-clone builder and the match-source check: the
# shared rule has to be the one doing the ignoring, because check-ignore succeeds
# for a clone-private .git/info/exclude or a developer's global core.excludesFile
# too, and those are exactly the sources a fresh vessel does not inherit.
test_runtime_artifacts_leave_a_fresh_clone_clean() {
  local seed clone path status
  seed="$TMP_ROOT/seed"
  clone="$TMP_ROOT/fresh-clone"

  fm_fresh_ignore_clone "$seed" "$clone" .claude/settings.json .claude/skills

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$(dirname "$clone/$path")" || fail "could not create the fixture parent for $path"
    : > "$clone/$path" || fail "could not create the runtime artifact fixture $path"
    fm_assert_ignored_by_tracked_gitignore "$clone" "$path" "runtime artifact"
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
  fm_assert_ignored_by_tracked_gitignore "$ROOT" .claude/settings.local.json "runtime artifact"
  pass "Claude's runtime-rewritten local settings remain untracked and shared-ignored"
}

test_runtime_artifacts_leave_a_fresh_clone_clean
test_local_settings_can_never_become_tracked_accidentally

echo "# all fm-runtime-ignore tests passed"
