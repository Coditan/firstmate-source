#!/usr/bin/env bash
# Behavior tests for the drain rule and the write-back.
#
# Three of these carry the weight.
#
# test_only_the_seat_that_drained_a_finding_writes_its_outcome_back pins the
# dependency the whole design hangs on. On 2026-08-03 another vessel ran three
# backlog audits that judged 30 entries dead and wrote not one outcome back, so
# its morning report showed 16 open decisions of which 11 were no longer alive.
# A findings surface nobody writes back to rebuilds that failure from scratch.
#
# test_a_finding_nobody_took_becomes_visible_as_overdue pins the coupling. The
# captain's phrasing: not discipline, but a coupling whose absence is itself
# visible. Ignoring a finding has to be a visible act.
#
# test_a_drain_that_cannot_reach_the_surface_never_reports_an_empty_queue pins
# the defect class. Four instruments in this fleet were caught on 2026-08-04
# answering a question adjacent to the one asked, each by degrading into a
# reading indistinguishable from an ordinary calm one. A drain that reports
# "nothing to work on" when it reached no surface is the next one.
#
# Fixtures are synthetic and the clock is pinned. They pin the RULE - which
# finding comes first and why - not any live surface's contents.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINDING="$ROOT/bin/fm-finding.sh"
DRAIN="$ROOT/bin/fm-finding-drain.sh"
fm_test_tmproot TMP_ROOT fm-finding-drain

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# surface <name>: a fresh, initialised surface directory on stdout.
surface() {
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# emit <dir> <severity> <observed> <claim>: one finding, and its id on stdout.
# Every field the format demands is filled with something plausible so each test
# below states only the thing it is about.
emit() {
  local dir=$1 severity=$2 observed=$3 claim=$4 out
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" emit \
    --class evidence \
    --claim "$claim" \
    --where "crew-hlr:/home/sc1/projects/tugboat" \
    --measurement "3 commits authored by the vessel seat between 09:12 and 09:14 UTC" \
    --refuted-by "the commits carry a crewmate seat's authorship, not the vessel's" \
    --officer "po-crew-hlr" \
    --severity "$severity" \
    --observed "$observed") || fail "emit ($claim) must succeed on a healthy surface"
  printf '%s\n' "$out" | sed -n 's/^id=//p'
}

# drain <dir> <now> [args...]: the drain script against a pinned clock.
drain() {
  local dir=$1 now=$2
  shift 2
  FM_FINDINGS_DIR="$dir" FM_FINDING_NOW="$now" "$DRAIN" "$@"
}

# claims <tsv>: the claim column of a queue listing, space separated, so a test
# can assert the ORDER in the words the finding was written in.
claims() {
  printf '%s\n' "$1" | cut -f8 | tr '\n' ' '
}

test_the_rule_takes_the_nearest_deadline_not_the_loudest_severity() {
  local dir out urgent
  dir=$(surface ordering)
  # Three findings whose severity and age disagree on purpose. The low one is
  # the oldest, the high one the youngest, so age-order and severity-order
  # point in opposite directions and only the deadline settles it.
  emit "$dir" low "2026-08-01T00:00:00Z" "low-and-oldest" >/dev/null
  urgent=$(emit "$dir" high "2026-08-04T00:00:00Z" "high-and-newest")
  emit "$dir" medium "2026-08-03T00:00:00Z" "medium-and-middle" >/dev/null

  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue) || fail "queue must read a healthy surface"
  [ "$(claims "$out")" = "high-and-newest medium-and-middle low-and-oldest " ] \
    || fail "the rule must order by deadline, got: $(claims "$out")"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" next) || fail "next must succeed"
  assert_contains "$out" "next=$urgent" "next must select the finding the queue puts first"

  # The property that distinguishes this rule from severity-first, and the whole
  # reason severity is read as a waiting time rather than as a rank: a fresh
  # high-severity finding queues BEHIND a low one that has already waited out
  # its week. Under severity-first a steady supply of high findings would keep
  # the low one from ever being reached - and a claim nobody ever reaches is the
  # shape of the 2027 unread log lines the officer exists to notice.
  emit "$dir" high "2026-08-11T00:00:00Z" "high-arriving-late" >/dev/null
  out=$(drain "$dir" "2026-08-11T12:00:00Z" queue) || fail "queue must read a healthy surface"
  [ "$(claims "$out")" = "high-and-newest medium-and-middle low-and-oldest high-arriving-late " ] \
    || fail "a fresh high finding must not jump a low one that has waited: $(claims "$out")"

  # Severity still buys the shorter wait it is for: two findings observed at the
  # same instant order high, medium, low.
  dir=$(surface ordering-same-instant)
  emit "$dir" low "2026-08-04T00:00:00Z" "same-instant-low" >/dev/null
  emit "$dir" medium "2026-08-04T00:00:00Z" "same-instant-medium" >/dev/null
  emit "$dir" high "2026-08-04T00:00:00Z" "same-instant-high" >/dev/null
  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue) || fail "queue"
  [ "$(claims "$out")" = "same-instant-high same-instant-medium same-instant-low " ] \
    || fail "severity must decide between findings of the same age: $(claims "$out")"
}

