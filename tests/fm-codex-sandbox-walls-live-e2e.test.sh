#!/usr/bin/env bash
# Opt-in credentialed Codex regression for the TWO walls a Codex worker meets on a
# host whose kernel refuses to start a sandbox:
#
#   wall 1 - running a command. The worktree-isolation assertion every ship brief
#            demands as its first action is a shell command, and a sandboxed one
#            fails before it runs.
#   wall 2 - editing a file. apply_patch routes through the same sandbox even on an
#            approved uncontained path, so a worker that cleared wall 1 still
#            changed zero files. Passing only wall 1 is what made this look fixed
#            once already, which is why both are asserted here.
#
# The unit coverage in tests/fm-spawn-dispatch-profile.test.sh pins the launch line
# fm-spawn composes for each host shape. This regression is the other half: it asks a
# REAL codex on THIS host whether that launch line actually works, so the fix rests on
# a measurement rather than on the flag's name. It costs a model call, so it is
# opt-in (docs/codex-sandbox-unavailable.md).
set -u

if [ "${FM_CODEX_SANDBOX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_SANDBOX_LIVE_E2E=1 to run the real Codex sandbox-wall regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v codex >/dev/null 2>&1 || fail "codex not found"

if unshare --user --map-root-user true >/dev/null 2>&1; then
  echo "skip: this host CAN start a sandbox, so it meets neither wall; run this on a host that cannot"
  exit 0
fi

TMP=$(mktemp -d) || fail "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# The mode fm-spawn composes for a host that fails the probe, read out of the script
# rather than restated here, so this regression cannot pass against a mode the fix no
# longer uses.
MODE=$(sed -n 's/^[[:space:]]*CODEX_LAUNCH_SANDBOX_MODE=\([a-z][a-z-]*\)$/\1/p' "$ROOT/bin/fm-spawn.sh")
[ -n "$MODE" ] || fail "could not read the degraded sandbox mode out of bin/fm-spawn.sh"

# Wall 1: a command runs.
# shellcheck disable=SC2016  # the backticks are prompt text for codex, not a shell expansion
out=$(cd "$TMP" && codex exec --skip-git-repo-check --sandbox "$MODE" \
  'Run the shell command `pwd -P` and reply with nothing but its output.' </dev/null 2>&1) \
  || fail "codex exec refused to run at all under --sandbox $MODE"$'\n'"$out"
printf '%s\n' "$out" | grep -qF "$(cd "$TMP" && pwd -P)" \
  || fail "wall 1: no command output came back under --sandbox $MODE"$'\n'"$out"
pass "wall 1: a shell command runs under the sandbox mode a degraded host launches with"

# Wall 2: a file edit lands. Asserted on the FILE, never on what codex says it did.
out=$(cd "$TMP" && codex exec --skip-git-repo-check --sandbox "$MODE" \
  'Create a file named wall2.txt in the current directory whose only content is the word landed.' </dev/null 2>&1) \
  || fail "codex exec failed while editing a file under --sandbox $MODE"$'\n'"$out"
[ -f "$TMP/wall2.txt" ] \
  || fail "wall 2: codex reported success but wrote no file under --sandbox $MODE"$'\n'"$out"
grep -qi landed "$TMP/wall2.txt" \
  || fail "wall 2: the file exists but does not carry the requested content"
pass "wall 2: a file edit actually lands under the sandbox mode a degraded host launches with"

echo "# all fm-codex-sandbox-walls-live-e2e tests passed"
