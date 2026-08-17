#!/usr/bin/env bash
# Behavior tests for the off-grid fleet nudges: one watcher check, several
# subjects, each with its own period, record, and payload.
#
# Every property this suite pins was named as a proof obligation when the nudge
# was commissioned, and each is asserted against what the script actually does
# rather than against what its header says it does:
#   - the scheduling function never returns a minute that is a multiple of five,
#     over many draws, for EVERY registered subject;
#   - the curation period is 48 hours, not 24 and not 72; the codebase-sweep
#     period is 52 hours, and no two subjects share a period;
#   - the two subjects do not travel together - their targets stay far apart
#     over a long simulated run, measured rather than asserted;
#   - a firing reaches a supervising session as a wake naming what is due;
#   - one shim serves every subject, and arming retires the single-subject
#     predecessor rather than leaving a silent sibling behind;
#   - nothing here writes to Bridge, opens a network connection, or touches a
#     git repository - asserted by executing every mode with route tripwires;
#   - stopping the thing makes EVERY subject's health reading go bad rather than
#     stay quiet, and one subject going bad never silences another.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one that must see the reporting modes speak, for every
# subject tests/lib.sh silences suite-wide.
export FM_CURATION_NUDGE_DISABLE=0
export FM_CODEBASE_SWEEP_NUDGE_DISABLE=0

fm_test_tmproot TMP_ROOT fm-nudge-tests

NUDGE="$ROOT/bin/fm-nudge.sh"

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
  cp "$NUDGE" "$home/bin/fm-nudge.sh"
  cp "$ROOT/bin/fm-check-register.sh" "$home/bin/fm-check-register.sh"
  cp "$ROOT/bin/fm-pr-lib.sh" "$home/bin/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-check-lib.sh" "$home/bin/fm-check-lib.sh"
  chmod +x "$home/bin/fm-nudge.sh" "$home/bin/fm-check-register.sh"
  printf 'learned one\nlearned two\n' > "$home/data/learnings.md"
  printf 'preference one\n' > "$home/data/captain.md"
  printf '%s\n' "$home"
}

# Every mode, restricted to one named subject. The cases below that predate the
# second subject use the curation subject through run_nudge, so what they pin is
# still one subject's behavior and not an accident of evaluation order; the
# whole-check cases use run_check, which is what the watcher actually executes.
run_subject() {
  local home=$1 subject=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-nudge.sh" --subject "$subject" "$@"
}

run_nudge() {
  local home=$1
  shift
  run_subject "$home" curation "$@"
}

run_check() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-nudge.sh" "$@"
}

registered_subjects() {
  local home=$1
  run_check "$home" --subjects | awk '{print $1}'
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

make_failing_probe_write() {
  local home=$1 fakebin real_dd
  fakebin=$(fm_fakebin "$home")
  real_dd=$(command -v dd)
  cat > "$fakebin/dd" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    of=*/.curation-nudge-health.*) : > "\${arg#of=}"; exit 1 ;;
  esac
done
exec "$real_dd" "\$@"
SH
  chmod +x "$fakebin/dd"
  printf '%s\n' "$fakebin"
}

make_failing_probe_rename() {
  local home=$1 fakebin real_mv
  fakebin=$(fm_fakebin "$home")
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${!#}" in
  */.curation-nudge-health.*.published) exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  printf '%s\n' "$fakebin"
}

assert_no_probe_artifacts() {
  local home=$1 artifacts
  artifacts=$(find "$home/state" -maxdepth 1 -name '.curation-nudge-health.*' -print)
  [ -z "$artifacts" ] || fail "the health probe left scratch artifacts: $artifacts"
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
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
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
    "$home/bin/fm-nudge.sh") || status=$?
  [ "$status" -ne 0 ] || fail "detect accepted an unavailable state path: $out"
  assert_contains "$out" 'state persistence failure' \
    "detect must report unavailable state"
  assert_contains "$out" "$state_path" \
    "detect must name the unavailable state path"

  status=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state_path" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-nudge.sh" --armed) || status=$?
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
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
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
  assert_contains "$armed" 'supervision outage' \
    "a usable overdue state must name the supervision cause"
  assert_contains "$armed" 'nothing is executing it' \
    "a usable state path must identify the remaining overdue target as supervision"
  assert_not_contains "$armed" 'state persistence failure' \
    "a recovered state path must not retain a transient persistence diagnosis"
  [ "$(cat "$report")" = "$before" ] || fail "successful health probing changed the authoritative record"
  assert_no_probe_artifacts "$home"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "health consumed the preserved due event"
  retry=$(FM_CURATION_NUDGE_NOW="$due" run_nudge "$home")
  assert_contains "$retry" 'curation sweep is due' "the next sweep must retry the same due event"
  pass "transient publish failure leaves a truthful supervision diagnosis"
}

