#!/usr/bin/env bash
# Resolve one vessel-local service's reachable address and a port it can
# actually bind, on a machine that may carry several vessels as separate UNIX
# accounts.
#
# This is a GENERAL allocator. Lavish review boards are its first consumer
# (bin/fm-lavish.sh), not its subject: any vessel-local service has the same
# problem, so nothing here knows what the service does.
#
# Two rules this script exists to enforce, both learned the hard way:
#
#   1. A successful bind is the ONLY proof a port is free. No registry file can
#      stop another UNIX account's process from taking a port, so this script
#      never consults a record to decide availability - it probes
#      (bin/fm-service-port-probe.mjs) and treats EADDRINUSE as authoritative.
#      The record it writes afterwards is a published fact, not a reservation.
#   2. Nothing is emitted that implies reach the vessel has not established.
#      With no usable tailnet this prints reachability=loopback with a concrete
#      reason instead of a tailnet address the consumer would put into a link
#      that opens nothing off this machine.
#
# There is a third case between those two, and it is a real vessel rather than a
# hypothetical one: a node that HAS a tailnet address it cannot bind. In
# userspace networking mode - no /dev/net/tun, no NET_ADMIN - tailscaled runs
# its own network stack, so the node is genuinely on the tailnet while no local
# interface carries its address and every bind on it fails EADDRNOTAVAIL. That
# is neither "tailnet" (nothing here can listen on the address) nor "loopback"
# (the vessel really is reachable from the captain's devices), so it is named
# and served on its own terms: reachability=tailnet-proxied, the port bound on
# loopback, and that port published onto the tailnet address with
# `tailscale serve` (bin/fm-tailnet-serve-lib.sh owns that mechanism) for a
# caller that said with --serving it will leave a service listening there.
#
# Usage:
#   fm-service-port.sh <service> [--mine <port>]... [--serving] [--check]
#
#   <service>   lowercase slug naming the service, e.g. lavish
#   --mine      a port the CALLER has already proved it owns and is still using.
#               The first such port is returned unprobed, because probing a port
#               you are yourself listening on would report a false collision.
#               The ownership proof belongs to the caller; this script does not
#               and cannot verify it.
#   --serving   this run WILL leave a service listening on the returned port.
#               It is the only thing that authorises publishing a proxy under
#               reachability=tailnet-proxied, and it is the caller's statement to
#               make because only the caller knows what it is about to run. A
#               publication is node-wide and survives a reboot, so a run that
#               closes a service, or only inspects one, must not leave a route
#               pointing at a port nothing answers on. It changes route=, never
#               reachability=: whether THIS run published a route says nothing
#               about whether the host can be reached by proxy, and a run that
#               finds a route somebody else already published reports it, because
#               reading a route is not making one.
#   --check     resolve identity and reachability only. No bind is attempted and
#               no record is written, so no port is claimed: the output carries
#               seat= (the deterministic preference) and no port= at all.
#
# Output: key=value lines on stdout, exit 0.
#
#   service=lavish
#   vessel=coditan
#   machine=crew-hlr
#   dnsname=crew-hlr.tail7b8448.ts.net
#   addr=100.121.172.63
#   tailaddr=100.121.172.63
#   seat=4413
#   window=4400-4499
#   port=4413
#   reachability=tailnet
#   route=
#   reason=
#
#   machine     tailnet node name, the only fleet-unique machine identity
#               available; unknown-<vessel> when there is no tailnet, so a
#               machine that cannot be identified is never silently treated as
#               a distinct one.
#   addr        the address the service must BIND. It is the tailnet address
#               under reachability=tailnet, and 127.0.0.1 under both
#               tailnet-proxied and loopback, so a consumer always binds what
#               this names without inspecting the reachability first.
#   tailaddr    this node's own tailnet address whenever one was resolved, even
#               when it could not be bound. Empty with no usable tailnet. It is
#               a reachable link target under tailnet-proxied, because the
#               published proxy answers on it.
#   dnsname     the hostname a link may use. Set ONLY when it resolves over IPv4
#               to tailaddr, this node's own tailnet address, so a consumer
#               never writes a name into a URL without that name having been
#               checked. Empty means "use the address the link would otherwise
#               name": tailaddr under tailnet-proxied, where addr is loopback
#               and naming it would emit a link that opens nowhere, and addr
#               under tailnet and loopback, where the two are the same answer.
#               Cleared whenever no reach off this machine was established, so a
#               name is never offered on the loopback degrade.
#   reachability
#               tailnet          the address is this node's own and was bound.
#               tailnet-proxied  the node has a tailnet address it cannot bind,
#                                so the port is bound on loopback and reached
#                                over that address through a `tailscale serve`
#                                route. Links use the tailnet name or address
#                                once route=published says one exists, because
#                                that is where the service genuinely answers.
#                                That publication is node-wide and survives both
#                                this process and a reboot, so the consumer
#                                INHERITS the obligation to take it down with
#                                fm_tailnet_serve_withdraw when its service
#                                stops; bin/fm-tailnet-serve-lib.sh owns that
#                                mechanism and states what a caller must have
#                                proved before touching a port.
#               loopback         no reach off this machine was established.
#
#               This describes the HOST and never this run. A vessel that can be
#               reached by proxy stays tailnet-proxied on a run that published no
#               route at all; read route= for what the run itself did.
#
#               A run that neither published a route nor found one already
#               published has TESTED nothing about proxy capability, so it never
#               asserts tailnet-proxied on its own: it carries forward whatever
#               a previous allocation established, and claims loopback when there
#               is nothing to carry.
#   route       whether a `tailscale serve` route onto tailaddr exists for this
#               port. Only meaningful under reachability=tailnet-proxied, and
#               empty otherwise, including under --check, where there is no port
#               to route yet.
#               published        a route is in place, so a link may name the
#                                tailnet, and whoever holds the port owes its
#                                withdrawal.
#               none             no route exists for this port: this run was not
#                                told with --serving that it would leave a
#                                service listening, so it made none, and none was
#                                already in place. A link must not name the
#                                tailnet until a serving run publishes one.
#   seat        the deterministic preferred port for this service in this home.
#   port        the port actually bound (absent under --check).
#   reason      empty when fully nominal; otherwise one plain sentence naming
#               the concrete thing that is missing or degraded.
#
# Exit codes:
#   0  resolved
#   1  no port in the window could be bound: every candidate is held by another
#      process, or some were refused by this host (a privileged port, say). Both
#      are port-scoped, and the probe's own line counts how many candidates fell
#      into each case and names the errnos, so neither is asserted for the other.
#   2  usage error
#   3  no port was ever contended, which is what separates this from 1: the
#      probe runtime is unavailable, or the address stopped being bindable
#      partway through the window walk after the address probe had already
#      passed. A resolved address that cannot be bound AND cannot be published
#      over `tailscale serve` is NOT this - it degrades to a successful loopback
#      allocation carrying that diagnosis, so a consumer reads it from
#      reachability=loopback rather than from an exit code.
#
# The port window defaults to 4400-4499: above lavish-axi's compiled-in 4387
# default so a stray bare invocation never lands on an allocated seat, and far
# below the ephemeral range. Override with FM_SERVICE_PORT_RANGE=<start>-<end>.
#
# The record is written to FM_HOME/state/service-port.<service>. Read it to see
# who holds what; never read it to decide whether a port is free.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROBE="$SCRIPT_DIR/fm-service-port-probe.mjs"

