#!/usr/bin/env bash
# tests/fm-watch-bridge-inbox.test.sh - the watcher's read-only Bridge inbox
# check (bin/fm-bridge-inbox-lib.sh, driven from bin/fm-watch.sh).
#
# Covered contract: vessel resolution and the disabled default; a pending
# envelope producing exactly one durable check wake per inbox-tree signature;
# silence for an empty, unchanged, or acknowledged inbox; per-vessel independence
# in a multi-vessel list, including in an undrained queue; the urgent cadence
# tightening only the Bridge poll and never freezing the fetch that advances
# origin/main; the signature-keyed priority cache; and reads resolving against
# the fetched origin/main rather than a stale working tree.
#
# Each case drives a real fm-watch.sh subprocess against a throwaway Bridge
# clone, so the assertions are on observable watcher output plus durable state,
# never on internals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-bridge-inbox)
fm_git_identity

# Existing Bridge fixtures explicitly opt into the historical vessel name; cases
# that exercise the multi-vessel list or the disabled path override it.
export FM_BRIDGE_VESSEL=coditan
# An operator's own shell commonly exports FM_BRIDGE_ROOT for a live vessel, and
# it outranks FM_HOME in the library's resolution, so an inherited value would
# silently point every fixture below at that real clone. A misdirected root reads
# as "Bridge is unconfigured", which means the cases that WAIT for a wake would
# hang rather than fail. Drop it.
unset FM_BRIDGE_ROOT

# A home with its own bare Bridge origin and a clone under projects/. Extra
# arguments name additional vessels beside the default "coditan".
make_home() {
  local name=$1 home bridge origin vessel
  shift
  home="$TMP_ROOT/$name"
  bridge="$home/projects/coditan-bridge"
  origin="$home/bridge-origin.git"
  mkdir -p "$home/state" "$bridge/inbox/coditan/new"
  for vessel in "$@"; do
    mkdir -p "$bridge/inbox/$vessel/new"
  done
  git init -q --bare "$origin"
  git -C "$bridge" init -q -b main
  touch "$bridge/inbox/coditan/new/.gitkeep"
  for vessel in "$@"; do
    touch "$bridge/inbox/$vessel/new/.gitkeep"
  done
  git -C "$bridge" add inbox
  git -C "$bridge" commit -qm init
  git -C "$bridge" remote add origin "$origin"
  git -C "$bridge" push -qu origin main
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$home"
}

write_envelope() {
  local home=$1 name=$2 priority=$3 vessel=${4:-coditan}
  printf '{"schema":"bridge-envelope.v1","id":"%s","priority":"%s","state":"new"}\n' \
    "$name" "$priority" > "$home/projects/coditan-bridge/inbox/$vessel/new/$name.json"
  git -C "$home/projects/coditan-bridge" add "inbox/$vessel/new/$name.json"
  git -C "$home/projects/coditan-bridge" commit -qm "add $name"
  git -C "$home/projects/coditan-bridge" push -qu origin main
}

