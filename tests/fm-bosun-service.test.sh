#!/usr/bin/env bash
# tests/fm-bosun-service.test.sh - the bosun's systemd user service
# (bin/fm-bosun-service.sh, systemd/fm-bosun@.service).
#
# The case that matters is the third one, and it is why this unit exists in this
# shape. On the host this was built against, bridge-notify-poll.timer reported
# loaded, enabled and active for nine days after it last did any work. A unit's
# own state answers whether something was STARTED, never whether it is doing the
# thing it was started for, so the diagnostic here reads bin/fm-bosun.sh status
# instead. That case drives both directions against one fixture - a bosun whose
# cursor froze reports, and a healthy one stays silent - with the fake systemd
# reporting active throughout, and separately asserts the script never asks
# is-active at all, so the rule is structural rather than promised.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SERVICE="$ROOT/bin/fm-bosun-service.sh"
BOSUN="$ROOT/bin/fm-bosun.sh"
fm_test_tmproot TMP_ROOT fm-bosun-service

# A fake user manager. `enable --now` and `restart` write the start beacon a
# real bosun writes before its first pass, because that is what those commands
# actually cause and the confirmation this script performs depends on it.
make_fake_systemd() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_SYSTEMCTL_LOG:?}"
beacon() {
  mkdir -p "${FM_TEST_BOSUN_STATE:?}/bosun"
  {
    printf 'state: running\n'
    printf 'pid: %s\n' "$$"
    printf 'started: %s\n' "$(date +%s)"
    printf 'last_pass: %s\n' "$(date +%s)"
    printf 'passes_this_run: 0\n'
    printf 'verdicts_this_run: 0\n'
    printf 'last_judged: 0\n'
    printf 'cursor: 0\n'
    printf 'journal_last: 0\n'
    printf 'backlog_since: 0\n'
    printf 'interval: 30\n'
  } > "$FM_TEST_BOSUN_STATE/bosun/health"
}
case "$*" in
  '--user show-environment'|'--user daemon-reload') exit 0 ;;
  '--user is-enabled --quiet '*)
    [ -e "${FM_TEST_SYSTEMD_ENABLED:?}" ]
    ;;
  '--user is-active --quiet '*)
    [ -e "${FM_TEST_SYSTEMD_ACTIVE:?}" ]
    ;;
  '--user enable --now '*)
    touch "$FM_TEST_SYSTEMD_ENABLED" "$FM_TEST_SYSTEMD_ACTIVE"
    beacon
    ;;
  '--user restart '*)
    touch "$FM_TEST_SYSTEMD_ACTIVE"
    beacon
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
  # wake-helpers.sh exports FM_ROOT_OVERRIDE at a scratch non-git directory to
  # keep the tangle banner inert; point it back at this checkout, because the
  # tracked unit template the service installs lives under it.
  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY="${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
    FM_BOSUN_SYSTEMCTL="$fakebin/systemctl" \
    FM_BOSUN_SYSTEMD_ESCAPE="$fakebin/systemd-escape" \
    FM_BOSUN_SYSTEMD_UNIT_DIR="$unitdir" \
    FM_BOSUN_CONFIRM_TIMEOUT=2 \
    FM_TEST_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log" \
    FM_TEST_SYSTEMD_ENABLED="$TMP_ROOT/systemd.enabled" \
    FM_TEST_SYSTEMD_ACTIVE="$TMP_ROOT/systemd.active" \
    FM_TEST_BOSUN_STATE="$home/state" \
    "$@"
}

service_unset_environment() {
  awk '
    /^[[:space:]]*\[/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == "Service" && /^[[:space:]]*UnsetEnvironment[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value == "") {
        normalized=""
      } else if (normalized == "") {
        normalized=value
      } else {
        normalized=normalized " " value
      }
    }
    END { print normalized }
  ' "$ROOT/systemd/fm-bosun@.service"
}

test_unit_clears_manager_judge_override() {
  local entry found=0
  for entry in $(service_unset_environment); do
    [ "$entry" = FM_BOSUN_JUDGE_CMD ] && found=1
  done
  [ "$found" -eq 1 ] || \
    fail "bosun unit does not clear FM_BOSUN_JUDGE_CMD at the service boundary"
  pass "bosun unit clears the manager's ambient judge override"
}

# --- 1. a home that never opted in is left entirely alone --------------------
#
# The bosun spends an agent turn per judgement, so a standing process that
# spends it is a decision a home makes rather than one an instruction-surface
# update delivers. A home that never opted in is left entirely alone.

test_unopted_home_is_silent() {
  local fakebin home unitdir out
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/unopted"
  unitdir="$TMP_ROOT/units-unopted"
  mkdir -p "$home/state" "$unitdir"
  make_fake_systemd "$fakebin"
  : > "$TMP_ROOT/systemctl.log"
  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  [ -z "$out" ] || fail "a home that did not opt in produced a bosun diagnostic: $out"
  assert_absent "$unitdir/fm-bosun@.service" "unopted bootstrap installed a bosun unit"
  assert_absent "$home/state/.bosun-service.env" "unopted bootstrap wrote a bosun service environment"
  pass "bosun bootstrap is silent until a home opts in"
}

