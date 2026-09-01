#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a COUNTED
# remote - one the project is registered against, never the validation pipeline's own
# local mirror, and re-read from the remote with --prune before the test - OR, for a
# normal ship task whose commits are not so reachable, its PR is merged and GitHub
# reports a PR head that contains the current local work, or its content is already in
# the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#   (z) tracked-and-dirty Claude task overlay                  -> ALLOW narrowly
#   (aa) Claude task overlay plus genuine dirty work           -> REFUSE
#   (bb) untracked legacy .claude/settings.local.json hook      -> REMOVED
#   (cc) repository-tracked .claude/settings.local.json         -> KEPT
#   (dd) legacy hook whose tracked-ness git cannot answer       -> KEPT
#   (ee) Codex per-task signal directory                         -> REMOVED
#
# Landed-proof narrowing (both failure modes reproduced 2026-08-21 before the fix):
#   (ff) work only on the validation pipeline's local mirror   -> REFUSE (mirror)
#   (gg) branch deleted on the remote after the last fetch     -> REFUSE (stale ref)
#   (hh) a registered remote that cannot be re-read            -> REFUSE, and say so
#   (ii) a relocated pipeline mirror named by NM_HOME          -> REFUSE (mirror)
# The same narrowing must still ACCEPT work that really landed, or it is an outage
# rather than a guard:
#   (jj) branch on the remote, no cached ref for it             -> ALLOW (re-read)
#   (kk) pipeline mirror registered AND branch on origin        -> ALLOW (everyday)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
fm_test_tmproot TMP_ROOT fm-teardown-tests

REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: reset and clean the returned worktree.
# The real command is destructive; modeling that observable behavior matters now
# that teardown deliberately avoids mutating a slot before its ownership check.
if [ "${1:-}" = status ]; then
  exit 0
fi
wt=${*: -1}
if git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$wt" reset --hard -q || exit 1
  git -C "$wt" clean -fdq || exit 1
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Add the validation pipeline's own scratch mirror as a remote and push the task
# branch to it, exactly as `no-mistakes init` plus a pipeline run leaves a project:
# a bare repository under the pipeline's repos root that never reaches the forge.
# The branch is then on a remote by git's reckoning, and on no hosting service at
# all. Args: case_dir
add_pipeline_mirror_with_pushed_branch() {
  local case_dir=$1 mirror
  mirror="$case_dir/.no-mistakes/repos/6e487fc7bf03.git"
  mkdir -p "$(dirname "$mirror")"
  git init -q --bare "$mirror"
  git -C "$case_dir/project" remote add no-mistakes "$mirror"
  git -C "$case_dir/wt" push -q no-mistakes fm/task-x1
  git -C "$case_dir/project" fetch -q no-mistakes
}

# Push the task branch to origin, fetch it so the remote-tracking ref exists, then
# delete the branch on the remote itself. The tracking ref left behind is stale:
# it names work the remote no longer has. Args: case_dir
push_then_delete_branch_on_origin() {
  local case_dir=$1
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/origin.git" update-ref -d refs/heads/fm/task-x1
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override GitHub lookups so BOTH reads the teardown path makes are answered: the
# landed-work read (`--json state,headRefOid`) and bin/fm-pr-poll.sh's own read
# (`--json state`, the whole poll). $2 is the state both report and $3 the head
# the merged pull request is reported to carry. Args: case_dir state head
add_gh_pr_state_and_head() {
  local case_dir=$1 state=$2 head=$3
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,$state" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: $state" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' '$state' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
      *"--json state"*) printf '%s\n' '$state' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Set FM_TEST_NO_TIMEOUT_PATH to a directory of symlinks that reaches every
# command on PATH except timeout(1) and gtimeout(1) - a Darwin seat that never
# installed coreutils, which is the seat a two-branch "timeout or run it bare"
# form leaves entirely unbounded. Called as a plain statement rather than through
# a command substitution, so the built path and any failure both land in the
# caller's own shell, and the walk happens once for the whole suite.
FM_TEST_NO_TIMEOUT_PATH=
ensure_no_timeout_path() {
  local dir entry name dirs
  [ -z "$FM_TEST_NO_TIMEOUT_PATH" ] || return 0
  FM_TEST_NO_TIMEOUT_PATH="$TMP_ROOT/no-timeout-bin"
  mkdir -p "$FM_TEST_NO_TIMEOUT_PATH"
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
      [ -f "$entry" ] && [ -x "$entry" ] || continue
      name=${entry##*/}
      case "$name" in timeout|gtimeout) continue ;; esac
      [ -e "$FM_TEST_NO_TIMEOUT_PATH/$name" ] || ln -s "$entry" "$FM_TEST_NO_TIMEOUT_PATH/$name"
    done
  done
  command -v timeout >/dev/null 2>&1 || fail "the host has no timeout(1), so the two rungs cannot be told apart"
  PATH="$FM_TEST_NO_TIMEOUT_PATH" command -v timeout >/dev/null 2>&1 \
    && fail "the timeout-less PATH still resolves timeout(1)"
  return 0
}

# Arm the task's real merge poll through bin/fm-pr-check.sh, exactly as landing
# does. Args: case_dir
arm_merge_poll() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null
}

