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
# A flag-led invocation carrying no .html or .htm argument - `--version`,
# `--help` - opens nothing, so it claims no port, writes no record, and gets no
# reachability or link line. `--version <board>.html` IS an open, because that
# is how lavish-axi itself reads it, and takes the full open path.
#
# Whether a board actually opened is decided by what the run PRINTED, never by
# what its arguments looked like: an argv that dispatches `open` still opens
# nothing when it carries --help. So every line this wrapper says about a LINK
# waits for a session URL in the output. Whether this host has a tailnet is a
# different kind of fact - already known, and unchanged by anything the run
# does - so that one is stated up front instead. What has to be decided before
# the run - the port claim and the records that follow it - is likewise decided
# from the arguments, because a port must exist before the command can run at
# all.
#
# `stop --port <n>` is held to exactly the same ownership proof as a bare
# `stop`: the claim token has to answer on <n> first. lavish-axi's own stop path
# shuts down any server that answers /health with a lavish-axi body, and every
# vessel on this machine binds this same address, so an explicitly named port
# that was never proved would be a neighbour's board. An unproven port that is
# serving is refused by name; one that answers nothing at all is reported as
# nothing to stop.
#
# An explicit stop is not the only way a board ends, though: lavish-axi stops
# itself when it goes idle and when the last session ends with nothing
# connected, and a published proxy outlives all of that, a crash, and a reboot.
# So every run that could open or stop a board first reconciles THIS home's own
# recorded port - only that port, and only while nothing answers behind it - so
# a dead board does not leave whatever binds that loopback port next answering
# on the tailnet under this node's name.
#
# What it sets, and why each one is needed:
#   LAVISH_AXI_HOST            the address the board binds, so the server is
#                              reachable off this machine. Never a wildcard: an
#                              all-interfaces bind is broader than the captain
#                              approved. On a node whose tailnet address cannot
#                              be bound this is loopback, and the board reaches
#                              the tailnet through the published proxy instead.
#   LAVISH_AXI_PORT            a port proved free by bin/fm-service-port.sh, so
#                              vessels sharing this machine do not collide.
#   LAVISH_AXI_LINK_HOST       the hostname written into the link. The tailnet
#                              DNS name only after it has been confirmed to
#                              resolve to this node's tailnet address; otherwise
#                              that address itself, and loopback only when no
#                              tailnet reach was established at all.
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
#   - A tailnet address this node cannot bind: the allocator says so in one
#     plain sentence, binds loopback, and publishes that port onto the tailnet
#     address. The diagnosis is kept; what changes is that the board also works.
#   - A tailnet address that can be neither bound nor published: this says the
#     vessel is not reachable off this machine rather than that it has no
#     tailnet, because it plainly has one.
#   - Nothing established either way: this says so and claims neither reach nor
#     its absence, which is what a run that tested nothing honestly holds.
#   - The link host does not answer after the board opens: this says so and
#     names the address form that does work.
#   - No free port in the window: bin/fm-service-port.sh refuses. There is no
#     silent loopback downgrade, because that would reproduce the original bug
#     somewhere new.
#   - The walk failed on an address this run never established as bindable: a
#     different state from the one above, and it retries on loopback with the
#     proxy published rather than refusing.
#
# docs/lavish-access.md's "Honest degradation" list is the one owner of the
# exact sentences; this list names the branches they cover.
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
# shellcheck source=bin/fm-tailnet-serve-lib.sh
. "$SCRIPT_DIR/fm-tailnet-serve-lib.sh"

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

# lavish-axi rewrites a flag-led argv into `open` only when some argument is an
# html path, and otherwise passes it through untouched. This wrapper mirrors
# that one fact because it has to actually RUN the command: treating
# `--version` as an open would claim a port, rewrite this home's records, and
# then report on a board that was never opened. bin/fm-lavish-command-policy.mjs
# deliberately mirrors nothing of the sort, because it fails safe by denying
# rather than running anything.
if [ "$SUBCOMMAND" = open ]; then
  case "${ARGS[0]}" in
    -*)
      OPENS_BOARD=0
      for arg in "${ARGS[@]}"; do
        case "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')" in
          *.html|*.htm) OPENS_BOARD=1; break ;;
        esac
      done
      [ "$OPENS_BOARD" -eq 1 ] || SUBCOMMAND=passthrough
      ;;
  esac
