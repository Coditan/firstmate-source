#!/usr/bin/env bash
# ripgrep --pre adapter for one compressed session file.
set -uo pipefail

exec zstd -dcq -- "$1"
