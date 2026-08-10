#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
AGENT_BIN_DIR=
COMPOSER_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${AGENT_BIN_DIR:-}" ] && rm -rf "$AGENT_BIN_DIR"
  [ -n "${COMPOSER_DIR:-}" ] && rm -rf "$COMPOSER_DIR"
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- target resolution: the probes must not answer for another window ---------
#
# Incident fm-liveness-probe-target-fallback. `tmux display-message -p -t
# <target>` never refuses: for an unresolvable target it answers for the
# session's CURRENT window and still returns 0. Both liveness probes were built
# on that, so their verdict described the supervising pane instead of the target.
#
# The verdict therefore differed by host, which is what made it dangerous: on a
# host whose fallback window ran claude an invented name read ALIVE (Tugboat's
# report), and on a host whose fallback window ran bash the SAME name read DEAD
# (reproduced locally). A fix verified against only the bash shape proves
# nothing, because that shape already returned "dead" for entirely the wrong
# reason. Both shapes are therefore driven here, by changing which window is
# current and asserting the verdict does not move.
#
# The agent-running fallback is produced, not simulated away: a real binary
# copied to the name `claude` runs in the pane, so tmux's own
# #{pane_current_command} reports `claude` exactly as a real agent pane does.
# That is the only stand-in - the fallback itself is genuine tmux behavior.

AGENT_BIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-agent.XXXXXX")
cp "$(command -v sleep)" "$AGENT_BIN_DIR/claude" \
  || fail "could not stage an agent-named binary for the fallback control"
cleanup_agent_bin() { rm -rf "$AGENT_BIN_DIR"; }

tmux new-window -d -t "$SESSION" -n "agent-fallback" "$AGENT_BIN_DIR/claude 300" \
  || fail "could not create the agent-running fallback window"
# A bare shell, spawned explicitly rather than inheriting the host's login shell:
# `tmux new-window` with no command starts $SHELL, so a zsh or fish host would
# drive a different shape than a bash one, and this control must be the same
# experiment everywhere. What the pane actually reports is still READ rather than
# assumed below - hardcoding a shell name is exactly what made this half fragile.
tmux new-window -d -t "$SESSION" -n "shell-fallback" "$(command -v sh)" \
  || fail "could not create the bare-shell fallback window"
sleep 0.3
SHELL_FALLBACK_CMD=$(tmux display-message -p -t "$SESSION:shell-fallback" '#{pane_current_command}')
[ -n "$SHELL_FALLBACK_CMD" ] \
  || fail "could not read the bare-shell fallback window's own pane_current_command"

INVENTED="$SESSION:zzz-no-such-window"

assert_probes_refuse_invented_target() {  # <fallback-window> <expected-fallback-command>
  local fallback_window=$1 expected_cmd=$2 raw verdict
  tmux select-window -t "$SESSION:$fallback_window" \
    || fail "could not make $fallback_window the session's current window"
  sleep 0.3

  # Precondition: this tmux really does exhibit the fallback, and it really is
  # answering with the fallback window's command. If this ever stops holding the
  # control below would pass vacuously, so it is asserted, not assumed.
  raw=$(tmux display-message -p -t "$INVENTED" '#{pane_current_command}' 2>/dev/null || true)
  [ "$raw" = "$expected_cmd" ] || fail \
    "precondition: raw display-message on an invented window should have answered '$expected_cmd' (the $fallback_window pane), got '$raw'"

  verdict=$(fm_backend_agent_alive tmux "$INVENTED")
  [ "$verdict" != alive ] || fail \
    "fm_backend_agent_alive returned ALIVE for an invented window while the current window ran '$expected_cmd'"
  [ "$verdict" = unknown ] || fail \
    "fm_backend_agent_alive must report unknown for an invented window, got '$verdict' (fallback pane ran '$expected_cmd')"

  if fm_backend_target_exists tmux "$INVENTED"; then
    fail "fm_backend_target_exists reported an invented window as present (fallback pane ran '$expected_cmd')"
  fi

  [ -z "$(fm_backend_tmux_current_path "$INVENTED" 2>/dev/null)" ] || fail \
    "fm_backend_tmux_current_path returned the fallback pane's cwd for an invented window"
}

# The exact case that produced the false ALIVE.
assert_probes_refuse_invented_target agent-fallback claude
pass "real tmux: an invented window reads not-alive even when the current window is running an agent"

