#!/usr/bin/env bash
# THE CONTRACT between a vessel's health probe and firstmate's delivery status.
#
# Captain, 2026-09-03, vessel sweep decision 3: firstmate owns the contract
# between the vessel's health probe and firstmate's delivery and watcher status
# vocabulary, and the test holding that contract lives in firstmate-source.
# This file is that test.  docs/wake-delivery.md "Machine-readable status
# contract" states the contract for consumers; bin/fm-delivery-lib.sh owns the
# vocabulary both renderings read.  A consumer on another repository calls
#   FM_HOME=<home> bin/fm-delivery-service.sh status --format=machine
# and must be able to decide from `verdict=` alone, never from prose.
#
# What is asserted here:
#   1. every verdict the library can produce reaches the machine line, with the
#      documented exit status, through the real service command
#   2. the machine line parses with the documented parser - split on spaces,
#      then once on the first `=` - with the documented keys in the documented
#      order and no free text
#   3. the prose line's first word and the machine verdict never disagree
#   4. a consumer given each verdict can decide "seat is idle" from
#      `verdict=idle` alone
#   5. the documented reason token survives from the listener's blocked-attempt
#      record into `reason=`
#   6. an unknown flag or format is refused with exit 2, not silently ignored
#   7. docs/wake-delivery.md names every verdict and every key, so the doc and
#      the code cannot drift apart
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVICE="$ROOT/bin/fm-delivery-service.sh"
DOC="$ROOT/docs/wake-delivery.md"
fm_test_tmproot TMP_ROOT fm-delivery-status-contract

HOLDERS=()
cleanup_holders() {
  local pid
  for pid in "${HOLDERS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_holders; fm_test_cleanup' EXIT

# The documented contract, restated here as the values the test enforces.
EXPECTED_KEYS='verdict exit listener_pid pending beacon_age_seconds grace_seconds backend target reason'
expected_exit() {  # <verdict>
  case "$1" in
    idle|delivering|away) printf '0\n' ;;
    down|stalled|undeliverable) printf '1\n' ;;
    *) fail "verdict '$1' is outside the documented vocabulary" ;;
  esac
}

lib_verdicts() {
  bash -c '. "$1/bin/fm-delivery-lib.sh"; printf "%s\n" "$FM_DELIVERY_VERDICTS"' _ "$ROOT"
}

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

# A live, identity-matched listener built by hand from a sleeping holder, the
# way tests/fm-delivery.test.sh builds its stalled fixture: the classification
# under test is the reporting boundary, and a real listener would race the
# fixture by writing its own attempt outcome within a poll.
make_live_listener() {  # <home>
  local home=$1 holder identity
  sleep 300 &
  holder=$!
  HOLDERS+=("$holder")
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$holder")
  mkdir -p "$home/state/.delivery.lock"
  printf '%s\n' "$holder" > "$home/state/.delivery.lock/pid"
  printf '%s\n' "$home" > "$home/state/.delivery.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-delivery.sh" > "$home/state/.delivery.lock/delivery-path"
  printf '%s\n' "$identity" > "$home/state/.delivery.lock/pid-identity"
  touch "$home/state/.last-delivery-beat"
}

queue_wake() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal probe "signal: probe"' _ "$ROOT" \
    || fail "could not queue a wake"
}

publish_endpoint() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_endpoint_write "$2" tmux "%7" claude "$3" "/tmp/fm-contract-$$.sock,99999"' \
    _ "$ROOT" "$1/state" "$(cat "$1/state/.lock")" \
    || fail "could not publish the endpoint"
}

record_blocked_attempt() {  # <home> <prose> <token>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_attempt_outcome_write_blocked "$2" "$3" "$4"' \
    _ "$ROOT" "$1/state" "$2" "$3" \
    || fail "could not record a blocked attempt"
}

# This is exactly the consumer call the contract documents, with the grace
# pinned so a fixture beacon is judged by a known bar.  It returns the
# command's own exit status so `out=$(status ...); rc=$?` reads it.
status() {  # <home> [flags...] -> prints stdout, returns the exit status
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DELIVERY_GRACE=5 "$SERVICE" status "$@" 2>/dev/null
}

# The documented parser: split on spaces, then once on the first `=`.
declare -A FIELD=()
parse_machine_line() {  # <line>
  local line=$1 pair key
  FIELD=()
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "the machine output is not one line: $line"
  for pair in $line; do
    case "$pair" in
      *=*) ;;
      *) fail "free text in the machine line: '$pair' in: $line" ;;
    esac
    key=${pair%%=*}
    case "$key" in
      ''|*[!a-z_]*) fail "key '$key' is not a documented key shape in: $line" ;;
    esac
    [ -z "${FIELD[$key]+x}" ] || fail "key '$key' appears twice in: $line"
    FIELD[$key]=${pair#*=}
  done
}

