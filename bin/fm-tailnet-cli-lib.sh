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
#                               that declares its socket some third way.
#   2. $VESSEL_TAILNET_SOCKET - the vessel runtime's own declaration, present in
#                               PID 1's environment and so inherited by every
#                               process the container starts, this seat and its
#                               services included.
#   3. the running daemon's own `--socket=` argument, recovered from its command
#      line. This is the same declaration read from the other end, and it covers
#      a caller whose environment was stripped.
#
# When no source answers, no `--socket` is passed at all and the client uses its
# own default. That is deliberate: on a host that never declared a path, the
# default is correct, and inventing one would break a working vessel.
#
# Functions (source this file; it defines only fm_tailscale_*):
#   fm_tailscale_socket        prints the resolved socket path, or nothing; 0
#                              when one was resolved, 1 when none was
#   fm_tailscale <args...>     runs `tailscale` against the resolved socket
#
# fm_tailscale passes its arguments through untouched and says nothing of its
# own, so a caller keeps ownership of both the command and what its user reads.

fm_tailscale_socket() {
  local sock=''
  if [ -n "${FM_TAILSCALE_SOCKET:-}" ]; then
    sock=$FM_TAILSCALE_SOCKET
  elif [ -n "${VESSEL_TAILNET_SOCKET:-}" ]; then
    sock=$VESSEL_TAILNET_SOCKET
  else
    # The daemon's own command line carries the declaration. `pgrep -a` prints
    # "<pid> <cmdline>"; take the first --socket= it names. A host with no
    # running tailscaled simply yields nothing here, which is the right answer.
    sock=$(pgrep -a tailscaled 2>/dev/null \
      | sed -n 's/.*--socket=\([^ ]*\).*/\1/p' \
      | head -n 1)
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
