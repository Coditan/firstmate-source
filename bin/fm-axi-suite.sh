#!/usr/bin/env bash
# Keep the npm-distributed kunchenguid AXI CLI suite current.
#
# Usage: fm-axi-suite.sh [--check-only] [--force]
#   --check-only  report eligible patch/minor updates as AXI_SUITE_UPDATE:
#                 instead of installing them, and skip any pending hook-setup
#                 retry for an already-current tool (report it as
#                 AXI_SUITE_STUCK: ... retry pending instead).
#   --force       run the check now regardless of the cadence stamp.
#
# The default cadence is once every 24 hours per FM_HOME. Every home owns the
# npm prefix $FM_HOME/.local/axi, whose bin directory resolves before inherited
# PATH entries. A normal check seeds an absent home copy from the installed
# version on PATH, or directly installs an eligible patch/minor release there.
# Existing external installs are fallback inputs only and are never modified or
# removed. Major releases and missing suite commands are reported for review
# and never installed. A failed registry lookup or update is recorded in
# state/axi-suite-update.stuck and reported on every later invocation until a
# successful check clears it. state/axi-suite-prefix-v1.cutover records that this
# home has already attempted the isolated seeding once, so a pre-cutover cadence
# stamp cannot postpone the cutover while a failed attempt still costs at most
# one sweep per cadence window instead of one per session.
#
# A vessel copy that answers without a version would otherwise shadow an intact
# external copy forever, so it is removed and reseeded instead of trusted. One
# that never answers at all is reported and left in place, because a bounded
# probe cannot tell a hung copy from a very slow working one, and so is one that
# was never run because the probe budget was already spent.
#
# Hook setup for the hook-owning tools stays a shared user-global write that no
# prefix can isolate; it is invoked by name through the vessel bin directory so
# every home writes the same PATH-portable command (docs/configuration.md
# "AXI-suite self-update" owns that boundary).
#
# FM_AXI_SUITE_CHECK_INTERVAL overrides the cadence in seconds. Set it to 0 to
# check every time. FM_AXI_SUITE_DISABLE=1 disables the mechanism (tests and
# emergency diagnosis only). FM_AXI_SUITE_NETWORK_TIMEOUT bounds the whole
# suite's cumulative registry lookup, install, and hook-setup time in seconds
# (default 30), so an unreachable registry cannot multiply the stall across
# every tool in the suite. FM_AXI_SUITE_PROBE_TIMEOUT bounds the suite's
# cumulative local `--version` probing in seconds (default 15).
# FM_AXI_SUITE_SEED_TIMEOUT bounds the one-time installs that give a fresh
# vessel its own copies (default 120), because a first cutover installs the
# whole suite at once and would otherwise exhaust the steady-state network
# budget and report a healthy vessel as stuck. Each budget is charged only for
# the time its own calls spend, so no kind of work can consume another's.
# Seeding reports its progress and a closing summary on stderr - live when
# bootstrap is run directly in a terminal, and captured with the rest of the
# bootstrap output under automated session start. A seed that genuinely stalls
# or outlives the seeding budget is still reported as AXI_SUITE_STUCK, names
# which of the two happened, and is retried on the next cadence window.
# FM_AXI_SUITE_TOOLS overrides the space-separated
# suite tool list (default: quota-axi gh-axi tasks-axi gnhf lavish-axi
# chrome-devtools-axi).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
AXI_PREFIX=$(fm_axi_prefix "$FM_HOME")
AXI_BIN=$(fm_axi_bin_dir "$FM_HOME")
fm_axi_prepend_path "$FM_HOME"
INTERVAL=${FM_AXI_SUITE_CHECK_INTERVAL:-86400}
CHECK_ONLY=0
FORCE=0
SUITE="${FM_AXI_SUITE_TOOLS:-quota-axi gh-axi tasks-axi gnhf lavish-axi chrome-devtools-axi}"
NET_TIMEOUT=${FM_AXI_SUITE_NETWORK_TIMEOUT:-30}
PROBE_TIMEOUT=${FM_AXI_SUITE_PROBE_TIMEOUT:-15}
SEED_TIMEOUT=${FM_AXI_SUITE_SEED_TIMEOUT:-120}

while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "usage: fm-axi-suite.sh [--check-only] [--force]" >&2; exit 2 ;;
  esac
  shift
done

