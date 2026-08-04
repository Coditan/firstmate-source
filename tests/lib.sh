#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bootstrap's production AXI-suite check performs registry reads and package
# updates. Behavior tests opt out globally; fm-axi-suite.test.sh explicitly
# re-enables it against its isolated fake npm registry.
export FM_AXI_SUITE_DISABLE=1

# fm_axi_prepend_path records the pre-prepend PATH here and never overwrites it,
# so a suite launched from inside a firstmate session would otherwise inherit the
# operator's own ambient environment and ask the shadow check about that instead
# of about its fixture. Cleared once, the same hermeticity discipline as pinning
# PATH via BASE_PATH. Both halves go together: the value and its owner are one
# record, and clearing only one leaves an inherited half the library must then
# refuse to answer for.
unset FM_AXI_AMBIENT_PATH FM_AXI_AMBIENT_PATH_OWNER

# The weekly Grossreinschiff cadence check runs in bootstrap's detect pass, so
# every suite that composes fm-bootstrap.sh would otherwise see its due line the
# moment a fixture home has no sweep record - which is always. Silence the
# detect line suite-wide; tests/fm-grossreinschiff.test.sh sets it back to 0.
export FM_GROSSREINSCHIFF_DISABLE=1

# The watcher-service integration has its own dedicated suite with fake
# systemd and tmux managers.
# Unrelated behavior suites must not inspect or mutate the developer's live
# user manager merely because they compose fm-bootstrap.sh.
export FM_TEST_SKIP_WATCHER_SERVICE=1

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <output-var> [prefix] assigns a fresh temp dir to output-var
# and registers it for removal on EXIT. Assignment must happen in the calling
# shell: command substitution runs the function in a subshell and loses both
# the cleanup registration and its traps. The first call installs the cleanup
# traps. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call fm_test_cleanup from inside it so registered
# dirs are still removed.
#
# HUP, INT, and TERM are converted to explicit exits so the current EXIT trap
# runs on those interrupt paths. SIGKILL cannot be trapped by Bash, so a wrapper
# that escalates to SIGKILL can only be cleaned up if its earlier signal reaches
# this shell and is not deliberately ignored.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

# shellcheck disable=SC2317,SC2329 # Invoked by the signal traps below.
fm_test_signal_exit() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

fm_test_install_cleanup_traps() {
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
    trap 'fm_test_signal_exit 129' HUP
    trap 'fm_test_signal_exit 130' INT
    trap 'fm_test_signal_exit 143' TERM
  fi
}

fm_test_tmproot() {
  local _fm_test_tmproot_output_var=${1:-} _fm_test_tmproot_prefix=${2:-fm-test} _fm_test_tmproot_root
  case "$_fm_test_tmproot_output_var" in
    ''|[0-9]*|*[!a-zA-Z0-9_]*)
      printf 'fm_test_tmproot: first argument must be an output variable name\n' >&2
      return 2
      ;;
  esac
  _fm_test_tmproot_root=$(mktemp -d "${TMPDIR:-/tmp}/${_fm_test_tmproot_prefix}.XXXXXX") \
    || fail "could not create test temp root under ${TMPDIR:-/tmp}"
  fm_test_install_cleanup_traps
  FM_TEST_CLEANUP_DIRS+=("$_fm_test_tmproot_root")
  printf -v "$_fm_test_tmproot_output_var" '%s' "$_fm_test_tmproot_root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# fm_test_record_supervision_healthy <home> [state]: record identity-matched
