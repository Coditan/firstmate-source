#!/usr/bin/env bash
# Behavior tests for the expected-plugin-skill lock and check.
#
# The subject detects and reports; it installs nothing. So every harness call is
# replaced by a fake `claude` that answers `plugin list --json` from a file the
# test writes, and answers NOTHING else: any other subcommand is recorded and
# refused, so a subject that ever tried to change this seat fails the suite
# loudly instead of passing quietly. The list answer is shaped like the real
# command measured on 2026-09-07 - an array of objects carrying id, version and
# enabled - because a tidied fixture would pass while the real parse failed.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one that must see the mechanism run.
export FM_SKILLS_LOCK_DISABLE=0

fm_test_tmproot TMP_ROOT fm-skills-lock-tests

SUBJECT="$ROOT/bin/fm-skills-lock.sh"

# A home with its own state, its own manifest, and a fake `claude` on PATH whose
# installed set lives in $home/installed.json.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/bin" "$home/tmp"
  cat > "$home/bin/claude" <<'SH'
#!/usr/bin/env bash
# Fake harness. FAKE_CLAUDE_STORE names the installed-set file. Reading the
# plugin list is the ONLY thing this seat allows: everything else is written to
# FAKE_CLAUDE_UNEXPECTED_LOG and refused, so a subject that reaches for install,
# enable, or a marketplace leaves evidence the suite asserts on.
set -u
store=${FAKE_CLAUDE_STORE:?}
case "${1:-} ${2:-}" in
  "plugin list")
    [ "${FAKE_CLAUDE_LIST_SLEEP:-0}" = 0 ] || sleep "$FAKE_CLAUDE_LIST_SLEEP"
    [ "${FAKE_CLAUDE_LIST_RC:-0}" = 0 ] || exit "$FAKE_CLAUDE_LIST_RC"
    [ "${FAKE_CLAUDE_LIST_GARBAGE:-0}" = 0 ] || { printf 'not json at all\n'; exit 0; }
    cat "$store"
    ;;
  *)
    printf '%s\n' "$*" >> "${FAKE_CLAUDE_UNEXPECTED_LOG:-/dev/null}"
    exit 64
    ;;
esac
SH
  chmod +x "$home/bin/claude"
  printf '[]\n' > "$home/installed.json"
  printf '%s\n' "$home"
}

# The subject may never run a harness command other than the list read.
assert_no_harness_change() {  # <home> <why>
  [ ! -f "$1/unexpected-claude.log" ] || \
    fail "$2: the subject invoked the harness beyond reading the list: $(cat "$1/unexpected-claude.log")"
}

write_lock() {  # <path> <version>
  cat > "$1" <<LOCK
{
  "version": 1,
  "skills": {},
  "plugins": {
    "demo-skills@demo-market": {
      "source": "someone/demo-skills",
      "sourceType": "github",
      "marketplace": "someone/demo-market",
      "version": "$2",
      "versionBasis": "fixture",
      "pinnedOn": "2026-09-07"
    }
  }
}
LOCK
}

installed_with() {  # <path> <id> <version> <enabled>
  cat > "$1" <<JSON
[
  {"id": "$2", "version": "$3", "scope": "user", "enabled": $4,
   "installPath": "/nowhere/$3"}
]
JSON
}

run_subject() {  # <home> <mode...>
  local home=$1
  shift
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_SKILLS_LOCK_FILE="$home/skills-lock.json" \
  FAKE_CLAUDE_STORE="$home/installed.json" \
  FAKE_CLAUDE_UNEXPECTED_LOG="$home/unexpected-claude.log" \
  TMPDIR="$home/tmp" \
  PATH="$home/bin:$PATH" \
    "${SUBJECT_OVERRIDE:-$SUBJECT}" "$@" 2>&1
}

# The subject's scratch file lives in this home's own TMPDIR, so a leak is
# observable rather than lost among a shared /tmp.
assert_no_scratch_left() {  # <home> <why>
  local left
  left=$(find "$1/tmp" -maxdepth 1 -name 'fm-skills-lock.*' 2>/dev/null)
  [ -z "$left" ] || fail "$2: the subject left scratch files behind: $left"
}

