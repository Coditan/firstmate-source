#!/usr/bin/env bash
# fm-vessel-identity.sh - state which vessel a session belongs to, on a surface
# a person sees the moment they attach.
#
# WHY THIS EXISTS
# A vessel can be moved - onto another host, into a container - while the
# original seat is deliberately kept intact as the way back
# (.agents/skills/move-vessel/SKILL.md, "The way back is the original"). Two
# seats then exist for the same home, and attaching to the wrong one looks
# exactly like attaching to the right one: same prompt, same panes, same
# scrollback. Set that beside a seat whose wake never arrives, and the two
# failures are the same silence. Nothing on the screen said which vessel the
# terminal was pointed at, so this stamps that on the session's own status bar.
#
# WHAT IT IS NOT
# It displays an identity and checks no health. It does not probe the seat, the
# delivery listener, the watcher, or the lock, and it never reports a seat as
# live or dead. A person reading the label learns WHICH home on WHICH host this
# session is driving, and nothing about whether that vessel can be woken.
#
# WHERE THE IDENTITY COMES FROM
# From the home the session is actually operating on - $FM_HOME when the session
# carries one, otherwise this code root, which is the resolution every other
# firstmate script in this session already uses to find state/, data/, and
# config/. The label therefore cannot disagree with the session's own behaviour:
# a session driving the wrong home is labelled with the wrong home, which is the
# reading you want. Nothing here reads a hand-written name, because a label that
# can be edited into disagreement with reality answers confidently and wrongly,
# which is the defect this script exists to remove one level up.
#
# WHAT IT SHOWS WHEN THE VESSEL HAS MOVED AND THE OLD SEAT IS STILL RUNNING
# The old seat keeps running and keeps its own true label: its home path on its
# host. The moved seat carries the same home path on a different host, so the
# two labels differ in the host part and the person attaching can tell them
# apart. Two limits are real and are not designed away:
#   - Same home path AND same reported host name on both sides (a container
#     given the host's name, or a second seat on the same host) renders an
#     identical label, and this mechanism cannot separate them.
#   - The label is stamped from the session's own environment when the session
#     starts, so a home moved or renamed underneath a running session keeps the
#     name it started with.
# Beside the label the bar carries when THIS session started, read from the
# session itself, so a seat that has been sitting since before the move says so
# even when the two names collide. It is a displayed fact and not a verdict:
# nothing here calls a seat stale. docs/vessel-identity.md carries the full list
# of limits and the measured evidence behind every claim above.
#
# SURFACE
# tmux only, and deliberately: the fleet's seats and their worker windows run in
# one tmux session (bin/backends/tmux.sh), whose status bar is on screen from
# the first frame after an attach with no command run and nothing to remember.
# A seat on another session provider (zellij, cmux, herdr, orca) gets no stamp
# and is told so rather than silently skipped; those providers have their own
# name surfaces and none of them is this one.
#
# USAGE
#   fm-vessel-identity.sh              print the one-line label
#   fm-vessel-identity.sh --long       print the label and every field behind it
#   fm-vessel-identity.sh --arm-tmux   stamp the label onto the caller's own
#                                      tmux session status bar (idempotent;
#                                      prints `armed <label>`, or `not-tmux`
#                                      when this session is not a tmux session)
#   fm-vessel-identity.sh --help       print this header
#
# FM_VESSEL_IDENTITY_DISABLE=1 makes --arm-tmux a no-op that SAYS it did nothing.
# It exists because a test suite composing bin/fm-session-start.sh runs inside
# the operator's own terminal, and a stamp is a write onto the session that
# terminal is attached to. Nothing about it is silent: the arm prints `disabled`
# and the session-start digest repeats that in place of the armed line, so a
# vessel that lost its label says so rather than merely going blank.
#
# EXIT
#   0  the label was printed, or stamped, or this is not a tmux session
#   2  usage error
#   3  the home could not be resolved: the label says `unresolved-home` rather
#      than inventing a name, and the non-zero status carries that
#   4  this is a tmux session but tmux refused the option write
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

FM_VESSEL_SECONDMATE_MARKER=".fm-secondmate-home"

# Resolved home, or the empty string when the path does not resolve.
fm_vessel_home() {
  (cd "$FM_HOME" 2>/dev/null && pwd -P) || printf ''
}

# uname -n is the reported host name; a container reports its own, which is what
# separates a moved seat from the seat left behind on the old host.
fm_vessel_host() {
  local h
  h=$(uname -n 2>/dev/null) || h=
  [ -n "$h" ] || h=unknown-host
  printf '%s' "$h"
}

# primary | secondmate:<id> - read from the home itself, never from a name.
fm_vessel_kind() {
  local home=$1 marker id
  marker="$home/$FM_VESSEL_SECONDMATE_MARKER"
  if [ -n "$home" ] && [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null) || id=
    if [ -n "$id" ]; then
      printf 'secondmate:%s' "$id"
      return 0
    fi
  fi
  printf 'primary'
}

