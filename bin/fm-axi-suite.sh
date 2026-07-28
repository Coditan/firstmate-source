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
# successful check clears it. state/axi-suite-prefix-v1.ready records that every
# installed suite command has a vessel copy, so a pre-cutover cadence stamp can
# never postpone the first isolated install.
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
  local tool=$1 spec=$2 hint quoted_prefix quoted_tool
  printf -v quoted_prefix '%q' "$AXI_PREFIX"
  printf -v quoted_tool '%q' "$AXI_BIN/$tool"
  hint="npm install -g --prefix $quoted_prefix $spec"
  is_hook_tool "$tool" && hint="$hint && $quoted_tool setup hooks"
  printf '%s' "$hint"
}

STAMP="$STATE/axi-suite-update.checked"
PREFIX_READY="$STATE/axi-suite-prefix-v1.ready"
DIAGNOSTICS="$STATE/axi-suite-update.diagnostics"
STUCK="$STATE/axi-suite-update.stuck"

emit_cached() {
  [ -f "$DIAGNOSTICS" ] && cat "$DIAGNOSTICS"
  [ -f "$STUCK" ] && cat "$STUCK"
}

now=$(date +%s 2>/dev/null || echo 0)
if [ "$FORCE" -ne 1 ] && [ -f "$STAMP" ] && [ -f "$PREFIX_READY" ]; then
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

install_home_tool() {
  local tool=$1 spec=$2 expected installed
  expected=$3
  if ! net_call npm install -g --prefix "$AXI_PREFIX" "$spec" >/dev/null 2>&1; then
    return 1
  fi
  installed=$(version_of "$(home_tool_path "$tool")")
  [ "$installed" = "$expected" ]
}

setup_home_hooks() {
  net_call "$(home_tool_path "$1")" setup hooks >/dev/null 2>&1
}

seed_home_tool() {
  local tool=$1 version=$2
  if ! install_home_tool "$tool" "$tool@$version" "$version"; then
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

for tool in $SUITE; do
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
  home_tool=$(home_tool_path "$tool")
  home_installed=0
  [ -x "$home_tool" ] && home_installed=1
  if [ "$installed" = "$latest" ]; then
    if [ "$home_installed" -eq 0 ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        printf 'AXI_SUITE_UPDATE: %s %s needs vessel-prefix installation\n' \
          "$tool" "$installed" >> "$tmp_diag"
        if is_hook_tool "$tool" && grep -q "^AXI_SUITE_STUCK: $tool " "$STUCK" 2>/dev/null; then
          printf 'AXI_SUITE_STUCK: %s hook setup retry pending (already at %s)\n' \
            "$tool" "$latest" >> "$tmp_stuck"
        fi
      else
        seed_home_tool "$tool" "$installed" || true
      fi
      continue
    fi
    if is_hook_tool "$tool" && grep -q "^AXI_SUITE_STUCK: $tool " "$STUCK" 2>/dev/null; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        printf 'AXI_SUITE_STUCK: %s hook setup retry pending (already at %s)\n' "$tool" "$latest" >> "$tmp_stuck"
      elif ! setup_home_hooks "$tool"; then
        printf 'AXI_SUITE_STUCK: %s hook setup failed (already at %s)\n' "$tool" "$latest" >> "$tmp_stuck"
      fi
    fi
    continue
  fi
  if version_gt "$installed" "$latest"; then
    if [ "$home_installed" -eq 0 ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        printf 'AXI_SUITE_UPDATE: %s %s needs vessel-prefix installation\n' \
          "$tool" "$installed" >> "$tmp_diag"
      else
        seed_home_tool "$tool" "$installed" || true
      fi
    fi
    continue
  fi
  if [ "$(major_of "$installed")" != "$(major_of "$latest")" ]; then
    printf 'AXI_SUITE_REVIEW: %s major update %s -> %s (install: %s)\n' \
      "$tool" "$installed" "$latest" "$(install_hint "$tool" "$tool@$latest")" >> "$tmp_diag"
    if [ "$home_installed" -eq 0 ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        printf 'AXI_SUITE_UPDATE: %s %s needs vessel-prefix installation\n' \
          "$tool" "$installed" >> "$tmp_diag"
      else
        seed_home_tool "$tool" "$installed" || true
      fi
    fi
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
  prefix_ready=1
  for tool in $SUITE; do
    if command -v "$tool" >/dev/null 2>&1 && [ ! -x "$(home_tool_path "$tool")" ]; then
      prefix_ready=0
      break
    fi
  done
  if [ "$prefix_ready" -eq 1 ]; then
    : > "$PREFIX_READY"
  else
    rm -f "$PREFIX_READY"
  fi
fi
cat "$tmp_diag" 2>/dev/null
cat "$tmp_stuck" 2>/dev/null
