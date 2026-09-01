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
  assert_contains "$out" "$dir/home   account unknown, task records UNMEASURED" 'the failed installation vanished from the source list'
  status=0
  out=$(run_reading "$dir" --json) || status=$?
  expect_code 3 "$status" "json with a home whose task records could not be read"
  [ "$(printf '%s' "$out" | jq -r --arg home "$dir/home" '.installation_sources[] | select(.home == $home) | .status')" = unmeasured ] \
    || fail "json hid the requested installation whose records could not be read"
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

process_line_from_section() {  # <output> <section-prefix> <pid>
  local output=$1 section=$2 pid=$3
  printf '%s\n' "$output" | awk -v section="$section" -v pid="$pid" '
    index($0, section) == 1 { in_section = 1; next }
    in_section && $0 == "" { exit }
    in_section {
      for (i = 1; i <= NF; i++) {
        if ($i == pid) { print; exit }
      }
    }
  '
}

test_growth_separates_a_large_steady_process_from_a_fast_growing_one() {
  local dir="$TMP_ROOT/growth" out big_line grow_line
  new_scene "$dir"
  # pid 1000 is the largest and unchanged; pid 1006 is far smaller and has
  # quadrupled. Started 600s ago, so the recorded start epoch is NOW-600.
  write_sample "$dir/samples" $((NOW - 300)) \
    "1000=$((NOW - 600)):512000" \
    "1006=$((NOW - 600)):17500"
  out=$(run_reading "$dir")
  big_line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  grow_line=$(process_line_from_section "$out" 'FASTEST GROWING' 1006)
  [ -n "$big_line" ] || fail "the largest process row was not found"
  [ -n "$grow_line" ] || fail "the fastest-growing process row was not found"
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

test_a_sample_path_no_replacement_can_overwrite_stays_unmeasured() {
  local dir="$TMP_ROOT/unreadable-sample" out status=0
  new_scene "$dir"
  # A directory, not a file. Storing writes aside and moves into place, and a
  # move onto a directory lands INSIDE it, so this prior would survive every
  # replacement - which is why it is the one unusable prior the fresh sample
  # below is not allowed to soften.
  mkdir "$dir/samples"
  out=$(run_reading "$dir") || status=$?
  expect_code 3 "$status" "a stored sample path that is not a regular file"
  assert_contains "$out" 'growth-sample-path' \
    'the one growth failure no later run can repair was not named under its own input'
  assert_contains "$out" 'is not a regular file' 'the unwritable sample path was not named'
  assert_not_contains "$out" 'takes its place' 'a prior no replacement can overwrite was reported as replaced'
  pass "a stored sample path no fresh sample can overwrite stays unmeasured"
}

test_an_unusable_prior_is_replaced_rather_than_reported_as_blindness() {
  local dir="$TMP_ROOT/stale" out status=0 stored
  new_scene "$dir"
  # A host frozen for hours comes back to exactly this: a stored sample far too
  # old to divide by. The instrument is not broken, and saying it is relays a
  # machine nobody could measure as a machine nobody can see.
  write_sample "$dir/samples" $((NOW - 100000)) "1000=$((NOW - 600)):1000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a stale stored sample this run replaces"
  assert_contains "$out" 'growth scoped for every process above' 'a replaced stale sample was still reported as blindness'
  assert_not_contains "$out" 'growth unmeasured for every process above' 'a replaced stale sample was reported unmeasured'
  assert_contains "$out" 'past the' 'the staleness reason is missing'
  assert_contains "$out" 'takes its place' 'the reading did not say the unusable sample was replaced'
  assert_not_contains "$out" '+0.0 MiB/min' 'a replaced sample produced a growth rate it never measured'
  # The replacement is the whole claim, so it is read back rather than assumed.
  stored=$(awk '/^epoch /{print $2}' "$dir/samples")
  [ "$stored" = "$NOW" ] || fail "the unusable stored sample was not replaced with this run's own (epoch $stored)"
  pass "an unusable stored sample is discarded and replaced rather than reported as blindness"
}

test_an_unusable_prior_nothing_replaces_is_still_unmeasured() {
  local dir="$TMP_ROOT/stale-nostore" out status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 100000)) "1000=$((NOW - 600)):1000"
  # --no-store takes no fresh sample, so the next run would be just as blind.
  # The softer word is earned by the replacement, and there is none here.
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 3 "$status" "a stale stored sample nothing replaces"
  assert_contains "$out" 'growth unmeasured for every process above' 'an unreplaced stale sample was reported as scope'
  assert_contains "$out" 'nothing replaces it' 'the reading did not say why the stale sample stood'
  pass "an unusable stored sample nothing replaces stays unmeasured"
}

