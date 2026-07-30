#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for reachable review boards (docs/lavish-access.md).
#
# Three cooperating pieces are covered here:
#   - bin/fm-service-port.sh, the general vessel-local port allocator, whose one
#     rule is that a successful bind is the only proof a port is free;
#   - bin/fm-lavish.sh, the entry point that turns that into a link the captain
#     can actually open, and that degrades honestly when it cannot;
#   - bin/fm-lavish-pretool-check.sh, the guard that denies bare `lavish-axi`.
#
# Everything is hermetic: a fake `tailscale` reports 127.0.0.1 / localhost, so
# the allocator's tailnet path is exercised without touching a real tailnet, and
# every bind happens on loopback. A fake `lavish-axi` records the environment it
# was handed. No harness is spawned; live per-harness evidence lives in
# docs/lavish-access.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-lavish-access

command -v node >/dev/null 2>&1 || fail "node is required for the service-port probe"
command -v jq >/dev/null 2>&1 || fail "jq is required for the tailnet identity read"

# --- fixtures ---------------------------------------------------------------

# A fake tailscale whose answers are driven by FM_TEST_TS_MODE, so every
# degradation branch is reachable without a real tailnet:
#   running  - a node on 127.0.0.1 whose DNS name (localhost) really resolves
#   badname  - running, but the DNS name does not resolve to the address
#   stopped  - installed but not running
#   noipv4   - running with no IPv4 address
make_fake_tailscale() {
  local bin=$1
  cat > "$bin/tailscale" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 1
[ "${2:-}" = --json ] || { echo "127.0.0.1 fake"; exit 0; }
case "${FM_TEST_TS_MODE:-running}" in
  running)
    printf '{"BackendState":"Running","MagicDNSSuffix":"","Self":{"HostName":"localhost","DNSName":"localhost.","TailscaleIPs":["127.0.0.1","fd7a::1"]}}\n'
    ;;
  badname)
    printf '{"BackendState":"Running","MagicDNSSuffix":"invalid","Self":{"HostName":"nowhere","DNSName":"nowhere.invalid.","TailscaleIPs":["127.0.0.1"]}}\n'
    ;;
  stopped)
    printf '{"BackendState":"Stopped","MagicDNSSuffix":"","Self":{}}\n'
    ;;
  noipv4)
    printf '{"BackendState":"Running","MagicDNSSuffix":"","Self":{"HostName":"v6only","DNSName":"v6only.","TailscaleIPs":["fd7a::1"]}}\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$bin/tailscale"
}

# A fake lavish-axi installed where fm_axi_bin_dir looks first, so the wrapper
# resolves the vessel's own copy rather than anything on PATH. It records the
# environment it was handed and every argument it received.
make_fake_lavish() {
  local home=$1 bindir="$1/.local/axi/bin"
  mkdir -p "$bindir"
  cat > "$bindir/lavish-axi" <<'SH'
#!/usr/bin/env bash
{
  printf 'ARGS=%s\n' "$*"
  printf 'HOST=%s\n' "${LAVISH_AXI_HOST:-}"
  printf 'PORT=%s\n' "${LAVISH_AXI_PORT:-}"
  printf 'LINK=%s\n' "${LAVISH_AXI_LINK_HOST:-}"
  printf 'ALLOWED=%s\n' "${LAVISH_AXI_ALLOWED_HOSTS:-}"
  printf 'STATEDIR=%s\n' "${LAVISH_AXI_STATE_DIR:-}"
} >> "$FM_TEST_LAVISH_LOG"
printf 'url: "http://%s:%s/session/deadbeef"\n' "${LAVISH_AXI_LINK_HOST:-}" "${LAVISH_AXI_PORT:-}"
SH
  chmod +x "$bindir/lavish-axi"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config" "$dir/.lavish"
  printf '<html><body>board</body></html>\n' > "$dir/.lavish/board.html"
  make_fake_lavish "$dir"
  printf '%s\n' "$dir"
}

