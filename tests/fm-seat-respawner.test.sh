#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This is the suite that drives the restart service itself - its converge and
# --armed readings - so the suite-wide silencer tests/lib.sh sets for every
# other fixture home is lifted here.
export FM_SEAT_RESPAWNER_DISABLE=0

RESPAWNER="$ROOT/bin/fm-seat-respawner.sh"
STAY_DOWN="$ROOT/bin/fm-seat-stay-down.sh"
SERVICE="$ROOT/bin/fm-seat-respawner-service.sh"

fm_test_tmproot TMP_ROOT fm-seat-respawner

PIDNS=$(. "$ROOT/bin/fm-harness-pid-lib.sh"; fm_pid_namespace_token)

# A process whose name and command line look exactly like a harness, so the
# lock this component reads names something a liveness test accepts.
start_harness_shaped_process() {  # <home>
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$1/claude"
  chmod +x "$1/claude"
  "$1/claude" >/dev/null 2>&1 </dev/null &
  printf '%s\n' "$!"
}

record_seat() {  # <home> <pid>
  printf '%s\npidns=%s\n' "$2" "$PIDNS" > "$1/state/.lock"
}

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
    printf 'tmux-server=%s,%s\n' "$home/tmux.sock" "$$"
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

# A fake tmux that answers `new-window -P -F '#{pane_id}'` the way tmux does,
# so the launch records the pending first turn a real one would.
write_pane_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
for arg do
  if [ "\$arg" = new-window ]; then
    printf '%%9\n'
    break
  fi
done
exit 0
SH
  chmod +x "$path"
}

# A fake tmux that also completes the SERVER-IDENTITY ROUND TRIP a real one
# does, so the existence probe comes back CONFIRMED rather than unanswerable.
# bin/fm-tmux-lib.sh addresses a recorded server as
#   tmux -S <sock> if-shell <identity-test> <command> <mismatch-print> \; <completion-print>
# and reads the reply as "the server answered" only when the completion marker is
# the last line; anything else is rc=126, the backend could not be asked. The
# plain fake above never prints that marker, which is why it produces an
# unreadable pane and not a present one - the two are different fixtures because
# they are different facts, and the give-up says different things about them.
write_confirming_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
for arg do
  if [ "\$arg" = new-window ]; then
    printf '%%9\n'
    exit 0
  fi
done
idx=0
i=0
for arg do
  i=\$((i + 1))
  [ "\$arg" = if-shell ] && idx=\$((i + 2))
done
[ "\$idx" -gt 0 ] || exit 0
cmd=
last=
i=0
for arg do
  i=\$((i + 1))
  [ "\$i" = "\$idx" ] && cmd=\$arg
  last=\$arg
done
case "\$cmd" in
  *list-panes*|*pane_id*) printf '%%9\n' ;;
esac
printf '%s\n' "\$last"
exit 0
SH
  chmod +x "$path"
}

# The same confirming fake, but only while <switch> exists. Removing the switch
# is a tmux server that has exited: the round trip stops completing, so every
# later probe is unanswerable rather than a confident absence - which is what a
# container restart or a last window closing actually presents, and the only way
# to drive a confirmation that later goes stale.
write_switchable_fake_tmux() {
  local path=$1 log=$2 switch=$3
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
for arg do
  if [ "\$arg" = new-window ]; then
    printf '%%9\n'
    exit 0
  fi
done
[ -e "$switch" ] || exit 0
idx=0
i=0
for arg do
  i=\$((i + 1))
  [ "\$arg" = if-shell ] && idx=\$((i + 2))
done
[ "\$idx" -gt 0 ] || exit 0
cmd=
last=
i=0
for arg do
  i=\$((i + 1))
  [ "\$i" = "\$idx" ] && cmd=\$arg
  last=\$arg
done
case "\$cmd" in
  *list-panes*|*pane_id*) printf '%%9\n' ;;
esac
printf '%s\n' "\$last"
exit 0
SH
  chmod +x "$path"
}

write_executing_fake_tmux() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
last=
for arg do
  last=\$arg
done
printf '%s\n' "\$*" >> "$log"
env -i PATH=/usr/bin:/bin /bin/sh -c "\$last"
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
  FM_SEAT_RESPAWNER_BACKOFF="${FM_SEAT_RESPAWNER_BACKOFF:-1}" \
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS="${FM_SEAT_RESPAWNER_MAX_ATTEMPTS:-1}" \
  FM_SEAT_REVIVE_WATCHER=0 \
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
  local home delivery tmux log status findings launch_count
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
  printf 'undeliverable: listener pid 1 is up with 2 wake(s) pending, but the endpoint was published by a session that no longer holds the fleet lock\n' > "$status"
  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up check"

  launch_count=$(wc -l < "$log" | tr -d ' ')
  [ "$launch_count" = 1 ] || fail "changed wake count reset the retry bound; got $launch_count launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] || fail "give-up path did not emit exactly one finding; got $findings"
  assert_grep "exhausted 1 launch attempt" "$home/data/findings/"*.json \
    "give-up finding did not name the exhausted attempt bound"
  [ -f "$home/state/.seat-respawn-giveup" ] || fail "give-up episode marker was not recorded"
  pass "seat respawner reports exhausted retry episodes through findings"
}

