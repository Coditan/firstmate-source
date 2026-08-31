#!/usr/bin/env bash
# tests/fm-tg-recv-arm.test.sh - direct Telegram receiver arm wrapper behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-tg-recv-arm.sh"
fm_test_tmproot TMP_ROOT fm-tg-recv-arm-tests

home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state"

out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: inactive (config/telegram.env absent)'*) : ;;
  *) fail "expected inactive output without telegram.env, got: $out" ;;
esac

printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$home/config/telegram.env"
out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: FAILED - config/fm-tg-recv.sh missing or not executable'*) : ;;
  *) fail "expected missing receiver failure, got: $out" ;;
esac

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
sleep 0.2
printf 'CAPTAIN-TELEGRAM: test\n'
SH
chmod +x "$home/config/fm-tg-recv.sh"

out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: started pid='*'CAPTAIN-TELEGRAM: test'*) : ;;
  *) fail "expected started output and receiver payload, got: $out" ;;
esac
owner_leaks=$(find "$home/state" -maxdepth 1 -type d -name '.tg-recv.lock.owner.*' -print)
[ -z "$owner_leaks" ] || fail "receiver arm left lock owner directories behind: $owner_leaks"

plain_home="$TMP_ROOT/plain-home"
mkdir -p "$plain_home/config" "$plain_home/state"
printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$plain_home/config/telegram.env"
cat > "$plain_home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "$FM_HOME" = "$EXPECTED_FM_HOME" ] || {
  printf 'bad FM_HOME: %s\n' "${FM_HOME-}"
  exit 7
}
[ "$FM_CONFIG_OVERRIDE" = "$EXPECTED_FM_HOME/config" ] || {
  printf 'bad FM_CONFIG_OVERRIDE: %s\n' "${FM_CONFIG_OVERRIDE-}"
  exit 8
}
[ "$FM_STATE_OVERRIDE" = "$EXPECTED_FM_HOME/state" ] || {
  printf 'bad FM_STATE_OVERRIDE: %s\n' "${FM_STATE_OVERRIDE-}"
  exit 9
}
printf 'CAPTAIN-TELEGRAM: env ok\n'
SH
chmod +x "$plain_home/config/fm-tg-recv.sh"

out=$(EXPECTED_FM_HOME="$plain_home" FM_ROOT_OVERRIDE="$plain_home" env -u FM_HOME -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE "$ARM" 2>&1)
case "$out" in
  *'CAPTAIN-TELEGRAM: env ok'*) : ;;
  *) fail "expected receiver to inherit resolved home env, got: $out" ;;
esac

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'CAPTAIN-TELEGRAM: already pending\n'
sleep 0.1
SH
chmod +x "$home/config/fm-tg-recv.sh"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
sleep 0.05
exit 1
SH
chmod +x "$fakebin/ps"

out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'CAPTAIN-TELEGRAM: already pending'*)
    case "$out" in
      *'could not identify receiver process'*) fail "fast-exit receiver output was replayed with an identity failure: $out" ;;
      *) : ;;
    esac
    ;;
  *) fail "expected fast-exit receiver payload, got: $out" ;;
