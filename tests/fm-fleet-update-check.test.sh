#!/usr/bin/env bash
# Network-free behavior tests for the three-hop currency check.
#
# The pin source is a local fixture repository handed to the check through
# FM_FLEET_UPDATE_COMPARE_REPO, so no test reaches the network and every count
# below is a number this suite constructed and can therefore assert exactly.
#
# The properties under test are the ones the 2026-08-17 incident earned: the
# three hops are never collapsed into one word, a reading that could not be
# taken reports UNMEASURABLE rather than CURRENT, and the distances are counted
# rather than sampled.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-fleet-update-check-tests
fm_git_identity

CHECK="$ROOT/bin/fm-fleet-update-check.sh"
SOURCE_REF=refs/heads/source

# A fixture standing in for the pin source: one commit per call to advance it,
# with merge-commit subjects for the ones that should count as merged pull
# requests. Echoes the repository path.
make_source() {
  local name=$1 repo
  repo="$TMP_ROOT/$name.git"
  fm_git_init_commit "$TMP_ROOT/$name"
  git -C "$TMP_ROOT/$name" branch -M source
  git clone -q --bare "$TMP_ROOT/$name" "$repo"
  git -C "$TMP_ROOT/$name" remote add origin "$repo"
  printf '%s\n' "$repo"
}

# Add <count> commits to the fixture's source branch, <prs> of them titled the
# way a forge titles a merge commit.
advance_source() {
  local work=$1 count=$2 prs=$3 i n subject
  # A monotonic sequence across every call on the same fixture, so a later call
  # never re-adds a path an earlier one already committed and silently produces
  # no commit at all.
  n=0
  [ -f "$work/.seq" ] && IFS= read -r n < "$work/.seq"
  for i in $(seq 1 "$count"); do
    n=$((n + 1))
    printf '%s\n' "$n" > "$work/file-$n"
    git -C "$work" add "file-$n"
    if [ "$i" -le "$prs" ]; then subject="Merge pull request #$n from fixture/branch"
    else subject="ordinary commit $n"; fi
    git -C "$work" commit -qm "$subject"
  done
  printf '%s\n' "$n" > "$work/.seq"
}

# A home carrying a firstmate.lock that pins <pin> on <source_url>. Echoes the
# home path. The home is a git repo so hop 3 has something to read.
make_home() {
  local name=$1 pin=$2 url=$3 home
  home="$TMP_ROOT/$name"
  fm_git_init_commit "$home"
  cat > "$home/firstmate.lock" <<LOCK
source_url=$url
source_ref=source
commit=$pin
importer_version=1
LOCK
  printf '%s\n' "$home"
}

run_check() {
  local home=$1 compare=$2
  shift 2
  FM_HOME="$home" FM_FLEET_UPDATE_COMPARE_REPO="$compare" \
    FM_FLEET_UPDATE_SOURCE_REF_NAME="$SOURCE_REF" \
    "$CHECK" "$@"
}

test_a_stale_pin_is_counted_not_sampled() {
  local src work pin home out status=0
  src=$(make_source stale)
  work="$TMP_ROOT/stale"
  advance_source "$work" 20 6
  git -C "$work" push -q origin source
  # The pin is the fixture's very first commit, so the expected distance is
  # exactly the 20 commits just added and exactly the 6 merge subjects among
  # them. A head -N would have reported whatever it truncated to.
  pin=$(git -C "$work" rev-list --max-parents=0 source)
  home=$(make_home stale-home "$pin" "$src")

  out=$(run_check "$home" "$src") || status=$?
  expect_code 1 "$status" "a vessel behind its own pin source must exit non-zero"
  assert_contains "$out" 'hop 1  released   pin age         BEHIND 20 commit(s), 6 merged PR(s)' \
    "the pin age must carry the counted distance and the counted merged PRs"
  assert_contains "$out" 'hop 2  pinned     vendored pin' "hop 2 must name the pin it measured"
  assert_contains "$out" 'hop 3  installed  own origin' "hop 3 must be reported separately"
  assert_contains "$out" "answers hop 3 ONLY" \
    "the report must close with the sentence that caused the incident"
  pass "a stale pin is reported with counted commits and counted merged PRs"
}

