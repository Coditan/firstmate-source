#!/usr/bin/env bash
# tests/fm-urgency.test.sh - the urgency promoter (bin/fm-urgency-lib.sh,
# bin/fm-urgency.sh, and its one delivery site in bin/fm-bridge-inbox-lib.sh).
#
# THE CASE THAT MATTERS IS THE REPLAY, AND IT IS NOT A FORMALITY.
# A promoter that under-promotes is invisible: the event arrives at its declared
# priority, looks entirely normal, and whatever it understated is found later by
# a human. There is no error, no failed check, and nothing to see. Rules that
# read soundly therefore prove nothing, so the load-bearing cases below replay
# events that this fleet ACTUALLY RECORDED and require them to promote.
#
# The events are real. The Bridge case is the one the panel judge verified by
# hand on 2026-08-11 and named in
# data/panel-question-should-this-fleet-1177-judge/report.md: an envelope
# declared priority "normal" whose subject was "80/443 open to any source: INPUT
# policy ACCEPT, no Cloudflare rule". The status lines are transcribed from this
# fleet's own recorded status history of 2026-08-13 and 2026-08-14. Nothing here
# is an invented example shaped to match the implementation.
#
# Events reach the journal through the REAL wake library and the Bridge case
# runs through the REAL bridge_inbox_surface path, so the promoter is read
# against the record a real producer leaves rather than against journal rows
# written by this file.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

URGENCY="$ROOT/bin/fm-urgency.sh"
URGENCY_LIB="$ROOT/bin/fm-urgency-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
BRIDGE_LIB="$ROOT/bin/fm-bridge-inbox-lib.sh"

fm_test_tmproot TMP_ROOT fm-urgency-tests

# --- fixtures ---------------------------------------------------------------

