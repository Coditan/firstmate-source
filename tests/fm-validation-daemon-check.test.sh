#!/usr/bin/env bash
# Behavior tests for the startup assertion on the validation pipeline daemon.
#
# The 2026-08-30 defect, measured on the coditan vessel: a seat restart killed
# the no-mistakes daemon along with every crewmate. The dead crewmates were
# visible - each pane sat at a bare shell prompt - and the dead daemon was not
# visible anywhere:
#
#   connect to daemon socket: dial unix /home/coditan/.no-mistakes/socket: connect: connection refused
#   recorded pid 3223240 no longer exists
#
# No status line, no session-start diagnostic, no wake, no failing command. Four
# parked runs were unanswerable for about forty minutes, and it surfaced only
# when a relaunched worker tried to answer its own review gate and got that
# refusal back.
#
# The property that makes this a check rather than a habit: NOTHING on a seat
# touches the daemon until something needs it, so a seat with no gate work in
# flight carries a dead daemon indefinitely and reads perfectly healthy. Absence
# of complaint is not evidence of life, which is the one thing a startup reading
# can fix and no amount of care can.
#
# Four properties are pinned here, because a fix missing any one of them leaves
# the defect standing in a different shape:
#   1. It FIRES when the daemon is down, and the line carries the repair rather
#      than only the condition (the captain's 2026-08-24 ruling: a standing
#      diagnostic reaching a reader who cannot act on it is a defect whatever it
#      measures).
#   2. It is SILENT when the daemon is running. An assertion that fires either
#      way reports nothing, and a line per healthy subsystem is how a startup
#      digest becomes unread.
#   3. A reading it COULD NOT TAKE is reported as unable to read, never as
#      healthy. This is the case the fleet gets wrong, so it carries the most
#      cases here: a wedged daemon that never answers, an answer in a shape this
#      check does not recognise, and a seat with no way to bound the call.
#   4. It CLAIMS NO COUNT it cannot take. The socket is shared by an unknown
#      number of homes on one account, and no home can enumerate its siblings, so
#      the line names the account and never a number of homes.
#
# Every case drives bootstrap with a FAKE no-mistakes, so nothing here can pass
# or fail because of the developer's own live daemon - and nothing here can
# stop, start, or refresh it, which would kill every other lane's in-flight run
# on this account.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
fm_test_tmproot TMP_ROOT fm-validation-daemon-check

# This suite is the one place the check is exercised, so it opts back in to the
# assertion tests/lib.sh silences for every other suite.
export FM_VALIDATION_DAEMON_CHECK_DISABLE=0

new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/state" "$d/home/config"
  printf '%s\n' "$d"
}

# A fake no-mistakes whose `daemon status` behaves as <mode> and whose
# `--version` answers <version>, defaulting to the floor this fleet requires,
# written to <dir>/no-mistakes. The first two modes are the CLI's real answers,
# measured against no-mistakes v1.48.0 on 2026-08-30 and recorded in
# docs/validation-daemon.md:
#
#   running  ->   ● daemon running (pid 1727379)
#   down     ->   ○ daemon not running
#
# BOTH exit 0, which is why the check reads the answer instead of the status.
# `wedged` never answers at all, and `garbled` answers in a shape no version of
# this check should guess at.
#
# `no-daemon` and `stale-pid` are the two rewordings that make a loose match
# dangerous. Both report a daemon that is DOWN, both carry "daemon running" as a
# substring, and neither carries "daemon not running". `stale-pid` is the harder
# of the two, because it also carries "(pid" - the incident's own stale-pid
# shape - so it defeats an affirmative anchor as well as a negative one.
make_fake_nm() {  # <dir> <mode> [version]
  local dir=$1 mode=$2 version=${3:-v1.31.2}
  mkdir -p "$dir"
  cat > "$dir/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version $version (fake)'
  exit 0
fi
if [ "\${1:-}" = daemon ] && [ "\${2:-}" = status ]; then
  case "$mode" in
    running)   printf '  \xe2\x97\x8f daemon running (pid 4242)\n'; exit 0 ;;
    down)      printf '  \xe2\x97\x8b daemon not running\n'; exit 0 ;;
    no-daemon) printf '  \xe2\x97\x8b no daemon running\n'; exit 0 ;;
    stale-pid) printf '  \xe2\x97\x8b no daemon running (pid 3223240 no longer exists)\n'; exit 0 ;;
    wedged)    sleep 30; exit 0 ;;
    garbled)   printf 'unknown subcommand "status"\n'; exit 2 ;;
  esac
fi
exit 0
SH
  chmod +x "$dir/no-mistakes"
}