test_a_finding_nobody_took_becomes_visible_as_overdue() {
  local dir out status waiting overdue
  dir=$(surface coupling)
  emit "$dir" high "2026-08-04T00:00:00Z" "ignored-high" >/dev/null
  emit "$dir" low "2026-08-04T00:00:00Z" "still-waiting-low" >/dev/null

  # Before the deadline nothing is overdue, and the listing says so with a
  # number rather than by being empty.
  waiting=$(drain "$dir" "2026-08-04T12:00:00Z" queue --overdue) \
    || fail "an overdue listing must succeed on a healthy surface"
  [ -z "$waiting" ] || fail "nothing may read as overdue before its deadline: $waiting"

  # A day later the high finding is past its threshold and nobody has taken it.
  # That is the coupling: the act of ignoring it is now a visible line, not a
  # silence indistinguishable from an empty surface.
  overdue=$(drain "$dir" "2026-08-05T12:00:00Z" queue --overdue) || fail "overdue listing"
  [ "$(claims "$overdue")" = "ignored-high " ] \
    || fail "an unread finding past its threshold must be visible as overdue: $(claims "$overdue")"
  assert_contains "$overdue" "yes" "the overdue column must say so in the listing itself"

  # Taking it removes it from the ignored set without anyone editing a flag: the
  # coupling reads the claim state, so it cannot say "ignored" about work
  # somebody has started.
  drain "$dir" "2026-08-05T12:00:00Z" take --by builder-1 >/dev/null || fail "take"
  overdue=$(drain "$dir" "2026-08-05T12:00:00Z" queue --overdue) && status=0 || status=$?
  expect_code 0 "$status" "the overdue listing must still succeed"
  [ -z "$overdue" ] || fail "a taken finding is not being ignored: $overdue"
}

test_only_the_seat_that_drained_a_finding_writes_its_outcome_back() {
  local dir id out status before after
  dir=$(surface write-back)
  id=$(emit "$dir" high "2026-08-04T00:00:00Z" "sc1-wrote-where-forbidden")
  before=$(cat "$dir/$id.json")

  drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 >/dev/null || fail "take"

  out=$(drain "$dir" "2026-08-05T01:00:00Z" resolve "$id" \
    --outcome refuted --by builder-9 --evidence "I disagree" 2>&1) && status=0 || status=$?
  expect_code 5 "$status" "a seat that did not drain a finding may not answer it"
  assert_contains "$out" "written back by whoever drained it" \
    "the refusal must name the rule it is holding"

  out=$(drain "$dir" "2026-08-05T01:00:00Z" resolve "$id" \
    --outcome refuted --by builder-1 \
    --evidence "the three commits carry a crewmate seat's authorship, not the vessel's") \
    || fail "the seat that drained it must be able to write the outcome back"
  assert_contains "$out" "written=1" "the write-back must report that it wrote"

  # The outcome is a separate record. The officer's claim is not touched by the
  # answer to it, which is what keeps "he never writes an outcome, and nobody
  # rewrites his claim" a fact about files rather than about manners.
  after=$(cat "$dir/$id.json")
  [ "$before" = "$after" ] || fail "the write-back rewrote the officer's finding"
  assert_contains "$(cat "$dir/$id.outcome.json")" '"outcome": "refuted"' \
    "the outcome record must carry the verdict"
  assert_contains "$(cat "$dir/$id.outcome.json")" '"drained_by": "builder-1"' \
    "the outcome record must name who drained it"

  # And the drained finding leaves the open queue, so the same claim is not
  # worked twice.
  out=$(drain "$dir" "2026-08-05T02:00:00Z" next) || fail "next"
  assert_contains "$out" "open=0" "an answered finding must not still be open"
}

