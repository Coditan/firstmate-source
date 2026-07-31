# shellcheck shell=bash
# Vessel-role selection: which tracked role overlay a firstmate home runs.
#
# Usage: . bin/fm-role-lib.sh   (no FM_* setup required)
#
# A role is CONFIGURATION, not a codebase. Every fleet member runs the same
# tracked code root; the local, gitignored config/role file selects which
# tracked roles/<name>.md overlay amends AGENTS.md for this home. config/backend
# is the precedent: a documented default when the file is absent, and a loud
# bootstrap diagnostic (never a silent fallback) for an unrecognized value.
#
# The three recognized values:
#   vessel       the default, and the meaning of an ABSENT file. No overlay;
#                AGENTS.md stands unamended. roles/vessel.md deliberately does
#                not exist, because "no amendment" is not a document.
#   coordinator  relays captain authority to peer vessels and routes across
#                their domains; dispatches no crews (roles/coordinator.md).
#   executor     deploys, watches, and delivers the fleet's work, and leaves
#                another vessel's domain to that vessel to diagnose
#                (roles/executor.md).
#
# There is deliberately no FM_ROLE environment override. The role is a property
# of the HOME, not of a session, and an in-session variable would be exactly the
# thing that relaxes the coordinator spawn refusal in bin/fm-spawn.sh. Tests
# point at a fixture home with FM_CONFIG_OVERRIDE, the same seam every other
# config item uses.
#
# Delivery of the selected overlay is owned by two seams that already existed,
# not by this library: bin/fm-session-start.sh prints it into the session digest
# (deterministic delivery), and AGENTS.md's own load line makes an agent reload
# it after context compaction (persistence). docs/configuration.md "Vessel role"
# owns the operator-facing contract.

FM_ROLE_KNOWN="vessel coordinator executor"
FM_ROLE_DEFAULT="vessel"

# fm_role_value <config-dir>: the selected role - the first non-empty line of
# <config-dir>/role with whitespace stripped, or the default when the file is
# absent or holds only blank lines. Never validates; callers that care use
# fm_role_is_known so the one loud diagnostic stays with bootstrap.
fm_role_value() {
  local config_dir=$1 line v
  if [ -f "$config_dir/role" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
      fi
    done < "$config_dir/role"
  fi
  printf '%s\n' "$FM_ROLE_DEFAULT"
}

# fm_role_is_known <name>: true for a recognized role value.
fm_role_is_known() {
  local name=$1 known
  for known in $FM_ROLE_KNOWN; do
    if [ "$name" = "$known" ]; then
      return 0
    fi
  done
  return 1
}

# fm_role_overlay_path <fm-root> <name>: the tracked overlay file a known,
# non-default role expects. Returns non-zero (printing nothing) for the default
# role and for an unrecognized one, so a caller cannot construct a path for a
# role that has no overlay by contract.
fm_role_overlay_path() {
  local root=$1 name=$2
  if [ "$name" = "$FM_ROLE_DEFAULT" ]; then
    return 1
  fi
  if ! fm_role_is_known "$name"; then
    return 1
  fi
  printf '%s\n' "$root/roles/$name.md"
}

# fm_role_is_coordinator <config-dir>: true when this home runs the coordinator
# role. Used by bin/fm-spawn.sh's crew refusal.
fm_role_is_coordinator() {
  [ "$(fm_role_value "$1")" = coordinator ]
}
