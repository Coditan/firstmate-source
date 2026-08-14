#!/usr/bin/env bash
# Portable tmux-hosted keeper for the wake-delivery listener of a home whose
# systemd user manager is unusable.
# Usage: fm-delivery-keeper.sh <fm-home> <code-root> <state-dir> <source-version> <service-path>
#
# fm-delivery-service.sh owns selection and launch of this process.
# The keeper records its pid in state/.delivery-keeper.pid and respawns only its
# own home-scoped listener child after an unexpected exit.
#
# This tier exists for the same reason the watcher's does, and matters more:
# delivery is what turns a queued wake into a model turn, so a home that cannot
# run a systemd user unit must still get a supervised listener rather than
# falling back to a session-held waiter - the very object this design removed.
#
# <service-path> is the PATH the listener must run with, resolved by
# bin/fm-service-path-lib.sh in the launching session.  It is passed in rather
# than computed here because this process starts under the tmux server's
# environment, which may not reach the tools it would need to resolve them.  It
# is handed on as FM_DELIVERY_SERVICE_PATH so the listener can RECORD what it was
# given; without that record a keeper-backed home keeps a stale PATH forever
# while the systemd tier reconverges on its own recorded one.
set -u

[ "$#" -eq 5 ] || { echo "usage: $(basename "$0") <fm-home> <code-root> <state-dir> <source-version> <service-path>" >&2; exit 2; }
FM_HOME=$1
FM_ROOT_OVERRIDE=$2
FM_STATE_OVERRIDE=$3
FM_DELIVERY_SOURCE_VERSION=$4
FM_DELIVERY_SERVICE_PATH=$5
PATH=$5
export FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DELIVERY_SOURCE_VERSION \
  FM_DELIVERY_SERVICE_PATH PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/fm-delivery.sh"
PIDFILE="$FM_STATE_OVERRIDE/.delivery-keeper.pid"
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
  FM_DELIVERY_DAEMON=1 FM_DELIVERY_MANAGER=keeper "$DELIVERY" &
  CHILD=$!
  wait "$CHILD"
  CHILD=
  sleep "${FM_DELIVERY_RESTART_SEC:-2}"
done