test_unusable_state_path_preserves_the_publish_failure_diagnosis() {
  local home due out status=0 fakebin probe_bin report before armed
  home=$(make_home persistent-publish-failure)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
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
  assert_no_probe_artifacts "$home"
  pass "unusable state path keeps publish failure distinct from supervision"
}

test_indeterminate_state_probe_names_both_possible_causes() {
  local home due out status=0 fakebin probe_bin report before armed
  home=$(make_home indeterminate-publish-failure)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
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
  assert_no_probe_artifacts "$home"
  pass "indeterminate state probe names both causes and asserts neither"
}

test_representative_write_failure_reports_persistence_without_side_effects() {
  local home due report before fakebin armed
  home=$(make_home probe-write-failure)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
  run_nudge "$home" >/dev/null
  report="$home/state/curation-nudge.report"
  due=$(record_value "$home" next-epoch)
  before=$(cat "$report")
  fakebin=$(make_failing_probe_write "$home")

  armed=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state persistence failure' \
    "a rejected representative write must be diagnosed as persistence"
  assert_contains "$armed" 'representative authoritative-record content cannot be written' \
    "the write diagnosis must name the operation that failed"
  assert_not_contains "$armed" 'nothing is executing it' \
    "a rejected representative write must not be called a supervision outage"
  [ "$(cat "$report")" = "$before" ] || fail "the write probe changed the authoritative record"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "the write probe consumed the due event"
  assert_no_probe_artifacts "$home"
  pass "representative write failures stay distinct and non-destructive"
}

test_probe_rename_failure_reports_persistence_without_side_effects() {
  local home due report before fakebin armed
  home=$(make_home probe-rename-failure)
  run_nudge "$home" --arm >/dev/null || fail "arming failed"
  run_nudge "$home" >/dev/null
  report="$home/state/curation-nudge.report"
  due=$(record_value "$home" next-epoch)
  before=$(cat "$report")
  fakebin=$(make_failing_probe_rename "$home")

  armed=$(PATH="$fakebin:$PATH" FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_nudge "$home" --armed)
  assert_contains "$armed" 'state persistence failure' \
    "a rejected scratch rename must be diagnosed as persistence"
  assert_contains "$armed" 'same-directory atomic rename cannot complete' \
    "the rename diagnosis must name the operation that failed"
  assert_not_contains "$armed" 'nothing is executing it' \
    "a rejected scratch rename must not be called a supervision outage"
  [ "$(cat "$report")" = "$before" ] || fail "the rename probe changed the authoritative record"
  [ "$(record_value "$home" next-epoch)" = "$due" ] || fail "the rename probe consumed the due event"
  assert_no_probe_artifacts "$home"
  pass "same-directory rename failures stay distinct and non-destructive"
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
  assert_contains "$armed" 'supervision outage' \
    "a usable missing-record state must name the supervision cause"
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
  shim="$home/state/nudge.check.sh"
  [ -x "$shim" ] || fail "arming did not create the registered watcher shim"
  [ -f "$home/state/nudge.check-trust" ] \
    || fail "arming did not register the watcher shim"
  PATH="$fakebin:$PATH" "$shim" >/dev/null
  PATH="$fakebin:$PATH" run_check "$home" --force >/dev/null
  PATH="$fakebin:$PATH" run_check "$home" --status >/dev/null
  PATH="$fakebin:$PATH" run_check "$home" --armed >/dev/null
  PATH="$fakebin:$PATH" run_check "$home" --subjects >/dev/null
  PATH="$fakebin:$PATH" run_nudge "$home" --draw 3 >/dev/null
  PATH="$fakebin:$PATH" run_subject "$home" codebase-sweep --draw 3 >/dev/null
  PATH="$fakebin:$PATH" run_check "$home" --help >/dev/null

  tool=$(ls -A "$trip")
  [ -z "$tool" ] || fail "the nudge invoked: $tool"
  pass "the registered shim and every mode avoid Bridge, forge, network, and git"
}

