#!/usr/bin/env bash
# Watcher service backend selection, consent, fallback, and convergence tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-watcher-service.sh"
# shellcheck source=bin/fm-service-path-lib.sh
. "$ROOT/bin/fm-service-path-lib.sh"
unset FM_TEST_SKIP_WATCHER_SERVICE
fm_test_tmproot TMP_ROOT fm-watcher-service

cleanup_process_file() {
  local file=$1 pid
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  cleanup_process_file "$TMP_ROOT/systemd-watcher.pid"
  cleanup_process_file "$TMP_ROOT/keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeperpath.pid"
  cleanup_process_file "$TMP_ROOT/keeperreport.pid"
  cleanup_process_file "$TMP_ROOT/keeper-home/state/.watch-keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeper-home/state/.watch.lock/pid"
  cleanup_process_file "$TMP_ROOT/keeperpath-home/state/.watch-keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeperpath-home/state/.watch.lock/pid"
  cleanup_process_file "$TMP_ROOT/keeperreport-home/state/.watch-keeper.pid"
  cleanup_process_file "$TMP_ROOT/keeperreport-home/state/.watch.lock/pid"
  fm_test_cleanup
}
trap cleanup EXIT

make_fake_systemd() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SYSTEMCTL_LOG:?}"
case "$*" in
  '--user show-environment') exit 0 ;;
  '--user is-enabled --quiet '*) exit 0 ;;
  '--user is-active --quiet '*)
    pid=$(cat "${FM_TEST_SYSTEMD_PID_FILE:?}" 2>/dev/null || true)
    kill -0 "$pid" 2>/dev/null
    exit
    ;;
  '--user daemon-reload') exit 0 ;;
  '--user restart '*|'--user enable --now '*)
    pid=$(cat "${FM_TEST_SYSTEMD_PID_FILE:?}" 2>/dev/null || true)
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      i=0
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.01
        i=$((i + 1))
      done
    fi
    set -a
    # shellcheck disable=SC1090
    . "${FM_TEST_SERVICE_ENV:?}"
    set +a
    FM_WATCH_DAEMON=1 FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      bash "$FM_WATCH_EXEC" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$FM_TEST_SYSTEMD_PID_FILE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/loginctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'show-user '*'-p Linger --value') printf '%s\n' no; exit 0 ;;
  'enable-linger '*) printf 'enabled\n' >> "${FM_TEST_LOGINCTL_LOG:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/systemctl" "$fakebin/loginctl"
}

make_fake_tmux_keeper() {
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
    # A real tmux runs the command under the SERVER's environment, not this
    # caller's, which is why the keeper takes the PATH it must run with as an
    # argument. Record that argument so the test can assert it was supplied.
    printf '%s\n' "${11}" > "${FM_TEST_KEEPER_PATH_FILE:-/dev/null}"
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

test_unusable_systemd_selects_tmux_keeper() {
  local fakebin home out
  fakebin="$TMP_ROOT/select-bin"
  home="$TMP_ROOT/select-home"
  mkdir -p "$fakebin" "$home/state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/systemctl" "$fakebin/tmux"
  out=$(FM_HOME="$home" FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_TMUX="$fakebin/tmux" "$SERVICE" select)
  [ "$out" = keeper ] || fail "unusable systemd should select keeper, got: $out"
  pass "systemd --user failure automatically selects the tmux keeper tier"
}

test_missing_systemd_unit_requires_separate_consent() {
  local fakebin home unitdir out
  fakebin="$TMP_ROOT/consent-bin"
  home="$TMP_ROOT/consent-home"
  unitdir="$TMP_ROOT/consent-units"
  mkdir -p "$home/state" "$unitdir"
  make_fake_systemd "$fakebin"
  : > "$TMP_ROOT/systemctl-consent.log"
  : > "$TMP_ROOT/loginctl-consent.log"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl-consent.log" \
    FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-consent.log" "$SERVICE" bootstrap)
  assert_contains "$out" "install watcher-unit" "missing unit did not surface unit-install consent"
  assert_contains "$out" "install watcher-linger" "disabled lingering did not surface separate consent"
  assert_absent "$unitdir/fm-watch@.service" "bootstrap silently installed the systemd unit"
  [ ! -s "$TMP_ROOT/loginctl-consent.log" ] || fail "bootstrap silently enabled lingering"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl-consent.log")" "enable --now" "bootstrap silently enabled the unit"
  pass "unit installation and lingering remain separate explicit-consent operations"
}

