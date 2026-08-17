#!/usr/bin/env bash
# Behavior tests for the 48-hour fleet knowledge-file curation nudge.
#
# Every property this suite pins was named as a proof obligation when the nudge
# was commissioned, and each is asserted against what the script actually does
# rather than against what its header says it does:
#   - the scheduling function never returns a minute that is a multiple of five,
#     over many draws;
#   - the period is 48 hours, not 24 and not 72;
#   - a firing reaches a supervising session as a wake naming what is due;
#   - nothing here writes to Bridge, opens a network connection, or touches a
#     git repository - asserted by executing every mode with route tripwires;
#   - stopping the thing makes its health reading go bad rather than stay quiet.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one that must see the reporting modes speak.
export FM_CURATION_NUDGE_DISABLE=0

fm_test_tmproot TMP_ROOT fm-curation-nudge-tests

NUDGE="$ROOT/bin/fm-curation-nudge.sh"

fm_mode_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# A home with its own state and data. The script is run from a COPY in the
# home's own bin so --arm resolves fm-check-register.sh beside it and no test
# reaches this checkout's state.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/bin"
  cp "$NUDGE" "$home/bin/fm-curation-nudge.sh"
  cp "$ROOT/bin/fm-check-register.sh" "$home/bin/fm-check-register.sh"
  cp "$ROOT/bin/fm-pr-lib.sh" "$home/bin/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-check-lib.sh" "$home/bin/fm-check-lib.sh"
  chmod +x "$home/bin/fm-curation-nudge.sh" "$home/bin/fm-check-register.sh"
  printf 'learned one\nlearned two\n' > "$home/data/learnings.md"
  printf 'preference one\n' > "$home/data/captain.md"
  printf '%s\n' "$home"
}

run_nudge() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-curation-nudge.sh" "$@"
}

make_failing_mv() {
  local home=$1 target=$2 fakebin real_mv
  fakebin=$(fm_fakebin "$home")
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
if [ "\${!#}" = "$target" ]; then
  exit 1
fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  printf '%s\n' "$fakebin"
}

make_failing_mktemp() {
  local home=$1 status=$2 fakebin real_mktemp
  fakebin=$(fm_fakebin "$home")
  real_mktemp=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  */.curation-nudge-health.*) exit $status ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$fakebin/mktemp"
  printf '%s\n' "$fakebin"
}

record_value() {
  local home=$1 key=$2
  sed -n "s/^$key: //p" "$home/state/curation-nudge.report"
}

# --- the five-minute refusal ------------------------------------------------

test_the_scheduler_never_lands_on_the_five_minute_grid() {
  local home draws on_grid count
  home=$(make_home grid)

  # 2000 independent draws. The refusal is the property under test, so a merely
  # unlikely hit must fail this case rather than pass it.
  draws=$(run_nudge "$home" --draw 2000) || fail "the scheduler refused to draw at all"
  count=$(printf '%s\n' "$draws" | grep -c .)
  [ "$count" -eq 2000 ] || fail "expected 2000 draws, got $count"
  on_grid=$(printf '%s\n' "$draws" | awk '{ if (int($1 / 60) % 60 % 5 == 0) n++ } END { print n + 0 }')
  [ "$on_grid" -eq 0 ] \
    || fail "$on_grid of $count drawn targets landed on a five-minute boundary"
  pass "2000 drawn targets, none on a multiple-of-five minute"
}