esac

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
while [ ! -f "$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
SH
chmod +x "$home/config/fm-tg-recv.sh"
rm -f "$home/state/receiver.pid" "$home/state/stop-receiver"

FM_HOME="$home" "$ARM" > "$home/state/arm1.out" 2>&1 &
arm1=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$home/state/receiver.pid" ] && break
  sleep 0.1
done
[ -s "$home/state/receiver.pid" ] || fail "receiver did not start"

FM_HOME="$home" "$ARM" > "$home/state/arm2.out" 2>&1 &
arm2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/arm2.out" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
grep -q 'telegram receiver: attached pid=' "$home/state/arm2.out" || fail "second arm did not attach"

touch "$home/state/stop-receiver"
wait "$arm1"
wait "$arm2"

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
trap ':' TERM
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
printf 'start\n' >> "$FM_HOME/state/receiver.starts"
while [ ! -f "$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
printf 'CAPTAIN-TELEGRAM: after abandoned wrapper\n'
SH
chmod +x "$home/config/fm-tg-recv.sh"
rm -f "$home/state/receiver.pid" "$home/state/receiver.starts" "$home/state/stop-receiver"

FM_HOME="$home" "$ARM" > "$home/state/term-arm1.out" 2>&1 &
term_arm1=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$home/state/receiver.pid" ] && break
  sleep 0.1
done
[ -s "$home/state/receiver.pid" ] || fail "signal cleanup receiver did not start"
receiver_pid=$(cat "$home/state/receiver.pid")

kill -TERM "$term_arm1"
wait "$term_arm1" 2>/dev/null
fm_pid_alive=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_alive "$2"; printf "%s\n" "$?"' sh "$ROOT/bin/fm-wake-lib.sh" "$receiver_pid")
[ "$fm_pid_alive" = 0 ] || fail "signal cleanup killed slow receiver before bounded wait check"
[ -L "$home/state/.tg-recv.lock" ] || fail "signal cleanup dropped live receiver lock"
capture_path=$(cat "$home/state/.tg-recv.lock/output-path" 2>/dev/null || true)
[ -n "$capture_path" ] || fail "signal cleanup did not preserve output capture metadata"
[ -e "$capture_path" ] || fail "signal cleanup removed live receiver output capture"

FM_HOME="$home" "$ARM" > "$home/state/term-arm2.out" 2>&1 &
term_arm2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/term-arm2.out" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
grep -q 'telegram receiver: attached pid=' "$home/state/term-arm2.out" || fail "second arm did not attach after signal cleanup: $(cat "$home/state/term-arm2.out")"
[ "$(wc -l < "$home/state/receiver.starts")" -eq 1 ] || fail "signal cleanup allowed duplicate receiver start"
touch "$home/state/stop-receiver"
wait "$term_arm2"
grep -q 'CAPTAIN-TELEGRAM: after abandoned wrapper' "$home/state/term-arm2.out" || fail "attached arm did not relay abandoned receiver output: $(cat "$home/state/term-arm2.out")"

rm -f "$home/state/.tg-recv.lock"
rm -rf "$home/state"/.tg-recv.lock.owner.*
sleep 5 &
race_pid=$!
race_identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' sh "$ROOT/bin/fm-wake-lib.sh" "$race_pid")
race_owner="$home/state/.tg-recv.lock.owner.race"
mkdir "$race_owner"
printf '%s\n' "$race_pid" > "$race_owner/pid"
ln -s "$race_owner" "$home/state/.tg-recv.lock"
(
  sleep 0.3
  printf '%s\n' "$home" > "$race_owner/fm-home"
  printf '%s\n' "$race_identity" > "$race_owner/pid-identity"
  printf '%s\n' "$home/config/fm-tg-recv.sh" > "$race_owner/receiver-path"
) &
publisher=$!
FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=3 FM_TG_RECV_ATTACH_POLL=0.1 FM_HOME="$home" "$ARM" > "$home/state/race.out" 2>&1 &
race_arm=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/race.out" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
grep -q 'telegram receiver: attached pid=' "$home/state/race.out" || fail "second arm did not wait for receiver lock metadata: $(cat "$home/state/race.out")"
kill "$race_pid" 2>/dev/null || true
wait "$race_pid" 2>/dev/null || true
wait "$publisher"
wait "$race_arm"

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'CAPTAIN-TELEGRAM: fresh receiver\n'
SH
chmod +x "$home/config/fm-tg-recv.sh"
rm -f "$home/state/.tg-recv.lock"
rm -rf "$home/state"/.tg-recv.lock.owner.*
orphan_owner="$home/state/.tg-recv.lock.owner.orphan"
orphan_capture="$home/state/.tg-recv-output.orphan"
mkdir "$orphan_owner"
printf '999999\n' > "$orphan_owner/pid"
printf '%s\n' "$home" > "$orphan_owner/fm-home"
printf '%s\n' "$home/config/fm-tg-recv.sh" > "$orphan_owner/receiver-path"
printf '%s\n' "$orphan_capture" > "$orphan_owner/output-path"
printf 'CAPTAIN-TELEGRAM: orphaned message\n' > "$orphan_capture"
ln -s "$orphan_owner" "$home/state/.tg-recv.lock"
out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'CAPTAIN-TELEGRAM: orphaned message'*) : ;;
  *) fail "dead recorded receiver output was not relayed before lock cleanup: $out" ;;
