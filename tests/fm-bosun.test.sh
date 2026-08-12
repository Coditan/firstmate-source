#!/usr/bin/env bash
# tests/fm-bosun.test.sh - the observer-only bosun (bin/fm-bosun-lib.sh,
# bin/fm-bosun.sh).
#
# The first case is the one that matters and it is the reason this unit exists:
# a bosun that has stopped judging must be distinguishable from one that judged
# nothing because nothing happened. A run was found on 2026-08-12 with its
# process alive, its log growing, and no work produced for seventeen hours, so
# "the process is up" is exactly the evidence that does not settle it. The case
# asserts BOTH directions against the same fixture - quiet reads healthy, stalled
# reads unhealthy - because a check that only ever reports one of them proves
# nothing about its ability to tell them apart.
#
# Events reach the journal through the REAL wake library rather than by writing
# journal rows by hand, so the bosun is read against the record a real producer
# leaves. Judges are fakes on purpose: this suite tests the bosun's handling of
# every judge outcome, and a real model cannot be made to time out on demand.
# The default judge's own model choice is provisional and documented as such in
# docs/bosun-observer.md; nothing here asserts a model's opinion.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BOSUN="$ROOT/bin/fm-bosun.sh"

fm_test_tmproot TMP_ROOT fm-bosun-tests

# Build a case with its own state dir and a judge of the requested shape.
# The judge is a real executable, so the bosun reaches it exactly as it would
# reach a model wrapper.
make_bosun_case() {  # <name> <judge-body>
  local name=$1 body=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$body" > "$dir/judge"
  chmod +x "$dir/judge"
  printf '%s\n' "$dir"
}

# Single-quoted on purpose: this is the SOURCE of a judge script, and its own
# expansions must survive into the file rather than being resolved here.
# shellcheck disable=SC2016
JUDGE_SANE='#!/usr/bin/env bash
ev=$(cat)
if printf "%s" "$ev" | grep -q blocked; then
  echo "{\"verdict\":\"escalate\",\"confidence\":\"high\",\"reason\":\"blocker\",\"judge\":\"fake\"}"
else
  echo "{\"verdict\":\"routine\",\"confidence\":\"high\",\"reason\":\"progress\",\"judge\":\"fake\"}"
fi'

# Queue one real wake through the production library, having first moved the
# task's status file, so the journal record carries a real arrival-time capture.
emit_event() {  # <state> <task> <status-line>
  printf '%s\n' "$3" >> "$1/$2.status"
  append_wake "$1" signal "$2.status" "$2 needs attention"
}

bosun() {  # <state> <judge> <args...>
  local state=$1 judge=$2
  shift 2
  FM_STATE_OVERRIDE="$state" FM_BOSUN_JUDGE_CMD="$judge" "$BOSUN" "$@"
}

# --- 1. quiet is not dead, and stalled is not quiet --------------------------
#
# One fixture, three readings, driven by the real run loop.

dir=$(make_bosun_case quiet-vs-stalled "$JUDGE_SANE")
state="$dir/state"

# (a) A bosun that has run against an empty journal is QUIET, not dead. It has
#     judged nothing, and that is the healthy outcome of nothing having happened.
bosun "$state" "$dir/judge" run --once > /dev/null 2>&1
# The run's own clean exit records STOPPED, which is a third thing again; re-arm
# the record as a live one so this case reads the quiet/stalled axis rather than
# the running/exited one. Only the two fields a live loop would have written.
mark_running() {  # <state>
  local health="$1/bosun/health" now
  now=$(date +%s)
  sed -i.bak -e "s/^state: .*/state: running/" -e "s/^last_pass: .*/last_pass: $now/" "$health"
  rm -f "$health.bak"
}
mark_running "$state"

out=$(bosun "$state" "$dir/judge" status); rc=$?
assert_contains "$out" "QUIET" "an idle bosun with an empty journal reports QUIET"
[ "$rc" -eq 0 ] || fail "QUIET must exit 0, got $rc"
pass "quiet bosun reads healthy and exits 0"