# shellcheck source=bin/fm-tailnet-serve-lib.sh
. "$SCRIPT_DIR/fm-tailnet-serve-lib.sh"

die() {
  printf 'SERVICE_PORT: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  cat <<'EOF'
Usage: fm-service-port.sh <service> [--mine <port>]... [--serving] [--check]

Prints key=value lines describing this vessel's reachable address and a port it
actually bound for <service>. --check resolves identity and reachability only
and claims no port. --serving states that this run will leave a service
listening, which is what authorises publishing a proxy. See the script header
for the full contract.
EOF
}

SERVICE=""
CHECK_ONLY=0
SERVING=0
MINE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --serving)
      SERVING=1
      shift
      ;;
    --mine)
      [ "$#" -gt 1 ] || die "--mine requires a port"
      MINE="$MINE $2"
      shift 2
      ;;
    --mine=*)
      MINE="$MINE ${1#--mine=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown argument: $1"
      ;;
    *)
      [ -z "$SERVICE" ] || { usage >&2; die "unexpected argument: $1"; }
      SERVICE=$1
      shift
      ;;
  esac
done

[ -n "$SERVICE" ] || { usage >&2; die "a service name is required"; }
case "$SERVICE" in
  [a-z0-9]|[a-z0-9][a-z0-9-]*) ;;
  *) die "service name must be a lowercase slug: $SERVICE" ;;
