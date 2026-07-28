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

fix_clause() {  # <task> <blocker> <edge token as written> <task-resolvable>
  if [ "$BACKEND_MANUAL" = 1 ]; then
    printf 'edit data/backlog.md by hand and delete the blocked-by token "%s" naming blocker %s from the record for task %s' \
      "$3" "$2" "$1"
  elif [ "$4" = false ]; then
    printf 'no tasks-axi fix is available because tasks-axi does not list task %s when reading data/backlog.md, so edit data/backlog.md by hand and delete the blocked-by token "%s" naming blocker %s from the record for task %s' \
      "$1" "$3" "$2" "$1"
  else
    printf 'run tasks-axi unblock %s --by %s' "$1" "$2"
  fi
}

LINT_STATUS=0
UNIT=$(printf '\001')
EDGES_FILE="$LINT_TMP/edges"
AXI_LIST_FILE="$LINT_TMP/axi-list"
ROWS_FILE="$LINT_TMP/rows"

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
    | (if $live[$blocker] == "done" then "done"
       elif $live[$blocker] != null then "live"
       elif $archived[$blocker] == true then "archived"
       else "missing"
       end) as $class
    | select($class != "live")
    | [
        $record.id,
        $blocker,
        $class,
        ((($record.unresolved_blocker_ids // []) | index($blocker)) != null | tostring),
        edge_token($record.raw; $blocker)
      ]
    | join("\u0001")
  ' > "$EDGES_FILE" \
  || { echo "fm-backlog-lint: dependency edge extraction failed for $BACKLOG" >&2; exit 1; }

[ -s "$EDGES_FILE" ] || exit 0

tasks-axi list --file "$BACKLOG" --fields blocked_by </dev/null > "$AXI_LIST_FILE" 2>/dev/null \
  || { echo "fm-backlog-lint: tasks-axi blocker listing failed: $BACKLOG" >&2; exit 1; }
grep -q '^tasks\[[0-9][0-9]*\]{id,state,kind,repo,title,blocked_by}:$' "$AXI_LIST_FILE" \
  || grep -q '^count: 0$' "$AXI_LIST_FILE" \
  || { echo "fm-backlog-lint: unexpected tasks-axi list schema for $BACKLOG" >&2; exit 1; }

awk -v listing="$AXI_LIST_FILE" '
  BEGIN { FS = "\001"; OFS = "\001" }
  FILENAME == listing {
    if (rows && $0 !~ /^  /) { rows = 0 }
    if ($0 ~ /^tasks\[/) { rows = 1; next }
    if (!rows) { next }
    line = substr($0, 3)
    comma = index(line, ",")
    if (comma < 2) { next }
    id = substr(line, 1, comma - 1)
    if (substr(line, length(line), 1) == "\"") {
      start = 0
      scan = 1
      while ((hit = index(substr(line, scan), ",\"")) > 0) {
        start = scan + hit - 1
        scan = start + 1
      }
      if (start == 0) { next }
      blockers = substr(line, start + 2, length(line) - start - 2)
    } else {
      start = 0
      for (i = length(line); i > 0; i--) {
        if (substr(line, i, 1) == ",") { start = i; break }
      }
      if (start == 0) { next }
      blockers = substr(line, start + 1)
    }
    if (blockers == "none" || blockers == "-") { blockers = "" }
    listed[id] = 1
    blocked_by[id] = blockers
    next
  }
  { print $1, $2, $3, $4, ($1 in listed ? "true" : "false"), blocked_by[$1], $5 }
' "$AXI_LIST_FILE" "$EDGES_FILE" > "$ROWS_FILE" \
  || { echo "fm-backlog-lint: tasks-axi blocker table read failed for $BACKLOG" >&2; exit 1; }

unreadable_task=
while IFS="$UNIT" read -r task blocker target_class snapshot_unresolved \
  axi_resolvable axi_blocked_by edge_token; do
  [ -n "$task" ] || continue
  case "$target_class" in
    missing)
      printf "BACKLOG_STALE: task %s has dangling blocked-by %s (target is absent from data/backlog.md and data/done-archive.md); fix: %s, then add the intended existing blocker if this id was a typo\n" \
        "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$axi_resolvable")"
      ;;
    done)
      printf "BACKLOG_STALE: task %s has satisfied blocked-by %s (target is already Done in data/backlog.md); fix: %s\n" \
        "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$axi_resolvable")"
      ;;
    archived)
      if [ "$axi_resolvable" = false ]; then
        if [ "$task" != "$unreadable_task" ]; then
          unreadable_task=$task
          LINT_STATUS=1
          printf "BACKLOG_UNREADABLE: task %s in data/backlog.md is parsed by fm-fleet-snapshot but tasks-axi does not list that record when reading the same file, so whether its archived-target edges are stale stays undecided and none is reported; fix: repair that row in data/backlog.md - tasks-axi resolves only a slug-shaped id (letters, digits, \".\", \"_\", \"-\", no spaces and no Markdown emphasis) in a \"- [ ] <id> - <title>\" row - until tasks-axi list --file data/backlog.md shows that id\n" \
            "$task"
        fi
      elif [ "$snapshot_unresolved" = true ] \
        && ! csv_has "$axi_blocked_by" "$blocker"; then
        printf "BACKLOG_STALE: task %s has reader-disagreement blocked-by %s (tasks-axi says satisfied; fm-fleet-snapshot says unresolved after the target moved to data/done-archive.md); fix: %s\n" \
          "$task" "$blocker" "$(fix_clause "$task" "$blocker" "$edge_token" "$axi_resolvable")"
      fi
      ;;
  esac
done < "$ROWS_FILE"

exit "$LINT_STATUS"
