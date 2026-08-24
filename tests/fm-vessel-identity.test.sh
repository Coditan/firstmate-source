#!/usr/bin/env bash
# tests/fm-vessel-identity.test.sh - behavior tests for bin/fm-vessel-identity.sh,
# the label that tells a person which vessel the terminal they just attached to
# belongs to.
#
# The tmux half talks to a REAL tmux server on a private socket (`-L`), the same
# isolation tests/fm-backend-tmux-smoke.test.sh uses, so it never touches the
# host's own sessions - and it must not, because the thing under test writes a
# session option a live seat would then wear.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tests/lib.sh silences the stamp for every other suite, because composing
# bin/fm-session-start.sh from inside the operator's terminal would write a
# status-bar option onto the seat the run was launched from. This suite is the
# one that must exercise it, and it does so against a private tmux server.
export FM_VESSEL_IDENTITY_DISABLE=0

SCRIPT="$ROOT/bin/fm-vessel-identity.sh"
TMPROOT=
fm_test_tmproot TMPROOT fm-vessel-identity

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-vessel-identity-$$"
TMUX_SHIM=

tmux_cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1
  fm_test_cleanup
}
trap tmux_cleanup EXIT

# A home is just a directory; the script reads its own name off it.
make_home() {  # <name> -> prints path
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

label_for() {  # <home> [extra env assignments...]
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$SCRIPT"
}

# --- identity derivation ----------------------------------------------------

test_name_comes_from_the_home_the_session_runs_in() {
  local a b la lb
  a=$(make_home alpha-firstmate)
  b=$(make_home bravo-firstmate)
  la=$(label_for "$a")
  lb=$(label_for "$b")
  assert_contains "$la" "alpha-firstmate@" "label names the home the session runs in"
  assert_contains "$lb" "bravo-firstmate@" "a second home gets its own name"
  [ "$la" != "$lb" ] || fail "two homes on one host must not render one label"
  pass "the name is derived from the home the session is running in"
}

test_secondmate_home_is_named_by_its_own_id() {
  local h out
  h=$(make_home relief-firstmate)
  printf 'harbour\n' > "$h/.fm-secondmate-home"
  out=$(label_for "$h")
  assert_contains "$out" "2ndmate:harbour@" "a secondmate home is named by its own id"
  pass "a secondmate home is named by the id it carries"
}

test_blank_secondmate_marker_falls_back_to_the_home_basename() {
  local h out
  h=$(make_home quiet-firstmate)
  printf '   \n' > "$h/.fm-secondmate-home"
  out=$(label_for "$h")
  assert_contains "$out" "quiet-firstmate@" "a marker with no id falls back to the home basename"
  pass "an empty secondmate marker never produces a nameless vessel"
}

test_host_component_is_the_reported_host_name() {
  local h fakebin out
  h=$(make_home alpha-firstmate)
  fakebin=$(fm_fakebin "$TMPROOT")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = "-n" ]; then printf 'fm-container-demo\n'; exit 0; fi
exec /usr/bin/uname "$@"
SH
  chmod +x "$fakebin/uname"
  out=$(env FM_HOME="$h" PATH="$fakebin:$PATH" "$SCRIPT")
  assert_contains "$out" "alpha-firstmate@fm-container-demo" \
    "the host half tracks the host name this seat reports"
  rm -f "$fakebin/uname"
  pass "the host half is the host name the seat reports, so a moved seat reads differently"
}

test_unresolvable_home_is_said_not_invented() {
  local out rc=0
  out=$(env FM_HOME="$TMPROOT/there-is-no-such-home" "$SCRIPT") || rc=$?
  expect_code 3 "$rc" "an unresolvable home"
  assert_contains "$out" "unresolved-home@" "an unresolvable home is said, never guessed at"
  pass "a home that does not resolve is reported, not invented"
}

test_long_form_states_measured_or_unmeasured() {
  local h ok bad rc=0
  h=$(make_home alpha-firstmate)
  ok=$(env FM_HOME="$h" "$SCRIPT" --long)
  assert_contains "$ok" "(measured)" "a resolved home is marked measured"
  assert_contains "$ok" "home: $h" "the long form names the resolved home path"
  bad=$(env FM_HOME="$TMPROOT/gone" "$SCRIPT" --long) || rc=$?
  expect_code 3 "$rc" "long form on an unresolvable home"
  assert_contains "$bad" "unmeasured" "an unresolvable home is marked unmeasured"
  pass "the long form separates a reading it took from one it could not"
}

test_usage_error_exits_2() {
  local rc=0
  env FM_HOME="$TMPROOT" "$SCRIPT" --not-a-flag >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown flag"
  pass "an unknown flag is a usage error"
}

test_outside_tmux_says_so_and_arms_nothing() {
  local h out rc=0
  h=$(make_home alpha-firstmate)
  out=$(env -u TMUX -u TMUX_PANE FM_HOME="$h" "$SCRIPT" --arm-tmux) || rc=$?
  expect_code 0 "$rc" "arming outside tmux"
  [ "$out" = "not-tmux" ] || fail "outside tmux the arm must say not-tmux, got: $out"
  pass "a session that is not a tmux session is told so rather than silently skipped"
}

# --- real tmux --------------------------------------------------------------

tmux_shim() {  # prints a bin dir whose `tmux` targets the private socket
  local dir="$TMPROOT/tmuxshim"
  mkdir -p "$dir"
  cat > "$dir/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$dir/tmux"
  printf '%s\n' "$dir"
}

