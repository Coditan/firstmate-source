#!/usr/bin/env bash
# Tests for the pooled-worktree ownership guard: bin/fm-slot-lib.sh,
# bin/fm-slot-guard.sh, and the refusal they give bin/fm-teardown.sh.
#
# THE FAILURE THESE REPRODUCE, measured 2026-08-17
#
# A pooled treehouse slot has two owners that disagree in one direction. The
# pool's owner is a PROCESS: `treehouse status` calls a slot in-use only while
# something is alive inside it, and frees it the moment that dies. firstmate's
# owner is a TASK: state/<id>.meta records worktree=<path> until teardown, which
# can be much later. So a task's window dies, the pool hands its slot to the next
# spawn, and the first task's meta still names it. Tearing the first task down
# then returns a slot the second task is standing in - and `treehouse return`
# terminates every process in the worktree and resets it.
#
# That is what happened: a merged task's teardown returned slot 4, which had been
# re-handed to a live mid-task worker. The worker's window died and its
# uncommitted work was destroyed. One commit survived only because it was already
# in the shared object store, which is timing, not a guarantee.
#
# Teardown was not missing a refusal - it refuses on unlanded work, and had done
# so for that same task minutes earlier. It was missing a QUESTION: every check
# it runs is scoped to the task it was told about, never to the RESOURCE it is
# about to touch. Case (a) is that exact sequence, and it must REFUSE.
#
# Matrix:
#   (a) stale record + a different LIVE task in the slot   -> REFUSE, naming it
#   (b) sole owner, nobody else in the slot                -> ALLOW (no regression)
#   (c) stale record + live holder + --force               -> REFUSE (force is not
#       authority over a third party's work)
#   (d) stale record + FM_TEARDOWN_SLOT_OVERRIDE=<holder>  -> ALLOW (deliberate)
#   (e) stale record + a DEAD other claimant               -> ALLOW (nobody to lose)
#   (f) a dispute marker the watcher left earlier          -> REFUSE without re-deriving
#   (g) lease witness: slot leased to another task         -> REFUSE, naming it
#   (h) a task's own lease is not a conflict               -> ALLOW
#   (i) fm-slot-guard --status                             -> reports the dispute
#   (j) fm-slot-guard detect                               -> writes marker + wakes once
#   (k) dispute resolves                                   -> marker cleared, wake once
#   (l) forced child cleanup reads the child home's state
#   (m) child refusal preserves its worktree and parent records
#   (n) late top-level refusal leaves hooks and branch untouched
#   (o) returned top-level slot is never mutated after release
#   (p) returned child slot is never mutated after release
#   (q) home-return refusal preserves registry and task state
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
GUARD="$ROOT/bin/fm-slot-guard.sh"
fm_test_tmproot TMP_ROOT fm-slot-guard-tests

# A case dir with: a project clone with an origin, a pooled "slot" worktree, a
# firstmate state dir, and mocks for treehouse and tmux.
#
# LIVE_WINDOWS (a file of window targets, one per line) is what the tmux mock
# treats as alive, so a test can make one task's window live and another's dead -
# which is the whole distinction the guard turns on.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  : > "$case_dir/live-windows"
  : > "$case_dir/leases"
  : > "$case_dir/lease-on-status"
  : > "$case_dir/reallocate-on-return"
  printf '0\n' > "$case_dir/status-count"
  : > "$case_dir/returned"

  # treehouse mock. `status` reports leases from $CASE/leases (one
  # "<path>\t<holder>" per line). `return` records the path it was asked to
  # return, and honours --if-lease-holder exactly as the real tool was measured
  # to: exit 1 and change nothing when the lease does not match, or is absent.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
