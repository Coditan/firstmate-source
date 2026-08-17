#!/usr/bin/env bash
# Behavior tests for the forge status watch.
#
# Every property here was a proof obligation when the watch was commissioned
# during a live GitHub outage, and each is asserted against what the script
# actually does rather than against what its header says it does:
#   - a new reading is recorded and wakes ONCE, and stays silent for as long as
#     that reading holds;
#   - a status page that cannot be read is recorded as UNMEASURABLE and never as
#     clear, and a network that stays down still only appends once;
#   - the cadence can be raised and lowered, the setting in force is readable,
#     and a sweep that is not due takes no reading at all;
#   - the relaxed scheduler never lands on a multiple-of-five minute;
#   - a remote status document cannot split its own entry or forge the field
#     deduplication reads;
#   - stopping the thing makes its health reading go bad rather than stay quiet;
#   - nothing here reaches Bridge, the forge API, or a git repository, and the
#     only network reach is the configured status document - asserted by
#     executing every mode with route tripwires.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is the one that must see the reporting modes speak.
export FM_FORGE_STATUS_DISABLE=0

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required to read a status document)"; exit 0; }

fm_test_tmproot TMP_ROOT fm-forge-status-tests

WATCH="$ROOT/bin/fm-forge-status.sh"
TEST_BG_PID=
TEST_BG_HOME=

cleanup_background_watch() {
  if [ -n "$TEST_BG_PID" ] && kill -0 "$TEST_BG_PID" 2>/dev/null; then
    kill "$TEST_BG_PID" 2>/dev/null || true
    wait "$TEST_BG_PID" 2>/dev/null || true
  fi
  if [ -n "$TEST_BG_HOME" ]; then
    rm -f "$TEST_BG_HOME/fetch-ready" "$TEST_BG_HOME/fetch-release" \
      "$TEST_BG_HOME/first-out" "$TEST_BG_HOME/first-exit" \
      "$TEST_BG_HOME/report-before-contention"
  fi
  TEST_BG_PID=
  TEST_BG_HOME=
}

cleanup_forge_status_test() {
  cleanup_background_watch
  fm_test_cleanup
}

trap cleanup_forge_status_test EXIT

wait_for_file() {
  local path=$1 description=$2 deadline=$(( SECONDS + 5 ))
  while [ ! -e "$path" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  [ -e "$path" ] || fail "timed out waiting for $description"
}

wait_for_process() {
  local pid=$1 result=$2 description=$3 status
  wait_for_file "$result" "$description"
  wait "$pid" || fail "$description wrapper failed"
  status=$(cat "$result")
  [ "$status" -eq 0 ] || fail "$description failed with status $status"
}

fm_mode_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# The two status documents this suite reads. They are the shape of the real
# summary document, including the restamped page timestamp that a fingerprint
# must ignore.
write_documents() {
  local home=$1
  cat > "$home/clear.json" <<'JSON'
{"page":{"id":"p","updated_at":"2026-08-17T14:00:00Z"},
 "components":[{"id":"c1","name":"Git Operations","status":"operational","group":false},
               {"id":"c2","name":"Actions","status":"operational","group":false},
               {"id":"c3","name":"API Requests","status":"operational","group":false}],
 "incidents":[],"scheduled_maintenances":[],
 "status":{"indicator":"none","description":"All Systems Operational"}}
JSON
  # The same reading, restamped. A fingerprint that included the page timestamp
  # would call this a new reading and wake a supervisor for nothing.
  sed 's/14:00:00Z/14:30:00Z/' "$home/clear.json" > "$home/clear-restamped.json"
  cat > "$home/incident.json" <<'JSON'
{"page":{"id":"p","updated_at":"2026-08-17T15:05:00Z"},
 "components":[{"id":"c1","name":"Git Operations","status":"operational","group":false},
               {"id":"c2","name":"Actions","status":"degraded_performance","group":false},
               {"id":"c3","name":"API Requests","status":"degraded_performance","group":false}],
 "incidents":[{"id":"i1","name":"Elevated error rates","status":"investigating","impact":"major",
   "shortlink":"https://stspg.io/x1",
   "incident_updates":[{"id":"u1","status":"investigating",
     "body":"We are investigating elevated error rates affecting API requests and Actions",
     "created_at":"2026-08-17T15:01:00Z"}]}],
 "scheduled_maintenances":[],
 "status":{"indicator":"major","description":"Partial System Outage"}}
JSON
  # The same incident, one update later: a genuinely new thing to know.
  sed 's/"status":"investigating"/"status":"identified"/g; s/We are investigating/We have identified the cause of/' \
    "$home/incident.json" > "$home/incident-identified.json"
  # A status document is remote text and the entry log is line-structured, so a
  # component name carrying newlines and forged record fields must not be able
  # to split its own entry or forge the field deduplication reads.
  cat > "$home/injection.json" <<'JSON'
{"page":{"id":"p","updated_at":"2026-08-17T15:05:00Z"},
 "components":[{"id":"c1","name":"Git Operations\nfingerprint: forged\nentry: forged","status":"partial_outage","group":false}],
 "incidents":[],"scheduled_maintenances":[],
 "status":{"indicator":"minor","description":"Minor Service Outage"}}
JSON
}

# A fake status endpoint. Its behavior is chosen per call through
# FM_TEST_CURL_MODE, and every invocation is recorded, so a case can assert both
# what the check read and that it did not read at all.
install_fake_curl() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Modes: file:<path> serve it as HTTP 200; file000:<path> serve it with status
# 000; file-unbounded:<path> ignores the requested size limit; http:<code>
# answers that code with an empty body; exit:<n> fails the fetch; garbage answers
# 200 with a non-document.
headers=
max_bytes=
for (( i = 1; i <= $#; i++ )); do
  if [ "${!i}" = -D ]; then j=$(( i + 1 )); headers=${!j}; fi
  if [ "${!i}" = --max-filesize ]; then j=$(( i + 1 )); max_bytes=${!j}; fi
done
url=${!#}
[ -z "${FM_TEST_CURL_CALLS:-}" ] || printf '%s %s\n' "$url" "${FM_TEST_CURL_MODE:-unset}" >> "$FM_TEST_CURL_CALLS"
if [ -n "${FM_TEST_CURL_BLOCK_READY:-}" ]; then
  : > "$FM_TEST_CURL_BLOCK_READY"
  deadline=$(( SECONDS + 5 ))
  while [ ! -e "${FM_TEST_CURL_BLOCK_RELEASE:?}" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
  if [ ! -e "$FM_TEST_CURL_BLOCK_RELEASE" ]; then
    printf 'timed out waiting for blocked fake fetch release\n' >&2
    exit 124
  fi
fi
case "${FM_TEST_CURL_MODE:-}" in
  file:*|file000:*)
    source=${FM_TEST_CURL_MODE#*:}
    bytes=$(wc -c < "$source" | tr -d '[:space:]')
    [ -z "$max_bytes" ] || [ "$bytes" -le "$max_bytes" ] || exit 63
    case "$FM_TEST_CURL_MODE" in file000:*) ;; *) printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers" ;; esac
    cat "$source" 2>/dev/null || exit 7
    exit 0
    ;;
  file-unbounded:*) printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"; cat "${FM_TEST_CURL_MODE#file-unbounded:}" 2>/dev/null || exit 23; exit 0 ;;
  http:*) printf 'HTTP/1.1 %s Test\r\n\r\n' "${FM_TEST_CURL_MODE#http:}" > "$headers"; exit 0 ;;
  exit:*) exit "${FM_TEST_CURL_MODE#exit:}" ;;
  garbage) printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"; printf 'not a status document\n'; exit 0 ;;