# The launcher used to export its own PATH into the fresh seat, so a respawned
# seat silently ran a different tool set from a hand-started one. Measured on
# coditan-vessel 2026-08-27: `bash -lc` reaches claude 2.1.234 and `bash -lic`
# reaches 2.1.247, because ~/.bashrc returns at its interactive guard before the
# line that adds the npm prefix. No value composed by the launcher can reproduce
# that chain, so it composes none and the launch command owns its own
# environment. This asserts the absence, because the defect was invisible - a
# pinned PATH produces a seat that runs perfectly, on the wrong binary.
test_launch_does_not_pin_the_respawners_path() {
  local home delivery tmux log status
  home=$(make_home no-path-pin)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"
  printf "bash -lic 'exec claude'\n" > "$home/config/seat-launch-command"

  PATH="$home/should-not-be-pinned:${PATH:-/usr/bin:/bin}" FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner did not complete a launch cycle"
  assert_grep "new-window" "$log" "the launch never reached tmux"
  assert_no_grep "should-not-be-pinned" "$log" \
    "the respawner pinned its own PATH into the fresh seat"
  assert_no_grep "PATH=" "$log" \
    "the respawner composed a PATH for the seat; the launch command owns its own environment"
  assert_grep "exec bash -lic" "$log" \
    "the configured launch command did not reach tmux intact"
  pass "seat respawner composes no PATH for the fresh seat"
}

test_resume_style_launch_command_is_refused() {
  local home delivery tmux log status
  home=$(make_home resume-command)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$log"
  printf 'codex resume --last\n' > "$home/config/seat-launch-command"

  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused to complete a cycle after rejecting resume launch"
  [ ! -e "$log" ] || fail "resume-style launch command reached tmux"
  assert_grep "resume-style config/seat-launch-command" "$home/state/.seat-respawner.log" \
    "resume-style launch rejection was not operator-visible"
  pass "seat respawner refuses resume-style launch commands"
}

# One launch per unattended home at a time. The delivery verdict stays
# undeliverable until the fresh seat finishes session start and publishes an
# endpoint, which outlasts the first backoff, so a respawner that kept launching
# on schedule would leave live agent processes in windows nothing tracks - up to
# one per retry. The pending first-turn record is what it waits on.
test_a_pending_first_turn_holds_the_next_launch() {
  local home delivery tmux log status launches
  home=$(make_home first-turn-hold)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] || fail "the first cycle did not launch exactly one seat; got $launches"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the launch recorded no pending first turn, so there is nothing to hold on"

  # Past the retry backoff, so the next launch is due on schedule and only the
  # pending first turn can be what holds it.
  sleep 2
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the second unreachable check"

  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a second seat was launched while the first had not taken the lock; got $launches"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the pending first turn was dropped while its pane could not be read"
  assert_grep "held: the seat already started for this episode" "$home/state/.seat-respawner.log" \
    "holding the next launch was not operator-visible"
  pass "seat respawner waits out the seat it already started before starting another"
}

# THE BOUND, AND WHAT THE GIVE-UP MAY CLAIM WHEN IT IS REACHED.
#
# The captain ruled twice on this episode. First that the launch hold must still
# be bounded by the existing attempt limit, because a hold that never ends is a
# home nobody is coming back to and nothing ever says so. Then that the finding
# which ends it may not call a held cycle a launch: an episode whose first turn
# never lands makes ONE window call, and telling him five launches were spent
# would be the same overclaim this branch refuses everywhere else.
#
# So both halves are asserted here together, because either one alone is wrong.
# The bound without the honest count reports five launches that never happened;
# the honest count without the bound reports nothing at all, forever.
#
# THE BOUND AND THE ACCOUNTING ARE THIS TEST'S PROPERTY, AND THE PANE IS ONLY
# NAMED HERE. This fixture's backend never completes the server round trip, so no
# probe of the pane can be answered and the give-up cannot take - and must not
# take - the pane-still-open wording. What is asserted below is therefore that the
# episode reached its bound at all, that one launch is reported as one launch, and
# that the pane is NAMED whichever sentence carries it. The still-open claim is
# proved by test_a_giveup_reached_without_holds_still_names_the_open_pane, the one
# case given a confirming backend, and the refusal to make that claim on an
# unanswerable probe by test_a_giveup_whose_pane_could_not_be_read_claims_neither_way.
# Those two drive nearly the same fixture as this one and are not redundant with
# it: each pins a different property of the same episode.
test_a_held_episode_is_bounded_and_the_giveup_counts_launches_as_launches() {
  local home delivery tmux log status launches findings i
  home=$(make_home held-bound)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  # Four cycles at a three-attempt bound: one launch, then holds. Each later
  # cycle sleeps past the backoff so nothing but the pending first turn can be
  # what holds it.
  i=0
  while [ "$i" -lt 4 ]; do
    [ "$i" -eq 0 ] || sleep 2
    FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
      run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
  done

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the pending first turn was dropped, so no cycle was actually held"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a held episode opened more than one seat; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "a held episode never reached its bound; got $findings give-up findings"
  assert_no_grep "exhausted 3 launch attempt" "$home/data/findings/"*.json \
    "the give-up finding claimed launches that were holds"
  assert_grep "1 launch attempt" "$home/data/findings/"*.json \
    "the give-up finding did not name the one launch that was actually made"
  assert_grep "%9" "$home/data/findings/"*.json \
    "the give-up finding did not name the pane this episode is standing on"
  pass "a held episode is bounded and its give-up counts launches as launches"
}