test_too_short_an_interval_is_scoped_rather_than_divided_by() {
  local dir="$TMP_ROOT/short" out line status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 6)) "1000=$((NOW - 600)):1000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "a stored sample under the minimum interval"
  assert_contains "$out" 'under the 270s floor' 'a six-second interval was divided by anyway'
  assert_contains "$out" 'scoped for this run' 'a short operator interval was not labelled scoped'
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  assert_contains "$line" 'scoped' 'a six-second allocation spike was not scoped'
  assert_not_contains "$line" 'MiB/min' 'a six-second allocation spike became a machine-wide rate'
  assert_not_contains "$out" 'UNMEASURED for every tracked process' 'a short operator interval was labelled unmeasured'
  assert_not_contains "$out" ' unmeasured  unmeasured ' 'a short interval encoded per-process growth as unmeasured'
  pass "an interval under the floor is scoped rather than divided by"
}

test_a_short_explicit_interval_uses_the_same_floor() {
  local dir="$TMP_ROOT/short-explicit" out line status=0
  new_scene "$dir"
  out=$(run_reading "$dir" --interval 12) || status=$?
  expect_code 0 "$status" "an explicit interval under the default minimum"
  assert_contains "$out" 'under the 270s floor' 'a short explicit interval bypassed the sampling floor'
  assert_contains "$out" 'scoped for this run' 'a short explicit interval was not labelled scoped'
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  assert_contains "$line" 'scoped' 'a short explicit interval did not take the scoped path'
  assert_not_contains "$line" 'MiB/min' 'a short explicit interval produced a growth rate'
  assert_not_contains "$out" 'requested wait' 'a scoped explicit interval claimed a wait that never occurred'
  pass "a short explicit interval uses the configured sampling floor"
}

test_an_explicit_floor_override_preserves_the_short_survey() {
  local dir="$TMP_ROOT/short-explicit-override" out line status=0
  new_scene "$dir"
  out=$(run_reading "$dir" "FM_MEMORY_SAMPLE_MIN_AGE=12" --interval 12) || status=$?
  expect_code 0 "$status" "the deliberate 12-second explicit survey"
  assert_contains "$out" 'measured over 12s' 'the explicit floor override did not enable the short survey'
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  assert_contains "$line" 'MiB/min' 'the explicit floor override produced no growth rate'
  assert_not_contains "$out" 'growth scoped for every process above' 'the explicit floor override remained scoped'
  assert_contains "$out" 'of which 12000 was the requested wait' 'an actual explicit wait was omitted from the reading cost'
  pass "an explicit floor override preserves the deliberate short survey"
}

test_the_watcher_interval_still_reports_a_real_rate() {
  local dir="$TMP_ROOT/watcher-interval" out line status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 300)) "1000=$((NOW - 600)):1000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "the watcher's 300-second sampling interval"
  line=$(process_line_from_section "$out" 'FASTEST GROWING' 1000)
  [ -n "$line" ] || fail "a process growing across the watcher's interval had no rate"
  assert_contains "$line" 'MiB/min' 'the realistic interval did not produce a growth rate'
  assert_contains "$line" 'growing' 'the realistic interval did not classify the growth'
  pass "the watcher's realistic interval still produces a growth rate"
}

test_the_observed_delayed_interval_remains_measurable() {
  local dir="$TMP_ROOT/delayed" out status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 926)) "1000=$((NOW - 600)):512000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "the observed 926-second delayed interval"
  assert_contains "$out" 'measured over 926s' 'the observed delayed interval was not retained as measured'
  assert_not_contains "$out" 'growth unmeasured for every process above' 'the observed delayed interval was still marked unmeasured'
  pass "the observed 926-second delayed interval remains measurable"
}