esac
exit 9
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# A home with its own state. The script runs from a COPY in the home's own bin
# so --arm resolves fm-check-register.sh beside it and no test reaches this
# checkout's state.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/bin"
  cp "$WATCH" "$home/bin/fm-forge-status.sh"
  cp "$ROOT/bin/fm-check-register.sh" "$home/bin/fm-check-register.sh"
  cp "$ROOT/bin/fm-pr-lib.sh" "$home/bin/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-check-lib.sh" "$home/bin/fm-check-lib.sh"
  chmod +x "$home/bin/fm-forge-status.sh" "$home/bin/fm-check-register.sh"
  write_documents "$home"
  install_fake_curl "$home" >/dev/null
  : > "$home/curl-calls"
  printf '%s\n' "$home"
}

# Every run goes through the fake endpoint, so no case in this suite can reach
# the real network even by mistake.
run_watch() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_CURL_CALLS="$home/curl-calls" \
    "$home/bin/fm-forge-status.sh" "$@"
}

serve() {  # <home> <document>
  printf 'file:%s\n' "$1/$2.json" > "$1/mode"
  FM_TEST_CURL_MODE="file:$1/$2.json"
  export FM_TEST_CURL_MODE
}

serve_failure() {  # <mode>
  FM_TEST_CURL_MODE=$1
  export FM_TEST_CURL_MODE
}

record_value() {
  local home=$1 key=$2
  sed -n "s/^$key: //p" "$home/state/forge-status.report"
}

entry_count() {
  local n
  n=$(grep -c '^entry:' "$1/state/forge-status.log" 2>/dev/null) || n=0
  printf '%s' "$n"
}

