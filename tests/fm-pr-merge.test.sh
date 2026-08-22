#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) no-method merge records pr= and pr_head= before merging, then defaults
#       to a real merge commit
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --merge)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge methods, including --squash, are not overridden by the
#       default --merge
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) the merged head branch is deleted by the merge itself, by default
#   (j) only the long-form --delete-branch[=false] counts as the caller's own
#       choice, so -d never suppresses the default deletion
#   (k) a failed merge issues no branch deletion of any kind
#   (l) a PR carrying the validation pipeline's placeholder title is refused
#       before any state is recorded, with a message naming both the problem
#       and the remedy
#   (m) titles that merely resemble the placeholder merge exactly as before,
#       because an over-eager guard is bypassed rather than heeded
#   (n) case and surrounding whitespace do not evade the placeholder match
#   (o) --allow-placeholder-title lands it deliberately, and never leaks into
#       the forge CLI arguments
#   (p) a title that stays unreadable is refused distinctly, saying it could not
#       be read and never calling it a placeholder
#   (q) a transient read failure is retried and merges normally once the read
#       succeeds
#   (r) --allow-unreadable-title merges an unread title, and never leaks into
#       the forge CLI arguments
#   (s) the two escapes do not substitute for each other: --allow-unreadable-title
#       still refuses a read placeholder, and --allow-placeholder-title still
#       refuses an unread title
#   (t) a PR no local task owns lands through --no-local-task, records nothing,
#       arms nothing, and says both out loud rather than succeeding silently
#   (u) --no-local-task keeps every other guard: a placeholder title is still
#       refused on that path
#   (v) --no-local-task refuses a PR a local task has already recorded, so the
#       flag cannot be aimed at the case the recording requirement protects
#   (w) --no-local-task takes only the PR URL, so a task id passed out of habit
#       is refused rather than forwarded to the forge as a merge argument
#   (x) the recording requirement still refuses: a task that exists whose
#       recording fails does not merge
#   (y) the missing-meta refusal names the route for a PR with no local task,
#       and says plainly that it is not a way past the requirement
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
fm_test_tmproot TMP_ROOT fm-pr-merge-tests

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup plus title for the
# placeholder-title guard. FM_TEST_GH_TITLE overrides the title a case sees;
# the default is an ordinary descriptive title, so every pre-existing case
# proves the guard stays out of the way of normal work. FM_TEST_GH_TITLE_FAIL=1
# fails every title read; FM_TEST_GH_TITLE_FAIL_COUNT=n fails only the first n,
# which is how a transient read failure is told apart from a persistent one. The
# mock counts its title reads into <case_dir>/gh-title-attempts, so a case can
# prove the retry actually happened and stayed bounded.
# Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
attempts_file='$case_dir/gh-title-attempts'
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *" title "*)
        attempt=\$(cat "\$attempts_file" 2>/dev/null || printf '0')
        attempt=\$((attempt + 1))
        printf '%s\n' "\$attempt" > "\$attempts_file"
        [ "\${FM_TEST_GH_TITLE_FAIL:-0}" = 0 ] || exit 1
        [ "\$attempt" -gt "\${FM_TEST_GH_TITLE_FAIL_COUNT:-0}" ] || exit 1
        printf '%s\n' "\${FM_TEST_GH_TITLE-fix(pipeline): tighten the merge guard}"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" title "*) printf '%s\n' "${FM_TEST_GH_TITLE-fix(pipeline): tighten the merge guard}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# FM_HOME is pinned to a per-case directory rather than left inherited. Every
