#!/usr/bin/env bash
# Behavior tests for the run-state reader's dependency reach.
#
# The 2026-08-13 defect: bin/fm-crew-state.sh reached the no-mistakes CLI only
# through its caller's PATH. An interactive shell carries one because a login
# profile put ~/.no-mistakes/bin on it; a scheduled service, a hook, a fresh
# login and an independent reviewer session do not, so the same task read
# `working - run-step` interactively and `degraded - run-reader-missing`
# unattended, at the same moment. A reviewer that cannot see a decision resolved
# re-reports it as outstanding after every answer, so the blindness produced
# FALSE PENDING WORK rather than merely missing information.
#
# Two halves are pinned here, because a fix to either alone leaves the other
# defect standing:
#   1. RESOLUTION (bin/fm-nm-path-lib.sh, wired into bin/fm-crew-state.sh) - the
#      reader resolves the seat's own install instead of trusting the
#      environment, WITHOUT changing which binary an environment that already
#      resolves one runs, and WITHOUT inventing an answer when there is no
#      install to find.
#   2. DETECTION (bin/fm-bootstrap.sh's RUN_READER: line) - startup asserts that
#      an unattended context would reach the CLI, and says so when it would not.
#      A dependency that only surfaces when somebody happens to read a task's
#      state is not detected, it is stumbled upon.
#
# Every reader case runs on a PATH holding only a hermetic toolbin, so nothing
# here can pass because the developer's own shell is well provisioned - which is
# exactly how the original defect passed every test while failing in production.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
fm_test_tmproot TMP_ROOT fm-run-reader-reach

fm_git_identity fmtest fmtest@example.invalid

# This suite is the one place the startup assertion is exercised, so it opts back
# in to the check tests/lib.sh silences for every other suite.
export FM_RUN_READER_CHECK_DISABLE=0

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# A real git repo on <branch>, so the reader's branch attribution resolves like a
# live crew worktree's does. Exports the real head for the run fixture to bind.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  CASE_HEAD=$(git -C "$dir" rev-parse HEAD)
}

# A fake no-mistakes whose `axi status` reports one run with the given status,
# written to <dir>/no-mistakes. <status> is baked into the binary rather than
# read from the environment on purpose: two of these exist at once in the
# precedence case, and an env-driven fake could not tell the tester WHICH one
# answered.
make_fake_nm() {  # <dir> <branch> <head> <status>
  local dir=$1 branch=$2 head=$3 status=$4
  mkdir -p "$dir"
  cat > "$dir/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    [ "\${1:-}" = status ] || exit 0
    cat <<'TOON'
run:
  id: "01RUN"
  branch: $branch
  status: $status
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,$status,0,0
TOON
    ;;
  runs) ;;
  --version) printf '%s\n' 'no-mistakes version v1.31.2 (fake)' ;;
esac
exit 0
SH
  chmod +x "$dir/no-mistakes"
}

# Everything the reader needs EXCEPT no-mistakes, used as the WHOLE PATH so the
# developer's own shell cannot quietly supply it. The pane reader gets a fake
# tmux reporting an IDLE pane, so nothing but the run-step can produce a state
# and no case can pass on pane evidence it was not testing.
make_stripped_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/strippedbin" tool real
  mkdir -p "$tb"
  cat > "$tb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes)      printf '%%1 1\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane)    printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$tb/tmux"
  for tool in bash cat git grep sed awk head cut tail tr dirname basename date stat cksum mktemp timeout; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || continue
    ln -s "$real" "$tb/$tool"
  done
  for tool in bash cat git grep sed timeout; do
    [ -e "$tb/$tool" ] || fail "missing core tool for the stripped path: $tool"
  done
  [ ! -e "$tb/no-mistakes" ] || fail "the stripped toolbin must not contain no-mistakes"
  printf '%s\n' "$tb"
}

