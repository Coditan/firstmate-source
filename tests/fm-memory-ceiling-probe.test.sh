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
  # The boundary this whole slice sits behind: the probe may set a ceiling on
  # its own transient scope and nowhere else, and it must contain no path that
  # ends a process. A grep is a coarse check, but it is the one that would have
  # caught a victim-selection rule arriving by a later edit.
  assert_no_grep 'kill ' "$PROBE" "the probe must contain no kill path"
  assert_no_grep 'pkill' "$PROBE" "the probe must contain no pkill path"
  assert_no_grep 'MemoryMax=1' "$PROBE" "the probe must never set an enforcing maximum"
  assert_grep 'MemoryMax=infinity' "$PROBE" \
    "the probe's own scopes must explicitly disclaim an enforcing maximum"
  assert_no_grep 'systemctl --user set-property' "$PROBE" \
    "the probe must not set a property on any unit it did not create"
  pass "the probe sets no lasting limit and contains no path that could kill"
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
test_usage_errors_exit_two
