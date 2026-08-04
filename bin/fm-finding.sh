#!/usr/bin/env bash
# fm-finding.sh - append to and read the political officer's findings surface.
#
# The officer states what is true and has no authority: he writes findings here,
# never a fix, never a priority, never addressed to a seat. Everything else in
# the fleet reads this surface. `bin/fm-finding-lib.sh` owns the record format
# and the reasons behind it; this script is the command surface.
#
# Usage:
#   fm-finding.sh init
#   fm-finding.sh emit --class <class> --claim <text> --where <text>
#                      --measurement <text> --refuted-by <text> --officer <name>
#                      [--severity low|medium|high] [--observed <iso8601>]
#   fm-finding.sh list [--json]
#   fm-finding.sh show <id>
#   fm-finding.sh check
#
#   init         create the surface directory. Nothing else creates it: a
#                command that made its own surface on demand would turn a
#                mistyped location into a fresh empty surface nobody reads,
#                reported as success.
#   emit         validate one finding and append it. Refuses rather than writing
#                a record that is not a finding, so the surface never holds one.
#   list         every finding, oldest first. --json emits the records as an
#                array for a machine reader.
#   show         one finding's record, by id.
#   check        the surface's own health: state, how many findings, how many
#                files on it that are not findings.
#
# --refuted-by is required of every class, not only of judgements. The header of
# bin/fm-finding-lib.sh owns why.
#
# There is deliberately no command here that writes an outcome. A drained
# finding's outcome is written back by whoever drained it, through
# bin/fm-finding-drain.sh, so the officer answering his own claim is a command
# that does not exist rather than a rule he has to keep.
#
# Surface location: FM_FINDINGS_DIR, else the FM_HOME/config/findings-dir
# pointer, else FM_HOME/data/findings.
#
# Exit codes:
#   0  done
#   2  usage error, including a finding that is missing a required field, and a
#      judgement that does not state what would refute it
#   3  the surface could not be reached: absent, not a directory, or not
#      readable or writable by this process. Distinct from an empty surface, and
#      deliberately so - `check` on a reachable empty surface prints findings=0,
#      while `check` on an unreachable one prints findings= with no number at
#      all, because a count is a measurement and an unreachable surface was
#      never measured.
#   4  the surface holds files that are not findings. Reported, never skipped: a
#      reader that drops what it cannot parse turns a corrupted surface into a
#      calm empty one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-finding-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-finding-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message>
  printf 'fm-finding.sh: %s\n' "$2" >&2
  exit "$1"
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || die "$FM_FINDING_EXIT_USAGE" "jq is required to read or write findings and is not installed"
}

cmd_init() {
  local state
  fm_finding_resolve_surface
  state=$(fm_finding_surface_state "$SURFACE")
  case "$state" in
    ok)
      printf 'surface=%s\nstate=ok\ncreated=0\n' "$SURFACE"
      ;;
    absent)
      mkdir -p "$SURFACE" \
        || die "$FM_FINDING_EXIT_UNREACHABLE" "could not create the findings surface $SURFACE"
      printf 'surface=%s\nstate=ok\ncreated=1\n' "$SURFACE"
      ;;
    *)
      fm_finding_surface_reason "$SURFACE" "$state" >&2
      exit "$FM_FINDING_EXIT_UNREACHABLE"
      ;;
  esac
}

