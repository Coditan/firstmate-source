#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-dispatch-profile

CODEX_CREW_NETWORK_FLAG='-c '\''sandbox_workspace_write.network_access=true'\'''
CODEX_SECONDMATE_PROFILE_FLAGS='-c '\''sandbox_mode="workspace-write"'\'' -c '\''approval_policy="on-request"'\'' -c '\''approvals_reviewer="auto_review"'\'''

codex_signal_root_flag() {  # <task-id>
  printf -- "-c 'sandbox_workspace_write.writable_roots=[\"%s/state/.crew-signal/%s\"]'" "$HOME_DIR" "$1"
}

# The crewmate form of the same flag: the per-task signal directory AND the git
# common directory of the worktree the spawn is launched into. Resolved here the
# way fm-spawn resolves it - from the worktree, canonicalized - rather than by
# rebuilding "$PROJ_DIR/.git", so a test that passes proves the script asked git
# rather than proving both sides string-build the same guess.
codex_resolved_git_common_dir() {  # <worktree>
  local wt=$1 common
  common=$(git -C "$wt" rev-parse --git-common-dir) \
    || fail "test setup: $wt has no resolvable git common directory"
  (cd "$wt" && cd "$common" && pwd -P) \
    || fail "test setup: could not canonicalize the git common directory of $wt"
}

codex_crew_roots_flag() {  # <task-id> <worktree>
  printf -- "-c 'sandbox_workspace_write.writable_roots=[\"%s/state/.crew-signal/%s\", \"%s\"]'" \
    "$HOME_DIR" "$1" "$(codex_resolved_git_common_dir "$2")"
}

# The composed writable_roots array, one root per line. A substring assertion on the
# launch line cannot answer "is the working tree a root?", because the granted git
# directory has the working tree's path as its prefix; reading the array as a list can.
codex_launch_writable_roots() {  # <launch-line>
  printf '%s\n' "$1" \
    | sed -n 's/.*sandbox_workspace_write\.writable_roots=\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' \
    | sed '/^$/d'
}

assert_root_present() {  # <roots> <root> <msg>
  printf '%s\n' "$1" | grep -qxF "$2" \
    || fail "$3 (missing root: '$2')"$'\n'"--- roots ---"$'\n'"$1"
}

assert_root_absent() {  # <roots> <root> <msg>
  printf '%s\n' "$1" | grep -qxF "$2" \
    && fail "$3 (unexpected root: '$2')"$'\n'"--- roots ---"$'\n'"$1"
  return 0
}

codex_secondmate_profile_flags_for_id() {  # <task-id>
  printf '%s %s' "$CODEX_SECONDMATE_PROFILE_FLAGS" "$(codex_signal_root_flag "$1")"
}

# Defaults to the case's $WT_DIR, which is the worktree run_spawn hands the fake
# pane; a case that launches into a different worktree passes it explicitly.
codex_crewmate_profile_flags_for_id() {  # <task-id> [worktree]
  printf '%s %s %s' "$CODEX_SECONDMATE_PROFILE_FLAGS" \
    "$(codex_crew_roots_flag "$1" "${2:-$WT_DIR}")" "$CODEX_CREW_NETWORK_FLAG"
}

assert_codex_signal_paths() {  # <task-id>
  local id=$1 status_link turn_link probe
  [ -d "$HOME_DIR/state/.crew-signal/$id" ] \
    || fail "codex spawn did not create the per-task signal directory for $id"
  [ -L "$HOME_DIR/state/$id.status" ] \
    || fail "codex spawn did not make state/$id.status a public signal symlink"
  [ -L "$HOME_DIR/state/$id.turn-ended" ] \
    || fail "codex spawn did not make state/$id.turn-ended a public signal symlink"
  status_link=$(readlink "$HOME_DIR/state/$id.status")
  turn_link=$(readlink "$HOME_DIR/state/$id.turn-ended")
  [ "$status_link" = ".crew-signal/$id/status" ] \
    || fail "state/$id.status points to $status_link, not .crew-signal/$id/status"
  [ "$turn_link" = ".crew-signal/$id/turn-ended" ] \
    || fail "state/$id.turn-ended points to $turn_link, not .crew-signal/$id/turn-ended"
  [ -f "$HOME_DIR/state/$id.status" ] \
    || fail "state/$id.status does not have a live private signal target"
  [ -f "$HOME_DIR/state/$id.turn-ended" ] \
    || fail "state/$id.turn-ended does not have a live private signal target"
  probe="done: public append reached private signal target for $id"
  printf '%s\n' "$probe" >> "$HOME_DIR/state/$id.status"
  [ "$(tail -n 1 "$HOME_DIR/state/.crew-signal/$id/status")" = "$probe" ] \
    || fail "append through state/$id.status did not land in state/.crew-signal/$id/status"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
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
  new-window)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG.newwindow"
    fi
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        case "$a" in
          'export PATH='*) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG.path" ;;
        esac
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
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
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# Every case pins the host-sandbox probe rather than inheriting the real host, so
# the whole suite's workspace-write expectations state "on a host whose sandbox
# starts" instead of quietly meaning "on whatever host CI happens to run on" - the
# machine this was written on fails that probe, and an unpinned suite would have
# read its degraded launch line as the shipped one. A case that wants the other
# host shape exports FM_CODEX_SANDBOX_PROBE around its own call; a case that wants
# the real probe taken against its own fake uname/unshare exports it empty.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_CODEX_SANDBOX_PROBE="${FM_CODEX_SANDBOX_PROBE-yes}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

assert_tracked_codex_profile_omits_dynamic_launch_grants() {
  local file=$1 rc
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to parse the tracked Codex profile"
  python3 - "$file" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(2)

with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)

workspace = config.get("sandbox_workspace_write")
if isinstance(workspace, dict):
    if workspace.get("network_access") is not None:
        sys.exit(1)
    if workspace.get("writable_roots") is not None:
        sys.exit(1)
