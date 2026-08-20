#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Busy-queued Enter (opencode 1.18.4, on the tmux backend only for now): when
# the agent is mid-turn, opencode accepts Enter as a "send when the turn ends"
# keystroke but does NOT clear the composer until then, so the composer keeps
# showing the typed text the whole time. The plain "empty iff composer cleared"
# acknowledgement above false-positives on a swallowed Enter for every steer
# sent to a busy opencode pane, and `fm-send` exits non-zero on a normal
# captain instruction. The submit core now falls back to `fm_pane_is_busy` once
# the Enter-retry budget is spent: a busy pane means the harness accepted and
# queued the Enter (report `empty` so the caller does not re-send), while an
# idle pane keeps the `pending` verdict (a genuine swallow). The herdr backend
# observes the same opencode behavior but needs a separate fix; it is recorded
# as a known gap in `docs/herdr-backend.md` rather than patched here, so the
# tmux adapter does not paper over a herdr-specific shape.
#
# No-break composer padding (claude 2.1.226; task fm-send-false-swallowed-enter):
# claude pads its EMPTY composer with a U+00A0 no-break space that no ASCII trim
# removes, so every claude cursor row - idle, or emptied because the harness
# queued the message - used to classify as `pending`. The composer verdict then
# carried no information about a claude submit at all, which left the busy
# fallback below deciding every claude steer on its own; a long steer that
# claude had not yet acknowledged with its busy footer therefore reported a
# DELIVERED message as a swallowed Enter. Blank padding is now trimmed by the
# shared fm_composer_trim (bin/fm-composer-lib.sh), which owns that decision for
# every adapter; the evidence is in docs/tmux-backend.md, "claude's empty
# composer is padded with U+00A0". With the composer read informative again, the
# busy fallback is back to being the narrow opencode tiebreak it was built as
# rather than the only thing standing between a true and a false verdict.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

fm_tmux_quote_command_arg() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

fm_tmux_run_command_string() {
  local identity=$1 command=$2 socket identity_check output marker done tmux_command=${FM_TMUX_COMMAND:-tmux}
  socket=${identity%,*}
  identity_check="test \"\${TMUX%,*}\" = $(fm_tmux_quote_command_arg "$identity")"
  marker="__FM_TMUX_SERVER_MISMATCH_$$__"
  done="__FM_TMUX_SERVER_CONNECTED_$$__"
  output=$("$tmux_command" -S "$socket" if-shell "$identity_check" "$command" \
    "display-message -p '$marker'" \; display-message -p "$done" 2>/dev/null) || true
  case "$output" in
    "$done") output= ;;
    *$'\n'"$done") output=${output%$'\n'"$done"} ;;
    *) return 126 ;;
  esac
  [ "$output" != "$marker" ] || return 125
  printf '%s' "$output"
}

fm_tmux_command_string() {
  local command= arg
  for arg in "$@"; do
    command="$command$(fm_tmux_quote_command_arg "$arg") "
  done
  printf '%s' "$command"
}

fm_tmux_command() {
  local identity=${FM_TMUX_SERVER_IDENTITY:-} command tmux_command=${FM_TMUX_COMMAND:-tmux}
  if [ -z "$identity" ]; then
    "$tmux_command" "$@"
    return $?
  fi
  command=$(fm_tmux_command_string "$@")
  fm_tmux_run_command_string "$identity" "$command"
}