# --- arming, and the health reading that is not a unit's own claim ----------

test_arming_is_idempotent_and_registers_the_check() {
  local home first second
  home=$(make_home arm)

  run_nudge "$home" --arm >/dev/null || fail "arming failed"
  [ -x "$home/state/nudge.check.sh" ] || fail "the watcher check was not written"
  [ -f "$home/state/nudge.check-trust" ] || fail "the watcher check was not registered"
  [ "$(fm_mode_of "$home/state/nudge.check.sh")" = 700 ] \
    || fail "the watcher check must be private and executable"
  first=$(cat "$home/state/nudge.check.sh")

  run_nudge "$home" --arm >/dev/null || fail "re-arming failed"
  second=$(cat "$home/state/nudge.check.sh")
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
  shim="$home/state/nudge.check.sh"

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
  rm -f "$home/state/nudge.check.sh"
  out=$(run_nudge "$home" --armed)
  assert_contains "$out" 'is not armed' "removing the check must make the reading fail"

  run_nudge "$home" --arm >/dev/null
  rm -f "$home/state/nudge.check-trust"
  out=$(run_nudge "$home" --armed)
  assert_contains "$out" 'is not armed' "removing the trust registration must make the reading fail"

  run_nudge "$home" --arm >/dev/null
  printf 'fm-custom-check-v1\n%s\n' "$(printf '%064d' 0)" > "$home/state/nudge.check-trust"
  chmod 0600 "$home/state/nudge.check-trust"
  out=$(run_nudge "$home" --armed)
  assert_contains "$out" 'is not armed' "a stale trust registration must make the reading fail"
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

  status=0
  out=$(run_check "$home" --subjects) || status=$?
  [ "$status" -eq 0 ] || fail "--subjects exited $status: $out"
  assert_contains "$out" 'curation CURATION_NUDGE 172800' \
    "--subjects must name each subject, its code, and its period"

  status=0
  out=$(run_check "$home" --subject nonesuch --armed 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "an unregistered subject must be refused, not silently swept: $out"
  assert_contains "$out" 'unknown subject nonesuch' \
    "the refusal must name the subject it did not recognise"

  status=0
  out=$(run_check "$home" --draw 1 2>&1) || status=$?
  [ "$status" -eq 2 ] \
    || fail "--draw without a subject must be refused rather than guessing a period: $out"
  pass "every public mode executes with its observable contract"
}

# --- the second subject, and the one mechanism both ride on ------------------

test_every_registered_subject_refuses_the_five_minute_grid() {
  local home subject draws count on_grid
  home=$(make_home grid-every-subject)
  for subject in $(registered_subjects "$home"); do
    # 500 draws per subject. The refusal belongs to the shared scheduling
    # function, so a subject added later inherits it - this case enumerates the
    # registry rather than naming subjects, so a new one cannot skip the proof.
    draws=$(run_subject "$home" "$subject" --draw 500) \
      || fail "the $subject scheduler refused to draw at all"
    count=$(printf '%s\n' "$draws" | grep -c .)
    [ "$count" -eq 500 ] || fail "expected 500 $subject draws, got $count"
    on_grid=$(printf '%s\n' "$draws" | awk '{ if (int($1 / 60) % 60 % 5 == 0) n++ } END { print n + 0 }')
    [ "$on_grid" -eq 0 ] \
      || fail "$on_grid of $count $subject targets landed on a five-minute boundary"
  done
  pass "every registered subject draws off the five-minute grid, not just the first"
}

test_the_codebase_sweep_period_is_fifty_two_hours() {
  local home draws min max
  home=$(make_home codebase-period)

  draws=$(FM_CODEBASE_SWEEP_NUDGE_NOW=1000000 run_subject "$home" codebase-sweep --draw 400) \
    || fail "the scheduler refused to draw"
  min=$(printf '%s\n' "$draws" | sort -n | head -1)
  max=$(printf '%s\n' "$draws" | sort -n | tail -1)

  # 52h = 187200s. Every target sits inside 187200 + [180, 420] from the base,
  # which excludes the curation subject's 48 hours by construction rather than
  # by a nominal check.
  [ "$((min - 1000000))" -ge 187380 ] \
    || fail "a target fell short of 52 hours plus the minimum jitter: $((min - 1000000))s"
  [ "$((max - 1000000))" -le 187620 ] \
    || fail "a target exceeded 52 hours plus the maximum jitter: $((max - 1000000))s"
  [ "$((min - 1000000))" -gt 173220 ] \
    || fail "the codebase-sweep period collapsed onto the curation subject's 48 hours"
  pass "every codebase-sweep target is 52 hours plus 3-7 minutes, never the curation 48"
}

test_no_two_subjects_share_a_period() {
  local home periods duplicates count
  home=$(make_home distinct-periods)
  periods=$(run_check "$home" --subjects | awk '{print $3}')
  count=$(printf '%s\n' "$periods" | grep -c .)
  [ "$count" -ge 2 ] || fail "the registry must hold more than one subject to compare"
  duplicates=$(printf '%s\n' "$periods" | sort | uniq -d)
  [ -z "$duplicates" ] \
    || fail "subjects share a period, so they would lock to one rhythm: $duplicates"
  pass "no two registered subjects share a period"
}

test_firing_one_subject_leaves_the_others_untouched() {
  local home before after
  home=$(make_home subject-independence)
  run_check "$home" >/dev/null || fail "the initial schedule failed"
  before=$(cat "$home/state/codebase-sweep-nudge.report")

  run_nudge "$home" --force >/dev/null || fail "forcing the curation subject failed"
  after=$(cat "$home/state/codebase-sweep-nudge.report")
  [ "$before" = "$after" ] \
    || fail "firing one subject rewrote another subject's authoritative record"

  before=$(cat "$home/state/curation-nudge.report")
  run_subject "$home" codebase-sweep --force >/dev/null \
    || fail "forcing the codebase-sweep subject failed"
  after=$(cat "$home/state/curation-nudge.report")
  [ "$before" = "$after" ] \
    || fail "firing the second subject rewrote the first subject's record"
  pass "each subject keeps its own record; firing one never moves another"
}

test_the_two_subjects_stay_apart_until_their_common_multiple() {
  local home base i target closest pair curation_targets codebase_targets

  # Drive both subjects from one common base and walk each forward through the
  # firings that reach their common multiple: 13 curation periods and 12
  # codebase-sweep periods are both exactly 624 hours. Everything before that is
  # separated by a whole multiple of the 4-hour period difference, so the two
  # cannot arrive on one watcher sweep; the pair AT the common multiple is the
  # one place they re-approach, and this case pins where that is rather than
  # pretending it never happens.
  home=$(make_home separation)
  base=1800000000
  curation_targets=''
  codebase_targets=''

  target=$base
  for i in $(seq 1 13); do
    FM_CURATION_NUDGE_NOW="$target" run_nudge "$home" --force >/dev/null \
      || fail "curation firing $i failed"
    target=$(record_value "$home" next-epoch)
    curation_targets="$curation_targets $i:$target"
  done

  target=$base
  for i in $(seq 1 12); do
    FM_CODEBASE_SWEEP_NUDGE_NOW="$target" run_subject "$home" codebase-sweep --force >/dev/null \
      || fail "codebase-sweep firing $i failed"
    target=$(sed -n 's/^next-epoch: //p' "$home/state/codebase-sweep-nudge.report")
    codebase_targets="$codebase_targets $i:$target"
  done

  # The closest approach among every pair EXCEPT the common multiple (13, 12).
  closest=$(awk -v a="$curation_targets" -v b="$codebase_targets" '
    BEGIN {
      na = split(a, ca, " "); nb = split(b, cb, " ")
      min = -1
      for (i = 1; i <= na; i++) {
        if (ca[i] == "") continue
        split(ca[i], x, ":")
        for (j = 1; j <= nb; j++) {
          if (cb[j] == "") continue
          split(cb[j], y, ":")
          if (x[1] == 13 && y[1] == 12) continue
          d = x[2] - y[2]; if (d < 0) d = -d
          if (min < 0 || d < min) { min = d; pair = x[1] "/" y[1] }
        }
      }
      print min, pair
    }')
  pair=${closest#* }
  closest=${closest%% *}

  # 4 hours of period difference, less the worst-case jitter each side can
  # accumulate over these cycles, leaves well over two hours. A watcher sweep is
  # 300 seconds, so nothing before the common multiple can share one.
  [ "$closest" -ge 7200 ] \
    || fail "two subjects came within ${closest}s (pair $pair) before their common multiple"

  # And the pair at the common multiple is where the arithmetic says it must be,
  # which is what makes the exclusion above a measurement rather than a hole.
  closest=$(awk -v a="$curation_targets" -v b="$codebase_targets" '
    BEGIN {
      split(a, ca, " "); split(b, cb, " ")
      for (i in ca) { split(ca[i], x, ":"); if (x[1] == 13) c = x[2] }
      for (j in cb) { split(cb[j], y, ":"); if (y[1] == 12) k = y[2] }
      d = c - k; if (d < 0) d = -d
      print d
    }')
  [ "$closest" -le 7200 ] \
    || fail "the common-multiple pair was ${closest}s apart, so this case is measuring the wrong pair"
  pass "the two subjects stay over two hours apart for 26 days, re-approaching only at their common multiple"
}

test_a_sweep_where_both_are_due_prints_one_line_per_subject() {
  local home out lines
  home=$(make_home both-due)

  # The re-approach above is harmless only if a sweep carrying both keeps them
  # separable: one line per subject, each naming its own code and its own record.
  out=$(run_check "$home" --force)
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 2 ] || fail "a sweep with two due subjects must print two lines, got $lines: $out"
  assert_contains "$out" 'CURATION_NUDGE: ' "the first subject must name its own code"
  assert_contains "$out" 'CODEBASE_SWEEP_NUDGE: ' "the second subject must name its own code"
  assert_contains "$out" 'curation-nudge.report' "each line must point at its own record"
  assert_contains "$out" 'codebase-sweep-nudge.report' "each line must point at its own record"
  pass "a sweep where both are due prints one separable line per subject"
}

test_the_codebase_sweep_wake_tells_and_never_sweeps() {
  local home out
  home=$(make_home codebase-payload)
  out=$(run_subject "$home" codebase-sweep --force)
  assert_contains "$out" 'CODEBASE_SWEEP_NUDGE:' "the firing must print its own coded wake"
  assert_contains "$out" 'codebase-design sweep is due (every 52 hours)' \
    "the wake must name what is due and its period"
  assert_contains "$out" 'codebase-sweep skill' \
    "the wake must send each vessel to the skill that owns the obligation"
  assert_contains "$out" 'OWN repositories' \
    "each vessel sweeps its own repositories, so the wake must say so"
  assert_contains "$out" 'one named repository at a time' \
    "the wake must carry the skill's one-repository-at-a-time boundary"
  assert_contains "$out" 'All-Ships' "the wake must name the notice firstmate then dispatches"
  assert_contains "$out" 'sweeps nothing' \
    "the cadence tells and never sweeps, so the wake must disclaim sweeping"
  assert_contains "$out" 'decide for itself' \
    "each vessel decides its own findings, so the payload must not decide them"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
    || fail "the wake must be one line, so a watcher sweep surfaces it whole"
  pass "the codebase-sweep wake tells each vessel to run the skill and sweeps nothing itself"
}

test_stopping_the_check_makes_every_subject_reading_fail() {
  local home subject out due report code
  home=$(make_home stopped-every-subject)
  run_check "$home" --arm >/dev/null || fail "arming failed"
  run_check "$home" --force >/dev/null || fail "the first firing failed"

  # Stop it the way a dead timer stops: every schedule stays, the shim stays, and
  # nothing executes it. Enumerating the registry means a subject added later
  # cannot quietly ship without a health reading that discriminates.
  for subject in $(registered_subjects "$home"); do
    report="$home/state/$subject-nudge.report"
    due=$(sed -n 's/^next-epoch: //p' "$report")
    code=$(run_check "$home" --subjects | awk -v s="$subject" '$1 == s {print $2}')
    out=$(export "FM_${code}_NOW=$(( due + 7200 ))"; run_subject "$home" "$subject" --armed)
    assert_contains "$out" 'supervision outage' \
      "a $subject target nothing executes must be loud"
    assert_contains "$out" 'nothing is executing it' \
      "the $subject reading must say the schedule stands and nothing is running it"
    assert_contains "$out" 'it last fired' \
      "the $subject reading must report when it last actually fired"
  done
  pass "stopping the one check makes every subject's health reading go bad"
}

test_one_subject_going_bad_never_silences_another() {
  local home due out
  home=$(make_home one-bad-subject)
  run_check "$home" --arm >/dev/null || fail "arming failed"
  run_check "$home" --force >/dev/null || fail "the first firing failed"
  due=$(record_value "$home" next-epoch)

  # The curation subject has stopped; the codebase-sweep subject is healthy. The
  # reading must name exactly the one that is bad.
  out=$(FM_CURATION_NUDGE_NOW=$(( due + 7200 )) run_check "$home" --armed)
  assert_contains "$out" 'CURATION_NUDGE:' "the stopped subject must be reported"
  assert_not_contains "$out" 'CODEBASE_SWEEP_NUDGE:' \
    "a healthy subject must not be dragged into another subject's failure"

  # And an unreadable record for one subject must not stop the other being
  # evaluated: a shared check that gave up at the first bad subject would hide
  # every subject behind it.
  printf 'garbage\n' > "$home/state/curation-nudge.report"
  out=$(FM_CODEBASE_SWEEP_NUDGE_NOW=$(( due + 604800 )) run_check "$home" --armed)
  assert_contains "$out" 'CURATION_NUDGE:' "the unreadable record must still be reported"
  assert_contains "$out" 'CODEBASE_SWEEP_NUDGE:' \
    "the subject after a failing one must still be evaluated"
  pass "one subject's failure is reported without silencing or masking another"
}

test_one_shim_serves_every_subject() {
  local home shims shim
  home=$(make_home one-shim)
  run_check "$home" --arm >/dev/null || fail "arming failed"

  shims=$(find "$home/state" -maxdepth 1 -name '*.check.sh' | wc -l | tr -d ' ')
  [ "$shims" -eq 1 ] \
    || fail "arming created $shims watcher checks; two near-identical units is the trap this avoids"
  shim="$home/state/nudge.check.sh"
  [ -x "$shim" ] || fail "the one watcher check was not written"
  assert_not_contains "$(cat "$shim")" '--subject' \
    "the shim must pass no subject, so a subject added upstream needs no re-arming"

  # What the watcher actually runs must schedule every registered subject.
  "$shim" >/dev/null || fail "the shim failed"
  for shim in $(registered_subjects "$home"); do
    [ -f "$home/state/$shim-nudge.report" ] \
      || fail "the shared shim did not schedule the $shim subject"
  done
  pass "one shim, no subject baked in, and every registered subject scheduled by it"
}

test_arming_retires_the_single_subject_predecessor() {
  local home legacy
  home=$(make_home legacy-shim)
  legacy="$home/state/curation-nudge.check.sh"

  # The shim this check replaced, exactly as an already-updated home would still
  # carry it. Left in place it execs a script that is no longer there, and the
  # watcher sends a check's standard error to /dev/null - so it would fail
  # silently forever while every surface still reported a registered check.
  printf '#!/usr/bin/env bash\nexec /nonexistent/fm-curation-nudge.sh\n' > "$legacy"
  chmod 0700 "$legacy"
  printf 'fm-custom-check-v1\n%s\n' "$(printf '%064d' 0)" > "$home/state/curation-nudge.check-trust"

  run_check "$home" --arm >/dev/null || fail "arming failed"
  [ ! -e "$legacy" ] || fail "arming left the single-subject predecessor behind"
  [ ! -e "$home/state/curation-nudge.check-trust" ] \
    || fail "arming left the predecessor's registration behind"
  [ -x "$home/state/nudge.check.sh" ] || fail "arming did not write the replacement"
  [ -f "$home/state/nudge.check-trust" ] || fail "arming did not register the replacement"
  pass "arming retires the single-subject predecessor instead of leaving a silent sibling"
}

test_arming_fails_when_predecessor_trust_cannot_be_removed() {
  local home out status=0
  home=$(make_home legacy-trust-directory)
  mkdir "$home/state/curation-nudge.check-trust"

  out=$(run_check "$home" --arm 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "arming succeeded with an unremovable predecessor trust path"
  [ -d "$home/state/curation-nudge.check-trust" ] \
    || fail "the fixture no longer demonstrates the unremovable predecessor trust path"
  [ -x "$home/state/nudge.check.sh" ] \
    || fail "the replacement must be registered before predecessor retirement is attempted: $out"
  pass "arming fails when predecessor trust retirement is incomplete"
}

test_a_predecessor_record_is_honoured_rather_than_restarted() {
  local home out next

  # The record the single-subject predecessor wrote carries no subject or code
  # line, because those fields arrived with the registry. A home that updates
  # mid-cycle must keep its live target rather than treat the record as foreign
  # and re-schedule, which would silently move every already-scheduled sweep.
  home=$(make_home predecessor-record)
  run_check "$home" --arm >/dev/null || fail "arming failed"
  next=$(( $(date +%s) + 100000 ))
  cat > "$home/state/curation-nudge.report" <<RECORD
state: scheduled
next-epoch: $next
last-fire-epoch: 1000000
refusal-recorded-epoch: 0
refusal-surfaced: 0
interval-seconds: 172800
jitter-min-seconds: 180
jitter-max-seconds: 420
draw-attempts: 64
persistence-path: 
persistence-condition: 
RECORD

  out=$(run_nudge "$home")
  [ -z "$out" ] || fail "a live predecessor record must not fire on sight: $out"
  [ "$(record_value "$home" next-epoch)" = "$next" ] \
    || fail "the predecessor record's target was replaced instead of honoured"
  out=$(run_nudge "$home" --armed)
  [ -z "$out" ] || fail "a live predecessor record must read healthy: $out"
  pass "a record written before the registry existed is honoured, not restarted"
}

test_every_registered_subject_is_silenced_by_the_shared_suite_library() {
  local home subject out
  home=$(make_home suite-silence)
  for subject in $(registered_subjects "$home"); do
    out=$(env -u FM_TEST_LIB_SOURCED bash -c '
      set -u
      . "$1"
      FM_HOME="$2" FM_STATE_OVERRIDE="$2/state" FM_DATA_OVERRIDE="$2/data" \
        "$2/bin/fm-nudge.sh" --subject "$3" --armed
    ' bash "$ROOT/tests/lib.sh" "$home" "$subject")
    [ -z "$out" ] || fail "tests/lib.sh did not silence the $subject subject: $out"
  done
  pass "every registered subject is silenced suite-wide by the shared test library"
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
  shim="$home/state/nudge.check.sh"
  [ -x "$shim" ] || fail "bootstrap did not arm the watcher shim"
  [ -f "$home/state/nudge.check-trust" ] \
    || fail "bootstrap did not register the watcher shim"

  assert_not_contains "$out" 'CODEBASE_SWEEP_NUDGE:' \
    "the same bootstrap step must leave every subject healthy, not only the first"

  # The shim bootstrap armed is what the watcher runs, and it must establish a
  # schedule for every registered subject - not only the one the check is named
  # after on a home that has not been re-armed for the second.
  "$shim" >/dev/null || fail "the armed shim failed"
  [ -f "$home/state/curation-nudge.report" ] \
    || fail "the armed shim did not schedule the curation subject"
  [ -f "$home/state/codebase-sweep-nudge.report" ] \
    || fail "the armed shim did not schedule the codebase-sweep subject"

  rm -f "$shim"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CURATION_NUDGE_DISABLE=0 \
    FM_CODEBASE_SWEEP_NUDGE_DISABLE=0 \
    "$ROOT/bin/fm-nudge.sh" --armed)
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
test_representative_write_failure_reports_persistence_without_side_effects
test_probe_rename_failure_reports_persistence_without_side_effects
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
test_every_registered_subject_refuses_the_five_minute_grid
test_the_codebase_sweep_period_is_fifty_two_hours
test_no_two_subjects_share_a_period
test_firing_one_subject_leaves_the_others_untouched
test_the_two_subjects_stay_apart_until_their_common_multiple
test_a_sweep_where_both_are_due_prints_one_line_per_subject
test_the_codebase_sweep_wake_tells_and_never_sweeps
test_stopping_the_check_makes_every_subject_reading_fail
test_one_subject_going_bad_never_silences_another
test_one_shim_serves_every_subject
test_arming_retires_the_single_subject_predecessor
test_arming_fails_when_predecessor_trust_cannot_be_removed
test_a_predecessor_record_is_honoured_rather_than_restarted
test_every_registered_subject_is_silenced_by_the_shared_suite_library
