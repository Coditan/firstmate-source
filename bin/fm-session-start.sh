#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
# A harness tool-result limit can still keep stdout from reaching the session.
# The REQUIRED SESSION READS block therefore leads every potentially verbose
# subsection and tells the session to read data/captain.md and data/learnings.md
# itself in bounded chunks through EOF.
# Their later full copies remain compatibility output for harnesses that deliver
# the complete digest, but printing those copies is not delivery proof.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its eight mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why the captain/learnings head is the first output, while LOCK
# still runs before BOOTSTRAP (the old AGENTS.md order was bootstrap-then-lock):
#
#   0. priority head - print a bounded, explicitly incomplete head of
#                       data/captain.md and data/learnings.md before any
#                       scaffolding, so a receiving harness that previews only
#                       the start still delivers both kinds of durable context.
#                       The complete files and every operational section remain
#                       later in the full digest saved by that harness.
#   0a. tmux window  - when firstmate is running inside a crew-shaped tmux
#                       fm-<id> window, rename the caller's own window to the
#                       reserved firstmate name before any pane reads can confuse
#                       firstmate with that crew. This is lock-free, targets only
#                       the caller's own tmux window, and is a no-op outside tmux.
#   0b. vessel identity - stamp WHICH home on WHICH host this session is
#                       driving onto the session's own status bar, so a person
#                       attaching reads it off the first frame instead of
#                       running a command. Lock-free, targets only the caller's
#                       own tmux session, no-op outside tmux, and it checks no
#                       health: bin/fm-vessel-identity.sh owns the mechanics and
#                       docs/vessel-identity.md owns what it shows when a moved
#                       vessel's old seat is still running.
#   0c. required reads - before any potentially verbose output, tell the
#                       session to read data/captain.md and data/learnings.md
#                       itself in bounded chunks through EOF after this command
#                       returns. The block states PRESENT or ABSENT for each
#                       path, so tool-output truncation cannot silently turn a
#                       printed file into a false delivery claim.
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       shared-state mutating step runs.
#   2. bootstrap      - detect-only diagnostics always run. The eight
#                       MUTATING sweeps (legacy PR-check migration, arming this
#                       home's daily currency round, arming this home's memory
#                       alarm, the AXI-suite currency check that installs into
#                       this home's own npm prefix, secondmate fast-forward,
#                       secondmate liveness, X-mode artifact writes, fleet sync)
#                       run only when this session actually holds the lock.
#                       fm-bootstrap.sh's own header owns that list; keep the two
#                       in step, because a count stated in one place and
#                       enumerated in another is exactly how this one drifted.
#   2b. wake delivery - publish where this session's model turn lives, so the
#                       externally supervised delivery listener has an address to
#                       submit into, then STATE the listener's verdict. Nothing
#                       is armed here: the listener is not this session's object.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked. It prints the raw drained records as the
#                       turn's first work queue; a bounded, clearly labeled
#                       historical status-event annotation may follow a valid
#                       `signal` record but never replaces it. On a lock refusal
#                       the queue is left UNTOUCHED, because the session holding
#                       the lock owns it - nothing is lost, and the guard's
#                       tangle and watcher-liveness alarms still print in
#                       advisory wording with no repair command attached.
#   4. telegram      - reports whether this home's optional direct Telegram
#                       receiver is inactive, misconfigured, service-owned, or
#                       still on the consent-preserving tracked-task fallback.
#   5. supervision    - emits exactly ONE operating block for the DETECTED
#                       primary harness, rendered by
#                       bin/fm-supervision-instructions.sh from
#                       docs/supervision-protocols/ and parameterized by the
#                       read-only, afk, and X-mode flags. On a Pi primary this
#                       step also prints PI_TURNEND_EXTENSION when the tracked
#                       turn-end guard extension is not loaded. It runs AFTER
#                       the wake queue and BEFORE the context digest, so the
#                       block is in view while the queue is still the turn's
#                       first work.
#   6. context digest - the active role overlay (roles/<name>.md, emitted only
#                       when config/role selects a recognized non-default role),
#                       then data/projects.md, data/secondmates.md,
#                       data/captain.md, data/captain-shared.md,
#                       data/learnings.md: read-only, always safe, always runs.
#                       The captain and learnings copies are compatibility
#                       output; step 0c owns their delivery to the session.
#   7. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       the standing context-ceiling condition from
#                       docs/context-reset.md, every state/*.meta, a bounded
#                       state/*.status tail, state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs. The status tail is labeled as
#                       wake-EVENT history rather than current state, and prints
#                       the full log path so a deeper read is one command away.
#                       The liveness line is a PRESENCE check, not a state read:
#                       it answers "is the endpoint there", never "what run step
#                       is this crew on". bin/fm-crew-state.sh answers the
#                       second, and the digest deliberately skips that slower
#                       read for every task so startup stays fast and bounded.
#                       It ALSO prints the captain decisions this home has already
#                       settled, in his own words, from bin/fm-decision-ledger.sh.
#                       That read is what makes a reset survivable: a decision he
#                       gave in an earlier session is not in this session's
#                       context, and the record only helps a session that consults
#                       it before asking again.
#   8. closing reminder - points back to the step-5 block and keeps only the
#                       lock, afk, X-mode, and read-once reminders. This script
#                       deliberately never runs long-lived polls itself; the
#                       step-4 receiver fallback is the one tracked background
#                       job it may name before the receiver service is installed,
#                       and wake delivery stays outside the harness entirely as
#                       a supervised service (docs/wake-delivery.md).
#
#   9. timing        - one line naming what this whole run cost, and the path of
#                       state/session-start-timing.log, where the per-step
#                       breakdown for this run and the previous ones was appended.
#                       A vessel had no way to see its own startup getting slower
#                       as its in-flight count grew, and reconstructing it from
#                       file timestamps afterwards is blind to every step that
#                       touches no file. This is that reading, kept to one line so
#                       the digest does not gain another thing to read at every
#                       start.
#
# These numbers are the section markers in the body below, and are kept in step
# with them on purpose: a header that renumbers independently of the code it
# describes is a map of a script that no longer exists.
#
# Why lock before shared-state mutation: the old documented order (bootstrap,
# THEN lock) let a SECOND concurrent session run bootstrap's mutating sweeps -
# fast-forwarding secondmate homes, writing X-mode artifacts, fetching/
# fast-forwarding every project clone - before ever discovering another session
# already holds the lock. Two sessions racing those sweeps is exactly the hazard
# the lock exists to prevent, so locking before bootstrap closes the hole
# outright: only the session that actually wins the lock ever touches shared
# mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute from a second
# session.
# Only the eight mutating sweeps and the wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: FM_SESSION_START_BACKLOG_LIMIT bounds the startup backlog
# listing, default 80 items.
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# --- per-step timing --------------------------------------------------------
# A VESSEL COULD NOT READ ITS OWN STARTUP COST. Nothing here recorded a duration
# anywhere, so no seat could tell whether its own session start was getting slower
# as its in-flight count grew, and the one vessel that asked had to reconstruct the
# shape afterwards from file timestamps - which is blind to exactly the steps that
# touch no file, and those are several of the expensive ones.
#
# So every step is timed, and the breakdown is APPENDED to a log rather than
# printed. The digest gains one line naming the total and where the breakdown is;
# it does not gain another thing to read at every start. The cost is two clock
# reads per step, both shell builtins where the shell has EPOCHREALTIME.
#
# THE CLOCK STARTS HERE, ahead of the harness probe and the library sources, and
# not after them: a total that excludes real startup work under-reports the very
# run it names, which is the blind spot this exists to remove. Only $STATE has to
# be resolved first, and it is.
TIMING_LOG="$STATE/session-start-timing.log"
TIMING_KEEP=${FM_SESSION_START_TIMING_KEEP:-200}
case "$TIMING_KEEP" in ''|*[!0-9]*|0) TIMING_KEEP=200 ;; esac
TIMING_MARKS=""

