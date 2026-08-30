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
# this check should guess at - deliberately NOT a subcommand refusal, which is
# its own branch below.
#
# `unknown-cmd` and `daemon-help` are the two refusal shapes measured against the
# real CLI on 2026-08-30, for a version that does not carry the verb: an absent
# GROUP answers `unknown command "daemon" for "no-mistakes"` on STDERR with exit
# 1, and an absent VERB under a group that exists answers the group's help on
# stdout with exit 0. The stderr one is why the check captures that stream at
# all, and a fixture that only wrote to stdout would not prove it does.
#
# Two <version> values are sentinels rather than versions: `UNREADABLE` answers
# `--version` with a banner carrying no major.minor.patch, and `BROKEN` fails the
# call outright. Both are seats where no version was established at all, which is
# a different fact from a version that was read and found too old.
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
  case "$version" in
    UNREADABLE) printf '%s\n' 'no-mistakes (build 2ac3769, channel stable)'; exit 0 ;;
    BROKEN)     printf '%s\n' 'error: install manifest unreadable' >&2; exit 1 ;;
    *)          printf '%s\n' 'no-mistakes version $version (fake)'; exit 0 ;;
  esac
fi
if [ "\${1:-}" = daemon ] && [ "\${2:-}" = status ]; then
  case "$mode" in
    running)     printf '  \xe2\x97\x8f daemon running (pid 4242)\n'; exit 0 ;;
    down)        printf '  \xe2\x97\x8b daemon not running\n'; exit 0 ;;
    no-daemon)   printf '  \xe2\x97\x8b no daemon running\n'; exit 0 ;;
    stale-pid)   printf '  \xe2\x97\x8b no daemon running (pid 3223240 no longer exists)\n'; exit 0 ;;
    wedged)      sleep 30; exit 0 ;;
    garbled)     printf '  daemon: state indeterminate\n'; exit 2 ;;
    unknown-cmd) printf 'unknown command "daemon" for "no-mistakes"\n' >&2; exit 1 ;;
    daemon-help) printf 'Manage the no-mistakes daemon\n\nUsage:\n  no-mistakes daemon [command]\n\nAvailable Commands:\n  start       Install or refresh the managed daemon service and start it\n'; exit 0 ;;
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

# Every assertion about this check's wording reads THIS line, never the whole
# digest: forgejo_client_check runs in the same detect pass and prints the word
# `unestablished` too, so an assertion against the full output would pass on a
# neighbour's line and is specific only by accident of the fixture.
daemon_line() {  # <bootstrap output> -> echoes the VALIDATION_DAEMON line, if any
  printf '%s\n' "$1" | grep '^VALIDATION_DAEMON:' || true
}

