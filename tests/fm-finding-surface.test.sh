#!/usr/bin/env bash
# Behavior tests for the political officer's findings surface.
#
# Two of these carry the weight.
#
# test_a_judgement_that_cannot_be_refuted_never_reaches_the_surface pins the
# captain's rule as a property of the format: not that emit prints a warning,
# but that the surface is still empty afterwards. A rule someone remembers
# leaves a record behind; a rule the format holds does not.
#
# test_an_empty_surface_and_an_unreachable_one_never_read_alike pins the defect
# class the whole design exists against. On 2026-08-04 four instruments in this
# fleet answered a question adjacent to the one asked, each by degrading into a
# reading indistinguishable from an ordinary calm one. A findings surface that
# reports "no findings" when it cannot be reached is the fifth.
#
# Fixtures are synthetic. They pin the RULES - the required fields, the
# ordering, the distinction between empty and broken - not any live surface's
# contents.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINDING="$ROOT/bin/fm-finding.sh"
fm_test_tmproot TMP_ROOT fm-finding

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# surface <name>: a fresh, initialised surface directory on stdout.
surface() {
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# emit_into <dir> [extra args...]: a complete, valid finding unless an argument
# overrides one of its fields. Keeping the valid case in one helper means each
# test states only the field it is about.
emit_into() {
  local dir=$1
  shift
  FM_FINDINGS_DIR="$dir" "$FINDING" emit \
    --class evidence \
    --claim "sc1 wrote to a project worktree" \
    --where "crew-hlr:/home/sc1/projects/tugboat" \
    --measurement "3 commits authored by the vessel seat between 09:12 and 09:14 UTC" \
    --refuted-by "the commits carry a crewmate seat's authorship, not the vessel's" \
    --officer "po-crew-hlr" \
    "$@"
}

test_a_judgement_that_cannot_be_refuted_never_reaches_the_surface() {
  local dir out status count
  dir=$(surface refuse-judgement)

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" emit \
    --class judgement \
    --claim "sc1 did not report its outcome faithfully" \
    --where "crew-hlr:sc1" \
    --measurement "the report says green; the run has no green check" \
    --officer "po-crew-hlr" 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a judgement with no refutation must be refused"
  assert_contains "$out" "what would disprove it" \
    "the refusal must say what is missing and why it matters"

  # The property under test is the surface's state, not the message. A rule
  # someone remembers would have left the record behind anyway.
  count=$(find "$dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" = "0" ] || fail "an unrefutable judgement reached the surface anyway ($count file(s))"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null)
  assert_contains "$out" "findings=0" "the surface must still read as empty"
}

test_no_class_escapes_the_refutation_requirement() {
  local dir out status class
  dir=$(surface refuse-every-class)
  for class in evidence judgement pattern; do
    out=$(FM_FINDINGS_DIR="$dir" "$FINDING" emit \
      --class "$class" \
      --claim "a claim" --where "somewhere" --measurement "a reading" \
      --officer "po-crew-hlr" 2>&1) && status=0 || status=$?
    expect_code 2 "$status" "class $class must also state its refutation"
  done

  # Whitespace is not a refutation. The check has to be on the content, or the
  # requirement is satisfiable by pressing the space bar.
  out=$(emit_into "$dir" --refuted-by "   " 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a whitespace-only refutation must be refused"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null)
  assert_contains "$out" "findings=0" "no refused emit may leave a record"
}

test_a_finding_carries_its_whole_record_and_is_named_by_its_own_content() {
  local dir out id record stem
  dir=$(surface whole-record)
  out=$(emit_into "$dir" --observed "2026-08-04T09:14:00Z" --severity high) \
    || fail "a complete finding must be emittable"
  assert_contains "$out" "appended=1" "emit must report that it appended"

  id=$(printf '%s\n' "$out" | sed -n 's/^id=//p')
  [ -n "$id" ] || fail "emit must report the id it wrote"
  case "$id" in
    20260804T091400Z-*) : ;;
    *) fail "the id must lead with the observation time so a byte sort is chronological: $id" ;;
  esac

  record=$(FM_FINDINGS_DIR="$dir" "$FINDING" show "$id") || fail "show must return the record"
  assert_contains "$record" '"refuted_by"' "the record must carry what would disprove it"
  assert_contains "$record" '"measurement"' "the record must carry the measurement behind it"
  assert_contains "$record" '"where"' "the record must carry where it was found"
  assert_contains "$record" '"observed"' "the record must carry the date"
  assert_contains "$record" '"officer"' "the record must name who claimed it"
  assert_contains "$record" '"schema": "fm-finding/1"' "the record must name its own format"

  # The id is the filename stem, so a record cannot be listed under a name other
  # than the one it claims.
  stem=$(printf '%s\n' "$out" | sed -n 's|^path=.*/||p')
  [ "$stem" = "$id.json" ] || fail "the file must be named by the id: $stem vs $id"
}