# Occupy ports for real, because a test that mocks the collision would not be
# testing the one thing the allocator promises.
PORT_HOLDER_PID=
hold_ports() {
  local addr=$1
  shift
  local ready="$TMP_ROOT/holder.ready" waited=0
  rm -f "$ready"
  cat > "$TMP_ROOT/holder.mjs" <<'JS'
import net from "node:net";
const [ready, addr, ...ports] = process.argv.slice(2);
import { writeFileSync } from "node:fs";
let live = 0;
for (const port of ports) {
  const server = net.createServer();
  server.listen({ host: addr, port: Number(port) }, () => {
    if (++live === ports.length) writeFileSync(ready, "ready\n");
  });
}
process.stdin.resume();
JS
  node "$TMP_ROOT/holder.mjs" "$ready" "$addr" "$@" </dev/null >/dev/null 2>&1 &
  PORT_HOLDER_PID=$!
  while [ ! -s "$ready" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "port holder did not come up"
    sleep 0.05
  done
}

release_ports() {
  [ -n "$PORT_HOLDER_PID" ] || return 0
  kill "$PORT_HOLDER_PID" 2>/dev/null || true
  wait "$PORT_HOLDER_PID" 2>/dev/null || true
  PORT_HOLDER_PID=
}

trap 'release_ports; fm_test_cleanup' EXIT

field() {
  printf '%s\n' "$2" | sed -n "s/^$1=\(.*\)$/\1/p" | head -1
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
make_fake_tailscale "$FAKEBIN"
PATH="$FAKEBIN:$PATH"
export PATH
export FM_TEST_TS_MODE=running

# --- the probe is the oracle -------------------------------------------------

PROBE="$ROOT/bin/fm-service-port-probe.mjs"

hold_ports 127.0.0.1 4731
out=$(node "$PROBE" bind 127.0.0.1 4731 4732)
expect_code 0 "$?" "probe should find the free candidate"
[ "$out" = 4732 ] || fail "probe should skip the held port and return 4732, got '$out'"
node "$PROBE" bind 127.0.0.1 4731 >/dev/null 2>&1
expect_code 3 "$?" "a fully held candidate list is exit 3"
pass "the bind probe treats a real listener as authoritative and reports exhaustion distinctly"

node "$PROBE" bind 203.0.113.7 4731 >/dev/null 2>&1
expect_code 4 "$?" "an unbindable address is exit 4, never a collision"
pass "an unusable address is reported apart from a port collision"

# A refused port (EACCES on a privileged port) is port-scoped: it says nothing
# about the address, so it must neither end the walk nor be dressed up as an
# unusable address, which would send the reader hunting the network interface.
node "$PROBE" bind 127.0.0.1 80 >/dev/null 2>&1
low_port_status=$?
if [ "$low_port_status" -eq 5 ]; then
  out=$(node "$PROBE" bind 127.0.0.1 80 4733 2>/dev/null)
  expect_code 0 "$?" "a refused candidate must not end the walk"
  [ "$out" = 4733 ] || fail "the walk should continue past a refused port and return 4733, got '$out'"
  # The summary must count what happened rather than assert contention that was
  # never observed: nothing was held here, and saying otherwise would be the
  # same false-concrete-diagnosis class the reason lines exist to avoid.
  summary=$(node "$PROBE" bind 127.0.0.1 80 81 2>&1 >/dev/null)
  assert_contains "$summary" "0 candidate(s) held" "an all-refused window must not claim any candidate was held"
  assert_contains "$summary" "2 refused" "the summary counts the refusals it actually saw"
  assert_contains "$summary" "EACCES" "the summary names the concrete errno"
  mixed=$(node "$PROBE" bind 127.0.0.1 80 4731 2>&1 >/dev/null)
  expect_code 5 "$?" "a window of one refused and one held candidate is neither exhaustion nor an unusable address"
  assert_contains "$mixed" "1 candidate(s) held" "a mixed window counts the held candidate"
  pass "a refused port keeps the walk going and is counted apart from a held one"
else
  pass "this host lets an unprivileged account bind port 80, so the refused-port branch is not exercisable here"
fi

node "$PROBE" resolve localhost 127.0.0.1 >/dev/null 2>&1
expect_code 0 "$?" "localhost resolves to 127.0.0.1"
node "$PROBE" resolve nowhere.invalid 127.0.0.1 >/dev/null 2>&1
expect_code 1 "$?" "an unresolvable name must not be treated as usable"
pass "the resolve mode refuses a name that does not point at the bound address"
release_ports

# --- allocator: identity and determinism -------------------------------------

HOME_A=$(make_home "$TMP_ROOT/vessel-a")
HOME_B=$(make_home "$TMP_ROOT/vessel-b")

rec1=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish)
expect_code 0 "$?" "allocation should succeed"
rec2=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish)
[ "$(field seat "$rec1")" = "$(field seat "$rec2")" ] \
  || fail "the seat must be deterministic for one home and service"
[ "$(field port "$rec1")" = "$(field seat "$rec1")" ] \
  || fail "an unheld seat must be the port taken"
[ "$(field addr "$rec1")" = 127.0.0.1 ] || fail "the fake tailnet address should be used"
[ "$(field reachability "$rec1")" = tailnet ] || fail "a running tailnet is reachability=tailnet"
[ -z "$(field reason "$rec1")" ] || fail "a nominal resolution must carry no reason"
pass "one home gets the same deterministic seat every run"

recB=$(FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish)
[ "$(field seat "$rec1")" != "$(field seat "$recB")" ] \
  || fail "two homes on one machine must not share a seat"
pass "two co-hosted homes are separated without talking to each other"

# The realpath of FM_HOME, not the vessel id, is what separates a secondmate
# home from its parent: they share the id and the UNIX account.
mkdir -p "$HOME_A/state" "$HOME_B/state"
printf 'shared\n' > "$HOME_A/config/bridge-vessel"
printf 'shared\n' > "$HOME_B/config/bridge-vessel"
sameA=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish --check)
sameB=$(FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish --check)
[ "$(field vessel "$sameA")" = shared ] && [ "$(field vessel "$sameB")" = shared ] \
  || fail "the configured vessel id should be used"
[ "$(field seat "$sameA")" != "$(field seat "$sameB")" ] \
  || fail "two homes sharing one vessel id must still get different seats"