test_keeper_fallback_establishes_real_watcher() {
  local fakebin home log manager old_watcher_pid new_watcher_pid i
  fakebin="$TMP_ROOT/keeper-bin"
  home="$TMP_ROOT/keeper-home"
  log="$TMP_ROOT/keeper-tmux.log"
  mkdir -p "$home/state" "$home/config"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeper.path" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "tmux keeper fallback did not establish a healthy watcher"
  # The keeper tier must resolve its own tools too: a fix that only reached the
  # systemd unit would leave every keeper-backed home reading crew state blind.
  [ "$(cat "$TMP_ROOT/keeper.path")" = "$(fm_service_path)" ] \
    || fail "the keeper was launched without the resolved service PATH: $(cat "$TMP_ROOT/keeper.path")"
  [ -z "$(fm_service_path_unreachable "$(cat "$TMP_ROOT/keeper.path")")" ] \
    || fail "the keeper's PATH cannot reach $(fm_service_path_unreachable "$(cat "$TMP_ROOT/keeper.path")" | tr '\n' ' ')"
  manager=$(cat "$home/state/.watch.lock/manager")
  [ "$manager" = keeper ] || fail "fallback watcher recorded manager=$manager instead of keeper"
  assert_contains "$(cat "$log")" "new-session -d -s fm-watch-" "fallback did not start a detached home-scoped keeper"
  # A queued wake must survive with no consumer at all: nothing in this session
  # holds delivery any more, so the only thing that may touch the queue is a
  # model turn running the drain.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" . "$ROOT/bin/fm-wake-lib.sh"
  fm_wake_append signal keeper "signal: keeper smoke"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || fail "the keeper tier drained or duplicated the fallback wake"
  old_watcher_pid=$(cat "$home/state/.watch.lock/pid")
  printf 'FM_CHECK_INTERVAL=7\n' > "$home/config/x-mode.env"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeper.pid" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" bootstrap >/dev/null \
    || fail "tmux keeper did not converge the X-mode cadence change"
  new_watcher_pid=$(cat "$home/state/.watch.lock/pid")
  [ "$new_watcher_pid" != "$old_watcher_pid" ] || fail "X-mode cadence change did not restart the keeper watcher"
  [ "$(cat "$home/state/.watch.lock/x-mode-version")" != absent ] || fail "keeper watcher did not record the X-mode version"
  pass "keeper fallback keeps the durable queue intact and converges X-mode cadence"
}

test_installed_unit_converges_source_and_x_mode() {
  local fakebin home unitdir log old_pid new_pid restarts env_text detect_out
  fakebin="$TMP_ROOT/converge-bin"
  home="$TMP_ROOT/converge-home"
  unitdir="$TMP_ROOT/converge-units"
  log="$TMP_ROOT/systemctl-converge.log"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  make_fake_systemd "$fakebin"
  cp "$ROOT/systemd/fm-watch@.service" "$unitdir/fm-watch@.service"
  : > "$log"
  : > "$TMP_ROOT/loginctl-converge.log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" ensure || fail "installed unit did not establish a healthy watcher"
  old_pid=$(cat "$home/state/.watch.lock/pid")
  printf '%s\n' pre-update-source > "$home/state/.watch.lock/source-version"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" bootstrap >/dev/null || fail "bootstrap did not converge stale watcher source identity"
  new_pid=$(cat "$home/state/.watch.lock/pid")
  [ "$new_pid" != "$old_pid" ] || fail "stale source identity did not restart the unit"
  printf 'FM_CHECK_INTERVAL=7\n' > "$home/config/x-mode.env"
  detect_out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SERVICE" bootstrap)
  assert_contains "$detect_out" "needs locked convergence" "read-only bootstrap missed stale X-mode service environment"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-converge.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" bootstrap >/dev/null || fail "bootstrap did not converge X-mode environment"
  restarts=$(grep -c '^--user restart ' "$log")
  [ "$restarts" -eq 3 ] || fail "expected initial, source, and X-mode restarts; got $restarts"
  env_text=$(cat "$home/state/.watch-service.env")
  assert_not_contains "$env_text" 'FM_WATCH_X_MODE_VERSION="absent"' "X-mode hash stayed absent after convergence"
  pass "locked bootstrap restarts stale source and X-mode systemd instances"
}

