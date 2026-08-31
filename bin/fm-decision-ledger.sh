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
# session runs BEFORE presenting any captain decision record as open.
#
# WHAT IT READS
# The one store, directly: `kind: captain` rows in the active home's
# data/backlog.md and data/done-archive.md.
# That is the captain decision-record set.
# It is deliberately narrower than the captain-actionable hold set in
# bin/fm-fleet-snapshot.sh, which counts queued, unblocked records held with
# `hold-kind: captain` whatever their own record kind.
# Not a second store - it never writes, and it holds nothing of its own.
# It reads the raw markdown rather than `tasks-axi show`, for two reasons: `show`
# cannot see archived rows at all, and its escaped one-line body is a
# representation of the captain's words rather than the words.
# The raw row is the only place the bytes survive unmediated.
#
# THE DIGEST IS RE-CHECKED ON EVERY READ
# bin/fm-decision-hold.sh stores a sha256 of the exact decision text alongside it.
# This command recomputes that digest from the stored text and reports
# `verbatim: false` when they disagree. So a later hand-edit of a settled decision
# is visible here rather than quietly authoritative, and "these are his words" is
# something this output demonstrates rather than asserts.
#
# The whole set is re-hashed in ONE pass, and one full read is reusable by the next
# caller in the same session start through the script-owned `state/.decision-ledger-memo`.
# Both are cost changes and neither weakens the re-check: the reuse is keyed on the
# content of the record files and of this script, so it is only ever returned when
# recomputing would give the same answer. See "THE SAME RE-CHECK" and "ONE FULL READ
# PER SESSION START" in the body.
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
#                          whole mechanism exists to prevent. Where this home
#                          already holds an answered record for the same
#                          investigation, the finding names it and the command
#                          that attests it. See "THE CLASS THAT HAD NO ROUTE OUT".
#   answer-pointer-broken  A record attested as answered elsewhere whose named
#                          answer record is no longer an answered captain record
#                          in this home carrying the digest the attestation was
#                          made against.
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
# THE ADOPTION BASELINE, AND WHY THE AUDIT NEEDED ONE
# Measured on the main home the day after this check was written: 58 findings, of
# which 57 were on captain records closed long before any of this existed - 48
# `closed-without-record` and 9 `stale-body-state`, the latter nine being nine of
# the same records counted a second time. Exactly one finding was on a live record.
# bin/fm-bootstrap.sh prints one line per finding at every session start, so this
# check would have opened at 57 irreparable demands and could never have reached
# zero. An alarm whose only available response is to stop reading it is the same
# failure this whole mechanism exists against, one layer up: a check nobody reads
# and a store nobody consults fail in exactly the same way.
#
# `--record-baseline` writes the findings that sit on ALREADY-CLOSED records into
# data/decision-baseline.md, once, as a deliberate statement that those particular
# answers are lost rather than pending. `--audit` then withholds exactly those
# (class, id, observed closed date) entries and says in one line how many it
# withheld and where they are listed. The generated entry set carries a digest;
# editing any entry invalidates the whole baseline and leaves every finding visible.
# It is a disclosure, never a deletion: the file is the list, `--audit
# --json` still carries every withheld finding under `baseline_excluded`, and
# re-taking a baseline means removing that file by hand.
#
# THE CLASS THAT HAD NO ROUTE OUT, AND THE DISPOSITION THAT GAVE IT ONE
# `closed-without-record` was the one class with no reachable resolution. Its
# records are closed, so `supersede` refuses them by design; several live in
# data/done-archive.md, which `tasks-axi show` cannot see at all; and a row closed
# without an observable date cannot be baselined either. Three findings on this
# home were in all three of those states at once and reported at every session
# start with no action able to clear them - while the captain's answers to all
# three had since been recovered and stored under other identities, so the finding
# was not merely unactionable but false.
#
# The captain ruled on 2026-08-24 that a standing diagnostic reaching a reader who
# cannot act on it is a defect whatever it measures, and that the fix is one of two
# things and never a third: make it fire only where somebody owns it, or attach the
# action so it stops being a report. This takes the second. The finding now names
# the answered record for the same investigation and the exact
# `fm-decision-hold.sh answered-by` call that disposes of it, and that command is
# the fourth disposition: it records on the closed row that his answer is stored
# under another identity, and this reader stops demanding one.
#
# THIS READER NEVER TAKES THAT STEP ITSELF. A shared origin group is where to look,
# not proof that the stored answer answers THIS question - one work item can gate
# two decisions. Withholding the finding on a group match would be this command
# repairing a record on a guess, which is the thing the whole file refuses to do.
# So the attestation is a person's act, and what is automated is only the reading
# back: the named record must still be an answered captain record here and still
# carry the digest the attestation was made against, or `answer-pointer-broken`
# reports.
#
# ONLY A DATED CLOSED RECORD MAY BE BASELINED. A closed record's answer is either stored
# or it is lost, and nothing a later session does can recover a lost one. Every
# other class sits on a LIVE record, which is repairable by definition, so no
# baseline may ever silence one. A dateless closed record cannot be bound to the
# closure observed at baseline time, so it remains reported. A record closed AFTER
# the baseline was taken is a genuine new failure and is reported in full. These
# rules stop a baseline being used to launder today's mistake into yesterday's history.
#
# It reports; it never repairs. Repair is bin/fm-decision-hold.sh's, and closing a
# captain decision is never a script's call to make unprompted.
#
# Usage:
#   fm-decision-ledger.sh [--limit <n>] [--all]
#   fm-decision-ledger.sh --audit [--json]
#   fm-decision-ledger.sh --record-baseline
#   fm-decision-ledger.sh --premises [--json]
#   fm-decision-ledger.sh --records [--repo <name>]
#   fm-decision-ledger.sh --json [--limit <n>] [--all]
#   fm-decision-ledger.sh -h | --help
#
# Options:
#   --limit <n>  settled decisions to show, newest first (default 5)
#   --all        every settled decision, no limit
#   --audit      only the unfinished records; exit 1 when any are found that the
#                adoption baseline does not already cover
#   --record-baseline
#                record, once, that today's findings on already-closed records are
#                lost rather than pending; refuses if a baseline already exists
#   --premises   every open decision with the premise it was filed on and when that
#                premise was last re-measured; the weekly sweep's input
#   --records    flat `class<TAB>id<TAB>repo<TAB>title` list of every captain record,
#                open first; this is what the intake gate reads
#   --repo <n>   with --records, restrict to one repository
#   --json       machine-readable form of whichever view was selected
#
# Exit status is 0 for a clean read, 1 under --audit when any finding exists that
# the adoption baseline does not cover, and 2 for a usage or environment error. The
# nonzero --audit status is what lets a caller treat "nothing is half-closed" as a
# checkable condition.
#
# Output contract: `fm-decision-ledger.v1`.
#   settled[]  id, origin, key, title, repo, door, closed, source, routed[],
#              decision (verbatim), digest, verbatim (digest re-check)
#   open[]     id, title, repo, held, blocks[] - captain decision records still
#              unanswered
#   folded[]   id, title, successor, fold_reason - questions a later record covers
#   answered_elsewhere[]  id, title, answer_record - closed questions whose answer
#              is stored under another identity
#   audit[]    class, id, detail
#   baseline_excluded[]  the same shape, for findings the adoption baseline covers
#   baseline   path, recorded, count - null when this home has taken no baseline
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$DATA/backlog.md"
ARCHIVE="$DATA/done-archive.md"
BASELINE="$DATA/decision-baseline.md"
# This script's own scratch record under state/, per AGENTS.md section 2: the
# script that writes a state file is the only thing that ever changes it.
MEMO="$STATE/.decision-ledger-memo"
MEMO_TTL="${FM_DECISION_LEDGER_MEMO_TTL:-120}"
case "$MEMO_TTL" in ''|*[!0-9]*) MEMO_TTL=120 ;; esac
[ "${FM_DECISION_LEDGER_NO_MEMO:-0}" = 1 ] && MEMO_TTL=0