# Every file the task's merge poll consists of. A retirement removes all of them
# or none of them, so the assertions below check the whole set rather than the
# runnable name alone. Args: case_dir
poll_artifacts_left() {
  local case_dir=$1 artifact left=
  for artifact in check.sh pr-poll pr-poll-registration check-trust; do
    if [ -e "$case_dir/state/task-x1.$artifact" ]; then
      left="$left task-x1.$artifact"
    fi
  done
  printf '%s' "${left# }"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# The defect this fixes: retiring a merge poll was reachable ONLY through a
# completed teardown, so a teardown correctly refused for unlanded work left the
# poll armed with nothing able to stop it. On the seat that reported it, the poll
# for an already-merged pull request then woke the session every five minutes for
# hours - 31% of every wake that reached the model that day - and the refusal was
# correct the whole time, because discarding those commits was the captain's call
# and he was away.
#
# The fixture is that exact shape: the pull request is MERGED, and the local copy
# still holds a commit the merged head does not contain, so the landed-work check
# refuses. Before the fix the poll survived that refusal.
test_refused_teardown_retires_a_fulfilled_poll() {
  local case_dir rc head_before merged_head left
  case_dir=$(make_case refused-retires-poll)
  write_meta "$case_dir" no-mistakes ship
  # The merged pull request's head is origin/main's tip: a real commit that does
  # not contain the task's own work.
  merged_head=$(git -C "$case_dir/wt" rev-parse origin/main)
  wt_commit_file "$case_dir" superseded.txt "pre-rebase" "work the merged head does not carry"
  head_before=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_state_and_head "$case_dir" MERGED "$merged_head"
  arm_merge_poll "$case_dir"
  [ -e "$case_dir/state/task-x1.check.sh" ] || fail "refused-retires-poll: fixture armed no poll"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The refusal must be exactly as strong as before: same exit status, same
  # REFUSED line, and the work itself untouched.
  expect_code 1 "$rc" "refused-retires-poll: teardown must still refuse unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "refused-retires-poll: no REFUSED line in stderr"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "refused-retires-poll: the refused teardown moved the worktree HEAD"
  [ -f "$case_dir/wt/superseded.txt" ] \
    || fail "refused-retires-poll: the refused teardown discarded the unlanded work"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "refused-retires-poll: the refused teardown removed the task record"

  left=$(poll_artifacts_left "$case_dir")
  [ -z "$left" ] || fail "refused-retires-poll: the spent poll survived the refusal: $left"
  grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
    || fail "refused-retires-poll: the refusal did not say the poll had been retired"
  pass "a teardown refused for unlanded work still retires the poll of an already-merged PR"
}

# The other half of the same rule: only a FULFILLED poll is retired. An unmerged
# poll prints nothing, so it wakes nobody and costs nothing, and it is still
# carrying the merge notification the task is waiting for. Retiring it on a
# refusal would trade a loud defect for a silent one.
test_refused_teardown_keeps_an_unfulfilled_poll() {
  local case_dir rc
  case_dir=$(make_case refused-keeps-poll)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" pending.txt "not landed" "work still in review"
  add_gh_pr_state_and_head "$case_dir" OPEN "$(git -C "$case_dir/wt" rev-parse origin/main)"
  arm_merge_poll "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refused-keeps-poll: teardown must refuse unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "refused-keeps-poll: no REFUSED line in stderr"
  [ -e "$case_dir/state/task-x1.check.sh" ] \
    || fail "refused-keeps-poll: an open PR's poll was retired, losing its merge notification"
  [ -e "$case_dir/state/task-x1.pr-poll" ] \
    || fail "refused-keeps-poll: an open PR's sidecar was removed"
  ! grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
    || fail "refused-keeps-poll: teardown claimed to retire an unmerged PR's poll"
  pass "a refused teardown leaves an unmerged PR's poll armed, so no merge notification is lost"
}

# The refusal, not one call site, is what a spent poll must not survive. Wiring
# the retirement to the worktree-safety check alone left the identical outcome -
# a teardown refuses, and a poll whose pull request has already merged stays
# armed and keeps printing "merged" every CHECK_INTERVAL - reachable through
# every sibling refusal that fails for the same reason. This fixture takes one of
# them: a scout whose report was never written, refused before the worktree is
# ever inspected, carrying a poll for a merged pull request.
test_refused_sibling_teardown_retires_a_fulfilled_poll() {
  local case_dir rc head_before left
  case_dir=$(make_case refused-sibling-retires-poll)
  write_meta "$case_dir" no-mistakes scout
  mkdir -p "$case_dir/data"
  wt_commit_file "$case_dir" findings.txt "unwritten" "work the scout has not reported"
  head_before=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_state_and_head "$case_dir" MERGED "$(git -C "$case_dir/wt" rev-parse origin/main)"
  arm_merge_poll "$case_dir"
  [ -e "$case_dir/state/task-x1.check.sh" ] \
    || fail "refused-sibling-retires-poll: fixture armed no poll"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The refusal is exactly as strong as before: same exit status, its own REFUSED
  # line, and the work untouched.
  expect_code 1 "$rc" "refused-sibling-retires-poll: teardown must still refuse a reportless scout"
  grep -q 'REFUSED: scout task task-x1 has no report' "$case_dir/stderr" \
    || fail "refused-sibling-retires-poll: the scout refusal line is gone: $(cat "$case_dir/stderr")"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "refused-sibling-retires-poll: the refused teardown moved the worktree HEAD"
  [ -f "$case_dir/wt/findings.txt" ] \
    || fail "refused-sibling-retires-poll: the refused teardown discarded the unreported work"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "refused-sibling-retires-poll: the refused teardown removed the task record"

  left=$(poll_artifacts_left "$case_dir")
  [ -z "$left" ] || fail "refused-sibling-retires-poll: the spent poll survived a sibling refusal: $left"
  grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
    || fail "refused-sibling-retires-poll: the refusal did not say the poll had been retired"
  pass "a sibling teardown refusal retires the poll of an already-merged PR too"
}

# The same half-rule holds on the sibling path: only a FULFILLED poll goes. An
# open pull request's poll still carries the merge notification the task waits
# for, and it wakes nobody until it arrives.
test_refused_sibling_teardown_keeps_an_unfulfilled_poll() {
  local case_dir rc
  case_dir=$(make_case refused-sibling-keeps-poll)
  write_meta "$case_dir" no-mistakes scout
  mkdir -p "$case_dir/data"
  wt_commit_file "$case_dir" findings.txt "unwritten" "work the scout has not reported"
  add_gh_pr_state_and_head "$case_dir" OPEN "$(git -C "$case_dir/wt" rev-parse origin/main)"
  arm_merge_poll "$case_dir"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refused-sibling-keeps-poll: teardown must refuse a reportless scout"
  grep -q 'REFUSED: scout task task-x1 has no report' "$case_dir/stderr" \
    || fail "refused-sibling-keeps-poll: the scout refusal line is gone"
  [ -e "$case_dir/state/task-x1.check.sh" ] \
    || fail "refused-sibling-keeps-poll: an open PR's poll was retired, losing its merge notification"
  [ -e "$case_dir/state/task-x1.pr-poll" ] \
    || fail "refused-sibling-keeps-poll: an open PR's sidecar was removed"
  ! grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
    || fail "refused-sibling-keeps-poll: teardown claimed to retire an unmerged PR's poll"
  pass "a sibling refusal leaves an unmerged PR's poll armed"
}

# The ownership refusal is the same class as the refusals already routed: it
# protects a THIRD party's uncommitted work in a pooled slot, and a poll is not
# what it protects. It sits above teardown's own poll pre-flight, so it used to
# exit before any retirement could run and strand a spent poll exactly as the
# reported incident did. Its own exit status - not a flattened 1 - must survive.
# Run on both rungs of the bounded-execution ladder: on a seat with a timeout
# binary, and on one with neither timeout nor gtimeout, which falls to the perl
# alarm. A rung that cannot read the poll's answer would retire nothing while
# every "stays armed" assertion elsewhere still passed, so this is the positive
# control for both.
test_ownership_refusal_retires_a_fulfilled_poll() {
  local case_dir rc head_before left label case_path
  for label in timeout-binary no-timeout-binary; do
    case_dir=$(make_case "ownership-refusal-retires-poll-$label")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" pending.txt "not landed" "work still in review"
    head_before=$(git -C "$case_dir/wt" rev-parse HEAD)
    add_gh_pr_state_and_head "$case_dir" MERGED "$(git -C "$case_dir/wt" rev-parse origin/main)"
    arm_merge_poll "$case_dir"
    printf 'holder=task-other\n' > "$case_dir/state/task-x1.slot-disputed"

    if [ "$label" = no-timeout-binary ]; then
      ensure_no_timeout_path
      case_path="$case_dir/fakebin:$FM_TEST_NO_TIMEOUT_PATH"
    else
      case_path="$case_dir/fakebin:$PATH"
    fi

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_path" \
      "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 4 "$rc" "$label: the slot-held refusal must keep its own exit status"
    grep -q 'is held by task-other, which is still live' "$case_dir/stderr" \
      || fail "$label: the ownership REFUSED line is gone: $(cat "$case_dir/stderr")"
    [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head_before" ] \
      || fail "$label: the refused teardown moved the worktree HEAD"
    [ -f "$case_dir/wt/pending.txt" ] \
      || fail "$label: the refused teardown discarded the unlanded work"
    [ -f "$case_dir/state/task-x1.meta" ] \
      || fail "$label: the refused teardown removed the task record"

    left=$(poll_artifacts_left "$case_dir")
    [ -z "$left" ] || fail "$label: the spent poll survived the ownership refusal: $left"
    grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
      || fail "$label: the refusal did not say the poll had been retired"
  done
  pass "a teardown refused for a contested pooled slot retires an already-merged PR's poll on either timeout rung"
}

# Retirement asks the forge, and it now runs on refusals that were decided from
# purely local facts, so that read is bounded by the same deadline the watcher
# gives this exact program. A stalled forge must not hold a refusal open: the
# refusal prints and exits on time, and the unanswered poll simply stays armed,
# which costs nothing because an unfulfilled poll is silent.
# Bounded on EVERY seat, not only on one with GNU coreutils. The second vector
# runs teardown on a PATH with no timeout(1) and no gtimeout(1) - a Darwin seat
# without coreutils - which is the seat where a two-branch form runs the forge
# read with no deadline at all and hangs a refusal that was already decided from
# purely local facts. Both must refuse on time and leave the poll armed.
test_refusal_is_not_held_open_by_a_stalled_forge() {
  local case_dir rc left label case_path
  for label in timeout-binary no-timeout-binary; do
    case_dir=$(make_case "refusal-bounded-forge-read-$label")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" pending.txt "not landed" "work still in review"
    add_gh_pr_state_and_head "$case_dir" MERGED "$(git -C "$case_dir/wt" rev-parse origin/main)"
    arm_merge_poll "$case_dir"
    printf 'holder=task-other\n' > "$case_dir/state/task-x1.slot-disputed"
    # Only now does the forge stall - the fixture had to be armed against a
    # readable one first.
    cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 600
SH
    chmod +x "$case_dir/fakebin/gh"

    if [ "$label" = no-timeout-binary ]; then
      ensure_no_timeout_path
      case_path="$case_dir/fakebin:$FM_TEST_NO_TIMEOUT_PATH"
    else
      case_path="$case_dir/fakebin:$PATH"
    fi

    # The deadline on the whole run is this test's own, resolved on the test's
    # PATH; only teardown itself runs on the seat's PATH.
    set +e
    timeout 60 env \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$case_dir/state" \
      FM_CONFIG_OVERRIDE="$case_dir/config" \
      FM_CHECK_TIMEOUT=1 \
      PATH="$case_path" \
      "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    [ "$rc" -ne 124 ] || fail "$label: a stalled forge held the refusal open"
    expect_code 4 "$rc" "$label: the refusal must exit with its own status"
    grep -q 'is held by task-other, which is still live' "$case_dir/stderr" \
      || fail "$label: the ownership REFUSED line is gone: $(cat "$case_dir/stderr")"
    [ -f "$case_dir/wt/pending.txt" ] \
      || fail "$label: the refused teardown discarded the unlanded work"

    # The read never answered, so it is evidence of nothing: the poll stays armed.
    left=$(poll_artifacts_left "$case_dir")
    case "$left" in *task-x1.check.sh*) ;; *) fail "$label: an unread poll was retired: '$left'" ;; esac
    ! grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
      || fail "$label: teardown claimed to retire a poll it could not read"
  done
  pass "a stalled forge cannot hold a teardown refusal open on either timeout rung, and an unread poll stays armed"
}

