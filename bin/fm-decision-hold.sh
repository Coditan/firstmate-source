#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity. An
# identity already durably resolved, in the live backlog or in data/done-archive.md,
# is never reopened.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# A captain decision reaches this fleet through three doors, and only one of them
# used to have a durable home. `hold` plus `resolve` cover the first: a decision an
# investigation or visual review discovered, registered ahead of the answer, and
# routed into dependent work. `record` covers all three, including the two that had
# none - an ask-user finding returned by a validation gate, and a plain sentence in
# chat - by writing the same resolution record without requiring that a hold was
# registered first or that any dependent work was gated on the answer.
# Measured on 2026-08-17: four decisions the captain gave that day, every one acted
# on and landed, appeared zero times in the backlog, because all three of their
# homes - a worker status log deleted at teardown, a pull-request body on the forge,
# and one session's context - are temporary. `record` is the entrance that store was
# missing; docs/decision-hold-lifecycle.md keeps that measurement.
# It is deliberately ONE store with several entrances, not a second store beside the
# holds: two records that can disagree are worse than the gap, because then a reader
# must know which one is lying.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> --premise <one line> [--repo <repo>] \
#     (--supersedes <id>... | --new-ground)
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh record <origin-id> <decision-key> \
#     --door <hold|ask-user|chat> --decision-file <path> [--title <title>] \
#     [--repo <repo>] [--routed-to <task-id>...] \
#     (--supersedes <id>... | --new-ground)
#   fm-decision-hold.sh supersede <hold-id> --by <successor-id> --reason <one line>
#   fm-decision-hold.sh recheck <origin-id> <decision-key> \
#     --outcome <holds|broken|unmeasurable> --measured-at <locator> [--note <line>] \
#     [--premise <restated line>]
#
# ONE RECORD, THREE ACTS, ONE RE-MEASUREMENT.
# A captain decision record is FILED (`hold`) with the premise that makes it live,
# ANSWERED (`record`, `resolve`) with the captain's verbatim words, or FOLDED
# (`supersede`) into a later record that covers its ground without claiming he
# answered it. `recheck` re-measures a filed record's premise and closes nothing.
# These are dispositions of one record in one store, not separate systems: a second
# store that could disagree with this one would only make a reader ask which is
# lying.
#
# `--premise`, `--title`, and the disposition flags apply when the identity is NEW.
# Repeating either command on an identity that already exists is still idempotent
# and needs none of them, because nothing is being added.
#
# THE INTAKE GATE. `hold` and `record` refuse to add a captain record while this
# home holds others for the same repository that the caller has not disposed of.
# `--supersedes <id>` folds one; `--new-ground` attests that none of them asks this
# question. The refusal lists them, so the filer sees the open questions AND the
# recorded answers before it attests. The gate is on the answer as well as the
# question, because an answer that cannot fold what it settles leaves it standing.
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `complete` may append its metadata keys after a task's PR fields; bin/fm-pr-lib.sh
# owns the PR parser contract and does not reserve a state/<id>.meta tail.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded. A resolved captain hold that retention
# moved into data/done-archive.md remains a durable completion record, but only
# while every archived entry under that identity is itself a resolved captain hold.
# One successor rule covers live and archived records: it must be a captain record;
# an open question is valid, while a completed record must carry an answered
# resolution. A fold remains a valid disposition for completion and reopen
# protection, but never a successor to fold into because it carries no answer.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# `record` takes the same final step for a decision that arrived through any door.
# It creates the captain item when none exists, so a chat answer needs no prior
# registration, and it accepts zero --routed-to tasks, because a decision the
# captain gave and a worker acted on immediately gated nothing. What it will not do
# is invent the decision: --decision-file carries the captain's own words, and the
# caller supplies them. This script never reads chat, prose, or terminal output to
# guess that a decision happened.
#
# THE WORDS ARE STORED VERBATIM AND THE DIGEST PROVES IT. The recorded body carries
# a sha256 of the exact decision text, and after writing, `record` reads the stored
# text back out of the backlog and refuses unless it is byte-identical. The one
# boundary normalization is that trailing newlines are stripped from the decision
# file, because a text file's terminating newline is not part of what was said; any
# other difference is a refusal, never a silent repair. bin/fm-decision-ledger.sh
# re-checks that digest on every read, so a later hand-edit is visible rather than
# quietly authoritative.
#
# AN UNFINISHED CLOSE IS DETECTABLE BY CONSTRUCTION. Both `resolve` and `record`
# write the resolution body FIRST, then clear dependency edges, then mark the item
# Done. A close interrupted anywhere therefore leaves a captain item that carries a
# resolution record while still being open - a state bin/fm-decision-ledger.sh
# --audit reports and session start prints. The ordering is the mechanism; do not
# reorder these three steps for convenience.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# The archive location is pinned rather than read from tasks-axi configuration.
# That is correct only because the tracked root .tasks.toml pins
# archive = "data/done-archive.md" and every fleet home is a checkout carrying it.
# It diverges if markdown.archive is repointed or if FM_DATA_OVERRIDE moves away
# from $FM_HOME/data, because tasks-axi resolves the archive relative to $FM_HOME.
# The divergence is fail-closed: cleanup is refused, never wrongly accepted.
#
# Accepted limitation with the same shape: when one identity has both a resolved
# and an unresolved archived entry, the completion gate refuses that identity
# permanently, because an all-entries-resolved test cannot tell a stale resolution
# apart from a stale unresolved record. Such an archive is only reachable through a
# manual `tasks-axi prune --state queued` or a hand edit, and the refusal names the
# offending entry so an operator can repair it. The lockout is preferred over
# trusting append order, which is not trustworthy in exactly the hand-edited case
# that produces it.
ARCHIVE="$DATA/done-archive.md"
# How many already-answered decisions the intake gate lists before it starts
# disclosing a withheld count. Open questions are never capped.
FM_DECISION_GATE_ANSWERS=${FM_DECISION_GATE_ANSWERS:-10}
case "$FM_DECISION_GATE_ANSWERS" in
  ''|*[!0-9]*) FM_DECISION_GATE_ANSWERS=10 ;;
