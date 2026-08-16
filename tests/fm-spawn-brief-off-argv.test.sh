#!/usr/bin/env bash
# Behavior tests for the brief-off-argv contract in bin/fm-spawn.sh's
# launch_template().
#
# A launch command is world-readable in the host process table for as long as the
# agent runs, so a brief composed INTO that command is continuously readable by
# every account on the host and by every same-account sibling worker. These tests
# pin the contract that closes that: the launch carries the brief's PATH, never
# its BODY.
#
# The load-bearing assertion EXECUTES each captured launch command with the
# harness replaced by a recorder that writes its own argv to a file, then greps
# that argv for a sentinel that exists only inside the brief. Code inspection
# alone cannot show what a shell actually puts on a command line - a
# `$(cat brief)` and a `$(... launch-pointer path)` look equally innocent as
# strings - so the shell is made to expand it and the resulting argv is read.
#
# test_every_launch_template_is_covered keeps this honest as adapters are added:
# it enumerates the harnesses launch_template() accepts and fails if one is not
# exercised above.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-brief-off-argv

# Harnesses whose launch template is exercised by a case below. Kept in sync with
# bin/fm-spawn.sh's launch_template() by test_every_launch_template_is_covered.
COVERED_HARNESSES='claude codex opencode pi grok'

# A string that exists ONLY in the brief body. If it reaches any argv, the brief
# reached the process table.
BRIEF_SENTINEL='FM-BRIEF-BODY-SENTINEL-8f31c0'

make_fakebin() {
  local dir=$1 fakebin harness
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-panes) printf '%%1 1\n'; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *pane_id*) printf '%%1\n'; exit 0 ;; esac; done
    printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # Argv recorders standing in for the real harness binaries. Each writes the
  # exact argv the kernel handed it - which is what /proc/<pid>/cmdline shows -
  # and nothing else.
  for harness in claude codex opencode pi grok; do
    cat > "$fakebin/$harness" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf '%s\n' "$0"
  for a in "$@"; do printf '%s\n' "$a"; done
} > "$FM_ARGV_LOG"
exit 0
SH
    chmod +x "$fakebin/$harness"
  done
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/data/$id"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  # A brief shaped like a real one: multi-line, and carrying the sentinel plus the
  # kinds of content the leak actually exposed (task, acceptance criteria, paths).
  cat > "$home/data/$id/brief.md" <<BRIEF
You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
$BRIEF_SENTINEL

Acceptance criteria: the body of this file must never reach a command line.
Internal path: $home/state/$id.meta
BRIEF
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

seed_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cat > "$home/data/charter.md" <<BRIEF
You are a second mate.

# Charter
$BRIEF_SENTINEL
BRIEF
}

# Run the captured launch command for real, with the harness replaced by an argv
# recorder, and print the recorded argv. This is the step that turns a string
# assertion into a measurement of what the shell actually builds.
expand_launch_argv() {  # <launch-line> <fakebin> <argv-log>
  local launch=$1 fakebin=$2 argv_log=$3
  : > "$argv_log"
  ( export FM_ARGV_LOG="$argv_log" PATH="$fakebin:$PATH"; eval "$launch" ) >/dev/null 2>&1
  cat "$argv_log"
}

assert_brief_stayed_off_argv() {  # <label> <launch-line> <fakebin> <case-dir> <brief-path>
  local label=$1 launch=$2 fakebin=$3 case_dir=$4 brief=$5 argv

  # 1. The command firstmate types into the pane must not contain the body.
  case "$launch" in
    *"$BRIEF_SENTINEL"*)
      fail "$label: the launch command firstmate sends carries the brief body" ;;
  esac

  # 2. The command, once the shell expands it, must not put the body on any argv.
  argv=$(expand_launch_argv "$launch" "$fakebin" "$case_dir/argv.log")
  [ -n "$argv" ] || fail "$label: launch command did not reach the harness at all"$'\n'"launch: $launch"
  case "$argv" in
    *"$BRIEF_SENTINEL"*)
      fail "$label: the brief body reached the harness argv, so it is readable in the process table" ;;
  esac

  # 3. It must still deliver the brief: the argv carries the brief's path inside a
  #    launch-brief input, so the worker can open it. A launch that leaks nothing
  #    because it delivers nothing is not a pass.
  case "$argv" in
    *"$brief"*) ;;
    *) fail "$label: launch argv does not name the brief, so the worker cannot find it"$'\n'"argv: $argv" ;;
  esac
  case "$argv" in
    *'FIRSTMATE_OP: v1 launch-brief: '*) ;;
    *) fail "$label: launch argv lost the canonical launch-brief input kind"$'\n'"argv: $argv" ;;
  esac
}

spawn_case_and_assert() {  # <name> <harness> <id> [extra spawn args...]
  local name=$1 harness=$2 id=$3 rec out status launch target
  shift 3
  rec=$(make_case "$name" "$harness" "$id")
  read_case_record "$rec"
  target=$PROJ_DIR
  if [ "${1:-}" = "--secondmate" ]; then
    target="$CASE_DIR/secondmate-home"
    seed_secondmate_home "$target" "$id"
  fi
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$target" "$@")
  status=$?
  expect_code 0 "$status" "$name spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  if [ "${1:-}" = "--secondmate" ]; then
    assert_brief_stayed_off_argv "$name" "$launch" "$FAKEBIN_DIR" "$CASE_DIR" "$target/data/charter.md"
  else
    assert_brief_stayed_off_argv "$name" "$launch" "$FAKEBIN_DIR" "$CASE_DIR" "$HOME_DIR/data/$id/brief.md"
  fi
}

