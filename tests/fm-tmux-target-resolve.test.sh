#!/usr/bin/env bash
# tests/fm-tmux-target-resolve.test.sh - regression: a tmux liveness probe must
# never answer for a window other than the one it was asked about.
#
# Incident fm-liveness-probe-target-fallback (reported by Tugboat 2026-07-28,
# reproduced 2026-08-05): `tmux display-message -p -t <target>` does not refuse
# an unresolvable target. It answers for the target session's current window, or
# the active client's, or expands the format to empty - and returns 0 in every
# case. Both probes built on it were therefore describing the SUPERVISING pane:
# fm_backend_target_exists reported a non-existent window as present, and
# fm_backend_agent_alive computed its confident alive/dead verdict from whatever
# that other pane was running.
#
# These are the hermetic, always-run halves. The real-tmux control - including
# the case that produced Tugboat's false ALIVE, an invented name on a host whose
# fallback pane is running an agent - lives in tests/fm-backend-tmux-smoke.test.sh
# against a private tmux socket, because only a real tmux exhibits the fallback.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-target-resolve.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- fake tmux ---------------------------------------------------------------
#
# Models the two behaviors that matter, exactly as tmux 3.4 was measured to
# behave (docs/tmux-backend.md "Target resolution: display-message answers for
# the wrong window"):
#   list-panes    - refuses an unknown target (rc=1), lists real ones.
#   display-message - NEVER refuses. For an unknown target it answers for
#                   FM_FAKE_FALLBACK_CMD, the supervising pane's command, which
#                   is precisely the bug.
# One live window, "sess:real", whose pane %1 runs FM_FAKE_REAL_CMD.
make_fake_tmux() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
known=0
case "$target" in
  sess:real|%1|@1) known=1 ;;
esac
case "${1:-}" in
  has-session)
    case "$target" in sess:real|sess:ghost) exit 0 ;; esac
    exit 1 ;;
  list-panes)
    [ "$known" = 1 ] || { echo "can't find window: $target" >&2; exit 1; }
    printf '%%1 1\n'; exit 0 ;;
  display-message)
    # The defect, faithfully: rc=0 whether or not the target resolved, and an
    # unresolved one answers with the FALLBACK pane's command.
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          if [ "$known" = 1 ]; then printf '%s\n' "${FM_FAKE_REAL_CMD:-bash}"
          else printf '%s\n' "${FM_FAKE_FALLBACK_CMD:-bash}"; fi
          exit 0 ;;
        *pane_current_path*)
          if [ "$known" = 1 ]; then printf '%s\n' "${FM_FAKE_REAL_PATH:-/real/worktree}"
          else printf '%s\n' "${FM_FAKE_FALLBACK_PATH:-/supervisor/primary-checkout}"; fi
          exit 0 ;;
        *pane_pid*) printf '%s\n' "${FM_FAKE_REAL_PID:-1234}"; exit 0 ;;
        *pane_id*) printf '%%1\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  send-keys)
    # Real tmux refuses an unresolvable send target (measured rc=1); model that
    # so the test cannot pass by accident when the preflight is removed.
    [ "$known" = 1 ] || { echo "can't find window: $target" >&2; exit 1; }
    printf 'sent\n' >> "${FM_FAKE_SENT_LOG:?}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_fake_tmux "$TMP_ROOT")
PATH="$FAKEBIN:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=bin/fm-keeper-name-lib.sh
. "$ROOT/bin/fm-keeper-name-lib.sh"

# --- fm_tmux_resolve_pane ----------------------------------------------------

test_resolver_refuses_what_display_message_would_answer() {
  local t
  fm_tmux_resolve_pane 'sess:real' >/dev/null \
    || fail "fm_tmux_resolve_pane must resolve a live target"
  [ "$(fm_tmux_resolve_pane 'sess:real')" = '%1' ] \
    || fail "fm_tmux_resolve_pane must print the pane id the target names"

  for t in 'sess:zzz-nope' 'sess:also-not-real' '%9999' '@9999' 'nosuchsession:win' ''; do
    if fm_tmux_resolve_pane "$t" >/dev/null 2>&1; then
      fail "fm_tmux_resolve_pane accepted the unresolvable target '$t'"
    fi
    [ -z "$(fm_tmux_resolve_pane "$t" 2>/dev/null)" ] \
      || fail "fm_tmux_resolve_pane printed a pane id for the unresolvable target '$t'"
  done
  pass "fm_tmux_resolve_pane resolves a live target and refuses every unresolvable one"
}