# daemon and delivery-stub locks owned by the long-lived test shell. This is for
# fixtures whose subject merely passes through fm-guard.sh; tests of watcher
# health itself should construct each state explicitly.
# shellcheck disable=SC2031 # false positive: fm-wake-lib.sh's *sourced-in-a-
# subshell* locals of the same names (state/pid/home) never touch this scope.
fm_test_record_supervision_healthy() {
  local record_home=$1 record_state=${2:-$1/state} record_pid record_identity record_session_lock
  record_pid=$$
  # Compute identity through the shared fm_pid_identity (subshell-scoped so its
  # STATE/FM_HOME/FM_ROOT side effects from sourcing fm-wake-lib.sh never leak
  # into this test shell), the same predicate fm_watcher_lock_matches_pid and
  # fm_wake_stub_lock_matches_pid re-derive from the live pid, so a recorded
  # lock always compares equal to itself.
  record_identity=$(. "$ROOT/bin/fm-wake-lib.sh" >/dev/null 2>&1; fm_pid_identity "$record_pid") \
    || fail "could not read test-shell identity"
  [ -n "$record_identity" ] || fail "test-shell identity was empty"
  record_session_lock=$(cat "$record_state/.lock" 2>/dev/null || true)

  mkdir -p "$record_state/.watch.lock" "$record_state/.wake-stub.lock"
  printf '%s\n' "$record_pid" > "$record_state/.watch.lock/pid"
  printf '%s\n' "$record_home" > "$record_state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$record_state/.watch.lock/watcher-path"
  printf '%s\n' "$record_identity" > "$record_state/.watch.lock/pid-identity"
  printf '%s\n' "$record_pid" > "$record_state/.wake-stub.lock/pid"
  printf '%s\n' "$record_home" > "$record_state/.wake-stub.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-wake-wait.sh" > "$record_state/.wake-stub.lock/stub-path"
  printf '%s\n' "$record_session_lock" > "$record_state/.wake-stub.lock/session-lock-pid"
  printf '%s\n' "$record_identity" > "$record_state/.wake-stub.lock/pid-identity"
  touch "$record_state/.last-watcher-beat"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_gitignore_ignores <path> <msg>: the tracked .gitignore must ignore
# <path>. Assert the BEHAVIOR, never a literal line: the captain-private rules
# are deliberately directory- and prefix-wide (docs/configuration.md owns why),
# so grepping for one file name both fails on a correct wholesale rule and would
# pass on a rule that no longer ignores anything.
#
# The question is only ever "would a FRESH VESSEL be protected", so this probes
# the tracked .gitignore alone, in a throwaway repo. Asking the live checkout
# instead proves nothing: a working home may carry a private
# .git/info/exclude or a global core.excludesFile the fleet does not inherit,
# and when such a rule excludes a whole directory git never descends into it to
# consult .gitignore at all - so a checkout with `/config/` privately excluded
# answers "ignored" whether or not the shared rule still exists.
assert_gitignore_ignores() {
  local path=$1 msg=$2 match status=0
  fm_tracked_gitignore_probe
  match=$(fm_gitignore_match "$FM_TRACKED_GITIGNORE_PROBE" "$path") || status=$?
  case "$status" in
    0) ;;
    3) fail "$msg (the tracked .gitignore could not be tested at all: $match)" ;;
    *) fail "$msg (the tracked .gitignore alone does not ignore it, so a fresh vessel is unprotected)" ;;
  esac
}

# fm_gitignore_match <repo> <path>: print the `check-ignore -v` match for <path>
# in <repo>, with the developer's global ignore file disabled. Exit 0 when the
# tracked .gitignore is the source, 1 when nothing ignores <path>, 2 when some
# other source does, and 3 when git itself failed - a broken or unreadable repo
# is not the same answer as a missing ignore rule, and reporting it as one sends
# the reader after the wrong cause.
#
# Which source matched is the whole question: check-ignore succeeds just as
# happily for a clone-private .git/info/exclude or a global core.excludesFile,
# and those are exactly the rules a fresh vessel does not inherit. This is the
# single owner of that check, so every ignore assertion in the suite gets it.
fm_gitignore_match() {
  local repo=$1 path=$2 match status=0
  match=$(git -C "$repo" -c core.excludesFile=/dev/null \
    check-ignore -v --no-index -- "$path") || status=$?
  case "$status" in
    0) ;;
    1) return 1 ;;
    *)
      printf 'git check-ignore exited %s in %s\n' "$status" "$repo"
      return 3
      ;;
  esac
  printf '%s\n' "$match"
  case "$match" in
    .gitignore:*) return 0 ;;
    *) return 2 ;;
  esac
}

