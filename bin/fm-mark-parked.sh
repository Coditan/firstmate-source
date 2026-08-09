#!/usr/bin/env bash
# Operator-facing entry point for declaring an ordinary task parked after its
# terminal outcome has been relayed and only external human action remains.
# bin/fm-watch.sh owns window validation, secondmate rejection, key derivation,
# and marker creation; this wrapper only provides a seatbelt-safe command shape.
# NOT for a mid-pipeline worker waiting at a no-mistakes decision gate: that one
# is neither terminal nor waiting on anything external, the watcher recognizes it
# on its own from the authoritative run-step plus agent liveness
# (bin/fm-watch.sh's parked_gate_liveness_class), and a hand-placed marker here
# would keep muting that pane after the gate was answered.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
  echo "Usage: fm-mark-parked.sh <window>" >&2
  exit 2
fi

exec "$SCRIPT_DIR/fm-watch.sh" mark-parked "$1"