cmd_emit() {
  local class="" claim="" where="" measurement="" refuted_by="" officer=""
  local severity="medium" observed="" payload digest id path tmp existing

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--class requires a value"; class=$2; shift 2 ;;
      --claim) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--claim requires a value"; claim=$2; shift 2 ;;
      --where) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--where requires a value"; where=$2; shift 2 ;;
      --measurement) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--measurement requires a value"; measurement=$2; shift 2 ;;
      --refuted-by) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--refuted-by requires a value"; refuted_by=$2; shift 2 ;;
      --officer) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--officer requires a value"; officer=$2; shift 2 ;;
      --severity) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--severity requires a value"; severity=$2; shift 2 ;;
      --observed) [ "$#" -gt 1 ] || die "$FM_FINDING_EXIT_USAGE" "--observed requires a value"; observed=$2; shift 2 ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for emit: $1" ;;
    esac
  done

  fm_finding_member_p "$class" "$FM_FINDING_CLASSES" \
    || die "$FM_FINDING_EXIT_USAGE" "--class must be one of: $FM_FINDING_CLASSES"
  fm_finding_member_p "$severity" "$FM_FINDING_SEVERITIES" \
    || die "$FM_FINDING_EXIT_USAGE" "--severity must be one of: $FM_FINDING_SEVERITIES"

  # refuted_by is checked first and named for what it is, because this is the
  # refusal the surface exists to make and a caller reading the error should
  # learn the rule from it rather than from a generic missing-field message.
  if fm_finding_blank_p "$refuted_by"; then
    die "$FM_FINDING_EXIT_USAGE" \
      "--refuted-by is empty: a finding that cannot say what would disprove it is not emittable, and a $class finding least of all"
  fi
  fm_finding_blank_p "$claim" && die "$FM_FINDING_EXIT_USAGE" "--claim is empty"
  fm_finding_blank_p "$where" && die "$FM_FINDING_EXIT_USAGE" "--where is empty"
  fm_finding_blank_p "$measurement" && die "$FM_FINDING_EXIT_USAGE" "--measurement is empty"
  fm_finding_blank_p "$officer" && die "$FM_FINDING_EXIT_USAGE" "--officer is empty"

  [ -n "$observed" ] || observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  fm_finding_resolve_surface
  fm_finding_require_surface append

  payload=$(jq -n -S \
    --arg schema "$FM_FINDING_SCHEMA" \
    --arg class "$class" \
    --arg claim "$claim" \
    --arg where "$where" \
    --arg measurement "$measurement" \
    --arg observed "$observed" \
    --arg refuted_by "$refuted_by" \
    --arg officer "$officer" \
    --arg severity "$severity" \
    '{schema:$schema, class:$class, claim:$claim, where:$where,
      measurement:$measurement, observed:$observed, refuted_by:$refuted_by,
      officer:$officer, severity:$severity}') \
    || die "$FM_FINDING_EXIT_USAGE" "the finding could not be encoded as JSON"

  digest=$(printf '%s' "$payload" | fm_finding_digest) \
    || die "$FM_FINDING_EXIT_USAGE" "the finding could not be digested"
  id=$(fm_finding_id "$observed" "$digest")
  path=$(fm_finding_path "$SURFACE" "$id")

  # The id is derived from the content, so an identical finding appended twice
  # lands on the same path. That is idempotence, not a collision: a container
  # that retries an append must not manufacture a second record of one
  # observation, because the accuracy score counts records.
  if [ -e "$path" ]; then
    existing=$(jq -S -c 'del(.id)' "$path" 2>/dev/null || printf '')
    if [ "$existing" = "$(printf '%s' "$payload" | jq -S -c '.')" ]; then
      printf 'surface=%s\nid=%s\npath=%s\nappended=0\n' "$SURFACE" "$id" "$path"
      return 0
    fi
    die "$FM_FINDING_EXIT_UNREACHABLE" \
      "$path already holds a different record; the surface would lose one of the two"
  fi

  tmp=$(mktemp "$SURFACE/.emit.XXXXXX") \
    || die "$FM_FINDING_EXIT_UNREACHABLE" "could not write to the findings surface $SURFACE"
  printf '%s' "$payload" | jq -S --arg id "$id" '. + {id:$id}' > "$tmp" || {
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_USAGE" "the finding could not be written"
  }

  # Validate the file that is about to become the record, not the values that
  # went into it. A record reaches the surface only if the same reader every
  # consumer uses already accepts it.
  local violations
  if ! violations=$(fm_finding_validate "$tmp" "$id"); then
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_USAGE" "the finding did not validate: $(printf '%s' "$violations" | tr '\n' ';')"
  fi

  mv "$tmp" "$path" || {
    rm -f "$tmp"
    die "$FM_FINDING_EXIT_UNREACHABLE" "could not place the finding at $path"
  }
  printf 'surface=%s\nid=%s\npath=%s\nappended=1\n' "$SURFACE" "$id" "$path"
}

