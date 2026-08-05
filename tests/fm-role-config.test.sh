#!/usr/bin/env bash
# Behavior tests for the role-as-config mechanism: a fleet role is a local,
# gitignored config/role selector over one shared tracked code root, delivered
# as a roles/<name>.md amendment to AGENTS.md.
#
# The guarantees under test:
#   - Resolution (bin/fm-role-lib.sh): absent file and blank file both mean the
#     default `vessel`; the value is the first non-empty line with whitespace
#     stripped; the default and unrecognized values have no overlay path by
#     contract.
#   - NO BEHAVIOR CHANGE for a home with no config/role file. Proven, not
#     asserted: bootstrap's detect output and the session digest's CONTEXT
#     section are byte-identical with the file absent and with an explicit
#     `vessel`, neither mentions a role at all, and CONTEXT still carries
#     exactly the five pre-existing per-home records in their original order.
#   - Both delivery seams carry a selected role: the session digest prints the
#     overlay at the head of CONTEXT, and AGENTS.md carries the load line that
#     survives context compaction.
#   - An unrecognized value is a loud bootstrap diagnostic (ROLE_INVALID) and
#     delivers no overlay; a recognized role whose overlay file is missing is
#     ROLE_OVERLAY_MISSING plus an explicit ABSENT marker, never a silent
#     unamended session.
#   - A coordinator home is refused ship, scout, and batch crew spawns before
#     any metadata exists, while --secondmate is untouched.
#   - config/role is NOT inherited into secondmate homes, verified by driving
#     the real propagation rather than by reading the declared list alone.
# shellcheck disable=SC2016 # tracked-text assertions quote backticks literally
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-role-lib.sh
. "$ROOT/bin/fm-role-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
SPAWN="$ROOT/bin/fm-spawn.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"

fm_test_tmproot TMP_ROOT fm-role-config

fm_git_identity fmtest fmtest@example.invalid

# Hermetic runtime-backend detection: the dev shell's own multiplexer markers
# must not flip a fixture onto a non-tmux backend (same discipline as
# tests/fm-bootstrap.test.sh).
unset TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# --- fixtures ---------------------------------------------------------------

# A fake toolchain where every tool bootstrap detects is present and current, so
# its detect-only output is stable across the paired runs these tests diff.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.3'; exit 0 ;;
  update) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi update <id>'; printf '%s\n' '  --archive-body'; exit 0; } ;;
  mv) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path>'; exit 0; } ;;
  list) printf '%s\n' 'count: 0'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  # fm-lock.sh walks `ps` ancestry for a harness command name; report every pid
  # as a live claude so lock acquisition is deterministic.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# new_home <name>: a code root that is a real git repo on `main` (so the
# worktree-tangle and default-branch checks behave as they do against the real
# repo) plus an empty operational home. Echoes "<root>|<home>|<fakebin>".
new_home() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_toolchain "$w/fake")
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