# THE PANE-STILL-OPEN FACT IS STATED EXACTLY WHEN IT IS TRUE, AND THE TWO WAYS
# THAT CAN GO WRONG ARE OPPOSITE, SO THEY ARE ASSERTED SEPARATELY.
#
# It is the one fact the captain acts on: "a seat is open in this pane and the
# respawner is deliberately not opening another beside it" sends him to a machine
# to look at that pane, while "the launches ran out" sends him to start one. A
# give-up that picks between them by whether any cycle was ever HELD gets both
# wrong, because a hold is evidence that a pane was open THEN and says nothing
# about now. This half is the false positive: the episode held, the record was
# then retired, and at the bound nothing is open and nothing is being refused -
# so the finding may not say a seat is sitting in some pane it cannot even name.
#
# THE ROUTE THAT RETIRES THE RECORD HERE IS THE DEADLINE, NOT A VANISHED PANE.
# The fixture shrinks FM_SEAT_FIRST_TURN_DEADLINE on the last cycle, and with
# `submitted` never set the record is abandoned as one whose pane "never
# presented an empty agent composer". The confident pane-disappearance route is
# NOT exercised here and cannot be by a fake backend: write_pane_fake_tmux
# answers every non-new-window call with empty output, which reaches
# fm_backend_target_exists as "the backend could not be asked" rather than as a
# confident absence - which is exactly why the sibling test above asserts the
# record SURVIVES while its pane could not be read. Both routes end the same way
# for what is asserted below, a bound reached with no record standing, so this
# still bisects a selector keyed on the hold count; it simply does not prove
# anything about a pane that really closed.
test_a_giveup_with_no_standing_record_never_claims_an_open_pane() {
  local home delivery tmux log status launches findings i

  home=$(make_home giveup-no-record)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  # One launch, then two held cycles, each past its backoff so the pending first
  # turn is the only thing that can be holding it.
  i=0
  while [ "$i" -lt 3 ]; do
    [ "$i" -eq 0 ] || sleep 3
    FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
  done
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the pending first turn was dropped, so no cycle was actually held"

  # The first-turn deadline expires with nothing ever submitted, so the record is
  # abandoned, and the episode reaches its bound with holds already spent and
  # nothing left standing.
  FM_SEAT_FIRST_TURN_DEADLINE=1 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up cycle"

  [ ! -e "$home/state/.seat-first-turn" ] \
    || fail "the first-turn record still stands, so this is not the no-record case"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "this episode opened more than one seat; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "a held episode never reached its bound; got $findings give-up findings"
  assert_no_grep "pane unknown" "$home/data/findings/"*.json \
    "the give-up finding placed an open seat in a pane it could not name"
  assert_no_grep "is still open in pane" "$home/data/findings/"*.json \
    "the give-up finding claimed a seat was still open when no record stood"
  assert_grep "holds=2" "$home/data/findings/"*.json \
    "the held cycles were dropped from the measurement when the pane was gone"
  assert_grep "1 launch attempt" "$home/data/findings/"*.json \
    "the give-up finding did not name the one launch that was actually made"
  pass "a give-up with no standing record never claims an open pane"
}

# The other direction, and the false negative. Every cycle here is a launch - no
# cycle is ever held - so an episode that reached its bound on launches alone
# still ends with the record of its last one standing. The pane IS open, and the
# fact the captain acts on must be carried whether or not any hold was spent.
#
# THE BACKEND HERE ANSWERS, WHICH IS WHAT MAKES "STILL OPEN" SAYABLE AT ALL.
# write_confirming_fake_tmux completes the server round trip, so the existence
# probe returns a confirmed pane and the respawner records that it saw one. The
# plain fake would leave the probe unanswerable, and the sibling test below is
# what covers that case; a fixture that could not confirm the pane must not be
# the one asserting the pane is open.
test_a_giveup_reached_without_holds_still_names_the_open_pane() {
  local home delivery tmux log status launches findings

  home=$(make_home giveup-open-pane)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_confirming_fake_tmux "$tmux" "$log"

  # A one-launch bound: the single launch exhausts it, so the bound is reached on
  # the next cycle before any wait is due and no hold is ever spent.
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the launch recorded no pending first turn, so no pane is open to report"
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up check"

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the record was retired, so this is not the still-open case"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "the bound did not stop the launches; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "the episode never reached its bound; got $findings give-up findings"
  assert_grep "is still open in pane %9" "$home/data/findings/"*.json \
    "an unheld give-up dropped the open pane the captain acts on"
  assert_grep "not opening another beside it" "$home/data/findings/"*.json \
    "the give-up finding did not say the silence is a deliberate refusal"
  assert_grep "holds=0" "$home/data/findings/"*.json \
    "the hold count was dropped from the measurement when no cycle was held"
  pass "a give-up reached without holds still names the pane still open"
}