# bin/ entrypoint prepends "$FM_HOME/.local/axi/bin" to its own PATH, so under a
# session that exports a real FM_HOME - which a crewmate session does - the
# operator's own gh-axi sat ahead of this fixture's fakebin and the real forge
# CLI ran against a repository this test invented. That is what failed the first
# case here on the fleet's own machine while it passed elsewhere. The case dir
# holds no such directory, so the prepend is inert and the mocks are what run; it
# also keeps bin/fm-guard.sh reading this sandbox rather than the live fleet.
run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_no_method_defaults_to_merge_commit_after_recording() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --merge"
  pass "fm-pr-merge records pr= and pr_head= before defaulting to a real merge commit"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_explicit_squash_and_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge honors explicit --squash and forwards extra flags after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  # A refusal with no route is what sent an operator looking for a bare forge
  # merge, so this one names the route - and says what it is not.
  assert_grep 'no-local-task' "$case_dir/stderr" \
    "missing-meta: refusal did not name the route for a PR with no local task"
  assert_grep 'typo' "$case_dir/stderr" \
    "missing-meta: refusal did not warn that a mistyped task id lands here too"
  assert_grep 'not a way' "$case_dir/stderr" \
    "missing-meta: refusal did not say the route is no way past the requirement"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --delete-branch --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --merge"
  pass "fm-pr-merge does not add default --merge when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --delete-branch --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --merge"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --merge"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_default_deletes_merged_head_branch() {
  local case_dir
  case_dir=$(make_case default-delete-branch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "default-delete-branch: fm-pr-merge failed"

  grep -qxF 'pr merge 31 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "default-delete-branch: the merged head branch was not deleted by the merge itself"
  # The deletion must ride on the merge, never on a second command that could
  # run when the merge did not land.
  [ "$(wc -l < "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "default-delete-branch: fm-pr-merge issued a branch deletion separate from the merge"
  pass "fm-pr-merge has the forge delete the merged head branch as part of the merge"
}

test_caller_delete_choice_not_overridden() {
  local case_dir
  case_dir=$(make_case delete-branch-shorthand)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "delete-branch-shorthand: fm-pr-merge failed"

  grep -qxF 'pr merge 33 --repo example/repo --merge --delete-branch -d' "$case_dir/gh-axi.log" \
    || fail "delete-branch-shorthand: caller -d suppressed the default --delete-branch"

  case_dir=$(make_case keep-branch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 -- --delete-branch=false \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "keep-branch: fm-pr-merge failed"

  grep -qxF 'pr merge 34 --repo example/repo --merge --delete-branch=false' "$case_dir/gh-axi.log" \
    || fail "keep-branch: a caller asking to keep the branch had --delete-branch forced back on"
  pass "fm-pr-merge honors only a long-form caller delete-branch choice, on or off"
}

test_failed_merge_deletes_nothing() {
  local case_dir rc
  case_dir=$(make_case merge-fails-no-delete)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails-no-delete: fm-pr-merge should propagate the merge failure"
  # A failed merge must leave the branch alone. It can only do that if the one
  # deletion path is the merge command itself, which deleted nothing when it
  # failed, and nothing else ran afterwards.
  [ "$(wc -l < "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "merge-fails-no-delete: something ran after the merge failed"
  grep -qxF 'pr merge 35 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "merge-fails-no-delete: the failed invocation was not the merge itself"
  pass "fm-pr-merge deletes no branch when the merge itself failed"
}

test_placeholder_title_refuses_before_recording() {
  local case_dir rc
  case_dir=$(make_case placeholder-title)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE='chore: update pull request'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE

  expect_code 1 "$rc" "placeholder-title: fm-pr-merge should refuse the pipeline's placeholder title"
  # The refusal has to name the problem AND the remedy, or the next operator
  # learns only that something failed and reaches around this path.
  assert_grep 'chore: update pull request' "$case_dir/stderr" \
    "placeholder-title: refusal did not quote the offending title"
  assert_grep 'merge commit' "$case_dir/stderr" \
    "placeholder-title: refusal did not say why the title is permanent"
  assert_grep 'gh pr edit 41 --repo example/repo --title' "$case_dir/stderr" \
    "placeholder-title: refusal did not name the remedy"
  assert_grep 'allow-placeholder-title' "$case_dir/stderr" \
    "placeholder-title: refusal did not name the deliberate override"
  assert_no_grep 'pr=https://github.com/example/repo/pull/41' "$case_dir/state/task-x1.meta" \
    "placeholder-title: PR URL was recorded despite the refusal"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "placeholder-title: a refused merge armed a merge poll"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "placeholder-title: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses a placeholder PR title before recording state or merging"
}

test_placeholder_match_is_exact_not_a_heuristic() {
  local case_dir title n=0
  # A guard that cries wolf gets bypassed, so titles that merely resemble the
  # placeholder must merge exactly as they do today.
  for title in 'chore: update the vendored pin' 'chore: update pull request handling in the poll' \
    'fix(pr): stop dropping the pull request title'; do
    n=$((n + 1))
    case_dir=$(make_case "near-miss-$n")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    : > "$case_dir/gh-axi.log"

    export FM_TEST_GH_TITLE="$title"
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "near-miss: fm-pr-merge refused the legitimate title '$title'"
    unset FM_TEST_GH_TITLE

    grep -qxF 'pr merge 42 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
      || fail "near-miss: '$title' did not merge exactly as an ordinary title does"
  done
  pass "fm-pr-merge matches placeholder titles exactly and never fires on a title that only resembles one"
}

test_placeholder_match_ignores_case_and_surrounding_space() {
  local case_dir rc
  case_dir=$(make_case placeholder-title-variant)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE='  Chore: Update Pull Request  '
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE

  expect_code 1 "$rc" "placeholder-title-variant: recasing or padding the placeholder should not evade the guard"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "placeholder-title-variant: gh-axi pr merge was invoked"
  pass "fm-pr-merge sees through case and surrounding whitespace on a placeholder title"
}

test_override_lands_placeholder_title_deliberately() {
  local case_dir
  case_dir=$(make_case placeholder-title-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE='chore: update pull request'
  run_pr_merge "$case_dir" --allow-placeholder-title task-x1 \
    https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "placeholder-title-override: the deliberate override did not merge"
  unset FM_TEST_GH_TITLE

  # The override is this path's own option and must never reach the forge CLI.
  grep -qxF 'pr merge 44 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "placeholder-title-override: the override leaked into the gh-axi merge arguments"
  assert_grep 'pr=https://github.com/example/repo/pull/44' "$case_dir/state/task-x1.meta" \
    "placeholder-title-override: an overridden merge did not record pr="
  pass "fm-pr-merge lands a placeholder title only when the caller asks for it explicitly"
}

test_unreadable_title_refuses_rather_than_guessing() {
  local case_dir rc
  case_dir=$(make_case unreadable-title)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE_FAIL=1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE_FAIL

  expect_code 1 "$rc" "unreadable-title: fm-pr-merge should refuse a title it could not read"
  assert_grep 'could not read the title' "$case_dir/stderr" \
    "unreadable-title: refusal did not name the unread title as the distinct problem"
  # An operator must never have to assert a title is a placeholder to get past a
  # read they could not make, so this refusal must not mention placeholders at
  # all - not as the diagnosis and not as the way through.
  assert_no_grep 'placeholder' "$case_dir/stderr" \
    "unreadable-title: refusal called an unread title a placeholder"
  assert_grep 'rate limit' "$case_dir/stderr" \
    "unreadable-title: refusal did not admit a transient cause"
  assert_grep 'allow-unreadable-title' "$case_dir/stderr" \
    "unreadable-title: refusal did not name its own way through"
  # Retried, but bounded: a retry loop with no ceiling is a hang, not a fix.
  [ "$(cat "$case_dir/gh-title-attempts")" = 3 ] \
    || fail "unreadable-title: the title read was not retried exactly 3 times"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "unreadable-title: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses when it cannot read the title instead of assuming one"
}

test_transient_read_failure_retries_then_merges() {
  local case_dir
  case_dir=$(make_case transient-title-read)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  : > "$case_dir/gh-axi.log"

  # A rate limit or a network blip must not become a refusal on the first try.
  export FM_TEST_GH_TITLE_FAIL_COUNT=2
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/46 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "transient-title-read: a read that succeeded on a later attempt did not merge"
  unset FM_TEST_GH_TITLE_FAIL_COUNT

  [ "$(cat "$case_dir/gh-title-attempts")" = 3 ] \
    || fail "transient-title-read: the failing reads were not actually retried"
  grep -qxF 'pr merge 46 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "transient-title-read: a title read on the third attempt did not merge like a first-attempt read"
  pass "fm-pr-merge retries a transient title read and merges normally once it succeeds"
}

test_unreadable_override_lands_unread_title_only() {
  local case_dir rc
  case_dir=$(make_case unreadable-title-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4040404040404040404040404040404040404040
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE_FAIL=1
  run_pr_merge "$case_dir" --allow-unreadable-title task-x1 \
    https://github.com/example/repo/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unreadable-title-override: proceeding unread deliberately did not merge"
  unset FM_TEST_GH_TITLE_FAIL

  # This path's own option, which must never reach the forge CLI.
  grep -qxF 'pr merge 47 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "unreadable-title-override: the override leaked into the gh-axi merge arguments"
  assert_grep 'pr=https://github.com/example/repo/pull/47' "$case_dir/state/task-x1.meta" \
    "unreadable-title-override: an overridden merge did not record pr="

  # It says only "I did not read the title", so it must not land a title that
  # WAS read and IS the placeholder.
  case_dir=$(make_case unreadable-override-vs-placeholder)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5050505050505050505050505050505050505050
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE='chore: update pull request'
  set +e
  run_pr_merge "$case_dir" --allow-unreadable-title task-x1 \
    https://github.com/example/repo/pull/48 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE

  expect_code 1 "$rc" "unreadable-override-vs-placeholder: --allow-unreadable-title landed a read placeholder"
  assert_grep 'merge commit' "$case_dir/stderr" \
    "unreadable-override-vs-placeholder: the refusal was not the placeholder one"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "unreadable-override-vs-placeholder: gh-axi pr merge was invoked"
  pass "fm-pr-merge's unread-title override lands only a title it could not read"
}

test_placeholder_override_does_not_pass_an_unread_title() {
  local case_dir rc
  case_dir=$(make_case placeholder-override-vs-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE_FAIL=1
  set +e
  run_pr_merge "$case_dir" --allow-placeholder-title task-x1 \
    https://github.com/example/repo/pull/49 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE_FAIL

  expect_code 1 "$rc" "placeholder-override-vs-unreadable: --allow-placeholder-title passed a title nobody read"
  assert_grep 'could not read the title' "$case_dir/stderr" \
    "placeholder-override-vs-unreadable: the refusal was not the unread-title one"
  assert_no_grep 'pr=https://github.com/example/repo/pull/49' "$case_dir/state/task-x1.meta" \
    "placeholder-override-vs-unreadable: PR URL was recorded despite the refusal"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "placeholder-override-vs-unreadable: gh-axi pr merge was invoked"
  pass "fm-pr-merge's placeholder override never doubles as a way past an unread title"
}

test_no_local_task_lands_and_says_it_recorded_nothing() {
  local case_dir
  # make_case leaves an unrelated task in state, so this also proves the
  # ownership check does not fire on a task that simply exists.
  case_dir=$(make_case no-local-task)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7070707070707070707070707070707070707070
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" --no-local-task https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-local-task: a PR with no local task did not land"

  # Every merge argument is exactly what the task-owned path produces, and this
  # path's own flag never reaches the forge CLI.
  grep -qxF 'pr merge 51 --repo example/repo --merge --delete-branch' "$case_dir/gh-axi.log" \
    || fail "no-local-task: the merge did not run exactly as the task-owned merge does"
  # Nothing recorded, nothing armed - there is no task here to record against.
  assert_no_grep 'pr=https://github.com/example/repo/pull/51' "$case_dir/state/task-x1.meta" \
    "no-local-task: an unrelated task's meta was written"
  [ -z "$(find "$case_dir/state" -name '*.check.sh' -print -quit)" ] \
    || fail "no-local-task: a merge with no task armed a merge poll"
  # And it is never a silent success: a later reader must be able to tell this
  # run from one that recorded.
  assert_grep 'no local task' "$case_dir/stdout" \
    "no-local-task: the merge did not say it had no local task"
  assert_grep 'no pr= and no pr_head= were recorded' "$case_dir/stdout" \
    "no-local-task: the merge did not say what it left unrecorded"
  assert_grep 'no merge watch was armed' "$case_dir/stdout" \
    "no-local-task: the merge did not say it armed no watch"
  pass "fm-pr-merge lands a PR with no local task and says plainly that it recorded nothing"
}

test_no_local_task_keeps_the_other_guards() {
  local case_dir rc
  case_dir=$(make_case no-local-task-placeholder)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8080808080808080808080808080808080808080
  : > "$case_dir/gh-axi.log"

  export FM_TEST_GH_TITLE='chore: update pull request'
  set +e
  run_pr_merge "$case_dir" --no-local-task https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_TITLE

  expect_code 1 "$rc" "no-local-task-placeholder: the placeholder-title guard stopped applying"
  assert_grep 'merge commit' "$case_dir/stderr" \
    "no-local-task-placeholder: the refusal was not the placeholder one"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-local-task-placeholder: gh-axi pr merge was invoked"
  pass "fm-pr-merge keeps its other guards on the no-local-task path"
}

test_no_local_task_refuses_a_pr_a_local_task_owns() {
  local case_dir rc
  case_dir=$(make_case no-local-task-owned)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9090909090909090909090909090909090909090
  : > "$case_dir/gh-axi.log"
  # The ordinary state of an owned task: firstmate records the PR URL when the
  # PR is first reported, long before anyone merges it.
  printf 'pr=%s\n' 'https://github.com/example/repo/pull/53' >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" --no-local-task https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-local-task-owned: --no-local-task landed a PR a local task owns"
  assert_grep 'already recorded by task' "$case_dir/stderr" \
    "no-local-task-owned: refusal did not say a local task owns the PR"
  assert_grep 'task-x1' "$case_dir/stderr" \
    "no-local-task-owned: refusal did not name the owning task"
  assert_grep 'fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/53' "$case_dir/stderr" \
    "no-local-task-owned: refusal did not name the ordinary merge as the remedy"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-local-task-owned: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses --no-local-task for a PR a local task has recorded"
}

test_no_local_task_refuses_a_stray_task_id() {
  local case_dir rc
  case_dir=$(make_case no-local-task-stray-id)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
  : > "$case_dir/gh-axi.log"

  # A task id where the URL belongs: the URL parse refuses it outright.
  set +e
  run_pr_merge "$case_dir" --no-local-task task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "no-local-task-stray-id: a task id in the URL position was accepted"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-local-task-stray-id: gh-axi pr merge was invoked"

  # And a trailing argument with no -- separator, which would otherwise be
  # forwarded to the forge as a merge flag rather than questioned.
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" --no-local-task https://github.com/example/repo/pull/54 task-x1 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "no-local-task-stray-id: a trailing argument was not questioned"
  assert_grep 'takes only the PR URL' "$case_dir/stderr" \
    "no-local-task-stray-id: refusal did not explain the argument shape"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "no-local-task-stray-id: a stray argument reached the forge CLI"

  # Deliberate extra merge arguments still work, introduced by --.
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" --no-local-task https://github.com/example/repo/pull/54 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-local-task-stray-id: extra merge args after -- did not merge"
  grep -qxF 'pr merge 54 --repo example/repo --delete-branch --squash' "$case_dir/gh-axi.log" \
    || fail "no-local-task-stray-id: extra merge args after -- were not forwarded"
  pass "fm-pr-merge's no-local-task path takes only the PR URL, and extra merge args only after --"
}

test_recording_failure_still_refuses_for_a_task_that_exists() {
  local case_dir rc
  case_dir=$(make_case recording-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0
  : > "$case_dir/gh-axi.log"
  # A second hard link to the meta: fm-pr-merge's own file check passes, and
  # fm-pr-check.sh refuses to record into a file with more than one name. That
  # is a task that exists whose recording fails, which is exactly the case the
  # requirement was built for.
  ln "$case_dir/state/task-x1.meta" "$case_dir/second-name.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "recording-fails: a task whose recording failed was merged anyway"
  assert_no_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "recording-fails: pr= was recorded despite the failure"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "recording-fails: gh-axi pr merge was invoked without a recorded pr="
  pass "fm-pr-merge still refuses to merge a task whose PR recording failed"
}

# ---------------------------------------------------------------------------
# The self-hosted forge.
#
# Every case below drives bin/fm-pr-merge.sh against a recording forgejo-axi
# stand-in, so what is proven here is what this path decides and what argv it
# builds. What that argv then does to a forge is proven separately, by running
# the real client against a Forgejo-shaped server; docs/forgejo-merge-helper.md
# carries that run and names the seam between the two.
#
# jq is required rather than skipped around, because the merge path itself
# requires it on this forge: a case that quietly skipped would leave the whole
# forge path unexercised while the suite still reported green.
require_jq_for_forge() {
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required to exercise the Forgejo merge path; install jq and re-run"
}

FORGEJO_HEAD_A=aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11
FORGEJO_HEAD_B=bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22

# A case whose home names this fleet's Forgejo instance, so bin/fm-pr-lib.sh
# resolves an address on it. A home that names none refuses every Forgejo
# address, which is its own case below.
make_forgejo_case() {
  local name=$1 case_dir
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/home/config" "$case_dir/wt"
  printf '%s\n' forge.example > "$case_dir/home/config/forgejo-host"
  printf '%s\n' "$case_dir"
}

# The forge client stand-in. It answers the one read this path makes and the one
# merge it performs, and it enforces the head the real client enforces, so a
# head that moved between the two is refused here as it is there.
#
# Knobs, each of which exists to cause one condition a guard is supposed to
# catch: FM_TEST_FORGEJO_TITLE the title read back; FM_TEST_FORGEJO_NO_TITLE the
# forge omitting it; FM_TEST_FORGEJO_NO_HEAD the forge omitting the head;
# FM_TEST_FORGEJO_VIEW_FAIL the read failing outright;
# FM_TEST_FORGEJO_HEAD_AT_MERGE the head having moved by merge time;
# FM_TEST_FORGEJO_PROOF_MERGED and FM_TEST_FORGEJO_PROOF_HEAD a call that exits
# zero while its own merged proof does not say the work was done.
add_forgejo_mock() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/forgejo-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_FORGEJO_LOG"
head='$head'
case "\${1:-} \${2:-}" in
  "pr view")
    [ "\${FM_TEST_FORGEJO_VIEW_FAIL:-0}" = 0 ] || exit 1
    fields=
    if [ "\${FM_TEST_FORGEJO_NO_TITLE:-0}" = 0 ]; then
      fields="\"title\":\"\${FM_TEST_FORGEJO_TITLE-fix(merge): teach the helper this forge}\""
    fi
    if [ "\${FM_TEST_FORGEJO_NO_HEAD:-0}" = 0 ]; then
      [ -z "\$fields" ] || fields="\$fields,"
      fields="\$fields\"head_sha\":\"\$head\""
    fi
    printf '{"pull_request":{%s}}\n' "\$fields"
    exit 0
    ;;
  "pr merge")
    expected=
    prev=
    for arg in "\$@"; do
      [ "\$prev" != --expected-head ] || expected=\$arg
      prev=\$arg
    done
    actual=\${FM_TEST_FORGEJO_HEAD_AT_MERGE:-\$head}
    if [ "\$expected" != "\$actual" ]; then
      # On stdout, where the real client answers in both directions, so this
      # case proves the merge path puts a captured refusal back where a caller
      # can see it rather than swallowing it with the proof it was reading for.
      printf '{"error":"Pull request head changed","code":"HEAD_CHANGED"}\n'
      exit 1
    fi
    printf '{"proof":{"merged":%s,"number":7,"head_sha":"%s","merge_commit_sha":"cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33"}}\n' \
      "\${FM_TEST_FORGEJO_PROOF_MERGED:-true}" "\${FM_TEST_FORGEJO_PROOF_HEAD:-\$actual}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/forgejo-axi"
}

# Errexit is on for most of this file, so every call below is wrapped the way
# the cases above wrap theirs: a refusal is the outcome under test, not a fault.
run_forgejo_merge() {
  local case_dir=$1; shift
  FM_TEST_FORGEJO_LOG="$case_dir/forgejo-axi.log" \
    run_pr_merge "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

test_forgejo_merge_records_then_merges_the_head_it_read() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-merges)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/forgejo-axi.log"

  set +e
  run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-merges: merging on the configured instance should succeed"
  assert_grep 'pr=https://forge.example/team/tools/pulls/7' "$case_dir/state/task-x1.meta" \
    "forgejo-merges: pr= was not recorded the way it is for the other forge"
  assert_grep "pr_head=$FORGEJO_HEAD_A" "$case_dir/state/task-x1.meta" \
    "forgejo-merges: pr_head= was not recorded from the head this merge was gated on"
  grep -qxF "pr merge 7 --repo team/tools --base-url https://forge.example --expected-head $FORGEJO_HEAD_A --method merge --json" \
    "$case_dir/forgejo-axi.log" \
    || fail "forgejo-merges: the merge did not name the project, the instance, the head, and a real merge commit"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "forgejo-merges: a pull request on the self-hosted forge reached the GitHub client"

  # The two guarantees this forge does not give are stated by the run itself.
  assert_grep 'no merge watch was armed' "$case_dir/stdout" \
    "forgejo-merges: the absent merge watch was not reported"
  assert_grep 'deletes no branch' "$case_dir/stdout" \
    "forgejo-merges: the branch that is not deleted was not reported"
  [ ! -e "$case_dir/state/task-x1.check.sh" ] \
    || fail "forgejo-merges: a watch was armed for a forge nothing can watch"
  [ ! -e "$case_dir/state/task-x1.pr-poll" ] \
    || fail "forgejo-merges: a poll sidecar was left for a forge nothing can watch"
  assert_grep "merged: PR 7 in team/tools on forge.example" "$case_dir/stdout" \
    "forgejo-merges: the merge did not report what it merged"
  pass "fm-pr-merge merges on the self-hosted forge, records the same metadata, and reports both absent guarantees"
}

test_forgejo_merge_refuses_a_head_that_moved() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-head-moved)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_HEAD_AT_MERGE=$FORGEJO_HEAD_B \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "forgejo-head-moved: a head that moved under the merge was merged anyway"
  # The client answers on stdout in both directions and this path captures it to
  # check the proof, so a refusal has to be put back where a caller reads it.
  assert_grep 'HEAD_CHANGED' "$case_dir/stderr" \
    "forgejo-head-moved: the refusal was captured and never shown"
  assert_no_grep 'merged: PR' "$case_dir/stdout" \
    "forgejo-head-moved: a refused merge still reported a merge"
  pass "fm-pr-merge refuses a Forgejo merge whose head moved rather than merging a different commit"
}

test_forgejo_merge_refuses_a_head_the_forge_did_not_supply() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-no-head)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_NO_HEAD=1 \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-no-head: a merge with no head to gate on was not refused"
  assert_grep 'could not read the head commit' "$case_dir/stderr" \
    "forgejo-no-head: the refusal did not name the missing head"
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
    "forgejo-no-head: the pull request was recorded before the refusal"
  assert_no_grep 'pr merge' "$case_dir/forgejo-axi.log" \
    "forgejo-no-head: a merge was attempted with no head to name"
  pass "fm-pr-merge refuses a Forgejo merge when the forge supplied no head, with no override"
}

