#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for the proven-isolated set,
# timing markers, and the complete-regression coverage guard.
#
# --check-coverage is this repository's one zero-drift gate location. It proves
# three derived things, and every file set it compares is derived from the
# directory or the document itself, never from a list kept here by hand:
#   1. the lane partition equals the complete tests/*.test.sh inventory
#   2. docs/scripts.md names every bin/*.sh, once, and nothing that is gone
#   3. every tests/*.test.sh carries a decided family - there is no catch-all
# A second gate location would be a second hand-kept thing, so new derived
# invariants belong here rather than in a new script or a new CI job.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage   (also proves the two derived zero-drift
#                                      guards: the docs/scripts.md index and the
#                                      test-family map)
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the Phase 2 proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list). Cap is 8. Stateful
#                   families never schedule under --jobs.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero or a configured
# --fail-on-gate-skip token appears. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_MAX=8

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

# WHAT EACH FAMILY IS, AND THE QUESTION THAT DECIDES A BORDER CASE
#
# A family is a decision about what a test is ABOUT, so every one below states
# the boundary it claims and the discriminator against the family it is most
# easily confused with. Read this before adding a mapping: if a new test does
# not fit a stated boundary, widen a boundary here on purpose or add a family
# with its own, rather than filing it where it merely fits alphabetically.
#
#   pure-contract-unit   Fixture-driven behavior and contract tests of one
#                        script, library, or instruction surface, needing
#                        nothing but this repository. This is where a test
#                        belongs when its subject is one unit's own contract,
#                        not a subsystem. Not a bucket: it is claimed by a
#                        stated boundary, and a test that needs a live host, an
#                        external source, or a subsystem's shared state fails it.
#   watcher-wake-lock    The supervision loop's own machinery: watcher ticks,
#                        wake queue, delivery, journal, event batching, locks,
#                        turn-end guards, the context ceiling, and the bosun
#                        that observes it. vs service-units: this is what the
#                        loop DOES; service-units is how it is installed and
#                        kept alive. fm-nudge is here rather than with the
#                        currency checks because a periodic subject with its own
#                        record is watcher machinery, whatever it nudges about.
#   service-units        The unit tier around those daemons: backend selection,
#                        consent, convergence, fallback, and reporting. Its
#                        subject is the installation, never the loop's behavior.
#   systemd-live-optin   The one smoke that drives a real `systemd --user` and
#                        is opt-in by env. Separated from service-units so its
#                        expected gate skip (optin-env) is not claimed by three
#                        suites that must actually run in CI: a family carries
#                        one expected-skip class, so a mixed family would lie
#                        about three of its four members.
#   messaging-relay      A message crossing this home's boundary in either
#                        direction, and the seam that carries it: Bridge relay
#                        and inbox, the frequency monitor, direct Telegram send
#                        and receive. vs watcher-wake-lock: the subject is the
#                        message and its transport, not the tick that noticed it.
#   currency-checks      "Has the code or tooling this seat runs been overtaken
#                        by its source?" Every member measures a hop between
#                        what runs here and what exists upstream, and reports a
#                        hop it could not measure. vs external-watches: these
#                        are readings taken on demand or at session start, and
#                        they compare this seat against its own source.
#   external-watches     A cadence watch over a source outside this repository
#                        entirely, keeping its own record of what it has already
#                        surfaced so an unreadable source is never reported as a
#                        quiet one. The record-of-what-was-surfaced is the
#                        discriminator, because that is what makes it a watch
#                        rather than a reading.
#   decision-backlog     The durable backlog and captain-decision store, and the
#                        surfaces that only PRESENT them: board layout, the
#                        board driver, the sea chart, the breakdown filer, the
#                        dependency lint. Nothing here decides anything, which
#                        is why fm-grade is not here: a review-quality scale
#                        judges work, it does not hold a record about work.
#   findings-urgency     The two mechanisms that decide how soon something must
#                        be looked at: the findings surface with its
#                        severity-to-deadline table, and the promoter that
#                        raises an event whose own declaration understates it.
#                        They are one family because both answer "how soon",
#                        not because they share a store - they do not.
#   memory-watch         Anything whose subject is this host's memory headroom:
#                        the attributable reading, the alarm over it, the
#                        ceiling probe, and the live crossing that proves the
#                        alarm fires. vs watcher-wake-lock: the alarm arrives as
#                        an ordinary wake, but its subject is the instrument.
#   real-herdr-gated     Needs a real Herdr binary. Lane-significant: the
#                        portable lanes exclude it and a dedicated required lane
#                        owns it, so this is the one family a mapping must never
#                        be guessed into.
#   live-harness-optin   Needs a live agent harness and is opt-in by env.
#   secondmate           Secondmate homes, their lifecycle, their inherited
#                        material, and the parent-side guards on what they
#                        return.
#   session-bootstrap    Session start, bootstrap sweeps, fleet sync, self
#                        update, and the tangle and gate refusals around them.
#   backend-dispatch     Choosing and launching a worker: backends, dispatch
#                        profiles, spawn, and the send path into a pane.
#   pr-forge             Work leaving this repository: review diffs, PR checks,
#                        merges, teardown, X mode, and the PR-body workflow.
#   afk                  Away mode and its return.
#   snapshot-bearings    The read-only fleet snapshot and its projections.
#   cmux                 One optional backend binary.
#   zellij               One optional backend binary.
#   orca                 One optional backend binary.
#
# Primary family for one tests/*.test.sh basename, or empty output when the
# basename is not mapped. There is deliberately no catch-all: an unmapped
# tests/*.test.sh is a gap in this map that someone must close, run_coverage_guard
# fails on it by name, and family_for_script refuses to run it.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-axi-tool-intake.test.sh|fm-brief.test.sh|\
    fm-calm-pi-extension.test.sh|fm-captain-translation-contract.test.sh|\
    fm-cd-pretool-check.test.sh|fm-codebase-sweep.test.sh|\
    fm-design-it-twice.test.sh|fm-scout-research.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-continuity-pretool-check.test.sh|fm-crew-state.test.sh|\
    fm-decision-hold-lifecycle.test.sh|fm-deploy-verify.test.sh|\
    fm-dispatch-select.test.sh|fm-ensure-agents-md.test.sh|fm-grade.test.sh|\
    fm-grok-harness.test.sh|fm-grossreinschiff.test.sh|\
    fm-herdr-lab.test.sh|fm-instruction-owners.test.sh|fm-landing-remote-lib.test.sh|\
    fm-lint.test.sh|fm-lock.test.sh|\
    fm-install-herdr.test.sh|fm-model-panel.test.sh|fm-nm-test-contract.test.sh|\
    fm-no-mistakes-ownership.test.sh|\
    fm-operational-input.test.sh|fm-pdf-output.test.sh|fm-pi-primary-types.test.sh|\
    fm-private-material-ignore.test.sh|fm-project-remove.test.sh|\
    fm-role-config.test.sh|fm-run-reader-reach.test.sh|fm-runtime-ignore.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|fm-slot-guard.test.sh|\
    fm-stow-contract.test.sh|fm-subagent-pretool-check.test.sh|\
    fm-supervision-cost.test.sh|fm-supervision-instructions.test.sh|\
    fm-test-lib.test.sh|fm-tmux-submit-busy.test.sh|\
    fm-tmux-target-resolve.test.sh|fm-transcript-archive.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-bosun.test.sh|fm-context-reset.test.sh|fm-daemon.test.sh|\
    fm-delivery.test.sh|fm-event-batch.test.sh|fm-guard-stale-banner.test.sh|\
    fm-journal.test.sh|fm-nudge.test.sh|fm-retry-episode.test.sh|\
    fm-seat-keeper.test.sh|\
    fm-seat-respawner.test.sh|fm-supervision-events.test.sh|\
    fm-turnend-guard.test.sh|\
    fm-wake-daemon-lifecycle-e2e.test.sh|fm-wake-queue.test.sh|\
    fm-watch-run-bounded.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-pending-reply.test.sh|fm-secondmate-harness.test.sh|\
    fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-bootstrap.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-lavish-access.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-tangle-guard.test.sh|\
    fm-update.test.sh|fm-vessel-identity.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|fm-claude-continuity-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-send-strict.test.sh|fm-spawn-batch.test.sh|fm-spawn-brief-off-argv.test.sh|\
    fm-spawn-dispatch-profile.test.sh|\
    fm-spawn-worktree-settle.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh|no-mistakes-required-workflow.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-snapshot.test.sh|fm-fleet-snapshot-argv-limit.test.sh|\
    fm-fleet-snapshot-view.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backlog-lint.test.sh|fm-board.test.sh|fm-decision-inventory.test.sh|\
    fm-decision-ledger.test.sh|fm-run-decisionboard.test.sh|fm-sea-chart.test.sh|\
    fm-to-backlog.test.sh)
      printf '%s\n' decision-backlog
      ;;
    fm-axi-suite.test.sh|fm-currency-round.test.sh|fm-firstmate-update-check.test.sh|\
    fm-fleet-update-check.test.sh|fm-self-drift.test.sh|\
    fm-upstream-distance.test.sh)
      printf '%s\n' currency-checks
      ;;
    fm-forge-status.test.sh|fm-github-inbox.test.sh)
      printf '%s\n' external-watches
      ;;
    fm-memory-alarm.test.sh|fm-memory-alarm-crossing-e2e.test.sh|\
    fm-memory-ceiling-probe.test.sh|fm-memory-reading.test.sh)
      printf '%s\n' memory-watch
      ;;
    fm-finding-drain.test.sh|fm-finding-surface.test.sh|fm-urgency.test.sh)
      printf '%s\n' findings-urgency
      ;;
    fm-bridge-relay.test.sh|fm-frequency-monitor.test.sh|fm-tg-recv-arm.test.sh|\
    fm-tg-recv-route.test.sh|fm-tg-send.test.sh|fm-watch-bridge-inbox.test.sh)
      printf '%s\n' messaging-relay
      ;;
    fm-bosun-service.test.sh|fm-frequency-monitor-service.test.sh|\
    fm-watcher-service.test.sh)
      printf '%s\n' service-units
      ;;
    fm-watcher-systemd-smoke.test.sh)
      printf '%s\n' systemd-live-optin
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    *)
      ;;
  esac
}

