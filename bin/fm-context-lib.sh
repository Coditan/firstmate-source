#!/usr/bin/env bash
# fm-context-lib.sh - the single owner of the context-ceiling predicates shared
# by the watcher (which measures and enqueues), bin/fm-stow-receipt.sh (which
# binds a receipt to the transcript position), and bin/fm-context-reset.sh
# (which re-verifies everything and clears).
#
# WHY ONE LIBRARY
# The watcher decides "reset or ask"; the reset tool decides "proceed or refuse".
# Those two must agree on what "over ceiling", "quiet", and "captain active"
# mean, or the watcher enqueues a reset the tool then always refuses (or worse,
# the reverse). One definition, three consumers.
#
# WHAT IS READ FROM THE TRANSCRIPT, AND WHAT IS NOT
# Only three things: the last assistant record's token `usage` numbers, the
# timestamp of the last genuine captain prompt, and the file's byte size. Message
# CONTENT is never read and never printed. That is a hard constraint - the
# watcher runs unattended and its output lands in wake payloads - and it is
# enforceable here because Claude Code stamps every user record with a structural
# `origin.kind`, so provenance needs no text inspection at all (see
# fm_context_scan).
#
# docs/context-reset.md owns the mechanism narrative, the verified evidence, and
# the limits. This file owns the predicates; each consumer script's header owns
# its own flags and exit codes.
#
# This file is sourced by its callers and has no side effects on source.

_FM_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CONTEXT_LIB_DIR="."

# Shared status-file classifier, for the open-decision half of the quiet
# predicate. Its status readers are pure file reads; nothing here calls the
# crew-state path that would make a poll expensive.
if ! declare -F status_open_decisions >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_CONTEXT_LIB_DIR/fm-classify-lib.sh"
fi

# The captain's decided ceiling (data/decisions/2026-08-02-supervision-cost-two-decisions.md).
FM_CONTEXT_CEILING="${FM_CONTEXT_CEILING:-300000}"
# Seconds since the last genuine captain prompt below which the captain counts as
# in live conversation. The proven cost of resetting then is a wiped scrollback
# and a queued message answered into a context that is immediately discarded, so
# this window is deliberately generous.
FM_CONTEXT_CAPTAIN_IDLE_SECS="${FM_CONTEXT_CAPTAIN_IDLE_SECS:-1800}"
# How long a stow receipt stays fresh, and how far the transcript may advance
# under it. Both are small because the receipt and the reset are meant to happen
# in ONE firstmate turn; anything larger means the session moved on and the
# receipt no longer describes what is about to be discarded.
FM_CONTEXT_RECEIPT_MAX_AGE="${FM_CONTEXT_RECEIPT_MAX_AGE:-900}"
FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES="${FM_CONTEXT_RECEIPT_MAX_GROWTH_BYTES:-262144}"
# Trailing bytes of the transcript scanned for the last usage record and the last
# captain prompt. Bounded so a multi-hundred-megabyte transcript cannot turn one
# watcher poll into an unbounded read.
FM_CONTEXT_TAIL_BYTES="${FM_CONTEXT_TAIL_BYTES:-2097152}"

fm_context_record_path() {  # <state-dir>
  printf '%s/.primary-transcript' "$1"
}

fm_context_receipt_path() {  # <state-dir>
  printf '%s/.stow-receipt' "$1"
}

