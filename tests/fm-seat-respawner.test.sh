#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This is the suite that drives the restart service itself - its converge and
# --armed readings - so the suite-wide silencer tests/lib.sh sets for every
# other fixture home is lifted here.
export FM_SEAT_RESPAWNER_DISABLE=0

RESPAWNER="$ROOT/bin/fm-seat-respawner.sh"
STAY_DOWN="$ROOT/bin/fm-seat-stay-down.sh"
SERVICE="$ROOT/bin/fm-seat-respawner-service.sh"

fm_test_tmproot TMP_ROOT fm-seat-respawner

PIDNS=$(. "$ROOT/bin/fm-harness-pid-lib.sh"; fm_pid_namespace_token)

# A process whose name and command line look exactly like a harness, so the
# lock this component reads names something a liveness test accepts.
start_harness_shaped_process() {  # <home>
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$1/claude"
  chmod +x "$1/claude"
  "$1/claude" >/dev/null 2>&1 </dev/null &
  printf '%s\n' "$!"
}

record_seat() {  # <home> <pid>
  printf '%s\npidns=%s\n' "$2" "$PIDNS" > "$1/state/.lock"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data/findings"
  printf 'printf respawned\n' > "$home/config/seat-launch-command"
  {
    printf 'backend=tmux\n'
    printf 'target=%%9\n'
    printf 'harness=claude\n'
    printf 'session-lock-pid=999999\n'
    printf 'tmux-server=%s,%s\n' "$home/tmux.sock" "$$"
  } > "$home/state/.primary-endpoint"
  printf '%s\n' "$home"
}

write_fake_delivery() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  cat "$FM_FAKE_DELIVERY_STATUS"
  exit 0
fi
exit 2
SH
  chmod +x "$path"
}

write_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$path"
}

# A fake tmux that answers `new-window -P -F '#{pane_id}'` the way tmux does,
# so the launch records the pending first turn a real one would.
write_pane_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
for arg do
  if [ "\$arg" = new-window ]; then
    printf '%%9\n'
    break
  fi
done
exit 0
SH
  chmod +x "$path"
}

write_executing_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
last=
for arg do
  last=\$arg
done
printf '%s\n' "\$*" >> "$log"
env -i PATH=/usr/bin:/bin /bin/sh -c "\$last"
SH
  chmod +x "$path"
}

run_respawner_once() {
  local home=$1 delivery=$2 tmux=$3
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_FINDINGS_DIR="$home/data/findings" \
  FM_SEAT_DELIVERY_SERVICE="$delivery" \
  FM_SEAT_TMUX="$tmux" \
  FM_SEAT_RESPAWNER_ONCE=1 \
  FM_SEAT_RESPAWNER_BACKOFF="${FM_SEAT_RESPAWNER_BACKOFF:-1}" \
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS="${FM_SEAT_RESPAWNER_MAX_ATTEMPTS:-1}" \
  FM_SEAT_REVIVE_WATCHER=0 \
    "$RESPAWNER"
}

test_stay_down_marker_is_authoritative() {
  local home delivery tmux log status
  home=$(make_home stay-down)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$STAY_DOWN" down "test stay down" >/dev/null
  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused to run with a stay-down marker"

  [ ! -e "$log" ] || fail "stay-down marker did not suppress tmux launch"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "stay-down marker left an active retry episode"
  pass "seat respawner honors the declared stay-down marker"
}

test_giveup_path_reports_a_finding() {
  local home delivery tmux log status findings launch_count
  home=$(make_home giveup)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but the endpoint was published by a session that no longer holds the fleet lock\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"

  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  [ -e "$log" ] || fail "first unreachable check did not attempt a launch"
  printf 'undeliverable: listener pid 1 is up with 2 wake(s) pending, but the endpoint was published by a session that no longer holds the fleet lock\n' > "$status"
  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up check"

  launch_count=$(wc -l < "$log" | tr -d ' ')
  [ "$launch_count" = 1 ] || fail "changed wake count reset the retry bound; got $launch_count launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] || fail "give-up path did not emit exactly one finding; got $findings"
  assert_grep "exhausted 1 launch attempt" "$home/data/findings/"*.json \
    "give-up finding did not name the exhausted attempt bound"
  [ -f "$home/state/.seat-respawn-giveup" ] || fail "give-up episode marker was not recorded"
  pass "seat respawner reports exhausted retry episodes through findings"
}