# --- the control: verdict must not depend on the supervising pane ------------
#
# The same invented window name, on two hosts that differ ONLY in what their own
# fallback pane is running. Before the gate this returned alive on one and dead
# on the other; neither was a reading of the target. That host-dependence is why
# the defect got diagnosed as an environment quirk instead of a fleet-wide bug.
test_agent_alive_never_reads_the_fallback_pane() {
  local verdict
  for fallback in claude codex opencode grok bash zsh; do
    verdict=$(FM_FAKE_FALLBACK_CMD="$fallback" fm_backend_agent_alive tmux 'sess:zzz-nope')
    [ "$verdict" != alive ] \
      || fail "an invented window read ALIVE off a fallback pane running '$fallback'"
    [ "$verdict" = unknown ] \
      || fail "an invented window must read unknown, not '$verdict' (fallback pane: '$fallback')"
  done
  pass "fm_backend_agent_alive reports unknown for an invented window whatever the fallback pane runs"
}

test_agent_alive_still_reads_a_real_target() {
  local verdict
  verdict=$(FM_FAKE_REAL_CMD=claude FM_FAKE_FALLBACK_CMD=bash fm_backend_agent_alive tmux 'sess:real')
  [ "$verdict" = alive ] || fail "a live agent pane must still read alive, got '$verdict'"
  verdict=$(FM_FAKE_REAL_CMD=bash FM_FAKE_FALLBACK_CMD=claude fm_backend_agent_alive tmux 'sess:real')
  [ "$verdict" = dead ] || fail "a bare-shell pane must still read dead, got '$verdict'"
  pass "fm_backend_agent_alive still reads a real target's own command, not the fallback's"
}

test_target_exists_refuses_an_invented_window() {
  fm_backend_target_exists tmux 'sess:real' \
    || fail "fm_backend_target_exists must report a live window as present"
  local t
  for t in 'sess:zzz-nope' '%9999' '@9999' 'nosuchsession:win'; do
    if fm_backend_target_exists tmux "$t"; then
      fail "fm_backend_target_exists reported the non-existent target '$t' as present"
    fi
  done
  pass "fm_backend_target_exists refuses a non-existent window instead of reporting it present"
}

# fm-crew-state.sh's pane_readable was the third copy of the same raw probe. It
# now dispatches through fm_backend_target_exists, so it cannot drift again.
test_crew_state_presence_has_one_owner() {
  local probes
  probes=$(grep -n 'tmux display-message' "$ROOT/bin/fm-crew-state.sh" | grep -v '^[0-9]*: *#' || true)
  [ -z "$probes" ] \
    || fail "fm-crew-state.sh must not run its own raw tmux presence probe:"$'\n'"$probes"
  assert_grep 'fm_backend_target_exists tmux' "$ROOT/bin/fm-crew-state.sh" \
    "fm-crew-state.sh's pane_readable must dispatch through the shared presence owner"
  pass "fm-crew-state.sh asks the shared presence owner instead of probing tmux itself"
}

test_current_path_refuses_an_invented_window() {
  local out
  out=$(FM_FAKE_FALLBACK_PATH=/supervisor/primary-checkout \
        fm_backend_tmux_current_path 'sess:zzz-nope' 2>/dev/null) || true
  [ -z "$out" ] \
    || fail "fm_backend_tmux_current_path returned the supervising pane's cwd '$out' for an invented window"
  out=$(FM_FAKE_REAL_PATH=/real/worktree fm_backend_tmux_current_path 'sess:real')
  [ "$out" = /real/worktree ] \
    || fail "fm_backend_tmux_current_path must still read a live target's cwd, got '$out'"
  pass "fm_backend_tmux_current_path refuses an invented window rather than reading the supervisor's cwd"
}

test_send_key_preflight_actually_verifies() {
  export FM_FAKE_SENT_LOG="$TMP_ROOT/sent.log"
  : > "$FM_FAKE_SENT_LOG"
  if fm_backend_tmux_send_key 'sess:zzz-nope' Enter 2>/dev/null; then
    fail "fm_backend_tmux_send_key must refuse an unresolvable target"
  fi
  [ ! -s "$FM_FAKE_SENT_LOG" ] \
    || fail "fm_backend_tmux_send_key sent a key to an unresolvable target"
  fm_backend_tmux_send_key 'sess:real' Enter || fail "fm_backend_tmux_send_key must still send to a live target"
  [ -s "$FM_FAKE_SENT_LOG" ] || fail "fm_backend_tmux_send_key did not send to the live target"
  pass "fm_backend_tmux_send_key's preflight refuses an unresolvable target before sending"
}

