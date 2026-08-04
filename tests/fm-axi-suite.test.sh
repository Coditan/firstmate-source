#!/usr/bin/env bash
# Isolated gating tests for AXI-suite self-update behavior.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-axi-suite-tests

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_tool() {
  local bin=$1 tool=$2 version=$3
  cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '$tool $version'; fi
SH
  chmod +x "$bin/$tool"
}

make_hook_tool() {
  local bin=$1 tool=$2 version=$3 hook_log=$4
  cat > "$bin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '$tool $version'; exit 0; fi
if [ "\${1:-}" = setup ] && [ "\${2:-}" = hooks ]; then printf '%s\n' '$tool setup hooks' >> '$hook_log'; exit 0; fi
SH
  chmod +x "$bin/$tool"
}

make_npm() {
  local bin=$1 versions=$2 log=$3
  cat > "$bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then
  sleep "${FM_TEST_VIEW_SLEEP:-0}"
  sed -n "s/^${2}=//p" "$FM_TEST_VERSIONS"
  exit 0
fi
if [ "${1:-}" = install ]; then
  printf '%s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
  shift
  prefix=
  spec=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) prefix=${2:-}; shift 2 ;;
      -g) shift ;;
      *) spec=$1; shift ;;
    esac
  done
  [ -n "$prefix" ] && [ -n "$spec" ] || exit 1
  tool=${spec%@*}
  version=${spec##*@}
  sleep "${FM_TEST_INSTALL_SLEEP:-0}"
  mkdir -p "$prefix/bin"
  cat > "$prefix/bin/$tool" <<TOOL
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '$tool $version'; exit 0; fi
if [ "\${1:-}" = setup ] && [ "\${2:-}" = hooks ]; then
  [ -z "\${FM_TEST_HOOK_LOG:-}" ] || printf '%s\n' '$tool setup hooks' >> "\$FM_TEST_HOOK_LOG"
  exit 0
fi
TOOL
  chmod +x "$prefix/bin/$tool"
  exit 0
fi
exit 1
SH
  chmod +x "$bin/npm"
  : > "$log"
  : > "$versions"
}

run_case() {
  local root=$1 tools=$2
  PATH="$root/bin:$BASE_PATH" FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="$tools" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$root/versions" FM_TEST_INSTALL_LOG="$root/install.log" \
    FM_TEST_HOOK_LOG="$root/hook.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force
}

test_patch_and_minor_auto_update() {
  local w out
  w="$TMP_ROOT/automatic"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" patch-axi 1.2.3
  make_tool "$w/bin" minor-axi 1.2.3
  sed -i "s/patch-axi 1.2.3/1.2.3/" "$w/bin/patch-axi"
  printf '%s\n' 'patch-axi=1.2.4' 'minor-axi=1.3.0' > "$w/versions"
  out=$(run_case "$w" "patch-axi minor-axi")
  assert_contains "$out" 'AXI_SUITE_UPDATED: patch-axi 1.2.3 -> 1.2.4' "patch update was not reported"
  assert_contains "$out" 'AXI_SUITE_UPDATED: minor-axi 1.2.3 -> 1.3.0' "minor update was not reported"
  assert_grep "--prefix $w/home/.local/axi patch-axi@1.2.4" "$w/install.log" "patch update did not target the vessel prefix"
  assert_grep "--prefix $w/home/.local/axi minor-axi@1.3.0" "$w/install.log" "minor update did not target the vessel prefix"
  [ "$("$w/bin/patch-axi" --version)" = '1.2.3' ] || fail "the pre-existing patch-axi install was modified"
  pass "patch and minor AXI-suite releases update only the vessel prefix"
}

test_major_and_missing_wait_for_review() {
  local w out
  w="$TMP_ROOT/review"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" major-axi 1.9.9
  printf '%s\n' 'major-axi=2.0.0' > "$w/versions"
  out=$(run_case "$w" "major-axi new-axi")
  assert_contains "$out" 'AXI_SUITE_REVIEW: major-axi major update 1.9.9 -> 2.0.0' "major update was not held"
  assert_contains "$out" 'AXI_SUITE_REVIEW: new-axi is not installed' "new tool was not held"
  assert_grep "--prefix $w/home/.local/axi major-axi@1.9.9" "$w/install.log" "the current major was not seeded into the vessel prefix"
  assert_no_grep 'major-axi@2.0.0' "$w/install.log" "the held major release was installed"
  pass "major releases wait for review while the current major seeds the vessel prefix"
}