sys.exit(0)
PY
  rc=$?
  case "$rc" in
    0) ;;
    1) fail "tracked Codex profile carries dynamic crewmate launch grants" ;;
    2) fail "python3 tomllib is required to parse the tracked Codex profile" ;;
    *) fail "tracked Codex profile did not parse as TOML" ;;
  esac
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="FM_HOME='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --settings '$WT_DIR/.claude/settings.fm-task.json' \"\$('${ROOT}/bin/fm-operational-input.sh' launch-pointer '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_grep "export PATH='$HOME_DIR/.local/axi/bin':\$PATH" "$LAUNCH_LOG.path" \
    "ordinary crew did not receive the owning vessel's AXI bin first"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_claude_hook_preserves_repo_local_settings() {
  local rec id out status launch local_settings overlay exclude
  id=profile-claude-overlay-z1
  rec=$(make_spawn_case profile-claude-overlay claude "$id")
  read_case_record "$rec"
  local_settings="$WT_DIR/.claude/settings.local.json"
  overlay="$WT_DIR/.claude/settings.fm-task.json"
  mkdir -p "$WT_DIR/.claude"
  printf '%s\n' '{"permissions":{"allow":["Bash(git status:*)"]}}' > "$local_settings"
  git -C "$WT_DIR" add .claude/settings.local.json
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -q -m "track repository-local Claude settings"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude spawn with tracked local settings should succeed"
  [ "$(cat "$local_settings")" = '{"permissions":{"allow":["Bash(git status:*)"]}}' ] \
    || fail "Claude spawn truncated the repository's tracked settings.local.json"
  [ -f "$overlay" ] || fail "Claude spawn did not write the distinct per-task settings overlay"
  assert_grep '"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch ' "$overlay" \
    "Claude per-task settings overlay does not contain the Stop hook"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--settings '$overlay'" \
    "Claude launch did not explicitly load the per-task settings overlay"
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep '.claude/settings.fm-task.json' "$exclude" \
    "Claude per-task settings overlay is not excluded from git"
  pass "Claude spawn preserves tracked local settings and explicitly loads the distinct hook overlay"
}

# fm-spawn writes the per-task Claude settings overlay only when KIND != secondmate,
# so the secondmate launch line must NOT carry --settings for it: the flag would name
# a file that is never written and Claude would fail to start. This pins the pairing
# from the other side of the branch, the way the codex and pi templates are pinned.
test_secondmate_claude_launch_omits_the_task_overlay() {
  local rec id sm out status launch
  id=secondmate-claude-overlay-z19
  rec=$(make_spawn_case secondmate-claude-overlay claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate claude spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" "secondmate launch did not resolve claude"
  assert_absent "$sm/.claude/settings.fm-task.json" \
    "spawn wrote a per-task Claude overlay for a secondmate"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *--settings*) fail "secondmate claude launch passes --settings for an overlay spawn never writes"$'\n'"actual: $launch" ;;
  esac
  assert_grep "export PATH='$sm/.local/axi/bin':\$PATH" "$LAUNCH_LOG.path" \
    "secondmate launch did not receive its own home's AXI bin first"
  assert_no_grep "$HOME_DIR/.local/axi/bin" "$LAUNCH_LOG.path" \
    "secondmate launch inherited the primary vessel's AXI bin as its first entry"
  pass "a secondmate claude launch omits --settings because no per-task overlay is written"
}

# An ordinary crewmate or scout is launched by a home too, and it must be told
# which one - not only a secondmate. Two distinct places carry it, and the second
# is not a belt-and-braces copy of the first:
#
#   1. the task surface's environment, seeded when the window is CREATED. An
#      operator shell profile that derives per-vessel values from FM_HOME runs
#      once, when that shell starts, and nothing re-derives them afterwards. A
#      home announced after the shell exists is a home announced too late, and
#      the profile's own fallback - on a machine with two firstmate homes under
#      one OS account, another vessel entirely - is what the worker then acts as.
#   2. the launch command, which is what reaches the agent process on every
#      backend, including those whose task-creation call has no environment seam.
#
# The operational overrides stay uncleared: only a secondmate spawn needs that,
# because only there do they name a different home's directories.
test_ordinary_crew_launch_names_its_own_home() {
  local rec id out status launch
  id=crew-home-z20
  rec=$(make_spawn_case crew-home claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ordinary crew spawn should succeed"
  assert_grep "FM_HOME=$HOME_DIR" "$LAUNCH_LOG.newwindow" \
    "the crew window was created without its own home in the environment its shell starts with"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "FM_HOME='$HOME_DIR' "*) ;;
    *) fail "ordinary crew launch did not name its own firstmate home"$'\n'"actual: $launch" ;;
  esac
  assert_not_contains "$launch" "FM_STATE_OVERRIDE=" \
    "ordinary crew launch cleared the operational overrides a secondmate spawn owns"
  pass "an ordinary crew launch names the home that spawned it, before its shell starts and on the launch command"
}

# The same seeding for a secondmate names the SECONDMATE's home, never the
# primary's: it is the primary's own fm-spawn process creating a window for a
# different home, so the process environment it would otherwise pass down is the
# wrong answer at exactly the moment the new shell reads it.
test_secondmate_window_is_created_in_its_own_home() {
  local rec id sm out status
  id=secondmate-window-home-z21
  rec=$(make_spawn_case secondmate-window-home claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed"
  assert_grep "FM_HOME=$sm" "$LAUNCH_LOG.newwindow" \
    "the secondmate window was not created in the secondmate's own home"
  assert_no_grep "FM_HOME=$HOME_DIR" "$LAUNCH_LOG.newwindow" \
    "the secondmate window was created carrying the primary's home"
  pass "a secondmate window is created in the secondmate's own home, not the primary's"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch expected_flags
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_crewmate_profile_flags_for_id "$id")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' $expected_flags" \
    "explicit harness launch did not thread model and effort"
  assert_codex_signal_paths "$id"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" \
    "codex profile overrides would be inert under the dangerous bypass flag"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_codex_signal_paths "$id"
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "FM_HOME='$HOME_DIR' custom-agent --flag" ] \
    || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_raw_claude_launch_loads_the_task_overlay() {
  local rec id out status launch overlay
  id=raw-claude-overlay-z16
  rec=$(make_spawn_case raw-claude-overlay claude "$id")
  read_case_record "$rec"
  overlay="$WT_DIR/.claude/settings.fm-task.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "FOO=1 claude --dangerously-skip-permissions")
  status=$?
  expect_code 0 "$status" "raw claude launch command should succeed"
  [ -f "$overlay" ] || fail "raw claude launch did not write the per-task settings overlay"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "FM_HOME='$HOME_DIR' FOO=1 claude --settings '$overlay' --dangerously-skip-permissions" ] \
    || fail "raw claude launch did not load the per-task settings overlay"$'\n'"actual: $launch"
  pass "a raw claude launch command loads the per-task hook overlay it is given"
}

