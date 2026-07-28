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
  home=$(make_home 'done')
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
    tasks-axi 'done' archived-blocker --note "completed" >/dev/null
    for n in 01 02 03 04 05 06 07 08 09 10; do
      tasks-axi add "archived-filler-$n" "Unrelated filler $n" --kind ship --repo sample >/dev/null
      tasks-axi 'done' "archived-filler-$n" --note "completed" >/dev/null
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

test_unresolvable_record_is_a_coded_diagnostic_not_a_finding() {
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
    "an edge whose staleness could not be decided must never become a finding"
  [ "$(lint_status)" = 1 ] \
    || fail "an unreadable tasks-axi answer must exit 1, got $(lint_status)"
  [ -z "$(lint_stderr)" ] \
    || fail "the unreadable-record report must be a coded line, not stderr: $(lint_stderr)"
  assert_contains "$out" "BACKLOG_UNREADABLE: task **unresolvable-dependent** in data/backlog.md" \
    "the unreadable-record diagnostic must be coded and name the record and file"
  assert_contains "$out" "is parsed by fm-fleet-snapshot but tasks-axi does not list that record when reading the same file" \
    "the unreadable-record diagnostic must name the reader that failed and the mismatch"
  assert_contains "$out" "fix: repair that row in data/backlog.md" \
    "the unreadable-record diagnostic must say which record text to repair"
  assert_contains "$out" "tasks-axi list --file data/backlog.md shows that id" \
    "the unreadable-record diagnostic must name its closing condition"
  assert_grep "BACKLOG_UNREADABLE" "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
    "the coded diagnostic must have a documented handling procedure"
  assert_grep "BACKLOG_UNREADABLE" "$ROOT/AGENTS.md" \
    "the coded diagnostic must be registered with the other bootstrap codes"
  pass "an unresolvable record is a coded documented diagnostic, not a reader-disagreement false alarm"
}

test_unresolvable_record_still_reports_edges_decided_without_tasks_axi() {
  local home out
  home=$(make_home unresolvable-decidable)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] **decidable-dependent** - Id tasks-axi cannot resolve blocked-by: decidable-missing (repo: sample) (kind: ship)
- [ ] **decidable-done-dependent** - Id tasks-axi cannot resolve blocked-by: decidable-done (repo: sample) (kind: ship)
## Done
- [x] decidable-done - Already complete (repo: sample) (kind: ship) (done 2026-07-28)
EOF
  out=$(run_lint "$home")
  assert_ok "edges the parsed backlog alone decides must leave the run decided"
  assert_not_contains "$out" "BACKLOG_UNREADABLE" \
    "BACKLOG_UNREADABLE is only for edges whose staleness could not be decided"
  assert_contains "$out" "BACKLOG_STALE: task **decidable-dependent** has dangling blocked-by decidable-missing" \
    "a dangling edge stays a finding when the readers decide it without tasks-axi"
  assert_contains "$out" "BACKLOG_STALE: task **decidable-done-dependent** has satisfied blocked-by decidable-done" \
    "an already-Done edge stays a finding when the readers decide it without tasks-axi"
  assert_contains "$out" 'fix: no tasks-axi fix is available because tasks-axi does not list task **decidable-dependent** when reading data/backlog.md, so edit data/backlog.md by hand and delete the blocked-by token "blocked-by: decidable-missing" naming blocker decidable-missing from the record for task **decidable-dependent**' \
    "an unresolvable record must get hand-edit guidance naming file, record, token, and blocker"
  assert_not_contains "$out" "tasks-axi unblock" \
    "the lint must never prescribe a tasks-axi command that cannot run"
  pass "an unresolvable record keeps the findings its own row decides, with a runnable fix"
}

test_unresolvable_record_separates_decided_and_undecided_edges() {
  local home out unreadable_lines
  home=$(make_home unresolvable-mixed)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] **mixed-dependent** - Two faults blocked-by: mixed-missing blocked-by: mixed-archived (repo: sample) (kind: ship)
## Done
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-07-01

- [x] mixed-archived - Rotated out of the live backlog (repo: sample) (kind: ship) (done 2026-06-01)
EOF
  out=$(run_lint "$home")
  [ "$(lint_status)" = 1 ] \
    || fail "one undecided edge must still mark the run undecided, got $(lint_status)"
  assert_contains "$out" "BACKLOG_STALE: task **mixed-dependent** has dangling blocked-by mixed-missing" \
    "the decided edge of an unresolvable record must still be reported"
  assert_not_contains "$out" "reader-disagreement" \
    "the undecided edge of the same record must not be guessed at"
  assert_contains "$out" "BACKLOG_UNREADABLE: task **mixed-dependent** in data/backlog.md" \
    "the undecided edge must be reported as the coded diagnostic"
  unreadable_lines=$(printf '%s\n' "$out" | grep -c "^BACKLOG_UNREADABLE:")
  [ "$unreadable_lines" = 1 ] \
    || fail "a record must report BACKLOG_UNREADABLE once, got $unreadable_lines"
  pass "one record reports its decided edge and its undecided edge under the right code"
}

