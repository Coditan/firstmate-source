#!/usr/bin/env bash
# fm-decision-ledger.sh - read the captain decisions this home has already settled,
# and report every decision record that is structurally unfinished.
#
# WHY
# A store nobody consults is the same failure wearing different clothes. On
# 2026-08-17 firstmate re-asked the captain three questions he had already settled
# that day, because the answers lived only in worker status logs, a pull-request
# body, and one session's context - all three temporary. bin/fm-decision-hold.sh
# `record` closed the write side of that. This is the read side: the command a fresh
# session, a bearings pass, and a decision board run BEFORE presenting anything as
# open.
#
# WHAT IT READS
# The one store, directly: `kind: captain` rows in the active home's
# data/backlog.md and data/done-archive.md. Not a second store - it never writes,
# and it holds nothing of its own. It reads the raw markdown rather than
# `tasks-axi show`, for two reasons: `show` cannot see archived rows at all, and its
# escaped one-line body is a representation of the captain's words rather than the
# words. The raw row is the only place the bytes survive unmediated.
#
# THE DIGEST IS RE-CHECKED ON EVERY READ
# bin/fm-decision-hold.sh stores a sha256 of the exact decision text alongside it.
# This command recomputes that digest from the stored text and reports
# `verbatim: false` when they disagree. So a later hand-edit of a settled decision
# is visible here rather than quietly authoritative, and "these are his words" is
# something this output demonstrates rather than asserts.
#
# WHAT --audit FINDS
# Every class below is STRUCTURAL. None of them reads prose to guess that a
# decision happened, which the lifecycle rightly forbids; each one is a shape the
# records themselves are in.
#
#   duplicate-suspect      One investigation group holds several open records, or
#                          one decision key is open under several investigations.
#                          A BACKSTOP, not the duplicate mechanism: it is blind to
#                          the same question re-asked in different words, which is
#                          measured behaviour, so the fold is required of the filer
#                          at intake in bin/fm-decision-hold.sh instead.
#   open-but-settled       An open record whose group and key already carry a
#                          settled record. The ruling exists; nothing re-measured
#                          the question against it.
#   unfinished-close       A captain item carries a resolution record but is not
#                          closed. bin/fm-decision-hold.sh writes the body, then
#                          clears dependency edges, then closes - so this is
#                          exactly what an interrupted close leaves behind, and
#                          re-running the same `record` call completes it.
#   closed-without-record  A captain item is closed and carries no resolution
#                          record. The question is gone from the open surfaces and
#                          the answer was never stored, which is the loss this
#                          whole mechanism exists to prevent.
#   acted-but-open         A captain hold is still held, it blocks at least one
#                          task, and every task it blocks is done. The work went
#                          ahead, so the decision was given; nothing closed the
#                          hold. This is the shape the 2026-08-17 recovery-point
#                          case was in, and nothing detected it.
#   altered-record         The stored decision text no longer matches its recorded
#                          digest.
#   stale-body-state       A closed record whose own text still says it awaits a
#                          captain decision, so body and state disagree and neither
#                          reader can tell which is stale.
#   premise-unmeasurable   An open record whose premise could not be measured from
#                          the seat that last tried. Reported so it is NOT folded:
#                          unmeasurable is a third outcome, never a synonym for
#                          false. See "WHY NOTHING HERE FOLDS ON A PREMISE" below.
#
# WHY NOTHING HERE FOLDS ON A PREMISE
# On 2026-08-17 a seat re-measured a record saying a validation gate registered that
# home against the wrong public repository, so a push from there would land in the
# wrong place. Re-measured, the registry was empty and the premise did not hold. But
# the record had been measured on a path that seat no longer occupied: the seat had
# moved and the validation state had not come with it, so the wrong registration may
# still stand on the original machine, which that seat cannot see. An automatic fold
# on that reading would have closed a live finding with nobody left who could see
# it. So a premise reading that cannot be taken is recorded as unmeasurable and
# surfaced for a person, and `false now` and `cannot be measured from here` are never
# collapsed into one outcome. It is this fleet's own rule - never convert cannot
# measure into does not exist - applied to the decision mechanism itself.
#
# It reports; it never repairs. Repair is bin/fm-decision-hold.sh's, and closing a
# captain decision is never a script's call to make unprompted.
#
# Usage:
#   fm-decision-ledger.sh [--limit <n>] [--all]
#   fm-decision-ledger.sh --audit [--json]
#   fm-decision-ledger.sh --premises [--json]
#   fm-decision-ledger.sh --records [--repo <name>]
#   fm-decision-ledger.sh --json [--limit <n>] [--all]
#   fm-decision-ledger.sh -h | --help
#
# Options:
#   --limit <n>  settled decisions to show, newest first (default 5)
#   --all        every settled decision, no limit
#   --audit      only the unfinished records; exit 1 when any are found
#   --premises   every open decision with the premise it was filed on and when that
#                premise was last re-measured; the weekly sweep's input
#   --records    flat `class<TAB>id<TAB>repo<TAB>title` list of every captain record,
#                open first; this is what the intake gate reads
#   --repo <n>   with --records, restrict to one repository
#   --json       machine-readable form of whichever view was selected
#
# Exit status is 0 for a clean read, 1 under --audit when any finding exists, and 2
# for a usage or environment error. The nonzero --audit status is what lets a caller
# treat "nothing is half-closed" as a checkable condition.
#
# Output contract: `fm-decision-ledger.v1`.
#   settled[]  id, origin, key, title, repo, door, closed, source, routed[],
#              decision (verbatim), digest, verbatim (digest re-check)
#   open[]     id, title, repo, held, blocks[] - captain questions still unanswered
#   folded[]   id, title, successor, fold_reason - questions a later record covers
#   audit[]    class, id, detail
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
ARCHIVE="$DATA/done-archive.md"

