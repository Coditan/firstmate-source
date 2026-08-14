#!/usr/bin/env bash
# tests/fm-event-batch.test.sh - priority batching of supervision events
# (bin/fm-event-batch-lib.sh, bin/fm-event-batch.sh).
#
# Events reach the journal through the REAL wake library rather than as
# hand-written journal rows, and every timing assertion is read back from the
# batch RECORD rather than from what the code says it did, so each number below
# is a measurement of one run and not a restatement of an implementation.
#
# THE BUDGETS ARE MEASURED AGAINST THE SHIPPED DEFAULTS, ON A CONTROLLED CLOCK.
# The captain's low class may be held for ten minutes, and a suite that waited it
# out would never be run. FM_BATCH_CLOCK_FILE moves the batcher's clock instead,
# so the 60/120/600-second cases exercise the real default constants and the real
# deadline arithmetic at full size. That seam is not a way around the
# measurement, and the last case proves it: with no clock file at all, a batch
# closes on real elapsed wall time, so the controlled-clock cases are measuring
# the arithmetic the fleet runs on rather than a fiction.
#
# Each budget is checked in BOTH directions - still open one second before, closed
# on the second - because a batcher that closed everything instantly would satisfy
# "within one minute" while doing no batching at all.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BATCH="$ROOT/bin/fm-event-batch.sh"
JOURNAL="$ROOT/bin/fm-journal.sh"

fm_test_tmproot TMP_ROOT fm-event-batch-tests

make_batch_case() {  # <name> -> dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# Run the batcher against one case's state, with that case's controlled clock
# when it has one. FM_HOME points at the case so a per-home config file is read
# from there rather than from the suite's shared root.
batch() {  # <dir> <args...>
  local dir=$1
  shift
  FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" \
    FM_BATCH_CLOCK_FILE="${FM_BATCH_CLOCK_FILE-$dir/clock}" \
    "$BATCH" "$@"
}

set_clock() {  # <dir> <epoch>
  printf '%s\n' "$2" > "$1/clock"
}

# Queue one real wake through the production library, having first appended the
# status line, so the journal record carries a real arrival-time capture and the
# batcher classifies the line a real producer left.
emit() {  # <dir> <task> <status-line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
  append_wake "$1/state" signal "$2.status" "$2 needs attention"
}

journal_arrival() {  # <dir> <jseq> -> the epoch that event arrived
  FM_STATE_OVERRIDE="$1/state" "$JOURNAL" read | awk -F '\t' -v s="$2" '$1 == s { print $2 }'
}

# One closed batch's record field, by batch sequence.
batch_field() {  # <dir> <bseq> <1-based field>
  awk -F '\t' -v b="$2" -v f="$3" '$1 == b { print $f }' "$1/state/batches/batches.tsv" 2>/dev/null
}

closed_bseq_for() {  # <dir> <priority> -> the first closed batch of that class
  awk -F '\t' -v p="$2" '$2 == p { print $1; exit }' "$1/state/batches/batches.tsv" 2>/dev/null
}

is_open() {  # <dir> <priority>
  [ -r "$1/state/batches/open/$2" ]
}

member_jseqs() {  # <dir> -> every batched journal sequence, sorted
  awk -F '\t' 'NF >= 8 { print $4 }' "$1/state/batches/members.tsv" 2>/dev/null | LC_ALL=C sort -n
}

# --- 1. the captain's numbers are the shipped defaults -----------------------

test_the_shipped_defaults_are_the_captains_numbers() {
  local dir out
  dir=$(make_batch_case shipped-defaults)
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" "$BATCH" delays) \
    || fail "delays refused to report on a fresh home"
  printf '%s\n' "$out" | grep -Eq '^immediate +0s +\(fixed\)$' \
    || fail "immediate does not ship at no delay at all: $out"
  printf '%s\n' "$out" | grep -Eq '^high +60s +\(default\)$' \
    || fail "high does not ship at the captain's one minute: $out"
  printf '%s\n' "$out" | grep -Eq '^normal +120s +\(default\)$' \
    || fail "normal does not ship at the captain's two minutes: $out"
  printf '%s\n' "$out" | grep -Eq '^low +600s +\(default\)$' \
    || fail "low does not ship at the captain's ten minutes: $out"
  pass "the shipped delays are the captain's own numbers: 0, 60, 120 and 600 seconds"
}

# --- 2. immediate is not held ------------------------------------------------

test_an_immediate_event_is_passed_straight_through() {
  local dir arrival bseq reason hold
  dir=$(make_batch_case immediate)
  emit "$dir" fm-alpha "blocked: needs a human right now"
  arrival=$(journal_arrival "$dir" 1)
  set_clock "$dir" "$arrival"

  batch "$dir" run --once > /dev/null 2>&1 || fail "the pass failed"

  bseq=$(closed_bseq_for "$dir" immediate)
  [ -n "$bseq" ] || fail "an immediate event was not released by the pass that admitted it"
  reason=$(batch_field "$dir" "$bseq" 7)
  [ "$reason" = immediate ] \
    || fail "the immediate batch closed as '$reason'; anything but 'immediate' means it was held"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -eq 0 ] || fail "an immediate event was held ${hold}s; the captain's number is no delay at all"
  pass "an immediate event is released by the pass that admits it, with no hold at all"
}

