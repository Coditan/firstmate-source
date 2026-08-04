#!/usr/bin/env bash
# fm-finding-lib.sh - the record contract of the political officer's findings
# surface: where the surface is, what a finding is, and what makes a file on the
# surface not one.
#
# Sourced, never executed. `bin/fm-finding.sh` is the command surface; the drain
# and the accuracy score read findings through this file so all three agree on
# one spelling of the format.
#
# WHY THE SURFACE IS A DIRECTORY OF FILES AND NOT ONE APPENDED FILE
# The officer has no outbound network path: findings leave him by appending to
# one directory on the host, which a vessel collects from
# (data/decisions/2026-08-04-politoffizier-vollstaendige-bauform.md section 4).
# One file per finding means an append needs no lock, which matters because the
# writer is a container the host cannot ask to hold a host lock, and because a
# drainer writing an outcome back must never be able to corrupt the claim it is
# answering. The finding file is written once and never rewritten; the outcome
# of a drained finding is a SEPARATE sibling file written by the drainer, so
# "the outcome is written back by whoever drained it, never by the officer" is a
# fact about which file each seat may create rather than a rule either has to
# remember.
#
# WHY refuted_by IS REQUIRED OF EVERY CLASS AND NOT ONLY OF JUDGEMENTS
# The captain's rule is that a judgement finding which cannot state what would
# refute it is not emitted at all. A validator that applied that rule only to
# `class: judgement` would make correctness depend on the emitter classifying
# itself honestly - the emitter with the strongest reason to misclassify is
# exactly the one making an unfalsifiable judgement. Requiring the field of
# every class removes the incentive and the branch: there is no class to escape
# into. An evidence finding loses nothing by saying which reading would overturn
# it, and a finding without the field is not a finding to anything that reads
# this surface.
#
# WHY A MALFORMED FILE IS REPORTED AND NEVER SKIPPED
# A reader that silently drops files it cannot parse reports an unreachable or
# corrupted surface as an empty one, and an empty surface is the ordinary, calm
# state. That is the defect this fleet measured four times on 2026-08-04: a
# broken instrument and a quiet subject look identical. Every read path here
# counts malformed records separately from findings and says so.

FM_FINDING_SCHEMA="fm-finding/1"

# The three classes of claim the officer makes, per section 3 of the design
# decision. They differ in what settles a dispute, not in what the format
# demands: `evidence` has a line someone else can look at, `judgement` is a
# statement about intent, `pattern` is a shape only visible from outside.
FM_FINDING_CLASSES="evidence judgement pattern"

# Severity ranks the finding's consequence, not its confidence. The drain rule
# reads it; the officer never expresses a priority, because a priority is an
# instruction and he has no authority to give one.
FM_FINDING_SEVERITIES="low medium high"

# The fields every finding carries are checked by fm_finding_validate below and
# their meanings are documented in docs/findings-surface.md. There is no third
# list of them here: a name list nothing reads is the copy that drifts.

# Exit codes shared by every command that touches the surface. Kept distinct so
# a caller can tell an empty surface from one it could not reach. Consumed by
# sourcing scripts, so they read as unused in this file alone.
# shellcheck disable=SC2034
FM_FINDING_EXIT_USAGE=2
# shellcheck disable=SC2034
FM_FINDING_EXIT_UNREACHABLE=3
# shellcheck disable=SC2034
FM_FINDING_EXIT_MALFORMED=4

# fm_finding_json_list <space-separated list>: the same list as a JSON array.
fm_finding_json_list() {
  local item out=""
  for item in $1; do
    out="$out${out:+,}\"$item\""
  done
  printf '[%s]\n' "$out"
}

# fm_finding_member_p <probe> <space-separated list>: true when probe is in it.
fm_finding_member_p() {
  local probe=$1 item
  for item in $2; do
    [ "$probe" = "$item" ] && return 0
  done
  return 1
}

# fm_finding_home: this home, resolved the way every other bin/ script does.
fm_finding_home() {
  local script_dir root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  printf '%s\n' "${FM_HOME:-$root}"
}

# fm_finding_surface_dir: where this machine's surface is.
#
# Precedence: FM_FINDINGS_DIR, then the `config/findings-dir` pointer, then the
# home-local default. The pointer exists because the officer is one container
# per MACHINE while a home is one vessel: a machine carrying several vessels
# points every home at the one directory the officer appends to. The default is
# home-local because that is correct for a machine carrying one vessel and is
# the only default that cannot silently point two homes at each other.
#
# A pointer file that exists but names nothing is a misconfiguration, not a
# reason to fall back: falling back would send findings to a directory nobody
# reads while reporting success. Prints the reason and returns
# FM_FINDING_EXIT_USAGE instead.
fm_finding_surface_dir() {
  local pointer line
  if [ -n "${FM_FINDINGS_DIR:-}" ]; then
    printf '%s\n' "$FM_FINDINGS_DIR"
    return 0
  fi
  pointer="$(fm_finding_home)/config/findings-dir"
  if [ -f "$pointer" ]; then
    line=$(head -n 1 "$pointer" | tr -d '\r')
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ -z "$line" ]; then
      printf 'the findings-surface pointer %s exists but names no directory\n' "$pointer" >&2
      return "$FM_FINDING_EXIT_USAGE"
    fi
    printf '%s\n' "$line"
    return 0
  fi
  printf '%s\n' "$(fm_finding_home)/data/findings"
}