# The only two classes a baseline may cover, and the reason is the same for both:
# each sits on a record that is already CLOSED, so its answer is either stored or
# lost and no later act recovers a lost one. Every other class sits on a live
# record and stays repairable, so none of them is ever silenceable here.
BASELINE_CLASSES='["closed-without-record","stale-body-state"]'

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
    --record-baseline) MODE=record-baseline; shift ;;
    --records) MODE=records; shift ;;
    --premises) MODE=premises; shift ;;
    --repo) [ "$#" -gt 1 ] || die "--repo needs a name"; RECORDS_REPO=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

# The baseline as JSON [{class, id, closed}], and empty when this home has never taken one.
# Anything it cannot parse with at least `<class> <id>` is skipped rather than guessed at, on
# the same rule the rest of this script follows: a misread line here would silence a
# real finding, which is the one failure a baseline must never be able to cause.
read_baseline() {
  [ -f "$BASELINE" ] || { printf '[]'; return 0; }
  awk '
    BEGIN { printf "[" }
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    { printf "%s{\"class\":\"%s\",\"id\":\"%s\",\"closed\":\"%s\"}", (n++ ? "," : ""), $1, $2, (NF == 3 ? $3 : "") }
    END { printf "]" }
  ' "$BASELINE"
}

# The date the baseline was taken, read from its own header. Empty when unknown,
# and an unknown date is printed as unknown rather than as today.
baseline_recorded() {
  [ -f "$BASELINE" ] || return 0
  awk '/^# recorded: / { sub(/^# recorded: /, ""); print; exit }' "$BASELINE"
}