# A timeout shim that counts every bounded Bridge read, so "did not scan" is
# asserted on evidence rather than on silence alone.
counting_timeout() {
  local dir=$1 counter=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  : > "$counter"
  cat > "$fakebin/timeout" <<EOF
#!/usr/bin/env bash
echo x >> "$counter"
exec /usr/bin/timeout "\$@"
EOF
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# A jq shim that counts envelope reads while still reporting the real priority,
# so cache hits and misses are countable.
counting_jq() {
  local dir=$1 counter=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  : > "$counter"
  cat > "$fakebin/jq" <<EOF
#!/usr/bin/env bash
echo x >> "$counter"
priority=\$(grep -o '"priority":"[a-z]*"' | head -1 | cut -d'"' -f4)
printf '%s\n' "\${priority:-normal}"
EOF
  chmod +x "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

count_lines() { wc -l < "$1" | tr -d '[:space:]'; }

# Both helpers keep the Bridge poll due on every cycle: the urgent interval
# gates discovery and FM_CHECK_INTERVAL is what the non-urgent cadence returns,
# so zeroing both makes a silent run prove the check RAN and said nothing rather
# than prove only that it was not yet due. The heartbeat is parked so nothing but
# Bridge can print. Trailing arguments are appended last and therefore override
# these defaults.

# Wait up to <limit> 0.1s ticks for <pid> to exit; 0 if it exited, 1 on expiry.
# A regressed check would otherwise loop forever and block the whole suite,
# which applies no per-test timeout, instead of failing with a diagnostic.
wait_exit() {  # <pid> [limit]
  local pid=$1 limit=${2:-600} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

# Run the watcher until it exits on its own; the caller expects a wake.
watch_until_wake() {  # <home> <out> [extra env assignments...]
  local home=$1 out=$2 pid
  shift 2
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
  pid=$!
  wait_exit "$pid" || fail "the watcher never produced a Bridge wake"
  wait "$pid"
}

# Run the watcher for a few cycles and stop it; the caller expects silence.
watch_briefly() {  # <home> <out> <seconds> [extra env assignments...]
  local home=$1 out=$2 seconds=$3 pid
  shift 3
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" 2>&1 &
  pid=$!
  sleep "$seconds"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_vessel_resolution_precedence() {
  local home resolved
  home=$(make_home vessel-resolution)
  mkdir -p "$home/config"
  printf '%s\n' tugboat > "$home/config/bridge-vessel"

  resolved=$(
    # shellcheck disable=SC2016  # $1/$BRIDGE_VESSEL belong to the inner bash -c process.
    FM_HOME="$home" FM_BRIDGE_VESSEL=override \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = override ] || fail "FM_BRIDGE_VESSEL did not override config/bridge-vessel: $resolved"

  resolved=$(
    # shellcheck disable=SC2016
    env -u FM_BRIDGE_VESSEL FM_HOME="$home" \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = tugboat ] || fail "config/bridge-vessel was not used without an env override: $resolved"

  resolved=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL='' \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = tugboat ] || fail "an empty FM_BRIDGE_VESSEL shadowed config/bridge-vessel: $resolved"

  # A caller reading another home redirects config the same way every other
  # config reader in bin/ is redirected.
  mkdir -p "$home/alt-config"
  printf '%s\n' dinghy > "$home/alt-config/bridge-vessel"
  resolved=$(
    # shellcheck disable=SC2016
    env -u FM_BRIDGE_VESSEL FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/alt-config" \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = dinghy ] || fail "FM_CONFIG_OVERRIDE was ignored when reading bridge-vessel: $resolved"
  pass "Bridge vessel resolution prefers a non-empty env value and falls back to the effective home's config"
}

test_vessel_config_without_trailing_newline_resolves() {
  local home resolved
  home=$(make_home vessel-no-newline)
  mkdir -p "$home/config"
  # An editor with no final EOL, or printf/echo -n, writes the file this way.
  printf tugboat > "$home/config/bridge-vessel"

  resolved=$(
    # shellcheck disable=SC2016
    env -u FM_BRIDGE_VESSEL FM_HOME="$home" \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = tugboat ] || \
    fail "config/bridge-vessel without a trailing newline silently disabled the check: '$resolved'"
  pass "a config/bridge-vessel written without a final newline still resolves its vessel"
}

test_multi_vessel_list_resolves_into_array() {
  local home resolved
  home=$(make_home multi-vessel-list)

  resolved=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL="coditan captain" \
      bash -c '. "$1"; printf "%s" "$BRIDGE_VESSEL"' _ "$WATCH"
  )
  [ "$resolved" = coditan ] || fail "BRIDGE_VESSEL did not keep the first vessel for single-vessel compatibility: $resolved"

  resolved=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL="coditan captain" \
      bash -c '. "$1"; printf "%s %s (%s)" "${BRIDGE_VESSELS[0]}" "${BRIDGE_VESSELS[1]}" "${#BRIDGE_VESSELS[@]}"' _ "$WATCH"
  )
  [ "$resolved" = "coditan captain (2)" ] || fail "space-separated vessels did not resolve in order: $resolved"

  resolved=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL=coditan \
      bash -c '. "$1"; printf "%s" "${#BRIDGE_VESSELS[@]}"' _ "$WATCH"
  )
  [ "$resolved" = 1 ] || fail "a single-vessel value did not resolve to exactly one watched vessel: $resolved"
  pass "a space-separated FM_BRIDGE_VESSEL resolves into an ordered vessel list, with BRIDGE_VESSEL as the first"
}

test_unconfigured_home_skips_bridge_scan() {
  local home fakebin counter out
  home=$(make_home unconfigured)
  counter="$home/timeout-calls"
  fakebin=$(counting_timeout "$home" "$counter")
  out="$home/watch.out"

  # Neither the environment variable nor config/bridge-vessel: the feature is off.
  ( unset FM_BRIDGE_VESSEL; watch_briefly "$home" "$out" 2 "PATH=$fakebin:$PATH" )

  assert_absent "$home/config/bridge-vessel" "the unconfigured fixture grew a vessel config file"
  [ ! -s "$out" ] || fail "unconfigured Bridge watcher did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "unconfigured Bridge watcher created a wake"
  [ "$(count_lines "$counter")" = 0 ] || \
    fail "unconfigured Bridge watcher still spawned a bounded scan"
  pass "a home with neither FM_BRIDGE_VESSEL nor config/bridge-vessel performs no Bridge scan and emits no wake"
}

test_missing_bridge_clone_skips_scan() {
  local home fakebin counter out
  home="$TMP_ROOT/missing"
  mkdir -p "$home/state"
  counter="$home/timeout-calls"
  fakebin=$(counting_timeout "$home" "$counter")
  out="$home/watch.out"

  watch_briefly "$home" "$out" 3 "PATH=$fakebin:$PATH"

  [ ! -s "$out" ] || fail "missing Bridge clone did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "missing Bridge clone created a wake"
  [ "$(count_lines "$counter")" = 0 ] || \
    fail "missing Bridge clone still spawned a bounded scan"
  pass "a configured vessel without a Bridge clone short-circuits without spawning a scan"
}

test_empty_inbox_is_silent() {
  local home out
  home=$(make_home empty)
  out="$home/watch.out"

  watch_briefly "$home" "$out" 2

  [ ! -s "$out" ] || fail "empty Bridge inbox did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "empty Bridge inbox created a wake"
  assert_absent "$home/state/.bridge-surfaced" "empty Bridge inbox recorded a surfaced marker"
  pass "an empty Bridge inbox is scanned and absorbed silently"
}

test_bridge_inbox_surfaces_each_signature_once() {
  local home bridge out first_marker second_marker
  home=$(make_home pending)
  bridge="$home/projects/coditan-bridge"
  out="$home/watch.out"
  write_envelope "$home" urgent high

  watch_until_wake "$home" "$out" || fail "watcher failed while checking a pending Bridge envelope"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=1 highest=high" \
    "pending Bridge envelope did not produce an actionable check wake"
  assert_contains "$(cat "$home/state/.wake-queue")" $'\tcheck\tbridge-inbox:coditan\t' \
    "Bridge check wake was not queued durably under its own vessel key"
  first_marker=$(cat "$home/state/.bridge-surfaced")
  [ -n "$first_marker" ] || fail "first surfaced inbox signature was not recorded"

  # Unchanged pending inbox: still pending, but already surfaced.
  : > "$out"
  rm -f "$home/state/.wake-queue"
  watch_briefly "$home" "$out" 2
  [ ! -s "$out" ] || fail "unchanged Bridge inbox signature re-fired a wake: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "unchanged Bridge inbox signature created a wake"
  [ "$(cat "$home/state/.bridge-surfaced")" = "$first_marker" ] || \
    fail "absorbing an unchanged inbox altered the surfaced marker"

  # New mail moves the tree signature, so it surfaces again.
  write_envelope "$home" second normal
  : > "$out"
  watch_until_wake "$home" "$out" || fail "watcher failed after the Bridge inbox signature changed"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=2 highest=high" \
    "changed Bridge inbox signature did not produce a new wake"
  second_marker=$(cat "$home/state/.bridge-surfaced")
  [ "$second_marker" != "$first_marker" ] || fail "changed inbox did not advance the surfaced marker"

  # Acknowledged on origin: silent again, and the marker is dropped.
  git -C "$bridge" rm -q inbox/coditan/new/urgent.json inbox/coditan/new/second.json
  git -C "$bridge" commit -qm "ack envelopes"
  git -C "$bridge" push -qu origin main
  : > "$out"
  rm -f "$home/state/.wake-queue"
  watch_briefly "$home" "$out" 2
  [ ! -s "$out" ] || fail "acked Bridge inbox did not stay silent: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "acked Bridge inbox created a wake"
  assert_absent "$home/state/.bridge-surfaced" "acked inbox did not clear the surfaced marker"

  # Byte-identical re-delivery restores the earlier tree, which the dropped
  # marker must not suppress.
  write_envelope "$home" urgent high
  write_envelope "$home" second normal
  : > "$out"
  watch_until_wake "$home" "$out" || fail "watcher failed after a byte-identical Bridge re-delivery"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=2 highest=high" \
    "byte-identical re-delivered inbox did not produce a new wake"
  [ "$(cat "$home/state/.bridge-surfaced")" = "$second_marker" ] || \
    fail "re-delivered inbox did not record its surfaced signature"
  pass "Bridge inbox wakes once per pending signature, clears on ack, and re-fires on re-delivery"
}

test_multi_vessel_each_surfaces_independently() {
  local home out
  home=$(make_home multi-independent captain)
  out="$home/watch.out"
  write_envelope "$home" urgent high coditan

  watch_until_wake "$home" "$out" 'FM_BRIDGE_VESSEL=coditan captain' \
    || fail "watcher failed while checking the primary vessel's pending envelope"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=1 highest=high" \
    "primary vessel envelope did not produce a wake"
  assert_not_contains "$(cat "$out")" "captain pending" \
    "the secondary vessel with no mail was reported as pending"
  assert_present "$home/state/.bridge-surfaced" \
    "the primary vessel did not keep its historical unsuffixed surfaced marker"
  assert_absent "$home/state/.bridge-surfaced-captain" \
    "the secondary vessel surfaced a marker despite having no mail"

  : > "$out"
  rm -f "$home/state/.wake-queue"
  watch_briefly "$home" "$out" 2 'FM_BRIDGE_VESSEL=coditan captain'
  [ ! -s "$out" ] || fail "an unchanged primary vessel inbox re-fired a wake: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" "an unchanged primary vessel inbox created a wake"

  write_envelope "$home" second normal captain
  : > "$out"
  watch_until_wake "$home" "$out" 'FM_BRIDGE_VESSEL=coditan captain' \
    || fail "watcher failed while checking the secondary vessel's pending envelope"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox captain pending=1 highest=normal" \
    "secondary vessel envelope did not produce its own wake"
  assert_not_contains "$(cat "$out")" "coditan pending" \
    "an unchanged primary vessel was re-surfaced alongside the secondary vessel's new mail"
  assert_present "$home/state/.bridge-surfaced-captain" \
    "the secondary vessel's surfaced marker was not recorded"
  pass "each configured vessel surfaces its own pending mail independently of the others"
}

test_multi_vessel_wakes_survive_an_undrained_queue() {
  local home out drained
  home=$(make_home multi-undrained captain)
  out="$home/watch.out"

  # The primary vessel's wake is queued and its marker advances, and only then
  # does the secondary vessel get mail. The queue keeps one record per kind and
  # key, so a key shared between vessels would drop the primary's still-pending
  # mail here for good: its marker already claims the mail was surfaced.
  write_envelope "$home" first high coditan
  watch_until_wake "$home" "$out" 'FM_BRIDGE_VESSEL=coditan captain' \
    || fail "watcher failed while checking the primary vessel's pending envelope"

  write_envelope "$home" second normal captain
  : > "$out"
  watch_until_wake "$home" "$out" 'FM_BRIDGE_VESSEL=coditan captain' \
    || fail "watcher failed while checking the secondary vessel's pending envelope"

  drained="$home/drain.out"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drained" \
    || fail "draining the queued Bridge wakes failed"
  assert_contains "$(cat "$drained")" "bridge-inbox coditan pending=1 highest=high" \
    "the primary vessel's undrained wake was collapsed by the secondary vessel's later wake"
  assert_contains "$(cat "$drained")" "bridge-inbox captain pending=1 highest=normal" \
    "the secondary vessel's wake was not drained"
  pass "a vessel queued before the queue drains is still named once a later vessel queues its own wake"
}

test_priority_tightens_only_bridge_cadence() {
  local home interval
  home=$(make_home cadence)

  interval=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$interval" = 300 ] || fail "empty-inbox Bridge cadence was $interval, expected 300"

  write_envelope "$home" routine normal
  interval=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$interval" = 300 ] || fail "normal envelope cadence was $interval, expected 300"

  write_envelope "$home" flash immediate
  interval=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_CHECK_INTERVAL=300 FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$interval" = 30 ] || fail "immediate envelope cadence was $interval, expected 30"
  pass "high-priority Bridge traffic tightens only the Bridge poll interval"
}

test_multi_vessel_cadence_reflects_any_vessel() {
  local home interval
  home=$(make_home multi-cadence captain)
  write_envelope "$home" routine normal coditan
  interval=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL="coditan captain" FM_CHECK_INTERVAL=300 \
      FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$interval" = 300 ] || fail "cadence with only normal-priority mail was $interval, expected 300"

  write_envelope "$home" flash immediate captain
  interval=$(
    # shellcheck disable=SC2016
    FM_HOME="$home" FM_BRIDGE_VESSEL="coditan captain" FM_CHECK_INTERVAL=300 \
      FM_BRIDGE_URGENT_CHECK_INTERVAL=30 \
      bash -c '. "$1"; bridge_check_interval' _ "$WATCH"
  )
  [ "$interval" = 30 ] || \
    fail "cadence with the secondary vessel at immediate priority was $interval, expected 30"
  pass "the shared Bridge cadence tightens when any watched vessel is high or immediate priority"
}

test_cache_skips_rescan_when_unchanged() {
  local home fakebin counter out calls
  home=$(make_home cache)
  counter="$home/jq-calls"
  fakebin=$(counting_jq "$home" "$counter")
  write_envelope "$home" first normal

  # shellcheck disable=SC2016
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '. "$1"; bridge_pending_priority' _ "$WATCH")
  [ "$out" = normal ] || fail "first priority read was $out, expected normal"
  # shellcheck disable=SC2016
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '. "$1"; bridge_pending_priority' _ "$WATCH")
  [ "$out" = normal ] || fail "cached priority read was $out, expected normal"
  calls=$(count_lines "$counter")
  [ "$calls" = 1 ] || fail "unchanged inbox re-ran the priority scan ($calls envelope reads, expected 1)"

  write_envelope "$home" second immediate
  # shellcheck disable=SC2016
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '. "$1"; bridge_pending_priority' _ "$WATCH")
  [ "$out" = immediate ] || fail "priority after new arrival was $out, expected immediate"
  calls=$(count_lines "$counter")
  [ "$calls" = 3 ] || fail "new arrival did not trigger a rescan (1 old + 2 new reads: got $calls, expected 3)"
  pass "an unchanged Bridge inbox reuses the cached priority; new arrivals trigger a rescan"
}

