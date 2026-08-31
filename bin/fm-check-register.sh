#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
#
# Usage:
#   fm-check-register.sh <id>
#   fm-check-register.sh -h|--help
#
# The check must already exist at state/<id>.check.sh as a regular, non-symlinked,
# single-link file with mode 0700 on the state directory's filesystem.
# Registration writes state/<id>.check-trust, binding the check to its current
# SHA-256 hash; register it again after changing its bytes.
#
# This command neither creates the check nor gives it a wall-clock cadence.
# The watcher sweeps state/*.check.sh no more often than once per
# FM_CHECK_INTERVAL seconds (default 300), and a sweep stops at the first
# registered check that reports. It stamps the interval before it stops, so the
# checks sorted after that one wait for the next sweep rather than running later
# in the same pass: a check is not guaranteed to run once per interval when an
# earlier-sorting check is chatty. A check that must run less often therefore
# owns that schedule itself and stays silent when it is not due.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Read help before the id check: every -h/--help spelling is path-safe, so an
# unguarded caller asking for help is taken for a check named "--help" and
# refused as a missing script.
case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || { echo "error: invalid custom check registration" >&2; exit 2; }
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
CHECK_DISPLAY="state/$ID.check.sh"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
# Each condition fm_pr_private_file_valid folds into one boolean is named
# separately here, so the refusal states the remedy instead of implying it.
[ -e "$CHECK" ] || [ -L "$CHECK" ] \
  || { echo "error: custom check script does not exist: $CHECK_DISPLAY" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] \
  || { echo "error: custom check script must be a regular non-symlink file: $CHECK_DISPLAY" >&2; exit 1; }
CHECK_MODE=$(fm_pr_file_mode "$CHECK") \
  || { echo "error: custom check script could not be inspected: $CHECK_DISPLAY" >&2; exit 1; }
[ "$CHECK_MODE" = 700 ] \
  || { printf 'error: custom check script must have mode 0700: %s (found 0%s)\n' "$CHECK_DISPLAY" "$CHECK_MODE" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
CHECK_DEVICE=$(fm_pr_file_device "$CHECK") \
  || { echo "error: custom check script could not be inspected: $CHECK_DISPLAY" >&2; exit 1; }
[ "$CHECK_DEVICE" = "$STATE_DEVICE" ] \
  || { echo "error: custom check script must be on the state directory's filesystem: $CHECK_DISPLAY" >&2; exit 1; }
CHECK_LINKS=$(fm_pr_file_link_count "$CHECK") \
  || { echo "error: custom check script could not be inspected: $CHECK_DISPLAY" >&2; exit 1; }
[ "$CHECK_LINKS" = 1 ] \
  || { echo "error: custom check script must have exactly one hard link: $CHECK_DISPLAY" >&2; exit 1; }
# The composite predicate still runs: the named checks above are diagnostics, and
# this is what refuses a script swapped since they read it.
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check script changed while it was being validated: $CHECK_DISPLAY" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