# The shape this host reproduces naturally, which alone would have proved nothing.
assert_probes_refuse_invented_target shell-fallback "$SHELL_FALLBACK_CMD"
pass "real tmux: an invented window reads not-alive when the current window is a bare shell, and for the right reason"

# The probes must still read their own target correctly, or "never alive" would
# be a trivially safe answer rather than a correct one.
tmux select-window -t "$SESSION:shell-fallback"
[ "$(fm_backend_agent_alive tmux "$SESSION:agent-fallback")" = alive ] \
  || fail "fm_backend_agent_alive must still report a real agent pane as alive"
[ "$(fm_backend_agent_alive tmux "$SESSION:shell-fallback")" = dead ] \
  || fail "fm_backend_agent_alive must still report a real bare-shell pane as dead"
fm_backend_target_exists tmux "$SESSION:agent-fallback" \
  || fail "fm_backend_target_exists must still report a live window as present"
pass "real tmux: the probes still read a real target's own agent/shell state after the gate"

tmux kill-window -t "$SESSION:agent-fallback" 2>/dev/null || true
tmux kill-window -t "$SESSION:shell-fallback" 2>/dev/null || true
cleanup_agent_bin

# --- target resolution, pane scope: the gate must name the pane it was asked ---
#
# `tmux list-panes` takes a target-WINDOW, so it lists EVERY pane of the
# containing window whatever pane the target named. Measured here, on this
# server, in a real two-pane window. A gate that picked the ACTIVE row from that
# listing therefore answered for a neighbouring pane - which reaches
# bin/fm-context-reset.sh, whose whole premise is that a reset is never typed
# into a pane it cannot identify, and the away-mode composer-emptiness check.
#
# This needs a genuine SPLIT window: in a single-pane window "every pane of the
# window" and "the pane the target names" are indistinguishable, which is exactly
# why the original verification missed it.

tmux new-window -d -t "$SESSION" -n "split-probe" -c "$HOME" \
  || fail "could not create the split-probe window"
tmux split-window -d -t "$SESSION:split-probe" -c "$HOME" \
  || fail "could not split the split-probe window"

# Leave a pane OTHER than the one under test active, or the two answers coincide.
tmux select-pane -t "$SESSION:split-probe.1" \
  || fail "could not make pane 1 the active pane of the split-probe window"

SPLIT_PANES=$(tmux list-panes -t "$SESSION:split-probe" -F '#{pane_id} #{pane_active}')
SPLIT_P0=$(printf '%s\n' "$SPLIT_PANES" | awk 'NR==1 {print $1}')
SPLIT_P1=$(printf '%s\n' "$SPLIT_PANES" | awk 'NR==2 {print $1}')
[ -n "$SPLIT_P0" ] && [ -n "$SPLIT_P1" ] && [ "$SPLIT_P0" != "$SPLIT_P1" ] \
  || fail "the split-probe window did not end up with two distinct panes:"$'\n'"$SPLIT_PANES"
[ "$(printf '%s\n' "$SPLIT_PANES" | awk 'NR==2 {print $2}')" = 1 ] \
  || fail "pane 1 of the split-probe window is not the active one, so this control proves nothing:"$'\n'"$SPLIT_PANES"

# The precondition the gate has to work around, asserted rather than assumed:
# list-panes really does list the whole window for a pane-qualified target.
[ "$(tmux list-panes -t "$SPLIT_P0" -F '#{pane_id}' | wc -l | tr -d ' ')" = 2 ] \
  || fail "precondition: tmux list-panes -t $SPLIT_P0 should list both panes of the containing window"

[ "$(fm_backend_tmux_resolve_pane "$SPLIT_P0")" = "$SPLIT_P0" ] \
  || fail "fm_backend_tmux_resolve_pane resolved the pane id $SPLIT_P0 to '$(fm_backend_tmux_resolve_pane "$SPLIT_P0")', not to itself"
[ "$(fm_backend_tmux_resolve_pane "$SESSION:split-probe.0")" = "$SPLIT_P0" ] \
  || fail "fm_backend_tmux_resolve_pane resolved $SESSION:split-probe.0 to the window's ACTIVE pane instead of the pane the target names"
[ "$(fm_backend_tmux_resolve_pane "$SPLIT_P1")" = "$SPLIT_P1" ] \
  || fail "fm_backend_tmux_resolve_pane did not resolve the pane id $SPLIT_P1 to itself"
