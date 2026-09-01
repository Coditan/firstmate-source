#!/usr/bin/env bash
# Contract tests for bin/fm-toolbelt-domain-map.py.
#
# The generator is the single owner of docs/command-domain-map.md.
# It must be deterministic, reject a stale committed map, and refuse a command
# inventory it cannot place.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAPPER="$ROOT/bin/fm-toolbelt-domain-map.py"
MAP="$ROOT/docs/command-domain-map.md"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$MAPPER" "bin/fm-toolbelt-domain-map.py is missing"
[ -x "$MAPPER" ] || fail "bin/fm-toolbelt-domain-map.py must be executable"

test_committed_map_is_current() {
  local out
  out=$("$MAPPER" --check 2>&1) || fail "committed command-domain map is stale"$'\n'"$out"
  assert_contains "$out" "FM_TOOLBELT_DOMAIN_MAP ok" "freshness check did not report its ok marker"
  pass "committed command-domain map matches the tree"
}

test_generation_is_deterministic() {
  local tmp first second
  fm_test_tmproot tmp fm-toolbelt-map-deterministic
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  first="$tmp/first.md"
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  second="$tmp/second.md"
  "$MAPPER" --stdout >"$first"
  "$MAPPER" --stdout >"$second"
  cmp -s "$first" "$second" || fail "two unchanged generator runs produced different bytes"
  pass "command-domain map generation is deterministic"
}

init_map_fixture() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/docs"
  cp "$MAPPER" "$repo/bin/fm-toolbelt-domain-map.py"
  chmod +x "$repo/bin/fm-toolbelt-domain-map.py"
  cat >"$repo/bin/fm-afk-fixture.sh" <<'SH'
#!/usr/bin/env bash
# fm-afk-fixture.sh - exercise away-mode fixture classification.
printf 'away-mode fixture\n'
SH
  chmod +x "$repo/bin/fm-afk-fixture.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_check_rejects_stale_map() {
  local tmp repo out rc
  fm_test_tmproot tmp fm-toolbelt-map-stale
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  repo="$tmp/repo"
  init_map_fixture "$repo"
  "$repo/bin/fm-toolbelt-domain-map.py" --root "$repo" --write >/dev/null
  git -C "$repo" add docs/command-domain-map.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm map
  cat >"$repo/bin/fm-afk-new.sh" <<'SH'
#!/usr/bin/env bash
# fm-afk-new.sh - exercise a new away-mode command after map generation.
printf 'new away-mode fixture\n'
SH
  chmod +x "$repo/bin/fm-afk-new.sh"
  git -C "$repo" add bin/fm-afk-new.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm new-command
  rc=0
  out=$("$repo/bin/fm-toolbelt-domain-map.py" --root "$repo" --check 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "stale map check returned $rc instead of 1"
  assert_contains "$out" "is out of date" "stale map check did not name the stale artifact"
  pass "check mode rejects stale generated content"
}