[ "${FM_AXI_SUITE_DISABLE:-0}" = 1 ] && exit 0
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=86400 ;; esac
case "$NET_TIMEOUT" in ''|*[!0-9]*) NET_TIMEOUT=30 ;; esac
case "$PROBE_TIMEOUT" in ''|*[!0-9]*) PROBE_TIMEOUT=15 ;; esac
case "$SEED_TIMEOUT" in ''|*[!0-9]*) SEED_TIMEOUT=120 ;; esac

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi
bounded() {
  local call_timeout=$1
  shift
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$call_timeout" "$@" ;;
    gtimeout) gtimeout "$call_timeout" "$@" ;;
    *)
      local cmd_pid status
      set -m
      "$@" &
      cmd_pid=$!
      set +m
      # The watchdog must not inherit the caller's stdout: a command
      # substitution stays open until every writer closes the pipe, so an
      # attached watchdog would hold a fast call open for its whole budget.
      ( sleep "$call_timeout"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
      local watchdog_pid=$!
      wait "$cmd_pid" 2>/dev/null
      status=$?
      kill "$watchdog_pid" 2>/dev/null
      wait "$watchdog_pid" 2>/dev/null
      return "$status"
      ;;
  esac
}

# Each budget is an accumulator over the time its own calls actually spend, not
# a wall-clock deadline: a deadline would let one kind of work drain another's
# budget even though they bound unrelated failure modes. Callers must therefore
# stay in this shell - running a budgeted call inside a command substitution
# would discard the charge it made.
#
# The three budgets exist because their work has three different shapes: steady
# registry and update traffic (net), running a local suite binary (probe), and
# the one-time installs that give a fresh vessel its own copies (seed). Seeding
# is charged separately because a first cutover installs the whole suite at
# once, which would otherwise exhaust the tight steady-state network budget and
# report a healthy vessel as stuck.
NET_SPENT=0
PROBE_SPENT=0
SEED_SPENT=0
PROBE_GRANTED=0
SEED_GRANTED=0
BUDGET_GRANTED=0
BUDGET_SPENT_DELTA=0

budget_grant() {
  local rem
  rem=$(($1 - $2))
  [ "$rem" -gt 0 ] || rem=0
  printf '%s' "$rem"
}

seconds_since() {
  local now spent
  now=$(date +%s 2>/dev/null || echo 0)
  spent=$((now - $1))
  [ "$spent" -ge 0 ] || spent=0
  printf '%s' "$spent"
}

# Runs one bounded call against <cap> given <already-spent>, publishing the
# granted budget and the time the call actually consumed so each wrapper can
# charge its own accumulator. Returns 124 without running anything at all once
# that budget is spent.
run_budgeted() {
  local cap=$1 spent=$2 started status=0
  shift 2
  BUDGET_SPENT_DELTA=0
  BUDGET_GRANTED=$(budget_grant "$cap" "$spent")
  [ "$BUDGET_GRANTED" -gt 0 ] || return 124
  started=$(date +%s 2>/dev/null || echo 0)
  bounded "$BUDGET_GRANTED" "$@" || status=$?
  BUDGET_SPENT_DELTA=$(seconds_since "$started")
  return "$status"
}

# Bounds the whole suite's cumulative registry and update exposure to
# NET_TIMEOUT instead of NET_TIMEOUT per tool, so an unreachable registry
# cannot multiply the stall across every entry in FM_AXI_SUITE_TOOLS.
net_call() {
  local status=0
  run_budgeted "$NET_TIMEOUT" "$NET_SPENT" "$@" || status=$?
  NET_SPENT=$((NET_SPENT + BUDGET_SPENT_DELTA))
  return "$status"
}

# Running a local suite binary is its own stall risk: a half-installed shim can
# hang instead of exiting, and it must never wedge bootstrap or session start.
# PROBE_GRANTED is 0 when the budget was already spent, which tells a caller
# that the binary was never run rather than that it failed to answer.
probe_call() {
  local status=0
  run_budgeted "$PROBE_TIMEOUT" "$PROBE_SPENT" "$@" || status=$?
  PROBE_SPENT=$((PROBE_SPENT + BUDGET_SPENT_DELTA))
  PROBE_GRANTED=$BUDGET_GRANTED
  return "$status"
}

# The one-time installs that give this vessel its own copies. SEED_GRANTED is 0
# when the budget was already spent, which separates "never attempted" from an
# install that ran and failed.
seed_call() {
  local status=0
  run_budgeted "$SEED_TIMEOUT" "$SEED_SPENT" "$@" || status=$?
  SEED_SPENT=$((SEED_SPENT + BUDGET_SPENT_DELTA))
  SEED_GRANTED=$BUDGET_GRANTED
  return "$status"
}