fi

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

# Needing a port and leaving a board serving on it are different questions, and
# only the second may publish a route onto the tailnet. `open`, `poll`, and
# `server` all leave lavish-axi's server up and a reviewer able to reach it.
# `end` closes the last session and lets that server stop itself, so a route
# published for it would point at nothing and would survive this process, this
# vessel, and the machine's next reboot.
case "$SUBCOMMAND" in
  open|poll|server) LEAVES_SERVER=1 ;;
  *) LEAVES_SERVER=0 ;;
esac
# One thing the argv shape CAN answer: a run carrying a help flag prints usage
# and returns without reaching any handler, so it leaves no server whatever
# subcommand it names. `open --help <board>.html` is an accepted shape and it
# would otherwise publish a node-wide route for a port lavish-axi never binds.
for arg in "${ARGS[@]}"; do
  case "$arg" in
    --help|-h) LEAVES_SERVER=0; break ;;
  esac
done

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

ADDR=""; TAILADDR=""; DNSNAME=""; MACHINE=""; SEAT=""; WINDOW=""; REACHABILITY=""; ROUTE=""; REASON=""

# Read once here from the --check pre-read, and AGAIN from the allocation
# itself. The two can genuinely differ: --check cannot know whether publishing a
# proxy will succeed, because there is no port to publish yet, and a resolution
# that degrades at that moment must not leave this wrapper holding the link host
# and the message the pre-read implied.
read_identity() {
  while IFS='=' read -r key value; do
    case "$key" in
      addr) ADDR=$value ;;
      tailaddr) TAILADDR=$value ;;
      dnsname) DNSNAME=$value ;;
      machine) MACHINE=$value ;;
      seat) SEAT=$value ;;
      window) WINDOW=$value ;;
      reachability) REACHABILITY=$value ;;
      route) ROUTE=$value ;;
      reason) REASON=$value ;;
    esac
  done <<EOF
$1
EOF
}

# Whether the link may name the tailnet at all. Under tailnet-proxied that is
# not answered by the reachability alone, because reachability describes the
# HOST: a vessel that can be reached by proxy stays tailnet-proxied on a run
# that published no route, and naming the tailnet then would hand over a link
# that opens nowhere. An empty route is the --check pre-read, where no port
# exists yet and so no route can have been decided either way; only a definite
# route=none withholds the name.
links_the_tailnet() {
  case "$REACHABILITY" in
    tailnet) return 0 ;;
    tailnet-proxied) [ "$ROUTE" != none ] ;;
    *) return 1 ;;
  esac
}

# ADDR is the address to BIND, which is not always the address to LINK. On a
# node whose tailnet address cannot be bound the port is bound on loopback and
# published onto that address, so the link still has to name the tailnet - the
# proxy is where the board genuinely answers, and 127.0.0.1 is exactly the link
# this wrapper exists to stop being handed over. When no proxy could be
# published, though, the tailnet names nothing that answers, and falling back to
# loopback is the honest link even though it opens only here.
resolve_link_identity() {
  LINK_HOST=${DNSNAME:-${TAILADDR:-$ADDR}}
  links_the_tailnet || LINK_HOST=$ADDR
  # The Host header a browser sends through the published proxy carries the
  # tailnet NAME, measured rather than reasoned about
  # (bin/fm-tailnet-serve-lib.sh records that measurement), so both the name and
  # the tailnet address belong in the allowlist whenever the tailnet identity is
  # what the link names. The allowlist is compared on hostname alone, so the
  # port the proxy adds is not part of the question.
  ALLOWED="$LINK_HOST $ADDR $CLAIM_TOKEN"
  if links_the_tailnet; then
    [ -z "$TAILADDR" ] || [ "$TAILADDR" = "$ADDR" ] || ALLOWED="$TAILADDR $ALLOWED"
    [ -z "$MACHINE" ] || ALLOWED="$MACHINE $ALLOWED"
  fi
}

