#!/usr/bin/env bash
# fm-transcript-search.sh - look something up in this home's reduced session archive.
#
# Usage:
#   fm-transcript-search.sh <regex> [-C n] [-s claude|codex|all] [--since YYYY-MM-DD]
#                           [--cwd substring] [--files-only]
#
# Prints, per hit: the session's working directory and time span, the matching
# line with n lines of context, and the derivative path.
#
# GREP IS THE INDEX. The archive is plain UTF-8 text laid out one file per
# session, and a full-content scan of the whole store costs about a fifth of a
# second, so no inverted index exists and none should be added: a search index
# is a component that can be silently out of date, which is the exact failure
# this archive was built against. `_index.tsv` is not a search index - it
# narrows the FILE SET before grep runs, and only when --since or --cwd asks it
# to. Plain `grep -r` over the archive works identically for anyone who does not
# want this wrapper.
#
# The archive is this home's private material and never travels: it resolves
# under $FM_HOME/data/transcripts, so a secondmate home searches its own store
# and no vessel reads another's. FM_TRANSCRIPT_ARCHIVE overrides the location.
#
# Exit status is grep's: 0 when something matched, 1 when nothing did, 2 on a
# usage error or an archive that is not there.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARCHIVE="${FM_TRANSCRIPT_ARCHIVE:-$DATA/transcripts}"

usage() {
  cat <<'EOF'
usage: fm-transcript-search.sh <regex> [-C n] [-s claude|codex|all]
                               [--since YYYY-MM-DD] [--cwd substring] [--files-only]

  -C n          lines of context around each match (default 2)
  -s SOURCE     search one store or both: claude, codex, all (default all)
  --since DATE  only sessions whose first entry is on or after DATE
  --cwd SUBSTR  only sessions whose working directory contains SUBSTR
  --files-only  print matching session paths and nothing else
EOF
}

ctx=2; src=all; since=""; cwd=""; files_only=0; q=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) ctx="${2:?-C needs a number}"; shift 2;;
    -s) src="${2:?-s needs a source}"; shift 2;;
    --since) since="${2:?--since needs a date}"; shift 2;;
    --cwd) cwd="${2:?--cwd needs a substring}"; shift 2;;
    --files-only) files_only=1; shift;;
    -h|--help) usage; exit 0;;
    *) q="$1"; shift;;
  esac
done
[ -n "$q" ] || { usage >&2; exit 2; }

roots=()
case "$src" in
  claude) roots=("$ARCHIVE/claude-redacted");;
  codex)  roots=("$ARCHIVE/codex-redacted");;
  all)    roots=("$ARCHIVE/claude-redacted" "$ARCHIVE/codex-redacted");;
  *) echo "unknown source: $src" >&2; exit 2;;
esac

# An archive that is not there is reported as absent, never as "no matches":
# those two answers look identical to the caller and only one of them is true.
present=0
for r in "${roots[@]}"; do
  [ -d "$r" ] && present=1
done
if [ "$present" -eq 0 ]; then
  echo "no session archive under $ARCHIVE - build one with $SCRIPT_DIR/fm-transcript-refresh.sh" >&2
  exit 2
fi

# narrow the file set from the per-source index when asked
filelist="$(mktemp)"; trap 'rm -f "$filelist"' EXIT
for r in "${roots[@]}"; do
  [ -d "$r" ] || continue
  idx="$r/_index.tsv"
  if [ -f "$idx" ] && { [ -n "$since" ] || [ -n "$cwd" ]; }; then
    awk -F'\t' -v r="$r" -v since="$since" -v cwd="$cwd" '
      /^#/ {next}
      { if (since != "" && substr($2,1,10) < since) next
        if (cwd   != "" && index($4, cwd) == 0)     next
        print r "/" $1 }' "$idx" >> "$filelist"
  else
    find "$r" -name '*.txt' -type f >> "$filelist" 2>/dev/null
  fi
done

n=$(wc -l < "$filelist")
echo "# searching $n session files under: ${roots[*]}" >&2
[ "$n" -gt 0 ] || exit 1

if [ "$files_only" = 1 ]; then
  xargs -a "$filelist" -d '\n' grep -lE -- "$q" 2>/dev/null
  exit $?
fi

xargs -a "$filelist" -d '\n' grep -nHZE -C "$ctx" --color=never -- "$q" 2>/dev/null |
awk -F'\0' -v arch="$ARCHIVE" '
  /^--$/ { print "  --"; next }
  NF < 2 { next }
  {
    path=$1; rest=$2
    if (path != last) {
      cmd="sed -n \"1,8p\" \"" path "\" | grep -E \"^# (cwd|span)\" | sed \"s/^# *//\" | tr \"\\n\" \"|\""
      hdr=""; cmd | getline hdr; close(cmd)
      short=path; sub(arch "/", "", short)
      printf "\n=== %s\n    %s\n", short, hdr
      last=path
    }
    print "  " rest
  }'