is_hook_tool() {
  case "$1" in
    gh-axi|chrome-devtools-axi|lavish-axi) return 0 ;;
    *) return 1 ;;
  esac
}

install_hint() {
  local tool=$1 spec=$2 hint quoted_prefix quoted_bin
  printf -v quoted_prefix '%q' "$AXI_PREFIX"
  printf -v quoted_bin '%q' "$AXI_BIN"
  hint="npm install -g --prefix $quoted_prefix $spec"
  is_hook_tool "$tool" && hint="$hint && PATH=$quoted_bin:\$PATH $tool setup hooks"
  printf '%s' "$hint"
}

STAMP="$STATE/axi-suite-update.checked"
PREFIX_CUTOVER="$STATE/axi-suite-prefix-v1.cutover"
DIAGNOSTICS="$STATE/axi-suite-update.diagnostics"
STUCK="$STATE/axi-suite-update.stuck"

emit_cached() {
  [ -f "$DIAGNOSTICS" ] && cat "$DIAGNOSTICS"
  [ -f "$STUCK" ] && cat "$STUCK"
}

now=$(date +%s 2>/dev/null || echo 0)
if [ "$FORCE" -ne 1 ] && [ -f "$STAMP" ] && [ -f "$PREFIX_CUTOVER" ]; then
  checked=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  if [ "$now" -ge "$checked" ] && [ $((now - checked)) -lt "$INTERVAL" ]; then
    emit_cached
    exit 0
  fi
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "AXI_SUITE_STUCK: cannot create state directory $STATE"
  exit 0
}

tmp_diag=$(mktemp "${TMPDIR:-/tmp}/fm-axi-suite-diag.XXXXXX") || exit 0
tmp_stuck=$(mktemp "${TMPDIR:-/tmp}/fm-axi-suite-stuck.XXXXXX") || { rm -f "$tmp_diag"; exit 0; }
tmp_diag_persist=$(mktemp "${TMPDIR:-/tmp}/fm-axi-suite-diag-persist.XXXXXX") || { rm -f "$tmp_diag" "$tmp_stuck"; exit 0; }
tmp_read=$(mktemp "${TMPDIR:-/tmp}/fm-axi-suite-read.XXXXXX") || { rm -f "$tmp_diag" "$tmp_stuck" "$tmp_diag_persist"; exit 0; }
trap 'rm -f "$tmp_diag" "$tmp_stuck" "$tmp_diag_persist" "$tmp_read"' EXIT

# Reads one binary's version under the probe budget with stdin closed, and
# publishes both halves of the answer: VERSION_READ is the parsed version and
# VERSION_PROBE separates a copy that answered without a version (empty, and
# therefore replaceable) from one that ran but never answered (timeout) and one
# that was never run because the probe budget was already spent (skipped).
# Only `empty` is evidence about the binary itself, so only `empty` may lead to
# a removal. Every caller reuses the published values rather than probing the
# same binary twice. The probe writes to a file because a command substitution
# would run the budgeted call in a subshell and discard its charge.
VERSION_READ=
VERSION_PROBE=empty
read_version() {
  local status=0
  VERSION_READ=
  VERSION_PROBE=empty
  : > "$tmp_read"
  probe_call "$1" --version </dev/null >"$tmp_read" 2>/dev/null || status=$?
  VERSION_READ=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$tmp_read" 2>/dev/null | head -n 1)
  if [ -n "$VERSION_READ" ]; then
    VERSION_PROBE=ok
  elif [ "$PROBE_GRANTED" -eq 0 ]; then
    VERSION_PROBE=skipped
  else
    case "$status" in 124|137|143) VERSION_PROBE=timeout ;; esac
  fi
}

major_of() {
  printf '%s\n' "$1" | cut -d. -f1
}

version_gt() {
  [ "$1" = "$2" ] && return 1
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$a1" -eq "$b1" ] 2>/dev/null || { [ "$a1" -gt "$b1" ] 2>/dev/null; return; }
  [ "$a2" -eq "$b2" ] 2>/dev/null || { [ "$a2" -gt "$b2" ] 2>/dev/null; return; }
  [ "$a3" -gt "$b3" ] 2>/dev/null
}