LEASES="${FM_TEST_CASE_DIR:?}/leases"
RETURNED="${FM_TEST_CASE_DIR:?}/returned"
case "${1:-}" in
  status)
    count=$(cat "${FM_TEST_CASE_DIR:?}/status-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "${FM_TEST_CASE_DIR:?}/status-count"
    while IFS=$'\t' read -r at p h; do
      [ "$at" = "$count" ] || continue
      printf '%s\t%s\n' "$p" "$h" >> "$LEASES"
    done < "${FM_TEST_CASE_DIR:?}/lease-on-status"
    n=0
    while IFS=$'\t' read -r p h; do
      [ -n "$p" ] || continue
      n=$((n + 1))
      printf '%-5s %-12s %s  (held by %s)\n' "$n" leased "$p" "$h"
    done < "$LEASES"
    exit 0 ;;
  return)
    shift
    want= ; path=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        --if-lease-holder) want=${2:-}; shift ;;
        *) path=$1 ;;
      esac
      shift
    done
    if [ -n "$want" ]; then
      have=$(awk -F'\t' -v p="$path" '$1 == p {print $2}' "$LEASES" | head -1)
      if [ -z "$have" ]; then
        echo "failed to return worktree: lease precondition failed: worktree $path is not leased" >&2
        exit 1
      fi
      if [ "$have" != "$want" ]; then
        echo "failed to return worktree: lease precondition failed: lease holder does not match worktree $path" >&2
        exit 1
      fi
    fi
    printf '%s\n' "$path" >> "$RETURNED"
    if [ -s "${FM_TEST_CASE_DIR:?}/reallocate-on-return" ]; then
      branch=$(cat "${FM_TEST_CASE_DIR:?}/reallocate-on-return")
      git -C "$path" switch -q -c "$branch"
      mkdir -p "$path/.claude"
      printf '{"hooks":"reallocated-worker"}\n' > "$path/.claude/settings.fm-task.json"
    fi
    exit 0 ;;
esac
exit 0
SH

  # tmux mock: a window is alive only if listed in $CASE/live-windows.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
LIVE="${FM_TEST_CASE_DIR:?}/live-windows"
target=
prev=
for a in "$@"; do
  [ "$prev" = "-t" ] && target=$a
  prev=$a
done
case "${1:-}" in
  list-panes|display-message)
    [ -n "$target" ] || exit 1
    grep -qxF "$target" "$LIVE" || exit 1
    printf '%%0\n'
    exit 0 ;;
esac
exit 0
SH

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$fakebin/gh-axi" "$fakebin/gh"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # The pooled slot. Both tasks in these tests record THIS path.
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/slot" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Record a task: its meta (window + worktree + project) and whether it is alive.
write_task() {  # <case> <id> <alive|dead> [worktree]
  local case_dir=$1 id=$2 alive=$3 wt=${4:-$1/slot}
  cat > "$case_dir/state/$id.meta" <<EOF
window=fmtest:$id
worktree=$wt
project=$case_dir/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
backend=tmux
EOF
  [ "$alive" = alive ] && printf '%s\n' "fmtest:$id" >> "$case_dir/live-windows"
  return 0
}

lease_slot() {  # <case> <path> <holder>
  printf '%s\t%s\n' "$2" "$3" >> "$1/leases"
}

lease_slot_on_status() {  # <case> <status-count> <path> <holder>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1/lease-on-status"
}

reallocate_slot_on_return() {  # <case> <branch>
  printf '%s\n' "$2" > "$1/reallocate-on-return"
}

