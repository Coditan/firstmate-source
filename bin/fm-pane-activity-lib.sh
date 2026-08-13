#!/usr/bin/env bash
# The fleet's one owner of "is this agent pane in use right now": the busy read
# and the unsubmitted-text read that every process typing into the captain's
# pane must pass before it types.
#
# Two processes now ask that question - bin/fm-supervise-daemon.sh, which
# injects away-mode escalations, and bin/fm-delivery.sh, the external wake
# listener - and both must be wrong in the same direction, because the cost of a
# wrong answer is identical: typing into a working agent corrupts its turn, and
# typing into a half-typed captain line merges with it.  These predicates lived
# inside the daemon while it was the only caller.  They live here now so the
# second caller cannot drift into a second, subtly different safety rule.
#
# The names are unchanged from when this logic was inline, so the daemon's unit
# tests (tests/fm-daemon.test.sh) exercise the same functions after the move.
# The per-backend primitives themselves stay where they are: bin/fm-backend.sh
# dispatches, bin/fm-tmux-lib.sh and bin/fm-composer-lib.sh classify.  This file
# adds no classification of its own, only the shared policy of which reads a
# caller must take.
#
# Callers must source bin/fm-tmux-lib.sh and bin/fm-backend.sh before this file:
# it deliberately does not source them itself, because both callers already do
# and a re-source would reorder their own careful load sequences.

# pane_is_busy: 0 when <target> shows an agent mid-turn.
# Tries the backend's native busy-state first and falls back to the shared
# regex-over-capture reader whenever that does not report "busy".  tmux has no
# native busy-state primitive, so it always takes the fallback path.
pane_is_busy() {  # <target> [backend]
  local target=$1 backend=${2:-tmux} bs tail40
  bs=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# pane_input_pending: 0 when the cursor line holds real unsubmitted text - a
# captain's half-typed line, or a previous submit whose Enter was swallowed.
# The classifier drops dim/faint ghost text and strips composer box borders, so
# an idle bordered composer reads as empty rather than pending.
#
# A caller deciding whether to TYPE must read the full tri-state through
# fm_backend_composer_state instead of this boolean: 'unknown' covers a bare
# dead-shell prompt and an unreadable pane, and neither is a safe target, so
# only an affirmative 'empty' may be typed into.  This predicate remains the
# shared pending check for callers that genuinely want the boolean.
pane_input_pending() {  # <target> [backend]
  local target=$1 backend=${2:-tmux}
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = pending ]
}
