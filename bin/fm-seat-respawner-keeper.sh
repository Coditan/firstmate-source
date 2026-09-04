#!/usr/bin/env bash
# Portable tmux-hosted keeper for the primary-seat respawner of a home whose
# systemd user manager is unusable.
# Usage: fm-seat-respawner-keeper.sh <fm-home> <code-root> <state-dir> <source-version> <service-path>
#
# fm-seat-respawner-service.sh owns selection and launch of this process.
# The keeper records its pid in state/.seat-respawner-keeper.pid and respawns
# only its own home-scoped respawner child after an unexpected exit.
#
# WHY THIS TIER EXISTS AT ALL, WHEN THE WATCHER'S AND THE LISTENER'S ALREADY DO
# Those two were given a keeper because a home without a working systemd user
# manager still has to supervise them.  The respawner was not, so on such a home
# bin/fm-seat-respawner-service.sh reported "no primary-seat respawner can be
# supervised here" and stopped - which is why coditan-vessel had a restarter in
# the tree and none running when its seat died on 2026-08-27.
#
# WHAT RE-ENSURES THIS KEEPER, WHICH IS THE QUESTION THAT MATTERS
# Not a seat session start.  That was the whole defect: on a container with no
# service manager, every keeper in this fleet is started by bin/fm-bootstrap.sh
# and therefore by a seat, so a restarter supervised that way is re-ensured by
# the very thing it exists to restart.  That circle cannot restart anything once
# the seat is the part that is gone.
#
# So this keeper is converged from the WATCHER instead, through the armed check
# bin/fm-seat-respawner-service.sh --arm installs, which runs every watcher
# sweep.  The watcher is not supervised either, but it is the one loop on such a
# home that outlived the outage this was written for, and converging from it
# takes the seat out of the restart path entirely.  In the other direction
# bin/fm-seat-respawner.sh revives a provably dead watcher, so either process
# surviving restores both.  docs/seat-absence.md states what is left over when
# neither does, because it is not nothing and it is not this file's to hide.
#
# <service-path> is the PATH the RESPAWNER must run with, resolved by
# bin/fm-service-path-lib.sh in the launching session, for the same reason the
# watcher's and the listener's keepers take one: this process starts under the
# tmux server's environment, which may not reach the tools it needs.
# That is not the PATH pin bin/fm-seat-respawner.sh deliberately does NOT compose
# for the seat, and the two must not be confused.  This one is the environment a
# BACKGROUND SERVICE of this fleet runs with, which this fleet resolves
# deliberately.  That one was an accident of whoever launched the respawner being
# baked into a fresh agent session that never reads its own login environment.
set -u

[ "$#" -eq 5 ] || { echo "usage: $(basename "$0") <fm-home> <code-root> <state-dir> <source-version> <service-path>" >&2; exit 2; }
FM_HOME=$1
FM_ROOT_OVERRIDE=$2
FM_STATE_OVERRIDE=$3
FM_SEAT_RESPAWNER_SOURCE_VERSION=$4
FM_SEAT_RESPAWNER_SERVICE_PATH=$5
PATH=$5
export FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_SEAT_RESPAWNER_SOURCE_VERSION \
  FM_SEAT_RESPAWNER_SERVICE_PATH PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESPAWNER="$SCRIPT_DIR/fm-seat-respawner.sh"
PIDFILE="$FM_STATE_OVERRIDE/.seat-respawner-keeper.pid"
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
  FM_SEAT_RESPAWNER_MANAGER=keeper "$RESPAWNER" &
  CHILD=$!
  wait "$CHILD"
  CHILD=
  sleep "${FM_SEAT_RESPAWNER_RESTART_SEC:-2}"
done