esac
[ ! -e "$orphan_capture" ] || fail "dead recorded receiver output capture was left after relay"

# The receiver is reached through a shebang chain the wrapper does not control:
# between the fork and the last execve of that chain the child still carries an
# image that will never exist again. A wrapper that fingerprints the child's
# image at fork time therefore records a process that no longer exists, and every
# later arm reports FAILED against a receiver that is perfectly healthy - the
# alarm that invites killing it. These tests exercise the exec transition itself
# by widening it deliberately, rather than asserting on an already settled
# process, which is exactly the case that hides the defect.
slow_interp="$TMP_ROOT/slow-interp"
cat > "$slow_interp" <<'SH'
#!/usr/bin/env bash
# Hold the child in a pre-final image long enough for the arm's fingerprint to
# land inside the exec transition on purpose.
sleep "${FM_TEST_INTERP_DELAY:-1}"
exec bash "$@"
SH
chmod +x "$slow_interp"

exec_home="$TMP_ROOT/exec-home"
mkdir -p "$exec_home/config" "$exec_home/state"
printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$exec_home/config/telegram.env"
cat > "$exec_home/config/fm-tg-recv.sh" <<SH
#!$slow_interp
set -u
printf '%s\n' "\$\$" > "\$FM_HOME/state/receiver.pid"
printf 'start\n' >> "\$FM_HOME/state/receiver.starts"
while [ ! -f "\$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
printf 'CAPTAIN-TELEGRAM: settled receiver\n'
SH
chmod +x "$exec_home/config/fm-tg-recv.sh"

FM_HOME="$exec_home" "$ARM" > "$exec_home/state/exec-arm1.out" 2>&1 &
exec_arm1=$!
for _ in $(seq 60); do
  [ -s "$exec_home/state/receiver.pid" ] && break
  sleep 0.1
done
[ -s "$exec_home/state/receiver.pid" ] || fail "receiver behind a slow interpreter hop did not start: $(cat "$exec_home/state/exec-arm1.out")"

# The settled image differs from the one the child carried when the arm forked
# it; without that, this fixture would prove nothing.
exec_pid=$(cat "$exec_home/state/.tg-recv.lock/pid" 2>/dev/null || true)
[ -n "$exec_pid" ] || fail "receiver arm recorded no receiver pid behind a slow interpreter hop"
settled_identity=$(FM_HOME="$exec_home" bash -c '. "$1"; fm_pid_identity "$2"' sh "$ROOT/bin/fm-wake-lib.sh" "$exec_pid")
interp_hex=$(printf '%s' "$slow_interp" | od -An -v -tx1 | tr -d '[:space:]')
case "$settled_identity" in
  *"$interp_hex"*)
    fail "receiver never left its interpreter image, so the exec transition was not exercised" ;;
esac

# Re-arm several times: a healthy receiver must be confirmed every time.
for attempt in 1 2 3; do
  FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=3 FM_TG_RECV_ATTACH_POLL=0.1 FM_HOME="$exec_home" \
    "$ARM" > "$exec_home/state/exec-rearm.$attempt.out" 2>&1 &
  rearm=$!
  for _ in $(seq 40); do
    if grep -q 'telegram receiver: attached pid=' "$exec_home/state/exec-rearm.$attempt.out" 2>/dev/null; then
      break
    fi
    if grep -q 'FAILED' "$exec_home/state/exec-rearm.$attempt.out" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  case "$(cat "$exec_home/state/exec-rearm.$attempt.out")" in
    *'telegram receiver: attached pid='*) : ;;
    *) fail "re-arm $attempt reported a healthy receiver as unconfirmable: $(cat "$exec_home/state/exec-rearm.$attempt.out")" ;;
  esac
  rearm_pids="${rearm_pids:-} $rearm"
done
[ "$(wc -l < "$exec_home/state/receiver.starts")" -eq 1 ] || fail "re-arming a healthy receiver started a second one"

