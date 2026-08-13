#!/usr/bin/env bash
# Behavior tests for the attributable memory reading.
#
# Every input is a fixture: a stub process table, a fake /proc for working
# directory resolution, a fake cgroup tree, and fixture meminfo and pressure
# files. Nothing here reads the host, so the suite measures the reading's
# contract rather than the machine it happens to run on.
#
# The contract under test is mostly about the DIFFERENCE between two calm
# results: a machine that was measured and is fine, and an instrument that
# could not look. Several cases below deliberately feed a bad input and require
# the reading to say so rather than return a healthy-looking zero.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-memory-reading-tests

READING="$ROOT/bin/fm-memory-reading.sh"
ME_UID=$(id -u)
OTHER_UID=4242
NOW=1700000000

# --- fixtures ---------------------------------------------------------------

# A home with task records, plus the worktrees those records point at.
make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/work/alpha" "$home/work/beta"
  fm_write_meta "$home/state/alpha-task.meta" \
    "window=sess:fm-alpha-task" \
    "worktree=$home/work/alpha" \
    "project=/projects/alpha-project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/beta-task.meta" \
    "window=sess:fm-beta-task" \
    "worktree=$home/work/beta" \
    "project=/projects/beta-project" \
    "harness=codex" \
    "kind=scout" \
    "mode=direct-PR"
}

# A cgroup tree with one account slice.
make_cgroup() {
  local root=$1 uid=$2 current=$3 max=$4
  mkdir -p "$root/user.slice/user-$uid.slice"
  printf '%s\n' "$current" > "$root/user.slice/user-$uid.slice/memory.current"
  printf '%s\n' "$max" > "$root/user.slice/user-$uid.slice/memory.max"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' \
    > "$root/user.slice/user-$uid.slice/memory.pressure"
}

make_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       24019276 kB
MemFree:         6764412 kB
MemAvailable:   16517040 kB
SwapTotal:             0 kB
SwapFree:              0 kB
EOF
}

make_pressure_calm() {
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=5135032\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=4911577\n' > "$1"
}

# A stub process table. Each argument is one "pid ppid uid rss etimes args"
# row, written out in the exact shape `ps -eo pid=,ppid=,uid=,rss=,etimes=,args=`
# produces.
make_ps() {
  local script=$1 row
  shift
  {
    printf '#!/usr/bin/env bash\ncat <<%s\n' "'PSEOF'"
    for row in "$@"; do printf '%s\n' "$row"; done
    printf 'PSEOF\n'
  } > "$script"
  chmod +x "$script"
}

# A fake /proc: one directory per pid with a cwd symlink. A pid given no
# directory here is a process that vanished between the table read and now.
make_proc() {
  local proc=$1 pair pid target
  shift
  mkdir -p "$proc"
  for pair in "$@"; do
    pid=${pair%%=*}
    target=${pair#*=}
    mkdir -p "$proc/$pid"
    ln -sfn "$target" "$proc/$pid/cwd"
  done
}

# The standard scene: one worker in each worktree, one worker of another
# account, one worker in no known worktree, a tiny wake-delivery listener, and
# a worker whose own instructions merely MENTION the delivery script.
standard_scene() {
  local dir=$1 home=$2
  make_ps "$dir/ps" \
    "1000 1 $ME_UID 512000 600 claude --settings $home/work/alpha/.claude/settings.json" \
    "1001 1 $ME_UID 256000 600 codex --model gpt" \
    "1002 1 $OTHER_UID 400000 600 claude --dangerously-skip-permissions" \
    "1003 1 $ME_UID 180000 600 node /opt/unknown/server.js" \
    "1004 1 $ME_UID 4400 600 bash $home/bin/fm-wake-wait.sh --hold" \
    "1005 1 $ME_UID 90000 600 claude read bin/fm-watch.sh and report on fm-wake-wait.sh" \
    "1006 1 $ME_UID 70000 600 python3 /opt/tool/run.py"
  make_proc "$dir/proc" \
    "1000=$home/work/alpha" \
    "1001=$home/work/beta" \
    "1003=/opt/unknown" \
    "1004=$home" \
    "1005=$home/work/alpha" \
    "1006=/opt/tool"
  # pid 1002 has no /proc entry readable (another account); pid 1007 never
  # existed. Both must be reported, not dropped.
}

# Run the reading against a prepared scene directory. Extra arguments of the
# form NAME=value become environment overrides; anything else is passed to the
# reading as a flag.
run_reading() {
  local dir=$1 arg
  local -a envs=() flags=()
  shift
  for arg in "$@"; do
    case "$arg" in
      -*) flags+=("$arg") ;;
      *=*) envs+=("$arg") ;;
      *) flags+=("$arg") ;;
    esac
  done
  env \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_MEMORY_SAMPLES="$dir/samples" \
    FM_MEMORY_PS="$dir/ps" \
    FM_MEMORY_PROC="$dir/proc" \
    FM_MEMORY_MEMINFO="$dir/meminfo" \
    FM_MEMORY_PRESSURE="$dir/pressure" \
    FM_MEMORY_CGROUP_ROOT="$dir/cgroup" \
    FM_MEMORY_NO_TMUX=1 \
    FM_MEMORY_NOW="$NOW" \
    ${envs+"${envs[@]}"} \
    "$READING" ${flags+"${flags[@]}"}
}

