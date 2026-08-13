#!/usr/bin/env bash
# Behavior tests for the memory-ceiling probe.
#
# The probe's arms need a live kernel, a delegated cgroup subtree, and a real
# systemd user manager, so this suite does not run them. What it does test is
# the half that decides whether a verdict may be issued at all: every
# precondition is named when it fails, a failed precondition is reported as
# unmeasured rather than worked around, and no run that could not look comes
# back with a clean answer.
#
# That is the property worth a test. A probe whose arms are broken produces an
# obviously wrong number, but a probe that quietly skips a precondition
# produces a confident wrong verdict, and something downstream fits a ceiling on
# it.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-memory-ceiling-probe-tests

PROBE="$ROOT/bin/fm-memory-ceiling-probe.sh"

# A meminfo fixture with the given MemAvailable, in kB.
write_meminfo() {
  local path=$1 avail_kb=$2
  cat >"$path" <<EOF
MemTotal:       24019908 kB
MemFree:         1000000 kB
MemAvailable:   $avail_kb kB
SwapTotal:             0 kB
SwapFree:              0 kB
EOF
}

write_pressure() {
  cat >"$1" <<'EOF'
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
EOF
}

# A run with every precondition satisfiable EXCEPT the ones a case overrides.
# The cgroup root points at an ordinary directory, so cgroup2 is the failing
# precondition by default and no arm is ever reached.
probe_with() {
  env "$@" "$PROBE" --scratch "$TMP_ROOT/scratch" 2>&1
}