test_forgejo_merge_refuses_an_unprovable_success() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-unproven)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_PROOF_MERGED=false \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-unproven: a merge whose own proof denies it was reported as done"
  assert_grep 'does not confirm it' "$case_dir/stderr" \
    "forgejo-unproven: the refusal did not say the proof failed to confirm the merge"
  assert_no_grep 'merged: PR' "$case_dir/stdout" \
    "forgejo-unproven: an unproven merge still printed a merge line"
  pass "fm-pr-merge refuses a Forgejo merge that exits zero while its own proof does not say the work was done"
}

test_forgejo_merge_refuses_a_proof_naming_another_head() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-proof-head)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_PROOF_HEAD=$FORGEJO_HEAD_B \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-proof-head: a proof naming another head was accepted"
  assert_grep "must name $FORGEJO_HEAD_A" "$case_dir/stderr" \
    "forgejo-proof-head: the refusal did not name the head that should have been merged"
  pass "fm-pr-merge refuses a Forgejo merged proof that names a head other than the one it merged"
}

test_forgejo_merge_refuses_branch_deletion_rather_than_emulating_it() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-delete-branch)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7 -- --delete-branch
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-delete-branch: --delete-branch was accepted on a forge that cannot do it"
  assert_grep 'cannot delete the head branch' "$case_dir/stderr" \
    "forgejo-delete-branch: the refusal did not say why"
  [ ! -s "$case_dir/forgejo-axi.log" ] \
    || fail "forgejo-delete-branch: the forge was reached before the argument was refused"
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
    "forgejo-delete-branch: state was recorded before the argument was refused"
  pass "fm-pr-merge refuses --delete-branch on the self-hosted forge instead of deleting a branch behind the merge"
}