test_check_rejects_unplaced_command() {
  local tmp repo out rc
  fm_test_tmproot tmp fm-toolbelt-map-unplaced
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  repo="$tmp/repo"
  init_map_fixture "$repo"
  cat >"$repo/bin/unmapped-fixture" <<'SH'
#!/usr/bin/env bash
# Deliberately carries no firstmate domain evidence.
printf 'fixture\n'
SH
  chmod +x "$repo/bin/unmapped-fixture"
  git -C "$repo" add bin/unmapped-fixture
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm unmapped
  "$repo/bin/fm-toolbelt-domain-map.py" --root "$repo" --write >/dev/null
  rc=0
  out=$("$repo/bin/fm-toolbelt-domain-map.py" --root "$repo" --check 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "unplaced map check returned $rc instead of 1"
  assert_contains "$out" "command(s) are unplaced" "unplaced check did not report the domain gap"
  pass "check mode rejects commands with no domain"
}

test_map_preserves_wrapped_purposes_and_path_kinds() {
  local tmp repo out
  fm_test_tmproot tmp fm-toolbelt-map-source-kinds
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  cp "$MAPPER" "$repo/bin/fm-toolbelt-domain-map.py"
  chmod +x "$repo/bin/fm-toolbelt-domain-map.py"
  cat >"$repo/bin/fm-watch-fixture.sh" <<'SH'
#!/usr/bin/env bash
# fm-watch-fixture.sh - Watcher fixture purpose wraps across
# two lines for the generated public map.
printf 'watcher fixture\n'
SH
  chmod +x "$repo/bin/fm-watch-fixture.sh"
  cat >"$repo/bin/fm-ordinary.sh" <<'SH'
#!/usr/bin/env bash
# mentions systemd and fm-watch-fixture.sh without becoming a service script.
printf 'ordinary fixture\n'
SH
  chmod +x "$repo/bin/fm-ordinary.sh"
  cat >"$repo/tests/fm-reference.test.sh" <<'SH'
#!/usr/bin/env bash
# mentions systemd and fm-watch-fixture.sh from a test.
:
SH
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  out=$("$repo/bin/fm-toolbelt-domain-map.py" --root "$repo" --stdout)
  assert_contains "$out" "| \`fm-watch-fixture.sh\` | Watcher fixture purpose wraps across two lines for the generated public map |" \
    "generated map did not preserve a wrapped header purpose"
  assert_contains "$out" "scripts: bin/fm-ordinary.sh" \
    "generated map did not classify an ordinary bin reference by path"
  assert_contains "$out" "tests: tests/fm-reference.test.sh" \
    "generated map did not classify a test reference by path"
  assert_not_contains "$out" "scripts/systemd: bin/fm-ordinary.sh" \
    "ordinary script reference was misclassified from file content"
  assert_not_contains "$out" "systemd: tests/fm-reference.test.sh" \
    "test reference was misclassified from file content"
  pass "map preserves wrapped purposes and path-based source kinds"
}

test_coverage_guard_runs_map_check() {
  local tmp repo out rc
  fm_test_tmproot tmp fm-toolbelt-map-runner
  # shellcheck disable=SC2031 # fm_test_tmproot assigns the caller's variable by name.
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/docs" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/bin/fm-toolbelt-domain-map.py" <<'PY'
#!/usr/bin/env python3
import sys
print("fixture-domain-map-check-ran", file=sys.stderr)
sys.exit(1)
PY
  chmod +x "$repo/bin/fm-toolbelt-domain-map.py"
  cat >"$repo/docs/scripts.md" <<'MD'
| Script | Purpose |
| --- | --- |
| `fm-test-run.sh` | Fixture runner. |
MD
  : >"$repo/tests/fm-toolbelt-domain-map.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  rc=0
  out=$("$repo/bin/fm-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "--check-coverage returned $rc instead of the mapper guard failure"
  assert_contains "$out" "fixture-domain-map-check-ran" \
    "--check-coverage did not invoke the command-domain map check"

  printf '# mapper changed\n' >>"$repo/bin/fm-toolbelt-domain-map.py"
  assert_contains "$("$repo/bin/fm-test-run.sh" --list --changed --base HEAD)" \
    "tests/fm-toolbelt-domain-map.test.sh" \
    "changed mapper path did not select the command-domain map test"
  pass "coverage guard owns command-domain map freshness"
}

test_map_records_required_counts() {
  # shellcheck disable=SC2016 # This regex intentionally matches literal Markdown backticks.
  grep -Eq '^- Command count: [0-9][0-9]* top-level files in `bin/`\.$' "$MAP" \
    || fail "map must record command count"
  grep -Eq '^- Domain count: [0-9][0-9]* domains currently used\.$' "$MAP" \
    || fail "map must record domain count"
  grep -Eq '^- Ambiguous command count: [0-9][0-9]*\.$' "$MAP" \
    || fail "map must record ambiguous command count"
  grep -Eq '^- Unplaced command count: 0\.$' "$MAP" \
    || fail "map must record zero unplaced commands before completion"
  pass "map records the decision numbers"
}

test_committed_map_is_current
test_generation_is_deterministic
test_check_rejects_stale_map
test_check_rejects_unplaced_command
test_map_preserves_wrapped_purposes_and_path_kinds
test_coverage_guard_runs_map_check
test_map_records_required_counts