command -v jq >/dev/null 2>&1 || { pass "fm-skills-lock: skipped, jq is required by the fixture harness"; exit 0; }

# --- a satisfied seat is silent ---------------------------------------------

HOME_OK=$(make_home satisfied)
write_lock "$HOME_OK/skills-lock.json" 1.2.3
installed_with "$HOME_OK/installed.json" demo-skills@demo-market 1.2.3 true
out=$(run_subject "$HOME_OK")
[ -z "$out" ] || fail "a seat carrying the expected set must print nothing, got: $out"
pass "fm-skills-lock: a seat with the expected set installed reports nothing"

out=$(run_subject "$HOME_OK" --status)
assert_contains "$out" "state=ok" "the status listing must still show the satisfied reading"

# --- a short seat is reported, and the report names the seat and the command --
#
# THE NEGATIVE CONTROL. The check must be observed producing this line, not
# assumed to: a check that cannot go red is a check whose silence means nothing.
HOME_SHORT=$(make_home short)
write_lock "$HOME_SHORT/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_SHORT/installed.json"
out=$(run_subject "$HOME_SHORT")
assert_contains "$out" "SKILLS_LOCK:" "a seat short of an expected plugin skill must report it"
assert_contains "$out" "demo-skills@demo-market" "the report must name the missing skill"
assert_contains "$out" "$HOME_SHORT" "the report must name the seat, not only the skill"
assert_contains "$out" "claude plugin marketplace add someone/demo-market" \
  "the report must name the marketplace command an operator would run"
assert_contains "$out" "claude plugin install demo-skills@demo-market" \
  "the report must name the install command an operator would run"
assert_no_harness_change "$HOME_SHORT" "a short seat is reported, never repaired"
pass "fm-skills-lock: a short seat is reported by seat and by skill, and the line carries the command"

# --- running twice reports the same thing and changes nothing ----------------
#
# There is no install to be idempotent about; what must hold is that this is a
# pure reader. Two runs against an unchanged seat answer identically, leave the
# seat's installed set byte-identical, write no state, and never call the
# harness for anything but the list.
HOME_TWICE=$(make_home twice)
write_lock "$HOME_TWICE/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_TWICE/installed.json"
before_set=$(cat "$HOME_TWICE/installed.json")
first=$(run_subject "$HOME_TWICE")
second=$(run_subject "$HOME_TWICE")
[ -n "$first" ] || fail "the first run must report the short seat, got nothing"
[ "$first" = "$second" ] || fail "two runs must report the same thing, got:
$first
---
$second"
[ "$before_set" = "$(cat "$HOME_TWICE/installed.json")" ] \
  || fail "running the check must leave this seat's installed set byte-identical"
[ -z "$(ls -A "$HOME_TWICE/state" 2>/dev/null)" ] \
  || fail "the check must write no state, found: $(ls -A "$HOME_TWICE/state")"
assert_no_harness_change "$HOME_TWICE" "running twice"
pass "fm-skills-lock: running twice reports the same thing and changes nothing"

# --- cannot tell is never silent, and never a value --------------------------

