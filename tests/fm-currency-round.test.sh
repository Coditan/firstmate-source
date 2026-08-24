#!/usr/bin/env bash
# Network-free behavior tests for the daily currency round.
#
# Every reading that would reach the network is replaced by a fixture: the
# instruction-surface check is stubbed through a fake bin, and the tool table is
# overridden with pinned references that are local scripts.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one that must see the reporting modes speak.
export FM_CURRENCY_ROUND_DISABLE=0

fm_test_tmproot TMP_ROOT fm-currency-round-tests
fm_git_identity

ROUND="$ROOT/bin/fm-currency-round.sh"

fm_mode_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# A home whose external checks are stubbed. Returns the home path; state, config
# and a private bin of stubs live under it. FM_ROOT_OVERRIDE points at a fixture
# repository so the seat reading measures the fixture, never this checkout.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/stub"
  fm_git_init_commit "$home/repo"
  git -C "$home/repo" remote add origin "file://$home/repo"
  cat > "$home/stub/fm-firstmate-update-check.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${STUB_UPDATE_OUT:-}" ] && printf '%s\n' "$STUB_UPDATE_OUT"
exit "${STUB_UPDATE_RC:-0}"
SH
  cat > "$home/stub/fm-fleet-update-check.sh" <<'SH'
#!/usr/bin/env bash
[ "${STUB_PIN_AGE_RC:-0}" = 0 ] || exit "$STUB_PIN_AGE_RC"
printf '%s\n' "${STUB_PIN_AGE_OUT:-skipped|this home carries no firstmate.lock, so it is not pin-delivered and has no pin to age}"
SH
  cat > "$home/stub/pin" <<'SH'
#!/usr/bin/env bash
[ "${STUB_PIN_RC:-0}" = 0 ] || exit "$STUB_PIN_RC"
printf '%s\n' "${STUB_PIN_VERSION:-1.0.0}"
SH
  cat > "$home/stub/faketool" <<'SH'