test_a_current_pin_reads_current() {
  local src work pin home out status=0
  src=$(make_source current)
  work="$TMP_ROOT/current"
  advance_source "$work" 3 1
  git -C "$work" push -q origin source
  pin=$(git -C "$work" rev-parse source)
  home=$(make_home current-home "$pin" "$src")

  out=$(run_check "$home" "$src" --pin-age) || status=$?
  expect_code 0 "$status" "--pin-age always exits 0 so the round can consume it"
  assert_contains "$out" 'ok|' "a pin naming the source head must read ok"
  assert_contains "$out" 'names the head of source' "the ok detail must name the ref it measured"
  pass "a pin naming the source head reads current"
}

test_a_pin_the_source_does_not_carry_is_unmeasurable_never_current() {
  local src home out status=0
  src=$(make_source missing)
  git -C "$TMP_ROOT/missing" push -q origin source
  # Forty hex characters that no fixture commit will ever be.
  home=$(make_home missing-home 0123456789012345678901234567890123456789 "$src")

  out=$(run_check "$home" "$src") || status=$?
  expect_code 1 "$status" "an unmeasurable pin age must exit non-zero"
  assert_contains "$out" 'pin age         UNMEASURABLE' \
    "a pin the source does not carry must read unmeasurable"
  assert_not_contains "$out" 'CURRENT' "an instrument that cannot read must never report current"
  assert_contains "$out" 'UNMEASURABLE is not an all-clear' \
    "the report must say what unmeasurable means"

  out=$(run_check "$home" "$src" --pin-age)
  assert_contains "$out" 'unmeasured|' "the round's reading must be unmeasured, never ok"
  pass "a pin the source no longer carries is unmeasurable, never current"
}

test_an_unreachable_pin_source_is_unmeasurable_never_current() {
  local home out status=0
  # No FM_FLEET_UPDATE_COMPARE_REPO, and a URL nothing can resolve: this is the
  # offline case, and it must not fall through to a stale local view.
  home=$(make_home offline-home 0123456789012345678901234567890123456789 \
    "https://source.invalid/nothing.git")

  out=$(FM_HOME="$home" FM_FLEET_UPDATE_TIMEOUT=5 "$CHECK") || status=$?
  expect_code 1 "$status" "an unreachable pin source must exit non-zero"
  assert_contains "$out" 'pin age         UNMEASURABLE' \
    "a fetch that fails must produce UNMEASURABLE"
  assert_not_contains "$out" 'pin age         CURRENT' \
    "a fetch that fails must never produce CURRENT"

  out=$(FM_HOME="$home" FM_FLEET_UPDATE_TIMEOUT=5 "$CHECK" --pin-age)
  assert_contains "$out" 'unmeasured|' "the round's reading must be unmeasured when the source is unreachable"
  pass "an unreachable pin source is unmeasurable, never current"
}

test_a_home_with_no_lock_is_not_pin_delivered_rather_than_faulty() {
  local home out
  home="$TMP_ROOT/no-lock"
  fm_git_init_commit "$home"

  out=$(FM_HOME="$home" "$CHECK" --pin-age)
  assert_contains "$out" 'skipped|' "a home with no lock must be skipped, not faulted"
  assert_contains "$out" 'not pin-delivered' "the reason must be stated plainly"

  out=$(FM_HOME="$home" "$CHECK" || true)
  assert_contains "$out" 'NOT PIN-DELIVERED' \
    "the full report must state plainly that nothing pins this home"
  assert_not_contains "$out" 'UNREADABLE' "an absent lock is not an unreadable one"
  pass "a home with no firstmate.lock reports plainly rather than as a fault"
}

test_an_unusable_lock_is_unmeasurable_rather_than_silent() {
  local home out status=0
  home="$TMP_ROOT/bad-lock"
  fm_git_init_commit "$home"
  printf 'source_url=https://source.invalid/x.git\ncommit=nonsense\n' > "$home/firstmate.lock"

  out=$(FM_HOME="$home" "$CHECK") || status=$?
  expect_code 1 "$status" "an unusable lock must exit non-zero"
  assert_contains "$out" 'vendored pin    UNREADABLE' "an unusable pin must be named as such"
  assert_contains "$out" 'pin age         UNMEASURABLE' "an unreadable pin has an unmeasurable age"

  printf 'source_ref=source\ncommit=0123456789012345678901234567890123456789\n' > "$home/firstmate.lock"
  out=$(FM_HOME="$home" "$CHECK" --pin-age)
  assert_contains "$out" 'unmeasured|' "a lock with no source_url cannot age its pin"
  assert_contains "$out" 'source_url' "the reading must name the field that is missing"
  pass "an unusable lock is reported as unmeasurable rather than passing quietly"
}

