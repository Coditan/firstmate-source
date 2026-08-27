#!/usr/bin/env bash
# The one owner of publishing a loopback port onto this node's tailnet address
# with `tailscale serve`, and of withdrawing it again.
#
# It exists for one measured case. A tailscale node can hold an ADDRESS without
# the machine having an INTERFACE for it: in userspace networking mode there is
# no /dev/net/tun and no NET_ADMIN, so tailscaled runs a userspace network stack
# and no local interface ever carries the tailnet IPv4. `bind()` on that address
# fails EADDRNOTAVAIL for every port, so no port window can rescue it. The node
# is genuinely on the tailnet - other devices reach it - but nothing on this
# machine can listen on its address directly.
#
# `tailscale serve` is the route around that, because the listener lives inside
# tailscaled's own userspace stack rather than on a host interface. It proxies
# the tailnet address to a loopback port this account CAN bind.
#
# Two facts every caller depends on, both measured rather than reasoned:
#
#   1. The published port and the loopback port are deliberately THE SAME
#      number. Consumers write their own bound port into the links they hand
#      over, so a proxy on a different port would emit a link that answers
#      nothing. Serve's listener is on the tailnet address inside the userspace
#      stack and the service's listener is on 127.0.0.1, so the two never
#      collide despite the shared number.
#   2. The Host header a browser's request carries through the proxy is
#      "<tailnet-dns-name>:<port>" - the tailnet name, not loopback and not the
#      node's address. A consumer with a Host allowlist must carry that name.
#
# Serve configuration belongs to the tailscale node, which is shared by every
# UNIX account on this machine. So withdraw only a port whose ownership the
# caller has already proved; withdrawing a neighbour's published port would take
# their service off the tailnet.
#
# Functions (source this file; it defines only fm_tailnet_serve_*):
#   fm_tailnet_serve_available            0 when a running tailscale can serve
#   fm_tailnet_serve_publish <port>       proxy the tailnet address to
#                                         http://127.0.0.1:<port> on <port>
#   fm_tailnet_serve_published <port>     0 when <port> is currently published
#   fm_tailnet_serve_withdraw <port>      remove that publication
#
# Every function is quiet and reports through its exit status alone, so a caller
# owns what its user is told. Publish and withdraw are both idempotent.

fm_tailnet_serve_available() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"' || return 1
  return 0
}

fm_tailnet_serve_publish() {
  local port=${1:-}
  case "$port" in
    ''|*[!0-9]*) return 2 ;;
  esac
  fm_tailnet_serve_available || return 1
  # --yes because this runs non-interactively; serve otherwise prompts before
  # changing a node's published configuration.
  tailscale serve --bg --yes --http="$port" "http://127.0.0.1:$port" >/dev/null 2>&1 || return 1
  fm_tailnet_serve_published "$port"
}

fm_tailnet_serve_published() {
  local port=${1:-}
  case "$port" in
    ''|*[!0-9]*) return 2 ;;
  esac
  command -v tailscale >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # `serve status --json` keys its TCP map by published port, which is an exact
  # answer; the human-readable form has to be pattern-matched and has already
  # changed shape between releases.
  [ "$(tailscale serve status --json 2>/dev/null \
    | jq -r --arg p "$port" '(.TCP // {}) | has($p)' 2>/dev/null)" = true ] || return 1
  return 0
}

fm_tailnet_serve_withdraw() {
  local port=${1:-}
  case "$port" in
    ''|*[!0-9]*) return 2 ;;
  esac
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale serve --yes --http="$port" off >/dev/null 2>&1 || true
  fm_tailnet_serve_published "$port" && return 1
  return 0
}