# The reach of a retirement has to follow whether the task actually ENDS. A
# refusal does not end it, so on that path the poll's own files go and the
# custom-check trust record - which belongs to bin/fm-check-register.sh, not to
# any poll - stays. A completed teardown does end the task, and legitimately
# takes the trust record with everything else. Both halves are asserted here so
# the two paths cannot quietly converge on either scope.
test_refusal_and_completion_differ_in_what_they_may_remove() {
  local case_dir rc left pr_head
  case_dir=$(make_case refusal-keeps-trust-record)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" superseded.txt "pre-rebase" "work the merged head does not carry"
  add_gh_pr_state_and_head "$case_dir" MERGED "$(git -C "$case_dir/wt" rev-parse origin/main)"
  arm_merge_poll "$case_dir"
  printf 'fm-custom-check-v1\n' > "$case_dir/state/task-x1.check-trust"
  chmod 0600 "$case_dir/state/task-x1.check-trust"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refusal-keeps-trust-record: teardown must still refuse unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "refusal-keeps-trust-record: no REFUSED line in stderr"
  grep -q 'RETIRED MERGE POLL' "$case_dir/stderr" \
    || fail "refusal-keeps-trust-record: the refusal did not retire the spent poll"
  [ ! -e "$case_dir/state/task-x1.check.sh" ] \
    || fail "refusal-keeps-trust-record: the spent poll's check survived the refusal"
  [ ! -e "$case_dir/state/task-x1.pr-poll" ] \
    || fail "refusal-keeps-trust-record: the spent poll's sidecar survived the refusal"
  [ -e "$case_dir/state/task-x1.check-trust" ] \
    || fail "refusal-keeps-trust-record: a refused teardown removed a trust record it does not own"

  # A teardown that COMPLETES ends the task, so the same shape loses both.
  case_dir=$(make_case completion-removes-trust-record)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf 'fm-custom-check-v1\n' > "$case_dir/state/task-x1.check-trust"
  chmod 0600 "$case_dir/state/task-x1.check-trust"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "completion-removes-trust-record: teardown should succeed on a merged PR"
  ! grep -q REFUSED "$case_dir/stderr" || fail "completion-removes-trust-record: teardown printed a REFUSED line"
  left=$(poll_artifacts_left "$case_dir")
  [ -z "$left" ] || fail "completion-removes-trust-record: a completed teardown left task state behind: $left"
  pass "a refused teardown retires only the poll; a completed one ends the task and takes the trust record too"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_tracked_dirty_claude_task_overlay_allows() {
  local case_dir rc
  case_dir=$(make_case tracked-dirty-claude-task-overlay)
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"hooks":{"Stop":[]}}' > "$case_dir/wt/.claude/settings.fm-task.json"
  git -C "$case_dir/wt" add .claude/settings.fm-task.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "track Claude task overlay fixture"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[]}]}}' > "$case_dir/wt/.claude/settings.fm-task.json"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "tracked-dirty-claude-task-overlay: teardown should ignore only the generated Claude task overlay"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "tracked-dirty-claude-task-overlay: teardown refused the generated overlay"
  pass "tracked-and-dirty Claude task overlay does not make a landed ship worktree unteardownable"
}