test_the_surface_reads_oldest_first() {
  local dir out ids
  dir=$(surface ordering)
  emit_into "$dir" --observed "2026-08-04T12:00:00Z" --claim "third" >/dev/null || fail "emit third"
  emit_into "$dir" --observed "2026-08-02T12:00:00Z" --claim "first" >/dev/null || fail "emit first"
  emit_into "$dir" --observed "2026-08-03T12:00:00Z" --claim "second" >/dev/null || fail "emit second"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" list) || fail "list must succeed on a healthy surface"
  ids=$(printf '%s\n' "$out" | cut -f6 | tr '\n' ' ')
  [ "$ids" = "first second third " ] \
    || fail "the surface must read oldest first, got: $ids"
}

test_an_identical_append_is_the_same_record_and_not_a_second_one() {
  local dir first second out
  dir=$(surface idempotent)
  first=$(emit_into "$dir" --observed "2026-08-04T09:14:00Z") || fail "first emit"
  assert_contains "$first" "appended=1" "the first append must report itself as one"
  second=$(emit_into "$dir" --observed "2026-08-04T09:14:00Z") || fail "retried emit"
  assert_contains "$second" "appended=0" "a retried identical append must not append again"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check)
  assert_contains "$out" "findings=1" "one observation must be one record even after a retry"
}