# A lock already written by the older wrapper - image half and all, captured
# before the exec transition finished - still names a receiver this one can
# confirm, so updating over a live receiver cannot raise the false alarm once.
lock_owner=$(readlink "$exec_home/state/.tg-recv.lock")
[ -n "$lock_owner" ] || fail "receiver lock is not the expected owner symlink"
rm -f "$lock_owner/pid-incarnation"
printf '%s cmdline-hex=%s\n' "${settled_identity%% cmdline-hex=*}" "$interp_hex" > "$lock_owner/pid-identity"
FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=3 FM_TG_RECV_ATTACH_POLL=0.1 FM_HOME="$exec_home" \
  "$ARM" > "$exec_home/state/legacy-rearm.out" 2>&1 &
legacy_rearm=$!
for _ in $(seq 40); do
  grep -q 'telegram receiver: attached pid=' "$exec_home/state/legacy-rearm.out" 2>/dev/null && break
  grep -q 'FAILED' "$exec_home/state/legacy-rearm.out" 2>/dev/null && break
  sleep 0.1
done
case "$(cat "$exec_home/state/legacy-rearm.out")" in
  *'telegram receiver: attached pid='*) : ;;
  *) fail "a lock recorded by an older wrapper was not confirmed: $(cat "$exec_home/state/legacy-rearm.out")" ;;
esac

touch "$exec_home/state/stop-receiver"
wait "$exec_arm1"
wait "$legacy_rearm"
for rearm in ${rearm_pids:-}; do
  wait "$rearm"
done

# When the incarnation genuinely cannot be established, the wrapper must refuse
# and say so, never record an unusable lock and report a start.
refuse_home="$TMP_ROOT/refuse-home"
mkdir -p "$refuse_home/config" "$refuse_home/state"
printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$refuse_home/config/telegram.env"
cat > "$refuse_home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
while [ ! -f "$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
SH
chmod +x "$refuse_home/config/fm-tg-recv.sh"
out=$(PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" FM_HOME="$refuse_home" "$ARM" 2>&1)
rc=$?
case "$out" in
  *'telegram receiver: FAILED - could not identify receiver process'*) : ;;
  *) fail "unestablishable receiver identity was not refused: rc=$rc out=$out" ;;
esac
[ "$rc" -ne 0 ] || fail "unestablishable receiver identity exited successfully: $out"
if [ -e "$refuse_home/state/.tg-recv.lock" ] || [ -L "$refuse_home/state/.tg-recv.lock" ]; then
  fail "refused receiver arm left a lock behind"
fi

rm -f "$home/state/.tg-recv.lock"
rm -rf "$home/state"/.tg-recv.lock.owner.*
partial_owner="$home/state/.tg-recv.lock.owner.partial"
mkdir "$partial_owner"
printf '999999\n' > "$partial_owner/pid"
ln -s "$partial_owner" "$home/state/.tg-recv.lock"
out=$(FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=0 FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'CAPTAIN-TELEGRAM: fresh receiver'*) : ;;
  *) fail "stale partial receiver lock was not reclaimed: $out" ;;
esac
if [ -e "$home/state/.tg-recv.lock" ] || [ -L "$home/state/.tg-recv.lock" ]; then
  fail "stale partial receiver lock was left after reclaimed receiver exited"
fi

# A systemd-owned receiver has no harness background task to carry its output
# into the primary seat. Its successful message and its sustained failure must
# therefore take the same durable wake path as the rest of supervision. The
# failure fixture exits without output on purpose: an empty receiver exit must
# not be allowed to look like an empty mailbox, and repeated service restarts
# must not flood the queue with the same outage.
service_home="$TMP_ROOT/service-home"
mkdir -p "$service_home/config" "$service_home/state"
printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$service_home/config/telegram.env"
cat > "$service_home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
emit_event() {
  python3 -c 'import base64,sys; print("FM_TG_EVENT_V1:" + base64.b64encode(sys.argv[1].encode()).decode(), flush=True)' "$1"
}
case "$(cat "$FM_HOME/state/receiver-mode")" in
  message)
    emit_event 'CAPTAIN-TELEGRAM: service message'
    ;;
  handoff)
    emit_event 'CAPTAIN-TELEGRAM: captured before handoff'
    trap 'exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  failure)
    emit_event $'CAPTAIN-TELEGRAM: message delivered before failure\ncontinued captain message'
    printf 'request failed for https://api.telegram.org/botSECRET-TOKEN/getUpdates: denied\n' >&2
    head -c 5000 /dev/zero | tr '\0' x >&2
    printf '\n' >&2
    exit 7
    ;;
  diagnostic-exit)
    printf 'request failed for https://api.telegram.org/botPRIVATE-TOKEN/getUpdates: denied\n' >&2
    exit 0
    ;;
  empty-exit)
    exit 0
    ;;