run_teardown() {  # <case> <id> [args...]
  local case_dir=$1 id=$2; shift 2
  FM_TEST_CASE_DIR="$case_dir" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

make_secondmate_case() {  # <case> <parent-id>
  local case_dir=$1 parent_id=$2 home="$1/secondmate-home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  mkdir -p "$case_dir/tasktmp"
  printf '%s\n' "$parent_id" > "$home/.fm-secondmate-home"
  cat > "$case_dir/state/$parent_id.meta" <<EOF
window=fmtest:$parent_id
worktree=$home
home=$home
project=$case_dir/project
harness=claude
kind=secondmate
mode=no-mistakes
yolo=off
backend=tmux
tasktmp=$case_dir/tasktmp
EOF
  printf 'running\n' > "$case_dir/state/$parent_id.status"
  printf '%s\n' "- $parent_id home=$home" > "$case_dir/data/secondmates.md"
  printf '%s\n' "$home"
}

register_mock_home_worktree() {  # <case> <home>
  printf '%s\n' "$2" > "$1/home-worktree"
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${*: -3}" = "worktree list --porcelain" ]; then
  /usr/bin/git "$@"
  printf 'worktree %s\n\n' "$(cat "${FM_TEST_CASE_DIR:?}/home-worktree")"
  exit 0
fi
exec /usr/bin/git "$@"
SH
  chmod +x "$1/fakebin/git"
}

write_child_task() {  # <case> <home> <id> <alive|dead>
  local case_dir=$1 home=$2 id=$3 alive=$4
  cat > "$home/state/$id.meta" <<EOF
window=fmtest:$id
worktree=$case_dir/slot
project=$case_dir/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
backend=tmux
EOF
  [ "$alive" = alive ] && printf '%s\n' "fmtest:$id" >> "$case_dir/live-windows"
  return 0
}

# The mock appends every path it actually returned; empty means nothing was.
assert_nothing_returned() {  # <case> <msg>
  [ -s "$1/returned" ] && fail "$2 (returned: $(cat "$1/returned"))"
  return 0
}

run_guard() {  # <case> [args...]
  local case_dir=$1; shift
  FM_TEST_CASE_DIR="$case_dir" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$GUARD" "$@"
}

# --- (a) THE REPRODUCTION --------------------------------------------------
test_stale_record_live_holder_refuses() {
  local case_dir rc branch
  case_dir=$(make_case repro)
  # finished-task: window already dead, meta still names the slot.
  write_task "$case_dir" finished-task dead
  # live-task: was handed the same slot and is working in it right now.
  write_task "$case_dir" live-task alive
  git -C "$case_dir/slot" switch -q -c live-holder-work
  mkdir -p "$case_dir/slot/.claude"
  printf '{"hooks":"live-holder"}\n' > "$case_dir/slot/.claude/settings.fm-task.json"

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "repro: teardown returned a slot a live task was standing in"
  assert_grep "REFUSED" "$case_dir/stderr" "repro: teardown should refuse"
  assert_grep "live-task" "$case_dir/stderr" "repro: the refusal must NAME the holder"
  assert_nothing_returned "$case_dir" "repro: nothing should have been returned"
  assert_present "$case_dir/slot/.claude/settings.fm-task.json" \
    "repro: refusal must not remove the live holder's hook"
  branch=$(git -C "$case_dir/slot" branch --show-current)
  [ "$branch" = live-holder-work ] || fail "repro: refusal changed the live holder's branch"
  pass "(a) a slot held by a different live task is refused, naming the holder"
}

# --- (b) no regression: the ordinary teardown still works -------------------
test_sole_owner_allows() {
  local case_dir rc
  case_dir=$(make_case sole)
  write_task "$case_dir" finished-task dead

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "sole: teardown of an uncontested slot should succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" "sole: no refusal expected"
  assert_grep "$case_dir/slot" "$case_dir/returned" "sole: the slot should have been returned"
  pass "(b) an uncontested slot is still returned normally"
}

# --- (c) --force is not authority over someone else's work ------------------
test_force_does_not_override() {
  local case_dir rc
  case_dir=$(make_case forced)
  write_task "$case_dir" finished-task dead
  write_task "$case_dir" live-task alive

  set +e
  run_teardown "$case_dir" finished-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "forced: --force destroyed a third party's worktree"
  assert_grep "REFUSED" "$case_dir/stderr" "forced: refusal must hold under --force"
  assert_nothing_returned "$case_dir" "forced: nothing should have been returned"
  pass "(c) --force does not authorise displacing a live third party"
}

# --- (d) the deliberate escape hatch names who is displaced -----------------
test_named_override_allows() {
  local case_dir rc
  case_dir=$(make_case override)
  write_task "$case_dir" finished-task dead
  write_task "$case_dir" live-task alive

  set +e
  FM_TEARDOWN_SLOT_OVERRIDE=live-task \
    run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "override: naming the holder should permit the return"
  assert_grep "displacing live-task" "$case_dir/stderr" "override: displacement must be stated"
  pass "(d) an override naming the holder displaces it deliberately"
}

# --- (e) a dead co-claimant is not a holder --------------------------------
test_dead_claimant_allows() {
  local case_dir rc
  case_dir=$(make_case deadclaim)
  write_task "$case_dir" finished-task dead
  write_task "$case_dir" other-dead-task dead

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "deadclaim: a dead co-claimant should not block teardown"
  assert_no_grep "REFUSED" "$case_dir/stderr" "deadclaim: no refusal expected"
  pass "(e) a co-claimant whose window is dead does not block cleanup"
}

# --- (f) the watcher's durable marker refuses on its own --------------------
test_dispute_marker_refuses() {
  local case_dir rc
  case_dir=$(make_case marker)
  write_task "$case_dir" finished-task dead
  printf 'holder=someone-else\nrecorded=%s/slot\n' "$case_dir" \
    > "$case_dir/state/finished-task.slot-disputed"

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "marker: a recorded dispute did not stop the return"
  assert_grep "someone-else" "$case_dir/stderr" "marker: the refusal must name the recorded holder"
  assert_nothing_returned "$case_dir" "marker: nothing should have been returned"
  pass "(f) a dispute the watcher recorded earlier refuses on its own"
}

# --- (g) the lease witness sees a holder with no meta here ------------------
test_lease_holder_refuses() {
  local case_dir rc
  case_dir=$(make_case lease)
  write_task "$case_dir" finished-task dead
  lease_slot "$case_dir" "$case_dir/slot" "fm:someone-elses-task"

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "lease: a slot leased to another task was returned"
  assert_grep "someone-elses-task" "$case_dir/stderr" "lease: the refusal must name the lease holder"
  pass "(g) a slot leased to another task is refused, naming the lease holder"
}

# --- (h) a task's own lease is not a conflict ------------------------------
test_own_lease_allows() {
  local case_dir rc
  case_dir=$(make_case ownlease)
  write_task "$case_dir" finished-task dead
  lease_slot "$case_dir" "$case_dir/slot" "fm:finished-task"

  set +e
  run_teardown "$case_dir" finished-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ownlease: a task's own lease must not block its own teardown"
  assert_grep "$case_dir/slot" "$case_dir/returned" "ownlease: the slot should have been returned"
  pass "(h) a task's own lease permits its own cleanup"
}

# --- (i) the watcher's human reading ---------------------------------------
test_guard_status_reports() {
  local case_dir rc out
  case_dir=$(make_case status)
  write_task "$case_dir" finished-task dead
  write_task "$case_dir" live-task alive

  set +e
  out=$(run_guard "$case_dir" --status 2>&1)
  rc=$?
  set -e

  expect_code 2 "$rc" "status: a dispute should report a non-clear status"
  assert_contains "$out" "DISPUTED" "status: should name the condition"
  assert_contains "$out" "live-task" "status: should name the holder"
  pass "(i) the guard's status reading names the disputed slot and its holder"
}

# --- (j) and (k) the watcher tick: mark, wake once, then clear --------------
test_guard_detect_marks_and_clears() {
  local case_dir first second
  case_dir=$(make_case detect)
  write_task "$case_dir" finished-task dead
  write_task "$case_dir" live-task alive

  first=$(run_guard "$case_dir" 2>&1)
  assert_contains "$first" "SLOT_GUARD:" "detect: the first sweep should wake firstmate"
  assert_contains "$first" "live-task" "detect: the wake should name the holder"
  assert_present "$case_dir/state/finished-task.slot-disputed" \
    "detect: a durable dispute marker should exist"

  second=$(run_guard "$case_dir" 2>&1)
  [ -z "$second" ] || fail "detect: an unchanged dispute should not wake again (got: $second)"
  pass "(j) the watcher marks the dispute and wakes once, not every tick"

  # The holder finishes: its window goes away, so the dispute is over.
  : > "$case_dir/live-windows"
  local cleared
  cleared=$(run_guard "$case_dir" 2>&1)
  assert_contains "$cleared" "resolved" "clear: the watcher should report the dispute over"
  assert_absent "$case_dir/state/finished-task.slot-disputed" \
    "clear: the marker should be removed once the holder is gone"
  pass "(k) the watcher clears the marker and reports once when the dispute ends"
}

test_child_home_state_refuses() {
  local case_dir home rc
  case_dir=$(make_case child-state)
  home=$(make_secondmate_case "$case_dir" parent-task)
  write_child_task "$case_dir" "$home" finished-child dead
  write_child_task "$case_dir" "$home" live-child alive

  set +e
  run_teardown "$case_dir" parent-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "child-state: forced cleanup ignored the child home's live holder"
  assert_grep "live-child" "$case_dir/stderr" "child-state: refusal must name the child holder"
  assert_nothing_returned "$case_dir" "child-state: child slot must not be returned"
  assert_present "$case_dir/slot" "child-state: child slot must remain present"
  pass "(l) forced child cleanup checks ownership in the child home's state"
}

test_child_refusal_does_not_delete() {
  local case_dir home rc branch
  case_dir=$(make_case child-refusal)
  home=$(make_secondmate_case "$case_dir" parent-task)
  write_child_task "$case_dir" "$home" finished-child dead
  git -C "$case_dir/slot" switch -q -c live-child-work
  mkdir -p "$case_dir/slot/.claude"
  printf '{"hooks":"live-child"}\n' > "$case_dir/slot/.claude/settings.fm-task.json"
  lease_slot_on_status "$case_dir" 2 "$case_dir/slot" "fm:live-child"

  set +e
  run_teardown "$case_dir" parent-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "child-refusal: ownership refusal did not abort forced cleanup"
  assert_grep "live-child" "$case_dir/stderr" "child-refusal: refusal must name the lease holder"
  assert_nothing_returned "$case_dir" "child-refusal: child slot must not be returned"
  assert_present "$case_dir/slot" "child-refusal: refused child slot must not be deleted"
  assert_present "$case_dir/slot/.claude/settings.fm-task.json" \
    "child-refusal: late refusal must preserve the holder's hook"
  branch=$(git -C "$case_dir/slot" branch --show-current)
  [ "$branch" = live-child-work ] || fail "child-refusal: late refusal changed the holder's branch"
  assert_present "$home/state/finished-child.meta" \
    "child-refusal: refused cleanup must preserve the child record"
  assert_present "$home" "child-refusal: refused cleanup must preserve the parent home"
  assert_present "$case_dir/state/parent-task.meta" \
    "child-refusal: refused cleanup must preserve the parent meta"
  assert_present "$case_dir/state/parent-task.status" \
    "child-refusal: refused cleanup must preserve the parent status"
  assert_grep "- parent-task " "$case_dir/data/secondmates.md" \
    "child-refusal: refused cleanup must preserve the registry entry"
  assert_present "$case_dir/tasktmp" "child-refusal: refused cleanup must preserve task temp"
  pass "(m) child refusal preserves its worktree and parent records"
}

test_late_top_level_refusal_is_mutation_free() {
  local case_dir rc branch
  case_dir=$(make_case late-top-level)
  write_task "$case_dir" finished-task dead
  git -C "$case_dir/slot" switch -q -c live-top-level-work
  mkdir -p "$case_dir/slot/.claude"
  printf '{"hooks":"live-top-level"}\n' > "$case_dir/slot/.claude/settings.fm-task.json"
  lease_slot_on_status "$case_dir" 2 "$case_dir/slot" "fm:live-task"

  set +e
  run_teardown "$case_dir" finished-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "late-top-level: late ownership conflict did not refuse"
  assert_grep "live-task" "$case_dir/stderr" "late-top-level: refusal must name the late holder"
  assert_nothing_returned "$case_dir" "late-top-level: slot must not be returned"
  assert_present "$case_dir/slot/.claude/settings.fm-task.json" \
    "late-top-level: refusal must preserve the holder's hook"
  branch=$(git -C "$case_dir/slot" branch --show-current)
  [ "$branch" = live-top-level-work ] || fail "late-top-level: refusal changed the holder's branch"
  pass "(n) late top-level refusal leaves hooks and branch untouched"
}

test_returned_top_level_slot_is_not_mutated() {
  local case_dir rc branch
  case_dir=$(make_case returned-top-level)
  write_task "$case_dir" finished-task dead
  git -C "$case_dir/slot" switch -q -c finished-task-work
  reallocate_slot_on_return "$case_dir" reallocated-top-level-work

  set +e
  run_teardown "$case_dir" finished-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "returned-top-level: uncontested teardown should succeed"
  assert_present "$case_dir/slot/.claude/settings.fm-task.json" \
    "returned-top-level: teardown must not delete the new occupant's hook"
  branch=$(git -C "$case_dir/slot" branch --show-current)
  [ "$branch" = reallocated-top-level-work ] || fail "returned-top-level: teardown changed the new occupant's branch"
  pass "(o) returned top-level slot is not mutated after reallocation"
}

test_returned_child_slot_is_not_mutated() {
  local case_dir home rc branch
  case_dir=$(make_case returned-child)
  home=$(make_secondmate_case "$case_dir" parent-task)
  write_child_task "$case_dir" "$home" finished-child dead
  reallocate_slot_on_return "$case_dir" reallocated-child-work

  set +e
  run_teardown "$case_dir" parent-task --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "returned-child: uncontested forced cleanup should succeed"
  assert_present "$case_dir/slot/.claude/settings.fm-task.json" \
    "returned-child: teardown must not delete the new occupant's hook"
  branch=$(git -C "$case_dir/slot" branch --show-current)
  [ "$branch" = reallocated-child-work ] || fail "returned-child: teardown changed the new occupant's branch"
  pass "(p) returned child slot is not mutated after reallocation"
}

test_secondmate_home_refusal_preserves_records() {
  local case_dir home rc
  case_dir=$(make_case refused-home)
  home=$(make_secondmate_case "$case_dir" parent-task)
  register_mock_home_worktree "$case_dir" "$home"
  printf 'holder=live-home-holder\nrecorded=%s\n' "$home" \
    > "$case_dir/state/parent-task.slot-disputed"

  set +e
  run_teardown "$case_dir" parent-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "refused-home: home ownership refusal reported success"
  assert_grep "live-home-holder" "$case_dir/stderr" "refused-home: refusal must name the holder"
  assert_present "$home" "refused-home: refusal must preserve the secondmate home"
  assert_present "$case_dir/state/parent-task.meta" "refused-home: refusal must preserve task meta"
  assert_present "$case_dir/state/parent-task.status" "refused-home: refusal must preserve task status"
  assert_present "$case_dir/state/parent-task.slot-disputed" \
    "refused-home: refusal must preserve the dispute marker"
  assert_grep "- parent-task " "$case_dir/data/secondmates.md" \
    "refused-home: refusal must preserve the registry entry"
  assert_present "$case_dir/tasktmp" "refused-home: refusal must preserve task temp"
  assert_no_grep "teardown parent-task complete" "$case_dir/stdout" \
    "refused-home: refusal must not print success"
  pass "(q) secondmate home refusal preserves registry and task state"
}

test_stale_record_live_holder_refuses
test_sole_owner_allows
test_force_does_not_override
test_named_override_allows
test_dead_claimant_allows
test_dispute_marker_refuses
test_lease_holder_refuses
test_own_lease_allows
test_guard_status_reports
test_guard_detect_marks_and_clears
test_child_home_state_refuses
test_child_refusal_does_not_delete
test_late_top_level_refusal_is_mutation_free
test_returned_top_level_slot_is_not_mutated
test_returned_child_slot_is_not_mutated
test_secondmate_home_refusal_preserves_records

printf '\nall fm-slot-guard tests passed\n'
