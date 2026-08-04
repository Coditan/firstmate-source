#!/usr/bin/env bash
# Resolve the npm prefix owned by one Firstmate operational home.
#
# Usage:
#   . bin/fm-axi-path-lib.sh
#   fm_axi_prefix [<home>]       # prints <home>/.local/axi
#   fm_axi_bin_dir [<home>]      # prints <home>/.local/axi/bin
#   fm_axi_prepend_path [<home>] # exports that bin directory first on PATH
#   fm_axi_ambient_path          # the PATH before ANY firstmate prepend, or fail
#   fm_axi_shadowed <path> <home> <tool>...  # which maintained tools do not run
#
# The location is derived only from the home, so a fresh vessel needs no local
# configuration before bootstrap can install its AXI suite. With no argument the
# home is FM_HOME, and with neither it is this file's own checkout - the same
# "${FM_HOME:-$FM_ROOT}" fallback every bin/ script applies.
#
# That last fallback is what makes this file sourceable on its own, by anything
# that has no FM_HOME to offer, naming the checkout exactly once. An operator who
# wants his own shells to resolve the maintained copies can therefore source it
# from a login profile instead of remembering a PATH prefix at every launch
# (README.md "Install and launch"). Firstmate never writes that profile itself;
# see docs/configuration.md "AXI-suite self-update" for why the inherited login
# environment stays the operator's to change.
#
# That profile route prepends the directory printed by fm_axi_bin_dir and does NOT
# call fm_axi_prepend_path, because the ambient record below belongs to firstmate's
# own entrypoints: a login shell that claimed it would record its PRE-prepend PATH
# as the session's ambient one, and every session descending from that shell would
# then be told the maintained copies are shadowed while it is in fact running them.

# Self-locate at source time, and only on a positive identity check: a shell that
# cannot say where this file lives leaves the fallback empty and callers keep their
# existing "no home" failure, rather than prepending a guessed directory.
#
# BASH_SOURCE is named WITHOUT a subscript on purpose: bash expands the bare name
# to element 0, while a POSIX shell reading this file - /bin/sh being dash on
# Debian, which a login profile may well be - sees an ordinary unset scalar and
# takes the empty fallback. `${BASH_SOURCE[0]}` is a fatal "Bad substitution"
# there, which would abort the whole sourcing file rather than prepend nothing.
FM_AXI_LIB_ROOT=
if [ -n "${BASH_SOURCE:-}" ]; then
  FM_AXI_LIB_ROOT=$(cd "$(dirname "${BASH_SOURCE}")/.." 2>/dev/null && pwd || true)
  [ -f "$FM_AXI_LIB_ROOT/bin/fm-axi-path-lib.sh" ] || FM_AXI_LIB_ROOT=
fi

fm_axi_prefix() {
  local home=${1:-${FM_HOME:-$FM_AXI_LIB_ROOT}}
  [ -n "$home" ] || return 1
  printf '%s/.local/axi\n' "${home%/}"
}

fm_axi_bin_dir() {
  local prefix
  prefix=$(fm_axi_prefix "${1:-}") || return 1
  printf '%s/bin\n' "$prefix"
}

# The parent pid of <pid>, or failure when this machine will not say. /proc is
# tried first because a stripped PATH may not reach ps, which is the very kind of
# environment the callers of this library exist to diagnose. The sed strips
# through the LAST ")" so a command name containing spaces or parentheses cannot
# shift the field positions.
fm_axi_pid_parent() {  # <pid>
  local pid=$1 ppid=''
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    ppid=$(sed -e 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $2}')
  fi
  if [ -z "$ppid" ] && command -v ps >/dev/null 2>&1; then
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$ppid"
}

# 0 when <pid> is this process or one of its ancestors. Anything else - a pid
# that is gone, one in another tree, one this machine will not resolve, and pid 0
# or 1, which are never firstmate entrypoints - answers no, because the only
# question worth asking is whether THIS chain of firstmate processes recorded the
# value being offered.
fm_axi_pid_is_self_or_ancestor() {  # <pid>
  local want=$1 pid=$$ hops=0 parent
  case "$want" in ''|*[!0-9]*) return 1 ;; esac
  [ "$want" -gt 1 ] || return 1
  while [ "$hops" -lt 64 ]; do
    [ "$pid" = "$want" ] && return 0
    parent=$(fm_axi_pid_parent "$pid") || return 1
    [ "$parent" -gt 1 ] || return 1
    pid=$parent
    hops=$((hops + 1))
  done
  return 1
}