# The short name a person reads: the secondmate's own id when the home declares
# one, otherwise the home directory's own basename.
fm_vessel_name() {
  local home=$1 kind=$2
  case "$kind" in
    secondmate:*) printf '2ndmate:%s' "${kind#secondmate:}" ;;
    *)
      if [ -n "$home" ]; then
        printf '%s' "$(basename "$home")"
      else
        printf 'unresolved-home'
      fi
      ;;
  esac
}

fm_vessel_label() {  # <name> <host>
  printf '%s@%s' "$1" "$2"
}

# tmux treats `#` as the start of a format substitution, so a `#` anywhere in a
# home basename or host name has to be doubled before it is embedded.
fm_vessel_tmux_escape() {
  printf '%s' "$1" | sed 's/#/##/g'
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; s/^set -u$//'
}

MODE=label
case "${1-}" in
  '') MODE=label ;;
  --long) MODE=long ;;
  --arm-tmux) MODE=arm ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: fm-vessel-identity.sh [--long|--arm-tmux|--help]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: fm-vessel-identity.sh [--long|--arm-tmux|--help]" >&2; exit 2; }

HOME_RESOLVED=$(fm_vessel_home)
HOST=$(fm_vessel_host)
KIND=$(fm_vessel_kind "$HOME_RESOLVED")
NAME=$(fm_vessel_name "$HOME_RESOLVED" "$KIND")
LABEL=$(fm_vessel_label "$NAME" "$HOST")
RC=0
[ -n "$HOME_RESOLVED" ] || RC=3

case "$MODE" in
  label)
    printf '%s\n' "$LABEL"
    exit "$RC"
    ;;
  long)
    printf 'label: %s\n' "$LABEL"
    if [ -n "$HOME_RESOLVED" ]; then
      printf 'home: %s (measured)\n' "$HOME_RESOLVED"
    else
      printf 'home: %s (unmeasured: does not resolve)\n' "$FM_HOME"
    fi
    printf 'host: %s\n' "$HOST"
    printf 'kind: %s\n' "$KIND"
    printf 'surface: tmux status bar (bin/fm-vessel-identity.sh --arm-tmux)\n'
    exit "$RC"
    ;;
esac

# --- arm ---------------------------------------------------------------------
if [ "${FM_VESSEL_IDENTITY_DISABLE:-0}" = 1 ]; then
  printf 'disabled\n'
  exit 0
fi

if [ -z "${TMUX:-}" ]; then
  printf 'not-tmux\n'
  exit 0
fi

# Target the caller's OWN pane, never a bare targetless call: without -t, tmux
# acts on whichever window is ACTIVE in the session, which is not necessarily
# the one this session runs in. $TMUX_PANE is set for every pane whenever $TMUX
# is (the same reasoning as fm_tmux_ensure_own_window in bin/fm-tmux-lib.sh).
TARGET=${TMUX_PANE:-}
if [ -z "$TARGET" ]; then
  printf 'not-tmux\n'
  exit 0
fi

ESCAPED=$(fm_vessel_tmux_escape "$LABEL")

# When this session started, read from the session itself. A session's creation
# time never changes, so stamping the read value is exactly as truthful as a
# live format would be - and the live format is not available: tmux 3.4's
# documented `#{t/f/<strftime>:<variable>}` renders the CURRENT clock for
# session_created and window_activity alike, so a bar built on it would have
# labelled every seat "since <now>" and read as freshly started forever
# (docs/vessel-identity.md records the probe). `#{t:...}` is correct, and its
# ctime shape is trimmed to the day and minute here. A read that does not come
# back in that shape drops the clause rather than printing a time it cannot
# stand behind.
CREATED_RAW=$(tmux display-message -p -t "$TARGET" '#{t:session_created}' 2>/dev/null) || CREATED_RAW=
CREATED=$(printf '%s' "$CREATED_RAW" | awk 'NF>=5 && length($4)==8 {print $2, $3, substr($4,1,5)}')
if [ -n "$CREATED" ]; then
  SINCE=" | since $(fm_vessel_tmux_escape "$CREATED")"
else
  SINCE=
fi

CONTENT=" vessel $ESCAPED | #{session_name}$SINCE "
STATUS_LEFT="#[bg=colour24,fg=colour231,bold]${CONTENT}#[default]"
# tmux truncates status-left at status-left-length, whose default is 10, so the
# label needs room made for it. Measure the rendered width by asking tmux to
# expand the unstyled content - style directives are zero-width - rather than
# guessing at a session name and a timestamp this script does not own.
RENDERED=$(tmux display-message -p -t "$TARGET" "$CONTENT" 2>/dev/null) || RENDERED=
if [ -n "$RENDERED" ]; then
  LEFT_LEN=${#RENDERED}
else
  LEFT_LEN=$(( ${#LABEL} + 48 ))
fi

for setting in \
  "status on" \
  "status-left-length $LEFT_LEN"
do
  # shellcheck disable=SC2086
  tmux set-option -t "$TARGET" $setting 2>/dev/null || {
    printf 'error: tmux refused set-option %s\n' "$setting" >&2
    exit 4
  }
done
tmux set-option -t "$TARGET" status-left "$STATUS_LEFT" 2>/dev/null || {
  printf 'error: tmux refused set-option status-left\n' >&2
  exit 4
}

printf 'armed %s\n' "$LABEL"
exit "$RC"
