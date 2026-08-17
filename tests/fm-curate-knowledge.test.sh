#!/usr/bin/env bash
# Behavior tests for /run-curate-knowledge's driver.
#
# The driver exists because a hand-run prune on 2026-08-16 moved content without
# curating it: headings went 232 -> 252, nothing was folded, and ten entries out
# of 254 vanished with no record of why. Each test below pins one of the gates
# that would have caught that, so a later refactor cannot quietly relax one.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$ROOT/.agents/skills/run-curate-knowledge/fm-curate-knowledge.py"
SKILL="$ROOT/.agents/skills/run-curate-knowledge/SKILL.md"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'skip: python3 not found\n'
  exit 0
fi

fm_test_tmproot TMP fm-curate-knowledge

# A miniature home whose bin/fm-session-start.sh names its context files the
# same way production does, so the extractor is exercised rather than mocked.
# The curation fixtures live inside this home because a documented route back is
# written to be run from the home, and the driver resolves and runs it there.
setup_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/data"
  cat >"$home/bin/fm-session-start.sh" <<'EOF'
#!/usr/bin/env bash
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
EOF
  printf '# Agents\n\nSome instruction body.\n' >"$home/AGENTS.md"
  printf '# Projects\n\nA project.\n' >"$home/data/projects.md"
  printf '# Captain\n\nA preference.\n' >"$home/data/captain.md"
}

# Three entries: one that will split, one that will fold into it, one that will
# be deleted with evidence.
write_before() {
  cat >"$1" <<'EOF'
# Store

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

## Alpha rule seen a second time

The same evening, the same measurement, told again.

## A path that no longer exists

Everything here concerns bin/gone.sh.
EOF
}

write_after_loaded() {
  cat >"$1" <<'EOF'
# Store

The incidents live in `after-archive.md`, which is not loaded.
Reach them with `grep -n '^## ' after-archive.md`.

- **Alpha rule**: the one sentence that must be in hand first.
EOF
}

write_after_archive() {
  cat >"$1" <<'EOF'
# Store archive

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

**Seen a second time the same evening:** told again.
EOF
}

write_worksheet() {
  cat >"$1" <<'EOF'
# fm-curate-knowledge worksheet v1
# shape: private
# level: 2

--- entry 1
key: alpha rule and the incident behind it#1
heading: Alpha rule and the incident behind it
verdict: split
why: rule now a bullet under Store in the loaded half

--- entry 2
key: alpha rule seen a second time#1
heading: Alpha rule seen a second time
verdict: fold
why: merged under Alpha rule and the incident behind it - one evening, one measurement

--- entry 3
key: a path that no longer exists#1
heading: A path that no longer exists
verdict: delete
why: bin/gone.sh is absent from the tree; git log -- bin/gone.sh returns nothing
EOF
}

