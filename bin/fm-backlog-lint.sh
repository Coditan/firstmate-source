#!/usr/bin/env bash
# fm-backlog-lint.sh - detect mechanically stale blocked-by edges.
#
# Usage:
#   fm-backlog-lint.sh
#   fm-backlog-lint.sh --help
#
# Reads data/backlog.md and data/done-archive.md from FM_HOME, reports one
# actionable BACKLOG_STALE line per bad current-task edge, and exits 0 even
# when findings exist.
# It is detect-only: it never edits, removes, or repairs an edge.
# Silence means every current blocked-by target exists as a non-Done live task
# and tasks-axi agrees with fm-fleet-snapshot about whether the edge blocks.
#
# Findings are intentionally limited to three mechanically closable classes:
#   - dangling: the target exists in neither the live backlog nor the archive
#   - satisfied: the target is already Done in the live backlog
#   - reader-disagreement: an archived Done target is treated as satisfied by
#     tasks-axi but unresolved by fm-fleet-snapshot
#
# Every finding names the dependent task, blocker, fault, and the exact fix that
# removes the stale edge.
#
# The classification boundary is what the readers could decide about the edge,
# not whether the dependent record is well formed:
#   - dangling and satisfied are decided from the parsed backlog and archive
#     alone, so they stay BACKLOG_STALE findings even when tasks-axi cannot
#     resolve the dependent record
#   - reader-disagreement needs tasks-axi's own answer about that record, so a
#     record tasks-axi cannot resolve leaves the edge undecided and reports one
#     coded BACKLOG_UNREADABLE line instead - never a stale-edge finding, since
#     a miss is preferred to a false positive
#
# The fix clause is the tasks-axi command only when that command would actually
# run: on the manual backend, and on any record tasks-axi cannot resolve, it is
# instead hand-edit guidance naming the backlog file, the dependent task, the
# blocker, and the blocked-by token quoted as the record actually spells it.
# Missing prerequisites and unreadable structured inputs are command errors, not
# findings: they abort on stderr.
# An undecided edge sets exit status 1; findings alone leave it 0. Bootstrap
# calls this only after its normal tool checks and treats command failure as
# non-blocking.
set -uf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
ARCHIVE="$DATA/done-archive.md"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  sed -n '2,/^set -uf$/s/^# \{0,1\}//p' "$0"
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[ -f "$BACKLOG" ] || exit 0
command -v jq >/dev/null 2>&1 \
  || { echo "fm-backlog-lint: jq not found" >&2; exit 1; }
command -v tasks-axi >/dev/null 2>&1 \
  || { echo "fm-backlog-lint: tasks-axi not found" >&2; exit 1; }
[ -x "$SNAPSHOT" ] \
  || { echo "fm-backlog-lint: fleet snapshot reader not executable: $SNAPSHOT" >&2; exit 1; }

LINT_TMP=$(
  mktemp -d "${TMPDIR:-/tmp}/fm-backlog-lint.XXXXXX"
) || { echo "fm-backlog-lint: could not create private temporary directory" >&2; exit 1; }

cleanup() {
  rm -rf "$LINT_TMP"
}
trap cleanup EXIT
BACKLOG_JSON_FILE="$LINT_TMP/backlog.json"
ARCHIVE_JSON_FILE="$LINT_TMP/archive.json"

FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_HOME="$FM_HOME" \
  FM_DATA_OVERRIDE="$DATA" \
  "$SNAPSHOT" --backlog-json "$BACKLOG" > "$BACKLOG_JSON_FILE" \
  || { echo "fm-backlog-lint: live backlog read failed: $BACKLOG" >&2; exit 1; }

if [ -f "$ARCHIVE" ]; then
  FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_DATA_OVERRIDE="$DATA" \
    "$SNAPSHOT" --backlog-json "$ARCHIVE" > "$ARCHIVE_JSON_FILE" \
    || { echo "fm-backlog-lint: done archive read failed: $ARCHIVE" >&2; exit 1; }
else
  printf '%s\n' '{"records":[]}' > "$ARCHIVE_JSON_FILE"
fi