# A complete, healthy scene.
new_scene() {
  local dir=$1
  mkdir -p "$dir"
  make_home "$dir/home"
  make_meminfo "$dir/meminfo"
  make_pressure_calm "$dir/pressure"
  make_cgroup "$dir/cgroup" "$ME_UID" 3221225472 max
  standard_scene "$dir" "$dir/home"
}

# --- a complete reading -----------------------------------------------------

test_a_complete_reading_says_so_and_exits_zero() {
  local dir="$TMP_ROOT/complete" out status=0
  new_scene "$dir"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a fully measured reading"
  assert_contains "$out" 'memory-reading: complete' 'the reading does not report itself complete'
  assert_contains "$out" 'UNMEASURED INPUTS (0)' 'a complete reading still lists its unmeasured inputs as none'
  assert_contains "$out" 'peak memory of this reading unavailable in scope' 'unavailable cost was not rendered as scope'
  assert_not_contains "$out" 'peak memory of this reading 0' 'unavailable cost was fabricated as zero'
  pass "a fully measured reading reports complete and exits 0"
}

test_headroom_and_stall_appear_with_the_per_process_attribution() {
  local dir="$TMP_ROOT/onesheet" out
  new_scene "$dir"
  out=$(run_reading "$dir")
  # The whole point of one reading rather than two investigations.
  assert_contains "$out" 'HEADROOM' 'headroom is missing from the reading'
  assert_contains "$out" 'available' 'available headroom is missing'
  assert_contains "$out" 'STALL' 'the stall reading is missing'
  assert_contains "$out" 'LARGEST TRACKED PROCESSES' 'the per-process table is missing'
  assert_contains "$out" 'alpha-task' 'per-process attribution is missing from the same output'
  pass "aggregate headroom, the stall reading, and per-process attribution share one output"
}

test_swap_absent_is_reported_as_a_fact_not_a_blank() {
  local dir="$TMP_ROOT/swap" out status=0
  new_scene "$dir"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "measured zero SwapTotal"
  assert_contains "$out" 'none configured' 'a machine with no swap does not say so'
  pass "no swap at all is stated rather than shown as zero"
}

test_swap_fields_fail_visibly_without_inventing_zero() {
  local dir="$TMP_ROOT/swap-fields" out status=0
  new_scene "$dir"
  sed -i 's/SwapTotal:.*/SwapTotal:       2097152 kB/; s/SwapFree:.*/SwapFree:        1048576 kB/' "$dir/meminfo"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "configured swap with valid free space"
  assert_contains "$out" '2048 MiB total, 1024 MiB free' 'valid swap fields were not rendered'

  sed -i '/SwapFree:/d' "$dir/meminfo"
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "configured swap without SwapFree"
  assert_contains "$out" '2048 MiB total, free UNMEASURED' 'measured swap total was not preserved'
  assert_not_contains "$out" '2048 MiB total, 0 MiB free' 'missing SwapFree was replaced with zero'

  sed -i '/SwapTotal:/d' "$dir/meminfo"
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "meminfo without SwapTotal"
  assert_contains "$out" 'no usable SwapTotal' 'the missing SwapTotal instrument was not named'
  pass "swap fields fail visibly and never invent free space"
}

