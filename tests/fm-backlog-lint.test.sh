#!/usr/bin/env bash
# Behavior tests for the detect-only durable backlog dependency lint.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-backlog-lint.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
fm_test_tmproot TMP_ROOT fm-backlog-lint

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' "$home"
}

# run_lint keeps the lint's stdout on stdout so callers can capture it, and
# records exit status and stderr in files that survive the capture subshell.
LINT_STATUS_FILE=$TMP_ROOT/lint-status
LINT_ERR_FILE=$TMP_ROOT/lint-stderr

run_lint() {  # <home>
  local status=0
  FM_HOME="$1" "$LINT" 2>"$LINT_ERR_FILE" || status=$?
  printf '%s\n' "$status" > "$LINT_STATUS_FILE"
}

lint_status() {
  cat "$LINT_STATUS_FILE"
}

lint_stderr() {
  cat "$LINT_ERR_FILE"
}

assert_ok() {  # <message>
  [ "$(lint_status)" = 0 ] || fail "$1: lint exited $(lint_status) instead of succeeding"
  [ -z "$(lint_stderr)" ] || fail "$1: lint wrote to stderr: $(lint_stderr)"
}

assert_clean() {  # <home> <message>
  local out
  out=$(run_lint "$1")
  [ -z "$out" ] || fail "$2: $out"
  assert_ok "$2"
}

test_clean_live_edge_is_silent() {
  local home
  home=$(make_home clean)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] clean-blocker - Still active (repo: sample) (kind: ship)
- [ ] clean-dependent - Correctly blocked blocked-by: clean-blocker (repo: sample) (kind: ship)
## Done
EOF
  assert_clean "$home" "a live unresolved edge must be silent"
  pass "clean live dependency edge is silent"
}

test_large_clean_backlog_is_silent() {
  local home n
  home=$(make_home large-clean)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] large-clean-task - Large clean task (repo: sample) (kind: ship)
EOF
  n=0
  while [ "$n" -lt 1800 ]; do
    printf '  Large durable body line %04d carries enough detail to exceed one operating-system argument while remaining a clean record.\n' "$n" \
      >> "$home/data/backlog.md"
    n=$((n + 1))
  done
  printf '%s\n' '## Done' >> "$home/data/backlog.md"
  assert_clean "$home" "a clean backlog larger than one process argument must stay silent"
  pass "large clean backlog avoids process-argument limits and stays silent"
}

test_dangling_edge_names_fault_and_closable_fix() {
  local home out
  home=$(make_home dangling)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] dangling-dependent - Bad missing edge blocked-by: never-existed (repo: sample) (kind: ship)
## Done
EOF
  out=$(run_lint "$home")
  assert_ok "a dangling edge is a finding, not a command error"
  assert_contains "$out" "BACKLOG_STALE: task dangling-dependent has dangling blocked-by never-existed" \
    "dangling finding must name the record and missing target"
  assert_contains "$out" "target is absent from data/backlog.md and data/done-archive.md" \
    "dangling finding must name both checked stores"
  assert_contains "$out" "fix: run tasks-axi unblock dangling-dependent --by never-existed" \
    "dangling finding must provide its exact closing command"
  (cd "$home" && tasks-axi unblock dangling-dependent --by never-existed >/dev/null)
  assert_clean "$home" "dangling finding must clear after its printed fix"
  pass "dangling edge fires and its printed fix makes the lint silent"
}

test_done_edge_names_fault_and_closable_fix() {
  local home out
  home=$(make_home done)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] done-dependent - Bad satisfied edge blocked-by: done-blocker (repo: sample) (kind: ship)
## Done
- [x] done-blocker - Already complete (repo: sample) (kind: ship) (done 2026-07-28)
EOF
  out=$(run_lint "$home")
  assert_ok "an already-Done edge is a finding, not a command error"
  assert_contains "$out" "BACKLOG_STALE: task done-dependent has satisfied blocked-by done-blocker" \
    "Done finding must name the record and satisfied target"
  assert_contains "$out" "target is already Done in data/backlog.md" \
    "Done finding must state the mechanical fault"
  assert_contains "$out" "fix: run tasks-axi unblock done-dependent --by done-blocker" \
    "Done finding must provide its exact closing command"
  (cd "$home" && tasks-axi unblock done-dependent --by done-blocker >/dev/null)
  assert_clean "$home" "Done finding must clear after its printed fix"
  pass "already-Done edge fires and its printed fix makes the lint silent"
}