baseline_entries_digest() {
  [ -f "$BASELINE" ] || return 0
  awk '/^# entries-digest: / { sub(/^# entries-digest: /, ""); print; exit }' "$BASELINE"
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

# THE SAME RE-CHECK, IN TWO PROCESSES INSTEAD OF FOUR PER RECORD.
#
# Every settled record still has its digest recomputed from its stored text on
# every read; what changed is only what that costs. The record-at-a-time loop this
# replaced spent about four jq launches per record and re-serialised a growing
# accumulator on each pass: measured on the main home on 2026-08-31, 232 settled
# records cost 933 jq launches and 13.6 of the command's 14.1 seconds, while
# everything else this script does - both awk passes over 3.4 MB of markdown and
# the whole classification - accounted for the remaining 0.5.
#
# jq has no sha256, and sha256sum hashes files rather than a stream of records, so
# the texts are handed over NUL-separated and written one file each by shell
# builtins - no process per record - then hashed by a single pass over the set.
# The separator has to be NUL: most decision texts contain newlines, and none can
# contain a NUL, because they are markdown read out of the backlog.
sha256_each_decision() {  # <settled-json> -> one hex digest per record, in record order
  local settled=$1 dir text i=0
  local -a files=() hasher=()
  if command -v shasum >/dev/null 2>&1; then
    hasher=(shasum -a 256)
  elif command -v sha256sum >/dev/null 2>&1; then
    hasher=(sha256sum)
  else
    die "shasum or sha256sum is required"
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-decision-ledger.XXXXXX") \
    || die "could not create a working directory for the digest re-check"
  # `.decision` is chomped of trailing newlines to reproduce EXACTLY the text the
  # per-record loop hashed: it read the text through a command substitution, which
  # strips them, so a record whose decision ends in a blank line was hashed without
  # it. Preserving that is deliberate - this rewrite is a cost change and must not
  # move any record's verbatim verdict - and it is why the chomp is spelled out
  # rather than left to happen by accident.
  while IFS= read -r -d '' text; do
    printf '%s' "$text" > "$dir/$i" \
      || { rm -rf "$dir"; die "could not stage a decision text for the digest re-check"; }
    files[i]="$dir/$i"
    i=$((i + 1))
  done < <(printf '%s' "$settled" | jq -j '
    def chomp: if endswith("\n") then .[0:-1] | chomp else . end;
    .[] | (.decision | chomp), "\u0000"')
  # xargs batches the file list, so the pass still works on a home holding more
  # settled records than one argument list can carry, and its batches run in order.
  if [ "$i" -gt 0 ]; then
    printf '%s\0' "${files[@]}" | xargs -0 "${hasher[@]}" | awk '{print $1}'
  fi
  rm -rf "$dir"
}

# ONE FULL READ PER SESSION START, NOT ONE PER CALLER.
#
# bin/fm-bootstrap.sh runs --audit and bin/fm-session-start.sh runs --limit 5 a few
# seconds later, inside the SAME session start, over the same two files. The second
# used to redo the whole walk to print five records.
#
# THE KEY IS WHAT MAKES A REUSE HONEST. What is memoised is the entire computed
# model, and the key is the content of everything that model is derived from: this
# script's own bytes, both record files, and the baseline - hashed with their paths,
# so a home reading a different data directory can never collide with this one. A
# hit is therefore only ever returned when recomputing would provably produce the
# same answer, and a hand-edit between the two calls - exactly the thing the digest
# re-check exists to catch - changes the key and the walk runs again. That is what
# keeps this reader's claim true: every settled record it shows had its digest
# verified against these bytes, in this session start, seconds ago.
#
# The TTL is the second bound. A memo older than FM_DECISION_LEDGER_MEMO_TTL
# seconds (default 120, which is a session start's width and not a working day's)
# is ignored, so "the same session start" stays a wall-clock statement and not just
# a content one. FM_DECISION_LEDGER_NO_MEMO=1 turns the reuse off entirely.
#
# Every failure path here recomputes. A memo that cannot be read, written, keyed,
# or parsed costs a full walk and never a wrong answer.
memo_key() {
  local f hashes='' missing=''
  local -a present=()
  for f in "${BASH_SOURCE[0]}" "$BACKLOG" "$ARCHIVE" "$BASELINE"; do
    if [ -f "$f" ]; then present+=("$f"); else missing="$missing absent:$f"; fi
  done
  if [ "${#present[@]}" -gt 0 ]; then
    if command -v shasum >/dev/null 2>&1; then
      hashes=$(shasum -a 256 "${present[@]}" 2>/dev/null) || return 1
    else
      hashes=$(sha256sum "${present[@]}" 2>/dev/null) || return 1
    fi
  fi
  sha256_text "$hashes$missing"
}

# THE FILE SHAPE IS THE WHOLE POINT. A reuse only wins if reading it back costs
# less than recomputing it, and the model is a megabyte of JSON: round-tripping it
# through jq cost more than the walk it was meant to save, measured. So the memo is
# four lines - `<key> <epoch>`, then the three compact JSON values exactly as the
# shell already holds them - read back with shell builtins alone. No parse, no
# process, and the values downstream get are byte-identical to the computed ones.
MEMO_CLASSIFIED=""
MEMO_VERIFIED=""
MEMO_ALTERED=""

memo_read() {  # <key>; on a hit fills MEMO_* and returns 0, otherwise returns 1
  local key=$1 header stored_key stored_at now c v a
  [ "$MEMO_TTL" -gt 0 ] || return 1
  [ -f "$MEMO" ] || return 1
  { IFS= read -r header && IFS= read -r c && IFS= read -r v && IFS= read -r a; } < "$MEMO" 2>/dev/null \
    || return 1
  stored_key=${header%% *}
  stored_at=${header#* }
  [ -n "$stored_key" ] && [ "$stored_key" = "$key" ] || return 1
  case "$stored_at" in ''|*[!0-9]*) return 1 ;; esac
  now=${EPOCHSECONDS:-$(date +%s)}
  [ "$((now - stored_at))" -ge 0 ] && [ "$((now - stored_at))" -le "$MEMO_TTL" ] || return 1
  # A truncated or otherwise unreadable payload is a miss, not a guess.
  case "$c" in '['*|'{'*) ;; *) return 1 ;; esac
  case "$v" in '['*) ;; *) return 1 ;; esac
  case "$a" in '['*) ;; *) return 1 ;; esac
  MEMO_CLASSIFIED=$c
  MEMO_VERIFIED=$v
  MEMO_ALTERED=$a
  return 0
}

