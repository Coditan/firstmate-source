#!/usr/bin/env bash
# Report whether this seat carries the third-party plugin skills the fleet
# expects, and make a seat that is short of one visible without anyone
# remembering to look.
#
# WHAT THIS IS FOR
# Skills under .agents/skills/ reach every vessel on their own: they are
# vendored material carried by the fleet pin. Third-party plugin skills do not.
# They are installed per seat by the harness, they live outside every repository
# this fleet controls, and until this script existed nothing recorded that a
# seat was supposed to have one, nothing checked whether it did, and a seat
# missing one lost the skills that depend on it silently - AGENTS.md's
# codebase-sweep, design-it-twice and scout-research all reach for
# mattpocock-skills, and on a seat without it they simply find nothing.
#
# It is deliberately a mechanism and not an instruction. A rule saying "check
# these" is carried by whoever remembers to read it, which in this fleet is
# nobody: bin/fm-currency-round.sh takes this reading daily between sessions,
# and that round is armed without anyone deciding to arm it.
#
# WHAT IT DOES NOT DO
# It NEVER installs, enables, or changes anything. That is the captain's ruling
# and it is the whole shape of this script: installing a plugin runs a command
# whose content a third party decides, unattended, on a seat with no human
# present, so this repository does not run it. Where a seat is short, the
# finding NAMES the command an operator would run and stops there.
#
# The cost of that is a property of the mechanism rather than an oversight: a
# seat that is short STAYS SHORT UNTIL A PERSON ACTS. Nothing here closes the
# gap; it only refuses to let the gap stay quiet.
#
# WHAT IT READS AND HOW RELIABLY
# The expected set is the "plugins" object in skills-lock.json at the repository
# root, which also owns the existing installed-skill records. Each entry names a
# plugin id (<plugin>@<marketplace>), the marketplace it comes from, the version
# this fleet has chosen, and the basis for choosing it. Nothing of the plugin's
# own content is vendored here; only what a seat should have and where it comes
# from. The recorded version is a record of intent and not a constraint: nothing
# in this fleet installs, so nothing can enforce it, and a differing version is
# reported for a person to decide about.
#
# The installed set is read through `claude plugin list --json`, a documented
# command of the harness, NOT through the versioned cache directory under
# ~/.claude/plugins/cache. That distinction was measured on 2026-09-07 and it is
# the whole reason this check's silence can be trusted: the cache path embeds a
# version and a marketplace name and is an internal detail that may move, while
# the command answers the question directly. docs/fleet-plugin-skills.md records
# the measurement.
#
# A reading that could not be taken never renders as an installed plugin and
# never renders as a missing one. Three separate outcomes exist for that:
#   skipped     this seat has no `claude` on PATH, so it has no plugin
#               mechanism at all and cannot be short of a plugin skill.
#   unmeasured  `claude` is here but its plugin list could not be read or did
#               not parse, or the fleet's own manifest could not be decoded, so
#               this seat's standing is UNKNOWN, not clean.
#   missing / disabled / version-differs
#               the list was read and it actually says so.
#
# Usage:
#   fm-skills-lock.sh             print one SKILLS_LOCK line per entry this seat
#                                 does not satisfy, each naming the command an
#                                 operator would run; exit 0
#   fm-skills-lock.sh --status    print every reading, satisfied ones included
#   fm-skills-lock.sh --reading   print "<id>|<state>|<detail>" per entry for
#                                 bin/fm-currency-round.sh
#   fm-skills-lock.sh --help
#
# Environment:
#   FM_SKILLS_LOCK_TIMEOUT    ceiling in seconds for the plugin list read
#                             (default 120).
#   FM_SKILLS_LOCK_DISABLE=1  silence and skip everything (tests, diagnosis).
#   FM_SKILLS_LOCK_FILE       override the manifest path (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LOCK="${FM_SKILLS_LOCK_FILE:-$(cd "$SCRIPT_DIR/.." && pwd)/skills-lock.json}"

STEP_TIMEOUT=${FM_SKILLS_LOCK_TIMEOUT:-120}
case "$STEP_TIMEOUT" in ''|*[!0-9]*) STEP_TIMEOUT=120 ;; esac

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=report
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --status) MODE=status ;;
  --reading) MODE=reading ;;
  *)
    printf 'fm-skills-lock: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--status|--reading|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: %s [--status|--reading|--help]\n' "$(basename "$0")" >&2
  exit 2
}

[ "${FM_SKILLS_LOCK_DISABLE:-0}" = 1 ] && exit 0

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