test_inplace_edit_invalidates_cache() {
  local home fakebin counter out calls
  home=$(make_home inplace)
  counter="$home/jq-calls"
  fakebin=$(counting_jq "$home" "$counter")
  write_envelope "$home" first normal

  # shellcheck disable=SC2016
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '. "$1"; bridge_pending_priority' _ "$WATCH")
  [ "$out" = normal ] || fail "first priority read was $out, expected normal"

  write_envelope "$home" first immediate
  # shellcheck disable=SC2016
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" bash -c '. "$1"; bridge_pending_priority' _ "$WATCH")
  [ "$out" = immediate ] || \
    fail "priority after an in-place edit was $out, expected immediate (the cache did not invalidate)"
  calls=$(count_lines "$counter")
  [ "$calls" = 2 ] || \
    fail "an in-place edit under an unchanged filename did not trigger a rescan ($calls reads, expected 2)"
  pass "an in-place envelope edit under an unchanged filename invalidates the cached priority"
}

test_discovery_gated_by_urgent_interval() {
  local home fakebin counter out calls
  # An empty inbox keeps the watcher looping, so the scan count reflects the
  # discovery gate rather than an early exit on a wake.
  home=$(make_home discovery)
  counter="$home/timeout-calls"
  fakebin=$(counting_timeout "$home" "$counter")
  out="$home/watch.out"

  # A wide urgent interval means exactly one discovery, no matter how many poll
  # cycles elapse; without the gate every 1s cycle would fetch and rescan.
  watch_briefly "$home" "$out" 4 "PATH=$fakebin:$PATH" \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=999999 FM_CHECK_INTERVAL=999999

  calls=$(count_lines "$counter")
  [ "$calls" -le 5 ] || \
    fail "repeated unchanged loop cycles kept spawning bounded scans ($calls calls across several ticks)"
  assert_present "$home/state/.last-bridge-discovery" "the Bridge discovery cadence marker was never written"
  pass "repeated loop cycles do not keep spawning Bridge scans within the urgent window"
}

