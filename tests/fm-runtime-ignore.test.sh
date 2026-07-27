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

test_runtime_artifacts_leave_a_fresh_clone_clean() {
  local seed clone path match status
  seed="$TMP_ROOT/seed"
  clone="$TMP_ROOT/fresh-clone"

  mkdir -p "$seed/.claude"
  cp "$ROOT/.gitignore" "$seed/.gitignore"
  cp "$ROOT/.claude/settings.json" "$seed/.claude/settings.json"
  fm_git_identity
  git -C "$seed" init -q
  git -C "$seed" add .gitignore .claude/settings.json
  git -C "$seed" commit -qm baseline
  git clone --quiet "$seed" "$clone"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$(dirname "$clone/$path")"
    : > "$clone/$path"
    match=$(git -C "$clone" check-ignore -v -- "$path") \
      || fail "runtime artifact has no shared ignore rule: $path"
    case "$match" in
      .gitignore:*) ;;
      *) fail "runtime artifact is not ignored by the tracked .gitignore: $match" ;;
    esac
  done < <(runtime_artifacts)

  status=$(git -C "$clone" status --porcelain --untracked-files=all)
  [ -z "$status" ] \
    || fail "runtime artifacts dirty a fresh clone and would block self-update: $status"
  pass "all repository-local runtime artifact classes leave a fresh clone clean"
}

test_local_settings_can_never_become_tracked_accidentally() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- .claude/settings.local.json)
  [ -z "$tracked" ] \
    || fail ".claude/settings.local.json is tracked and would freeze fleet self-update"
  git -C "$ROOT" check-ignore -q --no-index -- .claude/settings.local.json \
    || fail ".claude/settings.local.json must be covered by the shared ignore"
  pass "Claude's runtime-rewritten local settings remain untracked and shared-ignored"
}

test_runtime_artifacts_leave_a_fresh_clone_clean
test_local_settings_can_never_become_tracked_accidentally

echo "# all fm-runtime-ignore tests passed"
