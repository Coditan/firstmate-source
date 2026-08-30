#!/usr/bin/env bash
# Regression tests for fm-guard's stale-watcher banner deduplication.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands in that same stale episode should print only a concise
# reminder, while unrelated alarms such as queued wakes stay independent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-guard-stale-banner

# fm-guard names a repair command only for the session that OPERATES the home it
# just judged, which it reads from the checkout the running script was loaded
# from. So a fixture that means "firstmate's own session" has to run the guard out
# of the fixture home's own bin/, the way tests/fm-turnend-guard.test.sh and
# tests/fm-continuity-pretool-check.test.sh already stage their operator shape.
# fm-watch.sh and fm-watcher-service.sh are deliberately NOT installed: the guard
# only compares the watcher path as a string, and the missing service exercises
# the same 'bin/fm-watcher-service.sh restart' fallback the real service prints.
GUARD_SCRIPTS='fm-guard.sh fm-wake-lib.sh fm-journal-lib.sh fm-delivery-lib.sh
fm-harness-pid-lib.sh fm-tangle-lib.sh fm-supervision-lib.sh
fm-primary-scope-lib.sh'

install_guard_scripts() {
  local dir=$1 file
  mkdir -p "$dir/bin"
  for file in $GUARD_SCRIPTS; do
    cp "$ROOT/bin/$file" "$dir/bin/$file"
  done
  chmod +x "$dir/bin/fm-guard.sh"
}

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  install_guard_scripts "$home"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

run_guard_case() {
  local dir=$1 home
  home=$(case_home "$dir")
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    FM_WATCH_SERVICE_FORCE_BACKEND=keeper \
    "$home/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1 home
  home=$(case_home "$dir")
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    FM_WATCH_SERVICE_FORCE_BACKEND=keeper \
    "$home/bin/fm-guard.sh" 2>&1
}

# The worker shape bin/fm-spawn.sh actually produces: the task worktree carries
# its own tracked copy of the guard, the launch command prepends only
# FM_HOME=<launching home>, and FM_ROOT_OVERRIDE is deliberately left unset so
# FM_ROOT resolves to the worker's own worktree. That is the shape an FM_ROOT
# comparison would misread as the operator.
case_worker() {
  printf '%s/worker\n' "$1"
}

make_worker_checkout() {
  local dir=$1 worker
  worker=$(case_worker "$dir")
  [ -d "$worker/bin" ] || install_guard_scripts "$worker"
  printf '%s\n' "$worker"
}

run_guard_case_as_worker() {
  local dir=$1 worker
  worker=$(make_worker_checkout "$dir")
  FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_WATCH_SERVICE_FORCE_BACKEND=keeper \
    "$worker/bin/fm-guard.sh" 2>&1
}