# Run "$@" under the per-step ceiling. With no timeout binary the call runs
# unbounded rather than being skipped, so a home without coreutils still gets
# its readings; the caller's own timeout stays the backstop.
bounded() {
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$STEP_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$STEP_TIMEOUT" "$@" ;;
    *) "$@" ;;
  esac
}

# Who this reading is about. A finding that names only the skill sends a
# supervisor looking for the wrong thing: every seat reads the same manifest, so
# the seat is the variable and it belongs in the line.
SEAT="$(hostname 2>/dev/null || echo unknown-host):$FM_HOME"

# --- the expected set -------------------------------------------------------
#
# One record per line as "<id>\t<marketplace>\t<version>". jq or python3 decodes
# it; a manifest that cannot be decoded is an error rather than an empty set,
# because an empty expected set is silence and silence here means "nothing to
# do", which is exactly the claim an unreadable manifest may not make.
#
# The reason travels through a FILE and not a variable. expected_entries is read
# with a command substitution, so it runs in a subshell and anything it assigns
# dies with that subshell; a reason that cannot cross that boundary reaches the
# report blank, which makes "no jq or python3", "manifest absent" and "manifest
# undecodable" one indistinguishable reading.
EXPECTED_ERROR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-skills-lock.XXXXXX" 2>/dev/null) || EXPECTED_ERROR_FILE=
if [ -z "$EXPECTED_ERROR_FILE" ]; then
  # Without a private file the reason cannot cross the subshell, so the reading
  # says that outright rather than shipping a blank cause.
  EXPECTED_ERROR_FILE=/dev/null
fi
trap '[ "$EXPECTED_ERROR_FILE" = /dev/null ] || rm -f "$EXPECTED_ERROR_FILE"' EXIT

expected_error() {
  printf '%s' "$1" > "$EXPECTED_ERROR_FILE" 2>/dev/null
  return 1
}