# Prints an integer, or prints nothing and returns 1 when no clock here can be read.
# Timing must never be able to break a startup digest, so every read is validated as
# digits before it is trusted and the last resort is whole seconds. The fallback
# branch is the shell without EPOCHREALTIME - bash before 4.4, which in practice
# means the system bash on macOS, where `date` is BSD date: it does not implement
# %N, prints it literally, and still exits 0, so an unvalidated read yields a
# non-numeric string that no `||` ever catches.
#
# AND WHEN EVEN THAT LAST RESORT FAILS, IT SAYS SO. It used to substitute 0, which
# an elapsed-time subtraction turns into "took 0ms" - the best result this
# instrument can print, produced for a measurement it never took. A reading that
# could not be taken must not render as a value, least of all as the ideal one, so
# the failure travels as a status and timing_mark below latches it for the run.
now_ms() {
  local micros nanos secs
  if [ -n "${EPOCHREALTIME:-}" ]; then
    micros=${EPOCHREALTIME/[.,]/}
    case "$micros" in ''|*[!0-9]*) micros="" ;; esac
    if [ -n "$micros" ]; then
      printf '%s' "$((10#$micros / 1000))"
      return 0
    fi
  fi
  nanos=$(date +%s%N 2>/dev/null)
  case "$nanos" in ''|*[!0-9]*) nanos="" ;; esac
  if [ -n "$nanos" ]; then
    printf '%s' "$((10#$nanos / 1000000))"
    return 0
  fi
  secs=$(date +%s 2>/dev/null)
  case "$secs" in ''|*[!0-9]*) secs="" ;; esac
  if [ -n "$secs" ]; then
    printf '%s' "$((10#$secs * 1000))"
    return 0
  fi
  return 1
}