esac
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

# --body-file rather than --body: a body passed as an argument travels through a
# command substitution that eats its trailing newlines, and this body's last line is
# a routed identity that must survive.
write_body() {  # <id> <body>
  local id=$1 body=$2 tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-decision-body.XXXXXX") || return 1
  printf '%s' "$body" > "$tmp"
  tasks_axi update "$id" --body-file "$tmp" >/dev/null
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# The single boundary normalization, stated where it happens: a text file's
# terminating newline is not part of what the captain said, so trailing newlines are
# dropped and nothing else is touched. Everything after this point treats the result
# as the captain's exact words.
read_decision_file() {  # <path>
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  case "$decision" in
    *$'\r'*) fail "decision file contains a carriage return; the backlog stores line-feed text and would not round-trip it verbatim" ;;
  esac
  reject_envelope_collision "$decision"
  printf '%s' "$decision"
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  if ! show=$(task_show "$id"); then
    archived_hold_resolved "$id"
    return
  fi
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

scan_archived_hold() {  # <hold-id> <all|any|unresolved|answered>
  local id=$1 mode=$2
  [ -f "$ARCHIVE" ] || return 1
  awk -v target="$id" -v mode="$mode" '
    function finish_entry() {
      if (active) {
        valid = checked && captain && resolution && routed
        if (mode != "answered") valid = valid || (checked && captain && superseded && successor)
        if (valid) resolved_seen = 1
        else {
          unresolved_seen = 1
          if (first_unresolved == "") first_unresolved = entry_line ": " entry_header
        }
      }
      active = 0
    }
    function is_task_header(line) {
      if (line ~ /^- \[( |x)\] [A-Za-z0-9][A-Za-z0-9._-]* - /) return 1
      return line ~ /^- \*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\* - /
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (is_task_header(line)) {
        finish_entry()
        checked = index(line, "- [x] " target " - ") == 1
        active = checked || index(line, "- [ ] " target " - ") == 1 \
          || index(line, "- **" target "** - ") == 1
        if (active) {
          captain = index(line, "(kind: captain)") > 0
          resolution = 0
          routed = 0
          superseded = 0
          successor = 0
          entry_line = NR
          entry_header = line
        }
        next
      }
      if (active && line == "  Resolution recorded by fm-decision-hold.") resolution = 1
      if (active && index(line, "  Routed work:") == 1) routed = 1
      # A fold is a durable disposition for completion and reopen checks, but the
      # answered mode deliberately excludes it because a fold successor must carry
      # a captain answer before gated work can be released.
      if (active && line == "  Superseded by fm-decision-hold.") superseded = 1
      if (active && index(line, "  Successor: ") == 1) successor = 1
      if (active && line != "" && index(line, "  ") != 1) finish_entry()
    }
    END {
      finish_entry()
      if (mode == "any") exit(resolved_seen ? 0 : 1)
      if (mode == "unresolved") {
        if (first_unresolved == "") exit 1
        print first_unresolved
        exit 0
      }
      exit(resolved_seen && !unresolved_seen ? 0 : 1)
    }
  ' "$ARCHIVE"
}

# The completion gate needs every archived entry under this identity to be a
# resolved captain hold, so a stale resolution never vouches for a later decision
# that reused the same key.
archived_hold_resolved() {  # <hold-id>
  scan_archived_hold "$1" all
}

archived_hold_answered() {  # <hold-id>
  scan_archived_hold "$1" answered
}

require_fold_successor() {  # <successor-id>
  local id=$1 show state kind body
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    [ "$kind" = captain ] \
      || fail "successor $id is a live $kind item, not a captain record"
    if [ "$state" = "done" ]; then
      body=$(show_field "$show" body)
      case "$body" in
        *"Resolution recorded by fm-decision-hold."*"Routed work:"*) : ;;
        *) fail "successor $id is a completed captain record without an answered resolution; a folded question is a disposition, never a successor to fold into" ;;
      esac
    fi
    FOLD_SUCCESSOR_STATE=$state
    return 0
  fi
  archived_hold_answered "$id" \
    || fail "successor $id is absent from the live backlog and is not an unambiguous archived answered captain record carrying both the recorded resolution and routed work; a folded question is a disposition, never a successor to fold into"
  FOLD_SUCCESSOR_STATE="done"
}