test_a_window_with_no_off_grid_minute_refuses_rather_than_scheduling_on_it() {
  local home out status=0
  home=$(make_home refuse)

  # Pin the jitter to a single second whose target minute IS on the grid: 48h is
  # a whole number of hours, so base 0 plus 172800 plus 0 lands on minute 0. The
  # refusal must exhaust and report, never fall back to the on-grid target.
  out=$(FM_CURATION_NUDGE_NOW=0 FM_CURATION_NUDGE_JITTER_MIN=0 FM_CURATION_NUDGE_JITTER_MAX=0 \
    run_nudge "$home" --draw 1 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a window containing only an on-grid minute must refuse: $out"
  assert_contains "$out" 'refusing to schedule' \
    "the refusal must say it refused rather than reporting an empty draw"
  pass "a window with no off-grid minute refuses instead of accepting one"
}

test_initial_detect_loudly_explains_an_exhausted_draw() {
  local home out now report report_next status_next
  home=$(make_home initial-refusal)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
  now=$(( $(date +%s) / 300 * 300 ))

  out=$(FM_CURATION_NUDGE_NOW="$now" FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home")
  assert_contains "$out" 'CURATION_NUDGE:' \
    "an initial draw failure must immediately raise a wake"
  assert_contains "$out" 'all 64 candidate minutes' \
    "the wake must name the exhausted draw bound and concrete cause"
  assert_contains "$out" 'landed on the five-minute grid' \
    "the wake must distinguish draw refusal from dead supervision"
  assert_contains "$out" 'FM_CURATION_NUDGE_JITTER_MIN=0' \
    "the wake must carry the effective jitter minimum"
  assert_contains "$out" 'FM_CURATION_NUDGE_JITTER_MAX=0' \
    "the wake must carry the effective jitter maximum"
  assert_contains "$out" 'FM_CURATION_NUDGE_INTERVAL=172800' \
    "the wake must carry the effective interval"
  assert_not_contains "$out" 'nothing is running this home' \
    "a draw refusal must not masquerade as a watcher failure"
  report="$home/state/curation-nudge.report"
  [ "$(record_value "$home" state)" = refused ] || fail "the refusal was not persisted"
  [ "$(record_value "$home" next-epoch)" = 0 ] || fail "the refusal persisted an on-grid target"
  [ "$(record_value "$home" refusal-recorded-epoch)" = "$now" ] || fail "the refusal omitted its epoch"
  [ "$(record_value "$home" jitter-min-seconds)" = 0 ] || fail "the refusal omitted its jitter minimum"
  [ "$(record_value "$home" jitter-max-seconds)" = 0 ] || fail "the refusal omitted its jitter maximum"
  [ "$(record_value "$home" interval-seconds)" = 172800 ] || fail "the refusal omitted its interval"
  [ "$(record_value "$home" draw-attempts)" = 64 ] || fail "the refusal omitted its attempt bound"

  out=$(FM_CURATION_NUDGE_NOW=$(( now + 7200 )) run_nudge "$home" --armed)
  assert_contains "$out" 'scheduler has refused' \
    "the later health reading must preserve the scheduling cause"
  assert_contains "$out" 'for 120 minute(s)' \
    "the health reading must say how long the refusal has stood"
  assert_contains "$out" 'all 64 candidate minutes' \
    "the later health reading must retain the attempt bound"
  assert_contains "$out" 'FM_CURATION_NUDGE_JITTER_MIN=0' \
    "the later health reading must retain the effective operands"
  assert_not_contains "$out" 'nothing is running this home' \
    "a persisted draw refusal must not masquerade as dead supervision"

  out=$(FM_CURATION_NUDGE_NOW=$(( now + 60 )) FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home")
  [ -z "$out" ] || fail "a successful recovery draw must be silent: $out"
  [ "$(record_value "$home" state)" = scheduled ] || fail "a successful draw did not replace the refusal"
  report_next=$(grep '^next:' "$report")
  status_next=$(FM_CURATION_NUDGE_NOW=$(( now + 60 )) run_nudge "$home" --status | grep '^next:')
  [ "$report_next" = "$status_next" ] \
    || fail "recovery from refusal left the report inconsistent: $report_next != $status_next"
  assert_not_contains "$(cat "$report")" 'refused' \
    "recovery from refusal must replace the stale report outcome"
  assert_not_contains "$(cat "$report")" 'successor scheduling follows' \
    "recovery from refusal must clear any pending report outcome"
  out=$(FM_CURATION_NUDGE_NOW=$(( now + 60 )) run_nudge "$home" --armed)
  [ -z "$out" ] || fail "a recovered scheduler must have a silent health reading: $out"
  pass "draw refusal remains distinct from supervision failure and clears on recovery"
}

test_a_refused_successor_records_the_firing_and_the_refusal() {
  local home due jitter out report
  home=$(make_home refused-successor)
  run_nudge "$home" >/dev/null
  due=$(record_value "$home" next-epoch)
  jitter=$(( (300 - due % 300) % 300 ))

  out=$(FM_CURATION_NUDGE_NOW="$due" FM_CURATION_NUDGE_JITTER_MIN="$jitter" \
    FM_CURATION_NUDGE_JITTER_MAX="$jitter" run_nudge "$home")
  assert_contains "$out" 'no next curation sweep was scheduled' \
    "a refused successor must report the scheduling refusal"
  assert_contains "$out" 'curation sweep is due' \
    "the completed firing must still emit its wake"
  [ "$(record_value "$home" last-fire-epoch)" = "$due" ] \
    || fail "the completed firing did not advance last-fire"
  report="$home/state/curation-nudge.report"
  assert_grep 'next: refused because all 64 candidate minutes' "$report" \
    "the firing report must record the final refusal and its cause"
  assert_not_contains "$(cat "$report")" 'successor scheduling follows' \
    "a refused successor must not leave a pending report"
  out=$(FM_CURATION_NUDGE_NOW="$due" run_nudge "$home" --status)
  assert_not_contains "$out" 'last-fire: never' \
    "status must retain the firing despite successor refusal"
  out=$(FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$out" 'scheduler has refused' \
    "health must retain the refusal rather than inventing a firing"
  pass "a refused successor records both the firing and refusal"
}

test_unchanged_refusal_is_surfaced_once_and_resets() {
  local home now first second third
  home=$(make_home refusal-dedup)
  run_nudge "$home" --arm >/dev/null
  now=$(( $(date +%s) / 300 * 300 ))

  first=$(FM_CURATION_NUDGE_NOW="$now" FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home")
  assert_contains "$first" 'no next curation sweep was scheduled' \
    "the first refusal must be immediate"
  second=$(FM_CURATION_NUDGE_NOW=$(( now + 300 )) FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home")
  [ -z "$second" ] || fail "an unchanged refusal repeated: $second"

  FM_CURATION_NUDGE_NOW=$(( now + 60 )) FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home" >/dev/null
  rm -f "$home/state/curation-nudge.report"
  third=$(FM_CURATION_NUDGE_NOW=$(( now + 600 )) FM_CURATION_NUDGE_JITTER_MIN=0 \
    FM_CURATION_NUDGE_JITTER_MAX=0 run_nudge "$home")
  assert_contains "$third" 'no next curation sweep was scheduled' \
    "the refusal must surface again after clearing"
  pass "unchanged refusal is surfaced once and resets after clearing"
}

test_unavailable_state_path_is_loud() {
  local home blocked state_path out status
  home=$(make_home unavailable-state)
  blocked="$home/blocked"
  state_path="$blocked/state"
  printf 'not a directory\n' > "$blocked"

  status=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state_path" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-curation-nudge.sh") || status=$?
  [ "$status" -ne 0 ] || fail "detect accepted an unavailable state path: $out"
  assert_contains "$out" 'state persistence failure' \
    "detect must report unavailable state"
  assert_contains "$out" "$state_path" \
    "detect must name the unavailable state path"

  status=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state_path" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-curation-nudge.sh" --armed) || status=$?
  [ "$status" -ne 0 ] || fail "--armed accepted an unavailable state path: $out"
  assert_contains "$out" 'state persistence failure' \
    "--armed must report unavailable state"
  assert_contains "$out" "$state_path" \
    "--armed must name the unavailable state path"
  pass "unavailable state path is loud in detect and health modes"
}

test_transient_publish_failure_becomes_a_supervision_diagnosis() {
  local home due out status=0 fakebin report before retry armed
  home=$(make_home record-publish-failure)
  run_nudge "$home" >/dev/null
  report="$home/state/curation-nudge.report"
  due=$(record_value "$home" next-epoch)
  before=$(cat "$report")
  fakebin=$(make_failing_mv "$home" "$report")

  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$due" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "a failed authoritative publish reported success: $out"
  assert_contains "$out" 'state persistence failure' "the failed publish must be actionable"
  assert_not_contains "$out" 'curation sweep is due' "a failed publish must not emit the wake"
  [ "$(cat "$report")" = "$before" ] || fail "a failed publish changed the authoritative record"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "a failed publish consumed the due event"
  armed=$(FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'nothing is executing it' \
    "a usable state path must identify the remaining overdue target as supervision"
  assert_not_contains "$armed" 'state persistence failure' \
    "a recovered state path must not retain a transient persistence diagnosis"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "health consumed the preserved due event"
  retry=$(FM_CURATION_NUDGE_NOW="$due" run_nudge "$home")
  assert_contains "$retry" 'curation sweep is due' "the next sweep must retry the same due event"
  pass "transient publish failure leaves a truthful supervision diagnosis"
}

test_unusable_state_path_preserves_the_publish_failure_diagnosis() {
  local home due out status=0 fakebin probe_bin report before armed
  home=$(make_home persistent-publish-failure)
  run_nudge "$home" >/dev/null
  report="$home/state/curation-nudge.report"
  due=$(record_value "$home" next-epoch)
  before=$(cat "$report")
  fakebin=$(make_failing_mv "$home" "$report")

  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$due" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "a failed authoritative publish reported success: $out"
  probe_bin=$(make_failing_mktemp "$home" 1)
  armed=$(PATH="$probe_bin:$PATH" FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state persistence failure' \
    "an unusable state path must retain the persistence diagnosis"
  assert_contains "$armed" 'temporary state cannot be created' \
    "the persistence diagnosis must name the observed condition"
  assert_not_contains "$armed" 'nothing is executing it' \
    "an unusable state path must not be called a supervision outage"
  [ "$(cat "$report")" = "$before" ] || fail "health changed the authoritative record"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "health consumed the preserved due event"
  pass "unusable state path keeps publish failure distinct from supervision"
}

test_indeterminate_state_probe_names_both_possible_causes() {
  local home due out status=0 fakebin probe_bin report before armed
  home=$(make_home indeterminate-publish-failure)
  run_nudge "$home" >/dev/null
  report="$home/state/curation-nudge.report"
  due=$(record_value "$home" next-epoch)
  before=$(cat "$report")
  fakebin=$(make_failing_mv "$home" "$report")

  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$due" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "a failed authoritative publish reported success: $out"
  probe_bin=$(make_failing_mktemp "$home" 126)
  armed=$(PATH="$probe_bin:$PATH" FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state health indeterminate' \
    "an unavailable instrument must report an indeterminate reading"
  assert_contains "$armed" 'state publication failure' \
    "the indeterminate reading must name the persistence candidate"
  assert_contains "$armed" 'supervision outage' \
    "the indeterminate reading must name the supervision candidate"
  assert_contains "$armed" 'asserts neither cause' \
    "the indeterminate reading must refuse to choose a cause"
  assert_not_contains "$armed" 'state persistence failure at' \
    "the indeterminate reading must not assert persistence"
  assert_not_contains "$armed" 'nothing is executing it' \
    "the indeterminate reading must not assert supervision"
  [ "$(cat "$report")" = "$before" ] || fail "health changed the authoritative record"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "health consumed the preserved due event"
  pass "indeterminate state probe names both causes and asserts neither"
}

test_missing_record_with_unusable_state_reports_persistence() {
  local home now out status=0 fakebin probe_bin armed
  home=$(make_home missing-record-persistence)
  run_nudge "$home" --arm >/dev/null
  now=$(date +%s)
  fakebin=$(make_failing_mv "$home" "$home/state/curation-nudge.report")
  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$now" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "the first failed publish reported success: $out"
  [ ! -e "$home/state/curation-nudge.report" ] || fail "the failed first publish left a record"

  probe_bin=$(make_failing_mktemp "$home" 1)
  armed=$(PATH="$probe_bin:$PATH" FM_CURATION_NUDGE_NOW=$(( now + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state persistence failure' \
    "a missing record with unusable state must report persistence"
  assert_contains "$armed" 'cannot persist its first authoritative schedule' \
    "the missing-record diagnosis must name the failed work"
  assert_not_contains "$armed" 'nothing is running this home' \
    "unusable state must not be called a missing watcher"
  [ ! -e "$home/state/curation-nudge.report" ] || fail "health created a missing record"
  pass "missing record with unusable state stays a persistence diagnosis"
}

test_missing_record_with_usable_state_reports_supervision() {
  local home now out status=0 fakebin armed
  home=$(make_home missing-record-supervision)
  run_nudge "$home" --arm >/dev/null
  now=$(date +%s)
  fakebin=$(make_failing_mv "$home" "$home/state/curation-nudge.report")
  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$now" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "the first failed publish reported success: $out"

  armed=$(FM_CURATION_NUDGE_NOW=$(( now + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'nothing is running this home' \
    "a missing record with recovered state must report supervision"
  assert_not_contains "$armed" 'state persistence failure' \
    "usable state must not retain a transient persistence diagnosis"
  assert_not_contains "$armed" 'state health indeterminate' \
    "usable state must not report an indeterminate diagnosis"
  [ ! -e "$home/state/curation-nudge.report" ] || fail "health created a missing record"
  pass "missing record with usable state becomes a supervision diagnosis"
}

test_missing_record_with_indeterminate_state_names_both_causes() {
  local home now out status=0 fakebin probe_bin armed
  home=$(make_home missing-record-indeterminate)
  run_nudge "$home" --arm >/dev/null
  now=$(date +%s)
  fakebin=$(make_failing_mv "$home" "$home/state/curation-nudge.report")
  out=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW="$now" run_nudge "$home") || status=$?
  [ "$status" -ne 0 ] || fail "the first failed publish reported success: $out"

  probe_bin=$(make_failing_mktemp "$home" 126)
  armed=$(PATH="$probe_bin:$PATH" FM_CURATION_NUDGE_NOW=$(( now + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state health indeterminate' \
    "an unavailable missing-record probe must report indeterminate health"
  assert_contains "$armed" 'state publication failure' \
    "the indeterminate reading must name the persistence candidate"
  assert_contains "$armed" 'supervision outage' \
    "the indeterminate reading must name the supervision candidate"
  assert_contains "$armed" 'asserts neither cause' \
    "the indeterminate reading must refuse to choose a cause"
  assert_not_contains "$armed" 'state persistence failure at' \
    "the indeterminate reading must not assert persistence"
  assert_not_contains "$armed" 'nothing is running this home' \
    "the indeterminate reading must not assert supervision"
  [ ! -e "$home/state/curation-nudge.report" ] || fail "health created a missing record"
  pass "missing record with indeterminate state names both causes"
}

test_the_period_is_forty_eight_hours() {
  local home draws min max
  home=$(make_home period)

  draws=$(FM_CURATION_NUDGE_NOW=1000000 run_nudge "$home" --draw 400) \
    || fail "the scheduler refused to draw"
  min=$(printf '%s\n' "$draws" | sort -n | head -1)
  max=$(printf '%s\n' "$draws" | sort -n | tail -1)

  # 48h = 172800s. Every target sits inside 172800 + [180, 420] from the base,
  # which excludes 24h and 72h by construction rather than by a nominal check.
  [ "$((min - 1000000))" -ge 172980 ] \
    || fail "a target fell short of 48 hours plus the minimum jitter: $((min - 1000000))s"
  [ "$((max - 1000000))" -le 173220 ] \
    || fail "a target exceeded 48 hours plus the maximum jitter: $((max - 1000000))s"
  [ "$((min - 1000000))" -gt 86400 ] || fail "the period collapsed to a day or less"
  [ "$((max - 1000000))" -lt 259200 ] || fail "the period stretched to three days or more"
  pass "every target is 48 hours plus 3-7 minutes from its base, never 24 or 72"
}

test_successive_firings_drift_rather_than_repeating_one_time() {
  local home i first target distinct
  home=$(make_home drift)
  first=''
  distinct=0
  for i in 1 2 3 4 5 6 7 8; do
    target=$(FM_CURATION_NUDGE_NOW=$(( 1000000 + i )) run_nudge "$home" --draw 1) \
      || fail "the scheduler refused to draw"
    # Strip the identical base so only the jitter is compared.
    target=$(( target - 1000000 - i ))
    if [ -z "$first" ]; then
      first=$target
    elif [ "$target" != "$first" ]; then
      distinct=1
    fi
  done
  [ "$distinct" -eq 1 ] \
    || fail "eight draws from the same base all produced the same jitter, so nothing drifts"
  pass "jitter is drawn fresh per firing, so successive fires drift"
}

# --- the cadence and the wake -----------------------------------------------

test_arming_schedules_the_first_sweep_without_waking_anyone() {
  local home out due report_next status_next
  home=$(make_home first)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"

  out=$(run_nudge "$home")
  [ -z "$out" ] || fail "arming a home must not immediately wake it: $out"
  due=$(record_value "$home" next-epoch)
  case "${due:-}" in ''|*[!0-9]*) fail "the first sweep was not scheduled" ;; esac
  [ "$(record_value "$home" last-fire-epoch)" = 0 ] \
    || fail "scheduling the first sweep must not record a firing"
  report_next=$(grep '^next:' "$home/state/curation-nudge.report")
  status_next=$(run_nudge "$home" --status | grep '^next:')
  [ "$report_next" = "$status_next" ] \
    || fail "the initial schedule and report disagree: $report_next != $status_next"
  pass "arming schedules the first sweep and stays silent"
}

test_a_firing_reaches_a_session_as_a_wake_that_names_what_is_due() {
  local home out due later report report_last report_next status_last status_next
  home=$(make_home fire)
  run_nudge "$home" >/dev/null
  due=$(record_value "$home" next-epoch)

  # One second before the target the sweep is silent; at the target it speaks.
  out=$(FM_CURATION_NUDGE_NOW=$(( due - 1 )) run_nudge "$home")
  [ -z "$out" ] || fail "a sweep before the target must not fire: $out"

  out=$(FM_CURATION_NUDGE_NOW="$due" run_nudge "$home")
  assert_contains "$out" 'CURATION_NUDGE:' "the firing must print a wake line"
  assert_contains "$out" 'curation sweep is due' "the wake must name what is due"
  assert_contains "$out" 'data/learnings.md' "the wake must name the files to measure"
  assert_contains "$out" 'data/captain.md' "the wake must name both files to measure"
  assert_contains "$out" 'session-start digest' "the wake must ask for the digest share"
  assert_contains "$out" 'All-Ships' "the wake must name the notice firstmate then dispatches"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
    || fail "the wake must be one line, so a watcher sweep surfaces it whole"

  later=$(record_value "$home" next-epoch)
  [ "$later" -gt "$due" ] || fail "firing must schedule the next sweep"
  [ "$(record_value "$home" last-fire-epoch)" = "$due" ] \
    || fail "firing must record when it actually fired"

  report="$home/state/curation-nudge.report"
  assert_grep 'reading: this vessel data/learnings.md 2 lines' "$report" \
    "the record must carry this vessel's own measurement"
  report_next=$(grep '^next:' "$report")
  status_next=$(run_nudge "$home" --status | grep '^next:')
  [ "$report_next" = "$status_next" ] \
    || fail "the firing report does not match the committed successor: $report_next != $status_next"
  assert_contains "$report_next" "minute $(( later / 60 % 60 )), off the five-minute grid" \
    "the firing report must name the committed successor minute"
  assert_not_contains "$(cat "$report")" 'successor scheduling follows' \
    "the finalized firing report must not retain a pending placeholder"
  report_last=$(grep '^last-fire:' "$report")
  status_last=$(run_nudge "$home" --status | grep '^last-fire:')
  [ "$report_last" = "$status_last" ] \
    || fail "the first report describes a different firing than last-fire"
  assert_not_contains "$report_last" 'never' \
    "the first report must name the firing it records"
  pass "a firing wakes a session with one line naming what is due"
}

test_the_second_report_describes_the_second_firing() {
  local home first_due second_due first_last second_last status_last
  home=$(make_home second-report)
  run_nudge "$home" >/dev/null
  first_due=$(record_value "$home" next-epoch)
  FM_CURATION_NUDGE_NOW="$first_due" run_nudge "$home" >/dev/null
  first_last=$(grep '^last-fire:' "$home/state/curation-nudge.report")
  second_due=$(record_value "$home" next-epoch)

  FM_CURATION_NUDGE_NOW="$second_due" run_nudge "$home" >/dev/null
  second_last=$(grep '^last-fire:' "$home/state/curation-nudge.report")
  status_last=$(run_nudge "$home" --status | grep '^last-fire:')
  [ "$second_last" != "$first_last" ] \
    || fail "the second report still describes the first firing"
  [ "$second_last" = "$status_last" ] \
    || fail "the second report and last-fire describe different events"
  pass "the second report describes the second firing"
}

test_the_wake_prompts_measurement_and_claims_nothing_about_another_vessel() {
  local home out
  home=$(make_home claims)
  out=$(run_nudge "$home" --force)
  assert_contains "$out" 'measure its OWN' "the payload must be a prompt to measure"
  assert_contains "$out" 'Nothing is claimed about any other vessel.' \
    "the payload must disclaim any reading of another vessel"
  assert_contains "$out" "This vessel's own reading" \
    "this seat's own numbers must be marked as its own"
  assert_contains "$out" 'decide for itself' \
    "each vessel decides its own split, so the payload must not decide one"
  assert_not_contains "$out" 'prune' \
    "the nudge asks for a measurement; it must not prescribe the curation itself"
  pass "the payload prompts each vessel to measure and decide for itself"
}

test_a_home_that_was_off_schedules_one_sweep_ahead_rather_than_catching_up() {
  local home due first second
  home=$(make_home away)
  run_nudge "$home" >/dev/null
  due=$(record_value "$home" next-epoch)

  # A week past the target: it fires once and re-bases on now, so the next sweep
  # is a fresh 48 hours away instead of a backlog of missed windows.
  first=$(FM_CURATION_NUDGE_NOW=$(( due + 604800 )) run_nudge "$home")
  assert_contains "$first" 'CURATION_NUDGE:' "a long-overdue sweep must fire"
  second=$(FM_CURATION_NUDGE_NOW=$(( due + 604801 )) run_nudge "$home")
  [ -z "$second" ] || fail "the sweep must not fire again immediately: $second"
  [ "$(record_value "$home" next-epoch)" -ge $(( due + 604800 + 172980 )) ] \
    || fail "the next sweep must be a full period from the firing, not from the missed target"
  pass "a home that was off fires once and re-bases instead of catching up"
}

# --- the boundary: no Bridge, no network, no repository ---------------------

test_no_bridge_or_network_binary_is_ever_invoked() {
  local home fakebin trip tool shim
  home=$(make_home tripwire)
  fakebin=$(fm_fakebin "$home")
  trip="$home/tripped"
  mkdir -p "$trip"
  # Tripwires named after every route out of this machine. If any mode reaches
  # for one of them, its name appears in $trip and the case fails - an assertion
  # by execution, not by reading the source.
  for tool in fm-bridge-relay.sh bridge-axi gh gh-axi git curl wget nc ssh scp; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
: > "$trip/\$(basename "\$0")"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done

  PATH="$fakebin:$PATH" run_nudge "$home" --arm >/dev/null || fail "arming failed"
  shim="$home/state/curation-nudge.check.sh"
  [ -x "$shim" ] || fail "arming did not create the registered watcher shim"
  [ -f "$home/state/curation-nudge.check-trust" ] \
    || fail "arming did not register the watcher shim"
  PATH="$fakebin:$PATH" "$shim" >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --force >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --status >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --armed >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --draw 3 >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --help >/dev/null

  tool=$(ls -A "$trip")
  [ -z "$tool" ] || fail "the nudge invoked: $tool"
  pass "the registered shim and every mode avoid Bridge, forge, network, and git"
}

# --- arming, and the health reading that is not a unit's own claim ----------

test_arming_is_idempotent_and_registers_the_check() {
  local home first second
  home=$(make_home arm)

  run_nudge "$home" --arm >/dev/null || fail "arming failed"
  [ -x "$home/state/curation-nudge.check.sh" ] || fail "the watcher check was not written"
  [ -f "$home/state/curation-nudge.check-trust" ] || fail "the watcher check was not registered"
  [ "$(fm_mode_of "$home/state/curation-nudge.check.sh")" = 700 ] \
    || fail "the watcher check must be private and executable"
  first=$(cat "$home/state/curation-nudge.check.sh")

  run_nudge "$home" --arm >/dev/null || fail "re-arming failed"
  second=$(cat "$home/state/curation-nudge.check.sh")
  [ "$first" = "$second" ] || fail "re-arming rewrote an already-correct check"
  pass "arming writes a private registered check and converges on re-run"
}

test_a_healthy_nudge_reports_nothing() {
  local home out
  home=$(make_home healthy)
  run_nudge "$home" --arm >/dev/null
  run_nudge "$home" >/dev/null
  out=$(run_nudge "$home" --armed)
  [ -z "$out" ] || fail "a scheduled, armed nudge must be silent: $out"
  pass "an armed nudge with a live target says nothing"
}

test_stopping_the_nudge_makes_the_health_reading_fail() {
  local home out due
  home=$(make_home stopped)
  run_nudge "$home" --arm >/dev/null
  run_nudge "$home" >/dev/null
  out=$(run_nudge "$home" --force)
  assert_contains "$out" 'CURATION_NUDGE:' "the nudge must fire before it is stopped"
  due=$(record_value "$home" next-epoch)

  # Stop it the way a dead timer stops: the schedule stays, the shim stays, and
  # nothing executes it. Every surface still looks armed; only the target going
  # further and further past due gives it away.
  out=$(FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$out" 'CURATION_NUDGE:' "a target nothing executes must be loud"
  assert_contains "$out" 'nothing is executing it' \
    "the reading must say the schedule stands and nothing is running it"
  assert_contains "$out" 'it last fired' \
    "the reading must report when the nudge last actually fired"
  pass "a nudge that stopped firing reports a bad reading rather than staying quiet"
}

test_a_nudge_that_never_scheduled_a_target_is_loud() {
  local home out shim
  home=$(make_home notrigger)
  run_nudge "$home" --arm >/dev/null
  shim="$home/state/curation-nudge.check.sh"

  # The bridge-notify-poll.timer shape: armed, loaded, enabled - and no next
  # trigger at all. Fresh arming is not a fault, so this only speaks once the
  # shim has been sitting there longer than a sweep could plausibly take.
  out=$(run_nudge "$home" --armed)
  [ -z "$out" ] || fail "a freshly armed home must not be called stopped: $out"

  out=$(FM_CURATION_NUDGE_NOW=$(( $(date +%s) + 7200 )) run_nudge "$home" --armed)
  assert_contains "$out" 'never published its authoritative schedule' \
    "an armed home with no next trigger must say so"
  [ -f "$shim" ] || fail "the case must not have removed the shim"
  pass "an armed home with no next trigger is loud, exactly where a unit state would lie"
}

test_an_unarmed_home_is_loud() {
  local home out
  home=$(make_home unarmed)
  out=$(run_nudge "$home" --armed)
  assert_contains "$out" 'is not armed' "an unarmed home must say nothing is watching"

  run_nudge "$home" --arm >/dev/null
  rm -f "$home/state/curation-nudge.check.sh"
  out=$(run_nudge "$home" --armed)
  assert_contains "$out" 'is not armed' "removing the check must make the reading fail"
  pass "an unarmed home, and one whose check was removed, are both loud"
}

test_status_reports_the_schedule_without_advancing_it() {
  local home out before
  home=$(make_home status)
  run_nudge "$home" >/dev/null
  before=$(record_value "$home" next-epoch)

  out=$(run_nudge "$home" --status)
  assert_contains "$out" 'next: ' "--status must print the next scheduled sweep"
  assert_contains "$out" 'last-fire: never' "--status must say when it last actually fired"
  assert_contains "$out" 'reading: this vessel data/learnings.md 2 lines' \
    "--status must print this vessel's own readings"
  assert_contains "$out" 'each vessel measures its own' \
    "--status must state the share it deliberately does not measure"
  [ "$(record_value "$home" next-epoch)" = "$before" ] \
    || fail "--status must not advance the schedule"
  [ "$(record_value "$home" last-fire-epoch)" = 0 ] \
    || fail "--status must not record a firing"
  pass "--status reports the schedule and readings without advancing anything"
}

test_a_disabled_nudge_stays_out_of_composing_suites() {
  local home out
  home=$(make_home disabled)
  run_nudge "$home" --arm >/dev/null

  out=$(FM_CURATION_NUDGE_DISABLE=1 run_nudge "$home")
  [ -z "$out" ] || fail "the detect mode must be silent when disabled: $out"
  out=$(FM_CURATION_NUDGE_DISABLE=1 run_nudge "$home" --armed)
  [ -z "$out" ] || fail "the armed reading must be silent when disabled: $out"
  out=$(FM_CURATION_NUDGE_DISABLE=1 run_nudge "$home" --status)
  assert_contains "$out" 'cadence: ' "--status must ignore the disable switch"
  out=$(FM_CURATION_NUDGE_DISABLE=1 run_nudge "$home" --draw 1)
  case "$out" in ''|*[!0-9]*) fail "--draw must ignore the disable switch" ;; esac
  pass "the disable switch silences only the reporting modes"
}

test_every_public_mode_has_an_executable_contract() {
  local home out status
  home=$(make_home public-modes)
  rmdir "$home/state" || fail "could not prepare a home without state"

  status=0
  out=$(run_nudge "$home" --draw 1) || status=$?
  [ "$status" -eq 0 ] || fail "--draw exited $status without state: $out"
  case "$out" in ''|*[!0-9]*) fail "--draw must emit one epoch: $out" ;; esac
  [ ! -e "$home/state" ] || fail "--draw created state on a fresh home"

  status=0
  out=$(run_nudge "$home" --status) || status=$?
  [ "$status" -eq 0 ] || fail "--status exited $status without state: $out"
  assert_contains "$out" 'next: none' "--status must report an absent schedule"
  assert_contains "$out" 'last-fire: never' "--status must report an absent firing"
  [ ! -e "$home/state" ] || fail "--status created state on a fresh home"

  status=0
  out=$(run_nudge "$home" --arm) || status=$?
  [ "$status" -eq 0 ] || fail "--arm exited $status: $out"
  assert_contains "$out" 'armed: ' "--arm must report the registered check"

  status=0
  out=$(run_nudge "$home") || status=$?
  [ "$status" -eq 0 ] || fail "bare detect exited $status: $out"
  [ -z "$out" ] || fail "a healthy bare detect must be silent: $out"
  [ "$(record_value "$home" state)" = scheduled ] \
    || fail "bare detect must establish the initial schedule"

  status=0
  out=$(run_nudge "$home" --armed) || status=$?
  [ "$status" -eq 0 ] || fail "--armed exited $status: $out"
  [ -z "$out" ] || fail "a healthy --armed reading must be silent: $out"

  status=0
  out=$(run_nudge "$home" --status) || status=$?
  [ "$status" -eq 0 ] || fail "--status exited $status: $out"
  assert_contains "$out" 'cadence: ' "--status must render the cadence"

  status=0
  out=$(run_nudge "$home" --draw 1) || status=$?
  [ "$status" -eq 0 ] || fail "--draw exited $status: $out"
  case "$out" in ''|*[!0-9]*) fail "--draw must emit one epoch: $out" ;; esac

  status=0
  out=$(run_nudge "$home" --force) || status=$?
  [ "$status" -eq 0 ] || fail "--force exited $status: $out"
  assert_contains "$out" 'curation sweep is due' \
    "--force must unconditionally emit the curation wake"
  pass "every public mode executes with its observable contract"
}

test_bootstrap_arms_the_nudge_and_asks_whether_it_is_still_running() {
  local home out shim
  home=$(make_home bootstrap)
  mkdir -p "$home/config"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CURATION_NUDGE_DISABLE=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" 'CURATION_NUDGE:' \
    "bootstrap must leave a freshly armed nudge healthy"
  shim="$home/state/curation-nudge.check.sh"
  [ -x "$shim" ] || fail "bootstrap did not arm the watcher shim"
  [ -f "$home/state/curation-nudge.check-trust" ] \
    || fail "bootstrap did not register the watcher shim"

  rm -f "$shim"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CURATION_NUDGE_DISABLE=0 \
    "$ROOT/bin/fm-curation-nudge.sh" --armed)
  assert_contains "$out" 'CURATION_NUDGE:' \
    "an unarmed bootstrap home must produce the owned diagnostic"
  assert_contains "$out" 'is not armed' \
    "the diagnostic must expose the stopped watcher state"
  pass "bootstrap observably arms, registers, and diagnoses the nudge"
}

test_the_scheduler_never_lands_on_the_five_minute_grid
test_a_window_with_no_off_grid_minute_refuses_rather_than_scheduling_on_it
test_initial_detect_loudly_explains_an_exhausted_draw
test_a_refused_successor_records_the_firing_and_the_refusal
test_unchanged_refusal_is_surfaced_once_and_resets
test_unavailable_state_path_is_loud
test_transient_publish_failure_becomes_a_supervision_diagnosis
test_unusable_state_path_preserves_the_publish_failure_diagnosis
test_indeterminate_state_probe_names_both_possible_causes
test_missing_record_with_unusable_state_reports_persistence
test_missing_record_with_usable_state_reports_supervision
test_missing_record_with_indeterminate_state_names_both_causes
test_the_period_is_forty_eight_hours
test_successive_firings_drift_rather_than_repeating_one_time
test_arming_schedules_the_first_sweep_without_waking_anyone
test_a_firing_reaches_a_session_as_a_wake_that_names_what_is_due
test_the_second_report_describes_the_second_firing
test_the_wake_prompts_measurement_and_claims_nothing_about_another_vessel
test_a_home_that_was_off_schedules_one_sweep_ahead_rather_than_catching_up
test_no_bridge_or_network_binary_is_ever_invoked
test_arming_is_idempotent_and_registers_the_check
test_a_healthy_nudge_reports_nothing
test_stopping_the_nudge_makes_the_health_reading_fail
test_a_nudge_that_never_scheduled_a_target_is_loud
test_an_unarmed_home_is_loud
test_status_reports_the_schedule_without_advancing_it
test_a_disabled_nudge_stays_out_of_composing_suites
test_every_public_mode_has_an_executable_contract
test_bootstrap_arms_the_nudge_and_asks_whether_it_is_still_running