test_legacy_keeper_ownership_resolves_before_reading_pid() {
  local lock="$TMP_ROOT/keeper.lock" pid_file="$TMP_ROOT/keeper.pid"
  mkdir -p "$lock"
  printf '%s\n' 1234 > "$pid_file"
  printf '%s\n' /home/expected > "$lock/fm-home"

  fm_legacy_keeper_owned_by_home "$FAKEBIN/tmux" sess:real "$pid_file" "$lock" /home/expected \
    || fail "legacy keeper ownership must accept the identity-matched live keeper"
  if fm_legacy_keeper_owned_by_home "$FAKEBIN/tmux" sess:ghost "$pid_file" "$lock" /home/expected; then
    fail "legacy keeper ownership accepted a session whose target could not be resolved"
  fi
  pass "legacy keeper ownership resolves its session before reading the keeper pid"
}

# --- the anti-recurrence rule ------------------------------------------------
#
# The hazard was documented in a comment beside ONE caller (bin/fm-spawn.sh's
# worktree poll) while two other call sites kept using the unguarded form. A
# comment is not enforcement, so this is the enforcement: every `display-message
# -p` read in bin/ must target a pane the caller already RESOLVED or OWNS.
#
# The exemption is tied to evidence, not to spelling. An earlier form of this
# rule exempted any `-t` whose argument was literally "$pane", "$PANE",
# "$RESOLVED_PANE" or "$TMUX_PANE", which proved a naming convention rather than
# that resolution happened: `pane=$1; tmux display-message -p -t "$pane" ...` -
# an unresolved caller-supplied target, the exact incident shape - passed it. The
# rule now reads each file for the variables that actually hold a resolved pane
# (assigned from fm_tmux_resolve_pane / fm_backend_tmux_resolve_pane, or from
# $TMUX_PANE, which is the caller's OWN pane and needs no resolving) and exempts
# only a `-t "$VAR"` naming one of those. Every other form - `-t "$target"`,
# `-t "$1"`, `-t "$win"`, or a `$pane` that was never resolved - offends.
#
# fm_tmux_resolve_pane's own body is skipped, because it IS the gate: it is the
# one place that may read display-message against a raw target, and only after
# `list-panes` has refused an unresolvable one. That body is not unmeasured -
# test_resolver_gates_before_it_reads below drives it against a fake tmux that
# answers with a pane outside the listing and requires it to refuse.
#
# Two forms are deliberately NOT covered and are recorded rather than silently
# permitted (docs/tmux-backend.md "Adjacent sites not changed"): a `-p` read
# with no -t at all, which reads the caller's own current window rather than an
# arbitrary target, and bin/fm-supervise-daemon.sh's non-`-p` status-line flash,
# which displays a message rather than producing a verdict.

# resolved_pane_vars: the variables in <file> that provably hold a pane the
# script resolved (from the shared gate) or owns ($TMUX_PANE).
#
# The sed expressions below are literal source text being matched, not
# variables to expand.
# shellcheck disable=SC2016
resolved_pane_vars() {  # <file> -> one variable name per line
  sed -n \
    -e 's/^[[:space:]]*\(local[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=\$(.*fm_\(backend_\)\{0,1\}tmux_resolve_pane.*/\2/p' \
    -e 's/^[[:space:]]*\(local[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)="\{0,1\}\${\{0,1\}TMUX_PANE.*/\2/p' \
    "$1" | sort -u
}

unguarded_display_message_reads() {  # <dir> -> prints offending file:line matches
  local file vars
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    vars=" $(resolved_pane_vars "$file" | tr '\n' ' ')TMUX_PANE "
    awk -v vars="$vars" -v file="$file" '
      /^[[:space:]]*#/ { next }
      /^fm_tmux_resolve_pane\(\)/ { in_gate = 1; next }
      in_gate { if ($0 ~ /^}/) in_gate = 0; next }
      !/display-message -p -t/ { next }
      {
        arg = $0
        sub(/.*display-message -p -t[[:space:]]+/, "", arg)
        sub(/[[:space:]].*/, "", arg)
        if (arg ~ /^"\$[A-Za-z_][A-Za-z0-9_]*"$/) {
          name = substr(arg, 3, length(arg) - 3)
          if (index(vars, " " name " ") > 0) next
        }
        printf "%s:%d:%s\n", file, FNR, $0
      }
    ' "$file"
  done <<EOF
