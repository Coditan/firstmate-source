#!/usr/bin/env bash
# Direct Telegram receiver systemd service consent and convergence tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-tg-recv-service.sh"
fm_test_tmproot TMP_ROOT fm-tg-recv-service

make_fake_systemd() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SYSTEMCTL_LOG:?}"
case "$*" in
  '--user show-environment'|'--user daemon-reload') exit 0 ;;
  '--user is-enabled --quiet '*) [ -e "${FM_TEST_SYSTEMD_ENABLED:?}" ] ;;
  '--user is-active --quiet '*) [ -e "${FM_TEST_SYSTEMD_ACTIVE:?}" ] ;;
  '--user enable --now '*)
    [ ! -e "${FM_TEST_RECEIVER_ACTIVE:-/nonexistent}" ] \
      || touch "${FM_TEST_RECEIVER_OVERLAP:?}"
    if [ "${FM_TEST_START_SERVICE:-0}" = 1 ]; then
      FM_TG_RECV_MANAGER=systemd FM_HOME="$FM_TEST_SERVICE_HOME" \
        "$FM_TEST_SERVICE_ARM" > "$FM_TEST_SERVICE_OUT" 2>&1 &
      printf '%s\n' "$!" > "$FM_TEST_SERVICE_PID"
    fi
    touch "$FM_TEST_SYSTEMD_ENABLED" "$FM_TEST_SYSTEMD_ACTIVE"
    ;;
  '--user restart '*)
    if [ "${FM_TEST_START_SERVICE:-0}" = 1 ]; then
      old_pid=$(cat "$FM_TEST_SERVICE_PID" 2>/dev/null || true)
      case "$old_pid" in ''|*[!0-9]*) ;; *) kill -TERM "$old_pid" 2>/dev/null || true ;; esac
      for _ in $(seq 1 50); do
        [ ! -e "$FM_TEST_RECEIVER_ACTIVE" ] && break
        sleep 0.05
      done
      FM_TG_RECV_MANAGER=systemd FM_HOME="$FM_TEST_SERVICE_HOME" \
        "$FM_TEST_SERVICE_ARM" > "$FM_TEST_SERVICE_OUT" 2>&1 &
      printf '%s\n' "$!" > "$FM_TEST_SERVICE_PID"
    fi
    touch "$FM_TEST_SYSTEMD_ACTIVE"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/systemd-escape" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --path ] || exit 1
printf '%s\n' "${2#/}" | tr '/' '-'
SH
  chmod +x "$fakebin/systemctl" "$fakebin/systemd-escape"
}

service_env() {
  local fakebin=$1 home=$2 unitdir=$3
  shift 3
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY="${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
    FM_TG_RECV_SYSTEMCTL="$fakebin/systemctl" \
    FM_TG_RECV_SYSTEMD_ESCAPE="$fakebin/systemd-escape" \
    FM_TG_RECV_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log" \
    FM_TEST_SYSTEMD_ENABLED="$TMP_ROOT/systemd.enabled" \
    FM_TEST_SYSTEMD_ACTIVE="$TMP_ROOT/systemd.active" \
    FM_TEST_RECEIVER_ACTIVE="$home/state/receiver-active" \
    FM_TEST_RECEIVER_OVERLAP="$home/state/receiver-overlap" \
    FM_TEST_START_SERVICE="${FM_TEST_START_SERVICE:-1}" \
    FM_TEST_SERVICE_HOME="$home" \
    FM_TEST_SERVICE_ARM="$ROOT/bin/fm-tg-recv-arm.sh" \
    FM_TEST_SERVICE_OUT="$home/service.out" \
    FM_TEST_SERVICE_PID="$home/state/service-wrapper-pid" \
    "$@"
}

fakebin="$TMP_ROOT/fakebin"
unitdir="$TMP_ROOT/units"
home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state" "$unitdir"
make_fake_systemd "$fakebin"
: > "$TMP_ROOT/systemctl.log"

out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
[ -z "$out" ] || fail "unconfigured home produced a Telegram receiver service diagnostic: $out"

printf 'BOT_TOKEN=fake\nCHAT_ID=fake\n' > "$home/config/telegram.env"
cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$home/config/fm-tg-recv.sh"

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
if ! mkdir "$FM_HOME/state/receiver-active" 2>/dev/null; then
  touch "$FM_HOME/state/receiver-overlap"
fi
trap 'rmdir "$FM_HOME/state/receiver-active" 2>/dev/null || true; exit 0' TERM INT
while :; do sleep 0.1; done
SH
chmod +x "$home/config/fm-tg-recv.sh"

racebin="$TMP_ROOT/racebin"
mkdir -p "$racebin"
real_ln=$(command -v ln)
cat > "$racebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "${FM_TEST_PAUSE_LOCK:?}" ]; then
  touch "${FM_TEST_PAUSE_REACHED:?}"
  while [ ! -e "${FM_TEST_PAUSE_RELEASE:?}" ]; do sleep 0.05; done
fi
exec "${FM_TEST_REAL_LN:?}" "$@"
SH
chmod +x "$racebin/ln"