# The unit template sets no PATH, so a service that records none inherits
# systemd's user-manager default - the 2026-08 defect, where the watcher could
# reach neither the no-mistakes CLI nor gh and answered "no state available" for
# every crew without ever failing. Two properties are pinned here: the recorded
# environment carries a PATH that reaches the tools this machine has, and a home
# whose recorded PATH does NOT reach them says so at startup instead of running
# blind.
test_service_env_records_a_reaching_path_and_reports_one_that_does_not() {
  local fakebin home unitdir log env_text recorded detect_out
  fakebin="$TMP_ROOT/servicepath-bin"
  home="$TMP_ROOT/servicepath-home"
  unitdir="$TMP_ROOT/servicepath-units"
  log="$TMP_ROOT/systemctl-servicepath.log"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  make_fake_systemd "$fakebin"
  cp "$ROOT/systemd/fm-watch@.service" "$unitdir/fm-watch@.service"
  : > "$log"
  : > "$TMP_ROOT/loginctl-servicepath.log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-servicepath.log" FM_ARM_CONFIRM_TIMEOUT=5 \
    "$SERVICE" ensure || fail "installed unit did not establish a healthy watcher"
  env_text=$(cat "$home/state/.watch-service.env")
  assert_contains "$env_text" 'PATH=' "the service environment recorded no PATH, so the unit inherits systemd's default"
  recorded=$(grep -E '^PATH=' "$home/state/.watch-service.env" | tail -1)
  recorded=${recorded#PATH=\"}; recorded=${recorded%\"}
  [ -z "$(fm_service_path_unreachable "$recorded")" ] \
    || fail "the recorded service PATH cannot reach $(fm_service_path_unreachable "$recorded" | tr '\n' ' ')"

  # A home converged before this fix - or by a session with poor reach - keeps a
  # PATH that resolves nothing. Detect-only bootstrap must name it.
  sed 's|^PATH=.*|PATH="/nonexistent-service-path"|' "$home/state/.watch-service.env" > "$home/state/.watch-service.env.tmp"
  mv -f "$home/state/.watch-service.env.tmp" "$home/state/.watch-service.env"
  detect_out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-servicepath.log" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SERVICE" bootstrap)
  assert_contains "$detect_out" "cannot reach" "a watcher that cannot resolve its own tools reported nothing at startup"
  assert_contains "$detect_out" "crew state will read as unavailable" "the report did not say what the unreachable tools cost"
  pass "the watcher records a PATH that reaches its tools, and reports one that does not"
}