test_an_interval_past_the_ceiling_is_never_divided_by() {
  local dir="$TMP_ROOT/past-window" out line status=0
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 1261)) "1000=$((NOW - 2000)):1000"
  # Replacing the sample is not the same as accepting it. The ceiling still
  # refuses to divide by this interval; what changed is that the refusal is
  # repaired in the same run instead of being reported as a broken instrument.
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "an over-age sample this run replaces"
  assert_contains "$out" 'past the 1260s window' 'the ceiling was not named in the growth report'
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  assert_contains "$line" 'scoped' 'an over-age process was not marked scoped'
  assert_not_contains "$line" 'MiB/min' 'an over-age sample produced a growth rate'

  write_sample "$dir/samples" $((NOW - 1261)) "1000=$((NOW - 2000)):1000"
  status=0
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 3 "$status" "an over-age sample nothing replaces"
  assert_contains "$out" 'growth unmeasured for every process above' 'an over-age sample nothing replaced was treated as scope'
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  assert_not_contains "$line" 'MiB/min' 'an over-age sample produced a growth rate'
  pass "an interval past the ceiling is never divided by, replaced or not"
}

test_corrupt_and_future_samples_are_replaced_or_reported() {
  local dir="$TMP_ROOT/badsample" out status case_name stored
  for case_name in corrupt future; do
    rm -rf "$dir"
    new_scene "$dir"
    case "$case_name" in
      corrupt) printf 'epoch nonsense\n' > "$dir/samples" ;;
      future) write_sample "$dir/samples" $((NOW + 60)) "1000=$((NOW - 600)):512000" ;;
    esac
    status=0
    out=$(run_reading "$dir" --no-store) || status=$?
    expect_code 3 "$status" "a $case_name stored sample nothing replaces"
    assert_contains "$out" 'growth-sample' "a $case_name sample did not name the failed input"
    assert_not_contains "$out" 'growth-sample-path' \
      "a $case_name sample a later storing run repairs was named as the permanent failure"

    status=0
    out=$(run_reading "$dir") || status=$?
    expect_code 0 "$status" "a $case_name stored sample this run replaces"
    assert_contains "$out" 'takes its place' "a $case_name sample was not reported as replaced"
    stored=$(awk '/^epoch /{print $2}' "$dir/samples")
    [ "$stored" = "$NOW" ] || fail "a $case_name stored sample was not replaced (epoch $stored)"
  done
  pass "corrupt and future-dated samples are replaced when storing and reported when not"
}

test_sample_body_failures_are_not_first_sightings() {
  local dir="$TMP_ROOT/sample-body" out status=0 real_awk
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 60)) "1000=$((NOW - 600)):512000"
  real_awk=$(command -v awk)
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    cat <<'EOF'
for arg in "$@"; do
  [ "$arg" = "$FAIL_SAMPLE" ] && exit 7
