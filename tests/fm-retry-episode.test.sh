#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The bounded relaunch episode both seat supervisors run on. Exercised directly
# here so the rules are pinned once, where they live, rather than only through
# whichever supervisor happens to reach them.
# shellcheck source=bin/fm-retry-episode-lib.sh
. "$ROOT/bin/fm-retry-episode-lib.sh"

fm_test_tmproot TMP_ROOT fm-retry-episode

make_home() {  # <name> -> echoes the home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data/findings"
  printf '%s\n' "$home"
}

test_backoff_doubles_from_the_base_and_stops_at_the_maximum() {
  local seen n
  seen=
  for n in 1 2 3 4 5 6; do
    seen="$seen$(fm_retry_backoff "$n" 30 900) "
  done
  [ "$seen" = "30 60 120 240 480 900 " ] \
    || fail "backoff did not double from the base up to the maximum; got: $seen"
  [ "$(fm_retry_backoff 20 30 900)" = 900 ] \
    || fail "backoff grew past its maximum on a long episode"
  pass "retry backoff doubles from its base and never exceeds its maximum"
}

test_a_different_condition_starts_a_fresh_episode() {
  local home record
  home=$(make_home fresh-episode)
  record="$home/state/.attempts"

  fm_retry_read_attempts "$record" first-condition
  [ "$FM_RETRY_ATTEMPT_COUNT" = 0 ] || fail "an absent record reported an episode already under way"

  fm_retry_write_attempts "$record" first-condition 4 1750000000 \
    || fail "could not write the attempt record"
  fm_retry_read_attempts "$record" first-condition
  [ "$FM_RETRY_ATTEMPT_COUNT" = 4 ] || fail "the recorded attempt count did not survive a read back"
  [ "$FM_RETRY_ATTEMPT_NEXT" = 1750000000 ] || fail "the recorded next-attempt time did not survive a read back"

  fm_retry_read_attempts "$record" second-condition
  [ "$FM_RETRY_ATTEMPT_COUNT" = 0 ] \
    || fail "a new condition inherited the previous condition's exhausted attempts"
  [ "$FM_RETRY_ATTEMPT_NEXT" = 0 ] \
    || fail "a new condition inherited the previous condition's backoff deadline"
  pass "a different condition starts its own episode from zero"
}

test_clearing_an_episode_removes_both_records() {
  local home record giveup
  home=$(make_home clear-episode)
  record="$home/state/.attempts"
  giveup="$home/state/.giveup"
  fm_retry_write_attempts "$record" a-condition 2 0 || fail "could not write the attempt record"
  printf 'key=a-condition\n' > "$giveup"

  fm_retry_clear_episode "$record" "$giveup"
  [ ! -e "$record" ] || fail "clearing the episode left the attempt record behind"
  [ ! -e "$giveup" ] || fail "clearing the episode left the give-up marker behind"
  pass "clearing an episode removes both the attempt record and the give-up marker"
}

test_the_give_up_finding_is_filed_once_per_condition() {
  local home giveup findings out
  home=$(make_home give-up)
  giveup="$home/state/.giveup"

  out=$(FM_HOME="$home" FM_ROOT="$ROOT" FM_FINDINGS_DIR="$home/data/findings" \
    fm_retry_giveup_emit "$giveup" a-condition fm-test-officer \
    "A test supervisor exhausted its attempts." "tests/fm-retry-episode.test.sh" \
    "undeliverable: the published pane no longer exists") \
    || fail "the give-up finding could not be filed: $out"
  [ -f "$giveup" ] || fail "the give-up marker was not recorded"
  case "$out" in *"give-up finding emitted for a-condition"*) ;; *) fail "the caller was told nothing to log: $out" ;; esac

  out=$(FM_HOME="$home" FM_ROOT="$ROOT" FM_FINDINGS_DIR="$home/data/findings" \
    fm_retry_giveup_emit "$giveup" a-condition fm-test-officer \
    "A test supervisor exhausted its attempts." "tests/fm-retry-episode.test.sh" \
    "undeliverable: the published pane no longer exists") \
    || fail "a repeat give-up for the same condition failed"
  [ -z "$out" ] \
    || fail "the same exhausted condition was filed and announced a second time: $out"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] || fail "the same exhausted condition was filed more than once; got $findings findings"

  FM_HOME="$home" FM_ROOT="$ROOT" FM_FINDINGS_DIR="$home/data/findings" \
    fm_retry_giveup_emit "$giveup" another-condition fm-test-officer \
    "A test supervisor exhausted its attempts." "tests/fm-retry-episode.test.sh" \
    "undeliverable: the endpoint was published by a session that no longer holds the fleet lock" \
    >/dev/null || fail "a give-up for a new condition failed"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 2 ] || fail "a newly exhausted condition was not filed; got $findings findings"
  assert_grep "fm-test-officer" "$home/data/findings/"*.json \
    "the finding did not carry the officer the caller named"
  pass "an exhausted condition is filed once, and a new condition is filed again"
}

test_backoff_doubles_from_the_base_and_stops_at_the_maximum
test_a_different_condition_starts_a_fresh_episode
test_clearing_an_episode_removes_both_records
test_the_give_up_finding_is_filed_once_per_condition
