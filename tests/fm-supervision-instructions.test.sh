#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-supervision-instructions

RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: external wake delivery, Codex primary." "codex snippet missing"
  assert_not_contains "$out" "Claude primary" "renderer printed the claude snippet too"
  assert_not_contains "$out" "Pi primary" "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "unrecognized primary harness" "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: external wake delivery, Codex primary.' "codex snippet missing"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  # The repair is the same on every harness now, because the thing being
  # repaired is a service, not a harness object.
  local harness
  for harness in claude codex grok opencode pi; do
    out=$(FM_HOME="$home" "$RENDER" --harness "$harness" --repair-line)
    assert_contains "$out" "wake-delivery listener is not running" \
      "$harness repair line does not name the down listener"
    assert_contains "$out" "bin/fm-delivery-service.sh status" \
      "$harness repair line does not tell the model how to confirm the repair"
    assert_contains "$out" "there is no longer such a thing" \
      "$harness repair line does not refuse the old arm-a-session-wait reflex"
  done

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_not_contains "$out" "source '$home/config/x-mode.env' first" "x-mode delivery repair still sourced daemon-owned cadence"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --afk 1 --repair-line)
  assert_contains "$out" "no live identity-matched away daemon" "away repair line does not describe the dead-daemon situation"
  assert_contains "$out" "bin/fm-afk-launch.sh start-native" "claude away repair line does not use the native no-terminal preparation"
  assert_contains "$out" "FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh" "claude away repair line does not name the native daemon entry"
  assert_contains "$out" "Claude Code background task" "claude away repair line does not host the daemon in the native background tool"
  assert_contains "$out" "bin/fm-afk-launch.sh stop, which EXITS away mode by clearing state/.afk" "away rollback does not state that it leaves away mode"
  assert_contains "$out" "followed immediately by a fresh away entry" "away rollback does not require re-entering away mode"
  assert_not_contains "$out" "load /afk" "away repair line still described the old delivery-ownership contract"
  assert_not_contains "$out" "wake-delivery listener is not running" "away repair line pointed at the listener instead of the away daemon"

  out=$(FM_HOME="$home" "$RENDER" --harness grok --afk 1 --repair-line)
  assert_contains "$out" "bin/fm-afk-launch.sh start-native" "grok away repair line does not use the native no-terminal preparation"
  assert_contains "$out" "Grok tracked background task" "grok away repair line does not host the daemon in the native background tool"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --afk 1 --repair-line)
  assert_contains "$out" "bin/fm-afk-launch.sh start" "pi away repair line does not name the terminal-backed launcher"
  assert_not_contains "$out" "start-native" "pi has no native background tool and must not be sent down the native path"
  assert_not_contains "$out" "bin/fm-delivery-service.sh restart" "away repair line pointed at the listener instead of the away daemon"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --repair-line)
  assert_contains "$out" "bin/fm-afk-launch.sh start" "codex away repair line does not name the terminal-backed launcher"
  assert_not_contains "$out" "start-native" "codex wake supervision forbids native background hosting"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --afk 1 --queue-pending 1 --repair-line)
  assert_not_contains "$out" "After draining queued wakes" "away mode must not tell the session to drain the daemon-owned queue"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  pass "renderer repair-line mode names the listener repair and honors conditional state"
}

# The acceptance condition of moving delivery out of the harness, asserted as a
# contract rather than trusted: no snippet may leave a session holding, arming,
# or re-arming a delivery object, and every snippet must say so in its own words
# so a seat reading only its own block cannot reintroduce one.
test_no_snippet_leaves_a_session_held_delivery_object() {
  local harness out banned
  for harness in claude codex grok opencode pi not-real; do
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness:" \
      "$harness block did not render at all, so its absence checks would pass vacuously"
    assert_contains "$out" "holds no wake-delivery object" \
      "$harness snippet does not state that the session holds no delivery object"
    assert_contains "$out" "bin/fm-wake-drain.sh" \
      "$harness snippet lost the drain-first instruction, which is all a wake now requires"
    for banned in fm-watch-arm.sh fm-wake-wait.sh fm-watch-checkpoint.sh fm_watch_arm_pi; do
      assert_not_contains "$out" "$banned" \
        "$harness snippet still names $banned, an object no session holds any more"
    done
    assert_contains "$out" "Do not arm anything" \
      "$harness snippet does not forbid arming a delivery object"
  done
  pass "no harness snippet leaves a session-held, arm-able, or re-armable delivery object"
}

# The block above the snippet is rendered by the script itself rather than read
# from a file, so it needs its own assertion that it did not keep the old
# "re-arm this harness delivery wait" line.
test_current_state_block_states_service_ownership() {
  local out
  out=$("$RENDER" --harness claude)
  assert_contains "$out" "a companion service owns delivery; this session arms nothing" \
    "the rendered current-state block does not state who owns delivery"
  assert_not_contains "$out" "re-arm only this harness delivery wait" \
    "the rendered current-state block kept the old per-harness re-arm line"
  pass "the rendered current-state block names the service as delivery owner"
}

test_grok_keeps_its_passive_stop_backstop() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "bin/fm-turnend-guard-grok.sh" "grok snippet lost its passive Stop-hook backstop"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "synthetic_reason: task_completed" "grok snippet still describes a background-task delivery wake"
  pass "grok keeps its passive Stop-hook backstop with no delivery task of its own"
}

test_no_change_wakes_are_explicitly_silent() {
  local harness out
  for harness in claude codex grok opencode pi; do
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "tool calls and no chat text" "$harness snippet omitted tool-only no-change turns"
    assert_contains "$out" "protocol violation, not politeness" "$harness snippet did not make no-change chat a violation"
  done
  pass "every supported harness makes no-change wake turns explicitly silent"
}

