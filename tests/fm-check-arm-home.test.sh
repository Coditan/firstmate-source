#!/usr/bin/env bash
# Tests for the cross-home arm refusal: bin/fm-check-lib.sh's coherence guard,
# the six `--arm` paths that call it, and bin/fm-check-register.sh as the
# choke point every check that registers has to pass through.
#
# THE FAILURE THESE REPRODUCE, measured 2026-08-30
#
# An armed watcher check BAKES its home rather than inheriting one, because
# bin/fm-watch.sh runs it from a private snapshot with the watcher's own
# environment. So `--arm` writes whatever FM_HOME it was called with into
# whatever state directory it resolved - and nothing made those two agree.
#
# A caller that sets FM_HOME for a fixture home while FM_STATE_OVERRIDE is
# still inherited from a live session therefore resolves a FIXTURE home and a
# LIVE state directory, overwrites that live home's armed check with the
# fixture's locations, and reports `armed:` and exit 0.
#
# Six of this fleet's live checks were overwritten that way in one day:
# graph-freshness four separate times, each roughly twenty minutes apart, and
# memory-alarm, currency-round, forge-status, nudge and slot-guard once each.
# A leaked check then runs, looks in a temporary directory that no longer
# exists, finds nothing, prints nothing, and is indistinguishable from a
# healthy check with nothing to report. The graph one was silent for weeks
# over a store where nothing had been rebuilt in 24 days.
#
# WHAT THESE PIN
#
# bin/fm-check-lib.sh owns the predicate and states it in full; these cases hold
# it at every seam that can reach an armed check, and hold open the permission
# it must not take away. Arming a FIXTURE home stays legitimate and necessary -
# tests/lib.sh deliberately does not silence `--arm`, so the bootstrap suites
# still exercise arming against fixture homes - so cases (b) and (c) exist to
# refuse any fix that reaches for a blanket ban.
#
# Matrix:
#   (a) arm into another home's state/            -> REFUSE, naming both homes
#   (b) arm a fixture home's own state/           -> ALLOW (the suites depend on it)
#   (c) arm with no FM_STATE_OVERRIDE at all      -> ALLOW (bootstrap's own shape)
#   (d) a refused arm mutates nothing             -> victim's check and trust intact
#   (e) the registrar refuses the same mismatch   -> covers callers that render
#       their own shim and only borrow bin/fm-check-register.sh
#   (f) a state directory that is not named state -> ALLOW (it claims no owner)
#   (g) tests/lib.sh clears inherited location overrides -> a suite that sets
#       only FM_HOME can no longer resolve the operator's live state directory

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"

