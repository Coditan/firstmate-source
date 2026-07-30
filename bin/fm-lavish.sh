#!/usr/bin/env bash
# The one entry point every agent uses to open a Lavish review board, instead of
# bare `lavish-axi`.
#
# A bare `lavish-axi` binds loopback and writes http://127.0.0.1:<port>/... into
# the link it hands the captain. That link opens nothing on his PC or phone, and
# it fails silently: the board looks fine on the machine that made it. This
# wrapper resolves this host's own tailnet address at runtime, takes a port no
# other vessel on this machine is using, restricts the Host allowlist to this
# vessel's own names, and emits a link that has been checked before it is
# handed over.
#
# Documentation could not fix this. A profile export never reaches an agent's
# non-interactive shell, and it had already failed here once. So the mechanism
# is this script plus the PreToolUse guard that denies bare `lavish-axi`
# (bin/fm-lavish-pretool-check.sh), not a note somebody has to remember.
#
# Usage:
#   fm-lavish.sh <html-file>            open or resume a board
#   fm-lavish.sh poll <html-file>       wait for reviewer feedback
#   fm-lavish.sh end <html-file>        end the session
#   fm-lavish.sh stop                   stop THIS vessel's board server
#   fm-lavish.sh <any other lavish-axi arguments...>
#   fm-lavish.sh --fm-help              this help
#
# Every argument except the wrapper's own --fm-* flags is passed through
# untouched, so `poll`, `end`, `export`, and `stop` all resolve the same server
# as the invocation that opened the board. A wrapper that fronted only the open
# call would leave every follow-up pointed at the compiled-in default port.
#
# `stop --port <n>` is held to exactly the same ownership proof as a bare
# `stop`: the claim token has to answer on <n> first. lavish-axi's own stop path
# shuts down any server that answers /health with a lavish-axi body, and every
# vessel on this machine binds this same address, so an explicitly named port
# that was never proved would be a neighbour's board. An unproven port that is
# serving is refused by name; one that answers nothing at all is reported as
# nothing to stop.
#
# What it sets, and why each one is needed:
#   LAVISH_AXI_HOST            the tailnet address, so the server is reachable
#                              off this machine. Never a wildcard: an
#                              all-interfaces bind is broader than the captain
#                              approved.
#   LAVISH_AXI_PORT            a port proved free by bin/fm-service-port.sh, so
#                              vessels sharing this machine do not collide.
#   LAVISH_AXI_LINK_HOST       the hostname written into the link. The tailnet
#                              DNS name only after it has been confirmed to
#                              resolve to the bound address; otherwise the
#                              address itself.
#   LAVISH_AXI_ALLOWED_HOSTS   this vessel's tailnet DNS name, its short node
#                              name, its address, and this home's claim token.
#                              Never "*".
#   LAVISH_AXI_STATE_DIR       FM_HOME/state/lavish, so a secondmate home does
#                              not share one server and one session store with
#                              its parent, which shares its UNIX account.
#
# The claim token is a per-home random name in the Host allowlist. It is how
# this wrapper answers "is the server on my port MY server", which no health
# body can answer: every lavish-axi reports the same {ok, app, version}, so a
# neighbouring UNIX account's server on the same port is silently adopted
# otherwise. It adds no exposure - anyone who can already reach the port can
# already reach it under the address - it only makes one specific Host header
# identify one specific home's server.
#
# Honest degradation, in every branch:
#   - No usable tailnet: this says so in one plain sentence and falls back to
#     loopback. The board still opens locally and is never presented as
#     reachable.
#   - The link host does not answer after the board opens: this says so and
#     names the address form that does work.
#   - No free port in the window: bin/fm-service-port.sh refuses. There is no
#     silent loopback downgrade, because that would reproduce the original bug
#     somewhere new.
#
# `share` publishes the board to a third-party host. Review boards carry fleet
# names, security findings, and captain decisions, so it is refused unless
# --fm-allow-share (or FM_LAVISH_ALLOW_SHARE=1) makes the intent explicit. The
# refusal names the override; it does not remove the capability.
#
# Not solved here, and stated rather than implied: a board is an
# unauthenticated server that anything on the tailnet can read. That is the
# fleet's existing trust boundary, and this script does not widen it - but it
# does not close it either.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROBE="$SCRIPT_DIR/fm-service-port-probe.mjs"
LAV_STATE="$STATE/lavish"
OWNER="$LAV_STATE/fm-owner"
TOKEN_FILE="$LAV_STATE/claim-token"

# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"

note() { printf 'fm-lavish: %s\n' "$1" >&2; }
die() { note "$1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Usage: fm-lavish.sh <html-file>                 open or resume a review board
       fm-lavish.sh poll <html-file>            wait for reviewer feedback
       fm-lavish.sh end <html-file>             end the session
       fm-lavish.sh stop                        stop this vessel's board server
       fm-lavish.sh <lavish-axi arguments...>   anything else, passed through
       fm-lavish.sh --fm-help                   this help

Opens Lavish review boards on this vessel's own tailnet address and a port no
other vessel on this machine is using, so the link works on the captain's own
devices instead of only on this machine. --fm-allow-share is required before
`share` will publish a board to third-party hosting. Read this script's header
for the full contract.
EOF
}

# --- wrapper flags ----------------------------------------------------------

ALLOW_SHARE=${FM_LAVISH_ALLOW_SHARE:-0}
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --fm-allow-share) ALLOW_SHARE=1 ;;
    --fm-help) usage; exit 0 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
  usage >&2
  exit 2
fi

# Mirror lavish-axi's own dispatch: a first argument that is not a known
# subcommand is a file, which means the default open command.
SUBCOMMAND=open
EXPLICIT_PORT=0
EXPLICIT_PORT_VALUE=""
first=1
want_port=0
for arg in "${ARGS[@]}"; do
  if [ "$first" -eq 1 ]; then
    first=0
    case "$arg" in
      poll|end|stop|server|playbook|design|setup|export|share|open) SUBCOMMAND=$arg ;;
    esac
  fi
  if [ "$want_port" -eq 1 ]; then
    EXPLICIT_PORT_VALUE=$arg
    want_port=0
    continue
  fi
  case "$arg" in
    --port) EXPLICIT_PORT=1; want_port=1 ;;
    --port=*) EXPLICIT_PORT=1; EXPLICIT_PORT_VALUE=${arg#--port=} ;;
  esac
done

if [ "$SUBCOMMAND" = share ] && [ "$ALLOW_SHARE" != 1 ]; then
  die "refusing to publish this board to third-party hosting: review boards carry fleet names, security findings, and captain decisions, and the transport is meant to stay inside the tailnet. Pass --fm-allow-share (or set FM_LAVISH_ALLOW_SHARE=1) if this particular board is genuinely not private." 3
fi

# Commands that can start a server need a port that was actually proved free.
# The rest must never trigger an allocation, because claiming a port they will
# not use is how a window fills up with nothing.
case "$SUBCOMMAND" in
  open|poll|end|server) NEEDS_PORT=1 ;;
  *) NEEDS_PORT=0 ;;
esac

# The vessel's own AXI prefix wins over whatever PATH resolves, so a home always
# drives its own installed lavish-axi. Resolved after the wrapper's own flags so
# --fm-help and the share refusal still work on a vessel that has no lavish-axi.
LAVISH=$(fm_axi_bin_dir 2>/dev/null)/lavish-axi
[ -x "$LAVISH" ] || LAVISH=$(command -v lavish-axi 2>/dev/null) \
  || die "lavish-axi is not installed for this vessel" 6

# --- identity ---------------------------------------------------------------

if ! IDENTITY=$("$SCRIPT_DIR/fm-service-port.sh" lavish --check 2>&1); then
  printf '%s\n' "$IDENTITY" >&2
  die "could not resolve this vessel's address for review boards" 4
fi

ADDR=""; DNSNAME=""; MACHINE=""; SEAT=""; WINDOW=""; REACHABILITY=""; REASON=""
while IFS='=' read -r key value; do
  case "$key" in
    addr) ADDR=$value ;;
    dnsname) DNSNAME=$value ;;
    machine) MACHINE=$value ;;
    seat) SEAT=$value ;;
    window) WINDOW=$value ;;
    reachability) REACHABILITY=$value ;;
    reason) REASON=$value ;;
  esac
done <<EOF
$IDENTITY
EOF

[ -n "$ADDR" ] && [ -n "$SEAT" ] || die "the address resolver returned no usable address" 4

LINK_HOST=${DNSNAME:-$ADDR}

# --- claim token ------------------------------------------------------------