expected_entries() {
  : > "$EXPECTED_ERROR_FILE" 2>/dev/null
  if [ ! -f "$LOCK" ]; then
    expected_error "the manifest $LOCK does not exist"
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      (.plugins // {}) |
      if type != "object" then error("plugins must be an object") else . end |
      to_entries[] |
      if (.value | type) != "object" then
        error("plugins." + .key + " must be an object")
      else
        [.key, (.value.marketplace // ""), (.value.version // "")] | @tsv
      end
    ' "$LOCK" 2>/dev/null && return 0
    expected_error "the manifest $LOCK could not be decoded"
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$LOCK" 2>/dev/null <<'PY' && return 0
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
plugins = manifest.get("plugins", {})
if not isinstance(plugins, dict):
    raise ValueError("plugins must be an object")
for name, record in plugins.items():
    if not isinstance(record, dict):
        raise ValueError("plugins.%s must be an object" % name)
    print("\t".join([name, record.get("marketplace") or "", record.get("version") or ""]))
PY
    expected_error "the manifest $LOCK could not be decoded"
    return 1
  fi
  expected_error "neither jq nor python3 is available to decode $LOCK"
  return 1
}

# --- the installed set ------------------------------------------------------
#
# INSTALLED_STATE is why this script can be trusted when it says nothing:
#   absent  no `claude` on PATH at all
#   ok      the list was read; INSTALLED holds "<id>\t<version>\t<enabled>"
#   error   `claude` is here and the list could not be read; the reason is in
#           INSTALLED_ERROR and every entry becomes unmeasured, never satisfied
INSTALLED_STATE=error
INSTALLED_ERROR=
INSTALLED=
read_installed() {
  local raw status=0
  INSTALLED=
  INSTALLED_ERROR=
  if ! command -v claude >/dev/null 2>&1; then
    INSTALLED_STATE=absent
    return 0
  fi
  raw=$(bounded claude plugin list --json 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    INSTALLED_STATE=error
    INSTALLED_ERROR="\`claude plugin list --json\` exited $status (it may have exceeded ${STEP_TIMEOUT}s)"
    return 0
  fi
  if [ -z "$raw" ]; then
    INSTALLED_STATE=error
    INSTALLED_ERROR="\`claude plugin list --json\` printed nothing, so this seat's plugin set is unknown rather than empty"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    INSTALLED=$(printf '%s' "$raw" | jq -r '
      if type != "array" then error("not an array") else . end |
      .[] | [(.id // ""), (.version // ""), (if .enabled == false then "no" else "yes" end)] | @tsv
    ' 2>/dev/null) || {
      INSTALLED_STATE=error
      INSTALLED_ERROR="\`claude plugin list --json\` answered in a shape this check does not know"
      return 0
    }
  elif command -v python3 >/dev/null 2>&1; then
    INSTALLED=$(printf '%s' "$raw" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    raise ValueError("not an array")
for entry in data:
    print("\t".join([entry.get("id") or "", entry.get("version") or "",
                     "no" if entry.get("enabled") is False else "yes"]))
' 2>/dev/null) || {
      INSTALLED_STATE=error
      INSTALLED_ERROR="\`claude plugin list --json\` answered in a shape this check does not know"
      return 0
    }
  else
    INSTALLED_STATE=error
    INSTALLED_ERROR="neither jq nor python3 is available to decode \`claude plugin list --json\`"
    return 0
  fi
  INSTALLED_STATE=ok
}

# The installed record for one id, or nothing. Deliberately only ever consulted
# when INSTALLED_STATE is ok.
installed_record() {
  printf '%s\n' "$INSTALLED" | awk -F'\t' -v id="$1" '$1 == id { print; exit }'
}

# --- readings ---------------------------------------------------------------
#
# One record per entry as "<id>|<state>|<detail>", held in an array so the
# report, the status listing and the round's reading are rendered from the same
# measurement and cannot disagree.
READINGS=()

read_all() {
  local entries id marketplace want record have enabled reason
  READINGS=()
  if ! entries=$(expected_entries); then
    reason=$(cat "$EXPECTED_ERROR_FILE" 2>/dev/null)
    [ -n "$reason" ] || reason="the reason could not be recovered"
    READINGS+=("skills-lock|unmeasured|the fleet's expected plugin set could not be read on $SEAT: $reason")
    return 0
  fi
  [ -n "$entries" ] || return 0
  read_installed
  while IFS=$'\t' read -r id marketplace want; do
    [ -n "$id" ] || continue
    case "$INSTALLED_STATE" in
      absent)
        READINGS+=("$id|skipped|$SEAT has no \`claude\` on PATH, so it carries no plugin skills and cannot be short of $id")
        continue
        ;;
      error)
        READINGS+=("$id|unmeasured|whether $SEAT carries $id could not be established: $INSTALLED_ERROR")
        continue
        ;;
    esac
    record=$(installed_record "$id")
    if [ -z "$record" ]; then
      # The line carries the command rather than running it: an operator decides
      # whether this seat runs what the marketplace serves today.
      READINGS+=("$id|missing|$SEAT does not have $id installed (from $marketplace); the fleet records version $want. Nothing here installs it: run \`claude plugin marketplace add $marketplace\` then \`claude plugin install $id\` on this seat")
      continue
    fi
    have=$(printf '%s' "$record" | cut -f2)
    enabled=$(printf '%s' "$record" | cut -f3)
    if [ "$enabled" != yes ]; then
      READINGS+=("$id|disabled|$SEAT has $id installed at $have but disabled, so its skills never reach a session here; run \`claude plugin enable $id\` on this seat")
      continue
    fi
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
      READINGS+=("$id|version-differs|$SEAT carries $id $have, and the fleet records $want as the version its own tracked skills were written against")
      continue
    fi
    READINGS+=("$id|ok|$SEAT carries $id $have, enabled")
  done <<< "$entries"
}

# --- rendering --------------------------------------------------------------

render_status() {
  local record id state detail
  if [ "${#READINGS[@]}" -eq 0 ]; then
    printf 'no plugin skills are locked for the fleet, so this seat has nothing to carry\n'
    return 0
  fi
  for record in "${READINGS[@]:-}"; do
    [ -n "$record" ] || continue
    IFS='|' read -r id state detail <<< "$record"
    printf 'reading: %s state=%s detail=%s\n' "$id" "$state" "$detail"
  done
}

render_findings() {
  local record id state detail
  for record in "${READINGS[@]:-}"; do
    [ -n "$record" ] || continue
    IFS='|' read -r id state detail <<< "$record"
    case "$state" in
      ok|skipped) continue ;;
    esac
    printf 'SKILLS_LOCK: %s\n' "$detail"
  done
}

read_all
case "$MODE" in
  status)
    render_status
    ;;
  reading)
    for record in "${READINGS[@]:-}"; do
      [ -n "$record" ] && printf '%s\n' "$record"
    done
    ;;
  *)
    render_findings
    ;;
esac
exit 0