read_identity "$IDENTITY"

[ -n "$ADDR" ] && [ -n "$SEAT" ] || die "the address resolver returned no usable address" 4

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

resolve_link_identity

# --- is the server on our recorded port actually ours ------------------------
#
# A bind probe cannot answer this: a port we are ourselves listening on always
# reports as taken. The claim token can, and it is the only check here that
# distinguishes our server from a same-version one belonging to another UNIX
# account on this machine.

port_is_ours_on() {
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$PROBE" ] || return 1
  node "$PROBE" http "http://$1:$2/health" "$CLAIM_TOKEN" >/dev/null 2>&1
}

# The address the proof actually answered on, kept because it is where a board
# of ours IS: lavish-axi builds every target it reaches from LAVISH_AXI_HOST, so
# a run that hands it any other address takes the route down and then reports
# nothing running while the board keeps serving. On a run that allocates, the
# allocation resolved that address; on `stop`, which allocates nothing, only
# this proof can name it.
PROVEN_ADDR=""

port_is_ours() {
  local a
  for a in $(own_addresses); do
    if port_is_ours_on "$a" "$1"; then
      PROVEN_ADDR=$a
      return 0
    fi
  done
  return 1
}

# Deliberately without the token: it separates "a board is serving here and it
# is not ours" from "nothing is serving here at all", which are different facts
# and deserve different answers. The address is named explicitly by the second
# form, because a published proxy always points at loopback whatever this run
# resolved as its own bind address.
port_answers_on() {
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$PROBE" ] || return 1
  node "$PROBE" http "http://$1:$2/health" >/dev/null 2>&1
}

# The other half of the ownership rule: a port nothing is serving on may be
# withdrawn by anyone, so this has to be sure of EVERY listener a board of ours
# could be on, for the same reason port_is_ours asks all of them. Asking only
# the bind address this run resolved would call a co-hosted vessel's live
# proxied board silent and take it off the tailnet.
nothing_serves_on() {
  local a
  for a in $(own_addresses); do
    port_answers_on "$a" "$1" && return 1
  done
  return 0
}

recorded_port() {
  local record="$STATE/service-port.lavish" recorded=""
  [ -r "$record" ] || return 1
  recorded=$(sed -n 's/^port=\([0-9][0-9]*\)$/\1/p' "$record" | head -1)
  [ -n "$recorded" ] || return 1
  printf '%s\n' "$recorded"
}

recorded_addr() {
  local record="$STATE/service-port.lavish" recorded=""
  [ -r "$record" ] || return 1
  recorded=$(sed -n 's/^addr=\(.*\)$/\1/p' "$record" | head -1)
  [ -n "$recorded" ] || return 1
  printf '%s\n' "$recorded"
}

# Every address a board of THIS vessel could be listening on, most authoritative
# first. The record leads because it names the address the allocation actually
# resolved, and the --check pre-read cannot answer that: whether a proxy will
# publish is unanswerable until a port exists, so a run that degraded to
# loopback after the pre-read reported the tailnet address is bound there and
# nowhere else. Loopback is always asked last because a published proxy forwards
# there whatever this run resolved for itself. The claim token is what keeps
# asking widely safe: a neighbour's board on any of these never carries it.
own_addresses() {
  local seen="" a
  for a in "$(recorded_addr || true)" "$ADDR" 127.0.0.1; do
    [ -n "$a" ] || continue
    case " $seen " in *" $a "*) continue ;; esac
    seen="$seen $a"
    printf '%s\n' "$a"
  done
}

owned_port() {
  local recorded
  recorded=$(recorded_port) || return 1
  port_is_ours "$recorded" || return 1
  PROVEN=$recorded
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
  # It deliberately leaves the publication alone: a caller that is about to bind
  # the same port again still needs it, and a caller that is walking away says
  # so by calling withdraw_proxy itself.
  LAVISH_AXI_HOST=${PROVEN_ADDR:-$ADDR} LAVISH_AXI_PORT=$1 \
    "$LAVISH" stop --port "$1" >/dev/null 2>&1 || true
}