PATH="$racebin:$PATH" \
  FM_TEST_REAL_LN="$real_ln" \
  FM_TEST_PAUSE_LOCK="$home/state/.tg-recv.lock" \
  FM_TEST_PAUSE_REACHED="$home/state/fallback-at-receiver-lock" \
  FM_TEST_PAUSE_RELEASE="$home/state/release-fallback-lock" \
  FM_HOME="$home" "$ROOT/bin/fm-tg-recv-arm.sh" > "$home/harness.out" 2>&1 &
harness_pid=$!
for _ in $(seq 1 50); do
  [ -e "$home/state/fallback-at-receiver-lock" ] && break
  sleep 0.1
done
[ -e "$home/state/fallback-at-receiver-lock" ] \
  || fail "fallback did not pause between its fence check and receiver-lock acquisition"

out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
assert_contains "$out" "install telegram-receiver-unit" \
  "missing Telegram receiver unit did not request explicit consent"
assert_absent "$unitdir/fm-tg-recv@.service" \
  "bootstrap silently installed the Telegram receiver unit"
assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now" \
  "bootstrap silently enabled the Telegram receiver unit"

FM_TEST_START_SERVICE=1 service_env "$fakebin" "$home" "$unitdir" \
  "$ROOT/bin/fm-bootstrap.sh" install telegram-receiver-unit > "$home/install.out" 2>&1 &
install_pid=$!
sleep 0.2
assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now" \
  "installer crossed the handoff boundary while fallback held its shared gate"
touch "$home/state/release-fallback-lock"
wait "$install_pid" || fail "approved receiver service installation failed"
assert_contains "$(cat "$home/install.out")" "installing telegram-receiver-unit" \
  "bootstrap install did not announce the approved Telegram receiver action"
[ -f "$unitdir/fm-tg-recv@.service" ] || fail "approved installer did not copy the tracked receiver unit"
assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now fm-tg-recv@" \
  "approved installer did not enable and start the home-scoped receiver instance"
assert_grep 'FM_TG_RECV_MANAGER=systemd' "$home/state/.tg-recv-service.env" \
  "service environment did not select durable service output routing"
assert_absent "$home/state/receiver-overlap" \
  "service installation started a second receiver before retiring the harness receiver"
assert_absent "$home/state/.tg-recv-service-handoff" \
  "successful installation left the fallback receiver fenced"
wait "$harness_pid"
for _ in $(seq 1 50); do
  [ -e "$home/state/receiver-active" ] && break
  sleep 0.1
done
[ -e "$home/state/receiver-active" ] || fail "service-owned receiver did not start after handoff"

service_env "$fakebin" "$home" "$unitdir" "$SERVICE" selected \
  || fail "healthy matching receiver service was not selected"
printf '%s\n' stale > "$home/state/.tg-recv-service.env"
if service_env "$fakebin" "$home" "$unitdir" "$SERVICE" selected; then
  fail "stale service environment suppressed the tracked receiver fallback"
fi
FM_HOME="$home" "$ROOT/bin/fm-tg-recv-arm.sh" > "$home/stale-fallback.out" 2>&1 &
stale_fallback_pid=$!
wait "$stale_fallback_pid" || fail "persistently service-owned receiver made fallback fail noisily"
assert_contains "$(cat "$home/stale-fallback.out")" "service ownership handoff in progress" \
  "stale service health allowed a fallback wrapper to attach to the service receiver"
assert_absent "$home/state/receiver-overlap" \
  "stale service health allowed service and fallback receivers to coexist"
FM_TEST_START_SERVICE=1 service_env "$fakebin" "$home" "$unitdir" "$SERVICE" ensure >/dev/null
for _ in $(seq 1 50); do
  [ -e "$home/state/receiver-active" ] && break
  sleep 0.1
done
assert_absent "$home/state/receiver-overlap" \
  "service convergence restarted alongside a harness-owned receiver"
rm -f "$TMP_ROOT/systemd.active"
if service_env "$fakebin" "$home" "$unitdir" "$SERVICE" selected; then
  fail "inactive receiver service suppressed the tracked receiver fallback"
fi
touch "$TMP_ROOT/systemd.active"

printf '%s\n' stale > "$unitdir/fm-tg-recv@.service"
: > "$TMP_ROOT/systemctl.log"
detect_out=$(FM_BOOTSTRAP_DETECT_ONLY=1 \
  service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
assert_contains "$detect_out" "needs locked convergence" \
  "detect-only bootstrap missed stale Telegram receiver unit bytes"
assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart" \
  "detect-only bootstrap restarted the Telegram receiver"

FM_TEST_START_SERVICE=1 service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap > /dev/null
cmp -s "$ROOT/systemd/fm-tg-recv@.service" "$unitdir/fm-tg-recv@.service" \
  || fail "locked bootstrap did not converge tracked Telegram receiver unit bytes"
assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart fm-tg-recv@" \
  "locked bootstrap did not restart the stale Telegram receiver instance"
service_pid=$(cat "$home/state/service-wrapper-pid")
kill -TERM "$service_pid" 2>/dev/null || true
wait "$service_pid" 2>/dev/null || true
pass "Telegram receiver service installation is consent-gated and converges per home"