test_forgejo_merge_accepts_keeping_the_branch_and_an_explicit_squash() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-squash)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7 \
    -- --squash --delete-branch=false
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-squash: an explicit squash keeping the branch was refused"
  grep -qxF "pr merge 7 --repo team/tools --base-url https://forge.example --expected-head $FORGEJO_HEAD_A --method squash --json" \
    "$case_dir/forgejo-axi.log" \
    || fail "forgejo-squash: --squash did not become this forge's own merge method"
  pass "fm-pr-merge translates --squash into this forge's merge method and honours keeping the branch"
}

test_forgejo_merge_refuses_a_flag_written_for_the_other_forge() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-foreign-flag)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7 -- --auto
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-foreign-flag: a GitHub-shaped flag was forwarded to another client"
  assert_grep 'is not a merge argument this path can send' "$case_dir/stderr" \
    "forgejo-foreign-flag: the refusal did not say the argument belongs to the other forge"
  [ ! -s "$case_dir/forgejo-axi.log" ] \
    || fail "forgejo-foreign-flag: the forge was reached with an argument it does not accept"
  pass "fm-pr-merge refuses an unknown merge argument on the self-hosted forge rather than forwarding it"
}

test_forgejo_merge_keeps_the_placeholder_title_guard() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-placeholder)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_TITLE='chore: update pull request' \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-placeholder: a placeholder title merged on this forge"
  assert_grep "which is the validation pipeline's" "$case_dir/stderr" \
    "forgejo-placeholder: the placeholder refusal did not fire"
  assert_grep 'forgejo-axi pr update --repo team/tools 7' "$case_dir/stderr" \
    "forgejo-placeholder: the remedy named the other forge's retitle command"
  assert_no_grep 'pr merge' "$case_dir/forgejo-axi.log" \
    "forgejo-placeholder: the merge ran despite the placeholder title"
  pass "fm-pr-merge keeps the placeholder-title guard on the self-hosted forge, with that forge's own remedy"
}

