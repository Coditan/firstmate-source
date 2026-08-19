#!/usr/bin/env bash
# ripgrep --pre adapter for compressed and retained plain session files.
set -uo pipefail

case $1 in
  *.zst) exec zstd -dcq -- "$1" ;;
  *) exec cat -- "$1" ;;
esac