esac
SH
chmod +x "$service_home/config/fm-tg-recv.sh"

decoded_queue() {
  python3 - "$1" <<'PY'
import sys

for row in open(sys.argv[1], encoding="utf-8"):
    fields = row.rstrip("\n").split("\t", 4)
    if len(fields) == 5 and fields[2] == "signal" and fields[3].startswith("telegram.v1."):
        payload = fields[4]
        result = []
        index = 0
        escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\"}
        while index < len(payload):
            if payload[index] == "\\" and index + 1 < len(payload) and payload[index + 1] in escapes:
                result.append(escapes[payload[index + 1]])
                index += 2
            else:
                result.append(payload[index])
                index += 1
        print("".join(result))
PY
}

decoded_output_file() {
  python3 - "$1" <<'PY'
import base64
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("FM_TG_EVENT_V1:"):
        print(base64.b64decode(line.split(":", 1)[1], validate=True).decode())
    else:
        print(line)
PY
}

printf '%s\n' message > "$service_home/state/receiver-mode"
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-message.out" 2>&1
assert_contains "$(decoded_queue "$service_home/state/.wake-queue")" 'CAPTAIN-TELEGRAM: service message' \
  "systemd receiver message was left in the service journal instead of the durable wake queue"
assert_grep 'receiver exited 0 after delivering output' "$service_home/state/.wake-queue" \
  "receiver exit after a delivered message was not reported as a durable failure"
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-message-second.out" 2>&1
message_rows=$(decoded_queue "$service_home/state/.wake-queue" | grep -c 'CAPTAIN-TELEGRAM: service message')
[ "$message_rows" -eq 2 ] \
  || fail "two messages shared one wake identity and would be deduplicated at drain time: $message_rows rows"

unknown_home="$TMP_ROOT/unknown-exit-home"
mkdir -p "$unknown_home/config" "$unknown_home/state/.tg-recv.lock.owner.unknown"
cp "$service_home/config/telegram.env" "$unknown_home/config/telegram.env"
cp "$service_home/config/fm-tg-recv.sh" "$unknown_home/config/fm-tg-recv.sh"
printf '%s\n' empty-exit > "$unknown_home/state/receiver-mode"
python3 -c 'import base64; print("FM_TG_EVENT_V1:" + base64.b64encode(b"CAPTAIN-TELEGRAM: recovered message").decode())' > "$unknown_home/state/recovered-output"
printf '%s\n' 999999 > "$unknown_home/state/.tg-recv.lock.owner.unknown/pid"
printf '%s\n' "$unknown_home" > "$unknown_home/state/.tg-recv.lock.owner.unknown/fm-home"
printf '%s\n' "$unknown_home/config/fm-tg-recv.sh" > "$unknown_home/state/.tg-recv.lock.owner.unknown/receiver-path"
printf '%s\n' "$unknown_home/state/recovered-output" > "$unknown_home/state/.tg-recv.lock.owner.unknown/output-path"
ln -s "$unknown_home/state/.tg-recv.lock.owner.unknown" "$unknown_home/state/.tg-recv.lock"
FM_TG_RECV_MANAGER=systemd FM_HOME="$unknown_home" "$ARM" > "$unknown_home/state/recovery.out" 2>&1
assert_contains "$(decoded_queue "$unknown_home/state/.wake-queue")" 'CAPTAIN-TELEGRAM: recovered message' \
  "unknown-status recovery did not durably relay captured output"
assert_grep 'recorded receiver exited with status unavailable' "$unknown_home/state/.wake-queue" \
  "unknown-status dead receiver recovery omitted the durable failure"