$(grep -rl --include='*.sh' 'display-message -p -t' "$1" 2>/dev/null | sort)
EOF
}

test_no_unguarded_display_message_read_in_bin() {
  # First prove the detector can fail, on BOTH shapes it must catch. A rule that
  # cannot fire is exactly the defect under repair: bin/fm-spawn.sh's comment
  # named this hazard while two other call sites kept the unguarded form, and
  # nothing was measuring them.
  local probe_dir
  probe_dir="$TMP_ROOT/rule-selfcheck"
  rm -rf "$probe_dir"; mkdir -p "$probe_dir"
  # Literal offending source text, deliberately unexpanded.
  # shellcheck disable=SC2016
  printf '%s\n' 'cmd=$(tmux display-message -p -t "$target" '"'"'#{pane_current_command}'"'"')' \
    > "$probe_dir/offender-target.sh"
  [ -n "$(unguarded_display_message_reads "$probe_dir")" ] \
    || fail "the unguarded-display-message rule does not detect the '\$target' spelling; it is not enforcing anything"

  # The shape the old spelling-based rule let through: a caller-supplied target
  # that is merely NAMED like a resolved pane.
  rm -rf "$probe_dir"; mkdir -p "$probe_dir"
  # shellcheck disable=SC2016
  printf '%s\n' 'probe() {' 'pane=$1' \
    'tmux display-message -p -t "$pane" '"'"'#{pane_current_command}'"'"'' '}' \
    > "$probe_dir/offender-unresolved-pane.sh"
  [ -n "$(unguarded_display_message_reads "$probe_dir")" ] \
    || fail "the unguarded-display-message rule exempts an UNRESOLVED target just because it is spelled \"\$pane\"; it proves a naming convention, not resolution"

  # ...and that the same spelling is accepted once it is actually resolved, or
  # the rule would be unusable and the real call sites would have to be excused.
  rm -rf "$probe_dir"; mkdir -p "$probe_dir"
  # shellcheck disable=SC2016
  printf '%s\n' 'probe() {' 'pane=$(fm_tmux_resolve_pane "$1") || return 1' \
    'tmux display-message -p -t "$pane" '"'"'#{pane_current_command}'"'"'' '}' \
    > "$probe_dir/resolved-pane.sh"
  [ -z "$(unguarded_display_message_reads "$probe_dir")" ] \
    || fail "the unguarded-display-message rule rejects a properly resolved pane read"

  local offenders
  offenders=$(unguarded_display_message_reads "$ROOT/bin")
  [ -z "$offenders" ] || fail \
    "a tmux display-message read targets an unresolved, caller-supplied target; resolve it with fm_tmux_resolve_pane first:"$'\n'"$offenders"
  pass "no bin/ script reads tmux display-message against an unresolved caller-supplied target (rule self-checked on both offending shapes)"
}

# The resolver itself must stay built on a command that refuses. If the refusal
# is ever moved onto display-message, every test above would still pass against a
# fake that models the real fallback - but the fleet would be broken again.
test_resolver_is_built_on_a_refusing_command() {
  local body lp dm
  body=$(awk '/^fm_tmux_resolve_pane\(\)/,/^}/' "$ROOT/bin/fm-tmux-lib.sh")
  assert_contains "$body" "list-panes" \
    "fm_tmux_resolve_pane must resolve through tmux list-panes, which refuses an unknown target"
  # display-message may be READ from, but never before list-panes has refused an
  # unresolvable target, and never for its exit status (see the behavioral test
  # below). Ordering is asserted here because it is the one property the fakes
  # cannot observe: a display-message-first resolver would answer for another
  # window before anything had a chance to refuse.
  lp=$(printf '%s\n' "$body" | grep -n 'list-panes' | head -1 | cut -d: -f1)
  dm=$(printf '%s\n' "$body" | grep -n 'display-message' | head -1 | cut -d: -f1)
  [ -n "$lp" ] || fail "fm_tmux_resolve_pane no longer calls list-panes"
  if [ -n "$dm" ]; then
    [ "$lp" -lt "$dm" ] \
      || fail "fm_tmux_resolve_pane reads display-message before list-panes has gated the target"
  fi
  pass "fm_tmux_resolve_pane gates on a tmux command that refuses before it reads any identity"
}