# A window-qualified target names no pane of its own, so its ACTIVE pane is the
# correct answer - the property the old form got right and must keep.
[ "$(fm_backend_tmux_resolve_pane "$SESSION:split-probe")" = "$SPLIT_P1" ] \
  || fail "fm_backend_tmux_resolve_pane must resolve a window-qualified target to that window's active pane"
pass "real tmux: fm_backend_tmux_resolve_pane names the pane the target names, in a genuine two-pane window"

# The costly path: bin/fm-context-reset.sh resolves $TMUX_PANE and then types a
# reset into whatever the result names, so the round trip back to a
# session:window.pane target must land on the SAME pane it started from.
SPLIT_TARGET=$(tmux display-message -p -t "$(fm_backend_tmux_resolve_pane "$SPLIT_P0")" \
  '#{session_name}:#{window_index}.#{pane_index}')
[ "$(tmux display-message -p -t "$SPLIT_TARGET" '#{pane_id}')" = "$SPLIT_P0" ] \
  || fail "the resolve-then-address round trip fm-context-reset.sh performs landed on a pane other than $SPLIT_P0 (got target '$SPLIT_TARGET')"
pass "real tmux: fm-context-reset.sh's resolve-then-address round trip stays on the caller's own pane"

tmux kill-window -t "$SESSION:split-probe" 2>/dev/null || true

# --- fm_tmux_ensure_own_window (firstmate must not sit in a crew window) ------
# The helper reads the CALLER's own window (no -t), so drive it from INSIDE a
# window via send-keys and assert the rename, exactly the resume path it guards.
tmux new-window -d -t "$SESSION" -n "fm-selftest" -c "$HOME"
tmux send-keys -t "$SESSION:fm-selftest" -l ". '$ROOT/bin/fm-tmux-lib.sh' && fm_tmux_ensure_own_window >/dev/null"
tmux send-keys -t "$SESSION:fm-selftest" Enter
sleep 0.5
if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "fm-selftest"; then
  fail "fm_tmux_ensure_own_window left firstmate in a crew (fm-*) window"
fi
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "firstmate" \
  || fail "fm_tmux_ensure_own_window should have renamed the crew window to 'firstmate'"
pass "real tmux: fm_tmux_ensure_own_window renames firstmate out of a crew (fm-*) window"

# A deliberately non-crew window name is left untouched.
tmux new-window -d -t "$SESSION" -n "captain-cockpit" -c "$HOME"
tmux send-keys -t "$SESSION:captain-cockpit" -l ". '$ROOT/bin/fm-tmux-lib.sh' && fm_tmux_ensure_own_window >/dev/null"
tmux send-keys -t "$SESSION:captain-cockpit" Enter
sleep 0.5
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "captain-cockpit" \
  || fail "fm_tmux_ensure_own_window must leave a non-crew window name untouched"
pass "real tmux: fm_tmux_ensure_own_window leaves a non-crew window name untouched"

# --- submit verdict on a real pane whose composer carries no-break padding ----
#
# Task fm-send-false-swallowed-enter. `fm-send` reported DELIVERED steers as
# swallowed Enters against claude workers. Claude Code 2.1.226 draws its empty
# composer as `❯` followed by U+00A0 NO-BREAK SPACE, which neither bash's
# `[[:space:]]` nor glibc's `iswspace` treats as whitespace, so every claude
# composer row classified as `pending` and the verdict fell through to the coarse
# busy fallback that exists for opencode's queued Enter. A worker that had not
# yet painted its busy footer therefore reported a landed steer as lost, and the
# only sensible reaction to that report - re-send - delivers a second copy of a
# decision the worker is already applying.
#
# Driven on a REAL pane rather than a mocked tmux because the defect was in what
# tmux actually hands back for a real cursor row: the byte sequence, the cursor
# position, and the styling all had to be genuine for the misread to appear. The
# stand-in is only the harness - a composer that renders claude's measured row
# shape and either submits or swallows Enter on demand, which is the one thing a
# real claude cannot be told to do. Both assertions run with the pane NOT busy,
# so the busy fallback can never be what makes them pass.

