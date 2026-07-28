#!/usr/bin/env bash
# Resolve the npm prefix owned by one Firstmate operational home.
#
# Usage:
#   . bin/fm-axi-path-lib.sh
#   fm_axi_prefix [<home>]       # prints <home>/.local/axi
#   fm_axi_bin_dir [<home>]      # prints <home>/.local/axi/bin
#   fm_axi_prepend_path [<home>] # exports that bin directory first on PATH
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
