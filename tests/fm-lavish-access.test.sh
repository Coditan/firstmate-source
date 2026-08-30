#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for reachable review boards (docs/lavish-access.md).
#
# Three cooperating pieces are covered here:
#   - bin/fm-service-port.sh, the general vessel-local port allocator, whose one
#     rule is that a successful bind is the only proof a port is free;
#   - bin/fm-tailnet-serve-lib.sh, the one owner of publishing a loopback port
#     onto this node's tailnet address and withdrawing it again, driven end to
#     end here through the fake `tailscale serve` below;
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
#   userspace - running on an address no local interface carries, which is what
#               tailscale userspace networking mode looks like. 192.0.2.1 is
#               TEST-NET-1: it is assigned on no host, so the bind really does
#               fail EADDRNOTAVAIL here rather than being mocked into failing.
#   kernel    - running on a bindable address that is NOT loopback, which is
#               what a node looks like once it has kernel-mode networking. It is
#               the address this vessel binds and probes, so a listener that a
#               publication forwards to on 127.0.0.1 is somewhere else entirely.
#   portscoped - running on an address whose bind fails for a reason that is
#               NOT address-scoped, so the probe answers exit 1 and says nothing
#               about the address either way. 1.2.3.4.5 is not an IPv4 address,
#               so node resolves it as a name and the bind really does fail
#               ENOTFOUND, the same class as the EPERM and fd-pressure answers a
#               healthy kernel-mode vessel can meet.
#
# It also fakes `tailscale serve`, keeping its published ports in
# FM_TEST_TS_SERVE_STATE and logging every serve invocation to
# FM_TEST_TS_SERVE_LOG, so a test can assert that the proxy path was taken - or,
# just as importantly, that it was NOT. FM_TEST_TS_SERVE=broken makes every
# serve mutation fail, which is the vessel that has the unbindable address and
# no way around it.
make_fake_tailscale() {
  local bin=$1
  cat > "$bin/tailscale" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = serve ]; then
  printf '%s\n' "$*" >> "${FM_TEST_TS_SERVE_LOG:-/dev/null}"
  state=${FM_TEST_TS_SERVE_STATE:-/dev/null}
  if [ "${2:-}" = status ]; then
    printf '{"TCP":{'
    sep=""
    while read -r p; do
      [ -n "$p" ] || continue
      printf '%s"%s":{"HTTP":true}' "$sep" "$p"
      sep=","
    done < <(sort -u "$state" 2>/dev/null)
    printf '}}\n'
    exit 0
  fi
  [ "${FM_TEST_TS_SERVE:-ok}" = broken ] && exit 1
  port=""
  for a in "$@"; do
    case "$a" in --http=*) port=${a#--http=} ;; esac
  done
  [ -n "$port" ] || exit 1
  if [ "${*: -1}" = off ]; then
    grep -vx "$port" "$state" > "$state.tmp" 2>/dev/null || : > "$state.tmp"
    mv -f "$state.tmp" "$state"
  else
    printf '%s\n' "$port" >> "$state"
  fi
  exit 0
fi
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
  userspace)
    printf '{"BackendState":"Running","MagicDNSSuffix":"","Self":{"HostName":"userspace","DNSName":"userspace.","TailscaleIPs":["192.0.2.1"]}}\n'
    ;;
  portscoped)
    printf '{"BackendState":"Running","MagicDNSSuffix":"","Self":{"HostName":"portscoped","DNSName":"portscoped.","TailscaleIPs":["1.2.3.4.5"]}}\n'
    ;;
  kernel)
    printf '{"BackendState":"Running","MagicDNSSuffix":"","Self":{"HostName":"kernel","DNSName":"kernel.","TailscaleIPs":["127.0.0.2"]}}\n'
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
# lavish-axi's CLI layer answers --help with the command's help text and never
# reaches the handler, so an argv that dispatches `open` can still open nothing.
for arg in "$@"; do
  [ "$arg" = --help ] || continue
  printf 'Usage: lavish-axi <html-file> [--no-open] [--no-gate] [--reopen]\n'
  exit 0
done
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
export FM_TEST_TS_SERVE_STATE="$TMP_ROOT/serve-state"
export FM_TEST_TS_SERVE_LOG="$TMP_ROOT/serve-log"
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"

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

# --- allocator: an address the node has but cannot bind ----------------------
#
# The case that is neither of the other two. Each assertion below is paired with
# its negative, because a fallback that fires everywhere has replaced the
# resolution rather than extended it, and would hand every ordinary vessel a
# proxy it never needed.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
node "$PROBE" addr 127.0.0.1 >/dev/null 2>&1
expect_code 0 "$?" "loopback is bindable, so the address probe must say so"
node "$PROBE" addr 192.0.2.1 >/dev/null 2>&1
expect_code 4 "$?" "an address no interface carries is exit 4 from the address probe"
pass "the address probe separates a bindable address from one this host cannot carry"

