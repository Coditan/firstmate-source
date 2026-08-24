#!/usr/bin/env bash
# tests/fm-upstream-distance.test.sh - behavior tests for the on-demand
# upstream-distance reading.
#
# Coverage:
#   - the defect the retired fork-sync check carried, reproduced against its own
#     mechanism: `git diff --quiet <fork> <upstream> -- <paths>` IS quiet when a
#     path is on neither side, and this reading nonetheless never calls that
#     change absorbed
#   - absorbed rests only on patch equivalence; tip agreement earns `converged`
#     and never `absorbed`
#   - `converged` cannot be reached by absence: it requires the path to be
#     present on both sides before their content is compared
#   - the fourth verdict, `superseded`, covers the shape where none of the other
#     three is honest, including a change that touches no path at all
#   - the counts are of the whole range even when the printed list is windowed,
#     and the written report is never windowed
#   - both compared repositories are named in the reading and in the report
#   - a reading that cannot be taken exits 3 and says so, never 0
#   - NOTHING this adds speaks unless it is run: the session-start digest gains
#     no line from it, and no armed or reporting surface references it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISTANCE="$ROOT/bin/fm-upstream-distance.sh"
fm_test_tmproot TMP_ROOT fm-upstream-distance-tests
fm_git_identity fmtest fmtest@example.invalid

commit() {
  local repo=$1 msg=$2
  git -C "$repo" add -A
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "$msg"
}

write() {
  local repo=$1 path=$2 content=$3
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
}

# world <name>: one repository holding both sides, `main` as the fork side and
# `upstream` as the upstream side, sharing a base commit. Echoes the repo path.
#
# Both sides live in ONE repository on purpose: it keeps every test network-free
# while still exercising the real comparison, which is the same shape
# FM_UPSTREAM_DISTANCE_COMPARE_REPO exists for.
world() {
  local name=$1 repo
  repo="$TMP_ROOT/$name"
  git init -q -b main "$repo"
  write "$repo" bin/base.sh base
  commit "$repo" base
  printf '%s\n' "$repo"
}

# read_distance <repo> [args...]: take the reading over that repository's two
# branches with no network and a fixed timestamp.
read_distance() {
  local repo=$1 fork upstream
  shift
  fork=$(git -C "$repo" rev-parse main)
  upstream=$(git -C "$repo" rev-parse upstream)
  FM_UPSTREAM_DISTANCE_COMPARE_REPO="$repo" \
    FM_UPSTREAM_DISTANCE_FORK_HEAD="$fork" \
    FM_UPSTREAM_DISTANCE_UPSTREAM_HEAD="$upstream" \
    FM_UPSTREAM_DISTANCE_NOW=2026-08-24T00:00Z \
    "$DISTANCE" "$@"
}

# verdict_of <output> <subject>: the verdict the reading printed for the change
# with that commit subject.
verdict_of() {
  printf '%s\n' "$1" | awk -v s="$2" '$0 ~ s { print $1; exit }'
}

# --- the defect this reading replaces ---------------------------------------

test_a_path_absent_from_both_sides_is_never_absorbed() {
  local repo out shortcut
  repo=$(world absent-both)

  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/gone.sh gone
  commit "$repo" "upstream-adds-a-path-neither-side-keeps"
  git -C "$repo" rm -q bin/gone.sh
  commit "$repo" "upstream-removes-it-again"
  write "$repo" bin/live.sh live
  commit "$repo" "upstream-adds-something-live"
  git -C "$repo" checkout -q main

  # The retired check's own mechanism, run here rather than described: it asked
  # `git diff --quiet <fork> <upstream> -- <paths the commit touched>` and
  # called the change absorbed when that was quiet. It IS quiet for a path that
  # is on neither side, which is what mislabelled 16 of the 17 patches it
  # claimed (docs/fork-upstream-merge-assessment.md).
  if git -C "$repo" diff --quiet main upstream -- bin/gone.sh; then
    shortcut=quiet
  else
    shortcut=noisy
  fi
  [ "$shortcut" = quiet ] ||
    fail "the retired check's shortcut was expected to be quiet for a path absent from both sides; it was $shortcut"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-adds-a-path-neither-side-keeps)" = superseded ] ||
    fail "a change whose path is absent from both sides was not called superseded: $out"
  assert_not_contains "$(printf '%s\n' "$out" | grep upstream-adds-a-path-neither-side-keeps)" absorbed \
    "a change whose path is absent from both sides was reported as absorbed"
  pass "a change whose path is absent from both sides is superseded, never absorbed"
}