test_lint_cost_stays_bounded_as_backlog_rot_grows() {
  local home_clean home_rot shim log n calls
  shim=$TMP_ROOT/tasks-axi-shim
  log=$TMP_ROOT/tasks-axi-calls
  mkdir -p "$shim"
  cat > "$shim/tasks-axi" <<EOF
#!/usr/bin/env bash
printf 'call\n' >> "\$FM_TEST_TASKS_AXI_CALL_LOG"
exec $(command -v tasks-axi) "\$@"
EOF
  chmod +x "$shim/tasks-axi"

  home_clean=$(make_home bounded-clean)
  home_rot=$(make_home bounded-rot)
  {
    printf '%s\n' '# Backlog' '' '## In flight' '## Queued'
    n=0
    while [ "$n" -lt 40 ]; do
      printf -- '- [ ] bounded-live-%02d - Clean queued task (repo: sample) (kind: ship)\n' "$n"
      n=$((n + 1))
    done
    printf '%s\n' '## Done'
  } > "$home_clean/data/backlog.md"
  {
    printf '%s\n' '# Backlog' '' '## In flight' '## Queued'
    n=0
    while [ "$n" -lt 40 ]; do
      printf -- '- [ ] bounded-rot-%02d - Stale task blocked-by: bounded-ghost-%02d (repo: sample) (kind: ship)\n' "$n" "$n"
      n=$((n + 1))
    done
    printf '%s\n' '## Done'
  } > "$home_rot/data/backlog.md"

  : > "$log"
  PATH="$shim:$PATH" FM_TEST_TASKS_AXI_CALL_LOG="$log" FM_HOME="$home_clean" "$LINT" >/dev/null 2>&1
  calls=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$calls" = 0 ] \
    || fail "a clean backlog must start no tasks-axi process, started $calls"

  : > "$log"
  PATH="$shim:$PATH" FM_TEST_TASKS_AXI_CALL_LOG="$log" FM_HOME="$home_rot" "$LINT" >/dev/null 2>&1
  calls=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "40 stale edges must be resolved by one tasks-axi process, started $calls"
  pass "session-start lint cost stays bounded as backlog rot grows"
}

test_bootstrap_surfaces_the_unreadable_record_diagnostic() {
  local home out
  home=$(make_home bootstrap-unreadable)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
- [ ] **bootstrap-unreadable-dependent** - Id tasks-axi cannot resolve blocked-by: bootstrap-archived (repo: sample) (kind: ship)
## Done
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-07-01

- [x] bootstrap-archived - Rotated out of the live backlog (repo: sample) (kind: ship) (done 2026-06-01)
EOF
  out=$(FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "the unreadable-record diagnostic must not make bootstrap fail"
  assert_contains "$out" "BACKLOG_UNREADABLE: task **bootstrap-unreadable-dependent** in data/backlog.md" \
    "session-start bootstrap must surface the coded unreadable-record diagnostic"
  pass "bootstrap surfaces the coded unreadable-record diagnostic without blocking"
}

test_manual_backend_prints_hand_edit_fix() {
  local home out
  home=$(make_home manual-backend)
  printf '%s\n' manual > "$home/config/backlog-backend"
  {
    printf '%s\n' '# Backlog' '' '## In flight' '## Queued'
    printf -- '- [ ] manual-dependent - Bad missing edge blocked-by: manual-missing (repo: sample) (kind: ship)\n'
    printf -- '- [ ] manual-done-dependent - Bad satisfied edge blocked-by:   manual-done (repo: sample) (kind: ship)\n'
    printf -- '- [ ] manual-tab-dependent - Tab separated edge blocked-by:\tmanual-tab-missing (repo: sample) (kind: ship)\n'
    printf '%s\n' '## Done'
    printf -- '- [x] manual-done - Already complete (repo: sample) (kind: ship) (done 2026-07-28)\n'
  } > "$home/data/backlog.md"
  out=$(run_lint "$home")
  assert_ok "the lint must still run under config/backlog-backend=manual"
  assert_contains "$out" "BACKLOG_STALE: task manual-dependent has dangling blocked-by manual-missing" \
    "manual mode must keep the finding message shape"
  assert_contains "$out" 'fix: edit data/backlog.md by hand and delete the blocked-by token "blocked-by: manual-missing" naming blocker manual-missing from the record for task manual-dependent' \
    "manual mode must name the file, record, blocked-by token, and blocker id"
  assert_contains "$out" 'delete the blocked-by token "blocked-by:   manual-done" naming blocker manual-done from the record for task manual-done-dependent' \
    "manual mode must quote a multi-space blocked-by token as the record actually spells it"
  assert_contains "$out" $'delete the blocked-by token "blocked-by:\tmanual-tab-missing" naming blocker manual-tab-missing from the record for task manual-tab-dependent' \
    "manual mode must quote a tab-separated blocked-by token without escaping it"
  assert_not_contains "$out" 'blocked-by:\tmanual-tab-missing' \
    "the quoted token must not carry a two-character escape the file does not contain"
  assert_not_contains "$out" "tasks-axi unblock" \
    "manual mode must not prescribe the backend the home opted out of"
  while IFS= read -r quoted; do
    assert_grep "$quoted" "$home/data/backlog.md" \
      "a quoted blocked-by token must be findable in the backlog file"
  done < <(printf '%s\n' "$out" | sed -n 's/.*delete the blocked-by token "\([^"]*\)".*/\1/p')
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
test_unresolvable_record_is_a_coded_diagnostic_not_a_finding
test_unresolvable_record_still_reports_edges_decided_without_tasks_axi
test_unresolvable_record_separates_decided_and_undecided_edges
test_lint_cost_stays_bounded_as_backlog_rot_grows
test_bootstrap_surfaces_the_unreadable_record_diagnostic
test_manual_backend_prints_hand_edit_fix
test_bootstrap_surfaces_findings_and_stays_silent_when_clean