# --- the stand-in GitHub reader ---------------------------------------------
#
# bin/fm-github-inbox.sh will not arm on a feed it could not read, so every case
# in the table would otherwise need a live, authenticated gh-axi to reach the
# guard at all - and this suite's family in bin/fm-test-run.sh promises it needs
# nothing but this repository.
#
# It answers every request with a well-formed EMPTY feed. The response marker is
# taken back out of the caller's own --jq program rather than hardcoded, so this
# stays a reader of the envelope the script asks for and not a copy of a
# constant; an empty payload needs neither jq nor base64.
fm_test_tmproot SUITE_ROOT fm-check-arm-home-reader
FAKE_GH="$SUITE_ROOT/fake-gh"
cat >"$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
set -u
expr=${4:-}
mark=${expr#*\"}
mark=${mark%%\"*}
printf 'api_response:\n  body: %s\n  truncated: false\n' "$mark"
EOF
chmod +x "$FAKE_GH" || fail "could not install the stand-in GitHub reader"

# Every `--arm` path in bin/, as "<check id>|<script>|<args>". A script added to
# this table is a script whose arm path must carry the guard; case (a) then
# fails for it until it does.
arm_subjects() {
  cat <<'EOF'
currency-round|fm-currency-round.sh|--arm
memory-alarm|fm-memory-alarm.sh|--arm
slot-guard|fm-slot-guard.sh|--arm
forge-status|fm-forge-status.sh|--arm
github-inbox|fm-github-inbox.sh|--arm
nudge|fm-nudge.sh|--subject curation --arm
EOF
}

# A home with the directories an arm expects, and nothing else. `env -u` is not
# enough on its own here: tests/lib.sh already clears the inherited overrides,
# and this keeps each case honest about which of them it is setting.
make_home() {  # <path>
  mkdir -p "$1/state" "$1/config" "$1/data" || fail "could not build fixture home $1"
}

# Run one subject's arm path against an explicit home and state directory.
# The argument string comes from the table above and is deliberately word-split
# into the subject's own flags.
run_arm() {  # <script> <arg string>, with ARM_HOME/ARM_STATE set by the caller
  local script=$1 argstr=$2
  local -a args
  read -r -a args <<<"$argstr"
  env FM_HOME="$ARM_HOME" FM_STATE_OVERRIDE="$ARM_STATE" \
    FM_CONFIG_OVERRIDE="$ARM_HOME/config" FM_DATA_OVERRIDE="$ARM_HOME/data" \
    FM_GH_INBOX_GH="$FAKE_GH" \
    "$ROOT/bin/$script" "${args[@]}" 2>&1
}

test_arming_another_homes_state_is_refused() {
  local root id script args victim intruder out status
  fm_test_tmproot root fm-check-arm-home
  while IFS='|' read -r id script args; do
    [ -n "$id" ] || continue
    victim="$root/$id/victim"
    intruder="$root/$id/intruder"
    make_home "$victim"
    make_home "$intruder"

    # The victim is a correctly armed home first, so the case measures what an
    # intruding arm does to a LIVE check rather than to an empty directory.
    ARM_HOME=$victim ARM_STATE="$victim/state" \
      run_arm "$script" "$args" >/dev/null || fail "$id: arming the victim's own home must succeed"

    status=0
    out=$(ARM_HOME=$intruder ARM_STATE="$victim/state" run_arm "$script" "$args") || status=$?
    [ "$status" -ne 0 ] \
      || fail "$id: arming $victim/state with FM_HOME=$intruder reported success: $out"
    assert_contains "$out" "$victim" \
      "$id: the refusal must name the home whose state directory it protected"
    assert_contains "$out" "$intruder" \
      "$id: the refusal must name the home the arm would have baked in"
  done < <(arm_subjects)
  pass "an arm whose state directory belongs to another home is refused, naming both"
}

test_arming_a_fixture_home_still_works() {
  local root id script args home before after
  fm_test_tmproot root fm-check-arm-home
  while IFS='|' read -r id script args; do
    [ -n "$id" ] || continue
    home="$root/$id"
    make_home "$home"

    ARM_HOME=$home ARM_STATE="$home/state" \
      run_arm "$script" "$args" >/dev/null \
      || fail "$id: arming a fixture home must stay legitimate - the bootstrap suites depend on it"
    assert_present "$home/state/$id.check.sh" "$id: arming must write the fixture home's check"
    assert_present "$home/state/$id.check-trust" "$id: arming must bind the check to its own bytes"

    # Idempotence is what lets bin/fm-bootstrap.sh re-arm at every locked
    # session start; a guard that made the second call differ would churn.
    before=$(cat "$home/state/$id.check.sh")
    ARM_HOME=$home ARM_STATE="$home/state" \
      run_arm "$script" "$args" >/dev/null || fail "$id: re-arming a fixture home must succeed"
    after=$(cat "$home/state/$id.check.sh")
    [ "$before" = "$after" ] || fail "$id: re-arming must converge rather than rewrite"
  done < <(arm_subjects)
  pass "a fixture home can still be armed, and re-armed idempotently"
}

test_bootstraps_own_shape_is_never_refused() {
  # bin/fm-bootstrap.sh arms with FM_HOME set and no FM_STATE_OVERRIDE at all,
  # at every locked session start. A guard that refused this would silence the
  # very checks it exists to protect, so it gets its own case.
  local root id script args home out status
  local -a flags
  fm_test_tmproot root fm-check-arm-home
  while IFS='|' read -r id script args; do
    [ -n "$id" ] || continue
    home="$root/$id"
    make_home "$home"
    status=0
    read -r -a flags <<<"$args"
    out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      FM_HOME="$home" FM_GH_INBOX_GH="$FAKE_GH" \
      "$ROOT/bin/$script" "${flags[@]}" 2>&1) || status=$?
    [ "$status" -eq 0 ] \
      || fail "$id: arming with FM_HOME alone must succeed - that is bootstrap's own shape: $out"
    assert_present "$home/state/$id.check.sh" "$id: bootstrap's shape must write the check"
  done < <(arm_subjects)
  pass "arming with FM_HOME alone, the way bootstrap does, is never refused"
}

test_a_refused_arm_mutates_nothing() {
  # The refusal has to land BEFORE the write. Refusing only at registration
  # would still leave the victim's check overwritten and its trust stale, which
  # trades a silent wrong check for a silently rejected one.
  local root victim intruder check trust check_before trust_before
  fm_test_tmproot root fm-check-arm-home
  victim="$root/victim"
  intruder="$root/intruder"
  make_home "$victim"
  make_home "$intruder"
  check="$victim/state/currency-round.check.sh"
  trust="$victim/state/currency-round.check-trust"

  ARM_HOME=$victim ARM_STATE="$victim/state" \
    run_arm fm-currency-round.sh --arm >/dev/null || fail "arming the victim must succeed"
  check_before=$(cat "$check")
  trust_before=$(cat "$trust")

  ARM_HOME=$intruder ARM_STATE="$victim/state" \
    run_arm fm-currency-round.sh --arm >/dev/null 2>&1 \
    && fail "the intruding arm must be refused"

  [ "$(cat "$check")" = "$check_before" ] \
    || fail "a refused arm must not overwrite the victim's armed check"
  [ "$(cat "$trust")" = "$trust_before" ] \
    || fail "a refused arm must not disturb the victim's registration"
  assert_absent "$intruder/state/currency-round.check.sh" \
    "a refused arm must not half-install into the intruding home either"
  pass "a refused arm leaves the protected home's check and registration untouched"
}

test_the_registrar_refuses_the_same_mismatch() {
  # Not every armed check is rendered by bin/. A caller can write its own shim
  # and borrow only bin/fm-check-register.sh, so the registrar has to hold the
  # same predicate or the guard has a door beside it.
  local root victim intruder out status
  fm_test_tmproot root fm-check-arm-home
  victim="$root/victim"
  intruder="$root/intruder"
  make_home "$victim"
  make_home "$intruder"

  ARM_HOME=$victim ARM_STATE="$victim/state" \
    run_arm fm-currency-round.sh --arm >/dev/null || fail "arming the victim must succeed"

  status=0
  out=$(env FM_HOME="$intruder" FM_STATE_OVERRIDE="$victim/state" \
    "$REGISTER" currency-round 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "registering into another home's state directory reported success: $out"
  assert_contains "$out" "$victim" "the registrar's refusal must name the owning home"

  status=0
  out=$(env FM_HOME="$victim" FM_STATE_OVERRIDE="$victim/state" \
    "$REGISTER" currency-round 2>&1) || status=$?
  [ "$status" -eq 0 ] \
    || fail "registering a home's own check must still succeed: $out"
  pass "the registrar holds the same predicate as the arm paths"
}

test_a_state_directory_that_names_no_home_is_allowed() {
  # The predicate reads ownership out of the layout docs/configuration.md
  # already owns: a home keeps its state at <home>/state. A directory called
  # anything else names no owner, so there is no claim to violate and the guard
  # must not invent one - that is what keeps a deliberately relocated scratch
  # state directory working.
  local root home out status
  fm_test_tmproot root fm-check-arm-home
  home="$root/home"
  make_home "$home"
  mkdir -p "$root/scratch-state"
  status=0
  out=$(ARM_HOME=$home ARM_STATE="$root/scratch-state" run_arm fm-currency-round.sh --arm) || status=$?
  [ "$status" -eq 0 ] \
    || fail "a state directory that names no home must not be refused: $out"
  assert_present "$root/scratch-state/currency-round.check.sh" \
    "the scratch state directory must still receive the check"
  pass "a state directory that claims no owner is left alone"
}

test_the_test_harness_cannot_resolve_a_live_state_directory() {
  # The second half of the fix, and the one that stops the next suite repeating
  # it. A suite launched from inside a running firstmate session inherits that
  # session's FM_STATE_OVERRIDE. A case that then sets only FM_HOME resolves a
  # FIXTURE home and the OPERATOR'S LIVE state directory - which is precisely
  # how all six live checks were overwritten. tests/lib.sh has to clear the
  # inherited location overrides before any case runs.
  local out var
  for var in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
    FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_FINDINGS_DIR; do
    out=$(env "$var=/fm-test-inherited-live-home" \
      bash -c ". '$ROOT/tests/lib.sh'; printf '%s' \"\${$var-cleared}\"" 2>&1)
    [ "$out" = cleared ] \
      || fail "tests/lib.sh must clear an inherited $var, but a case would still see '$out'"
  done
  pass "the test harness clears inherited location overrides before any case runs"
}

test_arming_another_homes_state_is_refused
test_arming_a_fixture_home_still_works
test_bootstraps_own_shape_is_never_refused
test_a_refused_arm_mutates_nothing
test_the_registrar_refuses_the_same_mismatch
test_a_state_directory_that_names_no_home_is_allowed
test_the_test_harness_cannot_resolve_a_live_state_directory

printf '\nall fm-check-arm-home tests passed\n'