# True when the path names one of this repository's own test scripts. Only those
# are in the inventory the family map must cover.
is_repo_test_path() {
  case "$1" in
    tests/*.test.sh) [ -f "$ROOT/$1" ] ;;
    "$ROOT"/tests/*.test.sh) [ -f "$1" ] ;;
    *) return 1 ;;
  esac
}

# Family for one selected script path. A repository test with no family is a gap
# someone must close, so this refuses rather than bucketing it. A script from
# outside tests/ - an ad-hoc fixture handed to the runner directly - is ad-hoc,
# which is not a family any --family or lane selection can reach.
family_for_script() {
  local p=$1 fam
  if ! is_repo_test_path "$p"; then
    printf '%s\n' ad-hoc
    return 0
  fi
  fam=$(family_for_basename "$(basename "$p")")
  if [ -n "$fam" ]; then
    printf '%s\n' "$fam"
    return 0
  fi
  die "no test family for $(basename "$p"): add it to family_for_basename in bin/fm-test-run.sh (there is no catch-all family)"
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin|systemd-live-optin) printf '%s\n' optin-env ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

# Every family a tests/*.test.sh can carry. ad-hoc is deliberately absent: it
# belongs only to scripts outside this inventory, so no selection may reach it.
list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
decision-backlog
currency-checks
external-watches
memory-watch
findings-urgency
messaging-relay
service-units
systemd-live-optin
cmux
zellij
orca
EOF
}

list_known_lanes() {
  cat <<'EOF'
portable-parallel-1
portable-parallel-2
portable-serial
real-herdr-gated
EOF
}

# Exact Phase 2 proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-dispatch-select.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-stow-contract.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using
# Phase 1 serial duration averages from CI timing artifacts on main after
# #825/#832/#834 (docs/fm-test-portable-shards.md). Execution order is longest
# first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-pr-merge.test.sh
tests/fm-test-run.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-dispatch-select.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-transition-lib.test.sh
tests/fm-composer-lib.test.sh
tests/fm-stow-contract.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-x-mode.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-crew-state.test.sh
tests/fm-grok-harness.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-send-strict.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-send-settle.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
EOF
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s fam found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      # Everything in the complete suite that is not proven-isolated and not
      # real-herdr-gated. Watcher/lock/AFK/tmux/daemon/ambiguous/stateful work
      # stays here, serial only.
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        fam=$(family_for_script "$s")
        if [ "$fam" = "real-herdr-gated" ]; then
          continue
        fi
        if is_proven_isolated_script "$s"; then
          continue
        fi
        add_script "$s"
        found=1
      done < <(all_repo_tests)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

# Every bin/*.sh, derived from the directory itself. A hand-kept enumeration
# here would be the very drift this guard exists to catch.
list_bin_scripts() {
  local f
  for f in "$ROOT"/bin/*.sh; do
    [ -f "$f" ] || continue
    basename "$f"
  done | LC_ALL=C sort
}

# Every script named in the first column of docs/scripts.md's index table,
# derived from the table itself for the same reason.
list_indexed_scripts() {
  # The backticks are Markdown table syntax, not command substitution.
  # shellcheck disable=SC2016
  sed -n 's/^| *`\([^`]*\)`.*/\1/p' "$ROOT/docs/scripts.md"
}