# WHAT REFUTES A SENTENCE IS NOT WHAT ENDS THE EPISODE, AND THE FINDING MAY NOT
# CONFLATE THEM.
#
# The give-up finding is read on a phone by someone deciding whether to walk to
# a machine, and its refuted-by line is where he learns what would change the
# picture. Saying the pane closing "ends this episode" tells him to close the
# pane and wait for a relaunch that cannot come: past the bound the attempt
# record still holds launches+holds at MAX_ATTEMPTS for the same condition key,
# so one_cycle returns at the bound test on every later cycle. The pane closing
# refutes the still-open-pane sentence and nothing more. Both halves are checked
# here against what the respawner actually does afterwards.
test_the_giveup_says_what_ends_the_episode_and_what_only_refutes_a_sentence() {
  local home delivery tmux log status findings refuted pane_sentence launches

  home=$(make_home giveup-episode-end)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_confirming_fake_tmux "$tmux" "$log"

  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the give-up check"

  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "the episode never reached its bound; got $findings give-up findings"
  assert_grep "is still open in pane %9" "$home/data/findings/"*.json \
    "the fixture did not reach the open-pane claim this case is about"

  # The finding record is this component's own emitted output; refuted_by is
  # read as the field it is rather than as text in a file.
  refuted=$(jq -r '.refuted_by' "$home/data/findings/"*.json) \
    || fail "the give-up finding carried no readable refuted_by"
  pane_sentence=$(printf '%s\n' "$refuted" | tr '.' '\n' | grep -i 'pane above closing' | head -1)
  [ -n "$pane_sentence" ] \
    || fail "the refuted-by line never says what closing the open pane would mean: $refuted"
  case "$pane_sentence" in
    *refutes*) : ;;
    *) fail "the pane sentence does not scope itself to the claim it refutes: $pane_sentence" ;;
  esac
  case "$pane_sentence" in
    *"ends this episode"*) fail "the refuted-by line still says closing the pane ends the episode: $pane_sentence" ;;
  esac
  case "$refuted" in
    *"delivery status"*) : ;;
    *) fail "the refuted-by line never names a changed delivery status as what clears the episode: $refuted" ;;
  esac
  case "$refuted" in
    *lock*) : ;;
    *) fail "the refuted-by line never names a seat taking this home's lock as what clears the episode: $refuted" ;;
  esac
  case "$refuted" in
    *stay-down*) : ;;
    *) fail "the refuted-by line never names the stay-down marker as what clears the episode: $refuted" ;;
  esac

  # The pane closes, so the record it left is retired exactly as
  # deliver_first_turn retires it on a confident absence. The episode is
  # untouched by that: nothing launches again.
  rm -f "$home/state/.seat-first-turn"
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the cycle after the pane closed"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "closing the pane restarted the episode; got $launches launches"
  [ -f "$home/state/.seat-respawn-attempts" ] \
    || fail "closing the pane cleared the episode record, so the refuted-by line would be right and the fixture wrong"

  # A changed delivery status is one of the three things that does clear it, and
  # only after that does this home get another seat.
  printf 'listener pid 1 is up with 0 wake(s) pending\n' > "$status"
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the cycle on a deliverable status"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "a changed delivery status did not clear the episode"
  [ ! -e "$home/state/.seat-respawn-giveup" ] \
    || fail "a changed delivery status left the give-up standing"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=1 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the check after the episode was cleared"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 2 ] \
    || fail "the cleared episode never launched again; got $launches launches"
  pass "the give-up names what clears the episode and what only refutes a sentence"
}

# THE READING NOBODY COULD TAKE, WHICH IS THE PRODUCTION CASE.
#
# An endpoint whose tmux server has exited - a container restart, or the last
# window closing - answers no probe at all. deliver_first_turn deliberately keeps
# the first-turn record through every such answer, because reading "I could not
# ask" as "the pane is gone" would release a launch beside a seat that may still
# be sitting there. That refusal is right, and it means a STANDING RECORD IS NOT
# EVIDENCE OF AN OPEN PANE: the record outlives the server. So the give-up may
# not turn it into one. It must say what it actually has - a seat was started
# here, and whether its pane is still there could not be read - in the register
# the alarm uses for `unmeasured`, asserting neither that the seat is open nor
# that it is gone. The plain fake tmux never completes the server round trip,
# which is exactly the shape a dead server presents.
test_a_giveup_whose_pane_could_not_be_read_claims_neither_way() {
  local home delivery tmux log status launches findings i

  home=$(make_home giveup-unreadable-pane)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  # One launch, then two held cycles, each past its backoff. The deadline stays
  # long, so the record is still standing when the bound arrives - and no probe
  # along the way was ever answered.
  i=0
  while [ "$i" -lt 4 ]; do
    [ "$i" -eq 0 ] || sleep 3
    FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
  done

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the record was retired, so this is not the unreadable-probe case"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "this episode opened more than one seat; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "a held episode never reached its bound; got $findings give-up findings"
  assert_no_grep "is still open in pane" "$home/data/findings/"*.json \
    "the give-up asserted an open pane on a probe that was never answered"
  assert_no_grep "no longer exists" "$home/data/findings/"*.json \
    "the give-up asserted the pane was gone on a probe that was never answered"
  assert_grep "cannot tell whether that pane is still there" "$home/data/findings/"*.json \
    "the give-up did not say plainly that the reading could not be taken"
  assert_grep "%9" "$home/data/findings/"*.json \
    "the give-up did not name the pane it started a seat in"
  assert_grep "holds=2" "$home/data/findings/"*.json \
    "the hold count was dropped when the pane could not be read"
  assert_grep "1 launch attempt" "$home/data/findings/"*.json \
    "the give-up did not name the one launch that was actually made"
  pass "a give-up whose pane could not be read claims neither way"
}

