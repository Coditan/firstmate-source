#!/usr/bin/env bash
# Opt-in real systemd --user smoke for the external watcher and the external
# wake-delivery listener: both are units, and this proves systemd restarts each.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SYSTEMD_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SYSTEMD_LIVE=1 for the transient real-systemd watcher smoke"
  exit 0
fi

systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "skip: systemd --user is unavailable"; exit 0; }

fm_test_tmproot TMP_ROOT fm-watcher-systemd-live
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config"
printf 'FM_CHECK_INTERVAL=999999\n' > "$HOME_DIR/config/x-mode.env"
WATCH="$ROOT/bin/fm-watch.sh"
DELIVERY="$ROOT/bin/fm-delivery.sh"
VERSION=$(sha256sum "$WATCH" | awk '{print "sha256:" $1}')
# Deliberately NOT the tracked template's own instance names. A machine with
# firstmate installed already has fm-watch@.service and fm-delivery@.service
# fragments in its user unit directory, and systemd-run refuses a transient unit
# whose name a fragment already claims - which made this smoke unrunnable on
# exactly the machines that run firstmate. The unit NAME is incidental here:
# what is under test is that a systemd user unit with Restart=always keeps these
# two processes alive, and the health predicates never read a unit name.
INSTANCE=$(systemd-escape --path "$HOME_DIR")
UNIT="fm-watch-smoke-${INSTANCE}.service"
DELIVERY_UNIT="fm-delivery-smoke-${INSTANCE}.service"

cleanup() {
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl --user stop "$DELIVERY_UNIT" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$DELIVERY_UNIT" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

systemd-run --user --unit "$UNIT" --collect \
  --property=Restart=always --property=RestartSec=1 \
  --property="EnvironmentFile=$HOME_DIR/config/x-mode.env" \
  --setenv="FM_HOME=$HOME_DIR" --setenv="FM_ROOT_OVERRIDE=$ROOT" \
  --setenv="FM_STATE_OVERRIDE=$STATE" --setenv=FM_WATCH_DAEMON=1 \
  --setenv=FM_WATCH_MANAGER=systemd --setenv="FM_WATCH_SOURCE_VERSION=$VERSION" \
  --setenv=FM_POLL=1 --setenv=FM_HEARTBEAT=999999 \
  /usr/bin/env bash "$WATCH" >/dev/null

# shellcheck source=bin/fm-wake-lib.sh
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-wake-lib.sh"
i=0
while ! fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR" && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR" || fail "real systemd unit did not establish the watcher health predicate"
old_pid=$FM_WATCHER_HEALTHY_PID
[ "$(cat "$STATE/.watch.lock/manager")" = systemd ] || fail "real unit did not publish manager=systemd"
systemctl --user show "$UNIT" -p EnvironmentFiles --value | grep -F "$HOME_DIR/config/x-mode.env" >/dev/null \
  || fail "real unit did not load the X-mode EnvironmentFile"

printf '%s\n' "$$" > "$STATE/.lock"

# --- the external delivery listener ------------------------------------------
# Queue a wake BEFORE any listener exists. Nothing in this test drains it, so if
# it is still there when the listener has been up and down again, the durable
# queue is proven to be the only store: a listener that kept its own copy, or
# that consumed the record itself, would fail here.
# shellcheck source=bin/fm-delivery-lib.sh
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-delivery-lib.sh"
fm_wake_append signal smoke "signal: systemd smoke"
[ "$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')" -eq 1 ] || fail "the queued wake was not recorded"

# With no listener running, the verdict must SAY the listener is down rather than
# report the healthy-looking silence of a home with nothing to deliver.
verdict=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DELIVERY_GRACE=5 \
  "$DELIVERY" --report || true)
case "$verdict" in
  down:*) : ;;
  *) fail "with no listener running the verdict must be 'down', got: $verdict" ;;
esac

DELIVERY_VERSION=$(sha256sum "$DELIVERY" | awk '{print "sha256:" $1}')
systemd-run --user --unit "$DELIVERY_UNIT" --collect \
  --property=Restart=always --property=RestartSec=1 \
  --setenv="FM_HOME=$HOME_DIR" --setenv="FM_ROOT_OVERRIDE=$ROOT" \
  --setenv="FM_STATE_OVERRIDE=$STATE" --setenv=FM_DELIVERY_DAEMON=1 \
  --setenv=FM_DELIVERY_MANAGER=systemd --setenv="FM_DELIVERY_SOURCE_VERSION=$DELIVERY_VERSION" \
  --setenv=FM_DELIVERY_POLL=0.2 --setenv=FM_DELIVERY_GRACE=5 \
  /usr/bin/env bash "$DELIVERY" >/dev/null

i=0
while ! fm_delivery_healthy "$STATE" "$DELIVERY" 5 "$HOME_DIR" && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
fm_delivery_healthy "$STATE" "$DELIVERY" 5 "$HOME_DIR" \
  || fail "the real systemd delivery unit did not establish the listener health predicate"
old_delivery_pid=$FM_DELIVERY_HEALTHY_PID
[ "$(cat "$STATE/.delivery.lock/manager")" = systemd ] || fail "the listener did not publish manager=systemd"

# The wake queued while nothing was listening is still pending, and the verdict
# now names the reason it cannot be delivered rather than falling silent: this
# home published no endpoint.
verdict=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DELIVERY_GRACE=5 \
  "$DELIVERY" --report || true)
case "$verdict" in
  undeliverable:*"no session has published where the model turn lives"*) : ;;
  *) fail "a listener with no published endpoint must say so, got: $verdict" ;;
esac
[ "$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')" -eq 1 ] \
  || fail "the listener touched the durable queue"

# Killing the listener must be recovered by systemd, exactly as for the watcher.
kill -TERM "$old_delivery_pid"
i=0
new_delivery_pid=$old_delivery_pid
while [ "$new_delivery_pid" = "$old_delivery_pid" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  if fm_delivery_healthy "$STATE" "$DELIVERY" 5 "$HOME_DIR"; then
    new_delivery_pid=$FM_DELIVERY_HEALTHY_PID
  fi
  i=$((i + 1))
done
[ "$new_delivery_pid" != "$old_delivery_pid" ] \
  || fail "systemd Restart=always did not replace the terminated delivery listener"
systemctl --user is-active --quiet "$DELIVERY_UNIT" \
  || fail "the transient delivery unit is not active after the listener restart"
[ "$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')" -eq 1 ] \
  || fail "the wake was lost or duplicated across the listener restart"

kill -TERM "$old_pid"
i=0
new_pid=$old_pid
while [ "$new_pid" = "$old_pid" ] && [ "$i" -lt 160 ]; do
  sleep 0.05
  if fm_watcher_healthy "$STATE" "$WATCH" 5 "$HOME_DIR"; then
    new_pid=$FM_WATCHER_HEALTHY_PID
  fi
  i=$((i + 1))
done
[ "$new_pid" != "$old_pid" ] || fail "systemd Restart=always did not replace the terminated daemon"
systemctl --user is-active --quiet "$UNIT" || fail "transient watcher unit is not active after daemon restart"

pass "real systemd user units keep both the watcher and the delivery listener external, restart each after a kill, and lose no queued wake"