# The whole exercise is priced in bytes because bytes per line is a house style
# and not a cost: 77 here against 211 at another seat. A line count invites a
# vessel to exonerate itself while carrying the identical load, so the driver
# refuses to print one rather than printing it with a caveat nobody reads.
test_line_counts_are_refused_as_a_headline_figure() {
  local out status
  out=$("$DRIVER" measure "$TMP/before.md" --lines --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "--lines exited $status, expected a refusal"
  printf '%s' "$out" | grep -q 'does not report line counts' \
    || fail "--lines refusal does not say what it refuses"
  printf '%s' "$out" | grep -q 'house style' \
    || fail "--lines refusal does not give the reason a line count misleads"

  out=$("$DRIVER" measure "$TMP/before.md" --home "$TMP" 2>&1)
  printf '%s' "$out" | grep -Eq '^[[:space:]]*lines' \
    && fail "measure printed a line count as a headline figure"
  printf '%s' "$out" | grep -q 'bytes' || fail "measure does not report bytes"
  pass "line counts are refused and bytes are reported instead"
}

# The denominator is extracted from bin/fm-session-start.sh rather than spelled
# out again here, so that script stays the single owner of what loads and the
# share cannot drift away from reality when the digest changes.
test_the_denominator_is_extracted_from_the_session_start_owner() {
  local out
  out=$("$DRIVER" measure --home "$TMP" 2>&1)
  printf '%s' "$out" | grep -q 'data/captain.md' \
    || fail "the surface does not include a file the digest prints"
  printf '%s' "$out" | grep -q 'bin/fm-session-start.sh context digest' \
    || fail "the surface does not attribute its file list to the digest owner"
  printf '%s' "$out" | grep -q 'AGENTS.md' \
    || fail "the surface omits AGENTS.md"

  # Removing a file from the digest must remove it from the denominator.
  local alt="$TMP/home-noc"
  setup_home "$alt"
  grep -v 'captain.md' "$TMP/bin/fm-session-start.sh" >"$alt/bin/fm-session-start.sh"
  out=$("$DRIVER" measure --home "$alt" 2>&1)
  printf '%s' "$out" | grep -q 'data/captain.md' \
    && fail "the denominator kept a file the digest no longer prints"
  pass "the denominator follows bin/fm-session-start.sh rather than a second list"
}

# The inventory must not decide anything. Its only opinion is that dividing an
# entry is the default, because leaving that as an option is what let 244
# entries move whole.
test_inventory_defaults_to_dividing_the_entry() {
  local out
  "$DRIVER" inventory "$TMP/before.md" --out "$TMP/ws.md" --home "$TMP" >/dev/null 2>&1 \
    || fail "inventory of a private file failed"
  [ "$(grep -c '^verdict: split' "$TMP/ws.md")" -eq 3 ] \
    || fail "private inventory does not pre-fill every verdict with split"
  assert_grep 'in hand BEFORE the problem appears' "$TMP/ws.md" \
    "the worksheet does not state the split criterion"
  assert_grep 'Age is not the test' "$TMP/ws.md" \
    "the worksheet does not rule age out as the axis"

  "$DRIVER" inventory "$TMP/AGENTS.md" --shape shared --out "$TMP/ws-shared.md" \
    --home "$TMP" >/dev/null 2>&1 || fail "inventory of a shared file failed"
  assert_grep 'verdict: stub' "$TMP/ws-shared.md" \
    "shared inventory does not pre-fill verdicts with stub"
  assert_no_grep 'verdict: cold' "$TMP/ws-shared.md" \
    "shared inventory offers a verdict that presupposes an archive"
  pass "the inventory defaults to dividing each entry and offers no cross-shape verdict"
}

# The gate that would have caught 232 -> 252. A split is heading-neutral, so the
# only things that move this number are folds and deletions.
test_a_flat_heading_count_is_a_failed_prune() {
  local out status
  # An after-state that moved everything and folded nothing.
  cat >"$TMP/flat-archive.md" <<'EOF'
# Store archive

## Alpha rule and the incident behind it
Body.

## Alpha rule seen a second time
Body.

## A path that no longer exists
Body.
EOF
  cat >"$TMP/flat-loaded.md" <<'EOF'
# Store

The rest is in `flat-archive.md`; reach it with `grep -n '^## ' flat-archive.md`.
EOF
  cat >"$TMP/flat-ws.md" <<'EOF'
--- entry 1
heading: Alpha rule and the incident behind it
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking

--- entry 2
heading: Alpha rule seen a second time
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking

--- entry 3
heading: A path that no longer exists
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/flat-ws.md" \
    --loaded "$TMP/flat-loaded.md" --archive "$TMP/flat-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a flat heading count exited $status, expected 1"
  printf '%s' "$out" | grep -q 'TOTAL heading count did not fall' \
    || fail "the flat-heading failure does not name the total heading count"
  printf '%s' "$out" | grep -q 'nothing is curated' \
    || fail "the flat-heading failure does not say what a flat total means"
  pass "a prune that moves entries whole exits non-zero"
}

# The defect the exercise exists to prevent: content that left with no record.
test_an_undeclared_deletion_fails_the_check() {
  local out status silent
  silent="$TMP/silent-archive.md"
  grep -v 'Seen a second time' "$TMP/after-archive.md" >"$silent"
  # Strip the surviving entry entirely, declaring nothing.
  cat >"$silent" <<'EOF'
# Store archive

Nothing survived here, and the worksheet still claims a split.
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --archive "$silent" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an undeclared deletion exited $status, expected 1"
  printf '%s' "$out" | grep -q 'disappeared with no verdict accounting for them' \
    || fail "the check does not name entries that vanished undeclared"
  pass "an entry that vanishes with no verdict fails the check"
}

# Rule 4: the bar for deleting is proof. A verdict of delete with a label
# instead of evidence is not a ledger entry.
test_a_deletion_without_evidence_fails() {
  local out status
  sed 's|^why: bin/gone.sh is absent.*|why: old|' "$TMP/ws-filled.md" >"$TMP/ws-thin.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-thin.md" \
    --loaded "$TMP/after-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a deletion with no evidence exited $status, expected 1"
  printf '%s' "$out" | grep -q 'only proof deletes' \
    || fail "the check does not state the bar a deletion must clear"
  pass "a deletion carrying a label instead of evidence fails the check"
}

test_phantom_delete_and_fold_declarations_fail() {
  local out status
  sed \
    -e '0,/verdict: split/s//verdict: delete/' \
    -e '0,/why: rule now/s//why: verified evidence claims this entry was removed/' \
    "$TMP/ws-filled.md" >"$TMP/ws-phantom-delete.md"
  out=$("$DRIVER" check --before "$TMP/before.json" \
    --worksheet "$TMP/ws-phantom-delete.md" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a phantom deletion exited $status, expected 1"
  # shellcheck disable=SC2016 # The driver's message contains literal backticks.
  printf '%s' "$out" | grep -q 'phantom deletion: `Alpha rule and the incident behind it`' \
    || fail "the phantom deletion failure does not name the still-present entry"

  out=$("$DRIVER" report --before "$TMP/before.json" \
    --worksheet "$TMP/ws-phantom-delete.md" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "report accepted a phantom deletion"
  printf '%s' "$out" | grep -q 'DELETION LEDGER' \
    && fail "report printed a deletion ledger containing a still-present entry"

  sed \
    -e '0,/verdict: split/s//verdict: fold/' \
    -e '0,/why: rule now/s//why: merged under Alpha rule and the incident behind it/' \
    "$TMP/ws-filled.md" >"$TMP/ws-phantom-fold.md"
  out=$("$DRIVER" check --before "$TMP/before.json" \
    --worksheet "$TMP/ws-phantom-fold.md" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a phantom fold exited $status, expected 1"
  # shellcheck disable=SC2016 # The driver's message contains literal backticks.
  printf '%s' "$out" | grep -q 'phantom fold: `Alpha rule and the incident behind it`' \
    || fail "the phantom fold failure does not name the still-present entry"
  pass "phantom delete and fold declarations fail before reporting"
}

test_unknown_worksheet_occurrence_keys_fail() {
  local out status
  cp "$TMP/ws-filled.md" "$TMP/ws-fabricated.md"
  cat >>"$TMP/ws-fabricated.md" <<'EOF'

--- entry 4
key: fabricated entry#1
heading: Fabricated entry
verdict: hot
why: this row was never present in the baseline snapshot
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" \
    --worksheet "$TMP/ws-fabricated.md" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a fabricated worksheet row exited $status, expected 1"
  # shellcheck disable=SC2016 # The driver's message contains literal backticks.
  printf '%s' "$out" | grep -q 'worksheet occurrence key `fabricated entry#1` is absent' \
    || fail "the fabricated worksheet key was not named"
  pass "worksheet occurrence keys must belong to the baseline"
}

# Rules 2 and 3: the route back lives inside the loaded half, and it is proved
# by running it rather than asserted.
test_the_route_back_must_live_in_the_loaded_half_and_run() {
  local out status
  cat >"$TMP/mute-loaded.md" <<'EOF'
# Store

- **Alpha rule**: the one sentence that must be in hand first.
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/mute-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a loaded half naming no archive exited $status, expected 1"
  printf '%s' "$out" | grep -q 'never names' \
    || fail "the check does not report a missing route back"

  # Naming the file is a location, not a route.
  cat >"$TMP/named-loaded.md" <<'EOF'
# Store

The incidents live in `after-archive.md`.

- **Alpha rule**: the one sentence that must be in hand first.
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/named-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a bare filename with no search exited $status, expected 1"
  printf '%s' "$out" | grep -q 'A filename is a location, not a route' \
    || fail "the check does not distinguish a location from a route"

  sed "s|grep -n '\^## '|grep -n '['|" "$TMP/after-loaded.md" >"$TMP/broken-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/broken-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a broken documented route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'documented route exited' \
    || fail "the broken documented route was not executed"

  mkdir -p "$TMP/wrong/directory"
  sed "s|grep -n '\^## ' after-archive.md|grep -n '^## ' wrong/directory/after-archive.md|" \
    "$TMP/after-loaded.md" >"$TMP/wrong-path-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/wrong-path-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a wrong documented path exited $status, expected 1"
  printf '%s' "$out" | grep -q 'documented route is broken from a normal shell' \
    || fail "a basename match silently repaired the wrong documented path"
  printf '%s' "$out" | grep -q 'wrong/directory/after-archive.md' \
    || fail "the route-path failure does not name the documented path"
  pass "the route back must be named and runnable inside the loaded half"
}

test_the_documented_route_must_reach_every_archived_entry() {
  local out status
  sed "s|grep -n '\^## '|grep -n 'Alpha rule'|" "$TMP/after-loaded.md" >"$TMP/partial-route-loaded.md"
  cat >>"$TMP/after-archive.md" <<'EOF'

## Unreachable incident

This heading is deliberately outside the documented search.
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/partial-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a partial route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived entries' \
    || fail "the route assertion does not report its complete reach count"
  printf '%s' "$out" | grep -q 'Unreachable incident' \
    || fail "the route failure does not name the unreachable heading"
  write_after_archive "$TMP/after-archive.md"
  pass "the documented route must reach every archived entry"
}

# A documented route is written to be run from the operational home: this home's
# real loaded half sends its reader to `grep -n '^## ' data/learnings-longterm.md`.
# Resolving that from anywhere else - the loaded file's own directory, say -
# turns a working route into a rejected one, so the home is the working
# directory and the command is executed exactly as documented.
test_a_home_relative_route_runs_from_the_home() {
  local out status
  write_before "$TMP/data/curated-before.md"
  # Written the way this home's real data/learnings.md is: the archive's
  # home-relative address in backticks, and then the search that reaches it.
  cat >"$TMP/data/curated-loaded.md" <<'EOF'
# Store

The incidents live in `data/curated-archive.md`, which is not loaded at session start.
Reach them with `grep -n '^## ' data/curated-archive.md`.

- **Alpha rule**: the one sentence that must be in hand first.
EOF
  write_after_archive "$TMP/data/curated-archive.md"
  "$DRIVER" measure "$TMP/data/curated-before.md" --home "$TMP" \
    --save "$TMP/curated-before.json" >/dev/null \
    || fail "measure could not snapshot the home-relative baseline"
  out=$("$DRIVER" check --before "$TMP/curated-before.json" \
    --worksheet "$TMP/ws-filled.md" --loaded "$TMP/data/curated-loaded.md" \
    --archive "$TMP/data/curated-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a home-relative route exited $status, expected 0: $out"
  printf '%s' "$out" | grep -Fq "grep -n '^## ' data/curated-archive.md" \
    || fail "the home-relative route was not executed as documented"
  printf '%s' "$out" | grep -q 'route reaches 1 of 1 archived entries' \
    || fail "the home-relative route did not reach every archived entry"

  # The same path with no command is still only an address.
  grep -v '^Reach them with' "$TMP/data/curated-loaded.md" >"$TMP/data/curated-address.md"
  out=$("$DRIVER" check --before "$TMP/curated-before.json" \
    --worksheet "$TMP/ws-filled.md" --loaded "$TMP/data/curated-address.md" \
    --archive "$TMP/data/curated-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a home-relative address with no search exited $status, expected 1"
  printf '%s' "$out" | grep -q 'A filename is a location, not a route' \
    || fail "a backticked home-relative path was accepted as the route itself"
  pass "a route written relative to the home is executed verbatim from the home"
}

test_nested_archive_headings_must_belong_to_an_entry() {
  local out status
  cat >"$TMP/orphan-archive.md" <<'EOF'
# Store archive

### Orphaned safety fact

This appears before any entry.

## Alpha rule and the incident behind it

The incident remains reachable through its entry.
EOF
  sed 's/after-archive.md/orphan-archive.md/g' \
    "$TMP/after-loaded.md" >"$TMP/orphan-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/orphan-loaded.md" --archive "$TMP/orphan-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an orphaned nested heading exited $status, expected 1"
  printf '%s' "$out" | grep -q 'nested archive headings are orphaned' \
    || fail "the structural failure does not identify an orphaned nested heading"
  printf '%s' "$out" | grep -q 'Orphaned safety fact' \
    || fail "the structural failure does not name the orphaned nested heading"

  cat >"$TMP/nested-before.md" <<'EOF'
# Store

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

### Nested incident detail

This remains inside its parent entry.

## Alpha rule seen a second time

The same evening, the same measurement, told again.

## A path that no longer exists

Everything here concerns bin/gone.sh.
EOF
  "$DRIVER" measure "$TMP/nested-before.md" --home "$TMP" \
    --save "$TMP/nested-before.json" >/dev/null \
    || fail "measure could not snapshot the nested baseline"
  cat >"$TMP/nested-archive.md" <<'EOF'
# Store archive

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

### Nested incident detail

This remains inside its parent entry.

**Seen a second time the same evening:** told again.
EOF
  sed 's/after-archive.md/nested-archive.md/g' \
    "$TMP/after-loaded.md" >"$TMP/nested-loaded.md"
  out=$("$DRIVER" check --before "$TMP/nested-before.json" \
    --worksheet "$TMP/ws-filled.md" --loaded "$TMP/nested-loaded.md" \
    --archive "$TMP/nested-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a nested heading inside its entry failed: $out"
  printf '%s' "$out" | grep -q 'route reaches 1 of 1 archived entries' \
    || fail "nested content incorrectly required a separate route record"
  pass "nested archive headings travel inside a structurally valid parent entry"
}

test_route_proof_cannot_write_real_files() {
  local before_hash escape_target fake_marker out status
  before_hash=$(sha256sum "$TMP/after-archive.md")
  sed "s|grep -n '\^## '|sed -i 's/Alpha/Changed/'|" \
    "$TMP/after-loaded.md" >"$TMP/sed-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/sed-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a sed -i route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'documented route failed' \
    || fail "the sed -i route was not reported as failed"
  # A refusal is the most security-relevant thing this gate says, so its reason
  # travels on the FAIL line rather than only in the narration above it.
  printf '%s' "$out" | grep -q 'FAIL  documented route failed: route command' \
    || fail "the refused route's FAIL line carries no reason"
  [ "$(sha256sum "$TMP/after-archive.md")" = "$before_hash" ] \
    || fail "the sed -i route changed the real archive"

  escape_target="/tmp/fm-curate-route-escape-$$"
  [ ! -e "$escape_target" ] || fail "the absolute escape target already exists"
  printf '# Store\n\nUse `awk '\''BEGIN { system("touch %s") } { print }'\'' after-archive.md`.\n' \
    "$escape_target" >"$TMP/awk-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/awk-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an awk system route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'cannot be proven non-writing; document the route with grep or rg' \
    || fail "the awk system route was not refused by the closed interface"
  [ ! -e "$escape_target" ] || fail "the refused awk route wrote to an absolute path"
  [ "$(sha256sum "$TMP/after-archive.md")" = "$before_hash" ] \
    || fail "the awk system route changed the real archive"

  sed "s|grep -n '\^## '|grep --include='*' -n '\^## '|" \
    "$TMP/after-loaded.md" >"$TMP/unknown-grep-flag-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/unknown-grep-flag-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an unknown grep flag exited $status, expected 1"
  printf '%s' "$out" | grep -q 'not in the closed read-only set' \
    || fail "the unknown grep flag was not rejected"
  printf '%s' "$out" | grep -q 'FAIL  documented route failed: route flag' \
    || fail "the rejected flag's FAIL line carries no reason"

  mkdir -p "$TMP/fake-bin"
  fake_marker="$TMP/fake-grep-ran"
  cat >"$TMP/fake-bin/grep" <<EOF
#!/usr/bin/env bash
touch "$fake_marker"
exit 0
EOF
  chmod +x "$TMP/fake-bin/grep"
  out=$(PATH="$TMP/fake-bin:$PATH" "$DRIVER" check --before "$TMP/before.json" \
    --worksheet "$TMP/ws-filled.md" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "trusted grep resolution failed: $out"
  [ ! -e "$fake_marker" ] || fail "route proof invoked a PATH-hijacked grep"
  printf '%s' "$out" | grep -Eq 'protected copy && /(usr/)?bin/grep ' \
    || fail "route transcript does not identify the trusted absolute binary"

  out=$(python3 - "$DRIVER" "$TMP" "$TMP/after-archive.md" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fm_curate_knowledge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = module.prove_route(
    "grep -n '^## ' after-archive.md",
    sys.argv[2],
    sys.argv[3],
    module.file_facts(sys.argv[3])["entries"],
    3,
    trusted_dirs=(),
)
print(result[3])
PY
  ) || fail "missing-trusted-binary probe crashed"
  # shellcheck disable=SC2016 # The driver's message contains literal backticks.
  printf '%s' "$out" | grep -q 'no trusted non-writable `grep` binary' \
    || fail "route proof degraded when no trusted binary resolved"
  pass "route proof cannot write the real archive"
}

test_duplicate_heading_occurrences_cannot_hide_a_deletion() {
  local out status
  cat >"$TMP/duplicate-before.md" <<'EOF'
# Store

## Repeated fact

First occurrence.

## Repeated fact

Second occurrence.
EOF
  "$DRIVER" measure "$TMP/duplicate-before.md" --home "$TMP" \
    --save "$TMP/duplicate-before.json" >/dev/null 2>&1
  "$DRIVER" inventory "$TMP/duplicate-before.md" --out "$TMP/duplicate-ws.md" \
    --home "$TMP" >/dev/null 2>&1
  sed -i 's/^verdict: split$/verdict: cold/; s/^why:$/why: the trigger arrives with the problem, so this stays searchable/' \
    "$TMP/duplicate-ws.md"
  cat >"$TMP/duplicate-loaded.md" <<'EOF'
# Store

Use `grep -n '^## ' duplicate-archive.md` to search the archive.
EOF
  cat >"$TMP/duplicate-archive.md" <<'EOF'
# Archive

## Repeated fact

Only one occurrence survived.
EOF
  out=$("$DRIVER" check --before "$TMP/duplicate-before.json" \
    --worksheet "$TMP/duplicate-ws.md" --loaded "$TMP/duplicate-loaded.md" \
    --archive "$TMP/duplicate-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a silently dropped duplicate exited $status, expected 1"
  printf '%s' "$out" | grep -q 'repeated fact#2' \
    || fail "the missing duplicate occurrence was not identified"
  pass "duplicate heading occurrences cannot hide an undeclared deletion"
}

test_duplicate_occurrences_can_split_across_both_halves() {
  local out status
  cat >"$TMP/duplicate-loaded-valid.md" <<'EOF'
# Store

Search with `grep -n '^## ' duplicate-archive-valid.md`.

## Repeated fact

The hot occurrence.
EOF
  cat >"$TMP/duplicate-archive-valid.md" <<'EOF'
# Archive

## Repeated fact

The cold occurrence.
EOF
  cat >"$TMP/duplicate-valid-ws.md" <<'EOF'
--- entry 1
key: repeated fact#1
heading: Repeated fact
verdict: hot
why: needed before the problem appears

--- entry 2
key: repeated fact#2
heading: Repeated fact
verdict: cold
why: searchable when the problem arrives
EOF
  out=$("$DRIVER" check --before "$TMP/duplicate-before.json" \
    --worksheet "$TMP/duplicate-valid-ws.md" --loaded "$TMP/duplicate-loaded-valid.md" \
    --archive "$TMP/duplicate-archive-valid.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "duplicate split fixture should fail only the required flat heading gate: $out"
  printf '%s' "$out" | grep -q 'disappeared with no verdict' \
    && fail "one duplicate in each half was falsely treated as a deletion"
  pass "duplicate occurrences remain accounted for across both halves"
}

test_duplicate_route_hits_are_counted() {
  local out status
  sed "s|grep -n '\^## '|grep -m1 -n '\^## '|" \
    "$TMP/duplicate-loaded.md" >"$TMP/duplicate-route-partial.md"
  cat >"$TMP/duplicate-archive-two.md" <<'EOF'
# Archive

## Repeated fact

First.

## Repeated fact

Second.
EOF
  sed 's/duplicate-archive.md/duplicate-archive-two.md/' \
    "$TMP/duplicate-route-partial.md" >"$TMP/duplicate-route-two.md"
  out=$("$DRIVER" check --before "$TMP/duplicate-before.json" \
    --worksheet "$TMP/duplicate-ws.md" --loaded "$TMP/duplicate-route-two.md" \
    --archive "$TMP/duplicate-archive-two.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a one-hit duplicate route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived entries' \
    || fail "duplicate route completeness did not count occurrences"

  # `-m` is in the closed read-only set in both its spellings, so a route using
  # the separated form is EXECUTED and then judged on coverage, rather than
  # refused as an unknown flag. A route flag accepted by one spelling and
  # unknown to the other is how an audited boundary stops describing itself.
  sed "s|grep -m1 -n|grep -m 1 -n|" \
    "$TMP/duplicate-route-two.md" >"$TMP/duplicate-route-spaced.md"
  out=$("$DRIVER" check --before "$TMP/duplicate-before.json" \
    --worksheet "$TMP/duplicate-ws.md" --loaded "$TMP/duplicate-route-spaced.md" \
    --archive "$TMP/duplicate-archive-two.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a separated -m route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived entries' \
    || fail "the separated -m form was not executed like the glued one"
  printf '%s' "$out" | grep -q 'not in the closed read-only set' \
    && fail "an enumerated read-only flag was rejected as unknown"
  pass "route completeness counts duplicate heading occurrences"
}

test_route_completeness_rejects_body_substrings() {
  local out status
  cat >"$TMP/body-substring-archive.md" <<'EOF'
## Repeated fact

Repeated fact

## Repeated fact

Second occurrence.
EOF
  cat >"$TMP/body-substring-loaded.md" <<'EOF'
# Store

Search with `grep -m2 -n -e '^## Repeated fact' -e '^Repeated fact$' body-substring-archive.md`.
EOF
  out=$("$DRIVER" check --before "$TMP/duplicate-before.json" \
    --worksheet "$TMP/duplicate-ws.md" --loaded "$TMP/body-substring-loaded.md" \
    --archive "$TMP/body-substring-archive.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "body substrings passed route completeness"
  printf '%s' "$out" | grep -q 'not a heading index record' \
    || fail "body prose was not rejected as non-record route output"
  pass "route completeness counts only heading index records"
}

# The route proof builds a protected copy, and where it builds it matters: run
# the documented way, `check` is invoked from the operational home, which this
# program promises never to write to. So the proof lands in TMPDIR, and a
# read-only working directory must not stop it.
test_the_route_proof_never_writes_the_working_directory() {
  local out status probe_dir leftover
  mkdir -p "$TMP/proof-tmpdir" "$TMP/readonly-cwd"
  chmod 0555 "$TMP/readonly-cwd"
  out=$(cd "$TMP/readonly-cwd" && TMPDIR="$TMP/proof-tmpdir" "$DRIVER" check \
    --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  chmod 0755 "$TMP/readonly-cwd"
  [ "$status" -eq 0 ] || fail "check failed from a read-only working directory: $out"
  [ -z "$(ls -A "$TMP/readonly-cwd")" ] \
    || fail "the route proof wrote into the working directory"
  [ -z "$(ls -A "$TMP/proof-tmpdir")" ] \
    || fail "the route proof left its protected directory behind in TMPDIR"

  # The protected bits are undone before removal, so a proof that ends any way
  # other than normally still hands back a removable directory.
  probe_dir=$(python3 - "$DRIVER" <<'PY'
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fm_curate_knowledge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = tempfile.mkdtemp(prefix="fm-route-proof-probe-")
with open(os.path.join(path, "archive.md"), "w", encoding="utf-8") as handle:
    handle.write("## Entry\n")
os.chmod(os.path.join(path, "archive.md"), 0o444)
os.chmod(path, 0o555)
module._register_proof_dir(path)
print(path)
PY
  ) || fail "proof-directory cleanup probe crashed"
  leftover=$(printf '%s' "$probe_dir" | tail -n1)
  [ -n "$leftover" ] || fail "the cleanup probe reported no directory"
  [ ! -e "$leftover" ] || fail "a protected proof directory survived the run"
  pass "the route proof builds in TMPDIR and leaves nothing behind"
}

# A prune gets eaten back, which is the whole argument for an instrument rather
# than a one-off cleanup. So every run after the first is a RE-RUN against an
# archive that already exists, and the before-state is then the PAIR: comparing
# a two-file after-state against one half fails a perfect curation on a heading
# total that was never comparable.
test_a_rerun_compares_against_the_existing_pair() {
  local out status
  cat >"$TMP/repeat-loaded.md" <<'EOF'
# Store

The incidents are not loaded at session start.
Reach them with `grep -n '^## ' repeat-archive-after.md`.

- **Alpha rule**: the one sentence that must be in hand first.

## New fact A and the incident behind it

The rule, then the incident that arrives with its own trigger.

## New fact A seen a second time

The same evening, the same measurement, told again.
EOF
  cat >"$TMP/repeat-archive.md" <<'EOF'
# Store archive

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

## An older incident kept for the record

Told once, in full, where a search will find it.
EOF
  "$DRIVER" measure "$TMP/repeat-loaded.md" "$TMP/repeat-archive.md" \
    --home "$TMP" --save "$TMP/repeat-before.json" >/dev/null \
    || fail "measure could not snapshot both halves of an existing pair"

  # The worksheet's keys are the ones inventory emits for the loaded half, so a
  # re-run curator inventories what grew rather than the whole archive.
  "$DRIVER" inventory "$TMP/repeat-loaded.md" --out "$TMP/repeat-inventory.md" \
    --home "$TMP" >/dev/null || fail "inventory of a re-run loaded half failed"
  assert_grep 'key: new fact a and the incident behind it#1' "$TMP/repeat-inventory.md" \
    "inventory does not emit the occurrence key a re-run worksheet names"
  assert_grep 'key: new fact a seen a second time#1' "$TMP/repeat-inventory.md" \
    "inventory does not emit the second occurrence key"
  [ "$(grep -c '^key: ' "$TMP/repeat-inventory.md")" -eq 2 ] \
    || fail "inventory of the loaded half asked for verdicts beyond it"

  cat >"$TMP/repeat-ws.md" <<'EOF'
--- entry 1
key: new fact a and the incident behind it#1
heading: New fact A and the incident behind it
verdict: split
why: rule now a bullet under Store in the loaded half

--- entry 2
key: new fact a seen a second time#1
heading: New fact A seen a second time
verdict: fold
why: merged under New fact A and the incident behind it - one evening, one measurement
EOF
  cat >"$TMP/repeat-loaded-after.md" <<'EOF'
# Store

The incidents are not loaded at session start.
Reach them with `grep -n '^## ' repeat-archive-after.md`.

- **Alpha rule**: the one sentence that must be in hand first.
- **New fact A**: the one sentence that must be in hand first.
EOF
  cat >"$TMP/repeat-archive-after.md" <<'EOF'
# Store archive

## Alpha rule and the incident behind it

The rule, then a long incident narrative that arrives with its own trigger.

## An older incident kept for the record

Told once, in full, where a search will find it.

## New fact A and the incident behind it

The rule, then the incident that arrives with its own trigger.

**Seen a second time the same evening:** told again.
EOF

  # The reported failure: the same correct curation judged against one half.
  out=$("$DRIVER" check --before "$TMP/repeat-before.json" \
    --before-file "$TMP/repeat-loaded.md" --worksheet "$TMP/repeat-ws.md" \
    --loaded "$TMP/repeat-loaded-after.md" --archive "$TMP/repeat-archive-after.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a single-half baseline accepted a re-run, expected 1"
  printf '%s' "$out" | grep -q 'TOTAL heading count did not fall: 3 -> 5' \
    || fail "the single-half baseline did not fail on the incomparable total"

  # The same curation against the pair it actually started from.
  out=$("$DRIVER" check --before "$TMP/repeat-before.json" \
    --before-loaded "$TMP/repeat-loaded.md" --before-archive "$TMP/repeat-archive.md" \
    --worksheet "$TMP/repeat-ws.md" --loaded "$TMP/repeat-loaded-after.md" \
    --archive "$TMP/repeat-archive-after.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a re-run against the pair baseline exited $status: $out"
  printf '%s' "$out" | grep -q 'HEADINGS  before 6  ->  after 5' \
    || fail "the pair baseline does not sum the before-state across both halves"
  printf '%s' "$out" | grep -q 'the before-state is the pair: loaded 3 + archive 3' \
    || fail "the check does not say which baseline mode it used"
  printf '%s' "$out" | grep -q 'route reaches 3 of 3 archived entries' \
    || fail "the re-run route proof did not reach every archived entry"

  out=$("$DRIVER" report --before "$TMP/repeat-before.json" \
    --before-loaded "$TMP/repeat-loaded.md" --before-archive "$TMP/repeat-archive.md" \
    --worksheet "$TMP/repeat-ws.md" --loaded "$TMP/repeat-loaded-after.md" \
    --archive "$TMP/repeat-archive-after.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "report refused a re-run against the pair baseline: $out"
  printf '%s' "$out" | grep -q 'before 6  ->  after 5' \
    || fail "the report does not carry the pair before-state"

  # The reason the archive belongs in the baseline: an entry that leaves it
  # silently must fail, and a single-half baseline can never see that.
  grep -v 'An older incident kept for the record' "$TMP/repeat-archive-after.md" \
    | grep -v 'Told once, in full' >"$TMP/repeat-archive-dropped.md"
  sed 's|repeat-archive-after.md|repeat-archive-dropped.md|g' \
    "$TMP/repeat-loaded-after.md" >"$TMP/repeat-loaded-dropped.md"
  out=$("$DRIVER" check --before "$TMP/repeat-before.json" \
    --before-loaded "$TMP/repeat-loaded.md" --before-archive "$TMP/repeat-archive.md" \
    --worksheet "$TMP/repeat-ws.md" --loaded "$TMP/repeat-loaded-dropped.md" \
    --archive "$TMP/repeat-archive-dropped.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a dropped archive entry exited $status, expected 1"
  printf '%s' "$out" | grep -q 'disappeared with no verdict accounting for them' \
    || fail "the pair baseline does not account for the existing archive's entries"
  printf '%s' "$out" | grep -q 'an older incident kept for the record' \
    || fail "the undeclared archive deletion was not named"

  # The mode is chosen from the arguments, never guessed.
  out=$("$DRIVER" check --before "$TMP/repeat-before.json" \
    --before-loaded "$TMP/repeat-loaded.md" --worksheet "$TMP/repeat-ws.md" \
    --loaded "$TMP/repeat-loaded-after.md" --archive "$TMP/repeat-archive-after.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "half a pair baseline exited $status, expected 2"
  printf '%s' "$out" | grep -q 'pass both or neither' \
    || fail "the incomplete pair baseline does not say what is missing"

  out=$("$DRIVER" check --before "$TMP/repeat-before.json" \
    --before-file "$TMP/repeat-loaded.md" \
    --before-loaded "$TMP/repeat-loaded.md" --before-archive "$TMP/repeat-archive.md" \
    --worksheet "$TMP/repeat-ws.md" --loaded "$TMP/repeat-loaded-after.md" \
    --archive "$TMP/repeat-archive-after.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "mixed baseline modes exited $status, expected 2"
  printf '%s' "$out" | grep -q 'cannot be combined' \
    || fail "mixing a single and a pair baseline was not refused"
  pass "a re-run is judged against the pair it started from"
}

# This driver's parse is fence-aware; the operator's `grep -n '^## '` is not and
# cannot be asked to be. So route records are matched by the line number grep
# already returned: a fenced example of a heading must not be able to stand in
# for the real entry it quotes, which a truncating route would read as full reach.
test_a_fenced_heading_cannot_stand_in_for_a_real_entry() {
  local out status
  cat >"$TMP/fence-before.md" <<'EOF'
# Store

## Alpha rule

The rule, and the incident that arrived with its own trigger attached.

## Beta rule

The second rule, with an incident narrative of its own to keep somewhere.

## Beta rule seen again

The same evening, the same measurement, told again at length.
EOF
  cat >"$TMP/fence-archive.md" <<'EOF'
```text
## Beta rule
```

## Alpha rule

The rule, and the incident that arrived with its own trigger attached.

## Beta rule

The second rule, with its incident narrative and the folded retelling.
EOF
  cat >"$TMP/fence-ws.md" <<'EOF'
--- entry 1
key: alpha rule#1
heading: Alpha rule
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking

--- entry 2
key: beta rule#1
heading: Beta rule
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking

--- entry 3
key: beta rule seen again#1
heading: Beta rule seen again
verdict: fold
why: merged under Beta rule in the archive, one evening and one measurement
EOF
  "$DRIVER" measure "$TMP/fence-before.md" --home "$TMP" \
    --save "$TMP/fence-before.json" >/dev/null \
    || fail "measure could not snapshot the fenced-example baseline"

  # The fenced `## Beta rule` sits above the real entries, so a truncating route
  # returns it plus one real entry and never reaches the real Beta rule.
  cat >"$TMP/fence-loaded-partial.md" <<'EOF'
# Store

- **Alpha rule**: the sentence that must be in hand first.
- **Beta rule**: the other sentence that must be in hand first.

Reach the incidents with `grep -m2 -n '^## ' fence-archive.md`.
EOF
  out=$("$DRIVER" check --before "$TMP/fence-before.json" \
    --worksheet "$TMP/fence-ws.md" --loaded "$TMP/fence-loaded-partial.md" \
    --archive "$TMP/fence-archive.md" --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a fenced look-alike route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived entries' \
    || fail "a fenced heading was counted as reaching the entry it quotes"
  printf '%s' "$out" | grep -q 'unreachable: Beta rule' \
    || fail "the unreached real entry was not named"

  cat >"$TMP/fence-loaded-full.md" <<'EOF'
# Store

- **Alpha rule**: the sentence that must be in hand first.
- **Beta rule**: the other sentence that must be in hand first.

Reach the incidents with `grep -n '^## ' fence-archive.md`.
EOF
  out=$("$DRIVER" check --before "$TMP/fence-before.json" \
    --worksheet "$TMP/fence-ws.md" --loaded "$TMP/fence-loaded-full.md" \
    --archive "$TMP/fence-archive.md" --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a complete route over a fenced archive exited $status: $out"
  printf '%s' "$out" | grep -q 'route reaches 2 of 2 archived entries' \
    || fail "a fence-unaware route was not reconciled with the real entries"
  pass "route records are matched by line number, so a fenced example proves nothing"
}

# The two halves of a pair routinely settle at different entry levels: a pruned
# loaded half of headings at one level, an archive of sections at another. Each
# half must be parsed at the level it was measured at, or a correct re-run reads
# as though the whole archive had been deleted.
test_a_pair_baseline_uses_each_halfs_own_entry_level() {
  local out status
  cat >"$TMP/level-loaded.md" <<'EOF'
# Store

Reach the incidents with `grep -n '^## ' level-archive-after.md`.

# New fact to curate

Body, learned since the last prune, whose trigger arrives with the problem.

# New fact seen a second time

The same evening, the same measurement, told again at length.
EOF
  cat >"$TMP/level-archive.md" <<'EOF'
## Existing archived entry

Told once, in full, where a search will find it again.

## Another archived entry

Also told once, and it must still be here when this is over.
EOF
  "$DRIVER" measure "$TMP/level-loaded.md" "$TMP/level-archive.md" \
    --home "$TMP" --save "$TMP/level-before.json" >/dev/null \
    || fail "measure could not snapshot a pair with two entry levels"
  cat >"$TMP/level-ws.md" <<'EOF'
--- entry 1
key: store#1
heading: Store
verdict: hot
why: the pointer and the rules are what must be in hand first

--- entry 2
key: new fact to curate#1
heading: New fact to curate
verdict: cold
why: the trigger arrives with the problem, so an agent will go looking

--- entry 3
key: new fact seen a second time#1
heading: New fact seen a second time
verdict: fold
why: merged under New fact to curate in the archive, one evening and one measurement
EOF
  cat >"$TMP/level-loaded-after.md" <<'EOF'
# Store

Reach the incidents with `grep -n '^## ' level-archive-after.md`.
EOF
  cat >"$TMP/level-archive-after.md" <<'EOF'
## Existing archived entry

Told once, in full, where a search will find it again.

## Another archived entry

Also told once, and it must still be here when this is over.

## New fact to curate

Body, learned since the last prune, whose trigger arrives with the problem.

**Seen a second time the same evening:** told again at length.
EOF
  out=$("$DRIVER" check --before "$TMP/level-before.json" \
    --before-loaded "$TMP/level-loaded.md" --before-archive "$TMP/level-archive.md" \
    --worksheet "$TMP/level-ws.md" --loaded "$TMP/level-loaded-after.md" \
    --archive "$TMP/level-archive-after.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a pair with two entry levels exited $status: $out"
  printf '%s' "$out" | grep -q 'entry level per half: loaded 1, archive 2' \
    || fail "the check does not carry each half's own entry level"
  printf '%s' "$out" | grep -q 'route reaches 3 of 3 archived entries' \
    || fail "the after-archive was not parsed at its own entry level"

  # The same pair, with an existing archive entry quietly dropped.
  grep -v 'Another archived entry' "$TMP/level-archive-after.md" \
    | grep -v 'Also told once' >"$TMP/level-archive-dropped.md"
  sed 's|level-archive-after.md|level-archive-dropped.md|g' \
    "$TMP/level-loaded-after.md" >"$TMP/level-loaded-dropped.md"
  out=$("$DRIVER" check --before "$TMP/level-before.json" \
    --before-loaded "$TMP/level-loaded.md" --before-archive "$TMP/level-archive.md" \
    --worksheet "$TMP/level-ws.md" --loaded "$TMP/level-loaded-dropped.md" \
    --archive "$TMP/level-archive-dropped.md" --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a dropped entry exited $status, expected 1"
  printf '%s' "$out" | grep -q 'another archived entry' \
    || fail "the dropped archive entry was not named"

  # One --level cannot mean two things, so it is refused rather than applied to
  # whichever half happens to be read first.
  out=$("$DRIVER" check --before "$TMP/level-before.json" \
    --before-loaded "$TMP/level-loaded.md" --before-archive "$TMP/level-archive.md" \
    --worksheet "$TMP/level-ws.md" --loaded "$TMP/level-loaded-after.md" \
    --archive "$TMP/level-archive-after.md" --level 2 --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "--level with a pair baseline exited $status, expected 2"
  printf '%s' "$out" | grep -q 'ambiguous with a pair baseline' \
    || fail "an ambiguous --level was silently applied to one half"
  pass "each half of a pair baseline is parsed at its own entry level"
}

test_measure_json_is_one_document() {
  "$DRIVER" measure "$TMP/before.md" --home "$TMP" --json \
    2>"$TMP/measure-json.stderr" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "measure --json stdout is not one JSON document"
  pass "measure JSON output is one machine-readable document"
}

# The two shapes must never borrow each other's method. An AGENTS.md archive
# would be a second owner of material stated once by contract.
test_the_two_shapes_never_borrow_each_others_method() {
  local out status
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --archive "$TMP/after-archive.md" \
    --shape shared --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "--archive with --shape shared exited $status, expected 1"
  printf '%s' "$out" | grep -q 'would be a second owner' \
    || fail "the archive refusal does not give the one-owner reason"

  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --shape private --home "$TMP" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "shape private with no archive exited $status, expected 1"
  printf '%s' "$out" | grep -q 'nothing to prove reachable' \
    || fail "the missing-archive refusal does not say what is lost"
  pass "an archive is refused for a shared file and required for a private one"
}

# A real curation - one split, one fold, one evidenced deletion - passes, and
# the report carries the ledger.
test_a_real_curation_passes_and_the_report_carries_the_ledger() {
  local out status
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a real curation exited $status, expected 0: $out"
  printf '%s' "$out" | grep -q 'CHECK PASSED' || fail "a real curation did not pass"
  printf '%s' "$out" | grep -q 'COMPLETE ROUTE ASSERTION' \
    || fail "a passing check does not print the executed recovery"
  printf '%s' "$out" | grep -Eq '^  \$ \(protected copy && /(usr/)?bin/grep' \
    || fail "the recovery proof shows no command it actually ran"

  out=$("$DRIVER" report --before "$TMP/before.json" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --worksheet "$TMP/ws-filled.md" \
    --home "$TMP" 2>&1) || fail "report failed on a passing curation"
  printf '%s' "$out" | grep -q 'DELETION LEDGER (1)' \
    || fail "the report does not count the deletions"
  printf '%s' "$out" | grep -q 'git log -- bin/gone.sh' \
    || fail "the report does not print the evidence that killed a deleted entry"
  printf '%s' "$out" | grep -q 'of the original still loads' \
    || fail "the report does not state the change in startup cost"
  pass "a real curation passes and its report carries the deletion ledger"
}

# The ledger is the only record a deleted entry ever gets, so a report that can
# be produced without one reports everything except the auditable part.
test_a_report_cannot_omit_the_deletion_ledger() {
  local out status
  out=$("$DRIVER" report --before "$TMP/before.json" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --home "$TMP" 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "report with no worksheet exited $status, expected 2"
  printf '%s' "$out" | grep -q -- '--worksheet' \
    || fail "the report usage error does not name the required worksheet"
  printf '%s' "$out" | grep -q 'DELETION LEDGER' \
    && fail "report printed a ledger-less report instead of refusing"
  pass "a report cannot be produced without the worksheet that carries the ledger"
}

# The skill must be reachable and must not claim a command the driver lacks.
test_skill_declares_its_trigger_and_only_real_subcommands() {
  assert_present "$SKILL" "run-curate-knowledge SKILL.md is missing"
  # This is the owned skill-trigger contract enforced fleet-wide by
  # tests/fm-instruction-owners.test.sh, not a proxy for model behavior.
  fm_skill_frontmatter "$ROOT/.agents/skills/run-curate-knowledge" \
    | grep -qx 'name: run-curate-knowledge' \
    || fail "skill name is not the directory name"
  fm_skill_frontmatter "$ROOT/.agents/skills/run-curate-knowledge" \
    | grep -qx 'user-invocable: true' \
    || fail "skill must stay captain-invocable"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_no_grep '- `run-curate-knowledge` - ' "$ROOT/AGENTS.md" \
    "a captain-invocable skill must not be listed in AGENTS.md section 13"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'load the `run-curate-knowledge` skill' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the run-curate-knowledge load trigger"

  local word
  for word in prune split curate measure learnings AGENTS.md; do
    fm_skill_description "$ROOT/.agents/skills/run-curate-knowledge" \
      | grep -Fq -- "$word" \
      || fail "skill description omits the verb or noun an agent would type: $word"
  done

  local sub
  for sub in measure inventory check report; do
    assert_grep "fm-curate-knowledge.py $sub" "$SKILL" \
      "SKILL.md does not show the $sub command"
    "$DRIVER" "$sub" --help >/dev/null 2>&1 \
      || fail "SKILL.md names a subcommand the driver does not have: $sub"
  done
  pass "the skill is triggered, describes itself in an agent's words, and names only real subcommands"
}

setup_home "$TMP"
write_before "$TMP/before.md"
write_after_loaded "$TMP/after-loaded.md"
write_after_archive "$TMP/after-archive.md"
write_worksheet "$TMP/ws-filled.md"
"$DRIVER" measure "$TMP/before.md" --home "$TMP" --save "$TMP/before.json" >/dev/null \
  || fail "measure could not snapshot the baseline"

test_line_counts_are_refused_as_a_headline_figure
test_the_denominator_is_extracted_from_the_session_start_owner
test_inventory_defaults_to_dividing_the_entry
test_a_flat_heading_count_is_a_failed_prune
test_an_undeclared_deletion_fails_the_check
test_a_deletion_without_evidence_fails
test_phantom_delete_and_fold_declarations_fail
test_unknown_worksheet_occurrence_keys_fail
test_the_route_back_must_live_in_the_loaded_half_and_run
test_the_documented_route_must_reach_every_archived_entry
test_a_home_relative_route_runs_from_the_home
test_nested_archive_headings_must_belong_to_an_entry
test_route_proof_cannot_write_real_files
test_duplicate_heading_occurrences_cannot_hide_a_deletion
test_duplicate_occurrences_can_split_across_both_halves
test_duplicate_route_hits_are_counted
test_route_completeness_rejects_body_substrings
test_the_route_proof_never_writes_the_working_directory
test_a_rerun_compares_against_the_existing_pair
test_a_fenced_heading_cannot_stand_in_for_a_real_entry
test_a_pair_baseline_uses_each_halfs_own_entry_level
test_measure_json_is_one_document
test_the_two_shapes_never_borrow_each_others_method
test_a_real_curation_passes_and_the_report_carries_the_ledger
test_a_report_cannot_omit_the_deletion_ledger
test_skill_declares_its_trigger_and_only_real_subcommands