test_a_probe_that_could_not_look_never_reports_a_verdict() {
  local out status=0
  mkdir -p "$TMP_ROOT/notcgroup"
  write_meminfo "$TMP_ROOT/meminfo" 16000000
  write_pressure "$TMP_ROOT/pressure"

  out=$(probe_with \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure") || status=$?

  expect_code 3 "$status" "a probe with an unusable cgroup root"
  assert_contains "$out" "INCOMPLETE" "an incomplete probe must say so first"
  assert_contains "$out" "unmeasured" "the failing precondition must be named as unmeasured"
  assert_contains "$out" "cgroup2" "the failing precondition must be named"
  assert_not_contains "$out" "MANUFACTURED" "a probe that could not look must not reach a verdict"
  assert_not_contains "$out" "clear" "a probe that could not look must not report a clean result"
  pass "a probe that could not establish a precondition names it and issues no verdict"
}

test_each_missing_input_is_named_by_its_own_name() {
  local out status=0
  mkdir -p "$TMP_ROOT/notcgroup"
  write_meminfo "$TMP_ROOT/meminfo" 16000000

  # An absent pressure file and an absent meminfo are different failures and
  # must not collapse into one generic complaint.
  out=$(probe_with \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/absent-pressure") || status=$?
  expect_code 3 "$status" "an unreadable host stall source"
  assert_contains "$out" "host-stall" "an unreadable pressure file must be named as the host-stall input"
  assert_contains "$out" "$TMP_ROOT/absent-pressure" "the reason must name the path it could not read"

  status=0
  write_pressure "$TMP_ROOT/pressure"
  out=$(probe_with \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/absent-meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure") || status=$?
  expect_code 3 "$status" "an unreadable headroom source"
  assert_contains "$out" "headroom" "an unreadable meminfo must be named as the headroom input"
  pass "each missing input is reported under its own name with the path it failed on"
}

test_a_meminfo_without_the_line_it_needs_is_unmeasured_not_zero() {
  local out status=0
  mkdir -p "$TMP_ROOT/notcgroup"
  write_pressure "$TMP_ROOT/pressure"
  # Present, readable, and useless: the exact shape that tempts a reading to
  # substitute a zero and then refuse to run for the wrong reason.
  printf 'MemTotal:       24019908 kB\n' >"$TMP_ROOT/meminfo-noavail"

  out=$(probe_with \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo-noavail" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure") || status=$?

  expect_code 3 "$status" "a meminfo with no MemAvailable line"
  assert_contains "$out" "no MemAvailable line" \
    "a missing MemAvailable must be reported as unread rather than as zero available memory"
  assert_not_contains "$out" "0 MiB available, below" \
    "an unreadable headroom must never be reported as a host that is out of memory"
  pass "a meminfo missing its line is unmeasured rather than silently read as zero"
}

test_the_probe_refuses_to_load_a_host_that_is_already_short() {
  local out status=0
  mkdir -p "$TMP_ROOT/notcgroup"
  write_pressure "$TMP_ROOT/pressure"
  write_meminfo "$TMP_ROOT/meminfo-tight" 262144   # 256 MiB available

  out=$(probe_with \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo-tight" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure") || status=$?

  expect_code 3 "$status" "a host below the available-memory floor"
  assert_contains "$out" "256 MiB available" "the refusal must state the headroom it measured"
  assert_contains "$out" "will not add load" "the refusal must say why it declined"
  pass "the probe refuses to add its own load to a host that is already short"
}

test_the_scratch_it_cannot_use_is_named_before_any_arm_runs() {
  local out status=0
  mkdir -p "$TMP_ROOT/notcgroup" "$TMP_ROOT/readonly"
  write_pressure "$TMP_ROOT/pressure"
  write_meminfo "$TMP_ROOT/meminfo" 16000000
  chmod 500 "$TMP_ROOT/readonly"

  out=$(env \
    FM_CEILING_PROBE_CGROUP_ROOT="$TMP_ROOT/notcgroup" \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure" \
    "$PROBE" --scratch "$TMP_ROOT/readonly/nested" 2>&1) || status=$?
  chmod 700 "$TMP_ROOT/readonly"

  expect_code 3 "$status" "an unwritable scratch directory"
  assert_contains "$out" "scratch" "an unusable scratch directory must be named"
  pass "an unusable scratch directory is named before any corpus is written"
}

test_the_probe_sets_no_lasting_limit_and_kills_nothing() {
  local fake="$TMP_ROOT/systemd-run" calls="$TMP_ROOT/systemd-run.calls" sentinels="$TMP_ROOT/sentinels"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >>"$FM_TEST_SYSTEMD_CALLS"
shift 9
sleep 30 >/dev/null 2>&1 &
export FM_TEST_SENTINEL_PID=$!
printf '%s\t%s\t%s\n' "$FM_TEST_SENTINEL_PID" \
  "$(ps -o pgid= -p "$FM_TEST_SENTINEL_PID" | tr -d ' ')" \
  "$(cat "/proc/$FM_TEST_SENTINEL_PID/cgroup")" >>"$FM_TEST_SENTINELS"
if [ "${FM_TEST_INJECT_KILL:-0}" = 1 ]; then
  command=$1
  flag=$2
  script=$3
  shift 3
  "$command" "$flag" 'kill "$FM_TEST_SENTINEL_PID"; '"$script" "$@"
else
  "$@"
fi
EOF
  chmod +x "$fake"
  local scope="$TMP_ROOT/scope"
  mkdir -p "$scope"
  printf '1048576\n' >"$scope/memory.current"
  printf 'high 0\n' >"$scope/memory.events"
  printf 'pgsteal 0\nworkingset_refault_file 0\n' >"$scope/memory.stat"
  write_pressure "$scope/memory.pressure"
  write_meminfo "$TMP_ROOT/meminfo" 16000000
  write_pressure "$TMP_ROOT/pressure"
  local out status=0
  out=$(env FM_CEILING_PROBE_SYSTEMD_RUN="$fake" FM_TEST_SYSTEMD_CALLS="$calls" \
    FM_TEST_SENTINELS="$sentinels" FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure" FM_CEILING_PROBE_SCOPE_CGROUP="$scope" \
    "$PROBE" --corpus-mib 64 \
    --seconds 5 --scratch "$TMP_ROOT/scratch-live" 2>&1) || status=$?
  expect_code 0 "$status" "a probe driven through the transient-scope seam"
  [ "$(wc -l <"$calls")" -eq 2 ] || fail "the probe must create exactly one transient scope per arm"
  local control=no ceiling=no unit high
  while IFS=$'\t' read -r arg1 arg2 arg3 arg4 arg5 arg6 arg7 arg8 arg9 arg10 arg11; do
    [ "$arg1" = --user ] && [ "$arg2" = --scope ] || fail "each arm must use a user transient scope"
    unit=${arg3#--unit=}
    [ "$arg4" = -p ] && high=${arg5#MemoryHigh=} || fail "each arm must set only its scoped MemoryHigh"
    [ "$arg6" = -p ] && [ "$arg7" = MemoryMax=infinity ] || fail "each arm must disclaim an enforcing maximum"
    [ "$arg8" = --quiet ] && [ "$arg9" = -- ] && [ "$arg10" = bash ] && [ "$arg11" = -c ] ||
      fail "scope properties must precede the workload command"
    case "$unit:$high" in
      fm-ceiling-probe-control-[0-9]*.scope:infinity) control=yes ;;
      fm-ceiling-probe-ceiling-[0-9]*.scope:2G) ceiling=yes ;;
      *) fail "the probe must set limits only on its two named transient scopes" ;;
    esac
  done <"$calls"
  [ "$control" = yes ] || fail "the control transient scope must remain unlimited"
  [ "$ceiling" = yes ] || fail "the ceiling must apply only to its own transient scope"
  local pid pgid cgroup current_pgid current_cgroup
  while IFS=$'\t' read -r pid pgid cgroup; do
    kill -0 "$pid" 2>/dev/null || fail "the probe must leave each reachable sentinel alive"
    current_pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
    current_cgroup=$(cat "/proc/$pid/cgroup")
    [ "$current_pgid" = "$pgid" ] || fail "the probe must not move a sentinel out of its payload process group"
    [ "$current_cgroup" = "$cgroup" ] || fail "the probe must not move a sentinel into a limiting cgroup"
    kill "$pid" 2>/dev/null || true
  done <"$sentinels"
  assert_contains "$out" "memory-ceiling-probe: clear" "the recorded arm results must reach the public verdict"

  : >"$calls"
  : >"$sentinels"
  status=0
  out=$(env FM_CEILING_PROBE_SYSTEMD_RUN="$fake" FM_TEST_SYSTEMD_CALLS="$calls" \
    FM_TEST_SENTINELS="$sentinels" FM_TEST_INJECT_KILL=1 \
    FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure" \
    FM_CEILING_PROBE_SCOPE_CGROUP="$scope" "$PROBE" --corpus-mib 64 --seconds 5 \
    --scratch "$TMP_ROOT/scratch-live" 2>&1) || status=$?
  expect_code 0 "$status" "the kill-injected control run"
  while IFS=$'\t' read -r pid _; do
    kill -0 "$pid" 2>/dev/null && fail "the sentinel assertion must detect a kill injected into the executed payload"
  done <"$sentinels"
  pass "the probe sets no lasting limit and contains no path that could kill"
}

test_an_arm_that_cannot_run_is_incomplete() {
  local fake="$TMP_ROOT/systemd-run-fails" out status=0
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
  chmod +x "$fake"
  write_meminfo "$TMP_ROOT/meminfo" 16000000
  write_pressure "$TMP_ROOT/pressure"
  out=$(env FM_CEILING_PROBE_SYSTEMD_RUN="$fake" FM_CEILING_PROBE_MEMINFO="$TMP_ROOT/meminfo" \
    FM_CEILING_PROBE_PRESSURE="$TMP_ROOT/pressure" "$PROBE" --corpus-mib 64 \
    --seconds 5 --scratch "$TMP_ROOT/scratch-failure" 2>&1) || status=$?
  expect_code 3 "$status" "an arm scope that could not run"
  assert_contains "$out" "INCOMPLETE" "a failed arm must not reach a measurement verdict"
  assert_contains "$out" "arm-control" "the failed arm must be named"
  assert_contains "$out" "status 19" "the arm failure reason must survive into the parent"
  assert_not_contains "$out" "memory-ceiling-probe: clear" "a failed arm must never become a clean verdict"
  pass "an arm execution failure is an incomplete measurement with a named reason"
}

test_usage_errors_exit_two() {
  local status=0
  "$PROBE" --corpus-mib banana >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a non-numeric --corpus-mib"
  status=0
  "$PROBE" --seconds 1 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a duration shorter than one stall average"
  status=0
  "$PROBE" --corpus-mib 8 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a corpus too small to fill any ceiling"
  status=0
  "$PROBE" --high >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "--high with no size"
  status=0
  "$PROBE" --nonsense >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown argument"
  status=0
  "$PROBE" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "--help"
  pass "usage errors exit 2 and --help exits 0"
}

test_a_probe_that_could_not_look_never_reports_a_verdict
test_each_missing_input_is_named_by_its_own_name
test_a_meminfo_without_the_line_it_needs_is_unmeasured_not_zero
test_the_probe_refuses_to_load_a_host_that_is_already_short
test_the_scratch_it_cannot_use_is_named_before_any_arm_runs
test_the_probe_sets_no_lasting_limit_and_kills_nothing
test_an_arm_that_cannot_run_is_incomplete
test_usage_errors_exit_two
