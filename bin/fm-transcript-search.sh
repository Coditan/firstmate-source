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
# per session, zstd-compressed, and a scan of the whole store costs about one and
# a half seconds for the file list, or two and a half with context. No inverted index exists and none should be added: a search
# index is a component that can be silently out of date, which is the exact
# failure this archive was built against. `_index.tsv` is not a search index - it
# narrows the FILE SET before the scan runs, and only when --since or --cwd asks
# it to.
#
# THE STORE IS COMPRESSED, SO PLAIN `grep -r` NO LONGER READS IT. It matches
# nothing here and exits as though the archive were empty, which is the one
# answer this archive must never give. The scan therefore decompresses each
# session and pipes it into grep, one file at a time, spread across the
# machine's cores.
#
# THE TOOLS THIS SEARCH REQUIRES ARE `zstd`, `grep` and `xargs`, all on PATH,
# and a missing one is reported as a missing tool rather than as a search that
# found nothing. That list is deliberately short. An earlier version scanned
# with ripgrep, whose behaviour differed from machine to machine - which flags
# its build supported, whether it could decompress at all - and twice reported
# an empty result over a full archive because of it. A search tool that answers
# differently depending on the machine it runs on is the same silent
# disagreement this archive exists to refuse, so the dependency is gone rather
# than pinned. No override names any of these tools either, for the same reason:
# one knob governing only part of the process twice passed its own prerequisite
# check before the scan read nothing.
#
# Anyone who would rather not use this wrapper reads a session the same way it
# does - `zstd -dcq <session>.txt.zst | grep <pattern>` - and gets the same
# content scan.
#
# The archive is this home's private material and never travels: it resolves
# under $FM_HOME/data/transcripts, so a secondmate home searches its own store
# and no vessel reads another's. FM_TRANSCRIPT_ARCHIVE overrides the location.
#
# Exit status: 0 when something matched, 1 when nothing did, 2 on a usage error,
# a missing archive, a missing decompressing search tool, or a scanner failure.
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

# The tools are named before anything else is done, because "no matches" and
# "the tool that reads this store is not installed" are the same output to a
# caller and only one of them is true.
ZSTD=zstd
READER="$SCRIPT_DIR/fm-transcript-zcat.sh"
for tool in "$ZSTD" grep xargs; do
  command -v "$tool" >/dev/null 2>&1 && continue
  echo "$tool is not installed, and the session store is compressed: this search cannot run." >&2
  echo "Install zstd (apt install zstd); grep and xargs are expected on any machine that runs this." >&2
  echo "Refusing rather than reporting no matches over an archive that was never read." >&2
  exit 2
done
[ -x "$READER" ] || { echo "missing session reader: $READER" >&2; exit 2; }

# One scan per core. A machine that will not say how many it has gets a modest
# default rather than an unbounded fan-out.
jobs=$(nproc 2>/dev/null || echo 4)
case "$jobs" in ''|*[!0-9]*) jobs=4;; esac
[ "$jobs" -ge 1 ] || jobs=1

# narrow the file set from the per-source index when asked
filelist="$(mktemp)"
# Each parallel worker writes its own file rather than into a shared pipe.
# Buffered writes from concurrent workers interleave at block boundaries, not at
# line boundaries, which split lines in half: measured on this archive as three
# runs of one query returning 8121, 8105 and 8104 lines, with header lines cut
# mid-path. A search whose answer changes between runs is not a search.
partdir="$(mktemp -d)"
trap 'rm -rf "$filelist" "$partdir"' EXIT
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
    statuses=("${PIPESTATUS[@]}")
    if [ "${statuses[0]}" -ne 0 ] || [ "${statuses[1]}" -ne 0 ]; then
      echo "could not gather searchable sessions from $idx" >&2
      exit 2
    fi
  else
    # Both shapes are listed: a store mid-migration must not go half unsearched.
    if ! find "$r" \( -name '*.txt.zst' -o -name '*.txt' \) -type f >> "$filelist" 2>/dev/null; then
      echo "could not gather searchable sessions under $r" >&2
      exit 2
    fi
  fi
done

n=$(wc -l < "$filelist")
echo "# searching $n session files under: ${roots[*]}" >&2
[ "$n" -gt 0 ] || exit 1