start_seat() {  # <session> <home> -> prints the pane id
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$1" -c "$2" bash --norc --noprofile >/dev/null 2>&1 \
    || fail "could not create tmux session $1"
  "$REAL_TMUX" -L "$SOCKET" display-message -p -t "$1" '#{pane_id}'
}

arm_seat() {  # <pane> <home> -> prints the arm output
  env FM_HOME="$2" TMUX="/fake-socket,1,0" TMUX_PANE="$1" PATH="$TMUX_SHIM:$PATH" "$SCRIPT" --arm-tmux
}

status_left_of() {  # <pane>
  "$REAL_TMUX" -L "$SOCKET" show-options -v -t "$1" status-left 2>/dev/null
}

test_the_disable_flag_reports_instead_of_hiding() {
  local h out rc=0
  h=$(make_home alpha-firstmate)
  out=$(env FM_HOME="$h" FM_VESSEL_IDENTITY_DISABLE=1 TMUX="/fake-socket,1,0" TMUX_PANE="%0" \
    "$SCRIPT" --arm-tmux) || rc=$?
  expect_code 0 "$rc" "arming with the stamp disabled"
  [ "$out" = "disabled" ] || fail "a disabled stamp must say so, got: $out"
  pass "a suppressed stamp says it did nothing rather than looking armed"
}

test_arming_puts_the_label_on_the_sessions_own_status_bar() {
  local h pane out bar len
  h=$(make_home alpha-firstmate)
  pane=$(start_seat armed "$h")
  out=$(arm_seat "$pane" "$h")
  assert_contains "$out" "armed alpha-firstmate@" "arming reports the label it stamped"
  bar=$(status_left_of "$pane")
  assert_contains "$bar" "vessel alpha-firstmate@" "the label is on the session's own status bar"
  [ "$("$REAL_TMUX" -L "$SOCKET" show-options -v -t "$pane" status)" = "on" ] \
    || fail "arming must turn the status bar on for that session"
  len=$("$REAL_TMUX" -L "$SOCKET" show-options -v -t "$pane" status-left-length)
  [ "$len" -ge 30 ] || fail "status-left-length must make room for the label, got $len"
  pass "the label lands on the status bar a person meets on attaching"
}

test_two_homes_on_one_server_get_two_different_bars() {
  local a b pa pb ba bb
  a=$(make_home alpha-firstmate)
  b=$(make_home bravo-firstmate)
  pa=$(start_seat seat-a "$a")
  pb=$(start_seat seat-b "$b")
  arm_seat "$pa" "$a" >/dev/null
  arm_seat "$pb" "$b" >/dev/null
  ba=$(status_left_of "$pa")
  bb=$(status_left_of "$pb")
  assert_contains "$ba" "vessel alpha-firstmate@" "seat A wears its own home's name"
  assert_contains "$bb" "vessel bravo-firstmate@" "seat B wears its own home's name"
  [ "$ba" != "$bb" ] || fail "two seats on two homes must not wear one bar"
  pass "a session run from a different home shows a different name"
}

test_stamped_start_time_is_the_sessions_own_not_the_current_clock() {
  local h pane bar created expected
  h=$(make_home alpha-firstmate)
  pane=$(start_seat timed "$h")
  arm_seat "$pane" "$h" >/dev/null
  bar=$(status_left_of "$pane")
  created=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$pane" '#{t:session_created}')
  expected=$(printf '%s' "$created" | awk 'NF>=5 {print $2, $3, substr($4,1,5)}')
  assert_contains "$bar" "since $expected" "the bar states when THIS session started"
  # tmux 3.4's #{t/f/<strftime>:<variable>} renders the CURRENT clock rather than
  # the named variable, so a bar built on it says "since <now>" forever. Keeping
  # that construct out of the bar is the guard, and it is asserted rather than
  # remembered.
  assert_not_contains "$bar" '#{t/' "the bar must not use tmux's t/f time format"
  pass "the start time on the bar is the session's own, not the current clock"
}

test_arming_is_idempotent() {
  local h pane first second
  h=$(make_home alpha-firstmate)
  pane=$(start_seat twice "$h")
  arm_seat "$pane" "$h" >/dev/null
  first=$(status_left_of "$pane")
  arm_seat "$pane" "$h" >/dev/null
  second=$(status_left_of "$pane")
  [ "$first" = "$second" ] || fail "arming twice must not stack: '$first' then '$second'"
  pass "arming the same seat again leaves the same bar"
}

test_a_hash_in_a_home_name_is_escaped_for_tmux() {
  local h pane bar
  h=$(make_home 'odd#name')
  pane=$(start_seat hashed "$h")
  arm_seat "$pane" "$h" >/dev/null
  bar=$(status_left_of "$pane")
  assert_contains "$bar" 'odd##name@' "a # in a home name is doubled so tmux prints it"
  pass "a home name carrying tmux's own format character is escaped"
}

test_name_comes_from_the_home_the_session_runs_in
test_secondmate_home_is_named_by_its_own_id
test_blank_secondmate_marker_falls_back_to_the_home_basename
test_host_component_is_the_reported_host_name
test_unresolvable_home_is_said_not_invented
test_long_form_states_measured_or_unmeasured
test_usage_error_exits_2
test_outside_tmux_says_so_and_arms_nothing
test_the_disable_flag_reports_instead_of_hiding

if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found - the status-bar half of this suite needs a real tmux"
  exit 0
fi
TMUX_SHIM=$(tmux_shim)
test_arming_puts_the_label_on_the_sessions_own_status_bar
test_two_homes_on_one_server_get_two_different_bars
test_stamped_start_time_is_the_sessions_own_not_the_current_clock
test_arming_is_idempotent
test_a_hash_in_a_home_name_is_escaped_for_tmux