test_memory_max_accepts_only_unbounded_or_byte_counts() {
  local dir="$TMP_ROOT/memory-max" out status=0 max_file
  new_scene "$dir"
  max_file="$dir/cgroup/user.slice/user-$ME_UID.slice/memory.max"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "memory.max holding max"
  assert_contains "$out" 'none - this account is unbounded' 'memory.max max was not rendered as unbounded'

  printf '1073741824\n' > "$max_file"
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "memory.max holding a byte count"
  assert_contains "$out" 'slice limit  1024 MiB' 'numeric memory.max was not rendered in MiB'

  printf 'unlimited-ish\n' > "$max_file"
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "malformed memory.max"
  assert_contains "$out" "account-slice[$(id -un)].memory.max" 'malformed memory.max did not name its account and file'
  pass "memory.max accepts only max or a byte count"
}

# --- attribution ------------------------------------------------------------

test_a_process_in_a_recorded_worktree_is_named_with_its_task() {
  local dir="$TMP_ROOT/attrib" out
  new_scene "$dir"
  out=$(run_reading "$dir")
  assert_contains "$out" 'task alpha-task (ship, alpha-project)' 'the worker in a recorded worktree is not tied to its task'
  assert_contains "$out" 'task beta-task (scout, beta-project)' 'the second worker is not tied to its task'
  pass "a process in a recorded worktree is named with its task, kind, and project"
}

test_an_unmatched_process_is_reported_unattributed_never_dropped() {
  local dir="$TMP_ROOT/unattrib" out
  new_scene "$dir"
  out=$(run_reading "$dir")
  assert_contains "$out" 'UNATTRIBUTED' 'the unattributed section is missing'
  assert_contains "$out" '1003' 'a process matching no record was dropped from the reading'
  assert_contains "$out" 'matches no record of the installations read' 'the unattributed reason is missing'
  pass "a process matching no task record is reported unattributed with its reason"
}

test_a_foreign_account_process_is_never_given_an_owner() {
  local dir="$TMP_ROOT/foreign" out
  new_scene "$dir"
  out=$(run_reading "$dir")
  assert_contains "$out" '1002' 'the process of another account was dropped'
  assert_contains "$out" 'no installation read by this run' 'the foreign-account reason is missing'
  # It must not be handed a task merely because another process of a known task
  # happens to look similar, and the account must not be promoted to an owner.
  assert_not_contains "$out" 'uid-4242 / task ' 'a foreign-account process was given a task it has no record for'
  assert_not_contains "$out" 'uid-4242 / firstmate home' 'a foreign-account process was given an installation it has no record for'
  pass "a process of an account with no readable records is reported unattributed, never given an owner"
}

test_the_reading_names_the_installations_it_actually_read() {
  local dir="$TMP_ROOT/installs" out
  new_scene "$dir"
  out=$(run_reading "$dir")
  assert_contains "$out" 'TASK RECORD SOURCES' 'the reading does not say whose records it consulted'
  assert_contains "$out" "$dir/home" 'the installation actually read is not named'
  assert_contains "$out" '2 task record(s)' 'the number of records read is not stated'
  pass "the reading names the installations whose records it read"
}