test_a_pin_off_the_current_lineage_is_named_not_counted_as_merely_behind() {
  local src work pin home out status=0
  src=$(make_source lineage)
  work="$TMP_ROOT/lineage"
  advance_source "$work" 2 0
  git -C "$work" push -q origin source
  # A commit that is on no branch the source publishes: reachable in the fixture
  # object store, but carrying content the source's own lineage does not.
  git -C "$work" checkout -q -b sidetrack
  advance_source "$work" 1 0
  pin=$(git -C "$work" rev-parse sidetrack)
  git -C "$work" push -q origin sidetrack
  git -C "$work" checkout -q source
  advance_source "$work" 4 2
  git -C "$work" push -q origin source
  home=$(make_home lineage-home "$pin" "$src")

  out=$(run_check "$home" "$src") || status=$?
  expect_code 1 "$status" "a pin off the current lineage must exit non-zero"
  assert_contains "$out" 'pin age         OFF LINEAGE' \
    "a pin carrying commits the source ref does not must be named, not silently counted as behind"
  assert_contains "$out" 'commit(s) that source does not' \
    "the detail must state what makes the pin off-lineage"
  pass "a pin off the source's current lineage is named rather than reported as merely behind"
}

test_the_hops_are_never_collapsed_into_one_word() {
  local src work pin home out
  src=$(make_source separate)
  work="$TMP_ROOT/separate"
  advance_source "$work" 5 2
  git -C "$work" push -q origin source
  pin=$(git -C "$work" rev-list --max-parents=0 source)
  home=$(make_home separate-home "$pin" "$src")

  out=$(run_check "$home" "$src" || true)
  # The home is a plain fixture repo with no origin, so hop 3 cannot be read.
  # It must say that, separately, while hop 1 still reports its own number.
  assert_contains "$out" 'hop 3  installed  own origin      UNMEASURABLE' \
    "a hop that cannot be read must say so on its own line"
  assert_contains "$out" 'no origin' "the hop 3 reason must be concrete"
  assert_contains "$out" 'BEHIND 5 commit(s), 2 merged PR(s)' \
    "an unreadable hop 3 must not suppress the hop 1 measurement"
  pass "each hop reports its own state and one unreadable hop never speaks for another"
}

test_a_secondmate_home_is_not_faulted_for_having_no_origin() {
  local home out
  home="$TMP_ROOT/linked"
  fm_git_init_commit "$home"
  printf 'domain\n' > "$home/.fm-secondmate-home"

  out=$(FM_HOME="$home" "$CHECK" || true)
  assert_contains "$out" 'own origin      NOT APPLICABLE' \
    "a linked home takes its updates from its primary and has no origin to be level with"
  assert_not_contains "$out" 'own origin      UNMEASURABLE' \
    "a linked home must not be reported as an instrument failure forever"
  pass "a secondmate home is judged by its own delivery route"
}

test_help_and_argument_handling() {
  local out status=0
  out=$("$CHECK" --help)
  assert_contains "$out" 'ALL THREE HOPS' "--help must render the header block"
  assert_contains "$out" '--pin-age' "--help must document the seam the round consumes"
  "$CHECK" --nonsense >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown argument must be refused rather than guessed at"
  pass "help renders and an unknown argument is refused"
}

test_a_stale_pin_is_counted_not_sampled
test_a_current_pin_reads_current
test_a_pin_the_source_does_not_carry_is_unmeasurable_never_current
test_an_unreachable_pin_source_is_unmeasurable_never_current
test_a_home_with_no_lock_is_not_pin_delivered_rather_than_faulty
test_an_unusable_lock_is_unmeasurable_rather_than_silent
test_a_pin_off_the_current_lineage_is_named_not_counted_as_merely_behind
test_the_hops_are_never_collapsed_into_one_word
test_a_secondmate_home_is_not_faulted_for_having_no_origin
test_help_and_argument_handling