home_tool_path() {
  printf '%s/%s\n' "$AXI_BIN" "$1"
}

# The vessel bin directory resolves before every inherited PATH entry, so a
# vessel copy that cannot report its version shadows an intact external copy for
# every consumer. Dropping it restores that fallback and lets the normal seeding
# path reinstall from a version that can actually be read. The caller owns the
# readability verdict; this only performs the removal.
discard_home_tool() {
  local path
  path=$(home_tool_path "$1")
  [ -e "$path" ] || return 0
  rm -f "$path" 2>/dev/null
  hash -r 2>/dev/null || true
  [ ! -e "$path" ]
}

# Seeding can take much longer than a steady-state check, so it says which tool
# it is installing and how much of the seeding budget is left. These lines go to
# stderr, separate from the diagnostics stdout carries.
#
# How live that is depends on the caller: a captain running bin/fm-bootstrap.sh
# in a terminal sees each line as the work happens, but bin/fm-session-start.sh
# captures bootstrap with `2>&1` inside a command substitution, so under
# automated session start these lines are buffered with everything else and
# reach the digest only once bootstrap returns. The per-tool lines and the
# closing summary are therefore written to be readable after the fact as well:
# together they say how far the pass got and how much budget it consumed, which
# is what makes a later AXI_SUITE_STUCK budget line interpretable.
SEEDING_ANNOUNCED=0
SEEDED_COUNT=0
announce_seeding() {
  local spec=$1 left
  left=$(budget_grant "$SEED_TIMEOUT" "$SEED_SPENT")
  if [ "$SEEDING_ANNOUNCED" -eq 0 ]; then
    SEEDING_ANNOUNCED=1
    printf 'fm-axi-suite.sh: seeding this vessel AXI prefix (%s) for the first time; these installs run under a separate %ss seeding budget, so this check takes longer than a steady-state one\n' \
      "$AXI_PREFIX" "$SEED_TIMEOUT" >&2
  fi
  SEEDED_COUNT=$((SEEDED_COUNT + 1))
  printf 'fm-axi-suite.sh: installing %s into %s (%ss of the seeding budget left)\n' \
    "$spec" "$AXI_PREFIX" "$left" >&2
}

summarize_seeding() {
  [ "$SEEDING_ANNOUNCED" -eq 1 ] || return 0
  printf 'fm-axi-suite.sh: seeding pass finished: %s install(s) attempted into %s, %ss of the %ss seeding budget used\n' \
    "$SEEDED_COUNT" "$AXI_PREFIX" "$SEED_SPENT" "$SEED_TIMEOUT" >&2
}

# An install that creates the vessel's copy is first-cutover seeding; one that
# replaces an existing vessel copy is an ordinary update. Deriving the budget
# from the copy itself keeps the two entry points - seed_home_tool and the
# patch/minor update path - from drifting apart.
INSTALL_BUDGET=net
install_home_tool() {
  local tool=$1 spec=$2 expected path status=0 install_status=0
  expected=$3
  path=$(home_tool_path "$tool")
  if [ -x "$path" ]; then
    INSTALL_BUDGET=net
    net_call npm install -g --prefix "$AXI_PREFIX" "$spec" >/dev/null 2>&1 || install_status=$?
  else
    INSTALL_BUDGET=seed
    SEED_GRANTED=0
    if [ "$(budget_grant "$SEED_TIMEOUT" "$SEED_SPENT")" -gt 0 ]; then
      announce_seeding "$spec"
    fi
    seed_call npm install -g --prefix "$AXI_PREFIX" "$spec" >/dev/null 2>&1 || install_status=$?
  fi
  if [ "$install_status" -eq 0 ]; then
    read_version "$path"
    if [ "$VERSION_PROBE" = skipped ]; then
      status=0
    elif [ "$VERSION_READ" != "$expected" ]; then
      status=1
    fi
  else
    status=1
    VERSION_READ=
    VERSION_PROBE=skipped
    [ ! -x "$path" ] || read_version "$path"
  fi
  if [ "$status" -ne 0 ] && [ -e "$path" ] && [ "$VERSION_PROBE" = empty ]; then
    discard_home_tool "$tool" || true
  fi
  return "$status"
}

setup_home_hooks() {
  local tool=$1
  net_call env PATH="$AXI_BIN:$PATH" "$tool" setup hooks >/dev/null 2>&1
}