# A published proxy outlives the server it points at, so a stopped board would
# otherwise leave a tailnet endpoint answering nothing on this vessel's own
# name. Serve configuration belongs to the whole node, which every UNIX account
# on this machine shares, so this is called only where ownership of the port has
# already been proved or where nothing is serving on it at all.
#
# What is asked is whether THIS PORT is published, never how the current run
# resolved. A publication made while the node was in userspace mode outlives
# that mode: the container can regain /dev/net/tun, or serve can be momentarily
# unavailable, and the same port then needs taking down by a run that resolved
# tailnet or loopback. Deciding from the current reachability orphans exactly
# those, and once the record names a different port nothing can reach them
# again.
#
# The status is returned rather than swallowed, because it carries a fact no
# caller can recover afterwards: a non-zero answer means the port is STILL
# published after the off command ran, so the withdrawal did not take. A caller
# that is about to hand control away is the one that has to say so.
withdraw_proxy() {
  fm_tailnet_serve_published "$1" || return 0
  fm_tailnet_serve_withdraw "$1"
}

# lavish-axi stops itself when it goes idle and when the last session ends with
# nothing connected, and neither path runs a line of this wrapper, so an
# explicit stop is not the only way a board goes away. The publication survives
# it - and a crash, and a reboot - which would leave whatever binds that
# loopback port next answering under this node's tailnet name to the whole
# tailnet, wider than the account that published it ever approved.
#
# The scope here is deliberately narrow and must stay narrow: only THIS home's
# own recorded port, and only while nothing at all answers behind it. Every
# other entry in the node's serve configuration belongs to an account this
# vessel cannot speak for, and sweeping them is exactly the harm the ownership
# rule above exists to prevent.
reconcile_stale_publication() {
  local recorded
  command -v node >/dev/null 2>&1 || return 0
  [ -f "$PROBE" ] || return 0
  recorded=$(recorded_port) || return 0
  fm_tailnet_serve_published "$recorded" || return 0
  port_answers_on 127.0.0.1 "$recorded" && return 0
  fm_tailnet_serve_withdraw "$recorded" || true
}

if [ "$NEEDS_PORT" -eq 1 ] || [ "$SUBCOMMAND" = stop ]; then
  reconcile_stale_publication
fi

MINE=""
RELOCATE_FROM=""
PROVEN=""
owned_port || PROVEN=""
if [ -n "$PROVEN" ]; then
  if in_window "$PROVEN"; then
    # Whether the running server was started with the configuration this run
    # resolves is not answerable yet, so that comparison waits for the
    # allocation below and this port is offered to the allocator as ours.
    MINE=$PROVEN
  else
    # A different port is wanted, so the working board must survive until a
    # replacement is actually secured. Tearing it down first would turn a failed
    # move into a lost board.
    RELOCATE_FROM=$PROVEN
  fi
fi

# --- port -------------------------------------------------------------------