rm -f "$HOME_A/config/bridge-vessel" "$HOME_B/config/bridge-vessel"
pass "a shared vessel id does not collapse two homes onto one seat"

# --- allocator: --check claims nothing ---------------------------------------

rm -f "$HOME_B/state/service-port.other"
chk=$(FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" other --check)
assert_not_contains "$chk" "port=" "--check must not report a port it never bound"
assert_contains "$chk" "seat=" "--check still reports the deterministic seat"
assert_absent "$HOME_B/state/service-port.other" "--check must not write a record"
pass "--check resolves identity without claiming a port or writing a record"

# --- allocator: the record is a published fact, not a lock --------------------

record="$HOME_A/state/service-port.lavish"
assert_present "$record" "an allocation writes its published record"
assert_grep "PUBLISHED RECORD, NOT A LOCK." "$record" \
  "the record must say in its own bytes that it confers no reservation"
assert_grep "port=$(field port "$rec1")" "$record" "the record carries the port actually taken"
pass "the record names itself a published fact so nobody mistakes it for an allocator"

# --- allocator: the deterministic seat is taken ------------------------------

seat=$(field seat "$rec1")
hold_ports 127.0.0.1 "$seat"
advanced=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish)
expect_code 0 "$?" "a held seat must not be a failure"
[ "$(field port "$advanced")" != "$seat" ] || fail "the allocator must not hand back a held seat"
[ "$(field seat "$advanced")" = "$seat" ] || fail "the preferred seat is still reported as the preference"
assert_grep "port=$(field port "$advanced")" "$record" "the record follows the port actually taken"
release_ports
pass "a held seat advances, and the record reports the port actually taken"

# --- allocator: the whole window is taken ------------------------------------

hold_ports 127.0.0.1 4760 4761
err=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4760-4761 "$ROOT/bin/fm-service-port.sh" lavish 2>&1 >/dev/null)
code=$?
expect_code 1 "$code" "an exhausted window must fail loudly"
assert_contains "$err" "SERVICE_PORT:" "the exhaustion diagnostic is prefixed"
assert_contains "$err" "no free port in 4760-4761" "the diagnostic names the window it exhausted"
assert_not_contains "$err" "127.0.0.1 loopback" "there is no silent loopback downgrade on exhaustion"
release_ports
pass "an exhausted window refuses loudly instead of downgrading silently"

# --- allocator: --mine is returned unprobed ----------------------------------

hold_ports 127.0.0.1 4762
mine=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4762-4762 "$ROOT/bin/fm-service-port.sh" lavish --mine 4762)
expect_code 0 "$?" "a caller-owned port must be accepted"
[ "$(field port "$mine")" = 4762 ] || fail "--mine must be returned as the port"
release_ports
pass "a port the caller already owns is returned without a self-defeating bind probe"

# --- allocator: honest degradation -------------------------------------------

for mode in stopped noipv4; do
  deg=$(FM_TEST_TS_MODE=$mode FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
    "$ROOT/bin/fm-service-port.sh" lavish --check)
  [ "$(field reachability "$deg")" = loopback ] || fail "$mode must degrade to loopback"
  [ "$(field addr "$deg")" = 127.0.0.1 ] || fail "$mode must fall back to the loopback address"
  [ -n "$(field reason "$deg")" ] || fail "$mode must carry a concrete reason"
  case "$(field machine "$deg")" in
    unknown-*) : ;;
    *) fail "$mode must not claim a machine identity it could not establish" ;;
  esac
done
pass "a vessel with no usable tailnet says so concretely instead of implying reach"

badname=$(FM_TEST_TS_MODE=badname FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-service-port.sh" lavish --check)
[ "$(field reachability "$badname")" = tailnet ] || fail "a resolvable address is still tailnet reach"
[ -z "$(field dnsname "$badname")" ] || fail "an unresolvable name must not be offered for links"
assert_contains "$badname" "does not resolve to" "the reason names the concrete DNS problem"
pass "a tailnet name that does not resolve to the bound address is dropped, not written into a link"

# --- allocator: usage errors -------------------------------------------------

FM_HOME="$HOME_A" "$ROOT/bin/fm-service-port.sh" 'Bad Name' >/dev/null 2>&1
expect_code 2 "$?" "a non-slug service name is a usage error"
FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=nonsense "$ROOT/bin/fm-service-port.sh" lavish >/dev/null 2>&1
expect_code 2 "$?" "a malformed window is a usage error"
pass "malformed input is refused rather than guessed at"

# --- entry point: the environment it hands to lavish-axi ---------------------

export FM_TEST_LAVISH_LOG="$TMP_ROOT/lavish-a.log"
: > "$FM_TEST_LAVISH_LOG"
out=$(FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_A/.lavish/board.html" 2>&1)
expect_code 0 "$?" "opening a board should succeed"
log=$(cat "$FM_TEST_LAVISH_LOG")
assert_contains "$log" "HOST=127.0.0.1" "the bind host is this vessel's address, never a wildcard"
assert_contains "$log" "LINK=localhost" "the link host is the checked tailnet name"
assert_contains "$log" "STATEDIR=$HOME_A/state/lavish" "each home gets its own server state directory"
assert_contains "$log" "ALLOWED=" "a closed Host allowlist is always set"
assert_not_contains "$log" "ALLOWED=*" "the allowlist must never be a wildcard"
port=$(printf '%s\n' "$log" | sed -n 's/^PORT=//p' | head -1)
case "$port" in
  47[45][0-9]) : ;;
  *) fail "the port should come from the configured window, got '$port'" ;;