die() { printf 'fm-decision-ledger.sh: %s\n' "$1" >&2; exit 2; }

usage() {
  awk 'NR == 1 { next } /^# ?/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

LIMIT=5
ALL=0
MODE=digest
JSON=0
RECORDS_REPO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --limit) [ "$#" -gt 1 ] || die "--limit needs a number"
             case "$2" in ''|*[!0-9]*) die "--limit must be a non-negative integer" ;; esac
             LIMIT=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    --audit) MODE=audit; shift ;;
    --records) MODE=records; shift ;;
    --premises) MODE=premises; shift ;;
    --repo) [ "$#" -gt 1 ] || die "--repo needs a name"; RECORDS_REPO=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

# One awk over both files. It emits JSON itself rather than a delimited stream,
# because a captain decision may legally contain tabs, quotes, and blank lines, and
# every delimiter cheap enough to be worth using is a delimiter the captain could
# type. Escaping once, here, is the honest option.
parse_records() {
  awk '
    function jesc(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else out = out c
        }
      return out
    }
    function field(line, name,   m) {
      if (match(line, "\\(" name ": [^)]*\\)")) {
        m = substr(line, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
        return m
      }
      return ""
    }
    function is_header(l) {
      return (l ~ /^- \[[ xX]\] [A-Za-z0-9][A-Za-z0-9._-]* - /) \
        || (l ~ /^- \*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\* - /)
    }
    function header_id(l,   rest) {
      if (index(l, "- **") == 1) { rest = substr(l, 5); return substr(rest, 1, index(rest, "**") - 1) }
      rest = substr(l, 7)
      return substr(rest, 1, index(rest, " - ") - 1)
    }
    function header_title(l, id,   rest, cut) {
      rest = substr(l, index(l, id " - ") + length(id) + 3)
      cut = index(rest, " (")
      if (cut > 0) rest = substr(rest, 1, cut - 1)
      cut = index(rest, " blocked-by:")
      if (cut > 0) rest = substr(rest, 1, cut - 1)
      return rest
    }
    function blockers(l,   rest, cut) {
      if (!match(l, /blocked-by:[[:space:]]*[^[:space:])]+/)) return ""
      rest = substr(l, RSTART + 11, RLENGTH - 11)
      sub(/^[[:space:]]+/, "", rest)
      gsub(/"/, "", rest)
      return rest
    }
    function flush(   i, decision, grab, envelope, digest, routed, door, line,
                      superseded, successor, premise, premise_checked, fold_reason,
                      state_text, premise_filed) {
      if (cur_id == "") return
      decision = ""; grab = 0; envelope = 0; digest = ""; routed = ""; door = ""
      superseded = 0; successor = ""; premise = ""; premise_checked = ""; fold_reason = ""
      state_text = ""; premise_filed = ""
      for (i = 1; i <= bn; i++) {
        line = body[i]
        if (i == 1 && line == "Resolution recorded by fm-decision-hold.") { envelope = 1; continue }
        if (i == 1 && line == "Superseded by fm-decision-hold.") { superseded = 1; continue }
        # A premise is carried by an open record, outside either envelope, so it is
        # read from any body line rather than from a fixed position.
        if (index(line, "Premise: ") == 1) { premise = substr(line, 10); continue }
        if (index(line, "Premise measured: ") == 1) { premise_checked = substr(line, 19); continue }
        if (index(line, "Premise filed: ") == 1) { premise_filed = substr(line, 16); continue }
        # A closed record whose body still asserts it awaits a decision is the exit
        # problem in its second form; the reader is told, not silently reconciled.
        if (index(line, "State: ") == 1) { state_text = substr(line, 8); continue }
        if (superseded) {
          if (index(line, "Successor: ") == 1) { successor = substr(line, 12) }
          else if (index(line, "Reason: ") == 1) { fold_reason = substr(line, 9) }
          continue
        }
        if (!envelope) continue
        if (grab == 1) {
          if (line == "Routed work:" && decision ~ /\n$/) { grab = 2; continue }
          decision = decision line "\n"
          continue
        }
        # "- (none)" is the recorded fact that the decision gated nothing; it is not
        # a routed identity, so it never enters the list.
        if (grab == 2) {
          if (line != "" && substr(line, 3) != "(none)") routed = routed (routed == "" ? "" : ",") substr(line, 3)
          continue
        }
        if (index(line, "Decision digest: ") == 1) { digest = substr(line, 18); continue }
        if (index(line, "Door: ") == 1) { door = substr(line, 7); continue }
        if (line == "Captain decision:") { grab = 1; continue }
      }
      # The decision ran up to the blank line before "Routed work:"; drop that
      # separator and the line terminator the accumulator added.
      sub(/\n\n$/, "", decision)
      printf "%s{\"id\":\"%s\",\"title\":\"%s\",\"repo\":\"%s\",\"kind\":\"%s\",\"state\":\"%s\",\"source\":\"%s\",\"closed\":\"%s\",\"hold_kind\":\"%s\",\"held\":%s,\"blockers\":\"%s\",\"envelope\":%s,\"complete\":%s,\"digest\":\"%s\",\"door\":\"%s\",\"routed\":\"%s\",\"decision\":\"%s\",\"folded\":%s,\"successor\":\"%s\",\"fold_reason\":\"%s\",\"premise\":\"%s\",\"premise_measured\":\"%s\",\"premise_filed\":\"%s\",\"state_text\":\"%s\"}",
        (emitted++ ? "," : ""), jesc(cur_id), jesc(cur_title), jesc(cur_repo), jesc(cur_kind),
        cur_state, cur_source, jesc(cur_closed), jesc(cur_hold_kind),
        (cur_hold == "" ? "false" : "true"), jesc(cur_blockers),
        (envelope ? "true" : "false"), (grab == 2 ? "true" : "false"),
        jesc(digest), jesc(door), jesc(routed), jesc(decision),
        (superseded ? "true" : "false"), jesc(successor), jesc(fold_reason),
        jesc(premise), jesc(premise_checked), jesc(premise_filed), jesc(state_text)
      cur_id = ""
    }
    BEGIN { printf "[" }
    FNR == 1 { flush(); section = ""; source = (FILENAME ~ /done-archive\.md$/ ? "archive" : "backlog") }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^##[[:space:]]+/) {
        flush()
        if (line ~ /In flight/) section = "in_flight"
        else if (line ~ /Queued/) section = "queued"
        else section = "done"
        next
      }
      if (is_header(line)) {
        flush()
        cur_id = header_id(line)
        cur_title = header_title(line, cur_id)
        cur_repo = field(line, "repo")
        cur_kind = field(line, "kind")
        cur_hold = field(line, "hold")
        cur_hold_kind = field(line, "hold-kind")
        cur_blockers = blockers(line)
        cur_source = source
        cur_state = section
        if (line ~ /^- \[[xX]\]/) cur_state = "done"
        if (match(line, /\(done [^)]*\)/)) cur_closed = substr(line, RSTART + 6, RLENGTH - 7)
        else cur_closed = ""
        bn = 0
        next
      }
      if (cur_id == "") next
      if (line != "" && index(line, "  ") != 1) { flush(); next }
      body[++bn] = (line == "" ? "" : substr(line, 3))
    }
    END { flush(); printf "]\n" }
  ' "$@"
}