# One sentence, stated once, so the digest line and the latch cannot drift apart.
TIMING_CLOCK_UNREADABLE="the system clock could not be read: EPOCHREALTIME held no digits and neither date +%s%N nor date +%s answered"
TIMING_CLOCK_FAULT=""
TIMING_T0=$(now_ms) || TIMING_CLOCK_FAULT=$TIMING_CLOCK_UNREADABLE
TIMING_LAST=$TIMING_T0

# ONE FAILED READ MAKES THE WHOLE RUN UNREADABLE, and that is deliberate rather than
# conservative: every number here is an elapsed time between two reads, so a span
# that starts or ends at a read nobody took has no value to report. The fault is
# latched, each step from that point on records the word rather than a number, and
# timing_report says the same thing the marks do.
timing_mark() {  # <step-name>: record the elapsed time since the previous mark
  local now
  if [ -z "$TIMING_CLOCK_FAULT" ] && now=$(now_ms); then
    TIMING_MARKS="$TIMING_MARKS${TIMING_MARKS:+ }$1=$((now - TIMING_LAST))ms"
    TIMING_LAST=$now
    return 0
  fi
  [ -n "$TIMING_CLOCK_FAULT" ] || TIMING_CLOCK_FAULT=$TIMING_CLOCK_UNREADABLE
  TIMING_MARKS="$TIMING_MARKS${TIMING_MARKS:+ }$1=unreadable"
}