test_raw_claude_launch_with_own_settings_writes_no_overlay() {
  local rec id out status launch
  id=raw-claude-own-settings-z17
  rec=$(make_spawn_case raw-claude-own-settings claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude --settings /tmp/captain-settings.json")
  status=$?
  expect_code 0 "$status" "raw claude launch with its own --settings should succeed"
  assert_absent "$WT_DIR/.claude/settings.fm-task.json" \
    "spawn wrote a per-task overlay the launch command would never load"
  assert_contains "$out" "turn-end hook was NOT installed" \
    "spawn did not warn that the turn-end hook is unarmed"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "FM_HOME='$HOME_DIR' claude --settings /tmp/captain-settings.json" ] \
    || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "a raw claude command carrying its own --settings warns instead of writing a dead hook"
}

test_raw_claude_shaped_wrapper_gets_no_settings_flag() {
  local rec id out status launch
  id=raw-claude-wrapper-z18
  rec=$(make_spawn_case raw-claude-wrapper claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude-yolo --dangerously-skip-permissions")
  status=$?
  expect_code 0 "$status" "raw claude-shaped wrapper launch should succeed"
  assert_absent "$WT_DIR/.claude/settings.fm-task.json" \
    "spawn wrote a per-task overlay the wrapper would never load"
  assert_contains "$out" "turn-end hook was NOT installed" \
    "spawn did not warn that the wrapper's turn-end hook is unarmed"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "FM_HOME='$HOME_DIR' claude-yolo --dangerously-skip-permissions" ] \
    || fail "spawn spliced flags into a claude-shaped wrapper command"$'\n'"actual: $launch"
  pass "a claude-shaped wrapper keeps its own argv and degrades with a warning"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --settings '$WT_DIR/.claude/settings.fm-task.json' --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch expected_flags
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_crewmate_profile_flags_for_id "$id")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' $expected_flags" \
    "codex launch did not thread model, reasoning effort, and profile config"
  assert_codex_signal_paths "$id"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" \
    "codex launch must not bypass the profile-driven sandbox and approval policy"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_signal_setup_migrates_existing_status_log() {
  local rec id out status expected
  id=profile-codex-migrate-z3
  rec=$(make_spawn_case profile-codex-migrate codex "$id")
  read_case_record "$rec"
  expected="working: existing event before codex respawn"
  printf '%s\n' "$expected" > "$HOME_DIR/state/$id.status"

  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1); status=$?
  set -e

  expect_code 0 "$status" "codex spawn should migrate an existing public status log"
  assert_codex_signal_paths "$id"
  [ "$(head -n 1 "$HOME_DIR/state/.crew-signal/$id/status")" = "$expected" ] \
    || fail "existing public status log was not preserved in the private signal target"
  assert_contains "$out" "spawned $id harness=codex" "codex migration spawn did not report success"
  pass "codex signal setup migrates an existing public status log without truncating it"
}

test_codex_omits_out_of_range_max_effort() {
  local rec id out status launch expected_flags
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with out-of-range max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_crewmate_profile_flags_for_id "$id")
  assert_contains "$launch" "codex --model 'gpt-5' $expected_flags" \
    "codex launch did not preserve the model flag and profile config when max effort was omitted"
  assert_codex_signal_paths "$id"
  assert_not_contains "$launch" "model_reasoning_effort" \
    "codex launch must omit max reasoning effort, which is above firstmate's codex ceiling of xhigh"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" \
    "codex launch must not bypass the profile-driven sandbox and approval policy"
  pass "codex omits max effort because firstmate's validators cap codex at xhigh"
}

# Codex classes a unix-socket connect as network access, not filesystem access, so a
# Codex crewmate under a plain workspace-write sandbox is refused the local
# no-mistakes daemon socket and every Codex-dispatched pipeline ship task stalls at
# the gate (docs/codex-sandbox-network.md). These three tests pin the grant from all
# three sides so a later edit can neither silently drop it nor silently widen it:
# a crewmate must carry it, a secondmate must not, and no other harness may acquire it.
test_codex_crewmate_carries_the_pipeline_socket_network_grant() {
  local rec ship scout out status launch expected_flags
  ship=profile-codex-net-ship-z20
  scout=profile-codex-net-scout-z20
  rec=$(make_spawn_case profile-codex-net codex "$ship" "$scout")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ship" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$CODEX_CREW_NETWORK_FLAG" \
    "codex ship launch dropped the sandbox network grant that reaches the no-mistakes daemon socket"
  expected_flags=$(codex_crewmate_profile_flags_for_id "$ship")
  assert_contains "$launch" "$expected_flags" \
    "codex ship launch did not compose the network grant alongside the rest of the profile"
  assert_codex_signal_paths "$ship"
  assert_not_contains "$launch" "writable_roots=[\"$HOME_DIR/state\"]" \
    "codex ship launch widened the filesystem grant to the whole state directory"
  assert_not_contains "$launch" "danger-full-access" \
    "the network grant must not be delivered by widening the whole sandbox"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" \
    "the network grant must not be delivered by bypassing the sandbox"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$scout" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "codex scout spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$CODEX_CREW_NETWORK_FLAG" \
    "codex scout launch dropped the sandbox network grant a crewmate is entitled to"
  expected_flags=$(codex_crewmate_profile_flags_for_id "$scout")
  assert_contains "$launch" "$expected_flags" \
    "codex scout launch did not compose the per-task signal root alongside the rest of the profile"
  assert_codex_signal_paths "$scout"
  assert_not_contains "$launch" "writable_roots=[\"$HOME_DIR/state\"]" \
    "codex scout launch widened the filesystem grant to the whole state directory"
  pass "a codex crewmate launch carries the sandbox network grant that reaches the pipeline socket"
}