test_requested_task_record_sources_fail_visibly() {
  local dir="$TMP_ROOT/requested-sources" out status=0 missing
  new_scene "$dir"
  missing="$dir/operator-requested"
  out=$(run_reading "$dir" --home "$missing") || status=$?
  expect_code 3 "$status" "an explicitly requested home with no readable state directory"
  assert_contains "$out" "$missing" 'the explicitly requested failed home vanished from the report'
  assert_contains "$out" 'task records UNMEASURED' 'the explicitly requested failed home was not marked unmeasured'

  rm -rf "$dir"
  new_scene "$dir"
  missing="$dir/recorded-secondmate"
  fm_write_meta "$dir/home/state/secondmate.meta" \
    'kind=secondmate' \
    "home=$missing" \
    'window=sess:fm-secondmate'
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "a secondmate home named by task metadata with no readable state directory"
  assert_contains "$out" "$missing" 'the failed secondmate home vanished from the report'
  assert_contains "$out" 'task records UNMEASURED' 'the failed secondmate home was not marked unmeasured'

  rm -rf "$dir"
  new_scene "$dir"
  rm -f "$dir/home/state"/*.meta
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a readable requested home with no task records"
  assert_contains "$out" "$dir/home" 'the readable empty home vanished from the report'
  assert_contains "$out" '0 task record(s)' 'the readable empty home was not reported with zero records'
  pass "requested task-record sources fail visibly while readable empty homes remain scoped"
}

test_empty_and_unreadable_task_record_sets_are_distinct() {
  local dir="$TMP_ROOT/task-record-boundary" out status=0
  new_scene "$dir"
  rm -f "$dir/home/state"/*.meta
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a home with no task records"
  assert_contains "$out" '0 task record(s)' 'an idle installation was not listed with zero records'

  mkdir "$dir/home/state/broken.meta"
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "a home with unreadable task records"
  assert_contains "$out" "$dir/home has task records that could not be read" 'the failed installation was not named'
  assert_not_contains "$out" "$dir/home   account" 'a failed installation was presented as successfully read'
  pass "empty task records are scoped while failed reads are incomplete"
}

test_a_process_that_vanished_mid_read_is_reported_as_exited() {
  local dir="$TMP_ROOT/gone" out
  new_scene "$dir"
  # A row for a pid with no /proc entry at all: the process ended between the
  # table read and the working-directory read.
  make_ps "$dir/ps" \
    "1009 1 $ME_UID 300000 600 python3 /opt/gone/run.py"
  out=$(run_reading "$dir")
  assert_contains "$out" '1009' 'a process that exited mid-read vanished from the reading too'
  assert_contains "$out" 'exited' 'a process that exited mid-read is not reported as such'
  pass "a process that exits mid-read is reported as exited, not silently dropped"
}

test_a_live_process_with_unresolved_cwd_is_not_reported_exited() {
  local dir="$TMP_ROOT/unresolved-cwd" out line status=0
  new_scene "$dir"
  make_ps "$dir/ps" "1010 1 $ME_UID 65536 60 codex inaccessible-worker"
  mkdir -p "$dir/proc/1010"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a live process whose cwd cannot be resolved"
  line=$(printf '%s\n' "$out" | grep '1010' | head -1)
  assert_contains "$line" 'may not resolve' 'the live process did not take the unreadable route'
  assert_not_contains "$line" 'exited' 'a live process with an unresolved cwd was reported exited'
  pass "unresolved live process cwd is unreadable, not exited"
}

# --- the protected delivery path --------------------------------------------

test_wake_delivery_is_labelled_protected_however_small() {
  local dir="$TMP_ROOT/protected" out
  new_scene "$dir"
  out=$(run_reading "$dir" FM_MEMORY_TRACK_MIB=64)
  # Far below the tracking floor, and still present and labelled.
  assert_contains "$out" '1004' 'the wake-delivery listener is missing from the reading'
  assert_contains "$out" 'PROTECTED' 'the wake-delivery listener is not labelled protected'
  pass "the wake-delivery listener is tracked at any size and labelled protected"
}

test_a_worker_that_merely_mentions_the_delivery_script_is_not_labelled() {
  local dir="$TMP_ROOT/mention" out line
  new_scene "$dir"
  out=$(run_reading "$dir")
  line=$(printf '%s\n' "$out" | grep ' 1005 ' | head -1)
  [ -n "$line" ] || fail "the worker whose instructions mention the delivery script is missing"
  case "$line" in
    *PROTECTED*) fail "a worker was labelled protected because its instructions mentioned the delivery script:"$'\n'"$line" ;;
  esac
  pass "the protected label matches the executed command, not any mention of it"
}

# --- growth -----------------------------------------------------------------

write_sample() {  # <file> <epoch> <pid=start:rss> ...
  local file=$1 epoch=$2 rec pid rest
  shift 2
  {
    printf '# fm-memory-reading.samples v1\n'
    printf 'epoch %s\n' "$epoch"
    for rec in "$@"; do
      pid=${rec%%=*}
      rest=${rec#*=}
      printf '%s\t%s\t%s\n' "$pid" "${rest%%:*}" "${rest##*:}"
    done
  } > "$file"
}

test_growth_separates_a_large_steady_process_from_a_fast_growing_one() {
  local dir="$TMP_ROOT/growth" out big_line grow_line
  new_scene "$dir"
  # pid 1000 is the largest and unchanged; pid 1006 is far smaller and has
  # quadrupled. Started 600s ago, so the recorded start epoch is NOW-600.
  write_sample "$dir/samples" $((NOW - 60)) \
    "1000=$((NOW - 600)):512000" \
    "1006=$((NOW - 600)):17500"
  out=$(run_reading "$dir")
  big_line=$(printf '%s\n' "$out" | grep ' 1000 ' | head -1)
  grow_line=$(printf '%s\n' "$out" | grep ' 1006 ' | head -1)
  assert_contains "$big_line" 'steady' 'the largest process was not reported as steady'
  assert_contains "$grow_line" 'growing' 'the fast-growing process was not reported as growing'
  assert_contains "$out" 'FASTEST GROWING' 'the growth ranking is missing'
  pass "a large steady process and a small fast-growing one are told apart and labelled"
}

test_growth_with_no_prior_sample_is_unmeasured_never_zero() {
  local dir="$TMP_ROOT/nosample" out status=0
  new_scene "$dir"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a first run with no prior sample"
  assert_contains "$out" 'growth scoped for every process above' 'a first run does not say growth was scoped'
  assert_not_contains "$out" 'growth unmeasured for every process above' 'a first run was labelled unmeasured'
  assert_not_contains "$out" ' unmeasured  unmeasured ' 'a scoped first run encoded per-process growth as unmeasured'
  assert_contains "$out" 'nothing to compare against' 'the reason growth could not be measured is missing'
  assert_not_contains "$out" '+0.0 MiB/min' 'a first run reported a growth rate of zero it never measured'
  pass "growth with no prior sample is reported unmeasured, never as zero growth"
}

test_an_unreadable_prior_sample_is_an_instrument_failure() {
  local dir="$TMP_ROOT/unreadable-sample" out status=0
  new_scene "$dir"
  mkdir "$dir/samples"
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "an existing unreadable stored sample"
  assert_contains "$out" 'growth-sample' 'the failed growth instrument was not named'
  assert_contains "$out" 'exists but could not be read' 'the unreadable sample was reported absent'
  pass "an unreadable stored sample is incomplete, not scoped"
}

test_a_stale_prior_sample_is_unmeasured_rather_than_meaningless() {
  local dir="$TMP_ROOT/stale" out status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 100000)) "1000=$((NOW - 600)):1000"
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "a stale stored sample"
  assert_contains "$out" 'growth unmeasured for every process above' 'a stale sample was used as if current'
  assert_contains "$out" 'past the' 'the staleness reason is missing'
  pass "a prior sample older than the growth window is reported unmeasured"
}

test_too_short_an_interval_is_scoped_rather_than_divided_by() {
  local dir="$TMP_ROOT/short" out status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 1)) "1000=$((NOW - 600)):1000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a stored sample under the minimum interval"
  assert_contains "$out" 'under the' 'a one-second interval was divided by anyway'
  assert_contains "$out" 'scoped for this run' 'a short operator interval was not labelled scoped'
  assert_not_contains "$out" 'UNMEASURED for every tracked process' 'a short operator interval was labelled unmeasured'
  assert_not_contains "$out" ' unmeasured  unmeasured ' 'a short interval encoded per-process growth as unmeasured'
  pass "an interval under the floor is scoped rather than divided by"
}

test_corrupt_and_future_samples_force_incomplete_readings() {
  local dir="$TMP_ROOT/badsample" out status case_name
  for case_name in corrupt future; do
    rm -rf "$dir"
    new_scene "$dir"
    case "$case_name" in
      corrupt) printf 'epoch nonsense\n' > "$dir/samples" ;;
      future) write_sample "$dir/samples" $((NOW + 60)) "1000=$((NOW - 600)):512000" ;;
    esac
    status=0
    out=$(run_reading "$dir") || status=$?
    expect_code 3 "$status" "a $case_name stored sample"
    assert_contains "$out" 'growth-sample' "a $case_name sample did not name the failed input"
  done
  pass "corrupt and future-dated samples force incomplete readings"
}

test_a_reused_pid_is_not_reported_as_growth() {
  local dir="$TMP_ROOT/reuse" out line
  new_scene "$dir"
  # Same pid, but the recorded process started far earlier: this is a different
  # process now, and the difference in size is not growth.
  write_sample "$dir/samples" $((NOW - 60)) "1000=$((NOW - 90000)):1000"
  out=$(run_reading "$dir")
  line=$(printf '%s\n' "$out" | grep -A1 ' 1000 ' | head -2)
  assert_contains "$line" 'unmeasured' 'a reused pid was reported as enormous growth'
  assert_contains "$out" 'different, later process' 'the pid-reuse reason is missing'
  pass "a pid that now belongs to a different process reports unmeasured, not growth"
}

# --- measured and fine versus could not measure ------------------------------

stall_block() {  # the machine-wide STALL section only, not the per-account ones
  printf '%s\n' "$1" | sed -n '/^STALL/,/^$/p'
}

test_a_genuinely_calm_stall_reading_is_not_confusable_with_a_blind_one() {
  local dir="$TMP_ROOT/calm" calm_out calm_status=0 blind_out blind_status=0
  new_scene "$dir"
  # Measured, and every average really is zero.
  calm_out=$(run_reading "$dir") || calm_status=$?
  # Same visual calm, no measurement behind it.
  : > "$dir/pressure"
  blind_out=$(run_reading "$dir") || blind_status=$?

  expect_code 0 "$calm_status" "a measured, calm stall reading"
  expect_code 3 "$blind_status" "a stall reading that could not be taken"
  assert_contains "$(stall_block "$calm_out")" 'avg10=0.00' 'the calm reading does not show the zero it measured'
  assert_contains "$calm_out" 'memory-reading: complete' 'the calm reading is not marked complete'
  assert_contains "$blind_out" 'memory-reading: INCOMPLETE' 'the blind reading is not marked incomplete'
  assert_not_contains "$(stall_block "$blind_out")" 'avg10=' 'the blind reading printed a stall figure it never read'
  assert_contains "$(stall_block "$blind_out")" 'UNMEASURED' 'the blind stall reading is not marked unmeasured'
  pass "a measured calm stall and an unreadable one differ in text and in exit status"
}

test_each_unreadable_input_is_named_and_forces_a_non_zero_exit() {
  local dir="$TMP_ROOT/badinputs" out status case_name

  # Every case is an input constructed to be bad on purpose.
  for case_name in pressure-empty pressure-garbage pressure-missing \
                   meminfo-empty meminfo-garbage meminfo-no-available \
                   ps-fails ps-empty cgroup-absent home-unreadable; do
    rm -rf "$dir"
    new_scene "$dir"
    status=0
    case "$case_name" in
      pressure-empty)      : > "$dir/pressure" ;;
      pressure-garbage)    printf 'nothing about memory here\n' > "$dir/pressure" ;;
      pressure-missing)    rm -f "$dir/pressure" ;;
      meminfo-empty)       : > "$dir/meminfo" ;;
      meminfo-garbage)     printf 'MemTotal: not-a-number\n' > "$dir/meminfo" ;;
      meminfo-no-available) printf 'MemTotal: 24019276 kB\nMemFree: 100 kB\n' > "$dir/meminfo" ;;
      ps-fails)            printf '#!/usr/bin/env bash\nexit 7\n' > "$dir/ps" ;;
      ps-empty)            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/ps" ;;
      cgroup-absent)       rm -rf "$dir/cgroup" ;;
      home-unreadable)     rm -rf "$dir/home/state" ;;
    esac
    out=$(run_reading "$dir") || status=$?
    expect_code 3 "$status" "the reading with a deliberately bad input ($case_name)"
    assert_contains "$out" 'memory-reading: INCOMPLETE' "$case_name did not mark the reading incomplete"
    assert_not_contains "$out" 'UNMEASURED INPUTS (0)' "$case_name reported no unmeasured input"
  done
  pass "every deliberately bad input is named as unmeasured and never exits 0"
}

test_a_cgroup_tree_nobody_read_is_not_reported_as_an_account_with_no_session() {
  local dir="$TMP_ROOT/blindcgroup" out
  new_scene "$dir"
  rm -rf "$dir/cgroup"
  out=$(run_reading "$dir")
  # The two produce the same empty slice fields, so the reason must separate
  # them: an account that is simply not logged in is not a failed measurement.
  assert_contains "$out" 'account-slices' 'a cgroup tree that was never read is not named as unmeasured'
  assert_not_contains "$out" 'no active session slice' 'a cgroup tree nobody read was reported as an account with no session'
  pass "an unreadable cgroup tree is told apart from an account with no session"
}

test_an_account_with_no_readable_slice_still_gets_its_process_total() {
  local dir="$TMP_ROOT/partial" out status=0
  new_scene "$dir"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "an account with no active session slice"
  # The other account has no slice in the fixture tree, and must still be
  # bounded by what the process table alone can say.
  assert_contains "$out" 'uid-4242' 'an account with no readable slice was dropped from the reading'
  assert_contains "$out" 'process(es)' 'the per-account process total is missing'
  assert_contains "$out" 'slice total  no active session slice for this account' 'a missing session slice was not rendered as scope'
  assert_not_contains "$out" 'UNMEASURED (no active session slice for this account)' 'a scoped session absence was rendered unmeasured'
  pass "an account with no readable slice is still bounded by its process total"
}

test_a_malformed_account_slice_file_forces_an_incomplete_reading() {
  local dir="$TMP_ROOT/malformed-slice" out status=0
  new_scene "$dir"
  printf 'not-bytes\n' > "$dir/cgroup/user.slice/user-$ME_UID.slice/memory.current"
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "a malformed per-account cgroup file"
  assert_contains "$out" "account-slice[$(id -un)].memory.current" 'the failed account and file were not named'
  assert_contains "$out" 'slice total  UNMEASURED' 'a genuine slice failure was not rendered unmeasured'
  pass "a malformed account slice file names its instrument and exits 3"
}

test_sample_storage_failure_is_visible_and_no_store_is_scoped() {
  local dir="$TMP_ROOT/sample-storage" out status=0
  new_scene "$dir"
  printf 'not a directory\n' > "$dir/state-blocker"
  out=$(run_reading "$dir" "FM_STATE_OVERRIDE=$dir/state-blocker") || status=$?
  expect_code 3 "$status" "a sample that cannot be stored"
  assert_contains "$out" 'sample-storage' 'sample persistence failure was not named'
  status=0
  out=$(run_reading "$dir" "FM_STATE_OVERRIDE=$dir/state-blocker" --no-store) || status=$?
  expect_code 0 "$status" "--no-store with unavailable storage"
  assert_contains "$out" 'UNMEASURED INPUTS (0)' '--no-store registered a persistence failure'
  pass "sample storage failures exit 3 while --no-store remains successful"
}

# --- machine-readable form ---------------------------------------------------

test_the_json_form_carries_the_same_completeness_verdict() {
  local dir="$TMP_ROOT/json" out status=0
  command -v jq >/dev/null 2>&1 || { pass "json form (skipped: no jq)"; return 0; }
  new_scene "$dir"
  out=$(run_reading "$dir" --json) || status=$?
  expect_code 0 "$status" "a complete reading in json form"
  [ "$(printf '%s' "$out" | jq -r .schema)" = "fm-memory-reading.v1" ] || fail "the json form carries no schema id"
  [ "$(printf '%s' "$out" | jq -r .complete)" = true ] || fail "a complete reading is not marked complete in json"
  [ "$(printf '%s' "$out" | jq -r '.processes[] | select(.pid == 1004) | .protected')" = true ] \
    || fail "the json form does not carry the protected label"
  [ "$(printf '%s' "$out" | jq -r '.processes[] | select(.pid == 1000) | .attribution.detail')" = "alpha-task (ship, alpha-project)" ] \
    || fail "the json form does not carry the task attribution"
  [ "$(printf '%s' "$out" | jq -r '.processes[] | select(.pid == 1000) | .growth_state')" = scoped ] \
    || fail "json encoded globally scoped growth as unmeasured"
  [ "$(printf '%s' "$out" | jq -r '.processes[] | select(.pid == 1000) | .growth_unmeasured_reason')" = null ] \
    || fail "json exposed an unmeasured reason for scoped growth"
  [ "$(printf '%s' "$out" | jq -r '.processes[] | select(.pid == 1000) | .growth_scope_reason')" != null ] \
    || fail "json omitted the scoped growth reason"

  : > "$dir/pressure"
  status=0
  out=$(run_reading "$dir" --json) || status=$?
  expect_code 3 "$status" "an incomplete reading in json form"
  [ "$(printf '%s' "$out" | jq -r .complete)" = false ] || fail "an incomplete reading is marked complete in json"
  [ "$(printf '%s' "$out" | jq -r '.unmeasured | length')" -ge 1 ] || fail "the json form lists no unmeasured input"
  [ "$(printf '%s' "$out" | jq -r '.stall.some_avg10')" = null ] || fail "the json form invented a stall figure it never read"

  new_scene "$dir"
  sed -i 's/SwapTotal:.*/SwapTotal:       2097152 kB/; s/SwapFree:.*/SwapFree:        1048576 kB/' "$dir/meminfo"
  status=0
  out=$(run_reading "$dir" --json) || status=$?
  expect_code 0 "$status" "json with measured SwapFree"
  [ "$(printf '%s' "$out" | jq -r '.headroom.swap_free_kb')" = 1048576 ] || fail "json omitted measured SwapFree"
  sed -i '/SwapFree:/d' "$dir/meminfo"
  status=0
  out=$(run_reading "$dir" --json) || status=$?
  expect_code 3 "$status" "json with unmeasured SwapFree"
  [ "$(printf '%s' "$out" | jq -r '.headroom.swap_free_kb')" = null ] || fail "json invented unavailable SwapFree"
  pass "the json form carries the same completeness verdict and never invents a figure"
}