done
EOF
    printf 'exec %q "$@"\n' "$real_awk"
  } > "$dir/bin/awk"
  chmod +x "$dir/bin/awk"
  out=$(run_reading "$dir" --no-store "PATH=$dir/bin:$PATH" "FAIL_SAMPLE=$dir/samples") || status=$?
  expect_code 3 "$status" "a sample whose body could not be read and nothing replaces"
  assert_contains "$out" 'stored sample body could not be read' 'the failed sample body was not named'
  assert_not_contains "$out" 'first sighting of this process' 'the failed sample body became ordinary first sightings'

  status=0
  out=$(run_reading "$dir" "PATH=$dir/bin:$PATH" "FAIL_SAMPLE=$dir/samples") || status=$?
  expect_code 0 "$status" "a sample whose body could not be read and this run replaces"
  assert_contains "$out" 'stored sample body could not be read' 'the replaced sample body was not named'
  assert_not_contains "$out" 'first sighting of this process' 'a replaced sample body became ordinary first sightings'

  rm -rf "$dir"
  new_scene "$dir"
  write_sample "$dir/samples" $((NOW - 300)) "1000=$((NOW - 600)):512000"
  printf 'not-a-pid\t123\t456\n' >> "$dir/samples"
  status=0
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 0 "$status" "one malformed stored sample record alongside usable records"
  assert_contains "$out" 'memory-reading: complete' 'one malformed sample record blinded the whole reading'
  assert_contains "$out" 'dropped 1 malformed stored sample record' 'the dropped sample record count was not named'
  assert_not_contains "$out" 'growth-sample' 'one malformed sample record was reported as a failed growth instrument'
  status=0
  out=$(run_reading "$dir" --no-store --json) || status=$?
  expect_code 0 "$status" "json with one malformed stored sample record alongside usable records"
  [ "$(printf '%s' "$out" | jq -r '.growth.dropped_sample_records')" = 1 ] \
    || fail "json did not expose the dropped stored-sample record count"

  write_sample "$dir/samples" $((NOW + 60)) "1000=$((NOW - 600)):512000"
  printf 'not-a-pid\t123\t456\n' >> "$dir/samples"
  status=0
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 3 "$status" "future-dated sample with one malformed stored sample record"
  assert_contains "$out" 'stored sample is dated in the future' 'the future-dated sample was not refused'
  assert_not_contains "$out" 'growth measured from the remaining records' 'a refused sample was described as measured'
  status=0
  out=$(run_reading "$dir" --no-store --json) || status=$?
  expect_code 3 "$status" "json future-dated sample with one malformed stored sample record"
  [ "$(printf '%s' "$out" | jq -r '.growth.dropped_sample_records')" = 0 ] \
    || fail "json exposed dropped stored-sample records for a refused sample"

  write_sample "$dir/samples" $((NOW - 300))
  printf 'not-a-pid\t123\t456\n' >> "$dir/samples"
  status=0
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 3 "$status" "a stored sample with no usable process records"
  assert_contains "$out" 'carries no usable process records' 'an all-bad sample body was not refused'

  write_sample "$dir/samples" $((NOW - 300))
  status=0
  out=$(run_reading "$dir" --no-store) || status=$?
  expect_code 3 "$status" "a stored sample with an empty process body"
  assert_contains "$out" 'carries no usable process records' 'an empty sample body was not refused'

  write_sample "$dir/samples" $((NOW - 300))
  status=0
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "an empty sample body this run replaces"
  assert_contains "$out" 'carries no usable process records' 'a replaced empty sample body was not named'
  assert_not_contains "$out" 'first sighting of this process' 'a replaced empty sample body became ordinary first sightings'
  pass "sample body failures are incomplete while isolated malformed records are dropped and counted"
}