# Read one key from a key=value record. Values may contain "="; keys may not.
fm_context_kv() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# Return 0 when <pid> is this process's own ancestor within eight generations.
# This answers "is the session that wrote this record the session I am running
# in", NOT "which ancestor is a harness" - harness IDENTIFICATION is owned by
# bin/fm-lock.sh and bin/fm-sessionstart-nudge.sh, and the pid it produces is
# what this function re-verifies. It exists because the reset tool is about to
# type into the pane it inherited, and typing a discard into a pane that belongs
# to a different session is the worst failure this mechanism can have.
fm_context_pid_in_ancestry() {  # <pid>
  local want=$1 pid=$$ _
  case "$want" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$want" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

fm_context_file_bytes() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

# Print an ISO-8601 UTC instant for <epoch>, second precision, no fraction.
# Transcript timestamps are ISO-8601 UTC with a Z suffix and milliseconds, so a
# plain lexicographic comparison against this string is a correct recency test
# and needs no ISO parsing (which has no portable form across GNU and BSD date).
# A same-second timestamp compares as NEWER, which biases every borderline read
# toward "the captain is active" - the safe direction.
fm_context_iso_utc() {  # <epoch>
  if [ "$(uname)" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null
  fi
}

# Print whole lines from the last <bytes> of <path>, discarding the partial first
# line so every emitted line is parseable. O_NOFOLLOW because the path comes out
# of a state record.
fm_context_tail_lines() {  # <path> <bytes>
  perl -MFcntl=:DEFAULT -e '
    my ($path, $limit) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat $fh or exit 1;
    exit 1 unless -f _;
    my $size = $st[7];
    my $start = $size > $limit ? $size - $limit : 0;
    seek($fh, $start, 0) or exit 1;
    my $buf = "";
    while (read($fh, my $chunk, 1 << 20)) { $buf .= $chunk }
    if ($start > 0) {
      my $nl = index($buf, "\n");
      exit 0 if $nl < 0;
      $buf = substr($buf, $nl + 1);
    }
    print $buf;
  ' "$1" "$2" 2>/dev/null
}

# Return 0 when a live session holds this home's session lock, and publish its
# pid. This is what separates "a firstmate session is running here and I cannot
# measure it" - a real defect worth reporting - from "there is no session here to
# measure", which is the ordinary state of a fresh home, a home between sessions,
# and every home that is not a primary. Reporting the second as a fault would put
# a standing false alarm in homes that are behaving perfectly.
FM_CONTEXT_LOCK_PID=
fm_context_session_live() {  # <state-dir>
  local pid
  FM_CONTEXT_LOCK_PID=
  pid=$(cat "$1/.lock" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  FM_CONTEXT_LOCK_PID=$pid
  return 0
}

# Read the primary-transcript record written by bin/fm-sessionstart-nudge.sh.
# Sets FM_CONTEXT_TRANSCRIPT, FM_CONTEXT_SESSION_ID, FM_CONTEXT_RECORD_PID.
# Returns 1 with FM_CONTEXT_RECORD_ERROR set when the record is absent, in its
# explicit error state, or structurally incomplete. An absent record is a
# REPORTABLE condition, not a silent skip: without it nothing can be measured,
# which is exactly the invisible non-enforcement this mechanism exists to remove.
FM_CONTEXT_TRANSCRIPT=
FM_CONTEXT_SESSION_ID=
FM_CONTEXT_RECORD_PID=
FM_CONTEXT_RECORD_ERROR=
fm_context_record_read() {  # <state-dir>
  local state=$1 record status
  FM_CONTEXT_TRANSCRIPT=
  FM_CONTEXT_SESSION_ID=
  FM_CONTEXT_RECORD_PID=
  FM_CONTEXT_RECORD_ERROR=
  record=$(fm_context_record_path "$state")
  if [ ! -f "$record" ]; then
    FM_CONTEXT_RECORD_ERROR="no session transcript recorded at $record"
    return 1
  fi
  status=$(fm_context_kv "$record" status || true)
  if [ "$status" != ok ]; then
    FM_CONTEXT_RECORD_ERROR="session transcript record is in error state: $(fm_context_kv "$record" error || printf 'unspecified')"
    return 1
  fi
  FM_CONTEXT_TRANSCRIPT=$(fm_context_kv "$record" transcript_path || true)
  FM_CONTEXT_SESSION_ID=$(fm_context_kv "$record" session_id || true)
  FM_CONTEXT_RECORD_PID=$(fm_context_kv "$record" harness_pid || true)
  case "$FM_CONTEXT_TRANSCRIPT" in
    /*) ;;
    *) FM_CONTEXT_RECORD_ERROR="recorded transcript path is not absolute"; return 1 ;;
  esac
  if [ ! -f "$FM_CONTEXT_TRANSCRIPT" ]; then
    FM_CONTEXT_RECORD_ERROR="recorded transcript $FM_CONTEXT_TRANSCRIPT does not exist"
    return 1
  fi
  case "$FM_CONTEXT_RECORD_PID" in
    ''|*[!0-9]*) FM_CONTEXT_RECORD_ERROR="recorded harness pid is not numeric"; return 1 ;;
  esac
  [ -n "$FM_CONTEXT_SESSION_ID" ] || { FM_CONTEXT_RECORD_ERROR="recorded session id is empty"; return 1; }
  return 0
}

# Scan the bounded transcript tail once and publish both measurements:
#   FM_CONTEXT_TOKENS         last assistant record's input + cache-creation +
#                             cache-read tokens (what the window actually holds)
#   FM_CONTEXT_LAST_HUMAN_TS  timestamp of the last genuine captain prompt, or
#                             empty when the tail holds none
#
# Provenance is structural, never textual. Claude Code marks a typed captain
# prompt `origin.kind == "human"`; a background-task wake delivery is
# `origin.kind == "task-notification"` with `promptSource == "system"`; hook and
# system injections carry `isMeta: true`; tool results carry array content. The
# one remaining shape - a string-content user record with neither origin nor
# promptSource - is a slash-command expansion that only ever follows real captain
# input, so it counts as human. Every ambiguity resolves toward "the captain is
# here", because the cost of a false quiet is a discarded conversation and the
# cost of a false busy is one deferred reset.
FM_CONTEXT_TOKENS=
FM_CONTEXT_LAST_HUMAN_TS=
FM_CONTEXT_SCAN_ERROR=
fm_context_scan() {  # <transcript-path>
  local transcript=$1 out
  FM_CONTEXT_TOKENS=
  FM_CONTEXT_LAST_HUMAN_TS=
  FM_CONTEXT_SCAN_ERROR=
  if ! command -v jq >/dev/null 2>&1; then
    FM_CONTEXT_SCAN_ERROR="jq is not installed; the transcript cannot be measured"
    return 1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    FM_CONTEXT_SCAN_ERROR="perl is not installed; the transcript cannot be measured"
    return 1
  fi
  out=$(fm_context_tail_lines "$transcript" "$FM_CONTEXT_TAIL_BYTES" | jq -R -n -r '
    [inputs | fromjson? // empty] as $rows
    | ( [ $rows[]
          | select(.type == "assistant" and (.message.usage | type) == "object")
          | ((.message.usage.input_tokens // 0)
             + (.message.usage.cache_creation_input_tokens // 0)
             + (.message.usage.cache_read_input_tokens // 0)) ] | last ) as $tokens
    | ( [ $rows[]
          | select(.type == "user")
          | select(.isMeta != true)
          | select((.message.content | type) == "string")
          | select(.origin.kind == "human" or (.origin == null and .promptSource == null))
          | .timestamp ] | last ) as $human
    | "\($tokens // "")\t\($human // "")"
  ' 2>/dev/null) || {
    FM_CONTEXT_SCAN_ERROR="could not parse the transcript tail of $transcript"
    return 1
  }
  FM_CONTEXT_TOKENS=${out%%	*}
  FM_CONTEXT_LAST_HUMAN_TS=${out#*	}
  case "$FM_CONTEXT_TOKENS" in
    ''|*[!0-9]*)
      FM_CONTEXT_TOKENS=
      FM_CONTEXT_SCAN_ERROR="no token usage record in the last ${FM_CONTEXT_TAIL_BYTES} bytes of $transcript"
      return 1
      ;;
  esac
  return 0
}

# Return 0 when the captain counts as in live conversation.
# An unreadable or absent timestamp returns 1 (not active): the tail genuinely
# holds no captain prompt, which is the quiet case. A malformed one returns 0,
# because a value that cannot be understood must not be read as silence.
fm_context_captain_active() {  # <last-human-ts>
  local ts=$1 threshold
  [ -n "$ts" ] || return 1
  threshold=$(fm_context_iso_utc "$(( $(date +%s) - FM_CONTEXT_CAPTAIN_IDLE_SECS ))") || return 0
  [ -n "$threshold" ] || return 0
  case "$ts" in
    [0-9][0-9][0-9][0-9]-*) ;;
    *) return 0 ;;
  esac
  [ "$ts" \> "$threshold" ]
}

# Return 0 when the fleet is quiet enough to discard a session's context.
# Sets FM_CONTEXT_NOT_QUIET to the concrete reason otherwise. Every input is a
# cheap file read, so this is safe on the watcher's poll cadence.
# Away mode is deliberately NOT folded in here: it is a separate branch that the
# watcher and the reset tool each answer differently.
FM_CONTEXT_NOT_QUIET=
fm_context_quiet() {  # <state-dir>
  local state=$1 f id open
  FM_CONTEXT_NOT_QUIET=
  if [ -s "$state/.wake-queue" ]; then
    FM_CONTEXT_NOT_QUIET="a queued wake is still undrained"
    return 1
  fi
  for f in "$state"/pending-replies/*; do
    [ -e "$f" ] || continue
    FM_CONTEXT_NOT_QUIET="a routed request is still awaiting its reply"
    return 1
  done
  for f in "$state"/*.status; do
    [ -f "$f" ] || continue
    open=$(status_open_decisions "$f")
    [ -n "$open" ] || continue
    id=${f##*/}
    # shellcheck disable=SC2034 # Read by callers after fm_context_quiet returns.
    FM_CONTEXT_NOT_QUIET="work ${id%.status} is still waiting on an answer"
    return 1
  done
  return 0
}

# Return 0 when the post-reset re-entry hook is still WIRED: the SessionStart
# matcher still contains `clear`, it still runs bin/fm-sessionstart-nudge.sh, and
# that script is still present and executable. Sets FM_CONTEXT_RESTART_ERROR
# otherwise.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT. It proves the hook is wired and its
# script is there. It does NOT prove a rebuild instruction is delivered: the
# nudge exits silently whenever the pid in state/.lock is in its ancestry, and
# state/.lock holds the harness process pid, which a self-clear does not restart.
# So on the self-clear this mechanism performs, the hook fires and injects
# nothing, and the fresh session rebuilds from AGENTS.md section 3 - always
# loaded, and already instructing it to run bin/fm-session-start.sh. That is the
# weaker of the two paths; making the nudge emit on a `source=clear` payload is
# filed as separate work on that script.
#
# It stays a hard precondition anyway, because what it catches is the total loss:
# the hook unwired from `clear`, or the script removed outright. It is one jq
# read, and the fallback above is the only thing standing behind it.
FM_CONTEXT_RESTART_ERROR=
fm_context_restart_path_ok() {  # <fm-home> <fm-root>
  local home=$1 root=$2 settings nudge
  FM_CONTEXT_RESTART_ERROR=
  settings="$home/.claude/settings.json"
  nudge="$root/bin/fm-sessionstart-nudge.sh"
  if ! command -v jq >/dev/null 2>&1; then
    FM_CONTEXT_RESTART_ERROR="jq is not installed; the re-entry hook cannot be verified"
    return 1
  fi
  if [ ! -f "$settings" ]; then
    FM_CONTEXT_RESTART_ERROR="no hook settings at $settings"
    return 1
  fi
  if ! jq -e '
        (.hooks.SessionStart // [])
        | map(select((.matcher // "") | test("clear")))
        | map(.hooks // [] | map(.command // "") | join(" "))
        | join(" ")
        | test("fm-sessionstart-nudge\\.sh")
      ' "$settings" >/dev/null 2>&1; then
    FM_CONTEXT_RESTART_ERROR="the session-start hook in $settings no longer runs fm-sessionstart-nudge.sh on a clear"
    return 1
  fi
  if [ ! -x "$nudge" ]; then
    FM_CONTEXT_RESTART_ERROR="the session-start hook script $nudge is missing or not executable"
    return 1
  fi
  return 0
}

# Compose the watcher's context-ceiling wake reason, or print nothing when there
# is nothing to say. Printed reasons, all on the "check" wake kind:
#   ... cannot measure ...  the recorded transcript is missing or unreadable, so
#                           the ceiling is UNENFORCED and an observer must see it
#   ... ask the captain     over ceiling and quiet, but the captain is in live
#                           conversation or away mode owns delivery
#   ... reset               over ceiling, quiet, and the captain is not present
# Under the ceiling, or over it while the fleet is busy, it prints nothing: that
# is an ordinary quiet poll, not a suppressed alarm.
fm_context_ceiling_reason() {  # <state-dir> <fm-home> <fm-root>
  local state=$1 home=$2 root=$3 branch
  # Nothing running here means nothing to measure, and nothing to report.
  fm_context_session_live "$state" || return 0
  if ! fm_context_record_read "$state"; then
    printf 'check: context-ceiling: a firstmate session is running here but its context cannot be measured (%s); the %s ceiling is unenforced until that is repaired' \
      "$FM_CONTEXT_RECORD_ERROR" "$FM_CONTEXT_CEILING"
    return 0
  fi
  # The session lock and the transcript record are keyed on the same session
  # process on purpose, so a disagreement means the record describes a session
  # that is no longer the one running - and measuring it would report the wrong
  # number rather than no number.
  if [ "$FM_CONTEXT_RECORD_PID" != "$FM_CONTEXT_LOCK_PID" ]; then
    printf 'check: context-ceiling: the recorded transcript belongs to session process %s but session process %s is the one running here; the %s ceiling is unenforced until this session records its transcript again' \
      "$FM_CONTEXT_RECORD_PID" "$FM_CONTEXT_LOCK_PID" "$FM_CONTEXT_CEILING"
    return 0
  fi
  if ! fm_context_scan "$FM_CONTEXT_TRANSCRIPT"; then
    printf 'check: context-ceiling: a firstmate session is running here but its context cannot be measured (%s); the %s ceiling is unenforced until that is repaired' \
      "$FM_CONTEXT_SCAN_ERROR" "$FM_CONTEXT_CEILING"
    return 0
  fi
  [ "$FM_CONTEXT_TOKENS" -ge "$FM_CONTEXT_CEILING" ] || return 0
  fm_context_quiet "$state" || return 0
  branch=reset
  [ -e "$state/.afk" ] && branch=ask
  fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS" && branch=ask
  if ! fm_context_restart_path_ok "$home" "$root"; then
    printf 'check: context-ceiling: %s tokens is over the %s ceiling, but a reset cannot run safely: %s' \
      "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING" "$FM_CONTEXT_RESTART_ERROR"
    return 0
  fi
  if [ "$branch" = ask ]; then
    printf 'check: context-ceiling: %s tokens is over the %s ceiling and the fleet is quiet, but the captain has been active - ASK the captain before resetting; never reset autonomously during a live conversation' \
      "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING"
    return 0
  fi
  printf 'check: context-ceiling: %s tokens is over the %s ceiling, the fleet is quiet and the captain is not present - run /stow now, then in the SAME turn run: %s/bin/fm-stow-receipt.sh && %s/bin/fm-context-reset.sh' \
    "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING" "$root" "$root"
}