test_failed_update_persists_stuck_signal() {
  local w out
  w="$TMP_ROOT/stuck"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" stuck-axi 1.0.0
  printf '%s\n' 'stuck-axi=1.0.1' > "$w/versions"
  sed -i 's/if \[ "${1:-}" = install \]; then/if [ "${1:-}" = install ]; then exit 1; fi\nif false; then/' "$w/bin/npm"
  out=$(run_case "$w" "stuck-axi")
  assert_contains "$out" 'AXI_SUITE_STUCK: stuck-axi automatic update 1.0.0 -> 1.0.1 failed' "failed update was not surfaced"
  assert_grep 'AXI_SUITE_STUCK:' "$w/state/axi-suite-update.stuck" "stuck signal was not persisted"
  pass "failed updates persist a local stuck signal"
}

test_check_only_never_runs_hook_setup() {
  local w out
  w="$TMP_ROOT/check-only-hooks"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_hook_tool "$w/bin" gh-axi 2.0.0 "$w/hook.log"
  : > "$w/hook.log"
  printf '%s\n' 'gh-axi=2.0.0' > "$w/versions"
  printf 'AXI_SUITE_STUCK: gh-axi hook setup failed (already at 2.0.0)\n' > "$w/state/axi-suite-update.stuck"
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="gh-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force --check-only)
  [ ! -s "$w/hook.log" ] || fail "check-only ran the mutating hook setup command"
  assert_contains "$out" 'AXI_SUITE_STUCK: gh-axi hook setup retry pending' "check-only did not report the pending hook retry"
  assert_grep 'AXI_SUITE_STUCK:' "$w/state/axi-suite-update.stuck" "check-only cleared the stuck signal"
  pass "check-only never mutates hooks and keeps reporting the pending retry"
}

test_hook_retry_self_clears_stuck_signal() {
  local w out
  w="$TMP_ROOT/hook-retry"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_hook_tool "$w/bin" gh-axi 2.0.0 "$w/hook.log"
  : > "$w/hook.log"
  printf '%s\n' 'gh-axi=2.0.0' > "$w/versions"
  printf 'AXI_SUITE_STUCK: gh-axi hook setup failed (already at 2.0.0)\n' > "$w/state/axi-suite-update.stuck"
  run_case "$w" "gh-axi" >/dev/null
  assert_grep 'gh-axi setup hooks' "$w/hook.log" "a normal run did not retry hook setup"
  [ ! -f "$w/state/axi-suite-update.stuck" ] || fail "stuck signal was not self-cleared after a successful hook retry"
  pass "a successful hook retry self-clears the stuck signal on a normal run"
}

test_version_gt_without_sort_dash_v() {
  local w out
  w="$TMP_ROOT/no-sort-v"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" ahead-axi 2.1.0
  printf '%s\n' 'ahead-axi=2.0.5' > "$w/versions"
  cat > "$w/bin/sort" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -V) echo "sort: invalid option -- 'V'" >&2; exit 2 ;;
  esac
done
exec /usr/bin/sort "$@"
SH
  chmod +x "$w/bin/sort"
  run_case "$w" "ahead-axi" >/dev/null
  assert_grep "--prefix $w/home/.local/axi ahead-axi@2.1.0" "$w/install.log" "the locally-ahead version was not seeded into the vessel prefix"
  assert_no_grep 'ahead-axi@2.0.5' "$w/install.log" "a locally-ahead tool was downgraded when sort -V is unavailable"
  pass "version comparison keeps a locally-ahead version while seeding the vessel prefix"
}