# --- 2. installation is consent-gated, and later convergence is scoped -------

test_install_requires_consent_and_converges() {
  local fakebin home unitdir out detect_out restarts env_mode
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/opted"
  unitdir="$TMP_ROOT/units-opted"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  : > "$home/config/bosun"
  rm -f "$TMP_ROOT/systemd.enabled" "$TMP_ROOT/systemd.active"
  : > "$TMP_ROOT/systemctl.log"

  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$out" "install bosun-unit" \
    "a missing bosun unit did not request explicit consent"
  assert_absent "$unitdir/fm-bosun@.service" "bootstrap silently installed the bosun unit"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now" \
    "bootstrap silently enabled the bosun unit"

  service_env "$fakebin" "$home" "$unitdir" \
    "$ROOT/bin/fm-bootstrap.sh" install bosun-unit > "$home/install.out"
  assert_contains "$(cat "$home/install.out")" "installing bosun-unit" \
    "bootstrap install did not announce the approved bosun action"
  [ -f "$unitdir/fm-bosun@.service" ] || fail "approved installer did not copy the tracked unit"
  assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "enable --now fm-bosun@" \
    "approved installer did not enable and start the home-scoped instance"
  env_mode=$(stat -c %a "$home/state/.bosun-service.env")
  [ "$env_mode" = 600 ] || fail "private service environment mode was $env_mode instead of 600"
  assert_contains "$(cat "$home/state/.bosun-service.env")" "FM_BOSUN_EXEC=\"$BOSUN\"" \
    "service environment did not record the bosun this checkout runs"

  printf '%s\n' stale > "$unitdir/fm-bosun@.service"
  detect_out=$(FM_BOOTSTRAP_DETECT_ONLY=1 \
    service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$detect_out" "needs locked convergence" \
    "detect-only bootstrap missed stale bosun unit bytes"
  restarts=$(grep -c '^--user restart ' "$TMP_ROOT/systemctl.log" || true)
  [ "$restarts" -eq 0 ] || fail "detect-only bootstrap restarted the bosun"

  service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap > /dev/null
  cmp -s "$ROOT/systemd/fm-bosun@.service" "$unitdir/fm-bosun@.service" || \
    fail "locked bootstrap did not converge tracked bosun unit bytes"
  assert_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user restart fm-bosun@" \
    "locked bootstrap did not restart the stale bosun instance"

  rm -f "$home/config/bosun"
  : > "$TMP_ROOT/systemctl.log"
  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  [ -z "$out" ] || fail "removing opt-in produced a bosun diagnostic: $out"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user stop" \
    "removing opt-in stopped the installed bosun instance"
  assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "--user disable" \
    "removing opt-in disabled the installed bosun instance"
  pass "bosun unit installation is consent-gated and later convergence is scoped"
}

# --- 3. the liveness reading is not the unit's own state ---------------------
#
# Both directions against one fixture, with the fake user manager reporting the
# instance active the whole way through. A check that only ever reports one of
# the two proves nothing about its ability to tell them apart.

# Re-arm the health record as a live loop would have left it. A run --once exits
# cleanly and records STOPPED, which is a different reading on a different axis.
mark_running() {  # <state>
  local health="$1/bosun/health" now
  now=$(date +%s)
  sed -i.bak -e "s/^state: .*/state: running/" -e "s/^last_pass: .*/last_pass: $now/" "$health"
  rm -f "$health.bak"
}

# Single-quoted on purpose: this is the SOURCE of a judge script.
# shellcheck disable=SC2016
JUDGE_SANE='#!/usr/bin/env bash
cat > /dev/null
echo "{\"verdict\":\"routine\",\"confidence\":\"high\",\"reason\":\"progress\",\"judge\":\"fake\"}"'

test_health_reading_is_not_the_units_own_state() {
  local fakebin home unitdir out judge restarts_before restarts_after
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/health"
  unitdir="$TMP_ROOT/units-health"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  : > "$home/config/bosun"
  judge="$home/judge"
  printf '%s\n' "$JUDGE_SANE" > "$judge"
  chmod +x "$judge"
  rm -f "$TMP_ROOT/systemd.enabled" "$TMP_ROOT/systemd.active"
  : > "$TMP_ROOT/systemctl.log"

  service_env "$fakebin" "$home" "$unitdir" \
    "$ROOT/bin/fm-bootstrap.sh" install bosun-unit > /dev/null

  # (a) Healthy: an installed, enabled, active instance whose bosun is keeping up
  #     is not worth a word.
  mark_running "$home/state"
  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_not_contains "$out" "nothing is being judged" \
    "a bosun that is keeping up was reported as a fault"

  # (b) Now freeze it: events arrive, the loop keeps passing, and the record it
  #     writes goes nowhere. The unit is still enabled and still active.
  FM_STATE_OVERRIDE="$home/state" append_wake "$home/state" signal "fm-a.status" "fm-a needs attention"
  FM_STATE_OVERRIDE="$home/state" append_wake "$home/state" signal "fm-b.status" "fm-b needs attention"
  touch "$home/state/bosun/verdicts.tsv"
  chmod 0444 "$home/state/bosun/verdicts.tsv"
  FM_STATE_OVERRIDE="$home/state" FM_BOSUN_JUDGE_CMD="$judge" FM_BOSUN_STALL_AFTER=1 \
    "$BOSUN" run --once > /dev/null 2>&1
  sleep 2
  FM_STATE_OVERRIDE="$home/state" FM_BOSUN_JUDGE_CMD="$judge" FM_BOSUN_STALL_AFTER=1 \
    "$BOSUN" run --once > /dev/null 2>&1
  mark_running "$home/state"

  [ -e "$TMP_ROOT/systemd.active" ] || fail "fixture lost the active instance the case depends on"
  restarts_before=$(grep -c '^--user restart ' "$TMP_ROOT/systemctl.log" || true)
  out=$(FM_BOSUN_STALL_AFTER=1 service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$out" "BOSUN_UNIT: nothing is being judged" \
    "a frozen bosun under an active unit was not reported"
  assert_contains "$out" "STALLED" \
    "the reported reading did not name the concrete state"

  # A stall is reported and left alone. Restarting it would clear the symptom and
  # hide the fault, which is the same defect as trusting the unit's own state.
  restarts_after=$(grep -c '^--user restart ' "$TMP_ROOT/systemctl.log" || true)
  [ "$restarts_after" -eq "$restarts_before" ] || \
    fail "a stalled bosun was silently restarted instead of reported"

  # The structural half: the reading cannot be the unit's own state, because the
  # script never asks for it.
  assert_not_contains "$(cat "$TMP_ROOT/systemctl.log")" "is-active" \
    "the bosun service asked systemd whether the unit was active"
  pass "the bosun's health is read from its own work, not from the unit's state"
}

# --- 4. an observer that cannot reach its judge is named ---------------------
#
# It would keep running, keep passing, and record every event as a failure-path
# escalation. A liveness reading would go on saying WORKING throughout.

test_unreachable_judge_is_reported() {
  local fakebin home unitdir out
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/nojudge"
  unitdir="$TMP_ROOT/units-nojudge"
  mkdir -p "$home/state" "$home/config" "$unitdir"
  : > "$home/config/bosun"
  printf '%s\n' fm-test-judge-that-is-not-installed > "$home/config/bosun-judge"
  rm -f "$TMP_ROOT/systemd.enabled" "$TMP_ROOT/systemd.active"
  : > "$TMP_ROOT/systemctl.log"

  service_env "$fakebin" "$home" "$unitdir" \
    "$ROOT/bin/fm-bootstrap.sh" install bosun-unit > /dev/null
  mark_running "$home/state"
  out=$(service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_contains "$out" "cannot reach its judge fm-test-judge-that-is-not-installed" \
    "a service environment that cannot reach the judge was not reported"
  pass "an observer whose recorded environment cannot reach its judge is named"
}

test_ambient_judge_override_does_not_change_service_resolution() {
  local fakebin home unitdir out durable_bin recorded_env
  fakebin="$TMP_ROOT/fakebin"
  home="$TMP_ROOT/durable-judge"
  unitdir="$TMP_ROOT/units-durable-judge"
  durable_bin="$home/durable-bin"
  mkdir -p "$home/state" "$home/config" "$unitdir" "$durable_bin"
  : > "$home/config/bosun"
  printf '%s\n' durable-bosun-judge > "$home/config/bosun-judge"
  printf '%s\n' "$JUDGE_SANE" > "$durable_bin/durable-bosun-judge"
  chmod +x "$durable_bin/durable-bosun-judge"
  rm -f "$TMP_ROOT/systemd.enabled" "$TMP_ROOT/systemd.active"
  : > "$TMP_ROOT/systemctl.log"

  PATH="$durable_bin:$PATH" FM_BOSUN_JUDGE_CMD=ambient-bosun-judge \
    service_env "$fakebin" "$home" "$unitdir" \
    "$ROOT/bin/fm-bootstrap.sh" install bosun-unit > /dev/null
  recorded_env=$(cat "$home/state/.bosun-service.env")
  assert_contains "$recorded_env" "$durable_bin" \
    "service PATH did not resolve the durable per-home judge"
  assert_not_contains "$recorded_env" "FM_BOSUN_JUDGE_CMD" \
    "service environment persisted the converging session's ambient judge"

  mark_running "$home/state"
  out=$(PATH="$durable_bin:$PATH" FM_BOSUN_JUDGE_CMD=ambient-bosun-judge \
    service_env "$fakebin" "$home" "$unitdir" "$SERVICE" bootstrap)
  assert_not_contains "$out" "ambient-bosun-judge" \
    "reachability check used the converging session's ambient judge"
  assert_not_contains "$out" "cannot reach its judge" \
    "reachability check rejected the reachable durable per-home judge"
  pass "bosun service resolution ignores ambient judge overrides"
}

test_unopted_home_is_silent
test_unit_clears_manager_judge_override
test_install_requires_consent_and_converges
test_health_reading_is_not_the_units_own_state
test_unreachable_judge_is_reported
test_ambient_judge_override_does_not_change_service_resolution