# The blind spot inside the reachability check itself. It only ever asked about
# tools the ASKING session could resolve, which is silent for the one caller that
# creates the problem: a session whose own PATH lacks a required tool composes a
# recorded PATH without it, restarts the service on that recorded value, and then
# reports nothing, because the tool it just dropped is one it cannot resolve
# either. Only the separate per-session MISSING: line appears, and that line
# describes the session rather than the service it just downgraded.
test_a_required_tool_this_session_cannot_resolve_is_still_reported() {
  local fakebin home unitdir log stripped detect_out
  fakebin="$TMP_ROOT/poorreach-bin"
  home="$TMP_ROOT/poorreach-home"
  unitdir="$TMP_ROOT/poorreach-units"
  log="$TMP_ROOT/systemctl-poorreach.log"
  stripped='/usr/bin:/bin:/usr/sbin:/sbin'
  mkdir -p "$home/state" "$home/config" "$unitdir"
  make_fake_systemd "$fakebin"
  cp "$ROOT/systemd/fm-watch@.service" "$unitdir/fm-watch@.service"
  : > "$log"
  : > "$TMP_ROOT/loginctl-poorreach.log"
  # The fixture is only meaningful while the session genuinely cannot resolve the
  # required tool, so say so loudly rather than passing vacuously.
  PATH="$fakebin:$stripped" command -v no-mistakes >/dev/null 2>&1 \
    && fail "the stripped fixture PATH unexpectedly resolves no-mistakes"
  printf 'PATH="%s"\n' "$stripped" > "$home/state/.watch-service.env"
  chmod 600 "$home/state/.watch-service.env"
  detect_out=$(PATH="$fakebin:$stripped" FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=systemd \
    FM_WATCH_SYSTEMCTL="$fakebin/systemctl" FM_WATCH_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$log" FM_TEST_SYSTEMD_PID_FILE="$TMP_ROOT/systemd-watcher.pid" \
    FM_TEST_SERVICE_ENV="$home/state/.watch-service.env" \
    FM_TEST_LOGINCTL_LOG="$TMP_ROOT/loginctl-poorreach.log" \
    FM_SERVICE_REQUIRED_TOOLS='no-mistakes' FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SERVICE" bootstrap)
  assert_contains "$detect_out" "cannot reach no-mistakes" \
    "a session that recorded a PATH it cannot itself reach reported nothing about the service"
  assert_contains "$detect_out" "this session cannot resolve it either" \
    "the report did not distinguish a tool this session cannot resolve from one it can"
  pass "a required tool the converging session cannot resolve is reported, not skipped"
}

# The composed value's tail is what a unit setting no PATH inherited before any
# of this, so it must stay a superset: composing a PATH here exists to ADD reach
# for a background service, and an operator-written state/<id>.check.sh calling a
# snap-installed binary must not regress from working to failing as a side effect
# of a fix aimed at something else.
test_service_path_keeps_every_directory_the_unit_inherited() {
  local inherited composed dir
  # systemd's compiled-in user-manager default, verbatim.
  inherited='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin'
  composed=$(fm_service_path)
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case ":$composed:" in
      *":$dir:"*) ;;
      *) fail "the composed service PATH dropped $dir, which the unit inherited before it: $composed" ;;
    esac
  done <<EOF
$(printf '%s' "$inherited" | tr ':' '\n')
EOF
  pass "the composed service PATH is a superset of what the unit inherited"
}