test_forgejo_merge_refuses_an_unreadable_title_distinctly() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-unreadable)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  set +e
  FM_TEST_FORGEJO_VIEW_FAIL=1 \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-unreadable: a title nobody read was merged"
  assert_grep 'could not read the title' "$case_dir/stderr" \
    "forgejo-unreadable: the refusal did not say the title was unread"
  assert_no_grep 'pr merge' "$case_dir/forgejo-axi.log" \
    "forgejo-unreadable: the merge ran with no title read"
  pass "fm-pr-merge refuses an unreadable Forgejo title distinctly rather than calling it a placeholder"
}

test_forgejo_merge_names_a_credential_that_will_not_be_read() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-ignored-token)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"

  # A bare token and nothing host-scoped, with a HOME that holds no hosts file:
  # the one arrangement where a credential is set and still not read.
  set +e
  HOME="$case_dir/home" FORGEJO_TOKEN=not-a-real-token \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-ignored-token: the note should not stop the merge"
  assert_grep 'FORGEJO_TOKEN is set' "$case_dir/stderr" \
    "forgejo-ignored-token: a credential that will not be read went unmentioned"
  assert_no_grep 'not-a-real-token' "$case_dir/stderr" \
    "forgejo-ignored-token: the note printed the credential itself"
  assert_no_grep 'not-a-real-token' "$case_dir/stdout" \
    "forgejo-ignored-token: the credential reached standard output"

  # And it stays quiet when a host-scoped credential is what is set, because a
  # note that fires on the ordinary arrangement is a note nobody reads.
  set +e
  HOME="$case_dir/home" FORGEJO_TOKEN=not-a-real-token \
    FORGEJO_TOKEN_FORGE_2E_EXAMPLE=not-a-real-token \
    run_forgejo_merge "$case_dir" task-x1 https://forge.example/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-ignored-token: a host-scoped credential should merge"
  assert_no_grep 'FORGEJO_TOKEN is set' "$case_dir/stderr" \
    "forgejo-ignored-token: the note fired where the credential will be read"
  pass "fm-pr-merge says when a credential that is set will not be read, and never prints it"
}