#!/usr/bin/env bash
printf 'faketool version %s\n' "${STUB_TOOL_VERSION:-1.0.0}"
SH
  chmod +x "$home/stub"/*
  printf '%s\n' "$home"
}

# The round resolves its sibling scripts from its own location, so the stubs are
# installed by running a COPY of the round from the stub directory: its siblings
# are then the fixtures, and no test can reach the real network checks.
install_round() {
  local home=$1
  cp "$ROUND" "$home/stub/fm-currency-round.sh"
  cp "$ROOT/bin/fm-ff-lib.sh" "$home/stub/fm-ff-lib.sh"
  cp "$ROOT/bin/fm-check-register.sh" "$home/stub/fm-check-register.sh"
  cp "$ROOT/bin/fm-pr-lib.sh" "$home/stub/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-check-lib.sh" "$home/stub/fm-check-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$home/stub/fm-primary-scope-lib.sh"
  chmod +x "$home/stub/fm-currency-round.sh"
}

run_round() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home/repo" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CURRENCY_ROUND_TOOLS="faketool:pinned:$home/stub/pin" \
    PATH="$home/stub:$PATH" \
    "$home/stub/fm-currency-round.sh" "$@"
}

test_clean_seat_is_silent_and_says_which_hops_it_measured() {
  local home out report
  home=$(make_home clean)
  install_round "$home"

  out=$(run_round "$home" --force)
  [ -z "$out" ] || fail "a seat with nothing to decide must not wake anyone: $out"

  report="$home/state/currency-round.report"
  assert_grep 'reading: seat-can-update hop=installed state=ok' "$report" \
    "a clean default-branch checkout must read as able to take an update"
  assert_grep 'reading: tool:faketool hop=installed state=ok' "$report" \
    "a tool matching its pinned reference must read ok"
  assert_grep 'FOR THIS SEAT ONLY' "$report" \
    "the report must say which hops it can speak for"
  assert_grep 'pin hop' "$report" \
    "the report must say what it can and cannot claim on the pin hop"
  assert_grep 'reading: pin-age hop=pinned state=skipped' "$report" \
    "a home that is not pin-delivered must be skipped by name, not faulted"
  pass "a clean round is silent and still records which hops it measured"
}

# The reading earned on 2026-08-17, when this seat's update tool reported
# "already current" while its pin was 72 commits and 15 merged pull requests
# behind. Nothing measured pin AGE, so the vessel passed its own currency check.
test_a_stale_pin_is_reported_against_the_pinned_hop() {
  local home out
  home=$(make_home stale-pin)
  install_round "$home"

  out=$(STUB_PIN_AGE_OUT='behind|the pin 6ef0e3e is 72 commit(s) and 15 merged PR(s) behind main on https://example.invalid/source.git (source head 49a7688)' \
    run_round "$home" --force)
  assert_contains "$out" 'pin-age (pinned) behind' \
    "a stale pin must be reported against the pinned hop"
  assert_contains "$out" '72 commit(s)' \
    "the finding must carry the measured distance, not a bare verdict"
  assert_grep 'reading: pin-age hop=pinned state=behind' "$home/state/currency-round.report" \
    "the behind reading must be recorded"
  pass "a pin that lags its own source is reported rather than passing as current"
}

test_an_unreadable_pin_age_never_reports_all_clear() {
  local home out report
  home=$(make_home pin-age-blind)
  install_round "$home"

  out=$(STUB_PIN_AGE_RC=1 run_round "$home" --force)
  [ -z "$out" ] || fail "a single unmeasured pin-age reading must not surface yet: $out"
  report="$home/state/currency-round.report"
  assert_grep 'reading: pin-age hop=pinned state=unmeasured' "$report" \
    "a pin-age check that could not complete must record as unmeasured, never as ok"

  out=$(STUB_PIN_AGE_RC=1 run_round "$home" --force)
  assert_contains "$out" 'pin-age (pinned) unmeasured' \
    "a pin-age reading unmeasured in two consecutive rounds must surface"
  pass "a pin age that could not be read is never relayed as an all-clear"
}

test_an_unknown_pin_age_answer_is_unmeasured_not_ok() {
  local home report
  home=$(make_home pin-age-garbled)
  install_round "$home"

  STUB_PIN_AGE_OUT='current and fine' run_round "$home" --force >/dev/null
  report="$home/state/currency-round.report"
  assert_grep 'reading: pin-age hop=pinned state=unmeasured' "$report" \
    "an answer in an unknown shape must not be read as a state the round trusts"
  pass "an answer the round cannot parse is unmeasured rather than ok"
}

test_dirty_checkout_is_reported_as_unable_to_update() {
  local home out
  home=$(make_home dirty)
  install_round "$home"
  printf 'runtime\n' > "$home/repo/.env.local"

  out=$(run_round "$home" --force)
  assert_contains "$out" 'CURRENCY_ROUND:' "a checkout that cannot take an update must say so"
  assert_contains "$out" 'seat-can-update (installed) blocked' \
    "the finding must name the subject and the hop"
  assert_contains "$out" 'cannot take an update' \
    "the line must say the seat is unable, not merely behind"
  assert_grep 'state=blocked' "$home/state/currency-round.report" \
    "the blocked reading must be recorded"
  pass "a stray untracked file is reported as unable to update, not as up to date"
}

test_a_linked_secondmate_home_is_not_reported_as_unable() {
  local home out report
  home=$(make_home linked)
  install_round "$home"
  # A secondmate home is a linked worktree leased at a detached HEAD, which the
  # fast-forward path explicitly allows. Judging it by the primary home's rules
  # would report every such home as permanently unable to take an update.
  printf 'domain\n' > "$home/repo/.fm-secondmate-home"
  git -C "$home/repo" checkout -q --detach HEAD
  git -C "$home/repo" remote remove origin

  out=$(run_round "$home" --force)
  [ -z "$out" ] || fail "a healthy linked home must not be reported as unable: $out"
  report="$home/state/currency-round.report"
  assert_grep 'reading: seat-can-update hop=installed state=ok' "$report" \
    "a detached, origin-less linked home is positioned to take its next commit"

  printf 'runtime\n' > "$home/repo/.env.local"
  out=$(run_round "$home" --force)
  assert_contains "$out" 'seat-can-update (installed) blocked' \
    "a dirty linked home must still be reported as unable to update"
  pass "a linked secondmate home is judged by its own sync rules"
}

test_behind_instruction_surface_names_the_released_hop() {
  local home out
  home=$(make_home behind)
  install_round "$home"

  out=$(STUB_UPDATE_OUT='FIRSTMATE_UPDATE_AVAILABLE: update-source instruction update aaa -> bbb' \
    run_round "$home" --force)
  assert_contains "$out" 'instruction-surface (released) behind' \
    "an update-source instruction change must be reported against the released hop"
  assert_contains "$out" 'Decide immediate or batch' \
    "a behind-only finding must carry the decision it needs"
  pass "an instruction-surface change is reported and named by hop"
}

test_an_unmeasured_reading_never_reports_all_clear() {
  local home out report
  home=$(make_home unmeasured)
  install_round "$home"

  out=$(STUB_PIN_RC=1 run_round "$home" --force)
  [ -z "$out" ] || fail "a single unmeasured reading must not surface yet: $out"
  report="$home/state/currency-round.report"
  assert_grep 'reading: tool:faketool hop=installed state=unmeasured' "$report" \
    "an unreadable reference must record as unmeasured, never as ok"
  assert_grep 'faketool' "$home/state/currency-round.unmeasured" \
    "the unmeasured subject must be remembered for the next round"

  out=$(STUB_PIN_RC=1 run_round "$home" --force)
  assert_contains "$out" 'tool:faketool (installed) unmeasured' \
    "a subject unmeasured in two consecutive rounds must surface"
  pass "sustained blindness surfaces while a single blip does not"
}

test_unchanged_findings_are_reported_once() {
  local home first second third
  home=$(make_home unchanged)
  install_round "$home"
  printf 'runtime\n' > "$home/repo/.env.local"

  first=$(run_round "$home" --force)
  assert_contains "$first" 'CURRENCY_ROUND:' "the first round must report the finding"
  second=$(run_round "$home" --force)
  [ -z "$second" ] || fail "an unchanged finding must not be restated: $second"

  third=$(STUB_PIN_VERSION=2.0.0 run_round "$home" --force)
  assert_contains "$third" 'CURRENCY_ROUND:' "a changed finding must be reported again"
  pass "an unchanged finding is reported once and a changed one is reported again"
}

test_cadence_gates_the_round_and_force_overrides_it() {
  local home out
  home=$(make_home cadence)
  install_round "$home"
  printf 'runtime\n' > "$home/repo/.env.local"

  out=$(run_round "$home")
  assert_contains "$out" 'CURRENCY_ROUND:' "the first detect round must run"
  rm -f "$home/state/currency-round.surfaced"
  out=$(run_round "$home")
  [ -z "$out" ] || fail "a second round inside the cadence window must not run: $out"
  out=$(FM_CURRENCY_ROUND_INTERVAL=0 run_round "$home")
  assert_contains "$out" 'CURRENCY_ROUND:' "a zero cadence must run every invocation"
  pass "the cadence gates the round and can be overridden"
}

test_arming_is_idempotent_and_registers_the_check() {
  local home first second
  home=$(make_home arm)
  install_round "$home"

  run_round "$home" --arm >/dev/null || fail "arming failed"
  [ -x "$home/state/currency-round.check.sh" ] || fail "the watcher check was not written"
  [ -f "$home/state/currency-round.check-trust" ] || fail "the watcher check was not registered"
  [ "$(fm_mode_of "$home/state/currency-round.check.sh")" = 700 ] \
    || fail "the watcher check must be private and executable"
  first=$(cat "$home/state/currency-round.check.sh")

  run_round "$home" --arm >/dev/null || fail "re-arming failed"
  second=$(cat "$home/state/currency-round.check.sh")
  [ "$first" = "$second" ] || fail "re-arming rewrote an already-correct check"
  pass "arming writes a private registered check and converges on re-run"
}

test_an_unarmed_or_stopped_round_is_loud() {
  local home out
  home=$(make_home armed)
  install_round "$home"

  out=$(run_round "$home" --armed)
  assert_contains "$out" 'is not armed' "an unarmed home must say nothing is watching"

  run_round "$home" --arm >/dev/null
  out=$(run_round "$home" --armed)
  [ -z "$out" ] || fail "a freshly armed home must not be called stopped: $out"

  printf '%s\n' 1 > "$home/state/currency-round.last-run"
  out=$(FM_CURRENCY_ROUND_NOW=1000000 run_round "$home" --armed)
  assert_contains "$out" 'stopped being checked' \
    "a home whose round stopped completing must say so"
  pass "an unarmed home and a home that stopped checking are both loud"
}

test_a_disabled_round_stays_out_of_composing_suites() {
  local home out
  home=$(make_home disabled)
  install_round "$home"
  printf 'runtime\n' > "$home/repo/.env.local"

  out=$(FM_CURRENCY_ROUND_DISABLE=1 run_round "$home")
  [ -z "$out" ] || fail "the detect mode must be silent when disabled: $out"
  out=$(FM_CURRENCY_ROUND_DISABLE=1 run_round "$home" --armed)
  [ -z "$out" ] || fail "the armed reading must be silent when disabled: $out"
  out=$(FM_CURRENCY_ROUND_DISABLE=1 run_round "$home" --status)
  assert_contains "$out" 'reading:' "--status must ignore the disable switch"
  pass "the disable switch silences only the reporting modes"
}

test_status_reports_without_writing_the_cadence() {
  local home out
  home=$(make_home status)
  install_round "$home"

  out=$(run_round "$home" --status)
  assert_contains "$out" 'reading: seat-can-update' "--status must print every reading"
  [ ! -f "$home/state/currency-round.last-run" ] \
    || fail "--status must not record a completed round"
  [ ! -f "$home/state/currency-round.surfaced" ] \
    || fail "--status must not consume the de-duplication record"
  pass "--status reports without advancing the cadence"
}

test_clean_seat_is_silent_and_says_which_hops_it_measured
test_a_stale_pin_is_reported_against_the_pinned_hop
test_an_unreadable_pin_age_never_reports_all_clear
test_an_unknown_pin_age_answer_is_unmeasured_not_ok
test_dirty_checkout_is_reported_as_unable_to_update
test_a_linked_secondmate_home_is_not_reported_as_unable
test_behind_instruction_surface_names_the_released_hop
test_an_unmeasured_reading_never_reports_all_clear
test_unchanged_findings_are_reported_once
test_cadence_gates_the_round_and_force_overrides_it
test_arming_is_idempotent_and_registers_the_check
test_an_unarmed_or_stopped_round_is_loud
test_a_disabled_round_stays_out_of_composing_suites
test_status_reports_without_writing_the_cadence
