#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed> · source: <run-step|pane|status-log> · <detail>
#   state: <unknown|degraded> · source: <none|missing-dependency|read-failed> · cause: <token> · <detail>
#
# A state-carrying answer is a READING and carries no cause. The two answers that
# are NOT readings carry one, because "I have no state for this crew" is useless
# to a supervisor until it says why, and a free-prose sentence cannot be switched
# on. `unknown` means the reader looked and found nothing; `degraded` means it
# could not look. The state vocabulary stays two-valued for that class on
# purpose - callers switch on it - and all the precision lives in `cause`, which
# is a fixed enumerated token, never prose:
#
#   unknown (looked, found nothing)
#     no-metadata               state/<id>.meta does not exist
#     no-worktree-recorded      the meta records no worktree= at all
#     worktree-gone             a worktree IS recorded and the directory is not there
#     no-endpoint-recorded      the meta records no backend target
#     endpoint-unreadable       the target did not answer and its CLI is installed
#     kind-skips-run-lookup     kind=scout/secondmate, which never drive a run
#     delivery-mode-skips-run-lookup  kind=ship but mode=direct-PR/local-only, which never drive a run
#     no-branch                 kind=ship at detached HEAD, so no run can be attributed
#     no-run-attributed         the run lookup answered and named no run for this crew
#     run-attribution-rejected  a run WAS found and this reader refused it
#     log-verb-not-a-state      the status log's last line carries no state verb
#     no-status-after-turn-end  a turn-end marker exists but no status event landed
#   degraded (could not look)
#     run-reader-missing        git is not on PATH or no-mistakes cannot be resolved
#     no-bounding-mechanism     no timeout, gtimeout or perl, so the call was never made
#     run-lookup-failed         the CLI ran and did not answer
#     endpoint-reader-missing   the backend's own session CLI is not on PATH
#
# WHAT REMAINS COLLAPSED after 2026-08-04, and why each is acceptable (this list
# is the contract; extend it rather than letting a collapse go unrecorded):
#   - run-attribution-rejected does not say WHICH rejection rule fired (rewritten
#     head, diverged history, local work advanced past the run head, terminal run
#     with an unbindable head, missing head field). All five are one fact for a
#     supervisor - a run exists and this reader will not treat it as this crew's
#     evidence - and separating them would publish no-mistakes internals this
#     reader does not own. The prose detail names the run when there is one.
#   - run-reader-missing does not say whether git or the no-mistakes CLI is the
#     absent one; the detail names it, and the repair is the same PATH repair.
#     Since 2026-08-13 it also means the no-mistakes CLI was not at this seat's
#     install location either, because bin/fm-nm-path-lib.sh looks there before
#     this verdict is reached - so the cause now names a dependency absent from
#     both supported resolution routes rather than an environment that merely
#     failed to carry one
#     (docs/run-reader-reach.md).
#   - log-verb-not-a-state takes precedence over the run-lookup cause when both
#     apply, because it names the LAST source consulted. The run-lookup reason is
#     then carried in the prose detail rather than in the token.
#   - worktree-gone cannot tell "torn down" from "never created" or a bad path;
#     nothing on disk distinguishes them, so the reader does not guess.
#   - no-run-attributed covers both "axi status named no run" and "the coarse runs
#     list had no row for this branch"; both mean the same thing to a caller.
#
# `degraded` is NOT a crew state - it is this reader refusing to answer. It is
# emitted when a source could not be consulted, and no other source produced a
# state. The distinction is load-bearing:
# an absence verdict ("no current-state source available", "backend target
# gone") is a positive claim about the crew, and a reader whose instrument is
# missing has no standing to make it. Collapsing the two is how the 2026-08
# watcher blindness survived for weeks - systemd's user-manager PATH reached no
# no-mistakes CLI, every ship crew answered `unknown - none`, and every caller
# treated a broken instrument as a valid quiet reading (bin/fm-service-path-lib.sh
# owns the PATH fix for one recorded service, bin/fm-nm-path-lib.sh owns
# resolving the run-step reader's own dependency for any context that inherits
# nothing, and bin/fm-classify-lib.sh's crew_absorb_class owns what a supervisor
# does with `degraded`). That honest refusal is also what made the SECOND round
# of this diagnosable nine days later - 2026-08-13, when the reader read true
# state interactively and refused unattended at the same moment, and an
# independent reviewer that could not see a decision resolved re-reported it as
# outstanding after every answer (docs/run-reader-reach.md).
# Two answers survive a missing run-step
# reader, because neither depends on it: a busy pane, which is independent
# positive evidence, and a DECLARED pause, which is the crew's own statement
# rather than an inference. Every other status-log verb is a stale event this
# script exists to reconcile against the run-step, so with the run-step unread it
# is not a reading and must not be passed off as one.
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind + delivery mode from state/<id>.meta.
#      A kind=ship task whose mode is not no-mistakes (direct-PR, local-only)
#      never starts a no-mistakes run at all, so the lookup in step 2 is skipped
#      for it exactly like it is for kind=scout/secondmate.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history), or the run is still ACTIVE and its head is not
#      an object here at all (a pipeline-owned run's unpushed fix commits - see
#      nm_run_head_matches_worktree). Local work that advanced past the run head,
#      or diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown with the cause that
#      names which. If no run is attributed to this crew, a dead endpoint also
#      reports unknown rather than trusting a stale status log - UNLESS the tool
#      that reads endpoints, or the one that reads run-steps, is not installed or
#      could not be run, in which case the answer is degraded (see above).
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-path-lib.sh
. "$SCRIPT_DIR/fm-nm-path-lib.sh"

