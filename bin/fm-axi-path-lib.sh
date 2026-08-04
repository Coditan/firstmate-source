#!/usr/bin/env bash
# Resolve the npm prefix owned by one Firstmate operational home.
#
# Usage:
#   . bin/fm-axi-path-lib.sh
#   fm_axi_prefix [<home>]       # prints <home>/.local/axi
#   fm_axi_bin_dir [<home>]      # prints <home>/.local/axi/bin
#   fm_axi_prepend_path [<home>] # exports that bin directory first on PATH
#   fm_axi_shadowed <path> <home> <tool>...  # which maintained tools do not run
#
# The location is derived only from FM_HOME, so a fresh vessel needs no local
# configuration before bootstrap can install its AXI suite.

fm_axi_prefix() {
  local home=${1:-${FM_HOME:-}}
  [ -n "$home" ] || return 1
  printf '%s/.local/axi\n' "${home%/}"
}

fm_axi_bin_dir() {
  local prefix
  prefix=$(fm_axi_prefix "${1:-${FM_HOME:-}}") || return 1
  printf '%s/bin\n' "$prefix"
}

fm_axi_prepend_path() {
  local bin
  bin=$(fm_axi_bin_dir "${1:-${FM_HOME:-}}") || return 1
  case "${PATH:-}" in
    "$bin"|"$bin":*) ;;
    *) PATH="$bin${PATH:+:$PATH}" ;;
  esac
  export PATH
}

# Print "<tool><TAB><path that actually runs>" for every named tool that <path>
# resolves to something OTHER than this home's maintained copy; print nothing
# when the maintained copy is what runs. A tool that resolves nowhere at all is
# not shadowed - it is missing, which the currency check already owns.
#
# Why this exists (2026-08-04, hand-measured on the coditan vessel): every
# firstmate script that calls an AXI tool prepends the maintained bin directory
# INTO ITS OWN PROCESS, and fm-axi-suite.sh does the same before measuring. So
# the currency check has always measured the copy it maintains and never asked
# whether that copy is the one anything else runs. On that vessel a firstmate-home
# shell resolved all six tools from ~/.npm-global/bin, every one behind the
# maintained copy (quota-axi 0.1.14 against 0.1.17, gh-axi 0.1.28 against
# 0.1.29, and four more), while the check reported the suite current. The
# version gap is not the defect; a true all-clear about a copy nobody runs is.
# The <path> argument is passed in rather than read from the environment
# precisely so a caller that has already prepended its own prefix can still ask
# about the environment as it found it.
fm_axi_shadowed() {  # <path> <home> <tool>...
  local path=$1 home=$2 bin resolved tool
  shift 2
  bin=$(fm_axi_bin_dir "$home") || return 1
  for tool in "$@"; do
    resolved=$(PATH="$path" command -v "$tool" 2>/dev/null) || continue
    [ -n "$resolved" ] || continue
    [ "$resolved" = "$bin/$tool" ] && continue
    printf '%s\t%s\n' "$tool" "$resolved"
  done
  return 0
}