test_archive_rotation_reader_disagreement_and_fix() {
  local home n show snapshot out
  home=$(make_home archived)
  (
    cd "$home" || exit 1
    tasks-axi add archived-blocker "Retention blocker" --kind ship --repo sample >/dev/null
    tasks-axi add archived-dependent "Captain decision" --kind captain --repo sample \
      --blocked-by archived-blocker >/dev/null
    tasks-axi hold archived-dependent --reason "captain decision" --kind captain >/dev/null
    tasks-axi done archived-blocker --note "completed" >/dev/null
    for n in 01 02 03 04 05 06 07 08 09 10; do
      tasks-axi add "archived-filler-$n" "Unrelated filler $n" --kind ship --repo sample >/dev/null
      tasks-axi done "archived-filler-$n" --note "completed" >/dev/null
    done
  )

  assert_grep "archived-blocker" "$home/data/done-archive.md" \
    "retention reproduction did not rotate the blocker into the archive"
  assert_grep "blocked-by: archived-blocker" "$home/data/backlog.md" \
    "retention reproduction unexpectedly rewrote the dependent edge"
  show=$(cd "$home" && tasks-axi show archived-dependent --full)
  assert_contains "$show" "blocked: no" "tasks-axi must reproduce the satisfied answer"
  assert_contains "$show" "blocked_by: none" "tasks-axi must drop the archived target from blockers"
  snapshot=$(FM_HOME="$home" "$SNAPSHOT" --backlog-json)
  printf '%s\n' "$snapshot" | jq -e '
    .records[] | select(.id == "archived-dependent")
    | .unresolved_blocker_ids == ["archived-blocker"]
      and .captain_actionable == false
  ' >/dev/null || fail "fleet snapshot did not reproduce the opposite unresolved answer"

  out=$(run_lint "$home")
  assert_ok "a reader-disagreement edge is a finding, not a command error"
  assert_contains "$out" "BACKLOG_STALE: task archived-dependent has reader-disagreement blocked-by archived-blocker" \
    "reader-disagreement finding must name the record and edge"
  assert_contains "$out" "tasks-axi says satisfied; fm-fleet-snapshot says unresolved" \
    "reader-disagreement finding must state both opposite answers"
  assert_contains "$out" "fix: run tasks-axi unblock archived-dependent --by archived-blocker" \
    "reader-disagreement finding must provide its exact closing command"
  (cd "$home" && tasks-axi unblock archived-dependent --by archived-blocker >/dev/null)
  assert_clean "$home" "reader-disagreement finding must clear after its printed fix"
  pass "retention-created reader disagreement fires and its printed fix makes the lint silent"
}

test_unresolvable_record_is_a_command_error_not_a_finding() {
  local home out
  home=$(make_home unresolvable)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] **unresolvable-dependent** - Id tasks-axi cannot resolve blocked-by: unresolvable-blocker (repo: sample) (kind: ship)
## Done
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-07-01

- [x] unresolvable-blocker - Rotated out of the live backlog (repo: sample) (kind: ship) (done 2026-06-01)
EOF
  out=$(run_lint "$home")
  assert_not_contains "$out" "BACKLOG_STALE:" \
    "a record tasks-axi cannot resolve must never become a finding"
  [ "$(lint_status)" = 1 ] \
    || fail "an unreadable tasks-axi answer must exit 1, got $(lint_status)"
  assert_contains "$(lint_stderr)" "tasks-axi could not resolve task **unresolvable-dependent**" \
    "an unreadable tasks-axi answer must name the record on stderr"
  pass "an unresolvable record is a command error instead of a reader-disagreement false alarm"
}

test_manual_backend_prints_hand_edit_fix() {
  local home out
  home=$(make_home manual-backend)
  printf '%s\n' manual > "$home/config/backlog-backend"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] manual-dependent - Bad missing edge blocked-by: manual-missing (repo: sample) (kind: ship)
- [ ] manual-done-dependent - Bad satisfied edge blocked-by: manual-done (repo: sample) (kind: ship)
## Done
- [x] manual-done - Already complete (repo: sample) (kind: ship) (done 2026-07-28)
EOF
  out=$(run_lint "$home")
  assert_ok "the lint must still run under config/backlog-backend=manual"
  assert_contains "$out" "BACKLOG_STALE: task manual-dependent has dangling blocked-by manual-missing" \
    "manual mode must keep the finding message shape"
  assert_contains "$out" 'fix: edit data/backlog.md by hand and delete the exact text "blocked-by: manual-missing" from the record for task manual-dependent' \
    "manual mode must name the file, record, and exact blocked-by text"
  assert_contains "$out" 'fix: edit data/backlog.md by hand and delete the exact text "blocked-by: manual-done" from the record for task manual-done-dependent' \
    "manual mode must give hand-edit guidance for every finding class"
  assert_not_contains "$out" "tasks-axi unblock" \
    "manual mode must not prescribe the backend the home opted out of"
  pass "manual backend keeps the lint enabled with closable hand-edit fixes"
}

test_bootstrap_surfaces_findings_and_stays_silent_when_clean() {
  local bad_home clean_home bad_out clean_out
  bad_home=$(make_home bootstrap-bad)
  cat > "$bad_home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] bootstrap-dependent - Bad edge blocked-by: bootstrap-missing (repo: sample) (kind: ship)
## Done
EOF
  clean_home=$(make_home bootstrap-clean)
  cat > "$clean_home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] bootstrap-ready - Clean queued task (repo: sample) (kind: ship)
## Done
EOF
  bad_out=$(FM_HOME="$bad_home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$bad_out" "BACKLOG_STALE: task bootstrap-dependent has dangling blocked-by bootstrap-missing" \
    "session-start bootstrap must surface lint findings"
  clean_out=$(FM_HOME="$clean_home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$clean_out" "BACKLOG_STALE:" \
    "session-start bootstrap must keep a clean backlog lint-silent"
  pass "bootstrap runs the detect-only lint and keeps clean homes silent"
}

test_clean_live_edge_is_silent
test_large_clean_backlog_is_silent
test_dangling_edge_names_fault_and_closable_fix
test_done_edge_names_fault_and_closable_fix
test_archive_rotation_reader_disagreement_and_fix
test_unresolvable_record_is_a_command_error_not_a_finding
test_manual_backend_prints_hand_edit_fix
test_bootstrap_surfaces_findings_and_stays_silent_when_clean