# Both install call sites can be the one that seeds this vessel, so both must
# describe a spent seeding budget the same way: an install that was never
# allowed to start is not a broken install. Reporting it from the state
# install_home_tool published keeps the two descriptions from drifting apart.
report_unattempted_seed() {
  [ "$INSTALL_BUDGET" = seed ] && [ "$SEED_GRANTED" -eq 0 ] || return 1
  printf 'AXI_SUITE_STUCK: %s vessel-prefix seeding at %s was not attempted: the %ss seeding budget is spent; the external copy stays the fallback and the next check retries\n' \
    "$1" "$AXI_PREFIX" "$SEED_TIMEOUT" >> "$tmp_stuck"
}

seed_home_tool() {
  local tool=$1 version=$2 registry_latest=${3:-}
  if ! install_home_tool "$tool" "$tool@$version" "$version"; then
    if report_unattempted_seed "$tool"; then
      return 1
    fi
    if [ -n "$registry_latest" ]; then
      printf 'AXI_SUITE_REVIEW: %s %s is ahead of registry latest %s and is not installable into %s; the external copy stays the fallback until it is published or %s is accepted (install: %s)\n' \
        "$tool" "$version" "$registry_latest" "$AXI_PREFIX" "$registry_latest" \
        "$(install_hint "$tool" "$tool@$registry_latest")" >> "$tmp_diag"
      return 1
    fi
    printf 'AXI_SUITE_STUCK: %s vessel-prefix installation at %s failed\n' \
      "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
    return 1
  fi
  if is_hook_tool "$tool" && ! setup_home_hooks "$tool"; then
    printf 'AXI_SUITE_STUCK: %s installed at %s but hook setup failed\n' \
      "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
    return 1
  fi
  printf 'AXI_SUITE_UPDATED: %s %s installed in vessel prefix\n' \
    "$tool" "$version" >> "$tmp_diag"
}

# Returns 0 when the vessel owns a copy once this call is done, 1 when it does
# not. HOME_COPY_ACTION records what this call did, so a caller can tell an
# untouched pre-existing copy (present) from one whose seeding - hook setup
# included - already ran in this pass (attempted) or was only reported
# (reported).
HOME_COPY_ACTION=present
ensure_home_copy() {
  local tool=$1 version=$2 registry_latest=${3:-}
  HOME_COPY_ACTION=present
  [ ! -x "$(home_tool_path "$tool")" ] || return 0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    HOME_COPY_ACTION=reported
    printf 'AXI_SUITE_UPDATE: %s %s needs vessel-prefix installation\n' \
      "$tool" "$version" >> "$tmp_diag"
    return 1
  fi
  HOME_COPY_ACTION=attempted
  seed_home_tool "$tool" "$version" "$registry_latest" || true
  [ -x "$(home_tool_path "$tool")" ]
}