# The launcher used to export its own PATH into the fresh seat, so a respawned
# seat silently ran a different tool set from a hand-started one. Measured on
# coditan-vessel 2026-08-27: `bash -lc` reaches claude 2.1.234 and `bash -lic`
# reaches 2.1.247, because ~/.bashrc returns at its interactive guard before the
# line that adds the npm prefix. No value composed by the launcher can reproduce
# that chain, so it composes none and the launch command owns its own
# environment. This asserts the absence, because the defect was invisible - a
# pinned PATH produces a seat that runs perfectly, on the wrong binary.
test_launch_does_not_pin_the_respawners_path() {
  local home delivery tmux log status
  home=$(make_home no-path-pin)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"
  printf "bash -lic 'exec claude'\n" > "$home/config/seat-launch-command"

  PATH="$home/should-not-be-pinned:${PATH:-/usr/bin:/bin}" FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner did not complete a launch cycle"
  assert_grep "new-window" "$log" "the launch never reached tmux"
  assert_no_grep "should-not-be-pinned" "$log" \
    "the respawner pinned its own PATH into the fresh seat"
  assert_no_grep "PATH=" "$log" \
    "the respawner composed a PATH for the seat; the launch command owns its own environment"
  assert_grep "exec bash -lic" "$log" \
    "the configured launch command did not reach tmux intact"
  pass "seat respawner composes no PATH for the fresh seat"
}

test_resume_style_launch_command_is_refused() {
  local home delivery tmux log status
  home=$(make_home resume-command)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"
  printf 'codex resume --last\n' > "$home/config/seat-launch-command"

  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused to complete a cycle after rejecting resume launch"
  [ ! -e "$log" ] || fail "resume-style launch command reached tmux"
  assert_grep "resume-style config/seat-launch-command" "$home/state/.seat-respawner.log" \
    "resume-style launch rejection was not operator-visible"
  pass "seat respawner refuses resume-style launch commands"
}

# One launch per unattended home at a time. The delivery verdict stays
# undeliverable until the fresh seat finishes session start and publishes an
# endpoint, which outlasts the first backoff, so a respawner that kept launching
# on schedule would leave live agent processes in windows nothing tracks - up to
# one per retry. The pending first-turn record is what it waits on.
test_a_pending_first_turn_holds_the_next_launch() {
  local home delivery tmux log status launches
  home=$(make_home first-turn-hold)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] || fail "the first cycle did not launch exactly one seat; got $launches"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the launch recorded no pending first turn, so there is nothing to hold on"

  # Past the retry backoff, so the next launch is due on schedule and only the
  # pending first turn can be what holds it.
  sleep 2
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the second unreachable check"

  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a second seat was launched while the first had not taken the lock; got $launches"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the pending first turn was dropped while its pane could not be read"
  assert_grep "held: the seat already started for this episode" "$home/state/.seat-respawner.log" \
    "holding the next launch was not operator-visible"
  pass "seat respawner waits out the seat it already started before starting another"
}

# THE BOUND, AND WHAT THE GIVE-UP MAY CLAIM WHEN IT IS REACHED.
#
# The captain ruled twice on this episode. First that the launch hold must still
# be bounded by the existing attempt limit, because a hold that never ends is a
# home nobody is coming back to and nothing ever says so. Then that the finding
# which ends it may not call a held cycle a launch: an episode whose first turn
# never lands makes ONE window call, and telling him five launches were spent
# would be the same overclaim this branch refuses everywhere else.
#
# So both halves are asserted here together, because either one alone is wrong.
# The bound without the honest count reports five launches that never happened;
# the honest count without the bound reports nothing at all, forever.
#
# It also asserts the one fact he can act on and the finding used not to carry:
# that a pane is still open holding this episode, so the silence is a deliberate
# refusal to open a second seat beside a live one, not a restarter that quit.
test_a_held_episode_is_bounded_and_the_giveup_counts_launches_as_launches() {
  local home delivery tmux log status launches findings i
  home=$(make_home held-bound)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  # Four cycles at a three-attempt bound: one launch, then holds. Each later
  # cycle sleeps past the backoff so nothing but the pending first turn can be
  # what holds it.
  i=0
  while [ "$i" -lt 4 ]; do
    [ "$i" -eq 0 ] || sleep 2
    FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
      run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
  done

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the pending first turn was dropped, so no cycle was actually held"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a held episode opened more than one seat; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "a held episode never reached its bound; got $findings give-up findings"
  assert_no_grep "exhausted 3 launch attempt" "$home/data/findings/"*.json \
    "the give-up finding claimed launches that were holds"
  assert_grep "1 launch attempt" "$home/data/findings/"*.json \
    "the give-up finding did not name the one launch that was actually made"
  assert_grep "%9" "$home/data/findings/"*.json \
    "the give-up finding did not name the pane still holding this episode"
  pass "a held episode is bounded and its give-up counts launches as launches"
}