make_state() {  # <name> -> state dir on stdout
  local dir="$TMP_ROOT/$1/state"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# A home with a real Bridge clone and its own origin, matching the fixture shape
# tests/fm-frequency-monitor.test.sh already uses so both suites drive the same
# production path.
make_bridge_home() {  # <name> -> home dir on stdout
  local name=$1 home bridge origin
  home="$TMP_ROOT/$name"
  bridge="$home/projects/coditan-bridge"
  origin="$home/bridge-origin.git"
  mkdir -p "$home/state" "$home/config" "$bridge/inbox/coditan/new"
  git init -q --bare "$origin"
  git -C "$bridge" init -q -b main
  git -C "$bridge" config user.name test
  git -C "$bridge" config user.email test@example.com
  touch "$bridge/inbox/coditan/new/.gitkeep"
  git -C "$bridge" add inbox
  git -C "$bridge" commit -qm init
  git -C "$bridge" remote add origin "$origin"
  git -C "$bridge" push -qu origin main
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  printf '%s\n' coditan > "$home/config/bridge-vessel"
  printf '%s\n' "$home"
}

write_envelope() {  # <home> <id> <priority> <subject>
  local home=$1 id=$2 priority=$3 subject=$4 bridge
  bridge="$home/projects/coditan-bridge"
  jq -n --arg id "$id" --arg p "$priority" --arg s "$subject" \
    '{schema:"bridge-envelope.v1", id:$id, priority:$p, state:"new", subject:$s}' \
    > "$bridge/inbox/coditan/new/$id.json"
  git -C "$bridge" add "inbox/coditan/new/$id.json"
  git -C "$bridge" commit -qm "add $id"
  git -C "$bridge" push -qu origin main
}

surface_bridge() {  # <home> -> the composed wake reason on stdout
  FM_HOME="$home" bash -c \
    '. "$1"; . "$2"; bridge_inbox_surface 0' _ "$WAKE_LIB" "$BRIDGE_LIB"
}

# Ask the production library one event's verdict, in a subshell scoped to a
# state dir so nothing here leaks into the caller's environment.
# The single-quoted body is the SOURCE of the subshell's script and its
# expansions must survive into it, which is what SC2016 would otherwise object
# to; the values it needs arrive as positional arguments instead.
# shellcheck disable=SC2016
urgency_ranks() {  # <state> <declared> <text> -> "<declared rank>\t<effective rank>"
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_urgency_effective "$2" "$3" || true
    printf "%s\t%s\n" "$(fm_urgency_rank "$2")" "$(fm_urgency_rank "$FM_URGENCY_EFFECTIVE")"
  ' _ "$URGENCY_LIB" "$2" "$3"
}

# shellcheck disable=SC2016
urgency_effective() {  # <state> <declared> <text> -> effective priority
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_urgency_effective "$2" "$3" || true
    printf "%s" "$FM_URGENCY_EFFECTIVE"
  ' _ "$URGENCY_LIB" "$2" "$3"
}

# --- the real recorded corpora ----------------------------------------------
#
# Transcribed from this fleet's own state/*.status history. Each line is a
# status event a crewmate actually appended, kept as it was written.
#
# The UNDER-DECLARED set is the point of the suite: every one of these arrived
# under a verb the classifier reads as ordinary, while its own text reports a
# blocker, a failure, a credential, or work waiting on a human.
UNDER_DECLARED_STATUS=(
  'working: branch pushed but the deploy key was revoked, cannot proceed'
  'paused: waiting on the upstream release; the API token in the runner is expired'
  'working: rebuilt the index, but the backup bucket is publicly readable'
  'working: der Lauf blockiert, wir brauchen eine Entscheidung des Commodore'
  'resolved: reverted by force-push, the branch history was rewritten'
)

# Real routine progress, kept exactly as recorded. Nothing in these asks for a
# human, and a promoter that raises them is spending the captain's attention for
# nothing.
ORDINARY_STATUS=(
  'working: worktree isolated, branch created, host cgroup layout measured'
  'working: isolated task branch created and repository health check passed'
  'working: verifying vantage point and reaper claims'
  'working: starting judge re-verification and report'
  'working: branch updated from main and pushed; CI run under way'
)

# --- the load-bearing cases -------------------------------------------------

# ACCEPTANCE: an event whose declared priority understates its content is
# DELIVERED at the higher priority. Driven end to end through the real Bridge
# surface path, so what is asserted is the wake a supervisor would actually
# receive rather than a library return value.
test_the_measured_under_declared_envelope_is_delivered_promoted() {
  local home out queue
  home=$(make_bridge_home measured)
  write_envelope "$home" tugboat-80-443 normal \
    '80/443 open to any source: INPUT policy ACCEPT, no Cloudflare rule'

  out=$(surface_bridge "$home")
  assert_contains "$out" 'highest=immediate' \
    "the verified under-declared envelope was not delivered at the promoted priority"
  assert_contains "$out" 'declared=normal' \
    "the delivered wake did not say what the envelope had declared"
  assert_contains "$out" 'promoted-by=exposure' \
    "the delivered wake did not name the rule that raised it"

  queue=$(cat "$home/state/.wake-queue")
  assert_contains "$queue" 'highest=immediate' \
    "the promoted priority did not reach the durable wake queue"
  pass "the measured under-declared envelope is delivered at the promoted priority"
}

# ACCEPTANCE: replaying the recorded under-declared cases from the journal
# promotes them. The events go in through the real wake library, which journals
# each one with the status line as it read AT ARRIVAL, and come back out through
# the real journal reader. This is the case the whole unit is judged by.
test_replaying_recorded_under_declared_cases_from_the_journal_promotes_them() {
  local state out i id promoted line
  state=$(make_state replay)

  i=0
  for line in "${UNDER_DECLARED_STATUS[@]}"; do
    i=$((i + 1))
    id="under$i"
    printf '%s\n' "$line" > "$state/$id.status"
    append_wake "$state" signal "$id.status" "signal: $state/$id.status"
  done

  out=$(FM_STATE_OVERRIDE="$state" "$URGENCY" replay)
  promoted=$(printf '%s' "$out" | awk -F': ' '$1 == "promoted" { print $2 }' | awk '{ print $1 }')
  [ "$promoted" = "${#UNDER_DECLARED_STATUS[@]}" ] || \
    fail "replaying the journal promoted $promoted of ${#UNDER_DECLARED_STATUS[@]} recorded under-declared events; every one of them must promote, and one that does not is invisible in production: $out"

  # Not merely "some number promoted": the rules that fired must be the ones the
  # events are actually about, or the count could be reached by the wrong rule
  # firing on the wrong event.
  assert_contains "$out" 'blocker' "the recorded blocker case did not promote on the blocker rule"
  assert_contains "$out" 'credential' "the recorded credential case did not promote on the credential rule"
  assert_contains "$out" 'exposure' "the recorded exposure case did not promote on the exposure rule"
  assert_contains "$out" 'irreversible' "the recorded history-rewrite case did not promote on the irreversible rule"
  pass "every recorded under-declared case in the journal promotes on replay"
}

# ACCEPTANCE: promotion never lowers an event's priority.
#
# Asserted exhaustively rather than by example: every level of the ladder is
# crossed with every text in both corpora, including texts whose matching rule
# has a LOWER floor than the declared priority, which is the only shape in which
# a lowering bug could ever appear.
test_promotion_never_lowers_a_priority() {
  local state declared text effective checks=0 out declared_rank effective_rank
  state=$(make_state neverlower)

  for declared in low normal high immediate; do
    for text in "${UNDER_DECLARED_STATUS[@]}" "${ORDINARY_STATUS[@]}"; do
      out=$(urgency_ranks "$state" "$declared" "$text")
      IFS=$'\t' read -r declared_rank effective_rank <<< "$out"
      [ "$effective_rank" -ge "$declared_rank" ] || \
        fail "promotion LOWERED a priority: declared $declared, effective rank $effective_rank, on: $text"
      checks=$((checks + 1))
    done
  done

  # An immediate event carrying a high-floor rule's text is the specific case a
  # naive "the matching rule wins" implementation gets wrong.
  effective=$(urgency_effective "$state" immediate \
    'working: the deploy key was revoked, cannot proceed')
  [ "$effective" = immediate ] || \
    fail "a high-floor rule pulled an immediate event down to $effective"
  pass "promotion never lowers a priority ($checks ladder-by-corpus checks, plus the high-rule-on-immediate case)"
}

# ACCEPTANCE: promotion decisions are recorded with the evidence that triggered
# them. Not the rule name alone - the actual matching text, so a reader can
# disagree with the promotion rather than only observe it.
test_a_promotion_records_the_evidence_that_triggered_it() {
  local home record fields declared effective rule match event
  home=$(make_bridge_home evidence)
  write_envelope "$home" dpapi normal \
    'Captain DPAPI store on Timbook: 149 entries, one unprotected'
  surface_bridge "$home" > /dev/null

  assert_present "$home/state/urgency/promotions.tsv" \
    "a promotion left no record behind"
  record=$(cat "$home/state/urgency/promotions.tsv")
  fields=$(printf '%s' "$record" | awk -F'\t' '{ print NF; exit }')
  [ "$fields" -eq 9 ] || fail "the promotion record has $fields fields, not the nine its format declares: $record"

  # Read the fields BY POSITION. Asserting against the whole line would let the
  # event text stand in for the evidence field, and a record that carries the
  # event but not what matched in it is exactly the unexplainable promotion this
  # criterion exists against.
  IFS=$'\t' read -r _ _ _ _ declared effective rule match event <<< "$record"
  [ "$declared" = normal ] || fail "the record says the event declared '$declared', not normal"
  [ "$effective" = immediate ] || fail "the record says it was promoted to '$effective', not immediate"
  [ "$rule" = exposure ] || fail "the record names rule '$rule', not exposure"
  assert_contains "$match" 'unprotected' \
    "the record's evidence field is '$match'; without the text that triggered it the promotion cannot be argued with"
  assert_contains "$event" 'Captain DPAPI store' \
    "the record does not carry the event it judged, so it stops reading back once the journal ages out"
  pass "a promotion is recorded with the rule and the text that triggered it"
}

# Over-promotion is the cheaper failure and it is still a cost: it spends the
# captain's attention, which is the resource the whole undertaking protects.
# Real recorded routine progress must survive untouched.
test_recorded_ordinary_traffic_is_left_alone() {
  local state out promoted i id line
  state=$(make_state ordinary)

  i=0
  for line in "${ORDINARY_STATUS[@]}"; do
    i=$((i + 1))
    id="plain$i"
    printf '%s\n' "$line" > "$state/$id.status"
    append_wake "$state" signal "$id.status" "signal: $state/$id.status"
  done

  out=$(FM_STATE_OVERRIDE="$state" "$URGENCY" replay)
  promoted=$(printf '%s' "$out" | awk -F': ' '$1 == "promoted" { print $2 }' | awk '{ print $1 }')
  [ "$promoted" = 0 ] || \
    fail "$promoted of ${#ORDINARY_STATUS[@]} recorded routine events were promoted; each one spends the captain's attention: $out"
  pass "recorded ordinary progress is left exactly as it was declared"
}

# The record is bookkeeping and the wake is the work. A home that cannot write
# the record must still deliver the promoted priority, because holding an urgent
# event back over a bookkeeping failure inverts the whole point of the tier.
test_a_promotion_that_cannot_be_recorded_is_still_delivered() {
  local home out
  home=$(make_bridge_home unrecordable)
  write_envelope "$home" locked normal \
    '80/443 open to any source: INPUT policy ACCEPT, no Cloudflare rule'
  # A plain file where the record directory must go: the record cannot be
  # written and cannot be repaired by creating a directory.
  printf 'not a directory\n' > "$home/state/urgency"

  out=$(surface_bridge "$home" 2>/dev/null)
  assert_contains "$out" 'highest=immediate' \
    "a home that could not record the promotion also failed to deliver it"
  pass "a promotion whose record cannot be written is still delivered at the promoted priority"
}

# Only promotions are recorded. A record written for every ordinary event would
# bury the ones that mattered under the ones that did not.
test_nothing_is_recorded_for_an_event_left_alone() {
  local home
  home=$(make_bridge_home norecord)
  write_envelope "$home" plain normal 'Ack: firstmate origin repointed to curated fork'
  surface_bridge "$home" > /dev/null
  assert_absent "$home/state/urgency/promotions.tsv" \
    "an event that was left alone still wrote a promotion record"
  pass "nothing is recorded for an event that was left at its declared priority"
}

# This fleet's notification stream is German and English in the same inbox. An
# English-only rule set under-promotes every German event, which is the
# invisible failure, so both halves are asserted against real recorded German.
test_a_german_under_declared_event_promotes() {
  local home out
  home=$(make_bridge_home german)
  write_envelope "$home" freeze normal \
    'Wir laufen nicht aus admiralty - der Pin erreicht uns nicht. Bitte um Feststellung, ob der Freeze fuer uns noch gilt'
  out=$(surface_bridge "$home")
  assert_contains "$out" 'highest=high' \
    "a German event asking for a ruling was not promoted; an English-only rule set is an invisible under-promoter"
  assert_contains "$out" 'promoted-by=blocker' "the German request promoted on the wrong rule"
  pass "a recorded German under-declared event promotes on the same rules as an English one"
}

# The declared priority is the envelope's OWN field, not a guess from its text:
# an envelope that already declares itself immediate must not be reported as a
# promotion, or the record stops meaning anything.
test_an_already_urgent_envelope_is_not_reported_as_promoted() {
  local home out
  home=$(make_bridge_home already)
  write_envelope "$home" audit immediate 'Old-URL exposure audit from hlr: EXPOSED, one home, three remotes'
  out=$(surface_bridge "$home")
  assert_contains "$out" 'highest=immediate' "an immediate envelope did not surface as immediate"
  assert_not_contains "$out" 'promoted-by=' \
    "an envelope that already declared itself immediate was reported as a promotion"
  assert_absent "$home/state/urgency/promotions.tsv" \
    "an envelope that already declared itself immediate wrote a promotion record"
  pass "an envelope already declared at the top of the ladder is not reported as promoted"
}

test_multi_envelope_promotion_keeps_its_own_evidence() {
  local home out record declared effective rule match event
  home=$(make_bridge_home multi)
  write_envelope "$home" a-high high 'Routine release completed successfully'
  write_envelope "$home" b-credential low 'The deploy key was revoked, cannot proceed'

  out=$(surface_bridge "$home")
  assert_contains "$out" 'highest=high' "the inbox-wide effective maximum was not delivered"
  assert_contains "$out" 'declared=low' "the wake replaced the promoted envelope's declaration with the inbox maximum"
  assert_contains "$out" 'promoted-by=credential' "the promotion tying the inbox maximum lost its rule"

  record=$(cat "$home/state/urgency/promotions.tsv")
  IFS=$'\t' read -r _ _ _ _ declared effective rule match event <<< "$record"
  [ "$declared" = low ] || fail "the multi-envelope record says the promoted envelope declared '$declared', not low"
  [ "$effective" = high ] || fail "the multi-envelope record says the envelope promoted to '$effective', not high"
  [ "$rule" = credential ] || fail "the multi-envelope record names '$rule', not the promoted envelope's credential rule"
  assert_contains "$match" 'deploy key' "the multi-envelope record lost the promoted envelope's evidence"
  assert_contains "$event" 'revoked' "the multi-envelope record names the wrong envelope"
  pass "multi-envelope promotion retains its own declaration and evidence"
}

test_an_incomplete_scan_is_retried_without_delivery_or_cache() {
  local home first second
  home=$(make_bridge_home partial)
  write_envelope "$home" later normal \
    '80/443 open to any source: INPUT policy ACCEPT, no Cloudflare rule'

  first=$(FM_HOME="$home" FM_CHECK_TIMEOUT=1 bash -c '
    . "$1"
    . "$2"
    bridge_pending_envelope_scan() {
      printf "normal\tRoutine prefix\n"
      sleep 2
      printf "%s\n" __FM_BRIDGE_ENVELOPE_SCAN_COMPLETE__
    }
    export -f bridge_pending_envelope_scan
    bridge_inbox_surface 0
  ' _ "$WAKE_LIB" "$BRIDGE_LIB")
  [ -z "$first" ] || fail "an incomplete scan was delivered as complete: $first"
  assert_absent "$home/state/.bridge-urgency-cache" "an incomplete scan was cached as complete"
  assert_absent "$home/state/.bridge-surfaced" "an incomplete scan marked the inbox surfaced"
  assert_absent "$home/state/.wake-queue" "an incomplete scan reached the durable wake queue"

  second=$(surface_bridge "$home")
  assert_contains "$second" 'highest=immediate' "the incomplete inbox was not re-examined on the next cycle"
  assert_present "$home/state/.bridge-urgency-cache" "the later complete scan did not populate the cache"
  assert_present "$home/state/.bridge-surfaced" "the later complete scan did not mark the inbox surfaced"
  pass "an incomplete scan is neither delivered nor cached and is retried"
}

test_unpromoted_cache_reload_preserves_empty_fields() {
  local home first second
  home=$(make_bridge_home cacheplain)
  write_envelope "$home" plain normal 'Ack: firstmate origin repointed to curated fork'

  first=$(surface_bridge "$home")
  assert_not_contains "$first" 'promoted-by=' "ordinary traffic was promoted before cache reload"
  rm -f "$home/state/.bridge-surfaced"
  second=$(surface_bridge "$home")
  assert_not_contains "$second" 'promoted-by=' "an empty cached rule reloaded as a false promotion"
  assert_absent "$home/state/urgency/promotions.tsv" "an unpromoted cached subject wrote a promotion record"
  pass "unpromoted cache reload preserves empty promotion fields"
}

# The timing boundary, asserted rather than only documented: this unit decides
# what an event's urgency IS, and how long an event of a given urgency waits
# belongs to the batching unit. bridge_check_interval must therefore still read
# the DECLARED priority, so a promotion here cannot silently become a cadence
# change owned by someone else.
test_promotion_does_not_reach_the_poll_cadence() {
  local home interval
  home=$(make_bridge_home cadence)
  write_envelope "$home" firewall normal \
    '80/443 open to any source: INPUT policy ACCEPT, no Cloudflare rule'
  interval=$(
    FM_HOME="$home" bash -c \
      '. "$1"; . "$2"; CHECK_INTERVAL=300 bridge_check_interval' _ "$WAKE_LIB" "$BRIDGE_LIB"
  )
  [ "$interval" = 300 ] || \
    fail "promoting an event changed the Bridge poll cadence to $interval; timing belongs to the batching unit, not this one"
  pass "a promotion changes what an event's urgency is, and leaves the poll cadence alone"
}

test_the_measured_under_declared_envelope_is_delivered_promoted
test_replaying_recorded_under_declared_cases_from_the_journal_promotes_them
test_promotion_never_lowers_a_priority
test_a_promotion_records_the_evidence_that_triggered_it
test_recorded_ordinary_traffic_is_left_alone
test_a_promotion_that_cannot_be_recorded_is_still_delivered
test_nothing_is_recorded_for_an_event_left_alone
test_a_german_under_declared_event_promotes
test_an_already_urgent_envelope_is_not_reported_as_promoted
test_multi_envelope_promotion_keeps_its_own_evidence
test_an_incomplete_scan_is_retried_without_delivery_or_cache
test_unpromoted_cache_reload_preserves_empty_fields
test_promotion_does_not_reach_the_poll_cadence
