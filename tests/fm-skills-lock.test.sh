#!/usr/bin/env bash
# Behavior tests for the expected-plugin-skill lock, install, and check.
#
# Every harness call is replaced by a fake `claude` whose installed set is a
# file the test writes, so nothing here reaches a marketplace and nothing
# touches this seat's real plugins. The fake is shaped like the real command
# that was measured on 2026-09-07: `plugin list --json` prints an array of
# objects carrying id, version and enabled, and `plugin install` appends to that
# set. A tidied fixture would pass while the real parse failed.
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
  mkdir -p "$home/state" "$home/bin"
  cat > "$home/bin/claude" <<'SH'
#!/usr/bin/env bash
# Fake harness. FAKE_CLAUDE_STORE names the installed-set file.
set -u
store=${FAKE_CLAUDE_STORE:?}
case "${1:-} ${2:-}" in
  "plugin list")
    [ "${FAKE_CLAUDE_LIST_RC:-0}" = 0 ] || exit "$FAKE_CLAUDE_LIST_RC"
    [ "${FAKE_CLAUDE_LIST_GARBAGE:-0}" = 0 ] || { printf 'not json at all\n'; exit 0; }
    cat "$store"
    ;;
  "plugin marketplace")
    exit 0
    ;;
  "plugin install")
    id=$3
    [ "${FAKE_CLAUDE_INSTALL_RC:-0}" = 0 ] || exit "$FAKE_CLAUDE_INSTALL_RC"
    printf '%s\n' "$id" >> "${FAKE_CLAUDE_INSTALL_LOG:-/dev/null}"
    tmp=$(mktemp)
    jq --arg id "$id" --arg v "${FAKE_CLAUDE_INSTALL_VERSION:-1.2.3}" \
      '. + [{id: $id, version: $v, scope: "user", enabled: true}]' "$store" > "$tmp"
    mv "$tmp" "$store"
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$home/bin/claude"
  printf '[]\n' > "$home/installed.json"
  printf '%s\n' "$home"
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
  FAKE_CLAUDE_INSTALL_LOG="$home/install.log" \
  PATH="$home/bin:$PATH" \
    "${SUBJECT_OVERRIDE:-$SUBJECT}" "$@" 2>&1
}

command -v jq >/dev/null 2>&1 || { pass "fm-skills-lock: skipped, jq is required by the fixture harness"; exit 0; }

# --- a satisfied seat is silent ---------------------------------------------

HOME_OK=$(make_home satisfied)
write_lock "$HOME_OK/skills-lock.json" 1.2.3
installed_with "$HOME_OK/installed.json" demo-skills@demo-market 1.2.3 true
out=$(run_subject "$HOME_OK" --force)
[ -z "$out" ] || fail "a seat carrying the expected set must print nothing, got: $out"
pass "fm-skills-lock: a seat with the expected set installed reports nothing"

out=$(run_subject "$HOME_OK" --status)
assert_contains "$out" "state=ok" "the status listing must still show the satisfied reading"

# --- a short seat is reported, and the report names the seat -----------------
#
# THE NEGATIVE CONTROL. The check must be observed producing this line, not
# assumed to: a check that cannot go red is a check whose silence means nothing.
# It runs against a manifest whose entry is absent from the installed set and a
# harness whose install fails, so the missing case survives convergence and
# reaches the report.
HOME_SHORT=$(make_home short)
write_lock "$HOME_SHORT/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_SHORT/installed.json"
out=$(FAKE_CLAUDE_INSTALL_RC=1 run_subject "$HOME_SHORT" --force)
assert_contains "$out" "SKILLS_LOCK:" "a seat short of an expected plugin skill must report it"
assert_contains "$out" "demo-skills@demo-market" "the report must name the missing skill"
assert_contains "$out" "$HOME_SHORT" "the report must name the seat, not only the skill"
pass "fm-skills-lock: a short seat is reported by seat and by skill"

# --- installing what is missing, and doing it twice --------------------------

HOME_CONV=$(make_home converge)
write_lock "$HOME_CONV/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_CONV/installed.json"
out=$(run_subject "$HOME_CONV" --force)
[ -z "$out" ] || fail "a successful convergence must report nothing, got: $out"
assert_grep 'demo-skills@demo-market' "$HOME_CONV/install.log" \
  "the first run must install the missing plugin skill"
first_set=$(cat "$HOME_CONV/installed.json")
first_installs=$(wc -l < "$HOME_CONV/install.log")

out=$(run_subject "$HOME_CONV" --force)
[ -z "$out" ] || fail "the second run must report nothing, got: $out"
second_installs=$(wc -l < "$HOME_CONV/install.log")
[ "$first_installs" = "$second_installs" ] \
  || fail "the second run must attempt no install (attempts went $first_installs -> $second_installs)"
[ "$first_set" = "$(cat "$HOME_CONV/installed.json")" ] \
  || fail "the second run must leave the installed set byte-identical"
pass "fm-skills-lock: installing twice changes nothing the second time"

# --- the cadence gate --------------------------------------------------------

HOME_CAD=$(make_home cadence)
write_lock "$HOME_CAD/skills-lock.json" 1.2.3
printf '[]\n' > "$HOME_CAD/installed.json"
printf '%s\n' "$(date +%s)" > "$HOME_CAD/state/skills-lock.checked"
out=$(FAKE_CLAUDE_INSTALL_RC=1 run_subject "$HOME_CAD")
[ -z "$out" ] || fail "a run inside the cadence window must do nothing, got: $out"
[ ! -f "$HOME_CAD/install.log" ] || fail "a run inside the cadence window must attempt no install"
pass "fm-skills-lock: the cadence gate holds without --force"