# --- the gate reads the pane the target NAMES, not the window's active one ----
#
# list-panes takes a target-WINDOW: `list-panes -t %0` and `list-panes -t
# sess:win.0` both list EVERY pane of the containing window (measured on tmux
# 3.4: `%0 0` and `%1 1`). A resolver that picked the active row from that
# listing answered %1 for a target that named %0 - the same answer-for-the-wrong-
# thing defect this branch exists to close, narrowed from window scope to pane
# scope. It reached bin/fm-context-reset.sh, which types a reset into whatever
# the resolved pane names, and the away-mode composer-emptiness safety check.
#
# The genuine two-pane control runs against real tmux in
# tests/fm-backend-tmux-smoke.test.sh. This is the hermetic half.
make_two_pane_tmux() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
# One window "sess:win" with two panes; %1 is ACTIVE, %0 is not.
case "$target" in
  sess:win|sess:win.0|sess:win.1|%0|%1|@1) ;;
  *) echo "can't find window: $target" >&2; exit 1 ;;
esac
case "${1:-}" in
  list-panes)
    # Real tmux lists the whole containing WINDOW whatever pane was named.
    printf '%%0\n%%1\n'; exit 0 ;;
  display-message)
    # Real tmux is exact here: the named pane, or the active one for a
    # window-qualified target.
    case "$target" in
      %0|sess:win.0) printf '%%0\n' ;;
      %1|sess:win.1) printf '%%1\n' ;;
      *) printf '%s\n' "${FM_FAKE_DM_PANE:-%1}" ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_resolver_returns_the_pane_the_target_names() {
  local fb got
  fb=$(make_two_pane_tmux "$TMP_ROOT/two-pane")
  got=$(PATH="$fb:$PATH" fm_tmux_resolve_pane 'sess:win.0')
  [ "$got" = '%0' ] \
    || fail "fm_tmux_resolve_pane returned '$got' for sess:win.0; it must name pane 0, not the window's active pane"
  got=$(PATH="$fb:$PATH" fm_tmux_resolve_pane '%0')
  [ "$got" = '%0' ] \
    || fail "fm_tmux_resolve_pane returned '$got' for the pane id %0; a pane id must resolve to itself"
  got=$(PATH="$fb:$PATH" fm_tmux_resolve_pane '%1')
  [ "$got" = '%1' ] || fail "fm_tmux_resolve_pane returned '$got' for the pane id %1"
  # A window-qualified target has no pane of its own, so the window's ACTIVE
  # pane is the correct answer there.
  got=$(PATH="$fb:$PATH" fm_tmux_resolve_pane 'sess:win')
  [ "$got" = '%1' ] \
    || fail "fm_tmux_resolve_pane returned '$got' for the window sess:win; a window-qualified target must resolve to its active pane"
  pass "fm_tmux_resolve_pane returns the pane the target names, not the containing window's active pane"
}

# The identity read is never TRUSTED, only used: its answer must appear in the
# listing that already refused. This is what catches the one window where
# display-message could still fall back - a pane that dies between the two
# commands - and it is why the gate cannot be reimplemented as a bare
# display-message read that happens to be preceded by a list-panes call.
test_resolver_gates_before_it_reads() {
  local fb
  fb=$(make_two_pane_tmux "$TMP_ROOT/two-pane-stale")
  if PATH="$fb:$PATH" FM_FAKE_DM_PANE='%77' fm_tmux_resolve_pane 'sess:win' >/dev/null 2>&1; then
    fail "fm_tmux_resolve_pane accepted a pane id that was not in the listing it had just gated on"
  fi
  [ -z "$(PATH="$fb:$PATH" FM_FAKE_DM_PANE='%77' fm_tmux_resolve_pane 'sess:win' 2>/dev/null)" ] \
    || fail "fm_tmux_resolve_pane printed a pane id that was not in the listing"
  pass "fm_tmux_resolve_pane refuses an identity that is absent from the listing it gated on"
}

test_resolver_refuses_what_display_message_would_answer
test_resolver_returns_the_pane_the_target_names
test_resolver_gates_before_it_reads
test_agent_alive_never_reads_the_fallback_pane
test_agent_alive_still_reads_a_real_target
test_target_exists_refuses_an_invented_window
test_crew_state_presence_has_one_owner
test_current_path_refuses_an_invented_window
test_send_key_preflight_actually_verifies
test_legacy_keeper_ownership_resolves_before_reading_pid
test_no_unguarded_display_message_read_in_bin
test_resolver_is_built_on_a_refusing_command