read_home_record() {
  IFS='|' read -r ROOT_DIR HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

seed_overlay() {
  local root=$1 role=$2
  mkdir -p "$root/roles"
  printf '# Role overlay: %s\n\nfixture overlay body for %s\n' "$role" "$role" > "$root/roles/$role.md"
}

set_role() {
  printf '%s\n' "$2" > "$1/config/role"
}

run_bootstrap() {
  local home=$1 root=$2 fakebin=$3
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u TMUX \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BACKEND=tmux \
    "$BOOTSTRAP" 2>&1
}

run_session_start() {
  local home=$1 root=$2 fakebin=$3
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u TMUX \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    FM_BACKEND=tmux \
    "$SESSION_START" 2>&1
}

# The CONTEXT section's ordered subsection labels: every line immediately
# followed by the subsection rule, between the CONTEXT and FLEET STATE banners.
context_labels() {
  printf '%s\n' "$1" | awk '
    /^CONTEXT$/ { inctx = 1; next }
    /^FLEET STATE$/ { inctx = 0 }
    inctx && /^--------/ { print prev }
    { prev = $0 }
  '
}

context_section() {
  printf '%s\n' "$1" | awk '/^CONTEXT$/ { inctx = 1 } /^FLEET STATE$/ { inctx = 0 } inctx { print }'
}

# --- resolution --------------------------------------------------------------

test_absent_and_blank_config_resolve_to_the_default() {
  local dir
  dir="$TMP_ROOT/resolve-default"
  mkdir -p "$dir"

  [ "$(fm_role_value "$dir")" = vessel ] || fail "an absent config/role must resolve to vessel"

  printf '\n\n   \n' > "$dir/role"
  [ "$(fm_role_value "$dir")" = vessel ] || fail "a blank config/role must resolve to vessel"

  [ "$FM_ROLE_DEFAULT" = vessel ] || fail "the declared default role changed without updating this contract"
  pass "an absent or blank config/role resolves to the default vessel role"
}

test_value_is_the_first_non_empty_stripped_line() {
  local dir
  dir="$TMP_ROOT/resolve-value"
  mkdir -p "$dir"

  printf '\n  coordinator  \nexecutor\n' > "$dir/role"
  [ "$(fm_role_value "$dir")" = coordinator ] \
    || fail "config/role must be the first non-empty line with whitespace stripped"

  printf 'executor' > "$dir/role"
  [ "$(fm_role_value "$dir")" = executor ] || fail "a config/role with no trailing newline must still resolve"
  pass "config/role is the first non-empty line, whitespace stripped"
}

test_known_roles_and_overlay_paths() {
  local out
  fm_role_is_known vessel || fail "vessel must be a known role"
  fm_role_is_known coordinator || fail "coordinator must be a known role"
  fm_role_is_known executor || fail "executor must be a known role"
  ! fm_role_is_known staffcaptain || fail "an unlisted value must not be a known role"
  ! fm_role_is_known "" || fail "the empty string must not be a known role"

  out=$(fm_role_overlay_path /code vessel) \
    && fail "the default role must have no overlay path (got: $out)"
  [ -z "$out" ] || fail "the default role must print nothing from fm_role_overlay_path"

  out=$(fm_role_overlay_path /code staffcaptain) \
    && fail "an unrecognized role must have no overlay path (got: $out)"

  out=$(fm_role_overlay_path /code coordinator) || fail "coordinator must resolve an overlay path"
  [ "$out" = /code/roles/coordinator.md ] || fail "unexpected coordinator overlay path: $out"
  pass "role recognition and overlay paths follow the declared contract"
}

test_coordinator_predicate() {
  local dir
  dir="$TMP_ROOT/resolve-coordinator"
  mkdir -p "$dir"
  ! fm_role_is_coordinator "$dir" || fail "a home with no config/role is not a coordinator"
  printf 'coordinator\n' > "$dir/role"
  fm_role_is_coordinator "$dir" || fail "config/role=coordinator must satisfy the coordinator predicate"
  printf 'vessel\n' > "$dir/role"
  ! fm_role_is_coordinator "$dir" || fail "config/role=vessel must not satisfy the coordinator predicate"
  pass "the coordinator predicate reads config/role"
}

# --- tracked material and the AGENTS.md delivery seam ------------------------

test_tracked_role_material() {
  assert_present "$ROOT/roles/coordinator.md" "the tracked coordinator overlay is missing"
  assert_present "$ROOT/roles/executor.md" "the tracked executor overlay is missing"
  assert_absent "$ROOT/roles/vessel.md" \
    "roles/vessel.md must not exist: the default role is an unamended AGENTS.md, not a document"
  assert_grep 'amends `AGENTS.md`' "$ROOT/roles/coordinator.md" \
    "the coordinator overlay must declare itself an amendment to AGENTS.md"
  assert_grep 'amends `AGENTS.md`' "$ROOT/roles/executor.md" \
    "the executor overlay must declare itself an amendment to AGENTS.md"
  assert_gitignore_ignores 'config/role' "config/role must be gitignored like its config siblings"
  assert_grep 'Vessel role (config/role / roles/)' "$ROOT/docs/configuration.md" \
    "docs/configuration.md must own the vessel-role schema"
  pass "the tracked role material is present and gitignored where it should be"
}

test_agents_md_carries_the_second_delivery_seam() {
  # The digest gives deterministic delivery at session start; this line is what
  # makes a role survive context compaction. Both seams are deliberate.
  assert_grep 'If this home'"'"'s `config/role` names a role, load `roles/<name>.md` and treat it as an amendment to this file' \
    "$ROOT/AGENTS.md" "AGENTS.md lost the role overlay load line"
  assert_grep 'An absent `config/role`, or `vessel`, means this file stands unamended.' \
    "$ROOT/AGENTS.md" "AGENTS.md lost the default-role meaning"
  pass "AGENTS.md carries the compaction-surviving role load line"
}

# --- no behavior change with no config/role ----------------------------------

test_absent_role_changes_no_bootstrap_output() {
  local rec out_absent out_vessel
  rec=$(new_home bootstrap-default)
  read_home_record "$rec"

  out_absent=$(run_bootstrap "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_not_contains "$out_absent" "ROLE_" "a home with no config/role must produce no role diagnostic"

  set_role "$HOME_DIR" vessel
  out_vessel=$(run_bootstrap "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  [ "$out_absent" = "$out_vessel" ] \
    || fail "bootstrap output differed between an absent config/role and an explicit vessel"$'\n'"--- absent ---"$'\n'"$out_absent"$'\n'"--- vessel ---"$'\n'"$out_vessel"
  pass "bootstrap output is unchanged for an absent config/role"
}

test_absent_role_changes_no_context_digest() {
  local rec out_absent out_vessel labels expected
  rec=$(new_home digest-default)
  read_home_record "$rec"
  printf '%s\n' '- demo [no-mistakes] - a demo project' > "$HOME_DIR/data/projects.md"

  out_absent=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_not_contains "$out_absent" "ACTIVE ROLE OVERLAY" \
    "a home with no config/role must print no role overlay section"
  assert_not_contains "$out_absent" "roles/" "a home with no config/role must not mention a role overlay at all"

  labels=$(context_labels "$out_absent")
  expected='data/projects.md
data/secondmates.md
data/captain.md
data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)
data/learnings.md'
  [ "$labels" = "$expected" ] \
    || fail "CONTEXT subsections changed for a home with no config/role"$'\n'"--- got ---"$'\n'"$labels"$'\n'"--- want ---"$'\n'"$expected"

  set_role "$HOME_DIR" vessel
  out_vessel=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  [ "$(context_section "$out_absent")" = "$(context_section "$out_vessel")" ] \
    || fail "the CONTEXT digest differed between an absent config/role and an explicit vessel"
  pass "the session digest is unchanged for an absent config/role"
}

test_absent_role_does_not_refuse_a_spawn() {
  local rec out status
  rec=$(make_spawn_case spawn-default role-default-a1)
  read_spawn_record "$rec"

  out=$(run_spawn "$HOME_DIR" "role-default-a1" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a home with no config/role must spawn exactly as before"$'\n'"$out"
  assert_not_contains "$out" "owns no crews" "a default home must never see the coordinator refusal"
  assert_present "$HOME_DIR/state/role-default-a1.meta" "a default-home spawn must still record task metadata"
  pass "a home with no config/role spawns crews exactly as before"
}

# --- loud diagnostics for an undeliverable role ------------------------------

test_unrecognized_role_is_a_loud_diagnostic() {
  local rec out
  rec=$(new_home bootstrap-invalid)
  read_home_record "$rec"
  set_role "$HOME_DIR" staffcaptain

  out=$(run_bootstrap "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_contains "$out" "ROLE_INVALID: staffcaptain (known: vessel coordinator executor)" \
    "an unrecognized config/role must produce a loud, actionable diagnostic"
  assert_not_contains "$out" "ROLE_OVERLAY_MISSING" \
    "an unrecognized role must report only the invalid value, not a missing overlay"
  pass "an unrecognized config/role fails loudly instead of falling back silently"
}

test_unrecognized_role_delivers_no_overlay() {
  local rec out
  rec=$(new_home digest-invalid)
  read_home_record "$rec"
  seed_overlay "$ROOT_DIR" coordinator
  set_role "$HOME_DIR" staffcaptain

  out=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_contains "$out" "ROLE_INVALID: staffcaptain" "the digest must carry the invalid-role diagnostic"
  assert_not_contains "$out" "ACTIVE ROLE OVERLAY" "an unrecognized role must deliver no overlay"
  assert_not_contains "$out" "fixture overlay body" "an unrecognized role must not fall back to another role's overlay"
  pass "an unrecognized config/role delivers no overlay"
}

test_selected_role_with_no_overlay_is_reported_not_silent() {
  # The fixture root deliberately carries no roles/ directory, so this drives the
  # case where a recognized role's overlay is absent from THIS code root. Every
  # recognized non-default role now ships an overlay in the real tree, which makes
  # the live case a home that selected the role before fast-forwarding to the
  # commit that carries it - not a role nobody has written.
  local rec out role_section
  rec=$(new_home overlay-missing)
  read_home_record "$rec"
  set_role "$HOME_DIR" executor

  out=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_contains "$out" "ROLE_OVERLAY_MISSING: executor (expected: roles/executor.md)" \
    "a recognized role whose overlay is missing must be reported"
  assert_contains "$out" "roles/executor.md (ACTIVE ROLE OVERLAY" \
    "the digest must still label the selected role's overlay slot"
  role_section=$(printf '%s\n' "$out" | awk '/ACTIVE ROLE OVERLAY/ { flag = 1; next } /^data\// { flag = 0 } flag')
  assert_contains "$role_section" "ABSENT" \
    "a missing overlay must print the explicit ABSENT marker, never nothing"
  pass "a selected role with no overlay file is reported, not silently unamended"
}

# --- delivery of a valid role ------------------------------------------------

test_valid_role_is_delivered_through_the_digest() {
  local rec out labels first
  rec=$(new_home digest-coordinator)
  read_home_record "$rec"
  seed_overlay "$ROOT_DIR" coordinator
  set_role "$HOME_DIR" coordinator
  printf '%s\n' '- demo [no-mistakes] - a demo project' > "$HOME_DIR/data/projects.md"

  out=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_contains "$out" "roles/coordinator.md (ACTIVE ROLE OVERLAY - amends AGENTS.md" \
    "the digest did not label the active role overlay"
  assert_contains "$out" "fixture overlay body for coordinator" \
    "the digest did not print the overlay's contents"
  assert_not_contains "$out" "ROLE_INVALID" "a recognized role must produce no invalid diagnostic"
  assert_not_contains "$out" "ROLE_OVERLAY_MISSING" "a present overlay must produce no missing diagnostic"

  labels=$(context_labels "$out")
  first=$(printf '%s\n' "$labels" | head -1)
  case "$first" in
    "roles/coordinator.md (ACTIVE ROLE OVERLAY"*) : ;;
    *) fail "the role overlay must lead CONTEXT, it amends AGENTS.md itself; got: $first" ;;
  esac
  pass "a valid role is delivered at the head of the session digest"
}

test_tracked_executor_overlay_reaches_the_digest() {
  # The seeded-overlay tests above prove the mechanism. This one proves the
  # shipped document actually arrives: the tracked roles/executor.md is copied
  # into the fixture root verbatim, so a mismatch between what is written and
  # what an executor home reads at session start fails here.
  local rec out labels first headings after
  rec=$(new_home digest-executor)
  read_home_record "$rec"
  mkdir -p "$ROOT_DIR/roles"
  cp "$ROOT/roles/executor.md" "$ROOT_DIR/roles/executor.md"
  set_role "$HOME_DIR" executor

  out=$(run_session_start "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_not_contains "$out" "ROLE_OVERLAY_MISSING" \
    "a home selecting executor must no longer be told the overlay is missing"
  assert_contains "$out" \
    "Where an executor operates work another vessel develops, that vessel owns diagnosing its own domain." \
    "the digest did not carry the executor overlay's one narrowing"
  assert_contains "$out" "This role has no mechanical enforcement" \
    "the digest did not carry the executor overlay's enforcement ceiling"
  assert_contains "$out" \
    "A request absorbed into a larger task keeps its own reply, recorded at intake and checked at teardown." \
    "the digest did not carry the executor overlay's report-back rule"
  assert_contains "$out" "how the request arrived does not decide that" \
    "the digest did not carry the rule that the arrival route does not pick the reply's channel"
  assert_contains "$out" 'Parcels ran on method 7014 instead of 341' \
    "the digest did not carry the symptom side of the executor's finding boundary"
  assert_contains "$out" 'Why Sendcloud resolves to 7014' \
    "the digest did not carry the cause side of the executor's finding boundary"

  # The counterpart section only reads as the other side of the narrowing if it
  # arrives immediately after it, so the delivered order is the claim, not the
  # mere presence of both headings.
  headings=$(context_section "$out" | grep '^## ') \
    || fail "the delivered overlay carried no section headings at all"
  after=$(printf '%s\n' "$headings" | grep -A1 '^## Narrowed: ' | tail -1)
  [ "$after" = "## Not narrowed: what operating shows that developing cannot" ] \
    || fail "the not-narrowed counterpart must follow the narrowing directly; got: $after"

  labels=$(context_labels "$out")
  first=$(printf '%s\n' "$labels" | head -1)
  case "$first" in
    "roles/executor.md (ACTIVE ROLE OVERLAY"*) : ;;
    *) fail "the executor overlay must lead CONTEXT like any role overlay; got: $first" ;;
  esac
  pass "the tracked executor overlay is delivered at the head of the session digest"
}

test_valid_role_leaves_bootstrap_quiet() {
  local rec out
  rec=$(new_home bootstrap-coordinator)
  read_home_record "$rec"
  seed_overlay "$ROOT_DIR" coordinator
  set_role "$HOME_DIR" coordinator

  out=$(run_bootstrap "$HOME_DIR" "$ROOT_DIR" "$FAKEBIN_DIR")
  assert_not_contains "$out" "ROLE_" "a correctly configured role must print no diagnostic"
  pass "a deliverable role produces no bootstrap diagnostic"
}

# --- the coordinator crew refusal --------------------------------------------

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-panes) printf '%%1 1\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" FM_BACKEND=tmux \
    GROK_HOME="$home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_coordinator_refuses_a_ship_spawn() {
  local rec out status
  rec=$(make_spawn_case spawn-coordinator-ship role-ship-b2)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" coordinator

  out=$(run_spawn "$HOME_DIR" role-ship-b2 "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a coordinator home must refuse a ship spawn"
  assert_contains "$out" "config/role is coordinator - this home owns no crews" \
    "the refusal did not explain the coordinator posture"
  assert_absent "$HOME_DIR/state/role-ship-b2.meta" \
    "the coordinator refusal must land before any task metadata exists"
  pass "a coordinator home refuses a ship spawn"
}