# A secondmate is a supervising firstmate home rather than a pipeline worker: it routes
# work, and its own crewmates pick the grant up from its own call into the same path.
# Pinning the omission here is what stops the grant from creeping outward to a
# supervising session the next time this branch is edited.
test_codex_secondmate_does_not_carry_the_crewmate_network_grant() {
  local rec id sm out status launch expected_flags roots count
  id=secondmate-codex-net-z21
  rec=$(make_spawn_case secondmate-codex-net codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate codex spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not resolve codex"
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_secondmate_profile_flags_for_id "$id")
  assert_contains "$launch" "$expected_flags" \
    "secondmate codex launch lost the sandbox, approval, and reviewer profile overrides"
  assert_codex_signal_paths "$id"
  assert_not_contains "$launch" "writable_roots=[\"$HOME_DIR/state\"]" \
    "secondmate codex launch widened the filesystem grant to the whole state directory"
  assert_not_contains "$launch" "network_access" \
    "the crewmate network grant widened to a secondmate, which supervises rather than runs the pipeline"
  # The same reasoning excludes a secondmate from the git-directory grant, and its
  # blast radius there is wider than a crewmate's: a secondmate home is a worktree of
  # the FIRSTMATE repository, so its common directory is the primary checkout's own
  # git directory. It ships nothing from that home, so it needs no ref write there.
  roots=$(codex_launch_writable_roots "$launch")
  count=$(printf '%s\n' "$roots" | wc -l | tr -d ' ')
  [ "$count" = 1 ] \
    || fail "secondmate codex launch carries $count writable roots, not the signal root alone"$'\n'"--- roots ---"$'\n'"$roots"
  assert_root_present "$roots" "$HOME_DIR/state/.crew-signal/$id" \
    "secondmate codex launch lost its per-task signal root"
  pass "a codex secondmate launch omits the crewmate-only network and git-directory grants"
}

# A Codex crewmate works in a linked worktree whose refs live in the project's
# PRIMARY checkout, so the first ref write a ship task makes - creating its branch -
# lands outside the workspace and outside the signal root. These four tests pin the
# second writable root that closes that: it names the git common directory, it never
# names the working tree, a plain clone gets no second root at all, and a worktree
# whose common directory cannot be resolved refuses the launch instead of quietly
# composing the pre-grant line.
test_codex_crewmate_can_write_its_worktree_refs() {
  local rec id out status launch expected_flags roots common
  id=profile-codex-refs-z23
  rec=$(make_spawn_case profile-codex-refs codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_crewmate_profile_flags_for_id "$id")
  assert_contains "$launch" "$expected_flags" \
    "codex ship launch did not grant the worktree's git common directory alongside the signal root"
  common=$(codex_resolved_git_common_dir "$WT_DIR")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$common" \
    "codex ship launch does not name the git common directory its ref writes land in"
  pass "a codex crewmate launch grants the git common directory its branch creation writes"
}

# The prohibition this grant must not retire: hard rule 1 in AGENTS.md, and the
# spawn-time isolation assertion, both rest on a worker being unable to write into
# projects/<name>/. Granting <project>/.git must leave the working tree that contains
# it ungranted, which no substring assertion on the launch line can show - the
# project path is a prefix of the granted one - so this reads the roots as a list.
test_codex_crewmate_is_not_granted_the_project_working_tree() {
  local rec id out status launch roots proj_real wt_real
  id=profile-codex-tree-z24
  rec=$(make_spawn_case profile-codex-tree codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  proj_real=$(cd "$PROJ_DIR" && pwd -P)
  wt_real=$(cd "$WT_DIR" && pwd -P)
  assert_root_absent "$roots" "$proj_real" \
    "codex ship launch made the project working tree a writable root"
  assert_root_absent "$roots" "$wt_real" \
    "codex ship launch named the worktree itself as a writable root"
  pass "the git-directory grant leaves the project working tree ungranted"
}

# A plain clone keeps its common directory inside its own working tree, which
# workspace-write already covers. Emitting it anyway would put a redundant second
# element in the array; emitting it wrongly could put a malformed one there.
test_codex_plain_clone_gets_no_second_writable_root() {
  local rec id plain out status launch roots count
  id=profile-codex-plain-z25
  rec=$(make_spawn_case profile-codex-plain codex "$id")
  read_case_record "$rec"
  plain="$CASE_DIR/plain-clone"
  fm_git_init_commit "$plain"

  out=$(run_spawn "$HOME_DIR" "$plain" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn into a plain clone should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$(codex_signal_root_flag "$id")" \
    "a plain-clone codex launch lost the per-task signal root"
  roots=$(codex_launch_writable_roots "$launch")
  count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 1 ] \
    || fail "a plain clone produced $count writable roots, not the signal root alone"$'\n'"--- roots ---"$'\n'"$roots"
  assert_root_absent "$roots" "$(cd "$plain" && pwd -P)/.git" \
    "a plain clone was granted its own git directory a second time"
  pass "a plain clone adds no second writable root and no duplicate"
}

# Unresolvable must refuse. Emitting no second root would restore the pre-grant
# behaviour - every ref write escalating to the approval reviewer - with nothing on
# the launch line or in the output to say the grant was dropped.
test_codex_unresolvable_common_dir_refuses_the_launch() {
  local rec id real_git out status
  id=profile-codex-nocommon-z26
  rec=$(make_spawn_case profile-codex-nocommon codex "$id")
  read_case_record "$rec"
  real_git=$(command -v git) || fail "test setup: no git on PATH"
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "--git-common-dir" ] && exit 1
done
exec $real_git "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"

  # The same set +e/set -e wrapper test_codex_signal_setup_migrates_existing_status_log
  # uses: a nonzero spawn is this test's expected result, not its failure.
  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite an unresolvable git common directory"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "could not resolve the git common directory" \
    "the refusal did not name the unresolvable git common directory"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "codex spawn composed a launch line after refusing the grant"$'\n'"$(cat "$LAUNCH_LOG")"
  pass "an unresolvable git common directory refuses the launch instead of silently dropping the grant"
}

# Point a fixture repository at a bare gate the way `no-mistakes init` does, so the
# spawn resolves the grant from the same effective push destination a real push uses.
# Returns the physically resolved gate path, which is what the launch line must name.
fm_fixture_gate_repo() {  # <repo> <gate-dir>
  local repo=$1 gate=$2
  git init -q --bare "$gate" || fail "test setup: could not create the fixture gate at $gate"
  git -C "$repo" remote add no-mistakes "$gate" \
    || fail "test setup: could not point $repo at the fixture gate"
  (cd "$gate" && pwd -P) || fail "test setup: could not canonicalize $gate"
}