handoff_home="$TMP_ROOT/handoff-output-home"
mkdir -p "$handoff_home/config" "$handoff_home/state"
cp "$service_home/config/telegram.env" "$handoff_home/config/telegram.env"
cp "$service_home/config/fm-tg-recv.sh" "$handoff_home/config/fm-tg-recv.sh"
printf '%s\n' handoff > "$handoff_home/state/receiver-mode"
FM_TG_RECV_MANAGER=systemd FM_HOME="$handoff_home" "$ARM" > "$handoff_home/state/wrapper.out" 2>&1 &
handoff_wrapper_pid=$!
for _ in $(seq 1 50); do
  handoff_output=$(cat "$handoff_home/state/.tg-recv.lock/output-path" 2>/dev/null || true)
  handoff_decoded=$([ -n "$handoff_output" ] && decoded_output_file "$handoff_output" 2>/dev/null || true)
  [ -n "$handoff_output" ] && printf '%s\n' "$handoff_decoded" | grep -q 'captured before handoff' && break
  sleep 0.1
done
if ! { [ -n "${handoff_output:-}" ] \
  && printf '%s\n' "${handoff_decoded:-}" | grep -q 'captured before handoff'; }; then
  fail "handoff fixture did not capture its captain message before TERM"
fi
kill -TERM "$handoff_wrapper_pid"
wait "$handoff_wrapper_pid" 2>/dev/null || true
assert_contains "$(decoded_queue "$handoff_home/state/.wake-queue")" 'CAPTAIN-TELEGRAM: captured before handoff' \
  "intentional service handoff discarded already-captured captain output"
handoff_message_rows=$(decoded_queue "$handoff_home/state/.wake-queue" | grep -c 'CAPTAIN-TELEGRAM: captured before handoff')
[ "$handoff_message_rows" -eq 1 ] \
  || fail "intentional service handoff relayed captured output $handoff_message_rows times instead of once"
assert_not_contains "$(cat "$handoff_home/state/.wake-queue")" 'telegram receiver: FAILED' \
  "intentional service handoff emitted a receiver-exit failure wake"

refused_home="$TMP_ROOT/refused-wake-home"
mkdir -p "$refused_home/config" "$refused_home/state/refused-wake-queue"
cp "$service_home/config/telegram.env" "$refused_home/config/telegram.env"
cp "$service_home/config/fm-tg-recv.sh" "$refused_home/config/fm-tg-recv.sh"
printf '%s\n' message > "$refused_home/state/receiver-mode"
service_rc=0
FM_WAKE_QUEUE="$refused_home/state/refused-wake-queue" \
  FM_TG_RECV_MANAGER=systemd FM_HOME="$refused_home" "$ARM" \
  > "$refused_home/state/refused-wake.out" 2>&1 || service_rc=$?
[ "$service_rc" -eq 1 ] || fail "a refused durable wake exited $service_rc instead of failing visibly"
assert_grep 'receiver output could not be durably relayed' "$refused_home/state/refused-wake.out" \
  "a refused durable wake looked like successful delivery"
preserved_output_path=$(cat "$refused_home/state/.tg-recv.lock/output-path" 2>/dev/null || true)
preserved_output=$([ -n "$preserved_output_path" ] && decoded_output_file "$preserved_output_path" 2>/dev/null || true)
assert_contains "$preserved_output" 'CAPTAIN-TELEGRAM: service message' \
  "a refused durable wake discarded the captured receiver message"

: > "$service_home/state/.wake-queue"
rm -f "$service_home/state/.tg-recv-last-failure-wake"
printf '%s\n' failure > "$service_home/state/receiver-mode"
service_rc=0
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-failure.out" 2>&1 \
  || service_rc=$?
[ "$service_rc" -eq 7 ] || fail "service receiver failure exited $service_rc instead of preserving receiver exit 7"
assert_grep 'check: telegram receiver: FAILED' "$service_home/state/.wake-queue" \
  "systemd receiver failure was indistinguishable from healthy silence"
assert_contains "$(decoded_queue "$service_home/state/.wake-queue")" 'CAPTAIN-TELEGRAM: message delivered before failure' \
  "valid receiver event was discarded when the receiver exited nonzero"
assert_not_contains "$(cat "$service_home/state/.wake-queue")" 'FM_TG_EVENT_V1:' \
  "durable wake retained an opaque receiver frame"
assert_contains "$(decoded_queue "$service_home/state/.wake-queue")" 'continued captain message' \
  "multiline receiver event was truncated when the receiver exited nonzero"
assert_grep 'private diagnostic: state/.tg-recv-last-failure-diagnostic' "$service_home/state/.wake-queue" \
  "receiver failure wake did not reference its private diagnostic"
