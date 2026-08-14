#!/usr/bin/env bash
# Read and replay this home's urgency promotions.
#
# bin/fm-urgency-lib.sh owns the priority ladder, the rule table, the
# never-lower property, and the promotion record format; read its header before
# first use. This script is the read and replay side: it never promotes a live
# event, and `replay` deliberately writes no record, because a measurement that
# changes the thing it measures is not a measurement.
#
# Usage:
#   fm-urgency.sh classify [--kind <kind>] [--key <key>] [--declared <p>] <text>
#   fm-urgency.sh replay [--since <seq>] [--limit <n>] [--corpus <file>] [--all]
#   fm-urgency.sh promotions [--limit <n>]
#   fm-urgency.sh rules
#
# classify     Decide one event without recording anything. Prints the declared
#              priority, the effective one, whether it was promoted, and EVERY
#              rule that matched with the text fragment that matched it - not
#              only the winning rule - so a reader can see what else nearly
#              fired. --declared defaults to what the event's own kind and text
#              declare; pass it to ask the question about a stated priority
#              instead. Exit status is 0 when the event would be promoted, 1
#              when it would be left alone, so a script can branch on it.
#
# replay       Run the rules over recorded history and report what they would
#              do, without touching a live event. This is the instrument the
#              unit is judged by: a promoter that under-promotes is invisible in
#              production, so the recorded cases are replayed rather than
#              reasoned about. With no --corpus it reads this home's append-only
#              event journal (bin/fm-journal.sh) and derives each record's
#              declared priority from the event itself. --corpus reads a
#              two-column "<declared>\t<text>" file instead, which is how a
#              corpus that predates this home's journal - a Bridge acked inbox,
#              an exported status history - is replayed. --all lists every
#              record with its verdict, not only the promoted ones. The closing
#              summary reports the promotion rate over ORDINARY traffic, because
#              over-promotion spends the captain's attention and a rate nobody
#              printed is a rate nobody bounded.
#
# promotions   Print recorded promotions, oldest first, in the raw nine-field
#              record format. There is deliberately no way to edit one.
#
# rules        Print the rule table that actually runs: name, floor, and the
#              regex, one per line. What a reader is shown here and what the
#              promoter evaluates are the same text.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-urgency-lib.sh
. "$SCRIPT_DIR/fm-urgency-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() { printf 'fm-urgency.sh: %s\n' "$1" >&2; exit 2; }

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
  -h|--help|help|'') usage; exit 0 ;;
esac

# --- classify ---------------------------------------------------------------

cmd_classify() {
  local kind=signal key='' declared='' text='' line rank name match

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --key) [ "$#" -ge 2 ] || die "--key needs a value"; key=$2; shift 2 ;;
      --declared) [ "$#" -ge 2 ] || die "--declared needs a value"; declared=$2; shift 2 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  text=$*
  [ -n "$text" ] || die "classify needs the event text"
  [ -n "$declared" ] || declared=$(fm_urgency_declared "$kind" "$text" "")

  if fm_urgency_effective "$declared" "$text"; then
    printf 'declared: %s\neffective: %s\npromoted: yes\nrule: %s\nmatch: %s\n' \
      "$declared" "$FM_URGENCY_EFFECTIVE" "$FM_URGENCY_RULE" "$FM_URGENCY_MATCH"
  else
    printf 'declared: %s\neffective: %s\npromoted: no\nrule: -\nmatch: -\n' \
      "$declared" "$FM_URGENCY_EFFECTIVE"
  fi
  [ -z "$key" ] || printf 'key: %s\n' "$key"

  printf 'matches:\n'
  line=$(fm_urgency_matches "$text" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr)
  if [ -z "$line" ]; then
    printf '  (none)\n'
  else
    while IFS=$'\t' read -r rank name match; do
      [ -n "$name" ] || continue
      printf '  %-13s %-9s %s\n' "$name" "$(fm_urgency_level "$rank")" "$match"
    done <<EOF
$line
EOF
  fi

  [ "$(fm_urgency_rank "$FM_URGENCY_EFFECTIVE")" -gt "$(fm_urgency_rank "$declared")" ]
}

# --- replay -----------------------------------------------------------------

# One replayed record: prints a verdict line when it promoted (or always, under
# --all) and emits one tallied outcome on fd 3 for the summary.
replay_record() {  # <all> <kind> <key> <declared> <text>
  local all=$1 kind=$2 key=$3 declared=$4 text=$5 shown

  shown=$text
  [ "${#shown}" -le 96 ] || shown="${shown:0:93}..."

  if fm_urgency_effective "$declared" "$text"; then
    printf 'PROMOTE  %-9s -> %-9s  %-12s  %s\n' \
      "$declared" "$FM_URGENCY_EFFECTIVE" "$FM_URGENCY_RULE" "$shown"
    printf 'promoted\t%s\t%s->%s\n' "$FM_URGENCY_RULE" "$declared" "$FM_URGENCY_EFFECTIVE" >&3
    return 0
  fi
  case "$all" in
    1) printf 'keep     %-9s     %-9s  %-12s  %s\n' "$declared" "" "-" "$shown" ;;
  esac
  printf 'kept\t-\t%s->%s\n' "$declared" "$declared" >&3
  return 1
}

