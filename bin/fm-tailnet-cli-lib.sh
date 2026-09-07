#!/usr/bin/env bash
# The one owner of HOW this vessel's `tailscale` client reaches its own daemon.
#
# It exists for one measured case, read on this vessel on 2026-09-07. The image
# starts tailscaled with an explicit `--socket=` rather than the client's
# compiled-in default, so every bare `tailscale` call fails:
#
#   failed to connect to local tailscaled (which appears to be running as
#   tailscaled, pid 176). Got error: ... dial unix
#   /var/run/tailscale/tailscaled.sock: connect: no such file or directory
#
# That message names a daemon that IS running, so a caller reading only the
# exit status concludes the vessel has no tailnet when it holds a perfectly
# good one. `bin/fm-service-port.sh` did exactly that and resolved loopback.
#
# The path is never written here. It is READ from where the image declares it,
# in this order, and the first source that answers wins:
#
#   1. $FM_TAILSCALE_SOCKET   - an explicit override, for tests and for a host
#                               that declares its socket some third way. It is
#                               read for whether it is SET, not for whether it
#                               is non-empty, so it has a value for every answer
#                               a resolution can have: set to a path redirects
#                               the client there, set to the empty string
#                               resolves nothing at all, and unset falls through
#                               to the next source.
#   2. $VESSEL_TAILNET_SOCKET - the vessel runtime's own declaration, present in
#                               PID 1's environment and so inherited by every
#                               process the container starts, this seat and its
#                               services included.
#
# When neither answers, no `--socket` is passed at all and the client uses its
# own default. That is deliberate: on a host that never declared a path, the
# default is correct, and inventing one would break a working vessel. It is also
# why the override distinguishes unset from empty: a vessel whose declaration is
# WRONG is exactly the situation this file was written for, and a seat cannot
# unset a variable the runtime exported into PID 1 for an already-running
# process tree - so `FM_TAILSCALE_SOCKET=` is how an operator hands the client
# back its own default without touching the declaration.
#
# A third source was considered and DELIBERATELY REJECTED, and a later reader
# who meets the stripped-environment case must find this decision rather than a
# gap: recovering the path from the running daemon's own `--socket=` argument,
# by matching a process named `tailscaled`. A process-name match matches across
# every UNIX account on the machine, and bin/fm-service-port.sh's own header
# states the target is "a machine that may carry several vessels as separate
# UNIX accounts". So an account we do not trust could run any executable it
# named `tailscaled` pointing at a socket it owns, and thereby choose the
# tailnet address and DNS name firstmate publishes to the captain as a board
# link - and receive this vessel's `tailscale serve` calls. That is the whole
# reach this cluster exists to establish, handed to whoever wins a process
# scan.
#
# Dropping it costs nothing here, which is why it is a decision and not a
# sacrifice: the vessel runtime exports $VESSEL_TAILNET_SOCKET into PID 1's
# environment, so every process the container starts inherits it and source 2
# always answers. The stripped-environment case the fallback existed for does
# not arise on this vessel.
#
# Functions (source this file; it defines only fm_tailscale_*):
#   fm_tailscale_socket        prints the resolved socket path, or nothing; 0
#                              when one was resolved, 1 when none was
#   fm_tailscale <args...>     runs `tailscale` against the resolved socket
#   fm_tailscale_dialled       one clause naming what the client dialled, for a
#                              caller reporting a call that failed: the socket
#                              this file resolved, or that none was declared and
#                              the client used its own default
#
# fm_tailscale passes its arguments through untouched and says nothing of its
# own, so a caller keeps ownership of both the command and what its user reads.

fm_tailscale_socket() {
  local sock=''
  if [ -n "${FM_TAILSCALE_SOCKET+set}" ]; then
    sock=$FM_TAILSCALE_SOCKET
  elif [ -n "${VESSEL_TAILNET_SOCKET:-}" ]; then
    sock=$VESSEL_TAILNET_SOCKET
  fi
  [ -n "$sock" ] || return 1
  printf '%s\n' "$sock"
  return 0
}

fm_tailscale() {
  local sock
  if sock=$(fm_tailscale_socket); then
    tailscale --socket="$sock" "$@"
  else
    tailscale "$@"
  fi
}

# A caller that has to explain a failed client call needs the one fact only this
# file holds: which socket the call was made against. Naming it is what makes
# the next instance of the original failure - a vessel whose daemon listens
# somewhere other than the path we resolved - readable from the output alone.
fm_tailscale_dialled() {
  local sock
  if sock=$(fm_tailscale_socket); then
    printf 'firstmate dialled the socket declared for this vessel, %s' "$sock"
  else
    printf 'no socket is declared for this vessel, so the client dialled its own default'
  fi
}