# fm_assert_ignored_by_tracked_gitignore <repo> <path> <subject>: <path> must be
# ignored in <repo> by the tracked .gitignore. <subject> opens the failure
# messages so each suite keeps its own wording.
fm_assert_ignored_by_tracked_gitignore() {
  local repo=$1 path=$2 subject=$3 match status=0
  match=$(fm_gitignore_match "$repo" "$path") || status=$?
  case "$status" in
    0) ;;
    1) fail "$subject has no shared ignore rule: $path" ;;
    2) fail "$subject is ignored by a private or global exclude, not the tracked .gitignore: $match" ;;
    *) fail "could not test the ignore rules for $subject $path: $match" ;;
  esac
}

# fm_ignore_probe_isolate <repo>: strip every ignore source from <repo> except
# its own working-tree .gitignore. Both `git init` and `git clone` apply the
# developer's init.templateDir, which may install a .git/info/exclude, and both
# inherit the global core.excludesFile - including the XDG ~/.config/git/ignore
# default, which applies even when no git config names it. A probe that keeps
# those answers the developer's question, not the fresh vessel's: a global rule
# for `config/` or `*.json` would report a captain-private path as ignored with
# the shared rule deleted outright.
#
# It only ever operates on a throwaway repository this test process created
# under fm_test_tmproot, and refuses anything else. The sibling assert in this
# family is routinely pointed at the live checkout, so the symmetric-looking
# call is one edit away - and here it would destroy a working home's private
# .git/info/exclude and rewrite the real repository's git config, silently.
fm_ignore_probe_isolate() {
  local repo=$1 gitdir here root_dir owned=0 dir
  here=$(cd "$repo" 2>/dev/null && pwd -P) \
    || fail "could not resolve the ignore probe directory $repo"
  root_dir=$(cd "$ROOT" && pwd -P) || fail "could not resolve $ROOT"
  if [ "$here" = "$root_dir" ]; then
    fail "refusing to isolate the live checkout at $ROOT: that would delete its private .git/info/exclude and rewrite its git config"
  fi
  for dir in "${FM_TEST_CLEANUP_DIRS[@]+"${FM_TEST_CLEANUP_DIRS[@]}"}"; do
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    case "$here" in
      "$dir"|"$dir"/*) owned=1; break ;;
    esac
  done
  if [ "$owned" -ne 1 ]; then
    fail "refusing to isolate $repo: it is not a throwaway probe this test process created (build it under fm_test_tmproot)"
  fi
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir) \
    || fail "could not locate the git directory of the ignore probe at $repo"
  mkdir -p "$gitdir/info" || fail "could not create $gitdir/info"
  : > "$gitdir/info/exclude" \
    || fail "could not clear the private exclude of the ignore probe at $repo"
  git -C "$repo" config core.excludesFile /dev/null \
    || fail "could not disable the global ignore file for the ignore probe at $repo"
}

# fm_tracked_gitignore_probe: build (once per test process) a throwaway repo
# carrying only the tracked .gitignore, and set FM_TRACKED_GITIGNORE_PROBE to it.
fm_tracked_gitignore_probe() {
  [ -z "${FM_TRACKED_GITIGNORE_PROBE:-}" ] || return 0
  local probe
  fm_test_tmproot probe fm-gitignore-probe
  cp "$ROOT/.gitignore" "$probe/.gitignore" \
    || fail "could not copy $ROOT/.gitignore: is it still the tracked ignore file?"
  git -C "$probe" init -q || fail "could not init the ignore probe repository at $probe"
  fm_ignore_probe_isolate "$probe"
  FM_TRACKED_GITIGNORE_PROBE=$probe
}

# fm_fresh_ignore_clone <seed> <clone> [tracked-path ...]: build a clone that
# carries the tracked .gitignore plus any named tracked paths from $ROOT
# (symlinks preserved) and no other ignore source, so an assertion made in it
# answers only "would a fresh vessel be protected".
fm_fresh_ignore_clone() {
  local seed=$1 clone=$2 path target
  shift 2
  mkdir -p "$seed" || fail "could not create the seed checkout at $seed"
  cp "$ROOT/.gitignore" "$seed/.gitignore" \
    || fail "could not seed .gitignore: is $ROOT/.gitignore still the tracked ignore file?"
  for path in "$@"; do
    mkdir -p "$(dirname "$seed/$path")" || fail "could not create the seed parent for $path"
    if [ -L "$ROOT/$path" ]; then
      target=$(readlink "$ROOT/$path") \
        || fail "could not read the tracked symlink $ROOT/$path"
      ln -s "$target" "$seed/$path" \
        || fail "could not seed the $path symlink pointing at $target"
    else
      cp "$ROOT/$path" "$seed/$path" \
        || fail "could not seed $path: has the tracked file moved or become a directory?"
    fi
  done
  fm_git_identity
  git -C "$seed" init -q || fail "could not init the seed repository at $seed"
  git -C "$seed" add --force .gitignore "$@" \
    || fail "could not stage the tracked fixture files in $seed"
  git -C "$seed" commit -qm baseline || fail "could not commit the seed baseline in $seed"
  git clone --quiet "$seed" "$clone" || fail "could not clone $seed into $clone"
  fm_ignore_probe_isolate "$clone"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# --- skill frontmatter --------------------------------------------------------

# fm_skill_frontmatter <skill-dir>: print the YAML frontmatter block only, from
# the opening `---` on line 1 to the next `---`, so a column-0 key anywhere in
# the SKILL.md body can never satisfy a frontmatter probe.
fm_skill_frontmatter() {
  awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    { print }
  ' "$1/SKILL.md"
}

# fm_skill_description <skill-dir>: print the frontmatter description as one
# line, flattening the folded-block forms, so an empty or absent description
# prints nothing.
fm_skill_description() {
  fm_skill_frontmatter "$1" | awk '
    /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      if ($0 != ">-" && $0 != ">" && $0 != "|" && $0 != "|-") printf "%s ", $0
      inblock = 1
      next
    }
    inblock && /^[[:space:]]+[^[:space:]]/ { sub(/^[[:space:]]+/, ""); printf "%s ", $0; next }
    inblock { exit }
  '
}

# --- runtime capability probes -----------------------------------------------

# fm_node_supports_ts_import: true if this `node` can import a .ts file
# directly (native type-stripping, Node 22.6+ behind a flag or 23.6+ by
# default). Pi extension tests exec plugins by importing the tracked .ts
# source at runtime; on an older Node that support is simply absent, so those
# tests skip rather than fail, the same as this suite's other missing-tool
# skips (herdr, cmux, zellij, tsc). Cached per process since the probe spawns
# node.
FM_NODE_TS_IMPORT_OK=
fm_node_supports_ts_import() {
  if [ -z "$FM_NODE_TS_IMPORT_OK" ]; then
    local probe
    probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-node-ts-probe.XXXXXX")
    printf 'export default 1;\n' > "$probe/probe.ts"
    if PROBE_TS="$probe/probe.ts" node --input-type=module -e \
      'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.env.PROBE_TS).href);' \
      >/dev/null 2>&1; then
      FM_NODE_TS_IMPORT_OK=1
    else
      FM_NODE_TS_IMPORT_OK=0
    fi
    rm -rf "$probe"
  fi
  [ "$FM_NODE_TS_IMPORT_OK" = 1 ]
}
