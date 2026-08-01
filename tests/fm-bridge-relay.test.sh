#!/usr/bin/env bash
# Behavior tests for the guarded envelope-only Bridge relay dispatcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAY="$ROOT/bin/fm-bridge-relay.sh"
fm_test_tmproot TMP_ROOT fm-bridge-relay-tests
fm_git_identity fmtest fmtest@example.invalid

make_bridge() {
  local name=$1 home seed origin bridge origin_abs script
  home="$TMP_ROOT/$name/home"
  seed="$TMP_ROOT/$name/seed"
  origin="$TMP_ROOT/$name/origin.git"
  bridge="$home/projects/coditan-bridge"
  mkdir -p "$seed/bin" "$home/projects"

  cat > "$seed/bin/bridge-stub.sh" <<'SH'
#!/usr/bin/env bash
{
  printf 'script=%s\n' "$(basename "$0")"
  printf 'cwd=%s\n' "$PWD"
  printf 'argc=%s\n' "$#"
  index=0
  for arg in "$@"; do
    printf 'arg%s=<%s>\n' "$index" "$arg"
    index=$(( index + 1 ))
  done
  # What the checkout's working tree actually holds when the script runs: a read
  # answers from this, so a clone left behind origin sees nothing here.
  for envelope in inbox/*/new/*.json; do
    [ -e "$envelope" ] || continue
    printf 'seen=%s\n' "$envelope"
  done
} > "${BRIDGE_RELAY_CAPTURE:?}"
SH
  for script in send inbox status broadcast; do
    cp "$seed/bin/bridge-stub.sh" "$seed/bin/bridge-$script.sh"
    chmod +x "$seed/bin/bridge-$script.sh"
  done
  rm "$seed/bin/bridge-stub.sh"

  git -C "$seed" init -q -b main
  git -C "$seed" add bin
  git -C "$seed" commit -qm initial
  git clone -q --bare "$seed" "$origin"
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  origin_abs=$(cd "$origin" && pwd -P)
  git clone -q "file://$origin_abs" "$bridge"
  printf '%s\n' "$home"
}

# Publish one envelope straight to origin, leaving the clone one commit behind.
# This is the reported failure's exact shape: the mail exists at origin while
# the checkout's working tree still holds an empty mailbox.
publish_envelope_at_origin() {
  local name=$1 vessel=$2 origin work
  origin=$(cd "$TMP_ROOT/$name/origin.git" && pwd -P)
  work="$TMP_ROOT/$name/publisher"
  git clone -q "file://$origin" "$work"
  mkdir -p "$work/inbox/$vessel/new"
  printf '{"priority":"high"}\n' > "$work/inbox/$vessel/new/2026-08-01T00-56-11Z-envelope.json"
  git -C "$work" add -A
  git -C "$work" commit -qm "envelope for $vessel"
  git -C "$work" push -q origin main
}

# Let the clone learn it is behind, then make origin unreachable so the guarded
# refresh cannot complete.
strand_clone() {
  local name=$1
  git -C "$TMP_ROOT/$name/home/projects/coditan-bridge" fetch -q origin main
  mv "$TMP_ROOT/$name/origin.git" "$TMP_ROOT/$name/origin-gone.git"
}

# run_relay <home> [args...]: run the relay against a fixture home with stderr
# merged into stdout. Two knobs a caller may set for the duration of its own
# calls: RELAY_PATH_PREFIX prepends a fakebin dir to PATH, and
# RELAY_FLEET_SYNC_RETRIES overrides fleet-sync's packed-refs lock retry count so
# a simulated lock race does not sit through its real retry waits.
run_relay() {
  local home=$1
  shift
  PATH="${RELAY_PATH_PREFIX:+$RELAY_PATH_PREFIX:}$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES="${RELAY_FLEET_SYNC_RETRIES:-3}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" BRIDGE_RELAY_CAPTURE="$home/capture" \
    "$RELAY" "$@" 2>&1
}

# Shim git so every fetch loses a race for a lock the way a concurrent
# whole-fleet sync (bin/fm-bootstrap.sh) makes it lose one, while every other
# git call stays real. Echoes the fakebin dir to prepend to PATH.
shim_git_fetch_lock_contention() {
  local home=$1 lock=$2 fakebin real
  real=$(command -v git)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    printf "fatal: Unable to create '%s': File exists.\\n" "$lock" >&2
    exit 128
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# Shim sed so fm-fleet-sync.sh dies mid-run instead of reporting a per-project
# outcome: it composes its skip reason through sed, so the crash lands the relay
# on the genuine no-outcome path, where fleet-sync's stderr is the only
# diagnosis the operator has. Echoes the fakebin dir to prepend to PATH.
shim_broken_sed() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/sed" <<'SH'
#!/usr/bin/env bash
echo "sed: simulated tool failure" >&2
exit 1
SH
  chmod +x "$fakebin/sed"
  printf '%s\n' "$fakebin"
}

test_unknown_subcommand_is_rejected() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/missing" FM_ROOT_OVERRIDE="$ROOT" "$RELAY" fetch 2>&1); rc=$?
  expect_code 1 "$rc" "unknown subcommand"
  assert_contains "$out" "unknown subcommand 'fetch'" "unknown subcommand was not identified"
  assert_contains "$out" 'usage: fm-bridge-relay.sh <send|inbox|status|broadcast> [args...]' \
    "unknown subcommand did not print usage"
  pass "Bridge relay rejects every unlisted subcommand before checkout inspection"
}

test_dirty_checkout_is_rejected() {
  local home bridge out rc
  home=$(make_bridge dirty)
  bridge="$home/projects/coditan-bridge"
  printf 'uncommitted\n' > "$bridge/dirty.txt"

  out=$(run_relay "$home" send vessel payload); rc=$?
  expect_code 1 "$rc" "dirty checkout"
  assert_contains "$out" 'has uncommitted changes' "dirty checkout refusal was unclear"
  assert_absent "$home/capture" "dirty checkout still invoked the Bridge script"
  pass "Bridge relay refuses a dirty target checkout without dispatching"
}

test_non_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge off-default)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" checkout -qb feature

  out=$(run_relay "$home" status vessel busy); rc=$?
  expect_code 1 "$rc" "non-default branch"
  assert_contains "$out" "must be on default branch 'main' (found 'feature')" \
    "non-default branch refusal was unclear"
  assert_absent "$home/capture" "non-default branch still invoked the Bridge script"
  pass "Bridge relay refuses a checkout that is not on its default branch"
}

test_untracked_default_branch_is_rejected() {
  local home bridge out rc
  home=$(make_bridge no-upstream)
  bridge="$home/projects/coditan-bridge"
  git -C "$bridge" branch --unset-upstream

  out=$(run_relay "$home" inbox list); rc=$?
  expect_code 1 "$rc" "untracked default branch"
  assert_contains "$out" "default branch 'main' is not tracking an upstream" \
    "missing-upstream refusal was unclear"
  assert_absent "$home/capture" "untracked default branch still invoked the Bridge script"
  pass "Bridge relay refuses a default branch without an upstream"
}

test_valid_calls_dispatch_verbatim() {
  local home bridge subcommand capture out
  home=$(make_bridge valid)
  bridge="$home/projects/coditan-bridge"

  for subcommand in send inbox status broadcast; do
    capture="$home/capture"
    rm -f "$capture"
    out=$(run_relay "$home" "$subcommand" 'argument with spaces' '--literal=*' '')
    [ -z "$out" ] || fail "$subcommand dispatch produced unexpected output: $out"
    assert_grep "script=bridge-$subcommand.sh" "$capture" \
      "$subcommand did not select its matching Bridge script"
    assert_grep "cwd=$bridge" "$capture" "$subcommand did not run inside the Bridge checkout"
    assert_grep 'argc=3' "$capture" "$subcommand did not preserve the argument count"
    assert_grep 'arg0=<argument with spaces>' "$capture" "$subcommand changed a spaced argument"
    assert_grep 'arg1=<--literal=*>' "$capture" "$subcommand expanded a literal argument"
    assert_grep 'arg2=<>' "$capture" "$subcommand dropped an empty argument"
  done
  pass "Bridge relay maps all four commands and forwards arguments verbatim from the checkout"
}

test_behind_checkout_is_refreshed_before_a_read() {
  local home out rc
  home=$(make_bridge behind)
  publish_envelope_at_origin behind tugboat

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read against a behind checkout"
  [ -z "$out" ] || fail "read against a behind checkout produced unexpected output: $out"
  assert_grep 'seen=inbox/tugboat/new/2026-08-01T00-56-11Z-envelope.json' "$home/capture" \
    "the read still answered from a checkout that was behind origin"
  pass "Bridge relay brings the checkout current before a read, so mail at origin is visible"
}

test_stranded_checkout_refuses_a_read() {
  local home out rc
  home=$(make_bridge stranded)
  publish_envelope_at_origin stranded tugboat
  strand_clone stranded

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read against a checkout that cannot be refreshed"
  assert_contains "$out" 'STALE CHECKOUT' "stale refusal was not identified as such"
  assert_contains "$out" 'NOTHING WAS READ' \
    "stale refusal could be mistaken for an empty mailbox"
  assert_contains "$out" 'unread mail may be waiting at origin' \
    "stale refusal did not warn about mail left unread"
  # The refresh DID run here and reported a fetch failure, so the refusal must
  # report that outcome rather than claim the refresh never completed.
  assert_contains "$out" 'the refresh ran and was blocked by the outcome it reports below' \
    "stale refusal gave no reason"
  assert_contains "$out" 'skipped: fetch failed' "stale refusal did not quote the refresh outcome"
  assert_not_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that ran and reported a fetch failure was described as not having completed"
  assert_absent "$home/capture" "stale checkout still invoked the Bridge script"
  pass "Bridge relay refuses a read it cannot prove current, instead of answering empty"
}

test_no_outcome_refusal_surfaces_the_refresh_error() {
  local home out rc RELAY_PATH_PREFIX
  home=$(make_bridge no-outcome)
  publish_envelope_at_origin no-outcome tugboat
  strand_clone no-outcome
  RELAY_PATH_PREFIX=$(shim_broken_sed "$home")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read after a refresh that reported no outcome"
  assert_contains "$out" 'STALE CHECKOUT' "no-outcome refusal was not identified as stale"
  assert_contains "$out" 'NOTHING WAS READ' \
    "no-outcome refusal could be mistaken for an empty mailbox"
  assert_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that reported nothing was not described as incomplete"
  assert_contains "$out" 'sed: simulated tool failure' \
    "the no-outcome refusal threw away the only diagnosis fleet-sync produced"
  assert_absent "$home/capture" "a refresh that reported nothing still invoked the Bridge script"
  pass "Bridge relay surfaces fleet-sync's stderr when the refresh reported no outcome at all"
}

test_diverged_checkout_refuses_a_read() {
  local home bridge out rc
  home=$(make_bridge diverged)
  bridge="$home/projects/coditan-bridge"
  publish_envelope_at_origin diverged tugboat
  printf 'local\n' > "$bridge/local.txt"
  git -C "$bridge" add local.txt
  git -C "$bridge" commit -qm "local-only commit"

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read against a diverged checkout"
  assert_contains "$out" 'STALE CHECKOUT' "diverged refusal was not identified as stale"
  assert_contains "$out" 'STUCK: on diverged main' "diverged refusal did not relay the refresh outcome"
  assert_contains "$out" 'reported the clone stuck' "diverged refusal misstated why it refused"
  assert_not_contains "$out" 'the guarded refresh did not complete' \
    "a refresh that ran and proved the clone stuck was described as not having completed"
  # The remedy must not be the command that just produced the STUCK line: fleet
  # sync never forces, resets, or pushes, so re-running it can never clear this.
  assert_contains "$out" "reconcile $bridge with " "diverged refusal did not ask for manual reconciliation"
  assert_not_contains "$out" 'bin/fm-fleet-sync.sh coditan-bridge' \
    "diverged refusal sent the operator back to the command that just reported STUCK"
  assert_absent "$home/capture" "diverged checkout still invoked the Bridge script"
  pass "Bridge relay refuses a read when the checkout cannot be fast-forwarded"
}

test_unrecognized_status_form_refuses_a_read() {
  local home out rc form
  home=$(make_bridge status-forms)
  publish_envelope_at_origin status-forms tugboat
  strand_clone status-forms

  # Anything not positively recognised as a write is a read: an unrecognised
  # status spelling must refuse, never answer from a clone proven not current.
  for form in "status" "status --vessel tugboat" "status --show=tugboat" "status --list"; do
    rm -f "$home/capture"
    # shellcheck disable=SC2086
    out=$(run_relay "$home" $form); rc=$?
    expect_code 1 "$rc" "unrecognised status form '$form' against a stranded checkout"
    assert_contains "$out" 'STALE CHECKOUT' "status form '$form' did not refuse as a read"
    assert_absent "$home/capture" "status form '$form' still invoked the Bridge script"
  done
  pass "Bridge relay treats every status form it cannot recognise as a write as a read that refuses"
}

test_lock_contention_proceeds_only_while_level() {
  local home bridge out rc RELAY_PATH_PREFIX RELAY_FLEET_SYNC_RETRIES=0
  home=$(make_bridge contended)
  bridge="$home/projects/coditan-bridge"
  RELAY_PATH_PREFIX=$(shim_git_fetch_lock_contention "$home" "$bridge/.git/packed-refs.lock")

  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 0 "$rc" "read while the refresh lost a lock race on a level clone"
  assert_contains "$out" 'lost a race for a git lock' \
    "the relaxed read never said it proceeded on a contended refresh"
  assert_grep 'script=bridge-inbox.sh' "$home/capture" \
    "a read on a provably level clone was refused over mere lock contention"

  # Same contention, but the clone is provably behind: nothing is proven now, so
  # the read must still refuse.
  publish_envelope_at_origin contended tugboat
  git -C "$bridge" fetch -q origin main
  rm -f "$home/capture"
  out=$(run_relay "$home" inbox --vessel tugboat); rc=$?
  expect_code 1 "$rc" "read while the refresh lost a lock race on a behind clone"
  assert_contains "$out" 'STALE CHECKOUT' "contended refresh on a behind clone did not refuse"
  assert_absent "$home/capture" "contended refresh on a behind clone still invoked the Bridge script"
  pass "Bridge relay proceeds through lock contention only while the clone is provably level"
}

test_only_read_shaped_calls_refuse() {
  local home out rc capture
  home=$(make_bridge shapes)
  publish_envelope_at_origin shapes tugboat
  strand_clone shapes
  capture="$home/capture"

  rm -f "$capture"
  out=$(run_relay "$home" status --show tugboat); rc=$?
  expect_code 1 "$rc" "status --show against a stranded checkout"
  assert_contains "$out" 'STALE CHECKOUT' "status --show did not refuse as a read"
  assert_absent "$capture" "status --show still invoked the Bridge script"

  # A publishing call still dispatches: its own publish path reconciles with
  # origin, and refusing it would strand outbound traffic rather than protect it.
  for args in "send hlr status subject --from tugboat" "broadcast status subject --from tugboat" \
      "status --push --vessel tugboat" "inbox --gc --vessel tugboat"; do
    rm -f "$capture"
    # shellcheck disable=SC2086
    out=$(run_relay "$home" $args); rc=$?
    expect_code 0 "$rc" "publishing call '$args' against a stranded checkout"
    assert_contains "$out" 'not proven current' "publishing call '$args' dispatched with no warning"
    assert_grep 'script=bridge-' "$capture" "publishing call '$args' never reached the Bridge script"
  done
  pass "Bridge relay refuses only the read-shaped calls and warns on the publishing ones"
}

test_unknown_subcommand_is_rejected
test_dirty_checkout_is_rejected
test_non_default_branch_is_rejected
test_untracked_default_branch_is_rejected
test_valid_calls_dispatch_verbatim
test_behind_checkout_is_refreshed_before_a_read
test_stranded_checkout_refuses_a_read
test_no_outcome_refusal_surfaces_the_refresh_error
test_diverged_checkout_refuses_a_read
test_unrecognized_status_form_refuses_a_read
test_lock_contention_proceeds_only_while_level
test_only_read_shaped_calls_refuse
