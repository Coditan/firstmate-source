#!/usr/bin/env bash
# fm-transcript-refresh.sh - rebuild this home's searchable session derivative
# and verify it.
#
# A full rebuild costs about a minute and a half over a two-thousand-session
# store, so there is no incremental path and no build state that can go stale.
# The archive is rebuilt from the raw stores every time, then the detector is
# re-run against the output and required to return zero.
#
# The store is written compressed, one zstd file per session, and is searched by
# bin/fm-transcript-search.sh, which decompresses each session into grep. `zstd` is therefore a
# hard requirement of a rebuild: the reducer refuses rather than leaving a store
# that is half compressed and half plain. A rebuild also compresses whatever
# plain session files it finds already in the store, so an archive built before
# compression converges on the first refresh instead of being left behind.
#
# Usage:
#   fm-transcript-refresh.sh [--fold-injected] [--limit N] [--level N]
#
#   --fold-injected  codex only: fold machine-injected user messages down to
#                    their marker and their tail. It shrinks the Codex store by
#                    roughly a third of its size - and it drops redaction
#                    findings with it, because less of the material was ever
#                    looked at. Off by default for that reason.
#   --limit N        reduce only the first N files of each store (smoke runs).
#   --level N        zstd compression level; the default and the measurement
#                    behind it are in docs/session-archive.md.
#
# Paths, all overridable so this runs on a vessel that is not the one it was
# written on:
#   FM_HOME                 the operating home (default: this repo's root)
#   FM_TRANSCRIPT_ARCHIVE   where the derivative goes (default: $FM_HOME/data/transcripts)
#   FM_CLAUDE_SESSIONS      raw Claude sessions (default: $HOME/.claude/projects)
#   FM_CODEX_SESSIONS       raw Codex rollouts  (default: $HOME/.codex/sessions)
#
# The raw stores are read-only inputs: nothing under them is written, moved, or
# removed. A store that is not present on this vessel is reported and skipped,
# never treated as a store that was empty.
#
# Exit status is the first failure's: a refused reduction (wrong shape, nothing
# read) or a verification that found residual hits both fail the whole run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARCHIVE="${FM_TRANSCRIPT_ARCHIVE:-$DATA/transcripts}"
REDUCE="$SCRIPT_DIR/fm-transcript-reduce.py"

CLAUDE_IN="${FM_CLAUDE_SESSIONS:-$HOME/.claude/projects}"
CODEX_IN="${FM_CODEX_SESSIONS:-$HOME/.codex/sessions}"

fold=()
limit=()
level=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fold-injected) fold=(--fold-injected); shift;;
    --limit) limit=(--limit "${2:?--limit needs a number}"); shift 2;;
    --level) level=(--level "${2:?--level needs a number}"); shift 2;;
    -h|--help) sed -n '2,41p' "$0" | sed 's/^# \?//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

built=0
for s in claude codex; do
  case "$s" in
    claude) in_dir="$CLAUDE_IN"; extra=();;
    codex)  in_dir="$CODEX_IN";  extra=("${fold[@]}");;
  esac
  if [ ! -d "$in_dir" ]; then
    echo "skip $s: no raw store at $in_dir (not present on this vessel)" >&2
    continue
  fi
  echo "== reducing $s from $in_dir"
  python3 "$REDUCE" --source "$s" --in "$in_dir" --out "$ARCHIVE/$s-redacted" \
          --quiet "${extra[@]+"${extra[@]}"}" "${limit[@]+"${limit[@]}"}" \
          "${level[@]+"${level[@]}"}"
  built=1
done

if [ "$built" -eq 0 ]; then
  echo "no raw session store found on this vessel; nothing was built" >&2
  exit 3
fi

for s in claude codex; do
  [ -d "$ARCHIVE/$s-redacted" ] || continue
  echo "== verifying $s"
  python3 "$REDUCE" --verify-only --out "$ARCHIVE/$s-redacted"
done

# The honest bound travels ON the artefact, not only in a report: a report is
# read once and an archive is read for years. Written only when absent, so a
# rebuild never overwrites what someone added to it.
if [ ! -f "$ARCHIVE/README.md" ]; then
  cat >"$ARCHIVE/README.md" <<'EOF'
# Searchable session archive - this vessel only

A reduced, redacted derivative of the agent session transcripts on this machine,
built by `bin/fm-transcript-refresh.sh`. The raw stores are read-only inputs and
are not touched.

Per session, one plain-text file: a header, both conversation sides verbatim,
every command verbatim, and the first 400 characters of every tool result and
reasoning block. Everything else is discarded.

## The honest bound - do not drop this sentence

The derivative is verified: the same detector is re-run against the output and
must return zero hits. **That statement covers the derivative and nothing else.
What the reduction discarded was never examined for credentials at all.** The
raw stores remain unredacted where they are.

The archive keeps sessions the raw store no longer has, and that retention is intended.
A rebuild rewrites every session it can still read and removes nothing.
The archive does not mirror a deletion.

A second bound, equally binding: **the redaction is exactly as good as
`bin/fm-transcript-patterns/patterns.txt` and not one bit better.** What the
detector never knew, it never removed.

Every claim made from this archive travels with both bounds.

## How to search it

    bin/fm-transcript-search.sh 'some-identifier'
    bin/fm-transcript-search.sh 'a phrase' -C 2
    bin/fm-transcript-search.sh 'pattern' --since 2026-08-15 --cwd myproject
    bin/fm-transcript-search.sh 'pattern' --files-only

The sessions are zstd-compressed, one file each. **Plain `grep -r` does not read
them: it finds nothing here and says so as if the archive were empty.** Use the
wrapper, or read a session the same way it does if you want the raw tools:

    zstd -dcq some-session.txt.zst | grep 'pattern'

A full scan of the content is still what answers every query, so there is no
index here and none is to be added.

## Rebuild

    bin/fm-transcript-refresh.sh

Full detail: `docs/session-archive.md` in the firstmate repository.
EOF
  echo "== wrote $ARCHIVE/README.md (the honest bound, on the artefact)"
elif grep -qE 'Plain .?grep -r' "$ARCHIVE/README.md" 2>/dev/null &&
     ! grep -q 'zstd -dcq' "$ARCHIVE/README.md" 2>/dev/null; then
  # This README predates compression and still tells its reader that plain
  # grep works here. It does not: it returns nothing, with no error, over a
  # full archive. The file is not overwritten because someone may have written
  # into it, so the correction is named instead of made.
  echo "WARNING: $ARCHIVE/README.md still points readers at plain grep -r, which reads" >&2
  echo "         nothing from a compressed store and reports no error while doing it." >&2
  echo "         Correct that sentence: the wrapper, or zstd piped into grep, is what reads this archive." >&2
fi