# The reopen guard asks the opposite question: does any archived entry already
# carry a durable resolution for this identity.
archived_hold_resolution_exists() {  # <hold-id>
  scan_archived_hold "$1" any
}

# Locates the archived entry that made the gate refuse, as `<line>: <header>`.
archived_hold_unresolved_entry() {  # <hold-id>
  scan_archived_hold "$1" unresolved
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind stale
  if ! show=$(task_show "$id"); then
    archived_hold_resolved "$id" && return 0
    stale=$(archived_hold_unresolved_entry "$id") || stale=''
    if [ -n "$stale" ]; then
      fail "$(printf 'captain decision %s is absent from %s and this archived entry under that identity records no captain answer:\n  %s:%s\nrecovery: repair or remove that archived entry in %s so every archived entry under %s carries "Resolution recorded by fm-decision-hold." and "Routed work:", or inventory the origin under a new decision key.' \
        "$id" "$FM_HOME/data/backlog.md" "$ARCHIVE" "$stale" "$ARCHIVE" "$id")"
    fi
    fail "captain decision $id is absent from $FM_HOME/data/backlog.md and has no resolved record in $ARCHIVE"
  fi
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if verify_hold_resolved "$id"; then
    return 0
  fi
  # A folded record is a durable outcome too. Refusing it here would make the
  # completion gate demand that a question already covered by a later record be
  # answered anyway, which is the duplicate pressure this mechanism exists against.
  if verify_hold_superseded "$id"; then
    return 0
  fi
  fail "captain decision $id is neither actively held, durably resolved, nor folded into a later record"
}

# The resolution envelope has exactly one owner: this function. `resolve` and
# `record` both build their body here so the two entrances cannot drift into two
# formats, and bin/fm-decision-ledger.sh parses what this writes.
#
# The header block is generated ASCII, one `Field: value` per line, terminated by
# the blank line before `Captain decision:`. Everything between that marker and the
# blank line before `Routed work:` is the captain's own text, byte for byte.
# The `Door:` field is new; a body written before it existed simply omits it, and
# every reader here treats it as optional for exactly that reason.
build_resolution_body() {  # <digest> <routed-csv> <door> <decision> <routed-id>...
  local digest=$1 routed_csv=$2 door=$3 decision=$4 body dep
  shift 4
  # The trailing newline is re-appended after the substitution, which eats it.
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nDoor: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$digest" "$routed_csv" "$door" "$decision")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    # A decision that gated nothing still gets an explicit line, so "no routed
    # work" is a recorded fact rather than a truncated record.
    body="${body}- (none)"$'\n'
  else
    for dep in "$@"; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  printf '%s' "$body"
}

# `show --full` renders the body as one escaped line. The generated header block is
# pure ASCII with no backslashes, so splitting the portion before the captain's text
# on the literal two-character `\n` is safe there; it would NOT be safe across the
# captain's own words, which is why this stops at the marker.
envelope_header() {  # <escaped-body>
  local body=$1 head
  case "$body" in
    *'\n\nCaptain decision:'*) head=${body%%'\n\nCaptain decision:'*} ;;
    *) return 1 ;;
  esac
  head=${head#\"}
  printf '%s' "$head" | sed 's/\\n/\
/g'
}