csv_has() {  # <csv> <value>
  local csv=$1 value=$2 entry old_ifs
  old_ifs=$IFS
  IFS=,
  for entry in $csv; do
    if [ "$entry" = "$value" ]; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

BACKEND_MANUAL=0
fm_backlog_backend_manual "$CONFIG" && BACKEND_MANUAL=1

decode_token() {  # <base64 edge token>
  printf '%s' "$1" | jq -Rrj '@base64d' 2>/dev/null
}

fix_clause() {  # <task> <blocker> <base64 edge token> <task-resolvable>
  local token
  if [ "$BACKEND_MANUAL" = 1 ] || [ "$4" = 0 ]; then
    token=$(decode_token "$3")
    [ -n "$token" ] || token="blocked-by: $2"
  fi
  if [ "$BACKEND_MANUAL" = 1 ]; then
    printf 'edit data/backlog.md by hand and delete the blocked-by token "%s" naming blocker %s from the record for task %s' \
      "$token" "$2" "$1"
  elif [ "$4" = 0 ]; then
    printf 'no tasks-axi fix is available because tasks-axi cannot resolve task %s in data/backlog.md, so edit data/backlog.md by hand and delete the blocked-by token "%s" naming blocker %s from the record for task %s' \
      "$1" "$token" "$2" "$1"
  else
    printf 'run tasks-axi unblock %s --by %s' "$1" "$2"
  fi
}

probe_task=
task_axi_readable=1
task_axi_unresolved=
unreadable_reported=0

probe_dependent_record() {  # <task> - memoized per task, read-only
  local show_status=0 show_out blocked_by_line
  [ "$1" != "$probe_task" ] || return 0
  probe_task=$1
  task_axi_readable=1
  task_axi_unresolved=
  unreadable_reported=0
  show_out=$(tasks-axi show "$1" --file "$BACKLOG" </dev/null 2>/dev/null) || show_status=$?
  blocked_by_line=$(
    printf '%s\n' "$show_out" |
      sed -n 's/^[[:space:]]*blocked_by:[[:space:]]*//p' |
      head -1
  )
  if [ "$show_status" -ne 0 ] || [ -z "$blocked_by_line" ]; then
    task_axi_readable=0
    return 0
  fi
  task_axi_unresolved=$blocked_by_line
  case "$task_axi_unresolved" in
    none|-) task_axi_unresolved= ;;
    \"*)
      task_axi_unresolved=${task_axi_unresolved#\"}
      task_axi_unresolved=${task_axi_unresolved%\"}
      ;;
  esac
}

LINT_STATUS=0
ROWS_FILE="$LINT_TMP/edges.tsv"

jq -nr \
  --slurpfile backlog "$BACKLOG_JSON_FILE" \
  --slurpfile archive "$ARCHIVE_JSON_FILE" '
    def edge_token($raw; $blocker):
      ([($raw // "") | scan("blocked-by:[[:space:]]+[^[:space:])]+")]
        | map(select(sub("^blocked-by:[[:space:]]+"; "") == $blocker))
        | .[0])
      // ("blocked-by: " + $blocker);
    ($backlog[0].records
      | map(select(.structured == true))
      | map({key:.id,value:.state})
      | from_entries) as $live
    | ($archive[0].records
        | map(select(.structured == true))
        | map({key:.id,value:true})
        | from_entries) as $archived
    | $backlog[0].records[]
    | select(.structured == true and .state != "done")
    | . as $record
    | (.blocked_by_ids // [])[]
    | . as $blocker
    | [
        $record.id,
        $blocker,
        (if $live[$blocker] == "done" then "done"
         elif $live[$blocker] != null then "live"
         elif $archived[$blocker] == true then "archived"
         else "missing"
         end),
        ((($record.unresolved_blocker_ids // []) | index($blocker)) != null),
        (edge_token($record.raw; $blocker) | @base64)
      ]
    | @tsv
  ' > "$ROWS_FILE" \
  || { echo "fm-backlog-lint: dependency edge extraction failed for $BACKLOG" >&2; exit 1; }

while IFS="$(printf '\t')" read -r task blocker target_class snapshot_unresolved edge_token; do
  [ -n "$task" ] || continue
  [ "$target_class" = live ] && continue
  probe_dependent_record "$task"
  case "$target_class" in
    missing)
      printf "BACKLOG_STALE: task %s has dangling blocked-by %s (target is absent from data/backlog.md and data/done-archive.md); fix: %s, then add the intended existing blocker if this id was a typo\n" \
        "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$task_axi_readable")"
      ;;
    done)
      printf "BACKLOG_STALE: task %s has satisfied blocked-by %s (target is already Done in data/backlog.md); fix: %s\n" \
        "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$task_axi_readable")"
      ;;
    archived)
      if [ "$task_axi_readable" = 0 ]; then
        if [ "$unreadable_reported" = 0 ]; then
          unreadable_reported=1
          LINT_STATUS=1
          printf "BACKLOG_UNREADABLE: task %s in data/backlog.md is parsed by fm-fleet-snapshot but tasks-axi show returns no blocked_by: property for it, so whether its archived-target edges are stale stays undecided and none is reported; fix: repair that row in data/backlog.md - tasks-axi resolves only a slug-shaped id (letters, digits, \".\", \"_\", \"-\", no spaces and no Markdown emphasis) in a \"- [ ] <id> - <title>\" row - until tasks-axi show <id> --file data/backlog.md prints a blocked_by: line\n" \
            "$task"
        fi
      elif [ "$snapshot_unresolved" = true ] \
        && ! csv_has "$task_axi_unresolved" "$blocker"; then
        printf "BACKLOG_STALE: task %s has reader-disagreement blocked-by %s (tasks-axi says satisfied; fm-fleet-snapshot says unresolved after the target moved to data/done-archive.md); fix: %s\n" \
          "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$task_axi_readable")"
      fi
      ;;
  esac
done < "$ROWS_FILE"

exit "$LINT_STATUS"