# (b) Now give it work AND break its ability to record a verdict. The loop keeps
#     passing, the journal keeps growing, and no work comes out - the exact
#     seventeen-hour shape, reproduced rather than described.
emit_event "$state" fm-alpha "blocked: cannot reach the registry"
emit_event "$state" fm-beta "working: still going"
# Break the record itself rather than the judge: a judge failure still produces
# an escalation and still advances, which is correct and is NOT a stall. The
# stall shape is a loop that keeps running while its output goes nowhere.
touch "$state/bosun/verdicts.tsv"
chmod 0444 "$state/bosun/verdicts.tsv"

FM_BOSUN_STALL_AFTER=1 bosun "$state" "$dir/judge" run --once > /dev/null 2>&1
sleep 2
FM_BOSUN_STALL_AFTER=1 bosun "$state" "$dir/judge" run --once > /dev/null 2>&1
mark_running "$state"

out=$(FM_BOSUN_STALL_AFTER=1 bosun "$state" "$dir/judge" status); rc=$?
assert_contains "$out" "STALLED" "a bosun that keeps passing but stops judging reports STALLED"
[ "$rc" -eq 0 ] && fail "STALLED must exit non-zero"
# The two readings must be different words from the same check, which is the
# whole claim: quiet and stalled are distinguishable, not merely both printable.
assert_not_contains "$out" "QUIET" "a stalled bosun must not also read QUIET"
pass "stalled bosun reads unhealthy and exits non-zero"

# (c) Repair the record and let it catch up: it must return to healthy on its
#     own, so STALLED is a live reading and not a latch nobody can clear.
chmod 0644 "$state/bosun/verdicts.tsv"
FM_BOSUN_STALL_AFTER=1 bosun "$state" "$dir/judge" run --once > /dev/null 2>&1
mark_running "$state"
out=$(FM_BOSUN_STALL_AFTER=1 bosun "$state" "$dir/judge" status); rc=$?
assert_contains "$out" "QUIET" "a bosun that catches up returns to QUIET"
[ "$rc" -eq 0 ] || fail "a caught-up bosun must exit 0, got $rc"
pass "the stalled reading clears once the bosun judges again"

# (d) A bosun that stopped reporting without exiting is DEAD, and one that
#     exited cleanly is STOPPED. Both mean nothing is being judged, and they are
#     kept apart because only one of them is a fault worth looking at.
#     The readings above were taken against a record re-armed as live, so take a
#     real clean exit here rather than asserting against that.
bosun "$state" "$dir/judge" run --once > /dev/null 2>&1
out=$(bosun "$state" "$dir/judge" status)
assert_contains "$out" "STOPPED" "a bosun that exited cleanly reports STOPPED"
assert_not_contains "$out" "DEAD" "a clean exit must not be reported as DEAD"

sed -i.bak -e "s/^state: .*/state: running/" \
  -e "s/^last_pass: .*/last_pass: $(( $(date +%s) - 6000 ))/" "$state/bosun/health"
rm -f "$state/bosun/health.bak"
out=$(bosun "$state" "$dir/judge" status); rc=$?
assert_contains "$out" "DEAD" "a bosun that stopped reporting without exiting reports DEAD"
[ "$rc" -eq 0 ] && fail "DEAD must exit non-zero"
pass "a wedged bosun and a cleanly stopped one are told apart"

# (e) One bosun per home: a second run refuses rather than double-judging. The
#     holder has to be a REAL live run - a lock left behind by an exited fixture
#     is a stale lock, and stealing it is the correct thing for the next run to
#     do, so a fixture would test the opposite of what this case is about.
dir2=$(make_bosun_case singleton "$JUDGE_SANE")
state2="$dir2/state"
FM_STATE_OVERRIDE="$state2" FM_BOSUN_JUDGE_CMD="$dir2/judge" FM_BOSUN_INTERVAL=60 \
  "$BOSUN" run > /dev/null 2>&1 &