# ROTATED once the log passes twice FM_SESSION_START_TIMING_KEEP runs, and this
# run's line is appended after that, so the one thing this adds to a home cannot
# grow without bound and the path the digest names always holds the run it names.
# Rotation rather than a tail-and-replace because two sessions can be starting at
# once - the read-only path a refused session takes reaches this too - and a
# rewrite from a stale snapshot silently drops whatever the other session appended
# in between, which is exactly the overlapping-startup sample a vessel most wants.
# An append is atomic and a rename is atomic: a line already written to the old
# file is carried into session-start-timing.log.1 rather than lost, and neither
# session waits on the other. Every step here stays best-effort: a startup digest
# must never fail, or block, because it could not write or rotate a timing line.
timing_report() {
  local total lines now total_field
  timing_mark closing
  if [ -n "$TIMING_CLOCK_FAULT" ] || ! now=$(now_ms); then
    total=""
    [ -n "$TIMING_CLOCK_FAULT" ] || TIMING_CLOCK_FAULT=$TIMING_CLOCK_UNREADABLE
  else
    total=$((now - TIMING_T0))
  fi
  # `2>/dev/null` goes FIRST on both of these. A redirection is applied left to
  # right, so a failing `<` or `>>` announced before stderr is silenced puts a bare
  # shell error in the digest - which the very first start in a new home, where
  # there is no log to read yet, would do every time.
  if mkdir -p "$STATE" 2>/dev/null; then
    lines=$(wc -l 2>/dev/null < "$TIMING_LOG" | tr -d ' ')
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    if [ "$lines" -ge "$((TIMING_KEEP * 2))" ]; then
      mv -f "$TIMING_LOG" "$TIMING_LOG.1" 2>/dev/null || true
    fi
  fi
  # The log gets the same word the digest gets: a later reader of this file must not
  # be able to mistake an unmeasured run for a run that cost nothing.
  if [ -n "$total" ]; then total_field="${total}ms"; else total_field="unreadable"; fi
  if printf '%s total=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       "$total_field" "$TIMING_MARKS" \
       2>/dev/null >> "$TIMING_LOG"; then
    if [ -n "$total" ]; then
      printf 'SESSION START took %sms; per-step breakdown for this run and the previous ones: %s\n' \
        "$total" "$TIMING_LOG"
    else
      printf 'SESSION START duration unreadable (%s); per-step breakdown for this run and the previous ones: %s\n' \
        "$TIMING_CLOCK_FAULT" "$TIMING_LOG"
    fi
  elif [ -n "$total" ]; then
    printf 'SESSION START took %sms; the per-step breakdown could not be written to %s\n' \
      "$total" "$TIMING_LOG"
  else
    printf 'SESSION START duration unreadable (%s); the per-step breakdown could not be written to %s\n' \
      "$TIMING_CLOCK_FAULT" "$TIMING_LOG"
  fi
}

# shellcheck source=bin/fm-axi-path-lib.sh
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

# The harness probe above forks a subprocess that walks the process tree, and five
# libraries are sourced. Named here so the breakdown stays a complete partition of
# the total rather than charging this to the first step that follows it.
timing_mark preamble

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
BACKLOG_LIMIT=${FM_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac
PAIR_HEAD_BYTES=512

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# print_bounded_file_head <path> <label>: a byte-bounded prefix, or an explicit
# empty/absent state. The full file is still printed by the context digest below.
# The partial-line fallback trims only incomplete UTF-8 code points; preserving
# combining-mark or emoji grapheme clusters would require a broader boundary and
# is deliberately out of scope. Keeping the head bounded lets both files lead
# the output without pretending either preview is the complete record.
print_bounded_file_head() {
  local path=$1 label=$2 total
  subsection "$label"
  if [ ! -f "$path" ]; then
    printf 'absent - no material received from this file in the bounded subset.\n'
    return
  fi
  if [ ! -s "$path" ]; then
    printf 'present but empty - no material received from this file in the bounded subset.\n'
    return
  fi

  total=$(wc -c < "$path")
  if [ "$total" -le "$PAIR_HEAD_BYTES" ]; then
    printf 'complete file (%s bytes; it fits inside the %s-byte per-file bound):\n' \
      "$total" "$PAIR_HEAD_BYTES"
    cat "$path"
    return
  fi

  printf 'BOUNDED SUBSET: first complete lines within %s bytes of %s total bytes; the remainder was NOT received here.\n' \
    "$PAIR_HEAD_BYTES" "$total"
  if ! LC_ALL=C awk -v max="$PAIR_HEAD_BYTES" '
    {
      bytes = length($0) + 1
      if (used + bytes > max) exit
      print
      used += bytes
    }
    END { exit used == 0 }
  ' "$path"
  then
    head -c "$PAIR_HEAD_BYTES" "$path" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
    printf '\n[partial final line; truncated at %s bytes]\n' "$PAIR_HEAD_BYTES"
  fi
}

print_required_session_read_state() {
  local path=$1 label=$2
  if [ -f "$path" ]; then
    printf '%s: PRESENT - %s\n' "$label" "$path"
  else
    printf '%s: ABSENT - %s\n' "$label" "$path"
  fi
}

print_required_session_reads() {
  printf 'REQUIRED SESSION READS\n'
  printf 'Before any action, read every PRESENT path in bounded chunks and continue until EOF.\n'
  printf 'Later full copies are compatibility output, not delivery proof.\n'
  print_required_session_read_state "$DATA/captain.md" "data/captain.md"
  print_required_session_read_state "$DATA/learnings.md" "data/learnings.md"
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; max %s item(s); indented task bodies omitted)\n' "$reason" "$BACKLOG_LIMIT"
  awk -v max="$BACKLOG_LIMIT" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "") print $0
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      if (shown < max) {
        print $0
        shown++
      }
      next
    }
    END {
      if (total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s))\n", shown, total
        if (total > shown) {
          printf "(truncated %d item(s); increase FM_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
        }
      }
    }
  ' "$path"
}

