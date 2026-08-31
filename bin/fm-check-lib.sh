#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

# --- the cross-home arm guard -----------------------------------------------
#
# THE DEFECT THIS CLOSES, measured 2026-08-30
#
# An armed watcher check BAKES its home rather than inheriting one, because
# bin/fm-watch.sh runs it from a private snapshot with the watcher's own
# environment. So `--arm` writes whatever FM_HOME it was called with into
# whatever state directory it resolved, and nothing made those two agree.
#
# A caller that sets FM_HOME for a fixture home while FM_STATE_OVERRIDE is
# still inherited from a live session therefore resolves a FIXTURE home and a
# LIVE state directory. It overwrites that live home's armed check with the
# fixture's locations and reports success. Six of this fleet's live checks were
# overwritten that way in a single day. A leaked check then runs, looks in a
# temporary directory that no longer exists, prints nothing, and is
# indistinguishable from a healthy check with nothing to report - one had been
# silent for weeks.
#
# THE PREDICATE
#
# An armed check must be COHERENT: the state directory it lands in must be the
# state directory of the home it bakes. Every legitimate arm satisfies that -
# bin/fm-bootstrap.sh arming this home at every locked session start, and every
# suite arming its own fixture home, set both to one home. Only an arm whose
# home and state directory came from different places fails it.
#
# Arming a fixture home stays legitimate and necessary, because the bootstrap
# suites exercise arming against fixture homes on purpose. This bans neither
# that nor arming from a test; it bans arming a home that is not the one the
# state directory belongs to.

# The home a state directory belongs to, or nothing when it names none.
#
# docs/configuration.md owns the layout: FM_HOME selects that home's private
# state/, so a directory literally named `state` names its owner in its own
# path and needs no marker file to say so. A directory called anything else is
# a deliberately relocated state directory that claims no owner, and this
# prints nothing rather than inventing one.
fm_check_state_home() {  # <state dir> -> the owning home, or nothing
  local state=$1 real parent base
  real=$(cd -P -- "$state" 2>/dev/null && pwd -P) || real=
  if [ -z "$real" ]; then
    # Not created yet. Canonicalize the parent instead so the reading is the
    # same before and after the directory exists; an arm path that creates its
    # own state directory must not be able to slip past the guard by running
    # one step earlier.
    base=$(basename -- "$state")
    parent=$(cd -P -- "$(dirname -- "$state")" 2>/dev/null && pwd -P) || return 0
    case "$parent" in
      /) real="/$base" ;;
      *) real="$parent/$base" ;;
    esac
  fi
  [ "${real##*/}" = state ] || return 0
  parent=${real%/*}
  [ -n "$parent" ] || parent=/
  printf '%s' "$parent"
}

# Whether an arm may write into this state directory for this home.
#
# Prints the refusal and returns 1 when the two disagree; silent and 0
# otherwise, including when the state directory names no owner.
fm_check_arm_home_refusal() {  # <state dir> <FM_HOME>
  local state=$1 home=$2 owner real
  owner=$(fm_check_state_home "$state") || return 0
  [ -n "$owner" ] || return 0
  real=$(cd -P -- "$home" 2>/dev/null && pwd -P) || real=$home
  [ "$real" != "$owner" ] || return 0
  printf 'refusing to arm %s: that state directory belongs to home %s, not to %s. Arming it would bake the wrong home into a check that home has to run, and the check would then read a directory it does not own. Point FM_HOME and FM_STATE_OVERRIDE at one home - an FM_STATE_OVERRIDE inherited from another session is the usual cause.' \
    "$state" "$owner" "$real"
  return 1
}