holder=$!
trap 'kill "$holder" 2>/dev/null; fm_test_cleanup' EXIT
# Wait for the first run to actually hold the lock rather than racing it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$state2/bosun/.run.lock" ] && break
  sleep 0.5
done
out=$(bosun "$state2" "$dir2/judge" run --once 2>&1); rc=$?
kill "$holder" 2>/dev/null
trap 'fm_test_cleanup' EXIT
[ "$rc" -eq 0 ] && fail "a second bosun must refuse, not run"
assert_contains "$out" "already running" "a second bosun says why it refused"
pass "a second bosun in one home refuses rather than double-judging"

# --- 2. never a dropped row --------------------------------------------------
#
# The cursor must not advance past an event whose verdict did not reach disk.
# Case (b) above froze the record; assert it froze the cursor with it, and that
# the events it could not record were judged after the repair rather than lost.

cursor=$(cat "$state/bosun/.cursor" 2>/dev/null || echo 0)
journal_last=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-journal.sh" status | awk -F': ' '$1=="last"{print $2}')
[ "$cursor" = "$journal_last" ] || fail "cursor $cursor did not reach journal head $journal_last after repair"
judged_keys=$(FM_STATE_OVERRIDE="$state" "$BOSUN" verdicts --raw | cut -f5 | sort -u)
assert_contains "$judged_keys" "fm-alpha.status" "the event that could not be recorded was judged after the repair"
assert_contains "$judged_keys" "fm-beta.status" "the second unrecordable event was judged too"
pass "no event was dropped while the record was broken"

# --- 3. fail toward escalation ----------------------------------------------
#
# Every way a judge can fail to produce a usable verdict must produce a RECORDED
# escalation, never a silent skip. One case per failure shape, each against a
# fresh journal carrying one ordinary event a working judge would call routine -
# so a verdict of escalate can only have come from the failure.

check_escalates() {  # <name> <judge-body> <expected reason fragment>
  local name=$1 body=$2 want=$3 d s rows verdict reason
  d=$(make_bosun_case "$name" "$body")
  s="$d/state"
  emit_event "$s" fm-plain "working: ordinary progress nobody needs to see"
  bosun "$s" "$d/judge" run --once > /dev/null 2>&1
  rows=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw | wc -l | tr -d ' ')
  [ "$rows" = 1 ] || fail "$name: expected exactly 1 recorded verdict, got $rows"
  verdict=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw | cut -f7)
  [ "$verdict" = escalate ] || fail "$name: expected escalate, got '$verdict'"
  reason=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw | cut -f9)
  assert_contains "$reason" "$want" "$name: the recorded reason names the failure"
}

check_escalates judge-exits-nonzero \
  '#!/usr/bin/env bash
cat > /dev/null
exit 3' \
  "exited 3"

check_escalates judge-prints-garbage \
  '#!/usr/bin/env bash
cat > /dev/null
echo "I think this one is probably fine"' \
  "exactly one JSON object"

check_escalates judge-prints-two-objects \
  '#!/usr/bin/env bash
cat > /dev/null
printf "%s\n%s\n" \
  "{\"verdict\":\"routine\",\"confidence\":\"high\",\"reason\":\"first\"}" \
  "{\"verdict\":\"escalate\",\"confidence\":\"high\",\"reason\":\"second\"}"' \
  "exactly one JSON object"

check_escalates judge-returns-unknown-verdict \
  '#!/usr/bin/env bash
cat > /dev/null
echo "{\"verdict\":\"maybe\",\"confidence\":\"high\",\"reason\":\"unsure really\"}"' \
  "unknown verdict"

check_escalates judge-is-unsure \
  '#!/usr/bin/env bash
cat > /dev/null
echo "{\"verdict\":\"routine\",\"confidence\":\"low\",\"reason\":\"cannot tell\"}"' \
  "unsure, escalated"