# A gate push runs git-receive-pack as the PUSHING process, so the quarantine
# directory it creates under the gate's objects/ is created by the sandboxed crewmate
# and refused: every Codex-dispatched pipeline ship task dies there
# (docs/codex-sandbox-gate-repo.md). These thirteen tests pin the third writable root from
# every side a later edit could break it from: a crewmate must carry it, it must name
# ONE gate and never the repos root that would reach every other project's gate, a
# push URL override must replace the fetch URL, a secondmate must not carry it even
# when one is resolvable, an ungated project must still launch, and a configured gate
# whose push destination is missing, multiple, non-bare, or does not resolve must refuse.
test_codex_crewmate_can_write_its_gate_repository() {
  local rec id gate out status launch roots
  id=profile-codex-gate-z27
  rec=$(make_spawn_case profile-codex-gate codex "$id")
  read_case_record "$rec"
  gate=$(fm_fixture_gate_repo "$PROJ_DIR" "$CASE_DIR/gate.git")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$gate" \
    "codex ship launch does not name the gate repository its pipeline push must write"
  assert_contains "$launch" "$CODEX_CREW_NETWORK_FLAG" \
    "the gate grant displaced the network grant that reaches the daemon socket"
  assert_root_present "$roots" "$HOME_DIR/state/.crew-signal/$id" \
    "the gate grant displaced the per-task signal root"
  assert_root_present "$roots" "$(codex_resolved_git_common_dir "$WT_DIR")" \
    "the gate grant displaced the git common directory root"
  assert_not_contains "$launch" "danger-full-access" \
    "the gate grant must not be delivered by widening the whole sandbox"
  assert_not_contains "$launch" "--dangerously-bypass-approvals-and-sandbox" \
    "the gate grant must not be delivered by bypassing the sandbox"
  pass "a codex crewmate launch grants the gate repository its pipeline push writes"
}