test_a_change_that_touches_no_path_is_stated_rather_than_assumed() {
  local repo out
  repo=$(world empty-change)
  git -C "$repo" checkout -q -b upstream
  git -C "$repo" -c user.name=t -c user.email=t@e.invalid \
    commit -q --allow-empty -m "upstream-empty-change"
  git -C "$repo" checkout -q main

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-empty-change)" = superseded ] ||
    fail "a change touching no path at all was not called superseded: $out"
  pass "a change that touches no path is called superseded by name, not by vacuous truth"
}

# --- what each verdict rests on ---------------------------------------------

test_absorbed_rests_only_on_patch_equivalence() {
  local repo out
  repo=$(world absorbed)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/shared.sh shared
  commit "$repo" "upstream-adds-shared"
  git -C "$repo" checkout -q main
  write "$repo" bin/shared.sh shared
  commit "$repo" "fork-adds-the-identical-change"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-adds-shared)" = absorbed ] ||
    fail "a patch-equivalent upstream change was not called absorbed: $out"
  pass "absorbed is given to a change this fork already carries as an equivalent patch"
}

test_tip_agreement_is_converged_and_needs_presence_on_both_sides() {
  local repo out
  repo=$(world converged)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/shared.sh final
  commit "$repo" "upstream-arrives-at-the-shared-content"
  git -C "$repo" checkout -q main
  # The fork reaches the same content by a different route, so no commit here is
  # patch-equivalent to upstream's; only the two tips agree.
  write "$repo" bin/shared.sh first
  commit "$repo" "fork-adds-it-differently"
  write "$repo" bin/shared.sh final
  commit "$repo" "fork-arrives-at-the-same-content"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-arrives-at-the-shared-content)" = converged ] ||
    fail "a change whose paths agree on both tips was not called converged: $out"
  assert_contains "$out" 'evidence, not proof' \
    "the converged verdict did not say that tip agreement is evidence rather than proof"
  pass "tip agreement earns converged, and says it is evidence rather than proof"
}

test_gitlinks_are_present_paths_and_compare_by_object_id() {
  local repo target_a target_b out
  repo=$(world gitlinks-converged)
  target_a=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b upstream
  git -C "$repo" update-index --add --cacheinfo "160000,$target_a,modules/dependency"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "upstream-adds-gitlink"
  git -C "$repo" checkout -q main
  write "$repo" bin/fork-route.sh route
  commit "$repo" "fork-takes-another-route"
  target_b=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-index --add --cacheinfo "160000,$target_b,modules/dependency"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "fork-adds-different-gitlink"
  git -C "$repo" update-index --cacheinfo "160000,$target_a,modules/dependency"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "fork-converges-gitlink"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-adds-gitlink)" = converged ] ||
    fail "an identical gitlink on both tips was not called converged: $out"

  repo=$(world gitlinks-differ)
  target_a=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b upstream
  git -C "$repo" update-index --add --cacheinfo "160000,$target_a,modules/dependency"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "upstream-adds-live-gitlink"
  git -C "$repo" checkout -q main
  write "$repo" bin/fork-route.sh route
  commit "$repo" "fork-creates-another-target"
  target_b=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-index --add --cacheinfo "160000,$target_b,modules/dependency"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m "fork-adds-divergent-gitlink"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-adds-live-gitlink)" = needs-review ] ||
    fail "a surviving divergent gitlink was not called needs-review: $out"
  pass "gitlinks count as present paths and compare by object id"
}