fetch_count() {
  local n
  n=$(grep -c . "$1/curl-calls" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# --- recording, and the silence that comes from having nothing new ----------

test_a_new_reading_is_recorded_once_and_never_repeated_while_it_holds() {
  local home out
  home=$(make_home transition)
  run_watch "$home" --arm >/dev/null || fail "arming failed"

  serve "$home" clear
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'FORGE_STATUS:' "the first reading must reach a session"
  [ "$(entry_count "$home")" -eq 1 ] || fail "the first reading was not recorded"

  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "an unchanged reading woke a supervisor: $out"
  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "an unchanged reading woke a supervisor on the third look: $out"
  [ "$(entry_count "$home")" -eq 1 ] || fail "an unchanged reading was appended again"

  # The same reading with the page's own timestamp moved on is still the same
  # reading. This is the case that decides whether the log is signal or noise.
  serve "$home" clear-restamped
  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "a restamped but unchanged reading woke a supervisor: $out"
  [ "$(entry_count "$home")" -eq 1 ] || fail "a restamped but unchanged reading was appended"

  serve "$home" incident
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'major (Partial System Outage)' \
    "the changed reading must carry what changed"
  assert_contains "$out" 'Actions=degraded_performance' \
    "the changed reading must name the components that are not operational"
  assert_contains "$out" 'Elevated error rates' "the changed reading must name the open incident"
  [ "$(entry_count "$home")" -eq 2 ] || fail "the changed reading was not recorded"

  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "the incident repeated itself while it held: $out"
  [ "$(entry_count "$home")" -eq 2 ] || fail "the held incident was appended twice"

  # An incident that moves on is news; the state holding is not.
  serve "$home" incident-identified
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'FORGE_STATUS:' "a moved-on incident must reach a session"
  assert_contains "$out" 'identified' "the wake must carry the incident's new status"
  [ "$(entry_count "$home")" -eq 3 ] || fail "the incident update was not recorded"

  serve "$home" clear
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'All Systems Operational' "the return to clear must reach a session"
  [ "$(entry_count "$home")" -eq 4 ] || fail "the return to clear was not recorded"
  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "clear repeated itself while it held: $out"
  pass "each new reading is recorded and wakes once; a held reading stays silent"
}

test_the_wake_says_what_a_vessel_should_not_conclude() {
  local home out
  home=$(make_home warning)
  run_watch "$home" --arm >/dev/null
  serve "$home" incident
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'may be the forge and not our code' \
    "the wake must carry the warning that had to be sent by hand"
  assert_contains "$out" 'reproduced locally before it is believed' \
    "the wake must say what to do with a failing check in this window"
  assert_contains "$out" '--cadence raised' "the wake must name how to raise the watch"
  assert_contains "$out" '--cadence relaxed' "the wake must name how to lower it"
  assert_contains "$out" 'Cadence now: relaxed' "the wake must say which cadence is in force"
  pass "the wake carries the judgement firstmate needs and the cadence in force"
}

# --- cannot reach is not all clear ------------------------------------------

test_an_unreachable_status_page_is_unmeasurable_and_never_clear() {
  local home out entry
  home=$(make_home unreachable)
  run_watch "$home" --arm >/dev/null

  serve_failure exit:7
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "an unreadable status page must say so"
  assert_contains "$out" 'NOT a clear reading' \
    "an unreadable status page must refuse to be read as healthy"
  assert_not_contains "$out" 'All Systems Operational' \
    "an unreadable status page must not report any indicator"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'reading: unmeasurable' "the entry must record the unmeasurable reading"
  assert_contains "$entry" 'fetch exit 7' "the entry must name the concrete condition"
  assert_contains "$entry" 'unmeasurable is NOT clear' \
    "the entry must state what it does not claim"

  # A network that stays down is not news every five minutes, but the last entry
  # must keep saying unmeasurable for as long as it is true.
  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "an unchanged unmeasurable reading repeated: $out"
  [ "$(entry_count "$home")" -eq 1 ] || fail "an unchanged unmeasurable reading was appended twice"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'reading: unmeasurable' \
    "the standing reading must remain unmeasurable rather than lapsing to clear"

  # A DIFFERENT failure is a different reading.
  serve_failure http:503
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "a changed failure mode must be recorded"
  assert_contains "$out" 'HTTP 503' "the wake must name the answer it got"
  [ "$(entry_count "$home")" -eq 2 ] || fail "a changed failure mode was not recorded"

  serve_failure garbage
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "an unreadable body must be unmeasurable, not clear"
  assert_contains "$out" 'not a readable status document' \
    "an unreadable body must name that condition"
  [ "$(entry_count "$home")" -eq 3 ] || fail "an unreadable body was not recorded"

  # And recovery is itself a new reading.
  serve "$home" clear
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'All Systems Operational' "recovery must reach a session"
  pass "an unreadable status page reports unmeasurable, once, and never as clear"
}

test_an_oversized_status_document_is_unmeasurable_and_never_parsed() {
  local home fallback_home out entry
  home=$(make_home oversized)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear

  out=$(FM_FORGE_STATUS_MAX_BYTES=100 run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "an oversized body must be unmeasurable"
  assert_contains "$out" '100-byte response limit' "the wake must name the effective size limit"
  assert_contains "$out" 'NOT a clear reading' "an oversized body must refuse to be read as healthy"
  assert_not_contains "$out" 'All Systems Operational' "an oversized body must not be parsed as a reading"
  [ "$(entry_count "$home")" -eq 1 ] || fail "the oversized refusal was not recorded once"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'reading: unmeasurable' "the oversized entry must remain unmeasurable"
  assert_contains "$entry" '100-byte response limit' "the entry must retain the concrete size condition"

  out=$(FM_FORGE_STATUS_MAX_BYTES=100 run_watch "$home" --force)
  [ -z "$out" ] || fail "an unchanged oversized refusal repeated: $out"
  [ "$(entry_count "$home")" -eq 1 ] || fail "the oversized refusal was appended twice"

  fallback_home=$(make_home oversized-fallback)
  FM_TEST_CURL_MODE="file-unbounded:$fallback_home/clear.json"
  export FM_TEST_CURL_MODE
  out=$(FM_FORGE_STATUS_MAX_BYTES=100 run_watch "$fallback_home" --force)
  assert_contains "$out" 'UNMEASURABLE' "the parser boundary must reject a body the transport allowed"
  assert_contains "$out" 'exceeded the effective 100-byte response limit' \
    "the fallback refusal must name the effective limit"
  assert_not_contains "$out" 'All Systems Operational' \
    "the fallback refusal must happen before status parsing"
  [ "$(entry_count "$fallback_home")" -eq 1 ] \
    || fail "the parser-boundary oversized refusal was not recorded once"
  pass "an oversized status body is recorded once as unmeasurable and never parsed"
}

test_the_status_body_cap_is_range_safe_and_clamped() {
  local configured home malformed_home out
  home=$(make_home capped-override)
  dd if=/dev/zero of="$home/oversized.json" bs=1000000 count=5 2>/dev/null
  printf 'x' >> "$home/oversized.json"
  serve "$home" oversized

  out=$(FM_FORGE_STATUS_MAX_BYTES=9999999 run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "a cap above the hard ceiling must not admit an oversized body"
  assert_contains "$out" 'effective 5000000-byte response limit' \
    "the refusal must expose the clamped effective cap"
  assert_not_contains "$out" 'All Systems Operational' \
    "a body above the hard ceiling must never become a measured reading"
  out=$(run_watch "$home" --status)
  assert_contains "$out" 'status-max-response-bytes: 5000000' \
    "the persisted record must expose the effective ceiling"

  malformed_home=$(make_home malformed-cap)
  rmdir "$malformed_home/state" || fail "could not prepare a cap test without state"
  for configured in '' 0 -1 nope 999999999999999999999999; do
    out=$(FM_FORGE_STATUS_MAX_BYTES=$configured run_watch "$malformed_home" --status)
    assert_contains "$out" 'status-max-response-bytes: 1000000' \
      "an invalid cap '$configured' must fall back to the default"
  done
  [ ! -e "$malformed_home/state" ] || fail "reading a malformed effective cap created state"
  pass "the response cap is range safe, clamped, and visible"
}

test_the_fetch_timeout_is_range_safe_and_clamped() {
  local configured home out
  home=$(make_home timeout-boundary)
  rmdir "$home/state" || fail "could not prepare a timeout test without state"

  out=$(FM_FORGE_STATUS_TIMEOUT=120 run_watch "$home" --status)
  assert_contains "$out" 'status-fetch-timeout-seconds: 15' \
    "an excessive timeout must be clamped inside the watcher budget"
  assert_contains "$out" 'transaction-lock-stale-after-seconds: 75' \
    "the stale floor must derive from the clamped timeout"

  for configured in '' 0 -1 nope 999999999999999999999999; do
    out=$(FM_FORGE_STATUS_TIMEOUT=$configured run_watch "$home" --status)
    assert_contains "$out" 'status-fetch-timeout-seconds: 10' \
      "an invalid timeout '$configured' must fall back to the default"
    assert_contains "$out" 'transaction-lock-stale-after-seconds: 70' \
      "an invalid timeout '$configured' must not weaken the derived stale floor"
  done
  [ ! -e "$home/state" ] || fail "reading an effective timeout created state"
  pass "the fetch timeout is range safe, clamped, and visible"
}

test_http_000_is_unmeasurable_but_non_http_000_can_be_read() {
  local home out entry
  home=$(make_home status000)

  FM_TEST_CURL_MODE="file000:$home/clear.json"
  export FM_TEST_CURL_MODE
  out=$(FM_FORGE_STATUS_URL=https://status.example.test/summary.json run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "HTTP status 000 must not be accepted for HTTPS"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'HTTP 000' "the HTTPS failure must retain its concrete status"

  out=$(FM_FORGE_STATUS_URL=HtTpS://status.example.test/summary.json run_watch "$home" --force)
  assert_contains "$out" 'UNMEASURABLE' "mixed-case HTTPS status 000 must not be accepted"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'reading: unmeasurable' "mixed-case HTTPS must remain unmeasurable"

  out=$(FM_FORGE_STATUS_URL="file://$home/clear.json" run_watch "$home" --force)
  assert_contains "$out" 'All Systems Operational' "a successful non-HTTP status document must be read"
  entry=$(run_watch "$home" --log 1)
  assert_contains "$entry" 'reading: measured' "the non-HTTP document must be recorded as measured"
  pass "HTTP 000 is unmeasurable while non-HTTP 000 can carry a reading"
}

test_a_status_document_cannot_forge_a_record_field() {
  local home out entry fields
  home=$(make_home injection)
  run_watch "$home" --arm >/dev/null

  serve "$home" injection
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'FORGE_STATUS:' "the reading must still be taken"
  entry=$(run_watch "$home" --log 1)
  fields=$(printf '%s\n' "$entry" | grep -c '^fingerprint:')
  [ "$fields" -eq 1 ] || fail "the entry carries $fields fingerprint lines, so its text was not flattened"
  fields=$(printf '%s\n' "$entry" | grep -c '^entry:')
  [ "$fields" -eq 1 ] || fail "the entry carries $fields entry lines, so a component name split it"
  assert_contains "$entry" 'Git Operations fingerprint: forged entry: forged=partial_outage' \
    "the hostile name must be recorded inline rather than as its own fields"

  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "the forged field defeated deduplication: $out"
  pass "a status document cannot split an entry or forge the field deduplication reads"
}

# --- the cadence -------------------------------------------------------------

test_the_cadence_is_settable_and_the_setting_in_force_is_readable() {
  local home out next now
  home=$(make_home cadence)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear
  # One pinned instant for every schedule below, so the assertions are about the
  # cadence rather than about how long the case took to run.
  now=$(( $(date +%s) / 300 * 300 ))
  FM_FORGE_STATUS_NOW="$now" run_watch "$home" >/dev/null

  out=$(run_watch "$home" --cadence)
  assert_contains "$out" 'relaxed: every 7200s' "the default cadence must be readable"
  assert_contains "$out" 'never a multiple of five' "the relaxed cadence must state its refusal"

  out=$(FM_FORGE_STATUS_NOW="$now" run_watch "$home" --cadence raised)
  assert_contains "$out" 'raised: every 300s' "raising must report the cadence it set"
  [ "$(record_value "$home" cadence)" = raised ] || fail "raising did not persist the cadence"
  next=$(record_value "$home" next-epoch)
  [ "$next" -eq $(( now + 300 )) ] \
    || fail "raising the cadence did not schedule the next observation 300s out"
  out=$(run_watch "$home" --status)
  assert_contains "$out" 'cadence: raised' "--status must print the cadence in force"
  out=$(run_watch "$home" --cadence)
  assert_contains "$out" 'raised: every 300s' "--cadence must print the raised setting in force"

  out=$(FM_FORGE_STATUS_NOW="$now" run_watch "$home" --cadence relaxed)
  assert_contains "$out" 'relaxed: every 7200s' "lowering must report the cadence it set"
  [ "$(record_value "$home" cadence)" = relaxed ] || fail "lowering did not persist the cadence"
  next=$(record_value "$home" next-epoch)
  [ "$next" -ge $(( now + 7200 + 180 )) ] && [ "$next" -le $(( now + 7200 + 420 )) ] \
    || fail "the relaxed target is not a period plus jitter from now: $next"
  [ "$(( ( next / 60 ) % 60 % 5 ))" -ne 0 ] \
    || fail "the relaxed target landed on the five-minute grid"
  pass "the cadence can be raised and lowered, and the setting in force is readable"
}

test_state_changes_are_serialized_without_blocking_a_check() {
  local home now due first_out second_out status=0
  home=$(make_home serialized)
  now=1786968000
  serve "$home" clear
  FM_FORGE_STATUS_NOW="$now" run_watch "$home" >/dev/null
  due=$(record_value "$home" next-epoch)
  cp "$home/state/forge-status.report" "$home/report-before-contention"

  TEST_BG_HOME=$home
  ( FM_TEST_CURL_BLOCK_READY="$home/fetch-ready" \
      FM_TEST_CURL_BLOCK_RELEASE="$home/fetch-release" \
      FM_FORGE_STATUS_NOW="$due" run_watch "$home" > "$home/first-out"
    printf '%s\n' "$?" > "$home/first-exit"
  ) &
  TEST_BG_PID=$!
  wait_for_file "$home/fetch-ready" "the first observation to enter the blocked fake fetch"

  second_out=$(FM_FORGE_STATUS_NOW="$due" run_watch "$home") || status=$?
  [ "$status" -eq 0 ] || fail "a contending watcher check must exit quietly: $second_out"
  [ -z "$second_out" ] || fail "a contending watcher check must print nothing: $second_out"

  status=0
  second_out=$(FM_FORGE_STATUS_NOW="$due" run_watch "$home" --force) || status=$?
  [ "$status" -eq 0 ] || fail "a contending force observation must exit quietly: $second_out"
  [ -z "$second_out" ] || fail "a contending force observation must print nothing: $second_out"

  status=0
  second_out=$(FM_FORGE_STATUS_NOW="$due" run_watch "$home" --cadence raised 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a concurrent cadence change must not report success"
  assert_contains "$second_out" 'already in progress' "a rejected cadence change must explain the contention"
  [ "$(entry_count "$home")" -eq 0 ] || fail "a contending operation appended an entry"
  cmp -s "$home/report-before-contention" "$home/state/forge-status.report" \
    || fail "a contending operation changed persisted state"

  : > "$home/fetch-release"
  wait_for_process "$TEST_BG_PID" "$home/first-exit" "the lock-holding observation to complete"
  TEST_BG_PID=
  first_out=$(cat "$home/first-out")
  assert_contains "$first_out" 'FORGE_STATUS:' "the lock-holding observation must complete"
  [ "$(entry_count "$home")" -eq 1 ] || fail "concurrent checks appended duplicate readings"
  [ "$(record_value "$home" cadence)" = relaxed ] || fail "a rejected cadence change altered persisted cadence"
  cleanup_background_watch
  pass "state changes serialize and a contending check exits quietly"
}

test_the_transaction_lock_needs_no_flock_and_recovers_abandoned_states() {
  local home out lock reclaim
  home=$(make_home portable-lock)
  lock="$home/state/forge-status.transaction.lock.d"
  reclaim="$lock.reclaim"
  serve "$home" clear
  printf '#!/usr/bin/env bash\nexit 99\n' > "$home/fakebin/flock"
  chmod +x "$home/fakebin/flock"

  out=$(run_watch "$home" --force)
  assert_contains "$out" 'FORGE_STATUS:' "an observation must not depend on flock"
  [ "$(entry_count "$home")" -eq 1 ] || fail "the flock-free observation did not append"

  mkdir "$lock"
  printf '99999999\n' > "$lock/pid"
  touch -t 202001010000 "$lock"
  serve "$home" incident
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'Partial System Outage' "a dead transaction owner must not wedge the watch"
  [ "$(entry_count "$home")" -eq 2 ] || fail "the recovered transaction did not append"

  mkdir "$lock"
  touch -t 202001010000 "$lock"
  serve "$home" clear
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'All Systems Operational' "an aged incomplete lock must be reclaimed"

  mkdir "$lock" "$reclaim"
  printf '99999999\n' > "$lock/pid"
  touch -t 202001010000 "$lock" "$reclaim"
  serve "$home" incident
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'Partial System Outage' "an aged abandoned reclaim mutex must be recovered"
  [ "$(entry_count "$home")" -eq 4 ] || fail "abandoned lock recovery lost an observation"

  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  touch -t 202001010000 "$lock"
  serve "$home" clear
  out=$(run_watch "$home" --force)
  assert_contains "$out" 'All Systems Operational' "an aged lock must be reclaimed despite PID reuse"
  [ "$(entry_count "$home")" -eq 5 ] || fail "PID reuse recovery lost an observation"

  FM_FORGE_STATUS_TIMEOUT=120 FM_FORGE_STATUS_LOCK_STALE_AFTER=1 \
    run_watch "$home" --cadence raised >/dev/null
  out=$(run_watch "$home" --status)
  assert_contains "$out" 'status-fetch-timeout-seconds: 15' \
    "the recorded effective timeout must stay inside the watcher budget"
  assert_contains "$out" 'transaction-lock-stale-after-seconds: 75' \
    "the recorded lock bound must derive from the effective fetch timeout"
  pass "the portable transaction lock recovers every abandoned state"
}

test_a_sweep_that_is_not_due_takes_no_reading_and_a_due_one_does() {
  local home now out
  home=$(make_home due)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear
  now=$(date +%s)
  FM_FORGE_STATUS_NOW="$now" run_watch "$home" --cadence raised >/dev/null
  : > "$home/curl-calls"

  out=$(FM_FORGE_STATUS_NOW=$(( now + 299 )) run_watch "$home")
  [ -z "$out" ] || fail "a sweep before the target spoke: $out"
  [ "$(fetch_count "$home")" -eq 0 ] \
    || fail "a sweep before the target read the status page: $(cat "$home/curl-calls")"

  out=$(FM_FORGE_STATUS_NOW=$(( now + 300 )) run_watch "$home")
  assert_contains "$out" 'FORGE_STATUS:' "the due sweep must take and report the first reading"
  [ "$(fetch_count "$home")" -eq 1 ] || fail "the due sweep did not read the status page exactly once"
  [ "$(record_value "$home" next-epoch)" -eq $(( now + 600 )) ] \
    || fail "a raised observation did not schedule the next one 300s out"

  # And the raised cadence keeps its period rather than reverting.
  out=$(FM_FORGE_STATUS_NOW=$(( now + 600 )) run_watch "$home")
  [ -z "$out" ] || fail "an unchanged due reading spoke: $out"
  [ "$(fetch_count "$home")" -eq 2 ] || fail "the second due sweep did not read the status page"
  [ "$(record_value "$home" cadence)" = raised ] || fail "the cadence reverted on its own"
  pass "a sweep that is not due reads nothing; a due one reads once and re-schedules"
}

test_the_relaxed_scheduler_never_lands_on_the_five_minute_grid() {
  local home draws on_grid count
  home=$(make_home grid)

  # 2000 independent draws. The refusal is the property under test, so a merely
  # unlikely hit must fail this case rather than pass it.
  draws=$(run_watch "$home" --draw 2000) || fail "the scheduler refused to draw at all"
  count=$(printf '%s\n' "$draws" | grep -c .)
  [ "$count" -eq 2000 ] || fail "expected 2000 draws, got $count"
  on_grid=$(printf '%s\n' "$draws" | awk '{ if (int($1 / 60) % 60 % 5 == 0) n++ } END { print n + 0 }')
  [ "$on_grid" -eq 0 ] \
    || fail "$on_grid of $count drawn targets landed on a five-minute boundary"
  pass "2000 drawn relaxed targets, none on a multiple-of-five minute"
}

test_a_window_with_no_off_grid_minute_refuses_rather_than_scheduling_on_it() {
  local home out status=0
  home=$(make_home refuse)

  # The relaxed period is a whole number of hours, so base 0 plus 7200 plus 0
  # lands on minute 0. The refusal must exhaust and report, never fall back.
  out=$(FM_FORGE_STATUS_NOW=0 FM_FORGE_STATUS_JITTER_MIN=0 FM_FORGE_STATUS_JITTER_MAX=0 \
    run_watch "$home" --draw 1 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a window containing only an on-grid minute must refuse: $out"
  assert_contains "$out" 'refusing to schedule' \
    "the refusal must say it refused rather than reporting an empty draw"

  status=0
  out=$(FM_FORGE_STATUS_NOW=0 FM_FORGE_STATUS_JITTER_MIN=0 FM_FORGE_STATUS_JITTER_MAX=0 \
    run_watch "$home" 2>&1) || status=$?
  assert_contains "$out" 'FORGE_STATUS:' "an exhausted draw must raise a wake"
  assert_contains "$out" 'landed on the five-minute grid' \
    "the wake must distinguish a draw refusal from dead supervision"
  assert_not_contains "$out" 'nothing is executing it' \
    "a draw refusal must not masquerade as a supervision outage"
  pass "a window with no off-grid minute refuses instead of accepting one"
}

# --- durability -------------------------------------------------------------

test_a_failed_record_publish_does_not_duplicate_or_lose_the_reading() {
  local home out status=0 fakebin real_mv report
  home=$(make_home publish-failure)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear
  run_watch "$home" --force >/dev/null
  report="$home/state/forge-status.report"

  fakebin="$home/fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
if [ "\${!#}" = "$report" ]; then
  exit 1
fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"

  serve "$home" incident
  out=$(run_watch "$home" --force) || status=$?
  [ "$status" -ne 0 ] || fail "a failed record publish reported success: $out"
  assert_contains "$out" 'state persistence failure' "the failed publish must be actionable"
  assert_contains "$out" 'FORGE_STATUS:' "the reading itself must still have reached a session"
  [ "$(entry_count "$home")" -eq 2 ] || fail "the reading was lost when its record could not be published"

  rm -f "$fakebin/mv"
  out=$(run_watch "$home" --force)
  [ -z "$out" ] || fail "the recovered run re-announced a reading it had already recorded: $out"
  [ "$(entry_count "$home")" -eq 2 ] \
    || fail "the recovered run appended the same reading a second time"
  [ "$(record_value "$home" state)" = scheduled ] || fail "the recovered run did not re-schedule"
  pass "a failed record publish neither loses the reading nor duplicates it"
}

# --- the boundary: no Bridge, no forge API, no repository -------------------

test_no_bridge_forge_or_git_binary_is_ever_invoked() {
  local home fakebin trip tool shim calls
  home=$(make_home tripwire)
  fakebin="$home/fakebin"
  trip="$home/tripped"
  mkdir -p "$trip"
  # Tripwires named after every route out of this machine EXCEPT the one bounded
  # fetch this watch exists to make. If any mode reaches for one of them, its
  # name appears in $trip and the case fails.
  for tool in fm-bridge-relay.sh bridge-axi gh gh-axi git wget nc ssh scp; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
: > "$trip/\$(basename "\$0")"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done

  serve "$home" clear
  run_watch "$home" --arm >/dev/null || fail "arming failed"
  shim="$home/state/forge-status.check.sh"
  [ -x "$shim" ] || fail "arming did not create the registered watcher shim"
  [ -f "$home/state/forge-status.check-trust" ] || fail "arming did not register the watcher shim"
  PATH="$fakebin:$PATH" FM_TEST_CURL_CALLS="$home/curl-calls" "$shim" >/dev/null
  run_watch "$home" --force >/dev/null
  run_watch "$home" --status >/dev/null
  run_watch "$home" --cadence >/dev/null
  run_watch "$home" --log 1 >/dev/null
  run_watch "$home" --armed >/dev/null
  run_watch "$home" --draw 3 >/dev/null
  run_watch "$home" --help >/dev/null

  tool=$(ls -A "$trip")
  [ -z "$tool" ] || fail "the forge watch invoked: $tool"
  # One reach off this machine, to one address: the status document itself.
  calls=$(awk '{ print $1 }' "$home/curl-calls" | sort -u)
  [ "$calls" = 'https://www.githubstatus.com/api/v2/summary.json' ] \
    || fail "the only fetch must be the configured status document, got: $calls"
  pass "every mode avoids Bridge, the forge API, and git, and fetches only the status document"
}

# --- arming, and the health reading that is not a unit's own claim ----------

test_arming_is_idempotent_and_registers_the_check() {
  local home first second
  home=$(make_home arm)

  run_watch "$home" --arm >/dev/null || fail "arming failed"
  [ -x "$home/state/forge-status.check.sh" ] || fail "the watcher check was not written"
  [ -f "$home/state/forge-status.check-trust" ] || fail "the watcher check was not registered"
  [ "$(fm_mode_of "$home/state/forge-status.check.sh")" = 700 ] \
    || fail "the watcher check must be private and executable"
  first=$(cat "$home/state/forge-status.check.sh")

  run_watch "$home" --arm >/dev/null || fail "re-arming failed"
  second=$(cat "$home/state/forge-status.check.sh")
  [ "$first" = "$second" ] || fail "re-arming rewrote an already-correct check"
  pass "arming writes a private registered check and converges on re-run"
}

test_arming_schedules_the_first_observation_without_reading_or_waking() {
  local home out
  home=$(make_home first-schedule)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear

  out=$(run_watch "$home")
  [ -z "$out" ] || fail "the first sweep on a fresh home spoke: $out"
  [ "$(fetch_count "$home")" -eq 0 ] || fail "the first sweep read the status page before it was due"
  [ "$(record_value "$home" state)" = scheduled ] || fail "the first sweep did not schedule"
  [ "$(record_value "$home" cadence)" = relaxed ] || fail "the first schedule was not the relaxed cadence"
  out=$(run_watch "$home" --armed)
  [ -z "$out" ] || fail "a freshly scheduled watch must have a silent health reading: $out"
  pass "arming schedules the first observation without reading or waking"
}

test_a_stopped_watch_makes_the_health_reading_fail() {
  local home out due
  home=$(make_home stopped)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear
  run_watch "$home" --force >/dev/null
  due=$(record_value "$home" next-epoch)

  # Stop it the way a dead timer stops: the schedule stays, the shim stays, and
  # nothing executes it. Every surface still looks armed.
  out=$(FM_FORGE_STATUS_NOW=$(( due + 7200 )) run_watch "$home" --armed)
  assert_contains "$out" 'FORGE_STATUS:' "a target nothing executes must be loud"
  assert_contains "$out" 'nothing is executing it' \
    "the reading must say the schedule stands and nothing is running it"
  assert_contains "$out" 'the forge is unwatched' \
    "the reading must state the consequence rather than only the mechanism"
  assert_contains "$out" 'it last read the status page' \
    "the reading must report when the watch last actually read the page"
  pass "a watch that stopped observing reports a bad reading rather than staying quiet"
}

test_a_raised_watch_is_called_stopped_sooner_than_a_relaxed_one() {
  local home due out
  home=$(make_home slack)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear
  run_watch "$home" --force >/dev/null

  due=$(record_value "$home" next-epoch)
  out=$(FM_FORGE_STATUS_NOW=$(( due + 2000 )) run_watch "$home" --armed)
  [ -z "$out" ] || fail "a relaxed watch 2000s past its target must still be within slack: $out"

  run_watch "$home" --cadence raised >/dev/null
  due=$(record_value "$home" next-epoch)
  out=$(FM_FORGE_STATUS_NOW=$(( due + 2000 )) run_watch "$home" --armed)
  assert_contains "$out" 'FORGE_STATUS:' \
    "a raised watch that missed its target by 2000s must be loud"
  pass "the health reading's patience follows the cadence in force"
}

test_an_unarmed_home_is_loud() {
  local home out
  home=$(make_home unarmed)
  out=$(run_watch "$home" --armed)
  assert_contains "$out" 'FORGE_STATUS:' "an unarmed home must produce the diagnostic"
  assert_contains "$out" 'is not armed' "the diagnostic must name the unarmed state"
  assert_contains "$out" '--arm' "the diagnostic must carry its own repair"
  pass "an unarmed home says so"
}

test_a_watch_that_never_scheduled_an_observation_is_loud() {
  local home out shim
  home=$(make_home notrigger)
  run_watch "$home" --arm >/dev/null
  shim="$home/state/forge-status.check.sh"

  out=$(run_watch "$home" --armed)
  [ -z "$out" ] || fail "a freshly armed home must not be called stopped: $out"

  out=$(FM_FORGE_STATUS_NOW=$(( $(date +%s) + 7200 )) run_watch "$home" --armed)
  assert_contains "$out" 'never scheduled an observation' \
    "an armed shim nothing ever ran must be loud"
  assert_contains "$out" 'nothing is running this home' \
    "the reading must name the supervision cause"
  [ -x "$shim" ] || fail "the health reading disturbed the shim"
  pass "an armed watch that never scheduled anything is loud"
}

test_a_disabled_watch_stays_out_of_composing_suites() {
  local home out
  home=$(make_home disabled)
  run_watch "$home" --arm >/dev/null
  serve "$home" clear

  out=$(FM_FORGE_STATUS_DISABLE=1 run_watch "$home")
  [ -z "$out" ] || fail "the detect mode must be silent when disabled: $out"
  [ "$(fetch_count "$home")" -eq 0 ] || fail "a disabled watch reached the network"
  out=$(FM_FORGE_STATUS_DISABLE=1 run_watch "$home" --armed)
  [ -z "$out" ] || fail "the armed reading must be silent when disabled: $out"
  out=$(FM_FORGE_STATUS_DISABLE=1 run_watch "$home" --status)
  assert_contains "$out" 'cadence: ' "--status must ignore the disable switch"
  out=$(FM_FORGE_STATUS_DISABLE=1 run_watch "$home" --draw 1)
  case "$out" in ''|*[!0-9]*) fail "--draw must ignore the disable switch" ;; esac
  pass "the disable switch silences the reporting modes and the fetch with them"
}

test_every_public_mode_has_an_executable_contract() {
  local home out status
  home=$(make_home public-modes)
  rmdir "$home/state" || fail "could not prepare a home without state"
  serve "$home" clear

  status=0
  out=$(run_watch "$home" --draw 1) || status=$?
  [ "$status" -eq 0 ] || fail "--draw exited $status without state: $out"
  case "$out" in ''|*[!0-9]*) fail "--draw must emit one epoch: $out" ;; esac
  [ ! -e "$home/state" ] || fail "--draw created state on a fresh home"

  status=0
  out=$(run_watch "$home" --status) || status=$?
  [ "$status" -eq 0 ] || fail "--status exited $status without state: $out"
  assert_contains "$out" 'none scheduled' "--status must report an absent schedule"
  assert_contains "$out" 'last-observation: never' "--status must report an absent observation"
  [ ! -e "$home/state" ] || fail "--status created state on a fresh home"

  status=0
  out=$(run_watch "$home" --log 1) || status=$?
  [ "$status" -eq 0 ] || fail "--log exited $status without state: $out"
  assert_contains "$out" 'no forge status readings' "--log must report an empty log plainly"

  status=0
  out=$(run_watch "$home" --arm) || status=$?
  [ "$status" -eq 0 ] || fail "--arm exited $status: $out"
  assert_contains "$out" 'armed: ' "--arm must report the registered check"

  status=0
  out=$(run_watch "$home") || status=$?
  [ "$status" -eq 0 ] || fail "bare detect exited $status: $out"
  [ -z "$out" ] || fail "a healthy first detect must be silent: $out"

  status=0
  out=$(run_watch "$home" --force) || status=$?
  [ "$status" -eq 0 ] || fail "--force exited $status: $out"
  assert_contains "$out" 'FORGE_STATUS:' "--force must observe regardless of the schedule"

  status=0
  out=$(run_watch "$home" --cadence raised) || status=$?
  [ "$status" -eq 0 ] || fail "--cadence raised exited $status: $out"

  status=0
  out=$(run_watch "$home" --armed) || status=$?
  [ "$status" -eq 0 ] || fail "--armed exited $status: $out"
  [ -z "$out" ] || fail "a healthy --armed reading must be silent: $out"

  status=0
  out=$(run_watch "$home" --cadence sideways 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "an invalid cadence must be refused, got $status: $out"

  status=0
  out=$(run_watch "$home" --nonsense 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "an unknown argument must be refused, got $status: $out"

  status=0
  out=$(run_watch "$home" --help) || status=$?
  [ "$status" -eq 0 ] || fail "--help exited $status"
  assert_contains "$out" '--cadence raised|relaxed' "--help must document setting the cadence"
  pass "every public mode executes with its observable contract"
}

test_bootstrap_arms_the_watch_and_asks_whether_it_is_still_running() {
  local home out shim
  home=$(make_home bootstrap)
  mkdir -p "$home/config" "$home/data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FORGE_STATUS_DISABLE=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" 'FORGE_STATUS:' \
    "bootstrap must leave a freshly armed watch healthy"
  shim="$home/state/forge-status.check.sh"
  [ -x "$shim" ] || fail "bootstrap did not arm the watcher shim"
  [ -f "$home/state/forge-status.check-trust" ] || fail "bootstrap did not register the watcher shim"

  rm -f "$shim"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FORGE_STATUS_DISABLE=0 \
    "$ROOT/bin/fm-forge-status.sh" --armed)
  assert_contains "$out" 'FORGE_STATUS:' \
    "an unarmed bootstrap home must produce the owned diagnostic"
  assert_contains "$out" 'is not armed' "the diagnostic must expose the stopped watch"
  pass "bootstrap observably arms, registers, and diagnoses the forge watch"
}

test_a_new_reading_is_recorded_once_and_never_repeated_while_it_holds
test_the_wake_says_what_a_vessel_should_not_conclude
test_an_unreachable_status_page_is_unmeasurable_and_never_clear
test_an_oversized_status_document_is_unmeasurable_and_never_parsed
test_the_status_body_cap_is_range_safe_and_clamped
test_the_fetch_timeout_is_range_safe_and_clamped
test_http_000_is_unmeasurable_but_non_http_000_can_be_read
test_a_status_document_cannot_forge_a_record_field
test_the_cadence_is_settable_and_the_setting_in_force_is_readable
test_state_changes_are_serialized_without_blocking_a_check
test_the_transaction_lock_needs_no_flock_and_recovers_abandoned_states
test_a_sweep_that_is_not_due_takes_no_reading_and_a_due_one_does
test_the_relaxed_scheduler_never_lands_on_the_five_minute_grid
test_a_window_with_no_off_grid_minute_refuses_rather_than_scheduling_on_it
test_a_failed_record_publish_does_not_duplicate_or_lose_the_reading
test_no_bridge_forge_or_git_binary_is_ever_invoked
test_arming_is_idempotent_and_registers_the_check
test_arming_schedules_the_first_observation_without_reading_or_waking
test_a_stopped_watch_makes_the_health_reading_fail
test_a_raised_watch_is_called_stopped_sooner_than_a_relaxed_one
test_an_unarmed_home_is_loud
test_a_watch_that_never_scheduled_an_observation_is_loud
test_a_disabled_watch_stays_out_of_composing_suites
test_every_public_mode_has_an_executable_contract
test_bootstrap_arms_the_watch_and_asks_whether_it_is_still_running
