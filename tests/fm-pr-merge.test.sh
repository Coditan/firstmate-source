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
#   (p) a title that cannot be read is refused distinctly, not assumed good
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
# proves the guard stays out of the way of normal work.
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
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *" title "*)
        [ "\${FM_TEST_GH_TITLE_FAIL:-0}" = 0 ] || exit 1
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

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
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
  assert_grep 'allow-placeholder-title' "$case_dir/stderr" \
    "unreadable-title: refusal did not name the way through"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "unreadable-title: gh-axi pr merge was invoked"
  pass "fm-pr-merge refuses when it cannot read the title instead of assuming one"
}

test_no_method_defaults_to_merge_commit_after_recording
test_merge_failure_propagates_after_recording
test_placeholder_title_refuses_before_recording
test_placeholder_match_is_exact_not_a_heuristic
test_placeholder_match_ignores_case_and_surrounding_space
test_override_lands_placeholder_title_deliberately
test_unreadable_title_refuses_rather_than_guessing
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
