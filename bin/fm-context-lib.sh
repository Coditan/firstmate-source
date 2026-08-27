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
# Only four things: the last assistant record's token `usage` numbers, the
# timestamp of the last genuine captain prompt, that prompt's own record id, and
# the file's byte size. Message CONTENT is never PRINTED. That is a hard
# constraint - the watcher runs unattended and its output lands in wake payloads.
# Content is INSPECTED, for exactly one purpose: the syntactic operational-input
# test owned by bin/fm-operational-input.sh, which is the only thing that can tell
# a firstmate delivery apart from a captain prompt. Structural provenance cannot,
# and believing otherwise is what broke this: a wake is typed into the session's
# pane, so the harness stamps it with the same `origin.kind == "human"` and
# `promptSource == "typed"` a captain prompt carries (see fm_context_scan).
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
if ! declare -F fm_operational_input_classify >/dev/null 2>&1; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$_FM_CONTEXT_LIB_DIR/fm-operational-input.sh"
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
  # First line only: bin/fm-lock.sh's record keeps the holder pid on line one and
  # carries its process-namespace identity below it, so a whole-file read would
  # hand this numeric test a multi-line string and report a live session as none.
  pid=$(sed -n '1p' "$1/.lock" 2>/dev/null) || return 1
  pid=${pid//[[:space:]]/}
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
FM_CONTEXT_RECORD_ERROR_KIND=
fm_context_record_read() {  # <state-dir>
  local state=$1 record status
  FM_CONTEXT_TRANSCRIPT=
  FM_CONTEXT_SESSION_ID=
  FM_CONTEXT_RECORD_PID=
  FM_CONTEXT_RECORD_ERROR=
  FM_CONTEXT_RECORD_ERROR_KIND=
  record=$(fm_context_record_path "$state")
  if [ ! -f "$record" ]; then
    FM_CONTEXT_RECORD_ERROR_KIND=missing
    FM_CONTEXT_RECORD_ERROR="no session transcript recorded at $record"
    return 1
  fi
  status=$(fm_context_kv "$record" status || true)
  if [ "$status" != ok ]; then
    FM_CONTEXT_RECORD_ERROR_KIND=error
    FM_CONTEXT_RECORD_ERROR="session transcript record is in error state: $(fm_context_kv "$record" error || printf 'unspecified')"
    return 1
  fi
  FM_CONTEXT_TRANSCRIPT=$(fm_context_kv "$record" transcript_path || true)
  FM_CONTEXT_SESSION_ID=$(fm_context_kv "$record" session_id || true)
  FM_CONTEXT_RECORD_PID=$(fm_context_kv "$record" harness_pid || true)
  case "$FM_CONTEXT_TRANSCRIPT" in
    /*) ;;
    *) FM_CONTEXT_RECORD_ERROR_KIND='path-relative'; FM_CONTEXT_RECORD_ERROR="recorded transcript path is not absolute"; return 1 ;;
  esac
  if [ ! -f "$FM_CONTEXT_TRANSCRIPT" ]; then
    FM_CONTEXT_RECORD_ERROR_KIND='transcript-missing'
    FM_CONTEXT_RECORD_ERROR="recorded transcript $FM_CONTEXT_TRANSCRIPT does not exist"
    return 1
  fi
  case "$FM_CONTEXT_RECORD_PID" in
    ''|*[!0-9]*) FM_CONTEXT_RECORD_ERROR_KIND='pid-invalid'; FM_CONTEXT_RECORD_ERROR="recorded harness pid is not numeric"; return 1 ;;
  esac
  [ -n "$FM_CONTEXT_SESSION_ID" ] || { FM_CONTEXT_RECORD_ERROR_KIND='session-id-empty'; FM_CONTEXT_RECORD_ERROR="recorded session id is empty"; return 1; }
  return 0
}

# One pass of the transcript reader: read the last <bytes> and publish both
# measurements from what that read covered. fm_context_scan owns how wide the
# read is and whether one pass is enough.
#
# TWO TESTS, IN THIS ORDER, AND THE ORDER IS THE WHOLE POINT.
#
# First the syntactic one: any string-content user record that
# bin/fm-operational-input.sh classifies is a firstmate delivery and is dropped,
# whatever provenance it carries. Then the structural one, over what is left:
# Claude Code marks a captain prompt `origin.kind == "human"`; a background-task
# wake delivery is `origin.kind == "task-notification"` with
# `promptSource == "system"`; hook and system injections carry `isMeta: true`;
# tool results carry array content; and a string-content record with neither
# origin nor promptSource counts as human, which keeps slash-command expansions
# captain-visible.
#
# The syntactic test used to run only on that last shape, and that was the defect.
# Firstmate's own wake delivery reaches the session by being TYPED into its pane,
# so the harness stamps it `origin.kind == "human"`, `promptSource == "typed"` -
# byte for byte the provenance of a captain prompt. The structural test matched
# first, the classifier was never consulted, and every delivered wake re-dated the
# captain to the moment of its own delivery. Measured on this seat 2026-08-20:
# the watcher chose the reset branch and the wake carrying that order was itself
# the record that then made bin/fm-context-reset.sh refuse it, four times over
# three hours. Provenance cannot separate firstmate from the captain, because
# firstmate speaks through the captain's own input channel; only the marker can.
#
# What is excluded is therefore every marked delivery - watcher, guard,
# session-start, away-supervisor, launch-brief, telegram-correspondent,
# from-firstmate, and the legacy operational forms - on any provenance at all.
# Every remaining ambiguity resolves toward "the captain is here", because the
# cost of a false quiet is a discarded conversation and the cost of a false busy
# is one deferred reset.
#
# The record's own `uuid` is carried alongside its timestamp because a timestamp
# alone cannot NAME the record it came from, and one consumer -
# bin/fm-context-reset.sh's captain-approved path - has to write into its durable
# log exactly which captain record it treated as the approval. An id is not
# content: it is the same structural metadata as the origin fields above.
_fm_context_scan_pass() {  # <transcript-path> <bytes>
  local out rest
  out=$(fm_context_tail_lines "$1" "$2" | jq -R -n -r \
    --arg operational_prefix "$FM_OPERATIONAL_PREFIX" \
    --arg fromfirst_mark "$FM_FROMFIRST_MARK" \
    --arg legacy_sessionstart "$FM_LEGACY_SESSIONSTART" \
    --arg legacy_watcher_prefix "$FM_LEGACY_WATCHER_PREFIX" \
    --arg legacy_watcher_suffix "$FM_LEGACY_WATCHER_SUFFIX" \
    --arg legacy_turnend_prefix "$FM_LEGACY_TURNEND_PREFIX" \
    --arg legacy_away_prefix "$FM_LEGACY_AWAY_PREFIX" '
    def has_body_after($prefix):
      startswith($prefix) and (length > ($prefix | length));
    def legacy_watcher_operational:
      startswith($legacy_watcher_prefix)
      and endswith($legacy_watcher_suffix)
      and (length > (($legacy_watcher_prefix | length) + ($legacy_watcher_suffix | length)));
    def legacy_turnend_operational:
      startswith($legacy_turnend_prefix)
      and (length > ($legacy_turnend_prefix | length));
    def firstmate_operational_input:
      type == "string"
      and (
        has_body_after($operational_prefix)
        or has_body_after($fromfirst_mark)
        or . == $legacy_sessionstart
        or startswith($legacy_away_prefix)
        or legacy_watcher_operational
        or legacy_turnend_operational
      );
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
          | select((.message.content | firstmate_operational_input) | not)
          | select(.origin.kind == "human" or (.origin == null and .promptSource == null))
        ] | last ) as $human
    | "\($tokens // "")\t\($human.timestamp // "")\t\($human.uuid // "")"
  ' 2>/dev/null) || {
    FM_CONTEXT_SCAN_ERROR="could not parse the transcript tail of $1"
    return 1
  }
  # Split the three fields by parameter expansion rather than by an IFS read.
  # Tab is IFS *whitespace*, so `IFS=$'\t' read` strips a leading empty field and
  # collapses a run of tabs into one delimiter - and any of these three fields can
  # legitimately be empty, which would then shift the ones behind it. This is
  # field-exact: each step cuts at exactly one tab.
  FM_CONTEXT_TOKENS=${out%%$'\t'*}
  rest=${out#*$'\t'}
  FM_CONTEXT_LAST_HUMAN_TS=${rest%%$'\t'*}
  FM_CONTEXT_LAST_HUMAN_UUID=${rest#*$'\t'}
  return 0
}

# Scan the transcript and publish both measurements:
#   FM_CONTEXT_TOKENS           last assistant record's input + cache-creation +
#                               cache-read tokens (what the window actually holds)
#   FM_CONTEXT_LAST_HUMAN_TS    timestamp of the last genuine captain prompt, or
#                               empty when the WHOLE transcript holds none
#   FM_CONTEXT_LAST_HUMAN_UUID  that same record's own id, so a consumer can name
#                               the record rather than only its clock reading, or
#                               empty when the transcript carries no id for it
#   FM_CONTEXT_SCAN_TRUNCATED   true when the bounded read did not cover the
#                               whole file, i.e. the file is larger than
#                               FM_CONTEXT_TAIL_BYTES
#   FM_CONTEXT_SCAN_WIDENED     true when the bounded read was re-run over the
#                               whole file because it held no captain record
#
# AN ABSENT CAPTAIN RECORD IS NOT EVIDENCE OF AN ABSENT CAPTAIN. The read is
# bounded so a multi-hundred-megabyte transcript cannot turn one watcher poll
# into an unbounded read, but that bound is exactly what can hide a captain
# prompt behind later tool output: the captain types, the session answers with
# more than one whole tail of transcript, and the bounded read finds nothing.
# Reading that as silence would let a reset land in the middle of a live
# conversation, which is the one outcome this mechanism must never have.
#
# So: when the bounded read finds NO captain record AND it did not cover the
# whole file, widen ONCE to the whole file and use whatever that finds. Never
# widen when the bounded read already covered everything - there is nothing
# further to find, and the cost would be paid on every poll of an idle session.
FM_CONTEXT_TOKENS=
FM_CONTEXT_LAST_HUMAN_TS=
FM_CONTEXT_LAST_HUMAN_UUID=
FM_CONTEXT_SCAN_ERROR=
FM_CONTEXT_SCAN_ERROR_KIND=
FM_CONTEXT_SCAN_TRUNCATED=false
FM_CONTEXT_SCAN_WIDENED=false
fm_context_scan() {  # <transcript-path>
  local transcript=$1 bytes
  FM_CONTEXT_TOKENS=
  FM_CONTEXT_LAST_HUMAN_TS=
  # shellcheck disable=SC2034 # Read by callers and tests after fm_context_scan returns.
  FM_CONTEXT_LAST_HUMAN_UUID=
  FM_CONTEXT_SCAN_ERROR=
  FM_CONTEXT_SCAN_ERROR_KIND=
  FM_CONTEXT_SCAN_TRUNCATED=false
  # shellcheck disable=SC2034 # Read by callers and tests after fm_context_scan returns.
  FM_CONTEXT_SCAN_WIDENED=false
  if ! command -v jq >/dev/null 2>&1; then
    FM_CONTEXT_SCAN_ERROR_KIND=jq-missing
    FM_CONTEXT_SCAN_ERROR="jq is not installed; the transcript cannot be measured"
    return 1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    FM_CONTEXT_SCAN_ERROR_KIND=perl-missing
    FM_CONTEXT_SCAN_ERROR="perl is not installed; the transcript cannot be measured"
    return 1
  fi
  bytes=$(fm_context_file_bytes "$transcript") || bytes=
  case "$bytes" in
    ''|*[!0-9]*)
      FM_CONTEXT_SCAN_ERROR="could not size the transcript $transcript"
      FM_CONTEXT_SCAN_ERROR_KIND=size-failed
      return 1
      ;;
  esac
  [ "$bytes" -gt "$FM_CONTEXT_TAIL_BYTES" ] && FM_CONTEXT_SCAN_TRUNCATED=true
  _fm_context_scan_pass "$transcript" "$FM_CONTEXT_TAIL_BYTES" || return 1
  if [ -z "$FM_CONTEXT_LAST_HUMAN_TS" ] && [ "$FM_CONTEXT_SCAN_TRUNCATED" = true ]; then
    FM_CONTEXT_SCAN_WIDENED=true
    _fm_context_scan_pass "$transcript" "$bytes" || return 1
  fi
  case "$FM_CONTEXT_TOKENS" in
    ''|*[!0-9]*)
      FM_CONTEXT_TOKENS=
      if [ "$FM_CONTEXT_SCAN_WIDENED" = true ]; then
        FM_CONTEXT_SCAN_ERROR="no token usage record anywhere in $transcript"
        FM_CONTEXT_SCAN_ERROR_KIND=usage-missing
      else
        FM_CONTEXT_SCAN_ERROR="no token usage record in the last ${FM_CONTEXT_TAIL_BYTES} bytes of $transcript"
        FM_CONTEXT_SCAN_ERROR_KIND=usage-outside-tail
      fi
      return 1
      ;;
  esac
  return 0
}

# Return 0 when the captain counts as in live conversation.
# An ABSENT timestamp returns 0 (PRESENT), and that is the point rather than an
# accident. fm_context_scan has already widened to the whole file if the bounded
# tail held no captain record, so an empty value here means the record was looked
# for everywhere it could be and still is not there - and a transcript that
# cannot say where the captain last spoke cannot be read as saying the captain is
# gone. An absent record is not evidence of absence. A malformed one returns 0
# for the same reason: a value that cannot be understood must not read as silence.
#
# FOUR CONDITIONS REACH ONE RETURN VALUE, SO THE RETURN VALUE IS NOT THE WHOLE
# ANSWER. Three different things make this say "present" - the captain spoke, the
# timestamp could not be read, no timestamp exists at all - and a caller that
# reports all three as "the captain has been active" states as fact something it
# has not established. That is not a wording nicety: on 2026-08-20 that one
# sentence sent three attempts chasing a timing race that was never there,
# because the message named a cause instead of the condition it actually hit.
# So the condition is published alongside the return value:
#
#   FM_CONTEXT_CAPTAIN_PRESENCE      a stable token, never prose:
#     spoke         a readable timestamp inside the idle window (returns 0)
#     unreadable    a timestamp that is not an instant this can compare (0)
#     unrecorded    no captain record was found anywhere (0)
#     unmeasurable  the current time could not be read, so nothing can be
#                   compared against anything (0)
#     idle          a readable timestamp older than the idle window (returns 1)
#   FM_CONTEXT_CAPTAIN_PRESENCE_WHY  one clause naming that condition, written to
#                                    drop into a caller's own sentence. The
#                                    condition is stated here so the two callers
#                                    cannot describe it differently; each still
#                                    composes its own consequence around it.
FM_CONTEXT_CAPTAIN_PRESENCE=
FM_CONTEXT_CAPTAIN_PRESENCE_WHY=
fm_context_captain_active() {  # <last-human-ts>
  local ts=$1 threshold
  FM_CONTEXT_CAPTAIN_PRESENCE=
  FM_CONTEXT_CAPTAIN_PRESENCE_WHY=
  if [ -z "$ts" ]; then
    FM_CONTEXT_CAPTAIN_PRESENCE=unrecorded
    FM_CONTEXT_CAPTAIN_PRESENCE_WHY="no captain message was found anywhere in this session's transcript, so nothing can show the captain is away"
    return 0
  fi
  threshold=$(fm_context_iso_utc "$(( $(date +%s) - FM_CONTEXT_CAPTAIN_IDLE_SECS ))") || threshold=
  if [ -z "$threshold" ]; then
    FM_CONTEXT_CAPTAIN_PRESENCE=unmeasurable
    FM_CONTEXT_CAPTAIN_PRESENCE_WHY="the current time could not be read, so the captain's last message at $ts cannot be placed inside or outside the ${FM_CONTEXT_CAPTAIN_IDLE_SECS}s window"
    return 0
  fi
  case "$ts" in
    [0-9][0-9][0-9][0-9]-*) ;;
    *)
      FM_CONTEXT_CAPTAIN_PRESENCE=unreadable
      FM_CONTEXT_CAPTAIN_PRESENCE_WHY="the captain's last message carries an unreadable timestamp ('$ts'), so it cannot be placed inside or outside the ${FM_CONTEXT_CAPTAIN_IDLE_SECS}s window"
      return 0
      ;;
  esac
  if [ "$ts" \> "$threshold" ]; then
    FM_CONTEXT_CAPTAIN_PRESENCE=spoke
    FM_CONTEXT_CAPTAIN_PRESENCE_WHY="the captain has been active within the last ${FM_CONTEXT_CAPTAIN_IDLE_SECS}s (last message at $ts)"
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers after fm_context_captain_active returns.
  FM_CONTEXT_CAPTAIN_PRESENCE=idle
  # shellcheck disable=SC2034 # Read by callers after fm_context_captain_active returns.
  FM_CONTEXT_CAPTAIN_PRESENCE_WHY="the captain's last message at $ts is older than the ${FM_CONTEXT_CAPTAIN_IDLE_SECS}s window"
  return 1
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
FM_CONTEXT_RESTART_ERROR_KIND=
fm_context_restart_path_ok() {  # <fm-home> <fm-root>
  local home=$1 root=$2 settings nudge
  FM_CONTEXT_RESTART_ERROR=
  FM_CONTEXT_RESTART_ERROR_KIND=
  settings="$home/.claude/settings.json"
  nudge="$root/bin/fm-sessionstart-nudge.sh"
  if ! command -v jq >/dev/null 2>&1; then
    FM_CONTEXT_RESTART_ERROR_KIND='jq-missing'
    FM_CONTEXT_RESTART_ERROR="jq is not installed; the re-entry hook cannot be verified"
    return 1
  fi
  if [ ! -f "$settings" ]; then
    FM_CONTEXT_RESTART_ERROR_KIND='settings-missing'
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
    FM_CONTEXT_RESTART_ERROR_KIND='hook-unwired'
    FM_CONTEXT_RESTART_ERROR="the session-start hook in $settings no longer runs fm-sessionstart-nudge.sh on a clear"
    return 1
  fi
  if [ ! -x "$nudge" ]; then
    FM_CONTEXT_RESTART_ERROR_KIND='nudge-unavailable'
    FM_CONTEXT_RESTART_ERROR="the session-start hook script $nudge is missing or not executable"
    return 1
  fi
  return 0
}

# Compose the watcher's context-ceiling wake reason, or print nothing when there
# is nothing to say. Printed reasons, all on the "check" wake kind:
#   ... cannot measure ...  the recorded transcript is missing or unreadable, so
#                           the ceiling is UNENFORCED and an observer must see it
#   ... cannot run safely   over ceiling and quiet, but the re-entry hook is gone
#   ... ask the captain     over ceiling and quiet, but the captain is in live
#                           conversation, away mode owns delivery, or presence
#                           could not be established at all - the payload names
#                           which of those it actually hit
#   ... reset               over ceiling, quiet, and the captain is not present
#
# Alongside the printed text it publishes five variables, so a caller that needs
# to suppress repeats can call it directly instead of through a command substitution that
# would discard them:
#
#   FM_CONTEXT_CEILING_REASON  the same text this prints, empty when there is none
#   FM_CONTEXT_CEILING_CLASS   the branch identity as a stable token - unenforced,
#                              blocked, ask, reset - empty when there is no
#                              reason. This is the display class: it is never prose
#                              and does not move when a payload is reworded.
#   FM_CONTEXT_CEILING_CONDITION  the stable semantic condition within that
#                              display class. This changes when the failed
#                              predicate or blocker changes and never contains
#                              mutable message wording.
#   FM_CONTEXT_CEILING_STATE   which of three outcomes this poll had:
#     surfaced    a reason is being reported
#     resolved    the condition is genuinely gone: nothing is running here, or
#                 the session is under the ceiling. ONLY this may clear a caller's
#                 suppression marker
#     suppressed  over the ceiling, but the fleet is not quiet, so this poll has
#                 nothing to say YET. The condition is unchanged and still true,
#                 and treating it as resolved would let a ceiling wake erase its
#                 own suppression marker - fm_context_quiet's first test is whether
#                 state/.wake-queue is non-empty, and that queue is exactly where
#                 the wake this check produces is parked until firstmate drains it
#
#   FM_CONTEXT_CEILING_PROTECTION  whether the ceiling is being applied at all:
#     absent      unenforced and blocked - nothing is protecting this session.
#                 Either no number can be read from it, or a number can but the
#                 reset that number would trigger cannot run
#     present     ask and reset - the ceiling is working and this is it working;
#                 a captain who is present is a reason to wait, not a defect
#   The distinction exists because absent protection needs a second durable
#   observation record. bin/fm-watch.sh keeps that record current while every
#   unchanged class and condition remains wake-suppressed.
FM_CONTEXT_CEILING_REASON=
FM_CONTEXT_CEILING_CLASS=
FM_CONTEXT_CEILING_CONDITION=
FM_CONTEXT_CEILING_STATE=
FM_CONTEXT_CEILING_PROTECTION=

_fm_context_ceiling_surfaced() {  # <class> <condition> <reason>
  FM_CONTEXT_CEILING_CLASS=$1
  FM_CONTEXT_CEILING_CONDITION=$2
  FM_CONTEXT_CEILING_REASON=$3
  FM_CONTEXT_CEILING_STATE=surfaced
  case "$1" in
    unenforced|blocked) FM_CONTEXT_CEILING_PROTECTION=absent ;;
    *) FM_CONTEXT_CEILING_PROTECTION=present ;;
  esac
  printf '%s' "$3"
}

fm_context_ceiling_reason() {  # <state-dir> <fm-home> <fm-root>
  local state=$1 home=$2 root=$3 branch msg cause
  # shellcheck disable=SC2034 # Read by callers after fm_context_ceiling_reason returns.
  FM_CONTEXT_CEILING_REASON=
  # shellcheck disable=SC2034 # Read by callers after fm_context_ceiling_reason returns.
  FM_CONTEXT_CEILING_CLASS=
  # shellcheck disable=SC2034 # Read by callers after fm_context_ceiling_reason returns.
  FM_CONTEXT_CEILING_CONDITION=
  # shellcheck disable=SC2034 # Read by callers after fm_context_ceiling_reason returns.
  FM_CONTEXT_CEILING_PROTECTION=
  FM_CONTEXT_CEILING_STATE=resolved
  # Nothing running here means nothing to measure, and nothing to report.
  fm_context_session_live "$state" || return 0
  if ! fm_context_record_read "$state"; then
    printf -v msg 'check: context-ceiling: a firstmate session is running here but its context cannot be measured (%s); the %s ceiling is unenforced until that is repaired' \
      "$FM_CONTEXT_RECORD_ERROR" "$FM_CONTEXT_CEILING"
    _fm_context_ceiling_surfaced unenforced "record-${FM_CONTEXT_RECORD_ERROR_KIND:-unknown}" "$msg"
    return 0
  fi
  # The session lock and the transcript record are keyed on the same session
  # process on purpose, so a disagreement means the record describes a session
  # that is no longer the one running - and measuring it would report the wrong
  # number rather than no number.
  if [ "$FM_CONTEXT_RECORD_PID" != "$FM_CONTEXT_LOCK_PID" ]; then
    printf -v msg 'check: context-ceiling: the recorded transcript belongs to session process %s but session process %s is the one running here; the %s ceiling is unenforced until this session records its transcript again' \
      "$FM_CONTEXT_RECORD_PID" "$FM_CONTEXT_LOCK_PID" "$FM_CONTEXT_CEILING"
    _fm_context_ceiling_surfaced unenforced session-mismatch "$msg"
    return 0
  fi
  if ! fm_context_scan "$FM_CONTEXT_TRANSCRIPT"; then
    printf -v msg 'check: context-ceiling: a firstmate session is running here but its context cannot be measured (%s); the %s ceiling is unenforced until that is repaired' \
      "$FM_CONTEXT_SCAN_ERROR" "$FM_CONTEXT_CEILING"
    _fm_context_ceiling_surfaced unenforced "scan-${FM_CONTEXT_SCAN_ERROR_KIND:-unknown}" "$msg"
    return 0
  fi
  [ "$FM_CONTEXT_TOKENS" -ge "$FM_CONTEXT_CEILING" ] || return 0
  if ! fm_context_quiet "$state"; then
    # shellcheck disable=SC2034 # Read by callers after fm_context_ceiling_reason returns.
    FM_CONTEXT_CEILING_STATE=suppressed
    return 0
  fi
  # Both conditions take the ask branch, and the payload names which one it hit.
  # Away mode is stated first because that is the order the reset tool refuses in,
  # so the wake and the refusal name the same cause when both are true.
  branch=reset
  cause=
  if [ -e "$state/.afk" ]; then
    branch=ask
    cause="away mode is active and owns wake delivery, so a reset here is the captain's call rather than an autonomous one"
  fi
  if fm_context_captain_active "$FM_CONTEXT_LAST_HUMAN_TS"; then
    branch=ask
    [ -n "$cause" ] || cause=$FM_CONTEXT_CAPTAIN_PRESENCE_WHY
  fi
  if ! fm_context_restart_path_ok "$home" "$root"; then
    printf -v msg 'check: context-ceiling: %s tokens is over the %s ceiling, but a reset cannot run safely: %s' \
      "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING" "$FM_CONTEXT_RESTART_ERROR"
    _fm_context_ceiling_surfaced blocked "restart-${FM_CONTEXT_RESTART_ERROR_KIND:-unknown}" "$msg"
    return 0
  fi
  if [ "$branch" = ask ]; then
    printf -v msg 'check: context-ceiling: %s tokens is over the %s ceiling and the fleet is quiet, but %s - ASK the captain before resetting; never reset autonomously during a live conversation' \
      "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING" "$cause"
    if [ -e "$state/.afk" ]; then
      _fm_context_ceiling_surfaced ask away "$msg"
    else
      _fm_context_ceiling_surfaced ask "captain-${FM_CONTEXT_CAPTAIN_PRESENCE:-unknown}" "$msg"
    fi
    return 0
  fi
  printf -v msg 'check: context-ceiling: %s tokens is over the %s ceiling, the fleet is quiet and the captain is not present - run /stow now, then in the SAME turn run: %s/bin/fm-stow-receipt.sh && %s/bin/fm-context-reset.sh' \
    "$FM_CONTEXT_TOKENS" "$FM_CONTEXT_CEILING" "$root" "$root"
  _fm_context_ceiling_surfaced reset ready "$msg"
}
