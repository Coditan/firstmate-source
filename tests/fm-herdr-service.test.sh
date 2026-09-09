#!/usr/bin/env bash
# Herdr runtime ownership: backend selection, adoption, detached start,
# survival of an owner teardown, and the readings the digest reports.
#
# The `herdr` here is a stub, deliberately, and this file states what that buys
# and what it does not.  What is under test is a PROCESS-TREE property - that the
# server the owner starts is in a session of its own, so killing the owner's
# process group the way a keeper teardown does cannot reach it - and that
# property belongs to the start mechanism, not to herdr's own code.  A stub that
# holds a pid and reports it through `status --json` exercises exactly the same
# fork, setsid, and signal paths the real binary would.  It does NOT prove
# anything about the real herdr server's own shutdown behavior, and this suite
# does not claim to; the real binary is covered by the real-herdr-gated family,
# and driving a real herdr server's lifecycle needs the guarded lab contract in
# bin/fm-herdr-lab.sh.
#
# The group-kill case carries its own control: a second, NON-detached child in
# the same process group must die from the same signal.  Without it the case
# would pass just as well if the kill had reached nothing at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-herdr-service.sh"
RUNTIME="$ROOT/bin/fm-herdr-runtime.sh"
# shellcheck source=bin/fm-service-path-lib.sh
. "$ROOT/bin/fm-service-path-lib.sh"
fm_test_tmproot TMP_ROOT fm-herdr-service

TRACKED_PIDS=()

KILLED_PIDS=()

cleanup_pid() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  KILLED_PIDS+=("$pid")
}