record_live_daemon() {
  local home=$1 pid=$2 watch_path=${3:-"$1/bin/fm-watch.sh"} identity state
  state="$home/state"
  identity=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch_path" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

test_first_stale_call_prints_full_banner() {
  local dir out
  dir=$(make_guard_case first-stale)
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale guard call did not print exactly one full banner: $out"
  assert_contains "$out" "Daemon repair: bin/fm-watcher-service.sh restart" \
    "full banner must keep the scoped daemon-repair instruction"
  assert_contains "$out" "WILL still run" \
    "full banner must keep the guarded-operation continuation line"
  pass "fm-guard stale banner: first stale call prints the full actionable banner"
}

test_repeated_same_episode_prints_reminder_only() {
  local dir out1 out2 marker lines
  dir=$(make_guard_case repeated-stale)
  out1=$(run_guard_case "$dir")
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "second stale call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second stale call did not print the concise reminder"
  marker="$(case_home "$dir")/state/.guard-watcher-stale-banner"
  assert_present "$marker" "stale banner marker was not written under the owning home"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "stale banner marker must stay bounded to one line, got $lines"
  pass "fm-guard stale banner: repeated same-episode calls print a concise reminder only"
}

test_healthy_recovery_rearms_next_stale_episode() {
  local dir home out1 healthy out2 live
  dir=$(make_guard_case healthy-recovery)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale episode did not print the full banner: $out1"

  sleep 60 & live=$!
  record_live_daemon "$home" "$live"
  : > "$home/state/.afk"
  healthy=$(run_guard_case "$dir")
  [ -z "$healthy" ] || fail "guard should be silent after watcher recovery, got: $healthy"
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "healthy recovery must clear the stale-banner marker"

  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  rm -f "$home/state/.afk"
  rm -f "$home/state/.last-watcher-beat"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "second stale episode did not re-print the full banner: $out2"
  pass "fm-guard stale banner: healthy recovery rearms the next stale episode"
}

test_concurrent_same_episode_prints_one_full_banner() {
  local dir out_dir i pids pid all full reminders
  dir=$(make_guard_case concurrent-stale)
  out_dir="$dir/outs"
  mkdir -p "$out_dir"
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    (
      run_guard_case "$dir" > "$out_dir/$i.out" 2>&1
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || fail "concurrent guard subprocess failed"
  done
  all=$(cat "$out_dir"/*.out)
  full=$(count_text "$all" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")
  reminders=$(count_text "$all" "full banner already printed this episode")
  [ "$full" -eq 1 ] || fail "concurrent same-episode calls printed $full full banners"$'\n'"$all"
  [ "$reminders" -eq 29 ] || fail "concurrent same-episode calls printed $reminders reminders, expected 29"$'\n'"$all"
  pass "fm-guard stale banner: concurrent same-episode calls claim exactly one full banner"
}

test_home_isolation() {
  local dir_a dir_b out_a1 out_a2 out_b1
  dir_a=$(make_guard_case home-a)
  dir_b=$(make_guard_case home-b)
  out_a1=$(run_guard_case "$dir_a")
  out_b1=$(run_guard_case "$dir_b")
  out_a2=$(run_guard_case "$dir_a")
  [ "$(count_text "$out_a1" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home A first stale call did not print a full banner: $out_a1"
  [ "$(count_text "$out_b1" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home B first stale call was suppressed by home A: $out_b1"
  assert_contains "$out_a2" "full banner already printed this episode" \
    "home A repeated stale call did not remember its own episode"
  pass "fm-guard stale banner: deduplication is isolated per FM_HOME"
}

test_queued_wake_warning_stays_independent() {
  local dir home out1 out2
  dir=$(make_guard_case queued-wake)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner before queued wake case: $out1"
  printf 'signal: %s/state/task.status\n' "$home" > "$home/state/.wake-queue"
  out2=$(run_guard_case "$dir")
  assert_contains "$out2" "full banner already printed this episode" \
    "same-episode stale call should still print its concise reminder"
  assert_contains "$out2" "queued wakes pending" \
    "queued wake warning must not be suppressed by stale-banner deduplication"
  pass "fm-guard stale banner: queued-wake warning remains independent"
}

test_read_only_before_writable_does_not_consume_full_banner() {
  local dir home marker lock out_ro out_rw
  dir=$(make_guard_case read-only-before-writable)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"

  out_ro=$(run_guard_case_read_only "$dir")
  [ "$(count_text "$out_ro" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "read-only stale call should print the advisory full banner: $out_ro"
  assert_absent "$marker" "read-only stale call must not create the stale-banner marker"
  assert_absent "$lock" "read-only stale call must not create the stale-banner lock"

  out_rw=$(run_guard_case "$dir")
  [ "$(count_text "$out_rw" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "writable stale call should still receive the full banner after read-only: $out_rw"
  assert_present "$marker" "writable stale call should claim the stale-banner marker"
  pass "fm-guard stale banner: read-only before writable does not consume full banner"
}

test_read_only_during_episode_observes_without_mutating_marker() {
  local dir home marker before after out_ro
  dir=$(make_guard_case read-only-during-episode)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  out_ro=$(run_guard_case_read_only "$dir")
  after=$(cat "$marker")
  assert_contains "$out_ro" "full banner already printed this episode" \
    "read-only stale call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only stale call must not update an existing marker"
  pass "fm-guard stale banner: read-only during episode observes without mutating marker"
}

test_healthy_read_only_does_not_clear_marker() {
  local dir home marker before after healthy live
  dir=$(make_guard_case healthy-read-only)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  sleep 60 & live=$!
  record_live_daemon "$home" "$live"
  : > "$home/state/.afk"
  healthy=$(run_guard_case_read_only "$dir")
  [ -z "$healthy" ] || fail "healthy read-only guard should stay silent, got: $healthy"
  assert_present "$marker" "healthy read-only guard must not clear the stale-banner marker"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "healthy read-only guard must not update the marker"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "fm-guard stale banner: healthy read-only does not clear marker"
}

test_read_only_never_mutates_stale_banner_state_files() {
  local dir home marker lock before after no_work
  dir=$(make_guard_case read-only-state-nonmutation)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"
  printf '%s\n' "sentinel-marker" > "$marker"

  before=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  run_guard_case_read_only "$dir" >/dev/null
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "stale read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "stale read-only guard updated the marker content"
  assert_absent "$lock" "stale read-only guard must not create the stale-banner lock"

  rm -f "$home/state/task.meta"
  no_work=$(run_guard_case_read_only "$dir")
  [ -z "$no_work" ] || fail "read-only guard with no in-flight work should stay silent, got: $no_work"
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "no-work read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "no-work read-only guard updated the marker content"
  pass "fm-guard stale banner: read-only never mutates stale-banner state files"
}

# --- addressee: firstmate's own session vs a task worker ---------------------
# fm-guard has no primary-scope gate by design, so a crewmate or scout runs its
# own tracked copy against the LAUNCHING home (bin/fm-spawn.sh puts FM_HOME into
# every worker launch command, and bin/fm-send.sh calls this guard on every
# send). It used to print 'Daemon repair: bin/fm-watcher-service.sh restart' -
# verbatim the string measured live on 2026-08-30 - to a worker that AGENTS.md
# section 1 forbids to run it. The alarm itself must survive untouched: the
# worker still needs to know supervision stalled so it can report it.
WORKER_REPORT_REASON='repairing it belongs to firstmate, not to a task worker: report the stalled supervision in your task status line and carry on with your own task in this worktree'
WORKER_FORBIDDEN_COMMANDS='bin/fm-watcher-service.sh bin/fm-delivery-service.sh'

assert_names_no_worker_forbidden_command() {
  local out=$1 context=$2 command
  for command in $WORKER_FORBIDDEN_COMMANDS; do
    assert_not_contains "$out" "$command" "$context ($command)"
  done
}

test_worker_daemon_banner_names_no_command_reserved_to_firstmate() {
  local dir out
  dir=$(make_guard_case worker-daemon-banner)
  out=$(run_guard_case_as_worker "$dir")
  [ "$(count_text "$out" "WATCHER DAEMON DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a task worker must still get the full alarm for the launching home: $out"
  assert_contains "$out" "task(s) in flight" "worker banner must keep the in-flight and beacon line"
  assert_contains "$out" "WILL still run" "worker banner must keep the guarded-operation continuation line"
  assert_contains "$out" "$WORKER_REPORT_REASON" "worker banner must name reporting as the worker's action"
  assert_not_contains "$out" "Daemon repair:" "worker banner must not carry a repair line at all"
  assert_names_no_worker_forbidden_command "$out" \
    "worker banner handed a task worker a command AGENTS.md reserves to firstmate"
  pass "fm-guard: a task worker still gets the daemon alarm but no command reserved to firstmate"
}

test_worker_delivery_warning_keeps_relay_prefix_without_a_repair() {
  local dir home worker out live
  dir=$(make_guard_case worker-delivery)
  home=$(case_home "$dir")
  worker=$(make_worker_checkout "$dir")
  sleep 60 & live=$!
  record_live_daemon "$home" "$live" "$worker/bin/fm-watch.sh"
  out=$(run_guard_case_as_worker "$dir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  assert_contains "$out" "WARNING: wake delivery listener " \
    "bin/fm-bridge-relay.sh classifies this line by prefix, so the worker variant must keep it"
  assert_contains "$out" "$WORKER_REPORT_REASON" \
    "worker delivery warning must name reporting as the worker's action"
  assert_names_no_worker_forbidden_command "$out" \
    "worker delivery warning handed a task worker a command AGENTS.md reserves to firstmate"
  pass "fm-guard: a task worker's delivery warning keeps the relay prefix and carries no repair"
}

# The other half of the pair: the session that operates this home must still be
# handed a repair. The fix is an addressee split, not a quietening.
test_operator_delivery_warning_still_carries_the_repair() {
  local dir home out live
  dir=$(make_guard_case operator-delivery)
  home=$(case_home "$dir")
  sleep 60 & live=$!
  record_live_daemon "$home" "$live"
  out=$(run_guard_case "$dir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  assert_contains "$out" "WARNING: wake delivery listener " \
    "the operator delivery warning must keep the relay prefix"
  assert_contains "$out" "Repair wake delivery according to the session-start operating block." \
    "the session operating this home must still be told to repair delivery"
  assert_not_contains "$out" "$WORKER_REPORT_REASON" \
    "the operator must not be told to report the repair to someone else"
  pass "fm-guard: the session operating this home still gets its delivery repair instruction"
}

test_first_stale_call_prints_full_banner
test_repeated_same_episode_prints_reminder_only
test_healthy_recovery_rearms_next_stale_episode
test_concurrent_same_episode_prints_one_full_banner
test_home_isolation
test_queued_wake_warning_stays_independent
test_read_only_before_writable_does_not_consume_full_banner
test_read_only_during_episode_observes_without_mutating_marker
test_healthy_read_only_does_not_clear_marker
test_read_only_never_mutates_stale_banner_state_files
test_worker_daemon_banner_names_no_command_reserved_to_firstmate
test_worker_delivery_warning_keeps_relay_prefix_without_a_repair
test_operator_delivery_warning_still_carries_the_repair