test_an_outcome_cannot_be_written_back_for_a_finding_nobody_drained() {
  local dir id out status
  dir=$(surface never-drained)
  id=$(emit "$dir" high "2026-08-04T00:00:00Z" "untaken")

  out=$(drain "$dir" "2026-08-05T00:00:00Z" resolve "$id" \
    --outcome upheld --by builder-1 --evidence "a reading" 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an outcome for work nobody claimed must be refused"
  assert_contains "$out" "was never taken" "the refusal must name what is missing"
  [ -e "$dir/$id.outcome.json" ] && fail "the refused write-back left an outcome behind anyway"

  # An outcome with no reading behind it is the other half of the same rule: it
  # would let the accuracy score be moved by an opinion about the officer.
  drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 >/dev/null || fail "take"
  out=$(drain "$dir" "2026-08-05T00:00:00Z" resolve "$id" \
    --outcome upheld --by builder-1 --evidence "  " 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an outcome with no evidence must be refused"
  assert_contains "$out" "not an answer to his finding" "the refusal must say why evidence is required"
}

test_a_written_back_outcome_is_the_record_and_not_a_draft() {
  local dir id out status
  dir=$(surface not-a-draft)
  id=$(emit "$dir" high "2026-08-04T00:00:00Z" "settled")
  drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 >/dev/null || fail "take"
  drain "$dir" "2026-08-05T01:00:00Z" resolve "$id" \
    --outcome refuted --by builder-1 --evidence "the reading that overturned it" >/dev/null \
    || fail "the first write-back"

  # A retried identical write-back is a retry, not a second outcome. The
  # accuracy score counts outcomes, so a retry that doubled one would move the
  # officer's measured rate without anyone deciding anything.
  out=$(drain "$dir" "2026-08-05T02:00:00Z" resolve "$id" \
    --outcome refuted --by builder-1 --evidence "the reading that overturned it") \
    || fail "an identical retry must be allowed"
  assert_contains "$out" "written=0" "a retry must not write a second outcome"

  out=$(drain "$dir" "2026-08-05T03:00:00Z" resolve "$id" \
    --outcome upheld --by builder-1 --evidence "on reflection" 2>&1) && status=0 || status=$?
  expect_code 5 "$status" "a written-back outcome must not be quietly replaced"
  assert_contains "$(cat "$dir/$id.outcome.json")" '"outcome": "refuted"' \
    "the original outcome must survive the attempt to edit it"
}

test_two_seats_cannot_both_take_the_same_finding() {
  local dir first second out status
  dir=$(surface contested)
  emit "$dir" high "2026-08-04T00:00:00Z" "first-claim" >/dev/null
  emit "$dir" high "2026-08-04T06:00:00Z" "second-claim" >/dev/null

  first=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 | sed -n 's/^id=//p')
  [ -n "$first" ] || fail "the first take must report the id it claimed"

  # A second builder reaching for the same finding by name is refused, and gets
  # its own exit code: "someone else has this" and "you asked for the wrong
  # thing" call for opposite responses.
  out=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-2 --id "$first" 2>&1) && status=0 || status=$?
  expect_code 5 "$status" "a claimed finding must not be claimable again"
  assert_contains "$out" "already" "the refusal must say the claim is held"

  # A second builder taking by the rule gets the next one instead of blocking.
  second=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-2 | sed -n 's/^id=//p')
  [ -n "$second" ] || fail "the second builder must get a finding of its own"
  [ "$second" = "$first" ] && fail "two builders were handed the same finding"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-3)
  assert_contains "$out" "taken=0" "a surface with nothing open must say so with a number"
  assert_contains "$out" "id=" "the key must still be present so nothing looks omitted"
}