COMPOSER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-composer.XXXXXX")
cat > "$COMPOSER_DIR/fake-composer" <<'SH'
#!/usr/bin/env bash
# Renders claude 2.1.226's measured composer row: the agent prompt glyph, one
# U+00A0, then whatever has been typed. Submitting appends the line to $2 and
# clears the row; FM_FAKE_CLAUDE_SWALLOW=1 keeps the text and writes nothing,
# which is a genuinely swallowed Enter. Nothing here ever prints a busy footer.
set -u
LOG=$1
NBSP=$'\302\240'
buf=""
draw() {
  printf '\033[2J\033[H'
  printf 'fake claude composer\n\n'
  printf '\033[38;5;246m❯%s\033[39m%s' "$NBSP" "$buf"
}
draw
while IFS= read -rsn1 c; do
  if [ -z "$c" ]; then
    if [ "${FM_FAKE_CLAUDE_SWALLOW:-0}" != 1 ]; then
      printf '%s\n' "$buf" >> "$LOG"
      buf=""
    fi
  else
    buf="$buf$c"
  fi
  draw
done
SH
chmod +x "$COMPOSER_DIR/fake-composer"

wait_for_composer_state() {  # <target> <expected> [samples]
  local target=$1 expected=$2 samples=${3:-100} i=0
  while [ "$i" -lt "$samples" ]; do
    [ "$(fm_tmux_composer_state "$target")" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

STEER='apply the reviewer proposal on finding F-12'

# Direction 1: the harness submits. The composer clears to claude's padded row,
# the pane never goes busy, and the verdict must be that the steer landed.
tmux new-window -d -t "$SESSION" -n "composer-submit" \
  "$COMPOSER_DIR/fake-composer '$COMPOSER_DIR/submitted.log'" \
  || fail "could not create the submitting fake-composer window"
wait_for_composer_state "$SESSION:composer-submit" empty \
  || fail "a real pane showing claude's U+00A0-padded empty composer must read empty, got '$(fm_tmux_composer_state "$SESSION:composer-submit")'"
pass "real tmux: claude's U+00A0-padded empty composer row reads empty on a real pane"

SUBMIT_VERDICT=$(fm_tmux_submit_core "$SESSION:composer-submit" "$STEER" 3 0.2 0.3)
if fm_pane_is_busy "$SESSION:composer-submit"; then
  fail "the submitting fake-composer pane must never read busy, or this control proves nothing"
fi
[ "$SUBMIT_VERDICT" = empty ] \
  || fail "a delivered steer on a not-busy claude-shaped pane must return empty, got '$SUBMIT_VERDICT'"
[ "$(grep -c -F "$STEER" "$COMPOSER_DIR/submitted.log" 2>/dev/null || echo 0)" -eq 1 ] \
  || fail "the steer should have been submitted exactly once:"$'\n'"$(cat "$COMPOSER_DIR/submitted.log" 2>/dev/null)"
pass "real tmux: a delivered steer reports empty on evidence alone, with the pane never busy"

# Direction 2: the harness swallows Enter. The text stays in the composer and
# the verdict must still say it did not land - the strictly worse failure this
# fix must not introduce.
# The command is handed straight to new-window, as in direction 1, so no
# interactive shell's line-editor readiness is in play; the swallow flag rides
# in as a command-prefix assignment.
tmux new-window -d -t "$SESSION" -n "composer-swallow" \
  "FM_FAKE_CLAUDE_SWALLOW=1 exec '$COMPOSER_DIR/fake-composer' '$COMPOSER_DIR/swallowed.log'" \
  || fail "could not create the swallowing fake-composer window"
wait_for_composer_state "$SESSION:composer-swallow" empty \
  || fail "the swallowing fake-composer pane never reached its empty composer row"

SWALLOW_VERDICT=$(fm_tmux_submit_core "$SESSION:composer-swallow" "$STEER" 3 0.2 0.3)
[ "$SWALLOW_VERDICT" = pending ] \
  || fail "a genuinely swallowed Enter must still return pending, got '$SWALLOW_VERDICT'"
[ ! -s "$COMPOSER_DIR/swallowed.log" ] \
  || fail "the swallowing composer must not have submitted anything:"$'\n'"$(cat "$COMPOSER_DIR/swallowed.log")"
case "$(fm_backend_tmux_capture "$SESSION:composer-swallow" 10)" in
  *"$STEER"*) : ;;
  *) fail "the swallowed steer should still be visible in the composer" ;;
esac
pass "real tmux: a genuinely swallowed Enter still reports pending, with the text left in the composer"

tmux kill-window -t "$SESSION:composer-submit" 2>/dev/null || true
tmux kill-window -t "$SESSION:composer-swallow" 2>/dev/null || true
rm -rf "$COMPOSER_DIR"
COMPOSER_DIR=

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

cleanup_all
trap - EXIT