pass "every judge failure shape is recorded as an escalation, one row each"

# A judge that is not on disk at all - the most likely reachability failure, and
# the one that must not read as "nothing to report".
d=$(make_bosun_case judge-missing "$JUDGE_SANE")
s="$d/state"
emit_event "$s" fm-plain "working: ordinary progress"
bosun "$s" "$d/nonexistent-judge" run --once > /dev/null 2>&1
row=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw)
[ "$(printf '%s' "$row" | cut -f7)" = escalate ] || fail "an unreachable judge must escalate"
[ "$(printf '%s' "$row" | cut -f10)" = unreachable ] || fail "an unreachable judge must be named as such in the record"
pass "an unreachable judge escalates and is named in the record"

# A retained journal that exists but cannot be read is uncertainty about the
# stream itself, not quiet. The pass records that uncertainty and status names
# the distinct health fault, while a genuinely absent journal remains healthy.
d=$(make_bosun_case journal-unreadable "$JUDGE_SANE")
s="$d/state"
emit_event "$s" fm-plain "working: ordinary progress"
chmod 0000 "$s/journal/events.tsv"
bosun "$s" "$d/judge" run --once > /dev/null 2>&1
row=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw)
[ "$(printf '%s' "$row" | cut -f5)" = journal-unreadable ] \
  || fail "an unreadable journal must produce a stream-level verdict"
[ "$(printf '%s' "$row" | cut -f7)" = escalate ] \
  || fail "an unreadable journal stream must escalate"
mark_running "$s"
out=$(bosun "$s" "$d/judge" status); rc=$?
[ "$rc" -ne 0 ] || fail "BLIND must exit non-zero"
assert_contains "$out" "BLIND" "an unreadable retained journal reports BLIND"
assert_not_contains "$out" "QUIET" "an unreadable retained journal must not report QUIET"
chmod 0644 "$s/journal/events.tsv"
pass "an unreadable journal escalates and reports unhealthy"

d=$(make_bosun_case journal-absent "$JUDGE_SANE")
s="$d/state"
bosun "$s" "$d/judge" run --once > /dev/null 2>&1
mark_running "$s"
out=$(bosun "$s" "$d/judge" status); rc=$?
[ "$rc" -eq 0 ] || fail "an absent journal must remain healthy"
assert_contains "$out" "QUIET" "a genuinely absent journal reports QUIET"
pass "a genuinely absent journal is not an access failure"

# A judge that never answers. Bounded by the timeout, recorded as an escalation.
d=$(make_bosun_case judge-hangs '#!/usr/bin/env bash
cat > /dev/null
sleep 30')
s="$d/state"
emit_event "$s" fm-plain "working: ordinary progress"
FM_BOSUN_JUDGE_TIMEOUT=1 bosun "$s" "$d/judge" run --once > /dev/null 2>&1
row=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw)
[ "$(printf '%s' "$row" | cut -f7)" = escalate ] || fail "a judge that never answers must escalate"
[ "$(printf '%s' "$row" | cut -f10)" = timeout ] || fail "a timed-out judge must be named as such in the record"
pass "a judge that never answers is bounded and escalates"

# --- 4. authority over nothing ----------------------------------------------
#
# The claim in this unit's own header, tested rather than asserted: a full pass
# leaves every byte of supervision state outside state/bosun/ exactly as it was.
# Nothing it concludes may change what surfaces, so nothing it writes may touch
# the queue, a task's status file, or any watcher record.

d=$(make_bosun_case authority "$JUDGE_SANE")
s="$d/state"
emit_event "$s" fm-alpha "blocked: needs a human right now"
emit_event "$s" fm-beta "working: fine"