esac

# --- identity ---------------------------------------------------------------

# The vessel id names the fleet member. It is NOT sufficient on its own to
# separate a secondmate from its parent: they share both the id and the UNIX
# account, so the realpath of FM_HOME is what actually separates their seats.
resolve_vessel() {
  local raw=""
  if [ -n "${FM_BRIDGE_VESSEL:-}" ]; then
    raw=${FM_BRIDGE_VESSEL%% *}
  elif [ -r "$CONFIG/bridge-vessel" ]; then
    raw=$(tr -s '[:space:]' ' ' < "$CONFIG/bridge-vessel" 2>/dev/null || true)
    raw=${raw## }
    raw=${raw%% *}
  fi
  [ -n "$raw" ] || raw=$(basename -- "$FM_HOME")
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  raw=${raw%%-}
  [ -n "$raw" ] || raw=vessel
  printf '%s\n' "$raw"
}

VESSEL=$(resolve_vessel)
HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || HOME_REAL=$FM_HOME

# --- address ----------------------------------------------------------------
#
# Everything below is read from the running tailscale at runtime. Nothing
# vessel-specific is compiled in, so this resolves correctly on every vessel
# including secondmate homes.

ADDR=""
TAILADDR=""
DNSNAME=""
MACHINE=""
REACHABILITY=loopback
ROUTE=""
REASON=""

# Several independent facts can degrade one resolution at once - an unresolvable
# name on a node that also cannot bind its own address, say - and dropping
# either would hand the reader half a diagnosis.
add_reason() {
  if [ -z "$REASON" ]; then
    REASON=$1
  else
    REASON="$REASON; $1"
  fi
}

tailscale_json() {
  command -v jq >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null
}

resolve_tailnet() {
  local json state addr host suffix dnsname
  command -v tailscale >/dev/null 2>&1 || {
    add_reason "tailscale is not installed on this host"
    return 1
  }
  json=$(tailscale_json) || {
    add_reason "tailscale status could not be read as JSON (jq missing or tailscale not responding)"
    return 1
  }
  [ -n "$json" ] || {
    add_reason "tailscale status returned nothing"
    return 1
  }
  state=$(printf '%s' "$json" | jq -r '.BackendState // empty' 2>/dev/null)
  [ "$state" = "Running" ] || {
    add_reason "tailscale is installed but not running (backend state: ${state:-unknown})"
    return 1
  }
  addr=$(printf '%s' "$json" | jq -r '[.Self.TailscaleIPs // [] | .[] | select(test("^[0-9]+\\.")) ] | first // empty' 2>/dev/null)
  case "$addr" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *)
      add_reason "tailscale reports no IPv4 address for this node"
      return 1
      ;;
  esac
  host=$(printf '%s' "$json" | jq -r '.Self.HostName // empty' 2>/dev/null)
  suffix=$(printf '%s' "$json" | jq -r '.MagicDNSSuffix // empty' 2>/dev/null)
  dnsname=$(printf '%s' "$json" | jq -r '.Self.DNSName // empty' 2>/dev/null)
  dnsname=${dnsname%.}
  [ -n "$dnsname" ] || { [ -z "$host" ] || [ -z "$suffix" ] || dnsname="$host.$suffix"; }
  ADDR=$addr
  TAILADDR=$addr
  MACHINE=$host
  REACHABILITY=tailnet
  # A name is only worth writing into a link once it has been checked, so an
  # unresolvable or misdirected name degrades to the bare address with a reason
  # rather than becoming a URL that fails on the captain's device. A name that
  # could not be checked at all is a different fact from one that was checked
  # and pointed elsewhere, and saying the second when the first happened would
  # hand the reader a concrete diagnosis that is simply untrue.
  if [ -n "$dnsname" ]; then
    if ! command -v node >/dev/null 2>&1 || [ ! -f "$PROBE" ]; then
      add_reason "the tailnet name $dnsname could not be checked here (node or $PROBE is unavailable), so links use the address instead"
    elif node "$PROBE" resolve "$dnsname" "$addr" >/dev/null 2>&1; then
      DNSNAME=$dnsname
    else
      add_reason "the tailnet name $dnsname does not resolve to $addr here, so links use the address instead"
    fi
  fi
  return 0
}