assert_keys_in_order() {  # <line>
  local got expected
  got=$(printf '%s\n' "$1" | tr ' ' '\n' | sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//')
  expected=$EXPECTED_KEYS
  [ "$got" = "$expected" ] || fail "machine keys are '$got', the contract documents '$expected'"
}

# The consumer's whole decision procedure, written the way the vessel's health
# probe would write it: nothing but the verdict field is read.
consumer_seat_is_idle() {  # <machine-line> -> 0 when the seat is idle
  local pair
  for pair in $1; do
    [ "$pair" = 'verdict=idle' ] && return 0
  done
  return 1
}

# --- one fixture per verdict --------------------------------------------------

SEEN_VERDICTS=' '
LINE=
check_verdict() {  # <home> <expected-verdict> <expected-reason> -> sets LINE and FIELD
  local home=$1 expected=$2 reason=$3 machine prose want_rc machine_rc prose_rc first
  machine=$(status "$home" --format=machine)
  machine_rc=$?
  prose=$(status "$home")
  prose_rc=$?
  want_rc=$(expected_exit "$expected")

  parse_machine_line "$machine"
  assert_keys_in_order "$machine"
  [ "${FIELD[verdict]}" = "$expected" ] || fail "expected verdict=$expected, got: $machine"
  [ "$machine_rc" -eq "$want_rc" ] || fail "verdict=$expected must exit $want_rc, exited $machine_rc"
  [ "${FIELD[exit]}" = "$want_rc" ] || fail "exit= must restate the exit status $want_rc, got: $machine"
  [ "${FIELD[reason]}" = "$reason" ] || fail "verdict=$expected must carry reason=$reason, got: $machine"
  case "${FIELD[pending]}" in ''|*[!0-9]*) fail "pending= must be a count, got: $machine" ;; esac
  case "${FIELD[beacon_age_seconds]}" in ''|*[!0-9]*) fail "beacon_age_seconds= must be a number, got: $machine" ;; esac
  [ "${FIELD[grace_seconds]}" = 5 ] || fail "grace_seconds= must report the grace in force (5), got: $machine"

  first=${prose%%:*}
  [ "$first" = "$expected" ] || fail "the prose line opens '$first' while the machine line says $expected"
  [ "$prose_rc" -eq "$machine_rc" ] || fail "prose exited $prose_rc while machine exited $machine_rc for $expected"

  if [ "$expected" = idle ]; then
    consumer_seat_is_idle "$machine" || fail "a consumer could not decide 'seat is idle' from: $machine"
  else
    consumer_seat_is_idle "$machine" && fail "a consumer decided 'seat is idle' from a $expected line: $machine"
  fi
  SEEN_VERDICTS="$SEEN_VERDICTS$expected "
  LINE=$machine
}

test_every_verdict_reaches_the_machine_line_with_its_exit_status() {
  local home

  home=$(make_home down)
  check_verdict "$home" down listener-dead
  [ -z "${FIELD[listener_pid]}" ] || fail "down must carry an empty listener_pid, got: $LINE"

  home=$(make_home stalled)
  make_live_listener "$home"
  touch -t 200001010000 "$home/state/.last-delivery-beat"
  check_verdict "$home" stalled beacon-stale
  [ -n "${FIELD[listener_pid]}" ] || fail "stalled must name the live pid, got: $LINE"
  [ "${FIELD[beacon_age_seconds]}" -ge 5 ] || fail "a stalled beacon must be at least the grace old, got: $LINE"

  home=$(make_home live)
  make_live_listener "$home"
  check_verdict "$home" idle ''
  [ "${FIELD[pending]}" = 0 ] || fail "idle must report pending=0, got: $LINE"
  [ "${FIELD[listener_pid]}" = "$(cat "$home/state/.delivery.lock/pid")" ] \
    || fail "idle must name the listener pid, got: $LINE"

  touch "$home/state/.afk"
  check_verdict "$home" away afk
  rm -f "$home/state/.afk"

  queue_wake "$home"
  check_verdict "$home" undeliverable endpoint-absent
  [ "${FIELD[pending]}" = 1 ] || fail "one queued wake must report pending=1, got: $LINE"

  publish_endpoint "$home"
  check_verdict "$home" delivering ''
  [ "${FIELD[backend]}" = tmux ] && [ "${FIELD[target]}" = '%7' ] \
    || fail "delivering must name the published backend and target, got: $LINE"

  record_blocked_attempt "$home" \
    'the session pane is mid-turn; delivery waits rather than typing into a working agent' mid-turn
  check_verdict "$home" undeliverable mid-turn
  [ "${FIELD[target]}" = '%7' ] || fail "a blocked attempt keeps the target visible, got: $LINE"

  # A record written before reason tokens existed still classifies, under a
  # token that says so rather than an empty field a consumer would read as fine.
  printf 'blocked=the published pane %%7 no longer exists\n' > "$home/state/.delivery-attempt-outcome"
  check_verdict "$home" undeliverable attempt-blocked

  pass "every verdict reaches the machine line through the service command with its documented exit status"
}