snapshot() {  # <state> -> "path<TAB>sha" for everything the bosun may not touch
  find "$1" -type f -not -path "$1/bosun/*" -not -path "$1/journal/*" \
    | LC_ALL=C sort | xargs -r sha256sum
}
before=$(snapshot "$s")
bosun "$s" "$d/judge" run --once > /dev/null 2>&1
after=$(snapshot "$s")
[ "$before" = "$after" ] || {
  printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2
  fail "a bosun pass changed supervision state outside its own directory"
}
# And it must have actually done the work, or the comparison above proves only
# that a bosun which does nothing changes nothing.
[ "$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw | wc -l | tr -d ' ')" = 2 ] \
  || fail "the authority case judged nothing, so it proves nothing"
pass "a pass that judged two events changed no supervision state outside state/bosun/"

# The journal is read-only to the bosun too: it consumes that stream, it does not
# curate it.
journal_before=$(sha256sum "$s"/journal/events.tsv 2>/dev/null)
bosun "$s" "$d/judge" run --once > /dev/null 2>&1
journal_after=$(sha256sum "$s"/journal/events.tsv 2>/dev/null)
[ "$journal_before" = "$journal_after" ] || fail "the bosun modified the event journal"
pass "the bosun does not write to the journal it reads"

# --- 5. events that aged out are escalated, not skipped ----------------------
#
# The journal has a retention horizon. Events that fell below it before the bosun
# reached them existed and will never be judged, and the escalation bias says
# that is a fact for a human, not a gap to step over silently.

d=$(make_bosun_case horizon "$JUDGE_SANE")
s="$d/state"
for n in 1 2 3 4 5; do emit_event "$s" fm-gamma "working: line $n"; done
# Drop the first four records, exactly as a rotation past the size bound would,
# leaving a horizon of 5 above a cursor of 0.
tail -1 "$s/journal/events.tsv" > "$s/journal/events.tsv.keep"
mv "$s/journal/events.tsv.keep" "$s/journal/events.tsv"

bosun "$s" "$d/judge" run --once > /dev/null 2>&1
horizon_row=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts --raw | awk -F '\t' '$5 == "journal-horizon"')
[ -n "$horizon_row" ] || fail "events below the retention horizon were skipped without a record"
[ "$(printf '%s' "$horizon_row" | cut -f7)" = escalate ] || fail "aged-out events must escalate"
assert_contains "$(printf '%s' "$horizon_row" | cut -f9)" "aged out" \
  "the horizon record says plainly that events can never be judged"
pass "events that aged out of the journal are escalated rather than skipped"

# --- 6. the record is readable back -----------------------------------------
#
# "Recorded" means a human can read back the event, the conclusion, and the
# reason. Assert the rendered form actually carries all three rather than only
# the machine format doing so.

d=$(make_bosun_case readback "$JUDGE_SANE")
s="$d/state"
emit_event "$s" fm-delta "blocked: waiting on a credential"
bosun "$s" "$d/judge" run --once > /dev/null 2>&1
out=$(FM_STATE_OVERRIDE="$s" "$BOSUN" verdicts)
assert_contains "$out" "blocked: waiting on a credential" "the rendered record shows the event judged"
assert_contains "$out" "escalate" "the rendered record shows what was concluded"
assert_contains "$out" "blocker" "the rendered record shows why"
assert_contains "$out" "fake" "the rendered record shows which judge concluded it"
pass "a judgement can be read back with its event, conclusion, reason, and judge"

# Filtering, so a human can ask the only question that matters day to day.
d2=$(make_bosun_case readback-filter "$JUDGE_SANE")
s2="$d2/state"
emit_event "$s2" fm-eps "working: fine"
emit_event "$s2" fm-zeta "blocked: needs a human"
bosun "$s2" "$d2/judge" run --once > /dev/null 2>&1
only=$(FM_STATE_OVERRIDE="$s2" "$BOSUN" verdicts --only escalate --raw | wc -l | tr -d ' ')
[ "$only" = 1 ] || fail "--only escalate returned $only rows, expected 1"
pass "the record can be filtered to what the bosun would have escalated"

printf '\nall fm-bosun cases passed\n'
