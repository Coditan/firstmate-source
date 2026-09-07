#!/usr/bin/env bash
# Keep this seat carrying the third-party plugin skills the fleet expects, and
# make a seat that is short of one visible without anyone remembering to look.
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
# It is deliberately a mechanism and not an instruction. A rule saying "install
# these" is carried by whoever remembers to read it, which in this fleet is
# nobody: bin/fm-bootstrap.sh converges this on every session start, and
# bin/fm-currency-round.sh takes its reading daily between sessions.
#
# WHAT IT READS AND HOW RELIABLY
# The expected set is the "plugins" object in skills-lock.json at the repository
# root, which also owns the existing installed-skill records. Each entry names a
# plugin id (<plugin>@<marketplace>), the marketplace it comes from, the version
# this fleet has chosen, and the basis for choosing it. Nothing of the plugin's
# own content is vendored here; only what to install and where it comes from.
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
#               not parse, so this seat's set is UNKNOWN, not empty.
#   missing / disabled / version-differs
#               the list was read and it actually says so.
#
# WHAT IT CHANGES
# Only `missing` is installed automatically: installing an absent skill restores
# what the fleet already decided, and running it twice installs nothing the
# second time because the plugin is then present. A version that differs from
# the locked one is REPORTED and never changed, because choosing which version
# of a third party's skills this fleet runs on is a decision, not a repair, and
# `claude plugin install` cannot target a version anyway.
#
# Usage:
#   fm-skills-lock.sh             converge: install what is missing when the
#                                 cadence window is open, print one SKILLS_LOCK
#                                 line per entry still not satisfied, exit 0
#   fm-skills-lock.sh --force     converge now, ignoring the cadence stamp
#   fm-skills-lock.sh --status    print every reading; writes no cadence stamp
#                                 and installs nothing
#   fm-skills-lock.sh --reading   print "<id>|<state>|<detail>" per entry for
#                                 bin/fm-currency-round.sh; installs nothing
#   fm-skills-lock.sh --help
#
# State, under FM_HOME/state:
#   skills-lock.checked           epoch of the last completed convergence
#
# Environment:
#   FM_SKILLS_LOCK_INTERVAL   cadence in seconds (default 86400); 0 converges on
#                             every invocation.
#   FM_SKILLS_LOCK_TIMEOUT    ceiling in seconds for each harness call (default
#                             120, because an install fetches a repository).
#   FM_SKILLS_LOCK_DISABLE=1  silence and skip everything (tests, diagnosis).
#   FM_SKILLS_LOCK_FILE       override the manifest path (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="${FM_SKILLS_LOCK_FILE:-$(cd "$SCRIPT_DIR/.." && pwd)/skills-lock.json}"
STAMP="$STATE/skills-lock.checked"

INTERVAL=${FM_SKILLS_LOCK_INTERVAL:-86400}
STEP_TIMEOUT=${FM_SKILLS_LOCK_TIMEOUT:-120}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=86400 ;; esac
case "$STEP_TIMEOUT" in ''|*[!0-9]*) STEP_TIMEOUT=120 ;; esac

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=converge
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --force) MODE=force ;;
  --status) MODE=status ;;
  --reading) MODE=reading ;;
  *)
    printf 'fm-skills-lock: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--force|--status|--reading|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: %s [--force|--status|--reading|--help]\n' "$(basename "$0")" >&2
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
EXPECTED_ERROR=
expected_entries() {
  EXPECTED_ERROR=
  if [ ! -f "$LOCK" ]; then
    EXPECTED_ERROR="the manifest $LOCK does not exist"
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
    EXPECTED_ERROR="the manifest $LOCK could not be decoded"
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
    EXPECTED_ERROR="the manifest $LOCK could not be decoded"
    return 1
  fi
  EXPECTED_ERROR="neither jq nor python3 is available to decode $LOCK"
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
# convergence pass, the status listing and the round's reading are rendered from
# the same measurement and cannot disagree.
READINGS=()

read_all() {
  local entries id marketplace want record have enabled
  READINGS=()
  if ! entries=$(expected_entries); then
    READINGS+=("skills-lock|unmeasured|the fleet's expected plugin set could not be read on $SEAT: $EXPECTED_ERROR")
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
      READINGS+=("$id|missing|$SEAT does not have $id installed (from $marketplace); the fleet expects version $want")
      continue
    fi
    have=$(printf '%s' "$record" | cut -f2)
    enabled=$(printf '%s' "$record" | cut -f3)
    if [ "$enabled" != yes ]; then
      READINGS+=("$id|disabled|$SEAT has $id installed at $have but disabled, so its skills never reach a session here")
      continue
    fi
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
      READINGS+=("$id|version-differs|$SEAT carries $id $have, and the fleet records $want as the version its own tracked skills were written against")
      continue
    fi
    READINGS+=("$id|ok|$SEAT carries $id $have, enabled")
  done <<< "$entries"
}

# --- convergence ------------------------------------------------------------
#
# Installs only what is missing. Adding the marketplace first is what makes a
# fresh seat converge rather than merely report: a seat that has never seen the
# marketplace cannot resolve the plugin id at all. Both calls are idempotent, so
# a second run of this whole script does nothing at all - the plugin is present
# by then and no install is attempted.
install_missing() {
  local record id state marketplace want entries acted=0
  entries=$(expected_entries) || return 0
  for record in "${READINGS[@]:-}"; do
    [ -n "$record" ] || continue
    id=${record%%|*}
    state=${record#*|}
    state=${state%%|*}
    [ "$state" = missing ] || continue
    marketplace=$(printf '%s\n' "$entries" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')
    want=$(printf '%s\n' "$entries" | awk -F'\t' -v id="$id" '$1 == id { print $3; exit }')
    acted=1
    if [ -n "$marketplace" ] && ! bounded claude plugin marketplace add "$marketplace" >/dev/null 2>&1; then
      # Not fatal on its own: the marketplace may already be configured, and the
      # install below is the reading that settles it either way.
      :
    fi
    if ! bounded claude plugin install "$id" --yes --scope user >/dev/null 2>&1; then
      printf 'SKILLS_LOCK: %s is missing %s (expected %s, from %s) and installing it failed; run "claude plugin install %s" here to see why\n' \
        "$SEAT" "$id" "$want" "$marketplace" "$id"
    fi
  done
  [ "$acted" -eq 1 ] || return 0
  # Re-read rather than assume: an install that reported success and produced
  # nothing must not be recorded as a repair.
  read_all
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

case "$MODE" in
  status)
    read_all
    render_status
    exit 0
    ;;
  reading)
    read_all
    for record in "${READINGS[@]:-}"; do
      [ -n "$record" ] && printf '%s\n' "$record"
    done
    exit 0
    ;;
esac

NOW=$(date +%s 2>/dev/null || echo 0)
if [ "$MODE" != force ] && [ -f "$STAMP" ]; then
  checked=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  if [ "$NOW" -ge "$checked" ] && [ $((NOW - checked)) -lt "$INTERVAL" ]; then
    exit 0
  fi
fi

read_all
install_missing
render_findings
mkdir -p "$STATE" 2>/dev/null || exit 0
printf '%s\n' "$NOW" > "$STAMP"
exit 0