cmd_list() {
  local as_json=0 file id malformed=0 findings=0 first=1 violations
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      *) die "$FM_FINDING_EXIT_USAGE" "unknown option for list: $1" ;;
    esac
  done
  require_jq
  fm_finding_resolve_surface
  fm_finding_require_surface read

  [ "$as_json" -eq 1 ] && printf '['
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! violations=$(fm_finding_validate "$file"); then
      malformed=$((malformed + 1))
      printf 'not a finding: %s: %s\n' "$file" "$(printf '%s' "$violations" | tr '\n' ';')" >&2
      continue
    fi
    findings=$((findings + 1))
    if [ "$as_json" -eq 1 ]; then
      [ "$first" -eq 1 ] || printf ','
      first=0
      jq -c '.' "$file"
    else
      id=$(jq -r '.id' "$file")
      jq -r '[.id, .observed, .class, .severity, .officer, .claim] | @tsv' "$file" \
        || die "$FM_FINDING_EXIT_MALFORMED" "could not render $id"
    fi
  done < <(fm_finding_each_record)
  [ "$as_json" -eq 1 ] && printf ']\n'

  if [ "$malformed" -gt 0 ]; then
    printf 'fm-finding.sh: %d file(s) on %s are not findings; this listing of %d finding(s) is incomplete\n' \
      "$malformed" "$SURFACE" "$findings" >&2
    exit "$FM_FINDING_EXIT_MALFORMED"
  fi
}

cmd_show() {
  local id=${1:-} path violations
  [ -n "$id" ] || die "$FM_FINDING_EXIT_USAGE" "show requires a finding id"
  require_jq
  fm_finding_resolve_surface
  fm_finding_require_surface read
  path=$(fm_finding_path "$SURFACE" "$id")
  [ -f "$path" ] || die "$FM_FINDING_EXIT_USAGE" "no finding $id on $SURFACE"
  if ! violations=$(fm_finding_validate "$path"); then
    printf 'fm-finding.sh: %s is on the surface but is not a finding: %s\n' \
      "$path" "$(printf '%s' "$violations" | tr '\n' ';')" >&2
    exit "$FM_FINDING_EXIT_MALFORMED"
  fi
  jq -S '.' "$path"
}

# cmd_check is the instrument-health command. It answers "is this surface empty
# or is it broken", which are the two readings the rest of the fleet must never
# confuse. A reachable surface always prints a number for findings and
# malformed; an unreachable one prints those keys with no value, because
# nothing was counted.
cmd_check() {
  local state file malformed=0 findings=0
  fm_finding_resolve_surface
  state=$(fm_finding_surface_state "$SURFACE")
  if [ "$state" != "ok" ]; then
    printf 'surface=%s\nstate=%s\nfindings=\nmalformed=\n' "$SURFACE" "$state"
    fm_finding_surface_reason "$SURFACE" "$state" >&2
    exit "$FM_FINDING_EXIT_UNREACHABLE"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'surface=%s\nstate=unreadable\nfindings=\nmalformed=\n' "$SURFACE"
    printf 'fm-finding.sh: jq is not installed, so nothing on %s could be read\n' "$SURFACE" >&2
    exit "$FM_FINDING_EXIT_UNREACHABLE"
  fi
  if [ ! -w "$SURFACE" ]; then
    state=append-blocked
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if fm_finding_validate "$file" >/dev/null; then
      findings=$((findings + 1))
    else
      malformed=$((malformed + 1))
    fi
  done < <(fm_finding_each_record)
  printf 'surface=%s\nstate=%s\nfindings=%d\nmalformed=%d\n' \
    "$SURFACE" "$state" "$findings" "$malformed"
  [ "$state" = "append-blocked" ] && {
    fm_finding_surface_reason "$SURFACE" unwritable >&2
    exit "$FM_FINDING_EXIT_UNREACHABLE"
  }
  [ "$malformed" -gt 0 ] && exit "$FM_FINDING_EXIT_MALFORMED"
  return 0
}

SURFACE=""
CMD=${1:-}
[ "$#" -gt 0 ] && shift
case "$CMD" in
  init) cmd_init "$@" ;;
  emit) require_jq; cmd_emit "$@" ;;
  list) cmd_list "$@" ;;
  show) cmd_show "$@" ;;
  check) cmd_check "$@" ;;
  -h|--help) usage ;;
  '') usage >&2; exit "$FM_FINDING_EXIT_USAGE" ;;
  *) die "$FM_FINDING_EXIT_USAGE" "unknown command: $CMD" ;;
esac