memo_write() {  # <key> <classified> <verified> <altered>; best-effort, never fatal
  local key=$1 tmp
  [ "$MEMO_TTL" -gt 0 ] || return 0
  [ -n "$key" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp=$(mktemp "$MEMO.XXXXXX" 2>/dev/null) || return 0
  if { printf '%s %s\n' "$key" "${EPOCHSECONDS:-$(date +%s)}"
       printf '%s\n' "$2" "$3" "$4"; } > "$tmp" 2>/dev/null; then
    # Rename, so a concurrent reader sees either the previous memo whole or this one
    # whole, and never a half-written file it would have to guess about.
    mv -f "$tmp" "$MEMO" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Feed JSON values that can grow with a home's backlog to jq on stdin instead of
# argv. Linux caps one argv string at MAX_ARGSTRLEN independently of ARG_MAX, so a
# large captain-record set must never travel through jq --argjson.
json_stdin() {  # <json>...
  printf '%s\n' "$@" 2>/dev/null
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
                      state_text, premise_filed, pointed, answer_record, answer_digest) {
      if (cur_id == "") return
      decision = ""; grab = 0; envelope = 0; digest = ""; routed = ""; door = ""
      superseded = 0; successor = ""; premise = ""; premise_checked = ""; fold_reason = ""
      state_text = ""; premise_filed = ""
      pointed = 0; answer_record = ""; answer_digest = ""
      for (i = 1; i <= bn; i++) {
        line = body[i]
        if (i == 1 && line == "Resolution recorded by fm-decision-hold.") { envelope = 1; continue }
        if (i == 1 && line == "Superseded by fm-decision-hold.") { superseded = 1; continue }
        # THE FOURTH DISPOSITION. A closed record whose answer is stored under a
        # different identity, attested by fm-decision-hold.sh answered-by. It is
        # neither answered here nor folded: the pointer is checked below against
        # the record it names, so a pointer to nothing reports rather than settles.
        if (i == 1 && line == "Answered elsewhere by fm-decision-hold.") { pointed = 1; continue }
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
        if (pointed) {
          if (index(line, "Answer record: ") == 1) { answer_record = substr(line, 16) }
          else if (index(line, "Answer digest: ") == 1) { answer_digest = substr(line, 16) }
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
      printf "%s{\"id\":\"%s\",\"title\":\"%s\",\"repo\":\"%s\",\"kind\":\"%s\",\"state\":\"%s\",\"source\":\"%s\",\"closed\":\"%s\",\"hold_kind\":\"%s\",\"held\":%s,\"blockers\":\"%s\",\"envelope\":%s,\"complete\":%s,\"digest\":\"%s\",\"door\":\"%s\",\"routed\":\"%s\",\"decision\":\"%s\",\"folded\":%s,\"successor\":\"%s\",\"fold_reason\":\"%s\",\"premise\":\"%s\",\"premise_measured\":\"%s\",\"premise_filed\":\"%s\",\"state_text\":\"%s\",\"pointed\":%s,\"answer_record\":\"%s\",\"answer_digest\":\"%s\"}",
        (emitted++ ? "," : ""), jesc(cur_id), jesc(cur_title), jesc(cur_repo), jesc(cur_kind),
        cur_state, cur_source, jesc(cur_closed), jesc(cur_hold_kind),
        (cur_hold == "" ? "false" : "true"), jesc(cur_blockers),
        (envelope ? "true" : "false"), (grab == 2 ? "true" : "false"),
        jesc(digest), jesc(door), jesc(routed), jesc(decision),
        (superseded ? "true" : "false"), jesc(successor), jesc(fold_reason),
        jesc(premise), jesc(premise_checked), jesc(premise_filed), jesc(state_text),
        (pointed ? "true" : "false"), jesc(answer_record), jesc(answer_digest)
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

MEMO_KEY=$(memo_key 2>/dev/null) || MEMO_KEY=""
MEMO_HIT=0
if [ -n "$MEMO_KEY" ] && memo_read "$MEMO_KEY"; then
  MEMO_HIT=1
fi

if [ "$MEMO_HIT" -eq 1 ]; then
  CLASSIFIED=$MEMO_CLASSIFIED
else

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
# Compact, because this value is a megabyte on a working home: every consumer
# below re-parses it, and the memo stores it as one line.
CLASSIFIED=$(printf '%s' "$RECORDS" | jq -c '
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
        # CLOSED WITH THE ANSWER NOWHERE - AND, WHEN THERE IS ONE, WHERE TO LOOK.
        # This was the one class with no route to resolution. Its records are
        # closed, so `supersede` refuses them; several are archived, which
        # `tasks-axi show` cannot see; and a dateless closed row cannot be
        # baselined either, so three of them reported at every session start
        # forever. Where this home already holds an ANSWERED captain record for
        # the same investigation, the finding names it and the exact command that
        # attests it, so the line carries its own next step instead of being a
        # standing demand nobody can meet. The attestation belongs to a person and never to
        # this reader: a shared origin is a place to look, not proof that the
        # stored answer is the answer to THIS question.
        + ($caps | map(select(.state == "done" and (.envelope | not) and (.folded | not) and (.pointed | not))
                     | . as $c
                     | ($answered | map(select(.origin == $c.origin)) | map(.id)) as $cand
                     | {class: "closed-without-record", id: .id,
                        detail: (if ($cand | length) > 0
                                 then ("closed with no captain decision stored, yet this home holds an answered captain record for the same investigation: "
                                       + ($cand | join(", "))
                                       + "; if it carries his answer to THIS question, attach it with fm-decision-hold.sh answered-by "
                                       + $c.id + " --by " + ($cand | first)
                                       + ", and if none of them does, his answer here is lost and belongs in the adoption baseline")
                                 else "closed with no captain decision stored and no supersession recorded; the answer is nowhere in this home" end)}))
        # A POINTER THAT NO LONGER RESOLVES IS NOT A DISPOSITION. The attested
        # answer record must still be an answered captain record in this home AND
        # still carry the digest the attestation was made against, so a later
        # hand-edit of his words breaks the pointer rather than being inherited by
        # every record aimed at them.
        + ($caps | map(select(.pointed)
                     | . as $p
                     | ($answered | map(select(.id == $p.answer_record))) as $hit
                     | select(($hit | length) == 0
                              or (($hit | map(.digest) | index($p.answer_digest)) == null))
                     | {class: "answer-pointer-broken", id: .id,
                        detail: ("is recorded as answered by " + $p.answer_record
                                 + ", but this home holds no answered captain record under that id carrying the attested digest; re-attest it with fm-decision-hold.sh answered-by "
                                 + $p.id + " --by <answered record id>, or repair the record it names")}))
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

fi  # end of the full parse-and-classify walk a memo hit skips

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
              elif .pointed then "answered-elsewhere"
              elif .live then "open" else "closed" end),
        id, repo, title, closed}]
    | (map(select(.cls == "open")) | sort_by(.id))
      + (map(select(.cls == "settled")) | sort_by(.closed) | reverse)
      + (map(select(.cls == "superseded" or .cls == "answered-elsewhere" or .cls == "closed")) | sort_by(.id))
    | .[] | [.cls, .id, .repo, .title] | @tsv'
  exit 0
fi

# A count this reader cannot read is an environment fault, and it says so in one
# line rather than limping on. A jq that answers nothing - a stubbed or broken one -
# leaves every value here empty, and a verification reader that continues from an
# unreadable count is asserting exactly what it just failed to establish.
require_count() {  # <value> <what>
  case "$1" in
    ''|*[!0-9]*) die "could not count $2 (jq answered '$1'); refusing to report on records this read could not size" ;;
  esac
}

if [ "$MEMO_HIT" -eq 1 ]; then
  # Reused, not skipped: these are the verdicts the walk moments ago took from
  # these exact bytes, and the key is what says so. See the memo note above.
  VERIFIED=$MEMO_VERIFIED
  ALTERED=$MEMO_ALTERED
  COUNT=$(printf '%s' "$VERIFIED" | jq 'length')
  require_count "$COUNT" "the settled decision records"
else

SETTLED=$(printf '%s' "$CLASSIFIED" | jq -c '[.captain[] | select(.settled)] | sort_by(.closed) | reverse')
COUNT=$(printf '%s' "$SETTLED" | jq 'length')
require_count "$COUNT" "the settled decision records"
RECOMPUTED=$(sha256_each_decision "$SETTLED")
# A COUNT MISMATCH IS A REFUSAL, NOT A DEFAULT. If the recomputed set does not line
# up one-to-one with the records, some record's text was not re-hashed on this read,
# and the whole claim this output makes is that every settled record it shows was.
# Presenting them anyway - with the unmatched ones silently reading as altered, or
# worse as verified - would be the reader asserting what it failed to demonstrate.
RECOMPUTED_COUNT=0
[ -n "$RECOMPUTED" ] && RECOMPUTED_COUNT=$(printf '%s\n' "$RECOMPUTED" | wc -l | tr -d ' ')
[ "$RECOMPUTED_COUNT" -eq "$COUNT" ] \
  || die "the digest re-check recomputed $RECOMPUTED_COUNT digest(s) for $COUNT settled record(s); refusing to present decisions whose stored text was not re-hashed on this read"
VERIFICATION=$(printf '%s' "$SETTLED" | jq -c --arg recomputed "$RECOMPUTED" '
  (if $recomputed == "" then [] else ($recomputed | split("\n")) end) as $got
  | [to_entries[] | .value + {verbatim: (.value.digest == $got[.key])}] as $verified
  | {verified: $verified,
     altered: [$verified[] | select(.verbatim | not)
               | {class: "altered-record", id: .id,
                  detail: "the stored decision text no longer matches its recorded digest"}]}')
VERIFIED=$(printf '%s' "$VERIFICATION" | jq -c '.verified')
ALTERED=$(printf '%s' "$VERIFICATION" | jq -c '.altered')
memo_write "$MEMO_KEY" "$CLASSIFIED" "$VERIFIED" "$ALTERED"

fi  # end of the full digest re-check a memo hit skips

AUDIT_ALL=$(json_stdin "$CLASSIFIED" "$ALTERED" \
  | jq -cn 'input as $classified | input as $altered | $classified.audit + $altered')

# THE BASELINE SPLIT. A (class, id, observed closed date) entry is withheld from the
# findings that demand action and carried instead under baseline_excluded, where a
# reader and `--json` can both still see it. Nothing is dropped, and the withheld
# count is stated on every direct --audit run.
BASELINE_JSON=$(read_baseline)
BASELINE_DATE=$(baseline_recorded)
BASELINE_EXPECTED_DIGEST=$(baseline_entries_digest)
BASELINE_ENTRY_LINES=$(printf '%s' "$BASELINE_JSON" | jq -r '.[] | "\(.class) \(.id) \(.closed)"')
BASELINE_ACTUAL_DIGEST=$(sha256_text "$BASELINE_ENTRY_LINES")
BASELINE_INTACT=0
if [ -n "$BASELINE_EXPECTED_DIGEST" ] && [ "$BASELINE_ACTUAL_DIGEST" = "$BASELINE_EXPECTED_DIGEST" ]; then
  BASELINE_INTACT=1
fi
# Membership integrity, class, current closure, observed closure and baseline date
# are all enforced here, not trusted from the hand-editable file.
if [ "$BASELINE_INTACT" -eq 1 ]; then
  BASELINE_HONOURED=$(json_stdin "$BASELINE_JSON" "$CLASSIFIED" | jq -cn \
    --argjson classes "$BASELINE_CLASSES" --arg date "$BASELINE_DATE" '
    input as $baseline
    | input as $records
    | $baseline
    |
    map(. as $b
        | ($records.captain | map(select(.id == $b.id)) | first // null) as $r
        | select(($classes | index($b.class)) != null
                 and $r != null and $r.closed != ""
                 and $b.closed != "" and $b.closed == $r.closed
                 and $date != "" and $b.closed <= $date))')
else
  BASELINE_HONOURED='[]'
fi
BASELINE_REJECTED=$(json_stdin "$BASELINE_JSON" "$BASELINE_HONOURED" \
  | jq -cn 'input as $baseline | input as $honoured
    | $baseline | map(. as $b | select($honoured | index($b) == null))')
# The finding is bound to $f before the lookup because `index(f)` evaluates f
# against its own input - the covered list - and not against the finding tested.
AUDIT=$(json_stdin "$AUDIT_ALL" "$BASELINE_HONOURED" | jq -cn '
  input as $audit_all
  | input as $base
  | $audit_all
  |
  ($base | map(.class + " " + .id)) as $covered
  | map(. as $f | select(($covered | index($f.class + " " + $f.id)) == null))')
BASELINE_EXCLUDED=$(json_stdin "$AUDIT_ALL" "$BASELINE_HONOURED" | jq -cn '
  input as $audit_all
  | input as $base
  | $audit_all
  |
  ($base | map(.class + " " + .id)) as $covered
  | map(. as $f | select(($covered | index($f.class + " " + $f.id)) != null))')
# What a baseline WOULD cover if one were taken now. Used to tell a home with no
# baseline that one is available, and to build the file under --record-baseline.
BASELINE_CANDIDATES=$(json_stdin "$AUDIT_ALL" "$CLASSIFIED" | jq -cn \
  --argjson classes "$BASELINE_CLASSES" '
  input as $audit_all
  | input as $records
  | $audit_all
  |
  map(select(.class as $c | $classes | index($c))
      | . as $f
      | ($records.captain | map(select(.id == $f.id)) | first // null) as $r
      | . + {closed: ($r.closed // "")})')
BASELINEABLE=$(printf '%s' "$BASELINE_CANDIDATES" | jq -c 'map(select(.closed != ""))')
BASELINE_SKIPPED=$(printf '%s' "$BASELINE_CANDIDATES" | jq -c 'map(select(.closed == ""))')

if [ "$MODE" = record-baseline ]; then
  [ -e "$BASELINE" ] && die "a baseline already exists at $BASELINE (recorded ${BASELINE_DATE:-unknown}); remove it by hand to take a new one, so a baseline can never be re-taken as a side effect of a routine run"
  n=$(printf '%s' "$BASELINEABLE" | jq 'length')
  skipped=$(printf '%s' "$BASELINE_SKIPPED" | jq 'length')
  [ "$n" -gt 0 ] || die "there is nothing to baseline: no finding in $DATA sits on an already-closed captain record"
  today=$(date -u +%Y-%m-%d)
  entries=$(printf '%s' "$BASELINEABLE" | jq -r 'sort_by(.class, .id)[] | "\(.class) \(.id) \(.closed)"')
  entries_digest=$(sha256_text "$entries")
  {
    printf '# Captain decision adoption baseline for %s\n' "$FM_HOME"
    printf '# recorded: %s\n' "$today"
    printf '# entries-digest: %s\n' "$entries_digest"
    printf '#\n'
    printf '# Each line below is one finding that bin/fm-decision-ledger.sh --audit reported\n'
    printf '# on a captain record that was ALREADY CLOSED when this baseline was taken. Their\n'
    printf '# answers are lost, not pending: the records were closed before this mechanism\n'
    printf '# existed, so nothing a later session does can recover them. --audit withholds\n'
    printf '# exactly these pairs and states how many it withheld, so the check can converge\n'
    printf '# on the records that can still be repaired.\n'
    printf '#\n'
    printf '# This file silences nothing else. A finding on a LIVE record is never covered\n'
    printf '# here, and a record closed after %s is a genuine new failure and is\n' "$today"
    printf '# reported in full. Editing any entry invalidates the whole baseline. To re-take\n'
    printf '# the baseline, delete this file by hand and run --record-baseline again.\n'
    printf '#\n'
    printf '# <audit class> <record id> <closed date observed at baseline>\n'
    printf '%s\n' "$entries"
  } > "$BASELINE" || die "could not write $BASELINE"
  printf 'recorded %s finding(s) on already-closed captain records as lost rather than pending\n' "$n"
  printf 'skipped %s finding(s) whose closed record has no closed date; they remain reported\n' "$skipped"
  printf 'baseline: %s\n' "$BASELINE"
  printf 'these are withheld from --audit from now on; every finding on a live record still reports\n'
  exit 0
fi
OPEN=$(printf '%s' "$CLASSIFIED" | jq -c \
  '[.captain[] | select(.live) | select(.envelope | not)
    | {id, title, repo, held, blocks, premise, premise_measured, premise_outcome}]')
FOLDED=$(printf '%s' "$CLASSIFIED" | jq -c \
  '[.captain[] | select(.superseded) | {id, title, successor, fold_reason}]')
POINTED=$(printf '%s' "$CLASSIFIED" | jq -c \
  '[.captain[] | select(.pointed) | {id, title, answer_record}]')

SHOWN=$LIMIT
[ "$ALL" -eq 1 ] && SHOWN=$COUNT

LEDGER=$(json_stdin "$VERIFIED" "$OPEN" "$AUDIT" "$BASELINE_EXCLUDED" "$BASELINE_JSON" "$FOLDED" "$POINTED" \
  | jq -cn \
  --arg home "$FM_HOME" \
  --arg basepath "$BASELINE" \
  --arg basedate "$BASELINE_DATE" \
  --argjson shown "$SHOWN" \
  'input as $settled
   | input as $open
   | input as $audit
   | input as $excluded
   | input as $baseline
   | input as $folded
   | input as $pointed
   | {schema: "fm-decision-ledger.v1", home: $home,
    settled_total: ($settled | length),
    settled: $settled[0:$shown],
    open: $open,
    folded: $folded,
    answered_elsewhere: $pointed,
    audit: $audit,
    baseline_excluded: $excluded,
    baseline: (if ($baseline | length) > 0
               then {path: $basepath, recorded: (if $basedate == "" then null else $basedate end),
                     count: ($baseline | length)}
               else null end),
    omitted: (if ($settled | length) > $shown
              then [{surface: "settled", count: (($settled | length) - $shown), reveal: "--all"}]
              else [] end)}')

AUDIT_COUNT=$(printf '%s' "$AUDIT" | jq 'length')
EXCLUDED_COUNT=$(printf '%s' "$BASELINE_EXCLUDED" | jq 'length')
BASELINEABLE_COUNT=$(printf '%s' "$BASELINEABLE" | jq 'length')
REJECTED_COUNT=$(printf '%s' "$BASELINE_REJECTED" | jq 'length')

# The one line that keeps a withheld finding from becoming a hidden one, and the one
# that tells a home still drowning in pre-mechanism history that it can converge.
# Both are emitted in the `<class> <id> - <detail>` shape bin/fm-bootstrap.sh feeds
# straight into its diagnostic stream.
baseline_note() {
  if [ -f "$BASELINE" ] && [ "$BASELINE_INTACT" -ne 1 ]; then
    printf 'baseline rejected - %s has been edited since it was generated, so no entry is honoured and every finding reports; delete it and re-take it with fm-decision-ledger.sh --record-baseline\n' \
      "$BASELINE"
  elif [ "$REJECTED_COUNT" -gt 0 ]; then
    printf 'baseline rejected - %s line(s) in %s do not match an allowed finding and the closure observed when the baseline was recorded; those lines are ignored and every finding they name still reports\n' \
      "$REJECTED_COUNT" "$BASELINE"
  fi
  if [ "$EXCLUDED_COUNT" -gt 0 ]; then
    printf 'baseline recorded - %s finding(s) on captain records already closed when this home adopted the mechanism are withheld; their answers are lost, not pending (listed in %s, recorded %s)\n' \
      "$EXCLUDED_COUNT" "$BASELINE" "${BASELINE_DATE:-unknown}"
  elif [ ! -f "$BASELINE" ] && [ "$BASELINEABLE_COUNT" -gt 0 ]; then
    printf 'baseline absent - %s of the findings above sit on captain records that are already closed, so nothing can recover their answers; if they are lost rather than pending, run fm-decision-ledger.sh --record-baseline once and this check converges on the records still worth repairing\n' \
      "$BASELINEABLE_COUNT"
  fi
}

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
    json_stdin "$PREMISES" "$AUDIT" \
      | jq -cn 'input as $p | input as $a
        | {schema: "fm-decision-ledger.v1", open_premises: $p, audit: $a}'
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
    printf '%s' "$LEDGER" | jq '{schema, home, audit, baseline_excluded, baseline}'
  else
    if [ "$AUDIT_COUNT" -eq 0 ]; then
      printf 'no unfinished captain decision records in %s\n' "$DATA"
    else
      # One line per finding, because bin/fm-bootstrap.sh prefixes this output
      # straight into its one-line-per-problem diagnostic stream.
      printf '%s' "$AUDIT" | jq -r '.[] | "\(.class) \(.id) - \(.detail)"'
    fi
    # Always, including on a clean read: a withheld finding that is never mentioned
    # is a hidden one, and hiding is the thing this baseline was built not to do.
    baseline_note
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
  "open captain decision records: \(.open | length)",
  "questions folded into a later record: \(.folded | length)",
  "questions whose answer is stored under another record: \(.answered_elsewhere | length)",
  (if (.audit | length) > 0 then
     "", "UNFINISHED DECISION RECORDS - these need repair, not a new question:",
     (.audit[] | "  \(.class)  \(.id)\n      \(.detail)")
   else empty end),
  (if (.baseline_excluded | length) > 0 then
     "", "(\(.baseline_excluded | length) further finding(s) sit on records already closed when this",
     " home adopted the mechanism; their answers are lost, not pending. Listed in",
     " \(.baseline.path), recorded \(.baseline.recorded // "unknown").)"
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