# --- 3. high, normal and low, measured against the shipped budgets -----------

test_high_normal_and_low_close_within_the_captains_budgets() {
  local dir t_low t_normal t_high bseq hold
  dir=$(make_batch_case budgets)
  # Oldest first, so every later deadline sits above every earlier one and the
  # controlled clock only ever moves forward.
  emit "$dir" fm-low "working: chugging along"
  emit "$dir" fm-normal "check: merge poll came back"
  emit "$dir" fm-high "done: PR is up and green"
  t_low=$(journal_arrival "$dir" 1)
  t_normal=$(journal_arrival "$dir" 2)
  t_high=$(journal_arrival "$dir" 3)

  # Admit all three. Nothing is due, so nothing may close.
  set_clock "$dir" "$t_high"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  is_open "$dir" high || fail "the high batch did not open"
  is_open "$dir" normal || fail "the normal batch did not open"
  is_open "$dir" low || fail "the low batch did not open"
  [ ! -s "$dir/state/batches/batches.tsv" ] \
    || fail "a batch closed before any budget had run out: $(cat "$dir/state/batches/batches.tsv")"

  # High: still held at 59 seconds, released at 60.
  set_clock "$dir" $((t_high + 59))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 59-second pass failed"
  is_open "$dir" high || fail "the high batch closed at 59s; a batcher that never holds is not batching"
  set_clock "$dir" $((t_high + 60))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 60-second pass failed"
  bseq=$(closed_bseq_for "$dir" high)
  [ -n "$bseq" ] || fail "the high batch was still held one minute after its oldest event arrived"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -le 60 ] || fail "the high batch was held ${hold}s against the captain's 60"
  [ "$hold" -eq 60 ] || fail "the high batch was held ${hold}s, not the 60 its budget allows"

  # Normal: still held at 119 seconds, released at 120.
  set_clock "$dir" $((t_normal + 119))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 119-second pass failed"
  is_open "$dir" normal || fail "the normal batch closed at 119s"
  set_clock "$dir" $((t_normal + 120))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 120-second pass failed"
  bseq=$(closed_bseq_for "$dir" normal)
  [ -n "$bseq" ] || fail "the normal batch was still held two minutes after its oldest event arrived"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -le 120 ] || fail "the normal batch was held ${hold}s against the captain's 120"
  [ "$hold" -eq 120 ] || fail "the normal batch was held ${hold}s, not the 120 its budget allows"

  # Low: still held at 599 seconds, released at 600.
  set_clock "$dir" $((t_low + 599))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 599-second pass failed"
  is_open "$dir" low || fail "the low batch closed at 599s"
  set_clock "$dir" $((t_low + 600))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 600-second pass failed"
  bseq=$(closed_bseq_for "$dir" low)
  [ -n "$bseq" ] || fail "the low batch was still held ten minutes after its oldest event arrived"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -le 600 ] || fail "the low batch was held ${hold}s against the captain's 600"
  [ "$hold" -eq 600 ] || fail "the low batch was held ${hold}s, not the 600 its budget allows"

  [ "$(member_jseqs "$dir" | tr '\n' ' ')" = "1 2 3 " ] \
    || fail "the three events did not all survive their holds"
  pass "high, normal and low are held to the second and released within one, two and ten minutes"
}