test_forgejo_merge_needs_the_forge_client() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-no-client)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  # Deliberately no forge client anywhere this run can see it.
  rm -f "$case_dir/fakebin/forgejo-axi"

  FM_TEST_BASE_PATH_ONLY=1 \
    PATH="$case_dir/fakebin:/usr/bin:/bin" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    "$PR_MERGE" task-x1 https://forge.example/team/tools/pulls/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" && rc=0 || rc=$?

  expect_code 1 "$rc" "forgejo-no-client: the merge proceeded with no client to reach the forge"
  assert_grep 'needs forgejo-axi on PATH' "$case_dir/stderr" \
    "forgejo-no-client: the refusal did not name the missing client"
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
    "forgejo-no-client: state was recorded before the client was found missing"
  pass "fm-pr-merge refuses a Forgejo merge with no forge client, before recording anything"
}

test_forgejo_address_on_another_instance_is_refused() {
  local case_dir rc
  require_jq_for_forge
  case_dir=$(make_forgejo_case forgejo-other-instance)
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  add_forgejo_mock "$case_dir" "$FORGEJO_HEAD_A"
  : > "$case_dir/forgejo-axi.log"
  : > "$case_dir/gh-axi.log"

  # The exact shape of a pull request on this forge, on a host this home does
  # not run. A merge sent there is a merge on somebody else's server.
  set +e
  run_forgejo_merge "$case_dir" task-x1 https://forge.example.evil/team/tools/pulls/7
  rc=$?
  set -e

  expect_code 2 "$rc" "forgejo-other-instance: an address on another instance was accepted"
  [ ! -s "$case_dir/forgejo-axi.log" ] \
    || fail "forgejo-other-instance: the forge client was reached for another instance"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "forgejo-other-instance: the GitHub client was reached for another instance"
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
    "forgejo-other-instance: an address on another instance was recorded"
  pass "fm-pr-merge refuses a Forgejo-shaped address on an instance this home does not run"
}

