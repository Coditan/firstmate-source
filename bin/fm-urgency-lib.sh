#!/usr/bin/env bash
# The urgency promoter: the tier that RAISES an event's urgency when the event's
# own declaration understates its content.
#
# WHY THIS EXISTS, AND WHY IT IS NOT A FILTER SETTING
# What was measured in this fleet's notification stream is UNDER-DECLARED
# urgency, not noise. The panel judge verified one case by hand on 2026-08-11
# (data/panel-question-should-this-fleet-1177-judge/report.md): Bridge envelope
# 2026-08-10T01-22-13Z-tugboat-80-443-open-to-any-source-...json, declared
# priority "normal", kind "reply", subject "80/443 open to any source: INPUT
# policy ACCEPT, no Cloudflare rule". A firewall opened to the whole internet,
# arriving marked as ordinary traffic.
# Raising urgency is the OPPOSITE job from filtering it out, so this is its own
# capability and not a knob on a filter. Nothing here suppresses, drops, defers,
# or downgrades an event: the captain settled on 2026-08-11 that volume is solved
# downstream by judgement, never upstream by quieting an observer.
#
# IT ONLY EVER RAISES
# fm_urgency_effective returns the MAXIMUM of the declared priority and every
# rule floor that matched. Lowering is not a path that exists to be disabled: it
# is unreachable by construction, because a maximum over a set that always
# contains the declared priority can never fall below it. There is deliberately
# no demotion function in this file.
#
# IT IS MECHANICAL
# No model call, no network, no clock dependence: the same event text always
# yields the same verdict. That is what makes a promotion replayable against the
# journal afterwards, and what lets this run in the watcher's own path rather
# than behind a tier that has to be awake.
#
# THE PRIORITY LADDER
# low < normal < high < immediate. This is not a new vocabulary: it is the one
# Bridge envelopes already carry in their own .priority field, read by
# bin/fm-bridge-inbox-lib.sh's bridge_pending_priority_scan, and the one the
# captain's batching delays are stated in. An unrecognised value reads as normal,
# the same fallback that scan already applies.
#
# WHAT THIS UNIT DOES NOT TOUCH
# HOW LONG an event of a given urgency waits is a separate unit's contract
# (fm-bosun-model-survey-priority-batching), and bridge_check_interval's
# priority-to-poll-cadence mapping belongs to it. This file decides what an
# event's urgency IS and stops there. docs/urgency-promotion.md records that
# boundary and the one consequence of holding it.
#
# PROMOTION RECORD FORMAT
# One record per line, nine tab-separated fields, written once and never
# rewritten, under $STATE/urgency/. A promotion nobody can explain afterwards is
# indistinguishable from a bug, so the record carries the evidence and not just
# the outcome:
#   useq       promotion sequence, monotonic within a home, allocated under the
#              urgency lock.
#   epoch      when the promotion was recorded.
#   kind       the event kind, verbatim from the producer.
#   key        the event key, verbatim from the producer.
#   declared   the priority the event ARRIVED marked as.
#   effective  the priority it was promoted to. Always above declared: only
#              promotions are recorded, because a record of "nothing happened"
#              on every ordinary event would bury the ones that did.
#   rule       which rule raised it, by name, from FM_URGENCY_RULES.
#   match      THE TEXT THAT TRIGGERED IT - the actual matching fragment of the
#              event, not a restatement of the rule. This is the field that makes
#              a promotion arguable: a reader can disagree with it.
#   event      the event text as it was judged, bounded, so the record still
#              reads back after the journal's retention horizon passes its
#              subject.
# No field can contain a tab, a carriage return, or a newline: every field goes
# through fm_wake_clean_field on the way in, the same cleaning the wake queue,
# the journal, and the bosun record already apply.
#
# RETENTION - THE SAME CRUDE BOUND, NAMED AS ONE
# A size bound, not a policy: two files of FM_URGENCY_MAX_BYTES. It does not
# reason about age or promotion rate. Deferred, and recorded as deferred rather
# than described as a policy, exactly as the journal and the bosun record do.

FM_URGENCY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_WAKE_LIB_DIR:-}" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_URGENCY_LIB_DIR/fm-wake-lib.sh"
fi

FM_URGENCY_DIR="${FM_URGENCY_DIR:-$STATE/urgency}"
FM_URGENCY_ACTIVE="$FM_URGENCY_DIR/promotions.tsv"
FM_URGENCY_PREVIOUS="$FM_URGENCY_DIR/promotions.previous.tsv"
FM_URGENCY_LOCK="$FM_URGENCY_DIR/.lock"
FM_URGENCY_SEQ_FILE="$FM_URGENCY_DIR/.seq"
FM_URGENCY_FIELD_BYTES="${FM_URGENCY_FIELD_BYTES:-4096}"
FM_URGENCY_MAX_BYTES="${FM_URGENCY_MAX_BYTES:-8388608}"