# A CONFIRMATION THAT HAS GONE STALE IS NOT A CONFIRMATION, and this is the
# DOMINANT shape of a held episode rather than a corner of it: typing the first
# turn requires a probe that answered, so nearly every episode that ever held has
# a pane once confirmed. The sibling above covers the narrow case where the server
# was already gone by the first probe; this covers the one that actually happened
# on 2026-08-27 - a seat confirmed early, and then a tmux server that exits.
#
# The record keeps its durable "a pane was confirmed here" mark, which is correct
# and is asserted below through `pane-confirmed=yes` in the measurement. What may
# not happen is a PRESENT-TENSE sentence resting on it: after the server goes,
# every probe is unanswerable, and the bound lands well inside the first-turn
# deadline so the deadline's own recheck never runs and never retires the record.
test_a_stale_confirmation_never_claims_the_pane_is_still_open() {
  local home delivery tmux log status switch launches findings i

  home=$(make_home giveup-stale-confirmation)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  switch="$home/tmux-server-up"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_switchable_fake_tmux "$tmux" "$log" "$switch"
  : > "$switch"

  # Cycle 1 launches; cycle 2 probes a server that is still answering, so the
  # pane is genuinely confirmed and the durable mark is written.
  i=0
  while [ "$i" -lt 2 ]; do
    [ "$i" -eq 0 ] || sleep 2
    FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
  done
  assert_grep "pane-seen=" "$home/state/.seat-first-turn" \
    "the fixture never confirmed the pane, so there is no stale confirmation to test"

  # The tmux server exits. Every probe from here is unanswerable, and the record
  # correctly keeps standing - so the bound arrives with a confirmation that is
  # now old and a pane nothing can currently see.
  rm -f "$switch"
  i=0
  while [ "$i" -lt 2 ]; do
    sleep 3
    FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused post-exit cycle $i"
    i=$((i + 1))
  done

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the record was retired, so the stale-confirmation case was not reached"
  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "this episode opened more than one seat; got $launches launches"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "the episode never reached its bound; got $findings give-up findings"
  assert_grep "pane-confirmed=yes" "$home/data/findings/"*.json \
    "the give-up dropped the durable record that a pane was once confirmed"
  assert_no_grep "is still open in pane" "$home/data/findings/"*.json \
    "the give-up claimed an open pane from a confirmation that had gone stale"
  assert_grep "cannot tell whether that pane is still there" "$home/data/findings/"*.json \
    "the give-up did not fall back to saying the reading could not be taken"
  assert_grep "holds=2" "$home/data/findings/"*.json \
    "the hold count was dropped when the confirmation went stale"
  assert_grep "1 launch attempt" "$home/data/findings/"*.json \
    "the give-up did not name the one launch that was actually made"
  pass "a stale confirmation never claims the pane is still open"
}

# The container-restart shape of the same defect. state/ outlives the process, so
# a respawner starting fresh finds a first-turn record carrying a `pane-seen` that
# a DIFFERENT process wrote against a tmux server that died with it. This one has
# confirmed nothing itself, and the mark it inherited may not speak for it.
test_an_inherited_confirmation_never_claims_the_pane_is_still_open() {
  local home delivery tmux log status findings i

  home=$(make_home giveup-inherited-confirmation)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
    FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the launching cycle"
  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the launch recorded no first turn to carry a mark across"

  # state/.seat-first-turn is this component's own persisted record; the mark the
  # dead process left in it is exactly what survives a container restart.
  printf 'pane-seen=%s\n' "$(($(date +%s) - 3600))" >> "$home/state/.seat-first-turn"

  i=0
  while [ "$i" -lt 3 ]; do
    sleep 3
    FM_SEAT_FIRST_TURN_DEADLINE=600 FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i after the restart"
    i=$((i + 1))
  done

  [ -f "$home/state/.seat-first-turn" ] \
    || fail "the record was retired, so the inherited-mark case was not reached"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "the episode never reached its bound; got $findings give-up findings"
  assert_grep "pane-confirmed=yes" "$home/data/findings/"*.json \
    "the fixture's inherited mark never reached the finding, so nothing was tested"
  assert_no_grep "is still open in pane" "$home/data/findings/"*.json \
    "the give-up claimed an open pane from a mark this process never confirmed"
  assert_grep "cannot tell whether that pane is still there" "$home/data/findings/"*.json \
    "the give-up did not fall back to saying the reading could not be taken"
  assert_grep "holds=2" "$home/data/findings/"*.json \
    "the hold count was dropped when the confirmation was only inherited"
  pass "an inherited confirmation never claims the pane is still open"
}

# The verdict the alarm turns into a sentence on the captain's phone. A
# respawner that is beating normally while the seat it started never finished
# starting is not a recovery under way, so it may not answer `up:`.
test_a_held_first_turn_is_reported_as_holding_rather_than_up() {
  local home out beat
  home=$(make_home holding-status)
  beat="$home/state/.last-seat-respawner-beat"

  run_status() {
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      "$SERVICE" status
  }

  # A respawner cycling normally: its own lock, this home, a live pid, a fresh
  # beacon. Nothing held yet.
  mkdir -p "$home/state/.seat-respawner.lock"
  {
    printf 'pid=%s\n' "$$"
    printf 'fm-home=%s\n' "$home"
  } > "$home/state/.seat-respawner.lock/record"
  : > "$beat"
  out=$(run_status)
  case "$out" in
    up:*) : ;;
    *) fail "a healthy respawner with nothing held did not answer up: $out" ;;
  esac

  # Now it is holding a first turn it typed into a pane that never took the lock.
  {
    printf 'pane=%%9\n'
    printf 'at=%s\n' "$(date +%s)"
    printf 'submitted=%s\n' "$(date +%s)"
    printf 'held=%s\n' "$(date +%s)"
  } > "$home/state/.seat-first-turn"
  out=$(run_status)
  case "$out" in
    holding:*) : ;;
    *) fail "a respawner holding a seat that never started did not answer holding: $out" ;;
  esac
  assert_contains "$out" "has not finished starting" \
    "the holding verdict did not say what it is waiting on"
  pass "a respawner holding a seat that never finished starting answers holding rather than up"
}