if ! resolve_tailnet; then
  ADDR=127.0.0.1
  TAILADDR=""
  DNSNAME=""
  REACHABILITY=loopback
  MACHINE=""
fi
[ -n "$MACHINE" ] || MACHINE="unknown-$VESSEL"

# --- can this node actually bind the address it was given? -------------------
#
# A resolved tailnet address is not yet a bindable one. Asked here with an
# ephemeral port rather than discovered halfway through a window walk, so the
# answer is available to --check too - a consumer decides its bind address and
# its link host before it ever claims a port, and would otherwise probe an
# address nothing can listen on.

# Only exit 4 answers this question. The probe separates an address that cannot
# be bound here from a bind that failed for a port-scoped reason - EPERM,
# ENOTSUP, fd pressure - which says nothing about the address either way, and
# exit 2 is a usage error rather than a verdict at all. Reading any non-zero as
# unbindable would rebind a healthy kernel-mode vessel on loopback, publish a
# node-wide serve entry it never needed, and tell it its address fails
# EADDRNOTAVAIL in userspace mode, which would simply not be true. Anything but
# 4 falls through to the window walk, which reports what it actually met.

if [ "$REACHABILITY" = tailnet ]; then
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$PROBE" ]; then
    : # Nothing to check with. The window walk below still reports honestly.
  else
    node "$PROBE" addr "$ADDR" >/dev/null 2>&1
    ADDR_PROBE_STATUS=$?
  fi
  if [ "${ADDR_PROBE_STATUS:-0}" -eq 4 ]; then
    if fm_tailnet_serve_available; then
      REACHABILITY=tailnet-proxied
      ADDR=127.0.0.1
      add_reason "this node has the tailnet address $TAILADDR but no local interface carries it (bind fails EADDRNOTAVAIL), which is what tailscale userspace networking mode looks like, so a port cannot be bound on that address and is bound on loopback instead"
    else
      REACHABILITY=loopback
      ADDR=127.0.0.1
      DNSNAME=""
      add_reason "this node has the tailnet address $TAILADDR but no local interface carries it (bind fails EADDRNOTAVAIL) and tailscale serve is not available to publish a loopback port onto it, so nothing here is reachable off this machine"
    fi
  fi
fi

# --- window and deterministic seat ------------------------------------------

WINDOW_START=4400
WINDOW_END=4499
if [ -n "${FM_SERVICE_PORT_RANGE:-}" ]; then
  case "$FM_SERVICE_PORT_RANGE" in
    [0-9]*-[0-9]*)
      WINDOW_START=${FM_SERVICE_PORT_RANGE%%-*}
      WINDOW_END=${FM_SERVICE_PORT_RANGE##*-}
      ;;
    *) die "FM_SERVICE_PORT_RANGE must be <start>-<end>: $FM_SERVICE_PORT_RANGE" ;;
  esac