# The ladder, lowest first. One owner for the ordering; the two functions below
# are the only readers, so a level added here must be added to both.
# shellcheck disable=SC2034 # Documents the ladder for a reader of this file.
FM_URGENCY_LEVELS="low normal high immediate"

fm_urgency_rank() {  # <priority> -> 0..3 on stdout
  case "$1" in
    low) printf '0' ;;
    normal) printf '1' ;;
    high) printf '2' ;;
    immediate) printf '3' ;;
    # Same fallback bridge_pending_priority_scan already applies to an
    # unrecognised envelope priority, so the two cannot disagree.
    *) printf '1' ;;
  esac
}

fm_urgency_level() {  # <rank> -> priority name on stdout
  case "$1" in
    0) printf 'low' ;;
    1) printf 'normal' ;;
    2) printf 'high' ;;
    3) printf 'immediate' ;;
    *) printf 'normal' ;;
  esac
}

# --- the rules --------------------------------------------------------------
#
# One rule per line: <name>|<floor>|<extended regex>, matched case-insensitively
# against the whole event text.
#
# THE RULES ARE BILINGUAL ON PURPOSE. This fleet's notification stream is
# measurably German and English in the same inbox - of 420 acked Bridge
# envelopes on 2026-08-14, both languages appear across every declared priority.
# An English-only rule set would under-promote every German event, and
# under-promotion is the invisible failure this tier exists against: the event
# arrives at its declared priority, looks normal, and what it understated is
# found later by a human, with no error and nothing to see.
#
# Each rule's floor is calibrated against what THIS FLEET already declares at
# that level rather than against a general notion of urgency, so a promotion
# lands where a sender who had thought about it would have put the event
# himself. Exposure and irreversibility sit at immediate because that is what
# the corpus's own seven immediate envelopes are about, almost without
# exception. Credentials, blockers, failures, and review-ready work sit at high
# because that is where the fleet's senders put them when they declare them at
# all - and the same class arriving as normal from a different sender is exactly
# the under-declaration being corrected.
#
# There is deliberately NO negation guard. "repaired", "no decision needed", and
# "verified working" would each suppress a promotion, and suppressing one is
# indistinguishable from never having found it. The cost of leaving them in is
# measured and reported in docs/urgency-promotion.md rather than tuned away by a
# rule nobody can see fire.
FM_URGENCY_RULES=$(cat <<'RULES'
exposure|immediate|(exposed|exposure|open to any source|world[- ]readable|publicly (readable|reachable|accessible|visible|available)|already public|unprotected|unencrypted|in the clear|plaintext (token|password|secret|key)|0\.0\.0\.0/0|exponiert|offengelegt|ungesch(ue|ü)tzt|(oe|ö)ffentlich (erreichbar|lesbar|sichtbar)|Klartext)
irreversible|immediate|(irreversible|unrecoverable|data loss|force[- ]push|--force|rewrit(e|es|ing|ten) (the )?history|history rewrite|discard(ed|ing)? unlanded|unwiderruflich|Datenverlust|nicht wiederherstellbar)
credential|high|(credential|api[- ]key|ssh key|access token|auth token|bearer token|password|passphrase|secret key|private key|relay key|deploy key|\btoken\b|Zugangsdaten|Schl(ue|ü)ssel|Kennwort|Passwort|Geheimnis)
blocker|high|(\bblocked\b|\bblocker\b|cannot proceed|can not proceed|unable to proceed|\bstuck\b|awaiting (the )?(captain|commodore|your|a) |await(s|ing) (your|the) (answer|decision|approval|ruling)|needs? a decision|please (decide|rule|confirm|advise)|wie verfahren|blockiert|Bitte um |erbeten|steht (noch )?aus|offene Frage|Entscheidung des Commodore)
failure|high|(\bfailed\b|\bfailure\b|\berror\b|\bbroken\b|\bcrash(ed|es)?\b|\boutage\b|exhaust(ed|ion)|refus(e|es|ed) to|timed out|false (alarm|pass|positive)|silently (fails|nothing|broken)|Fehler|Defekt|Ausfall|Absturz|scheitert|fehlgeschlagen|Fehlalarm)
review-ready|high|(PR ready|checks green|ready (for|to) (review|merge)|awaiting (review|merge)|pull/[0-9]+|merge request|zur (Pr(ue|ü)fung|Freigabe)\b|Freigabe erbeten)
RULES
)