HOME_BLIND=$(make_home unreadable)
write_lock "$HOME_BLIND/skills-lock.json" 1.2.3
out=$(FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_BLIND")
assert_contains "$out" "could not be established" \
  "a seat whose plugin list cannot be read must say so rather than report it as missing"
assert_not_contains "$out" "does not have" \
  "an unreadable list must never be rendered as a missing plugin"
assert_no_harness_change "$HOME_BLIND" "an unreadable list"

out=$(FAKE_CLAUDE_LIST_GARBAGE=1 run_subject "$HOME_BLIND")
assert_contains "$out" "shape this check does not know" \
  "a plugin list that does not parse must be reported as unmeasured"
pass "fm-skills-lock: a reading that could not be taken is never rendered as a value"

# --- a list read that outlasts the ceiling is unmeasured, never silence -------
#
# The daily round wraps this whole script in its own 12s ceiling, so this
# script's ceiling must fire first: a seat whose plugin list hangs has to be
# reported here, by seat and by id, rather than killed from outside and reduced
# to one generic line for the whole check.
assert_slow_list_is_unmeasured() {  # <home> <why> [env assignments applied by caller]
  local home=$1 why=$2 out=$3
  assert_contains "$out" "could not be established" \
    "$why: a plugin list that outlasts the ceiling must be reported as unmeasured"
  assert_contains "$out" "demo-skills@demo-market" \
    "$why: a timed-out reading must still name the id it could not establish"
  assert_contains "$out" "$home" \
    "$why: a timed-out reading must still name the seat"
  assert_contains "$out" "it may have exceeded 1s" \
    "$why: a timed-out reading must name the ceiling it exceeded, so a reader can act on it"
  assert_not_contains "$out" "does not have" \
    "$why: a timed-out reading must never be rendered as a missing plugin"
  assert_no_scratch_left "$home" "$why"
}

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
  || command -v perl >/dev/null 2>&1; then
  HOME_SLOW=$(make_home slow-list)
  write_lock "$HOME_SLOW/skills-lock.json" 1.2.3
  installed_with "$HOME_SLOW/installed.json" demo-skills@demo-market 1.2.3 true
  out=$(FAKE_CLAUDE_LIST_SLEEP=5 FM_SKILLS_LOCK_TIMEOUT=1 run_subject "$HOME_SLOW")
  assert_slow_list_is_unmeasured "$HOME_SLOW" "the ordinary rung" "$out"
  pass "fm-skills-lock: a plugin list that outlasts the ceiling is reported as unmeasured by seat and id"
else
  pass "fm-skills-lock: skipped the ceiling case, this seat has no timeout, gtimeout or perl to bound with"
fi

# --- and the ceiling still holds on a seat with no timeout binary ------------
#
# A two-branch timeout/gtimeout form falls back to running the command BARE,
# which is unbounded on exactly the seat the fallback exists for, and nothing
# upstream bounds it either: the round wraps this script in the same shape.
# FM_CHECK_FORCE_FALLBACK=1 makes bin/fm-bounded-lib.sh take its last rung, so
# this drives that seat class rather than reasoning about it.
if command -v perl >/dev/null 2>&1; then
  HOME_FB=$(make_home slow-list-fallback)
  write_lock "$HOME_FB/skills-lock.json" 1.2.3
  installed_with "$HOME_FB/installed.json" demo-skills@demo-market 1.2.3 true
  out=$(FM_CHECK_FORCE_FALLBACK=1 FAKE_CLAUDE_LIST_SLEEP=5 FM_SKILLS_LOCK_TIMEOUT=1 \
    run_subject "$HOME_FB")
  assert_slow_list_is_unmeasured "$HOME_FB" "the fallback rung" "$out"
  pass "fm-skills-lock: the ceiling holds on a seat with neither timeout nor gtimeout"
else
  pass "fm-skills-lock: skipped the fallback-rung case, no perl on this seat"
fi

HOME_NOCLAUDE=$(make_home no-harness)
write_lock "$HOME_NOCLAUDE/skills-lock.json" 1.2.3
out=$(FM_HOME="$HOME_NOCLAUDE" FM_STATE_OVERRIDE="$HOME_NOCLAUDE/state" \
  FM_SKILLS_LOCK_FILE="$HOME_NOCLAUDE/skills-lock.json" \
  PATH="/usr/bin:/bin" "$SUBJECT" --status 2>&1)
assert_contains "$out" "state=skipped" \
  "a seat with no harness has no plugin mechanism and must be skipped, not faulted"
pass "fm-skills-lock: a seat with no harness is skipped by name"

# --- a differing version is reported and never changed -----------------------

HOME_VER=$(make_home version)
write_lock "$HOME_VER/skills-lock.json" 1.2.3
installed_with "$HOME_VER/installed.json" demo-skills@demo-market 9.9.9 true
out=$(run_subject "$HOME_VER")
assert_contains "$out" "9.9.9" "a differing version must be reported"
assert_contains "$out" "1.2.3" "the report must name the version the fleet records"
assert_no_harness_change "$HOME_VER" "a differing version"
pass "fm-skills-lock: a differing version is reported and left alone"

# --- disabled is reported, with the command that restores it -----------------

HOME_DIS=$(make_home disabled)
write_lock "$HOME_DIS/skills-lock.json" 1.2.3
installed_with "$HOME_DIS/installed.json" demo-skills@demo-market 1.2.3 false
out=$(run_subject "$HOME_DIS")
assert_contains "$out" "disabled" "an installed but disabled plugin skill must be reported"
assert_contains "$out" "claude plugin enable demo-skills@demo-market" \
  "the report must name the command that restores a disabled plugin skill"
assert_no_harness_change "$HOME_DIS" "a disabled plugin skill"
pass "fm-skills-lock: an installed but disabled plugin skill is reported with its command"

# --- an unreadable manifest is never an empty expected set --------------------
#
# Two DIFFERENT failure modes, each asserted on its own cause text rather than
# on the shared prefix. The reason is composed inside a command substitution, so
# a prefix-only assertion passes while the cause reaches the report blank, and
# every manifest failure becomes one indistinguishable reading. These two
# assertions are what makes that regression visible.
HOME_BADLOCK=$(make_home bad-manifest)
printf '{ not json\n' > "$HOME_BADLOCK/skills-lock.json"
out=$(run_subject "$HOME_BADLOCK")
assert_contains "$out" "could not be read" \
  "a manifest that cannot be decoded must be reported, never read as nothing to do"
assert_contains "$out" "$HOME_BADLOCK/skills-lock.json could not be decoded" \
  "an undecodable manifest must name decoding as the cause, not ship the reason blank"
assert_not_contains "$out" "does not exist" \
  "an undecodable manifest must not be reported as an absent one"

HOME_NOLOCK=$(make_home absent-manifest)
rm -f "$HOME_NOLOCK/skills-lock.json"
out=$(run_subject "$HOME_NOLOCK")
assert_contains "$out" "could not be read" \
  "a manifest that is not there must be reported, never read as nothing to do"
assert_contains "$out" "$HOME_NOLOCK/skills-lock.json does not exist" \
  "an absent manifest must name absence as the cause, not ship the reason blank"
assert_not_contains "$out" "could not be decoded" \
  "an absent manifest must not be reported as an undecodable one"
pass "fm-skills-lock: each manifest failure is reported with its own cause, not a shared prefix"

# --- a dropped plugins key is a different fact from an empty one --------------
#
# skills-lock.json is written by the `npx skills` installer, so a run of it can
# drop the top-level key that installer does not recognise. An expected set that
# silently becomes empty is the failure this whole three-state design refuses,
# so the two shapes must read differently to a person running the check.
HOME_EMPTY=$(make_home empty-plugins)
cat > "$HOME_EMPTY/skills-lock.json" <<'JSON'
{ "version": 1, "skills": {}, "plugins": {} }
JSON
out=$(run_subject "$HOME_EMPTY")
[ -z "$out" ] || fail "a manifest that locks no plugin skills must report nothing, got: $out"
status_empty=$(run_subject "$HOME_EMPTY" --status)
assert_contains "$status_empty" "no plugin skills are locked" \
  "an explicitly empty plugins object means this home locks nothing, and --status must say so"

HOME_DROPPED=$(make_home dropped-plugins)
cat > "$HOME_DROPPED/skills-lock.json" <<'JSON'
{ "version": 1, "skills": {} }
JSON
out=$(run_subject "$HOME_DROPPED")
assert_contains "$out" "no \"plugins\" key" \
  "a manifest with no plugins key must be reported, never read as nothing to do"
assert_contains "$out" "unknown rather than empty" \
  "a dropped key must say the expected set is unknown, not that the fleet locks nothing"
status_dropped=$(run_subject "$HOME_DROPPED" --status)
assert_contains "$status_dropped" "state=unmeasured" \
  "--status must show a dropped plugins key as unmeasured"
assert_not_contains "$status_dropped" "no plugin skills are locked" \
  "a dropped key must not render as the fleet deliberately locking nothing"
[ "$status_empty" != "$status_dropped" ] \
  || fail "an empty plugins object and an absent one must not read identically"
pass "fm-skills-lock: an absent plugins key reads as unmeasured, an empty one as nothing locked"

# --- this repository's own tracked manifest still carries its expected set ----
#
# The contract here is skills-lock.json itself: a tracked, machine-consumed
# manifest this repository owns the plugins half of. It is parsed rather than
# grepped. If an installer run ever drops the key, this fails loudly instead of
# quietly emptying what the fleet expects of every seat.
plugin_count=$(jq -r '(.plugins // {}) | if type == "object" then length else -1 end' "$ROOT/skills-lock.json")
[ "$plugin_count" -gt 0 ] 2>/dev/null \
  || fail "this repository's skills-lock.json must carry a non-empty plugins object, got count=$plugin_count"
while IFS=$'\t' read -r id marketplace version; do
  [ -n "$id" ] || fail "a locked plugin entry must have an id"
  [ -n "$marketplace" ] || fail "locked plugin $id must name the marketplace it comes from"
  [ -n "$version" ] || fail "locked plugin $id must record the version the fleet chose"
done < <(jq -r '.plugins | to_entries[] | [.key, (.value.marketplace // ""), (.value.version // "")] | @tsv' "$ROOT/skills-lock.json")
pass "fm-skills-lock: the tracked manifest still names what every seat is expected to carry"

# --- the real manifest decodes, and the fleet pin states its basis ------------

out=$(FM_SKILLS_LOCK_FILE="$ROOT/skills-lock.json" \
  FM_HOME="$TMP_ROOT/real" FM_STATE_OVERRIDE="$TMP_ROOT/real/state" \
  PATH="/usr/bin:/bin" "$SUBJECT" --status 2>&1)
assert_not_contains "$out" "could not be read" \
  "this repository's own manifest must decode"
basis=$(jq -r '.plugins[] | .versionBasis // ""' "$ROOT/skills-lock.json")
[ -n "$basis" ] || fail "every locked plugin must record the basis of its pinned version"
pass "fm-skills-lock: this repository's manifest decodes and every pin states its basis"

# --- the negative controls: both failure modes observed failing ---------------
#
# WHY THESE ARE HERE RATHER THAN IN A ONE-OFF RUN SOMEONE DID ONCE. Every claim
# this change makes rests on the check reporting when a seat is short, and a
# check nobody has watched fail is worth nothing. So each control is a MUTANT:
# it breaks the subject in the exact way that would make its silence a lie, runs
# the same fixture, and asserts the finding disappears. A later edit that makes
# the check unable to go red fails here, instead of leaving a seat quietly
# unreported.
#
# The assertions are made against what the mutant STOPS saying and what it starts
# saying instead, never against a substring the healthy output already contains.
# A control that plants the one shape the pattern already matched passes without
# measuring anything, which is the failure this fleet has been caught by before.

# mutant <name> <old-TAB-new>...: a copy of the subject with each replacement
# applied, at its own path. It fails loudly when a replacement does not match, so
# a mutant cannot silently degrade into an unmodified copy - which would satisfy
# every precondition below for entirely the wrong reason.
mutant() {
  local name=$1 dir
  shift
  dir="$TMP_ROOT/mutant-$name"
  mkdir -p "$dir"
  cp "$SUBJECT" "$dir/fm-skills-lock.sh"
  chmod +x "$dir/fm-skills-lock.sh"
  # The subject sources the shared deadline ladder from beside itself, so a
  # mutant at its own path needs it there too.
  ln -sf "$ROOT/bin/fm-bounded-lib.sh" "$dir/fm-bounded-lib.sh"
  # The substitution is pure bash. These two controls are the evidence the whole
  # change rests on, so they must not go missing on a seat that happens to lack
  # an interpreter the subject itself never needs. Quoting the needle inside the
  # expansions makes it a literal rather than a glob.
  local source pair old new prefix
  source=$(cat "$dir/fm-skills-lock.sh")
  for pair in "$@"; do
    old=${pair%%$'\t'*}
    new=${pair#*$'\t'}
    prefix=${source%%"$old"*}
    [ "$prefix" != "$source" ] || fail "mutant $name: a replacement did not match the subject"
    source=$prefix$new${source#*"$old"}
  done
  printf '%s\n' "$source" > "$dir/fm-skills-lock.sh"
  printf '%s\n' "$dir/fm-skills-lock.sh"
}

# `fail` inside the command substitution above exits only that subshell, so the
# caller must confirm it actually got a mutant. Without this, a stale mutation
# falls back to the unmodified subject, and the control still goes red but blames
# the wrong thing.
require_mutant() {
  [ -n "$1" ] && [ -x "$1" ] || fail "$2: the mutant was not produced, so this control measured nothing"
}

# CONTROL 1: a seat that IS short of an expected plugin skill.
# The mutant classifies a missing plugin as ok, which is what a check that
# cannot tell absence from health would do.
HOME_NC1=$(make_home control-missing)
write_lock "$HOME_NC1/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_NC1/installed.json"

healthy=$(run_subject "$HOME_NC1")
assert_contains "$healthy" "SKILLS_LOCK:" \
  "control 1 precondition: the healthy subject must report the short seat"

# shellcheck disable=SC2016 # The subject's own source is the literal here; nothing may expand.
MUTANT1=$(mutant missing-reads-ok \
  "$(printf 'READINGS+=("$id|missing|$SEAT does not have\tREADINGS+=("$id|ok|$SEAT does not have')")
require_mutant "$MUTANT1" "control 1"
broken=$(SUBJECT_OVERRIDE="$MUTANT1" run_subject "$HOME_NC1")
assert_not_contains "$broken" "SKILLS_LOCK:" \
  "control 1: the mutant must go silent, or this control is not measuring the reporting path"
[ "$healthy" != "$broken" ] \
  || fail "control 1: healthy and mutant output are identical, so nothing was measured"
pass "fm-skills-lock: negative control - a short seat goes unreported the moment the check stops classifying it"

# CONTROL 2: a seat whose plugin list cannot be read.
# The mutant drops the unmeasured state, so an unreadable list falls through to
# the record lookup, finds nothing, and is reported as a missing plugin. That is
# the specific lie the third state exists to refuse, and the mutant is made to
# commit it: it goes on to tell an operator to install against a reading it
# never took.
HOME_NC2=$(make_home control-unmeasured)
write_lock "$HOME_NC2/skills-lock.json" 1.2.3
installed_with "$HOME_NC2/installed.json" demo-skills@demo-market 1.2.3 true

healthy=$(FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_NC2")
assert_contains "$healthy" "could not be established" \
  "control 2 precondition: the healthy subject must report an unreadable list as unmeasured"
assert_not_contains "$healthy" "does not have" \
  "control 2 precondition: the healthy subject must not call an unreadable list a missing plugin"
assert_not_contains "$healthy" "claude plugin install" \
  "control 2 precondition: the healthy subject must not prescribe an install against a reading it never took"

# shellcheck disable=SC2016 # The subject's own source is the literal here; nothing may expand.
MUTANT2=$(mutant unreadable-reads-empty "$(printf '      error)
        READINGS+=("$id|unmeasured|whether $SEAT carries $id could not be established: $INSTALLED_ERROR")
        continue
        ;;\t      error)
        ;;')")
require_mutant "$MUTANT2" "control 2"
broken=$(SUBJECT_OVERRIDE="$MUTANT2" FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_NC2")
assert_contains "$broken" "does not have" \
  "control 2: the mutant must report the unreadable seat as missing, or this control is not measuring the unmeasured path"
assert_not_contains "$broken" "could not be established" \
  "control 2: the mutant must lose the unmeasured wording"
assert_contains "$broken" "claude plugin install demo-skills@demo-market" \
  "control 2: the mutant must start prescribing an install against a reading it never took - that is the harm this state prevents"
pass "fm-skills-lock: negative control - an unreadable plugin list becomes a false missing the moment the third state is removed"