# Resolve the run-step reader's own dependency instead of trusting the caller's
# environment for it. Every caller of this script is unattended by nature - the
# watcher, a hook, a reviewer session - and an inherited PATH is exactly what
# they do not have. The call is a no-op wherever the CLI already resolves, so an
# interactive read runs the same binary it always did, and it adds nothing when
# the seat has no install, so the missing-dependency verdict below still fires
# for a genuine absence (bin/fm-nm-path-lib.sh owns both halves).
#
# This is the one deliberate exception to "read-only and side-effect free" above:
# the edit is to this process's own PATH, and is what lets the child that reads
# the run-step exist at all.
fm_nm_ensure_reachable || true

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
TURNEND="$STATE/$ID.turn-ended"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional. Used only for the
# state-carrying answers; the two not-a-reading answers go through the pair below
# so a cause token is structurally impossible to omit.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# The two answers that are not readings. The cause token is a required argument
# rather than an optional field, so a future branch cannot add another way to say
# "no state" without also saying why.
emit_unknown() {  # <cause> <detail>
  printf '%s\n' "state: unknown${SEP}source: none${SEP}cause: $1${SEP}$2"
  exit 0
}
emit_degraded() {  # <source> <cause> <detail>
  printf '%s\n' "state: degraded${SEP}source: $1${SEP}cause: $2${SEP}$3"
  exit 0
}

# Why the authoritative run-step read never produced a reading, set once below.
# READER_CAUSE is the enumerated token, READER_SOURCE the source field it belongs
# under, and READER_WHY the human half naming the specific tool or failure.
READER_CAUSE=
READER_SOURCE=missing-dependency
READER_WHY=

# The one wording for "the authoritative run-step reader could not be used here".
# <because> says which weaker answer was therefore refused, so a supervisor can
# see what was given up rather than only that something was.
emit_reader_degraded() {  # <because>
  emit_degraded "$READER_SOURCE" "$READER_CAUSE" \
    "$READER_WHY: the run-step state was never read and $1"
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit_unknown no-metadata "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship
# Delivery mode (bin/fm-project-mode.sh: no-mistakes|direct-PR|local-only, or
# secondmate for kind=secondmate). Only no-mistakes drives a no-mistakes run;
# direct-PR and local-only push straight to a branch/PR and never create one.
# Absent mode= (older meta, or a lookup ahead of fm-spawn recording it) defaults
# to no-mistakes, matching fm-spawn's own "mode=${MODE:-no-mistakes}" fallback -
# a missing field must not silently start skipping a real run's lookup.
DELIVERY_MODE=$(meta_value mode)
[ -n "$DELIVERY_MODE" ] || DELIVERY_MODE=no-mistakes

# A torn-down (or never-created) worktree has no current state to read. The two
# ways to get here are different facts about the crew record: a meta that never
# named a worktree is malformed, while a meta that names one whose directory is
# gone is an ordinary teardown, and only the second is expected.
if [ -z "$WT" ]; then
  emit_unknown no-worktree-recorded "no worktree recorded in $META"
fi
if [ ! -d "$WT" ]; then
  emit_unknown worktree-gone "worktree gone (torn down?): $WT"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    # Through fm_backend_target_exists, not a raw probe of its own: the inline
    # `tmux display-message -p -t "$1" '#{pane_id}'` this replaced returned 0
    # for a window that does not exist, because display-message answers for
    # another window rather than refusing (fm_tmux_resolve_pane).
    tmux)
      if fm_backend_target_exists tmux "$1"; then
        return 0
      fi
      return 1
      ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_pane_is_busy: the busy-signature fallback, backend-aware the same way -
