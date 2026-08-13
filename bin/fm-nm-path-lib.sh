#!/usr/bin/env bash
# fm-nm-path-lib.sh - resolve the no-mistakes CLI this SEAT owns, without asking
# the caller's environment for it.
#
# Why this exists (2026-08-13, measured on the coditan vessel): the run-state
# reader's authoritative source is a no-mistakes run-step, and it reached the CLI
# only through whatever PATH its caller happened to carry. An interactive shell
# carries one because a login profile put ~/.no-mistakes/bin on it; a context
# that inherits nothing does not:
#
#   $ command -v no-mistakes
#   /home/coditan/.no-mistakes/bin/no-mistakes
#   $ env -i HOME=/home/coditan bash -lc 'command -v no-mistakes'
#   (nothing - the login PATH does not reach it)
#
# So the same task read two different ways at the same moment:
#
#   interactive: state: working  · source: run-step · validating (running)
#   stripped   : state: degraded · source: missing-dependency · cause: run-reader-missing
#
# and every unattended reader - a scheduled service, a hook, a fresh login, an
# independent reviewer session - was blind to run state. The blindness produced
# FALSE PENDING WORK rather than merely missing information: a reviewer that
# cannot observe a decision being resolved re-reports it as outstanding after
# every answer.
#
# Why resolving rather than placing it somewhere the world inherits: three
# accounts run agents on this machine, and each has its OWN install with its own
# state.sqlite and daemon socket. A single shared entry on a system PATH -
# /usr/local/bin/no-mistakes - would point some seat at another seat's binary and
# another seat's pipeline state, needs root this repo cannot assume, and is a
# machine fact no checkout can carry or verify. The install location is derived
# from HOME instead, which every seat has and no seat shares, so the same code is
# correct for all three without any of them editing a shell profile.
#
# What it deliberately does NOT do: win. fm_axi_prepend_path PREPENDS, because a
# home is meant to run the AXI copies it maintains. This library APPENDS, and
# only when the CLI is unreachable at all, because firstmate does not own the
# no-mistakes install and has no standing to change which binary an environment
# that already resolves one runs. That is what keeps the interactive path exactly
# as it was: where `command -v no-mistakes` already answers, this library is a
# no-op.
#
# It also does not invent an all-clear. When the CLI is neither on PATH nor at
# the install location, nothing is added and the caller's own missing-dependency
# report stands - bin/fm-crew-state.sh's `degraded · cause: run-reader-missing`
# is the answer that made this diagnosable, and resolving harder must never turn
# it into a quiet wrong reading.
#
# Pure and side-effect free apart from fm_nm_prepend_path, which edits PATH in
# the calling process only.

# The directory the no-mistakes installer puts the binary in.
#
# NO_MISTAKES_INSTALL_DIR and the ~/.no-mistakes/bin default are the installer's
# OWN contract, read from docs/install.sh at kunchenguid/no-mistakes on
# 2026-08-13: `INSTALL_DIR="${NO_MISTAKES_INSTALL_DIR:-$HOME/.no-mistakes/bin}"`.
# Firstmate adds no variable of its own here, because a second name for one
# location is a second thing to keep true. NM_HOME is deliberately NOT consulted:
# it relocates no-mistakes' STATE (bin/fm-gate-refuse-lib.sh reads
# <NM_HOME>/repos and <NM_HOME>/worktrees), and nothing verifies it moves the
# binary, so honouring it here would be a guess wearing a variable's name.
#
# Fails when there is no HOME to derive from and no explicit override, which is
# an environment that cannot say where the install is - the caller then keeps its
# own missing-dependency answer rather than being handed a guessed directory.
fm_nm_bin_dir() {
  if [ -n "${NO_MISTAKES_INSTALL_DIR:-}" ]; then
    printf '%s' "${NO_MISTAKES_INSTALL_DIR%/}"
    return 0
  fi
  [ -n "${HOME:-}" ] || return 1
  printf '%s/.no-mistakes/bin' "${HOME%/}"
}

# The executable this seat's install provides, or failure when it has none.
fm_nm_installed_cli() {
  local bin
  bin=$(fm_nm_bin_dir) || return 1
  [ -x "$bin/no-mistakes" ] || return 1
  printf '%s/no-mistakes' "$bin"
}

# Make the CLI reachable from THIS process, and report whether it now is.
#
# Returns 0 when a `no-mistakes` will run - either the caller's environment
# already reached one and PATH is untouched, or this seat's install was appended
# to it. Returns 1 when neither is true, and changes nothing in that case: an
# absent dependency stays absent, and its caller's report about it stays correct.
#
# PATH is exported, because the reader shells out to the CLI in child processes.
#
# Named for what it guarantees rather than for how: `prepend` would be a false
# name here, and the direction is the whole point of the function.
fm_nm_ensure_reachable() {
  local bin
  command -v no-mistakes >/dev/null 2>&1 && return 0
  fm_nm_installed_cli >/dev/null 2>&1 || return 1
  bin=$(fm_nm_bin_dir) || return 1
  case ":${PATH:-}:" in
    *":$bin:"*) ;;
    *) PATH="${PATH:+$PATH:}$bin" ;;
  esac
  export PATH
  command -v no-mistakes >/dev/null 2>&1
}

# 0 when a context whose PATH is <path>, and which inherits nothing else, would
# reach the CLI once this library has resolved it; non-zero when it would not.
#
# This is the question a startup assertion has to ask, and it is NOT the question
# `command -v no-mistakes` answers in an interactive session. That one asks
# whether the OPERATOR can run it, which stayed true through every week of the
# blindness. This one asks whether the run-state reader can, in the environment
# it actually runs in.
#
# The install location is read from this process's own HOME on purpose: an
# unattended context on this seat has the same HOME, so the answer is about the
# seat rather than about the shell asking.
fm_nm_reaches() {  # <path>
  PATH="${1:-}" command -v no-mistakes >/dev/null 2>&1 && return 0
  fm_nm_installed_cli >/dev/null 2>&1
}