test_a_drain_that_cannot_reach_the_surface_never_reports_an_empty_queue() {
  local missing dir out status
  missing=$TMP_ROOT/never-created

  # This is the whole defect class in one assertion. "open=0" is the calm
  # reading a builder acts on by going back to sleep, and it must be reachable
  # only by having actually counted.
  out=$(drain "$missing" "2026-08-05T00:00:00Z" next 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "an unreachable surface must not exit 0"
  assert_not_contains "$out" "open=0" \
    "an unreachable surface must never report a queue it did not read"
  [ -z "$out" ] || fail "next printed a queue reading it never took: $out"

  out=$(drain "$missing" "2026-08-05T00:00:00Z" next 2>&1 >/dev/null)
  assert_contains "$out" "does not exist" "the reason must name the concrete defect"

  out=$(drain "$missing" "2026-08-05T00:00:00Z" queue 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "queue must refuse an unreachable surface rather than print nothing"
  [ -z "$out" ] || fail "queue printed rows from a surface it never reached: $out"

  out=$(drain "$missing" "2026-08-05T00:00:00Z" take --by builder-1 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "take must refuse an unreachable surface"
  assert_not_contains "$out" "taken=0" \
    "a surface that was never reached must not read as one with nothing to take"

  # The same distinction one step in: a surface a builder can read but cannot
  # write a claim onto is not a queue with nothing takeable either.
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: running as root, so mode bits do not block a claim"
    return 0
  fi
  dir=$(surface claim-blocked)
  emit "$dir" high "2026-08-04T00:00:00Z" "takeable-but-for-the-mode-bits" >/dev/null
  chmod 500 "$dir"
  out=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 2>&1) && status=0 || status=$?
  chmod 700 "$dir"
  expect_code 3 "$status" "a surface no claim can be written to must not report success"
  assert_contains "$out" "cannot be appended to" "the refusal must name the concrete block"
  assert_not_contains "$out" "taken=1" "nothing was claimed, so nothing may say it was"
}

test_a_finding_the_rule_cannot_place_is_reported_and_never_dropped() {
  local dir out status
  dir=$(surface undatable)
  emit "$dir" high "2026-08-04T00:00:00Z" "orderable" >/dev/null

  # A record that satisfies the format but whose observation time is not a time.
  # The rule has no deadline for it, so it has no place in the order - and a
  # record the rule cannot handle is exactly the one that must not become the
  # one nobody sees.
  jq -n '{schema:"fm-finding/1", id:"20260804T000000Z-aaaaaaaa", class:"judgement",
          claim:"undatable", where:"crew-hlr", measurement:"a reading",
          observed:"some time last week", refuted_by:"a timestamp",
          officer:"po-crew-hlr", severity:"high"}' \
    > "$dir/20260804T000000Z-aaaaaaaa.json"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue --state all 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "a queue holding a record it cannot place must not read as complete"
  assert_contains "$out" "undatable" "the record must still appear in the listing"
  assert_contains "$out" "orderable" "the records that CAN be placed must still be listed"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue --state all 2>&1 >/dev/null)
  assert_contains "$out" "20260804T000000Z-aaaaaaaa" "the unplaceable record must be named"
  assert_contains "$out" "is not an ISO-8601 UTC instant" "the reason must name the concrete defect"
  assert_contains "$out" "incomplete" "the ordering must say it is incomplete"

  # It is never handed to a builder as the next thing to work on, because the
  # rule has no answer for where it belongs.
  out=$(drain "$dir" "2026-08-05T00:00:00Z" next 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "next must flag an ordering it could not complete"
  assert_contains "$out" "open=1" "the placeable findings must still be counted"

  # A partial reading does not stop the work it CAN place. It just refuses to
  # look complete while doing it, so a builder that checks gets both the finding
  # and the fact that something on the surface has no place in the order.
  out=$(drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "take must flag an ordering it could not complete"
  assert_contains "$out" "taken=1" "the placeable findings must still be takeable"
}

test_a_finding_whose_claim_state_cannot_be_read_is_never_handed_out_again() {
  local dir id out status
  dir=$(surface unknown-claim)
  id=$(emit "$dir" high "2026-08-04T00:00:00Z" "possibly-somebodys-work")
  drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 >/dev/null || fail "take"
  printf 'not json at all\n' > "$dir/$id.outcome.json"

  # Reading it as open would hand a second builder work the first may be doing;
  # dropping it would hide a real claim behind a broken answer. Neither is a
  # reading anyone can act on, so it gets its own state and says so.
  out=$(drain "$dir" "2026-08-05T01:00:00Z" queue --state all 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "an unreadable claim must not leave the queue looking healthy"
  assert_contains "$out" "unknown" "the finding's claim state must read as unknown, not as open"

  out=$(drain "$dir" "2026-08-05T01:00:00Z" next 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "next must flag the queue it could not fully read"
  assert_contains "$out" "open=0" "a finding whose claim state is unknown must not be handed out"

  out=$(drain "$dir" "2026-08-05T01:00:00Z" next 2>&1 >/dev/null)
  assert_contains "$out" "$id.outcome.json" "the unreadable outcome file must be named"

  # And nothing can be written back through it either, because the seat that
  # holds the claim can no longer be established.
  out=$(drain "$dir" "2026-08-05T01:00:00Z" resolve "$id" \
    --outcome upheld --by builder-1 --evidence "a reading" 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "a write-back through an unreadable claim must be refused"
  assert_contains "$out" "cannot be confirmed" "the refusal must name what could not be established"
}

test_a_file_that_is_not_a_finding_makes_the_ordering_incomplete_not_shorter() {
  local dir out status
  dir=$(surface malformed)
  emit "$dir" high "2026-08-04T00:00:00Z" "readable" >/dev/null
  printf 'not json at all\n' > "$dir/20260803T000000Z-deadbeef.json"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "a surface holding a non-finding must not order as if it were healthy"
  assert_contains "$out" "readable" "the findings that ARE readable must still be ordered"

  out=$(drain "$dir" "2026-08-05T00:00:00Z" queue 2>&1 >/dev/null)
  assert_contains "$out" "20260803T000000Z-deadbeef.json" "the unreadable file must be named"
  assert_contains "$out" "incomplete" "the ordering must say it is incomplete"
}

test_a_clock_the_queue_cannot_read_refuses_rather_than_quietly_using_another() {
  local dir out status
  dir=$(surface bad-clock)
  emit "$dir" high "2026-08-04T00:00:00Z" "orderable" >/dev/null

  # Falling back to the wall clock here would answer a question adjacent to the
  # one asked: the caller pinned an instant, and the queue would be ordered
  # against a different one while reporting success.
  out=$(FM_FINDINGS_DIR="$dir" FM_FINDING_NOW="last tuesday" "$DRAIN" queue 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an unreadable clock must refuse rather than substitute another"
  assert_contains "$out" "is not an ISO-8601 UTC instant" "the refusal must name the concrete defect"
  assert_not_contains "$out" "orderable" "no queue may be printed against a clock nobody could read"
}

test_the_officer_has_no_command_that_writes_an_outcome() {
  local dir id out status
  dir=$(surface no-officer-outcome)
  id=$(emit "$dir" high "2026-08-04T00:00:00Z" "his-own-claim")

  # The emit surface has no option that could produce an outcome, so the officer
  # answering his own finding is not a rule he has to keep. It is a command that
  # does not exist.
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" emit --outcome upheld 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "the emit surface must not accept an outcome"
  assert_contains "$out" "unknown option" "the refusal must be that there is no such option"

  out=$(find "$dir" -maxdepth 1 -name '*.outcome.json' | wc -l | tr -d ' ')
  [ "$out" = "0" ] || fail "an outcome record exists without anyone having drained a finding"

  # And the officer's own listing never shows the drainer's answers as findings,
  # so his surface cannot grow claims he did not make.
  drain "$dir" "2026-08-05T00:00:00Z" take --by builder-1 >/dev/null || fail "take"
  drain "$dir" "2026-08-05T01:00:00Z" resolve "$id" \
    --outcome upheld --by builder-1 --evidence "the commits are the vessel seat's" >/dev/null \
    || fail "resolve"
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check) || fail "check must still read a healthy surface"
  assert_contains "$out" "findings=1" "an outcome must not be counted as a finding"
  assert_contains "$out" "malformed=0" "an outcome must not be counted as a broken file either"
}

test_the_rule_takes_the_nearest_deadline_not_the_loudest_severity
test_a_finding_nobody_took_becomes_visible_as_overdue
test_only_the_seat_that_drained_a_finding_writes_its_outcome_back
test_an_outcome_cannot_be_written_back_for_a_finding_nobody_drained
test_a_written_back_outcome_is_the_record_and_not_a_draft
test_two_seats_cannot_both_take_the_same_finding
test_a_drain_that_cannot_reach_the_surface_never_reports_an_empty_queue
test_a_finding_the_rule_cannot_place_is_reported_and_never_dropped
test_a_finding_whose_claim_state_cannot_be_read_is_never_handed_out_again
test_a_file_that_is_not_a_finding_makes_the_ordering_incomplete_not_shorter
test_a_clock_the_queue_cannot_read_refuses_rather_than_quietly_using_another
test_the_officer_has_no_command_that_writes_an_outcome

pass "drain rule: earliest deadline first, the outcome is written back by whoever drained it, and a drain that reached no surface never reads as an empty queue"