# --- 4. an immediate event closes what is waiting ---------------------------

test_an_immediate_event_closes_every_open_batch_early() {
  local dir t_open t_imm reasons bseq priority
  dir=$(make_batch_case bypass)
  emit "$dir" fm-low "working: chugging along"
  emit "$dir" fm-normal "check: merge poll came back"
  emit "$dir" fm-high "done: PR is up and green"
  t_open=$(journal_arrival "$dir" 3)
  set_clock "$dir" "$t_open"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  is_open "$dir" low || fail "the low batch did not open"

  emit "$dir" fm-alpha "failed: the deploy key was revoked"
  t_imm=$(journal_arrival "$dir" 4)
  set_clock "$dir" "$t_imm"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the bypass pass failed"

  for priority in immediate high normal low; do
    bseq=$(closed_bseq_for "$dir" "$priority")
    [ -n "$bseq" ] || fail "the $priority batch was left waiting behind an immediate event"
  done
  # "Early" stated exactly, and immune to how loaded the machine is: each waiting
  # batch closed strictly before the deadline its own budget gave it.
  for priority in high normal low; do
    bseq=$(closed_bseq_for "$dir" "$priority")
    [ "$(batch_field "$dir" "$bseq" 5)" -lt "$(batch_field "$dir" "$bseq" 6)" ] \
      || fail "the $priority batch ran out its own budget instead of closing early"
  done
  reasons=$(awk -F '\t' '{ printf "%s:%s ", $2, $7 }' "$dir/state/batches/batches.tsv")
  case "$reasons" in
    *"immediate:immediate"*) ;;
    *) fail "the immediate batch did not record its own straight-through close: $reasons" ;;
  esac
  case "$reasons" in
    *"high:bypass"*) ;;
    *) fail "the waiting high batch did not record an early close: $reasons" ;;
  esac

  # An early close is a close, never a discard: every member is still on record.
  [ "$(member_jseqs "$dir" | tr '\n' ' ')" = "1 2 3 4 " ] \
    || fail "closing early lost an event: $(member_jseqs "$dir" | tr '\n' ' ')"
  batch "$dir" account > /dev/null || fail "the bypass left the batching unaccountable"
  pass "an arriving immediate event closes every waiting batch early, and loses none of their events"
}

# --- 5. the drop test -------------------------------------------------------
#
# The whole premise of the bosun programme is that nothing is discarded. A
# batching mechanism that loses one event under load has removed the guarantee
# the journal was built to provide, and it would do so invisibly.