cmd_replay() {
  local since=0 limit=0 corpus='' all=0 tally records promoted
  local jseq epoch kind key origin payload snapshot event declared

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) [ "$#" -ge 2 ] || die "--since needs a sequence number"; since=$2; shift 2
        case "$since" in ''|*[!0-9]*) die "--since needs a sequence number" ;; esac ;;
      --limit) [ "$#" -ge 2 ] || die "--limit needs a count"; limit=$2; shift 2
        case "$limit" in ''|*[!0-9]*) die "--limit needs a count" ;; esac ;;
      --corpus) [ "$#" -ge 2 ] || die "--corpus needs a file"; corpus=$2; shift 2 ;;
      --all) all=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  tally=$(mktemp "${TMPDIR:-/tmp}/fm-urgency-replay.XXXXXX") || die "could not create a scratch file"
  # shellcheck disable=SC2064 # Expand the path now: it must survive this shell.
  trap "rm -f '$tally'" EXIT HUP INT TERM
  exec 3> "$tally"

  if [ -n "$corpus" ]; then
    [ -r "$corpus" ] || die "corpus not readable: $corpus"
    printf 'source: %s\n\n' "$corpus"
    while IFS=$'\t' read -r declared event; do
      [ -n "$event" ] || continue
      replay_record "$all" corpus - "$declared" "$event" || true
    done < "$corpus"
  else
    printf 'source: this home'\''s event journal\n\n'
    while IFS=$'\t' read -r jseq epoch kind key origin payload snapshot; do
      [ -n "$jseq" ] || continue
      case "$jseq" in *[!0-9]*) continue ;; esac
      event=$payload
      [ -z "$snapshot" ] || event="$payload | $snapshot"
      declared=$(fm_urgency_declared "$kind" "$payload" "$snapshot")
      replay_record "$all" "$kind" "$key" "$declared" "$event" || true
    done < <(
      if [ "$limit" -gt 0 ]; then
        "$SCRIPT_DIR/fm-journal.sh" read --since "$since" --limit "$limit" 2>/dev/null
      else
        "$SCRIPT_DIR/fm-journal.sh" read --since "$since" 2>/dev/null
      fi
    )
  fi

  exec 3>&-
  records=$(awk 'END { print NR + 0 }' "$tally")
  promoted=$(awk -F'\t' '$1 == "promoted"' "$tally" | wc -l | tr -d '[:space:]')

  printf '\nrecords: %s\n' "$records"
  if [ "$records" -gt 0 ]; then
    printf 'promoted: %s (%s%%)\n' "$promoted" \
      "$(awk -v p="$promoted" -v r="$records" 'BEGIN { printf "%.1f", (p * 100.0) / r }')"
  else
    printf 'promoted: 0\n'
  fi
  if [ "$promoted" -gt 0 ]; then
    printf 'by rule:\n'
    awk -F'\t' '$1 == "promoted" { print $2 }' "$tally" | LC_ALL=C sort | uniq -c \
      | LC_ALL=C sort -rn | awk '{ printf "  %-13s %s\n", $2, $1 }'
    printf 'by transition:\n'
    awk -F'\t' '$1 == "promoted" { print $3 }' "$tally" | LC_ALL=C sort | uniq -c \
      | LC_ALL=C sort -rn | awk '{ printf "  %-22s %s\n", $2, $1 }'
  fi
  return 0
}

# --- promotions / rules -----------------------------------------------------

cmd_promotions() {
  local limit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || die "--limit needs a count"; limit=$2; shift 2
        case "$limit" in ''|*[!0-9]*) die "--limit needs a count" ;; esac ;;
      *) die "unknown option: $1" ;;
    esac
  done
  if [ "$limit" -gt 0 ]; then
    fm_urgency_cat | head -n "$limit"
  else
    fm_urgency_cat
  fi
}

cmd_rules() {
  local name floor pattern
  while IFS='|' read -r name floor pattern; do
    [ -n "$name" ] || continue
    printf '%-13s %-9s %s\n' "$name" "$floor" "$pattern"
  done <<EOF
$(fm_urgency_rule_lines)
EOF
}

case "$cmd" in
  classify) cmd_classify "$@" ;;
  replay) cmd_replay "$@" ;;
  promotions) cmd_promotions "$@" ;;
  rules) cmd_rules ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
