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
  '--user enable --now '*) touch "$FM_TEST_SYSTEMD_ENABLED" "$FM_TEST_SYSTEMD_ACTIVE" ;;
  '--user restart '*) touch "$FM_TEST_SYSTEMD_ACTIVE" ;;
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

out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
assert_contains "$out" "install telegram-receiver-unit" \
  "missing Telegram receiver unit did not request explicit consent"
assert_absent "$unitdir/fm-tg-recv@.service" \
  "bootstrap silently installed the Telegram receiver unit"
assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now" \
  "bootstrap silently enabled the Telegram receiver unit"

service_env "$fakebin" "$home" "$unitdir" \
  "$ROOT/bin/fm-bootstrap.sh" install telegram-receiver-unit > "$home/install.out"
assert_contains "$(cat "$home/install.out")" "installing telegram-receiver-unit" \
  "bootstrap install did not announce the approved Telegram receiver action"
[ -f "$unitdir/fm-tg-recv@.service" ] || fail "approved installer did not copy the tracked receiver unit"
assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now fm-tg-recv@" \
  "approved installer did not enable and start the home-scoped receiver instance"
assert_grep 'FM_TG_RECV_MANAGER=systemd' "$home/state/.tg-recv-service.env" \
  "service environment did not select durable service output routing"

printf '%s\n' stale > "$unitdir/fm-tg-recv@.service"
detect_out=$(FM_BOOTSTRAP_DETECT_ONLY=1 \
  service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
assert_contains "$detect_out" "needs locked convergence" \
  "detect-only bootstrap missed stale Telegram receiver unit bytes"
assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart" \
  "detect-only bootstrap restarted the Telegram receiver"

service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap > /dev/null
cmp -s "$ROOT/systemd/fm-tg-recv@.service" "$unitdir/fm-tg-recv@.service" \
  || fail "locked bootstrap did not converge tracked Telegram receiver unit bytes"
assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart fm-tg-recv@" \
  "locked bootstrap did not restart the stale Telegram receiver instance"
pass "Telegram receiver service installation is consent-gated and converges per home"