envelope_field() {  # <header> <field>
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 header recorded_digest recorded_routes
  header=$(envelope_header "$hold_body") \
    || fail "captain hold $id has no retry identity record"
  case "$header" in
    'Resolution recorded by fm-decision-hold.'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=$(envelope_field "$header" 'Decision digest')
  recorded_routes=$(envelope_field "$header" 'Routed identities')
  [ -n "$recorded_digest" ] || fail "captain hold $id has an invalid retry identity record"
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

verify_resolution_retry_identity() {
  local id=$1 decision_digest=$2 routed_csv=$3 show body recorded_digest recorded_routes
  if show=$(task_show "$id"); then
    verify_resolution_identity "$id" "$(show_field "$show" body)" "$decision_digest" "$routed_csv"
    return
  fi
  archived_hold_resolved "$id" || fail "captain decision $id has no unambiguous durable resolution in $ARCHIVE"
  body=$(raw_body_lines "$id") || fail "captain decision $id has no readable archived resolution"
  recorded_digest=$(printf '%s\n' "$body" | sed -n 's/^Decision digest: //p' | head -1)
  recorded_routes=$(printf '%s\n' "$body" | sed -n 's/^Routed identities: //p' | head -1)
  [ -n "$recorded_digest" ] || fail "captain hold $id has an invalid retry identity record"
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

# Reads the stored decision back out of the item and proves it is the text that was
# handed in. A store that mangled the captain's words must refuse, not repair: the
# whole point of the digest is that nobody has to trust this round trip.
verify_stored_decision() {  # <id> <expected-decision> <expected-digest>
  local id=$1 expected=$2 digest=$3 stored
  stored=$(stored_decision_text "$id") \
    || fail "captain decision $id has no readable stored decision text"
  [ "$stored" = "$expected" ] \
    || fail "captain decision $id did not store the captain's words verbatim; the backlog is holding altered text and the record was not closed"
  [ "$(sha256_text "$stored")" = "$digest" ] \
    || fail "captain decision $id stored text does not match its recorded digest"
}

# Reads the raw markdown rather than `show --full`, because the raw rows are the
# only representation that carries the captain's bytes with no escaping layer in
# between. Body lines are indented by exactly two spaces; a blank line inside a body
# is stored genuinely blank.
#
# The live backlog and data/done-archive.md are both searched, in that order, and
# the LAST match in each wins: `tasks-axi done` prunes by default, so a record can
# land straight in the archive, and the archive appends its sections oldest first.
# Nothing is emitted unless the whole envelope is present, so a half-written record
# yields no decision text rather than a truncated one.
stored_decision_text() {  # <id>
  local file text
  for file in "$DATA/backlog.md" "$ARCHIVE"; do
    [ -f "$file" ] || continue
    text=$(FM_DH_TARGET="$1" awk '
      BEGIN { target = ENVIRON["FM_DH_TARGET"] }
      function is_header(l) {
        return (l ~ /^- \[[ xX]\] [A-Za-z0-9][A-Za-z0-9._-]* - /) \
          || (l ~ /^- \*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\* - /)
      }
      function stop() { active = 0; grabbing = 0 }
      {
        line = $0
        sub(/\r$/, "", line)
        if (is_header(line)) {
          stop()
          if (index(line, "- [x] " target " - ") == 1 || index(line, "- [X] " target " - ") == 1 \
              || index(line, "- [ ] " target " - ") == 1 || index(line, "- **" target "** - ") == 1) {
            active = 1; n = 0
          }
          next
        }
        if (!active) next
        if (line != "" && index(line, "  ") != 1) { stop(); next }
        body = (line == "" ? "" : substr(line, 3))
        if (grabbing) {
          if (body == "Routed work:" && n > 0 && out[n] == "") {
            n--
            found = 1
            for (i = 1; i <= n; i++) kept[i] = out[i]
            keptn = n
            stop()
            next
          }
          out[++n] = body
          next
        }
        if (body == "Captain decision:") { grabbing = 1; n = 0 }
      }
      END {
        if (!found) exit 1
        for (i = 1; i <= keptn; i++) printf "%s%s", kept[i], (i < keptn ? "\n" : "")
      }
    ' "$file") || continue
    printf '%s' "$text"
    return 0
  done
  return 1
}

# The envelope is delimited by generated marker lines, so the captain's own text may
# not contain one at line start. Refused BEFORE anything is written, because a
# refusal after the write would leave exactly the half-finished record this
# mechanism exists to prevent.
reject_envelope_collision() {  # <decision>
  local marker
  for marker in 'Resolution recorded by fm-decision-hold.' 'Captain decision:' 'Routed work:'; do
    case "
$1
" in
      *"
$marker
"*) fail "the decision text contains the reserved envelope line \"$marker\" at the start of a line; record it with that line reworded, or route it through a file the record links to" ;;
    esac
  done
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

today() { printf '%s' "${FM_DECISION_NOW:-$(date +%F)}"; }

# A premise is only re-checkable if a later reader knows where it was measured. The
# seat is part of the record for the reason the third canvass seat found: a premise
# measured on a machine this seat no longer occupies cannot be re-measured from
# here, and that is a different answer from "it is no longer true".
seat_id() {
  printf '%s:%s' "$(uname -n 2>/dev/null || printf unknown-host)" "$(basename "$FM_HOME")"
}

raw_body_lines() {  # <id>
  local file text
  for file in "$DATA/backlog.md" "$ARCHIVE"; do
    [ -f "$file" ] || continue
    text=$(FM_DH_TARGET="$1" awk '
      BEGIN { target = ENVIRON["FM_DH_TARGET"] }
      function is_header(l) {
        return (l ~ /^- \[[ xX]\] [A-Za-z0-9][A-Za-z0-9._-]* - /) \
          || (l ~ /^- \*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\* - /)
      }
      {
        line = $0
        sub(/\r$/, "", line)
        if (is_header(line)) {
          active = 0
          if (index(line, "- [x] " target " - ") == 1 || index(line, "- [X] " target " - ") == 1 \
              || index(line, "- [ ] " target " - ") == 1 || index(line, "- **" target "** - ") == 1) {
            active = 1; n = 0; found = 1
          }
          next
        }
        if (!active) next
        if (line != "" && index(line, "  ") != 1) { active = 0; next }
        out[++n] = (line == "" ? "" : substr(line, 3))
        keptn = n
        for (i = 1; i <= n; i++) kept[i] = out[i]
      }
      END {
        if (!found) exit 1
        for (i = 1; i <= keptn; i++) print kept[i]
      }
    ' "$file") || continue
    printf '%s' "$text"
    return 0
  done
  return 1
}

# `Premise filed` names the seat the premise was OBSERVED on, not just the one that
# typed it. A later reader on a different seat needs that to tell "I measured this
# and it is false" from "I am not the seat that can see this" - the distinction the
# third canvass seat's wrong-repository record turned on.
# Every task this record gates. `tasks-axi list --blocked` prints one row per
# blocked task as `<id>,<state>,<kind>,<repo>,<title>,<blocked_by>`, with blocked_by
# comma-joined and the whole field quoted when it holds more than one id; the awk
# below matches the token rather than the field so a multi-blocker row still counts.
dependents_of() {  # <hold-id>
  # -v rather than an environment prefix: the prefix would attach to the tasks_axi
  # FUNCTION rather than to awk, which is how this silently found nothing at first.
  # A hold id is a validated slug, so -v has no escape to mangle.
  tasks_axi list --blocked --fields blocked_by 2>/dev/null | awk -v hold="$1" '
    /^  [A-Za-z0-9]/ {
      line = $0
      sub(/^  /, "", line)
      id = substr(line, 1, index(line, ",") - 1)
      if (id == "") next
      gsub(/"/, "", line)
      n = split(line, parts, ",")
      for (i = 2; i <= n; i++) if (parts[i] == hold) { print id; break }
    }
  ' || true
}

build_open_body() {  # <origin> <key> <premise> <measured-line> [filed-line]
  printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.\nPremise: %s\nPremise filed: %s\nPremise measured: %s\n' \
    "$1" "$2" "$3" "${5:-$(today) from $(seat_id)}" "$4"
}

# A fold is a THIRD disposition, distinct from open and from answered. It must never
# read as the captain having decided anything, because he did not; it says a later
# record covers this ground and points at it.
build_supersession_body() {  # <successor> <reason> <premise>
  printf 'Superseded by fm-decision-hold.\nSuccessor: %s\nReason: %s\nPremise at fold: %s\nState: closed as superseded; the captain did not answer this record.\n' \
    "$1" "$2" "${3:-(none recorded)}"
}

verify_hold_superseded() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Superseded by fm-decision-hold."*"Successor: "*) return 0 ;;
  esac
  return 1
}

# --- the intake disposition gate ---------------------------------------------
#
# WHY THIS IS A GATE AND NOT A DETECTOR. Measured on 2026-08-17 across three seats:
# one had 99 open captain records of which 18 were duplicates and 14 already
# answered; a second had 5 open of which 2 were duplicates of each other AND both
# already answered. On that second seat the two duplicates asked one question in
# entirely different vocabulary - whether a named company counts as a customer, and
# which parties count as intra-group - sharing no wording, no decision key, and no
# origin group. No matcher pairs those. The filer knew it was re-asking; nothing
# asked it.
#
# Both records were also filed CORRECTLY: each investigation registered its
# unresolved decisions before completing, exactly as required. The rule was not
# broken, it was incomplete - it had an intake step and no supersession step. This
# gate is the missing half, and it is placed where the knowledge is.
#
# It refuses the first filing and prints what is already there. That refusal is the
# mechanism: it puts the existing questions and the existing answers in front of the
# filer before it can attest to anything. `--supersedes` names what this record
# folds; `--new-ground` attests that none of them asks this question. Naming a fold
# is itself an attestation, so the two combine and either alone satisfies the gate.
require_disposition() {  # <new-id> <repo> <supersedes-space-list> <new-ground 0|1>
  local id=$1 repo=$2 folds=$3 new_ground=$4 records listing='' count=0 settled_seen=0 fold
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required to file a captain decision: the intake gate must read the records already open before this one can be added, and it will not add one unchecked"
  # Read the whole home, then scope the LISTING to this repository below. The two
  # scopes differ on purpose: what a filer is asked to read is bounded to the
  # repository it is filing against, but an id it names explicitly is folded
  # wherever it lives, because the filer has already identified it.
  records=$("$SCRIPT_DIR/fm-decision-ledger.sh" --records 2>/dev/null) || records=''
  # Every OPEN question is listed, with no cap: those are what this record might be
  # re-asking, and a capped list would let the one that matters be the one withheld.
  # Recent ANSWERS are listed too - the second canvass seat's duplicates were both
  # already ruled on - but bounded, because a long-lived repository accumulates them
  # without bound and the withheld count is disclosed rather than hidden.
  while IFS=$'\t' read -r cls rid rrepo rtitle; do
    [ -n "$rid" ] || continue
    [ "$rid" != "$id" ] || continue
    [ "$rrepo" = "$repo" ] || continue
    case "$cls" in
      open) listing="${listing}  still open   $rid - $rtitle"$'\n'; count=$((count + 1)) ;;
      settled)
        count=$((count + 1))
        settled_seen=$((settled_seen + 1))
        if [ "$settled_seen" -le "$FM_DECISION_GATE_ANSWERS" ]; then
          listing="${listing}  ANSWERED     $rid - $rtitle"$'\n'
        fi
        ;;
    esac
  done <<EOF
$records
EOF
  if [ "$settled_seen" -gt "$FM_DECISION_GATE_ANSWERS" ]; then
    listing="${listing}$(printf '  (%d older answered decision(s) not listed; bin/fm-decision-ledger.sh --all shows them)' \
      "$((settled_seen - FM_DECISION_GATE_ANSWERS))")"$'\n'
  fi

  for fold in $folds; do
    case "
$records
" in
      *"
open	$fold	"*) : ;;
      *) fail "cannot fold $fold into $id: this home has no OPEN captain record with that id, so there is nothing to fold; an already answered or already folded record is not superseded" ;;
    esac
  done

  [ "$count" -gt 0 ] || return 0
  [ -n "$folds" ] || [ "$new_ground" -eq 1 ] || fail "$(printf 'this home already holds %d captain decision record(s) for repository %s, and one of them may be asking what %s is about to ask again:\n%s\nRead them, then re-run with --supersedes <id> for each record this one folds, or --new-ground if none of them asks this question. A duplicate is not detectable from the wording: two records asking one question in different words were measured on 2026-08-17, and only the filer can see it.' \
    "$count" "$repo" "$id" "$listing")"
  return 0
}

fold_records() {  # <successor-id> <reason> <fold-id>...
  local successor=$1 reason=$2 fold
  shift 2
  for fold in "$@"; do
    command_supersede "$fold" --by "$successor" --reason "$reason" >/dev/null \
      || fail "could not fold $fold into $successor"
  done
}

command_supersede() {
  local id=${1:-} successor='' reason='' show state kind body premise line dep blocked succ_state
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --by) shift; successor=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug hold-id "$id"
  validate_slug successor-id "$successor"
  validate_one_line reason "$reason"
  [ "$id" != "$successor" ] || fail "a record cannot supersede itself"
  require_tasks_axi

  if verify_hold_superseded "$id"; then
    body=$(show_field "$(task_show "$id")" body)
    case "$body" in
      *"Successor: $successor"*) printf 'superseded: %s -> %s (already folded)\n' "$id" "$successor"; return 0 ;;
      *) fail "captain record $id is already folded into a different successor" ;;
    esac
  fi

  show=$(task_show "$id") || fail "captain record $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  # An answered record is never folded: its body carries the captain's own words,
  # and a fold would replace them with a pointer. Superseding is for a question,
  # not for an answer.
  ! verify_hold_resolved "$id" \
    || fail "captain decision $id already records the captain's answer; it cannot be superseded"
  [ "$state" != "done" ] || fail "captain record $id is already closed"
  require_fold_successor "$successor"
  succ_state=$FOLD_SUCCESSOR_STATE

  premise=$(printf '%s\n' "$(raw_body_lines "$id" || true)" | sed -n 's/^Premise: //p' | head -1)

  # The gated work moves with the question. Leaving it blocked by a closed record
  # would strand it; unblocking it outright would drop a gate nobody lifted.
  # These are the tasks blocked BY this record, which is the opposite direction
  # from the record's own blocked_by field - `tasks-axi list --blocked` is the only
  # view that answers it.
  for dep in $(dependents_of "$id"); do
    [ -n "$dep" ] || continue
    if [ "$succ_state" != "done" ]; then
      tasks_axi block "$dep" --by "$successor" >/dev/null \
        || fail "could not move the gate on $dep to $successor"
    fi
    tasks_axi unblock "$dep" --by "$id" >/dev/null \
      || fail "could not clear the folded gate from $dep"
  done

  line=$(build_supersession_body "$successor" "$reason" "$premise")
  write_body "$id" "$line" || fail "could not record the supersession on $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close superseded record $id"
  verify_hold_superseded "$id" || fail "captain record $id did not retain its supersession record"
  printf 'superseded: %s -> %s\n' "$id" "$successor"
}