test_a_reused_pid_is_not_reported_as_growth() {
  local dir="$TMP_ROOT/reuse" out line
  new_scene "$dir"
  # Same pid, but the recorded process started far earlier: this is a different
  # process now, and the difference in size is not growth.
  write_sample "$dir/samples" $((NOW - 300)) "1000=$((NOW - 90000)):1000"
  out=$(run_reading "$dir")
  line=$(process_line_from_section "$out" 'LARGEST TRACKED PROCESSES' 1000)
  [ -n "$line" ] || fail "the reused-pid process row was not found"
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

test_a_kernel_that_accounts_no_memory_pressure_is_unmeasured_not_calm() {
  # Measured on a WSL seat on 2026-08-28: every memory pressure average 0.00 AND
  # a cumulative total of exactly zero over 3,526 seconds of uptime, while the io
  # counter stood at 2,063,189. Pressure accounting worked there; only the memory
  # account was flat. From a single read that is indistinguishable from a quiet
  # machine, so the reading has to prove the account is live rather than trust
  # that the file answered.
  local dir="$TMP_ROOT/flatmem" out status=0
  new_scene "$dir"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/pressure"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=2063189\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1031594\n' > "$dir/io-pressure"
  out=$(run_reading "$dir" "FM_MEMORY_PRESSURE_IO=$dir/io-pressure") || status=$?

  expect_code 3 "$status" "a kernel that accounts no memory pressure"
  assert_contains "$out" 'memory-reading: INCOMPLETE' \
    'a flat memory account beside a live io account was accepted as a complete reading'
  assert_contains "$out" 'accounted exactly zero memory stall since boot' \
    'the reading did not say why it distrusts these zeros'
  assert_not_contains "$(stall_block "$out")" 'avg10=' \
    'the reading printed stall averages it had just decided were meaningless'

  # The control: same flat memory account, but io is flat too, so nothing proves
  # this kernel accounts pressure at all and the zeros are not called dead.
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/io-pressure"
  status=0
  out=$(run_reading "$dir" "FM_MEMORY_PRESSURE_IO=$dir/io-pressure") || status=$?
  expect_code 0 "$status" "a freshly booted machine with both accounts still at zero"
  assert_contains "$(stall_block "$out")" 'avg10=0.00' \
    'a machine with no pressure accounted anywhere yet must not be called blind on that alone'
  pass "a kernel that accounts pressure but not memory pressure reports unmeasured, never calm"
}

test_an_io_control_nobody_could_read_is_told_apart_from_a_flat_one() {
  # Both leave the memory account's zeros standing, so from the verdict alone
  # they are the same outcome - but "the control has accounted no pressure
  # anywhere yet" and "the control could not be read at all" are different
  # facts, and this reader never reports an instrument it could not read as a
  # zero. The reading's own json (schema fm-memory-reading.v1) is the contract
  # where it says which of the two it was.
  local dir="$TMP_ROOT/iocontrol" out
  new_scene "$dir"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/pressure"

  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/io-pressure"
  out=$(run_reading "$dir" --json "FM_MEMORY_PRESSURE_IO=$dir/io-pressure")
  [ "$(printf '%s' "$out" | jq -r '.stall.io_control')" = flat ] \
    || fail 'an io control that read zero was not reported as a flat account'

  rm -f "$dir/io-pressure"
  out=$(run_reading "$dir" --json "FM_MEMORY_PRESSURE_IO=$dir/io-pressure")
  [ "$(printf '%s' "$out" | jq -r '.stall.io_control')" = unreadable ] \
    || fail 'an io control that could not be read was reported as though it had read zero'

  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=2063189\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1031594\n' > "$dir/io-pressure"
  out=$(run_reading "$dir" --json "FM_MEMORY_PRESSURE_IO=$dir/io-pressure" || true)
  [ "$(printf '%s' "$out" | jq -r '.stall.io_control')" = live ] \
    || fail 'a live io control was not named as the control that condemned the memory account'

  # A machine whose memory account is not flat needs no control at all, so the
  # reading says it consulted none rather than inventing a reading of one.
  make_pressure_calm "$dir/pressure"
  out=$(run_reading "$dir" --json "FM_MEMORY_PRESSURE_IO=$dir/io-pressure")
  [ "$(printf '%s' "$out" | jq -r '.stall.io_control')" = null ] \
    || fail 'the reading claimed an io control state on a run that never needed one'
  pass "an io control that could not be read is told apart from one that read zero"
}

test_the_cumulative_counter_is_carried_as_proof_and_never_as_a_trigger() {
  # The counter is monotonic since boot, so anything that fired on it could never
  # recover. It is carried so a reader can check the averages mean something.
  local dir="$TMP_ROOT/totals" out
  new_scene "$dir"
  out=$(run_reading "$dir" --json)
  [ "$(printf '%s' "$out" | jq -r '.stall.some_total_us')" = 5135032 ] \
    || fail 'the json did not carry the cumulative some counter'
  [ "$(printf '%s' "$out" | jq -r '.stall.full_total_us')" = 4911577 ] \
    || fail 'the json did not carry the cumulative full counter'
  pass "the cumulative stall counters are carried in the reading as proof the averages are live"
}

test_counters_that_recorded_nothing_are_not_captioned_as_proof() {
  # The human render is this reading's own reported output, and the caption
  # beside the counters is a claim about them. A live account can carry that
  # claim; an account that has recorded nothing at all cannot, and both totals
  # at zero beside a control that settles nothing is exactly the residual
  # docs/memory-alarm.md records under what the alarm cannot see.
  local dir="$TMP_ROOT/proofcaption" out stall
  new_scene "$dir"
  out=$(run_reading "$dir")
  stall=$(stall_block "$out")
  assert_contains "$stall" 'proof the averages are accounted' \
    'a live account did not carry the counters as proof'

  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/pressure"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/io-pressure"
  out=$(run_reading "$dir" "FM_MEMORY_PRESSURE_IO=$dir/io-pressure")
  stall=$(stall_block "$out")
  assert_not_contains "$stall" 'proof the averages are accounted' \
    'counters that have recorded nothing were captioned as proof they had'
  assert_contains "$stall" 'recorded nothing at all' \
    'the reading did not say the counters carry no evidence'
  assert_contains "$stall" 'is flat too' \
    'the reading did not name the control that failed to settle it'

  rm -f "$dir/io-pressure"
  out=$(run_reading "$dir" "FM_MEMORY_PRESSURE_IO=$dir/io-pressure")
  stall=$(stall_block "$out")
  assert_not_contains "$stall" 'proof the averages are accounted' \
    'counters that have recorded nothing were captioned as proof they had'
  assert_contains "$stall" 'could not be read as a control' \
    'a control nobody could read was not told apart from one that read zero'
  pass "counters that have recorded nothing are not captioned as proof"
}

test_each_unreadable_input_is_named_and_forces_a_non_zero_exit() {
  local dir="$TMP_ROOT/badinputs" out status case_name

  # Every case is an input constructed to be bad on purpose.
  for case_name in pressure-empty pressure-garbage pressure-missing \
                   pressure-no-totals \
                   meminfo-empty meminfo-garbage meminfo-no-available \
                   ps-fails ps-empty ps-malformed cgroup-absent home-unreadable; do
    rm -rf "$dir"
    new_scene "$dir"
    status=0
    case "$case_name" in
      pressure-empty)      : > "$dir/pressure" ;;
      pressure-garbage)    printf 'nothing about memory here\n' > "$dir/pressure" ;;
      pressure-missing)    rm -f "$dir/pressure" ;;
      pressure-no-totals)  printf 'some avg10=0.00 avg60=0.00 avg300=0.00\nfull avg10=0.00 avg60=0.00 avg300=0.00\n' > "$dir/pressure" ;;
      meminfo-empty)       : > "$dir/meminfo" ;;
      meminfo-garbage)     printf 'MemTotal: not-a-number\n' > "$dir/meminfo" ;;
      meminfo-no-available) printf 'MemTotal: 24019276 kB\nMemFree: 100 kB\n' > "$dir/meminfo" ;;
      ps-fails)            printf '#!/usr/bin/env bash\nexit 7\n' > "$dir/ps" ;;
      ps-empty)            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/ps" ;;
      ps-malformed)        make_ps "$dir/ps" "1000 1 $ME_UID 512000 600 codex worker" 'broken partial row' ;;
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

