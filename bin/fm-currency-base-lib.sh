# shellcheck shell=bash
# Shared resolution of the currency comparison base used by the instruction
# surface update check: the git URL it fetches its comparison side from.
#
# config/firstmate-update-base names the artifact THIS deployment updates from,
# so bin/fm-firstmate-update-check.sh asks "does the instruction surface I
# actually run have source-only changes?" against the right source.
#
# Precedence for the comparison base, highest first:
#   1. FM_FIRSTMATE_UPDATE_SOURCE_URL (explicit, per-invocation, passed through
#      unvalidated so existing test harnesses keep working)
#      FM_FIRSTMATE_UPSTREAM_URL is accepted as a compatibility alias.
#   2. the local gitignored config/firstmate-update-base file
#   3. FM_CURRENCY_BASE_DEFAULT, the update source this deployment came from
# An absent config file therefore changes nothing for an unconfigured home.
# A PRESENT but unusable file never silently falls back to the default: the
# resolver refuses with a reason, the check script persists that as its own
# STUCK diagnostic, and bootstrap reports it as CURRENCY_BASE: at startup.
#
# Usage: . bin/fm-currency-base-lib.sh
# The resolvers report through globals rather than stdout, so callers must NOT
# invoke them in a command substitution: fm_currency_base_resolve sets
# FM_CURRENCY_BASE_VALUE on success and FM_CURRENCY_BASE_REASON on refusal.

# The update source this deployment came from, used when nothing is configured.
FM_CURRENCY_BASE_DEFAULT="https://github.com/Coditan/firstmate-source.git"

# The declared config-dir-relative item names, so callers never spell them, plus
# the two result globals. All four are read by sourcing callers only.
# shellcheck disable=SC2034
FM_CURRENCY_BASE_UPDATE_ITEM="firstmate-update-base"
# shellcheck disable=SC2034
FM_CURRENCY_BASE_REASON=""
# shellcheck disable=SC2034
FM_CURRENCY_BASE_VALUE=""
# Which hop the last resolver call used, so a caller can name the source in its
# own diagnostic instead of asserting a bare URL.
# shellcheck disable=SC2034
FM_CURRENCY_BASE_SOURCE=""

# fm_currency_base_validate <value>: accept a value git can safely be handed as
# a remote. Silent on success; sets FM_CURRENCY_BASE_REASON and returns 1
# otherwise.
fm_currency_base_validate() {
  local value=$1
  FM_CURRENCY_BASE_REASON=""
  case $value in
    '')
      FM_CURRENCY_BASE_REASON="the value is empty"
      return 1
      ;;
    -*)
      FM_CURRENCY_BASE_REASON="the value starts with '-' and git would read it as an option"
      return 1
      ;;
    *[[:space:]]*)
      FM_CURRENCY_BASE_REASON="the value contains whitespace"
      return 1
      ;;
    *[![:print:]]*)
      FM_CURRENCY_BASE_REASON="the value contains control characters"
      return 1
      ;;
  esac
  case $value in
    https://?*|http://?*|ssh://?*|git://?*|git+ssh://?*|file://?*|/?*)
      return 0
      ;;
  esac
  # scp-style host:path, git's other native remote spelling. Git recognises it
  # by a colon appearing before the first slash, so this must be decided ahead
  # of the relative-path refusal: git@host:owner/repo.git has both.
  case ${value%%/*} in
    ?*:*)
      return 0
      ;;
  esac
  case $value in
    */*)
      # A relative path would resolve against each caller's differing working
      # directory, so it is never a durable per-home setting.
      FM_CURRENCY_BASE_REASON="the value is a relative path; use an absolute path or a URL"
      return 1
      ;;
  esac
  FM_CURRENCY_BASE_REASON="the value is not a git URL or an absolute path"
  return 1
}

# fm_currency_base_file_value <config_dir> <item>: set FM_CURRENCY_BASE_VALUE
# from the configured file. Returns 0 with the value, 2 when the file is absent
# (no configuration), or 1 with FM_CURRENCY_BASE_REASON set when the file is
# present but unusable.
fm_currency_base_file_value() {
  local config_dir=$1 item=$2 file line trimmed value="" seen=0
  file="$config_dir/$item"
  FM_CURRENCY_BASE_REASON=""
  FM_CURRENCY_BASE_VALUE=""
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 2
  fi
  # Present but not a readable regular file: a directory, a device, or a
  # dangling symlink is a configured intent this resolver cannot honour, so it
  # refuses rather than resolving the default behind the operator's back.
  if [ ! -f "$file" ]; then
    FM_CURRENCY_BASE_REASON="the path exists but is not a regular file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    FM_CURRENCY_BASE_REASON="the file is not readable"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ -n "$trimmed" ] || continue
    seen=$((seen + 1))
    [ "$seen" -eq 1 ] && value=$trimmed
  done < "$file"
  if [ "$seen" -eq 0 ]; then
    FM_CURRENCY_BASE_REASON="the file is empty"
    return 1
  fi
  if [ "$seen" -gt 1 ]; then
    FM_CURRENCY_BASE_REASON="the file has more than one non-empty line"
    return 1
  fi
  fm_currency_base_validate "$value" || return 1
  FM_CURRENCY_BASE_VALUE=$value
  return 0
}

# fm_currency_base_resolve <config_dir> <item>: set FM_CURRENCY_BASE_VALUE to
# the base to compare against, applying the documented precedence. Returns 1
# with FM_CURRENCY_BASE_REASON set only when a present config file is unusable.
# shellcheck disable=SC2034  # all three globals are read by sourcing callers.
fm_currency_base_resolve() {
  local config_dir=$1 item=$2 status
  FM_CURRENCY_BASE_REASON=""
  FM_CURRENCY_BASE_VALUE=""
  FM_CURRENCY_BASE_SOURCE=""
  if [ -n "${FM_FIRSTMATE_UPDATE_SOURCE_URL:-}" ]; then
    FM_CURRENCY_BASE_VALUE=$FM_FIRSTMATE_UPDATE_SOURCE_URL
    FM_CURRENCY_BASE_SOURCE="FM_FIRSTMATE_UPDATE_SOURCE_URL"
    return 0
  fi
  if [ -n "${FM_FIRSTMATE_UPSTREAM_URL:-}" ]; then
    FM_CURRENCY_BASE_VALUE=$FM_FIRSTMATE_UPSTREAM_URL
    FM_CURRENCY_BASE_SOURCE="FM_FIRSTMATE_UPSTREAM_URL compatibility alias"
    return 0
  fi
  fm_currency_base_file_value "$config_dir" "$item"
  status=$?
  case $status in
    0)
      FM_CURRENCY_BASE_SOURCE="config/$item"
      return 0
      ;;
    2)
      FM_CURRENCY_BASE_VALUE=$FM_CURRENCY_BASE_DEFAULT
      FM_CURRENCY_BASE_SOURCE="the built-in default"
      return 0
      ;;
  esac
  return 1
}
