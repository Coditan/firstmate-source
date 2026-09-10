#!/usr/bin/env bash
# Portable tmux-hosted keeper for the herdr runtime owner of a home whose
# systemd user manager is unusable.
# Usage: fm-herdr-keeper.sh <fm-home> <code-root> <state-dir> <source-version> <service-path> <session> <status-timeout>
#
# fm-herdr-service.sh owns selection and launch of this process.
# The keeper records its pid in state/.herdr-keeper.pid and respawns only its
# own home-scoped runtime-owner child after an unexpected exit.
#
# This tier matters more here than for any other keeper on a herdr home, because
# the container this fleet runs in has no usable `systemd --user` at all: the
# keeper IS the tier, not a fallback nobody reaches.
#
# Killing this keeper does NOT stop the herdr runtime.  The owner starts the
# server detached in a session of its own (bin/fm-herdr-runtime.sh), so what dies
# with this tmux session is the watching, never the workers - which is also the
# whole rollback for this feature.
#
# <service-path> is the PATH the owner must run with, resolved by
# bin/fm-service-path-lib.sh in the launching session.  It is passed in rather
# than computed here because this process starts under the tmux server's
# environment, which may not reach `herdr` or `jq` at all - and an owner that
# cannot reach herdr reads the runtime as unreadable rather than as down, which
# is correct but useless.  It is handed on as FM_HERDR_RUNTIME_SERVICE_PATH so
# the owner can RECORD what it was given; without that record a keeper-backed
# home keeps a stale PATH forever while the systemd tier reconverges on its own.
#
# <status-timeout> travels the same way and for the same reason: it is the
# deadline the owner puts on one status read, and the converging session sizes
# its own convergence wait from it, so the owner has to run with the value that
# session used rather than with whatever this tmux server's environment holds.
set -u

[ "$#" -eq 7 ] || { echo "usage: $(basename "$0") <fm-home> <code-root> <state-dir> <source-version> <service-path> <session> <status-timeout>" >&2; exit 2; }
FM_HOME=$1
FM_ROOT_OVERRIDE=$2
FM_STATE_OVERRIDE=$3
FM_HERDR_RUNTIME_SOURCE_VERSION=$4
FM_HERDR_RUNTIME_SERVICE_PATH=$5
FM_HERDR_RUNTIME_SESSION=$6
FM_HERDR_RUNTIME_STATUS_TIMEOUT=$7
PATH=$5
export FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_HERDR_RUNTIME_SOURCE_VERSION \
  FM_HERDR_RUNTIME_SERVICE_PATH FM_HERDR_RUNTIME_SESSION FM_HERDR_RUNTIME_STATUS_TIMEOUT PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$SCRIPT_DIR/fm-herdr-runtime.sh"
PIDFILE="$FM_STATE_OVERRIDE/.herdr-keeper.pid"
CHILD=

mkdir -p "$FM_STATE_OVERRIDE"
printf '%s\n' "${BASHPID:-$$}" > "$PIDFILE" || exit 1

cleanup() {
  trap - HUP INT TERM
  if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
    rm -f "$PIDFILE"
  fi
  exit 0
}
trap cleanup HUP INT TERM

while :; do
  FM_HERDR_RUNTIME_MANAGER=keeper "$RUNTIME" &
  CHILD=$!
  wait "$CHILD"
  CHILD=
  sleep "${FM_HERDR_RUNTIME_RESTART_SEC:-2}"
done