mkdir -p "$LAV_STATE" 2>/dev/null || die "cannot create the board state directory $LAV_STATE" 4
if [ -s "$TOKEN_FILE" ]; then
  CLAIM_TOKEN=$(tr -dc 'a-z0-9-' < "$TOKEN_FILE" 2>/dev/null | head -c 64)
fi
if [ -z "${CLAIM_TOKEN:-}" ]; then
  raw=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -dc 'a-f0-9')
  [ -n "$raw" ] || raw=$(printf '%s%s' "$$" "$(date +%s)" | cksum | awk '{print $1}')
  CLAIM_TOKEN="fm-claim-$raw"
  ( umask 077; printf '%s\n' "$CLAIM_TOKEN" > "$TOKEN_FILE" ) 2>/dev/null \
    || die "cannot write this home's board claim token" 4
fi

ALLOWED="$LINK_HOST $ADDR $CLAIM_TOKEN"
[ "$REACHABILITY" != tailnet ] || [ -z "$MACHINE" ] || ALLOWED="$MACHINE $ALLOWED"

# --- is the server on our recorded port actually ours ------------------------
#
# A bind probe cannot answer this: a port we are ourselves listening on always
# reports as taken. The claim token can, and it is the only check here that
# distinguishes our server from a same-version one belonging to another UNIX
# account on this machine.

port_is_ours() {
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$PROBE" ] || return 1
  node "$PROBE" http "http://$ADDR:$1/health" "$CLAIM_TOKEN" >/dev/null 2>&1
}

# Deliberately without the token: it separates "a board is serving here and it
# is not ours" from "nothing is serving here at all", which are different facts
# and deserve different answers.
port_answers() {
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$PROBE" ] || return 1
  node "$PROBE" http "http://$ADDR:$1/health" >/dev/null 2>&1
}

owned_port() {
  local record="$STATE/service-port.lavish" recorded=""
  [ -r "$record" ] || return 1
  recorded=$(sed -n 's/^port=\([0-9][0-9]*\)$/\1/p' "$record" | head -1)
  [ -n "$recorded" ] || return 1
  port_is_ours "$recorded" || return 1
  printf '%s\n' "$recorded"
}

owner_field() {
  [ -r "$OWNER" ] || return 1
  sed -n "s/^$1=\(.*\)$/\1/p" "$OWNER" | head -1
}