# Bootstrap needs a resolvable toolchain to get as far as the check; every other
# diagnostic it prints for this fixture is irrelevant here and is not asserted on.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi \
    treehouse tasks-axi quota-axi gh
  printf '%s\n' "$fakebin"
}

run_bootstrap() {  # <dir> <path-prefix>
  PATH="$2:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/home" \
    FM_VALIDATION_DAEMON_TIMEOUT=1 \
    "$BOOTSTRAP" 2>/dev/null
}

# --- 1. it fires, and it carries the repair ---------------------------------

# The live shape of the incident: the CLI runs fine, and the daemon behind it is
# gone. The line has to exist at all, and it has to be actionable on arrival -
# a reader who has to go and find out what to do next is reading a report, not
# a repair.
test_a_dead_daemon_is_reported_at_startup() {
  local d fakebin out
  d=$(new_case dead)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" down

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  assert_contains "$out" "VALIDATION_DAEMON:" \
    "startup must report a validation pipeline daemon that is not running"
  assert_contains "$out" "no-mistakes daemon start" \
    "the line must name the repair, not merely announce the condition"
  pass "a dead daemon is reported at startup"
}

# The repair that must never be named. `no-mistakes update` resets the daemon as
# part of upgrading the tool: on this seat it would have carried 1.48.0 to
# 1.60.2 as a side effect of a repair, with four parked runs sitting inside it.
# A repair must not smuggle a version change into parked work, so the line warns
# against it explicitly rather than relying on the reader knowing.
test_the_line_warns_against_the_update_path() {
  local d fakebin out line
  d=$(new_case warns)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" down

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(printf '%s\n' "$out" | grep '^VALIDATION_DAEMON:' || true)
  assert_contains "$line" "no-mistakes update" \
    "the line must name the update path so the reader recognises it"
  assert_contains "$line" "never" \
    "naming the update path without forbidding it would read as a second repair"
  pass "the line warns against the update path"
}

# A peer seat measured, on a machine with two firstmate homes on one Linux
# account, that the daemon process carries no FM_HOME in its environment at all:
# it was never told homes exist, so no home behind that socket can enumerate its
# siblings (docs/validation-daemon.md records the reading and its bounds). The
# number of homes one dead daemon impairs is therefore a reading this check
# cannot take, and a line that named one would be asserting it anyway.
test_the_line_claims_no_count_of_homes() {
  local d fakebin out line
  d=$(new_case no-count)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" down

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(printf '%s\n' "$out" | grep '^VALIDATION_DAEMON:' || true)
  assert_contains "$line" "on this account" \
    "the line must name the scope it can establish - the account the socket belongs to"
  assert_not_contains "$line" "home" \
    "the line must not describe the outage in homes; no home behind the socket can count its siblings"
  pass "the line claims no count of homes"
}

# --- 2. it is silent when the daemon is running ------------------------------

test_a_running_daemon_prints_nothing() {
  local d fakebin out
  d=$(new_case running)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" running

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  assert_not_contains "$out" "VALIDATION_DAEMON:" \
    "a running daemon must cost the startup digest no line at all"
  pass "a running daemon prints nothing"
}

# --- 3. a reading that could not be taken says so ----------------------------

# The case this whole check exists to remove, one layer in: a daemon that is
# wedged rather than dead answers nothing at all. Two things must hold at once -
# the digest must not stall waiting for it, and the silence must not be relayed
# as an all-clear.
test_a_wedged_daemon_is_reported_as_unreadable_not_healthy() {
  local d fakebin out started elapsed
  d=$(new_case wedged)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" wedged

  started=$(date +%s)
  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  elapsed=$(( $(date +%s) - started ))
  assert_contains "$out" "VALIDATION_DAEMON:" \
    "a daemon that never answers must not pass as healthy by saying nothing"
  assert_contains "$out" "unestablished" \
    "a reading that could not be taken is reported as unable to read, never as healthy"
  [ "$elapsed" -lt 25 ] || fail "the check must bound its call; the fixture daemon sleeps 30s and startup waited ${elapsed}s"
  pass "a wedged daemon is reported as unreadable and does not stall startup"
}

# The tool is external and this fleet does not own its output. When a version
# answers in a shape this check cannot classify, guessing either way is worse
# than saying so: guessing healthy hides a dead daemon, and guessing dead sends
# a reader to restart a live one and kill every other lane's in-flight run.
test_an_unrecognised_answer_is_reported_as_unreadable() {
  local d fakebin out
  d=$(new_case garbled)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" garbled

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  assert_contains "$out" "VALIDATION_DAEMON:" \
    "an answer this check cannot classify must not be classified as healthy"
  assert_contains "$out" "unestablished" \
    "the line must say the reading was not taken rather than assert a state"
  pass "an unrecognised answer is reported as unreadable"
}