test_wide_urgent_interval_does_not_freeze_detection() {
  local home out peer pid i=0
  # The discovery fetch is the only thing that advances the watcher's own
  # origin/main, so an urgent interval WIDER than the interval actually in force
  # must not gate it: gating on the urgent interval alone leaves the ref frozen
  # at the value it had when the watcher started, and mail that arrives later is
  # never seen. Bridge delivers from its own clone, so this envelope is pushed
  # from a peer: a push made from the watcher's clone would advance that clone's
  # remote-tracking ref by itself and hide a frozen fetch.
  home=$(make_home wide-urgent)
  out="$home/watch.out"
  peer="$home/bridge-peer"
  git clone -q "$home/bridge-origin.git" "$peer"

  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
    FM_BRIDGE_URGENT_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!

  while [ ! -e "$home/state/.last-bridge-discovery" ]; do
    [ "$i" -lt 300 ] || { kill "$pid" 2>/dev/null || true; fail "the first Bridge discovery never ran"; }
    sleep 0.1
    i=$((i + 1))
  done

  printf '{"schema":"bridge-envelope.v1","id":"late","priority":"normal","state":"new"}\n' \
    > "$peer/inbox/coditan/new/late.json"
  git -C "$peer" add inbox/coditan/new/late.json
  git -C "$peer" commit -qm "add late"
  git -C "$peer" push -q origin main
  wait_exit "$pid" \
    || fail "a wide FM_BRIDGE_URGENT_CHECK_INTERVAL froze Bridge detection: mail arriving after the first discovery was never seen"
  wait "$pid" || fail "watcher failed while detecting mail under a wide urgent interval"
  assert_contains "$(cat "$out")" "check: bridge-inbox: bridge-inbox coditan pending=1 highest=normal" \
    "mail arriving after the first discovery did not produce a wake"
  pass "a wide urgent interval only tightens the Bridge cadence and never stops refreshing origin/main"
}