fi
if [ "$WINDOW_START" -lt 1 ] || [ "$WINDOW_END" -gt 65535 ] || [ "$WINDOW_START" -gt "$WINDOW_END" ]; then
  die "port window $WINDOW_START-$WINDOW_END is not a usable range"
fi
WINDOW_SIZE=$((WINDOW_END - WINDOW_START + 1))

# FM_HOME's realpath is in the key, not just the vessel id, because a secondmate
# home shares both the id and the UNIX account with its parent - exactly the
# case that must not collide.
SEAT_KEY=$(printf '%s\n%s\n%s\n' "$SERVICE" "$VESSEL" "$HOME_REAL")
SEAT_SUM=$(printf '%s' "$SEAT_KEY" | cksum | awk '{print $1}')
[ -n "$SEAT_SUM" ] || die "could not derive a deterministic seat (cksum unavailable)" 3
SEAT=$((WINDOW_START + SEAT_SUM % WINDOW_SIZE))

# The resolution a previous allocation for this service recorded, and nothing
# else from that file. Empty when there is no readable record to carry forward.
recorded_reachability() {
  local record="$STATE/service-port.$SERVICE"
  [ -r "$record" ] || return 0
  sed -n 's/^reachability=\(.*\)$/\1/p' "$record" | head -1
}

emit() {
  printf 'service=%s\n' "$SERVICE"
  printf 'vessel=%s\n' "$VESSEL"
  printf 'machine=%s\n' "$MACHINE"
  printf 'dnsname=%s\n' "$DNSNAME"
  printf 'addr=%s\n' "$ADDR"
  printf 'tailaddr=%s\n' "$TAILADDR"
  printf 'seat=%s\n' "$SEAT"
  printf 'window=%s-%s\n' "$WINDOW_START" "$WINDOW_END"
  [ -z "${1:-}" ] || printf 'port=%s\n' "$1"
  printf 'reachability=%s\n' "$REACHABILITY"
  printf 'route=%s\n' "$ROUTE"
  printf 'reason=%s\n' "$REASON"
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  emit
  exit 0
fi

# --- a port the caller already owns -----------------------------------------

for candidate in $MINE; do
  case "$candidate" in
    ''|*[!0-9]*) die "--mine must be a port number: $candidate" ;;
  esac
  if [ "$candidate" -ge 1 ] && [ "$candidate" -le 65535 ]; then
    PORT=$candidate
    break
  fi
  die "--mine must be a port number: $candidate"
done

# --- bind ------------------------------------------------------------------

if [ -z "${PORT:-}" ]; then
  command -v node >/dev/null 2>&1 || die "node is required to prove a port is free" 3
  [ -f "$PROBE" ] || die "port probe is missing: $PROBE" 3

  CANDIDATES=""
  offset=0
  while [ "$offset" -lt "$WINDOW_SIZE" ]; do
    next=$((WINDOW_START + (SEAT - WINDOW_START + offset) % WINDOW_SIZE))
    CANDIDATES="$CANDIDATES $next"
    offset=$((offset + 1))
  done

  # The probe's stderr is deliberately not discarded: it is silent on success,
  # and on failure it is the only thing that names the concrete errnos.
  # shellcheck disable=SC2086
  PORT=$(node "$PROBE" bind "$ADDR" $CANDIDATES)
  probe_status=$?
  case "$probe_status" in
    0) ;;
    3)
      die "no free port in $WINDOW_START-$WINDOW_END on $ADDR for $SERVICE; every candidate is held by another process, so $SERVICE cannot start until one is released or FM_SERVICE_PORT_RANGE names a different window" 1
      ;;
    4)
      die "$ADDR cannot be bound on this host, so $SERVICE has no address to serve on; re-check the network interface before treating this as a port collision" 3
      ;;
    5)
      die "no bindable port in $WINDOW_START-$WINDOW_END on $ADDR for $SERVICE; the port probe's line above counts how many candidates were held and how many this host refused, and names the errnos, so read it before deciding whether the window or the account's permissions is what has to change" 1
      ;;
    *)
      die "the port probe failed for $SERVICE on $ADDR (exit $probe_status)" 3
      ;;
  esac
  case "$PORT" in
    ''|*[!0-9]*) die "the port probe returned no usable port for $SERVICE on $ADDR" 3 ;;
  esac