# The boundary this grant must draw in the capability, not only in the brief text.
# Granting the repos ROOT would work too, and would hand every crewmate write access
# to every other project's gate and to any gate created later; granting the daemon's
# own directory would reach the binary a crewmate is forbidden to touch. Measured:
# with one gate granted, a sibling gate and the daemon directory both stay refused.
test_codex_gate_grant_names_one_gate_not_the_repository_root() {
  local rec id gate out status launch roots repos_root
  id=profile-codex-gate-scope-z28
  rec=$(make_spawn_case profile-codex-gate-scope codex "$id")
  read_case_record "$rec"
  mkdir -p "$CASE_DIR/nm/repos"
  gate=$(fm_fixture_gate_repo "$PROJ_DIR" "$CASE_DIR/nm/repos/deadbeef.git")
  repos_root=$(cd "$CASE_DIR/nm/repos" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$gate" "codex ship launch lost its own gate root"
  assert_root_absent "$roots" "$repos_root" \
    "codex ship launch widened the gate grant to the repository root, reaching every other project's gate"
  assert_root_absent "$roots" "$(cd "$CASE_DIR/nm" && pwd -P)" \
    "codex ship launch widened the gate grant to the daemon's own data directory"
  pass "the gate grant names one project's gate, never the repository root or the daemon directory"
}

test_codex_gate_grant_uses_effective_push_destination() {
  local rec id fetch_gate push_gate out status launch roots
  id=profile-codex-gate-pushurl-z33
  rec=$(make_spawn_case profile-codex-gate-pushurl codex "$id")
  read_case_record "$rec"
  fetch_gate=$(fm_fixture_gate_repo "$PROJ_DIR" "$CASE_DIR/fetch-gate.git")
  git init -q --bare "$CASE_DIR/push-gate.git" \
    || fail "test setup: could not create the push fixture gate"
  git -C "$PROJ_DIR" config remote.no-mistakes.pushurl "$CASE_DIR/push-gate.git" \
    || fail "test setup: could not configure the fixture push URL"
  push_gate=$(cd "$CASE_DIR/push-gate.git" && pwd -P) \
    || fail "test setup: could not canonicalize the push fixture gate"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn with a push URL override should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$push_gate" \
    "codex ship launch does not grant the remote's effective push destination"
  assert_root_absent "$roots" "$fetch_gate" \
    "codex ship launch grants the fetch URL instead of the effective push destination"
  pass "the gate grant follows the remote's effective push destination"
}

test_codex_gate_grant_accepts_local_file_url() {
  local rec id gate out status launch roots
  id=profile-codex-gate-file-url-z37
  rec=$(make_spawn_case profile-codex-gate-file-url codex "$id")
  read_case_record "$rec"
  git init -q --bare "$CASE_DIR/file-url-gate.git" \
    || fail "test setup: could not create the file URL fixture gate"
  gate=$(cd "$CASE_DIR/file-url-gate.git" && pwd -P) \
    || fail "test setup: could not canonicalize the file URL fixture gate"
  git -C "$PROJ_DIR" remote add no-mistakes "file://$gate" \
    || fail "test setup: could not configure the local file URL gate"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn with a local file URL gate should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$gate" \
    "codex ship launch did not normalize the local file URL to its gate path"
  pass "a local file URL gate becomes its filesystem writable root"
}

test_codex_gate_grant_accepts_anchored_colon_path() {
  local rec id gate out status launch roots
  id=profile-codex-gate-colon-path-z38
  rec=$(make_spawn_case profile-codex-gate-colon-path codex "$id")
  read_case_record "$rec"
  git init -q --bare "$WT_DIR/name:gate.git" \
    || fail "test setup: could not create the anchored colon-path gate"
  gate=$(cd "$WT_DIR/name:gate.git" && pwd -P) \
    || fail "test setup: could not canonicalize the anchored colon-path gate"
  git -C "$PROJ_DIR" remote add no-mistakes "./name:gate.git" \
    || fail "test setup: could not configure the anchored colon-path gate"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn with an anchored colon-path gate should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_present "$roots" "$gate" \
    "codex ship launch rejected an explicitly anchored local path containing a colon"
  pass "an anchored colon-path gate remains a local writable root"
}

test_codex_scp_style_gate_destination_refuses_the_launch() {
  local rec id gate out status launch roots
  id=profile-codex-scp-gate-z39
  rec=$(make_spawn_case profile-codex-scp-gate codex "$id")
  read_case_record "$rec"
  git init -q --bare "$WT_DIR/host:gate.git" \
    || fail "test setup: could not create the matching scp-style fixture directory"
  gate=$(cd "$WT_DIR/host:gate.git" && pwd -P) \
    || fail "test setup: could not canonicalize the matching scp-style fixture directory"
  git -C "$PROJ_DIR" remote add no-mistakes "host:gate.git" \
    || fail "test setup: could not configure the scp-style gate destination"

  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite a scp-style gate destination"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "does not resolve to a directory" \
    "the refusal did not identify the scp-style gate as ungrantable"
  launch=$(cat "$LAUNCH_LOG")
  [ -z "$launch" ] \
    || fail "codex spawn composed a launch line after refusing the scp-style gate"$'\n'"$launch"
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_absent "$roots" "$gate" \
    "the scp-style destination granted its coincidentally matching local repository"
  pass "a scp-style gate cannot grant a matching local repository"
}

# A secondmate supervises rather than ships and runs no pipeline of its own, so it
# needs no gate root. Its home is given a resolvable gate here on purpose: a test
# whose fixture has no gate to find would pass without exercising the guard at all.
test_codex_secondmate_does_not_carry_the_gate_grant() {
  local rec id sm out status launch roots count
  id=secondmate-codex-gate-z29
  rec=$(make_spawn_case secondmate-codex-gate codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  fm_git_init_commit "$sm"
  make_seeded_secondmate_home "$sm" "$id"
  fm_fixture_gate_repo "$sm" "$CASE_DIR/secondmate-gate.git" > /dev/null

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate codex spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "gate.git" \
    "the crewmate-only gate grant widened to a secondmate, which runs no pipeline of its own"
  roots=$(codex_launch_writable_roots "$launch")
  count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 1 ] \
    || fail "secondmate codex launch carries $count writable roots, not the signal root alone"$'\n'"--- roots ---"$'\n'"$roots"
  assert_root_present "$roots" "$HOME_DIR/state/.crew-signal/$id" \
    "secondmate codex launch lost its per-task signal root"
  pass "a codex secondmate launch omits the crewmate-only gate grant"
}

# A project with no no-mistakes remote is not gated, so there is nothing to grant.
# That is the legitimate empty case, not a failure: refusing it would break every
# spawn into a project that has not been gated, which worked before this grant existed.
test_codex_ungated_project_gets_no_gate_root() {
  local rec id out status launch roots count
  id=profile-codex-ungated-z30
  rec=$(make_spawn_case profile-codex-ungated codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn into an ungated project should succeed"
  launch=$(cat "$LAUNCH_LOG")
  roots=$(codex_launch_writable_roots "$launch")
  count=$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 2 ] \
    || fail "an ungated project produced $count writable roots, not the signal and git-directory roots alone"$'\n'"--- roots ---"$'\n'"$roots"
  pass "a project with no gate configured adds no third writable root"
}

# Unresolvable must refuse. A configured gate remote means the worker WILL push
# there, so composing the launch line with the root silently dropped would strand it
# at the gate push with a message that names none of this.
test_codex_unresolvable_gate_repo_refuses_the_launch() {
  local rec id out status
  id=profile-codex-nogate-z31
  rec=$(make_spawn_case profile-codex-nogate codex "$id")
  read_case_record "$rec"
  git -C "$PROJ_DIR" remote add no-mistakes "$CASE_DIR/gate-that-does-not-exist.git" \
    || fail "test setup: could not point the fixture at a missing gate"

  # The same set +e/set -e wrapper the sibling refusal test uses: a nonzero spawn is
  # this test's expected result, not its failure.
  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite an unresolvable gate repository"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "does not resolve to a directory" \
    "the refusal did not name the unresolvable gate repository"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "codex spawn composed a launch line after refusing the gate grant"$'\n'"$(cat "$LAUNCH_LOG")"
  pass "an unresolvable gate repository refuses the launch instead of silently dropping the grant"
}

test_codex_configured_gate_without_push_destination_refuses_the_launch() {
  local rec id out status
  id=profile-codex-empty-gate-z34
  rec=$(make_spawn_case profile-codex-empty-gate codex "$id")
  read_case_record "$rec"
  git -C "$PROJ_DIR" config remote.no-mistakes.url "" \
    || fail "test setup: could not configure an empty gate URL"

  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite a configured gate with no push destination"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "does not resolve to a directory" \
    "the refusal did not name the configured gate's unresolvable push destination"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "codex spawn composed a launch line after effective push resolution failed"$'\n'"$(cat "$LAUNCH_LOG")"
  pass "a configured gate without an effective push destination refuses the launch"
}

test_codex_gate_with_multiple_push_destinations_refuses_the_launch() {
  local rec id gate_one gate_two out status launch
  id=profile-codex-multiple-gates-z35
  rec=$(make_spawn_case profile-codex-multiple-gates codex "$id")
  read_case_record "$rec"
  gate_one=$(fm_fixture_gate_repo "$PROJ_DIR" "$CASE_DIR/push-gate-one.git")
  git init -q --bare "$CASE_DIR/push-gate-two.git" \
    || fail "test setup: could not create the second push fixture gate"
  gate_two=$(cd "$CASE_DIR/push-gate-two.git" && pwd -P) \
    || fail "test setup: could not canonicalize the second push fixture gate"
  git -C "$PROJ_DIR" config --add remote.no-mistakes.pushurl "$gate_one" \
    || fail "test setup: could not configure the first push destination"
  git -C "$PROJ_DIR" config --add remote.no-mistakes.pushurl "$gate_two" \
    || fail "test setup: could not configure the second push destination"

  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite multiple effective push destinations"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "names 2 effective push destinations" \
    "the refusal did not name the worktree's multiple effective push destinations"
  launch=$(cat "$LAUNCH_LOG")
  [ -z "$launch" ] \
    || fail "codex spawn composed a launch line after refusing multiple gate destinations"$'\n'"$launch"
  assert_not_contains "$launch" "$gate_one" "the refused launch granted the first push destination"
  assert_not_contains "$launch" "$gate_two" "the refused launch granted the second push destination"
  pass "multiple effective gate push destinations refuse the launch"
}

test_codex_non_bare_gate_destination_refuses_the_launch() {
  local rec id out status launch roots worktree
  id=profile-codex-non-bare-gate-z36
  rec=$(make_spawn_case profile-codex-non-bare-gate codex "$id")
  read_case_record "$rec"
  worktree=$(cd "$PROJ_DIR" && pwd -P) \
    || fail "test setup: could not canonicalize the project working tree"
  git -C "$PROJ_DIR" remote add no-mistakes "$worktree" \
    || fail "test setup: could not point the fixture gate remote at its working tree"

  set +e
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  set -e

  [ "$status" != 0 ] \
    || fail "codex spawn launched despite a non-bare gate destination"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "is not a bare gate repository" \
    "the refusal did not identify the non-bare gate destination"
  launch=$(cat "$LAUNCH_LOG")
  [ -z "$launch" ] \
    || fail "codex spawn composed a launch line after refusing the non-bare gate"$'\n'"$launch"
  roots=$(codex_launch_writable_roots "$launch")
  assert_root_absent "$roots" "$worktree" \
    "the refused non-bare destination made the project working tree writable"
  pass "a non-bare gate destination cannot become a writable root"
}

# The gate grant lives entirely in the codex branch of the launch composition, like
# its two siblings. This fixture IS gated, so a claude launch that acquired anything
# would show it here; the harnesses the fleet runs today must be untouched.
test_non_codex_crewmate_acquires_no_gate_grant() {
  local rec id gate out status launch
  id=profile-claude-gate-z32
  rec=$(make_spawn_case profile-claude-gate claude "$id")
  read_case_record "$rec"
  gate=$(fm_fixture_gate_repo "$PROJ_DIR" "$CASE_DIR/gate.git")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn into a gated project should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "$gate" \
    "the codex gate grant leaked into a claude launch"
  assert_not_contains "$launch" "writable_roots" \
    "codex sandbox writable roots leaked into a claude launch"
  pass "a non-codex crewmate launch acquires no gate grant even in a gated project"
}

# The grant lives entirely in the codex branch of the launch composition. A claude
# crewmate's launch line is unchanged by it, which is what keeps this change from
# altering the behaviour of the harness the fleet runs today.
test_non_codex_crewmate_acquires_no_sandbox_network_grant() {
  local rec id out status launch
  id=profile-claude-net-z22
  rec=$(make_spawn_case profile-claude-net claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "network_access" \
    "the codex sandbox network grant leaked into a claude launch"
  assert_not_contains "$launch" "sandbox_workspace_write" \
    "codex sandbox profile overrides leaked into a claude launch"
  assert_absent "$HOME_DIR/state/.crew-signal/$id" \
    "non-codex spawn created a Codex signal directory"
  pass "a non-codex crewmate launch acquires no codex sandbox network grant"
}

# The grants have to stay on the launch line. Codex reads this repository's own
# .codex/config.toml as configuration for any Codex session running inside this
# trusted project - a supervising firstmate session included - so writing a grant
# into that file would widen it past crewmates however carefully the launch path
# above is gated. This is the widening the launch-line tests cannot see.
test_tracked_codex_profile_leaves_launch_grants_to_the_launch_line() {
  assert_tracked_codex_profile_omits_dynamic_launch_grants "$ROOT/.codex/config.toml"
  pass "the tracked Codex profile leaves dynamic grants to the launch line"
}

# The two host shapes for Codex's sandbox. On a host whose kernel refuses to start
# an unprivileged user namespace, every sandboxed command fails before it runs -
# including the worktree-isolation assertion a ship brief demands first, and
# including apply_patch, so such a worker cannot even edit a file. The launch
# degrades to danger-full-access there and says so; the shipped profile and every
# host whose sandbox starts are untouched (docs/codex-sandbox-unavailable.md).
test_codex_sandboxable_host_keeps_the_shipped_workspace_write() {
  local rec id out status launch
  id=profile-codex-sandbox-ok-z40
  rec=$(make_spawn_case profile-codex-sandbox-ok codex "$id")
  read_case_record "$rec"

  out=$(FM_CODEX_SANDBOX_PROBE=yes run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn on a sandboxable host should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-c 'sandbox_mode=\"workspace-write\"'" \
    "a host whose sandbox starts did not get the shipped workspace-write sandbox"
  assert_not_contains "$launch" 'danger-full-access' \
    "a host whose sandbox starts was launched unsandboxed anyway"
  assert_not_contains "$out" 'cannot start a sandbox' \
    "a host whose sandbox starts announced a degradation it did not take"
  pass "a host that can start a sandbox keeps workspace-write exactly as shipped"
}

test_codex_unsandboxable_host_launches_unsandboxed_and_says_so() {
  local rec id out status launch
  id=profile-codex-sandbox-blocked-z41
  rec=$(make_spawn_case profile-codex-sandbox-blocked codex "$id")
  read_case_record "$rec"

  out=$(FM_CODEX_SANDBOX_PROBE=no run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn on a host that cannot sandbox should still launch"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-c 'sandbox_mode=\"danger-full-access\"'" \
    "a host that cannot start a sandbox was still launched sandboxed, so its worker cannot run a command or edit a file"
  assert_not_contains "$launch" 'workspace-write"' \
    "the degraded launch still carries the sandbox mode the host cannot start"
  assert_contains "$launch" "-c 'approval_policy=\"on-request\"'" \
    "the degradation changed approval_policy, which is not host-conditional"
  assert_contains "$launch" "-c 'approvals_reviewer=\"auto_review\"'" \
    "the degradation changed approvals_reviewer, which is not host-conditional"
  assert_contains "$launch" "$CODEX_CREW_NETWORK_FLAG" \
    "the degraded launch dropped the crewmate network grant"
  assert_contains "$out" 'cannot start a sandbox' \
    "the degradation was silent; a weaker launch must announce itself"
  assert_contains "$(cat "$ROOT/.codex/config.toml")" 'sandbox_mode = "workspace-write"' \
    "the degradation rewrote the tracked profile that ships to every other host"
  pass "a host that cannot start a sandbox launches unsandboxed, announced, with the shipped profile untouched"
}

test_codex_unreadable_sandbox_probe_keeps_the_sandbox() {
  local rec id out status launch
  id=profile-codex-sandbox-unknown-z42
  rec=$(make_spawn_case profile-codex-sandbox-unknown codex "$id")
  read_case_record "$rec"

  out=$(FM_CODEX_SANDBOX_PROBE=unknown run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with an unreadable probe should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-c 'sandbox_mode=\"workspace-write\"'" \
    "a probe nobody could take bought a weaker launch"
  assert_contains "$out" 'could not test whether this host can start a sandbox' \
    "an unreadable probe passed silently as a healthy one"
  pass "a sandbox probe that could not be taken keeps the sandbox and says it could not be taken"
}

# Darwin has no unshare(1) and Codex sandboxes there through Seatbelt, so the user
# namespace probe does not apply: a Mac keeps the shipped sandbox with no probe taken
# and no notice, rather than announcing an unreadable probe on every spawn. The fake
# unshare here refuses, so a Linux reading of the same host would degrade - which is
# what proves the Darwin branch, not the pin, produced the shipped launch.
test_codex_darwin_host_keeps_the_sandbox_without_a_probe_or_a_notice() {
  local rec id out status launch
  id=profile-codex-sandbox-darwin-z43
  rec=$(make_spawn_case profile-codex-sandbox-darwin codex "$id")
  read_case_record "$rec"
  printf '#!/bin/sh\necho Darwin\n' > "$FAKEBIN_DIR/uname"
  printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN_DIR/unshare"
  chmod +x "$FAKEBIN_DIR/uname" "$FAKEBIN_DIR/unshare"

  out=$(FM_CODEX_SANDBOX_PROBE='' run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn on a Darwin host should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-c 'sandbox_mode=\"workspace-write\"'" \
    "a Darwin host did not keep the shipped workspace-write sandbox"
  assert_not_contains "$launch" 'danger-full-access' \
    "a Darwin host was degraded on a Linux-only probe it never needed"
  assert_not_contains "$out" 'could not test whether this host can start a sandbox' \
    "a Darwin host announced an unreadable probe that does not apply to it"
  assert_not_contains "$out" 'cannot start a sandbox' \
    "a Darwin host announced a degradation it did not take"
  pass "a Darwin host keeps workspace-write with no probe taken and no notice"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' launch-pointer " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' launch-pointer " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  assert_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF='" \
    "pi launch did not retain its legacy positional-brief source binding for Calm"
  pass "pi receives --model and --thinking max profile flags"
}

test_quota_selected_default_array_reaches_spawn() {
  local rec id quota random selected diagnostic harness model effort out status launch expected_flags
  id=profile-selected-default-z17
  rec=$(make_spawn_case profile-selected-default claude "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"default":[{"harness":"claude","model":"claude-sonnet-5","effort":"low"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}
JSON
  quota="$CASE_DIR/quota.json"
  random="$CASE_DIR/random"
  printf '\000\000\000\000' > "$random"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":10}]},{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90}]}]}
JSON

  selected=$(FM_DISPATCH_RANDOM_SOURCE="$random" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    "$(jq -c .default "$HOME_DIR/config/crew-dispatch.json")" 2>"$CASE_DIR/selection.err")
  diagnostic=$(cat "$CASE_DIR/selection.err")
  harness=$(printf '%s\n' "$selected" | jq -r .harness)
  model=$(printf '%s\n' "$selected" | jq -r .model)
  effort=$(printf '%s\n' "$selected" | jq -r .effort)
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness "$harness" --model "$model" --effort "$effort")
  status=$?

  expect_code 0 "$status" "quota-selected default-array profile should reach spawn"
  assert_contains "$diagnostic" "selection basis: quota-selected" "selection did not expose its quota basis"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5.5 high
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_crewmate_profile_flags_for_id "$id")
  assert_contains "$launch" "codex --model 'gpt-5.5' -c 'model_reasoning_effort=\"high\"' $expected_flags" \
    "quota-selected default profile did not reach the concrete launch"
  assert_codex_signal_paths "$id"
  pass "top-level default array resolves through quota selection into the real spawn path"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_codex_signal_paths "$id1"
  assert_codex_signal_paths "$id2"
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status launch expected_flags
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  launch=$(cat "$LAUNCH_LOG")
  expected_flags=$(codex_secondmate_profile_flags_for_id "$id")
  assert_contains "$launch" "$expected_flags" \
    "profile-exempt secondmate codex launch did not carry the per-task signal root"
  assert_not_contains "$launch" "network_access" \
    "profile-exempt secondmate codex launch picked up the crewmate-only network grant"
  assert_codex_signal_paths "$id"
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_profile_defaults
test_claude_hook_preserves_repo_local_settings
test_secondmate_claude_launch_omits_the_task_overlay
test_ordinary_crew_launch_names_its_own_home
test_secondmate_window_is_created_in_its_own_home
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_raw_claude_launch_loads_the_task_overlay
test_raw_claude_launch_with_own_settings_writes_no_overlay
test_raw_claude_shaped_wrapper_gets_no_settings_flag
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_signal_setup_migrates_existing_status_log
test_codex_omits_out_of_range_max_effort
test_codex_crewmate_carries_the_pipeline_socket_network_grant
test_codex_secondmate_does_not_carry_the_crewmate_network_grant
test_codex_crewmate_can_write_its_worktree_refs
test_codex_crewmate_is_not_granted_the_project_working_tree
test_codex_plain_clone_gets_no_second_writable_root
test_codex_unresolvable_common_dir_refuses_the_launch
test_codex_crewmate_can_write_its_gate_repository
test_codex_gate_grant_names_one_gate_not_the_repository_root
test_codex_gate_grant_uses_effective_push_destination
test_codex_gate_grant_accepts_local_file_url
test_codex_gate_grant_accepts_anchored_colon_path
test_codex_scp_style_gate_destination_refuses_the_launch
test_codex_secondmate_does_not_carry_the_gate_grant
test_codex_ungated_project_gets_no_gate_root
test_codex_unresolvable_gate_repo_refuses_the_launch
test_codex_configured_gate_without_push_destination_refuses_the_launch
test_codex_gate_with_multiple_push_destinations_refuses_the_launch
test_codex_non_bare_gate_destination_refuses_the_launch
test_non_codex_crewmate_acquires_no_gate_grant
test_non_codex_crewmate_acquires_no_sandbox_network_grant
test_tracked_codex_profile_leaves_launch_grants_to_the_launch_line
test_codex_sandboxable_host_keeps_the_shipped_workspace_write
test_codex_unsandboxable_host_launches_unsandboxed_and_says_so
test_codex_unreadable_sandbox_probe_keeps_the_sandbox
test_codex_darwin_host_keeps_the_sandbox_without_a_probe_or_a_notice
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_quota_selected_default_array_reaches_spawn
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