esac
token=$(cat "$HOME_A/state/lavish/claim-token")
assert_contains "$log" "$token" "this home's claim token must be in the allowlist"
pass "the entry point hands lavish-axi a reachable address, a free port, and a closed allowlist"

# The claim token is what identifies this home's own server, so it must be
# stable across runs rather than regenerated into a new identity each time.
: > "$FM_TEST_LAVISH_LOG"
FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_A/.lavish/board.html" >/dev/null 2>&1
[ "$(cat "$HOME_A/state/lavish/claim-token")" = "$token" ] \
  || fail "the claim token must be stable for one home"
pass "the claim token is one durable identity per home"

# --- entry point: passthrough ------------------------------------------------

: > "$FM_TEST_LAVISH_LOG"
FM_HOME="$HOME_A" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" poll "$HOME_A/.lavish/board.html" >/dev/null 2>&1
log=$(cat "$FM_TEST_LAVISH_LOG")
assert_contains "$log" "ARGS=poll $HOME_A/.lavish/board.html" "arguments pass through untouched"
assert_contains "$log" "HOST=127.0.0.1" "a follow-up command resolves the same server, not the default port"
pass "poll and other follow-ups resolve the same server the open call did"

# --- entry point: a flag-led invocation that opens nothing --------------------
#
# The guard denies bare `lavish-axi --version` and names this wrapper as the way
# to run it, so the wrapper has to treat it as what lavish-axi treats it as: a
# command that opens no board at all.