fi

# --- publish the proxy ------------------------------------------------------
#
# Only now, because the proxy has to name the port that was actually bound: the
# published port and the loopback port are the same number so a consumer's own
# link, which carries its bound port, answers unchanged. A failure here is not
# reported as reach, because it is not reach.
#
# And only for a caller that said it will leave a service listening. A
# publication belongs to the whole tailscale node and outlives this process and
# the machine's next reboot, so a run that closes a service or merely inspects
# one would otherwise manufacture a permanent route to a port nothing answers
# on. A port somebody else already published is a different matter: reading that
# route is not making one, so it is still reported as the route it is.
#
# What that choice may NOT do is change reachability, which is a fact about the
# host and not about this run: a node that can be reached by proxy is still
# tailnet-proxied on a run that publishes nothing. The run's own outcome is
# route=, so a reader can tell "this host is reachable by proxy" apart from
# "this run made no route". A proxy that could not be published AT ALL is the
# one case that does move reachability, because then the host really has no
# reach to describe.

if [ "$REACHABILITY" = tailnet-proxied ]; then
  if [ "$SERVING" -eq 1 ]; then
    if fm_tailnet_serve_publish "$PORT"; then
      ROUTE=published
    else
      REACHABILITY=loopback
      DNSNAME=""
      add_reason "publishing port $PORT onto $TAILADDR with tailscale serve failed, so this board is reachable only on this machine"
    fi
  elif fm_tailnet_serve_published "$PORT"; then
    ROUTE=published
  else
    ROUTE=none
    # This run published nothing and found nothing published, so it has tested
    # NOTHING about whether this node can be proxied at all: fm_tailnet_serve_available
    # reports only that tailscaled is running, and publishability is unanswerable
    # until a publish is actually attempted. Asserting tailnet-proxied from it
    # would overwrite a host fact that a run which DID attempt one established -
    # on a vessel whose serve cannot publish, that revives a session-start notice
    # offering a remedy which only degrades to the same link again, and tells the
    # fleet registry a vessel with no reach off the machine is proxy-reachable.
    #
    # Reading the record here is not the read this script forbids. What may never
    # be read from it is whether a PORT is free, which only a successful bind
    # answers; the resolution a previous allocation established is a different
    # question, and carrying it forward is what stops an untested run overwriting
    # a tested one.
    PRIOR=$(recorded_reachability)
    if [ "$PRIOR" != tailnet-proxied ]; then
      REACHABILITY=loopback
      DNSNAME=""
      add_reason "no tailscale serve route onto $TAILADDR has been established for $SERVICE, so no reach off this machine is claimed until one is"
    fi
  fi
fi

# --- published record -------------------------------------------------------
#
# Written after the fact, never consulted to decide availability.

RECORD="$STATE/service-port.$SERVICE"
if mkdir -p "$STATE" 2>/dev/null; then
  {
    printf '# PUBLISHED RECORD, NOT A LOCK.\n'
    printf '# Nothing may treat this port as reserved and no allocator may read this\n'
    printf '# file to decide whether a port is free. The only proof that a port is\n'
    printf '# available is a successful bind. This exists so a human or an agent can\n'
    printf '# see who holds what, and can spot a collision after the fact.\n'
    printf '# Written by bin/fm-service-port.sh.\n'
    emit "$PORT"
    printf 'home=%s\n' "$HOME_REAL"
    printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RECORD.tmp.$$" 2>/dev/null && mv -f "$RECORD.tmp.$$" "$RECORD" 2>/dev/null
  rm -f "$RECORD.tmp.$$" 2>/dev/null || true
fi

emit "$PORT"
exit 0