test_claude_task_overlay_does_not_mask_other_dirty_work() {
  local case_dir rc
  case_dir=$(make_case claude-task-overlay-plus-dirty-work)
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"hooks":{"Stop":[]}}' > "$case_dir/wt/.claude/settings.fm-task.json"
  git -C "$case_dir/wt" add .claude/settings.fm-task.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "track Claude task overlay fixture"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[]}]}}' > "$case_dir/wt/.claude/settings.fm-task.json"
  printf '%s\n' "genuine uncommitted work" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "claude-task-overlay-plus-dirty-work: teardown must refuse genuine dirty work"
  grep -q "uncommitted changes" "$case_dir/stderr" \
    || fail "claude-task-overlay-plus-dirty-work: refusal did not cite uncommitted changes"
  pass "Claude task overlay tolerance does not mask other uncommitted work"
}

test_untracked_legacy_claude_hook_is_removed() {
  local case_dir rc legacy
  case_dir=$(make_case untracked-legacy-claude-hook)
  write_meta "$case_dir" no-mistakes ship
  legacy="$case_dir/wt/.claude/settings.local.json"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '"'"'/tmp/state/old.turn-ended'"'"'"}]}]}}' \
    > "$legacy"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "untracked-legacy-claude-hook: teardown should allow an untracked generated hook"
  assert_absent "$legacy" \
    "untracked-legacy-claude-hook: a pre-upgrade hook file survived teardown and would fire for the dead task"
  pass "an untracked legacy Claude hook file is removed so a reused worktree cannot signal for a dead task"
}