# The verdict the alarm turns into a sentence on the captain's phone. A
# respawner that is beating normally while the seat it started never finished
# starting is not a recovery under way, so it may not answer `up:`.
test_a_held_first_turn_is_reported_as_holding_rather_than_up() {
  local home out beat
  home=$(make_home holding-status)
  beat="$home/state/.last-seat-respawner-beat"

  run_status() {
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      "$SERVICE" status
  }

  # A respawner cycling normally: its own lock, this home, a live pid, a fresh
  # beacon. Nothing held yet.
  mkdir -p "$home/state/.seat-respawner.lock"
  {
    printf 'pid=%s\n' "$$"
    printf 'fm-home=%s\n' "$home"
  } > "$home/state/.seat-respawner.lock/record"
  : > "$beat"
  out=$(run_status)
  case "$out" in
    up:*) : ;;
    *) fail "a healthy respawner with nothing held did not answer up: $out" ;;
  esac

  # Now it is holding a first turn it typed into a pane that never took the lock.
  {
    printf 'pane=%%9\n'
    printf 'at=%s\n' "$(date +%s)"
    printf 'submitted=%s\n' "$(date +%s)"
    printf 'held=%s\n' "$(date +%s)"
  } > "$home/state/.seat-first-turn"
  out=$(run_status)
  case "$out" in
    holding:*) : ;;
    *) fail "a respawner holding a seat that never started did not answer holding: $out" ;;
  esac
  assert_contains "$out" "has not finished starting" \
    "the holding verdict did not say what it is waiting on"
  pass "a respawner holding a seat that never finished starting answers holding rather than up"
}

# The state this whole area exists to remove is a restarter that is in the tree
# and has never once run, so an armed home with no beacon at all must be the
# loudest case rather than the one that stays silent.
test_an_armed_restart_that_never_ran_is_reported() {
  local home out
  home=$(make_home never-ran)

  run_service() {  # <now> <arg...>
    local now=$1; shift
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      FM_SEAT_RESPAWNER_TMUX="$(command -v sh)" FM_SEAT_RESPAWNER_NOW="$now" \
      "$SERVICE" "$@"
  }

  out=$(run_service "" --armed)
  assert_contains "$out" "nothing keeps this vessel" \
    "an unarmed home must say nothing keeps its restart running"

  run_service "" --arm >/dev/null || fail "the restart watch could not be armed"
  out=$(run_service "" --armed)
  [ -z "$out" ] || fail "a freshly armed home must not be called stopped: $out"

  out=$(run_service "$(( $(date +%s) + 7200 ))" --armed)
  assert_contains "$out" "has never run" \
    "an armed restart that never produced a beat said nothing"

  : > "$home/state/.last-seat-respawner-beat"
  out=$(run_service "$(( $(date +%s) + 7200 ))" --armed)
  assert_contains "$out" "last ran" \
    "a restart that ran and stopped was not reported"
  pass "an armed restart that never ran and one that stopped are both reported"
}

# A busy first mate produces the same `undeliverable:` verdict a missing one
# does - the delivery listener blocks the submit on a mid-turn pane - so the
# verdict alone cannot open a relaunch. The session lock is the presence
# reading, the same one bin/fm-seat-alarm.sh takes, and a home whose lock names
# a live harness is not missing a seat.
test_a_live_first_mate_is_never_relaunched() {
  local home delivery tmux log status seat launches
  home=$(make_home lock-held)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but the session pane is mid-turn\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  [ -f "$home/state/.seat-respawn-attempts" ] || fail "the first cycle opened no retry episode"

  # The seat that was there all along takes this home's lock, exactly as a busy
  # one holds it while the listener reports the pane unreachable.
  seat=$(start_harness_shaped_process "$home")
  record_seat "$home" "$seat"

  sleep 2
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused a cycle while a live first mate held the lock"
  kill "$seat" 2>/dev/null || true

  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a second seat was launched beside a live first mate; got $launches"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "a home with a live first mate kept an active retry episode"
  [ ! -e "$home/state/.seat-first-turn" ] \
    || fail "a home held by a first mate kept a pending first turn"
  assert_grep "a seat now holds this home" "$home/state/.seat-respawner.log" \
    "settling the pending first turn against a held home was not operator-visible"
  pass "seat respawner never launches beside a first mate that holds this home"
}

