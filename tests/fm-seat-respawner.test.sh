#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESPAWNER="$ROOT/bin/fm-seat-respawner.sh"
STAY_DOWN="$ROOT/bin/fm-seat-stay-down.sh"

fm_test_tmproot TMP_ROOT fm-seat-respawner

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
    printf 'tmux-server=%s,1\n' "$home/tmux.sock"
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
  FM_SEAT_RESPAWNER_BACKOFF=1 \
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
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
  local home delivery tmux log status findings
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
  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up check"

  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] || fail "give-up path did not emit exactly one finding; got $findings"
  assert_grep "exhausted 1 launch attempt" "$home/data/findings/"*.json \
    "give-up finding did not name the exhausted attempt bound"
  [ -f "$home/state/.seat-respawn-giveup" ] || fail "give-up episode marker was not recorded"
  pass "seat respawner reports exhausted retry episodes through findings"
}

test_stay_down_marker_is_authoritative
test_giveup_path_reports_a_finding