# Re-measuring a premise NEVER closes anything. That separation is the whole point
# of the third canvass finding: a seat re-measured a premise about a validation
# registration, found the registry empty, and would have folded the record - but the
# seat had MOVED, and the wrong registration may still exist on the machine where it
# was found, which this seat cannot see. A re-check that cannot tell "false now"
# from "unmeasurable from here" quietly closes real findings. So `unmeasurable` is a
# first-class outcome that surfaces the record, and even `broken` only records the
# reading; folding it is a separate, deliberate act.
command_recheck() {
  local origin=${1:-} key=${2:-} outcome='' at='' note='' premise='' id lines new measured filed
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome) shift; outcome=${1:-} ;;
      --measured-at) shift; at=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --premise) shift; premise=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  case "$outcome" in
    holds|broken|unmeasurable) : ;;
    '') fail "--outcome is required: holds, broken, or unmeasurable" ;;
    *) fail "--outcome must be holds, broken, or unmeasurable (never infer unmeasurable as broken): $outcome" ;;
  esac
  validate_one_line measured-at "$at"
  [ -z "$note" ] || validate_one_line note "$note"
  [ -z "$premise" ] || validate_one_line premise "$premise"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  verify_hold_active "$id"

  lines=$(raw_body_lines "$id") || fail "captain record $id has no readable body"
  [ -n "$premise" ] || premise=$(printf '%s\n' "$lines" | sed -n 's/^Premise: //p' | head -1)
  [ -n "$premise" ] || premise="(none recorded)"
  # The filing seat is carried forward unchanged. Overwriting it with the seat doing
  # the re-check would erase the one fact that says where this premise can be seen.
  filed=$(printf '%s\n' "$lines" | sed -n 's/^Premise filed: //p' | head -1)
  [ -n "$filed" ] || filed="unrecorded"
  measured=$(printf '%s %s from %s at %s' "$(today)" "$outcome" "$(seat_id)" "$at")
  # The command substitution eats the terminating newline; without it the note
  # would be appended onto the end of the reading line instead of below it.
  new=$(build_open_body "$origin" "$key" "$premise" "$measured" "$filed")
  new="${new}"$'\n'
  [ -z "$note" ] || new="${new}Premise note: ${note}"$'\n'
  write_body "$id" "$new" || fail "could not record the premise reading on $id"
  case "$outcome" in
    broken) printf 'rechecked: %s premise no longer holds as measured here; folding it is a separate decision, not this one\n' "$id" ;;
    unmeasurable) printf 'rechecked: %s premise CANNOT BE MEASURED from %s; do not fold it - the finding may still be live where it was made\n' "$id" "$(seat_id)" ;;
    *) printf 'rechecked: %s premise still holds\n' "$id" ;;
  esac
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' premise='' folds='' new_ground=0
  local id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --premise) shift; premise=${1:-} ;;
      --supersedes) shift; validate_slug superseded-id "${1:-}"; folds="${folds}${folds:+ }${1:-}" ;;
      --new-ground) new_ground=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if archived_hold_resolution_exists "$id"; then
      fail "captain decision $id is already durably resolved in $ARCHIVE; use a new decision key for a new decision"
    fi
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    # A premise is required on a new question because a record nobody can
    # re-measure is a record that stays open forever by default. It states what
    # makes this question live right now, so a later reader can check whether it
    # still does instead of guessing.
    validate_one_line premise "$premise"
    require_disposition "$id" "$repo" "$folds" "$new_ground"
    body=$(build_open_body "$origin" "$key" "$premise" never)
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  # Folded after the successor exists and replayed at the shared existing-record
  # boundary, so a retry completes an interrupted disposal without duplicating it.
  # shellcheck disable=SC2086  # $folds is a deliberate space-separated id list
  [ -z "$folds" ] || fold_records "$id" "superseded by $id at intake" $folds
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  decision=$(read_decision_file "$decision_file")
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    verify_resolution_retry_identity "$id" "$decision_digest" "$routed_csv"
    verify_stored_decision "$id" "$decision" "$decision_digest"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  # shellcheck disable=SC2086  # $routed is a deliberate space-separated id list
  body=$(build_resolution_body "$decision_digest" "$routed_csv" hold "$decision" $routed)
  write_body "$id" "$body" \
    || fail "could not record the captain decision on $id"
  verify_stored_decision "$id" "$decision" "$decision_digest"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_record() {
  local origin=${1:-} key=${2:-} door='' decision_file='' title='' repo='' routed='' id
  local folds='' new_ground=0 fresh=0
  local decision decision_digest routed_csv body show state kind existing_title dep blocked
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --door) shift; door=${1:-} ;;
      --decision-file) shift; decision_file=${1:-} ;;
      --title) shift; title=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      --supersedes) shift; validate_slug superseded-id "${1:-}"; folds="${folds}${folds:+ }${1:-}" ;;
      --new-ground) new_ground=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  # --door is required and closed-vocabulary because the point of this command is
  # that the store can be asked which entrances it is actually covering. A door
  # recorded as "whatever the caller typed" answers that question with noise.
  case "$door" in
    hold|ask-user|chat) : ;;
    '') fail "--door is required: hold, ask-user, or chat" ;;
    *) fail "--door must be hold, ask-user, or chat: $door" ;;
  esac
  decision=$(read_decision_file "$decision_file")
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  if [ -n "$routed" ]; then
    routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  else
    routed_csv=none
  fi
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")

  # Already recorded with these exact words and routes: say so and change nothing.
  # Re-running after a partial close is the same call, which is what makes an
  # interrupted close safe to simply repeat.
  if verify_hold_resolved "$id"; then
    verify_resolution_retry_identity "$id" "$decision_digest" "$routed_csv"
    verify_stored_decision "$id" "$decision" "$decision_digest"
    # shellcheck disable=SC2086  # $folds is a deliberate space-separated id list
    [ -z "$folds" ] || fold_records "$id" "answered by the captain decision recorded in $id" $folds
    printf 'recorded: %s (already durable)\n' "$id"
    return 0
  fi

  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$state" != "done" ] \
      || fail "captain decision $id is already closed without a decision record; repair that entry or use a new decision key"
    [ -z "$title" ] || [ "$existing_title" = "$title" ] \
      || fail "existing captain item $id has a different title"
  else
    if archived_hold_resolution_exists "$id"; then
      fail "captain decision $id is already durably resolved in $ARCHIVE; use a new decision key for a new decision"
    fi
    # An unregistered door has no hold to inherit a title from, so the caller
    # supplies the question the captain answered.
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    # `hold` requires the origin to be work this home owns, because a hold is a
    # question about that work. A decision the captain gave in this session belongs
    # to this home by construction even when it names no local task, so `record`
    # accepts an unknown origin and asks for the repository instead of refusing.
    if [ -z "$repo" ]; then
      origin_exists_here "$origin" \
        || fail "origin $origin is not work this home owns; pass --repo to record a decision that names no local task"
      repo=firstmate
    fi
    validate_one_line repo "$repo"
    # The gate applies to an ANSWER too, and that is not a technicality: on
    # 2026-08-17 a seat carried two open records for a question the captain had
    # already ruled on hours earlier, with the fix in an open pull request. An
    # answer that cannot fold the questions it settles leaves them standing.
    require_disposition "$id" "$repo" "$folds" "$new_ground"
    fresh=1
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" \
      --body "$(printf 'Origin: %s\nDecision key: %s\nState: recording captain decision.' "$origin" "$key")" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  : "$fresh"

  for dep in $routed; do
    task_show "$dep" >/dev/null || fail "routed task $dep does not exist in the active home"
  done

  # Body first, then edges, then Done. See the ordering note in this file's header:
  # an interruption anywhere in these three steps must leave a record that reads as
  # unfinished, and this is the order that guarantees it.
  # shellcheck disable=SC2086  # $routed is a deliberate space-separated id list
  body=$(build_resolution_body "$decision_digest" "$routed_csv" "$door" "$decision" $routed)
  write_body "$id" "$body" || fail "could not record the captain decision on $id"
  verify_stored_decision "$id" "$decision" "$decision_digest"
  for dep in $routed; do
    blocked=$(show_field "$(task_show "$dep")" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close recorded captain decision $id"
  verify_hold_resolved "$id" || fail "captain decision $id did not retain its durable record"
  verify_stored_decision "$id" "$decision" "$decision_digest"
  # Folded last, and only once this record is durable, so a failure anywhere above
  # leaves the earlier questions standing rather than folded into nothing.
  # shellcheck disable=SC2086  # $folds is a deliberate space-separated id list
  [ -z "$folds" ] || fold_records "$id" "answered by the captain decision recorded in $id" $folds
  printf 'recorded: %s (door=%s routed=%s%s)\n' "$id" "$door" "$routed_csv" \
    "$(if [ -n "$folds" ]; then printf ' folded=%s' "$(printf '%s' "$folds" | tr ' ' ',')"; fi)"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  record) shift; command_record "$@" ;;
  supersede) shift; command_supersede "$@" ;;
  recheck) shift; command_recheck "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