# The keeper tier receives its PATH as a launch argument, so nothing about it was
# recorded or compared: a keeper-backed home kept a stale environment until some
# unrelated source-version change happened to restart it, while the systemd tier
# reconverged on its own recorded PATH. Parity is the property, not this one
# rollout - the next toolchain move must restart either tier the same way.
test_keeper_reconverges_when_the_resolved_path_moves() {
  local fakebin home log extra starts_after_first starts_after_move starts_after_repeat
  fakebin="$TMP_ROOT/keeperpath-bin"
  home="$TMP_ROOT/keeperpath-home"
  log="$TMP_ROOT/keeperpath-tmux.log"
  extra="$TMP_ROOT/keeperpath-extra"
  mkdir -p "$home/state" "$home/config" "$extra"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeperpath.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeperpath.path" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "tmux keeper fallback did not establish a healthy watcher"
  [ "$(cat "$home/state/.watch.lock/service-path")" = "$(fm_service_path)" ] \
    || fail "the keeper watcher did not record the PATH it was launched with"
  starts_after_first=$(grep -c 'new-session -d -s fm-watch-' "$log")

  # The toolchain moves: the same session, the same watcher bytes, a different
  # resolved PATH. The systemd tier restarts on exactly this; so must the keeper.
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeperpath.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeperpath.path" \
    FM_SERVICE_PATH_BASE="$FM_SERVICE_PATH_BASE_DEFAULT:$extra" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "the keeper did not converge the moved toolchain"
  starts_after_move=$(grep -c 'new-session -d -s fm-watch-' "$log")
  [ "$starts_after_move" -gt "$starts_after_first" ] \
    || fail "a moved toolchain left the keeper running with its stale PATH"
  case ":$(cat "$TMP_ROOT/keeperpath.path"):" in
    *":$extra:"*) ;;
    *) fail "the restarted keeper was launched with the old PATH: $(cat "$TMP_ROOT/keeperpath.path")" ;;
  esac

  # And it must SETTLE: a comparison that never matches would restart the keeper
  # on every single bootstrap, which is worse than the staleness it replaces.
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeperpath.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeperpath.path" \
    FM_SERVICE_PATH_BASE="$FM_SERVICE_PATH_BASE_DEFAULT:$extra" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "the keeper did not stay healthy on an unchanged toolchain"
  starts_after_repeat=$(grep -c 'new-session -d -s fm-watch-' "$log")
  [ "$starts_after_repeat" -eq "$starts_after_move" ] \
    || fail "an unchanged toolchain restarted the keeper anyway"
  pass "a moved toolchain restarts a keeper-backed home exactly as it restarts a systemd-backed one"
}

# And a keeper-backed home running blind must say so at startup. Before this the
# keeper branch of bootstrap emitted no equivalent of the systemd branch's
# reachability line at all, so the tier that is chosen precisely when systemd is
# unusable was also the tier that reported nothing.
test_keeper_reports_a_recorded_path_that_cannot_reach_its_tools() {
  local fakebin home log out
  fakebin="$TMP_ROOT/keeperreport-bin"
  home="$TMP_ROOT/keeperreport-home"
  log="$TMP_ROOT/keeperreport-tmux.log"
  mkdir -p "$home/state" "$home/config"
  make_fake_tmux_keeper "$fakebin"
  : > "$log"
  FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeperreport.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeperreport.path" \
    FM_POLL=1 FM_WATCH_STOP_TIMEOUT=3 FM_ARM_CONFIRM_TIMEOUT=5 "$SERVICE" ensure \
    || fail "tmux keeper fallback did not establish a healthy watcher"
  # A keeper launched before this fix, or by a session with poor reach, is
  # running on a PATH that resolves nothing.
  printf '%s\n' /nonexistent-keeper-path > "$home/state/.watch.lock/service-path"
  out=$(FM_HOME="$home" FM_WATCH_SERVICE_FORCE_BACKEND=keeper FM_WATCH_TMUX="$fakebin/tmux" \
    FM_TEST_TMUX_LOG="$log" FM_TEST_KEEPER_PID_FILE="$TMP_ROOT/keeperreport.pid" \
    FM_TEST_KEEPER_PATH_FILE="$TMP_ROOT/keeperreport.path" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$SERVICE" bootstrap)
  assert_contains "$out" "cannot reach" "a keeper-backed home running blind reported nothing at startup"
  assert_contains "$out" "crew state will read as unavailable" "the keeper report did not say what the unreachable tools cost"
  pass "a keeper whose recorded PATH cannot reach its tools reports it, like the systemd tier"
}

test_unusable_systemd_selects_tmux_keeper
test_missing_systemd_unit_requires_separate_consent
test_keeper_fallback_establishes_real_watcher
test_installed_unit_converges_source_and_x_mode
test_service_env_records_a_reaching_path_and_reports_one_that_does_not
test_a_required_tool_this_session_cannot_resolve_is_still_reported
test_service_path_keeps_every_directory_the_unit_inherited
test_keeper_reconverges_when_the_resolved_path_moves
test_keeper_reports_a_recorded_path_that_cannot_reach_its_tools
