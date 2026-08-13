#!/usr/bin/env bash
# Behavior tests for the external wake-delivery listener (docs/wake-delivery.md):
# the outside-visible verdicts, the endpoint record, the retry-until-drained
# submit loop, the away-mode stand-down, and a real tmux end-to-end injection.
#
# The verdict tests are deliberately shaped as known-bad inputs. A listener that
# is not running and a listener with nothing to deliver both produce silence, so
# the only thing that makes the difference observable is a verdict that names it.
# Each bad condition below is created on purpose and the matching verdict is
# required back; asserting only the healthy path would let the whole
# distinguishability property rot without a single test failing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVERY="$ROOT/bin/fm-delivery.sh"
SERVICE="$ROOT/bin/fm-delivery-service.sh"
fm_test_tmproot TMP_ROOT fm-delivery

# Listener pids are recorded in files rather than a shell array: every listener
# is started inside a command substitution, so an array assignment there would be
# made in a subshell and thrown away, leaving cleanup with nothing to kill.
cleanup_listeners() {
  local file pid
  for file in "$TMP_ROOT"/*/listener.pid; do
    [ -e "$file" ] || continue
    pid=$(cat "$file" 2>/dev/null || true)
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$file"
  done
}
trap 'cleanup_listeners; fm_test_cleanup' EXIT

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

report() {  # <home> -> prints the one-line verdict
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$ROOT" FM_DELIVERY_GRACE=5 \
    "$DELIVERY" --report 2>&1 || true
}

start_listener() {  # <home> [extra env assignments...] -> prints pid
  local home=$1
  shift
  # env, not a bare assignment prefix: a NAME=VALUE that arrives through "$@" is
  # expanded after bash has already decided which words are assignments, so it
  # would be run as the command instead of setting anything.
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DELIVERY_GRACE=5 FM_DELIVERY_POLL=0.1 "$@" "$DELIVERY" >"$home/listener.out" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$home/listener.pid"
  local i=0
  while [ ! -e "$home/state/.delivery.lock/pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$home/state/.delivery.lock/pid" ] || fail "the listener did not publish its identity lock"
  printf '%s\n' "$pid"
}

# A listener started inside a command substitution is not this shell's child, so
# `wait` returns immediately and a verdict read straight after a kill can still
# see the dying process. Poll for the process to actually be gone instead.
stop_listener() {  # <pid>
  local pid=$1 i=0
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "the listener did not exit after SIGTERM"
  return 0
}

queue_wake() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal probe "signal: probe"' _ "$ROOT" \
    || fail "could not queue a wake"
}

publish_endpoint() {  # <home> <backend> <target>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_endpoint_write "$2" "$3" "$4" claude "$5"' \
    _ "$ROOT" "$1/state" "$2" "$3" "$(cat "$1/state/.lock")" \
    || fail "could not publish the endpoint"
}

# --- the six verdicts -------------------------------------------------------

test_every_not_delivering_state_names_itself() {
  local home out pid
  home=$(make_home verdicts)

  out=$(report "$home")
  case "$out" in
    down:*"no live identity-matched delivery listener"*) ;;
    *) fail "a home with no listener at all must report down, got: $out" ;;
  esac

  pid=$(start_listener "$home")
  out=$(report "$home")
  case "$out" in
    idle:*"durable queue is empty"*) ;;
    *) fail "a listening home with an empty queue must report idle, got: $out" ;;
  esac

  queue_wake "$home"
  out=$(report "$home")
  case "$out" in
    undeliverable:*"no session has published where the model turn lives"*) ;;
    *) fail "pending wakes with no endpoint must name the missing endpoint, got: $out" ;;
  esac

  printf 'garbage with no fields\n' > "$home/state/.primary-endpoint"
  out=$(report "$home")
  case "$out" in
    undeliverable:*"no usable address"*) ;;
    *) fail "a malformed endpoint must be named as malformed, got: $out" ;;
  esac

  publish_endpoint "$home" tmux '%99'
  printf '999999\n' > "$home/state/.lock"
  out=$(report "$home")
  case "$out" in
    undeliverable:*"no longer holds the fleet lock"*) ;;
    *) fail "an endpoint from an exited session must be named as stale, got: $out" ;;
  esac

  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(report "$home")
  case "$out" in
    delivering:*"tmux pane %99"*) ;;
    *) fail "a listening home with a usable endpoint must report delivering, got: $out" ;;
  esac

  touch "$home/state/.afk"
  out=$(report "$home")
  case "$out" in
    away:*"away mode owns delivery"*) ;;
    *) fail "away mode must be named rather than looking idle, got: $out" ;;
  esac
  rm -f "$home/state/.afk"

  stop_listener "$pid"
  out=$(report "$home")
  case "$out" in
    down:*) ;;
    *) fail "a killed listener must report down, got: $out" ;;
  esac
  pass "every non-delivering state names its own cause instead of falling silent"
}

test_a_live_listener_with_a_dead_beacon_is_stalled_not_down() {
  local home out holder identity
  home=$(make_home stalled)
  # Built by hand rather than by backdating a running listener's beacon: the
  # listener touches its beacon at the top of every cycle, so a real one would
  # undo the backdate within a poll. The state under test is a process that is
  # alive and identity-matched but has stopped beating - what a frozen host
  # leaves behind - and that has to be told apart from a death, because a
  # suspended machine must not be reported as a dead listener.
  sleep 60 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$holder")
  mkdir -p "$home/state/.delivery.lock"
  printf '%s\n' "$holder" > "$home/state/.delivery.lock/pid"
  printf '%s\n' "$home" > "$home/state/.delivery.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-delivery.sh" > "$home/state/.delivery.lock/delivery-path"
  printf '%s\n' "$identity" > "$home/state/.delivery.lock/pid-identity"
  touch -t 200001010000 "$home/state/.last-delivery-beat"

  out=$(report "$home")
  case "$out" in
    stalled:*"is alive but its beacon"*) ;;
    *) fail "a live listener with an aged beacon must report stalled, got: $out" ;;
  esac

  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(report "$home")
  case "$out" in
    down:*) ;;
    *) fail "once that process is gone the same state must report down, got: $out" ;;
  esac
  pass "a live listener with an aged beacon is stalled, and only a gone process is down"
}

# --- the durable queue stays the only store ---------------------------------

test_the_listener_never_touches_the_durable_queue() {
  local home pid before
  home=$(make_home queue-untouched)
  queue_wake "$home"
  queue_wake "$home"
  before=$(cat "$home/state/.wake-queue")
  publish_endpoint "$home" tmux '%99'
  pid=$(start_listener "$home")
  sleep 1
  [ "$(cat "$home/state/.wake-queue")" = "$before" ] \
    || fail "the listener modified the durable wake queue"
  stop_listener "$pid"
  [ "$(cat "$home/state/.wake-queue")" = "$before" ] \
    || fail "the listener modified the durable wake queue on the way out"
  # No second store: nothing under state/ may hold a copy of a queue record.
  if grep -rlF 'signal: probe' "$home/state" 2>/dev/null | grep -v '\.wake-queue$' | grep -v 'journal/' | grep -q .; then
    fail "a queue record was copied outside the durable queue: $(grep -rlF 'signal: probe' "$home/state" | tr '\n' ' ')"
  fi
  pass "the listener observes the durable queue and keeps no copy of it"
}

test_a_wake_queued_with_no_listener_is_delivered_once_one_returns() {
  local home pid out
  home=$(make_home queued-while-down)
  queue_wake "$home"
  publish_endpoint "$home" tmux '%99'
  out=$(report "$home")
  case "$out" in down:*) ;; *) fail "expected a down verdict before the listener starts, got: $out" ;; esac
  pid=$(start_listener "$home")
  out=$(report "$home")
  case "$out" in
    delivering:*) ;;
    *) fail "a wake queued while nothing was listening must be picked up when a listener returns, got: $out" ;;
  esac
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "the wake queued while nothing listened was lost"
  stop_listener "$pid"
  pass "a wake queued while nothing is listening survives until a listener returns"
}

test_a_session_exit_and_restart_loses_no_wake() {
  local home pid out
  home=$(make_home session-restart)
  pid=$(start_listener "$home")
  publish_endpoint "$home" tmux '%99'
  queue_wake "$home"
  case "$(report "$home")" in delivering:*) ;; *) fail "the first session should be deliverable: $(report "$home")" ;; esac

  # The session exits: its lock record is gone and the endpoint it published now
  # names a pane that is nobody's. The listener must say so rather than type into
  # it, and must not touch the pending wake.
  rm -f "$home/state/.lock"
  out=$(report "$home")
  case "$out" in
    undeliverable:*"no longer holds the fleet lock"*) ;;
    *) fail "after the session exits the stale endpoint must be named: $out" ;;
  esac

  # A new session starts, takes the lock, and publishes its own endpoint.
  printf '%s\n' "$$" > "$home/state/.lock"
  publish_endpoint "$home" tmux '%100'
  out=$(report "$home")
  case "$out" in
    delivering:*"tmux pane %100"*) ;;
    *) fail "the restarted session should be deliverable at its own pane: $out" ;;
  esac
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "the wake did not survive the session exit and restart"
  stop_listener "$pid"
  pass "a wake pending across a session exit and restart is neither lost nor delivered to a dead pane"
}

# --- away mode ---------------------------------------------------------------

test_away_mode_stands_the_listener_down_without_killing_it() {
  local home pid out
  home=$(make_home away)
  touch "$home/state/.afk"
  queue_wake "$home"
  publish_endpoint "$home" tmux '%99'
  pid=$(start_listener "$home")
  sleep 0.5
  out=$(report "$home")
  case "$out" in away:*) ;; *) fail "away mode must stand the listener down, got: $out" ;; esac
  grep -qF 'standing down' "$home/state/.delivery.log" \
    || fail "the listener did not record standing down for away mode"
  grep -qF 'delivered:' "$home/state/.delivery.log" \
    && fail "the listener submitted while away mode owned delivery"
  # Standing down must still read as up from outside: a listener that went quiet
  # for away mode and a listener that died must not look the same.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_healthy "$2" "$1/bin/fm-delivery.sh" 5 "$3"' \
    _ "$ROOT" "$home/state" "$home" \
    || fail "a listener standing down for away mode must still read as healthy"
  stop_listener "$pid"
  pass "away mode stands the listener down while it stays visibly up"
}

# --- refusing an unsafe target ----------------------------------------------

test_an_unsupported_backend_is_named_rather_than_guessed() {
  local home pid
  home=$(make_home unsupported-backend)
  queue_wake "$home"
  publish_endpoint "$home" zellij 'sess:0'
  pid=$(start_listener "$home")
  sleep 0.5
  grep -qF "no verified composer primitives for" "$home/state/.delivery.log" \
    || fail "an unsupported backend must be refused by name: $(cat "$home/state/.delivery.log")"
  stop_listener "$pid"
  pass "an endpoint naming an unverified backend is refused by name, not typed into"
}

# --- a real tmux end to end --------------------------------------------------
# The only proof that delivery actually delivers is a real pane receiving the
# real message. A fake backend would prove the loop's bookkeeping and nothing
# about the submit, which is the half that touches the captain's terminal.

test_real_tmux_delivery_reaches_the_composer() {
  local home socket session pid i pane
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not installed"; return 0; }
  home=$(make_home real-tmux)
  socket="fm-delivery-test-$$"
  session=fm-delivery-probe

  # A stand-in agent: it draws the agent composer glyph the shared classifier
  # accepts as a genuine empty composer, then reads one line and records it.
  # That is exactly the contract a real agent pane offers the listener - an
  # empty composer to type into and a submit that starts a turn.
  cat > "$home/agent.sh" <<'SH'
#!/usr/bin/env bash
printf '\xe2\x9d\xaf '
IFS= read -r line
printf '%s' "$line" > "$1"
printf '\nRECEIVED\n'
sleep 300
SH
  chmod +x "$home/agent.sh"
  tmux -L "$socket" new-session -d -s "$session" "$home/agent.sh" "$home/received.txt"
  # shellcheck disable=SC2064 # Expand the socket name now, at trap-set time.
  trap "tmux -L '$socket' kill-server 2>/dev/null || true; cleanup_listeners; fm_test_cleanup" EXIT
  sleep 0.5

  # The listener resolves tmux through PATH, so a shim pinned to this test's
  # private socket keeps the probe off the machine's real tmux server. That is
  # not a test-only convenience: this repo runs its own fleet inside tmux, and a
  # probe on the default socket would be creating and killing sessions next to
  # live crew.
  mkdir -p "$home/bin"
  cat > "$home/bin/tmux" <<SH
#!/usr/bin/env bash
exec $(command -v tmux) -L '$socket' "\$@"
SH
  chmod +x "$home/bin/tmux"

  publish_endpoint "$home" tmux "$session"
  queue_wake "$home"
  pid=$(start_listener "$home" PATH="$home/bin:$PATH")

  i=0
  while [ ! -s "$home/received.txt" ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  stop_listener "$pid"
  if [ ! -s "$home/received.txt" ]; then
    pane=$(tmux -L "$socket" capture-pane -p -t "$session" 2>/dev/null || true)
    tmux -L "$socket" kill-server 2>/dev/null || true
    fail "the listener did not submit into the real tmux composer; pane was: $pane; log: $(cat "$home/state/.delivery.log")"
  fi
  grep -qF 'FIRSTMATE_OP: v1 watcher: ' "$home/received.txt" \
    || fail "the delivered message was not the canonical typed watcher input: $(cat "$home/received.txt")"
  grep -qF 'bin/fm-wake-drain.sh' "$home/received.txt" \
    || fail "the delivered message did not tell the seat to drain: $(cat "$home/received.txt")"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "delivery consumed the durable queue record instead of leaving it for the drain"
  tmux -L "$socket" kill-server 2>/dev/null || true
  pass "the listener submits the canonical typed wake into a real tmux agent composer"
}

# --- the reaper has nothing left to kill --------------------------------------
# The failure class this design removes is "the session holds a killable
# object". The harness reaper's own precondition (a ~30-minute idle terminal
# plus a host memory-pressure event) cannot be produced on demand in a test, and
# reasoning about it is exactly what the brief forbids - so this proves the
# stronger property instead: the reaper can only destroy objects the session
# holds, and after the session is destroyed AS COMPLETELY AS A REAPER EVER
# COULD - the whole process group killed outright, with the reaper switch
# deliberately enabled in that environment - delivery is unaffected, because it
# was never in that group.
test_destroying_the_whole_session_process_group_leaves_delivery_running() {
  local home pid session_pid pgid i
  home=$(make_home reaper-class)
  publish_endpoint "$home" tmux '%99'

  # The listener is started with setsid, the way a service manager starts it:
  # its own process group and session, unreachable from the harness's.
  command -v setsid >/dev/null 2>&1 || { echo "skip: setsid not available"; return 0; }
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DELIVERY_GRACE=5 FM_DELIVERY_POLL=0.1 \
    setsid "$DELIVERY" >"$home/listener.out" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$home/listener.pid"
  i=0
  while [ ! -e "$home/state/.delivery.lock/pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$home/state/.delivery.lock/pid" ] || fail "the setsid listener did not publish its identity lock"
  pid=$(cat "$home/state/.delivery.lock/pid")

  # A stand-in session with the reaper deliberately ENABLED in its environment
  # (the switch that disables it is explicitly empty here) and background jobs of
  # its own - the class of object the reaper kills.
  cat > "$home/session.sh" <<'SH'
#!/usr/bin/env bash
sleep 300 &
sleep 300 &
printf '%s
' "$$" > "$1"
sleep 300
SH
  chmod +x "$home/session.sh"
  # Launched inside a subshell so this shell never adopts it as a job: a killed
  # job prints a "Killed" notice that would read like a test failure.
  ( env CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP= setsid "$home/session.sh" "$home/session.pid" & )
  i=0
  while [ ! -s "$home/session.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$home/session.pid" ] || fail "the stand-in session did not start"
  session_pid=$(cat "$home/session.pid")
  pgid=$(ps -o pgid= -p "$session_pid" | tr -d ' ')
  [ -n "$pgid" ] || fail "could not read the stand-in session process group"
  [ "$pgid" != "$(ps -o pgid= -p "$pid" | tr -d ' ')" ] \
    || fail "the listener shares the session process group, so it is still a session-held object"

  # Kill the session's entire group: everything a reaper could reach, and more.
  kill -KILL -- "-$pgid" 2>/dev/null || true
  i=0
  while kill -0 "$session_pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$session_pid" 2>/dev/null && fail "the stand-in session survived its own group kill"

  kill -0 "$pid" 2>/dev/null || fail "destroying the session process group also destroyed delivery"
  queue_wake "$home"
  sleep 0.5
  case "$(report "$home")" in
    delivering:*) ;;
    *) fail "delivery did not keep working after the session process group was destroyed: $(report "$home")" ;;
  esac
  stop_listener "$pid"
  pass "the whole session process group can be destroyed with the reaper enabled and delivery is unaffected"
}

# --- the service manager ------------------------------------------------------

test_service_status_and_repair_command_are_answerable_without_systemd() {
  local home out
  home=$(make_home service)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$SERVICE" status 2>&1 || true)
  case "$out" in
    down:*) ;;
    *) fail "the service status subcommand must answer with a verdict, got: $out" ;;
  esac
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DELIVERY_SERVICE_FORCE_BACKEND=keeper "$SERVICE" repair-command 2>&1)
  assert_contains "$out" "fm-delivery-service.sh restart" "the keeper-tier repair command is not runnable as printed"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DELIVERY_SERVICE_FORCE_BACKEND=keeper "$SERVICE" select 2>&1)
  [ "$out" = keeper ] || fail "forced keeper selection returned $out"
  pass "the delivery service answers status, selection, and repair without needing systemd"
}

test_publish_endpoint_refuses_rather_than_guessing() {
  local home out rc=0
  home=$(make_home publish-refusal)
  # No pane in the environment at all: publishing an address nobody verified is
  # worse than reporting that there is none, because the listener would then type
  # into whatever that address happens to name.
  out=$(env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
    -u FM_SUPERVISOR_BACKEND \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$SERVICE" publish-endpoint 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "publishing succeeded with no pane to publish"
  assert_contains "$out" "DELIVERY_ENDPOINT:" "the refusal did not carry its diagnostic label"
  [ ! -e "$home/state/.primary-endpoint" ] || fail "a refused publish still wrote an endpoint record"

  rm -f "$home/state/.lock"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    TMUX_PANE='%7' "$SERVICE" publish-endpoint 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "publishing succeeded with no session lock to name"
  assert_contains "$out" "no fleet lock is recorded" "the lockless refusal did not name its reason"
  pass "publishing an endpoint refuses a guessed pane and a nameless session"
}

test_publish_endpoint_records_the_session_that_published_it() {
  local home
  home=$(make_home publish-ok)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    TMUX_PANE='%7' "$SERVICE" publish-endpoint >/dev/null \
    || fail "publishing from a pane with a live lock failed"
  grep -qx 'backend=tmux' "$home/state/.primary-endpoint" || fail "the published record lost its backend"
  grep -qx 'target=%7' "$home/state/.primary-endpoint" || fail "the published record lost its target"
  grep -qx "session-lock-pid=$$" "$home/state/.primary-endpoint" \
    || fail "the published record did not name the publishing session"
  pass "a published endpoint records its backend, target, and owning session"
}

test_every_not_delivering_state_names_itself
test_a_live_listener_with_a_dead_beacon_is_stalled_not_down
test_the_listener_never_touches_the_durable_queue
test_a_wake_queued_with_no_listener_is_delivered_once_one_returns
test_a_session_exit_and_restart_loses_no_wake
test_away_mode_stands_the_listener_down_without_killing_it
test_an_unsupported_backend_is_named_rather_than_guessed
test_real_tmux_delivery_reaches_the_composer
test_destroying_the_whole_session_process_group_leaves_delivery_running
test_service_status_and_repair_command_are_answerable_without_systemd
test_publish_endpoint_refuses_rather_than_guessing
test_publish_endpoint_records_the_session_that_published_it