# THE RESTARTER THAT HAS STOPPED RETRYING, REPORTED AS ONE THAT IS STILL TRYING.
#
# The give-up is not the end of the process, only of the episode: past the bound
# one_cycle returns at the bound test every cycle while the loop keeps beating
# normally, so every reading that keys on the process alone still says `up:` and
# the alarm turns that into "an automatic restart is running and should bring it
# back on its own" on every repeat to the captain, for an absence nothing will
# retry.
#
# The path exercised here is the one that has no first-turn record at all, so
# `holding:` cannot cover it either: the endpoint's tmux server has exited, its
# recorded server pid answers no liveness test, and launch_in_tmux refuses
# before a window is opened. Each cycle still spends a launch, the bound is
# still reached, and the give-up is still recorded - against a condition key,
# which is what makes the reading below specific to the absence standing now.
test_a_respawner_that_gave_up_is_not_reported_as_a_running_restart() {
  local home delivery tmux log status findings out key i

  home=$(make_home giveup-status)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  # An endpoint whose tmux server is gone: the pid it names is not live, so the
  # socket is refused and no window is ever opened.
  {
    printf 'backend=tmux\n'
    printf 'target=%%9\n'
    printf 'harness=claude\n'
    printf 'session-lock-pid=999999\n'
    printf 'tmux-server=%s,999999\n' "$home/tmux.sock"
  } > "$home/state/.primary-endpoint"

  run_status() {
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      "$SERVICE" status
  }

  i=0
  while [ "$i" -lt 3 ]; do
    FM_SEAT_RESPAWNER_MAX_ATTEMPTS=2 \
      FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" \
      || fail "respawner refused cycle $i"
    i=$((i + 1))
    sleep 2
  done

  [ ! -e "$log" ] \
    || fail "the launch was not refused, so this is not the no-record path"
  [ ! -e "$home/state/.seat-first-turn" ] \
    || fail "a first turn was recorded, so this is not the no-record path"
  findings=$(find "$home/data/findings" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$findings" = 1 ] \
    || fail "the episode never reached its bound; got $findings give-up findings"
  key=$(sed -n 's/^key=//p' "$home/state/.seat-respawn-attempts" | head -1)
  [ -n "$key" ] || fail "the episode recorded no condition key to report against"

  # The process is untouched by all of that: its own lock, this home, a live
  # pid, a beacon it just wrote. Everything that makes a respawner healthy is
  # true, and it will still never launch again for this condition.
  mkdir -p "$home/state/.seat-respawner.lock"
  {
    printf 'pid=%s\n' "$$"
    printf 'fm-home=%s\n' "$home"
  } > "$home/state/.seat-respawner.lock/record"
  : > "$home/state/.last-seat-respawner-beat"

  out=$(run_status)
  case "$out" in
    gave-up:*) : ;;
    *) fail "a respawner that stopped retrying did not answer gave-up: $out" ;;
  esac
  assert_contains "$out" "stopped retrying" \
    "the gave-up verdict did not say that retrying has stopped"

  # A give-up recorded against a condition that no longer stands says nothing
  # about the one that does: the respawner starts a fresh count under the new
  # key without clearing the old record.
  printf 'key=0:0\nfinding=stale\n' > "$home/state/.seat-respawn-giveup"
  out=$(run_status)
  case "$out" in
    up:*) : ;;
    *) fail "a give-up against a superseded condition coloured the standing report: $out" ;;
  esac

  # And a record that could not be read is not a give-up either - two absent
  # keys are not a match.
  printf 'key=%s\nfinding=stale\n' "$key" > "$home/state/.seat-respawn-giveup"
  rm -f "$home/state/.seat-respawn-attempts"
  out=$(run_status)
  case "$out" in
    up:*) : ;;
    *) fail "an unreadable episode record was turned into a give-up: $out" ;;
  esac
  pass "a respawner that gave up on the standing condition is never reported as up"
}

# The state this whole area exists to remove is a restarter that is in the tree
# and has never once run, so an armed home with no beacon at all must be the
# loudest case rather than the one that stays silent.
test_an_armed_restart_that_never_ran_is_reported() {
  local home out
  home=$(make_home never-ran)

  run_service() {  # <now> <arg...>
    local now=$1; shift
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      FM_SEAT_RESPAWNER_TMUX="$(command -v sh)" FM_SEAT_RESPAWNER_NOW="$now" \
      "$SERVICE" "$@"
  }

  out=$(run_service "" --armed)
  assert_contains "$out" "nothing keeps this vessel" \
    "an unarmed home must say nothing keeps its restart running"

  run_service "" --arm >/dev/null || fail "the restart watch could not be armed"
  out=$(run_service "" --armed)
  [ -z "$out" ] || fail "a freshly armed home must not be called stopped: $out"

  out=$(run_service "$(( $(date +%s) + 7200 ))" --armed)
  assert_contains "$out" "has never run" \
    "an armed restart that never produced a beat said nothing"

  : > "$home/state/.last-seat-respawner-beat"
  out=$(run_service "$(( $(date +%s) + 7200 ))" --armed)
  assert_contains "$out" "last ran" \
    "a restart that ran and stopped was not reported"
  pass "an armed restart that never ran and one that stopped are both reported"
}

# A busy first mate produces the same `undeliverable:` verdict a missing one
# does - the delivery listener blocks the submit on a mid-turn pane - so the
# verdict alone cannot open a relaunch. The session lock is the presence
# reading, the same one bin/fm-seat-alarm.sh takes, and a home whose lock names
# a live harness is not missing a seat.
test_a_live_first_mate_is_never_relaunched() {
  local home delivery tmux log status seat launches
  home=$(make_home lock-held)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but the session pane is mid-turn\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"

  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused the first unreachable check"
  [ -f "$home/state/.seat-respawn-attempts" ] || fail "the first cycle opened no retry episode"

  # The seat that was there all along takes this home's lock, exactly as a busy
  # one holds it while the listener reports the pane unreachable.
  seat=$(start_harness_shaped_process "$home")
  record_seat "$home" "$seat"

  sleep 2
  FM_SEAT_RESPAWNER_MAX_ATTEMPTS=3 FM_FAKE_DELIVERY_STATUS="$status" \
    run_respawner_once "$home" "$delivery" "$tmux" \
    || fail "respawner refused a cycle while a live first mate held the lock"
  kill "$seat" 2>/dev/null || true

  launches=$(grep -c new-window "$log" 2>/dev/null || printf 0)
  [ "$launches" = 1 ] \
    || fail "a second seat was launched beside a live first mate; got $launches"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "a home with a live first mate kept an active retry episode"
  [ ! -e "$home/state/.seat-first-turn" ] \
    || fail "a home held by a first mate kept a pending first turn"
  assert_grep "a seat now holds this home" "$home/state/.seat-respawner.log" \
    "settling the pending first turn against a held home was not operator-visible"
  pass "seat respawner never launches beside a first mate that holds this home"
}

