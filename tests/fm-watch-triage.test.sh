#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
MARK_PARKED="$ROOT/bin/fm-mark-parked.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

fm_test_tmproot TMP_ROOT fm-watch-triage-tests

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_line_count() {  # <file> <minimum> [0.1s ticks]
  local file=$1 minimum=$2 limit=${3:-40} i=0 count
  while [ "$i" -lt "$limit" ]; do
    count=$(grep -c . "$file" 2>/dev/null || true)
    [ "$count" -ge "$minimum" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_file_value() {  # <file> <expected> [0.1s ticks]
  local file=$1 expected=$2 limit=${3:-40} i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(cat "$file" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set a file's mtime to an absolute epoch, so a test can age a marker past a
# cadence without sleeping through it.
backdate() {  # <epoch> <file>...
  local epoch=$1
  shift
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$epoch" '+%Y%m%d%H%M.%S')" "$@"
  else touch -m -d "@$epoch" "$@"; fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing ordinary status file.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: captain decision)'
  [ "$(crew_absorb_class a)" = parked ] || fail "an authoritative run-step decision gate not classed parked"
  ! crew_is_provably_working a || fail "a parked run was treated as provably working"
  ! crew_is_paused a || fail "a parked run was conflated with a declared external-wait pause"
  ! crew_is_degraded a || fail "a parked run was conflated with an unread crew state"
  # A gate known only from the append-only status log is an arbitrarily old EVENT
  # that reads the same whether the crew is at the gate or died an hour ago, so it
  # earns no absorb class of its own.
  FM_FAKE_CREW_STATE='state: parked · source: status-log · needs-decision: pick A or B'
  [ "$(crew_absorb_class a)" = none ] || fail "a status-log-sourced gate was classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/parked/none from one read, and the predicates keep their own meanings"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# --- one event, one wake ------------------------------------------------------
# A crewmate turn normally touches BOTH state/<id>.status and its turn-end
# marker, and every record built from one poll carries the identical payload, so
# enqueuing per changed file cost firstmate two full drain-and-re-arm cycles for
# a single turn. The enqueue is collapsed per task; the per-file marker
# advancement is NOT, or the collapsed-away file re-fires the wake forever.

test_single_turn_two_files_enqueue_one_wake() {
  local dir state fakebin out drain_out pid records
  dir=$(make_case single-turn-two-files); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # One turn: the crew's own status line, plus the same turn's turn-end hook.
  printf 'working: setup\ndone: branch ready for review\n' > "$state/task.status"
  : > "$state/task.turn-ended"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a captain-relevant signal: $(cat "$out")"
  records=$(grep -c "$(printf '\tsignal\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "$records" = 1 ] || fail "one crewmate turn enqueued $records signal records (expected 1): $(cat "$state/.wake-queue")"
  grep "$(printf '\tsignal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the surviving record is not keyed on the more informative status file: $(cat "$state/.wake-queue")"
  # Both markers must still advance, or this same turn re-fires next poll.
  [ -s "$state/.seen-task_status" ] || fail "the status file's .seen-* suppressor did not advance"
  [ -s "$state/.seen-task_turn-ended" ] || fail "the turn-end marker's .seen-* suppressor did not advance"
  [ -s "$state/.hb-surfaced-task" ] || fail "the captain-relevant status was not marked surfaced"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the collapsed signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.status" >/dev/null \
    || fail "the collapsed signal did not reach the drain with its full reason"
  reap "$pid"
  pass "a two-file single crewmate turn enqueues exactly one wake while both markers advance"
}

# Away mode collapses signal records per task too, deliberately: away mode still
# enqueues every actionable wake, but a duplicate record kept only for the
# `historical` annotation is exactly the noise away mode tolerates least, and the
# surviving .status key is a strict superset of the dropped .turn-ended key's
# information (fm_wake_status_key_map resolves both to the same status file, and
# fm_wake_annotation_manifest already lets `direct` win over `historical`).
test_afk_single_turn_two_files_enqueue_one_wake() {
  local dir state fakebin out drain_out pid records
  dir=$(make_case afk-single-turn-two-files); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A benign no-verb turn: only afk_present makes it actionable, so surfacing
  # here also proves the collapse runs on the away-mode branch.
  printf 'working: routine note\n' > "$state/task.status"
  : > "$state/task.turn-ended"
  date '+%s' > "$state/.afk"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not surface the benign turn: $(cat "$out")"
  records=$(grep -c "$(printf '\tsignal\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "$records" = 1 ] || fail "one crewmate turn enqueued $records signal records in away mode (expected 1): $(cat "$state/.wake-queue")"
  grep "$(printf '\tsignal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the surviving away-mode record is not keyed on the status file: $(cat "$state/.wake-queue")"
  # Both markers must still advance, or this same turn re-fires next poll.
  [ -s "$state/.seen-task_status" ] || fail "the status file's .seen-* suppressor did not advance in away mode"
  [ -s "$state/.seen-task_turn-ended" ] || fail "the turn-end marker's .seen-* suppressor did not advance in away mode"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the collapsed away-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.status" >/dev/null \
    || fail "the collapsed away-mode signal did not reach the drain with its full reason"
  unset FM_FAKE_CREW_STATE
  reap "$pid"
  pass "away mode collapses a two-file crewmate turn to one wake while both markers advance"
}

test_two_crewmates_signal_once_each() {
  local dir state fakebin out pid records
  dir=$(make_case two-crewmates-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Two DIFFERENT crewmates finishing a turn in the same poll: collapsing is per
  # task, so each still gets its own wake.
  printf 'done: first crew ready\n' > "$state/alpha.status"
  : > "$state/alpha.turn-ended"
  printf 'done: second crew ready\n' > "$state/beta.status"
  : > "$state/beta.turn-ended"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface two crewmates' captain-relevant signals: $(cat "$out")"
  records=$(grep -c "$(printf '\tsignal\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "$records" = 2 ] || fail "two crewmates enqueued $records signal records (expected 2): $(cat "$state/.wake-queue")"
  grep "$(printf '\tsignal\talpha.status\t')" "$state/.wake-queue" >/dev/null || fail "first crew's wake is missing or miskeyed"
  grep "$(printf '\tsignal\tbeta.status\t')" "$state/.wake-queue" >/dev/null || fail "second crew's wake is missing or miskeyed"
  reap "$pid"
  pass "two crewmates signalling in one poll still produce one wake each (dedup never crosses tasks)"
}

test_lone_turn_end_keeps_its_own_key() {
  local dir state fakebin out pid
  dir=$(make_case lone-turn-end); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # No status write this turn: the turn-end marker is the only key available.
  : > "$state/solo.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a lone turn-end whose crew is not provably working"
  grep "$(printf '\tsignal\tsolo.turn-ended\t')" "$state/.wake-queue" >/dev/null \
    || fail "a lone turn-end did not keep its own key: $(cat "$state/.wake-queue")"
  unset FM_FAKE_CREW_STATE
  reap "$pid"
  pass "a turn-end marker moving alone still keys its own wake"
}

test_signal_symlink_target_append_surfaces() {
  local dir state fakebin out pid signal_dir status_file
  dir=$(make_case signal-symlink-target); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  signal_dir="$state/.crew-signal/task"
  status_file="$state/task.status"
  mkdir -p "$signal_dir"
  : > "$signal_dir/status"
  ln -s ".crew-signal/task/status" "$status_file"
  # This is the signature the old watcher would have remembered: the symlink
  # object, not the target file.
  printf '%s' "$(seen_sig "$status_file")" > "$state/.seen-task_status"
  printf 'done: symlink status reached watcher\n' >> "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a status append through a public symlink"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "watcher did not print the public symlink status path: $(cat "$out")"
  grep "$(printf '\tsignal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "symlink status append did not enqueue the public status key: $(cat "$state/.wake-queue")"
  reap "$pid"
  pass "a status append through the public symlink wakes on the target file change"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- relayed terminal task parked on external human action ------------------
# Once firstmate has relayed a terminal result, an explicit .parked-<window-key>
# marker absorbs pane redraws on the same bounded cadence as a declared pause.
# The merge check remains independent, status writes remain immediate signals,
# and metadata changes invalidate the marker before stale classification.
test_terminal_stale_parked_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back
  dir=$(make_case terminal-stale-parked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked"
  printf 'window=%s\nkind=ship\npr=https://example.test/pr/4\n' "$window" > "$state/parked.meta"
  printf 'done: PR https://example.test/pr/4 checks green\n' > "$state/parked.status"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "finished, pane token 1")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.parked-$key"
  printf 'finished, pane token 2' > "$capture_file"
  pane_hash=$(hash_text "finished, pane token 2")

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for fresh parked pane churn: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "fresh parked stale printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "fresh parked stale enqueued a wake"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "parked pane churn did not advance the stale suppressor"; }
  [ -e "$state/.parkedmeta-$key" ] || { reap "$pid"; fail "parked marker was not bound to task metadata"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "parked stale started a wedge timer"; }
  reap "$pid"

  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.parked-$key"
  else touch -m -d "@$back" "$state/.parked-$key"; fi
  printf 'finished, pane token 3' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a parked task past the bounded cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "parked recheck omitted its stale identity"
  grep -F "awaiting external human action" "$out" >/dev/null || fail "parked recheck omitted its external-human reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "parked recheck was mislabeled a wedge"
  [ -e "$state/.parkedresurfaced-$key" ] || fail "parked re-surface throttle was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after parked re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "parked re-surface was not queued"
  pass "a relayed terminal task absorbs parked pane churn and re-surfaces on the bounded cadence"
}

# --- parked rechecks that fall due together reach the seat as ONE wake -------
# Fourteen tasks parked within minutes of each other put fourteen separate stale
# records on the queue once an hour (measured 2026-09-01, queue seq 8678-8691),
# because the window loop surfaces at most one wake per pass and then restarts:
# one record per pass, one pass per poll, each submitted into the seat as its own
# message. The recheck must still happen for every parked task on its bounded
# cadence - it is the only thing standing between a forgotten wait and invisible
# rot - so the fix is to carry them all on ONE record, not to drop any.
test_parked_rechecks_coalesce_into_one_wake() {
  local dir state fakebin out capture_file window_list pane_hash back i key rows payload pid
  local -a wins keys
  dir=$(make_case parked-coalesce); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  printf 'finished, awaiting review' > "$capture_file"
  pane_hash=$(hash_text "finished, awaiting review")
  back=$(( $(date +%s) - 500 ))
  wins=(); keys=(); window_list=''
  for i in 1 2 3; do
    wins+=("test:fm-pk$i")
    key=$(printf '%s' "test:fm-pk$i" | tr ':/.' '___')
    keys+=("$key")
    window_list="$window_list${window_list:+$'\n'}test:fm-pk$i"
    printf 'window=test:fm-pk%s\nkind=ship\n' "$i" > "$state/pk$i.meta"
    printf 'done: PR https://example.test/pr/%s checks green\n' "$i" > "$state/pk$i.status"
    printf '%s' "$(seen_sig "$state/pk$i.status")" > "$state/.seen-pk${i}_status"
    printf '%s' "$pane_hash" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
    : > "$state/.parked-$key"
    # The marker must not be older than the metadata it declares, or
    # reconcile_parked_markers reads the metadata as newer and revokes the
    # declaration before the cadence is ever consulted.
    backdate "$(( back - 60 ))" "$state/pk$i.meta"
    backdate "$back" "$state/.parked-$key"
  done

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window_list" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_DAEMON=1 "$WATCH" > "$out" 2>&1 &
  pid=$!
  # Every due recheck is accounted for once its throttle marker is down; only
  # then is the record count meaningful.
  for key in "${keys[@]}"; do
    wait_numeric_file "$state/.parkedresurfaced-$key" 60 \
      || { reap "$pid"; fail "a parked task's due recheck never happened: $key"$'\n'"--- watcher ---"$'\n'"$(cat "$out")"; }
  done
  reap "$pid"

  rows=$(grep -c "$(printf '\tstale\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "$rows" = 1 ] \
    || fail "three parked rechecks falling due together produced $rows stale records, not one"$'\n'"--- queue ---"$'\n'"$(cat "$state/.wake-queue")"
  payload=$(cat "$state/.wake-queue")
  for i in 1 2 3; do
    assert_contains "$payload" "test:fm-pk$i" "the coalesced parked recheck did not name every task it carries"
  done
  assert_contains "$payload" "awaiting external human action" "the coalesced parked recheck lost its external-human reason"
  assert_not_contains "$payload" "possible wedge" "the coalesced parked recheck was mislabeled a wedge"
  # What the seat actually receives is the drain, not the queue file: one record
  # is only one turn if it survives the drain as one record.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2>/dev/null \
    || fail "drain after the coalesced parked recheck failed"
  rows=$(grep -c "$(printf '\tstale\t')" "$dir/drain.out" 2>/dev/null || true)
  [ "$rows" = 1 ] \
    || fail "the coalesced parked recheck reached the seat as $rows records, not one"$'\n'"--- drain ---"$'\n'"$(cat "$dir/drain.out")"
  pass "parked rechecks falling due together reach the seat as one wake naming all of them"
}

# The cadence default is a prompt-cache decision, not a round number: the seat's
# prompt cache holds for one hour, so a recheck at exactly 3600s reliably arrives
# after the cache it would otherwise have reused has expired. Pinned here because
# the value is what makes that hold; docs/configuration.md and the definition's
# own comment carry the reason.
test_pause_resurface_default_stays_under_the_prompt_cache_hour() {
  [ "$FM_PAUSE_RESURFACE_SECS_DEFAULT" = 3000 ] \
    || fail "FM_PAUSE_RESURFACE_SECS_DEFAULT is $FM_PAUSE_RESURFACE_SECS_DEFAULT, not the 3000s that keeps a recheck inside the seat's one-hour prompt cache"
  [ "$FM_PAUSE_RESURFACE_SECS_DEFAULT" -lt 3600 ] \
    || fail "the bounded recheck cadence reached the one-hour prompt-cache window"
  pass "the bounded recheck cadence defaults inside the seat's one-hour prompt cache"
}

test_parked_marker_clears_on_status_write() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case parked-status-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-parked-status"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked-status.meta"
  printf 'done: ready for review\n' > "$state/parked-status.status"
  sig=$(seen_sig "$state/parked-status.status"); printf '%s' "$sig" > "$state/.seen-parked-status_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.parked-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 || fail "watcher exited while establishing parked status fixture"
  reap "$pid"

  printf 'blocked: review environment lost its credential\n' >> "$state/parked-status.status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "new status write did not wake a parked task immediately"
  grep -F "signal: $state/parked-status.status" "$out" >/dev/null || fail "parked task's new status was not surfaced as a signal"
  [ ! -e "$state/.parked-$key" ] || fail "new status write retained the parked marker"
  [ ! -e "$state/.stale-$key" ] || fail "new status write retained parked stale suppression"
  pass "a real status write wakes immediately and clears parked tracking"
}

test_parked_marker_clears_on_meta_change() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case parked-meta-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-parked-meta"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked-meta.meta"
  printf 'done: ready for review\n' > "$state/parked-meta.status"
  sig=$(seen_sig "$state/parked-meta.status"); printf '%s' "$sig" > "$state/.seen-parked-meta_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.parked-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 || fail "watcher exited while establishing parked metadata fixture"
  [ -e "$state/.parkedmeta-$key" ] || { reap "$pid"; fail "parked metadata fixture did not register"; }
  reap "$pid"

  printf 'pr=https://example.test/pr/9\n' >> "$state/parked-meta.meta"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "metadata change did not release parked stale suppression"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "metadata change did not reclassify and surface terminal stale"
  [ ! -e "$state/.parked-$key" ] || fail "metadata change retained the parked marker"
  [ ! -e "$state/.parkedmeta-$key" ] || fail "metadata change retained parked metadata tracking"
  pass "a metadata change clears parked tracking before stale classification"
}

# --- mark-parked wrapper: firstmate's operator-facing entry point -------------
# The watcher itself is normally a blocking singleton daemon; the wrapper must
# take effect as a one-shot command without touching that lock/loop so firstmate
# can declare a parked marker mid-supervision.
test_mark_parked_wrapper() {
  local dir state window key
  dir=$(make_case mark-parked-cli); state="$dir/state"
  window="test:fm-mark-parked"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\n' "$window" > "$state/mp.meta"

  FM_STATE_OVERRIDE="$state" "$MARK_PARKED" "$window" \
    || fail "mark-parked wrapper refused a window matching a recorded task"
  [ -e "$state/.parked-$key" ] || fail "mark-parked wrapper did not create the expected marker"
  [ ! -e "$state/.watch.lock" ] || fail "mark-parked wrapper acquired the watcher singleton lock"

  if FM_STATE_OVERRIDE="$state" "$MARK_PARKED" "test:fm-unknown" 2>/dev/null; then
    fail "mark-parked wrapper accepted a window naming no recorded task"
  fi
  [ ! -e "$state/.parked-test_fm-unknown" ] || fail "mark-parked wrapper left a marker for an unrecognized window"
  pass "mark-parked wrapper: creates the marker for a recorded window, refuses an unrecognized one, never engages the watcher lock"
}

test_mark_parked_wrapper_rejects_secondmate() {
  local dir state window key
  dir=$(make_case mark-parked-cli-secondmate); state="$dir/state"
  window="test:fm-mark-parked-sm"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/mp-sm.meta"

  if FM_STATE_OVERRIDE="$state" "$MARK_PARKED" "$window" 2>/dev/null; then
    fail "mark-parked wrapper accepted a kind=secondmate window"
  fi
  [ ! -e "$state/.parked-$key" ] || fail "mark-parked wrapper left a marker for a secondmate window"
  pass "mark-parked wrapper: refuses a kind=secondmate window, leaving the pause-tracking path untouched"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: past the threshold with the run STILL active - the escalation
  # re-reads the crew state, so a long pipeline step on a quiet pane holds the
  # ladder instead of alarming against a healthy run.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run climbed the wedge ladder on the overridden-terminal path: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "an active run enqueued a wedge escalation on the overridden-terminal path"
  reap "$pid"

  # Phase C: the run stops. The same overridden terminal status now escalates on
  # the unchanged schedule - a genuinely wedged validation is never swallowed.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate an overridden stale terminal status once its run stopped"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is absorbed while its run works, holds the ladder, and escalates once the run stops"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: past the threshold, but the run is STILL active - the escalation
  # re-reads the crew state, so the ladder is held instead of climbing against a
  # long-running pipeline step on a legitimately quiet pane.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run climbed the wedge ladder instead of holding it: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "an active run enqueued a wedge escalation: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "an active run incremented the wedge-escalation ladder"
  reap "$pid"

  # Phase C: the run has stopped. The same idle pane now escalates on the
  # unchanged schedule - the safety property this alarm exists for.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a stale pane whose run had stopped did not escalate past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  unset FM_FAKE_CREW_STATE
  pass "provably-working non-terminal stale is absorbed, holds the ladder while its run is active, and escalates once the run stops"
}

# --- codex static-pane liveness backstop (0.145.0 false-idle) ----------------
# codex 0.145.0 drops its "esc to interrupt" busy row while an answer streams and
# mid tool-call, so a healthy codex worker on a STATIC pane renders no busy text
# and crew_absorb_class reports `none` (no run-step, no busy signature). Without a
# backstop that reads none-of-the-interface-text, the non-terminal-stale path would
# surface it as a possible wedge (docs/codex-busy-detection.md). codex_static_pane_upgrade
# corroborates with the codex agent PROCESS: an `alive` process (foreground command
# still `codex`) upgrades none -> working (absorb + wedge timer), while a `dead`
# process (bare shell) and any non-codex harness keep surfacing at once.
_codex_backstop_case() {  # <dir-name> <window> <harness> <current-command>
  local dir state fakebin capture_file window key pane_hash sig
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; window=$2
  printf 'idle mid tool-call, no busy row' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=%s\n' "$window" "$3" > "$state/w.meta"
  # Non-terminal status, .seen-* primed so the signal scan does not pre-empt the stale path.
  printf 'working: running a shell tool\n' > "$state/w.status"
  sig=$(seen_sig "$state/w.status"); printf '%s' "$sig" > "$state/.seen-w_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle mid tool-call, no busy row")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No run-step and no busy signature: crew_absorb_class is `none`.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  # Echo the fields the caller needs, then the caller launches the watcher itself
  # with the right FM_FAKE_TMUX_CURRENT_COMMAND ($4) so agent-liveness is stubbed.
  printf '%s\t%s\t%s\t%s\n' "$dir" "$state" "$fakebin" "$key"
}

test_codex_static_pane_alive_absorbed() {
  local fields dir state fakebin key out window pid pane_hash
  window="test:fm-codexbusy"
  fields=$(_codex_backstop_case codex-backstop-alive "$window" codex codex)
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"; pane_hash=$(hash_text "idle mid tool-call, no busy row")
  # A healthy codex worker: process alive (foreground command `codex`), high wedge
  # threshold so a first sighting can only be absorbed, never escalated.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=codex \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced a healthy static-pane codex worker (should absorb via agent liveness): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "codex liveness absorb printed a wake reason"
  [ ! -s "$state/.wake-queue" ] || fail "codex liveness absorb enqueued a wake"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on codex liveness absorb"
  [ -s "$state/.stale-since-$key" ] || fail "codex liveness absorb did not start the wedge timer (a wedged codex must still escalate)"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a healthy static-pane codex worker with an alive process is absorbed (agent-liveness backstop), and the wedge timer still arms"
}

test_codex_static_pane_dead_surfaces() {
  local fields dir state fakebin key out drain_out window pid
  window="test:fm-codexdead"
  fields=$(_codex_backstop_case codex-backstop-dead "$window" codex bash)
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A crashed codex: the pane's foreground command is a bare shell (`dead`). The
  # backstop must NOT absorb this - it surfaces immediately even under a high threshold.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=bash \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a codex pane whose process is dead"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "dead-process codex did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "a dead-process codex was mislabeled a wedge instead of an immediate surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "a dead-process codex must not start the wedge timer (immediate surface)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the dead-process surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "dead-process stale wake was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a codex pane whose process is dead surfaces immediately (the backstop never masks a crash)"
}

test_codex_backstop_scoped_to_codex() {
  local fields dir state fakebin key out window pid
  window="test:fm-claudealive"
  # Same static pane and an alive process, but harness=claude: the backstop is
  # codex-scoped (other harnesses keep rendering their busy row all turn), so an
  # otherwise-`none` stale surfaces at once regardless of process liveness.
  fields=$(_codex_backstop_case codex-backstop-scope "$window" claude claude)
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "the codex backstop leaked to a claude worker (should surface at once)"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a non-codex worker did not print the immediate stale wake"
  [ ! -e "$state/.stale-since-$key" ] || fail "a non-codex worker must not get the codex liveness absorb"
  unset FM_FAKE_CREW_STATE
  pass "the agent-liveness absorb is scoped to codex: a claude worker with an alive process still surfaces immediately"
}

# --- parked-at-a-decision-gate liveness gate ---------------------------------
# A worker parked at an ask-user finding is idle because it did exactly what its
# brief requires: ask, then stop. fm-crew-state.sh answers that outright
# ("state: parked · source: run-step · parked at review: 3 finding(s) (ask-user:
# captain decision)") and the watcher escalated it as a possible wedge anyway,
# every four minutes, because crew_absorb_class collapsed `parked` into `none`.
# The gate buys no silence at a FIRST sighting - that wake is how firstmate learns
# the pane is idle at all - only a hold on the wedge LADDER afterwards, corroborated
# by the agent PROCESS and by nothing else: a worker that crashed one second after
# printing its gate prompt leaves the run parked identically and forever, so `dead`
# and `unknown` keep today's escalation exactly. The first-sight rule is harness-
# independent: codex is covered explicitly, because its static-pane liveness
# backstop answers a different question (no run-step at all) and must not hand
# codex alone the absorb every other harness gives up here.
#
# The authoritative reading the watcher used to ignore. Passed into each watcher
# launch rather than exported by the fixture, because the fixture runs inside a
# command substitution and an export there would never reach the watcher.
PARKED_GATE_STATE='state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: captain decision)'

_parked_gate_case() {  # <dir-name> <window> <status-line> <pane-text> [harness]
  local dir state fakebin capture_file window key pane_hash sig statusf harness
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; window=$2; statusf="$state/gate.status"; harness=${5:-claude}
  printf '%s' "$4" > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=%s\n' "$window" "$harness" > "$state/gate.meta"
  printf '%s\n' "$3" > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$4")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\t%s\t%s\t%s\n' "$dir" "$state" "$fakebin" "$key"
}

# The gate never buys silence on a pane nobody has been told about yet: this crew's
# last status line is not captain-relevant, so no needs-decision/blocked line ever
# reached firstmate, and a first-sight absorb would leave the decision waiting out
# the long bounded cadence unannounced. The gate only ever holds the wedge LADDER,
# from the second sighting of that already-surfaced pane onward. Driven once per
# harness, since the harness is exactly what decides whether a `none` verdict gets
# a liveness absorb of its own.
_assert_parked_gate_surfaces_then_holds() {  # <dir-name> <window> <harness> <agent-command>
  local fields dir state fakebin key out drain_out window harness agent pid pane_hash
  window=$2; harness=$3; agent=$4
  fields=$(_parked_gate_case "$1" "$window" 'working: running the pipeline' 'idle at the review gate' "$harness")
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; pane_hash=$(hash_text "idle at the review gate")

  # Phase A: first sighting. A live agent at a parked gate changes nothing here.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND="$agent" FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "$harness: the first sighting of a run parked at an unrelayed gate was swallowed: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "$harness: the first sighting did not print the immediate stale wake: $(cat "$out")"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "$harness: stale suppressor not advanced on the first-sight surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "$harness: the first sighting started a wedge timer instead of surfacing at once"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "$harness: drain after the parked-gate first surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "$harness: the first sighting's wake was not queued"

  # Phase B: same pane, already surfaced, now past the escalation threshold. THIS
  # is where the gate earns its hold - the alarm firstmate has already seen must
  # not climb the wedge ladder against a worker that is alive and waiting for an
  # answer.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND="$agent" FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "$harness: a live worker parked at a gate still escalated on an already-surfaced pane: $(cat "$out")"
  fi
  grep -F "possible wedge" "$out" >/dev/null && { reap "$pid"; fail "$harness: the parked gate was reported as a possible wedge: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "$harness: the held ladder enqueued a wake: $(cat "$state/.wake-queue")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "$harness: a parked-gate hold climbed the wedge-escalation ladder"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "$harness: the parked-gate hold dropped the wedge timer instead of refreshing it"; }
  grep -F "the run is parked at a decision gate and this worker is still alive" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "$harness: the hold did not record WHY it believed the worker was fine: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  reap "$pid"
}

test_parked_gate_first_sight_surfaces_then_holds_the_ladder() {
  _assert_parked_gate_surfaces_then_holds parked-gate-alive "test:fm-gatealive" claude claude
  pass "a run parked at an unrelayed gate surfaces its first sighting, then holds the wedge ladder while its worker is alive"
}

# Same run, same live process, harness=codex. codex is the one harness whose
# otherwise-`none` static pane earns a liveness absorb of its own
# (codex_static_pane_upgrade), and an authoritative run-step gate must not be
# routed into it: that would give codex alone the 3600s bounded recheck where
# every other harness surfaces at once, on the very decision nobody has been told
# about. The gate short-circuits first, so codex surfaces like the rest and still
# holds the ladder afterwards.
test_parked_gate_codex_first_sight_surfaces_then_holds_the_ladder() {
  _assert_parked_gate_surfaces_then_holds parked-gate-codex "test:fm-gatecodex" codex codex
  pass "a codex worker parked at an unrelayed gate surfaces its first sighting too, then holds the wedge ladder"
}

test_parked_gate_dead_surfaces() {
  local fields dir state fakebin key out drain_out window pid
  window="test:fm-gatedead"
  fields=$(_parked_gate_case parked-gate-dead "$window" 'working: running the pipeline' 'idle at the review gate')
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # Identical run-step reading, agent gone (bare shell). The gate can no longer be
  # answered by anyone, so the parked case must NOT swallow it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a run parked at a gate whose worker died was never surfaced"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the dead parked worker did not print the immediate stale wake: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] || fail "a dead parked worker started the wedge timer instead of surfacing at once"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the dead parked-worker surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the dead parked worker's wake was not queued"
  pass "a run parked at a gate whose worker has died surfaces immediately (the parked case never masks a crash)"
}

# The captain's exact repeat: the crew appended needs-decision:, the signal path
# already relayed it, and each poll thereafter climbed the wedge ladder against a
# run that fm-crew-state.sh reported parked at an ask-user gate.
_parked_gate_ladder_case() {  # <dir-name> <window>
  local fields dir state fakebin key last pane_hash
  fields=$(_parked_gate_case "$1" "$2" 'needs-decision: review raised an ask-user finding for the captain' 'idle at the review gate')
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  last='needs-decision: review raised an ask-user finding for the captain'
  printf '%s' "$last" > "$state/.hb-surfaced-gate"
  pane_hash=$(hash_text "idle at the review gate")
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '%s\t%s\t%s\t%s\n' "$dir" "$state" "$fakebin" "$key"
}

test_parked_gate_alive_holds_the_wedge_ladder() {
  local fields dir state fakebin key out window pid
  window="test:fm-ladderalive"
  fields=$(_parked_gate_ladder_case parked-gate-ladder-alive "$window")
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a live worker parked at an ask-user gate still escalated as a possible wedge: $(cat "$out")"
  fi
  grep -F "possible wedge" "$out" >/dev/null && { reap "$pid"; fail "the parked gate was reported as a possible wedge: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the held ladder still enqueued a wake: $(cat "$state/.wake-queue")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a parked-gate hold climbed the wedge-escalation ladder"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "the parked-gate hold dropped the wedge timer instead of refreshing it"; }
  grep -F "ladder held" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the parked-gate ladder-hold branch never executed: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  reap "$pid"
  pass "a live worker parked at an ask-user gate holds the wedge ladder instead of escalating"
}

# The failure direction that matters. Same frozen pane, same parked run-step, same
# already-relayed needs-decision line - only the agent is gone. The escalation must
# fire on the unchanged schedule; a parked case that swallowed this would be silence
# nobody notices.
test_parked_gate_dead_escalates_on_the_ladder() {
  local fields dir state fakebin key out drain_out window pid
  window="test:fm-ladderdead"
  fields=$(_parked_gate_ladder_case parked-gate-ladder-dead "$window")
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=bash FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a parked run whose worker died was held by the ladder instead of escalating: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the dead parked worker did not escalate: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "the dead parked worker escalated off the normal schedule: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the dead parked worker did not climb the wedge ladder"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the dead parked-worker escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the dead parked worker's escalation was not queued"
  pass "a run parked at a gate whose worker died escalates on the unchanged wedge schedule"
}

# pi's launcher execs into a generic `node`, so its liveness reads unknown
# (docs/tmux-backend.md "Known gaps"). Unknown is not evidence of anything and
# never licenses a hold: these crews keep exactly the escalation they have today.
test_parked_gate_unknown_liveness_escalates_on_the_ladder() {
  local fields dir state fakebin key out window pid
  window="test:fm-ladderunknown"
  fields=$(_parked_gate_ladder_case parked-gate-ladder-unknown "$window")
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=node FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "an unreadable agent liveness was treated as proof the parked worker was fine: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the unknown-liveness parked worker did not escalate: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "the unknown-liveness parked worker escalated off the normal schedule: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the unknown-liveness parked worker did not climb the wedge ladder"
  pass "a parked worker whose agent liveness cannot be read keeps today's escalation"
}

# The other half of the "a stopped alarm is worse than a noisy one" rule: the hold
# is a HOLD, not silence. A gate nobody ever answers - the crew is alive and will
# wait forever - must still reach the captain on the long bounded cadence, in the
# recheck's own words rather than as a wedge, and without ever climbing the ladder.
# The anchor is the frozen hash's own mtime, which the hold refreshes nowhere, so a
# permanent hold cannot postpone its own recheck.
test_parked_gate_hold_gets_bounded_recheck() {
  local fields dir state fakebin key out window pid back stale_mtime
  window="test:fm-gaterot"
  fields=$(_parked_gate_ladder_case parked-gate-hold-recheck "$window")
  IFS=$'\t' read -r dir state fakebin key <<< "$fields"
  out="$dir/watch.out"
  # This pane has been frozen at the gate for a full recheck window.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.stale-$key"
  else touch -m -d "@$back" "$state/.stale-$key"; fi
  stale_mtime=$(file_mtime "$state/.stale-$key")

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a gate held all day never got its bounded recheck: $(cat "$out")"
  grep -F "bounded recheck" "$out" >/dev/null || fail "the recheck did not identify itself as a bounded recheck: $(cat "$out")"
  grep -F "the run is parked at a decision gate and this worker is still alive" "$out" >/dev/null \
    || fail "the recheck did not tell the captain WHY the pane was held: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a parked-gate recheck was mislabeled a wedge escalation: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a parked-gate bounded recheck climbed the wedge-escalation ladder"
  [ -s "$state/.wedgeheld-$key" ] || fail "the parked-gate bounded recheck did not record its throttle marker"
  [ "$(file_mtime "$state/.stale-$key")" = "$stale_mtime" ] \
    || fail "the parked hold refreshed the .stale-<key> anchor, which would postpone its own recheck forever"
  grep "$(printf '\tstale\t')" "$state/.wake-queue" | grep -F "$window" >/dev/null \
    || fail "the parked-gate bounded recheck was not queued for the captain: $(cat "$state/.wake-queue")"

  # Throttled: the next poll inside the same recheck window holds again silently.
  echo "$back" > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude FM_FAKE_CREW_STATE="$PARKED_GATE_STATE" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the parked-gate bounded recheck repeated inside its own cadence: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a throttled parked-gate recheck enqueued another wake"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a throttled parked-gate recheck climbed the wedge-escalation ladder"
  reap "$pid"
  pass "a parked gate nobody answers still earns one bounded recheck per window, never a wedge escalation"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 15; then reap "$pid"; else wait "$pid" || fail "dead-agent watcher round $round failed"; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "live external-decision gate did not surface immediately"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -eq 1 ] || fail "live external-decision gate should surface once, got $wakes wakes"
  [ "$bare" -eq 1 ] || fail "live external-decision gate lost its immediate bare stale surface"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  # Past the threshold the escalation re-reads the crew state: the run is still
  # active, so the ladder is held and the timer refreshed rather than alarming.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run overriding a declared pause climbed the wedge ladder: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "an active run overriding a declared pause enqueued a wedge escalation"
  [ -s "$state/.stale-since-$key" ] || fail "the held wedge timer was dropped instead of refreshed"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "an active run climbed the wedge-escalation ladder"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working keeps its wedge timer and holds the ladder while the run is active"
}

# The hold's bounded recheck must reach this path too. hold_age is anchored on the
# frozen pane hash's own mtime (.stale-<key>), so any per-poll rewrite of that
# marker on a ladder-holding path would reset the anchor every poll and let a run
# whose agent died mid-step - it reports `running` forever - rot invisibly behind
# a permanent hold.
test_paused_authoritative_working_hold_gets_bounded_recheck() {
  local dir state fakebin out capture_file window key pane_hash sig pid back stale_mtime
  dir=$(make_case paused-working-hold-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-frozen"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-frozen.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-frozen.status"
  sig=$(seen_sig "$state/paused-frozen.status"); printf '%s' "$sig" > "$state/.seen-paused-frozen_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  # This pane froze long ago: back-date the hash marker that anchors hold_age.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.stale-$key"
  else touch -m -d "@$back" "$state/.stale-$key"; fi
  stale_mtime=$(file_mtime "$state/.stale-$key")
  echo "$back" > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a long-held ladder on the paused-then-working path never got its bounded recheck: $(cat "$out")"
  grep -F "bounded recheck" "$out" >/dev/null || fail "the recheck did not identify itself as a bounded recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a bounded recheck was mislabeled a wedge escalation: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a bounded recheck on the paused-then-working path climbed the wedge-escalation ladder"
  [ -s "$state/.wedgeheld-$key" ] || fail "the bounded recheck did not record its throttle marker"
  [ "$(file_mtime "$state/.stale-$key")" = "$stale_mtime" ] \
    || fail "the repeat poll refreshed the .stale-<key> anchor, which would defeat the bounded recheck"

  # Throttled: the next poll inside the same recheck window is absorbed again.
  echo "$back" > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the bounded recheck repeated inside its own cadence: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a throttled hold recheck on the paused-then-working path enqueued another wake"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a throttled hold recheck climbed the wedge-escalation ladder"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a ladder hold on the paused-then-working path surfaces one bounded recheck without climbing the ladder"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  # The run then STOPS: the ladder below is the contract for a crew with no
  # active run, which this change deliberately leaves untouched.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"

  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path re-reads the crew state only to decide whether an ACTIVE run holds
    # the ladder; with the run stopped, every rung fires on the unchanged
    # schedule).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_WEDGE_REPEAT_RESURFACE_SECS=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

# --- unchanged wedge alarms deliver once, then retain bounded history ----------
#
# The first case is deliberately the known-bad input for the suppression below.
# A crew with no active run and a frozen pane must still raise its first possible-
# wedge alarm, and the same condition must re-surface after the configured bound.
# Run this before the quiet-path replay so a broken implementation cannot prove
# itself merely by producing no output.
test_repeat_wedge_suppression_still_surfaces_a_real_wedge_on_a_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid back
  dir=$(make_case repeat-wedge-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-real-wedge"
  printf 'frozen worker output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/real-wedge.meta"
  printf 'working: last known progress\n' > "$state/real-wedge.status"
  sig=$(seen_sig "$state/real-wedge.status"); printf '%s' "$sig" > "$state/.seen-real-wedge_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "frozen worker output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=5 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a genuinely wedged worker did not raise its first alarm: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "known-wedged input did not produce a wedge alarm: $(cat "$out")"
  grep -F $'\tsurfaced\t' "$state/.wedge-alarm-history" >/dev/null \
    || fail "the surfaced known-wedge alarm was not retained in durable history"

  # The delivery marker is the cadence anchor. Age it past the deliberately tiny
  # bound and require the unchanged real wedge to get through again.
  back=$(( $(date +%s) - 6 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.wedgeheld-$key"
  else touch -m -d "@$back" "$state/.wedgeheld-$key"; fi
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=5 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "an unchanged real wedge stayed suppressed beyond the configured bound: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "bounded real-wedge re-surface lost its alarm payload: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a genuinely wedged worker surfaces first and re-surfaces after FM_WEDGE_REPEAT_RESURFACE_SECS"
}

# Real drain records from fleet-pin-bump-b696c0e on 2026-08-10:
#   1786366330 escalation 1, idle 249s
#   1786366581 escalation 2, idle 251s
#   1786366830 escalation 3, idle 247s
#   1786367080 escalation 4, idle 250s
#   1786367333 escalation 5, idle 251s
# The worker was checked after each delivery and remained healthy. Replaying the
# exact recorded idle-age sequence against one unchanged pane must deliver one
# alarm, retain all five candidates in history, and suppress candidates 2-5.
test_recorded_five_alarm_sequence_delivers_one() {
  local dir state fakebin out capture_file window key pane_hash sig pid age expected lines dispositions
  dir=$(make_case recorded-five-wedges); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-fleet-pin-bump-b696c0e"
  printf 'unchanged validation pane' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/fleet-pin-bump-b696c0e.meta"
  printf 'working: validation still under way\n' > "$state/fleet-pin-bump-b696c0e.status"
  sig=$(seen_sig "$state/fleet-pin-bump-b696c0e.status")
  printf '%s' "$sig" > "$state/.seen-fleet-pin-bump-b696c0e_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "unchanged validation pane")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # The first recorded alarm must still be delivered.
  echo $(( $(date +%s) - 249 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "the first recorded wedge candidate was suppressed: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "the first recorded alarm did not surface as escalation 1: $(cat "$out")"

  # Keep one watcher alive for the four remaining recorded ages. Each candidate
  # must append history before it is suppressed, so the line count is the test's
  # synchronization point and no sleep guesses at watcher timing.
  : > "$out"
  echo $(( $(date +%s) - 251 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  expected=2
  for age in 247 250 251; do
    wait_line_count "$state/.wedge-alarm-history" "$expected" 40 \
      || { reap "$pid"; fail "recorded candidate $expected was neither retained nor classified"; }
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "recorded candidate $expected was delivered instead of suppressed: $(cat "$out")"; }
    echo $(( $(date +%s) - age )) > "$state/.stale-since-$key"
    expected=$((expected + 1))
  done
  wait_line_count "$state/.wedge-alarm-history" 5 40 \
    || { reap "$pid"; fail "the fifth recorded candidate was not retained"; }
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "the fifth recorded candidate was delivered instead of suppressed: $(cat "$out")"; }
  reap "$pid"

  lines=$(grep -c . "$state/.wake-queue" 2>/dev/null || true)
  [ "$lines" = 1 ] || fail "the recorded five-alarm sequence delivered $lines alarms instead of 1"
  [ "$(wc -l < "$state/.wedge-alarm-history" | tr -d '[:space:]')" = 5 ] \
    || fail "the recorded five-alarm sequence did not retain all five candidates"
  dispositions=$(cut -f2 "$state/.wedge-alarm-history")
  [ "$dispositions" = "$(printf 'surfaced\nsuppressed\nsuppressed\nsuppressed\nsuppressed')" ] \
    || fail "the recorded sequence history carried the wrong delivery decisions: $dispositions"
  unset FM_FAKE_CREW_STATE
  pass "the real fleet-pin-bump-b696c0e five-alarm sequence delivers 1 and retains all 5"
}

test_repeat_wedge_state_change_and_history_failure_fail_open() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case repeat-wedge-fail-open); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-repeat-fail-open"
  printf 'static pane' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/repeat-fail-open.meta"
  printf 'working: earlier progress\n' > "$state/repeat-fail-open.status"
  sig=$(seen_sig "$state/repeat-fail-open.status"); printf '%s' "$sig" > "$state/.seen-repeat-fail-open_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "static pane")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  printf 'none' > "$state/.wedgeheld-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validation resumed'

  # A changed authoritative class updates the shared wedge state without waking.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_file_value "$state/.wedgeheld-$key" working 40 \
    || { reap "$pid"; fail "a genuine state change to working did not re-key wedge suppression"; }
  reap "$pid"

  # When that run then stops, the class change back to none must surface at once
  # even though the prior alarm's delivery bound has not elapsed.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · run stopped'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a genuine state change from working to stopped was suppressed: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the stopped-state change lost its wedge alarm: $(cat "$out")"

  # Suppression is permitted only after its append-only history write succeeds.
  # Replacing the history file with a directory makes that assurance fail; the
  # repeat must fail open to ordinary delivery rather than disappear silently.
  rm -f "$state/.wedge-alarm-history"
  mkdir "$state/.wedge-alarm-history"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_REPEAT_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a failed history write silently swallowed an unchanged wedge alarm"
  grep -F "possible wedge" "$out" >/dev/null || fail "history failure did not fail open to wedge delivery: $(cat "$out")"
  grep -F "repeat suppression disabled: append-only wedge alarm history could not be written" "$out" >/dev/null \
    || fail "the fail-open wedge delivery did not explain that suppression was disabled: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "wedge suppression re-keys on state changes and fails open when durable history cannot be written"
}

# --- the ladder-hold path under a STRIPPED service environment ----------------
#
# Every other ladder case in this file stubs the state reader through
# FM_CREW_STATE_BIN, so they prove the watcher's BRANCHING and say nothing about
# whether the real reader can answer at all. That gap is how the 2026-08 fleet
# blindness shipped: the ladder-hold branch was correct, carefully commented,
# and had never once executed on a real vessel, because systemd's user manager
# handed the watcher a PATH containing no no-mistakes CLI, bin/fm-crew-state.sh
# answered `unknown - none` for every crew, and `ladder held` appeared 0 times in
# 2027 triage entries while long validations woke the supervising session every
# four minutes. So this case runs the REAL bin/fm-crew-state.sh, and it runs it
# under the literal systemd user-manager default PATH - a test that passes only
# because the developer's own PATH is rich proves exactly nothing here.
FM_TEST_SYSTEMD_DEFAULT_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin'

test_ladder_holds_under_a_stripped_service_environment() {
  local dir state fakebin tools out window key pane_hash sig pid head service_path
  # Named explicitly rather than left to the default: earlier cases in this file
  # EXPORT a stubbed reader, and the whole point here is the real one.
  local real_reader="$ROOT/bin/fm-crew-state.sh"
  if ! PATH="$FM_TEST_SYSTEMD_DEFAULT_PATH" command -v git >/dev/null 2>&1; then
    pass "stripped-environment ladder regression skipped: this host has no git on the systemd default PATH"
    return
  fi
  dir=$(make_case ladder-stripped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; tools="$dir/tools"; window="test:fm-stripped"

  # A real worktree on a real branch, so the reader's branch attribution and
  # head binding run for real rather than being stubbed away.
  fm_git_identity fmtest fmtest@example.invalid
  mkdir -p "$dir/wt" "$tools"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" checkout -q -b fm/feat-stripped
  head=$(git -C "$dir/wt" rev-parse HEAD)

  # The no-mistakes CLI lives OUTSIDE the stripped PATH, exactly as
  # ~/.no-mistakes/bin does on a real vessel. Only a PATH that deliberately
  # resolves it can reach it.
  cat > "$tools/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-} \${2:-}" in
  "axi status")
    cat <<'TOON'
run:
  id: "01RUN"
  branch: fm/feat-stripped
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
TOON
    ;;
esac
exit 0
SH
  chmod +x "$tools/no-mistakes"

  # The shared fake tmux answers only what a stubbed reader needs; the REAL
  # reader also asks whether the endpoint is readable at all, so this case
  # supplies a fake that answers that too. Without it the endpoint would read as
  # gone and the case would never reach the question it exists to ask.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-panes) printf '%%1 1\n'; exit 0 ;;
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"; exit 0 ;;
  capture-pane) [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
    esac ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"

  printf 'idle while the review step runs' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$dir/wt" > "$state/stripped.meta"
  printf 'working: still validating\n' > "$state/stripped.status"
  sig=$(seen_sig "$state/stripped.status"); printf '%s' "$sig" > "$state/.seen-stripped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle while the review step runs")
  # Prime the repeat-sight wedge timer directly: this case is about what happens
  # at the escalation moment, not about first-sight classification.
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"

  # Phase A - the shipped defect's environment. The reader cannot find the CLI,
  # so it must say so rather than answer for the crew, and the ladder must not
  # climb on a reading nobody took.
  PATH="$fakebin:$FM_TEST_SYSTEMD_DEFAULT_PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$real_reader" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || { reap "$pid"; fail "an unreadable crew state was silently absorbed instead of reported"; }
  grep -F "crew state unreadable" "$out" >/dev/null \
    || fail "a missing-dependency read was not reported as its own condition: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a broken state reader was reported as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a reading that was never taken still climbed the wedge ladder"

  # Phase B - the same crew, the same moment, the same stripped base
  # environment, differing ONLY in that the service resolves the tools it
  # depends on. The real reader now attributes the active run, and the ladder
  # holds.
  service_path=$(PATH="$tools:$FM_TEST_SYSTEMD_DEFAULT_PATH" bash -c \
    ". '$ROOT/bin/fm-service-path-lib.sh'; fm_service_path")
  case "$service_path" in
    *"$tools"*) ;;
    *) fail "the composed service PATH did not resolve the tool it exists to reach: $service_path" ;;
  esac
  rm -f "$state/.degraded-$key" "$state/.wake-queue" "$state/.watch-triage.log"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$service_path" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$real_reader" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 60; then
    reap "$pid"; fail "an active run climbed the wedge ladder under a resolved service PATH: $(cat "$out")"
  fi
  grep -F "ladder held" "$state/.watch-triage.log" >/dev/null \
    || fail "the ladder-hold branch never executed: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  [ ! -s "$state/.wake-queue" ] || fail "a held ladder still enqueued a wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a held ladder still incremented the escalation counter"
  reap "$pid"
  pass "the ladder holds for a provably-working crew under a stripped environment, and an unreadable read is reported instead"
}

# --- the follow-on terminal stale for an already-surfaced line -----------------
# The real doubling: a crew's done: line wakes firstmate through the signal path,
# then its turn ends, its pane settles to a NEW stable hash seconds later, and
# the terminal-status stale branch reports the SAME line again as a second full
# supervision cycle. Suppression is content-keyed on .hb-surfaced-<task>, so this
# pair pins both directions: an already-surfaced line is absorbed (and still
# wedge-escalates if the pane really is stuck), a not-yet-surfaced or CHANGED
# captain-relevant line still surfaces at once.
test_terminal_stale_already_surfaced_absorbed_then_escalates() {
  local dir state fakebin out capture_file window key pane_hash sig pid last
  dir=$(make_case terminal-stale-already-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-relayed"
  printf 'idle prompt after the final turn' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/relayed.meta"
  last='done: branch ready for review'
  printf 'working: implementing\n%s\n' "$last" > "$state/relayed.status"
  sig=$(seen_sig "$state/relayed.status"); printf '%s' "$sig" > "$state/.seen-relayed_status"
  # The signal path already surfaced exactly this line moments ago.
  printf '%s' "$last" > "$state/.hb-surfaced-relayed"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt after the final turn")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Deliberately NOT provably working - the absorb must come from the surfaced
  # content, not from an active run.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the follow-on stale for an already-surfaced done: line woke firstmate a second time: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the follow-on stale enqueued a duplicate wake: $(cat "$state/.wake-queue")"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "the wedge timer was not started, so a wedged crew could not escalate"
  reap "$pid"

  # A crew genuinely stuck behind that already-relayed line still escalates.
  echo $(( $(date +%s) - 300 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a crew wedged behind an already-surfaced line never escalated: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "the escalation did not flag a possible wedge: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a follow-on stale repeating an already-surfaced terminal line is absorbed, and a real wedge behind it still escalates"
}

test_terminal_stale_changed_line_still_surfaces() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-changed-line); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-changed"
  printf 'idle prompt, waiting' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/changed.meta"
  # The crew has moved on to a NEW captain-relevant line; the marker still holds
  # the older one firstmate already saw. Suppressing by window would swallow this.
  printf 'done: first stage landed\nblocked: need the deploy credential\n' > "$state/changed.status"
  sig=$(seen_sig "$state/changed.status"); printf '%s' "$sig" > "$state/.seen-changed_status"
  printf '%s' 'done: first stage landed' > "$state/.hb-surfaced-changed"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, waiting")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a stale carrying a NEW captain-relevant line was suppressed: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "the new-line stale did not print a wake reason: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "the new-line stale was not queued"
  unset FM_FAKE_CREW_STATE
  reap "$pid"
  pass "a stale whose captain-relevant line has not been surfaced yet still wakes firstmate at once"
}

# --- a held ladder still gets a bounded recheck --------------------------------
# An active run holds the wedge ladder, which is right for a long pipeline step
# but would be wrong forever: a run whose agent died mid-step keeps reporting
# `running`. A hold lasting a full PAUSE_RESURFACE_SECS - measured on the frozen
# pane hash, not on the refreshed timer - surfaces ONE bounded recheck, throttled
# to one per window, and never touches the escalation ladder.
test_wedge_hold_bounded_recheck_after_long_freeze() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-hold-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-frozen"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/frozen.meta"
  printf 'working: still monitoring ci\n' > "$state/frozen.status"
  sig=$(seen_sig "$state/frozen.status"); printf '%s' "$sig" > "$state/.seen-frozen_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: absorbed, and .stale-$key now dates this frozen pane.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "priming round did not start the wedge timer"; }
  reap "$pid"

  # Let the frozen pane age past a (deliberately tiny) recheck cadence.
  sleep 6
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=5 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a long-frozen pane under an active run never got its bounded recheck: $(cat "$out")"
  grep -F "bounded recheck" "$out" >/dev/null || fail "the recheck did not identify itself as a bounded recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a bounded recheck was mislabeled a wedge escalation: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a bounded recheck climbed the wedge-escalation ladder"
  [ -s "$state/.wedgeheld-$key" ] || fail "the bounded recheck did not record its throttle marker"

  # Throttled: the next poll inside the same window is absorbed again.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  : > "$state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the bounded recheck repeated inside its own cadence: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a throttled hold recheck enqueued another wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a ladder hold that lasts a full recheck window surfaces one bounded recheck without climbing the ladder"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_CERTSYNC_PROJECT="$dir/no-certsync" "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_CERTSYNC_PROJECT="$dir/no-certsync" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# The certsync health check reads certsync's status directly off the host
# filesystem (no docker, no `exec`, no docker-group membership) by running
# certsync's own build_status via python3 against the exposed heartbeat/state
# files. These fakes stand in for that source tree and the heartbeat file so the
# firstmate-side wiring is exercised hermetically:
#   - setup_certsync_health_case installs a fake `hlr_certsync` package under the
#     project's src/ whose build_status returns the JSON dict named by
#     FM_FAKE_CERTSYNC_PAYLOAD (or raises on the RAISE sentinel), and seeds a
#     heartbeat file whose mtime the caller controls.
#   - certsync_health_env prints the env the watcher needs to find them.
setup_certsync_health_case() {  # <dir> [heartbeat-age-seconds]
  local dir=$1 age=${2:-0} project src hb back
  project="$dir/home/projects/hlr-certsync"
  src="$project/src"
  mkdir -p "$dir/root" "$project" "$src/hlr_certsync"
  : > "$project/docker-compose.yml"
  : > "$src/hlr_certsync/__init__.py"
  cat > "$src/hlr_certsync/state.py" <<'PY'
class StateStore:
    def __init__(self, path):
        self.path = path
PY
  cat > "$src/hlr_certsync/status.py" <<'PY'
import json, os
def build_status(store, heartbeat_path, *, daemon_state="unknown"):
    with open(os.environ["FM_FAKE_CERTSYNC_PAYLOAD"]) as fh:
        text = fh.read().strip()
    if text == "RAISE":
        raise RuntimeError("state DB unavailable")
    return json.loads(text)
PY
  # Seed the heartbeat file the freshness gate stats; default mtime is now.
  hb="$dir/certsync-heartbeat.json"
  printf '{"last_successful_sync":"2026-08-05T12:00:00Z","last_run_state":"success"}\n' > "$hb"
  if [ "$age" -gt 0 ]; then
    back=$(( $(date +%s) - age ))
    if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$hb"
    else touch -m -d "@$back" "$hb"; fi
  fi
}

# Env the watcher needs to run the file-read check against the fakes above.
certsync_health_env() {  # <dir>
  local dir=$1
  printf '%s\n' \
    "FM_ROOT_OVERRIDE=$dir/root" \
    "FM_HOME=$dir/home" \
    "FM_CERTSYNC_STATE_DB=$dir/certsync-state.sqlite3" \
    "FM_CERTSYNC_HEARTBEAT_FILE=$dir/certsync-heartbeat.json" \
    "FM_FAKE_CERTSYNC_PAYLOAD=$dir/certsync-payload.json"
}

test_heartbeat_certsync_healthy_absorbed() {
  local dir state out pid
  local -a health_env
  dir=$(make_case heartbeat-certsync-healthy); state="$dir/state"; out="$dir/watch.out"
  setup_certsync_health_case "$dir"
  printf '{"healthy":true,"reason":"ok"}\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for healthy certsync (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "healthy certsync printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "healthy certsync enqueued a durable wake record"
  reap "$pid"
  pass "heartbeat absorbs healthy certsync status read directly off the host files"
}

# The liveness signal the docker-exec check got for free (exec failed when the
# container was down) is reinstated here as a heartbeat-freshness bound: a
# healthy:true payload whose heartbeat file has gone stale (container stopped, or
# syncs failing so no fresh success) must read as unhealthy, never quiet, so
# "cannot confirm well" never collapses into "is well" off frozen files.
test_heartbeat_certsync_healthy_but_stale_surfaces_check_wake() {
  local dir state out drain_out pid
  local -a health_env
  dir=$(make_case heartbeat-certsync-stale); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir" 10800  # heartbeat 3h old, past the 7200s bound
  printf '{"healthy":true,"reason":"ok"}\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat did not surface a stale-heartbeat certsync as unhealthy: $(cat "$out")"
  if ! grep -F "check: certsync health: unhealthy: heartbeat stale (" "$out" >/dev/null \
    || ! grep -F "> 7200s); daemon may be stopped or syncs failing" "$out" >/dev/null; then
    fail "stale-heartbeat certsync wake reason was wrong: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after stale certsync wake failed"
  grep -F "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: unhealthy: heartbeat stale (')" "$drain_out" >/dev/null \
    || fail "stale-heartbeat certsync check wake was not queued: $(cat "$drain_out")"
  pass "a healthy payload with a stale heartbeat surfaces as unhealthy instead of reading as healthy off frozen files"
}

test_heartbeat_certsync_unhealthy_surfaces_check_wake() {
  local dir state out drain_out pid
  local -a health_env
  dir=$(make_case heartbeat-certsync-unhealthy); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir"
  printf '{"healthy":false,"reason":"state DB missing"}\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat did not surface unhealthy certsync"
  grep -Fx "check: certsync health: unhealthy: state DB missing" "$out" >/dev/null \
    || fail "certsync wake reason was wrong: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after certsync wake failed"
  grep "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: unhealthy: state DB missing')" "$drain_out" >/dev/null \
    || fail "certsync check wake was not queued: $(cat "$drain_out")"
  pass "heartbeat surfaces confirmed unhealthy certsync through the check wake path"
}

test_afk_heartbeat_certsync_unhealthy_surfaces_check_wake() {
  local dir state out drain_out pid
  local -a health_env
  dir=$(make_case afk-heartbeat-certsync-unhealthy); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir"
  printf '{"healthy":false,"reason":"replication stalled"}\n' > "$dir/certsync-payload.json"
  : > "$state/.afk"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "afk heartbeat did not surface unhealthy certsync"
  grep -Fx "check: certsync health: unhealthy: replication stalled" "$out" >/dev/null \
    || fail "afk certsync wake reason was wrong: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after afk certsync wake failed"
  grep "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: unhealthy: replication stalled')" "$drain_out" >/dev/null \
    || fail "afk certsync check wake was not queued: $(cat "$drain_out")"
  ! grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$drain_out" >/dev/null \
    || fail "afk certsync unhealthy also queued a generic heartbeat: $(cat "$drain_out")"
  pass "afk heartbeat surfaces confirmed unhealthy certsync through the check wake path"
}

# Regression for the 2026-08-04 defect: an unreadable certsync status (here a
# payload with no boolean healthy field) used to collapse into the SAME silent
# no-wake outcome as a confirmed-healthy read, so a check that could not run
# reported exactly like a check that ran and passed. It must surface as its own
# distinct "cannot run" check wake instead.
test_heartbeat_certsync_invalid_json_surfaces_check_wake() {
  local dir state out drain_out pid
  local -a health_env
  dir=$(make_case heartbeat-certsync-invalid-json); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir"
  printf '{"reason":"cannot tell"}\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat did not surface an unreadable certsync status as cannot-run: $(cat "$out")"
  grep -Fx "check: certsync health: cannot run: invalid or missing status JSON" "$out" >/dev/null \
    || fail "certsync cannot-run wake reason was wrong: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after certsync cannot-run wake failed"
  grep "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: cannot run: invalid or missing status JSON')" "$drain_out" >/dev/null \
    || fail "certsync cannot-run check wake was not queued: $(cat "$drain_out")"
  pass "heartbeat surfaces an unreadable certsync status as its own cannot-run check wake, distinct from healthy"
}

# The status read itself failing (build_status raising - e.g. an unreadable or
# corrupt state DB) is the file-read analogue of the old docker-exec failure: it
# must exit nonzero and surface a "cannot run" wake, never collapse into healthy.
test_heartbeat_certsync_status_read_failure_surfaces_check_wake() {
  local dir state out drain_out pid
  local -a health_env
  dir=$(make_case heartbeat-certsync-read-failure); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir"
  printf 'RAISE\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat did not surface a failing certsync status read: $(cat "$out")"
  grep -Fx "check: certsync health: cannot run: status command failed (exit 1)" "$out" >/dev/null \
    || fail "status-read-failure certsync wake reason was wrong: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after status-read-failure certsync wake failed"
  grep "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: cannot run: status command failed (exit 1)')" "$drain_out" >/dev/null \
    || fail "status-read-failure certsync check wake was not queued: $(cat "$drain_out")"
  pass "heartbeat surfaces a failing certsync status read as its own cannot-run check wake, not as healthy"
}

# certsync deployed (compose present) but its source tree absent means the check
# genuinely cannot read status: it must say so, never fall silent as healthy.
test_heartbeat_certsync_source_unavailable_surfaces_check_wake() {
  local dir state out drain_out pid src
  local -a health_env
  dir=$(make_case heartbeat-certsync-no-src); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  setup_certsync_health_case "$dir"
  src="$dir/home/projects/hlr-certsync/src"
  rm -rf "$src"   # deployed, but no importable certsync source
  printf '{"healthy":true,"reason":"ok"}\n' > "$dir/certsync-payload.json"
  mapfile -t health_env < <(certsync_health_env "$dir")
  env "${health_env[@]}" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat did not surface missing certsync source as cannot-run: $(cat "$out")"
  grep -F "check: certsync health: cannot run: certsync source unavailable at " "$out" >/dev/null \
    || fail "source-unavailable certsync wake reason was wrong: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after source-unavailable certsync wake failed"
  grep -F "$(printf '\tcheck\tcertsync-health\tcheck: certsync health: cannot run: certsync source unavailable at ')" "$drain_out" >/dev/null \
    || fail "source-unavailable certsync check wake was not queued: $(cat "$drain_out")"
  pass "heartbeat surfaces a certsync deployment with no readable source as its own cannot-run check wake"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_signal_crew_provably_working_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_single_turn_two_files_enqueue_one_wake
test_afk_single_turn_two_files_enqueue_one_wake
test_two_crewmates_signal_once_each
test_lone_turn_end_keeps_its_own_key
test_signal_symlink_target_append_surfaces
test_terminal_stale_surfaced
test_terminal_stale_parked_absorbed_then_resurfaced
test_parked_rechecks_coalesce_into_one_wake
test_pause_resurface_default_stays_under_the_prompt_cache_hour
test_parked_marker_clears_on_status_write
test_parked_marker_clears_on_meta_change
test_mark_parked_wrapper
test_mark_parked_wrapper_rejects_secondmate
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_codex_static_pane_alive_absorbed
test_codex_static_pane_dead_surfaces
test_codex_backstop_scoped_to_codex
test_parked_gate_first_sight_surfaces_then_holds_the_ladder
test_parked_gate_codex_first_sight_surfaces_then_holds_the_ladder
test_parked_gate_dead_surfaces
test_parked_gate_alive_holds_the_wedge_ladder
test_parked_gate_dead_escalates_on_the_ladder
test_parked_gate_unknown_liveness_escalates_on_the_ladder
test_parked_gate_hold_gets_bounded_recheck
test_terminal_stale_already_surfaced_absorbed_then_escalates
test_terminal_stale_changed_line_still_surfaces
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_repeat_wedge_suppression_still_surfaces_a_real_wedge_on_a_bound
test_recorded_five_alarm_sequence_delivers_one
test_repeat_wedge_state_change_and_history_failure_fail_open
test_ladder_holds_under_a_stripped_service_environment
test_wedge_hold_bounded_recheck_after_long_freeze
test_wedge_escalation_resets_when_pane_becomes_active
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_paused_authoritative_working_hold_gets_bounded_recheck
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_heartbeat_certsync_healthy_absorbed
test_heartbeat_certsync_healthy_but_stale_surfaces_check_wake
test_heartbeat_certsync_unhealthy_surfaces_check_wake
test_afk_heartbeat_certsync_unhealthy_surfaces_check_wake
test_heartbeat_certsync_invalid_json_surfaces_check_wake
test_heartbeat_certsync_status_read_failure_surfaces_check_wake
test_heartbeat_certsync_source_unavailable_surfaces_check_wake
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