test_the_library_vocabulary_is_covered_and_agrees_with_the_documented_exits() {
  local verdict lib_exit
  for verdict in $(lib_verdicts); do
    case "$SEEN_VERDICTS" in
      *" $verdict "*) ;;
      *) fail "the library can produce '$verdict' but no fixture above exercised it" ;;
    esac
    lib_exit=$(bash -c '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_verdict_exit "$2"' _ "$ROOT" "$verdict")
    [ "$lib_exit" = "$(expected_exit "$verdict")" ] \
      || fail "the library maps $verdict to exit $lib_exit, the contract documents $(expected_exit "$verdict")"
  done
  bash -c '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_verdict_exit bogus' _ "$ROOT" >/dev/null 2>&1 \
    && fail "a word outside the vocabulary must not be given an exit status"
  pass "the library's verdict vocabulary is exactly the contract's, with the documented exit statuses"
}

test_the_reason_token_travels_with_the_listener_record() {
  local home token
  home=$(make_home token)
  record_blocked_attempt "$home" 'the session composer holds unsubmitted text' composer-pending
  token=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_attempt_outcome_read_blocked "$2"; printf "%s\n" "$FM_DELIVERY_ATTEMPT_REASON_TOKEN"' \
    _ "$ROOT" "$home/state")
  [ "$token" = composer-pending ] || fail "the recorded token read back as '$token'"
  FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1/bin/fm-delivery-lib.sh"; fm_delivery_attempt_outcome_write_blocked "$2" "prose" "Not A Token"' \
    _ "$ROOT" "$home/state" 2>/dev/null \
    && fail "a token with spaces or capitals must be refused, or the machine line could not be parsed"
  pass "the reason token is recorded beside the prose and refused when it is not one token"
}

test_unknown_flags_are_refused_rather_than_ignored() {
  local home out
  home=$(make_home flags)
  local rc
  out=$(status "$home" --format=toon)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown --format value must exit 2, exited $rc: $out"
  case "$out" in error:*) ;; *) fail "a usage error must be named on stdout, got: $out" ;; esac
  out=$(status "$home" --machine)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag must exit 2, exited $rc: $out"
  assert_contains "$out" "--format=prose|machine" "the usage error must name the fix"
  out=$(status "$home" --help)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help must always pass, exited $rc"
  pass "an unknown status flag exits 2 with the fix named, so a consumer never acts on unscoped output"
}

test_the_documentation_names_every_verdict_and_every_key() {
  local verdict key section
  section=$(sed -n '/^## Machine-readable status contract/,/^## /p' "$DOC")
  [ -n "$section" ] || fail "docs/wake-delivery.md has no 'Machine-readable status contract' section"
  for verdict in $(lib_verdicts); do
    printf '%s\n' "$section" | grep -q "| \`$verdict\` |" \
      || fail "the contract section does not table the verdict '$verdict'"
  done
  for key in $EXPECTED_KEYS; do
    printf '%s\n' "$section" | grep -q "| \`$key\` |" \
      || fail "the contract section does not table the key '$key'"
  done
  printf '%s\n' "$section" | grep -qF 'tests/fm-delivery-status-contract.test.sh' \
    || fail "the contract section does not name this test as the contract's holder"
  printf '%s\n' "$section" | grep -qF -- '--format=machine' \
    || fail "the contract section does not show the consumer call"
  pass "docs/wake-delivery.md tables every verdict and every key and names this test as the contract"
}

test_every_verdict_reaches_the_machine_line_with_its_exit_status
test_the_library_vocabulary_is_covered_and_agrees_with_the_documented_exits
test_the_reason_token_travels_with_the_listener_record
test_unknown_flags_are_refused_rather_than_ignored
test_the_documentation_names_every_verdict_and_every_key
