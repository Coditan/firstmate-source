#!/usr/bin/env bash
# Opt-in credentialed OpenCode continuity regression on an isolated project and
# FM_HOME. Existing OpenCode credentials stay in their managed store.
set -u

if [ "${FM_OPENCODE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OPENCODE_LIVE_E2E=1 to run the interactive OpenCode continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v opencode >/dev/null 2>&1 || fail "opencode not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found"

TMUX=$(command -v tmux)
SOCKET="fm-opencode-live-e2e-$$"
LAB="$ROOT/.opencode-live-e2e.$$"
OPENCODE_VERSION=$(opencode --version)
AHOY_PROJECT="$LAB/ahoy-project"
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode session-start "$LEGACY_START" CURRENT_START \
  || fail "could not construct the current session-start fixture"
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

wait_for_text() {
  local expected=$1 attempts=${2:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_absent() {
  local unexpected=$1 attempts=${2:-60} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$unexpected" || return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

dismiss_update_offer() {
  capture | grep -Fq "Update Available" || return 0
  # Choose Skip explicitly. Escape merely hides the offer until the next idle
  # event, which can obstruct the watcher follow-up under test.
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Left Enter
  wait_for_absent "Update Available" 60
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 db="$LAB/opencode-$1.db"
  local assistant_text first_out second_out session_id status=0
  first_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --pure --format json "$preceding"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label setup exited $status: $first_out"
  session_id=$(printf '%s\n' "$first_out" | jq -r 'select(.sessionID != null) | .sessionID' | head -1)
  [ -n "$session_id" ] || fail "OpenCode Ahoy $label setup did not return a session id: $first_out"

  status=0
  second_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --pure --format json --session "$session_id" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label case exited $status: $second_out"
  assistant_text=$(printf '%s\n' "$second_out" | jq -r 'select(.type == "text") | .part.text' | tail -1)
  case "$expected" in
    bearings)
      printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "OpenCode Ahoy $label case did not take Bearings: $second_out"
      ;;
    boundary)
      printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "OpenCode Ahoy $label near miss was treated as operational: $second_out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p \
    "$AHOY_PROJECT/.opencode/plugins" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    "$ROOT/.opencode/plugins/package.json" \
    "$AHOY_PROJECT/.opencode/plugins/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$ROOT/bin/fm-harness-pid-lib.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native OpenCode Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

wait_for_db_count() {
  local db=$1 query=$2 expected=$3 attempts=${4:-180} i=0 actual
  while [ "$i" -lt "$attempts" ]; do
    actual=
    if [ -f "$db" ]; then
      actual=$(sqlite3 "$db" "$query" 2>/dev/null || true)
    fi
    [ "$actual" = "$expected" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

run_native_ahoy_regressions() {
  local first_home="$LAB/opencode-ahoy-first-home"
  local later_home="$LAB/opencode-ahoy-later-home"
  local first_db="$LAB/opencode-ahoy-first.db"
  local later_db="$LAB/opencode-ahoy-later.db"
  local native_session=opencode-ahoy-native
  local session_id startup_text assistant_text session_count status

  mkdir -p \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"

  status=0
  (
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$first_db" FM_HOME="$first_home" \
        OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --format json --auto "/ahoy"
  ) >/dev/null || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode native first-message Ahoy exited $status"
  session_id=$(sqlite3 "$first_db" 'select id from session order by time_created desc limit 1;')
  startup_text=$(sqlite3 -json "$first_db" \
    "select json_extract(p.data,'$.text') text from message m join part p on p.message_id=m.id where json_extract(m.data,'$.role')='user' and json_extract(p.data,'$.text') like '%FIRSTMATE_OP:%' order by m.time_created limit 1;" \
    | jq -r '.[0].text')
  [ "$startup_text" = "$CURRENT_START" ] \
    || fail "OpenCode native first-message session stored an unexpected typed startup input: $startup_text"
  assistant_text=$(sqlite3 -json "$first_db" \
    "select json_extract(p.data,'$.text') text from message m join part p on p.message_id=m.id where json_extract(m.data,'$.role')='assistant' and json_extract(p.data,'$.type')='text' order by m.time_created desc limit 1;" \
    | jq -r '.[0].text')
  printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "OpenCode native first-message Ahoy did not take Bearings: $assistant_text"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native first-message Ahoy did not preserve one session-start execution"
  session_count=$(sqlite3 "$first_db" 'select count(*) from session;')
  [ "$session_count" = 1 ] || fail "OpenCode native first-message Ahoy left the original session"

  "$TMUX" -L "$SOCKET" new-session -d -s "$native_session" -c "$AHOY_PROJECT" \
    "env OPENCODE_DB='$later_db' FM_HOME='$later_home' OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --auto"
  i=0
  while [ "$i" -lt 120 ]; do
    "$TMUX" -L "$SOCKET" capture-pane -p -t "$native_session" 2>/dev/null | grep -Fq "$OPENCODE_VERSION" && break
    sleep 0.5
    i=$((i + 1))
  done
  [ "$i" -lt 120 ] || fail "OpenCode native later-message session did not reach its TUI"
  "$TMUX" -L "$SOCKET" send-keys -t "$native_session" -l "Respond exactly PRIOR_BOUNDARY_ACK."
  "$TMUX" -L "$SOCKET" send-keys -t "$native_session" Enter
  wait_for_db_count "$later_db" \
    "select count(*) from message m join part p on p.message_id=m.id where json_extract(m.data,'$.role')='assistant' and json_extract(p.data,'$.type')='text' and json_extract(p.data,'$.text') like '%PRIOR_BOUNDARY_ACK%';" \
    1 || fail "OpenCode native later-message setup did not preserve the genuine captain boundary"
  session_id=$(sqlite3 "$later_db" 'select id from session order by time_created desc limit 1;')
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native later-message setup did not run session start exactly once"
  "$TMUX" -L "$SOCKET" kill-server

  status=0
  (
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$later_db" FM_HOME="$later_home" \
        OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --format json --auto --session "$session_id" "/ahoy"
  ) >/dev/null || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode native later-message Ahoy exited $status"
  assistant_text=$(sqlite3 -json "$later_db" \
    "select json_extract(p.data,'$.text') text from message m join part p on p.message_id=m.id where m.session_id='$session_id' and json_extract(m.data,'$.role')='assistant' and json_extract(p.data,'$.type')='text' order by m.time_created desc limit 1;" \
    | jq -r '.[0].text')
  printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "OpenCode native later-message Ahoy gathered Bearings: $assistant_text"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native later-message Ahoy reran session start"
  session_count=$(sqlite3 "$later_db" 'select count(*) from session;')
  [ "$session_count" = 1 ] || fail "OpenCode native later-message Ahoy left the original session"
}

mkdir -p "$LAB"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
# The plugin-owned delivery-arm cycle this section used to regress no longer
# exists: wake delivery is an external service, and no OpenCode plugin holds a
# delivery child any more. What replaced it is proven where it can actually be
# proven - tests/fm-delivery.test.sh drives the listener into a real tmux agent
# composer, and tests/fm-watcher-systemd-smoke.test.sh proves the systemd unit
# restarts it. This credentialed regression keeps the part that still has a live
# subject: OpenCode's native Ahoy handling above.

printf 'ok - OpenCode %s live E2E covered native Ahoy first/later messages and near misses\n' "$OPENCODE_VERSION"