test_legacy_claude_hook_survives_an_inconclusive_git_query() {
  local case_dir rc legacy before
  case_dir=$(make_case legacy-claude-hook-no-work-tree)
  write_meta "$case_dir" local-only ship
  legacy="$case_dir/wt/.claude/settings.local.json"
  # No work tree here, so git cannot answer whether the path is tracked. --force is
  # the only way to reach the cleanup without the safety check, which is exactly the
  # path the fail-closed guard has to hold on.
  rm -rf "$case_dir/wt"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '"'"'/tmp/state/old.turn-ended'"'"'"}]}]}}' \
    > "$legacy"
  before=$(cat "$legacy")

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "legacy-claude-hook-no-work-tree: forced teardown should still complete"
  [ -f "$legacy" ] && [ "$(cat "$legacy")" = "$before" ] \
    || fail "legacy-claude-hook-no-work-tree: an inconclusive tracked-ness query deleted the file instead of keeping it"
  pass "an inconclusive git tracked-ness query keeps the legacy settings.local.json (fails closed)"
}

test_tracked_legacy_claude_settings_survive_teardown() {
  local case_dir rc legacy before
  case_dir=$(make_case tracked-legacy-claude-settings)
  write_meta "$case_dir" no-mistakes ship
  legacy="$case_dir/wt/.claude/settings.local.json"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '"'"'/tmp/state/old.turn-ended'"'"'"}]}]}}' \
    > "$legacy"
  before=$(cat "$legacy")
  git -C "$case_dir/wt" add -f .claude/settings.local.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "track repository-local Claude settings"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "tracked-legacy-claude-settings: teardown should allow a clean landed worktree"
  [ -f "$legacy" ] && [ "$(cat "$legacy")" = "$before" ] \
    || fail "tracked-legacy-claude-settings: teardown discarded a repository-tracked settings.local.json"
  pass "a repository-tracked settings.local.json is left untouched by teardown"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_teardown_removes_codex_signal_directory() {
  local case_dir rc
  case_dir=$(make_case codex-signal-cleanup)
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/state/.crew-signal/task-x1"
  printf 'done: ready\n' > "$case_dir/state/.crew-signal/task-x1/status"
  : > "$case_dir/state/.crew-signal/task-x1/turn-ended"
  ln -s ".crew-signal/task-x1/status" "$case_dir/state/task-x1.status"
  ln -s ".crew-signal/task-x1/turn-ended" "$case_dir/state/task-x1.turn-ended"
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "codex-signal-cleanup: forced teardown should succeed"
  [ ! -e "$case_dir/state/task-x1.status" ] && [ ! -L "$case_dir/state/task-x1.status" ] \
    || fail "codex-signal-cleanup: teardown left the public status symlink"
  [ ! -e "$case_dir/state/task-x1.turn-ended" ] && [ ! -L "$case_dir/state/task-x1.turn-ended" ] \
    || fail "codex-signal-cleanup: teardown left the public turn-ended symlink"
  [ ! -e "$case_dir/state/.crew-signal/task-x1" ] \
    || fail "codex-signal-cleanup: teardown left the private signal directory"
  pass "teardown removes a Codex task's private signal directory and public signal symlinks"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_CLOSE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-unconfirmed-close: teardown should preserve best-effort endpoint semantics"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains the stale journal and attempts no workspace cleanup when exact-pane close is unconfirmed"
}

test_pipeline_mirror_only_refuses() {
  local case_dir rc
  case_dir=$(make_case mirror-only)
  write_meta "$case_dir" no-mistakes ship
  # Real content, so the content-in-default fallback cannot call it landed.
  wt_commit_file "$case_dir" mirror.txt "only on the pipeline mirror" "mirror-only work"
  add_pipeline_mirror_with_pushed_branch "$case_dir"

  # The work really is on that mirror and really is nowhere else.
  git -C "$case_dir/project" rev-parse --verify -q refs/remotes/no-mistakes/fm/task-x1 >/dev/null \
    || fail "mirror-only: the mirror remote-tracking ref was not created"
  ! git -C "$case_dir/origin.git" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
    || fail "mirror-only: the branch reached origin, so this case proves nothing"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mirror-only: teardown must refuse work that reached only the pipeline mirror"
  grep -q REFUSED "$case_dir/stderr" || fail "mirror-only: no REFUSED line in stderr"
  pass "work present only on the validation pipeline's local mirror is refused"
}

test_branch_deleted_on_remote_after_fetch_refuses() {
  local case_dir rc
  case_dir=$(make_case remote-deleted)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" gone.txt "pushed, then deleted upstream" "deleted-upstream work"
  push_then_delete_branch_on_origin "$case_dir"

  # The stale tracking ref is still here, which is exactly the trap.
  git -C "$case_dir/project" rev-parse --verify -q refs/remotes/origin/fm/task-x1 >/dev/null \
    || fail "remote-deleted: the stale tracking ref is gone, so this case proves nothing"
  ! git -C "$case_dir/origin.git" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
    || fail "remote-deleted: the branch still exists on the remote, so this case proves nothing"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "remote-deleted: teardown must refuse work the remote no longer has"
  grep -q REFUSED "$case_dir/stderr" || fail "remote-deleted: no REFUSED line in stderr"
  pass "work whose branch was deleted on the remote after the last fetch is refused"
}

test_unreadable_remote_is_not_trusted() {
  local case_dir rc
  case_dir=$(make_case unreadable-remote)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" unreadable.txt "pushed, remote now unreachable" "unreadable-remote work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  # The remote itself is gone, so nothing can be confirmed there any more. The
  # cached tracking ref still says the branch is on it.
  rm -rf "$case_dir/origin.git"
  git -C "$case_dir/project" rev-parse --verify -q refs/remotes/origin/fm/task-x1 >/dev/null \
    || fail "unreadable-remote: the cached tracking ref is gone, so this case proves nothing"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-remote: teardown must refuse when no remote could be re-read"
  grep -q REFUSED "$case_dir/stderr" || fail "unreadable-remote: no REFUSED line in stderr"
  assert_grep "could not be re-read: origin" "$case_dir/stderr" \
    "unreadable-remote: the refusal did not name the remote whose refs were not trusted"
  pass "a remote that cannot be re-read supplies no landing evidence, and the refusal says so"
}

test_relocated_pipeline_mirror_only_refuses() {
  local case_dir rc mirror
  case_dir=$(make_case mirror-relocated)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" relocated.txt "only on a relocated mirror" "relocated-mirror work"
  # An install whose state lives somewhere other than ~/.no-mistakes: the path
  # shape no longer gives it away, and NM_HOME is what names it.
  mirror="$case_dir/nm-elsewhere/repos/6e487fc7bf03.git"
  mkdir -p "$(dirname "$mirror")"
  git init -q --bare "$mirror"
  git -C "$case_dir/project" remote add no-mistakes "$mirror"
  git -C "$case_dir/wt" push -q no-mistakes fm/task-x1
  git -C "$case_dir/project" fetch -q no-mistakes

  set +e
  NM_HOME="$case_dir/nm-elsewhere" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mirror-relocated: teardown must refuse work that reached only a relocated pipeline mirror"
  grep -q REFUSED "$case_dir/stderr" || fail "mirror-relocated: no REFUSED line in stderr"
  pass "a relocated pipeline mirror named by NM_HOME is refused as landing evidence too"
}

test_branch_on_remote_but_never_fetched_allows() {
  local case_dir rc
  case_dir=$(make_case never-fetched)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" pushed.txt "on the remote right now" "pushed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  # The remote has the branch; this clone has no cached ref saying so, which is
  # what a clone that pushed from elsewhere, or pruned, or never fetched looks like.
  git -C "$case_dir/project" update-ref -d refs/remotes/origin/fm/task-x1
  git -C "$case_dir/origin.git" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
    || fail "never-fetched: the branch is not on the remote, so this case proves nothing"
  ! git -C "$case_dir/project" rev-parse --verify -q refs/remotes/origin/fm/task-x1 >/dev/null \
    || fail "never-fetched: a cached ref survived, so this case proves nothing"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "never-fetched: teardown must accept work the remote really has"
  ! grep -q REFUSED "$case_dir/stderr" || fail "never-fetched: teardown printed a REFUSED line"
  pass "work the remote holds is torn down even when no cached ref said so (the re-read accepts too)"
}

test_pipeline_mirror_alongside_origin_allows() {
  local case_dir rc
  case_dir=$(make_case mirror-and-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" shipped.txt "pushed to both" "shipped work"
  # The everyday shape of a no-mistakes ship task: the pipeline mirror is a
  # registered remote AND the branch reached origin. Excluding the mirror must
  # not cost the ordinary case its teardown.
  add_pipeline_mirror_with_pushed_branch "$case_dir"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "mirror-and-origin: teardown must accept work that reached origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "mirror-and-origin: teardown printed a REFUSED line"
  pass "an excluded pipeline mirror does not stop ordinary origin-pushed work being torn down"
}

test_local_only_fork_remote_allows
test_pipeline_mirror_only_refuses
test_branch_deleted_on_remote_after_fetch_refuses
test_unreadable_remote_is_not_trusted
test_relocated_pipeline_mirror_only_refuses
test_branch_on_remote_but_never_fetched_allows
test_pipeline_mirror_alongside_origin_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_teardown_removes_codex_signal_directory
test_herdr_teardown_clears_escalation_marker
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_tracked_dirty_claude_task_overlay_allows
test_claude_task_overlay_does_not_mask_other_dirty_work
test_untracked_legacy_claude_hook_is_removed
test_legacy_claude_hook_survives_an_inconclusive_git_query
test_tracked_legacy_claude_settings_survive_teardown
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_refused_teardown_retires_a_fulfilled_poll
test_refused_teardown_keeps_an_unfulfilled_poll
test_refused_sibling_teardown_retires_a_fulfilled_poll
test_refused_sibling_teardown_keeps_an_unfulfilled_poll
test_ownership_refusal_retires_a_fulfilled_poll
test_refusal_is_not_held_open_by_a_stalled_forge
test_refusal_and_completion_differ_in_what_they_may_remove