test_no_event_is_dropped_by_batching_proven_against_the_journal() {
  local dir n journal_seqs batched out
  dir=$(make_batch_case never-drops)
  # A mixed burst across every class, including immediate events mid-stream so
  # the bypass path runs inside the load rather than beside it.
  for n in 1 2 3 4; do
    emit "$dir" "fm-w$n" "working: step $n"
    emit "$dir" "fm-d$n" "done: PR $n is up"
    append_wake "$dir/state" heartbeat "beat-$n" "fleet heartbeat $n"
    append_wake "$dir/state" check "poll-$n" "check: poll $n came back"
    append_wake "$dir/state" stale "stale-$n" "stale: pane $n stopped changing"
  done
  emit "$dir" fm-blocked "blocked: needs a credential"
  emit "$dir" fm-more "working: still going"

  # Admit in small passes so the burst crosses pass boundaries, which is where a
  # cursor that moved too early would lose one.
  batch "$dir" run --once --limit 3 > /dev/null 2>&1 || fail "the first pass failed"
  # Mid-burst, with the cursor well behind a two-digit journal: an event the
  # batcher has not reached yet is pending, never missing. Asserted here because
  # a reconciliation that compares sequences as text calls every event past the
  # ninth lost the moment the cursor falls behind, and that reads as a drop.
  # The budget check allows one poll interval on top of each class's delay,
  # because a batcher cannot close a batch in a pass it is not running. This case
  # drives passes as separate serialized invocations rather than from a run loop,
  # so its real admission cadence is declared here instead of being left at the
  # 5-second default. It bounds only the budget arithmetic; missing, duplicated,
  # and orphaned - what this case is actually for - stay exact.
  out=$(FM_BATCH_INTERVAL=60 batch "$dir" account) || {
    printf '%s\n' "$out" >&2
    fail "events the batcher had not yet reached were reported as lost"
  }
  printf '%s\n' "$out" | grep -q '^pending: 19 ' \
    || fail "the unreached remainder of the burst was not counted as pending: $out"
  for n in 2 3 4 5 6 7 8 9; do
    batch "$dir" run --once --limit 3 > /dev/null 2>&1 || fail "pass $n failed"
  done
  batch "$dir" flush > /dev/null 2>&1 || fail "the flush failed"

  journal_seqs=$(FM_STATE_OVERRIDE="$dir/state" "$JOURNAL" read | awk -F '\t' '{ print $1 }' | LC_ALL=C sort -n)
  batched=$(member_jseqs "$dir")
  [ -n "$journal_seqs" ] || fail "the burst produced no journal records to reconcile against"
  [ "$journal_seqs" = "$batched" ] || {
    printf 'journal:\n%s\nbatched:\n%s\n' "$journal_seqs" "$batched" >&2
    fail "batching did not carry every journal event exactly once"
  }
  out=$(FM_BATCH_INTERVAL=60 batch "$dir" account) || {
    printf '%s\n' "$out" >&2
    fail "account could not vouch for a burst it should have carried whole"
  }
  printf '%s\n' "$out" | grep -q '^ACCOUNTED' \
    || fail "account did not state the reconciliation was clean: $out"
  pass "every event in a mixed burst reaches exactly one batch, reconciled against the journal itself"
}

# The control for the case above. Without it, "account reported clean" would only
# prove that account is capable of saying clean.
test_account_names_a_lost_event_instead_of_reading_clean() {
  local dir out rc=0
  dir=$(make_batch_case account-control)
  emit "$dir" fm-a "working: one"
  emit "$dir" fm-b "working: two"
  emit "$dir" fm-c "working: three"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  batch "$dir" account > /dev/null || fail "the control started from an unaccountable state"

  # Stand in for an event that batching lost: remove its member record, exactly
  # as a filter or a collapse would have.
  grep -v "$(printf '\t2\t')" "$dir/state/batches/members.tsv" > "$dir/members.trim" \
    || fail "could not build the lossy record"
  mv "$dir/members.trim" "$dir/state/batches/members.tsv"

  out=$(batch "$dir" account) || rc=$?
  [ "$rc" -ne 0 ] || fail "account reported a lossy record as clean"
  printf '%s\n' "$out" | grep -q '^missing: 2$\|^missing:.* 2$' \
    || fail "account did not name the lost journal event: $out"
  printf '%s\n' "$out" | grep -q '^UNACCOUNTED' \
    || fail "account did not say the stream was unaccountable: $out"
  pass "a lost event is named loudly by account rather than passing as a quiet period"
}

# --- 6. the cursor order, stated as a failure mode --------------------------