print_backlog_tasks_axi_compact() {
  local path=$1 out rc
  printf 'compact backlog listing (tasks-axi; max %s item(s); task bodies omitted)\n' "$BACKLOG_LIMIT"
  out=$(tasks-axi list --file "$path" --limit "$BACKLOG_LIMIT" --fields blocked_by,hold_kind,hold_reason 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
    printf '%s\n' "$out"
    print_backlog_manual_compact "$path" "fallback"
  fi
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

# Tool-output limits differ by harness and can replace or truncate the digest
# after this process exits. Put the session-owned reads ahead of every verbose
# subsection so even a short preview still carries the recovery path.
print_required_session_reads

# --- 0. captain and learnings priority head -------------------------------
section "CAPTAIN AND LEARNINGS - BOUNDED SUBSET"
cat <<'EOF'
This first-pass block carries a bounded head of each file before any startup scaffolding.
The complete files plus LOCK, BOOTSTRAP, WAKE QUEUE, and SUPERVISION follow in this command's full output.
If the receiving harness reports "Full output saved to: <path>", open that path for everything not delivered in its preview.
EOF
print_bounded_file_head "$DATA/captain.md" "data/captain.md - bounded head"
print_bounded_file_head "$DATA/learnings.md" "data/learnings.md - bounded head"

section "SESSION START - $FM_HOME"

# On resume the captain's `tmux new -A` can land firstmate inside a crew's
# fm-<id> window; move back to our own window before anything reads panes
# (see fm_tmux_ensure_own_window in fm-tmux-lib.sh). Safe, lock-free, no-op
# outside tmux.
fm_tmux_ensure_own_window >/dev/null 2>&1 || true

# Two seats can exist for one home - a moved vessel keeps its original seat as
# the way back - and attaching to the wrong one looks exactly like attaching to
# the right one. State this session's own vessel here, and put the same label
# on the status bar where an attaching person meets it without asking.
VESSEL_LABEL=$("$SCRIPT_DIR/fm-vessel-identity.sh" 2>/dev/null || true)
VESSEL_ARM=$("$SCRIPT_DIR/fm-vessel-identity.sh" --arm-tmux 2>&1 || true)
case "$VESSEL_ARM" in
  armed\ *) VESSEL_SURFACE='status bar armed' ;;
  not-tmux) VESSEL_SURFACE='no status bar: not a tmux session' ;;
  disabled) VESSEL_SURFACE='status bar NOT armed: FM_VESSEL_IDENTITY_DISABLE=1' ;;
  *) VESSEL_SURFACE="status bar NOT armed: $VESSEL_ARM" ;;
esac
printf 'VESSEL: %s (%s)\n' "${VESSEL_LABEL:-unresolved-home}" "$VESSEL_SURFACE"

timing_mark vessel-identity

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, currency-round arming,\n'
    printf '●  memory-alarm arming, AXI-suite currency, secondmate sync, secondmate\n'
    printf '●  liveness, X-mode artifacts, fleet sync, and wake-queue drain. Detect-only\n'
    printf '●  bootstrap diagnostics and the rest of this read-only-safe digest still ran\n'
    printf '●  below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