# A harness that refuses a turn with no visible output cannot obey a bare "send no
# chat text", so each snippet must carry the forced-turn floor as well as the rule
# it is an escape from. The restatement half has no harness excuse anywhere, so it
# is asserted on every snippet rather than only on the ones known to refuse.
test_forced_turns_have_a_prescribed_minimum_and_no_repetition() {
  local harness out
  for harness in claude codex grok opencode pi; do
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "send exactly one line holding the marker \`.\` and nothing else" \
      "$harness snippet omitted the forced-turn minimum output"
    assert_contains "$out" "restating an unchanged wait stays a violation even on a turn the harness forced to speak" \
      "$harness snippet let a forced turn excuse restating an unchanged state"
    assert_contains "$out" "docs/silent-turn-attempts.md" \
      "$harness snippet lost the pointer to the measured silent-turn attempts"
  done
  pass "every supported harness prescribes a forced-turn minimum and forbids repetition"
}

# What replaced "re-arm before you reply" is "drain before you read anything
# else". The ordering still has to be stated, because a seat that composes a
# reply first spends the turn the wake paid for.
test_drain_before_reply_ordering() {
  local harness out
  for harness in claude codex grok opencode pi not-real; do
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "before reading anything else and before composing any reply" \
      "$harness snippet lost the drain-before-reply ordering"
  done
  pass "every harness drains before reading anything else or composing a reply"
}

test_agents_md_states_the_external_delivery_contract() {
  local agents
  agents=$(cat "$ROOT/AGENTS.md")
  assert_contains "$agents" "a session holds no delivery object of any kind" \
    "AGENTS.md does not state that no session holds a delivery object"
  assert_contains "$agents" "A wake arrives in the composer and is handled by draining first, before reading anything else and before composing any reply." \
    "AGENTS.md dropped the drain-before-reply ordering"
  assert_contains "$agents" "an empty queue and a dead listener look identical from there" \
    "AGENTS.md dropped the rule that silence never proves delivery is working"
  pass "AGENTS.md states the no-session-object contract, the drain-first ordering, and why silence proves nothing"
}

test_x_mode_cadence_stays_with_the_service() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_not_contains "$out" "source '$config/x-mode.env'" "the rendered block still makes the session source the service-owned x-mode config"
  pass "x-mode cadence stays with the watcher service rather than the session"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend" "pi snippet did not render the effective turn-end guard launch path"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "fm-primary-pi-watch.ts" "pi snippet still names the removed watch extension"
  pass "pi supervision snippet renders the effective turn-end extension path"
}

# The ceiling reaches the model as a watcher-measured check wake carrying its own
# payload, so the session-start block must not carry a second, staler copy of the
# rule: a block rendered once at session start cannot know a threshold that is
# crossed hours later, and a model that believed it could would stop reading the
# wake that actually measured it.
test_context_ceiling_is_left_to_the_wake_payload() {
  local harness out snippet swept=0 nullglob_was
  for harness in claude codex grok opencode pi not-real; do
    out=$("$RENDER" --harness "$harness")
    # A positive anchor first: an absence assertion against empty output passes
    # vacuously, so prove the renderer actually produced this harness's block
    # before asserting the ceiling rule is absent from it. If the renderer ever
    # exits non-zero with empty stdout, this fails instead of a silent all-clear.
    assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness:" \
      "$harness block did not render at all, so its absence checks would pass vacuously"
    assert_not_contains "$out" "300k" "$harness block restates a ceiling the watcher measures and the wake carries"
    # The mechanism renders the ceiling as 300000, not 300k, so the likeliest
    # reintroduction of the rule would evade a 300k-only guard.
    assert_not_contains "$out" "300000" "$harness block restates the raw ceiling value the mechanism renders"
    assert_not_contains "$out" "Context ceiling" "$harness block restates the context-ceiling rule"
  done

  # An absence assertion passes loudest when it checks nothing: without nullglob
  # an unmatched glob leaves the literal pattern, the loop body runs once on a
  # path that does not exist, and the swept>0 guard below can never fire because
  # the loop always ran at least once. Enable nullglob so an unmatched glob
  # expands to nothing, the loop is skipped, and swept stays 0 for the guard to
  # catch.
  shopt -q nullglob && nullglob_was=1 || nullglob_was=0
  shopt -s nullglob
  for snippet in "$ROOT"/docs/supervision-protocols/*.md; do
    assert_no_grep '300k' "$snippet" "per-harness snippet $snippet carries a copy of the context-ceiling rule"
    assert_no_grep '300000' "$snippet" "per-harness snippet $snippet carries the raw context-ceiling value"
    swept=$((swept + 1))
  done
  [ "$nullglob_was" = 1 ] || shopt -u nullglob
  [ "$swept" -gt 0 ] || fail "no supervision-protocols snippets were checked for the context-ceiling rule"
  pass "the supervision block leaves the context ceiling to the wake that measures it"
}

test_selected_harness_block_only
test_unknown_fallback
test_context_ceiling_is_left_to_the_wake_payload
test_conditional_stanzas
test_repair_lines
test_no_snippet_leaves_a_session_held_delivery_object
test_current_state_block_states_service_ownership
test_grok_keeps_its_passive_stop_backstop
test_no_change_wakes_are_explicitly_silent
test_forced_turns_have_a_prescribed_minimum_and_no_repetition
test_drain_before_reply_ordering
test_agents_md_states_the_external_delivery_contract
test_x_mode_cadence_stays_with_the_service
test_pi_snippet_uses_effective_extension_path