fm_tmux_resolve_bound_endpoint() {
  local target=$1 identity=$2 first second output server pane listing
  first=$(fm_tmux_command_string list-panes -t "$target" -F 'PANE=#{pane_id}')
  second=$(fm_tmux_command_string display-message -p -t "$target" 'SERVER=#{socket_path},#{pid},#{pane_id}')
  output=$(fm_tmux_run_command_string "$identity" "$first ; $second") || return $?
  server=$(printf '%s\n' "$output" | sed -n 's/^SERVER=//p' | tail -1)
  [ -n "$server" ] || return 1
  pane=${server##*,}
  server=${server%,*}
  listing=$(printf '%s\n' "$output" | sed -n 's/^PANE=//p')
  printf '%s\n' "$listing" | grep -qxF "$pane" || return 1
  printf '%s\t%s\n' "$server" "$pane"
}

# fm_tmux_resolve_pane: the ONE sanctioned gate every read of a caller-supplied
# tmux target must pass. Prints the pane id <target> actually names and returns
# 0; prints nothing and returns 1 when the target does not resolve.
#
# Why this exists (incident fm-liveness-probe-target-fallback, reported by
# Tugboat 2026-07-28 and reproduced 2026-08-05): `tmux display-message -p -t
# <target>` does NOT refuse an unresolvable target. It answers for a DIFFERENT
# window - the target session's current window, or the active client's - or
# expands the format to empty, and it returns 0 in every one of those cases.
# Verified on tmux 3.4 (docs/tmux-backend.md "Target resolution: display-message
# answers for the wrong window"): every invented shape - `sess:no-such-window`,
# `sess:@9999`, `sess:win.99`, `%9999`, `@9999`, a bare unknown name - returned
# rc=0, and three of them returned a real pane id belonging to someone else.
# So a probe built on display-message's exit code never touches its target at
# all: it describes whatever the supervising pane happens to be running, which
# is why the same invented name read ALIVE on a host whose fallback pane ran
# claude and DEAD on a host whose fallback pane ran bash.
#
# `tmux list-panes -t <target>` is the correct primitive for the REFUSAL and
# needs no shape-parsing of our own: it refuses (rc=1, "can't find
# window/pane/session") for every one of those invented shapes and succeeds for
# every real one - window names, window ids (@N), pane ids (%N), and
# session:window.pane. Callers read the RESOLVED pane id rather than the original
# target, so the read is exact rather than subject to tmux's own prefix matching,
# and a pane that disappears between the resolve and the read degrades to an
# empty format expansion, which every caller already treats as unreadable.
#
# list-panes alone cannot say WHICH pane the target named, because it takes a
# target-WINDOW: it lists every pane of the containing window. Measured on tmux
# 3.4 in a two-pane window whose active pane is %1, both `list-panes -t %0` and
# `list-panes -t sess:win.0` print `%0 0` and `%1 1`, so picking the active row
# answers %1 for a target that named %0. The IDENTITY therefore comes from
# `display-message -p -t <target> '#{pane_id}'`, which is exact for every shape
# (%0 for %0, the named pane for sess:win.N, the window's active pane for a
# window-qualified target - the correct answer in each case). That read is only
# ever reached AFTER list-panes has proven the target resolves, so it can never
# fall back to another window, and its exit status is never trusted: the id it
# prints must appear in the listing or this refuses. That membership check is
# also what catches a pane that dies between the two commands, which is the one
# window in which display-message could still fall back.
#
# Deliberately NOT a presence verdict on its own: it answers "does this target
# name something", which is what the liveness probes in bin/backends/tmux.sh
# and bin/fm-backend.sh build their presence and agent-alive verdicts on.
#
# Deliberately strict about a BARE window name, and it is the caller's job not to
# pass one. tmux resolves a bare target only within its own current session
# (measured: a window named fm-target living in a non-current session is "can't
# find window" to both list-panes and display-message), so this refuses it. A
# cross-session bare lookup is firstmate's SELECTOR semantic, owned upstream by
# fm_backend_tmux_resolve_bare_selector, which turns a bare name into
# session:window BEFORE any probe runs - and it belongs upstream, because
# guessing which session a bare name meant is the very thing this gate exists to
# stop a probe from doing. Every production caller already passes the
# session-qualified target recorded in state/<id>.meta's window=.
fm_tmux_resolve_pane() {  # <target> [tmux-command] -> prints pane id, or returns 1
  local target=${1:-} tmux_command=${2:-tmux} listing named id rc
  [ -n "$target" ] || return 1
  if [ "$tmux_command" = tmux ]; then
    listing=$(fm_tmux_command list-panes -t "$target" -F '#{pane_id}' 2>/dev/null) || {
      rc=$?
      [ "$rc" -eq 125 ] && return 125
      [ "$rc" -eq 126 ] && return 126
      return 1
    }
  else
    listing=$("$tmux_command" list-panes -t "$target" -F '#{pane_id}' 2>/dev/null) || return 1
  fi
  [ -n "$listing" ] || return 1
  if [ "$tmux_command" = tmux ]; then
    named=$(fm_tmux_command display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || {
      rc=$?
      [ "$rc" -eq 125 ] && return 125
      [ "$rc" -eq 126 ] && return 126
      return 1
    }
  else
    named=$("$tmux_command" display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || return 1
  fi
  [ -n "$named" ] || return 1
  while read -r id _; do
    if [ "$id" = "$named" ]; then
      printf '%s\n' "$named"
      return 0
    fi
  done <<EOF
$listing
EOF
  return 1
}

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
# The cursor-row read is gated on fm_tmux_resolve_pane for the same reason the
# liveness probes are: display-message would otherwise report ANOTHER pane's
# cursor row for an unresolvable target. That never produced a wrong verdict
# here - the capture-pane on the same target refuses correctly, so the state
# already collapsed to unknown - but the gate makes the refusal come from the
# target check rather than from a second command happening to be stricter.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 pane cy raw plain stripped bordered=0 rc
  pane=$(fm_tmux_resolve_pane "$target") || {
    rc=$?
    [ "$rc" -eq 125 ] && { printf 'server-mismatch'; return 0; }
    [ "$rc" -eq 126 ] && { printf 'server-unverifiable'; return 0; }
    printf 'unknown'; return 0
  }
  cy=$(fm_tmux_command display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null) || {
    rc=$?
    [ "$rc" -eq 125 ] && { printf 'server-mismatch'; return 0; }
    [ "$rc" -eq 126 ] && { printf 'server-unverifiable'; return 0; }
    printf 'unknown'; return 0
  }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(fm_tmux_command capture-pane -e -p -t "$pane" -S "$cy" -E "$cy" 2>/dev/null) || {
    rc=$?
    [ "$rc" -eq 125 ] && { printf 'server-mismatch'; return 0; }
    [ "$rc" -eq 126 ] && { printf 'server-unverifiable'; return 0; }
    printf 'unknown'; return 0
  }
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  fm_composer_trim "$plain" plain
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  fm_composer_trim "$stripped" stripped
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  fm_composer_trim "$stripped" stripped
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(fm_tmux_command capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and the composer still
# reads "pending", the submit core falls back to `fm_pane_is_busy`: a busy pane
# means the Enter was accepted and queued (report `empty` so the caller does
# not re-send), while an idle pane keeps `pending` as a genuine swallow. This
# is the only place that exception lives, so the daemon's strict and
# fm-send's lenient success policies both treat a busy-queued Enter as
# delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state rc
  while :; do
    fm_tmux_command send-keys -t "$target" Enter 2>/dev/null || {
      rc=$?
      [ "$rc" -eq 125 ] && { printf 'server-mismatch'; return 0; }
      [ "$rc" -eq 126 ] && { printf 'server-unverifiable'; return 0; }
    }
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  # Retries exhausted, composer still shows pending.
  # If the pane is busy (agent mid-turn), the harness accepted the Enter
  # and queued the message for processing when the current turn ends.
  # Treat it as submitted so the caller does not re-send.
  # On an idle pane, keep reporting pending - a genuine swallow.
  if fm_pane_is_busy "$target"; then
    printf 'empty'
  else
    printf 'pending'
  fi
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 rc
  fm_tmux_command send-keys -t "$target" -l "$text" 2>/dev/null || {
    rc=$?
    [ "$rc" -eq 125 ] && { printf 'server-mismatch'; return 0; }
    [ "$rc" -eq 126 ] && { printf 'server-unverifiable'; return 0; }
    printf 'send-failed'; return 0
  }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}

# fm_tmux_ensure_own_window: keep firstmate out of a crew window.
# Incident (2026-07-06): firstmate and its crews share one tmux session, so on a
# resume `tmux new -A -s <session>` can attach the primary firstmate process INTO
# a crew's fm-<id> window. Two hazards follow: fm-crew-state and the watcher then
# read firstmate's OWN pane as that crew's pane (a busy firstmate reads as a
# "working" crew, a stale one as a stalled crew), and a respawn of <id> collides
# on the duplicate window name. When we are inside tmux and our current window is
# named like a crew window (fm-*), rename it to the reserved 'firstmate' name.
# The rename targets the caller's own window via $TMUX_PANE, needs no lock, and
# is idempotent. It is a no-op outside tmux, and it never touches a window the
# operator named anything other than fm-* (a deliberate cockpit name is kept).
# Echoes the action taken (renamed|kept|not-tmux) so callers and tests can assert.
fm_tmux_ensure_own_window() {
  if [ -z "${TMUX:-}" ]; then printf 'not-tmux'; return 0; fi
  # Target our OWN pane's window via $TMUX_PANE, never a bare (targetless)
  # call: without -t, display-message/rename-window act on whichever window is
  # ACTIVE in the session, which is not necessarily the one firstmate runs in
  # (verified 2026-07-06: a bare display-message from a background window
  # reported the session's active window instead). $TMUX_PANE is set for every
  # pane whenever $TMUX is, so this reliably names our own window.
  local pane=${TMUX_PANE:-} wname
  if [ -n "$pane" ]; then
    wname=$(tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null) || { printf 'not-tmux'; return 0; }
  else
    wname=$(tmux display-message -p '#{window_name}' 2>/dev/null) || { printf 'not-tmux'; return 0; }
  fi
  case "$wname" in
    fm-*)
      if [ -n "$pane" ]; then
        tmux rename-window -t "$pane" firstmate 2>/dev/null || true
      else
        tmux rename-window firstmate 2>/dev/null || true
      fi
      printf 'renamed' ;;
    *) printf 'kept' ;;
  esac
  return 0
}