# The reading that could not be taken. Every earlier orphaning finding on this
# branch was a state that is not "seat present" being converted into "launch",
# and this is the last door into it: a lock this process cannot read says
# nothing about whether a first mate holds this home, so it must not open one.
test_an_unreadable_lock_never_produces_a_launch() {
  local home delivery tmux log status rc=0
  home=$(make_home unmeasured-lock)
  status="$home/status.txt"
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  printf 'undeliverable: listener pid 1 is up with 1 wake(s) pending, but no session has published where the model turn lives\n' > "$status"
  write_fake_delivery "$delivery"
  write_pane_fake_tmux "$tmux" "$log"
  printf 'x\n' > "$home/state/.lock"
  chmod 000 "$home/state/.lock"

  FM_FAKE_DELIVERY_STATUS="$status" run_respawner_once "$home" "$delivery" "$tmux" || rc=$?
  chmod 600 "$home/state/.lock"
  [ "$rc" = 0 ] || fail "respawner refused to complete a cycle over an unreadable lock"

  [ ! -e "$log" ] \
    || fail "a lock this home could not read was treated as an absent first mate and produced a launch"
  [ ! -e "$home/state/.seat-respawn-attempts" ] \
    || fail "a reading that could not be taken opened a retry episode"
  pass "seat respawner never launches on a lock it could not read"
}

# The watcher wakes firstmate on any line this check prints, so a start it did
# not confirm would announce a restoration that did not hold once per sweep -
# 288 turns a day at the default interval, each of them false.
test_converge_never_claims_a_start_it_could_not_confirm() {
  local home tmux log line
  home=$(make_home unconfirmed-start)
  tmux="$home/fake-tmux"
  log="$home/tmux.log"
  write_fake_tmux "$tmux" "$log"

  converge_once() {
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
      FM_SEAT_RESPAWNER_TMUX="$tmux" FM_SEAT_RESPAWNER_CONFIRM_TIMEOUT=1 \
      "$SERVICE" converge
  }

  line=$(converge_once)
  assert_grep "new-session" "$log" "converging never tried to start a keeper"
  assert_contains "$line" "could not be started" \
    "a keeper whose respawner never came up was reported as started again"
  assert_not_contains "$line" "has been started again" \
    "converging claimed a restoration that never happened"

  # The watcher enqueues a durable wake for any line a check prints, so a
  # condition no turn can repair must be said once rather than every sweep.
  line=$(converge_once)
  [ -z "$line" ] \
    || fail "the same unclearable failure was announced again on the next sweep: $line"
  line=$(converge_once)
  [ -z "$line" ] \
    || fail "the same unclearable failure was announced again two sweeps later: $line"
  pass "converging never claims a start it could not confirm, and says a persisting failure once"
}

# A watcher service that records what it was asked to do and reports the keeper
# tier, so a revival attempt leaves a trace instead of touching a real watcher.
write_fake_watcher_service() {  # <path> <log>
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = select ]; then printf 'keeper\n'; fi
exit 0
SH
  chmod +x "$path"
}