# fm_finding_surface_state <dir>: one word naming what the surface is, on
# stdout. `ok` only when it is a directory this process can both read and list.
# Every other word names the concrete defect rather than collapsing into a
# missing-and-therefore-empty reading.
fm_finding_surface_state() {
  local dir=$1
  if [ -z "$dir" ]; then
    printf 'unresolved\n'
    return 0
  fi
  if [ ! -e "$dir" ]; then
    printf 'absent\n'
    return 0
  fi
  if [ ! -d "$dir" ]; then
    printf 'not-a-directory\n'
    return 0
  fi
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf 'unreadable\n'
    return 0
  fi
  printf 'ok\n'
}

# fm_finding_surface_reason <dir> <state>: one plain sentence for a state that
# is not `ok`. Empty for `ok`.
fm_finding_surface_reason() {
  local dir=$1 state=$2
  case "$state" in
    ok) printf '' ;;
    unresolved) printf 'the findings surface could not be resolved to a path\n' ;;
    absent) printf 'the findings surface %s does not exist; create it with fm-finding.sh init\n' "$dir" ;;
    not-a-directory) printf 'the findings surface %s exists but is not a directory\n' "$dir" ;;
    unreadable) printf 'the findings surface %s cannot be read by this process\n' "$dir" ;;
    unwritable) printf 'the findings surface %s cannot be appended to by this process\n' "$dir" ;;
    *) printf 'the findings surface %s is in an unrecognised state: %s\n' "$dir" "$state" ;;
  esac
}

# fm_finding_blank_p <text>: true when text is empty or only whitespace.
fm_finding_blank_p() {
  local text=$1
  text="${text#"${text%%[![:space:]]*}"}"
  [ -z "$text" ]
}

# fm_finding_path <dir> <id>: the file one finding lives in.
fm_finding_path() {
  printf '%s/%s.json\n' "$1" "$2"
}

# fm_finding_digest: 8 hex characters of the sha256 of stdin. Portable across
# the two checksum tools the fleet's machines actually carry.
fm_finding_digest() {
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 | cut -d' ' -f1)
  else
    printf 'no sha256 tool found (sha256sum or shasum)\n' >&2
    return 1
  fi
  printf '%s\n' "${sum:0:8}"
}

# fm_finding_id <observed-iso8601> <digest>: the record id, which is also the
# filename stem. The timestamp leads so a plain lexicographic sort of the
# directory is oldest-first, which is the order the drain rule needs and the
# only ordering that survives a directory listing with no index.
fm_finding_id() {
  local observed=$1 digest=$2 compact
  compact=${observed//-/}
  compact=${compact//:/}
  printf '%s-%s\n' "$compact" "$digest"
}

# fm_finding_validate <file> [expected-id]: print one violation per line on
# stdout, return 0 when the file is a finding and 1 when it is not. Never
# writes.
#
# The id must equal the filename stem. Without that check a file could carry one
# id and be listed under another, which is how a single finding becomes two
# records with one outcome between them. `expected-id` overrides the stem for
# the one caller that legitimately has neither yet: an emit validating the
# staged file it is about to place, which must be checked against the name it
# will take rather than the temporary one it has.
fm_finding_validate() {
  local file=$1 expected=${2:-} stem violations jq_status
  if [ ! -f "$file" ]; then
    printf 'not a regular file\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is not installed, so this file cannot be read as a finding\n'
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'not parseable as JSON\n'
    return 1
  fi
  if [ -n "$expected" ]; then
    stem=$expected
  else
    stem=$(basename "$file")
    stem=${stem%.json}
  fi
  # `jq_status` is separated from the output because a validator that reads its
  # own crash as "no violations" calls every file valid, which is the failure
  # this whole surface exists to refuse. An erroring reader is a violation.
  violations=$(jq -r \
    --arg schema "$FM_FINDING_SCHEMA" \
    --arg stem "$stem" \
    --argjson classes "$(fm_finding_json_list "$FM_FINDING_CLASSES")" \
    --argjson severities "$(fm_finding_json_list "$FM_FINDING_SEVERITIES")" '
    def blank:
      (. // null)
      | if type == "string"
        then (explode | map(select(. != 32 and . != 9 and . != 10 and . != 13)) | length) == 0
        else true
        end;
    def required($f):
      if (.[$f] | blank) then "\($f) is missing or empty" else empty end;
    [
      (if (.schema // "") == $schema then empty
       else "schema is \(.schema // "absent"), not \($schema)" end),
      required("id"),
      required("claim"),
      required("where"),
      required("measurement"),
      required("observed"),
      required("officer"),
      required("refuted_by"),
      ((.class // "") as $c
       | if ($classes | index($c)) then empty
         else "class is \(if $c == "" then "absent" else $c end), not one of \($classes | join(", "))" end),
      ((.severity // "") as $s
       | if ($severities | index($s)) then empty
         else "severity is \(if $s == "" then "absent" else $s end), not one of \($severities | join(", "))" end),
      (if (.id // "") == $stem then empty
       else "id \(.id // "absent") does not match the filename stem \($stem)" end)
    ] | .[]
  ' "$file" 2>&1)
  jq_status=$?
  if [ "$jq_status" -ne 0 ]; then
    printf 'the record could not be read: %s\n' "$(printf '%s' "$violations" | tr '\n' ' ')"
    return 1
  fi
  if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    return 1
  fi
  return 0
}
