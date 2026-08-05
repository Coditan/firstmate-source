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
#
# WHY THE DRAIN RULE IS EARLIEST DEADLINE FIRST
# The builder must take findings by a rule of its own, because no seat may take
# orders from the officer (design decision section 6). The rule here gives every
# finding a deadline of `observed + the waiting time its severity allows`, and
# takes the finding whose deadline is nearest, past or future. One key, one
# total order, no buckets.
#
# Severity-first alone would starve a low finding behind an endless supply of
# high ones - and a claim nobody ever looks at is exactly the shape of the 2027
# unread log lines the officer exists to notice. Oldest-first alone would park a
# high-consequence finding behind a queue of trivia. Earliest deadline first is
# the ordering that has neither failure: severity buys a shorter wait, never a
# permanent rank, so the officer's severity stays a statement about consequence
# and never becomes the priority he is forbidden to express.
#
# The coupling falls out of the same key rather than being bolted beside it. A
# finding is overdue exactly when its deadline has passed, so "left unread past
# its threshold, and visible as unread" is the drain rule's own sort key read
# with its sign, not a second instrument that could rot while looking healthy.

FM_FINDING_SCHEMA="fm-finding/1"

# The outcome of a drained finding, written to a sibling `<id>.outcome.json` by
# whoever drained it. A separate file, so "the officer never writes an outcome
# and the drainer never rewrites a claim" is a fact about which file each seat
# creates rather than a rule either has to remember.
FM_FINDING_OUTCOME_SCHEMA="fm-finding-outcome/1"

# The three outcomes of the captain's write-back rule, section 7: bestätigt,
# widerlegt, ungeklärt. `unresolved` is a written-back result - someone looked
# and could not settle it - and is not the same thing as never having looked.
FM_FINDING_OUTCOMES="upheld refuted unresolved"

# The two states an outcome record passes through. `taken` is the drainer's
# claim, written when it draws the finding; `closed` carries the outcome. A
# claim that never reaches `closed` is a finding somebody started and abandoned,
# which the queue reports as its own thing rather than as undrained.
FM_FINDING_OUTCOME_STATES="taken closed"

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
# A claim another seat already holds, or an outcome already written back with a
# different verdict. Its own code because "someone else has this" and "you asked
# for the wrong thing" call for opposite responses from a builder.
# shellcheck disable=SC2034
FM_FINDING_EXIT_CONTESTED=5

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
    reader-missing) printf 'jq is not installed, so nothing on %s could be read\n' "$dir" ;;
    *) printf 'the findings surface %s is in an unrecognised state: %s\n' "$dir" "$state" ;;
  esac
}

# fm_finding_resolve_surface: set SURFACE in the caller's shell, or print the
# resolver's reason and exit with its code. Shared by every command surface that
# touches the surface so all of them fail on the same terms.
fm_finding_resolve_surface() {
  local dir status
  dir=$(fm_finding_surface_dir)
  status=$?
  [ "$status" -eq 0 ] || exit "$status"
  SURFACE=$dir
}

# fm_finding_require_surface <read|append>: exit with the concrete reason when
# SURFACE cannot serve that mode. `append` is checked separately because a
# surface a drainer can read but not claim on is not a working surface for it,
# and must not be reported as a queue with nothing takeable.
fm_finding_require_surface() {
  local mode=$1 state
  state=$(fm_finding_surface_state "$SURFACE")
  if [ "$state" != "ok" ]; then
    fm_finding_surface_reason "$SURFACE" "$state" >&2
    exit "$FM_FINDING_EXIT_UNREACHABLE"
  fi
  if [ "$mode" = "append" ] && [ ! -w "$SURFACE" ]; then
    fm_finding_surface_reason "$SURFACE" unwritable >&2
    exit "$FM_FINDING_EXIT_UNREACHABLE"
  fi
}

# fm_finding_each_record: every candidate finding path on SURFACE, oldest first.
# The id's leading timestamp makes a plain byte sort the chronological one.
#
# `*.outcome.json` is excluded here, once, for every reader there is. That
# exclusion is the line between the officer's claim and the drainer's answer to
# it; a second copy of it in another script is the copy that would eventually
# list an outcome as a finding.
fm_finding_each_record() {
  find "$SURFACE" -maxdepth 1 -type f -name '*.json' ! -name '*.outcome.json' -print \
    | LC_ALL=C sort
}

# fm_finding_blank_p <text>: true when text is empty or only whitespace.
fm_finding_blank_p() {
  local text=$1
  text="${text#"${text%%[![:space:]]*}"}"
  [ -z "$text" ]
}