# A port outside the currently resolved window is as stale as a changed link
# host: an operator who narrows the window to move this service off a conflict
# would otherwise keep the old port forever, because it is still legitimately
# ours.
in_window() {
  local port=$1 start=${WINDOW%%-*} end=${WINDOW##*-}
  case "$start$end" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
}

stop_server() {
  # Safe only because the claim token has already proved this process is this
  # home's; the same call against an unproven port could shut down a neighbour.
  LAVISH_AXI_HOST=$ADDR LAVISH_AXI_PORT=$1 \
    "$LAVISH" stop --port "$1" >/dev/null 2>&1 || true
}

MINE=""
STALE_SAME_PORT=""
RELOCATE_FROM=""
PROVEN=$(owned_port) || PROVEN=""
if [ -n "$PROVEN" ]; then
  # The running server emits the link host it was born with, so a changed link
  # host is a stale server rather than a reusable one.
  if [ "$(owner_field link_host || true)" = "$LINK_HOST" ] \
    && [ "$(owner_field allowed || true)" = "$ALLOWED" ] \
    && in_window "$PROVEN"; then
    MINE=$PROVEN
  elif in_window "$PROVEN"; then
    # Same port wanted, new configuration: stopping first is what frees the seat
    # to be reclaimed immediately.
    STALE_SAME_PORT=$PROVEN
  else
    # A different port is wanted, so the working board must survive until a
    # replacement is actually secured. Tearing it down first would turn a failed
    # move into a lost board.
    RELOCATE_FROM=$PROVEN
  fi
fi

# --- port -------------------------------------------------------------------

if [ "$NEEDS_PORT" -eq 1 ] && [ -n "$STALE_SAME_PORT" ]; then
  note "the running board server was started with a different address configuration; restarting it so links are correct"
  stop_server "$STALE_SAME_PORT"
fi

PORT=""
if [ "$NEEDS_PORT" -eq 1 ]; then
  ALLOCATE=("$SCRIPT_DIR/fm-service-port.sh" lavish)
  [ -z "$MINE" ] || ALLOCATE+=(--mine "$MINE")
  if ! RECORD=$("${ALLOCATE[@]}" 2>&1); then
    printf '%s\n' "$RECORD" >&2
    [ -z "$RELOCATE_FROM" ] \
      || note "the board already serving on port $RELOCATE_FROM was left running, so nothing was lost"
    die "no port is available for a review board on this vessel, so no board was opened" 5
  fi
  PORT=$(printf '%s\n' "$RECORD" | sed -n 's/^port=\([0-9][0-9]*\)$/\1/p' | head -1)
  [ -n "$PORT" ] || die "the port allocator returned no port" 5
  if [ -n "$RELOCATE_FROM" ]; then
    note "moving this vessel's boards from port $RELOCATE_FROM to $PORT; links already handed over on the old port stop working"
    stop_server "$RELOCATE_FROM"
  fi
else
  PORT=${MINE:-${PROVEN:-$SEAT}}
fi

# Without the probe there is no proof either way, and "nothing to stop" would be
# a concrete claim this vessel cannot make.
if [ "$SUBCOMMAND" = stop ] && { ! command -v node >/dev/null 2>&1 || [ ! -f "$PROBE" ]; }; then
  die "cannot check whether a board server on $ADDR belongs to this vessel (node or $PROBE is unavailable), so nothing was stopped" 7
fi

if [ "$SUBCOMMAND" = stop ] && [ "$EXPLICIT_PORT" -eq 1 ]; then
  # An explicitly named port earns no shortcut. It gets the same claim-token
  # proof the recorded port gets, because lavish-axi's stop reaches any
  # lavish-shaped server on the address it is handed.
  case "$EXPLICIT_PORT_VALUE" in
    ''|*[!0-9]*)
      die "--port needs a port number, so this vessel can prove the server on it is its own before stopping it" 2
      ;;
  esac
  if ! port_is_ours "$EXPLICIT_PORT_VALUE"; then
    if port_answers "$EXPLICIT_PORT_VALUE"; then
      die "the board server on $ADDR port $EXPLICIT_PORT_VALUE is not one this vessel can prove is its own, so it was not stopped; a co-hosted vessel serves on this same address, and only the home that opened a board may stop it" 7
    fi
    note "no review-board server owned by this vessel is running on $ADDR port $EXPLICIT_PORT_VALUE; nothing to stop"
    exit 0
  fi
  PORT=$EXPLICIT_PORT_VALUE
elif [ "$SUBCOMMAND" = stop ] && [ -z "$PROVEN" ]; then
  note "no review-board server owned by this vessel is running on $ADDR; nothing to stop"
  exit 0
fi

# --- environment ------------------------------------------------------------

export LAVISH_AXI_HOST="$ADDR"
export LAVISH_AXI_PORT="$PORT"
export LAVISH_AXI_LINK_HOST="$LINK_HOST"
export LAVISH_AXI_ALLOWED_HOSTS="$ALLOWED"
export LAVISH_AXI_STATE_DIR="$LAV_STATE"

if [ "$NEEDS_PORT" -eq 1 ]; then
  ( umask 077; printf 'port=%s\naddr=%s\nlink_host=%s\nallowed=%s\n' \
      "$PORT" "$ADDR" "$LINK_HOST" "$ALLOWED" > "$OWNER" ) 2>/dev/null || true
fi

if [ "$REACHABILITY" != tailnet ]; then
  note "no tailnet on this host (${REASON:-reason unavailable}) - this board opens only on this machine."
elif [ -n "$REASON" ]; then
  note "$REASON"
fi

# --- run --------------------------------------------------------------------

if [ "$SUBCOMMAND" != open ]; then
  exec "$LAVISH" "${ARGS[@]}"
fi

"$LAVISH" "${ARGS[@]}"
STATUS=$?

# Verify the name that is now sitting in the captain's link, not the address we
# bound. A bind that succeeded proves nothing about whether the emitted URL
# resolves and answers, and the emitted URL is the only thing he can act on.
# This is still a same-host probe: it proves the name and the allowlist, not
# that his device has tailnet reach.
if [ "$STATUS" -eq 0 ] && command -v node >/dev/null 2>&1 && [ -f "$PROBE" ]; then
  if ! node "$PROBE" http "http://$LINK_HOST:$PORT/health" >/dev/null 2>&1; then
    note "the board is serving, but the link's hostname ($LINK_HOST) does not answer here - hand over http://$ADDR:$PORT/... instead and check this vessel's tailnet name."
  fi
fi

exit "$STATUS"