# --- the slice boundary ------------------------------------------------------

test_the_reading_does_not_kill_or_limit() {
  local dir="$TMP_ROOT/safety" out status=0 sentinel max_before pressure_before
  new_scene "$dir"
  sleep 60 &
  sentinel=$!
  make_ps "$dir/ps" "$sentinel 1 $ME_UID 65536 10 codex sentinel-worker"
  make_proc "$dir/proc" "$sentinel=$dir/home/work/alpha"
  max_before=$(od -An -tx1 "$dir/cgroup/user.slice/user-$ME_UID.slice/memory.max")
  pressure_before=$(od -An -tx1 "$dir/cgroup/user.slice/user-$ME_UID.slice/memory.pressure")
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "the safety-boundary reading"
  if ! kill -0 "$sentinel" 2>/dev/null; then
    fail "the reading terminated the sentinel process"
  fi
  [ "$max_before" = "$(od -An -tx1 "$dir/cgroup/user.slice/user-$ME_UID.slice/memory.max")" ] \
    || fail "the reading changed memory.max"
  [ "$pressure_before" = "$(od -An -tx1 "$dir/cgroup/user.slice/user-$ME_UID.slice/memory.pressure")" ] \
    || fail "the reading changed a cgroup control fixture"
  kill "$sentinel" 2>/dev/null || true
  wait "$sentinel" 2>/dev/null || true
  assert_contains "$out" "$sentinel" 'the sentinel was not observed through the executable interface'
  pass "the reading leaves a sentinel alive and cgroup controls unchanged"
}