# fm_finding_instant_p <value>: true when the value is an ISO-8601 UTC instant,
# which is the one time form anything on this surface may carry.
#
# Both halves are load-bearing. The shape check refuses everything that is not
# literally that form, including a value carrying a path separator, which
# matters because `observed` becomes the id and the id is a filename stem. The
# parse behind it refuses a value of the right shape that names no real moment,
# because a record the ordering cannot place is a claim nobody is ever handed.
#
# One owner for the form: emit's `observed` and the drain's clock are the same
# question asked twice, and two spellings of it would eventually disagree about
# which moments this surface accepts.
fm_finding_instant_p() {
  local value=$1
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || return 1
  jq -e -n --arg value "$value" \
    '($value | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) | type == "number"' >/dev/null 2>&1
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

# --- the drain rule ---------------------------------------------------------

# The waiting time each severity buys, in seconds. These are the whole of the
# drain rule's dependence on severity: a shorter wait, never a higher rank. The
# numbers are the captain's consequence scale read as time - a high-consequence
# finding that has sat a day is late, a low-consequence one has a week - and
# docs/findings-surface.md owns their meaning to a reader.
FM_FINDING_DEADLINE_HIGH=86400
FM_FINDING_DEADLINE_MEDIUM=259200
FM_FINDING_DEADLINE_LOW=604800

# fm_finding_deadline_json: the severity-to-seconds table as a JSON object, for
# the one jq pass that orders the queue. Built from the constants above so the
# table the queue sorts by and the table this file documents cannot drift.
#
# This is the only place the set of severities is spelled a second time, and it
# is the one the queue actually sorts by. A record whose severity is not one of
# ours is already refused by fm_finding_validate above and never reaches the
# ordering; the table's absent entry is the second line behind that, so such a
# record would get no deadline rather than a plausible place in the order.
fm_finding_deadline_json() {
  printf '{"high":%s,"medium":%s,"low":%s}\n' \
    "$FM_FINDING_DEADLINE_HIGH" "$FM_FINDING_DEADLINE_MEDIUM" "$FM_FINDING_DEADLINE_LOW"
}

# fm_finding_now: this moment as ISO-8601 UTC. FM_FINDING_NOW pins it, which is
# what makes a deadline test deterministic; the same override is why a queue
# printed at a named instant can be reproduced later.
fm_finding_now() {
  printf '%s\n' "${FM_FINDING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# fm_finding_outcome_path <dir> <finding-id>: the file one drained finding's
# outcome lives in. Sibling of the finding, excluded from every finding listing,
# and created only by a drainer.
fm_finding_outcome_path() {
  printf '%s/%s.outcome.json\n' "$1" "$2"
}

# fm_finding_outcome_validate <file> <finding-id>: print one violation per line
# on stdout, return 0 when the file is an outcome record for that finding.
#
# Held to the same standard as a finding, for the same reason: an outcome file
# nobody can read must not make a drained finding look undrained, and must not
# make an undrained one look answered. The jq exit status is separated from its
# output here too - a validator that reads its own crash as "no violations"
# accepts everything, which is the failure the whole surface exists to refuse.
fm_finding_outcome_validate() {
  local file=$1 finding=$2 violations jq_status
  if [ ! -f "$file" ]; then
    printf 'not a regular file\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is not installed, so this outcome cannot be read\n'
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'not parseable as JSON\n'
    return 1
  fi
  violations=$(jq -r \
    --arg schema "$FM_FINDING_OUTCOME_SCHEMA" \
    --arg finding "$finding" \
    --argjson outcomes "$(fm_finding_json_list "$FM_FINDING_OUTCOMES")" \
    --argjson states "$(fm_finding_json_list "$FM_FINDING_OUTCOME_STATES")" '
    def blank:
      (. // null)
      | if type == "string"
        then (explode | map(select(. != 32 and . != 9 and . != 10 and . != 13)) | length) == 0
        else true
        end;
    def required($f):
      if (.[$f] | blank) then "\($f) is missing or empty" else empty end;
    (.state // "") as $state
    | [
      (if (.schema // "") == $schema then empty
       else "schema is \(.schema // "absent"), not \($schema)" end),
      (if (.finding // "") == $finding then empty
       else "outcome names finding \(.finding // "absent"), not \($finding)" end),
      required("drained_by"),
      required("drained"),
      (if ($states | index($state)) then empty
       else "state is \(if $state == "" then "absent" else $state end), not one of \($states | join(", "))" end),
      # A closed record carries the verdict and the reading behind it. A taken
      # record must carry neither: a claim that already names an outcome is a
      # write-back that skipped the work it was supposed to report on.
      (if $state == "closed"
       then ((.outcome // "") as $o
             | if ($outcomes | index($o)) then empty
               else "outcome is \(if $o == "" then "absent" else $o end), not one of \($outcomes | join(", "))" end),
            required("closed"),
            required("evidence")
       elif $state == "taken"
       then (if (.outcome // null) == null then empty
             else "a taken claim already carries outcome \(.outcome)" end)
       else empty end)
    ] | .[]
  ' "$file" 2>&1)
  jq_status=$?
  if [ "$jq_status" -ne 0 ]; then
    printf 'the outcome could not be read: %s\n' "$(printf '%s' "$violations" | tr '\n' ' ')"
    return 1
  fi
  if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    return 1
  fi
  return 0
}
