#!/usr/bin/env bash
# fm-decision-inventory.sh - collapse the open captain decisions into the set of
# distinct questions, for the /decisionboard skill to lay out.
#
# WHY
# A model panel registers its holds per MEMBER, so one question becomes up to
# three records: two analysts and a judge each inventory the same investigation
# independently. On 2026-07-31 the open set was 26 records carrying 12 distinct
# questions. A board that listed all 26 would misrepresent how much is actually
# waiting on the captain, so the collapse has to happen somewhere - and in a
# script rather than in skill prose, because a rule restated per invocation is a
# rule that drifts.
#
# WHAT IT READS
# Only the structured inventory: `bin/fm-bearings-snapshot.sh --json
# --all-decisions`. Never report prose, chat, or terminal output - the same rule
# the bearings header states for itself. Bearings is the right cut because it
# already applies canonical captain-actionability: a hold still blocked by
# another hold, or one whose panel is still running, is not something the captain
# can answer yet and does not belong on the board.
#
# THE COLLAPSE RULE, AND WHY IT IS STRUCTURAL
# A hold identity is `<origin-id>-decision-<decision-key>` (bin/fm-decision-hold.sh),
# and panel member task ids are `<panel-id>-a`, `-b`, `-judge`, and `-judge<N>`
# for a replacement judge (bin/fm-model-panel.sh). Both are documented contracts
# owned elsewhere, so this script parses ids rather than guessing from wording:
#
#   1. Split the identity on the first `-decision-` into origin and key.
#   2. Strip a trailing panel role (-a, -b, -judge, -judge<N>) off the origin.
#      What remains is the ORIGIN GROUP: one investigation or panel.
#   3. Within a group that has a judge, the JUDGE's records are authoritative and
#      every non-judge record in that group is a superseded variant of the same
#      investigation. The judge re-verified both analysts, so its formulation is
#      the one the captain should answer.
#   4. A group with no judge contributes its records unchanged.
#
# LIMIT, STATED RATHER THAN PAPERED OVER
# Step 3 collapses reliably at the GROUP level. Attaching a specific analyst
# variant to a specific judge decision does not: judges reword keys freely. On
# 2026-07-31, 9 of 14 records in the upstream-pr-review group had no matching
# judge key. So an exact key match is reported as a confident pairing, and every
# other variant is reported at group level with paired=false. The board must show
# those as "further variants of the same investigation", never assert which
# question they belong to. Counting is exact; pairing is best-effort and says so.
#
# A group whose ids do not follow these conventions simply does not collapse, and
# each record stands alone. That is the safe direction: the board would show too
# many questions, never too few.
#
# WHAT IT DOES NOT DO
# It never writes, resolves, or reorders a decision. `bin/fm-decision-hold.sh`
# owns every mutation and .agents/skills/decision-hold-lifecycle owns the policy.
# This script is read-only.
#
# Usage:
#   fm-decision-inventory.sh [--json] [--from <file>]
#   fm-decision-inventory.sh --summary
#   fm-decision-inventory.sh -h | --help
#
# Options:
#   --json       full structured inventory (default)
#   --summary    one human line per distinct decision, plus the counts
#   --from <f>   read a bearings --json capture from <f> instead of running it
#                (used by the tests; also lets one capture drive several renders)
#
# Output contract: `fm-decision-inventory.v1`.
#   records          how many open captain-hold records bearings reported
#   decisions        how many distinct questions they carry
#   groups[]         one per origin group: group, has_judge, decisions[], variants[]
#   decisions[]      id, key, group, role, summary, owner, variants[]
#   variants[]       id, key, role, summary, paired (true only on an exact key match)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"

die() {
  printf 'fm-decision-inventory.sh: %s\n' "$1" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^# ?/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

MODE="json"
FROM=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) MODE="json"; shift ;;
    --summary) MODE="summary"; shift ;;
    --from) [ "$#" -gt 1 ] || die "--from needs a path"; FROM=$2; shift 2 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || die "no such capture: $FROM"
  SNAPSHOT=$(cat "$FROM")
else
  [ -x "$BEARINGS" ] || die "missing $BEARINGS"
  SNAPSHOT=$("$BEARINGS" --json --all-decisions) || die "bearings snapshot failed"
fi

INVENTORY=$(printf '%s' "$SNAPSHOT" | jq '
  # Parse one hold identity into its structural parts. Both conventions are
  # owned elsewhere; this only reads them.
  def split_identity:
    . as $id
    | ($id | index("-decision-")) as $at
    | if $at == null
      then {origin: $id, key: ""}
      else {origin: $id[0:$at], key: $id[($at + 10):]}
      end;

  def split_role:
    .origin as $o
    | ($o | capture("^(?<grp>.+)-(?<role>a|b|judge[0-9]*)$") // null) as $m
    | if $m == null
      then . + {group: $o, role: ""}
      else . + {group: $m.grp, role: (if ($m.role | startswith("judge")) then "judge" else $m.role end)}
      end;

  ((.decisions_open // []) | map(
      (.id | split_identity) as $p
      | ($p | split_role) as $q
      | {id: .id, summary: (.summary // ""), owner: (.owner // ""),
         key: $q.key, group: $q.group, role: $q.role}
  )) as $recs

  | ($recs
      | group_by(.group)
      | map(
          . as $items
          | ($items | map(select(.role == "judge"))) as $judges
          | (($judges | length) > 0) as $has_judge
          # Authoritative records: the judges when a judge ran, else everything.
          | (if $has_judge then $judges else $items end) as $auth
          | (if $has_judge then ($items - $judges) else [] end) as $others
          | ($auth | map(.key)) as $authkeys
          | {
              group: $items[0].group,
              has_judge: $has_judge,
              record_count: ($items | length),
              decision_count: ($auth | length),
              auth: $auth,
              decisions: ($auth | map(
                . as $d
                | {id: $d.id, key: $d.key, group: $d.group, role: $d.role,
                   summary: $d.summary, owner: $d.owner,
                   # Confident pairing ONLY on an exact key match.
                   variants: ($others | map(select(.key == $d.key))
                              | map({id: .id, key: .key, role: .role,
                                     summary: .summary, paired: true}))}
              )),
              # Variants no authoritative key matches. The board shows these at
              # group level and must not claim which question they restate.
              unpaired_variants: (
                $others
                | map(select(.key as $k | ($authkeys | index($k)) == null))
                | map({id: .id, key: .key, role: .role, summary: .summary, paired: false})
              )
            }
        )
    ) as $groups

  | {
      schema: "fm-decision-inventory.v1",
      records: ($recs | length),
      decisions: ($groups | map(.decision_count) | add // 0),
      groups: ($groups | map(del(.auth)))
    }
  | .decisions_flat = (.groups | map(.decisions) | add // [])
')

if [ "$MODE" = "summary" ]; then
  printf '%s' "$INVENTORY" | jq -r '
    "records: \(.records)   distinct decisions: \(.decisions)",
    "",
    (.groups[] |
      "group \(.group)  [\(.record_count) records -> \(.decision_count) decisions, judge: \(.has_judge)]",
      (.decisions[] | "  * \(.id)\n      \(.summary)" +
        (if (.variants | length) > 0
         then "\n      superseded (key match): " + (.variants | map(.id) | join(", "))
         else "" end)),
      (if (.unpaired_variants | length) > 0
       then "  ~ further variants of this investigation, pairing not established:\n" +
            (.unpaired_variants | map("      - " + .id) | join("\n"))
       else empty end),
      ""
    )
  '
  exit 0
fi

printf '%s\n' "$INVENTORY"