timing_mark lock

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$("$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

timing_mark bootstrap

# --- 2b. wake delivery ------------------------------------------------------
# The listener that turns a queued wake into a model turn runs outside this
# harness, under the same service supervision as the watcher loop, so this
# session arms nothing. What it DOES owe the listener is an address: only the
# session can see which pane its own model turn lives in, so it publishes that
# once, here, under the lock.
#
# The verdict line below is printed whether or not anything is wrong, and that
# is the point. A listener that is down and a listener with nothing to deliver
# both produce silence, so silence is never allowed to be the report; every
# session start states which of the two this home is in.
subsection "WAKE DELIVERY"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - the session holding the lock owns the delivery endpoint.\n'
  "$SCRIPT_DIR/fm-delivery-service.sh" status || true
else
  PUBLISH_OUT=$("$SCRIPT_DIR/fm-delivery-service.sh" publish-endpoint 2>&1) || true
  printf '%s\n' "$PUBLISH_OUT"
  "$SCRIPT_DIR/fm-delivery-service.sh" status || true
fi

timing_mark wake-delivery

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue (another session
# may be actively draining it) but still runs fm-guard.sh directly with
# non-mutating advisory text, so the same alarms surface without repair
# commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

timing_mark wake-queue

# --- 4. direct Telegram receiver ---------------------------------------------
TELEGRAM_PRESENT=0
[ -f "$CONFIG/telegram.env" ] && TELEGRAM_PRESENT=1
TELEGRAM_SERVICE_SELECTED=0

subsection "TELEGRAM RECEIVER"
if [ "$TELEGRAM_PRESENT" -eq 0 ] && "$SCRIPT_DIR/fm-tg-recv-service.sh" owned >/dev/null 2>&1; then
  TELEGRAM_SERVICE_SELECTED=1
  TELEGRAM_SERVICE_STATE=$("$SCRIPT_DIR/fm-tg-recv-service.sh" ownership-status 2>/dev/null || true)
  printf '%s\n' "TELEGRAM_RECEIVER: service-owned but unavailable - ${TELEGRAM_SERVICE_STATE:-down: configuration absent and retirement incomplete}; no tracked fallback will start"
elif [ "$TELEGRAM_PRESENT" -eq 0 ]; then
  printf '%s\n' 'inactive (config/telegram.env absent)'
elif [ ! -x "$CONFIG/fm-tg-recv.sh" ]; then
  printf '%s\n' 'TELEGRAM_RECEIVER: config/telegram.env exists but config/fm-tg-recv.sh is missing or not executable; direct Telegram receive is not armed'
elif "$SCRIPT_DIR/fm-tg-recv-service.sh" selected >/dev/null 2>&1; then
  TELEGRAM_SERVICE_SELECTED=1
  printf '%s\n' "TELEGRAM_RECEIVER: active - bin/fm-tg-recv-service.sh owns the receiver outside this session; no tracked background task is required"
elif "$SCRIPT_DIR/fm-tg-recv-service.sh" owned >/dev/null 2>&1; then
  TELEGRAM_SERVICE_SELECTED=1
  TELEGRAM_SERVICE_STATE=$("$SCRIPT_DIR/fm-tg-recv-service.sh" ownership-status 2>/dev/null || true)
  printf '%s\n' "TELEGRAM_RECEIVER: service-owned but unavailable - ${TELEGRAM_SERVICE_STATE:-down: health could not be determined}; no tracked fallback will start"
elif [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' 'skipped (read-only session) - the session holding the lock owns the tracked Telegram receiver fallback.'
else
  printf '%s\n' "TELEGRAM_RECEIVER: fallback active - run bin/fm-tg-recv-arm.sh as its own tracked background task until the consent-gated receiver service is installed; it starts or attaches to this home's receiver"
fi

timing_mark telegram

# --- 5. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

# Pi has one tracked primary extension left. Wake delivery is no longer one of
# its jobs, so an unloaded extension now costs the turn-end guard, not delivery.
if [ "$PRIMARY_HARNESS" = pi ]; then
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_TURNEND_EXTENSION: not loaded - approve Pi project trust once per clone, then restart plain pi so %s auto-loads for turn-end guard coverage; use -e %s only if project hooks are not trusted\n' "$PI_TURNEND_EXT" "$PI_TURNEND_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

timing_mark supervision

# --- 6. context digest -----------------------------------------------------
section "CONTEXT"
# The active role overlay leads the context digest because it amends AGENTS.md
# itself, so it outranks every per-home record that follows. It is emitted ONLY
# when config/role selects a recognized non-default role: a home with no
# config/role file (the default `vessel`) prints nothing extra here, exactly as
# before this seam existed. An unrecognized value prints nothing either - the one
# loud diagnostic for that belongs to bootstrap above (ROLE_INVALID), not here.
# Unlike the per-home data/ files below, the overlay is TRACKED and lives under
# the code root, so it fast-forwards with the rest of the instruction surface.
ROLE=$(fm_role_value "$CONFIG")
if ROLE_OVERLAY=$(fm_role_overlay_path "$FM_ROOT" "$ROLE"); then
  print_file_or_absent "$ROLE_OVERLAY" \
    "roles/$ROLE.md (ACTIVE ROLE OVERLAY - amends AGENTS.md; every AGENTS.md rule still binds except where it narrows one)"
fi
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

timing_mark context

# --- 7. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Standing context-ceiling condition (docs/context-reset.md)"
CEILING_MARKER="$STATE/.context-ceiling-surfaced"
CEILING_ABSENCE="$STATE/.context-ceiling-absent-since"
if [ ! -f "$CEILING_MARKER" ]; then
  printf '(none)\n'
elif read -r CEILING_CLASS CEILING_CONDITION CEILING_SINCE CEILING_OBSERVATIONS < "$CEILING_MARKER"; then
  case "${CEILING_SINCE:-}${CEILING_OBSERVATIONS:-}" in
    *[!0-9]*|'')
      printf 'unreadable standing record - do not treat the condition as clear\n'
      CEILING_CLASS=unreadable
      ;;
    *)
      CEILING_AGE=$(( $(date +%s) - CEILING_SINCE ))
      [ "$CEILING_AGE" -ge 0 ] || CEILING_AGE=0
      ;;
  esac
  case "$CEILING_CLASS" in
    reset|ask)
      printf 'class=%s; condition=%s; first_observed_epoch=%s; age=%ss; observations=%s; unchanged wake suppression is active until the condition changes or resolves\n' \
        "$CEILING_CLASS" "$CEILING_CONDITION" "$CEILING_SINCE" "$CEILING_AGE" "$CEILING_OBSERVATIONS"
      ;;
    blocked|unenforced)
      CEILING_ABSENCE_CLASS=
      CEILING_ABSENCE_CONDITION=
      CEILING_ABSENCE_SINCE=
      CEILING_ABSENCE_OBSERVATIONS=
      if [ -f "$CEILING_ABSENCE" ]; then
        read -r CEILING_ABSENCE_CLASS CEILING_ABSENCE_CONDITION CEILING_ABSENCE_SINCE CEILING_ABSENCE_OBSERVATIONS \
          < "$CEILING_ABSENCE" 2>/dev/null || true
      fi
      case "${CEILING_ABSENCE_SINCE:-}${CEILING_ABSENCE_OBSERVATIONS:-}" in
        *[!0-9]*|'')
          printf 'class=%s; absence record unreadable - do not treat this condition as clear\n' \
            "$CEILING_CLASS"
          ;;
        *)
          if [ "$CEILING_ABSENCE_CLASS" != "$CEILING_CLASS" ] \
            || [ "$CEILING_ABSENCE_CONDITION" != "$CEILING_CONDITION" ]; then
            printf 'class=%s; condition=%s; absence record names class=%s condition=%s - do not treat this condition as clear\n' \
              "$CEILING_CLASS" "$CEILING_CONDITION" "${CEILING_ABSENCE_CLASS:-missing}" \
              "${CEILING_ABSENCE_CONDITION:-missing}"
          else
            CEILING_ABSENCE_AGE=$(( $(date +%s) - CEILING_ABSENCE_SINCE ))
            [ "$CEILING_ABSENCE_AGE" -ge 0 ] || CEILING_ABSENCE_AGE=0
            printf 'class=%s; condition=%s; first_observed_epoch=%s; age=%ss; observations=%s; unchanged wake suppression is active\n' \
              "$CEILING_CLASS" "$CEILING_CONDITION" "$CEILING_SINCE" "$CEILING_AGE" \
              "$CEILING_OBSERVATIONS"
          fi
          ;;
      esac
      ;;
    *)
      printf 'unreadable class %s - do not treat the standing condition as clear\n' \
        "${CEILING_CLASS:-missing}"
      ;;
  esac
