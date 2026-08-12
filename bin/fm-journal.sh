#!/usr/bin/env bash
# Read this home's append-only event journal.
#
# bin/fm-journal-lib.sh owns the record format, the retention bound, and the
# privacy contract; read its header before first use. This script is the read
# side only: it never writes a record, and there is deliberately no way to edit
# one, because a journal that can be corrected is not a record of what happened.
#
# It is bash and files. Reading costs no model call and needs no supervising
# session to be awake, which is the point: a consumer can be pointed at this and
# make a judgement without waking anything.
#
# Usage:
#   fm-journal.sh read [--since <seq>] [--kind <kind>] [--limit <n>]
#   fm-journal.sh status
#
# read     Print retained records in arrival order, oldest first, in the raw
#          seven-field record format. --since <seq> prints only records ABOVE
#          that sequence number, which is how a consumer tails the journal: keep
#          the last seq you handled and pass it back. --kind filters to one event
#          kind. --limit prints at most n records, taking the OLDEST matches so
#          a tailing consumer advances rather than skipping ahead.
#
# status   Print what the stream can and cannot account for: the retained
#          horizon, the last sequence, how many records are present, and any gap
#          between them. A gap means records were allocated a sequence and never
#          written - a failed write, a crash between the two - and it is
#          reported rather than smoothed over, so a reader is never left to
#          assume a stream is whole. Fields are "name: value", one per line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
  -h|--help|help|'')
    usage
    exit 0
    ;;
esac

since=0
kind=
limit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)
      since=${2:-}
      shift 2 || true
      case "$since" in ''|*[!0-9]*) echo "fm-journal.sh: --since needs a sequence number" >&2; exit 2 ;; esac
      ;;
    --kind)
      kind=${2:-}
      shift 2 || true
      fm_journal_kind_valid "$kind" || { echo "fm-journal.sh: unknown event kind: $kind" >&2; exit 2; }
      ;;
    --limit)
      limit=${2:-}
      shift 2 || true
      case "$limit" in ''|*[!0-9]*) echo "fm-journal.sh: --limit needs a count" >&2; exit 2 ;; esac
      ;;
    *)
      echo "fm-journal.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$cmd" in
  read)
    fm_journal_cat | LC_ALL=C awk -F '\t' \
      -v since="$since" -v want="$kind" -v limit="$limit" '
      NF >= 7 && $1 + 0 > since && (want == "" || $3 == want) {
        if (limit > 0 && ++shown > limit) { exit }
        print
      }
    '
    ;;
  status)
    fm_journal_cat | LC_ALL=C awk -F '\t' -v maxbytes="$FM_JOURNAL_MAX_BYTES" '
      NF >= 7 {
        seq = $1 + 0
        if (!count || seq < horizon) { horizon = seq }
        if (seq > last) { last = seq }
        count++
      }
      END {
        printf "records: %d\n", count
        if (!count) {
          print "horizon: none"
          print "last: none"
          print "gaps: 0"
        } else {
          printf "horizon: %d\n", horizon
          printf "last: %d\n", last
          printf "gaps: %d\n", (last - horizon + 1) - count
        }
        printf "retention: at most two files of %d bytes; records below the horizon are gone\n", maxbytes
      }
    '
    ;;
  *)
    echo "fm-journal.sh: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