test_a_live_upstream_change_this_fork_lacks_needs_review() {
  local repo out
  repo=$(world needs-review)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/capability.sh capability
  commit "$repo" "upstream-adds-a-capability"
  git -C "$repo" checkout -q main
  write "$repo" bin/forkonly.sh forkonly
  commit "$repo" "fork-only-patch"

  out=$(read_distance "$repo" --no-write) || true
  [ "$(verdict_of "$out" upstream-adds-a-capability)" = needs-review ] ||
    fail "a live upstream change this fork lacks was not called needs-review: $out"
  pass "a change still live upstream and absent here needs review"
}

# --- counted, not sampled ----------------------------------------------------

test_counts_are_of_the_whole_range_even_when_the_list_is_windowed() {
  local repo out report i
  repo=$(world windowed)
  git -C "$repo" checkout -q -b upstream
  for i in 1 2 3 4 5; do
    write "$repo" "bin/up$i.sh" "up$i"
    commit "$repo" "upstream-change-$i"
  done
  git -C "$repo" checkout -q main
  report="$TMP_ROOT/windowed-report.md"

  out=$(read_distance "$repo" --limit 2 --out "$report") || true
  assert_contains "$out" '5 upstream-only changes' \
    "the windowed reading did not count the whole range"
  assert_contains "$out" 'verdicts over all 5' \
    "the verdict counts were not stated as covering the whole range"
  assert_contains "$out" 'showing 2 of 5' \
    "the windowed reading did not say how much of the range it was showing"
  [ "$(printf '%s\n' "$out" | grep -c '^  needs-review ')" = 2 ] ||
    fail "the window did not bound the printed list: $out"
  for i in 1 2 3 4 5; do
    assert_grep "upstream-change-$i" "$report" "the report omitted upstream-change-$i"
  done
  pass "the counts are of the whole range and the report lists every change"
}

# --- naming the comparison ---------------------------------------------------

test_the_reading_names_both_repositories_it_compared() {
  local repo out report
  repo=$(world named)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/up.sh up
  commit "$repo" "upstream-change"
  git -C "$repo" checkout -q main
  report="$TMP_ROOT/named-report.md"

  out=$(read_distance "$repo" --fork "fork-side-url" --upstream "upstream-side-url" --out "$report") || true
  assert_contains "$out" 'fork fork-side-url' "the reading did not name the fork side"
  assert_contains "$out" 'upstream upstream-side-url' "the reading did not name the upstream side"
  assert_grep 'fork-side-url' "$report" "the report did not name the fork side"
  assert_grep 'upstream-side-url' "$report" "the report did not name the upstream side"
  pass "every reading names which two repositories produced it"
}

# --- an instrument that cannot read says so ----------------------------------

test_a_reading_that_cannot_be_taken_is_never_reported_as_current() {
  local repo out status other
  repo=$(world unmeasurable)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/up.sh up
  commit "$repo" "upstream-change"
  git -C "$repo" checkout -q main

  status=0
  out=$(FM_UPSTREAM_DISTANCE_COMPARE_REPO="$repo" \
    FM_UPSTREAM_DISTANCE_FORK_HEAD=$(git -C "$repo" rev-parse main) \
    FM_UPSTREAM_DISTANCE_UPSTREAM_HEAD=0000000000000000000000000000000000000000 \
    "$DISTANCE" --no-write 2>&1) || status=$?
  [ "$status" = 3 ] || fail "an unreadable upstream side exited $status instead of 3"
  assert_contains "$out" 'UNMEASURABLE:' "an unreadable upstream side did not say so"

  # Two histories with nothing in common must not read as a distance of zero.
  other="$TMP_ROOT/unrelated"
  git init -q -b main "$other"
  write "$other" bin/other.sh other
  commit "$other" unrelated
  git -C "$repo" fetch -q --no-tags "$other" main:refs/heads/unrelated
  status=0
  out=$(FM_UPSTREAM_DISTANCE_COMPARE_REPO="$repo" \
    FM_UPSTREAM_DISTANCE_FORK_HEAD=$(git -C "$repo" rev-parse main) \
    FM_UPSTREAM_DISTANCE_UPSTREAM_HEAD=$(git -C "$repo" rev-parse refs/heads/unrelated) \
    "$DISTANCE" --no-write 2>&1) || status=$?
  [ "$status" = 3 ] || fail "two unrelated histories exited $status instead of 3"
  assert_contains "$out" 'share no history' "two unrelated histories were not reported as such"
  pass "a reading that cannot be taken exits 3 and says so, never 0"
}