for tool in $SUITE; do
  home_version=
  home_broken=0
  if [ -x "$(home_tool_path "$tool")" ]; then
    read_version "$(home_tool_path "$tool")"
    home_version=$VERSION_READ
    if [ -z "$home_version" ]; then
      if [ "$VERSION_PROBE" = timeout ]; then
        printf 'AXI_SUITE_STUCK: %s vessel copy at %s did not answer --version within %ss\n' \
          "$tool" "$AXI_PREFIX" "$PROBE_GRANTED" >> "$tmp_stuck"
        continue
      fi
      if [ "$VERSION_PROBE" = skipped ]; then
        printf 'AXI_SUITE_STUCK: %s vessel copy at %s was not checked: the %ss probe budget is spent\n' \
          "$tool" "$AXI_PREFIX" "$PROBE_TIMEOUT" >> "$tmp_stuck"
        continue
      fi
      home_broken=1
    fi
  fi
  if [ "$home_broken" -eq 1 ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      printf 'AXI_SUITE_STUCK: %s vessel copy at %s is unreadable (removal pending)\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
      continue
    fi
    if discard_home_tool "$tool"; then
      printf 'AXI_SUITE_UPDATED: %s unreadable vessel copy removed from %s\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_diag"
    else
      printf 'AXI_SUITE_STUCK: %s unreadable vessel copy at %s could not be removed\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
      continue
    fi
  fi
  if [ -n "$home_version" ]; then
    installed=$home_version
  else
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'AXI_SUITE_REVIEW: %s is not installed (install: %s)\n' "$tool" "$(install_hint "$tool" "$tool")" >> "$tmp_diag"
      continue
    fi
    read_version "$tool"
    installed=$VERSION_READ
    if [ -z "$installed" ]; then
      if [ "$VERSION_PROBE" = skipped ]; then
        printf 'AXI_SUITE_STUCK: %s was not checked: the %ss probe budget is spent\n' \
          "$tool" "$PROBE_TIMEOUT" >> "$tmp_stuck"
      else
        printf 'AXI_SUITE_STUCK: %s installed version could not be read\n' "$tool" >> "$tmp_stuck"
      fi
      continue
    fi
  fi
  : > "$tmp_read"
  if ! net_call npm view "$tool" version >"$tmp_read" 2>/dev/null; then
    printf 'AXI_SUITE_STUCK: %s latest version lookup failed\n' "$tool" >> "$tmp_stuck"
    continue
  fi
  latest=$(sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$tmp_read" 2>/dev/null | head -n 1)
  if [ -z "$latest" ]; then
    printf 'AXI_SUITE_STUCK: %s registry returned an invalid version\n' "$tool" >> "$tmp_stuck"
    continue
  fi
  if [ "$installed" = "$latest" ]; then
    home_present=0
    ensure_home_copy "$tool" "$installed" && home_present=1
    if is_hook_tool "$tool" && [ "$HOME_COPY_ACTION" != attempted ] \
      && grep -q "^AXI_SUITE_STUCK: $tool " "$STUCK" 2>/dev/null; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        printf 'AXI_SUITE_STUCK: %s hook setup retry pending (already at %s)\n' "$tool" "$latest" >> "$tmp_stuck"
      elif [ "$home_present" -eq 1 ] && ! setup_home_hooks "$tool"; then
        printf 'AXI_SUITE_STUCK: %s hook setup failed (already at %s)\n' "$tool" "$latest" >> "$tmp_stuck"
      fi
    fi
    continue
  fi
  if version_gt "$installed" "$latest"; then
    ensure_home_copy "$tool" "$installed" "$latest" || true
    continue
  fi
  if [ "$(major_of "$installed")" != "$(major_of "$latest")" ]; then
    printf 'AXI_SUITE_REVIEW: %s major update %s -> %s (install: %s)\n' \
      "$tool" "$installed" "$latest" "$(install_hint "$tool" "$tool@$latest")" >> "$tmp_diag"
    ensure_home_copy "$tool" "$installed" || true
    continue
  fi
  [ "$CHECK_ONLY" -eq 0 ] || {
    printf 'AXI_SUITE_UPDATE: %s %s -> %s is eligible for automatic update\n' "$tool" "$installed" "$latest" >> "$tmp_diag"
    continue
  }
  if ! install_home_tool "$tool" "$tool@$latest" "$latest"; then
    if ! report_unattempted_seed "$tool"; then
      printf 'AXI_SUITE_STUCK: %s automatic update %s -> %s failed (npm prefix %s)\n' \
        "$tool" "$installed" "$latest" "$AXI_PREFIX" >> "$tmp_stuck"
    fi
    continue
  fi
  if is_hook_tool "$tool" && ! setup_home_hooks "$tool"; then
    printf 'AXI_SUITE_STUCK: %s updated to %s but hook setup failed\n' "$tool" "$latest" >> "$tmp_stuck"
    continue
  fi
  printf 'AXI_SUITE_UPDATED: %s %s -> %s\n' "$tool" "$installed" "$latest" >> "$tmp_diag"
done

if [ "$CHECK_ONLY" -eq 0 ]; then
  if [ -s "$tmp_diag" ]; then
    grep -v '^AXI_SUITE_UPDATED:' "$tmp_diag" > "$tmp_diag_persist" 2>/dev/null || true
    if [ -s "$tmp_diag_persist" ]; then cp "$tmp_diag_persist" "$DIAGNOSTICS"; else rm -f "$DIAGNOSTICS"; fi
  else
    rm -f "$DIAGNOSTICS"
  fi
  if [ -s "$tmp_stuck" ]; then cp "$tmp_stuck" "$STUCK"; else rm -f "$STUCK"; fi
  summarize_seeding
  printf '%s\n' "$now" > "$STAMP"
  # Records the attempt, not its outcome: a home that could not seed every tool
  # retries on the next cadence window instead of paying a full sweep, and a
  # recurring alarm, on every single session.
  : > "$PREFIX_CUTOVER"
fi
cat "$tmp_diag" 2>/dev/null
cat "$tmp_stuck" 2>/dev/null