# The bindable case first, so the negative is measured on the same fixtures.
bindable=$(FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-service-port.sh" lavish)
[ "$(field reachability "$bindable")" = tailnet ] \
  || fail "a bindable tailnet address must stay reachability=tailnet"
[ "$(field addr "$bindable")" = 127.0.0.1 ] || fail "the bindable address is bound directly"
[ "$(field tailaddr "$bindable")" = 127.0.0.1 ] || fail "tailaddr names the node's own address"
[ ! -s "$FM_TEST_TS_SERVE_LOG" ] \
  || fail "a bindable address must not publish a proxy: $(cat "$FM_TEST_TS_SERVE_LOG")"
pass "a vessel that can bind its own tailnet address never reaches the proxy path"

: > "$FM_TEST_TS_SERVE_LOG"
proxied=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-service-port.sh" lavish --serving)
expect_code 0 "$?" "an unbindable address with a working serve must resolve, not refuse"
[ "$(field reachability "$proxied")" = tailnet-proxied ] \
  || fail "an unbindable tailnet address is its own reachability, got '$(field reachability "$proxied")'"
[ "$(field addr "$proxied")" = 127.0.0.1 ] || fail "the proxied case binds loopback"
[ "$(field tailaddr "$proxied")" = 192.0.2.1 ] \
  || fail "the proxied case must still name the tailnet address it could not bind"
proxied_port=$(field port "$proxied")
[ "$(field route "$proxied")" = published ] \
  || fail "a serving run that published must say so in route=, got '$(field route "$proxied")'"
assert_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "--http=$proxied_port" \
  "the port actually bound is the port published"
assert_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "http://127.0.0.1:$proxied_port" \
  "the proxy points at the loopback port that was bound"
# The diagnosis is the thing a vessel in this state most needs said out loud,
# and making it work is not a licence to stop saying it.
assert_contains "$proxied" "EADDRNOTAVAIL" "the reason keeps the concrete errno"
assert_contains "$proxied" "userspace" "the reason keeps the userspace-mode diagnosis"
pass "an address the node holds but cannot bind is served over a published proxy and still diagnosed"

# A publication is node-wide and survives a reboot, so only a caller that says it
# will leave a service listening may make one. The same fixtures that publish
# above must publish nothing here, or the flag is not carrying the decision.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
unserved=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-service-port.sh" lavish)
expect_code 0 "$?" "a caller that will not leave a service listening still gets a port"
# The run made no route, and says so in route=. What it must NOT do is restate
# that as a fact about the host: this vessel can be reached by proxy, and a
# consumer of the record - the fleet registry, the session-start notice - would
# otherwise read a proxy-capable vessel as loopback-only because a board closed.
[ "$(field reachability "$unserved")" = tailnet-proxied ] \
  || fail "a run that published nothing must not restate the host as unreachable, got '$(field reachability "$unserved")'"
[ "$(field route "$unserved")" = none ] \
  || fail "the run's own outcome belongs in route=, got '$(field route "$unserved")'"
assert_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "serve status" \
  "the allocator still has to READ whether a route already exists"
assert_not_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "--bg" \
  "nothing may be published for a run that will not leave a service listening"
# One reason cannot say both that a route exists and that none was made, and a
# deliberate choice is not a degradation: the caller's own flag has no business
# in a line the captain reads.
assert_not_contains "$unserved" "published onto" \
  "the reason must not claim a route this run did not make"
assert_not_contains "$unserved" "was not told" \
  "the caller's flag is not a diagnosis and must not reach user-facing output"

# Reading a route somebody else established is not making one, so an already
# published port is still the reach it is.
printf '%s\n' "$(field seat "$unserved")" > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
standing=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_B" \
  FM_SERVICE_PORT_RANGE="$(field seat "$unserved")-$(field seat "$unserved")" \
  "$ROOT/bin/fm-service-port.sh" lavish)
[ "$(field reachability "$standing")" = tailnet-proxied ] \
  || fail "an already published port is still proxied reach, got '$(field reachability "$standing")'"
[ "$(field route "$standing")" = published ] \
  || fail "a route somebody else established is still a route, got '$(field route "$standing")'"
assert_not_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "--bg" \
  "an existing route must be read, never re-made"
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
pass "only a caller that will leave a service listening may publish a route onto the tailnet"

# The proxied reading above is carried forward from a run that ACTUALLY published,
# not asserted from tailscaled being up. On a vessel whose serve cannot publish,
# a run that attempted it established loopback, and a later run that attempts
# nothing must not overwrite that: doing so tells the session-start notice to
# offer a reopen that only degrades to the same link again, and tells the fleet
# registry that a vessel with no reach off the machine is proxy-reachable.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_P=$(make_home "$TMP_ROOT/vessel-p")
tried=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_P" \
  FM_SERVICE_PORT_RANGE=4846-4847 "$ROOT/bin/fm-service-port.sh" lavish --serving)
[ "$(field reachability "$tried")" = loopback ] \
  || fail "a run that attempted a publish and failed establishes loopback, got '$(field reachability "$tried")'"
untested=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_P" \
  FM_SERVICE_PORT_RANGE=4846-4847 "$ROOT/bin/fm-service-port.sh" lavish)
[ "$(field reachability "$untested")" = loopback ] \
  || fail "a run that tested nothing must not overwrite a tested host fact, got '$(field reachability "$untested")'"
[ "$(field route "$untested")" = none ] || fail "no route exists, so route= says none"
[ -z "$(field dnsname "$untested")" ] \
  || fail "no name may be offered where no reach was established"
assert_grep "reachability=loopback" "$HOME_P/state/service-port.lavish" \
  "the published record keeps the resolution a run that tested it established"
assert_not_contains "$untested" "was not told" \
  "the caller's flag must not be named as the cause on a vessel that cannot publish at all"
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
pass "a run that neither published nor found a route claims no proxy reach of its own"

# Serve is the whole reason this case is not simply loopback, so a serve that
# cannot publish must not be reported as reach.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
noserve=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_B" \
  FM_SERVICE_PORT_RANGE=4740-4759 "$ROOT/bin/fm-service-port.sh" lavish --serving)
expect_code 0 "$?" "a vessel with no way off the machine still gets a local board"
[ "$(field reachability "$noserve")" = loopback ] \
  || fail "an unpublishable proxy must degrade to loopback, not claim tailnet reach"
[ -z "$(field dnsname "$noserve")" ] \
  || fail "a name that cannot be reached must not be offered for links"
assert_contains "$noserve" "EADDRNOTAVAIL" "the degraded case still names why the address failed"
pass "an unbindable address with no working proxy is reported as loopback rather than as reach"

# Only an address-scoped verdict may move a vessel onto the proxy path. Reading
# every non-zero probe exit as "unbindable" would take a healthy kernel-mode
# vessel that met fd pressure or EPERM, rebind it on loopback, publish a
# node-wide serve entry it never needed, and tell it its address fails
# EADDRNOTAVAIL in userspace mode - a concrete diagnosis with nothing behind it.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
node "$PROBE" addr 1.2.3.4.5 >/dev/null 2>&1
expect_code 1 "$?" "a bind that failed for a port-scoped reason answers nothing about the address"
portscoped=$(FM_TEST_TS_MODE=portscoped FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4816-4817 \
  "$ROOT/bin/fm-service-port.sh" lavish 2>&1)
expect_code 1 "$?" "an unreadable address answer falls through to the window walk, which refuses honestly"
assert_not_contains "$portscoped" "userspace" \
  "a userspace-mode diagnosis must never be asserted from a probe answer that did not say it"
assert_not_contains "$portscoped" "EADDRNOTAVAIL" \
  "the errno this run never met must not be named"
assert_not_contains "$portscoped" "tailnet-proxied" \
  "a port-scoped failure must not rebind the vessel behind a proxy it never needed"
[ ! -s "$FM_TEST_TS_SERVE_LOG" ] \
  || fail "nothing may be published for an address that was never proved unbindable: $(cat "$FM_TEST_TS_SERVE_LOG")"
pass "only an address-scoped probe verdict turns a vessel into a proxied one"

# The no-tailnet vessel is unchanged by any of this: same reachability, same
# message, and no serve configuration touched on its behalf.
: > "$FM_TEST_TS_SERVE_LOG"
for mode in stopped noipv4; do
  untouched=$(FM_TEST_TS_MODE=$mode FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
    "$ROOT/bin/fm-service-port.sh" lavish)
  [ "$(field reachability "$untouched")" = loopback ] || fail "$mode must still be loopback"
  [ -z "$(field tailaddr "$untouched")" ] \
    || fail "$mode has no tailnet address to name"
done
[ ! -s "$FM_TEST_TS_SERVE_LOG" ] \
  || fail "a host with no tailnet must not publish anything: $(cat "$FM_TEST_TS_SERVE_LOG")"
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
pass "a host with no tailnet at all keeps its existing loopback behaviour untouched"

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

# --- entry point: what it says about a board is what it observed --------------
#
# An argv can dispatch `open` and still open nothing, because lavish-axi answers
# --help with help text and never reaches the handler. The wrapper therefore
# decides from the session URL in the output, not from the argument shape.

for helped in "--help $HOME_F/.lavish/board.html" "open --help $HOME_F/.lavish/board.html"; do
  : > "$FM_TEST_LAVISH_LOG"
  # shellcheck disable=SC2086
  out=$(FM_TEST_TS_MODE=stopped FM_HOME="$HOME_F" FM_SERVICE_PORT_RANGE=4740-4759 \
    "$ROOT/bin/fm-lavish.sh" $helped 2>&1)
  expect_code 0 "$?" "asking for help must succeed: $helped"
  assert_contains "$out" "Usage: lavish-axi" "the help text still reaches the caller: $helped"
  assert_not_contains "$out" "does not answer here" \
    "nothing may report a link for a board that was never opened: $helped"
  # The host's own reachability is not a claim about a link, and withholding it
  # is the silent failure this mechanism exists to end.
  assert_contains "$out" "opens only on this machine" \
    "a loopback-only host is still named on an invocation that could open a board: $helped"
done
pass "an argv that dispatches open but opens nothing makes no claim about a link"

: > "$FM_TEST_LAVISH_LOG"
out=$(FM_TEST_TS_MODE=stopped FM_HOME="$HOME_F" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_F/.lavish/board.html" 2>&1)
assert_contains "$out" "/session/" "a genuine open emits the session link"
assert_contains "$out" "does not answer here" \
  "a genuine open still verifies the hostname now sitting in the captain's link"
assert_contains "$out" "opens only on this machine" \
  "a genuine open still says plainly that this board is local only"
pass "a genuine open still gets every line the captain needs about its link"

# --- the observed-open shape is pinned to the real tool ----------------------
#
# The wrapper decides that a board opened from a session URL in lavish-axi's own
# output, so a change to that output would disable the link check silently. The
# fake above cannot catch that, because this suite writes the very shape the
# wrapper reads, so the expectation is taken from the installed tool instead.

assert_grep '*://*/session/*' "$ROOT/bin/fm-lavish.sh" \
  "the wrapper must still recognise an open by the session URL shape pinned below"
REAL_LAVISH=$(command -v lavish-axi 2>/dev/null || true)
if [ -z "$REAL_LAVISH" ]; then
  echo "skip: lavish-axi not installed, so the observed-open shape was not pinned against the real tool"
else
  HOME_R=$(make_home "$TMP_ROOT/vessel-real")
  real_port=$(node "$PROBE" bind 127.0.0.1 4796 4797 4798)
  [ -n "$real_port" ] || fail "no free port to open a real board on"
  real_out=$(LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_PORT="$real_port" \
    LAVISH_AXI_LINK_HOST=127.0.0.1 LAVISH_AXI_ALLOWED_HOSTS="127.0.0.1 localhost" \
    LAVISH_AXI_STATE_DIR="$HOME_R/state/lavish" \
    "$REAL_LAVISH" "$HOME_R/.lavish/board.html" --no-open 2>&1) || true
  LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_PORT="$real_port" \
    LAVISH_AXI_STATE_DIR="$HOME_R/state/lavish" \
    "$REAL_LAVISH" stop --port "$real_port" >/dev/null 2>&1 || true
  case "$real_out" in
    *://*/session/*) : ;;
    *) fail "the installed lavish-axi no longer prints a session URL in the shape the wrapper reads: $real_out" ;;
  esac
  pass "the shape the wrapper reads as an open is the shape the installed lavish-axi prints"
fi

# --- entry point: honest degradation to the captain --------------------------

export FM_TEST_LAVISH_LOG="$TMP_ROOT/lavish-b.log"
: > "$FM_TEST_LAVISH_LOG"
err=$(FM_TEST_TS_MODE=stopped FM_HOME="$HOME_B" FM_SERVICE_PORT_RANGE=4740-4759 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_B/.lavish/board.html" 2>&1 >/dev/null)
assert_contains "$err" "no tailnet on this host" "a loopback-only board must say so"
assert_contains "$err" "opens only on this machine" "the consequence is stated in plain words"
assert_not_contains "$err" "not reachable off this machine" \
  "a vessel that genuinely has no tailnet keeps naming that, not the softer fact"
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
# AGENTS.md section 13 no longer carries a second copy of the diagnostic-prefix list.
# bootstrap-diagnostics is its one owner, while fm-instruction-owners and fm-bootstrap own the general AGENTS.md trigger's presence and wording.
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

# --- entry point: the vessel whose address it cannot bind --------------------
#
# The board binds loopback here, but nothing the captain is handed may say so:
# the link and the allowlist have to name the tailnet, because the published
# proxy is where the board actually answers.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_U=$(make_home "$TMP_ROOT/vessel-u")
make_serving_lavish "$HOME_U"
out=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_U" FM_SERVICE_PORT_RANGE=4796-4799 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_U/.lavish/board.html" 2>&1)
assert_contains "$out" "EADDRNOTAVAIL" "the vessel still says its address cannot be bound"
u_port=$(printf '%s\n' "$out" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$u_port" ] || fail "the proxied open should still emit a session link, got: $out"
assert_contains "$out" "192.0.2.1:$u_port/session/" \
  "the link must name the tailnet address, never the loopback the board is bound to"
assert_not_contains "$out" "127.0.0.1:$u_port/session/" \
  "a loopback link is exactly what this wrapper exists to stop handing over"
u_owner="$HOME_U/state/lavish/fm-owner"
assert_grep "addr=127.0.0.1" "$u_owner" "the board still binds the address it can bind"
assert_grep "link_host=192.0.2.1" "$u_owner" "the recorded link host is the tailnet address"
u_allowed=$(sed -n 's/^allowed=//p' "$u_owner" | tail -1)
# Measured, not reasoned about: a request through the published proxy carries
# the tailnet name as its Host, and the allowlist is compared on hostname alone.
case " $u_allowed " in
  *" 192.0.2.1 "*) : ;;
  *) fail "the allowlist must carry the tailnet address the proxy answers on: $u_allowed" ;;