# fm_backend_busy_state's native semantic state (herdr's agent.get) when
# available, else the shared tmux pane-regex reader (fm_pane_is_busy,
# bin/fm-tmux-lib.sh) unchanged for tmux/unknown.
#
# `busy` alone is trusted outright. Both `idle` and unknown/unparseable fall
# through to the shared tail-regex corroboration, NOT just unknown: herdr's
# agent.get reports generation state ("working" while the model is streaming
# a turn, "done"/"idle" once it is not - docs/herdr-backend.md "Busy state"),
# which is a narrower signal than "this crew's turn/tool call is still in
# progress". A crew blocked on its own long-running foreground tool call (e.g.
# `no-mistakes axi run` without --yes, which blocks synchronously until a gate
# or outcome - the crew-dispatch skill) is not generating for that whole span, so
# agent.get can read idle/blocked (bin/backends/herdr.sh maps both to `idle`)
# while the pane's own rendered text still shows the harness's busy banner
# (BUSY_REGEX, e.g. "esc to interrupt") for the entire tool call, exactly like
# tmux's regex-only reader would correctly report. Trusting herdr's `idle`
# outright (skipping that corroboration) is what let a still-working crew read
# as not-busy here, and - combined with a no-mistakes run-step lookup that also
# missed attribution (see nm_runs_status_for_branch) - as not provably working in
# fm-classify-lib.sh, triggering an immediate (non-wedge) stale wake instead of
# the absorb-then-escalate path. A genuinely human-blocked agent (a permission
# dialog, not mid-tool-call) does not render the busy banner, so this
# corroboration does not mask that case: it stays correctly not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
            | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
          ;;
      esac
      ;;
  esac
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, and it never aborts the
# script - but it does REPORT, which is the whole point. Until 2026-08-04 every
# arm ended in `|| true`, so a missing binary, a binary that exited non-zero, a
# call the timeout killed, a call that was never made at all, and a genuine "no
# run for this branch" all returned the same empty string. The caller could not
# tell a read that did not happen from one that honestly found nothing, which is
# the same defect this whole script exists to remove one level up.
#
# Return codes, distinct from the stdout the caller captures:
#   0                    the call ran and succeeded
#   NM_RUN_RC_FAILED     the call ran and did not succeed
#   NM_RUN_RC_UNBOUNDED  no bounding mechanism exists here, so it was never made
#
# A non-zero exit that still produced stdout is deliberately NOT treated by
# callers as a failed read: the CLI answered. Verified 2026-08-04 against the
# real CLI - `no-mistakes axi status` in a repo with no gate exits 1 and prints
# "error: repo not initialized" on STDOUT, which is a definitive "no run here",
# not a broken instrument. Degrading on the exit code alone would report every
# pre-init worktree in the fleet as unreadable.
NM_RUN_RC_FAILED=1
NM_RUN_RC_UNBOUNDED=3
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  local out='' rc=0
  case "$HAVE_TIMEOUT" in
    timeout)  out=$( ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ) || rc=$? ;;
    gtimeout) out=$( ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ) || rc=$? ;;
    perl)     out=$( ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ) || rc=$? ;;
    *)        return "$NM_RUN_RC_UNBOUNDED" ;;
  esac
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || return "$NM_RUN_RC_FAILED"
  return 0
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha rc=0
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT") || rc=$?
  # Propagated, not swallowed: a coarse lookup that could not run is not the same
  # answer as one that ran and listed no row for this branch.
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    return "$rc"
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      if ! nm_coarse_head_matches_worktree "$sha" "$st"; then
        continue
      fi
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
#
# It is ALSO empty when git itself is unreachable, and those two are different
# facts entirely: one is the crew's shape, the other is this reader's instrument.
# bin/fm-service-path-lib.sh names git as one of the two tools whose absence from
# a service's PATH silently degrades supervision, and an empty CREW_BRANCH is
# exactly how that absence used to disappear - no branch, so no run-step read, so
# `unknown - none` for a crew nobody looked at. GIT_MISSING keeps them apart, so
# detached HEAD keeps its answer while an unreachable git earns the degraded one.
GIT_MISSING=0
command -v git >/dev/null 2>&1 || GIT_MISSING=1
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the run reported by `axi status` is still ACTIVE (no terminal outcome and
# no terminal status word). Used only to decide how much benefit of the doubt an
# unbindable run head gets, below.
nm_run_is_active() {
  local status outcome
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -n "$outcome" ] && return 1
  status=$(strip_quotes "$(nm_field status)")
  case "$status" in
    completed|passed|checks-passed|failed|cancelled) return 1 ;;
    *) return 0 ;;
  esac
}

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rules:
#   - missing/empty head field: cannot bind; reject the run
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip)
#   - run head is a strict ancestor of worktree HEAD: no match (local work
#     advanced outside the run)
#   - run head is not an object in this worktree AT ALL: match while the run is
#     still active, reject once it is terminal. This is the normal mid-run state
#     of a pipeline-owned run: no-mistakes commits its fix rounds in its own
#     working copy and does not push them to the crew's worktree, so the run head
#     is simply an object this repo has not received yet ("fatal: Not a valid
#     object name"), not evidence of a rewritten branch. Rejecting it cost this
#     crew its entire current-state source for the whole validation (verified
#     2026-07-26: run 01KYDF72FZ, branch fm/fm-overlay-hook-truncation-fix,
#     `status: running`, `head: 67d35e35` absent from the worktree, and
#     fm-crew-state.sh answering `unknown - none` for hours while the pipeline
#     was demonstrably in fix round 1). A TERMINAL run with an unbindable head
#     stays rejected: there the head really is the only evidence tying a finished
#     run to this code, and attributing a stale one could report a done/failed
#     state for work the crew has moved past.
#   - diverged (both commits present, neither an ancestor): no match
nm_run_head_matches_worktree() {
  local run_head local_full run_full
  run_head=$(strip_quotes "$(nm_field head)")
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  if ! run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null); then
    nm_run_is_active && return 0
    return 1
  fi
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip), plus the
# same unpushed-pipeline-commit allowance: an unresolvable sha is accepted only
# for a row the runs list still reports as running. <status> is passed in because
# a coarse row carries no other activity evidence.
nm_coarse_head_matches_worktree() {  # <short-sha> <row-status>
  local run_head=$1 row_status=${2:-} local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  if ! run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null); then
    [ "$row_status" = running ] && return 0
    return 1
  fi
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# 1 when the run-step source was SKIPPED because a tool it needs is not on PATH,
# for a crew that would otherwise have been looked up. That is a broken
# instrument, not evidence about the crew, so it is tracked separately from
# HAVE_RUN=0 (which also covers "this crew genuinely has no run") and consumed
# only by the absence branches at the bottom of this script.
#
# Both required tools arm it, because the read fails identically either way: git
# is what turns this worktree into a branch to attribute a run to, and the
# no-mistakes CLI is what answers for that branch. Losing the first is checked
# first precisely because it presents as an empty branch rather than as an error.
READER_MISSING=0
# Why no run was attributed, when none was. Every branch below that ends without
# HAVE_RUN=1 names its own reason, so the catch-all at the bottom of this script
# never has to invent one.
UNKNOWN_CAUSE=no-run-attributed
UNKNOWN_REASON='the run lookup named no run for this crew'
if [ "$KIND" != ship ]; then
  # Scouts and secondmates never drive a no-mistakes validation of their own
  # worktree, so the lookup is skipped for them and state comes from pane/log
  # directly. Nothing failed here, and the cause says so.
  UNKNOWN_CAUSE=kind-skips-run-lookup
  UNKNOWN_REASON="kind=$KIND never drives a run"