test_failed_git_evidence_never_becomes_a_verdict() {
  local repo shim real_git command out status
  repo=$(world failed-evidence)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/up.sh up
  commit "$repo" "upstream-change"
  git -C "$repo" checkout -q main
  shim="$TMP_ROOT/git-shim"
  mkdir -p "$shim"
  real_git=$(command -v git)
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${3:-}" = "$FAIL_GIT_COMMAND" ]; then' \
    '  printf "injected %s failure\n" "$FAIL_GIT_COMMAND" >&2' \
    '  exit 71' \
    'fi' \
    'exec "$REAL_GIT" "$@"' > "$shim/git"
  chmod +x "$shim/git"

  for command in ls-tree cherry diff-tree log; do
    status=0
    out=$(REAL_GIT="$real_git" FAIL_GIT_COMMAND="$command" PATH="$shim:$PATH" \
      read_distance "$repo" --no-write 2>&1) || status=$?
    [ "$status" = 3 ] || fail "a failed git $command exited $status instead of 3: $out"
    assert_contains "$out" 'UNMEASURABLE:' "a failed git $command did not refuse the reading"
    assert_contains "$out" "injected $command failure" "a failed git $command hid git's reason"
  done
  pass "failed Git evidence exits unmeasurable instead of producing a verdict"
}

test_exit_status_separates_outstanding_work_from_nothing_outstanding() {
  local repo status
  repo=$(world statuses)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/up.sh up
  commit "$repo" "upstream-change"
  git -C "$repo" checkout -q main
  # A fork-only commit first, so the cherry-pick below lands on a different
  # parent and cannot reproduce upstream's commit object byte for byte.
  write "$repo" bin/forkonly.sh forkonly
  commit "$repo" "fork-only-patch"

  status=0
  read_distance "$repo" --no-write >/dev/null || status=$?
  [ "$status" = 1 ] || fail "an outstanding change exited $status instead of 1"

  # The fork takes the same patch, so nothing is outstanding any more.
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    cherry-pick "$(git -C "$repo" rev-parse upstream)" >/dev/null ||
    fail "the fixture could not take the upstream patch"
  status=0
  read_distance "$repo" --no-write >/dev/null || status=$?
  [ "$status" = 0 ] || fail "a fully carried upstream exited $status instead of 0"
  pass "exit status separates outstanding changes from nothing outstanding"
}

# --- the silence requirement -------------------------------------------------

test_the_default_report_lands_where_a_later_reader_can_use_it() {
  local repo home out
  repo=$(world default-out)
  git -C "$repo" checkout -q -b upstream
  write "$repo" bin/up.sh up
  commit "$repo" "upstream-change"
  git -C "$repo" checkout -q main
  home="$TMP_ROOT/default-out-home"
  mkdir -p "$home"

  out=$(FM_HOME="$home" read_distance "$repo") || true
  assert_present "$home/data/upstream-distance.md" "the default report was not written under the home's data/"
  assert_grep 'upstream-change' "$home/data/upstream-distance.md" "the default report holds no changes"
  assert_contains "$out" "$home/data/upstream-distance.md" "the reading did not say where it wrote its report"
  pass "the report lands in the home's durable records by default"
}