PORT=""
if [ "$NEEDS_PORT" -eq 1 ]; then
  ALLOCATE=("$SCRIPT_DIR/fm-service-port.sh" lavish)
  [ -z "$MINE" ] || ALLOCATE+=(--mine "$MINE")
  [ "$LEAVES_SERVER" -eq 0 ] || ALLOCATE+=(--serving)
  if ! RECORD=$("${ALLOCATE[@]}" 2>&1); then
    printf '%s\n' "$RECORD" >&2
    [ -z "$RELOCATE_FROM" ] \
      || note "the board already serving on port $RELOCATE_FROM was left running, so nothing was lost"
    die "no port is available for a review board on this vessel, so no board was opened" 5
  fi
  PORT=$(printf '%s\n' "$RECORD" | sed -n 's/^port=\([0-9][0-9]*\)$/\1/p' | head -1)
  [ -n "$PORT" ] || die "the port allocator returned no port" 5
  # The allocation is the authoritative resolution, not the pre-read: publishing
  # a proxy can only be attempted once a port exists, so this is the first point
  # at which a vessel that cannot publish one is known to be loopback-only. Left
  # unread, this wrapper would hand over a tailnet link that answers nothing,
  # which is the one thing it exists to prevent.
  read_identity "$RECORD"
  resolve_link_identity
  if [ -n "$RELOCATE_FROM" ]; then
    note "moving this vessel's boards from port $RELOCATE_FROM to $PORT; links already handed over on the old port stop working"
    stop_server "$RELOCATE_FROM"
    withdraw_proxy "$RELOCATE_FROM"
  fi
  # The running server emits the link host it was born with, so a changed link
  # host is a stale server rather than a reusable one. Decided from the
  # allocation and never from the --check pre-read: only the allocation knows
  # whether a proxy was published, so on a vessel that degrades every time, a
  # pre-read comparison never agrees with the record it wrote and would restart
  # a healthy board - dropping the reviewer's connected browser - on every
  # single open, poll, and end.
  #
  # Only a run that leaves a server may act on this. A run that starts nothing
  # cannot correct a mismatch, and its own link host is resolved from a route it
  # deliberately did not publish, so letting it compare would tear down a healthy
  # board over a difference it created and was never going to fix.
  if [ "$LEAVES_SERVER" -eq 1 ] && [ -n "$MINE" ] \
    && { [ "$(owner_field link_host || true)" != "$LINK_HOST" ] \
      || [ "$(owner_field allowed || true)" != "$ALLOWED" ]; }; then
    note "the running board server was started with a different address configuration; restarting it so links are correct"
    # Same port wanted, so the publication the allocation just made still names
    # the right port and is deliberately left standing across the restart.
    stop_server "$MINE"
  fi
else
  PORT=${MINE:-${PROVEN:-$SEAT}}
fi

# Without the probe there is no proof either way, and "nothing to stop" would be
# a concrete claim this vessel cannot make.
if [ "$SUBCOMMAND" = stop ] && { ! command -v node >/dev/null 2>&1 || [ ! -f "$PROBE" ]; }; then
  die "cannot check whether any board server on this machine belongs to this vessel (node or $PROBE is unavailable), so nothing was stopped" 7
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
    # One question, asked once: is ANYTHING serving here. A board that answers
    # but cannot be proved this vessel's is refused by name, and only a port
    # with nothing behind it on either listener may have its route withdrawn.
    if ! nothing_serves_on "$EXPLICIT_PORT_VALUE"; then
      die "something is serving on port $EXPLICIT_PORT_VALUE on this machine and this vessel cannot prove it is its own, so it was not stopped; only the home that opened a board may stop it" 7
    fi
    withdraw_proxy "$EXPLICIT_PORT_VALUE"
    note "nothing owned by this vessel answers on port $EXPLICIT_PORT_VALUE on any address one of its boards could be listening on; nothing to stop"
    exit 0
  fi
  PORT=$EXPLICIT_PORT_VALUE
elif [ "$SUBCOMMAND" = stop ] && [ -z "$PROVEN" ]; then
  # Nothing here has been proved to be this vessel's, and PORT has fallen back
  # to the bare seat, which a co-hosted vessel walking its own window can have
  # published for a board of its own. So the same proof the explicit --port
  # branch applies is required: a publication is only withdrawn where nothing is
  # serving behind it at all.
  nothing_serves_on "$PORT" && withdraw_proxy "$PORT"
  note "nothing owned by this vessel answers on port $PORT on any address one of its boards could be listening on; nothing to stop"
  exit 0
fi

# --- environment ------------------------------------------------------------

# `stop` allocates nothing, so $ADDR here is still the --check pre-read, which
# cannot know where the allocation bound: on a vessel whose address probe gives
# no verdict it names the tailnet address while the board is on loopback. The
# board is reached at the address its ownership proof answered on.
if [ "$SUBCOMMAND" = stop ] && [ -n "$PROVEN_ADDR" ]; then
  export LAVISH_AXI_HOST="$PROVEN_ADDR"
else
  export LAVISH_AXI_HOST="$ADDR"