esac
case " $u_allowed " in
  *" userspace "*) : ;;
  *) fail "the allowlist must carry this node's own name: $u_allowed" ;;
esac
case " $u_allowed " in
  *" * "*) fail "the allowlist must never become a wildcard: $u_allowed" ;;
esac
assert_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "--http=$u_port" \
  "the port the board bound is the port published onto the tailnet"
pass "a vessel that cannot bind its own address still hands over a tailnet link"

# A proxy outliving its board leaves this vessel's own name answering nothing,
# which reads as a broken board rather than a closed one.
FM_TEST_TS_MODE=userspace FM_HOME="$HOME_U" FM_SERVICE_PORT_RANGE=4796-4799 \
  "$ROOT/bin/fm-lavish.sh" stop >/dev/null 2>&1
[ "$(sort -u "$FM_TEST_TS_SERVE_STATE" | tr -d '[:space:]')" = "" ] \
  || fail "stopping the board must withdraw its published proxy, still published: $(cat "$FM_TEST_TS_SERVE_STATE")"
assert_contains "$(cat "$FM_TEST_TS_SERVE_LOG")" "--http=$u_port off" \
  "the withdrawal names the port it published"
pass "stopping a proxied board takes its tailnet endpoint down with it"

# A withdrawal that does not take is the exact residue this mechanism exists to
# prevent, and `stop` replaces this process, so the moment before it is the only
# one in which it can be said at all.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_Y=$(make_home "$TMP_ROOT/vessel-y")
make_serving_lavish "$HOME_Y"
y_out=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_Y" FM_SERVICE_PORT_RANGE=4826-4827 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_Y/.lavish/board.html" 2>/dev/null)
y_port=$(printf '%s\n' "$y_out" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$y_port" ] || fail "the proxied open should emit a port, got: $y_out"
grep -qx "$y_port" "$FM_TEST_TS_SERVE_STATE" || fail "the open should have published $y_port"

# Serve can still be read but no longer mutated, so the off command runs and the
# port stays published, which is the one answer that means the withdrawal failed
# rather than that there was nothing to withdraw.
y_stop=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_Y" \
  FM_SERVICE_PORT_RANGE=4826-4827 "$ROOT/bin/fm-lavish.sh" stop 2>&1)
expect_code 0 "$?" "a failed withdrawal must be reported, never turned into a refusal to stop"
assert_contains "$y_stop" "could not be withdrawn" \
  "a tailnet endpoint left standing must be said out loud, not left for the captain to find"
assert_contains "$y_stop" "$y_port" "the report names the port still answering"
assert_contains "$y_stop" "stopped" "the board really did stop, and the run says so"
grep -qx "$y_port" "$FM_TEST_TS_SERVE_STATE" \
  || fail "this case only means anything while the withdrawal genuinely did not take"
pass "a withdrawal that did not take is reported rather than left silent"

# The promise was never "bind this address". It was "never hand him a link that
# opens nowhere", so the branch with no proxy at all has to keep saying so.
: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_N=$(make_home "$TMP_ROOT/vessel-n")
make_serving_lavish "$HOME_N"
out=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_N" \
  FM_SERVICE_PORT_RANGE=4801-4804 "$ROOT/bin/fm-lavish.sh" "$HOME_N/.lavish/board.html" 2>&1)
assert_contains "$out" "this board opens only on this machine" \
  "with no proxy to publish, the vessel must still say the link goes nowhere else"
assert_contains "$out" "EADDRNOTAVAIL" "and must still name why"
# The lead clause and the parenthetical have to agree. This node HAS a tailnet
# address; it just cannot be bound or proxied, and being sent hunting a missing
# tailnet is the misdirection the reason lines exist to avoid.
assert_contains "$out" "not reachable off this machine" \
  "the degraded vessel is told the fact that is true of it"
assert_not_contains "$out" "no tailnet on this host" \
  "a vessel whose own parenthetical names its tailnet address must not be told it has none"
assert_not_contains "$out" "192.0.2.1:" \
  "a tailnet link must never be emitted when nothing answers on the tailnet"
n_owner="$HOME_N/state/lavish/fm-owner"
assert_grep "link_host=127.0.0.1" "$n_owner" \
  "the link falls back to loopback rather than naming an address nothing serves"
pass "a vessel with an unbindable address and no proxy is told its board opens only here"

# The same vessel, opened a SECOND time. One open cannot see this: the --check
# pre-read resolves tailnet-proxied every run, because whether a proxy will
# publish is unanswerable until a port exists, so a staleness comparison taken
# from the pre-read never agrees with the record the allocation writes. Deciding
# it from the pre-read restarts a healthy board on every open, poll and end, and
# drops the reviewer's connected browser each time.
n_port=$(printf '%s\n' "$out" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$n_port" ] || fail "the degraded open should still emit a session link, got: $out"
n_pid=$(cat "$FM_TEST_SERVERS/$n_port.pid" 2>/dev/null)
[ -n "$n_pid" ] || fail "the degraded open should have left a board server running on $n_port"
again=$(FM_TEST_TS_MODE=userspace FM_TEST_TS_SERVE=broken FM_HOME="$HOME_N" \
  FM_SERVICE_PORT_RANGE=4801-4804 "$ROOT/bin/fm-lavish.sh" "$HOME_N/.lavish/board.html" 2>&1)
assert_not_contains "$again" "different address configuration" \
  "a vessel that degrades identically every run has not changed configuration"
assert_contains "$again" ":$n_port/session" "the second open keeps the same port"
[ "$(cat "$FM_TEST_SERVERS/$n_port.pid" 2>/dev/null)" = "$n_pid" ] \
  || fail "the healthy board server was restarted on an unchanged configuration"
alive=$(node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$n_port/health" 2>/dev/null)
[ "$alive" = 200 ] || fail "the board must still be serving after a second open"
pass "a degraded vessel reopens onto its own running board instead of restarting it every time"

# --- entry point: a publication does not outlive the board it points at ------
#
# lavish-axi stops itself after its idle timeout and immediately when the last
# session ends with nothing connected, and neither path runs a line of the
# wrapper. Serve configuration is node-wide and persistent, so it survives all
# of that and would republish whatever binds that loopback port next under this
# node's tailnet name.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_S=$(make_home "$TMP_ROOT/vessel-s")
make_serving_lavish "$HOME_S"
opened=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_S" FM_SERVICE_PORT_RANGE=4806-4807 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_S/.lavish/board.html" 2>/dev/null)
r_port=$(printf '%s\n' "$opened" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$r_port" ] || fail "the proxied open should emit a port, got: $opened"
grep -qx "$r_port" "$FM_TEST_TS_SERVE_STATE" \
  || fail "the open should have published $r_port: $(cat "$FM_TEST_TS_SERVE_STATE")"

# The negative first: a board that is still answering keeps its publication.
FM_TEST_TS_MODE=userspace FM_HOME="$HOME_S" FM_SERVICE_PORT_RANGE=4806-4807 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_S/.lavish/board.html" >/dev/null 2>&1
grep -qx "$r_port" "$FM_TEST_TS_SERVE_STATE" \
  || fail "a board that is still answering must keep its publication"

# An unrelated entry, belonging to an account this vessel cannot speak for, with
# nothing serving behind it either. The reconcile is bounded to this home's own
# recorded port, so this one has to survive untouched: a node-wide sweep is the
# same harm as withdrawing a neighbour's port, at a larger blast radius.
printf '%s\n' 8443 >> "$FM_TEST_TS_SERVE_STATE"

# Killed the way the idle self-stop ends it: without telling the wrapper.
kill "$(cat "$FM_TEST_SERVERS/$r_port.pid")" 2>/dev/null || true
rm -f "$FM_TEST_SERVERS/$r_port.pid"
for _ in $(seq 1 100); do
  node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$r_port/health" \
    >/dev/null 2>&1 || break
  sleep 0.05
done

# A different window on the next run, so nothing republishes the old port and
# only the reconcile can take it down.
FM_TEST_TS_MODE=userspace FM_HOME="$HOME_S" FM_SERVICE_PORT_RANGE=4808-4809 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_S/.lavish/board.html" >/dev/null 2>&1
! grep -qx "$r_port" "$FM_TEST_TS_SERVE_STATE" \
  || fail "a publication whose board is gone must not survive the next run: $(cat "$FM_TEST_TS_SERVE_STATE")"
grep -qx 8443 "$FM_TEST_TS_SERVE_STATE" \
  || fail "the reconcile must touch this home's own port only, never sweep the node"
pass "a publication left behind by a board that stopped itself is withdrawn, and only that one"

# --- entry point: moving off a port takes its publication with it ------------
#
# A publication made in userspace mode outlives that mode. The container can
# regain /dev/net/tun, or serve can be briefly unavailable, and the run that
# moves this vessel off the old port then resolves tailnet or loopback. Deciding
# whether to withdraw from the CURRENT run's reachability orphans exactly those,
# and the record is about to stop naming the old port, so the reconcile above
# can never reach it again - not on the next run, not after a reboot.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_X=$(make_home "$TMP_ROOT/vessel-x")
make_serving_lavish "$HOME_X"
x_first=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_X" FM_SERVICE_PORT_RANGE=4821-4822 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_X/.lavish/board.html" 2>/dev/null)
x_old=$(printf '%s\n' "$x_first" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$x_old" ] || fail "the proxied open should emit a port, got: $x_first"
grep -qx "$x_old" "$FM_TEST_TS_SERVE_STATE" \
  || fail "the proxied open should have published $x_old: $(cat "$FM_TEST_TS_SERVE_STATE")"

# Out of scope on both counts, not this home's port and not dead, so it has to
# survive the withdrawal that follows.
printf '%s\n' 8443 >> "$FM_TEST_TS_SERVE_STATE"

# This run resolves tailnet - the address binds again - so it never touches the
# proxy path of its own accord.
x_moved=$(FM_HOME="$HOME_X" FM_SERVICE_PORT_RANGE=4823-4824 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_X/.lavish/board.html" 2>&1)
assert_contains "$x_moved" "moving this vessel's boards from port $x_old" \
  "the relocation has to actually happen for this to be the orphan case"
! grep -qx "$x_old" "$FM_TEST_TS_SERVE_STATE" \
  || fail "the publication on the port this vessel just moved off is now unreachable forever: $(cat "$FM_TEST_TS_SERVE_STATE")"
grep -qx 8443 "$FM_TEST_TS_SERVE_STATE" \
  || fail "withdrawing this home's own port must not reach an entry it cannot speak for"
pass "moving off a port takes its publication with it, whatever the new run resolved"

# --- entry point: a bare stop withdraws nothing it has not proved ------------
#
# Serve configuration belongs to the whole node. A co-hosted vessel in userspace
# mode can walk its own window onto this vessel's seat and publish it, and a
# bare `stop` here resolves its port to exactly that seat with nothing proved
# about it. Withdrawing then takes a live board off the tailnet from under an
# account this vessel cannot speak for.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_W=$(make_home "$TMP_ROOT/vessel-w")
w_seat=$(field seat "$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_W" \
  FM_SERVICE_PORT_RANGE=4811-4811 "$ROOT/bin/fm-service-port.sh" lavish --check)")
[ "$w_seat" = 4811 ] || fail "a single-port window seats this vessel on 4811, got '$w_seat'"

w_ready="$TMP_ROOT/vessel-w.ready"
rm -f "$w_ready"
node "$TMP_ROOT/board-server.mjs" "$w_ready" 127.0.0.1 "$w_seat" localhost \
  </dev/null >"$TMP_ROOT/vessel-w.log" 2>&1 &
W_PID=$!
# Registered where the EXIT trap reaps it, so a failing run does not leave this
# seat held and turn the next run's first assertion into the flake.
printf '%s\n' "$W_PID" > "$FM_TEST_SERVERS/$w_seat.pid"
for _ in $(seq 1 100); do [ -s "$w_ready" ] && break; sleep 0.05; done
[ -s "$w_ready" ] || fail "the co-hosted vessel's board did not come up"
printf '%s\n' "$w_seat" > "$FM_TEST_TS_SERVE_STATE"

out=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_W" FM_SERVICE_PORT_RANGE=4811-4811 \
  "$ROOT/bin/fm-lavish.sh" stop 2>&1)
expect_code 0 "$?" "a bare stop with nothing of this vessel's own is not a failure"
assert_contains "$out" "nothing to stop" "a vessel with no board of its own has nothing to stop"
grep -qx "$w_seat" "$FM_TEST_TS_SERVE_STATE" \
  || fail "a live board this vessel cannot prove is its own was taken off the tailnet: $(cat "$FM_TEST_TS_SERVE_LOG")"
alive=$(node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$w_seat/health" 2>/dev/null)
[ "$alive" = 200 ] || fail "the co-hosted vessel's board must still be serving after the stop"
kill "$W_PID" 2>/dev/null || true
wait "$W_PID" 2>/dev/null || true
rm -f "$FM_TEST_SERVERS/$w_seat.pid"
for _ in $(seq 1 100); do
  node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$w_seat/health" \
    >/dev/null 2>&1 || break
  sleep 0.05
done

# The other half of the same rule, so the guard is a proof and not a refusal to
# act: a seat with nothing serving behind it is still withdrawn.
FM_TEST_TS_MODE=userspace FM_HOME="$HOME_W" FM_SERVICE_PORT_RANGE=4811-4811 \
  "$ROOT/bin/fm-lavish.sh" stop >/dev/null 2>&1
[ -z "$(tr -d '[:space:]' < "$FM_TEST_TS_SERVE_STATE")" ] \
  || fail "a publication with nothing behind it must still be withdrawn: $(cat "$FM_TEST_TS_SERVE_STATE")"
pass "a bare stop withdraws only a publication with nothing serving behind it"

# --- entry point: the guard asks the listener a publication forwards to ------
#
# A publication always forwards to 127.0.0.1:<port>, whatever address this run
# resolved to bind. Once a node regains kernel-mode networking it binds its own
# tailnet address instead, so a guard that only asks that address calls a
# co-hosted vessel's live proxied board silent and takes it off the tailnet.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_K=$(make_home "$TMP_ROOT/vessel-k")
k_check=$(FM_TEST_TS_MODE=kernel FM_HOME="$HOME_K" FM_SERVICE_PORT_RANGE=4836-4836 \
  "$ROOT/bin/fm-service-port.sh" lavish --check)
[ "$(field reachability "$k_check")" = tailnet ] \
  || fail "the kernel-mode fixture must bind its own address, got '$(field reachability "$k_check")'"
[ "$(field addr "$k_check")" = 127.0.0.2 ] \
  || fail "this case needs a bind address that is not the proxy's target, got '$(field addr "$k_check")'"
k_seat=$(field seat "$k_check")
[ "$k_seat" = 4836 ] || fail "a single-port window seats this vessel on 4836, got '$k_seat'"

# The co-hosted vessel's board is on loopback, which is the only place a
# publication ever points, and nowhere near the address this vessel now binds.
k_ready="$TMP_ROOT/vessel-k.ready"
rm -f "$k_ready"
node "$TMP_ROOT/board-server.mjs" "$k_ready" 127.0.0.1 "$k_seat" localhost \
  </dev/null >"$TMP_ROOT/vessel-k.log" 2>&1 &
K_PID=$!
printf '%s\n' "$K_PID" > "$FM_TEST_SERVERS/$k_seat.pid"
for _ in $(seq 1 100); do [ -s "$k_ready" ] && break; sleep 0.05; done
[ -s "$k_ready" ] || fail "the co-hosted vessel's proxied board did not come up"
printf '%s\n' "$k_seat" > "$FM_TEST_TS_SERVE_STATE"

out=$(FM_TEST_TS_MODE=kernel FM_HOME="$HOME_K" FM_SERVICE_PORT_RANGE=4836-4836 \
  "$ROOT/bin/fm-lavish.sh" stop 2>&1)
expect_code 0 "$?" "a bare stop with nothing of this vessel's own is not a failure"
assert_contains "$out" "nothing to stop" "this vessel has no board of its own to stop"
grep -qx "$k_seat" "$FM_TEST_TS_SERVE_STATE" \
  || fail "a board still serving on the port the publication forwards to was taken off the tailnet: $(cat "$FM_TEST_TS_SERVE_LOG")"
alive=$(node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$k_seat/health" 2>/dev/null)
[ "$alive" = 200 ] || fail "the co-hosted vessel's board must still be serving"
kill "$K_PID" 2>/dev/null || true
wait "$K_PID" 2>/dev/null || true
rm -f "$FM_TEST_SERVERS/$k_seat.pid"
pass "a withdrawal guard asks both the bound address and the address a proxy forwards to"

# --- entry point: closing a board never manufactures a route -----------------
#
# Publishing on allocation was written for the command that OPENS a board.
# `poll` leaves the server up and the reviewer able to reach it, so its route
# stands; `end` closes the last session and lets the server stop itself, and a
# route published for it would point at nothing and outlive the reboot.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_Z=$(make_home "$TMP_ROOT/vessel-z")
make_serving_lavish "$HOME_Z"
z_out=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_Z" FM_SERVICE_PORT_RANGE=4841-4842 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_Z/.lavish/board.html" 2>/dev/null)
z_port=$(printf '%s\n' "$z_out" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$z_port" ] || fail "the proxied open should emit a port, got: $z_out"
grep -qx "$z_port" "$FM_TEST_TS_SERVE_STATE" || fail "the open should have published $z_port"

FM_TEST_TS_MODE=userspace FM_HOME="$HOME_Z" FM_SERVICE_PORT_RANGE=4841-4842 \
  "$ROOT/bin/fm-lavish.sh" poll "$HOME_Z/.lavish/board.html" >/dev/null 2>&1
grep -qx "$z_port" "$FM_TEST_TS_SERVE_STATE" \
  || fail "a run that leaves the board serving must keep its route: $(cat "$FM_TEST_TS_SERVE_STATE")"

# Killed the way the idle timeout and the last-session-ends path end it, without
# telling the wrapper, so `end` is the ordinary next run on a board already gone.
kill "$(cat "$FM_TEST_SERVERS/$z_port.pid")" 2>/dev/null || true
rm -f "$FM_TEST_SERVERS/$z_port.pid"
for _ in $(seq 1 100); do
  node "$ROOT/bin/fm-service-port-probe.mjs" http "http://127.0.0.1:$z_port/health" \
    >/dev/null 2>&1 || break
  sleep 0.05
done

# Out of scope on both counts, so it has to survive whatever this run does.
printf '%s\n' 8443 >> "$FM_TEST_TS_SERVE_STATE"

z_end=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_Z" FM_SERVICE_PORT_RANGE=4841-4842 \
  "$ROOT/bin/fm-lavish.sh" end "$HOME_Z/.lavish/board.html" 2>&1)
[ "$(sort -u "$FM_TEST_TS_SERVE_STATE" | tr -d '[:space:]')" = 8443 ] \
  || fail "closing a board must not manufacture a route to a port nothing answers on: $(cat "$FM_TEST_TS_SERVE_STATE")"

# Not publishing is this RUN's outcome and must not be restated as a fact about
# the host. Closing a board cannot make a proxy-capable vessel unreachable, and
# saying so would send the captain hunting a network fault he does not have.
assert_not_contains "$z_end" "not reachable off this machine" \
  "closing a board must not report the host as unreachable"
assert_not_contains "$z_end" "no tailnet on this host" \
  "and must not report a tailnet this vessel plainly has as missing"
assert_not_contains "$z_end" "published onto" \
  "one run cannot both claim a route and report that none was made"
z_record="$HOME_Z/state/service-port.lavish"
assert_grep "reachability=tailnet-proxied" "$z_record" \
  "the published record keeps describing the host, which is still reachable by proxy"
assert_grep "route=none" "$z_record" \
  "and carries this run's own outcome separately"
assert_not_contains "$z_end" "was not told" \
  "a deliberate non-serving run must not describe its own choice to the captain"
pass "closing a board withdraws its route, publishes none, and still calls the host reachable by proxy"

# --- entry point: a run that starts nothing does not rewrite the owner record --
#
# state/lavish/fm-owner is what a server was LAUNCHED with, and it is the only
# input to the restart-on-mismatch comparison. A publication can vanish under a
# live board - a neighbouring account running `tailscale serve reset`, or
# tailscaled losing its serve configuration - and `end` then resolves a loopback
# link host for a server that was started with the tailnet one.

: > "$FM_TEST_TS_SERVE_STATE"
: > "$FM_TEST_TS_SERVE_LOG"
HOME_O=$(make_home "$TMP_ROOT/vessel-o")
make_serving_lavish "$HOME_O"
o_out=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_O" FM_SERVICE_PORT_RANGE=4851-4852 \
  "$ROOT/bin/fm-lavish.sh" "$HOME_O/.lavish/board.html" 2>/dev/null)
o_port=$(printf '%s\n' "$o_out" | sed -n 's|.*://[^:]*:\([0-9][0-9]*\)/session/.*|\1|p' | head -1)
[ -n "$o_port" ] || fail "the proxied open should emit a port, got: $o_out"
o_owner="$HOME_O/state/lavish/fm-owner"
assert_grep "link_host=192.0.2.1" "$o_owner" "the open records the link host it launched the server with"

# The route disappears from under the still-running board.
: > "$FM_TEST_TS_SERVE_STATE"
FM_TEST_TS_MODE=userspace FM_HOME="$HOME_O" FM_SERVICE_PORT_RANGE=4851-4852 \
  "$ROOT/bin/fm-lavish.sh" end "$HOME_O/.lavish/board.html" >/dev/null 2>&1
assert_grep "link_host=192.0.2.1" "$o_owner" \
  "a run that launched no server must not record a link host no server was started with"

# The proof it matters: the next run that DOES serve republishes, resolves the
# tailnet link host again, and must find the record it left agreeing with it.
o_poll=$(FM_TEST_TS_MODE=userspace FM_HOME="$HOME_O" FM_SERVICE_PORT_RANGE=4851-4852 \
  "$ROOT/bin/fm-lavish.sh" poll "$HOME_O/.lavish/board.html" 2>&1)
assert_not_contains "$o_poll" "different address configuration" \
  "a healthy board must not be torn down over a mismatch a non-serving run invented"
pass "only a run that launches a server records what it was launched with"

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