HOME_F=$(make_home "$TMP_ROOT/vessel-f")
export FM_TEST_LAVISH_LOG="$TMP_ROOT/lavish-f.log"
: > "$FM_TEST_LAVISH_LOG"
out=$(FM_TEST_TS_MODE=stopped FM_HOME="$HOME_F" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" --version 2>&1)
expect_code 0 "$?" "a flag-led invocation that opens nothing must still run"
assert_contains "$(cat "$FM_TEST_LAVISH_LOG")" "ARGS=--version" "its arguments reach lavish-axi intact"
assert_absent "$HOME_F/state/service-port.lavish" "a command that opens no board must claim no port"
assert_absent "$HOME_F/state/lavish/fm-owner" "a command that opens no board must not rewrite the owner record"
assert_not_contains "$out" "does not answer here" "nothing may report on a link for a board that was never opened"
assert_not_contains "$out" "opens only on this machine" "nothing may describe the reach of a board that was never opened"
pass "a flag-led invocation carrying no board file claims nothing and reports on nothing"

: > "$FM_TEST_LAVISH_LOG"
FM_HOME="$HOME_F" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" --version "$HOME_F/.lavish/board.html" >/dev/null 2>&1
log=$(cat "$FM_TEST_LAVISH_LOG")
assert_contains "$log" "HOST=127.0.0.1" "a flag in front of a board file is still an open"
assert_contains "$log" "ARGS=--version $HOME_F/.lavish/board.html" "the open still passes its arguments through untouched"
assert_present "$HOME_F/state/service-port.lavish" "an open claims a port however its arguments are ordered"
assert_present "$HOME_F/state/lavish/fm-owner" "an open records what it launched a server with"
pass "a flag-led invocation that does carry a board file takes the full open path"

# --- entry point: honest degradation to the captain --------------------------

export FM_TEST_LAVISH_LOG="$TMP_ROOT/lavish-b.log"
: > "$FM_TEST_LAVISH_LOG"
err=$(FM_TEST_TS_MODE=stopped FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_B/.lavish/board.html" 2>&1 >/dev/null)
assert_contains "$err" "no tailnet on this host" "a loopback-only board must say so"
assert_contains "$err" "opens only on this machine" "the consequence is stated in plain words"
assert_contains "$(cat "$FM_TEST_LAVISH_LOG")" "HOST=127.0.0.1" "the board still opens locally"
pass "a vessel with no tailnet still opens the board and never implies it is reachable"

# --- entry point: third-party publishing needs explicit intent ---------------

: > "$FM_TEST_LAVISH_LOG"
err=$(FM_HOME="$HOME_B" "$ROOT/bin/fm-lavish.sh" share "$HOME_B/.lavish/board.html" 2>&1 >/dev/null)
expect_code 3 "$?" "share is refused by default"
assert_contains "$err" "--fm-allow-share" "the refusal names the override rather than being a dead end"
[ ! -s "$FM_TEST_LAVISH_LOG" ] || fail "a refused share must not reach lavish-axi at all"
FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" share "$HOME_B/.lavish/board.html" --fm-allow-share >/dev/null 2>&1
assert_contains "$(cat "$FM_TEST_LAVISH_LOG")" "ARGS=share" "the override lets the command through"
assert_not_contains "$(cat "$FM_TEST_LAVISH_LOG")" "--fm-allow-share" \
  "the wrapper's own flag must not leak into lavish-axi's arguments"
pass "publishing outside the tailnet requires stated intent, and stays available with it"

# --- entry point: stop only touches a server we own --------------------------

: > "$FM_TEST_LAVISH_LOG"
err=$(FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-lavish.sh" stop 2>&1 >/dev/null)
expect_code 0 "$?" "nothing to stop is not a failure"
assert_contains "$err" "nothing to stop" "the wrapper says plainly that no owned server is running"
[ ! -s "$FM_TEST_LAVISH_LOG" ] || fail "stop must not shut down a server this vessel does not own"
pass "stop refuses to reach a server this vessel has not proved is its own"

# --- guard: the decision matrix ----------------------------------------------

GUARD="$ROOT/bin/fm-lavish-pretool-check.sh"

"$GUARD" --command 'lavish-axi board.html' >/dev/null 2>&1
expect_code 2 "$?" "bare lavish-axi must be denied"
"$GUARD" --command 'bin/fm-lavish.sh board.html' >/dev/null 2>&1
expect_code 0 "$?" "the entry point must not block itself"
"$GUARD" --command 'command -v lavish-axi' >/dev/null 2>&1
expect_code 0 "$?" "tool detection must keep working"
"$GUARD" --command 'npm install -g lavish-axi' >/dev/null 2>&1
expect_code 0 "$?" "installing the package is not opening a board"
"$GUARD" --command 'echo hi && lavish-axi poll x.html' >/dev/null 2>&1
expect_code 2 "$?" "a later command in the list is still denied"
"$GUARD" --command '/opt/axi/bin/lavish-axi x.html' >/dev/null 2>&1
expect_code 2 "$?" "a path-qualified invocation is the same mistake"
"$GUARD" --command 'lavish-axi stop' >/dev/null 2>&1
expect_code 2 "$?" "stopping a server is ownership sensitive and belongs to the wrapper"
pass "the guard denies the invocation that emits an unreachable link and nothing else"

# Subcommands that neither start a server nor emit a link prevent nothing by
# being denied, and this repo prints some of them for the captain to run. Each
# one is a subcommand lavish-axi recognises, so an html argument after it cannot
# promote the invocation to `open`.
for allowed in \
  'lavish-axi setup hooks' \
  'lavish-axi playbook table' \
  'lavish-axi design' \
  'lavish-axi export board.html --out /tmp/board.html'; do
  "$GUARD" --command "$allowed" >/dev/null 2>&1
  expect_code 0 "$?" "a non-serving invocation must not be denied: $allowed"
done
pass "non-serving subcommands stay available, because denying them prevents nothing"

# lavish-axi rewrites a flag-led argv carrying an html path into `open`, so a
# version or help flag is not proof that no board is opened.
for flagged in \
  'lavish-axi --version board.html' \
  'lavish-axi -v /tmp/b.html' \
  'lavish-axi --help board.html' \
  'lavish-axi -h b.htm'; do
  "$GUARD" --command "$flagged" >/dev/null 2>&1
  expect_code 2 "$?" "a flag in front of a board file still opens a board: $flagged"
done
pass "a version or help flag never buys an invocation past the guard"

# The exact shapes bin/fm-bootstrap.sh install_cmd and bin/fm-axi-suite.sh
# install_hint print inside MISSING: and AXI_SUITE_REVIEW: diagnostics. They are
# handed to the captain and to agents as commands to run, so a guard that denies
# them would break the repo's own instructions.
"$GUARD" --command 'npm install -g --prefix /home/coditan/.local/axi lavish-axi && PATH=/home/coditan/.local/axi/bin:$PATH lavish-axi setup hooks' >/dev/null 2>&1
expect_code 0 "$?" "the install command bin/fm-bootstrap.sh prints must be allowed"
"$GUARD" --command 'npm install -g --prefix /home/coditan/.local/axi lavish-axi@0.1.43 && PATH=/home/coditan/.local/axi/bin:$PATH lavish-axi setup hooks' >/dev/null 2>&1
expect_code 0 "$?" "the install hint bin/fm-axi-suite.sh prints must be allowed"
pass "the install commands this repo itself emits are not denied by its own guard"

deny_out=$("$GUARD" --command 'lavish-axi board.html' 2>/dev/null || true)
assert_contains "$deny_out" '"decision":"deny"' "grok consumes the stdout decision object"
deny_err=$("$GUARD" --command 'lavish-axi board.html' 2>&1 >/dev/null || true)
assert_contains "$deny_err" 'fm-lavish.sh' "the reason names the entry point to use instead"
claude_out=$("$GUARD" --claude --command 'lavish-axi board.html' 2>/dev/null || true)
[ -z "$claude_out" ] || fail "Claude requires stdout to stay empty on deny"
grok_stdin=$(printf '{"toolInput":{"command":"lavish-axi x.html"}}' | "$GUARD" 2>/dev/null || true)
assert_contains "$grok_stdin" '"decision":"deny"' "the grok stdin shape is accepted"
codex_stdin=$(printf '{"tool_input":{"command":"lavish-axi x.html"}}' | "$GUARD" 2>&1 >/dev/null || true)
assert_contains "$codex_stdin" 'permissionDecision' "the claude/codex stdin shape is accepted"
pass "every tracked harness entry and output shape is honoured"

printf 'not json' | "$GUARD" >/dev/null 2>&1
expect_code 0 "$?" "malformed transport fails open"
printf '' | "$GUARD" >/dev/null 2>&1
expect_code 0 "$?" "empty transport fails open"
pass "a broken transport never denies a shell command"

# --- guard: scope is the wrapper's presence, not the primary checkout --------

INERT="$TMP_ROOT/no-wrapper"
mkdir -p "$INERT/bin"
: > "$INERT/AGENTS.md"
cp "$ROOT/bin/fm-lavish-pretool-check.sh" "$INERT/bin/"
cp "$ROOT/bin/fm-lavish-command-policy.mjs" "$INERT/bin/"
cp "$ROOT/bin/fm-arm-command-policy.mjs" "$INERT/bin/"
chmod +x "$INERT/bin/fm-lavish-pretool-check.sh"
"$INERT/bin/fm-lavish-pretool-check.sh" --command 'lavish-axi x.html' >/dev/null 2>&1
expect_code 0 "$?" "a checkout without the wrapper is inert"

# A linked worktree is where crewmates open boards, and is exactly where the
# cd-guard is deliberately inert. This guard must NOT be.
fm_git_identity
BASE="$TMP_ROOT/base-repo"
git init -q "$BASE"
git -C "$BASE" commit -q --allow-empty -m init
WT="$TMP_ROOT/task-worktree"
fm_git_worktree "$BASE" "$WT" fm/lavish-guard-scope
: > "$WT/AGENTS.md"
mkdir -p "$WT/bin"
cp "$ROOT/bin/fm-lavish-pretool-check.sh" "$ROOT/bin/fm-lavish-command-policy.mjs" \
  "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-lavish.sh" "$WT/bin/"
chmod +x "$WT/bin/fm-lavish-pretool-check.sh" "$WT/bin/fm-lavish.sh"
"$WT/bin/fm-lavish-pretool-check.sh" --command 'lavish-axi x.html' >/dev/null 2>&1
expect_code 2 "$?" "the guard must fire in a task worktree, where boards also get opened"
pass "the guard is scoped to the wrapper's presence, so it covers crew worktrees too"

# --- harness wiring ----------------------------------------------------------

jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-lavish-pretool-check.sh --claude"))' \
  "$ROOT/.claude/settings.json" >/dev/null \
  || fail ".claude/settings.json must register the lavish guard in Claude mode"
jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-lavish-pretool-check.sh"))' \
  "$ROOT/.codex/hooks.json" >/dev/null \
  || fail ".codex/hooks.json must register the lavish guard"
jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-lavish-pretool-check.sh"))' \
  "$ROOT/.grok/hooks/fm-primary-lavish-check.json" >/dev/null \
  || fail ".grok/hooks must register the lavish guard"

# OpenCode and Pi are not JSON hook surfaces; they call the guard through their
# own plugin and extension, exactly as the cd-guard is wired.
OPENCODE_PLUGIN="$ROOT/.opencode/plugins/fm-primary-lavish-check.js"
assert_present "$OPENCODE_PLUGIN" ".opencode/plugins must carry a lavish guard plugin"
assert_grep 'tool.execute.before' "$OPENCODE_PLUGIN" \
  "the OpenCode plugin must run before the bash tool executes"
assert_grep 'fm-lavish-pretool-check.sh' "$OPENCODE_PLUGIN" \
  "the OpenCode plugin must invoke the lavish guard owner"
assert_grep 'throw new Error' "$OPENCODE_PLUGIN" \
  "the OpenCode plugin must block by throwing"

PI_EXTENSION="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
assert_grep 'fm-lavish-pretool-check.sh' "$PI_EXTENSION" \
  "the Pi extension must invoke the lavish guard owner"
assert_grep 'runLavishCheck(command)' "$PI_EXTENSION" \
  "the Pi extension must run the lavish check on a tool call"
assert_grep 'block: true' "$PI_EXTENSION" \
  "the Pi extension must block the command it denies"

# Pi's registration reaches the sessions launched with this extension, which is
# not every session bin/fm-spawn.sh starts. The doc has to say so, because the
# whole point of this change is not overstating reach.
assert_grep 'not by a Pi crew' "$PI_EXTENSION" \
  "the Pi extension must state which sessions actually load it"
assert_grep 'does not reach a Pi crewmate or scout' "$ROOT/docs/lavish-access.md" \
  "the doc must name the Pi sessions this registration does not reach"
pass "the guard is registered on all five tracked harness surfaces, with Pi's crew limit stated rather than rounded up"

# --- the instruction surface points at the entry point -----------------------

assert_grep 'bin/fm-lavish.sh' "$ROOT/AGENTS.md" "AGENTS.md must name the entry point"
assert_grep 'LAVISH_ACCESS:' "$ROOT/AGENTS.md" \
  "AGENTS.md section 13 must list the new bootstrap diagnostic"
assert_grep 'LAVISH_ACCESS' "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
  "bootstrap-diagnostics must own the LAVISH_ACCESS response"
assert_grep 'fm-lavish.sh' "$ROOT/bin/fm-brief.sh" \
  "generated briefs must name the entry point, since the guard cannot reach project worktrees"
pass "the instruction surface names one owner and one entry point"

# --- server-backed cases: ownership, reuse, and refusal to adopt -------------
#
# The cases above use a fake lavish-axi that records its environment. These need
# something that actually listens, because the property under test is exactly
# the one no static fixture can express: whether the server on our port is OUR
# server. The fake board server below mimics the only behaviour that matters
# here - lavish-axi's Host allowlist, which always admits loopback and otherwise
# admits only the names it was started with.

cat > "$TMP_ROOT/board-server.mjs" <<'JS'
import http from "node:http";
import { writeFileSync } from "node:fs";
const [ready, addr, port, ...allowed] = process.argv.slice(2);
const names = new Set(["127.0.0.1", "::1", "localhost", ...allowed].map((v) => v.toLowerCase()));
http
  .createServer((req, res) => {
    const host = String(req.headers.host || "").split(":")[0].toLowerCase();
    if (!names.has(host)) {
      res.writeHead(403).end('{"error":"forbidden host"}');
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, app: "lavish-axi", version: "0.0.0-test" }));
  })
  .listen({ host: addr, port: Number(port) }, () => writeFileSync(ready, "ready\n"));
JS

# A lavish-axi that really starts and stops a server, so the wrapper's ownership
# probe has something truthful to answer against.
make_serving_lavish() {
  local home=$1 bindir="$1/.local/axi/bin"
  mkdir -p "$bindir"
  cat > "$bindir/lavish-axi" <<SH
#!/usr/bin/env bash
pidfile="\$FM_TEST_SERVERS/\${LAVISH_AXI_PORT:-none}.pid"
if [ "\${1:-}" = stop ]; then
  target="\${3:-\$LAVISH_AXI_PORT}"
  pidfile="\$FM_TEST_SERVERS/\$target.pid"
  if [ -s "\$pidfile" ]; then kill "\$(cat "\$pidfile")" 2>/dev/null || true; rm -f "\$pidfile"; fi
  printf 'stopped %s\n' "\$target"
  exit 0
fi
if [ ! -s "\$pidfile" ]; then
  ready="\$FM_TEST_SERVERS/\${LAVISH_AXI_PORT}.ready"
  rm -f "\$ready"
  # Detach every stream: a background child that inherits stdout would keep the
  # caller's command substitution open until it exits, which never happens.
  node "$TMP_ROOT/board-server.mjs" "\$ready" "\$LAVISH_AXI_HOST" "\$LAVISH_AXI_PORT" \$LAVISH_AXI_ALLOWED_HOSTS \\
    </dev/null >"\$FM_TEST_SERVERS/\${LAVISH_AXI_PORT}.log" 2>&1 &
  echo \$! > "\$pidfile"
  for _ in \$(seq 1 100); do [ -s "\$ready" ] && break; sleep 0.05; done
fi
printf 'url: "http://%s:%s/session/test"\n' "\$LAVISH_AXI_LINK_HOST" "\$LAVISH_AXI_PORT"
SH
  chmod +x "$bindir/lavish-axi"
}

export FM_TEST_SERVERS="$TMP_ROOT/servers"
mkdir -p "$FM_TEST_SERVERS"
kill_test_servers() {
  local p
  for p in "$FM_TEST_SERVERS"/*.pid; do
    [ -e "$p" ] || continue
    kill "$(cat "$p")" 2>/dev/null || true
    rm -f "$p"
  done
}
trap 'kill_test_servers; release_ports; fm_test_cleanup' EXIT

HOME_C=$(make_home "$TMP_ROOT/vessel-c")
make_serving_lavish "$HOME_C"

first=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4770-4779 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>/dev/null)
port_c=$(printf '%s\n' "$first" | sed -n 's|.*:\([0-9][0-9]*\)/session.*|\1|p')
[ -n "$port_c" ] || fail "the first open should emit a port"
second=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4770-4779 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>/dev/null)
[ "$first" = "$second" ] || fail "a second open must reuse the running server, got '$second' after '$first'"
[ "$(find "$FM_TEST_SERVERS" -name '*.pid' | wc -l)" = 1 ] \
  || fail "reusing must not leave a second server behind"
pass "a vessel reuses its own running board server instead of starting another"

# A neighbouring UNIX account's lavish-axi answers /health identically, so the
# only thing that separates it from ours is the claim token in its allowlist.
hold_ready="$TMP_ROOT/foreign.ready"
rm -f "$hold_ready"
node "$TMP_ROOT/board-server.mjs" "$hold_ready" 127.0.0.1 4781 localhost \
  </dev/null >"$TMP_ROOT/foreign.log" 2>&1 &
FOREIGN_PID=$!
for _ in $(seq 1 100); do [ -s "$hold_ready" ] && break; sleep 0.05; done
[ -s "$hold_ready" ] || fail "the foreign server did not come up"

HOME_D=$(make_home "$TMP_ROOT/vessel-d")
make_serving_lavish "$HOME_D"
err=$(FM_HOME="$HOME_D" FM_SERVICE_PORT_RANGE=4781-4781 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_D/.lavish/board.html" 2>&1 >/dev/null)
code=$?
expect_code 5 "$code" "a port held by another account's server must not produce a board"
assert_contains "$err" "no free port" "the refusal names the concrete port problem"
assert_contains "$err" "no board was opened" "the refusal is explicit that nothing was opened"
kill "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true
pass "a same-version server belonging to another account is refused, never silently adopted"

# A running server keeps emitting the link host it was born with, so a changed
# configuration has to restart it rather than be exported at it.
owner="$HOME_C/state/lavish/fm-owner"
sed -i.bak 's/^link_host=.*/link_host=stale.invalid/' "$owner" && rm -f "$owner.bak"
out=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4770-4779 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>&1)
assert_contains "$out" "different address configuration" "a stale server must be reported and restarted"
assert_contains "$out" ":$port_c/session" "the restart reclaims the same port"
pass "a server started with a stale configuration is restarted rather than reused"

# Moving to a new window must never destroy a working board before a
# replacement exists.
hold_ports 127.0.0.1 4791
err=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4791-4791 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>&1 >/dev/null)
expect_code 5 "$?" "a full window must refuse"
assert_contains "$err" "was left running, so nothing was lost" \
  "a failed move must say the existing board survived"
