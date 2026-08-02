#!/usr/bin/env bash
# Run one bounded foreground wake-delivery checkpoint for harnesses that should
# not rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Wait on bin/fm-wake-wait.sh in the foreground for a bounded checkpoint.
When the durable queue becomes non-empty, pass through the stub output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
When a healthy stub of this session already owns delivery, re-attempt across the
remaining window, then print "checkpoint: delivery stayed armed by a same-session
stub; no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# Seconds to wait before re-attempting delivery while a same-session stub still
# owns it. Derived from nothing else, so it is a knob rather than a coupling:
# it only trades how fast this checkpoint takes delivery over when the holder
# lets go against how often it re-attempts while the holder is healthy.
REARM_POLL=${FM_WATCH_CHECKPOINT_REARM_POLL:-5}
case "$REARM_POLL" in ''|*[!0-9]*|0) REARM_POLL=5 ;; esac

# This checkpoint is the only caller that gives bin/fm-wake-wait.sh a bounded
# lifetime, so its beat-confirmation window has to fit strictly inside this
# bound: a window at or above it would be restarted by every new checkpoint,
# never reach its own deadline, and never report a wedged watcher at all under
# Codex - a bounded delay silently becoming no report. Clamp rather than trust
# whoever set FM_WAKE_BEAT_CONFIRM, or the stub's own default, to have been
# chosen with this coupling in mind; an invariant that holds by construction
# beats one that holds by memory.
# The clamp is floored at 1 because 0 is not a short window: bin/fm-wake-wait.sh
# reads 0 as "window disabled, one reading is the whole verdict", so a clamp that
# reached 0 would switch off the very suspend survival it exists to protect.
# It is recomputed from the REQUESTED value for every delivery attempt, so a
# second attempt inside a shortened remainder is clamped to that remainder
# rather than to the whole checkpoint, and the clamp never ratchets downward
# across attempts. Only the first clamp is announced, so a checkpoint that
# re-attempts many times does not repeat one diagnostic dozens of times.
BEAT_CONFIRM_REQUESTED=${FM_WAKE_BEAT_CONFIRM:-$FM_WAKE_BEAT_CONFIRM_DEFAULT}
case "$BEAT_CONFIRM_REQUESTED" in ''|*[!0-9]*) BEAT_CONFIRM_REQUESTED=$FM_WAKE_BEAT_CONFIRM_DEFAULT ;; esac
CLAMP_ANNOUNCED=0

clamp_beat_confirm() {
  local window=$1 confirm=$BEAT_CONFIRM_REQUESTED clamped
  if [ "$confirm" -ge "$window" ]; then
    clamped=$((window / 2))
    [ "$clamped" -ge 1 ] || clamped=1
    if [ "$CLAMP_ANNOUNCED" -eq 0 ]; then
      printf 'checkpoint: beat-confirmation window %ss does not fit inside the %ss remaining in this checkpoint; clamping it to %ss\n' \
        "$confirm" "$window" "$clamped" >&2
      CLAMP_ANNOUNCED=1
    fi
    confirm=$clamped
  fi
  export FM_WAKE_BEAT_CONFIRM=$confirm
}

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {
  local window=$1
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$window" "$SCRIPT_DIR/fm-wake-wait.sh"
}

RC=0
run_stub() {
  local window=$1
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "$window" "$SCRIPT_DIR/fm-wake-wait.sh" >"$OUT" 2>"$ERR"
    RC=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$window" "$SCRIPT_DIR/fm-wake-wait.sh" >"$OUT" 2>"$ERR"
    RC=$?
  else
    run_with_perl_timeout "$window" >"$OUT" 2>"$ERR"
    RC=$?
  fi
  set -e
}

# A healthy stub of THIS session can already own delivery when a checkpoint
# starts - an orphan left by an interrupted checkpoint tool call, or a manual
# repair probe. bin/fm-wake-wait.sh reports that and exits 0 in milliseconds,
# because delivery is armed and there is nothing to repair. Returning that close
# straight to the caller would dissolve this checkpoint instead: the Codex
# protocol starts the next checkpoint after every close, so an instant close
# turns the bounded 180s foreground wait that IS Codex's delivery mechanism into
# a busy loop of instant tool calls - the same spin the old typed failure caused,
# only silent. So the already-armed close is absorbed here rather than passed up:
# this checkpoint keeps its own cadence and re-attempts delivery across the
# remaining window. The re-attempt is not a poll for its own sake - the holder
# releasing the lock is exactly the moment this checkpoint can take delivery
# over, and a wake the holder saw is still there to be found, because the durable
# queue outlives the stub that reported it.
DEADLINE=$(($(date +%s) + SECONDS_ARG))
ALREADY_ARMED_LINE=
WINDOW=$SECONDS_ARG
while :; do
  clamp_beat_confirm "$WINDOW"
  run_stub "$WINDOW"

  if grep -E '^wake: queued$' "$OUT" >/dev/null 2>&1; then
    cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi

  if [ "$RC" -eq 124 ]; then
    # This attempt held the lock and waited out its window, so whatever an
    # earlier attempt found is no longer what this checkpoint ended on.
    ALREADY_ARMED_LINE=
    break
  fi

  ARMED_LINE=$(grep -m1 -E '^wake delivery: already armed ' "$OUT" 2>/dev/null || true)
  if [ "$RC" -eq 0 ] && [ -n "$ARMED_LINE" ]; then
    ALREADY_ARMED_LINE=$ARMED_LINE
    NOW=$(date +%s)
    REMAINING=$((DEADLINE - NOW))
    if [ "$REMAINING" -lt 1 ]; then break; fi
    if [ "$REARM_POLL" -lt "$REMAINING" ]; then
      sleep "$REARM_POLL"
    else
      sleep "$REMAINING"
    fi
    NOW=$(date +%s)
    WINDOW=$((DEADLINE - NOW))
    if [ "$WINDOW" -lt 1 ]; then break; fi
    continue
  fi

  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit "$RC"
done

# Both remaining outcomes are quiet checkpoints and exit 124, so the protocols
# need no new exit code: the already-armed one only says so distinctly, because
# "another stub of this session is delivering" and "nothing happened" call for
# the same next step but not for the same diagnosis.
if [ -n "$ALREADY_ARMED_LINE" ]; then
  printf '%s\n' "$ALREADY_ARMED_LINE"
  printf 'checkpoint: delivery stayed armed by a same-session stub; no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
exit 124