# The record a live watcher publishes about itself: pid, home, watcher path and
# the identity that makes pid reuse a mismatch.
record_watcher() {  # <home> <pid>
  local home=$1 pid=$2 lockdir identity
  lockdir="$home/state/.watch.lock"
  mkdir -p "$lockdir"
  # Sourced through `env` with this fixture's overrides, because
  # bin/fm-wake-lib.sh creates a state directory as a side effect of being
  # sourced and must never be allowed to create this repo's own.
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  identity=$(env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$pid")
  printf '%s\n' "$pid" > "$lockdir/pid"
  printf '%s\n' "$home" > "$lockdir/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$lockdir/watcher-path"
  printf '%s\n' "$identity" > "$lockdir/pid-identity"
}

watcher_health() {  # <home>
  local home=$1
  # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
  env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
    '. "$1/bin/fm-wake-lib.sh"
     fm_watcher_healthy "$2/state" "$1/bin/fm-watch.sh" 300 "$2" || true
     printf "%s\n" "$FM_WATCHER_HEALTH"' _ "$ROOT" "$home"
}

# A watcher that is ALIVE but whose beacon has aged out is not a dead watcher.
# bin/fm-wake-lib.sh classifies that as beacon-stale and names machine suspend as
# the case that necessarily produces it, so reviving on the bare unhealthy return
# stops and restarts a running watcher - and the sweep it kills mid-flight is the
# one that now carries the seat alarm itself.
test_only_a_provably_dead_watcher_is_revived() {
  local home delivery tmux svc svclog watcher health

  home=$(make_home watcher-revive)
  delivery="$home/fake-delivery"
  tmux="$home/fake-tmux"
  svc="$home/fake-watcher-service"
  svclog="$home/watcher-service.log"
  printf 'delivered: nothing is waiting for this vessel\n' > "$home/status.txt"
  write_fake_delivery "$delivery"
  write_fake_tmux "$tmux" "$home/tmux.log"
  write_fake_watcher_service "$svc" "$svclog"

  run_revive_cycle() {
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FINDINGS_DIR="$home/data/findings" \
    FM_SEAT_DELIVERY_SERVICE="$delivery" \
    FM_FAKE_DELIVERY_STATUS="$home/status.txt" \
    FM_SEAT_TMUX="$tmux" \
    FM_SEAT_RESPAWNER_ONCE=1 \
    FM_SEAT_REVIVE_WATCHER=1 \
    FM_SEAT_WATCHER_SERVICE="$svc" \
      "$RESPAWNER" >/dev/null 2>&1 || true
  }

  # A live, identity-matched watcher that has never touched a beacon: the very
  # state a suspended host leaves behind.
  watcher=$(start_harness_shaped_process "$home")
  sleep 0.4
  record_watcher "$home" "$watcher"
  health=$(watcher_health "$home")
  [ "$health" = beacon-stale ] \
    || fail "the fixture did not produce a live watcher with an aged-out beacon: $health"

  run_revive_cycle
  assert_no_grep "ensure" "$svclog" \
    "a live watcher whose beacon had aged out was stopped and restarted"
  [ ! -e "$home/state/.seat-respawner-watcher-revived" ] \
    || fail "a live watcher whose beacon had aged out was recorded as revived"

  # The same home once the watcher is genuinely gone.
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  health=$(watcher_health "$home")
  [ "$health" = dead ] \
    || fail "the fixture did not produce a dead watcher after the kill: $health"

  run_revive_cycle
  assert_grep "ensure" "$svclog" \
    "a watcher that had actually died was never revived"
  pass "only a provably dead watcher is revived, never a live one whose beacon aged out"
}

# The watcher runs every due check and defers its wakes to the end of the sweep,
# so "converged on every watcher sweep" is a property of the sweep and neither
# shim can displace the other. The two ids therefore carry only an ordering: the
# restarter's convergence runs before the alarm reads the seat. Measured through
# the watcher's own glob rather than argued from the names.
test_convergence_is_swept_before_the_alarm_and_supersedes_its_old_shim() {
  local home shims restart_at vacancy_at i legacy id c

  home=$(make_home sweep-order)

  # A home armed under the pre-rename ids, exactly as an updating vessel has it.
  for legacy in seat-alarm seat-respawner; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/$legacy.check.sh"
    chmod 0700 "$home/state/$legacy.check.sh"
    printf 'fm-custom-check-v1\ndeadbeef\n' > "$home/state/$legacy.check-trust"
  done

  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SEAT_RESPAWNER_FORCE_BACKEND=keeper \
    "$SERVICE" --arm >/dev/null || fail "the restart watch could not be armed"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-seat-alarm.sh" --arm >/dev/null || fail "the first-mate watch could not be armed"

  # A superseded shim the watcher would keep executing is the whole hazard of a
  # rename, so arming must have removed both halves of each old pair.
  for legacy in seat-alarm seat-respawner; do
    [ ! -e "$home/state/$legacy.check.sh" ] \
      || fail "arming left the superseded $legacy shim in place for the watcher to run"
    [ ! -e "$home/state/$legacy.check-trust" ] \
      || fail "arming left the superseded $legacy registration in place"
  done

  # Both replacements must satisfy the predicate the watcher itself gates on.
  for id in seat-restart seat-vacancy; do
    # shellcheck disable=SC2016 # The inner script's positional args are the child shell's, on purpose.
    env FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" bash -c \
      '. "$1/bin/fm-pr-lib.sh"
       . "$1/bin/fm-check-lib.sh"
       fm_custom_check_registered "$2/state" "$3"' _ "$ROOT" "$home" "$id" \
      || fail "$id was not left registered for the watcher to execute"
  done

  # The watcher's own enumeration: `for c in "$STATE"/*.check.sh`.
  shims=()
  for c in "$home/state"/*.check.sh; do shims+=("$(basename "$c")"); done
  restart_at=-1
  vacancy_at=-1
  for i in "${!shims[@]}"; do
    [ "${shims[$i]}" = seat-restart.check.sh ] && restart_at=$i
    [ "${shims[$i]}" = seat-vacancy.check.sh ] && vacancy_at=$i
  done
  [ "$restart_at" -ge 0 ] && [ "$vacancy_at" -ge 0 ] \
    || fail "the sweep did not yield both shims: ${shims[*]}"
  [ "$restart_at" -lt "$vacancy_at" ] \
    || fail "the alarm is swept before the convergence, so the seat is read before it is restarted: ${shims[*]}"
  pass "the restarter's convergence is swept before the alarm and supersedes the old shims"
}

test_stay_down_marker_is_authoritative
test_giveup_path_reports_a_finding
test_converge_never_claims_a_start_it_could_not_confirm
test_a_live_first_mate_is_never_relaunched
test_only_a_provably_dead_watcher_is_revived
test_convergence_is_swept_before_the_alarm_and_supersedes_its_old_shim
test_an_unreadable_lock_never_produces_a_launch
test_a_pending_first_turn_holds_the_next_launch
test_a_held_episode_is_bounded_and_the_giveup_counts_launches_as_launches
test_a_giveup_with_no_standing_record_never_claims_an_open_pane
test_a_giveup_reached_without_holds_still_names_the_open_pane
test_a_giveup_whose_pane_could_not_be_read_claims_neither_way
test_the_giveup_says_what_ends_the_episode_and_what_only_refutes_a_sentence
test_a_stale_confirmation_never_claims_the_pane_is_still_open
test_an_inherited_confirmation_never_claims_the_pane_is_still_open
test_a_held_first_turn_is_reported_as_holding_rather_than_up
test_a_respawner_that_gave_up_is_not_reported_as_a_running_restart
test_an_armed_restart_that_never_ran_is_reported
test_launch_does_not_pin_the_respawners_path
test_resume_style_launch_command_is_refused
