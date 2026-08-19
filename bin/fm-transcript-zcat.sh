#!/usr/bin/env bash
set -uo pipefail

ZSTD="${FM_ZSTD:-zstd}"
exec "$ZSTD" -dcq -- "$1"