test_a_nonsearchable_cgroup_tree_is_unmeasured() {
  local dir="$TMP_ROOT/nonsearchable-cgroup" out status=0 user_slice
  new_scene "$dir"
  user_slice="$dir/cgroup/user.slice"
  chmod 644 "$user_slice"
  if [ -x "$user_slice" ]; then
    chmod 755 "$user_slice"
    printf 'ok - SKIP non-searchable cgroup permissions do not restrict this user\n'
    return
  fi
  out=$(run_reading "$dir") || status=$?
  chmod 755 "$user_slice"
  expect_code 3 "$status" "a readable but non-searchable user.slice"
  assert_contains "$out" 'account-slices' 'the non-searchable cgroup tree did not name the failed instrument'
  assert_contains "$out" 'not searchable' 'the cgroup failure did not distinguish search permission'
  assert_not_contains "$out" 'no active session slice' 'a blind cgroup traversal was rendered as scoped absence'
  pass "a non-searchable cgroup tree is unmeasured rather than scoped"
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

test_an_unusable_prior_whose_replacement_did_not_land_is_not_reported_as_replaced() {
  local dir="$TMP_ROOT/prior-store-failed" out status=0 err
  new_scene "$dir"
  mkdir -p "$dir/locked"
  # An aged prior that IS readable, so the run reaches the unusable-prior path
  # and means to replace it, beside a directory the replacement cannot be
  # written into. That is the shape an unwritable state directory produces.
  write_sample "$dir/locked/samples" $((NOW - 1400)) "1000=$((NOW - 3000)):512000"
  chmod a-w "$dir/locked"
  if ( : > "$dir/locked/probe" ) 2>/dev/null; then
    rm -f "$dir/locked/probe"; chmod u+w "$dir/locked"
    printf 'ok - SKIP directory write permissions do not restrict this user\n'
    return
  fi

  # The two streams are kept apart on purpose. Merging them would absorb any raw
  # interpreter error into the report and make both faults below invisible.
  err="$dir/store-stderr"
  out=$(run_reading "$dir" "FM_MEMORY_SAMPLES=$dir/locked/samples" 2>"$err") || status=$?
  chmod u+w "$dir/locked"
  expect_code 3 "$status" "an unusable prior whose replacement could not be stored"
  assert_contains "$out" 'growth-sample-store' \
    'a scope verdict resting on a store that never landed was not named as a failed input'
  assert_not_contains "$out" 'takes its place' \
    'the reading claimed a replacement that provably did not happen'
  assert_contains "$out" 'sample-storage' 'the storage failure itself was not named'
  # The step named must be the one that actually failed: the temporary file this
  # run writes aside, not the target it never got as far as replacing.
  assert_contains "$out" "$dir/locked/samples." \
    'the storage failure named the target rather than the temporary file it could not write'
  assert_not_contains "$out" 'could not be replaced' \
    'a temporary file that could not be opened was reported as a failed replacement'
  # A monitoring check speaks in its own voice and in no other.
  [ ! -s "$err" ] || fail "the reading leaked to its own stderr: $(cat "$err")"

  # The same aged prior with a writable destination: the replacement lands, so
  # the verdict and its wording stay exactly as they were.
  status=0
  write_sample "$dir/samples" $((NOW - 1400)) "1000=$((NOW - 3000)):512000"
  out=$(run_reading "$dir") || status=$?
  expect_code 0 "$status" "an unusable prior this run did replace"
  assert_contains "$out" 'takes its place' 'a replacement that landed was not reported as scope'
  assert_not_contains "$out" 'growth-sample-store' \
    'a replacement that landed was reported as a lost growth instrument'
  pass "a replacement that did not land is never reported as one that did"
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
test_a_sample_path_no_replacement_can_overwrite_stays_unmeasured
test_an_unusable_prior_is_replaced_rather_than_reported_as_blindness
test_an_unusable_prior_nothing_replaces_is_still_unmeasured
test_too_short_an_interval_is_scoped_rather_than_divided_by
test_a_short_explicit_interval_uses_the_same_floor
test_an_explicit_floor_override_preserves_the_short_survey
test_the_watcher_interval_still_reports_a_real_rate
test_the_observed_delayed_interval_remains_measurable
test_an_interval_past_the_ceiling_is_never_divided_by
test_corrupt_and_future_samples_are_replaced_or_reported
test_sample_body_failures_are_not_first_sightings
test_a_reused_pid_is_not_reported_as_growth
test_a_genuinely_calm_stall_reading_is_not_confusable_with_a_blind_one
test_a_kernel_that_accounts_no_memory_pressure_is_unmeasured_not_calm
test_an_io_control_nobody_could_read_is_told_apart_from_a_flat_one
test_the_cumulative_counter_is_carried_as_proof_and_never_as_a_trigger
test_counters_that_recorded_nothing_are_not_captioned_as_proof
test_each_unreadable_input_is_named_and_forces_a_non_zero_exit
test_a_cgroup_tree_nobody_read_is_not_reported_as_an_account_with_no_session
test_a_nonsearchable_cgroup_tree_is_unmeasured
test_an_account_with_no_readable_slice_still_gets_its_process_total
test_a_malformed_account_slice_file_forces_an_incomplete_reading
test_sample_storage_failure_is_visible_and_no_store_is_scoped
test_an_unusable_prior_whose_replacement_did_not_land_is_not_reported_as_replaced
test_the_json_form_carries_the_same_completeness_verdict
test_the_reading_does_not_kill_or_limit
test_usage_errors_exit_two