# Record the environment as the SESSION found it, before the first firstmate
# entrypoint replaces it. Exported so it survives into every child, because the
# entrypoints chain: fm-session-start.sh prepends and exports before spawning
# fm-bootstrap.sh, which prepends and exports before spawning fm-axi-suite.sh. A
# later prepender in the same chain must not overwrite it, or every downstream
# check would be handed an environment firstmate had already corrected, which is
# how the shadow report first shipped inert.
#
# But an exported value that is never overwritten has the lifetime of a process
# TREE, not of the session it describes, and a tree can outlive its session: when
# `tmux new-session` starts a server it freezes the launching environment into
# that server, and every pane created there afterwards inherits the snapshot.
# fm-watcher-service.sh prepends and then starts exactly such a server, so a
# firstmate session running months later inside that server could be handed a
# marker describing a session that is long gone - and answer confidently about
# it. So the marker carries the pid that recorded it, and is honoured only for
# that process and its descendants.
#
# A marker from another tree is not simply discarded, because this process may
# still know the answer: if its own PATH does not already lead with the
# maintained prefix, then nothing in ITS chain prepended, so its own PATH is the
# honest ambient one and is recorded afresh. Only when a foreign marker meets an
# already-prepended PATH is the question unanswerable here, and that is recorded
# as `unattributable` rather than guessed - see fm_axi_ambient_path.
#
# The value and its owner are ONE record, valid only together. A half-set pair -
# one half inherited or cleared without the other - is not a record this process
# may act on: an attributable owner means some ancestor prepended, so the missing
# value cannot be reconstructed from $PATH, and the ancestor may have prepended a
# DIFFERENT home's prefix, which the leading-entry test below cannot see. Guessing
# there would be the confident wrong answer this whole guard exists to prevent, so
# a half-set pair is unattributable outright.
fm_axi_ambient_claim() {  # <maintained-bin-dir>
  local bin=$1
  if [ -z "${FM_AXI_AMBIENT_PATH_OWNER+set}" ] && [ -z "${FM_AXI_AMBIENT_PATH+set}" ]; then
    FM_AXI_AMBIENT_PATH=${PATH:-}
    FM_AXI_AMBIENT_PATH_OWNER=$$
    export FM_AXI_AMBIENT_PATH FM_AXI_AMBIENT_PATH_OWNER
    return 0
  fi
  if [ -z "${FM_AXI_AMBIENT_PATH+set}" ] || [ -z "${FM_AXI_AMBIENT_PATH_OWNER+set}" ]; then
    FM_AXI_AMBIENT_PATH_OWNER=unattributable
    export FM_AXI_AMBIENT_PATH_OWNER
    return 0
  fi
  fm_axi_pid_is_self_or_ancestor "$FM_AXI_AMBIENT_PATH_OWNER" && return 0
  case "${PATH:-}" in
    "$bin"|"$bin":*)
      FM_AXI_AMBIENT_PATH_OWNER=unattributable
      export FM_AXI_AMBIENT_PATH_OWNER
      ;;
    *)
      FM_AXI_AMBIENT_PATH=${PATH:-}
      FM_AXI_AMBIENT_PATH_OWNER=$$
      export FM_AXI_AMBIENT_PATH FM_AXI_AMBIENT_PATH_OWNER
      ;;
  esac
}

fm_axi_prepend_path() {
  local bin
  bin=$(fm_axi_bin_dir "${1:-}") || return 1
  fm_axi_ambient_claim "$bin"
  case "${PATH:-}" in
    "$bin"|"$bin":*) ;;
    *) PATH="$bin${PATH:+:$PATH}" ;;
  esac
  export PATH
}

# The PATH the session had before any firstmate entrypoint prepended a maintained
# prefix, or NON-ZERO when this process cannot honestly say. Falling back to the
# current PATH in that case would be the original defect wearing a new hat: by
# then a prepend has already happened, so $PATH describes the correction rather
# than the environment. A caller that gets a failure here must report that it
# cannot tell, never an all-clear.
fm_axi_ambient_path() {
  if [ -z "${FM_AXI_AMBIENT_PATH_OWNER+set}" ] && [ -z "${FM_AXI_AMBIENT_PATH+set}" ]; then
    printf '%s' "${PATH:-}"
    return 0
  fi
  [ -n "${FM_AXI_AMBIENT_PATH+set}" ] || return 1
  [ -n "${FM_AXI_AMBIENT_PATH_OWNER+set}" ] || return 1
  fm_axi_pid_is_self_or_ancestor "$FM_AXI_AMBIENT_PATH_OWNER" || return 1
  printf '%s' "$FM_AXI_AMBIENT_PATH"
}

# Print "<tool><TAB><path that actually runs>" for every named tool that <path>
# resolves to something OTHER than this home's maintained copy; print nothing
# when the maintained copy is what runs. A tool that resolves nowhere at all is
# not shadowed - it is missing, which the currency check already owns. Neither is
# a tool this home maintains NO copy of: on an unseeded vessel the maintained bin
# directory is empty and every suite tool resolves externally, which is the
# ordinary pre-cutover state that the seeding and currency paths own, not six
# simultaneous shadow alarms.
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
# about the environment as it found it - and callers must source it from
# fm_axi_ambient_path rather than from their own pre-prepend $PATH, because by
# the time a check runs an outer firstmate entrypoint has usually prepended
# already and that $PATH no longer describes the session at all.
fm_axi_shadowed() {  # <path> <home> <tool>...
  local path=$1 home=$2 bin resolved tool
  shift 2
  bin=$(fm_axi_bin_dir "$home") || return 1
  for tool in "$@"; do
    [ -x "$bin/$tool" ] || continue
    resolved=$(PATH="$path" command -v "$tool" 2>/dev/null) || continue
    [ -n "$resolved" ] || continue
    [ "$resolved" = "$bin/$tool" ] && continue
    printf '%s\t%s\n' "$tool" "$resolved"
  done
  return 0
}