test_usage_errors_exit_two() {
  local status=0
  "$READING" --largest banana >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a non-numeric --largest"
  status=0
  "$READING" --nonsense >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown argument"
  status=0
  "$READING" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "--help"
  pass "usage errors exit 2 and --help exits 0"
}

test_a_complete_reading_says_so_and_exits_zero
test_headroom_and_stall_appear_with_the_per_process_attribution
test_swap_absent_is_reported_as_a_fact_not_a_blank
test_swap_fields_fail_visibly_without_inventing_zero
test_memory_max_accepts_only_unbounded_or_byte_counts
test_a_process_in_a_recorded_worktree_is_named_with_its_task
test_an_unmatched_process_is_reported_unattributed_never_dropped
test_a_foreign_account_process_is_never_given_an_owner
test_the_reading_names_the_installations_it_actually_read
test_requested_task_record_sources_fail_visibly
test_empty_and_unreadable_task_record_sets_are_distinct
test_a_process_that_vanished_mid_read_is_reported_as_exited
test_a_live_process_with_unresolved_cwd_is_not_reported_exited
test_wake_delivery_is_labelled_protected_however_small
test_a_worker_that_merely_mentions_the_delivery_script_is_not_labelled
test_growth_separates_a_large_steady_process_from_a_fast_growing_one
test_growth_with_no_prior_sample_is_unmeasured_never_zero
test_an_unreadable_prior_sample_is_an_instrument_failure
test_a_stale_prior_sample_is_unmeasured_rather_than_meaningless
test_too_short_an_interval_is_scoped_rather_than_divided_by
test_corrupt_and_future_samples_force_incomplete_readings
test_a_reused_pid_is_not_reported_as_growth
test_a_genuinely_calm_stall_reading_is_not_confusable_with_a_blind_one
test_each_unreadable_input_is_named_and_forces_a_non_zero_exit
test_a_cgroup_tree_nobody_read_is_not_reported_as_an_account_with_no_session
test_an_account_with_no_readable_slice_still_gets_its_process_total
test_a_malformed_account_slice_file_forces_an_incomplete_reading
test_sample_storage_failure_is_visible_and_no_store_is_scoped
test_the_json_form_carries_the_same_completeness_verdict
test_the_reading_does_not_kill_or_limit
test_usage_errors_exit_two