# The reading that could not be taken. Every earlier orphaning finding on this
# branch was a state that is not "seat present" being converted into "launch",
# and this is the last door into it: a lock this process cannot read says
# nothing about whether a first mate holds this home, so it must not open one.
test_an_unreadable_lock_never_produces_a_launch() {
  local home delivery tmux log status rc=0
  home=$(make_home unmeasured-lock)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"
  printf 'x\n' > "$home/state/.lock"
  chmod 000 "$home/state/.lock"

  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" || rc=$?
  chmod 600 "$home/state/.lock"
  [ "$rc" = 0 ] || fail "respawner refused to complete a cycle over an unreadable lock"

  [ ! -e "$log" ] \
    || fail "a lock this home could not read was treated as an absent first mate and produced a launch"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "a reading that could not be taken opened a retry episode"
  pass "seat respawner never launches on a lock it could not read"
}

# The watcher wakes firstmate on any line this check prints, so a start it did
# not confirm would announce a restoration that did not hold once per sweep -
# 288 turns a day at the default interval, each of them false.
test_converge_never_claims_a_start_it_could_not_confirm() {
  local home tmux log line
  home=$(make_home unconfirmed-start)
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  write_fake_tmux "$tmux" "$log"

  converge_once() {
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      FM_SEAT_RESPAWNER_TMUX="$tmux" FM_SEAT_RESPAWNER_CONFIRM_TIMEOUT=1 \
      "$SERVICE" converge
  }

  line=$(converge_once)
  assert_grep "new-session" "$log" "converging never tried to start a keeper"
  assert_contains "$line" "could not be started" \
    "a keeper whose respawner never came up was reported as started again"
  assert_not_contains "$line" "has been started again" \
    "converging claimed a restoration that never happened"

  # The watcher enqueues a durable wake for any line a check prints, so a
  # condition no turn can repair must be said once rather than every sweep.
  line=$(converge_once)
  [ -z "$line" ] \
    || fail "the same unclearable failure was announced again on the next sweep: $line"
  line=$(converge_once)
  [ -z "$line" ] \
    || fail "the same unclearable failure was announced again two sweeps later: $line"
  pass "converging never claims a start it could not confirm, and says a persisting failure once"
}

# A watcher service that records what it was asked to do and reports the keeper
# tier, so a revival attempt leaves a trace instead of touching a real watcher.
write_fake_watcher_service() {  # <path> <log>
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = select ]; then printf 'keeper\n'; fi
exit 0
SH
  chmod +x "$path"
}