test_no_method_defaults_to_merge_commit_after_recording
test_merge_failure_propagates_after_recording
test_placeholder_title_refuses_before_recording
test_placeholder_match_is_exact_not_a_heuristic
test_placeholder_match_ignores_case_and_surrounding_space
test_override_lands_placeholder_title_deliberately
test_unreadable_title_refuses_rather_than_guessing
test_transient_read_failure_retries_then_merges
test_unreadable_override_lands_unread_title_only
test_placeholder_override_does_not_pass_an_unread_title
test_default_deletes_merged_head_branch
test_caller_delete_choice_not_overridden
test_failed_merge_deletes_nothing
test_explicit_squash_and_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_no_local_task_lands_and_says_it_recorded_nothing
test_no_local_task_keeps_the_other_guards
test_no_local_task_refuses_a_pr_a_local_task_owns
test_no_local_task_refuses_a_stray_task_id
test_recording_failure_still_refuses_for_a_task_that_exists
test_forgejo_merge_records_then_merges_the_head_it_read
test_forgejo_merge_refuses_a_head_that_moved
test_forgejo_merge_refuses_a_head_the_forge_did_not_supply
test_forgejo_merge_refuses_an_unprovable_success
test_forgejo_merge_refuses_a_proof_naming_another_head
test_forgejo_merge_refuses_branch_deletion_rather_than_emulating_it
test_forgejo_merge_accepts_keeping_the_branch_and_an_explicit_squash
test_forgejo_merge_refuses_a_flag_written_for_the_other_forge
test_forgejo_merge_keeps_the_placeholder_title_guard
test_forgejo_merge_refuses_an_unreadable_title_distinctly
test_forgejo_merge_names_a_credential_that_will_not_be_read
test_forgejo_merge_needs_the_forge_client
test_forgejo_address_on_another_instance_is_refused
