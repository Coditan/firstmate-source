#!/usr/bin/env bash
# fm-absence-lib.sh - decide whether a path's ABSENCE is something this process
# actually established, or merely what a failed look reports.
#
# Why this exists (2026-08-31): `test -e` is false whenever the stat FAILS, not
# only when the file is not there. A containing directory this process cannot
# search makes a present, populated path answer exactly like a missing one, so a
# reader that concludes "absent" from `[ ! -e ]` alone is reporting a reading it
# never took. Both readers of a home's fleet - bin/fm-fleet-sync.sh, which refuses
# rather than reporting a home has nothing, and bin/fm-bootstrap.sh, whose cheap
# guard decides whether that reader runs at all - have to agree on that rule, so it
# is stated once here rather than twice.
#
# Proving that a NAMED child is absent needs SEARCH on the parent and nothing else:
# read permission is what listing a directory needs, and listing is not what this
# asks. A directory that is searchable and not readable therefore still proves the
# absence of a name inside it.

# fm_absence_unprovable <path>: prints the nearest ancestor directory that cannot
# be searched and returns 0 when the path's absence cannot be established there;
# returns 1 when an ancestor this process can search proves the path is not present.
fm_absence_unprovable() {
  local dir=$1
  while :; do
    case "$dir" in
      /) return 1 ;;
      */*) dir=${dir%/*}; [ -n "$dir" ] || dir=/ ;;
      *) dir=. ;;
    esac
    if [ -e "$dir" ]; then
      if [ ! -d "$dir" ] || [ ! -x "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
      fi
      return 1
    fi
    if [ -L "$dir" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    case "$dir" in
      /|.) return 1 ;;
    esac
  done
}