# Ordered, because these processes restart each other: a keeper left alive would
# start a replacement owner, and an owner left alive would start a replacement
# stub server, both of them after this suite has stopped looking.
cleanup() {
  local pid record
  cleanup_pid "$(cat "$TMP_ROOT/keeper.pid" 2>/dev/null || true)"
  for record in "$TMP_ROOT"/*-home/state/.herdr-runtime.lock/record; do
    [ -f "$record" ] || continue
    cleanup_pid "$(sed -n 's/^pid=//p' "$record" 2>/dev/null | head -1)"
  done
  for pid in "${TRACKED_PIDS[@]:-}"; do
    cleanup_pid "$pid"
  done
  # Every stub server this suite started, whether or not the case that started
  # it got as far as recording the pid.
  if [ -f "$TMP_ROOT/herdr-state/server-pids" ]; then
    while IFS= read -r pid; do cleanup_pid "$pid"; done < "$TMP_ROOT/herdr-state/server-pids"
  fi
  # A dying owner recreates its own state directory on its way out (it logs and
  # beats there), so removing the tree before the signals have landed leaves the
  # empty skeleton behind.  Wait for the processes rather than guessing at a
  # sleep.
  for pid in "${KILLED_PIDS[@]:-}"; do
    wait_for_dead "$pid" 30 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

# A stub `herdr` whose state directory is baked in as a literal, because the
# keeper tier runs under the tmux server's environment and inherits nothing this
# test exports.
make_fake_herdr() {  # <fakebin> <state-dir>
  local fakebin=$1 state=$2
  mkdir -p "$fakebin" "$state"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
HERDR_STUB_STATE='$state'
SH
  cat >> "$fakebin/herdr" <<'SH'
prev_flag=
session=default
sub=
for arg in "$@"; do
  if [ "$prev_flag" = session ]; then session=$arg; prev_flag=; continue; fi
  case "$arg" in
    --session) prev_flag=session ;;
    --*) ;;
    *) [ -n "$sub" ] || sub=$arg ;;
  esac
done
run="$HERDR_STUB_STATE/running-$session"
case "$sub" in
  status)
    running=false
    if [ -e "$run" ] && kill -0 "$(cat "$run" 2>/dev/null || echo 0)" 2>/dev/null; then
      running=true
    fi
    printf '{"client":{"version":"0.7.4","protocol":16},"server":{"status":"running","running":%s,"protocol":16,"capabilities":{"detached_server_daemon":false},"compatible":true}}\n' "$running"
    ;;
  server)
    if [ -e "$run" ] && kill -0 "$(cat "$run" 2>/dev/null || echo 0)" 2>/dev/null; then
      echo "stub: a server is already bound for session $session" >&2
      exit 1
    fi
    printf '%s\n' "$$" > "$run"
    printf '%s\n' "$$" >> "$HERDR_STUB_STATE/server-pids"
    echo "stub server up for session $session"
    trap 'rm -f "$run"; exit 0' TERM INT HUP
    while :; do sleep 0.2; done
    ;;
  *)
    echo "stub: unsupported herdr invocation: $*" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

# The fake tmux the watcher-service suite already uses, adapted to this keeper's
# six launch arguments.
make_fake_tmux_keeper() {  # <fakebin>
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_TMUX_LOG:?}"
case "${1:-}" in
  has-session)
    pid=$(cat "${FM_TEST_KEEPER_PID_FILE:?}" 2>/dev/null || true)
    kill -0 "$pid" 2>/dev/null
    ;;
  new-session)
    "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$FM_TEST_KEEPER_PID_FILE"
    ;;
  kill-session)
    pid=$(cat "${FM_TEST_KEEPER_PID_FILE:?}" 2>/dev/null || true)
    kill -TERM "$pid" 2>/dev/null || true
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

make_home() {  # <dir> [backend]
  local home=$1 backend=${2:-herdr}
  mkdir -p "$home/state" "$home/config"
  [ "$backend" = none ] || printf '%s\n' "$backend" > "$home/config/backend"
  printf '%s\n' "$home"
}

stub_server_pid() {  # <state-dir> <session>
  cat "$1/running-$2" 2>/dev/null || true
}

wait_for_file() {  # <path> [tries]
  local path=$1 tries=${2:-100}
  while [ "$tries" -gt 0 ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

wait_for_dead() {  # <pid> [tries]
  local pid=$1 tries=${2:-50}
  while [ "$tries" -gt 0 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

reading_field() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/state/.herdr-runtime.lock/reading" 2>/dev/null | head -1
}

# A reading published after the one taken at <previous-at>, which is how a caller
# tells a loop that is still going round from one frozen mid-poll.
wait_for_new_reading() {  # <home> <previous-at> [tries]
  local home=$1 prev=$2 tries=${3:-100} now
  while [ "$tries" -gt 0 ]; do
    now=$(reading_field "$home" at)
    [ -n "$now" ] && [ "$now" != "$prev" ] && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

test_a_home_that_does_not_run_herdr_is_left_alone() {
  local home out
  home=$(make_home "$TMP_ROOT/tmux-home" tmux)
  out=$(FM_HOME="$home" "$SERVICE" bootstrap)
  [ -z "$out" ] || fail "a tmux home produced a herdr runtime diagnostic: $out"
  out=$(FM_HOME="$home" "$SERVICE" status)
  assert_contains "$out" "not-applicable" "a tmux home did not report the runtime as not applicable"
  pass "a home that does not spawn into herdr neither installs nor reports a runtime owner"
}

test_install_and_restart_refuse_a_home_that_does_not_run_herdr() {
  local fakebin home err
  fakebin="$TMP_ROOT/refuse-bin"
  home=$(make_home "$TMP_ROOT/refuse-home" tmux)
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\necho "systemctl must not run on a tmux home: $*" >> "%s/refuse.calls"\nexit 0\n' "$TMP_ROOT" > "$fakebin/systemctl"
  printf '#!/usr/bin/env bash\necho "tmux must not run on a tmux home: $*" >> "%s/refuse.calls"\nexit 0\n' "$TMP_ROOT" > "$fakebin/tmux"
  chmod +x "$fakebin/systemctl" "$fakebin/tmux"
  err=$(FM_HOME="$home" FM_HERDR_SYSTEMCTL="$fakebin/systemctl" FM_HERDR_TMUX="$fakebin/tmux" \
    FM_HERDR_SYSTEMD_UNIT_DIR="$TMP_ROOT/refuse-units" "$SERVICE" install-unit 2>&1 >/dev/null) \
    && fail "install-unit installed a runtime owner on a home that does not run herdr"
  assert_contains "$err" "does not spawn workers into herdr" "install-unit did not say why it refused: $err"
  err=$(FM_HOME="$home" FM_HERDR_SYSTEMCTL="$fakebin/systemctl" FM_HERDR_TMUX="$fakebin/tmux" \
    "$SERVICE" restart 2>&1 >/dev/null) \
    && fail "restart converged a runtime owner on a home that does not run herdr"
  assert_contains "$err" "does not spawn workers into herdr" "restart did not say why it refused: $err"
  [ ! -e "$TMP_ROOT/refuse.calls" ] || fail "a refused install or restart still drove a service manager: $(cat "$TMP_ROOT/refuse.calls")"
  [ ! -e "$TMP_ROOT/refuse-units/fm-herdr@.service" ] || fail "a refused install still wrote the unit"
  pass "install-unit and restart refuse a home that does not spawn into herdr"
}

test_selection_falls_back_to_the_keeper_tier() {
  local fakebin home out
  fakebin="$TMP_ROOT/select-bin"
  home=$(make_home "$TMP_ROOT/select-home")
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/systemctl" "$fakebin/tmux"
  out=$(FM_HOME="$home" FM_HERDR_SYSTEMCTL="$fakebin/systemctl" FM_HERDR_TMUX="$fakebin/tmux" "$SERVICE" select)
  [ "$out" = keeper ] || fail "unusable systemd should select the keeper tier, got: $out"
  pass "an unusable systemd user manager selects the tmux keeper tier"
}

test_owner_adopts_a_running_runtime_without_restarting_it() {
  local fakebin state home before after
  fakebin="$TMP_ROOT/adopt-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/adopt-home")
  make_fake_herdr "$fakebin" "$state"

  # A runtime somebody else started, exactly the state every live herdr home is
  # in on the day this owner first arrives.
  PATH="$fakebin:$PATH" HERDR_SESSION=adopt "$fakebin/herdr" server --session adopt >/dev/null 2>&1 &
  TRACKED_PIDS+=("$!")
  wait_for_file "$state/running-adopt" || fail "the stub runtime never came up"
  before=$(stub_server_pid "$state" adopt)

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_RUNTIME_SESSION=adopt \
    FM_HERDR_RUNTIME_ONCE=1 "$RUNTIME" || fail "the owner failed on an already-running runtime"
  after=$(stub_server_pid "$state" adopt)
  [ "$before" = "$after" ] || fail "the owner replaced a running runtime (was $before, now $after)"
  kill -0 "$after" 2>/dev/null || fail "the owner ended a running runtime"
  [ "$(reading_field "$home" reading)" = running ] || fail "the owner did not record the adopted runtime as running"
  [ "$(reading_field "$home" starts)" = 0 ] || fail "the owner started a server it did not need to start"
  pass "an owner adopts a running runtime rather than restarting it"
}

test_owner_starts_a_down_runtime_in_a_session_of_its_own() {
  local fakebin state home owner_sid server_pid server_sid
  command -v setsid >/dev/null 2>&1 || { echo "skip: setsid not available"; return 0; }
  fakebin="$TMP_ROOT/start-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/start-home")
  make_fake_herdr "$fakebin" "$state"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_RUNTIME_SESSION=start \
    FM_HERDR_RUNTIME_ONCE=1 FM_HERDR_RUNTIME_CONFIRM_SLEEP=0.2 "$RUNTIME" \
    || fail "the owner failed on a runtime that was down"
  wait_for_file "$state/running-start" || fail "the owner did not start the runtime"
  server_pid=$(stub_server_pid "$state" start)
  [ "$(reading_field "$home" reading)" = running ] || fail "the owner did not record the started runtime as running"
  [ "$(reading_field "$home" detach)" = setsid ] || fail "the runtime was not started through setsid: $(reading_field "$home" detach)"

  # The session id is the load-bearing fact: a server in this shell's own session
  # is one a signal to that session reaches.
  owner_sid=$(ps -o sid= -p $$ | tr -d ' ')
  server_sid=$(ps -o sid= -p "$server_pid" | tr -d ' ')
  [ -n "$server_sid" ] || fail "could not read the started runtime's session id"
  [ "$server_sid" != "$owner_sid" ] || fail "the runtime was started inside the caller's own session ($server_sid)"
  pass "an owner starts a down runtime detached, in a session of its own"
}

test_server_output_has_its_own_capped_file() {
  local fakebin state home server_log owner_log
  fakebin="$TMP_ROOT/log-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/log-home")
  make_fake_herdr "$fakebin" "$state"
  server_log="$home/state/.herdr-server.log"
  owner_log="$home/state/.herdr-runtime.log"

  # Output from a previous runtime, already past the bound.
  head -c 3000 /dev/zero | tr '\0' 'x' > "$server_log"
  printf '\nold runtime last words\n' >> "$server_log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_RUNTIME_SESSION=logged \
    FM_HERDR_SERVER_LOG_MAX_BYTES=2048 \
    FM_HERDR_RUNTIME_ONCE=1 FM_HERDR_RUNTIME_CONFIRM_SLEEP=0.2 "$RUNTIME" \
    || fail "the owner failed on a runtime that was down"
  wait_for_file "$state/running-logged" || fail "the owner did not start the runtime"
  wait_for_file "$server_log" || fail "the server log was not recreated"

  assert_contains "$(cat "$server_log.1")" "old runtime last words" \
    "the copy taken at the cap lost the previous runtime's output"
  [ "$(wc -c < "$server_log")" -lt 2048 ] || fail "the server log was not truncated at the bound"
  local tries=50
  while [ "$tries" -gt 0 ] && ! grep -q "stub server up for session logged" "$server_log" 2>/dev/null; do
    sleep 0.1; tries=$((tries - 1))
  done
  assert_contains "$(cat "$server_log")" "stub server up for session logged" \
    "the started server's own output did not land in the server log"
  assert_contains "$(cat "$owner_log")" "started the herdr runtime for session logged" \
    "the owner's own line did not land in the owner log"
  case "$(cat "$owner_log")" in
    *"stub server up"*) fail "the server's output leaked into the owner's log" ;;
  esac
  pass "the server's output has its own file, kept apart from the owner's and capped once"
}

test_a_reading_that_could_not_be_taken_is_not_a_reading_of_down() {
  local emptybin state home out
  emptybin="$TMP_ROOT/empty-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/unreadable-home")
  mkdir -p "$emptybin"
  # jq is present, herdr is not: the owner cannot see the runtime at all.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$emptybin/tmux"
  chmod +x "$emptybin/tmux"

  PATH="$emptybin:/usr/bin:/bin" FM_HOME="$home" FM_HERDR_RUNTIME_SESSION=blind \
    FM_HERDR_RUNTIME_ONCE=1 "$RUNTIME" || fail "the owner failed rather than reporting an unreadable runtime"
  [ "$(reading_field "$home" reading)" = unreadable ] \
    || fail "an unreadable runtime was recorded as '$(reading_field "$home" reading)'"
  [ "$(reading_field "$home" starts)" = 0 ] || fail "the owner started a server on a reading it could not take"
  [ ! -e "$state/running-blind" ] || fail "the owner bound a server for a session it could not read"

  out=$(PATH="$emptybin:/usr/bin:/bin" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$emptybin/tmux" FM_BOOTSTRAP_DETECT_ONLY=1 "$SERVICE" bootstrap)
  assert_contains "$out" "cannot read whether the worker runtime is running" \
    "the digest did not report the unreadable runtime as unreadable"
  pass "a runtime the owner cannot read is reported as unreadable and never started over"
}

test_a_keeper_teardown_does_not_take_the_runtime_with_it() {
  local fakebin state home script pgid server_pid control_pid
  command -v setsid >/dev/null 2>&1 || { echo "skip: setsid not available"; return 0; }
  fakebin="$TMP_ROOT/detach-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/detach-home")
  make_fake_herdr "$fakebin" "$state"

  # A stand-in for the keeper pane: its own session and process group, holding
  # the owner and a plain control child.  Killing that group is what a tmux
  # kill-session, a systemd stop, or the watcher restart of 2026-09-04 does.
  script="$TMP_ROOT/detach-group.sh"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
export PATH="$fakebin:\$PATH"
export FM_HOME="$home"
export FM_HERDR_RUNTIME_SESSION=detach
export FM_HERDR_RUNTIME_CONFIRM_SLEEP=0.2
export FM_HERDR_RUNTIME_POLL=1
sleep 600 &
printf '%s\n' "\$!" > "$TMP_ROOT/control.pid"
printf '%s\n' "\$\$" > "$TMP_ROOT/group.pid"
exec "$RUNTIME"
SH
  chmod +x "$script"
  setsid "$script" >/dev/null 2>&1 &
  TRACKED_PIDS+=("$!")

  wait_for_file "$state/running-detach" || fail "the group-hosted owner never started the runtime"
  wait_for_file "$TMP_ROOT/control.pid" || fail "the control child was never recorded"
  server_pid=$(stub_server_pid "$state" detach)
  control_pid=$(cat "$TMP_ROOT/control.pid")
  pgid=$(ps -o pgid= -p "$(cat "$TMP_ROOT/group.pid")" | tr -d ' ')
  [ -n "$pgid" ] || fail "could not read the owner's process group"

  kill -TERM -- "-$pgid" 2>/dev/null || fail "could not signal the owner's process group"

  # The control proves the signal actually landed on the group.
  wait_for_dead "$control_pid" || fail "the group signal did not reach the group's own children"
  sleep 0.5
  kill -0 "$server_pid" 2>/dev/null \
    || fail "tearing the owner's process group down took the runtime with it (pid $server_pid)"
  [ "$(stub_server_pid "$state" detach)" = "$server_pid" ] \
    || fail "the runtime record changed when the owner group was torn down"
  pass "tearing down the owner takes the watching, never the runtime"
}

test_the_keeper_tier_starts_stops_and_readopts_one_runtime() {
  local fakebin state home log server_pid keeper_pid out recorded_path
  fakebin="$TMP_ROOT/keeper-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/keeper-home")
  log="$TMP_ROOT/keeper-tmux.log"
  make_fake_herdr "$fakebin" "$state"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"

  # The owner runs with a PATH the SERVICE composes, not with this shell's, and
  # the default tool list walks tools that resolve from the seat's own
  # directories.  On a seat where an earlier tool lives beside a real `herdr`,
  # that directory would sort ahead of the fixture bin and the owner would drive
  # a real herdr server.  This suite must never do that under any host layout, so
  # the list is pinned to what this case actually needs and the result asserted
  # below rather than left to the seat.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$fakebin/tmux" FM_HERDR_RUNTIME_SESSION=keeper \
    FM_SERVICE_TOOLS='herdr jq tmux' \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_HERDR_CONFIRM_TIMEOUT=15 "$SERVICE" ensure \
    || fail "the keeper tier did not establish a runtime owner"
  assert_contains "$(cat "$log")" "new-session -d -s fm-herdr-" \
    "the keeper tier did not start a detached home-scoped keeper"
  [ "$(sed -n 's/^manager=//p' "$home/state/.herdr-runtime.lock/record" | head -1)" = keeper ] \
    || fail "the owner did not record the keeper as its manager"
  # What the owner would actually run, resolved through the PATH it was handed.
  recorded_path=$(sed -n 's/^service-path=//p' "$home/state/.herdr-runtime.lock/record" | head -1)
  [ -n "$recorded_path" ] || fail "the owner did not record the PATH it was launched with"
  [ "$(PATH="$recorded_path" command -v herdr 2>/dev/null)" = "$fakebin/herdr" ] \
    || fail "the owner's recorded PATH resolves herdr to $(PATH="$recorded_path" command -v herdr 2>/dev/null || echo nothing), not to this suite's stub"
  wait_for_file "$state/running-keeper" || fail "the keeper-owned runtime never came up"
  server_pid=$(stub_server_pid "$state" keeper)
  keeper_pid=$(cat "$TMP_ROOT/keeper.pid")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$fakebin/tmux" FM_HERDR_RUNTIME_SESSION=keeper \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" "$SERVICE" status)
  assert_contains "$out" "up: runtime owner pid" "a keeper-owned runtime did not report as up"
  assert_contains "$out" "runtime reading running" "a keeper-owned runtime did not report its own reading"

  # Restarting the owner is the convergence every session start may perform with
  # a full fleet of workers on the home; it must not disturb the runtime.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$fakebin/tmux" FM_HERDR_RUNTIME_SESSION=keeper \
    FM_SERVICE_TOOLS='herdr jq tmux' \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_HERDR_CONFIRM_TIMEOUT=15 "$SERVICE" restart \
    || fail "restarting the runtime owner failed"
  [ "$(cat "$TMP_ROOT/keeper.pid")" != "$keeper_pid" ] || fail "restart did not replace the keeper"
  kill -0 "$server_pid" 2>/dev/null || fail "restarting the owner ended the runtime it was watching"
  [ "$(stub_server_pid "$state" keeper)" = "$server_pid" ] \
    || fail "the restarted owner replaced the runtime instead of readopting it"
  [ "$(reading_field "$home" starts)" = 0 ] || fail "the restarted owner started a second server"
  pass "the keeper tier starts, restarts, and readopts exactly one runtime"
}

# A client that never answers is the degradation this owner exists to notice, so
# the reading it takes has to survive one: an unbounded read would stop the loop
# inside the failure it is watching for.
test_a_client_that_never_answers_leaves_the_owner_beating() {
  local fakebin state home owner first hung pid
  fakebin="$TMP_ROOT/hang-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/hang-home")
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
HERDR_STUB_STATE='$state'
SH
  cat >> "$fakebin/herdr" <<'SH'
sub=
for arg in "$@"; do
  case "$arg" in --*) ;; *) [ -n "$sub" ] || sub=$arg ;; esac
done
case "$sub" in
  status)
    # Wedged on its socket: it answers nothing, ever.
    printf '%s\n' "$$" >> "$HERDR_STUB_STATE/hang-status-pids"
    while :; do sleep 0.2; done
    ;;
  server)
    printf '%s\n' "$$" >> "$HERDR_STUB_STATE/server-pids"
    printf '%s\n' "$$" > "$HERDR_STUB_STATE/running-hang"
    while :; do sleep 0.2; done
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  rm -f "$state/hang-status-pids"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_RUNTIME_SESSION=hang \
    FM_HERDR_RUNTIME_POLL=1 FM_HERDR_RUNTIME_STATUS_TIMEOUT=1 "$RUNTIME" >/dev/null 2>&1 &
  owner=$!
  TRACKED_PIDS+=("$owner")

  wait_for_file "$home/state/.herdr-runtime.lock/reading" 200 \
    || fail "the owner never published a reading against a client that does not answer"
  [ "$(reading_field "$home" reading)" = unreadable ] \
    || fail "a client that did not answer was recorded as '$(reading_field "$home" reading)'"
  case "$(reading_field "$home" note)" in
    *"did not answer"*) ;;
    *) fail "the wedged client is not distinguishable from a missing tool: $(reading_field "$home" note)" ;;
  esac

  # Still beating: a second reading, later than the first, proves the loop did not
  # freeze inside the blocked call.
  first=$(reading_field "$home" at)
  wait_for_new_reading "$home" "$first" 200 \
    || fail "the owner stopped publishing readings while the client hung"
  kill -0 "$owner" 2>/dev/null || fail "the owner exited instead of continuing to watch"
  [ "$(reading_field "$home" starts)" = 0 ] \
    || fail "the owner started a server on a reading it could not take"
  [ ! -e "$state/running-hang" ] || fail "the owner bound a server for a session it could not read"

  # Every timed-out client but the one in flight is gone: the deadline reaches the
  # blocked process rather than leaving one behind per poll.
  hung=$(sed '$d' "$state/hang-status-pids" 2>/dev/null || true)
  [ -n "$hung" ] || fail "the fixture never recorded a blocked client"
  for pid in $hung; do
    wait_for_dead "$pid" 50 || fail "a timed-out herdr client was left running (pid $pid)"
  done
  pass "a client that never answers leaves the owner beating on an unreadable reading"
}

# A keeper that dies without running its trap leaves its owner child alive, and
# the next convergence must replace THAT owner rather than start a second one
# beside it.
test_a_killed_keeper_leaves_no_second_owner_behind() {
  local fakebin state home log pidfile keeper_pid first_owner second_owner server_pid
  fakebin="$TMP_ROOT/orphan-bin"
  state="$TMP_ROOT/herdr-state"
  home=$(make_home "$TMP_ROOT/orphan-home")
  log="$TMP_ROOT/orphan-tmux.log"
  pidfile="$TMP_ROOT/orphan-keeper.pid"
  make_fake_herdr "$fakebin" "$state"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$fakebin/tmux" FM_HERDR_RUNTIME_SESSION=orphan \
    FM_SERVICE_TOOLS='herdr jq tmux' \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$pidfile" \
    FM_HERDR_CONFIRM_TIMEOUT=15 "$SERVICE" ensure \
    || fail "the keeper tier did not establish a runtime owner"
  keeper_pid=$(cat "$pidfile")
  first_owner=$(sed -n 's/^pid=//p' "$home/state/.herdr-runtime.lock/record" | head -1)
  TRACKED_PIDS+=("$keeper_pid" "$first_owner")
  wait_for_file "$state/running-orphan" || fail "the keeper-owned runtime never came up"
  server_pid=$(stub_server_pid "$state" orphan)

  # SIGKILL: the keeper's cleanup never runs, so its owner child survives it,
  # reparented and still writing the record, the beacon and the reading.
  kill -KILL "$keeper_pid" 2>/dev/null || fail "could not kill the keeper"
  wait_for_dead "$keeper_pid" || fail "the keeper did not die"
  kill -0 "$first_owner" 2>/dev/null || fail "the fixture left no orphaned owner to converge over"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HERDR_SERVICE_FORCE_BACKEND=keeper \
    FM_HERDR_TMUX="$fakebin/tmux" FM_HERDR_RUNTIME_SESSION=orphan \
    FM_SERVICE_TOOLS='herdr jq tmux' \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$pidfile" \
    FM_HERDR_CONFIRM_TIMEOUT=15 "$SERVICE" ensure \
    || fail "convergence over an orphaned owner failed"
  TRACKED_PIDS+=("$(cat "$pidfile")")
  second_owner=$(sed -n 's/^pid=//p' "$home/state/.herdr-runtime.lock/record" | head -1)
  [ "$second_owner" != "$first_owner" ] || fail "convergence did not replace the orphaned owner"
  wait_for_dead "$first_owner" 50 \
    || fail "convergence started a second owner beside the orphaned one (pid $first_owner still writes the record)"
  kill -0 "$second_owner" 2>/dev/null || fail "the replacement owner is not running"

  # And the runtime is untouched by any of it.
  kill -0 "$server_pid" 2>/dev/null || fail "replacing the owner ended the runtime it was watching"
  [ "$(stub_server_pid "$state" orphan)" = "$server_pid" ] \
    || fail "the replacement owner started a second runtime instead of readopting one"
  pass "a keeper killed outright leaves exactly one owner after convergence"
}

test_the_entrypoint_command_is_printed_verbatim() {
  local home out
  home=$(make_home "$TMP_ROOT/entrypoint-home")
  out=$(FM_HOME="$home" "$SERVICE" entrypoint-command)
  [ "$out" = "FM_HOME=$home $ROOT/bin/fm-herdr-service.sh ensure" ] \
    || fail "the entrypoint command is not the one a vessel definition can copy: $out"
  pass "the vessel entrypoint command is printed as one copyable line"
}

test_a_home_that_does_not_run_herdr_is_left_alone
test_install_and_restart_refuse_a_home_that_does_not_run_herdr
test_selection_falls_back_to_the_keeper_tier
test_owner_adopts_a_running_runtime_without_restarting_it
test_owner_starts_a_down_runtime_in_a_session_of_its_own
test_server_output_has_its_own_capped_file
test_a_reading_that_could_not_be_taken_is_not_a_reading_of_down
test_a_keeper_teardown_does_not_take_the_runtime_with_it
test_the_keeper_tier_starts_stops_and_readopts_one_runtime
test_a_client_that_never_answers_leaves_the_owner_beating
test_a_killed_keeper_leaves_no_second_owner_behind
test_the_entrypoint_command_is_printed_verbatim