test_bounded_kills_hung_call_without_timeout_binary() {
  local w out minbin f name start end elapsed
  w="$TMP_ROOT/no-timeout-binary"
  minbin="$w/minbin"
  mkdir -p "$w/bin" "$w/home" "$w/state" "$minbin"
  for f in /usr/bin/* /bin/*; do
    name=$(basename "$f")
    case "$name" in timeout|gtimeout) continue ;; esac
    ln -sf "$f" "$minbin/$name" 2>/dev/null
  done
  cat > "$w/bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then sleep 30; exit 0; fi
exit 1
SH
  chmod +x "$w/bin/npm"
  make_tool "$w/bin" hang-axi 1.0.0
  start=$(date +%s)
  out=$(PATH="$w/bin:$minbin" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="hang-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_AXI_SUITE_NETWORK_TIMEOUT=1 \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 15 ] || fail "bounded() did not enforce the timeout without timeout/gtimeout on PATH (took ${elapsed}s)"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-axi latest version lookup failed' "hung lookup was not reported as stuck"
  pass "bounded() enforces the network timeout even without timeout/gtimeout on PATH"
}

test_cumulative_timeout_across_tools() {
  local w out start end elapsed
  w="$TMP_ROOT/cumulative-timeout"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  cat > "$w/bin/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = view ]; then sleep 5; exit 0; fi
exit 1
SH
  chmod +x "$w/bin/npm"
  make_tool "$w/bin" hang-one-axi 1.0.0
  make_tool "$w/bin" hang-two-axi 1.0.0
  make_tool "$w/bin" hang-three-axi 1.0.0
  make_tool "$w/bin" hang-four-axi 1.0.0
  start=$(date +%s)
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="hang-one-axi hang-two-axi hang-three-axi hang-four-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_AXI_SUITE_NETWORK_TIMEOUT=2 \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 8 ] || fail "registry checks for 4 tools took ${elapsed}s, exceeding the cumulative FM_AXI_SUITE_NETWORK_TIMEOUT=2 budget (per-tool multiplication would take ~8s+)"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-one-axi latest version lookup failed' "first hung tool was not reported as stuck"
  assert_contains "$out" 'AXI_SUITE_STUCK: hang-four-axi latest version lookup failed' "last hung tool was not reported as stuck"
  pass "an unreachable registry cannot multiply the timeout across every tool in the suite"
}

test_two_homes_update_distinct_prefixes_concurrently() {
  local a b pid_a pid_b
  a="$TMP_ROOT/concurrent-a"
  b="$TMP_ROOT/concurrent-b"
  for w in "$a" "$b"; do
    mkdir -p "$w/bin" "$w/home/state"
    make_npm "$w/bin" "$w/versions" "$w/install.log"
    make_tool "$w/bin" race-axi 1.0.0
    printf '%s\n' 'race-axi=1.0.1' > "$w/versions"
  done
  PATH="$a/bin:$BASE_PATH" FM_HOME="$a/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=race-axi FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$a/versions" FM_TEST_INSTALL_LOG="$a/install.log" \
    FM_TEST_INSTALL_SLEEP=1 "$ROOT/bin/fm-axi-suite.sh" --force > "$a/out" &
  pid_a=$!
  PATH="$b/bin:$BASE_PATH" FM_HOME="$b/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=race-axi FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$b/versions" FM_TEST_INSTALL_LOG="$b/install.log" \
    FM_TEST_INSTALL_SLEEP=1 "$ROOT/bin/fm-axi-suite.sh" --force > "$b/out" &
  pid_b=$!
  wait "$pid_a" || fail "the first concurrent vessel update failed"
  wait "$pid_b" || fail "the second concurrent vessel update failed"
  assert_grep "--prefix $a/home/.local/axi race-axi@1.0.1" "$a/install.log" "the first vessel did not use its own prefix"
  assert_grep "--prefix $b/home/.local/axi race-axi@1.0.1" "$b/install.log" "the second vessel did not use its own prefix"
  assert_no_grep "$b/home/.local/axi" "$a/install.log" "the first vessel touched the second vessel prefix"
  assert_no_grep "$a/home/.local/axi" "$b/install.log" "the second vessel touched the first vessel prefix"
  pass "concurrent vessel updates have disjoint npm write destinations"
}

test_vessel_prefix_wins_over_inherited_path() {
  local w out
  w="$TMP_ROOT/path-order"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/home/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" order-axi 9.9.9
  make_tool "$w/home/.local/axi/bin" order-axi 1.2.3
  printf '%s\n' 'order-axi=1.2.4' > "$w/versions"
  out=$(PATH="$w/bin:$w/home/.local/axi/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=order-axi FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_contains "$out" 'AXI_SUITE_UPDATED: order-axi 1.2.3 -> 1.2.4' \
    "the inherited PATH copy won over the vessel copy"
  pass "the vessel AXI bin resolves first even when inherited PATH orders it later"
}

test_currency_clock_survives_prefix_cutover() {
  local w first second forced installs_after_first installs_after_second
  w="$TMP_ROOT/currency-clock"
  mkdir -p "$w/bin" "$w/home/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" clock-axi 1.2.3
  printf '%s\n' 'clock-axi=1.2.4' > "$w/versions"
  date +%s > "$w/home/state/axi-suite-update.checked"
  first=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=clock-axi FM_AXI_SUITE_CHECK_INTERVAL=86400 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh")
  assert_contains "$first" 'AXI_SUITE_UPDATED: clock-axi 1.2.3 -> 1.2.4' \
    "the first currency check did not update the vessel copy"
  assert_present "$w/home/state/axi-suite-update.checked" "the per-home currency stamp was not written"
  assert_present "$w/home/state/axi-suite-prefix-v1.cutover" "the vessel-prefix cutover marker was not written"
  installs_after_first=$(wc -l < "$w/install.log" | tr -d ' ')
  printf '%s\n' 'clock-axi=1.2.5' > "$w/versions"
  second=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=clock-axi FM_AXI_SUITE_CHECK_INTERVAL=86400 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh")
  installs_after_second=$(wc -l < "$w/install.log" | tr -d ' ')
  # The claim being pinned is that the CURRENCY check is cached, not that the run
  # is mute: this fixture keeps its tool on the ambient PATH ahead of the vessel
  # prefix, so it is genuinely shadowed, and that condition is a property of the
  # caller's environment rather than of the cadence window - it is reported every
  # run on purpose.
  case "$(printf '%s\n' "$second" | grep -v '^AXI_SUITE_SHADOWED:' | grep -c '[^[:space:]]')" in
    0) ;;
    *) fail "a cached currency check produced unexpected currency output: $second" ;;
  esac
  [ "$installs_after_second" = "$installs_after_first" ] || fail "the cached currency check installed again"
  forced=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=clock-axi FM_AXI_SUITE_CHECK_INTERVAL=86400 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_contains "$forced" 'AXI_SUITE_UPDATED: clock-axi 1.2.4 -> 1.2.5' \
    "the forced currency check did not read and update the vessel copy"
  pass "the per-home currency clock still gates and resumes vessel-prefix updates"
}

test_failed_seed_still_honours_the_cadence() {
  local w first second installs_after_first installs_after_second
  w="$TMP_ROOT/failed-seed-cadence"
  mkdir -p "$w/bin" "$w/home/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" offline-axi 1.0.0
  printf '%s\n' 'offline-axi=1.0.0' > "$w/versions"
  sed -i 's/if \[ "${1:-}" = install \]; then/if [ "${1:-}" = install ]; then printf "%s\\n" "$*" >> "$FM_TEST_INSTALL_LOG"; exit 1; fi\nif false; then/' "$w/bin/npm"
  first=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=offline-axi FM_AXI_SUITE_CHECK_INTERVAL=86400 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh")
  assert_contains "$first" 'AXI_SUITE_STUCK: offline-axi vessel-prefix installation' \
    "the failed seed was not surfaced"
  assert_present "$w/home/state/axi-suite-prefix-v1.cutover" \
    "a failed seed did not record the cutover attempt"
  installs_after_first=$(wc -l < "$w/install.log" | tr -d ' ')
  second=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=offline-axi FM_AXI_SUITE_CHECK_INTERVAL=86400 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh")
  installs_after_second=$(wc -l < "$w/install.log" | tr -d ' ')
  [ "$installs_after_second" = "$installs_after_first" ] || fail "a failed seed repeated the whole sweep in the same cadence window"
  assert_contains "$second" 'AXI_SUITE_STUCK: offline-axi vessel-prefix installation' \
    "the cached run dropped the persisted stuck signal"
  pass "a failed vessel seed keeps the cadence and retries on the next window"
}

test_unreadable_vessel_copy_is_replaced() {
  local w out
  w="$TMP_ROOT/broken-copy"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/home/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" repair-axi 1.2.3
  printf '#!/usr/bin/env bash\nexit 1\n' > "$w/home/.local/axi/bin/repair-axi"
  chmod +x "$w/home/.local/axi/bin/repair-axi"
  printf '%s\n' 'repair-axi=1.2.3' > "$w/versions"
  out=$(run_case "$w" "repair-axi")
  assert_contains "$out" 'AXI_SUITE_UPDATED: repair-axi unreadable vessel copy removed' \
    "the unreadable vessel copy was not removed"
  assert_grep "--prefix $w/home/.local/axi repair-axi@1.2.3" "$w/install.log" \
    "the removed vessel copy was not reseeded from the intact external copy"
  [ "$("$w/home/.local/axi/bin/repair-axi" --version)" = 'repair-axi 1.2.3' ] \
    || fail "the repaired vessel copy still cannot report its version"
  assert_absent "$w/state/axi-suite-update.stuck" \
    "the broken vessel copy left a permanent stuck signal"
  pass "an unreadable vessel copy is removed instead of shadowing the intact external copy"
}

test_hung_vessel_copy_is_bounded_and_kept() {
  local w out start end elapsed
  w="$TMP_ROOT/hung-copy"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" hungcopy-axi 1.0.0
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$w/home/.local/axi/bin/hungcopy-axi"
  chmod +x "$w/home/.local/axi/bin/hungcopy-axi"
  printf '%s\n' 'hungcopy-axi=1.0.0' > "$w/versions"
  start=$(date +%s)
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS=hungcopy-axi FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_AXI_SUITE_PROBE_TIMEOUT=1 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 15 ] || fail "a hung vessel copy stalled the check for ${elapsed}s"
  assert_contains "$out" 'AXI_SUITE_STUCK: hungcopy-axi vessel copy at' \
    "a hung vessel copy was not reported"
  assert_present "$w/home/.local/axi/bin/hungcopy-axi" \
    "a vessel copy that only failed to answer in time was removed"
  assert_present "$w/state/axi-suite-prefix-v1.cutover" \
    "a hung vessel copy blocked the cadence marker"
  pass "a hung vessel copy is bounded, reported, and not removed"
}

test_first_cutover_seeds_whole_suite_without_alarming() {
  local w out t tools
  w="$TMP_ROOT/first-cutover"
  tools="one-axi two-axi three-axi four-axi five-axi six-axi"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  : > "$w/versions"
  for t in $tools; do
    make_tool "$w/bin" "$t" 1.0.0
    printf '%s=1.0.0\n' "$t" >> "$w/versions"
  done
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="$tools" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_AXI_SUITE_NETWORK_TIMEOUT=3 FM_AXI_SUITE_SEED_TIMEOUT=60 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_INSTALL_SLEEP=1 \
    "$ROOT/bin/fm-axi-suite.sh" --force 2>"$w/progress.log")
  for t in $tools; do
    assert_contains "$out" "AXI_SUITE_UPDATED: $t 1.0.0 installed in vessel prefix" \
      "$t was not seeded during the first cutover"
    assert_grep "--prefix $w/home/.local/axi $t@1.0.0" "$w/install.log" \
      "$t never reached the vessel prefix"
  done
  assert_absent "$w/state/axi-suite-update.stuck" \
    "a healthy six-tool first cutover raised a stuck alarm"
  assert_grep 'seeding this vessel AXI prefix' "$w/progress.log" \
    "the first cutover never announced that seeding was in progress"
  assert_grep 'seeding budget left' "$w/progress.log" \
    "the seeding progress output did not report the remaining budget"
  pass "a healthy six-tool first cutover seeds every tool without alarming"
}

test_stalled_first_cutover_alarms_and_stays_bounded() {
  local w out start end elapsed
  w="$TMP_ROOT/stalled-cutover"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" stall-one-axi 1.0.0
  make_tool "$w/bin" stall-two-axi 1.0.0
  printf '%s\n' 'stall-one-axi=1.0.0' 'stall-two-axi=1.0.0' > "$w/versions"
  start=$(date +%s)
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="stall-one-axi stall-two-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_AXI_SUITE_SEED_TIMEOUT=1 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_INSTALL_SLEEP=30 \
    "$ROOT/bin/fm-axi-suite.sh" --force 2>/dev/null)
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 20 ] || fail "a stalled first cutover ran for ${elapsed}s instead of staying inside its seeding budget"
  assert_contains "$out" 'AXI_SUITE_STUCK: stall-one-axi vessel-prefix installation' \
    "a stalled seeding install was not reported"
  assert_contains "$out" 'AXI_SUITE_STUCK: stall-two-axi vessel-prefix seeding at' \
    "the tool left unseeded by the spent budget was not reported"
  assert_contains "$out" 'seeding budget is spent' \
    "the unattempted seed did not name the spent seeding budget"
  assert_present "$w/state/axi-suite-prefix-v1.cutover" \
    "a stalled first cutover blocked the cadence marker"
  pass "a stalled first cutover alarms clearly and stays inside its seeding budget"
}

test_stalled_cutover_of_stale_installs_reports_the_same_way() {
  local w out
  w="$TMP_ROOT/stalled-stale-cutover"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" stale-one-axi 1.0.0
  make_tool "$w/bin" stale-two-axi 1.0.0
  printf '%s\n' 'stale-one-axi=1.0.1' 'stale-two-axi=1.0.1' > "$w/versions"
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="stale-one-axi stale-two-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_AXI_SUITE_SEED_TIMEOUT=1 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_INSTALL_SLEEP=30 \
    "$ROOT/bin/fm-axi-suite.sh" --force 2>"$w/progress.log")
  assert_contains "$out" 'AXI_SUITE_STUCK: stale-two-axi vessel-prefix seeding at' \
    "a first cutover through the update path blamed a broken install for a spent seeding budget"
  assert_contains "$out" 'seeding budget is spent' \
    "the unattempted seed did not name the spent seeding budget"
  assert_grep 'seeding this vessel AXI prefix' "$w/progress.log" \
    "seeding stale shared installs did not announce the cutover"
  assert_grep 'seeding pass finished' "$w/progress.log" \
    "the seeding pass did not summarise what it attempted"
  pass "a spent seeding budget reads the same through the update path as through seeding"
}

test_registry_and_install_time_do_not_spend_the_probe_budget() {
  local w out t
  w="$TMP_ROOT/probe-budget"
  mkdir -p "$w/bin" "$w/home" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  : > "$w/versions"
  for t in slow-one-axi slow-two-axi slow-three-axi; do
    make_tool "$w/bin" "$t" 1.0.0
    printf '%s=1.0.0\n' "$t" >> "$w/versions"
  done
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="slow-one-axi slow-two-axi slow-three-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_AXI_SUITE_NETWORK_TIMEOUT=60 FM_AXI_SUITE_PROBE_TIMEOUT=2 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_VIEW_SLEEP=1 FM_TEST_INSTALL_SLEEP=1 \
    "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_no_grep 'AXI_SUITE_STUCK' <(printf '%s\n' "$out") \
    "slow registry and install work was charged to the probe budget"
  for t in slow-one-axi slow-two-axi slow-three-axi; do
    assert_contains "$out" "AXI_SUITE_UPDATED: $t 1.0.0 installed in vessel prefix" \
      "$t was not seeded after earlier tools spent wall-clock time"
    assert_grep "--prefix $w/home/.local/axi $t@1.0.0" "$w/install.log" \
      "$t never reached the vessel prefix"
  done
  assert_absent "$w/state/axi-suite-update.stuck" "a successful cutover persisted a stuck signal"
  pass "registry and install time never spends the local probe budget"
}

test_unpublished_ahead_version_is_not_a_recurring_alarm() {
  local w out
  w="$TMP_ROOT/ahead-unpublished"
  mkdir -p "$w/bin" "$w/home/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" dev-axi 3.1.0
  printf '%s\n' 'dev-axi=3.0.0' > "$w/versions"
  sed -i 's/if \[ "${1:-}" = install \]; then/if [ "${1:-}" = install ]; then printf "%s\\n" "$*" >> "$FM_TEST_INSTALL_LOG"; exit 1; fi\nif false; then/' "$w/bin/npm"
  out=$(run_case "$w" "dev-axi")
  assert_contains "$out" 'AXI_SUITE_REVIEW: dev-axi 3.1.0 is ahead of registry latest 3.0.0' \
    "an unpublishable locally-ahead build was not reported for review"
  assert_absent "$w/state/axi-suite-update.stuck" \
    "an unpublishable locally-ahead build raised a permanent stuck alarm"
  assert_no_grep 'dev-axi@3.0.0' "$w/install.log" "the locally-ahead build was downgraded to the registry latest"
  assert_present "$w/state/axi-suite-prefix-v1.cutover" \
    "an unpublishable locally-ahead build blocked the cadence marker"
  pass "an unpublishable locally-ahead build reports for review instead of alarming forever"
}

# The currency check maintains the vessel prefix and, before these cases, only
# ever measured the copy it maintains - it prepends that prefix into its own
# process and then asks about versions. So it could report a suite current while
# every other process ran an older copy from somewhere else entirely, which is
# what a 2026-08-04 hand measurement found on the coditan vessel: six of six
# suite tools resolving from ~/.npm-global/bin, each behind the maintained copy,
# under a clean all-clear. Note what these cases do NOT test: that the maintained
# copy is current. That already passed while the defect was live, which is
# exactly why it is not the test.
#
# This first one is the NARROW UNIT CASE: it calls the updater directly from a
# raw shell, so nothing has prepended the maintained prefix yet. That is not the
# production shape, and on its own it is the hole that let an inert diagnostic
# ship - see test_shadow_report_survives_an_entrypoint_that_prepended_first for
# the invocation path bootstrap actually uses.
test_shadowed_suite_is_reported_even_while_the_maintained_copy_is_current() {
  local w out
  w="$TMP_ROOT/shadowed"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  # The maintained copy is current, and an older copy earlier on the ambient
  # PATH is what actually runs.
  make_tool "$w/home/.local/axi/bin" shadow-axi 1.2.4
  make_tool "$w/bin" shadow-axi 1.2.3
  printf '%s\n' 'shadow-axi=1.2.4' > "$w/versions"
  out=$(run_case "$w" "shadow-axi")
  assert_contains "$out" "AXI_SUITE_SHADOWED: shadow-axi runs from $w/bin/shadow-axi" \
    "a suite tool resolving outside the maintained prefix was reported as current with no caveat"
  assert_contains "$out" "not the maintained copy in $w/home/.local/axi/bin" \
    "the report did not name the copy that is being maintained instead"
  assert_not_contains "$out" 'AXI_SUITE_UPDATE' "the maintained copy was current, so no update was due"
  pass "a maintained copy that is not the resolved copy is reported, not folded into an all-clear"
}

test_unshadowed_suite_reports_nothing_extra() {
  local w out
  w="$TMP_ROOT/unshadowed"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/home/.local/axi/bin" solo-axi 1.2.4
  printf '%s\n' 'solo-axi=1.2.4' > "$w/versions"
  # The maintained bin directory is on the ambient PATH ahead of everything else,
  # which is what a correctly resolving firstmate-launched process looks like.
  out=$(PATH="$w/home/.local/axi/bin:$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="solo-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_HOOK_LOG="$w/hook.log" "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_not_contains "$out" 'AXI_SUITE_SHADOWED' "a correctly resolving suite was reported as shadowed"
  pass "a suite that resolves from the maintained prefix reports no shadowing"
}

# The PRODUCTION invocation path, and the one the narrow case above cannot reach.
# bin/fm-bootstrap.sh prepends the maintained prefix into its own process and
# exports it (line 111) long before it invokes the suite check, and
# bin/fm-session-start.sh does the same before spawning bootstrap. A check that
# reads its own $PATH - even before its own prepend - therefore only ever sees an
# environment firstmate has already corrected, resolves every tool to the copy it
# maintains, and reports nothing however badly the session itself resolves. This
# case drives bootstrap, not the updater, so the report has to survive an
# entrypoint that prepended first or it is inert exactly where it is needed.
test_shadow_report_survives_an_entrypoint_that_prepended_first() {
  local w out
  w="$TMP_ROOT/shadow-through-bootstrap"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/home/.local/axi/bin" boot-axi 1.2.4
  make_tool "$w/bin" boot-axi 1.2.3
  printf '%s\n' 'boot-axi=1.2.4' > "$w/versions"
  # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home so the
  # ambient checkout cannot leak an unrelated line into this fixture.
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/home" \
    FM_STATE_OVERRIDE="$w/state" FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="boot-axi" \
    FM_AXI_SUITE_CHECK_INTERVAL=0 FM_TEST_VERSIONS="$w/versions" \
    FM_TEST_INSTALL_LOG="$w/install.log" FM_TEST_HOOK_LOG="$w/hook.log" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "AXI_SUITE_SHADOWED: boot-axi runs from $w/bin/boot-axi" \
    "the shadow report never fired on the invocation path production actually uses"
  assert_contains "$out" "not the maintained copy in $w/home/.local/axi/bin" \
    "the report did not name the copy that is being maintained instead"
  pass "the shadow report describes the session's environment, not the entrypoint's corrected one"
}

# The inversion of the same baseline error. On an unseeded vessel the maintained
# bin directory is empty, so every suite tool resolves to an external copy - the
# ordinary pre-cutover state that the seeding and currency paths own. A check
# comparing against a copy that does not exist would call all six shadowed and
# send the agent to the captain with two paths and no defect.
test_unseeded_vessel_reports_no_shadowing() {
  local w out
  w="$TMP_ROOT/unseeded-shadow"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/bin" fresh-axi 1.2.4
  printf '%s\n' 'fresh-axi=1.2.4' > "$w/versions"
  [ -e "$w/home/.local/axi/bin/fresh-axi" ] && fail "the unseeded fixture already owns a maintained copy"
  out=$(run_case "$w" "fresh-axi")
  assert_not_contains "$out" 'AXI_SUITE_SHADOWED' \
    "a tool this home maintains no copy of was reported as shadowing that absent copy"
  pass "an unseeded vessel reports no shadowing, only the seeding the other paths own"
}

# A pid that has certainly exited, so a marker stamped with it is provably from a
# process tree that is gone rather than merely from somewhere else.
dead_pid() {
  local p
  ( exit 0 ) &
  p=$!
  wait "$p" 2>/dev/null || true
  kill -0 "$p" 2>/dev/null && fail "the fixture pid $p is still alive"
  printf '%s' "$p"
}

# The recorded pre-prepend environment is exported and never overwritten by a
# later prepender, which is what makes it survive the entrypoint chain - and also
# what lets it outlive the session it describes. `tmux new-session` starts a
# server with the launching environment frozen into it, every pane opened there
# afterwards inherits that snapshot, and bin/fm-watcher-service.sh prepends
# before starting exactly such a server. So a session running inside that server
# can be handed a marker describing a session that ended months ago, and the
# check would answer about that one with complete confidence. Here the frozen
# marker claims a clean environment while this session in fact resolves the
# external copy.
test_a_marker_from_a_dead_process_tree_is_not_trusted() {
  local w out gone frozen
  w="$TMP_ROOT/stale-marker"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/home/.local/axi/bin" stale-axi 1.2.4
  make_tool "$w/bin" stale-axi 1.2.3
  printf '%s\n' 'stale-axi=1.2.4' > "$w/versions"
  gone=$(dead_pid)
  frozen="$w/home/.local/axi/bin:$BASE_PATH"
  out=$(PATH="$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_AMBIENT_PATH="$frozen" FM_AXI_AMBIENT_PATH_OWNER="$gone" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="stale-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_HOOK_LOG="$w/hook.log" "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_contains "$out" "AXI_SUITE_SHADOWED: stale-axi runs from $w/bin/stale-axi" \
    "a frozen marker from a dead process tree was believed over this session's own environment"
  pass "a recorded environment from another process tree is not answered for"
}

# The other half of the same guard: when the foreign marker meets a PATH that
# ALREADY leads with the maintained prefix, this process has nothing honest left
# to measure - its own PATH describes the correction, not the environment. The
# answer must be that it cannot tell, never a clean all-clear, because a
# confident wrong answer is the whole defect this change exists to remove.
test_an_unattributable_environment_reports_that_it_cannot_tell() {
  local w out gone frozen
  w="$TMP_ROOT/unattributable-marker"
  mkdir -p "$w/bin" "$w/home/.local/axi/bin" "$w/state"
  make_npm "$w/bin" "$w/versions" "$w/install.log"
  make_tool "$w/home/.local/axi/bin" opaque-axi 1.2.4
  make_tool "$w/bin" opaque-axi 1.2.3
  printf '%s\n' 'opaque-axi=1.2.4' > "$w/versions"
  gone=$(dead_pid)
  frozen="$w/home/.local/axi/bin:$BASE_PATH"
  out=$(PATH="$w/home/.local/axi/bin:$w/bin:$BASE_PATH" FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/state" \
    FM_AXI_AMBIENT_PATH="$frozen" FM_AXI_AMBIENT_PATH_OWNER="$gone" \
    FM_AXI_SUITE_DISABLE=0 FM_AXI_SUITE_TOOLS="opaque-axi" FM_AXI_SUITE_CHECK_INTERVAL=0 \
    FM_TEST_VERSIONS="$w/versions" FM_TEST_INSTALL_LOG="$w/install.log" \
    FM_TEST_HOOK_LOG="$w/hook.log" "$ROOT/bin/fm-axi-suite.sh" --force)
  assert_contains "$out" 'AXI_SUITE_SHADOW_UNKNOWN' \
    "an unanswerable environment was reported as a clean all-clear instead of as unknown"
  assert_not_contains "$out" 'AXI_SUITE_SHADOWED:' \
    "a check that cannot tell must not also claim a specific shadowing"
  pass "an environment this process cannot attribute is reported as unknown, not clear"
}

test_patch_and_minor_auto_update
test_major_and_missing_wait_for_review
test_a_marker_from_a_dead_process_tree_is_not_trusted
test_an_unattributable_environment_reports_that_it_cannot_tell
test_shadowed_suite_is_reported_even_while_the_maintained_copy_is_current
test_unshadowed_suite_reports_nothing_extra
test_shadow_report_survives_an_entrypoint_that_prepended_first
test_unseeded_vessel_reports_no_shadowing
test_two_homes_update_distinct_prefixes_concurrently
test_vessel_prefix_wins_over_inherited_path
test_currency_clock_survives_prefix_cutover
test_failed_seed_still_honours_the_cadence
test_unreadable_vessel_copy_is_replaced
test_hung_vessel_copy_is_bounded_and_kept
test_registry_and_install_time_do_not_spend_the_probe_budget
test_first_cutover_seeds_whole_suite_without_alarming
test_stalled_first_cutover_alarms_and_stays_bounded
test_stalled_cutover_of_stale_installs_reports_the_same_way
test_unpublished_ahead_version_is_not_a_recurring_alarm
test_failed_update_persists_stuck_signal
test_check_only_never_runs_hook_setup
test_hook_retry_self_clears_stuck_signal
test_version_gt_without_sort_dash_v
test_bounded_kills_hung_call_without_timeout_binary
test_cumulative_timeout_across_tools
