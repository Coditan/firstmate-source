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
  out=$("$DRIVER" measure "$TMP/before.md" --lines --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "--lines exited $status, expected a refusal"
  printf '%s' "$out" | grep -q 'does not report line counts' \
    || fail "--lines refusal does not say what it refuses"
  printf '%s' "$out" | grep -q 'house style' \
    || fail "--lines refusal does not give the reason a line count misleads"

  out=$("$DRIVER" measure "$TMP/before.md" --home "$TMP/home" 2>&1)
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
  out=$("$DRIVER" measure --home "$TMP/home" 2>&1)
  printf '%s' "$out" | grep -q 'data/captain.md' \
    || fail "the surface does not include a file the digest prints"
  printf '%s' "$out" | grep -q 'bin/fm-session-start.sh context digest' \
    || fail "the surface does not attribute its file list to the digest owner"
  printf '%s' "$out" | grep -q 'AGENTS.md' \
    || fail "the surface omits AGENTS.md"

  # Removing a file from the digest must remove it from the denominator.
  local alt="$TMP/home-noc"
  cp -r "$TMP/home" "$alt"
  grep -v 'captain.md' "$TMP/home/bin/fm-session-start.sh" >"$alt/bin/fm-session-start.sh"
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
  "$DRIVER" inventory "$TMP/before.md" --out "$TMP/ws.md" --home "$TMP/home" >/dev/null 2>&1 \
    || fail "inventory of a private file failed"
  [ "$(grep -c '^verdict: split' "$TMP/ws.md")" -eq 3 ] \
    || fail "private inventory does not pre-fill every verdict with split"
  assert_grep 'in hand BEFORE the problem appears' "$TMP/ws.md" \
    "the worksheet does not state the split criterion"
  assert_grep 'Age is not the test' "$TMP/ws.md" \
    "the worksheet does not rule age out as the axis"

  "$DRIVER" inventory "$TMP/home/AGENTS.md" --shape shared --out "$TMP/ws-shared.md" \
    --home "$TMP/home" >/dev/null 2>&1 || fail "inventory of a shared file failed"
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
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
    --loaded "$TMP/after-loaded.md" --archive "$silent" --home "$TMP/home" 2>&1) \
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a deletion with no evidence exited $status, expected 1"
  printf '%s' "$out" | grep -q 'only proof deletes' \
    || fail "the check does not state the bar a deletion must clear"
  pass "a deletion carrying a label instead of evidence fails the check"
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a bare filename with no search exited $status, expected 1"
  printf '%s' "$out" | grep -q 'A filename is a location, not a route' \
    || fail "the check does not distinguish a location from a route"

  sed "s|grep -n '\^## '|grep -n '['|" "$TMP/after-loaded.md" >"$TMP/broken-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/broken-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a broken documented route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'documented route exited' \
    || fail "the broken documented route was not executed"
  pass "the route back must be named and runnable inside the loaded half"
}

test_the_documented_route_must_reach_every_archived_heading() {
  local out status
  sed "s|grep -n '\^## '|grep -n 'Alpha rule'|" "$TMP/after-loaded.md" >"$TMP/partial-route-loaded.md"
  cat >>"$TMP/after-archive.md" <<'EOF'

## Unreachable incident

This heading is deliberately outside the documented search.
EOF
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/partial-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a partial route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived headings' \
    || fail "the route assertion does not report its complete reach count"
  printf '%s' "$out" | grep -q 'Unreachable incident' \
    || fail "the route failure does not name the unreachable heading"
  write_after_archive "$TMP/after-archive.md"
  pass "the documented route must reach every archived heading"
}

