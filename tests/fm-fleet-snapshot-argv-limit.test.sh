#!/usr/bin/env bash
# Regression tests for the argv-size ceiling in the read-only fleet snapshot.
#
# jq's --argjson hands its value to execve as ONE argv string, and Linux caps a
# single argv string at MAX_ARG_STRLEN (131072 bytes) independently of the much
# larger total ARG_MAX. Every jq composition in bin/fm-fleet-snapshot.sh that
# passed an unbounded aggregate that way died with "Argument list too long" once
# a home outgrew the ceiling, and the failure was total: --json, the secondmate
# home summary, and the bearings projection over them all produced no output.
#
# These tests drive the script with synthetic oversized input. Real captain
# backlogs are private and are never used as fixtures.
#
# On platforms with no per-argument cap (macOS bounds only total ARG_MAX) the
# pre-fix code survives these fixtures, so only the post-fix assertions are
# portable; the failure they pin is observed on Linux.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
fm_test_tmproot TMP_ROOT fm-fleet-snapshot-argv

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The ceiling this suite exists to defend. Kept as a literal so a fixture that
# stops crossing it is a test failure rather than a silent no-op.
ARGV_STRING_LIMIT=131072

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Write a backlog with <count> landed rows, each padded so the rendered JSON
# grows well past the argv ceiling. Synthetic throughout: no captain content.
write_oversized_backlog() {  # <home> <count>
  local home=$1 count=$2 i pad
  pad=$(printf 'padding%.0s' $(seq 1 24))
  {
    printf '## In flight\n\n## Queued\n\n## Done\n'
    for i in $(seq 1 "$count"); do
      printf -- '- [x] synth-%04d - Synthetic landed item %04d %s (repo: synth) (kind: ship) (merged 2026-07-0%d)\n' \
        "$i" "$i" "$pad" "$((i % 9 + 1))"
    done
  } > "$home/data/backlog.md"
}

assert_over_ceiling() {  # <bytes> <what>
  [ "$1" -gt "$ARGV_STRING_LIMIT" ] \
    || fail "$2 is $1 bytes, no longer over the $ARGV_STRING_LIMIT-byte argv ceiling this test defends"
}