test_coordinator_refuses_a_scout_spawn() {
  local rec out status
  rec=$(make_spawn_case spawn-coordinator-scout role-scout-c3)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" coordinator

  out=$(run_spawn "$HOME_DIR" role-scout-c3 "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "a coordinator home must refuse a scout spawn"
  assert_contains "$out" "config/role is coordinator - this home owns no crews" \
    "the scout refusal did not explain the coordinator posture"
  assert_absent "$HOME_DIR/state/role-scout-c3.meta" \
    "the coordinator refusal must land before any task metadata exists"
  pass "a coordinator home refuses a scout spawn"
}

test_coordinator_refuses_a_batch_spawn_before_fan_out() {
  local rec out status
  rec=$(make_spawn_case spawn-coordinator-batch role-batch-d4)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" coordinator

  out=$(run_spawn "$HOME_DIR" "role-batch-d4=$PROJ_DIR" "role-batch-e5=$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a coordinator home must refuse a batch spawn"
  assert_contains "$out" "config/role is coordinator - this home owns no crews" \
    "the batch refusal did not explain the coordinator posture"
  assert_absent "$HOME_DIR/state/role-batch-d4.meta" "the batch refusal must precede fan-out"
  pass "a coordinator home refuses a batch spawn before any pair is launched"
}

test_explicit_vessel_role_spawns_normally() {
  local rec out status
  rec=$(make_spawn_case spawn-vessel role-vessel-f6)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" vessel

  out=$(run_spawn "$HOME_DIR" role-vessel-f6 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an explicit vessel role must spawn normally"$'\n'"$out"
  assert_not_contains "$out" "owns no crews" "a vessel home must never see the coordinator refusal"
  pass "an explicit vessel role spawns crews normally"
}

test_executor_role_spawns_crews_normally() {
  # roles/executor.md states that the coordinator's crew refusal does not apply
  # to this role and that the ordinary task lifecycle is kept in full. That is a
  # behavior claim, so it is driven through the real fm-spawn.sh rather than
  # inferred from the coordinator-only predicate.
  local rec out status
  rec=$(make_spawn_case spawn-executor role-executor-h8)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" executor

  out=$(run_spawn "$HOME_DIR" role-executor-h8 "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an executor home must spawn crews normally"$'\n'"$out"
  assert_not_contains "$out" "owns no crews" "an executor home must never see the coordinator refusal"
  assert_present "$HOME_DIR/state/role-executor-h8.meta" \
    "an executor spawn must still record task metadata"
  pass "an executor home spawns crews normally"
}

test_coordinator_does_not_block_a_secondmate_spawn() {
  local rec out
  rec=$(make_spawn_case spawn-coordinator-secondmate role-second-g7)
  read_spawn_record "$rec"
  set_role "$HOME_DIR" coordinator

  # A persistent secondmate is a separate mechanism, not a crew. This spawn may
  # still fail for unrelated fixture reasons; what must never appear is the
  # role refusal.
  out=$(run_spawn "$HOME_DIR" role-second-g7 "$CASE_DIR/secondmate-home" --secondmate) || true
  assert_not_contains "$out" "owns no crews" \
    "the coordinator crew refusal must not fire on a --secondmate spawn"
  pass "the coordinator refusal leaves secondmate spawns alone"
}

# --- role is not inherited into secondmate homes -----------------------------

test_role_is_not_in_the_declared_inheritable_set() {
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  local item
  for item in $FM_INHERITABLE_CONFIG; do
    [ "$item" != role ] || fail "config/role must not be in the declared inheritable set"
  done
  pass "config/role is not in the declared inheritable set"
}

test_role_does_not_propagate_into_a_secondmate_home() {
  local dir src dest
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  dir="$TMP_ROOT/inheritance"
  src="$dir/primary/config"
  dest="$dir/secondmate/config"
  mkdir -p "$src" "$dest"
  printf 'coordinator\n' > "$src/role"
  printf 'codex\n' > "$src/crew-harness"

  propagate_inheritable_config "$src" "$dest" || fail "propagation failed on the fixture"

  assert_present "$dest/crew-harness" "a declared inheritable item must still propagate"
  assert_absent "$dest/role" \
    "config/role must never reach a secondmate home: a coordinator's child is not a coordinator"
  pass "config/role does not propagate into a secondmate home"
}

test_absent_and_blank_config_resolve_to_the_default
test_value_is_the_first_non_empty_stripped_line
test_known_roles_and_overlay_paths
test_coordinator_predicate
test_tracked_role_material
test_agents_md_carries_the_second_delivery_seam
test_absent_role_changes_no_bootstrap_output
test_absent_role_changes_no_context_digest
test_absent_role_does_not_refuse_a_spawn
test_unrecognized_role_is_a_loud_diagnostic
test_unrecognized_role_delivers_no_overlay
test_selected_role_with_no_overlay_is_reported_not_silent
test_valid_role_is_delivered_through_the_digest
test_tracked_executor_overlay_reaches_the_digest
test_valid_role_leaves_bootstrap_quiet
test_coordinator_refuses_a_ship_spawn
test_coordinator_refuses_a_scout_spawn
test_coordinator_refuses_a_batch_spawn_before_fan_out
test_explicit_vessel_role_spawns_normally
test_executor_role_spawns_crews_normally
test_coordinator_does_not_block_a_secondmate_spawn
test_role_is_not_in_the_declared_inheritable_set
test_role_does_not_propagate_into_a_secondmate_home

echo "# all fm-role-config tests passed"