test_claude_launch_keeps_the_brief_off_argv() {
  spawn_case_and_assert claude-ship claude brief-argv-claude-z1
  pass "a claude crewmate launch carries the brief's path, never its body"
}

test_codex_launch_keeps_the_brief_off_argv() {
  spawn_case_and_assert codex-ship codex brief-argv-codex-z2
  pass "a codex crewmate launch carries the brief's path, never its body"
}

test_opencode_launch_keeps_the_brief_off_argv() {
  spawn_case_and_assert opencode-ship opencode brief-argv-opencode-z3
  pass "an opencode crewmate launch carries the brief's path, never its body"
}

test_pi_launch_keeps_the_brief_off_argv() {
  spawn_case_and_assert pi-ship pi brief-argv-pi-z4
  pass "a pi crewmate launch carries the brief's path, never its body"
}

test_grok_launch_keeps_the_brief_off_argv() {
  spawn_case_and_assert grok-ship grok brief-argv-grok-z5
  pass "a grok crewmate launch carries the brief's path, never its body"
}

# The secondmate templates are separate strings in launch_template(), so a fix
# applied to the crewmate shapes alone would leave a charter on the process table.
test_secondmate_launches_keep_the_charter_off_argv() {
  spawn_case_and_assert claude-secondmate claude brief-argv-sm-claude-z6 --secondmate
  spawn_case_and_assert codex-secondmate codex brief-argv-sm-codex-z7 --secondmate
  spawn_case_and_assert pi-secondmate pi brief-argv-sm-pi-z8 --secondmate
  pass "secondmate launches carry the charter's path, never its body"
}

# Pi already set a brief-PATH environment variable while the whole encoded brief
# still rode the same command line. That half-converted shape reads as done and is
# not, so it gets its own assertion rather than being trusted to the generic one.
test_pi_brief_path_binding_is_not_mistaken_for_the_fix() {
  local rec id out status launch argv
  id='brief-argv-pi-halfway-z9'
  rec=$(make_case pi-halfway pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF='" \
    "pi launch lost the Calm-mode brief-path binding"
  argv=$(expand_launch_argv "$launch" "$FAKEBIN_DIR" "$CASE_DIR/argv.log")
  case "$argv" in
    *"$BRIEF_SENTINEL"*)
      fail "pi sets a brief-path variable AND still puts the brief body on the command line" ;;
  esac
  pass "pi's brief-path binding coexists with a body that never reaches argv"
}

# The source-level backstop for the shapes that reintroduce the leak. The argv
# assertions above catch any covered harness; this catches the intent directly, so
# a reviewer reading the diff sees the rule as well as its consequence.
test_no_launch_template_reads_the_brief_into_the_command() {
  local templates
  templates=$(sed -n '/^launch_template() {/,/^}/p' "$SPAWN")
  [ -n "$templates" ] || fail "could not locate launch_template() in $SPAWN"
  case "$templates" in
    *'encode launch-brief < __BRIEF__'*)
      fail "a launch template composes the brief body into the command again" ;;
  esac
  case "$templates" in
    *'cat __BRIEF__'*|*'cat < __BRIEF__'*)
      fail "a launch template cats the brief into the command" ;;
  esac
  assert_contains "$templates" 'launch-pointer __BRIEF__' \
    "launch templates no longer build the brief pointer through the canonical owner"
  pass "no launch template reads the brief file into the command it sends"
}

# Coverage gate: a harness added to launch_template() without a case above would
# otherwise ship unmeasured under a suite that still reports all green.
test_every_launch_template_is_covered() {
  local templates line harness missing=
  templates=$(sed -n '/^launch_template() {/,/^}/p' "$SPAWN")
  # Each adapter is a `<name>)` or `<name>|<name>)` case label inside the function.
  while IFS= read -r line; do
    harness=${line%%)*}
    harness=${harness#"${harness%%[![:space:]]*}"}
    case "$harness" in
      ''|'*'|'#'*|*' '*|*'$'*) continue ;;
    esac
    case " $COVERED_HARNESSES " in
      *" $harness "*) ;;
      *) missing="$missing $harness" ;;
    esac
  done <<EOF
$(printf '%s\n' "$templates" | grep -E '^[[:space:]]{4}[a-z|]+\)')
EOF
  [ -z "$missing" ] || fail "launch templates with no brief-off-argv case:$missing"
  pass "every harness launch_template() accepts is exercised by a brief-off-argv case"
}

test_claude_launch_keeps_the_brief_off_argv
test_codex_launch_keeps_the_brief_off_argv
test_opencode_launch_keeps_the_brief_off_argv
test_pi_launch_keeps_the_brief_off_argv
test_grok_launch_keeps_the_brief_off_argv
test_secondmate_launches_keep_the_charter_off_argv
test_pi_brief_path_binding_is_not_mistaken_for_the_fix
test_no_launch_template_reads_the_brief_into_the_command
test_every_launch_template_is_covered