# The record a live watcher publishes about itself: pid, home, watcher path and
# the identity that makes pid reuse a mismatch.
record_watcher() {  # <home> <pid>
  local home=$1 pid=$2 lockdir identity
  lockdir="$home/state/.watch.lock"
  mkdir -p "$lockdir"
  # Sourced through `env` with this fixture's overrides, because
  # bin/fm-wake-lib.sh creates a state directory as a side effect of being
  # sourced and must never be allowed to create this repo's own.
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  identity=$(env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$pid")
  printf '%s\n' "$pid" > "$lockdir/pid"
  printf '%s\n' "$home" > "$lockdir/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$lockdir/watcher-path"
  printf '%s\n' "$identity" > "$lockdir/pid-identity"
}

watcher_health() {  # <home>
  local home=$1
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
    '. "$1/bin/fm-wake-lib.sh"
     fm_watcher_healthy "$2/state" "$1/bin/fm-watch.sh" 300 "$2" || true
     printf "%s\n" "$FM_WATCHER_HEALTH"' _ "$ROOT" "$home"
}

# A watcher that is ALIVE but whose beacon has aged out is not a dead watcher.
# bin/fm-wake-lib.sh classifies that as beacon-stale and names machine suspend as
# the case that necessarily produces it, so reviving on the bare unhealthy return
# stops and restarts a running watcher - and the sweep it kills mid-flight is the
# one that now carries the seat alarm itself.
test_only_a_provably_dead_watcher_is_revived() {
  local home delivery tmux svc svclog watcher health

  home=$(make_home watcher-revive)
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  svc="$home/fake-watcher-service"
  svclog="$home/watcher-service.log"
  printf 'delivered: nothing is waiting for this vessel\n' > "$home/status.txt"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$home/tmux.log"
  write_fake_watcher_service "$svc" "$svclog"

  run_revive_cycle() {
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FINDINGS_DIR="$home/data/findings" \
    FM_SEAT_DELIVERY_SERVICE="$delivery" \
    FM_FAKE_DELIVERY_STATUS="$home/status.txt" \
    FM_SEAT_TMUX="$tmux" \
    FM_SEAT_RESPAWNER_ONCE=1 \
    FM_SEAT_REVIVE_WATCHER=1 \
    FM_SEAT_WATCHER_SERVICE="$svc" \
      "$RESPAWNER" >/dev/null 2>&1 || true
  }

  # A live, identity-matched watcher that has never touched a beacon: the very
  # state a suspended host leaves behind.
  watcher=$(start_harness_shaped_process "$home")
  sleep 0.4
  record_watcher "$home" "$watcher"
  health=$(watcher_health "$home")
  [ "$health" = beacon-stale ] \
    || fail "the fixture did not produce a live watcher with an aged-out beacon: $health"

  run_revive_cycle
  assert_no_grep "ensure" "$svclog" \
    "a live watcher whose beacon had aged out was stopped and restarted"
  [ ! -e "$home/state/.seat-respawner-watcher-revived" ] \
    || fail "a live watcher whose beacon had aged out was recorded as revived"

  # The same home once the watcher is genuinely gone.
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  health=$(watcher_health "$home")
  [ "$health" = dead ] \
    || fail "the fixture did not produce a dead watcher after the kill: $health"

  run_revive_cycle
  assert_grep "ensure" "$svclog" \
    "a watcher that had actually died was never revived"
  pass "only a provably dead watcher is revived, never a live one whose beacon aged out"
}

# The watcher breaks its check sweep at the FIRST check that prints a line
# (bin/fm-watch.sh:1698-1701), so "converged on every watcher sweep" is only true
# if no sibling that speaks sorts ahead of the convergence shim. The seat alarm
# is the sibling that would, so the two ids carry the ordering. Measured through
# the watcher's own glob rather than argued from the names.
test_convergence_is_swept_before_the_alarm_and_supersedes_its_old_shim() {
  local home shims restart_at vacancy_at i legacy id c

  home=$(make_home sweep-order)

  # A home armed under the pre-rename ids, exactly as an updating vessel has it.
  for legacy in seat-alarm seat-respawner; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/$legacy.check.sh"
    chmod 0700 "$home/state/$legacy.check.sh"
    printf 'fm-custom-check-v1\ndeadbeef\n' > "$home/state/$legacy.check-trust"
  done

  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
    "$SERVICE" --arm >/dev/null || fail "the restart watch could not be armed"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-seat-alarm.sh" --arm >/dev/null || fail "the first-mate watch could not be armed"

  # A superseded shim the watcher would keep executing is the whole hazard of a
  # rename, so arming must have removed both halves of each old pair.
  for legacy in seat-alarm seat-respawner; do
    [ ! -e "$home/state/$legacy.check.sh" ] \
      || fail "arming left the superseded $legacy shim in place for the watcher to run"
    [ ! -e "$home/state/$legacy.check-trust" ] \
      || fail "arming left the superseded $legacy registration in place"
  done

  # Both replacements must satisfy the predicate the watcher itself gates on.
  for id in seat-restart seat-vacancy; do
    # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
    env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
      '. "$1/bin/fm-pr-lib.sh"
       . "$1/bin/fm-check-lib.sh"
       fm_custom_check_registered "$2/state" "$3"' _ "$ROOT" "$home" "$id" \
      || fail "$id was not left registered for the watcher to execute"
  done

  # The watcher's own enumeration: `for c in "$STATE"/*.check.sh`.
  shims=()
  for c in "$home/state"/*.check.sh; do shims+=("$(basename "$c")"); done
  restart_at=-1
  vacancy_at=-1
  for i in "${!shims[@]}"; do
    [ "${shims[$i]}" = seat-restart.check.sh ] && restart_at=$i
    [ "${shims[$i]}" = seat-vacancy.check.sh ] && vacancy_at=$i
  done
  [ "$restart_at" -ge 0 ] && [ "$vacancy_at" -ge 0 ] \
    || fail "the sweep did not yield both shims: ${shims[*]}"
  [ "$restart_at" -lt "$vacancy_at" ] \
    || fail "the alarm is swept before the convergence, so it can displace it: ${shims[*]}"
  pass "the restarter's convergence is swept before the alarm and supersedes the old shims"
}

test_stay_down_marker_is_authoritative
test_giveup_path_reports_a_finding
test_converge_never_claims_a_start_it_could_not_confirm
test_a_live_first_mate_is_never_relaunched
test_only_a_provably_dead_watcher_is_revived
test_convergence_is_swept_before_the_alarm_and_supersedes_its_old_shim
test_an_unreadable_lock_never_produces_a_launch
test_a_pending_first_turn_holds_the_next_launch
test_a_held_episode_is_bounded_and_the_giveup_counts_launches_as_launches
test_a_held_first_turn_is_reported_as_holding_rather_than_up
test_an_armed_restart_that_never_ran_is_reported
test_launch_does_not_pin_the_respawners_path
test_resume_style_launch_command_is_refused