# --- cannot tell is never installed, and never silent ------------------------

HOME_BLIND=$(make_home unreadable)
write_lock "$HOME_BLIND/skills-lock.json" 1.2.3
out=$(FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_BLIND" --force)
assert_contains "$out" "could not be established" \
  "a seat whose plugin list cannot be read must say so rather than report it as missing"
assert_not_contains "$out" "does not have" \
  "an unreadable list must never be rendered as a missing plugin"
[ ! -f "$HOME_BLIND/install.log" ] || fail "an unreadable list must never trigger an install"

out=$(FAKE_CLAUDE_LIST_GARBAGE=1 run_subject "$HOME_BLIND" --force)
assert_contains "$out" "shape this check does not know" \
  "a plugin list that does not parse must be reported as unmeasured"
pass "fm-skills-lock: a reading that could not be taken is never rendered as a value"

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
out=$(run_subject "$HOME_VER" --force)
assert_contains "$out" "9.9.9" "a differing version must be reported"
assert_contains "$out" "1.2.3" "the report must name the version the fleet records"
[ ! -f "$HOME_VER/install.log" ] || fail "a differing version must never be changed automatically"
pass "fm-skills-lock: a differing version is reported and left alone"

# --- disabled is not installed ------------------------------------------------

HOME_DIS=$(make_home disabled)
write_lock "$HOME_DIS/skills-lock.json" 1.2.3
installed_with "$HOME_DIS/installed.json" demo-skills@demo-market 1.2.3 false
out=$(run_subject "$HOME_DIS" --force)
assert_contains "$out" "disabled" "an installed but disabled plugin skill must be reported"
pass "fm-skills-lock: an installed but disabled plugin skill is reported"

# --- an unreadable manifest is never an empty expected set --------------------

HOME_BADLOCK=$(make_home bad-manifest)
printf '{ not json\n' > "$HOME_BADLOCK/skills-lock.json"
out=$(run_subject "$HOME_BADLOCK" --force)
assert_contains "$out" "could not be read" \
  "a manifest that cannot be decoded must be reported, never read as nothing to do"
pass "fm-skills-lock: an undecodable manifest is reported rather than read as an empty set"

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
  python3 - "$dir/fm-skills-lock.sh" "$@" <<'PY' || fail "mutant $name: a replacement did not match the subject"
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
for pair in sys.argv[2:]:
    old, new = pair.split("\t", 1)
    if old not in source:
        raise SystemExit("no match for: " + old)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PY
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

healthy=$(FAKE_CLAUDE_INSTALL_RC=1 run_subject "$HOME_NC1" --force)
assert_contains "$healthy" "SKILLS_LOCK:" \
  "control 1 precondition: the healthy subject must report the short seat"

printf '[]\n' > "$HOME_NC1/installed.json"
rm -f "$HOME_NC1/state/skills-lock.checked" "$HOME_NC1/install.log"
MUTANT1=$(mutant missing-reads-ok \
  "$(printf 'READINGS+=("$id|missing|$SEAT does not have\tREADINGS+=("$id|ok|$SEAT does not have')")
require_mutant "$MUTANT1" "control 1"
broken=$(SUBJECT_OVERRIDE="$MUTANT1" FAKE_CLAUDE_INSTALL_RC=1 run_subject "$HOME_NC1" --force)
assert_not_contains "$broken" "SKILLS_LOCK:" \
  "control 1: the mutant must go silent, or this control is not measuring the reporting path"
[ "$healthy" != "$broken" ] \
  || fail "control 1: healthy and mutant output are identical, so nothing was measured"
pass "fm-skills-lock: negative control - a short seat goes unreported the moment the check stops classifying it"

# CONTROL 2: a seat whose plugin list cannot be read.
# The mutant drops the unmeasured state, so an unreadable list falls through to
# the record lookup, finds nothing, and is reported as a missing plugin. That is
# the specific lie the third state exists to refuse, and the mutant is made to
# commit it: it goes on to install against a reading it never took.
HOME_NC2=$(make_home control-unmeasured)
write_lock "$HOME_NC2/skills-lock.json" 1.2.3
installed_with "$HOME_NC2/installed.json" demo-skills@demo-market 1.2.3 true

healthy=$(FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_NC2" --force)
assert_contains "$healthy" "could not be established" \
  "control 2 precondition: the healthy subject must report an unreadable list as unmeasured"
assert_not_contains "$healthy" "does not have" \
  "control 2 precondition: the healthy subject must not call an unreadable list a missing plugin"
[ ! -f "$HOME_NC2/install.log" ] \
  || fail "control 2 precondition: the healthy subject must not install against an unreadable list"

rm -f "$HOME_NC2/state/skills-lock.checked"
MUTANT2=$(mutant unreadable-reads-empty "$(printf '      error)
        READINGS+=("$id|unmeasured|whether $SEAT carries $id could not be established: $INSTALLED_ERROR")
        continue
        ;;\t      error)
        ;;')")
require_mutant "$MUTANT2" "control 2"
broken=$(SUBJECT_OVERRIDE="$MUTANT2" FAKE_CLAUDE_LIST_RC=3 run_subject "$HOME_NC2" --force)
assert_contains "$broken" "does not have" \
  "control 2: the mutant must report the unreadable seat as missing, or this control is not measuring the unmeasured path"
assert_not_contains "$broken" "could not be established" \
  "control 2: the mutant must lose the unmeasured wording"
assert_grep 'demo-skills@demo-market' "$HOME_NC2/install.log" \
  "control 2: the mutant must install against a reading it never took - that is the harm this state prevents"
pass "fm-skills-lock: negative control - an unreadable plugin list becomes a false missing the moment the third state is removed"