test_startup_and_currency_surfaces_do_not_arm_or_report_this_reading() {
  local home bootstrap_out currency_out hit state_contract
  home="$TMP_ROOT/silence-home"
  mkdir -p "$home/state" "$home/config"

  bootstrap_out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_SKIP_WATCHER_SERVICE=1 \
    FM_CURRENCY_ROUND_DISABLE=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || true
  bootstrap_out=${bootstrap_out//"$TMP_ROOT"/[tmproot]}
  assert_not_contains "$bootstrap_out" 'upstream-distance' \
    "bootstrap emitted a line naming the on-demand reading"
  assert_not_contains "$bootstrap_out" 'UPSTREAM_DISTANCE:' \
    "bootstrap emitted a diagnostic for the on-demand reading"

  currency_out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CURRENCY_ROUND_TOOLS='' FM_CURRENCY_ROUND_TIMEOUT=1 \
    "$ROOT/bin/fm-currency-round.sh" --status 2>&1) || true
  currency_out=${currency_out//"$TMP_ROOT"/[tmproot]}
  assert_not_contains "$currency_out" 'upstream-distance' \
    "the currency round reported the on-demand reading"
  assert_not_contains "$currency_out" 'upstream distance' \
    "the currency round measured the on-demand reading"

  hit=$(find "$home/state" -type f -printf '%f\n' 2>/dev/null |
    grep 'upstream-distance\|UPSTREAM_DISTANCE' || true)
  [ -z "$hit" ] ||
    fail "startup or currency execution armed the on-demand reading: $hit"
  state_contract=$(find "$home/state" -type f -exec sed "s|$TMP_ROOT|[tmproot]|g" {} + 2>/dev/null || true)
  assert_not_contains "$state_contract" 'upstream-distance' \
    "registered watcher or schedule state names the on-demand reading"
  assert_not_contains "$state_contract" 'UPSTREAM_DISTANCE' \
    "registered watcher or schedule state contains a diagnostic for the on-demand reading"
  pass "startup and currency surfaces neither report nor arm the on-demand reading"
}

test_session_start_gains_no_line_from_a_written_report() {
  local w root home out
  w="$TMP_ROOT/session-start"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '# Upstream distance\n\nSENTINEL-UPSTREAM-DISTANCE-REPORT\n' \
    > "$home/data/upstream-distance.md"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-session-start.sh" 2>&1) || true
  # This suite's own temporary root is named after the subject under test, and
  # the digest echoes the home path, so that self-reference is removed before
  # the digest is searched for any mention the SCRIPT put there.
  out=${out//"$TMP_ROOT"/[tmproot]}
  assert_not_contains "$out" 'SENTINEL-UPSTREAM-DISTANCE-REPORT' \
    "the session-start digest read the on-demand report"
  assert_not_contains "$out" 'upstream-distance' \
    "the session-start digest gained a line naming the on-demand reading"
  pass "a written report adds no line to the session-start digest"
}

test_a_path_absent_from_both_sides_is_never_absorbed
test_a_change_that_touches_no_path_is_stated_rather_than_assumed
test_absorbed_rests_only_on_patch_equivalence
test_tip_agreement_is_converged_and_needs_presence_on_both_sides
test_gitlinks_are_present_paths_and_compare_by_object_id
test_a_live_upstream_change_this_fork_lacks_needs_review
test_counts_are_of_the_whole_range_even_when_the_list_is_windowed
test_the_reading_names_both_repositories_it_compared
test_a_reading_that_cannot_be_taken_is_never_reported_as_current
test_failed_git_evidence_never_becomes_a_verdict
test_exit_status_separates_outstanding_work_from_nothing_outstanding
test_the_default_report_lands_where_a_later_reader_can_use_it
test_startup_and_currency_surfaces_do_not_arm_or_report_this_reading
test_session_start_gains_no_line_from_a_written_report
