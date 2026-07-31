#!/usr/bin/env bash
# tests/fm-test-lib.test.sh - shared test-helper cleanup behavior.
# The shared temp-root helper must register cleanup in the caller shell and turn
# catchable interrupts into explicit exits through the current EXIT trap.
# SIGKILL is intentionally not covered because the kernel does not allow Bash to
# trap it; timeout wrappers must allow their initial HUP, INT, or TERM to run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-test-lib

PROBE="$TMP_ROOT/cleanup-probe.sh"
cat > "$PROBE" <<'PROBE'
#!/usr/bin/env bash
set -u
. "$1"
fm_test_tmproot scratch fm-test-lib-child

printf '%s\n' "$scratch" > "$2"
case "$3" in
  exit) exit 0 ;;
  failure) exit 17 ;;
  term-custom-exit)
    marker=$4
    trap 'printf "custom-exit-ran\n" > "$marker"; fm_test_cleanup' EXIT
    while :; do sleep 1; done
    ;;
  *) exit 2 ;;
esac
PROBE
chmod +x "$PROBE"

# fm_ignore_probe_isolate deletes a repository's private .git/info/exclude and
# rewrites its git config, so its refusals are the only thing standing between a
# mis-aimed call and a working home losing protection it can never get back.
# fail() exits, so the refusals have to be exercised in a child process.
ISOLATE_PROBE="$TMP_ROOT/isolate-probe.sh"
cat > "$ISOLATE_PROBE" <<'PROBE'
#!/usr/bin/env bash
set -u
. "$1"
fm_ignore_probe_isolate "$2"
printf 'isolate-mutated-the-target\n'
PROBE
chmod +x "$ISOLATE_PROBE"

# Every ignore source a mis-aimed call would destroy, as one comparable string.
# A worktree keeps info/exclude in the common git dir, so both are recorded.
ignore_source_fingerprint() {
  local repo=$1 dir
  for dir in "$(git -C "$repo" rev-parse --absolute-git-dir)" \
             "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"; do
    if [ -f "$dir/info/exclude" ]; then
      printf '%s: %s\n' "$dir/info/exclude" "$(cksum < "$dir/info/exclude")"
    else
      printf '%s: absent\n' "$dir/info/exclude"
    fi
  done
  git -C "$repo" config --local --list 2>/dev/null || true
}

wait_for_path() {
  local file=$1 pid=$2 i=0
  while [ "$i" -lt 50 ] && [ ! -s "$file" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$file" ]
}

test_normal_exit_cleans_registered_root() {
  local path_file="$TMP_ROOT/normal.path" scratch
  bash "$PROBE" "$ROOT/tests/lib.sh" "$path_file" exit || fail "normal cleanup probe failed"
  scratch=$(cat "$path_file")
  [ ! -e "$scratch" ] || {
    rm -rf "$scratch"
    fail "caller-shell temp root survived normal exit"
  }
  pass "caller-shell temp-root registration cleans on normal exit"
}

test_failed_exit_cleans_registered_root() {
  local path_file="$TMP_ROOT/failure.path" rc=0 scratch
  bash "$PROBE" "$ROOT/tests/lib.sh" "$path_file" failure || rc=$?
  [ "$rc" -eq 17 ] || fail "failed cleanup probe returned $rc instead of 17"
  scratch=$(cat "$path_file")
  [ ! -e "$scratch" ] || {
    rm -rf "$scratch"
    fail "caller-shell temp root survived a failed test exit"
  }
  pass "caller-shell temp-root registration cleans when a test fails"
}

test_term_runs_custom_exit_and_cleans_registered_root() {
  local path_file="$TMP_ROOT/term.path" marker="$TMP_ROOT/custom-exit" pid rc scratch
  bash "$PROBE" "$ROOT/tests/lib.sh" "$path_file" term-custom-exit "$marker" &
  pid=$!
  wait_for_path "$path_file" "$pid" || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "TERM cleanup probe did not publish its scratch path"
  }
  kill -TERM "$pid" || fail "could not interrupt cleanup probe"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ] || fail "TERM cleanup probe returned $rc instead of 143"
  scratch=$(cat "$path_file")
  [ -f "$marker" ] || fail "test-owned EXIT trap did not run after TERM"
  [ ! -e "$scratch" ] || {
    rm -rf "$scratch"
    fail "registered temp root survived TERM"
  }
  pass "TERM preserves a test-owned EXIT trap and cleans its registered root"
}

test_output_var_named_root_is_assigned() {
  local root
  fm_test_tmproot root fm-test-lib-collide
  [ -n "${root:-}" ] || fail "output variable named 'root' was not assigned"
  [ -d "$root" ] || fail "output variable named 'root' does not point at a temp dir"
  pass "fm_test_tmproot assigns a caller variable named 'root' without collision"
}

test_ignore_probe_isolate_refuses_the_live_checkout() {
  local before after out rc=0
  before=$(ignore_source_fingerprint "$ROOT")
  out=$(bash "$ISOLATE_PROBE" "$ROOT/tests/lib.sh" "$ROOT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "fm_ignore_probe_isolate accepted the live checkout instead of refusing it"
  assert_contains "$out" "refusing to isolate the live checkout" \
    "the live-checkout refusal does not say which repository it protected"
  after=$(ignore_source_fingerprint "$ROOT")
  [ "$before" = "$after" ] \
    || fail "fm_ignore_probe_isolate changed the live checkout's ignore sources before refusing"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  pass "fm_ignore_probe_isolate refuses the live checkout without touching it"
}

test_ignore_probe_isolate_refuses_a_repository_it_did_not_create() {
  local scratch before after out rc=0
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-lib-unowned.XXXXXX") \
    || fail "could not create the unowned probe repository"
  git -C "$scratch" init -q || { rm -rf "$scratch"; fail "could not init $scratch"; }
  printf '/config/\n' > "$scratch/.git/info/exclude" \
    || { rm -rf "$scratch"; fail "could not seed the private exclude in $scratch"; }
  before=$(ignore_source_fingerprint "$scratch")

  out=$(bash "$ISOLATE_PROBE" "$ROOT/tests/lib.sh" "$scratch" 2>&1) || rc=$?
  after=$(ignore_source_fingerprint "$scratch")
  rm -rf "$scratch"
  [ "$rc" -ne 0 ] \
    || fail "fm_ignore_probe_isolate accepted a repository no test process created"
  assert_contains "$out" "is not a throwaway probe this test process created" \
    "the unowned-repository refusal does not say what it expected"
  [ "$before" = "$after" ] \
    || fail "fm_ignore_probe_isolate changed an unowned repository's ignore sources before refusing"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  pass "fm_ignore_probe_isolate refuses a repository it did not create as a throwaway"
}

test_normal_exit_cleans_registered_root
test_failed_exit_cleans_registered_root
test_term_runs_custom_exit_and_cleans_registered_root
test_output_var_named_root_is_assigned
test_ignore_probe_isolate_refuses_the_live_checkout
test_ignore_probe_isolate_refuses_a_repository_it_did_not_create
