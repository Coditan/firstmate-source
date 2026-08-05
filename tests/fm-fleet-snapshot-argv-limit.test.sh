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

# Rendering a 400-row backlog into a ~140 KB summary is slower than the child
# read's 8-second production default, and a timeout there degrades the record to
# the parent-event fallback - the exact shape this suite reports as a genuine
# regression. Pin a generous bound so a loaded runner cannot forge that signal.
CHILD_SUMMARY_TIMEOUT=${FM_TEST_CHILD_SUMMARY_TIMEOUT:-120}

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
  list-panes) printf '%%1 1\n'; exit 0 ;;
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
    FM_SNAPSHOT_SECONDMATE_TIMEOUT="$CHILD_SUMMARY_TIMEOUT" \
    "$SNAPSHOT" --secondmate-home-summary) || fail "child home summary failed"
  bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
  assert_over_ceiling "$bytes" "the child home summary fixture"
  [ "$bytes" -lt 262144 ] \
    || fail "child home summary is $bytes bytes, past the snapshot's own 262144-byte validation cap"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$main" FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 \
    FM_SNAPSHOT_SECONDMATE_TIMEOUT="$CHILD_SUMMARY_TIMEOUT" \
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

# The task inventory crosses the ceiling on its own axis: it grows with the
# number of live tasks, with no backlog involvement at all, and it reaches jq at
# four separate consumers. A home with enough tasks must still render.
#
# The fixture inflates each task row rather than writing the ~90 rows real growth
# would need, because per-task state reconciliation dominates the runtime; the
# axis under test is the size of the rendered inventory either way. Tasks carry
# no endpoint on purpose, which keeps the fixture from paying for backend probes.
test_oversized_task_inventory_still_renders() {
  local home i pad out bytes
  home=$(make_home oversized-tasks)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  pad=$(printf 'p%.0s' $(seq 1 2400))
  for i in $(seq 1 30); do
    fm_write_meta "$home/state/bulk-$(printf '%03d' "$i").meta" \
      "worktree=$home/projects/w-$pad$i" \
      "project=alpha-$pad$i" \
      "harness=codex" \
      "kind=ship" \
      "mode=ship"
  done

  out=$(FM_HOME="$home" "$SNAPSHOT" --json) \
    || fail "--json failed on a home with an oversized task inventory"
  bytes=$(printf '%s' "$out" | jq -c '.tasks' | LC_ALL=C wc -c | tr -d ' ')
  assert_over_ceiling "$bytes" "the rendered task inventory fixture"
  printf '%s' "$out" | jq -e '
    (.tasks | length) == 30
      and .secondmate_current.total == 0
      and (.secondmate_current.records | length) == 0
      and (.secondmate_landed.records | length) == 0
  ' >/dev/null || fail "oversized task inventory broke the secondmate aggregation: $(
      printf '%s' "$out" | jq -c '{tasks:(.tasks|length),sm:.secondmate_current.total}')"
  pass "oversized task inventory renders through every consumer that binds it"
}

# Plumbing the values through stdin must not soften the contract. The property
# that is genuinely new here is that a two-stage `json_stdin | jq` pipeline, with
# no `set -o pipefail`, still reports jq's non-zero status rather than the
# writer's - and does it while a large value is mid-flight, where the consumer
# exits without draining and the writer takes SIGPIPE.
#
# So the stub must fail a converted site, not the first jq the script happens to
# reach. It passes `-Rn` through to the real jq (that is backlog_json, an
# untouched call site that must succeed to build the oversized value) and fails
# only `-n`, the first of which is main_inventory_json - a converted site fed the
# whole rendered backlog.
test_hard_failure_still_surfaces() {
  local home fb err rc out
  home=$(make_home failure-semantics)
  write_oversized_backlog "$home" 400
  fb=$(fm_fakebin "$home")
  cat > "$fb/jq" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-n" ]; then
  echo "jq: simulated composition failure" >&2
  exit 5
fi
exec $(command -v jq) "\$@"
SH
  chmod +x "$fb/jq"

  err=$(PATH="$fb:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failing composition must not produce a successful snapshot"
  # Naming the stage proves execution reached a CONVERTED site: backlog_json is
  # untouched and would have reported "backlog read failed" instead.
  assert_contains "$err" "fm-fleet-snapshot: main inventory summary failed" \
    "a failing converted composition must name its own stage"
  # The writer dying on SIGPIPE must not leak shell diagnostics into the report.
  case "$err" in
    *[Bb]roken*pipe*|*"write error"*)
      fail "a failed composition leaked writer-side pipe noise: $err" ;;
  esac
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>/dev/null || true)
  [ -z "$out" ] || fail "a failing snapshot must not print a partial result"

  # With SIGPIPE at its default disposition the writer is killed silently, so the
  # clean report above does not actually pin the suppression. Production often
  # runs with SIGPIPE ignored - systemd services default to IgnoreSIGPIPE=yes and
  # the watcher units drive this script - and an inherited SIG_IGN survives
  # execve, so there Bash's builtin printf outlives the closed pipe and reports
  # the EPIPE itself. Re-run the same failure under that disposition: the report
  # must still be jq plus the named stage, with no writer diagnostic wedged
  # between them.
  err=$(PATH="$fb:$PATH" FM_HOME="$home" \
    bash -c 'trap "" PIPE; exec "$1" --json' _ "$SNAPSHOT" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a failing composition must not produce a successful snapshot with SIGPIPE ignored"
  assert_contains "$err" "fm-fleet-snapshot: main inventory summary failed" \
    "a failing converted composition must name its own stage with SIGPIPE ignored"
  case "$err" in
    *[Bb]roken*pipe*|*"write error"*)
      fail "a failed composition leaked writer-side pipe noise with SIGPIPE ignored: $err" ;;
  esac

  pass "a failed composition on a large piped value still exits non-zero and names its stage"
}

test_oversized_backlog_still_renders
test_oversized_task_inventory_still_renders
test_oversized_secondmate_home_stays_readable
test_hard_failure_still_surfaces