test_a_pass_that_dies_before_the_cursor_moves_duplicates_rather_than_drops() {
  local dir out rc=0 seen
  dir=$(make_batch_case duplicate-not-drop)
  emit "$dir" fm-a "working: one"
  emit "$dir" fm-b "working: two"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  # Exactly what a process killed between the member append and the cursor write
  # leaves behind: the record is down, the cursor still points below it.
  printf '1\n' > "$dir/state/batches/.cursor"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the re-admitting pass failed"

  seen=$(member_jseqs "$dir" | grep -c '^2$')
  [ "$seen" -eq 2 ] || fail "the re-admitted event appears $seen time(s); the record must never lose it"
  out=$(batch "$dir" account) || rc=$?
  [ "$rc" -ne 0 ] || fail "a duplicated event was not reported"
  printf '%s\n' "$out" | grep -q '^duplicated:' \
    || fail "account did not name the duplicate: $out"
  pass "a pass that dies before its cursor moves re-admits the event and says so, rather than losing it"
}

test_a_stale_open_marker_is_reported_and_never_reused() {
  local dir marker old_bseq new_bseq out rc=0
  dir=$(make_batch_case stale-open-marker)
  emit "$dir" fm-a "working: one"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  marker=$(cat "$dir/state/batches/open/low")
  old_bseq=${marker%%$'\t'*}
  batch "$dir" flush > /dev/null 2>&1 || fail "the initial close failed"
  printf '%s\n' "$marker" > "$dir/state/batches/open/low"

  out=$(batch "$dir" account) || rc=$?
  [ "$rc" -ne 0 ] || fail "a closed batch still marked open was reported as accountable"
  printf '%s\n' "$out" | grep -q "^open_closed_overlap: $old_bseq$" \
    || fail "account did not name the open and closed overlap: $out"

  emit "$dir" fm-b "working: two"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the recovering pass failed"
  new_bseq=$(awk -F '\t' '$4 == 2 { print $2 }' "$dir/state/batches/members.tsv")
  [ -n "$new_bseq" ] || fail "the event after the stale marker was not admitted"
  [ "$new_bseq" -ne "$old_bseq" ] || fail "the event after the stale marker extended the closed batch"
  [ "$(member_jseqs "$dir" | tr '\n' ' ')" = "1 2 " ] \
    || fail "recovering from the stale marker lost a member"
  batch "$dir" account > /dev/null || fail "discarding the stale marker left the record unaccountable"
  pass "a stale open marker is reported and admission opens a fresh batch without losing members"
}

test_an_event_whose_record_fails_is_not_stepped_over() {
  local dir err cursor
  dir=$(make_batch_case record-failure)
  emit "$dir" fm-a "working: one"
  emit "$dir" fm-b "working: two"
  err="$dir/pass.err"
  # A directory where the member file belongs: every append to it fails, on every
  # platform, without the suite needing to run as anyone in particular.
  mkdir -p "$dir/state/batches/members.tsv"

  batch "$dir" run --once > /dev/null 2> "$err" || fail "a failed record aborted the run"
  grep -q 'it will be admitted again' "$err" \
    || fail "a member record that never reached disk was not reported: $(cat "$err")"
  cursor=$(cat "$dir/state/batches/.cursor" 2>/dev/null || printf '0')
  [ "$cursor" -eq 0 ] \
    || fail "the cursor advanced to $cursor past an event whose record never reached disk"

  rmdir "$dir/state/batches/members.tsv"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the recovering pass failed"
  [ "$(member_jseqs "$dir" | tr '\n' ' ')" = "1 2 " ] \
    || fail "the event held back by a failed record was never batched: $(member_jseqs "$dir" | tr '\n' ' ')"
  batch "$dir" account > /dev/null || fail "recovery left the batching unaccountable"
  pass "an event whose member record fails holds the cursor rather than being stepped over"
}

# --- 7. the size bound closes; it never truncates ---------------------------