# The file set is handed over in batches, spread across cores. Two rules hold
# inside a batch, and both were learned from a defect rather than designed in.
#
# EVERY SESSION IS READ THROUGH, so a non-zero reader status is always a genuine
# failure to read the store. grep must not stop at the first match: doing so
# closes the reader's pipe early and makes its status describe the closed pipe
# rather than the file. Both search paths therefore consume the whole session
# before deciding whether it matched.
#
# Both ways of getting this wrong have been measured on this branch. Requiring
# the reader to exit 0 returned 0 matching sessions where 75 were expected, over
# a full archive. Accepting only signal 141 made a search that matched every
# session exit 2 on a machine whose zstd reports a closed pipe differently. A
# search that lies about whether it worked is the same defect either way round.
#
# A genuine no-match must not stop the scan. It is normalised to success inside
# the batch so xargs keeps going, and what the completed search actually found
# decides the exit status at the end.
if [ "$files_only" = 1 ]; then
  # shellcheck disable=SC2016
  xargs -a "$filelist" -d '\n' -P "$jobs" -n 16 bash -c '
    reader=$1; pattern=$2; partdir=$3; shift 3
    part="$partdir/part.$$"
    for path do
      "$reader" "$path" | grep -aE -e "$pattern" >/dev/null
      statuses=("${PIPESTATUS[@]}")
      case ${statuses[1]} in
        0) matched=1 ;;
        1) matched=0 ;;
        *) exit 255 ;;
      esac
      [ "${statuses[0]}" -eq 0 ] || exit 255
      [ "$matched" -eq 0 ] || printf "%s\n" "$path" >>"$part"
    done
  ' _ "$READER" "$q" "$partdir" || exit 2
  find "$partdir" -type f -exec cat {} + 2>/dev/null |
  sort |
  awk 'NF { print; found=1 } END { exit(found ? 0 : 1) }'
  statuses=("${PIPESTATUS[@]}")
  if [ "${statuses[0]}" -ne 0 ] || [ "${statuses[1]}" -ne 0 ]; then
    exit 2
  fi
  exit "${statuses[2]}"
fi

# The scan reads every session as text (-a). A reduced session is UTF-8 by
# construction, but a stray control byte from the material it quotes makes grep
# call the whole file binary and print no lines at all - measured here as five
# sessions that contain the term reported by --files-only and missing from the
# context output, which is a search quietly disagreeing with itself.
#
# Every emitted line carries its own session path, including the separators
# between context groups, so parallel batches cannot misattribute a line. The
# stable sort then gathers each session's lines back together - equal keys keep
# their arrival order, so a session's own lines stay in file order - and the
# reader below prints one header per session.
# shellcheck disable=SC2016
xargs -a "$filelist" -d '\n' -P "$jobs" -n 16 bash -c '
  reader=$1; context=$2; pattern=$3; partdir=$4; shift 4
  part="$partdir/part.$$"
  for path do
    "$reader" "$path" |
      grep -naE -C "$context" -e "$pattern" |
      awk -v path="$path" '\''{ printf "%c%s%c%s\n", 28, path, 28, $0 }'\'' >>"$part"
    statuses=("${PIPESTATUS[@]}")
    case ${statuses[1]} in 0|1) ;; *) exit 255;; esac
    # grep -C reads the session through whether or not it matched, so here the
    # reader always had its chance and its status always carries information.
    [ "${statuses[0]}" -eq 0 ] || exit 255
    [ "${statuses[2]}" -eq 0 ] || exit 255
  done
' _ "$READER" "$ctx" "$q" "$partdir" || exit 2
find "$partdir" -type f -exec cat {} + 2>/dev/null |
sort -s -t "$(printf '\034')" -k2,2 |
awk -v arch="$ARCHIVE" -v zstd="$ZSTD" '
  function shell_quote(s, out, i, c) {
    out="\""
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1)
      if (c=="\\" || c=="\"" || c=="$" || c=="`") out=out "\\" c
      else out=out c
    }
    return out "\""
  }
  substr($0, 1, 1) != sprintf("%c", 28) { next }
  {
    record=substr($0, 2)
    split_at=index(record, sprintf("%c", 28))
    if (!split_at) next
    path=substr(record, 1, split_at - 1)
    rest=substr(record, split_at + 1)
    if (path != last) {
      # The session header is read the same way the store is: through the
      # decompressor when the file is compressed, plainly when it is not.
      if (path ~ /\.zst$/)
        cmd=shell_quote(zstd) " -dcq -- " shell_quote(path) " | sed -n \"1,8p\""
      else
        cmd="sed -n \"1,8p\" " shell_quote(path)
      cmd = cmd " | grep -E \"^# (cwd|span)\" | sed \"s/^# *//\" | tr \"\\n\" \"|\""
      hdr=""; cmd | getline hdr; close(cmd)
      short=path; sub(arch "/", "", short)
      printf "\n=== %s\n    %s\n", short, hdr
      last=path
      found=1
    }
    if (rest == "--") print "  --"
    else print "  " rest
  }
  END { exit(found ? 0 : 1) }'
statuses=("${PIPESTATUS[@]}")
if [ "${statuses[0]}" -ne 0 ] || [ "${statuses[1]}" -ne 0 ]; then
  exit 2
fi
exit "${statuses[2]}"