# The upgrade command the fleet already prints for this tool, taken from the one
# line that owns it rather than restated here: a seat with no no-mistakes at all
# prints `MISSING: no-mistakes (install: <command>)`, and every VALIDATION_DAEMON
# path that routes to an upgrade must name that same command.
nm_install_cmd() {  # <bootstrap output> -> echoes the no-mistakes install command
  local missing=$1
  missing=$(printf '%s\n' "$missing" | grep '^MISSING: no-mistakes ' || true)
  [ -n "$missing" ] || return 1
  missing=${missing#*(install: }
  printf '%s\n' "${missing%)}"
}

# Six reasons now share the unestablished line, which is identical across all of
# them except the reason clause and the repair. A test asserting only the word
# `unestablished` therefore cannot tell them apart, and stays green when one
# branch's pattern widens until it swallows another's answers - the branch would
# be gone and its test would still pass. Every unestablished assertion here names
# its OWN reason and its OWN repair, so a swallow makes the swallowed test fail.
#
# The repair is the second half of the identity, not decoration: `hand` is for
# reasons that leave the CLI able to answer, `upgrade` for reasons whose blocker
# is the installed tool itself and where the hand reading would be refused
# exactly as the check's was.
# The DOWN verdict is the one this whole check exists to produce, and it is the
# easiest to lose without noticing: the generic unestablished line also ends in
# `no-mistakes daemon start`, through VALIDATION_DAEMON_REPAIR, so asserting that
# command proves nothing about which branch answered. Pin it by what only it
# says - the verdict clause, its own `repair:` form, and the ABSENCE of the
# unestablished hedge - so an arm reordering that drops the down fixture into
# any unestablished branch fails here rather than passing quietly.
assert_daemon_down() {  # <line> <what>
  local line=$1 what=$2
  assert_contains "$line" "VALIDATION_DAEMON:" \
    "$what must print the line at all rather than passing as healthy by saying nothing"
  assert_contains "$line" "the validation pipeline daemon is not running" \
    "$what must report the daemon as down, which is the verdict this check exists to produce"
  assert_not_contains "$line" "unestablished" \
    "$what is a reading that WAS taken, so it must not be hedged as one that was not"
  assert_contains "$line" "repair: no-mistakes daemon start" \
    "$what must name the start as its own repair rather than borrowing the by-hand reading"
  assert_contains "$line" "never no-mistakes update" \
    "$what must keep the ban on the update path, which no reason varies"
}

assert_unestablished() {  # <line> <reason fragment> <hand|upgrade> <what>
  local line=$1 reason=$2 repair=$3 what=$4
  assert_contains "$line" "VALIDATION_DAEMON:" \
    "$what must print the line at all rather than passing as healthy by saying nothing"
  assert_contains "$line" "unestablished" \
    "$what must report a reading it could not take, never a verdict"
  assert_contains "$line" "$reason" \
    "$what must carry its own reason clause rather than another branch's"
  case $repair in
    hand)
      assert_contains "$line" "take the reading by hand with no-mistakes daemon status" \
        "$what leaves the CLI able to answer, so the hand reading is the repair it must name"
      ;;
    upgrade)
      assert_not_contains "$line" "take the reading by hand with no-mistakes daemon status" \
        "$what cannot run the hand reading, so the line must not prescribe it"
      ;;
    *) fail "assert_unestablished: unknown repair family '$repair'" ;;
  esac
  assert_contains "$line" "never no-mistakes update" \
    "$what must keep the ban on the update path, which no reason varies"
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
  local d fakebin out line
  d=$(new_case dead)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" down

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(daemon_line "$out")
  assert_daemon_down "$line" "startup meeting a daemon that is not running"
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
  line=$(daemon_line "$out")
  assert_daemon_down "$line" "the down line this case drives"
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
  line=$(daemon_line "$out")
  assert_daemon_down "$line" "the down line this case drives"
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
  local d fakebin out line started elapsed
  d=$(new_case wedged)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" wedged

  started=$(date +%s)
  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  elapsed=$(( $(date +%s) - started ))
  line=$(daemon_line "$out")
  assert_unestablished "$line" "which is a wedged daemon rather than a dead one" hand \
    "a daemon that never answers"
  [ "$elapsed" -lt 25 ] || fail "the check must bound its call; the fixture daemon sleeps 30s and startup waited ${elapsed}s"
  pass "a wedged daemon is reported as unreadable and does not stall startup"
}

# The tool is external and this fleet does not own its output. When a version
# answers in a shape this check cannot classify, guessing either way is worse
# than saying so: guessing healthy hides a dead daemon, and guessing dead sends
# a reader to restart a live one and kill every other lane's in-flight run.
test_an_unrecognised_answer_is_reported_as_unreadable() {
  local d fakebin out line
  d=$(new_case garbled)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" garbled

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(daemon_line "$out")
  assert_unestablished "$line" "answered in a shape this check does not recognise" hand \
    "an answer this check cannot classify"
  pass "an unrecognised answer is reported as unreadable"
}