test_a_full_batch_closes_early_rather_than_dropping_the_overflow() {
  local dir n closed
  dir=$(make_batch_case full-batch)
  for n in 1 2 3 4 5; do emit "$dir" "fm-$n" "working: step $n"; done
  FM_BATCH_MAX_EVENTS=2 batch "$dir" run --once > /dev/null 2>&1 || fail "the pass failed"

  closed=$(awk -F '\t' '$7 == "full"' "$dir/state/batches/batches.tsv" | wc -l | tr -d ' ')
  [ "$closed" -eq 2 ] || fail "expected 2 batches closed by the size bound, got $closed"
  [ "$(member_jseqs "$dir" | tr '\n' ' ')" = "1 2 3 4 5 " ] \
    || fail "the size bound discarded members instead of closing the batch"
  is_open "$dir" low || fail "the sixth slot did not open a fresh batch for the remainder"
  batch "$dir" account > /dev/null || fail "the size bound left the batching unaccountable"
  pass "a batch that reaches its size bound closes early and carries every member with it"
}

# --- 8. configurability ------------------------------------------------------

test_the_delays_are_configurable_and_a_bad_value_is_refused() {
  local dir out rc=0
  dir=$(make_batch_case configurable)
  mkdir -p "$dir/config"
  printf '# this home holds work shorter\nhigh = 5\nlow=7\n' > "$dir/config/batch-delays"
  out=$(batch "$dir" delays) || fail "delays refused a valid config"
  printf '%s\n' "$out" | grep -Eq '^high +5s +\(config\)$' \
    || fail "a configured high delay was not used: $out"
  printf '%s\n' "$out" | grep -Eq '^low +7s +\(config\)$' \
    || fail "a configured low delay was not used: $out"
  printf '%s\n' "$out" | grep -Eq '^normal +120s +\(default\)$' \
    || fail "an unconfigured class lost the captain's shipped number: $out"

  out=$(FM_BATCH_DELAY_HIGH=9 batch "$dir" delays) || fail "delays refused an environment override"
  printf '%s\n' "$out" | grep -Eq '^high +9s +\(environment\)$' \
    || fail "an environment override did not win over the config file: $out"

  # A home that mistyped its delay must not be handed the shipped default while
  # believing it configured one.
  printf 'high = soon\n' > "$dir/config/batch-delays"
  out=$(batch "$dir" delays 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unusable configured delay was accepted (rc=$rc)"
  printf '%s\n' "$out" | grep -q 'not a whole number of seconds' \
    || fail "the refusal did not name the problem: $out"
  pass "delays come from the environment, then the home's config, then the captain's shipped number"
}

# immediate is the class DEFINED as never held, so it carries no delay to set.
# Accepting a value for it and then ignoring it is the same defect as accepting a
# mistyped one: the home believes it configured something that does nothing.
test_configuring_the_immediate_class_is_refused_rather_than_ignored() {
  local dir out rc=0
  dir=$(make_batch_case immediate-not-configurable)
  mkdir -p "$dir/config"

  printf 'immediate = 30\n' > "$dir/config/batch-delays"
  out=$(batch "$dir" delays 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a configured immediate delay was accepted instead of refused (rc=$rc)"
  printf '%s\n' "$out" | grep -q 'immediate is never held' \
    || fail "the refusal did not say why immediate takes no delay: $out"

  rc=0
  : > "$dir/config/batch-delays"
  out=$(FM_BATCH_DELAY_IMMEDIATE=30 batch "$dir" delays 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an immediate delay from the environment was accepted (rc=$rc)"
  printf '%s\n' "$out" | grep -q 'immediate is never held' \
    || fail "the environment refusal did not say why immediate takes no delay: $out"

  # And the three real delays are unaffected by that refusal.
  rc=0
  printf 'high = 5\n' > "$dir/config/batch-delays"
  out=$(batch "$dir" delays) || rc=$?
  [ "$rc" -eq 0 ] || fail "refusing an immediate delay broke the configurable classes (rc=$rc)"
  printf '%s\n' "$out" | grep -Eq '^high +5s +\(config\)$' \
    || fail "a configured high delay stopped working: $out"
  pass "an attempt to give immediate a delay is refused, and the three real delays still configure"
}

# A configured delay must actually govern a hold, not merely be reported back.
test_a_configured_delay_governs_the_hold() {
  local dir arrival bseq hold
  dir=$(make_batch_case configured-hold)
  mkdir -p "$dir/config"
  printf 'low = 30\n' > "$dir/config/batch-delays"
  emit "$dir" fm-a "working: chugging along"
  arrival=$(journal_arrival "$dir" 1)
  set_clock "$dir" "$arrival"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  set_clock "$dir" $((arrival + 29))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 29-second pass failed"
  is_open "$dir" low || fail "a 30-second configured hold released at 29s"
  set_clock "$dir" $((arrival + 30))
  batch "$dir" run --once > /dev/null 2>&1 || fail "the 30-second pass failed"
  bseq=$(closed_bseq_for "$dir" low)
  [ -n "$bseq" ] || fail "a 30-second configured hold did not release at 30s"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -eq 30 ] || fail "the configured hold measured ${hold}s, not 30"
  pass "a configured delay governs the hold that is actually taken"
}

# --- 9. it decides nothing --------------------------------------------------

test_batching_changes_no_supervision_state_outside_its_own_directory() {
  local dir before after
  dir=$(make_batch_case authority)
  emit "$dir" fm-a "blocked: needs a human right now"
  emit "$dir" fm-b "working: fine"

  snapshot() {  # <state> -> "sha path" for everything the batcher may not touch
    find "$1" -type f -not -path "$1/batches/*" | LC_ALL=C sort | xargs -r sha256sum
  }
  before=$(snapshot "$dir/state")
  batch "$dir" run --once > /dev/null 2>&1 || fail "the pass failed"
  after=$(snapshot "$dir/state")
  [ "$before" = "$after" ] || {
    printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    fail "a batching pass changed supervision state outside state/batches/"
  }
  # And it must have actually done the work, or the comparison above proves only
  # that a batcher which does nothing changes nothing.
  [ "$(member_jseqs "$dir" | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "the authority case batched nothing, so it proves nothing"
  pass "a pass that batched two events changed no supervision state outside state/batches/"
}

# --- 10. a stalled batcher is visible, not silent ---------------------------

test_an_open_batch_past_its_deadline_is_reported_rather_than_held_silently() {
  local dir arrival out rc=0
  dir=$(make_batch_case overdue)
  emit "$dir" fm-a "working: chugging along"
  arrival=$(journal_arrival "$dir" 1)
  set_clock "$dir" "$arrival"
  batch "$dir" run --once > /dev/null 2>&1 || fail "the admitting pass failed"
  # The batcher stops here. Time passes; the batch is due and nobody releases it.
  set_clock "$dir" $((arrival + 900))

  out=$(batch "$dir" account) || rc=$?
  [ "$rc" -ne 0 ] || fail "a batch held past its deadline was reported as accountable"
  printf '%s\n' "$out" | grep -q '^overdue_open:' \
    || fail "account did not name the overdue batch: $out"
  rc=0
  out=$(batch "$dir" status) || rc=$?
  [ "$rc" -ne 0 ] || fail "status reported a stuck batcher as healthy"
  printf '%s\n' "$out" | tail -1 | grep -q '^OVERDUE' \
    || fail "status did not resolve a stuck batcher to OVERDUE: $(printf '%s' "$out" | tail -1)"
  pass "events held past their deadline are reported rather than sitting there looking like a quiet fleet"
}

# --- 11. the controlled clock is not measuring a fiction --------------------

test_a_real_wall_clock_closes_a_batch_on_elapsed_time() {
  local dir bseq hold
  dir=$(make_batch_case wall-clock)
  emit "$dir" fm-a "working: chugging along"
  # No clock file at all: this case runs on date(1), exactly as the fleet does.
  FM_BATCH_CLOCK_FILE='' FM_BATCH_DELAY_LOW=2 batch "$dir" run --once > /dev/null 2>&1 \
    || fail "the admitting pass failed"
  is_open "$dir" low || fail "the batch closed before any real time had passed"
  sleep 3
  FM_BATCH_CLOCK_FILE='' FM_BATCH_DELAY_LOW=2 batch "$dir" run --once > /dev/null 2>&1 \
    || fail "the closing pass failed"
  bseq=$(closed_bseq_for "$dir" low)
  [ -n "$bseq" ] || fail "the batch was not released after its real delay elapsed"
  [ "$(batch_field "$dir" "$bseq" 7)" = deadline ] \
    || fail "the batch did not close on its deadline"
  hold=$(( $(batch_field "$dir" "$bseq" 5) - $(batch_field "$dir" "$bseq" 4) ))
  [ "$hold" -ge 2 ] || fail "the wall-clock hold measured ${hold}s, under its own 2s delay"
  pass "with no clock seam at all, a batch is held and released on real elapsed time"
}

# --- 12. classification ------------------------------------------------------

test_events_are_classified_into_the_captains_four_classes() {
  local table row kind line want got
  # kind | status line the journal captured | expected class
  table='signal|blocked: needs a human|immediate
signal|failed: the deploy key was revoked|immediate
signal|needs-decision [key=scope]: two options|immediate
signal|done: PR is up and green|high
signal|checks green|high
signal|working: rebased onto merged #76|low
signal|paused: waiting on an upstream release|low
signal|resolved: unblocked by the captain|low
signal|captain-held: filed as a backlog decision|low
signal|chugging along with no verb at all|normal
heartbeat|fleet heartbeat|low
stale|pane stopped changing|high
check|merge poll came back|normal'

  while IFS='|' read -r kind line want; do
    [ -n "$kind" ] || continue
    got=$(FM_STATE_OVERRIDE="$TMP_ROOT/classify-state" bash -c '
      . "$1"
      fm_batch_priority "$2" "$3" "$4"
    ' _ "$ROOT/bin/fm-event-batch-lib.sh" "$kind" "payload" "$line")
    [ "$got" = "$want" ] || fail "'$line' ($kind) classified as $got, not $want"
  done <<< "$table"
  # The trap in the middle of that table is the one worth naming: a progress line
  # whose prose contains a terminal word must not be promoted by it.
  row=$(FM_STATE_OVERRIDE="$TMP_ROOT/classify-state" bash -c '
    . "$1"
    fm_batch_priority signal payload "working: rebased onto merged #76"
  ' _ "$ROOT/bin/fm-event-batch-lib.sh")
  [ "$row" = low ] || fail "progress prose containing a terminal word was promoted to $row"
  pass "every kind and status verb lands in the timing class the captain's table gives it"
}

test_the_shipped_defaults_are_the_captains_numbers
test_an_immediate_event_is_passed_straight_through
test_high_normal_and_low_close_within_the_captains_budgets
test_an_immediate_event_closes_every_open_batch_early
test_no_event_is_dropped_by_batching_proven_against_the_journal
test_account_names_a_lost_event_instead_of_reading_clean
test_a_pass_that_dies_before_the_cursor_moves_duplicates_rather_than_drops
test_a_stale_open_marker_is_reported_and_never_reused
test_an_event_whose_record_fails_is_not_stepped_over
test_a_full_batch_closes_early_rather_than_dropping_the_overflow
test_the_delays_are_configurable_and_a_bad_value_is_refused
test_configuring_the_immediate_class_is_refused_rather_than_ignored
test_a_configured_delay_governs_the_hold
test_batching_changes_no_supervision_state_outside_its_own_directory
test_an_open_batch_past_its_deadline_is_reported_rather_than_held_silently
test_a_real_wall_clock_closes_a_batch_on_elapsed_time
test_events_are_classified_into_the_captains_four_classes