else
  printf 'unreadable marker - do not treat the standing condition as clear\n'
fi

subsection "Direct reports (state/*.meta; state=resting secondmates are not work under way)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      if [ "$?" -eq 1 ]; then
        printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
      else
        printf 'endpoint: unknown (backend=%s window=%s unreadable)\n' "$backend" "$window"
      fi
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Captain decisions already settled (bin/fm-decision-ledger.sh)"
# THE POINT OF THIS SECTION: a decision the captain gave in an earlier session is
# not in this session's context, and on 2026-08-17 that is exactly how he was asked
# three settled questions again in one day. The answers are printed here, in his own
# words, before anything below or above invites a fresh question - a store nobody
# consults is the same failure wearing different clothes.
# Read-only, local-only, bounded to the most recent few; --all for the rest.
if command -v jq >/dev/null 2>&1; then
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-decision-ledger.sh" --limit 5 \
    || printf '(the settled-decision record could not be read; run bin/fm-decision-ledger.sh directly)\n'
else
  printf '(jq is absent, so the settled-decision record was not read - treat every decision below as unverified)\n'
fi

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns queue delivery, the watcher service owns the loop, and the delivery listener stands down.\n'
else
  printf 'absent\n'
fi

timing_mark fleet-state

# --- 8. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not publish
an endpoint, drain, spawn, steer, merge, or repair fleet state from here. The
session holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the away daemon is reading the external watcher's durable
queue.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  TELEGRAM_NEXT=
  if [ "$TELEGRAM_PRESENT" -eq 1 ] && [ "$TELEGRAM_SERVICE_SELECTED" -eq 0 ] && [ -x "$CONFIG/fm-tg-recv.sh" ]; then
    TELEGRAM_NEXT='The Telegram receiver fallback is active, so keep its separate tracked task armed until the service is installed.'
  elif [ "$TELEGRAM_SERVICE_SELECTED" -eq 1 ]; then
    TELEGRAM_NEXT='The Telegram receiver is service-owned and needs no tracked task in this session.'
  fi
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
$TELEGRAM_NEXT
This script never starts long-lived polls itself.