# Print the rule table, one "<name> <floor> <regex>" per line. The CLI's `rules`
# command prints exactly this, so what a reader is shown and what actually runs
# are the same text.
fm_urgency_rule_lines() {
  printf '%s\n' "$FM_URGENCY_RULES" | grep -v '^[[:space:]]*$'
}

# --- declared priority ------------------------------------------------------

# What an event ARRIVED marked as. Two surfaces carry a declaration today and
# they are not the same thing:
#
#   1. A Bridge inbox event carries an EXPLICIT priority, read verbatim from the
#      envelope's own .priority field and printed into the wake payload as
#      "highest=<p>". This is the surface the measured under-declaration lives
#      on, and the only one where a sender states an urgency in so many words.
#   2. Every other kind carries an IMPLICIT declaration in its own shape: a
#      heartbeat declares itself routine by being a heartbeat, and a signal
#      declares itself through its status verb, which bin/fm-classify-lib.sh
#      already owns the reading of. That owner is reused here rather than
#      re-derived, so a change to the captain-relevant verb set reaches this
#      tier too.
fm_urgency_declared() {  # <kind> <payload> [<snapshot>] -> priority on stdout
  local kind=$1 payload=$2 snapshot=${3:-} declared

  case "$kind" in
    check)
      declared=$(printf '%s' "$payload" | grep -oiE 'highest=[a-z]+' | tail -1)
      declared=${declared#*=}
      if [ -n "$declared" ]; then
        # Round-trip through the ladder so an unrecognised value lands on the
        # documented fallback rather than reaching a caller raw.
        fm_urgency_level "$(fm_urgency_rank "$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]')")"
        return 0
      fi
      printf 'normal'
      ;;
    heartbeat)
      printf 'low'
      ;;
    signal)
      if [ -n "$snapshot" ] && fm_urgency_status_is_captain_relevant "$snapshot"; then
        printf 'high'
      else
        printf 'normal'
      fi
      ;;
    *)
      printf 'normal'
      ;;
  esac
  return 0
}

# Reach bin/fm-classify-lib.sh's reading of a status line, loading it on first
# use. Kept behind one function so the Bridge path, which never asks about a
# status verb, does not pay for a library it does not consult.
fm_urgency_status_is_captain_relevant() {  # <status-line>
  if ! command -v status_is_captain_relevant >/dev/null 2>&1; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$FM_URGENCY_LIB_DIR/fm-classify-lib.sh" || return 1
  fi
  status_is_captain_relevant "$1"
}

# --- the promotion ----------------------------------------------------------

# Decide one event's effective urgency.
#
# Sets FM_URGENCY_EFFECTIVE, FM_URGENCY_RULE, and FM_URGENCY_MATCH.
# Returns 0 when the event was PROMOTED, 1 when it was left exactly as declared.
# Both are ordinary outcomes; the return code says which happened so a caller
# can record only the promotions.
#
# When several rules match, the one with the highest floor wins and is the one
# named in the record. The others are not lost information worth carrying: a
# reader who disagrees with the winning rule can re-run the whole table with the
# CLI's `classify`, which prints every match.
FM_URGENCY_EFFECTIVE=
FM_URGENCY_RULE=
FM_URGENCY_MATCH=
fm_urgency_effective() {  # <declared> <text>
  local declared=$1 text=$2
  local line name floor pattern rank best_rank hit

  declared=$(fm_urgency_level "$(fm_urgency_rank "$declared")")
  best_rank=$(fm_urgency_rank "$declared")
  FM_URGENCY_EFFECTIVE=$declared
  FM_URGENCY_RULE=
  FM_URGENCY_MATCH=

  while IFS='|' read -r name floor pattern; do
    [ -n "$name" ] || continue
    rank=$(fm_urgency_rank "$floor")
    # Nothing below the standing best can change the outcome, so it is not
    # consulted. This is what makes the never-lower property structural rather
    # than a check that could be forgotten: the result is a maximum, and the
    # declared priority is always one of the values in it.
    [ "$rank" -gt "$best_rank" ] || continue
    hit=$(printf '%s' "$text" | grep -oiE "$pattern" | head -1) || true
    [ -n "$hit" ] || continue
    best_rank=$rank
    FM_URGENCY_EFFECTIVE=$(fm_urgency_level "$rank")
    FM_URGENCY_RULE=$name
    FM_URGENCY_MATCH=$hit
  done <<EOF
$(fm_urgency_rule_lines)
EOF

  [ -n "$FM_URGENCY_RULE" ] || return 1
  return 0
}