test_an_empty_surface_and_an_unreachable_one_never_read_alike() {
  local healthy missing out status

  # A reachable surface with nothing on it. This is the calm reading, and it
  # carries a number, because it was measured.
  healthy=$(surface healthy-empty)
  out=$(FM_FINDINGS_DIR="$healthy" "$FINDING" check) && status=0 || status=$?
  expect_code 0 "$status" "a reachable empty surface is not an error"
  assert_contains "$out" "state=ok" "a reachable surface must say so"
  assert_contains "$out" "findings=0" "a measured empty surface must report zero"

  # A surface that does not exist. Nothing was counted, so no count is printed:
  # the keys are present and empty rather than zero, and the exit code is its
  # own. A caller that reads findings= as a number gets nothing to misread.
  missing=$TMP_ROOT/never-created
  out=$(FM_FINDINGS_DIR="$missing" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "an unreachable surface must not exit 0"
  assert_contains "$out" "state=absent" "an absent surface must name itself absent"
  assert_contains "$out" "findings=" "the key must still be present so nothing looks omitted"
  assert_not_contains "$out" "findings=0" \
    "an unreachable surface must never report a count it did not take"

  # The same distinction on the read path a drain would use.
  out=$(FM_FINDINGS_DIR="$missing" "$FINDING" list 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "list must refuse an unreachable surface rather than print nothing"
  [ -z "$out" ] || fail "list must print no findings when it reached no surface: $out"

  out=$(FM_FINDINGS_DIR="$missing" "$FINDING" check 2>&1 >/dev/null)
  assert_contains "$out" "does not exist" "the reason must name the concrete defect"
}

test_a_file_that_is_not_a_finding_is_reported_and_never_skipped() {
  local dir out status
  dir=$(surface malformed)
  emit_into "$dir" --observed "2026-08-04T09:14:00Z" >/dev/null || fail "the valid emit"

  # Two ways a surface goes wrong that a naive reader would both swallow: a file
  # it cannot parse, and one it can parse that is missing the load-bearing
  # field. Neither may reduce the surface to a smaller, calmer-looking one.
  printf 'not json at all\n' > "$dir/20260804T100000Z-deadbeef.json"
  jq -n '{schema:"fm-finding/1", id:"20260804T110000Z-cafebabe", class:"judgement",
          claim:"a seat lied", where:"crew-hlr", measurement:"a reading",
          observed:"2026-08-04T11:00:00Z", officer:"po-crew-hlr", severity:"high"}' \
    > "$dir/20260804T110000Z-cafebabe.json"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" list 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "a surface holding non-findings must not read as healthy"
  assert_contains "$out" "sc1 wrote to a project worktree" \
    "the findings that ARE readable must still be listed"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" list 2>&1 >/dev/null)
  assert_contains "$out" "20260804T100000Z-deadbeef.json" "the unparseable file must be named"
  assert_contains "$out" "20260804T110000Z-cafebabe.json" "the incomplete record must be named"
  assert_contains "$out" "refuted_by is missing or empty" \
    "the incomplete record must be named for the field it lacks"
  assert_contains "$out" "incomplete" "the listing must say it is incomplete"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "check must fail on a surface holding non-findings"
  assert_contains "$out" "findings=1" "the readable findings must still be counted"
  assert_contains "$out" "malformed=2" "the unreadable files must be counted separately"
}

test_a_record_the_reader_crashes_on_is_a_violation_and_not_a_pass() {
  local dir out status
  dir=$(surface reader-crash)

  # Well-formed JSON of the wrong shape: the reader cannot index it at all, so
  # its field checks never run. A validator that read its own crash as "no
  # violations found" would call this a finding. That is the same shape as the
  # ladder-hold branch that fired zero times in 2027 log entries - a mechanism
  # reporting a clean result from a reading it never took.
  printf '["a finding, surely"]\n' > "$dir/20260804T120000Z-11111111.json"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "a record the reader cannot process must not be counted as a finding"
  assert_contains "$out" "malformed=1" "the unreadable record must be counted as unreadable"
  assert_contains "$out" "findings=0" "an unreadable record must not be counted as a finding"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" list 2>&1 >/dev/null)
  assert_contains "$out" "could not be read" "the reader must say it could not read the record"
}

test_a_record_renamed_out_from_under_its_id_is_reported() {
  local dir out status id
  dir=$(surface renamed)
  out=$(emit_into "$dir" --observed "2026-08-04T09:14:00Z") || fail "emit"
  id=$(printf '%s\n' "$out" | sed -n 's/^id=//p')
  mv "$dir/$id.json" "$dir/20260804T090000Z-00000000.json"

  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" list 2>&1 >/dev/null) && status=0 || status=$?
  expect_code 4 "$status" "a record listed under a name it does not claim must not pass"
  assert_contains "$out" "does not match the filename stem" \
    "the reason must name the mismatch, not merely reject the file"
}

test_emit_never_creates_the_surface_it_cannot_find() {
  local missing out status
  missing=$TMP_ROOT/emit-never-creates
  out=$(emit_into "$missing" 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "emit must refuse an absent surface"
  assert_contains "$out" "does not exist" "the refusal must name the missing directory"
  [ -e "$missing" ] && fail "emit created a surface nobody reads instead of refusing"

  # init is the one command that makes a surface, and it says that it did.
  out=$(FM_FINDINGS_DIR="$missing" "$FINDING" init) || fail "init must create the surface"
  assert_contains "$out" "created=1" "init must report that it created the surface"
  [ -d "$missing" ] || fail "init must actually create the directory"
  out=$(FM_FINDINGS_DIR="$missing" "$FINDING" init) || fail "init must be idempotent"
  assert_contains "$out" "created=0" "a second init must not claim to have created anything"
}

test_a_surface_that_cannot_be_appended_to_says_so() {
  local dir out status
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: running as root, so mode bits do not block a write"
    return 0
  fi
  dir=$(surface unwritable)
  emit_into "$dir" --observed "2026-08-04T09:14:00Z" >/dev/null || fail "the seeding emit"
  chmod 500 "$dir"

  out=$(emit_into "$dir" --observed "2026-08-05T09:14:00Z" 2>&1) && status=0 || status=$?
  chmod 700 "$dir"
  expect_code 3 "$status" "an append to an unwritable surface must not report success"
  assert_contains "$out" "cannot be appended to" "the refusal must name the concrete block"

  chmod 500 "$dir"
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  chmod 700 "$dir"
  expect_code 3 "$status" "check must fail on a surface no finding can reach"
  assert_contains "$out" "state=append-blocked" \
    "a readable but unappendable surface must be its own state, not ok"
  assert_contains "$out" "findings=1" \
    "the findings already on it were measured, so they still carry a count"
}

test_an_observed_that_is_not_an_instant_never_reaches_the_surface() {
  local dir out status value
  dir=$(surface refuse-observed)

  # A date with no time, a sentence, an instant with no zone, and a value of
  # exactly the right shape naming no real moment. The last one is the reason
  # the shape check alone is not the whole rule.
  for value in "2026-08-04" "some time last week" "2026-08-04T09:14:00" "2026-13-45T99:99:99Z"; do
    out=$(emit_into "$dir" --observed "$value" 2>&1) && status=0 || status=$?
    expect_code 2 "$status" "--observed '$value' is not an instant and must be refused"
    assert_contains "$out" "not an ISO-8601 UTC instant" \
      "the refusal must name the concrete defect in '$value'"
  done

  # The property is the surface's state. A record carrying an unreadable
  # observation is one the drain rule can never place, and nothing rewrites a
  # finding file, so a single accepted emit would wedge that claim forever.
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 0 "$status" "no refused emit may leave the surface unhealthy"
  assert_contains "$out" "findings=0" "no refused emit may leave a record"
}

test_an_observed_carrying_a_path_never_writes_outside_the_surface() {
  local dir outside out status count
  dir=$(surface traversal)
  # A sibling of the surface, and named without a hyphen, because the id drops
  # hyphens: this is the value that really would land a record here.
  outside=$TMP_ROOT/outside
  mkdir -p "$outside"

  # `observed` becomes the id and the id is the filename stem, so an unchecked
  # value carrying a path separator is a write outside the surface reported as
  # an ordinary append.
  out=$(emit_into "$dir" --observed "../outside/pwned" 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an --observed carrying a path must be refused"
  assert_not_contains "$out" "appended=1" "a refused emit must never report an append"

  count=$(find "$outside" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$count" = "0" ] || fail "emit wrote $count file(s) outside the surface"
  out=$(FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null)
  assert_contains "$out" "findings=0" "the surface itself must also be untouched"
}

test_a_surface_with_no_reader_is_its_own_state_and_not_an_unreadable_one() {
  local dir shim out status
  dir=$(surface no-reader)

  # A PATH carrying only what the script needs to reach the question, and no
  # jq. The surface is perfectly readable; the reader is what is missing.
  shim=$TMP_ROOT/no-reader-path
  mkdir -p "$shim"
  ln -s "$(command -v bash)" "$shim/bash"
  ln -s "$(command -v dirname)" "$shim/dirname"

  out=$(PATH="$shim" FM_FINDINGS_DIR="$dir" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "a surface nothing can read must not exit 0"
  assert_contains "$out" "state=reader-missing" \
    "a missing reader must be its own state, not the word for a surface that cannot be reached"
  assert_not_contains "$out" "state=unreadable" \
    "a readable directory must never be reported as one this process cannot read"
  assert_contains "$out" "findings=" "the key must still be present so nothing looks omitted"
  assert_not_contains "$out" "findings=0" \
    "nothing was counted, so no count may be printed"

  out=$(PATH="$shim" FM_FINDINGS_DIR="$dir" "$FINDING" check 2>&1 >/dev/null)
  assert_contains "$out" "jq is not installed" "the reason must name the missing tool"
}

test_the_pointer_names_the_machine_surface_and_an_empty_pointer_refuses() {
  local home shared out status
  home=$TMP_ROOT/pointer-home
  shared=$TMP_ROOT/pointer-shared
  mkdir -p "$home/config" "$home/data" "$shared"
  printf '%s\n' "$shared" > "$home/config/findings-dir"

  out=$(FM_HOME="$home" "$FINDING" check) || fail "the pointer's surface must be used"
  assert_contains "$out" "surface=$shared" "the pointer must name the surface"

  # A pointer that names nothing is a misconfiguration. Falling back to the
  # home-local default would send findings to a directory nobody collects from
  # and report success while doing it.
  : > "$home/config/findings-dir"
  out=$(FM_HOME="$home" "$FINDING" check 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an empty pointer must refuse rather than fall back"
  assert_contains "$out" "names no directory" "the refusal must name the pointer's defect"

  # With no pointer at all the home-local default applies, and it is a real
  # default rather than a silent creation: it still has to be initialised.
  rm -f "$home/config/findings-dir"
  out=$(FM_HOME="$home" "$FINDING" check 2>/dev/null) && status=0 || status=$?
  expect_code 3 "$status" "the default surface is not conjured on first read"
  assert_contains "$out" "surface=$home/data/findings" "the default must be home-local"
}

test_a_judgement_that_cannot_be_refuted_never_reaches_the_surface
test_no_class_escapes_the_refutation_requirement
test_a_finding_carries_its_whole_record_and_is_named_by_its_own_content
test_the_surface_reads_oldest_first
test_an_identical_append_is_the_same_record_and_not_a_second_one
test_an_empty_surface_and_an_unreachable_one_never_read_alike
test_a_file_that_is_not_a_finding_is_reported_and_never_skipped
test_a_record_the_reader_crashes_on_is_a_violation_and_not_a_pass
test_a_record_renamed_out_from_under_its_id_is_reported
test_emit_never_creates_the_surface_it_cannot_find
test_a_surface_that_cannot_be_appended_to_says_so
test_an_observed_that_is_not_an_instant_never_reaches_the_surface
test_an_observed_carrying_a_path_never_writes_outside_the_surface
test_a_surface_with_no_reader_is_its_own_state_and_not_an_unreadable_one
test_the_pointer_names_the_machine_surface_and_an_empty_pointer_refuses

pass "findings surface: refutation is a property of the format, and an unreachable surface never reads as an empty one"
