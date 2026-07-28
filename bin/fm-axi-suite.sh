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
# A vessel copy whose version cannot be read would otherwise shadow an intact
# external copy forever, so it is removed and reseeded instead of trusted.
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
# every tool in the suite. FM_AXI_SUITE_TOOLS overrides the space-separated
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
      ( sleep "$call_timeout"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
      local watchdog_pid=$!
      wait "$cmd_pid" 2>/dev/null
      status=$?
      kill "$watchdog_pid" 2>/dev/null
      wait "$watchdog_pid" 2>/dev/null
      return "$status"
      ;;
  esac
}

PHASE_DEADLINE=$(( $(date +%s 2>/dev/null || echo 0) + NET_TIMEOUT ))
remaining_budget() {
  local now rem
  now=$(date +%s 2>/dev/null || echo 0)
  rem=$((PHASE_DEADLINE - now))
  [ "$rem" -gt 0 ] || rem=0
  [ "$rem" -le "$NET_TIMEOUT" ] || rem=$NET_TIMEOUT
  printf '%s' "$rem"
}

# Bounds the whole suite's cumulative network exposure to NET_TIMEOUT instead
# of NET_TIMEOUT per tool, so an unreachable registry cannot multiply the
# stall across every entry in FM_AXI_SUITE_TOOLS. Once the phase budget is
# spent, remaining calls fail fast without touching the network at all.
net_call() {
  local budget
  budget=$(remaining_budget)
  [ "$budget" -gt 0 ] || return 124
  bounded "$budget" "$@"
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
trap 'rm -f "$tmp_diag" "$tmp_stuck" "$tmp_diag_persist"' EXIT

version_of() {
  "$1" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
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

home_tool_is_readable() {
  [ -n "$(version_of "$(home_tool_path "$1")")" ]
}

# The vessel bin directory resolves before every inherited PATH entry, so a
# vessel copy that cannot report its version shadows an intact external copy for
# every consumer. Dropping it restores that fallback and lets the normal seeding
# path reinstall from a version that can actually be read.
discard_broken_home_tool() {
  local tool=$1 path
  path=$(home_tool_path "$tool")
  [ -e "$path" ] || return 0
  home_tool_is_readable "$tool" && return 0
  rm -f "$path" 2>/dev/null
  hash -r 2>/dev/null || true
  [ ! -e "$path" ]
}

install_home_tool() {
  local tool=$1 spec=$2 expected installed status=0
  expected=$3
  if ! net_call npm install -g --prefix "$AXI_PREFIX" "$spec" >/dev/null 2>&1; then
    status=1
  else
    installed=$(version_of "$(home_tool_path "$tool")")
    [ "$installed" = "$expected" ] || status=1
  fi
  [ "$status" -eq 0 ] || discard_broken_home_tool "$tool" >/dev/null 2>&1 || true
  return "$status"
}

setup_home_hooks() {
  local tool=$1
  net_call env PATH="$AXI_BIN:$PATH" "$tool" setup hooks >/dev/null 2>&1
}

seed_home_tool() {
  local tool=$1 version=$2 registry_latest=${3:-}
  if ! install_home_tool "$tool" "$tool@$version" "$version"; then
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

# Returns 0 when the vessel already owns a copy, 1 when this call reported or
# performed the seeding for an absent one.
ensure_home_copy() {
  local tool=$1 version=$2 registry_latest=${3:-}
  [ ! -x "$(home_tool_path "$tool")" ] || return 0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    printf 'AXI_SUITE_UPDATE: %s %s needs vessel-prefix installation\n' \
      "$tool" "$version" >> "$tmp_diag"
  else
    seed_home_tool "$tool" "$version" "$registry_latest" || true
  fi
  return 1
}

for tool in $SUITE; do
  if [ -x "$(home_tool_path "$tool")" ] && ! home_tool_is_readable "$tool"; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      printf 'AXI_SUITE_STUCK: %s vessel copy at %s is unreadable (removal pending)\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
      continue
    fi
    if discard_broken_home_tool "$tool"; then
      printf 'AXI_SUITE_UPDATED: %s unreadable vessel copy removed from %s\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_diag"
    else
      printf 'AXI_SUITE_STUCK: %s unreadable vessel copy at %s could not be removed\n' \
        "$tool" "$AXI_PREFIX" >> "$tmp_stuck"
      continue
    fi
  fi
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'AXI_SUITE_REVIEW: %s is not installed (install: %s)\n' "$tool" "$(install_hint "$tool" "$tool")" >> "$tmp_diag"
    continue
  fi
  installed=$(version_of "$tool")
  if [ -z "$installed" ]; then
    printf 'AXI_SUITE_STUCK: %s installed version could not be read\n' "$tool" >> "$tmp_stuck"
    continue
  fi
  if ! latest=$(net_call npm view "$tool" version 2>/dev/null); then
    printf 'AXI_SUITE_STUCK: %s latest version lookup failed\n' "$tool" >> "$tmp_stuck"
    continue
  fi
  latest=$(printf '%s\n' "$latest" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -n 1)
  if [ -z "$latest" ]; then
    printf 'AXI_SUITE_STUCK: %s registry returned an invalid version\n' "$tool" >> "$tmp_stuck"
    continue
  fi
  if [ "$installed" = "$latest" ]; then
    home_present=0
    ensure_home_copy "$tool" "$installed" && home_present=1
    if is_hook_tool "$tool" && grep -q "^AXI_SUITE_STUCK: $tool " "$STUCK" 2>/dev/null; then
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
    printf 'AXI_SUITE_STUCK: %s automatic update %s -> %s failed (npm prefix %s)\n' \
      "$tool" "$installed" "$latest" "$AXI_PREFIX" >> "$tmp_stuck"
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
  printf '%s\n' "$now" > "$STAMP"
  # Records the attempt, not its outcome: a home that could not seed every tool
  # retries on the next cadence window instead of paying a full sweep, and a
  # recurring alarm, on every single session.
  : > "$PREFIX_CUTOVER"
fi
cat "$tmp_diag" 2>/dev/null
cat "$tmp_stuck" 2>/dev/null