# A seat with no way to bound the call cannot take this reading safely: running
# it unbounded is the one outcome the check is forbidden to produce, because a
# wedged daemon would then hang every session start on the seat.
test_a_seat_that_cannot_bound_the_call_says_so() {
  local d fakebin out
  d=$(new_case unbounded)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" running

  out=$(FM_VALIDATION_DAEMON_FORCE_UNBOUNDED=1 run_bootstrap "$d" "$d/nmbin:$fakebin")
  assert_contains "$out" "VALIDATION_DAEMON:" \
    "a seat that cannot bound the call must say the reading was not taken"
  assert_contains "$out" "unestablished" \
    "an unbounded seat has taken no reading, so it must not report one"
  pass "a seat that cannot bound the call says so"
}

# The healthy verdict is the one branch where a wrong answer is SILENCE, so it is
# the one branch that must not be reachable from a loose match. Both fixtures
# here report a daemon that is down in wording the measured CLI does not use; a
# check anchored on "daemon running" alone reads each as an all-clear and
# reproduces the original defect against a differently worded tool.
test_a_down_daemon_worded_otherwise_is_never_an_all_clear() {
  local d fakebin out mode
  for mode in no-daemon stale-pid; do
    d=$(new_case "worded-$mode")
    fakebin=$(make_fakebin "$d")
    make_fake_nm "$d/nmbin" "$mode"

    out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
    assert_contains "$out" "VALIDATION_DAEMON:" \
      "an answer reporting a daemon that is down ($mode) must never pass as healthy by saying nothing"
    assert_contains "$out" "unestablished" \
      "wording this check cannot classify is a reading it did not take, not a verdict"
  done
  pass "a daemon reported down in other wording is never an all-clear"
}

# A CLI below the version floor cannot be asked at all, so silence here would be
# the same all-clear this check exists to remove - but the standing repair cannot
# work either, because both daemon verbs need the upgrade first. The line has to
# carry the action that IS available, which is the upgrade MISSING: already names.
test_a_below_floor_cli_names_the_upgrade_as_its_repair() {
  local d fakebin out line missing upgrade
  d=$(new_case below-floor)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" running v1.30.9

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(printf '%s\n' "$out" | grep '^VALIDATION_DAEMON:' || true)
  assert_contains "$line" "unestablished" \
    "a CLI that cannot be asked has taken no reading, so its daemon answer must not be relayed as one"
  missing=$(printf '%s\n' "$out" | grep '^MISSING: no-mistakes ' || true)
  upgrade=${missing#*(install: }
  upgrade=${upgrade%)}
  [ -n "$upgrade" ] && [ "$upgrade" != "$missing" ] \
    || fail "the below-floor fixture must also produce the MISSING: line whose repair this one borrows"
  assert_contains "$line" "$upgrade" \
    "the repair must be the upgrade MISSING: already prints, because it is the only action that can succeed here"
  assert_not_contains "$line" "no-mistakes daemon status" \
    "a hand reading cannot be prescribed on a CLI that cannot answer it"
  assert_not_contains "$line" "no-mistakes daemon start" \
    "a start cannot be prescribed on a CLI that cannot run it"
  assert_contains "$line" "never no-mistakes update" \
    "naming an upgrade must not read as lifting the ban on the update path"
  pass "a below-floor CLI names the upgrade as its repair"
}

# --- 4. absence has an owner already ----------------------------------------

# Repeating it here would give one fact two owners and tell the reader to start a
# daemon whose CLI is not installed.
test_a_wholly_absent_cli_is_left_to_the_missing_line() {
  local d fakebin out
  d=$(new_case absent)
  fakebin=$(make_fakebin "$d")

  out=$(run_bootstrap "$d" "$fakebin")
  assert_not_contains "$out" "VALIDATION_DAEMON:" \
    "an uninstalled CLI is the MISSING: line's to report, not this one's"
  assert_contains "$out" "MISSING: no-mistakes" \
    "an uninstalled CLI must still be reported by its own owner"
  pass "a wholly absent CLI is left to the MISSING: line"
}

test_a_dead_daemon_is_reported_at_startup
test_the_line_warns_against_the_update_path
test_the_line_claims_no_count_of_homes
test_a_running_daemon_prints_nothing
test_a_wedged_daemon_is_reported_as_unreadable_not_healthy
test_an_unrecognised_answer_is_reported_as_unreadable
test_a_seat_that_cannot_bound_the_call_says_so
test_a_down_daemon_worded_otherwise_is_never_an_all_clear
test_a_below_floor_cli_names_the_upgrade_as_its_repair
test_a_wholly_absent_cli_is_left_to_the_missing_line

printf 'all fm-validation-daemon-check tests passed\n'