test_route_proof_cannot_write_real_files() {
  local before_hash escape_target out status
  before_hash=$(sha256sum "$TMP/after-archive.md")
  sed "s|grep -n '\^## '|sed -i 's/Alpha/Changed/'|" \
    "$TMP/after-loaded.md" >"$TMP/sed-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/sed-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a sed -i route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'documented route failed' \
    || fail "the sed -i route was not reported as failed"
  [ "$(sha256sum "$TMP/after-archive.md")" = "$before_hash" ] \
    || fail "the sed -i route changed the real archive"

  escape_target="/tmp/fm-curate-route-escape-$$"
  [ ! -e "$escape_target" ] || fail "the absolute escape target already exists"
  printf '# Store\n\nUse `awk '\''BEGIN { system("touch %s") } { print }'\'' after-archive.md`.\n' \
    "$escape_target" >"$TMP/awk-route-loaded.md"
  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/awk-route-loaded.md" --archive "$TMP/after-archive.md" \
    --home "$TMP/home" 2>&1) && status=0 || status=$?
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an unknown grep flag exited $status, expected 1"
  printf '%s' "$out" | grep -q 'not in the closed read-only set' \
    || fail "the unknown grep flag was not rejected"
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
  "$DRIVER" measure "$TMP/duplicate-before.md" --home "$TMP/home" \
    --save "$TMP/duplicate-before.json" >/dev/null 2>&1
  "$DRIVER" inventory "$TMP/duplicate-before.md" --out "$TMP/duplicate-ws.md" \
    --home "$TMP/home" >/dev/null 2>&1
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
    --archive "$TMP/duplicate-archive.md" --home "$TMP/home" 2>&1) \
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
    --archive "$TMP/duplicate-archive-valid.md" --home "$TMP/home" 2>&1) \
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
    --archive "$TMP/duplicate-archive-two.md" --home "$TMP/home" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "a one-hit duplicate route exited $status, expected 1"
  printf '%s' "$out" | grep -q 'route reaches 1 of 2 archived headings' \
    || fail "duplicate route completeness did not count occurrences"
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
    --archive "$TMP/body-substring-archive.md" --home "$TMP/home" 2>&1) \
    && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "body substrings passed route completeness"
  printf '%s' "$out" | grep -q 'not a heading index record' \
    || fail "body prose was not rejected as non-record route output"
  pass "route completeness counts only heading index records"
}

test_measure_json_is_one_document() {
  "$DRIVER" measure "$TMP/before.md" --home "$TMP/home" --json \
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
    --shape shared --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "--archive with --shape shared exited $status, expected 1"
  printf '%s' "$out" | grep -q 'would be a second owner' \
    || fail "the archive refusal does not give the one-owner reason"

  out=$("$DRIVER" check --before "$TMP/before.json" --worksheet "$TMP/ws-filled.md" \
    --loaded "$TMP/after-loaded.md" --shape private --home "$TMP/home" 2>&1) \
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
    --home "$TMP/home" 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "a real curation exited $status, expected 0: $out"
  printf '%s' "$out" | grep -q 'CHECK PASSED' || fail "a real curation did not pass"
  printf '%s' "$out" | grep -q 'COMPLETE ROUTE ASSERTION' \
    || fail "a passing check does not print the executed recovery"
  printf '%s' "$out" | grep -q '^  \$ (protected copy && grep' \
    || fail "the recovery proof shows no command it actually ran"

  out=$("$DRIVER" report --before "$TMP/before.json" --loaded "$TMP/after-loaded.md" \
    --archive "$TMP/after-archive.md" --worksheet "$TMP/ws-filled.md" \
    --home "$TMP/home" 2>&1) || fail "report failed on a passing curation"
  printf '%s' "$out" | grep -q 'DELETION LEDGER (1)' \
    || fail "the report does not count the deletions"
  printf '%s' "$out" | grep -q 'git log -- bin/gone.sh' \
    || fail "the report does not print the evidence that killed a deleted entry"
  printf '%s' "$out" | grep -q 'of the original still loads' \
    || fail "the report does not state the change in startup cost"
  pass "a real curation passes and its report carries the deletion ledger"
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

setup_home "$TMP/home"
write_before "$TMP/before.md"
write_after_loaded "$TMP/after-loaded.md"
write_after_archive "$TMP/after-archive.md"
write_worksheet "$TMP/ws-filled.md"
"$DRIVER" measure "$TMP/before.md" --home "$TMP/home" --save "$TMP/before.json" >/dev/null \
  || fail "measure could not snapshot the baseline"

test_line_counts_are_refused_as_a_headline_figure
test_the_denominator_is_extracted_from_the_session_start_owner
test_inventory_defaults_to_dividing_the_entry
test_a_flat_heading_count_is_a_failed_prune
test_an_undeclared_deletion_fails_the_check
test_a_deletion_without_evidence_fails
test_the_route_back_must_live_in_the_loaded_half_and_run
test_the_documented_route_must_reach_every_archived_heading
test_route_proof_cannot_write_real_files
test_duplicate_heading_occurrences_cannot_hide_a_deletion
test_duplicate_occurrences_can_split_across_both_halves
test_duplicate_route_hits_are_counted
test_route_completeness_rejects_body_substrings
test_measure_json_is_one_document
test_the_two_shapes_never_borrow_each_others_method
test_a_real_curation_passes_and_the_report_carries_the_ledger
test_skill_declares_its_trigger_and_only_real_subcommands
