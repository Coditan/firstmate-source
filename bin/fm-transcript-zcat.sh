#!/usr/bin/env bash
# fm-transcript-zcat.sh - read one session file from the archive, whatever
# shape it is in: compressed sessions come back through zstd, and a plain one
# left from a store built before compression comes back as it is.
#
# One owner for that decision, because the scan and the session-header read
# must never disagree about how a file is read.
set -uo pipefail

case $1 in
  *.zst) exec zstd -dcq -- "$1" ;;
  *) exec cat -- "$1" ;;
esac