EOF
else
TELEGRAM_NEXT=
if [ "$TELEGRAM_PRESENT" -eq 1 ] && [ "$TELEGRAM_SERVICE_SELECTED" -eq 0 ] && [ -x "$CONFIG/fm-tg-recv.sh" ]; then
  TELEGRAM_NEXT='The Telegram receiver fallback is active, so keep its separate tracked task armed until the service is installed.'
elif [ "$TELEGRAM_SERVICE_SELECTED" -eq 1 ]; then
  TELEGRAM_NEXT='The Telegram receiver is service-owned and needs no tracked task in this session.'
fi
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
$TELEGRAM_NEXT
This script never starts long-lived polls itself.

EOF
fi
cat <<'EOF'
The script's digest above is complete, but model-visible tool output may be shorter.
The REQUIRED SESSION READS block at the top still applies now.
Compatibility context still includes full copies of data/captain.md,
data/captain-shared.md, data/learnings.md;
REQUIRED SESSION READS governs which files must be read again after this command.
Do NOT re-read data/projects.md, data/secondmates.md,
data/captain-shared.md, or state/*.meta now - they were just printed in full.
Do NOT bulk-read data/backlog.md now either: the compact identity/metadata
listing was just printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed there with full log paths for targeted older-history follow-up.
If you received only a preview, open the `Full output saved to` path named in
the bounded priority section, or read any missing knowledge file directly
before proceeding. Never treat the bounded subset as the complete files.
The settled captain decisions printed above are answers he has ALREADY given.
Treat them as decided. Do not re-ask a question they answer, and do not
paraphrase one back to him as though it were still open; if one of them needs
revisiting, say which answer you are reopening and why.
Outside REQUIRED SESSION READS, re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

# --- 9. timing -----------------------------------------------------------
timing_report

exit 0