fi
export LAVISH_AXI_PORT="$PORT"
export LAVISH_AXI_LINK_HOST="$LINK_HOST"
export LAVISH_AXI_ALLOWED_HOSTS="$ALLOWED"
export LAVISH_AXI_STATE_DIR="$LAV_STATE"

# What a server was LAUNCHED with, which is the only thing the comparison above
# can mean, so only a run that launches one may write it. A run that starts
# nothing would otherwise record a link host no running server ever used - and
# the next run that does start one would read that, find a mismatch it did not
# cause, and stop a healthy board to fix it.
if [ "$LEAVES_SERVER" -eq 1 ]; then
  ( umask 077; printf 'port=%s\naddr=%s\nlink_host=%s\nallowed=%s\n' \
      "$PORT" "$ADDR" "$LINK_HOST" "$ALLOWED" > "$OWNER" ) 2>/dev/null || true
fi

# This describes the HOST, not the outcome, and it is already known: no run can
# make a loopback-only vessel reachable or a tailnet one unreachable. So it goes
# out on every invocation that could open a board, before that board is opened.
# Saying it to somebody who only asked for help is noise; withholding it on a
# genuinely loopback-only host is the silent failure this whole mechanism exists
# to end.
if [ "$NEEDS_PORT" -eq 1 ]; then
  case "$REACHABILITY" in
    tailnet|tailnet-proxied)
      [ -z "$REASON" ] || note "$REASON"
      ;;
    untested)
      # Neither reach nor its absence has been established, and saying either
      # would be the same unbacked assertion in opposite directions. Which
      # sentence applies turns on what this run met, because that is the only
      # thing it has actually established.
      #
      # Publishing a route is the only thing left that could settle it, so the
      # question is asked of the same library that would do the publishing, and
      # each sentence reports what THIS run met. A host whose tailscale could
      # not be READ at all returns the same non-answer on every later run, which
      # is a fact about the read rather than a prediction. A host whose
      # tailscale could not serve just now has a named blocker. A host whose
      # tailscale can serve has neither: no route onto its address exists yet,
      # and that is all this run knows. None of them says what a later open will
      # do - a publish can be refused durably, by a serve policy or a CLI too
      # old for the flags, while `tailscale status` keeps reporting Running - so
      # a sentence promising the next open would be the same unbacked prediction
      # in the one arm where it can be false.
      if [ -z "$TAILADDR" ]; then
        note "nothing here could read whether this vessel has any reach off this machine (${REASON:-reason unavailable}) - this board certainly opens here, and nothing more can be settled until that can be read."
      elif fm_tailnet_serve_available; then
        note "nothing has established whether this vessel is reachable off this machine (${REASON:-reason unavailable}) - this board certainly opens here, and no tailscale serve route onto $TAILADDR has been established yet."
      else
        note "nothing has established whether this vessel is reachable off this machine (${REASON:-reason unavailable}) - this board certainly opens here, and no route could be published onto $TAILADDR because tailscale could not serve here just now."
      fi
      ;;
    *)
      # A vessel that HAS a tailnet address it can neither bind nor publish is
      # not a vessel with no tailnet, and saying so sends the reader hunting the
      # wrong thing. Both branches state the same consequence; only the fact
      # they lead with differs, and the concrete diagnosis stays where it is
      # owned, in REASON.
      if [ -n "$TAILADDR" ]; then
        note "this vessel is not reachable off this machine (${REASON:-reason unavailable}) - this board opens only on this machine."
      else
        note "no tailnet on this host (${REASON:-reason unavailable}) - this board opens only on this machine."
      fi
      ;;
  esac
fi

# --- run --------------------------------------------------------------------

# Withdrawn before the stop rather than after it, because `stop` replaces this
# process and there is no "after" to run in. The port has already been proved to
# be this home's by the claim token above, which is the whole condition on
# touching node-wide serve configuration, and a proxy left pointing at a port
# that is about to stop answering is the dead tailnet endpoint this exists to
# prevent - it answers 502 rather than nothing, which reads as a broken board
# rather than a closed one.
#
# A withdrawal that did not take is reported rather than refused. The board is
# stopping either way, and this is the one moment it can be said at all: the
# exec below replaces this process, so a silent failure here would leave the
# captain told his board was stopped while his own tailnet name keeps answering
# on that port.
if [ "$SUBCOMMAND" = stop ]; then
  withdraw_proxy "$PORT" \
    || note "this board is stopping, but its published tailnet endpoint on port $PORT could not be withdrawn, so this vessel's tailnet name keeps answering there until \`tailscale serve --http=$PORT off\` succeeds"
