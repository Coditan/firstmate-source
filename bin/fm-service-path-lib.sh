#!/usr/bin/env bash
# fm-service-path-lib.sh - the PATH a firstmate BACKGROUND SERVICE runs with.
#
# Why this exists (2026-08-04, verified on the coditan vessel): systemd's user
# manager gives a unit that sets no PATH the compiled-in default
# "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin".
# systemd/fm-watch@.service set none, so the watcher ran with a PATH that reached
# neither the no-mistakes CLI (~/.no-mistakes/bin) nor gh (~/.local/bin).  Every
# tool lookup those two feed then failed SILENTLY:
#   - bin/fm-crew-state.sh skipped its authoritative run-step read entirely
#     (`command -v no-mistakes` false) and answered `unknown - none`, so
#     crew_is_provably_working was false for every crew and fm-watch.sh's
#     ladder-hold branch fired 0 times in 2027 triage entries;
#   - bin/fm-pr-poll.sh's `gh pr view ... || exit 0` read as "PR not merged yet"
#     for every poll.
# Neither surfaced as an error, because a missing tool and a quiet fleet produce
# the same output.  A service must therefore RESOLVE the tools it depends on
# instead of inheriting whatever environment its launcher happened to have.
#
# Why a resolved PATH rather than absolute paths at each point of use:
#   1. It is not one tool.  The watcher and its children reach for no-mistakes,
#      gh or glab, git, jq and the session-provider CLI, and a registered custom
#      state/<id>.check.sh is an operator-written script that may call anything.
#      Absolute resolution needs one variable per tool and still cannot cover the
#      custom checks.
#   2. PATH is inherited by every child, so one resolved value fixes all of them
#      at once and cannot rot as new call sites are added.
#   3. It stays correct per deployment: the value is built from where THIS
#      installation actually keeps its tools, not from a hardcoded guess.
# The composed value is deterministic given the same installed tool set (fixed
# tool list, first-match directory each, fixed base tail), so it does not churn
# with the launching shell's own PATH ordering and cannot restart the service on
# every convergence.
#
# Pure and side-effect free: every function reads `command -v` and prints.

# Tools a firstmate background service may need to resolve.  Order is fixed
# because it determines the composed PATH's order; a tool that is not installed
# simply contributes no directory.  Over-inclusion is harmless, so this list is
# firstmate's whole plausible service toolchain rather than a per-service subset.
#
# The AXI suite leads the list because a home maintains its own copies under
# $FM_HOME/.local/axi/bin: whichever copy the composing session resolves is the
# one the service will run, so a caller that wants the maintained copies must
# prepend that prefix (fm_axi_prepend_path) before composing. Listing them first
# also puts that directory first in the composed value.
FM_SERVICE_TOOLS_DEFAULT='quota-axi gh-axi tasks-axi gnhf lavish-axi chrome-devtools-axi no-mistakes git gh glab jq node tmux herdr zellij orca cmux treehouse'

# Tools whose ABSENCE from a service's PATH silently degrades supervision rather
# than failing loudly, so bootstrap reports them.  Deliberately narrow: these two
# are what the authoritative crew-state read needs.  A missing session-provider
# CLI is caught at runtime instead, by bin/fm-crew-state.sh's `degraded`
# verdict, because which provider a home uses is a per-task fact.
FM_SERVICE_REQUIRED_TOOLS_DEFAULT='no-mistakes git'

# The tail every composed service PATH ends with, so system tools stay reachable
# even when the composing session's own PATH is unusual.  Matches systemd's user
# default minus the games/snap entries firstmate never calls.
FM_SERVICE_PATH_BASE_DEFAULT='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# Print the PATH a background service should run with: the directory of each
# resolvable tool from the tool list, in list order and de-duplicated, followed
# by the base tail.  Resolution uses the CALLER's PATH, so the converging
# session's reach is what gets recorded - that is the point, and
# fm_service_path_unreachable is how a converging session with poor reach is
# caught rather than trusted.
fm_service_path() {
  local tools tool dir resolved base out=''
  base=${FM_SERVICE_PATH_BASE:-$FM_SERVICE_PATH_BASE_DEFAULT}
  tools=${FM_SERVICE_TOOLS:-$FM_SERVICE_TOOLS_DEFAULT}
  for tool in $tools; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    case "$resolved" in /*) ;; *) continue ;; esac
    dir=${resolved%/*}
    [ -n "$dir" ] || continue
    case ":$out:$base:" in
      *":$dir:"*) continue ;;
    esac
    if [ -z "$out" ]; then out=$dir; else out="$out:$dir"; fi
  done
  if [ -z "$out" ]; then
    printf '%s' "$base"
    return 0
  fi
  printf '%s:%s' "$out" "$base"
}

# Print, one per line, each required tool that is INSTALLED on this machine but
# that <path> cannot reach; print nothing when the path reaches them all.
#
# Deliberately scoped to installed-but-unreachable rather than simply missing: a
# tool that is not installed at all is already owned and reported by bootstrap's
# toolchain check, and repeating it here would give one fact two owners. What
# only this check can see is the specific failure that hid for weeks - the tool
# is present, the operator can run it, and the background service cannot.
fm_service_path_unreachable() {  # <path>
  local path=$1 tools tool
  tools=${FM_SERVICE_REQUIRED_TOOLS:-$FM_SERVICE_REQUIRED_TOOLS_DEFAULT}
  for tool in $tools; do
    command -v "$tool" >/dev/null 2>&1 || continue
    PATH="$path" command -v "$tool" >/dev/null 2>&1 || printf '%s\n' "$tool"
  done
  return 0
}