# A backlog whose rendered JSON exceeds MAX_ARG_STRLEN must still produce a
# complete snapshot, home summary, and bearings projection. Before the fix all
# three aborted with "Argument list too long" and emitted nothing at all.
test_oversized_backlog_still_renders() {
  local home out rc bytes records summary bearings
  home=$(make_home oversized-backlog)
  write_oversized_backlog "$home" 400

  out=$(FM_HOME="$home" "$SNAPSHOT" --backlog-json) \
    || fail "--backlog-json failed on an oversized backlog"
  bytes=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')
  assert_over_ceiling "$bytes" "the rendered backlog fixture"

  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--json exited $rc on an oversized backlog"
  printf '%s' "$out" | jq -e . >/dev/null || fail "--json output is not valid JSON on an oversized backlog"
  records=$(printf '%s' "$out" | jq '.backlog.records | length')
  [ "$records" -eq 400 ] \
    || fail "oversized snapshot dropped backlog records: got $records, want 400"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null || fail "oversized snapshot lost its main inventory summary"

  summary=$(FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--secondmate-home-summary exited $rc on an oversized backlog"
  printf '%s' "$summary" | jq -e '
    .schema == "fm-secondmate-home-summary.v1" and .counts.landed == 400
  ' >/dev/null || fail "oversized home summary is incomplete: $(printf '%s' "$summary" | head -c 200)"

  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "bearings exited $rc on an oversized backlog"
  printf '%s' "$bearings" | jq -e '.schema == "fm-bearings.v1"' >/dev/null \
    || fail "bearings projection lost its schema on an oversized backlog"

  pass "oversized backlog renders a complete snapshot, home summary, and bearings projection"
}

# The aggregation path has its own ceiling crossing: a registered secondmate's
# home summary is accepted up to FM_SNAPSHOT_SECONDMATE_MAX_BYTES (262144), which
# is ABOVE the 131072-byte argv ceiling. Before the fix such a home failed
# silently - exit 0, but the whole home reported "unknown"/unreadable with its
# landed work erased - which is worse than the loud abort.
test_oversized_secondmate_home_stays_readable() {
  local main mate fakebin summary bytes out
  main=$(make_home aggregate-main)
  mate=$(make_home aggregate-mate)
  printf 'mate' > "$mate/.fm-secondmate-home"
  cp "$ROOT/AGENTS.md" "$mate/AGENTS.md"
  ln -s "$ROOT/bin" "$mate/bin"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$main/data/backlog.md"
  printf -- '- mate (home: %s; scope: synthetic)\n' "$mate" > "$main/data/secondmates.md"
  fm_write_meta "$main/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$mate" \
    "project=$mate" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$mate" \
    "state=active"
  printf 'working: watching delegated scope\n' > "$main/state/mate.status"
  write_oversized_backlog "$mate" 400
  fakebin=$(make_fakebin "$main")

  # An unbounded per-home landed cap is what lets one home's summary cross the
  # argv ceiling while still passing the snapshot's own byte validation.
  summary=$(PATH="$fakebin:$PATH" FM_HOME="$mate" FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 \
    "$SNAPSHOT" --secondmate-home-summary) || fail "child home summary failed"
  bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
  assert_over_ceiling "$bytes" "the child home summary fixture"
  [ "$bytes" -lt 262144 ] \
    || fail "child home summary is $bytes bytes, past the snapshot's own 262144-byte validation cap"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$main" FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 \
    "$SNAPSHOT" --json) || fail "--json failed with an oversized secondmate home"
  printf '%s' "$out" | jq -e '
    .secondmate_current.records | length == 1
  ' >/dev/null || fail "the registered secondmate vanished from the aggregation"
  printf '%s' "$out" | jq -e '
    .secondmate_current.records[0]
    | .provenance.selected == "structured-home"
      and .current.state != "unknown"
      and (.landed | length) == 400
  ' >/dev/null || fail "oversized secondmate home degraded to a fallback instead of structured state: $(
      printf '%s' "$out" | jq -c '.secondmate_current.records[0] | {state:.current.state,reason:.current.reason,selected:.provenance.selected}')"
  printf '%s' "$out" | jq -e '
    (.secondmate_landed.records | length) == 400
      and (.secondmate_landed.unreadable | length) == 0
      and (.secondmate_landed.partial | length) == 0
  ' >/dev/null || fail "landed roll-up lost an oversized secondmate home: $(
      printf '%s' "$out" | jq -c '.secondmate_landed | {n:(.records|length),unreadable,partial}')"

  pass "oversized secondmate home summary stays structured and keeps its landed work"
}

# Plumbing the values through stdin must not soften the contract: a jq failure
# still has to surface as a non-zero exit and a named stage, never as a silent
# empty result.
test_hard_failure_still_surfaces() {
  local home fakebin fb err rc out
  home=$(make_home failure-semantics)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  # A jq that refuses every composition is the cheapest way to prove the callers
  # still check status. It must not shadow the real jq during the fixture build.
  fb=$fakebin
  cat > "$fb/jq" <<'SH'
#!/usr/bin/env bash
echo "jq: simulated composition failure" >&2
exit 5
SH
  chmod +x "$fb/jq"
  err=$(PATH="$fb:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failing jq must not produce a successful snapshot"
  assert_contains "$err" "fm-fleet-snapshot:" "a failing composition must name the stage that failed"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>/dev/null || true)
  [ -z "$out" ] || fail "a failing snapshot must not print a partial result"
  pass "a failed composition still exits non-zero and names its stage"
}

test_oversized_backlog_still_renders
test_oversized_secondmate_home_stays_readable
test_hard_failure_still_surfaces