release_ports
still=$(node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$port_c/health" 2>/dev/null)
[ "$still" = 200 ] || fail "the existing board must still be serving after a failed move"
pass "a failed relocation leaves the working board untouched"

moved=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>&1)
assert_contains "$moved" "moving this vessel's boards from port $port_c" \
  "a real move must name both ports"
assert_contains "$moved" "links already handed over on the old port stop working" \
  "the cost of moving must be stated, not hidden"
pass "a successful relocation reports the consequence for links already handed over"

out=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 "$ROOT/bin/fm-lavish.sh" stop 2>&1)
assert_contains "$out" "stopped" "stop reaches this vessel's own server"
out=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 "$ROOT/bin/fm-lavish.sh" stop 2>&1)
assert_contains "$out" "nothing to stop" "a second stop has nothing left to reach"
pass "stop reaches this vessel's own server and then reports honestly that none is left"

# --- entry point: an explicit --port earns no shortcut -----------------------
#
# lavish-axi's own stop shuts down whatever answers /health on the address it is
# handed, and every co-hosted vessel binds that same address, so a named port
# has to clear the same claim-token proof the recorded one does.

reopened=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_C/.lavish/board.html" 2>/dev/null)
own_port=$(printf '%s\n' "$reopened" | sed -n 's|.*:\([0-9][0-9]*\)/session.*|\1|p')
[ -n "$own_port" ] || fail "reopening the board should emit a port"
out=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 \
  "$ROOT/bin/fm-lavish.sh" stop --port "$own_port" 2>&1)