assert_not_contains "$(cat "$service_home/state/.wake-queue")" 'SECRET-TOKEN' \
  "receiver failure wake exposed a token-bearing diagnostic"
assert_not_contains "$(cat "$service_home/state/service-failure.out")" 'SECRET-TOKEN' \
  "receiver stderr exposed a token-bearing diagnostic in service output"
assert_grep 'SECRET-TOKEN' "$service_home/state/.tg-recv-last-failure-diagnostic" \
  "private receiver failure diagnostic discarded the captured evidence"
assert_not_contains "$(cat "$service_home/state/.tg-recv-last-failure-diagnostic")" \
  'CAPTAIN-TELEGRAM: message delivered before failure' \
  "valid receiver event was misclassified as a private diagnostic"
diagnostic_size=$(wc -c < "$service_home/state/.tg-recv-last-failure-diagnostic" | tr -d ' ')
[ "$diagnostic_size" -le 4096 ] \
  || fail "private receiver failure diagnostic exceeded its 4096-byte bound: $diagnostic_size"
if [ "$(uname)" = Darwin ]; then
  diagnostic_mode=$(stat -f %Lp "$service_home/state/.tg-recv-last-failure-diagnostic")
else
  diagnostic_mode=$(stat -c %a "$service_home/state/.tg-recv-last-failure-diagnostic")
fi
[ "$diagnostic_mode" = 600 ] || fail "private receiver failure diagnostic mode was $diagnostic_mode instead of 600"

drain_home="$TMP_ROOT/downstream-drain-home"
mkdir -p "$drain_home/config" "$drain_home/state"
cp "$service_home/state/.wake-queue" "$drain_home/state/.wake-queue"
drained=$(FM_HOME="$drain_home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
assert_contains "$drained" 'CAPTAIN-TELEGRAM: message delivered before failure' \
  "the real wake drain did not receive the decoded Telegram event"
assert_contains "$drained" 'continued captain message' \
  "the real wake drain did not preserve the multiline Telegram event"
assert_not_contains "$drained" 'SECRET-TOKEN' \
  "the real wake drain exposed a private receiver diagnostic"

first_failure_rows=$(grep -c 'check: telegram receiver: FAILED' "$service_home/state/.wake-queue")
service_rc=0
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-failure-repeat.out" 2>&1 \
  || service_rc=$?
[ "$service_rc" -eq 7 ] || fail "repeated service receiver failure exited $service_rc instead of preserving receiver exit 7"
second_failure_rows=$(grep -c 'check: telegram receiver: FAILED' "$service_home/state/.wake-queue")
[ "$second_failure_rows" -eq "$first_failure_rows" ] \
  || fail "one outage queued $second_failure_rows failure wakes across service restarts instead of $first_failure_rows"

: > "$service_home/state/.wake-queue"
rm -f "$service_home/state/.tg-recv-last-failure-wake"
printf '%s\n' empty-exit > "$service_home/state/receiver-mode"
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-empty.out" 2>&1
assert_grep 'check: telegram receiver: FAILED' "$service_home/state/.wake-queue" \
  "an empty receiver exit was treated as an empty mailbox"

: > "$service_home/state/.wake-queue"
rm -f "$service_home/state/.tg-recv-last-failure-wake"
printf '%s\n' diagnostic-exit > "$service_home/state/receiver-mode"
FM_TG_RECV_MANAGER=systemd FM_HOME="$service_home" "$ARM" > "$service_home/state/service-diagnostic.out" 2>&1
assert_grep 'receiver exited 0 with diagnostic output but no valid event' "$service_home/state/.wake-queue" \
  "diagnostic-only zero exit was mislabeled as empty"
assert_grep 'private diagnostic: state/.tg-recv-last-failure-diagnostic' "$service_home/state/.wake-queue" \
  "diagnostic-only zero exit did not reference private evidence"
assert_not_contains "$(cat "$service_home/state/.wake-queue")" 'PRIVATE-TOKEN' \
  "diagnostic-only zero exit leaked private evidence into its wake"
assert_grep 'PRIVATE-TOKEN' "$service_home/state/.tg-recv-last-failure-diagnostic" \
  "diagnostic-only zero exit did not preserve private evidence"
pass "service-owned receiver output is durable, and one sustained outage wakes once"