test_acked_on_origin_ignores_stale_working_tree() {
  local home bridge peer out
  home=$(make_home stale-working-tree)
  bridge="$home/projects/coditan-bridge"
  peer="$home/bridge-peer"
  write_envelope "$home" acked normal

  # Acknowledge from a peer clone so the local Bridge working tree keeps the
  # envelope file that origin/main no longer carries.
  git clone -q "$home/bridge-origin.git" "$peer"
  git -C "$peer" rm -q inbox/coditan/new/acked.json
  git -C "$peer" commit -qm "ack envelope"
  git -C "$peer" push -qu origin main
  assert_present "$bridge/inbox/coditan/new/acked.json" \
    "the stale-working-tree fixture did not retain the locally pending envelope"

  out="$home/watch.out"
  watch_briefly "$home" "$out" 3

  [ ! -s "$out" ] || fail "an origin-acked envelope in a stale working tree caused a false wake: $(cat "$out")"
  assert_absent "$home/state/.wake-queue" \
    "an origin-acked envelope in a stale working tree created a wake"
  assert_present "$bridge/inbox/coditan/new/acked.json" \
    "the watcher fetch mutated the stale Bridge working tree"
  pass "an origin ack clears the check without mutating a stale local working tree"
}

test_vessel_resolution_precedence
test_vessel_config_without_trailing_newline_resolves
test_multi_vessel_list_resolves_into_array
test_unconfigured_home_skips_bridge_scan
test_missing_bridge_clone_skips_scan
test_empty_inbox_is_silent
test_bridge_inbox_surfaces_each_signature_once
test_multi_vessel_each_surfaces_independently
test_multi_vessel_wakes_survive_an_undrained_queue
test_priority_tightens_only_bridge_cadence
test_multi_vessel_cadence_reflects_any_vessel
test_cache_skips_rescan_when_unchanged
test_inplace_edit_invalidates_cache
test_discovery_gated_by_urgent_interval
test_wide_urgent_interval_does_not_freeze_detection
test_acked_on_origin_ignores_stale_working_tree