# docs/scripts.md must name every bin/*.sh, must not name a file that is gone,
# and must name each one once.
run_script_index_guard() {
  local tmp missing stale dups entry rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-script-index.XXXXXX")

  list_bin_scripts >"$tmp/scripts"
  list_indexed_scripts | LC_ALL=C sort >"$tmp/indexed_raw"
  LC_ALL=C sort -u "$tmp/indexed_raw" >"$tmp/indexed"
  LC_ALL=C grep '\.sh$' "$tmp/indexed" >"$tmp/indexed_sh" || true

  dups=$(LC_ALL=C uniq -d "$tmp/indexed_raw" || true)
  if [ -n "$dups" ]; then
    log "script index guard: docs/scripts.md names a script more than once:"
    printf '%s\n' "$dups" >&2
    rc=1
  fi

  missing=$(LC_ALL=C comm -23 "$tmp/scripts" "$tmp/indexed_sh" || true)
  if [ -n "$missing" ]; then
    log "script index guard: every bin/*.sh must have a row in docs/scripts.md; these have none:"
    printf '%s\n' "$missing" >&2
    rc=1
  fi

  stale=
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -e "$ROOT/bin/$entry" ] && continue
    stale="${stale}${entry}
"
  done <"$tmp/indexed"
  if [ -n "$stale" ]; then
    log "script index guard: docs/scripts.md names files that are not in bin/:"
    printf '%s' "$stale" >&2
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'FM_SCRIPT_INDEX ok scripts=%s indexed=%s\n' \
      "$(wc -l <"$tmp/scripts" | tr -d ' ')" \
      "$(wc -l <"$tmp/indexed" | tr -d ' ')"
  fi
  rm -rf "$tmp"
  return "$rc"
}