FILES=""
[ -f "$BACKLOG" ] && FILES="$BACKLOG"
[ -f "$ARCHIVE" ] && FILES="$FILES${FILES:+ }$ARCHIVE"
if [ -z "$FILES" ]; then
  RECORDS='[]'
else
  # shellcheck disable=SC2086  # deliberate word split of a locally built file list
  RECORDS=$(parse_records $FILES) || die "could not read $DATA"
fi

printf '%s' "$RECORDS" | jq -e . >/dev/null 2>&1 \
  || die "backlog parse produced invalid records; inspect $BACKLOG"

# Classify. `acted-but-open` needs the state of every task in the home, not just the
# captain ones, so the dependent-state map is built from the full record set before
# the captain rows are filtered out.
CLASSIFIED=$(printf '%s' "$RECORDS" | jq '
  (map({key: .id, value: .state}) | from_entries) as $state
  | (map(select((.blockers // "") != "")
         | . as $t
         | (.blockers | split(",") | map(select(length > 0)))
         | map({blocker: ., dep: $t.id, dep_state: $t.state}))
     | add // []) as $edges
  | map(select(.kind == "captain"))
  | map(
      . as $r
      | ($edges | map(select(.blocker == $r.id))) as $deps
      # A panel files its records per MEMBER, so one question becomes up to three
      # ids. The origin group - the identity with a trailing panel role stripped -
      # is what makes those recognisable as one investigation, and it is the same
      # convention bin/fm-decision-inventory.sh reads. Both are reading contracts
      # owned elsewhere (bin/fm-decision-hold.sh, bin/fm-model-panel.sh).
      | (($r.id | index("-decision-")) as $at
         | if $at == null then {o: $r.id, k: ""} else {o: $r.id[0:$at], k: $r.id[($at + 10):]} end) as $split
      | $r + {
          origin: $split.o,
          key_slug: $split.k,
          group: (($split.o | capture("^(?<g>.+)-(a|b|judge[0-9]*)$") // null) as $m
                  | if $m == null then $split.o else $m.g end),
          blocks: ($deps | map(.dep)),
          all_deps_done: (($deps | length) > 0 and ($deps | all(.dep_state == "done"))),
          settled: ($r.envelope and $r.complete and $r.state == "done"),
          superseded: ($r.folded and $r.state == "done"),
          # "<date> <outcome> from <seat> at <locator>", or "never". Parsed
          # positionally because bin/fm-decision-hold.sh writes it positionally;
          # anything it cannot parse stays null rather than becoming a default,
          # since a guessed reading is what this whole class of failure is made of.
          premise_outcome: (($r.premise_measured // "") | capture("^[0-9-]+ (?<o>holds|broken|unmeasurable) ") // null | .o),
          premise_seat: (($r.premise_measured // "") | capture(" from (?<s>[^ ]+) at ") // null | .s),
          stale_state_text: (($r.state_text // "") | test("awaiting captain decision"))
        }
    )
  | map(. + {live: ((.settled or .superseded or .state == "done") | not)})
  | . as $caps
  | ($caps | map(select(.settled))) as $answered
  | {
      captain: $caps,
      audit: (
        ($caps | map(select(.envelope and .state != "done")
                     | {class: "unfinished-close", id: .id,
                        detail: "carries a recorded captain decision but is still open; re-run the same fm-decision-hold.sh record call to finish the close"}))
        + ($caps | map(select(.state == "done" and (.envelope | not) and (.folded | not))
                     | {class: "closed-without-record", id: .id,
                        detail: "closed with no captain decision stored and no supersession recorded; the answer is nowhere in this home"}))
        + ($caps | map(select(.live and .held and .all_deps_done)
                     | {class: "acted-but-open", id: .id,
                        detail: ("still held, yet every task it blocks is done: " + (.blocks | join(", ")))}))
        # THE EXIT PROBLEM IN ITS SECOND FORM. A closed record whose own body still
        # says it awaits a decision: three of four holds closed on one seat on
        # 2026-08-17 read that way. A reader who trusts the body reaches the
        # opposite conclusion from a reader who trusts the state, and neither can
        # tell which is stale.
        + ($caps | map(select((.live | not) and (.stale_state_text // false))
                     | {class: "stale-body-state", id: .id,
                        detail: "is closed, yet its own text still says it awaits a captain decision; the body and the record state disagree"}))
        # A PREMISE THAT COULD NOT BE MEASURED IS NOT A PREMISE THAT IS FALSE. A
        # seat re-measured a record about a wrong repository registration, found the
        # registry empty, and would have folded it - but the seat had moved, and the
        # wrong registration may still stand on the machine where it was found,
        # which this seat cannot see. Folding it there would have closed a live
        # finding with nobody left who could see it.
        + ($caps | map(select(.live and (.premise_outcome == "unmeasurable"))
                     | {class: "premise-unmeasurable", id: .id,
                        detail: ("its premise could not be measured from " + (.premise_seat // "the recording seat")
                                 + "; do NOT fold it on that reading - the finding may still be live where it was made")}))
        # DUPLICATES, AND THE HALF OF THEM THIS CANNOT SEE.
        # These two classes are STRUCTURAL: one investigation group holding several
        # open records, or one decision key open under several investigations. They
        # catch the panel-shaped multiplication, where one question becomes an
        # analyst record per member.
        # They do NOT catch a re-ask in different words, and that limit is measured,
        # not theoretical: on 2026-08-17 a seat with five open records had two that
        # asked one question - whether a named company counts as a customer, and
        # which parties count as intra-group - sharing no wording, no key, and no
        # origin group. No matcher here would pair those, and a text-similarity
        # matcher would not either.
        # That is why the fold is required of the FILER at intake, in
        # bin/fm-decision-hold.sh, and why these classes are a backstop for records
        # filed before that gate existed rather than the mechanism. They report a
        # suspicion for a reader to fold or reject; nothing is folded here.
        # More than one ORIGIN inside one group, not merely more than one record:
        # an investigation that legitimately raises two distinct questions shares a
        # group and an origin, and flagging that would make this alarm noise. What
        # is worth a look is several MEMBERS of one investigation each holding their
        # own open record.
        + ($caps | map(select(.live)) | group_by(.group)
           | map(select((map(.origin) | unique | length) > 1))
           | map({class: "duplicate-suspect", id: (.[0].id),
                  detail: ("one investigation has open captain records under "
                           + ((map(.origin) | unique | length) | tostring)
                           + " separate passes; fold the superseded ones with fm-decision-hold.sh supersede: "
                           + (map(.id) | join(", ")))}))
        + ($caps | map(select(.live)) | group_by(.key_slug)
           | map(select(length > 1 and (.[0].key_slug != "")))
           | map(select((map(.group) | unique | length) > 1))
           | map({class: "duplicate-suspect", id: (.[0].id),
                  detail: ("decision key \"" + (.[0].key_slug) + "\" is open under "
                           + (length | tostring) + " separate investigations: "
                           + (map(.id) | join(", ")))}))
        # ALREADY ANSWERED. An open record whose group and key already carry a
        # SETTLED record: the ruling exists and nothing re-measured the question
        # against it. 14 of that same 99 were in this state.
        + ($caps | map(select(.live)
                       | . as $o
                       | ($answered | map(select(.group == $o.group and .key_slug == $o.key_slug))) as $hit
                       | select(($hit | length) > 0)
                       | {class: "open-but-settled", id: $o.id,
                          detail: ("still open although the same question is already answered by "
                                   + ($hit | map(.id) | join(", "))
                                   + "; read that answer before putting this to the captain")}))
      )
    }
')

# Digest re-check. Only the settled records are re-hashed, because they are the ones
# whose text a reader is about to act on; an unfinished record has no verified text
# to offer either way.
# The intake gate in bin/fm-decision-hold.sh reads this. It is deliberately a flat
# tab-separated list rather than the full model: the gate needs the identity, the
# disposition and the question, and nothing it has to parse a body to obtain.
if [ "$MODE" = records ]; then
  printf '%s' "$CLASSIFIED" | jq -r --arg repo "$RECORDS_REPO" '
    [.captain[]
     | select($repo == "" or .repo == $repo)
     | {cls: (if .settled then "settled" elif .superseded then "superseded"
              elif .live then "open" else "closed" end),
        id, repo, title, closed}]
    | (map(select(.cls == "open")) | sort_by(.id))
      + (map(select(.cls == "settled")) | sort_by(.closed) | reverse)
      + (map(select(.cls == "superseded" or .cls == "closed")) | sort_by(.id))
    | .[] | [.cls, .id, .repo, .title] | @tsv'
  exit 0
fi

SETTLED=$(printf '%s' "$CLASSIFIED" | jq -c '[.captain[] | select(.settled)] | sort_by(.closed) | reverse')
VERIFIED='[]'
ALTERED='[]'
COUNT=$(printf '%s' "$SETTLED" | jq 'length')
i=0
while [ "$i" -lt "$COUNT" ]; do
  rec=$(printf '%s' "$SETTLED" | jq -c ".[$i]")
  text=$(printf '%s' "$rec" | jq -r '.decision')
  want=$(printf '%s' "$rec" | jq -r '.digest')
  got=$(sha256_text "$text")
  if [ "$got" = "$want" ]; then
    VERIFIED=$(printf '%s' "$VERIFIED" | jq -c --argjson r "$rec" '. + [$r + {verbatim: true}]')
  else
    VERIFIED=$(printf '%s' "$VERIFIED" | jq -c --argjson r "$rec" '. + [$r + {verbatim: false}]')
    ALTERED=$(printf '%s' "$ALTERED" | jq -c --argjson r "$rec" \
      '. + [{class: "altered-record", id: $r.id,
             detail: "the stored decision text no longer matches its recorded digest"}]')
  fi
  i=$((i + 1))
done

AUDIT=$(printf '%s' "$CLASSIFIED" | jq -c --argjson altered "$ALTERED" '.audit + $altered')
OPEN=$(printf '%s' "$CLASSIFIED" | jq -c \
  '[.captain[] | select(.live) | select(.envelope | not)
    | {id, title, repo, held, blocks, premise, premise_measured, premise_outcome}]')
FOLDED=$(printf '%s' "$CLASSIFIED" | jq -c \
  '[.captain[] | select(.superseded) | {id, title, successor, fold_reason}]')

SHOWN=$LIMIT
[ "$ALL" -eq 1 ] && SHOWN=$COUNT

LEDGER=$(jq -n \
  --arg home "$FM_HOME" \
  --argjson settled "$VERIFIED" \
  --argjson open "$OPEN" \
  --argjson audit "$AUDIT" \
  --argjson folded "$FOLDED" \
  --argjson shown "$SHOWN" \
  '{schema: "fm-decision-ledger.v1", home: $home,
    settled_total: ($settled | length),
    settled: $settled[0:$shown],
    open: $open,
    folded: $folded,
    audit: $audit,
    omitted: (if ($settled | length) > $shown
              then [{surface: "settled", count: (($settled | length) - $shown), reveal: "--all"}]
              else [] end)}')

AUDIT_COUNT=$(printf '%s' "$AUDIT" | jq 'length')

# THE PREMISE VIEW, and the candidate rule it deliberately does not implement.
#
# The proposal was a premise re-check that surfaces a decision whose stated premise
# no longer measures true. A script cannot measure most of these premises: "the
# bosun service is not deployed yet" is not a computable predicate, and building a
# facility to run stored check commands would add an execution surface to the weekly
# sweep in exchange for the minority of premises that happen to be mechanical.
#
# So this view does what can actually be done honestly. It prints every open captain
# decision with the premise it was filed on and the date that premise was last
# re-measured, oldest first, and it reports a record with no premise as having none
# rather than as fine. The re-measuring is the reader's, which is what the weekly
# sweep already is; `fm-decision-hold.sh recheck` stamps the result so the next sweep
# can tell an examined record from an untouched one. Nothing here claims a premise
# still holds - only when it was last looked at.
if [ "$MODE" = premises ]; then
  PREMISES=$(printf '%s' "$CLASSIFIED" | jq -c \
    '[.captain[] | select(.live)
      | {id, title, repo, premise, premise_measured, premise_filed, premise_outcome, premise_seat,
         has_premise: ((.premise // "") != "")}]
     | sort_by(.premise_measured)')
  if [ "$JSON" -eq 1 ]; then
    jq -n --argjson p "$PREMISES" --argjson a "$AUDIT" \
      '{schema: "fm-decision-ledger.v1", open_premises: $p, audit: $a}'
    exit 0
  fi
  printf '%s' "$PREMISES" | jq -r '
    "open captain decisions to re-measure: \(length)",
    "each line states when the premise was last re-measured, never that it still holds",
    "",
    (.[] | "- \(.id)  [premise last re-measured: \(if (.premise_measured // "") == "" then "never" else .premise_measured end)]",
           "  question: \(.title)",
           (if (.premise_filed // "") != "" then "  observed on:  \(.premise_filed)" else empty end),
           (if .has_premise then "  premise:  \(.premise)"
            else "  premise:  (none recorded - this record cannot be re-measured as filed)" end),
           "")'
  exit 0
fi

if [ "$MODE" = audit ]; then
  if [ "$JSON" -eq 1 ]; then
    printf '%s' "$LEDGER" | jq '{schema, home, audit}'
  elif [ "$AUDIT_COUNT" -eq 0 ]; then
    printf 'no unfinished captain decision records in %s\n' "$DATA"
  else
    # One line per finding, because bin/fm-bootstrap.sh prefixes this output
    # straight into its one-line-per-problem diagnostic stream.
    printf '%s' "$AUDIT" | jq -r '.[] | "\(.class) \(.id) - \(.detail)"'
  fi
  [ "$AUDIT_COUNT" -eq 0 ] || exit 1
  exit 0
fi

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$LEDGER" | jq .
  exit 0
fi

printf '%s' "$LEDGER" | jq -r '
  "settled captain decisions: \(.settled_total) (showing \(.settled | length))",
  "open captain questions: \(.open | length)",
  "questions folded into a later record: \(.folded | length)",
  (if (.audit | length) > 0 then
     "", "UNFINISHED DECISION RECORDS - these need repair, not a new question:",
     (.audit[] | "  \(.class)  \(.id)\n      \(.detail)")
   else empty end),
  "",
  (.settled[] |
    "- \(.id)  [door: \(.door), closed \(.closed // "?"), \(if .verbatim then "verbatim verified" else "TEXT ALTERED SINCE RECORDING" end)]",
    "  question: \(.title)",
    "  answer:",
    (.decision | split("\n") | .[] | if . == "" then "" else "    " + . end),
    (if (.routed // "") != "" then "  routed to: \(.routed)" else empty end),
    ""),
  (.omitted[] | "(\(.count) older settled decision(s) not shown; \(.reveal))")
'
exit 0