fi

if [ "$SUBCOMMAND" != open ]; then
  exec "$LAVISH" "${ARGS[@]}"
fi

# stdout is captured and replayed so this wrapper can read what the run
# actually produced. An argument shape cannot answer "did a board open": a
# lavish-axi argv that dispatches `open` still opens nothing when it carries
# --help, and a wrapper that predicts instead of observing ends up describing a
# board that does not exist.
OUTPUT=$("$LAVISH" "${ARGS[@]}")
STATUS=$?
[ -z "$OUTPUT" ] || printf '%s\n' "$OUTPUT"

# A session link in the output is the evidence that a board is now serving and
# that a link has been handed over. Without it there is no link to make any
# claim about, and silence is the honest answer. Only claims ABOUT A LINK hang
# off this; the host's own reachability is stated above regardless, so a change
# in lavish-axi's output shape can never silence that. The shape itself is
# pinned against the installed tool by tests/fm-lavish-access.test.sh.
case "$OUTPUT" in
  *://*/session/*) OPENED=1 ;;
  *) OPENED=0 ;;
esac

# A route is node-wide and outlives this process and the machine's next reboot,
# so it may not stand for a board that never opened. The argv shape cannot
# answer that on its own, which is exactly why OPENED is observed rather than
# predicted, and the withdrawal carries the same guard as every other: only
# where nothing is serving on the port at all.
if [ "$OPENED" -eq 0 ] && [ "$ROUTE" = published ] && nothing_serves_on "$PORT"; then
  withdraw_proxy "$PORT" \
    || note "no board opened, but the tailnet route on port $PORT could not be withdrawn"
fi

# Verify the name that is now sitting in the captain's link, not the address we
# bound. A bind that succeeded proves nothing about whether the emitted URL
# resolves and answers, and the emitted URL is the only thing he can act on.
# This is still a same-host probe: it proves the name and the allowlist, not
# that his device has tailnet reach. The one state where the link host cannot
# be asked at all is handled first, with its reason given there.
if [ "$OPENED" -eq 1 ] && [ "$STATUS" -eq 0 ] && command -v node >/dev/null 2>&1 && [ -f "$PROBE" ]; then
  if [ "$REACHABILITY" = tailnet-proxied ] && [ "$ROUTE" = published ]; then
    # Here the link host is, by construction, an address this machine could not
    # bind - that is the whole reason a proxy was published onto it, and the
    # userspace diagnosis above has already said so. Its silence to a local
    # probe is therefore the premise of this path rather than evidence about the
    # board, and the loopback link the advice below offers is exactly the link
    # this path exists to stop handing over. So the readiness question is asked
    # of what this run actually bound.
    #
    # What that answers is bounded and the sentences stay inside it: the board
    # is up on this vessel and its port was published. Nothing here reached the
    # tailnet name from anywhere, so nothing here may say the link works - or
    # that it does not.
    if node "$PROBE" http "http://$ADDR:$PORT/health" >/dev/null 2>&1; then
      note "the board is serving on this vessel at $ADDR:$PORT and that port is published over tailscale serve under $LINK_HOST; whether that name answers from another device is not something this run tested."
    else
      note "the board did not answer on the port it bound ($ADDR:$PORT), so it is not serving here even though its port was published over tailscale serve under $LINK_HOST."
    fi
  elif ! node "$PROBE" http "http://$LINK_HOST:$PORT/health" >/dev/null 2>&1; then
    note "the board is serving, but the link's hostname ($LINK_HOST) does not answer here - hand over http://$ADDR:$PORT/... instead and check this vessel's tailnet name."
  fi
fi

exit "$STATUS"
