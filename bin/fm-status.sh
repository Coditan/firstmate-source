#!/usr/bin/env bash
# fm-status.sh - compose and append one status line for a task, from parts.
#
# Usage:
#   fm-status.sh <status-file> <verb> [--key <slug>] <note...>
#   fm-status.sh -h|--help
#
# This is the one write path a brief hands its worker for the task's own
# status file. The worker supplies the parts and never types the line grammar:
# the script composes exactly one of
#   <verb>: <note>
#   <verb> [key=<slug>]: <note>
# and appends it, newline-terminated, to <status-file>. The key token sits in
# the verb prefix, between the verb and the colon, which is the only position
# bin/fm-classify-lib.sh reads a key from; a key typed anywhere else by hand was
# read as "default" or dropped the line from the decision fold entirely.
#
# What it refuses, by name and without writing:
#   - a verb outside the worker vocabulary bin/fm-classify-lib.sh owns
#     (status_worker_verbs: working, needs-decision, blocked, failed, done, and
#     the configured resolve and pause verbs); captain-held is not a worker verb;
#   - a key that is not a privacy-safe slug (status_key_is_slug: non-empty,
#     only A-Z a-z 0-9 . _ -), or --key with no value;
#   - an empty note, or a note holding a newline, because a second line would
#     be a second event the readers classify on their own;
#   - a status file whose name is not <id>.status, or whose directory is not
#     this home's state/ (FM_STATE_OVERRIDE, else $FM_HOME/state, else the
#     state/ beside this script's bin/). The directory is compared by resolved
#     path, and the file itself is left as it is found: a Codex direct report's
#     public state/<id>.status is a symlink into its per-task writable signal
#     directory (docs/codex-status-signalling.md), and the append follows it.
# Every refusal prints one "fm-status: <reason>" line to stderr and exits 2.
#
# The append is one write of one line with O_APPEND, so two writers reaching
# the same file never interleave inside a line. After writing, the script reads
# the file's last line back and exits 1 naming the file if it is not the line
# just composed: a write that reported success while the public path led
# nowhere is the silent shape docs/codex-status-signalling.md records, and this
# is where it is caught. On success it prints "appended: <line>" to stdout and
# exits 0. Each append wakes firstmate, so callers report sparingly, as their
# brief says.
#
# Note text is opaque: the script never inspects it and never rewrites it, so
# a corr=<id> token, a PR URL, or a doc path in the note reaches the file
# verbatim. Nothing here alters any line already on disk.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

refuse() {
  printf 'fm-status: %s\n' "$*" >&2
  exit 2
}

[ $# -ge 3 ] || refuse "usage: fm-status.sh <status-file> <verb> [--key <slug>] <note...>"

STATUS_FILE=$1
VERB=$2
shift 2

KEY=''
KEY_GIVEN=0
if [ "${1:-}" = --key ]; then
  [ $# -ge 2 ] || refuse "--key needs a slug value"
  KEY=$2
  KEY_GIVEN=1
  shift 2
fi

status_verb_is_writable "$VERB" \
  || refuse "unknown status verb '$VERB'; the vocabulary is: $(status_worker_verbs)"

if [ "$KEY_GIVEN" = 1 ]; then
  status_key_is_slug "$KEY" || refuse "decision key must be a privacy-safe slug: $KEY"
fi

[ $# -ge 1 ] || refuse "a note is required after the verb"
NOTE=$*
case "$NOTE" in
  *$'\n'*|*$'\r'*) refuse "note must be one line" ;;
esac
stripped=${NOTE//[[:space:]]/}
[ -n "$stripped" ] || refuse "note must not be empty"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "$STATUS_FILE" in
  */) refuse "status file must be a file, not a directory: $STATUS_FILE" ;;
esac
base=${STATUS_FILE##*/}
case "$base" in
  *.status) ;;
  *) refuse "status file must be named <id>.status: $STATUS_FILE" ;;
esac
[ "$base" != .status ] || refuse "status file must be named <id>.status: $STATUS_FILE"

dir=${STATUS_FILE%/*}
[ "$dir" != "$STATUS_FILE" ] || dir=.
[ -d "$STATE" ] || refuse "this home's state/ does not exist: $STATE"
[ -d "$dir" ] || refuse "status file directory does not exist: $dir"
state_real=$(cd "$STATE" && pwd -P)
dir_real=$(cd "$dir" && pwd -P)
[ "$dir_real" = "$state_real" ] \
  || refuse "refusing to write outside this home's state/: $STATUS_FILE (state is $STATE)"

if [ "$KEY_GIVEN" = 1 ]; then
  LINE="$VERB [key=$KEY]: $NOTE"
else
  LINE="$VERB: $NOTE"
fi

printf '%s\n' "$LINE" >> "$STATUS_FILE"

last=$(tail -n 1 -- "$STATUS_FILE" 2>/dev/null || true)
if [ "$last" != "$LINE" ]; then
  printf 'fm-status: append reported success but %s does not end with the line: %s\n' "$STATUS_FILE" "$LINE" >&2
  exit 1
fi
printf 'appended: %s\n' "$LINE"
