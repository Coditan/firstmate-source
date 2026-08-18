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
# A FULL CONTENT SCAN IS THE INDEX. The archive is UTF-8 text laid out one file
# per session, zstd-compressed, and a scan of the whole store costs well under a
# second, so no inverted index exists and none should be added: a search index is
# a component that can be silently out of date, which is the exact failure this
# archive was built against. `_index.tsv` is not a search index - it narrows the
# FILE SET before the scan runs, and only when --since or --cwd asks it to.
#
# THE STORE IS COMPRESSED, SO PLAIN `grep -r` NO LONGER READS IT. It matches
# nothing here and exits as though the archive were empty, which is the one
# answer this archive must never give. The scan therefore runs through ripgrep's
# `-z`, and `rg` is a hard requirement: a missing one is reported as a missing
# tool, never as a search that found nothing. Anyone who would rather not use
# this wrapper runs `rg -z <pattern>` over the archive directory directly and
# gets the same content scan. FM_RG and FM_ZSTD name the two binaries on a
# vessel where they sit elsewhere.
#
# The archive is this home's private material and never travels: it resolves
# under $FM_HOME/data/transcripts, so a secondmate home searches its own store
# and no vessel reads another's. FM_TRANSCRIPT_ARCHIVE overrides the location.
#
# Exit status: 0 when something matched, 1 when nothing did, 2 on a usage error,
# a missing archive, or a missing decompressing search tool.
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

# The searcher is named before anything else is done, because "no matches" and
# "the tool that reads this store is not installed" are the same output to a
# caller and only one of them is true.
RG="${FM_RG:-rg}"
ZSTD="${FM_ZSTD:-zstd}"
for tool in "$RG" "$ZSTD"; do
  command -v "$tool" >/dev/null 2>&1 && continue
  echo "$tool is not installed, and the session store is compressed: this search cannot run." >&2
  echo "Install ripgrep and zstd (apt install ripgrep zstd), or point FM_RG and FM_ZSTD at them." >&2
  echo "Refusing rather than reporting no matches over an archive that was never read." >&2
  exit 2
done
# A user ripgrep config can change what a search means - case folding, column
# limits, skipped files - and this store's answers must not depend on it.
export RIPGREP_CONFIG_PATH=

# narrow the file set from the per-source index when asked
filelist="$(mktemp)"; trap 'rm -f "$filelist"' EXIT
for r in "${roots[@]}"; do
  [ -d "$r" ] || continue
  idx="$r/_index.tsv"
  if [ -f "$idx" ] && { [ -n "$since" ] || [ -n "$cwd" ]; }; then
    # An index written before the store was compressed names the plain file, so
    # the compressed sibling is accepted for the same session: a stale name must
    # narrow to the session it meant, not to nothing.
    awk -F'\t' -v r="$r" -v since="$since" -v cwd="$cwd" '
      /^#/ {next}
      { if (since != "" && substr($2,1,10) < since) next
        if (cwd   != "" && index($4, cwd) == 0)     next
        print r "/" $1 }' "$idx" |
    while IFS= read -r f; do
      if [ -f "$f" ]; then printf '%s\n' "$f"
      elif [ -f "$f.zst" ]; then printf '%s\n' "$f.zst"
      elif [ "${f%.zst}" != "$f" ] && [ -f "${f%.zst}" ]; then printf '%s\n' "${f%.zst}"
      fi
    done >> "$filelist"
  else
    # Both shapes are listed: a store mid-migration must not go half unsearched.
    find "$r" \( -name '*.txt.zst' -o -name '*.txt' \) -type f >> "$filelist" 2>/dev/null
  fi
done

n=$(wc -l < "$filelist")
echo "# searching $n session files under: ${roots[*]}" >&2
[ "$n" -gt 0 ] || exit 1

# The file set is handed over in batches, so a batch with no hit exits non-zero
# while another batch matched. What the caller is told is whether the SEARCH
# matched, decided by what came out of it, not by the status of one batch.
if [ "$files_only" = 1 ]; then
  xargs -a "$filelist" -d '\n' "$RG" -lz --no-messages -e "$q" -- 2>/dev/null |
  awk 'NF { print; found=1 } END { exit(found ? 0 : 1) }'
  exit "${PIPESTATUS[1]}"
fi

xargs -a "$filelist" -d '\n' "$RG" -z -n -H --null --no-heading --color never \
      --no-messages -C "$ctx" -e "$q" -- 2>/dev/null |
awk -F'\0' -v arch="$ARCHIVE" -v zstd="$ZSTD" '
  /^--$/ { print "  --"; next }
  NF < 2 { next }
  {
    path=$1; rest=$2
    if (path != last) {
      # The session header is read the same way the store is: through the
      # decompressor when the file is compressed, plainly when it is not.
      if (path ~ /\.zst$/)
        cmd=zstd " -dcq -- \"" path "\" | sed -n \"1,8p\""
      else
        cmd="sed -n \"1,8p\" \"" path "\""
      cmd = cmd " | grep -E \"^# (cwd|span)\" | sed \"s/^# *//\" | tr \"\\n\" \"|\""
      hdr=""; cmd | getline hdr; close(cmd)
      short=path; sub(arch "/", "", short)
      printf "\n=== %s\n    %s\n", short, hdr
      last=path
      found=1
    }
    print "  " rest
  }
  END { exit(found ? 0 : 1) }'
exit "${PIPESTATUS[1]}"
