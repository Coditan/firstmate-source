#!/usr/bin/env bash
# fm-supervision-cost.sh - measure what supervision costs a firstmate session,
# in the unit the provider window actually counts.
#
# WHY: supervision spend was argued for weeks in units nobody could check - a
# share of turns eyeballed from a transcript, a saving projected from a change
# that was never measured on either side of it. This reads the provider's own
# usage records instead. Every number it prints was counted; none was derived
# from a byte count or a rate card.
#
# THE UNIT is FRESH tokens: input_tokens + cache_creation_input_tokens for one
# request, deduplicated by request id. Cache reads are carried context, not
# freshly written, so they are reported apart and never summed in. Only the
# fresh half is what a change to firstmate's own machinery can move.
#
# This tool MEASURES and never decides. It reads transcripts read-only, gates
# nothing, and writes nothing anywhere. bin/fm-supervision-cost-engine.py's
# header owns the definitions of every counted thing; docs/supervision-cost.md
# owns the measurements taken with it and their limits.
#
# Usage:
#   fm-supervision-cost.sh [--since <YYYY-MM-DD>] [--until <YYYY-MM-DD>]
#                          [--project <substring>] [--session <id>]
#                          [--transcripts <dir>] [--json]
#
#   --since / --until   inclusive day bounds; omit for every retained day
#   --project           keep only transcripts under a matching project directory
#   --session           report one session in detail instead of the daily table
#   --transcripts       transcript root (default: $FM_TRANSCRIPTS or
#                       $HOME/.claude/projects)
#   --json              machine-readable report, for diffing one run against another
#
# Coverage is a property of the input, and the report states it: only Claude Code
# keeps a local usage record, so no other harness is measured, and a day the
# provider has already rolled off is absent rather than zero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/fm-supervision-cost-engine.py"
TRANSCRIPTS="${FM_TRANSCRIPTS:-$HOME/.claude/projects}"

note() { printf 'fm-supervision-cost: %s\n' "$1" >&2; }

usage() {
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --transcripts)
      [ "$#" -gt 1 ] || { note "--transcripts requires a value"; exit 2; }
      TRANSCRIPTS=$2
      shift 2
      ;;
    --transcripts=*)
      TRANSCRIPTS=${1#--transcripts=}
      shift
      ;;
    # Always forwarded in --flag=value form: a project directory name legitimately
    # begins with a dash, and a separate argument would be read as another flag.
    --since|--until|--project|--session)
      [ "$#" -gt 1 ] || { note "$1 requires a value"; exit 2; }
      ARGS+=("$1=$2")
      shift 2
      ;;
    --since=*|--until=*|--project=*|--session=*)
      ARGS+=("$1")
      shift
      ;;
    --json)
      ARGS+=(--json)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      note "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { note "python3 is required"; exit 2; }
[ -f "$ENGINE" ] || { note "measurement engine missing at $ENGINE"; exit 2; }

exec python3 "$ENGINE" --transcripts "$TRANSCRIPTS" ${ARGS+"${ARGS[@]}"}