write_ship_meta() {  # <file> <worktree>
  fm_write_meta "$1" \
    "window=fm:fm-reach" \
    "worktree=$2" \
    "kind=ship" \
    "mode=no-mistakes"
}

# --- 1. resolution: the stripped read now answers with the true run state ----

# The acceptance case, and the exact shape measured on the vessel: no CLI
# anywhere on PATH, an install at the seat's own location, and a read that must
# come back with the run state rather than with a refusal.
test_stripped_environment_reads_the_true_run_state() {
  local d wt toolbin nmbin out
  d=$(new_case stripped-resolves)
  wt="$d/wt"
  make_repo_on_branch "$wt" fm/feat-reach
  toolbin=$(make_stripped_toolbin "$d")
  nmbin="$d/nm-install/bin"
  make_fake_nm "$nmbin" fm/feat-reach "$CASE_HEAD" running
  write_ship_meta "$d/state/reach.meta" "$wt"

  out=$(PATH="$toolbin" NO_MISTAKES_INSTALL_DIR="$nmbin" \
    FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" reach)
  assert_contains "$out" "source: run-step" \
    "a context that inherits nothing must still read the authoritative run-step"
  assert_not_contains "$out" "state: degraded" \
    "the reader must not refuse to answer merely because its caller carried no PATH"
  assert_not_contains "$out" "run-reader-missing" \
    "a resolvable install is not a missing dependency"
  pass "a stripped environment reads the true run state"
}

# --- 2. the interactive path is unchanged -----------------------------------

# The resolution must never decide WHICH no-mistakes runs. Firstmate does not own
# that install, and an operator pointing PATH at a particular build must keep
# getting it. Two fakes disagree about the run's status here, so the assertion
# names which one answered rather than merely observing that something did.
test_a_reachable_cli_still_wins_over_the_install_location() {
  local d wt toolbin pathbin nmbin out
  d=$(new_case path-wins)
  wt="$d/wt"
  make_repo_on_branch "$wt" fm/feat-precedence
  toolbin=$(make_stripped_toolbin "$d")
  pathbin="$d/pathbin"
  nmbin="$d/nm-install/bin"
  make_fake_nm "$pathbin" fm/feat-precedence "$CASE_HEAD" running
  make_fake_nm "$nmbin" fm/feat-precedence "$CASE_HEAD" failed
  write_ship_meta "$d/state/precedence.meta" "$wt"

  out=$(PATH="$pathbin:$toolbin" NO_MISTAKES_INSTALL_DIR="$nmbin" \
    FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" precedence)
  assert_contains "$out" "state: working" \
    "the CLI the caller's own PATH resolves must remain the one that answers"
  assert_not_contains "$out" "state: failed" \
    "resolving a seat install must never displace a CLI the environment already reached"
  pass "an already-reachable CLI still wins over the install location"
}

# --- 3. the degraded verdict survives a genuine absence ---------------------

# The honest refusal is what made this diagnosable at all. Resolving harder must
# not turn a real absence into a quiet wrong reading, so the missing-dependency
# verdict and its named cause are pinned against the fix.
test_a_genuine_absence_is_still_degraded_with_its_cause() {
  local d wt toolbin out
  d=$(new_case genuine-absence)
  wt="$d/wt"
  make_repo_on_branch "$wt" fm/feat-absent
  toolbin=$(make_stripped_toolbin "$d")
  mkdir -p "$d/nm-install/bin"
  write_ship_meta "$d/state/absent.meta" "$wt"
  printf 'resolved: carried on\n' > "$d/state/absent.status"

  out=$(PATH="$toolbin" NO_MISTAKES_INSTALL_DIR="$d/nm-install/bin" \
    FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" absent)
  assert_contains "$out" "state: degraded" \
    "an absent CLI must still stop the reader from answering with a crew state"
  assert_contains "$out" "cause: run-reader-missing" \
    "the degraded verdict must still name its cause"
  assert_not_contains "$out" "state: unknown" \
    "a broken instrument must still not be reported as a positive claim about the crew"
  pass "a genuine absence is still degraded and still names its cause"
}

# --- 4. detection: startup says so when an unattended context cannot reach it -

# Bootstrap needs a resolvable toolchain to get as far as the check; every other
# diagnostic it prints for this fixture is irrelevant here and is not asserted on.
make_bootstrap_home() {  # <dir> -> echoes fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/state" "$dir/home/config"
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi \
    treehouse tasks-axi quota-axi gh
  printf '%s\n' "$fakebin"
}

run_bootstrap() {  # <dir> <path-prefix> <unattended-base> <install-dir>
  PATH="$2:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/home" \
    FM_SERVICE_PATH_BASE="$3" NO_MISTAKES_INSTALL_DIR="$4" \
    "$BOOTSTRAP" 2>/dev/null
}

# The assertion has to be SEEN to fail, or it is not known to work. This is the
# live shape: the CLI is installed somewhere only a shell profile reaches, so the
# operator runs it every day and nothing unattended can.
test_startup_reports_a_cli_no_unattended_context_can_reach() {
  local d fakebin out
  d=$(new_case startup-unreachable)
  fakebin=$(make_bootstrap_home "$d")
  make_fake_nm "$d/profile-only" fm/none none running
  mkdir -p "$d/empty-install" "$d/unattended-base"

  out=$(run_bootstrap "$d" "$d/profile-only:$fakebin" "$d/unattended-base" "$d/empty-install")
  assert_contains "$out" "RUN_READER:" \
    "startup must report a run-state dependency no unattended context can reach"
  assert_contains "$out" "$d/profile-only/no-mistakes" \
    "the report must name the copy this session runs, so the gap is legible"
  pass "startup reports the dependency as unreachable when it is"
}

# The counterpart: on a seat whose install IS where an unattended context will
# look, the line must stay silent. An assertion that fires either way reports
# nothing.
test_startup_is_silent_when_an_unattended_context_would_reach_it() {
  local d fakebin out
  d=$(new_case startup-reachable)
  fakebin=$(make_bootstrap_home "$d")
  make_fake_nm "$d/profile-only" fm/none none running
  make_fake_nm "$d/nm-install/bin" fm/none none running
  mkdir -p "$d/unattended-base"

  out=$(run_bootstrap "$d" "$d/profile-only:$fakebin" "$d/unattended-base" "$d/nm-install/bin")
  assert_not_contains "$out" "RUN_READER:" \
    "a seat whose install an unattended context reaches must not be reported as blind"
  pass "startup is silent when an unattended context would reach the CLI"
}

# Absence has an owner already. Repeating it here would give one fact two owners
# and tell the operator to link a binary that is not installed.
test_startup_leaves_a_wholly_absent_cli_to_the_missing_line() {
  local d fakebin out
  d=$(new_case startup-absent)
  fakebin=$(make_bootstrap_home "$d")
  mkdir -p "$d/empty-install" "$d/unattended-base"

  out=$(run_bootstrap "$d" "$fakebin" "$d/unattended-base" "$d/empty-install")
  assert_not_contains "$out" "RUN_READER:" \
    "an uninstalled CLI is the MISSING: line's to report, not this one's"
  assert_contains "$out" "MISSING: no-mistakes" \
    "an uninstalled CLI must still be reported by its own owner"
  pass "a wholly absent CLI is left to the MISSING: line"
}

test_stripped_environment_reads_the_true_run_state
test_a_reachable_cli_still_wins_over_the_install_location
test_a_genuine_absence_is_still_degraded_with_its_cause
test_startup_reports_a_cli_no_unattended_context_can_reach
test_startup_is_silent_when_an_unattended_context_would_reach_it
test_startup_leaves_a_wholly_absent_cli_to_the_missing_line

printf 'all fm-run-reader-reach tests passed\n'
