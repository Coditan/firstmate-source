# shellcheck shell=bash
# Shared resolution of the currency comparison bases used by the two upstream
# checks: the git URL each check fetches its comparison side from.
#
# There are THREE bases because the two checks answer different questions, and a
# curator vessel running from a fleet repository needs all of them at once:
#   config/firstmate-update-base  the artifact THIS deployment updates from, so
#     bin/fm-firstmate-update-check.sh asks "does the instruction surface I
#     actually run have upstream-only changes?" against the right source.
#   config/fork-sync-upstream     the REAL upstream the curated fork tracks, so
#     bin/fm-fork-sync-check.sh asks "has the fork absorbed real upstream
#     content?" against the template's true origin.
#   config/fork-sync-fork         the curated fork ITSELF, the other side of that
#     same comparison. It exists because the fork side used to be taken from the
#     home's origin, which is only the fork in the plain topology. On a curator
#     vessel deployed from a fleet repository, origin is that fleet repository,
#     so the check silently compared upstream against the wrong repository and
#     reported fleet commits as fork-only patches.
# Collapsing them into one knob would make a fleet vessel either compare its
# instruction surface with a repository it never updates from, or compare its
# fork with itself.
#
# Precedence for the two upstream bases, highest first:
#   1. FM_FIRSTMATE_UPSTREAM_URL (explicit, per-invocation, passed through
#      unvalidated so existing test harnesses keep working)
#   2. the named local gitignored config/ file
#   3. FM_CURRENCY_BASE_DEFAULT, the canonical upstream template
# An absent config file therefore changes nothing for an unconfigured home.
# The fork side has no canonical default - every deployment's fork is its own -
# so fm_currency_base_fork_repo resolves its last hop from the checkout's own
# remotes instead. See its own comment for why the order is what it is.
# A PRESENT but unusable file never silently falls back to the default: the
# resolver refuses with a reason, the check scripts persist that as their own
# STUCK diagnostic, and bootstrap reports it as CURRENCY_BASE: at startup.
#
# Usage: . bin/fm-currency-base-lib.sh
# The resolvers report through globals rather than stdout, so callers must NOT
# invoke them in a command substitution: fm_currency_base_resolve sets
# FM_CURRENCY_BASE_VALUE on success and FM_CURRENCY_BASE_REASON on refusal.

# The canonical upstream template, used when nothing is configured.
FM_CURRENCY_BASE_DEFAULT="https://github.com/kunchenguid/firstmate.git"

# The declared config-dir-relative item names, so callers never spell them, plus
# the two result globals. All four are read by sourcing callers only.
# shellcheck disable=SC2034
FM_CURRENCY_BASE_UPDATE_ITEM="firstmate-update-base"
# shellcheck disable=SC2034
FM_CURRENCY_BASE_FORK_ITEM="fork-sync-upstream"
# shellcheck disable=SC2034
FM_CURRENCY_BASE_FORK_REPO_ITEM="fork-sync-fork"
# shellcheck disable=SC2034
FM_CURRENCY_BASE_REASON=""
# shellcheck disable=SC2034
FM_CURRENCY_BASE_VALUE=""
# Which hop the last fm_currency_base_fork_repo call resolved from, so a caller
# can name the source in its own diagnostic instead of asserting a bare URL.
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
# shellcheck disable=SC2034  # both globals are read by sourcing callers.
fm_currency_base_resolve() {
  local config_dir=$1 item=$2 status
  FM_CURRENCY_BASE_REASON=""
  FM_CURRENCY_BASE_VALUE=""
  if [ -n "${FM_FIRSTMATE_UPSTREAM_URL:-}" ]; then
    FM_CURRENCY_BASE_VALUE=$FM_FIRSTMATE_UPSTREAM_URL
    return 0
  fi
  fm_currency_base_file_value "$config_dir" "$item"
  status=$?
  case $status in
    0) return 0 ;;
    2)
      FM_CURRENCY_BASE_VALUE=$FM_CURRENCY_BASE_DEFAULT
      return 0
      ;;
  esac
  return 1
}

# fm_currency_base_fork_repo <config_dir> <fm_root>: set FM_CURRENCY_BASE_VALUE
# to the CURATED FORK's own URL - the other side of the fork-sync comparison -
# and FM_CURRENCY_BASE_SOURCE to the hop it came from. Returns 1 with
# FM_CURRENCY_BASE_REASON set when a present config file is unusable or when no
# hop yields a URL at all.
#
# Precedence, highest first, and why each hop exists:
#   1. FM_FIRSTMATE_FORK_URL     explicit and per-invocation, passed through
#      unvalidated for the same reason the upstream override is.
#   2. config/fork-sync-fork     the durable per-home declaration. It is the only
#      hop that states the fork rather than inferring it, so it is the one to set
#      on any home where the inference below is not obviously right.
#   3. the "fork" remote          a remote spelled "fork" is an operator saying,
#      in git's own vocabulary, that this checkout's fork is a DIFFERENT
#      repository from its origin. That is exactly the curator topology, and
#      reading it means such a seat measures correctly with no new configuration.
#   4. origin                     the plain topology, where the checkout simply
#      is a clone of the fork. This was the ONLY hop before, which is the defect:
#      on a curator vessel deployed from a fleet repository it silently measured
#      that fleet repository and called its commits fork-only patches.
# There is deliberately no default: a fork nobody named cannot be guessed, so the
# resolver refuses rather than comparing against something invented.
# shellcheck disable=SC2034  # all three globals are read by sourcing callers.
fm_currency_base_fork_repo() {
  local config_dir=$1 fm_root=$2 status url remote
  FM_CURRENCY_BASE_REASON=""
  FM_CURRENCY_BASE_VALUE=""
  FM_CURRENCY_BASE_SOURCE=""
  if [ -n "${FM_FIRSTMATE_FORK_URL:-}" ]; then
    FM_CURRENCY_BASE_VALUE=$FM_FIRSTMATE_FORK_URL
    FM_CURRENCY_BASE_SOURCE="FM_FIRSTMATE_FORK_URL"
    return 0
  fi
  fm_currency_base_file_value "$config_dir" "$FM_CURRENCY_BASE_FORK_REPO_ITEM"
  status=$?
  case $status in
    0)
      FM_CURRENCY_BASE_SOURCE="config/$FM_CURRENCY_BASE_FORK_REPO_ITEM"
      return 0
      ;;
    1)
      # Named in the reason, exactly as the upstream side names its own file, so
      # the refusal points at the thing an operator has to fix.
      FM_CURRENCY_BASE_REASON="config/$FM_CURRENCY_BASE_FORK_REPO_ITEM is unusable - $FM_CURRENCY_BASE_REASON"
      return 1
      ;;
  esac
  for remote in fork origin; do
    url=$(git -C "$fm_root" remote get-url "$remote" 2>/dev/null) || continue
    [ -n "$url" ] || continue
    FM_CURRENCY_BASE_VALUE=$url
    FM_CURRENCY_BASE_SOURCE="the $remote remote"
    return 0
  done
  FM_CURRENCY_BASE_REASON="the curated fork's own URL cannot be resolved: nothing is configured in config/$FM_CURRENCY_BASE_FORK_REPO_ITEM and $fm_root has neither a fork nor an origin remote"
  return 1
}