# Every tests/*.test.sh must carry a decided family, and every family must state
# the boundary it claims. There is no catch-all to fall into, so this names every
# gap at once rather than dying on the first.
run_family_guard() {
  local s fam boundaries unmapped='' undocumented=''
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -n "$(family_for_basename "$(basename "$s")")" ] && continue
    unmapped="${unmapped}${s}
"
  done < <(all_repo_tests)
  if [ -n "$unmapped" ]; then
    log "family guard: every tests/*.test.sh must map to a family in family_for_basename (there is no catch-all); these do not:"
    printf '%s' "$unmapped" >&2
    return 1
  fi

  # A classification someone has to live with is only defensible while its
  # reasoning is present, so the boundary block above family_for_basename must
  # name every family the map can produce. Undocumented is the same defect one
  # layer up: a decision nobody wrote down.
  boundaries=$(sed -n '/^# WHAT EACH FAMILY IS/,/^family_for_basename() {/p' \
    "$ROOT/bin/fm-test-run.sh")
  while IFS= read -r fam; do
    [ -n "$fam" ] || continue
    printf '%s\n' "$boundaries" | grep -Eq "^#   ${fam}[[:space:]]" && continue
    undocumented="${undocumented}${fam}
"
  done < <(list_known_families)
  if [ -n "$undocumented" ]; then
    log "family guard: every family must state its boundary in the block above family_for_basename; these state none:"
    printf '%s' "$undocumented" >&2
    return 1
  fi
  printf 'FM_TEST_FAMILIES ok total=%s families=%s\n' \
    "$(all_repo_tests | wc -l | tr -d ' ')" \
    "$(list_known_families | wc -l | tr -d ' ')"
  return 0
}