elif [ "$DELIVERY_MODE" != no-mistakes ]; then
  # A direct-PR or local-only ship task pushes straight to a branch/PR itself and
  # never starts a no-mistakes run, so there is nothing here to reconcile against -
  # this is a known, answerable shape, not a failed read.
  UNKNOWN_CAUSE=delivery-mode-skips-run-lookup
  UNKNOWN_REASON="mode=$DELIVERY_MODE never drives a run"
elif [ "$GIT_MISSING" = 1 ]; then
  READER_MISSING=1
  READER_CAUSE=run-reader-missing
  READER_SOURCE=missing-dependency
  READER_WHY='git not on PATH'
elif [ -z "$CREW_BRANCH" ]; then
  UNKNOWN_CAUSE=no-branch
  UNKNOWN_REASON='detached HEAD, so no run can be attributed'
elif ! command -v no-mistakes >/dev/null 2>&1; then
  READER_MISSING=1
  READER_CAUSE=run-reader-missing
  READER_SOURCE=missing-dependency
  READER_WHY='no-mistakes CLI not on PATH'
fi
if [ "$KIND" = ship ] && [ "$DELIVERY_MODE" = no-mistakes ] && [ -n "$CREW_BRANCH" ] && [ "$READER_MISSING" = 0 ]; then
  nm_rc=0
  RUN_OUT=$(nm_run axi status) || nm_rc=$?
  if [ "$nm_rc" = "$NM_RUN_RC_UNBOUNDED" ]; then
    # The call was never made at all. This passes a `command -v no-mistakes`
    # pre-check cleanly, which is why the outcome has to come from the call site
    # rather than from a check standing next to it.
    READER_MISSING=1
    READER_CAUSE=no-bounding-mechanism
    READER_SOURCE=missing-dependency
    READER_WHY='no timeout, gtimeout or perl on PATH, so the bounded run-step call was never made'
  elif [ "$nm_rc" != 0 ] && [ -z "$RUN_OUT" ]; then
    READER_MISSING=1
    READER_CAUSE=run-lookup-failed
    READER_SOURCE=read-failed
    READER_WHY='the no-mistakes run lookup ran and returned nothing'
  elif [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      if [ -n "$run_branch" ]; then
        # A run WAS found and this reader refused it. That is materially
        # different from finding no run, because it means the evidence exists
        # and something about its identity did not bind to this crew.
        UNKNOWN_CAUSE=run-attribution-rejected
        UNKNOWN_REASON="a run for $run_branch was found and not attributed to this crew's code identity"
      fi
      coarse_rc=0
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH") || coarse_rc=$?
      if [ "$coarse_rc" != 0 ]; then
        READER_MISSING=1
        READER_CAUSE=run-lookup-failed
        READER_SOURCE=read-failed
        READER_WHY='the no-mistakes runs lookup ran and returned nothing'
      elif [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: captain decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit_unknown no-endpoint-recorded "no backend target recorded"
if ! fm_backend_session_cli_available "$TASK_BACKEND"; then
  emit_degraded missing-dependency endpoint-reader-missing \
    "$TASK_BACKEND CLI not on PATH: endpoint $BACKEND_TARGET cannot be read"
fi
if [ -e "$TURNEND" ]; then
  emit_unknown no-status-after-turn-end "turn-end marker exists but no status event landed: $TURNEND${SEP}$UNKNOWN_REASON"
fi
# An unreadable endpoint means the crew is gone ONLY if the tool that reads
# endpoints is installed. Without it, `fm_backend_capture` fails identically for
# a live crew and a dead one, and answering "gone" would send firstmate into
# stuck-crewmate recovery against a perfectly healthy worker.
if ! pane_readable "$BACKEND_TARGET"; then
  emit_unknown endpoint-unreadable "backend target gone: $BACKEND_TARGET"
fi

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    # A DECLARED pause survives a missing run-step reader: it is the crew's own
    # statement that it is idle on purpose, not an inference this script drew,
    # and the bounded recheck it earns is safe either way. Every other verb here
    # is a stale echo of an event log that this script exists to reconcile
    # against the run-step - and reconciliation is exactly what did not happen.
    if [ "$READER_MISSING" = 1 ] && [ "$LOG_STATE" != paused ]; then
      emit_reader_degraded "its '$LOG_VERB' event was never reconciled against the run"
    fi
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

# Nothing answered. Whether that is a fact about the crew or a fact about this
# machine depends on whether the authoritative reader was even available.
if [ "$READER_MISSING" = 1 ]; then
  emit_reader_degraded "no other source answered either"
fi
# A log line that exists but carries no state verb is the LAST source consulted,
# so it names the cause; an absent log leaves the run-lookup reason standing.
# Only the verb is reported, never the line: a decision-closing event's prose
# must not leak into the detail (see the mapping comment above).
if [ -n "$LOG_LINE" ]; then
  if [ -n "$LOG_VERB" ]; then
    emit_unknown log-verb-not-a-state "the status log's last verb '$LOG_VERB' is not a state${SEP}$UNKNOWN_REASON"
  fi
  emit_unknown log-verb-not-a-state "the status log's last line carries no state verb${SEP}$UNKNOWN_REASON"
fi
emit_unknown "$UNKNOWN_CAUSE" "no current-state source available: $UNKNOWN_REASON"