expect_code 0 "$?" "an explicit --port on a proven-own server is a normal stop"
assert_contains "$out" "stopped" "a proven-own port is still stopped when named explicitly"

neighbour_ready="$TMP_ROOT/neighbour.ready"
rm -f "$neighbour_ready"
node "$TMP_ROOT/board-server.mjs" "$neighbour_ready" 127.0.0.1 4794 localhost \
  </dev/null >"$TMP_ROOT/neighbour.log" 2>&1 &
NEIGHBOUR_PID=$!
for _ in $(seq 1 100); do [ -s "$neighbour_ready" ] && break; sleep 0.05; done
[ -s "$neighbour_ready" ] || fail "the neighbouring server did not come up"

err=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 \
  "$ROOT/bin/fm-lavish.sh" stop --port 4794 2>&1 >/dev/null)
expect_code 7 "$?" "an unproven --port must be refused, not obeyed"
assert_contains "$err" "4794" "the refusal names the port it declined to touch"
assert_contains "$err" "not one this vessel can prove is its own" \
  "the refusal says plainly why the port was left alone"
alive=$(node "$ROOT/bin/fm-service-port-probe.mjs" http http://127.0.0.1:4794/health 2>/dev/null)
[ "$alive" = 200 ] || fail "a neighbour's board must still be serving after a refused stop"
kill "$NEIGHBOUR_PID" 2>/dev/null || true
wait "$NEIGHBOUR_PID" 2>/dev/null || true

out=$(FM_HOME="$HOME_C" FM_SERVICE_PORT_RANGE=4792-4793 \
  "$ROOT/bin/fm-lavish.sh" stop --port 4795 2>&1)
expect_code 0 "$?" "a named port with nothing on it is not a failure"
assert_contains "$out" "nothing to stop" "an empty port is reported as nothing to stop"
assert_contains "$out" "4795" "the message names the port that was checked"
pass "stop --port is held to the same ownership proof as a bare stop"