run_coverage_guard() {
  local tmp missing extra a b
  local -a saved_scripts=()
  local rc=0

  # The two derived zero-drift guards run first: the family guard names every
  # unmapped test at once, which the lane selections below could not do because
  # family_for_script refuses on the first one it meets.
  run_script_index_guard || rc=1
  run_family_guard || rc=1
  [ "$rc" -eq 0 ] || return 1

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(LC_ALL=C comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(LC_ALL=C comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial + Herdr lane listings without disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    LC_ALL=C comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(LC_ALL=C comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(LC_ALL=C comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      LC_ALL=C comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s herdr=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    fam=$(family_for_script "$s")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/fm-board-behavior.test.mjs)
      # Not a suite entry of its own: tests/fm-board.test.sh drives it.
      printf '%s\n' "__script__:fm-board.test.sh"
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-classify-lib.sh)
      printf '%s\n' watcher-wake-lock
      # The status-event vocabulary also backs bin/fm-model-panel.sh's judge
      # gate, whose test lives in the pure-contract-unit family.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      # bin/fm-bridge-relay.sh matches this script's supervision alarms line by
      # line to tell them apart from fleet-sync's diagnosis and relay them to the
      # caller, so a reword here must re-run the relay's own suite; its basename
      # family (watcher-wake-lock) would never select it from this path.
      printf '%s\n' "__script_required__:fm-bridge-relay.test.sh"
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-delivery*|bin/fm-seat-respawner.sh|\
    bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-pane-activity-lib.sh)
      printf '%s\n' watcher-wake-lock
      # The pre-typing pane reads are shared with the away daemon, and the
      # delivery listener's health predicate is read by the session-start digest.
      printf '%s\n' afk
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-seat-stay-down.sh|bin/fm-seat-respawner-service.sh)
      printf '%s\n' service-units
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-secondmate*|bin/fm-home-seed.sh|bin/fm-backlog-handoff.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*)
      printf '%s\n' secondmate
      ;;
    bin/fm-fleet-sync.sh)
      printf '%s\n' session-bootstrap
      # bin/fm-bridge-relay.sh classifies this script's per-project outcome
      # vocabulary to decide whether a Bridge read may answer at all, so a reword
      # here must re-run the relay's own suite; its basename family
      # (messaging-relay) would never select it from this path.
      printf '%s\n' "__script_required__:fm-bridge-relay.test.sh"
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-tg-correspondent-lib.sh)
      printf '%s\n' "__script_required__:fm-tg-recv-route.test.sh"
      printf '%s\n' "__script_required__:fm-tg-send.test.sh"
      ;;
    bin/fm-tg-recv-route.sh)
      printf '%s\n' "__script_required__:fm-tg-recv-route.test.sh"
      ;;
    bin/fm-tg-send.sh)
      printf '%s\n' "__script_required__:fm-tg-send.test.sh"
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-dispatch-select.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-blocker-class-lib.sh)
      # The one owner of "is a blocked-by target real", spliced into the fleet
      # snapshot, bearings, sea chart, and backlog lint. Its tests do not name this
      # file by basename, so the grep resolution the bin/* fallthrough uses cannot
      # find them: select every reader explicitly instead.
      printf '%s\n' snapshot-bearings
      printf '%s\n' "__script_required__:fm-sea-chart.test.sh"
      printf '%s\n' "__script_required__:fm-backlog-lint.test.sh"
      ;;
    bin/fm-finding*.sh)
      # The findings surface's record contract lives in bin/fm-finding-lib.sh,
      # which no test names by path, so the bin/* grep fallthrough below cannot
      # find its reader. Name the suites explicitly. Both are selected for any
      # of the three scripts, because the drain rule and the emit path share
      # that one record contract and a change to it can break either side.
      printf '%s\n' "__script_required__:fm-finding-surface.test.sh"
      printf '%s\n' "__script_required__:fm-finding-drain.test.sh"
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|bin/fm-model-panel.sh|\
    bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-axi-path-lib.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    .agents/skills/*|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    .gitignore)
      # Every suite that asserts against the tracked .gitignore; this arm is the
      # single owner of that list, so a new dependent belongs here too, and
      # tests/fm-test-run.test.sh fails when one is missing. __script_required__
      # names a script this map promises exists, unlike the __script__ entries
      # derived from a changed path, which may name a file the change deleted.
      printf '%s\n' "__script_required__:fm-runtime-ignore.test.sh"
      printf '%s\n' "__script_required__:fm-private-material-ignore.test.sh"
      printf '%s\n' "__script_required__:fm-model-panel.test.sh"
      printf '%s\n' "__script_required__:fm-role-config.test.sh"
      printf '%s\n' "__script_required__:fm-secondmate-sync.test.sh"
      printf '%s\n' "__script_required__:fm-test-lib.test.sh"
      ;;
    tests/lib.sh|tests/*-helpers.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    docs/examples/*)
      # Worked examples are load-bearing test input, not prose: fm-board.test.sh
      # builds them and pins what they must still contain.
      printf '%s\n' "__script__:fm-board.test.sh"
      ;;
    README.md|LICENSE|assets/*|docs/*)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()
  local -a required_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script_required__:*)
          required_scripts+=("${entry#__script_required__:}")
          ;;
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      fam=$(family_for_script "$s")
      if [ "$fam" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  # A changed path may name a script the change itself deleted or renamed, so a
  # miss here is normal and stays silent.
  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  for script_name in "${required_scripts[@]+"${required_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    else
      die "changed-test map names a test script that does not exist: tests/$script_name (update the map in families_for_changed_path or restore the suite)"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_script "$s")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
if [ "$JOBS" -gt 1 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
trap 'rm -rf "$RUN_TMP"' EXIT

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local family expected gate_skip fail_delta
  family=$(family_for_script "$script")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

run_one_serial() {
  local script=$1
  local family expected out begin_iso begin_ms end_ms end_iso duration rc
  family=$(family_for_script "$script")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  # PIPESTATUS[0] is the test script; tee's exit is ignored for aggregate.
  bash "$script" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for proven-isolated scripts only. Each worker
  # gets a private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are
  # never used as a green strategy.
  declare -a WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    set -e
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done < <(jobs -r -p)
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${SCRIPTS[@]}"; do
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    family=$(family_for_script "$script")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1
      rc=$?
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    WORKER_PIDS[worker_n]=$!
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
