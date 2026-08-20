#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# fm_backend_tmux_resolve_pane: re-exported verbatim from bin/fm-tmux-lib.sh
# under this adapter's naming convention (the same pattern the submit core
# uses), so the adapter and the shared library cannot drift on what counts as
# a resolvable target. It is the gate EVERY read of a caller-supplied target in
# this file goes through; see that function for why `tmux display-message`
# cannot be trusted to refuse one.
fm_backend_tmux_resolve_pane() {  # <target> -> prints pane id, or returns 1
  fm_tmux_resolve_pane "$@"
}

# fm_backend_tmux_target_exists: pane-PRESENCE of <target>, and the one owner
# of that question for this backend - fm_backend_target_exists (bin/fm-backend.sh)
# and fm-crew-state.sh's pane_readable both dispatch here rather than each
# running their own raw probe, which is how two of the three copies kept using
# the unguarded display-message form after the hazard was already documented at
# the third (bin/fm-spawn.sh's worktree-discovery poll).
fm_backend_tmux_target_exists() {  # <target>
  fm_backend_tmux_resolve_pane "$1" >/dev/null
}

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  fm_tmux_command capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path,
# whose preflight used to be `tmux display-message -p -t "$T" '#{pane_id}'
# >/dev/null` - a check that could not fail, because display-message answers
# for another window instead of refusing (fm_tmux_resolve_pane). The preflight
# now actually verifies the target before any key is sent. `tmux send-keys`
# itself was measured to refuse an unresolvable target correctly (rc=1, nothing
# delivered anywhere - docs/tmux-backend.md), so no keystroke was ever
# misdelivered by the old form; it simply reported the failure from send-keys
# rather than from the preflight that claimed to be guarding it.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_backend_tmux_resolve_pane "$1" >/dev/null || return 1
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
#
# The optional <fm-home> seeds FM_HOME into the new window's environment with
# `new-window -e`, which tmux applies BEFORE the window's shell starts. That
# ordering is the whole point of passing it here rather than leaving it to the
# launch command: a login/interactive profile that derives per-vessel values
# from FM_HOME runs once, at shell start, and nothing re-derives them
# afterwards, so a home announced later is a home announced too late. Callers
# that do not care may omit it, and the flag is then not passed at all.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> [<fm-home>] -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 fm_home=${4:-} wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  if [ -n "$fm_home" ]; then
    wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs" -e "FM_HOME=$fm_home") || return 1
  else
    wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  fi
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error AND on a target that does not resolve. Mirrors
# fm-spawn.sh's worktree-discovery poll.
#
# The resolve gate is what bin/fm-spawn.sh's own comment at that poll has warned
# about since it was written: an unresolvable target makes display-message read
# firstmate's OWN pane path as the crewmate's worktree and tangle a hook into
# the primary checkout. fm-spawn.sh answered that by passing the stable window
# id, which is a correct fix for that ONE caller and no protection for any
# other. The gate lives here instead, so the hazard is closed for every caller.
fm_backend_tmux_current_path() {  # <target>
  local pane
  pane=$(fm_backend_tmux_resolve_pane "$1") || return 1
  tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export, the vessel AXI PATH export) that
# already ran this exact sequence inline in fm-spawn.sh. Mirrors
# `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# fm-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
fm_backend_tmux_kill() {  # <target>
  tmux kill-window -t "$1" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
#
# Gated on fm_backend_tmux_resolve_pane: an unresolvable target returns 1 with
# no output rather than the foreground command of some OTHER pane. Without that
# gate this function - and therefore fm_backend_tmux_agent_alive, its only
# consumer - answered for the supervising pane and never read the target at all.
fm_backend_tmux_current_command() {  # <target>
  local pane
  pane=$(fm_backend_tmux_resolve_pane "$1") || return 1
  tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS in <target>'s pane, distinct from fm_backend_target_exists's
# pane-PRESENCE-only check (a pane that still exists but is sitting at a bare
# idle shell passes THAT check as "alive" - the secondmate-liveness gap
# AGENTS.md's session-start guarantee closes). See docs/tmux-backend.md
# "Agent liveness probe" for the empirical basis. Prints one of:
#   alive   - the foreground command is one of the verified harness binaries
#             (claude, codex, opencode, grok - each confirmed to run as its
#             own process name, never wrapped by a generic interpreter).
#   dead    - the foreground command is a bare shell: nothing is running in
#             the pane, so a prior agent process has exited.
#   unknown - anything else, INCLUDING a bare "node"/"python" interpreter
#             name (pi's own launcher execs into a generic "node" process
#             with no reliable way to attribute it back to pi from outside
#             the pane - docs/tmux-backend.md "Known gaps"), an unreadable
#             pane, or a TARGET THAT DOES NOT RESOLVE. Callers must never treat
#             unknown as a confirmed-dead signal (bin/fm-bootstrap.sh's
#             secondmate-liveness sweep gates a respawn on `dead` only).
#
# An unresolvable target reports unknown, not dead, and the distinction is the
# point of the fix: `dead` here means "this pane exists and confidently holds no
# agent", which is a reading of the target. Whether the endpoint exists at all
# is fm_backend_target_exists's question, and a gone endpoint routes to the
# recovery path (AGENTS.md section 5), so nothing is lost by refusing to answer
# a liveness question about a pane that is not there. The sweep turns unknown
# into a REPORTED skip; before the gate, the same target silently produced a
# confident alive or dead verdict read off the supervising pane, which is how
# one host would never respawn a dead secondmate while another risked spawning
# a duplicate over a live one.
fm_backend_tmux_agent_alive() {  # <target>
  local target=$1 comm
  comm=$(fm_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  comm=${comm#-}
  case "$comm" in
    '') printf 'unknown' ;;
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