# Every rule that matches, highest floor first, as "<name> <floor> <match>".
# The audit view: fm_urgency_effective answers what happened, this answers what
# else nearly did.
fm_urgency_matches() {  # <text>
  local text=$1 line name floor pattern hit
  while IFS='|' read -r name floor pattern; do
    [ -n "$name" ] || continue
    hit=$(printf '%s' "$text" | grep -oiE "$pattern" | head -1) || true
    [ -n "$hit" ] || continue
    printf '%s\t%s\t%s\n' "$(fm_urgency_rank "$floor")" "$name" "$hit"
  done <<EOF
$(fm_urgency_rule_lines)
EOF
}

# --- the record -------------------------------------------------------------

fm_urgency_cap_field() {  # <text> -> capped text on stdout
  local text=$1 marker=' [truncated]' keep
  local LC_ALL=C
  if [ "${#text}" -le "$FM_URGENCY_FIELD_BYTES" ]; then
    printf '%s' "$text"
    return 0
  fi
  keep=$((FM_URGENCY_FIELD_BYTES - ${#marker}))
  [ "$keep" -gt 0 ] || keep=0
  printf '%s%s' "${text:0:$keep}" "$marker"
}

fm_urgency_rotate_if_full() {
  local size
  [ -f "$FM_URGENCY_ACTIVE" ] || return 0
  size=$(wc -c < "$FM_URGENCY_ACTIVE" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$FM_URGENCY_MAX_BYTES" ] || return 0
  mv -f "$FM_URGENCY_ACTIVE" "$FM_URGENCY_PREVIOUS" 2>/dev/null || return 1
  return 0
}

# Append one promotion record. Returns 0 when it reached disk.
#
# A failure here must never fail the caller's own work: DELIVERY OUTRANKS THE
# RECORD OF IT, the same order the journal keeps. A promoted event that could not
# be recorded is still delivered at its promoted priority, and the failure is
# reported on stderr rather than swallowed - because the alternative is holding
# an urgent event back over a bookkeeping problem.
fm_urgency_record() {  # <kind> <key> <declared> <effective> <rule> <match> <event>
  local kind=$1 key=$2 declared=$3 effective=$4 rule=$5 match=$6 event=$7
  local seq status=0 epoch

  epoch=$(date +%s)
  kind=$(printf '%s' "$kind" | fm_wake_clean_field)
  key=$(printf '%s' "$key" | fm_wake_clean_field)
  rule=$(printf '%s' "$rule" | fm_wake_clean_field)
  match=$(fm_urgency_cap_field "$(printf '%s' "$match" | fm_wake_clean_field)")
  event=$(fm_urgency_cap_field "$(printf '%s' "$event" | fm_wake_clean_field)")

  mkdir -p "$FM_URGENCY_DIR" 2>/dev/null || return 1
  fm_lock_acquire_wait "$FM_URGENCY_LOCK" || return 1

  fm_urgency_rotate_if_full || status=1
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$FM_URGENCY_SEQ_FILE" 2>/dev/null || true)
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$FM_URGENCY_SEQ_FILE" 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$seq" "$epoch" "$kind" "$key" "$declared" "$effective" "$rule" "$match" "$event" \
      >> "$FM_URGENCY_ACTIVE" 2>/dev/null || status=1
  fi

  fm_lock_release "$FM_URGENCY_LOCK"
  return "$status"
}

fm_urgency_cat() {
  [ -f "$FM_URGENCY_PREVIOUS" ] && cat "$FM_URGENCY_PREVIOUS"
  [ -f "$FM_URGENCY_ACTIVE" ] && cat "$FM_URGENCY_ACTIVE"
  return 0
}

# Decide AND record in one call: the entry point for a delivery site.
#
# Prints the effective priority on stdout so a caller can use it directly, and
# returns 0 when it promoted. The record is written only on a promotion, and a
# failure to write it is reported without changing the priority handed back.
fm_urgency_deliver() {  # <kind> <key> <declared> <text> -> effective on stdout
  local kind=$1 key=$2 declared=$3 text=$4

  if fm_urgency_effective "$declared" "$text"; then
    fm_urgency_record "$kind" "$key" "$declared" "$FM_URGENCY_EFFECTIVE" \
      "$FM_URGENCY_RULE" "$FM_URGENCY_MATCH" "$text" \
      || printf 'fm-urgency: could not record the promotion of %s/%s from %s to %s (rule %s); it is still delivered at %s\n' \
        "$kind" "$key" "$declared" "$FM_URGENCY_EFFECTIVE" "$FM_URGENCY_RULE" "$FM_URGENCY_EFFECTIVE" >&2
    printf '%s' "$FM_URGENCY_EFFECTIVE"
    return 0
  fi
  printf '%s' "$FM_URGENCY_EFFECTIVE"
  return 1
}