# A seat with no way to bound the call cannot take this reading safely: running
# it unbounded is the one outcome the check is forbidden to produce, because a
# wedged daemon would then hang every session start on the seat.
test_a_seat_that_cannot_bound_the_call_says_so() {
  local d fakebin out line
  d=$(new_case unbounded)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" running

  out=$(FM_VALIDATION_DAEMON_FORCE_UNBOUNDED=1 run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(daemon_line "$out")
  assert_unestablished "$line" "neither timeout nor gtimeout to bound the call" hand \
    "a seat that cannot bound the call"
  pass "a seat that cannot bound the call says so"
}

# The healthy verdict is the one branch where a wrong answer is SILENCE, so it is
# the one branch that must not be reachable from a loose match. Both fixtures
# here report a daemon that is down in wording the measured CLI does not use; a
# check anchored on "daemon running" alone reads each as an all-clear and
# reproduces the original defect against a differently worded tool.
test_a_down_daemon_worded_otherwise_is_never_an_all_clear() {
  local d fakebin out line mode
  for mode in no-daemon stale-pid; do
    d=$(new_case "worded-$mode")
    fakebin=$(make_fakebin "$d")
    make_fake_nm "$d/nmbin" "$mode"

    out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
    line=$(daemon_line "$out")
    assert_unestablished "$line" "answered in a shape this check does not recognise" hand \
      "a daemon reported down in wording this check cannot classify ($mode)"
  done
  pass "a daemon reported down in other wording is never an all-clear"
}

# A CLI below the version floor cannot be asked at all, so silence here would be
# the same all-clear this check exists to remove - but the standing repair cannot
# work either, because both daemon verbs need the upgrade first. The line has to
# carry the action that IS available, which is the upgrade MISSING: already names.
test_a_below_floor_cli_names_the_upgrade_as_its_repair() {
  local d fakebin out line upgrade
  d=$(new_case below-floor)
  fakebin=$(make_fakebin "$d")
  make_fake_nm "$d/nmbin" running v1.30.9

  out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
  line=$(daemon_line "$out")
  assert_unestablished "$line" "below the version floor this fleet requires" upgrade \
    "a CLI whose version was read and found too old"
  upgrade=$(nm_install_cmd "$out") \
    || fail "the below-floor fixture must also produce the MISSING: line whose repair this one borrows"
  assert_contains "$line" "$upgrade" \
    "the repair must be the upgrade MISSING: already prints, because it is the only action that can succeed here"
  assert_not_contains "$line" "no-mistakes daemon status" \
    "a hand reading cannot be prescribed on a CLI that cannot answer it"
  assert_not_contains "$line" "no-mistakes daemon start" \
    "a start cannot be prescribed on a CLI that cannot run it"
  pass "a below-floor CLI names the upgrade as its repair"
}

# `no_mistakes_compatible` fails for three different reasons, and only one of them
# is an out-of-date CLI: `--version` can fail outright, or answer in a shape no
# version parses out of. Reporting either as below the floor tells a reader on the
# newest release that their CLI is old - a version reading this check never took,
# in the one diagnostic whose whole premise is that it never states one it did not
# measure. The verdict and the upgrade repair are right on all three paths; only
# the reason has to say which reading was actually taken.
test_a_version_that_could_not_be_read_is_not_called_out_of_date() {
  local d fakebin out line upgrade version
  for version in UNREADABLE BROKEN; do
    d=$(new_case "version-$version")
    fakebin=$(make_fakebin "$d")
    make_fake_nm "$d/nmbin" running "$version"

    out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
    line=$(daemon_line "$out")
    assert_unestablished "$line" "answered with no version this check could read" upgrade \
      "a CLI whose version could not be read ($version)"
    assert_not_contains "$line" "below the version floor" \
      "no version was established for $version, so the line must not assert the CLI is out of date"
    upgrade=$(nm_install_cmd "$out") \
      || fail "the $version fixture must also produce the MISSING: line whose repair this one borrows"
    assert_contains "$line" "$upgrade" \
      "an unreadable version is a broken install, so the upgrade stays the action the reader can take"
  done
  pass "a version that could not be read is not reported as an out-of-date CLI"
}

# A CLI old enough not to carry the daemon verbs refuses the call outright. That
# refusal is DETECTABLE from the answer, so this branch needs no measurement of
# when the verbs were introduced - a fact this fleet cannot establish for a tool
# it does not own, and the reason a second version floor was not invented for it.
# Both measured refusal shapes belong here, and the first is on stderr, so a
# check that read only stdout would send the reader to a hand reading that
# refuses exactly as the check just did.
test_a_cli_that_refuses_the_verb_names_the_upgrade() {
  local d fakebin out line upgrade mode
  d=$(new_case refuses-baseline)
  fakebin=$(make_fakebin "$d")
  upgrade=$(nm_install_cmd "$(run_bootstrap "$d" "$fakebin")") \
    || fail "a seat with no no-mistakes must print the MISSING: line this repair is compared against"

  for mode in unknown-cmd daemon-help; do
    d=$(new_case "refuses-$mode")
    fakebin=$(make_fakebin "$d")
    make_fake_nm "$d/nmbin" "$mode"

    out=$(run_bootstrap "$d" "$d/nmbin:$fakebin")
    line=$(daemon_line "$out")
    assert_unestablished "$line" "refused daemon status as a command it does not have" upgrade \
      "a CLI that refuses the verb ($mode)"
    assert_contains "$line" "$upgrade" \
      "the repair must be the upgrade, because neither daemon verb exists on a CLI that refused this one"
  done
  pass "a CLI that refuses the verb names the upgrade as its repair"
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
test_a_version_that_could_not_be_read_is_not_called_out_of_date
test_a_cli_that_refuses_the_verb_names_the_upgrade
test_a_wholly_absent_cli_is_left_to_the_missing_line

printf 'all fm-validation-daemon-check tests passed\n'
