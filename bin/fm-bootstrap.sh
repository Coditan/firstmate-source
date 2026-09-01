#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "FORGE_CLIENT: <what is wrong with this home's Forgejo client, or what could not be established about it>",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "ROLE_INVALID: <name> (known: <names>)",
#                 "ROLE_OVERLAY_MISSING: <name> (expected: roles/<name>.md)",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "CURRENCY_BASE: config/<file> is unusable - <reason>; <remediation>",
#                 "LAVISH_ACCESS: <N> open review board link(s) still point at this machine only ...",
#                 "BACKLOG_STALE: task <id> has <fault>; fix: <command>",
#                 "BACKLOG_UNREADABLE: task <id> in <backlog file> is parsed by <reader> but not <reader>; fix: <row repair>",
#                 "DECISION_LEDGER: <class> <id> - <what is unfinished about that captain decision record>",
#                 "DECISION_LEDGER: baseline recorded|absent|rejected - <what the adoption baseline covers or refuses>",
#                 "DECISION_LEDGER: and <n> more not shown here; run bin/fm-decision-ledger.sh --audit for the full list",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "FLEET_SYNC: fleet: STUCK: cannot read the project registry <path>: <cause> ...",
#                 "FLEET_SYNC: fleet: STUCK: cannot list the projects directory <path>: <cause> ...",
#                 "FLEET_SYNC: fleet: refresh failed (exit <rc>); <what the outcomes above cover>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "SELF_DRIFT: primary checkout default branch '<branch>' is <N> ahead, <M> behind origin/<branch> (<state>) - needs attention",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed: <reason>",
#                 "AXI_SUITE_UPDATED|REVIEW|STUCK|SHADOWED|SHADOW_UNKNOWN: <detail>",
#                 "FIRSTMATE_UPDATE_AVAILABLE|STUCK: <detail>",
#                 "GROSSREINSCHIFF: weekly fleet cleanup sweep is due (...)",
#                 "CURRENCY_ROUND: the daily update check <is not armed|has stopped> (...)",
#                 "MEMORY_ALARM: <nothing is watching this machine|the memory watch ... has stopped> (...)",
#                 "GITHUB_INBOX: the GitHub notification watch ... has stopped (...)",
#                 "FORGE_STATUS: the forge status watch could not be armed on this home (...)",
#                 "SLOT_GUARD: the worktree-ownership watch could not be armed on this home (...)",
#                 "CURATION_NUDGE|CODEBASE_SWEEP_NUDGE: <not armed|could not be armed|scheduler refusal|state persistence failure|state health indeterminate|supervision outage> (...)",
#                 "FMX: X mode on ..." or "FMX: X mode off ...",
#                 "WATCHER_UNIT: <consent, convergence, or fallback detail>",
#                 "DELIVERY_UNIT: <consent, convergence, or fallback detail>",
#                 "TELEGRAM_RECEIVER_UNIT: <consent, convergence, or fallback detail>",
#                 "FREQUENCY_MONITOR_UNIT: <consent, convergence, or fallback detail>",
#                 "RESPAWNER_UNIT: <consent, convergence, or health detail>",
#                 "BOSUN_UNIT: <consent, convergence, judge-reach, or health detail>",
#                 "RUN_READER: no-mistakes runs in this session (<path>) but a
#                 context that inherits no shell setup cannot reach it (...)",
#                 "VALIDATION_DAEMON: the validation pipeline daemon is not
#                 running (...)" or "VALIDATION_DAEMON: whether the validation
#                 pipeline daemon is running is unestablished - <reason> (...)".
#          When a RUNNING secondmate worktree is fast-forwarded to firstmate's
#          own current default-branch commit (a purely LOCAL fast-forward, never
#          an origin fetch) AND its loaded instruction surface (AGENTS.md, bin/,
#          roles/, or .agents/skills/) actually changed, bootstrap immediately
#          nudges it via FM_HOME=<active-home> bin/fm-send.sh fm-<id> so meta
#          resolves the current backend target and the standard from-firstmate
#          marker is applied. A successful send prints one BOOTSTRAP_INFO line
#          with the exact target and message sent; a failed send leaves an
#          idempotent retry marker under state/.secondmate-nudge-pending/ and
#          prints an actionable NUDGE_SECONDMATES line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inherited local material
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs or
#          inheritance failures for live secondmate homes, plus quarantine
#          diagnostics for divergent shared captain-preference copies;
#          no-op/current and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report only actionable failures from the
#          deeper agent-liveness verdict (bin/fm-backend.sh's
#          fm_backend_agent_alive, distinct from endpoint pane-presence):
#          skipped means the probe could not confidently classify the endpoint,
#          and respawn failed means relaunch did not complete. Already-live and
#          successfully respawned secondmates are silent.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          A SELF_DRIFT line means that checkout's default branch differs from its
#          own origin; the check fetches origin without advancing any local branch,
#          is bounded by FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT (default 10s), and silently
#          skips missing origins, off-default branches, and fetch failures/timeouts.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). tasks-axi is also version and feature gated (0.1.1+
#          with update --archive-body and mv [<id>...]); an installed but
#          incompatible build reports MISSING like no-mistakes. A compatible
#          tasks-axi default backend is silent. quota-axi is required because
#          every crew-dispatch profile array calls it automatically;
#          fm-dispatch-select.sh still uses OS-backed random selection across
#          valid candidates when quota data is unavailable.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the eight MUTATING sweeps
#          (PR-check migration, fm-currency-round.sh --arm,
#          fm-memory-alarm.sh --arm, fm-axi-suite.sh,
#          secondmate_sync, secondmate_liveness_sweep, x_mode_setup, fleet_sync)
#          while still printing every read-only detect line above; the TANGLE line
#          switches to advisory-only wording with no checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, secondmate homes, X-mode artifacts, project
#          clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-absence-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-absence-lib.sh"
# shellcheck source=bin/fm-axi-path-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-axi-path-lib.sh"
fm_axi_prepend_path "$FM_HOME"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-currency-base-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-currency-base-lib.sh"
# shellcheck source=bin/fm-role-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-nm-path-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-nm-path-lib.sh"
# shellcheck source=bin/fm-service-path-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-service-path-lib.sh"
# Sourced for fm_pr_configured_forgejo_host alone: the Forgejo client is
# required only where this home names an instance, and that resolution has one
# owner rather than a second copy of it here.
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Resolve the no-mistakes CLI here too, so bootstrap's version and compatibility
# reads are about the binary an unattended reader will actually run rather than
# about whatever the launching shell reached. No-op where the CLI already
# resolves (bin/fm-nm-path-lib.sh).
fm_nm_ensure_reachable || true

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync_path_may_speak() {  # <path>: false only when this path is provably absent
  [ -e "$1" ] || [ -L "$1" ] || fm_absence_unprovable "$1" >/dev/null
}

fleet_sync() {
  local rc
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  # A home that genuinely keeps no clones and registers no projects must still cost
  # nothing here. Every other reading falls through: a path that is PRESENT as
  # anything at all, a dangling symlink, and a path whose absence this process cannot
  # establish are all readings fm-fleet-sync.sh refuses on, and returning 0 on any of
  # them would swallow that refusal and hand the session start the same silence a
  # home with nothing to sync produces. Only a provable absence skips, because only
  # that one is an answer - and it has to be provable for BOTH paths that reader
  # speaks about, since it refuses on the registry before it ever walks the clones.
  fleet_sync_path_may_speak "$PROJECTS" \
    || fleet_sync_path_may_speak "$DATA/projects.md" \
    || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  # A REFRESH THAT DID NOT COMPLETE IS NOT A REFRESH. This status was thrown away,
  # so a sync that stopped without producing a per-project line - the shape a home
  # that cannot read its own project registry takes - reached a session start as
  # silence, which reads exactly like a fleet with nothing to say.
  [ "$rc" -eq 0 ] \
    || echo "FLEET_SYNC: fleet: refresh failed (exit $rc); the outcomes above are only what it managed before stopping"
  rm -f "$tmp"
}

self_drift_bootstrap_timeout() {
  case "${FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT:-}" in
    ''|*[!0-9]*) echo 10 ;;
    *) echo "$FM_SELF_DRIFT_BOOTSTRAP_TIMEOUT" ;;
  esac
}

# Detect drift between the primary checkout's checked-out default branch and its
# own origin. Fetch is bounded and best-effort; this never advances a local
# branch, checks out a ref, or reports an off-default TANGLE state twice.
self_drift_check() {
  local default current base timeout monitor_was_on pid start elapsed fetch_ok
  local ahead behind state

  git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1 || return 0
  default=$(fm_default_branch "$FM_ROOT" 2>/dev/null) || return 0
  current=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$default" ] || return 0

  timeout=$(self_drift_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  git -C "$FM_ROOT" fetch origin --prune --quiet >/dev/null 2>&1 &
  pid=$!
  start=$SECONDS
  fetch_ok=1
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fetch_ok=0
      break
    fi
    sleep 1
  done
  if [ "$fetch_ok" -eq 1 ] && ! wait "$pid" 2>/dev/null; then
    fetch_ok=0
  fi
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  [ "$fetch_ok" -eq 1 ] || return 0

  # Recheck after the network wait so a concurrent branch switch cannot turn
  # this into a duplicate or stale off-default diagnostic.
  current=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$default" ] || return 0
  base="origin/$default"
  git -C "$FM_ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null || return 0
  ahead=$(git -C "$FM_ROOT" rev-list --count "$base..$default" 2>/dev/null) || return 0
  behind=$(git -C "$FM_ROOT" rev-list --count "$default..$base" 2>/dev/null) || return 0
  [ "$ahead" -ne 0 ] || [ "$behind" -ne 0 ] || return 0

  if git -C "$FM_ROOT" merge-base --is-ancestor "$default" "$base" 2>/dev/null; then
    state=behind
  elif git -C "$FM_ROOT" merge-base --is-ancestor "$base" "$default" 2>/dev/null; then
    state=ahead
  else
    state=diverged
  fi
  echo "SELF_DRIFT: primary checkout default branch '$default' is $ahead ahead, $behind behind $base ($state) - needs attention"
}

secondmate_sync() {
  # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Startup sends reread nudges only
  # for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, roles/,
  # or .agents/skills/) actually changed, so a secondmate already on the
  # primary's version is never disturbed (AGENTS.md bootstrap + supervision).
  # Unlike /updatefirstmate, startup owns the live-convergence send itself
  # because it is a deterministic locked sweep and can report success as
  # BOOTSTRAP_INFO while preserving failed sends as NUDGE_SECONDMATES retry
  # markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE='firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.secondmate-nudge-pending"

  secondmate_nudge_marker_path() {
    case "$1" in
      *[!/A-Za-z0-9._-]*|""|*/*) return 1 ;;
    esac
    printf '%s/%s.pending' "$SECOND_MATE_NUDGE_PENDING_DIR" "$1"
  }

  secondmate_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker tmp parent
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || return 1
    parent=${marker%/*}
    mkdir -p "$parent" || return 1
    tmp=$(mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
    {
      printf 'id=%s\n' "$id"
      printf 'selector=%s\n' "$selector"
      printf 'home=%s\n' "$home"
      printf 'commit=%s\n' "$commit"
      printf 'instructions=%s\n' "$instr"
      printf 'message=%s\n' "$SECOND_MATE_NUDGE_MESSAGE"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  }

  secondmate_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || {
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: unsafe id"
      return 0
    }
    if ! secondmate_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    secondmate_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  secondmate_retry_pending_nudges() {
    local marker id selector home commit message expected_marker meta meta_home home_real head
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(fm_meta_get "$marker" id)
      if ! expected_marker=$(secondmate_nudge_marker_path "$id"); then
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(fm_meta_get "$marker" selector)
      home=$(fm_meta_get "$marker" home)
      commit=$(fm_meta_get "$marker" commit)
      message=$(fm_meta_get "$marker" message)
      [ "$selector" = "fm-$id" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker message mismatch"
        continue
      }
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry target has no live secondmate metadata"
        continue
      }
      meta_home=$(fm_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
      if ! validate_secondmate_home "$id" "$meta_home"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  secondmate_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes "$DATA/secondmates.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SECONDMATES:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f fm_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live secondmate home swept above.
  # FF_SEEN_HOMES is exactly that set, and fm-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  local id home home_real propagated_homes
  propagated_homes=""
  while IFS='|' read -r id home _window _meta; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    if ! propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
    fi
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  return 0
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. A
  # secondmate agent that has exited leaves its backend endpoint alive as a
  # bare shell; the session-start digest's "endpoint: alive" read
  # (fm_backend_target_exists, pane-PRESENCE only) reports that shell as
  # alive, so recovery never respawns it, and the watcher deliberately exempts
  # secondmates from stale-pane detection (an idle secondmate pane is healthy
  # by design). Evidence 2026-07-07: every secondmate in this fleet was found
  # as a dead zsh shell, invisible to every existing check. This sweep closes
  # the gap deterministically: for every LIVE secondmate meta (kind=secondmate
  # with a recorded window=), run the deeper fm_backend_agent_alive probe
  # (bin/fm-backend.sh) and act only on a CONFIDENT verdict:
  #   alive   - no-op.
  #   dead    - kill the stale endpoint first (best-effort; the tmux adapter
  #             refuses to create a same-named window over a live one) then
  #             respawn via the existing recovery path (bin/fm-spawn.sh <id>
  #             --secondmate; secondmate-provisioning).
  #   unknown - NEVER acted on. A false-dead reading would spin up a DUPLICATE
  #             agent (two supervisors in one home); a false-alive reading
  #             merely leaves today's bug unfixed for one more sweep. The
  #             worse direction is guarded by never treating anything less
  #             than a confident dead reading as license to respawn.
  # A meta with no recorded window= at all is left to the existing "meta with
  # no window" recovery path (AGENTS.md section 5 / secondmate-provisioning);
  # there is no endpoint here for this probe to read.
  # Naturally scoped to the primary: a secondmate's own state/ never holds
  # kind=secondmate metas (secondmates never spawn secondmates), so this
  # sweep is a silent no-op there, exactly like secondmate_sync above.
  # Scope: session start (reboot/restart) only. A secondmate dying
  # MID-SESSION is a harder follow-on needing a periodic liveness beacon -
  # explicitly out of scope here.
  [ -d "$STATE" ] || return 0
  local meta id window harness backend target verdict out
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(fm_meta_get "$meta" harness)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict="unknown"
    case "$harness" in
      claude|codex|opencode|pi|grok) ;;
      *) [ "$verdict" = dead ] && verdict=unknown ;;
    esac
    case "$verdict" in
      alive)
        ;;
      dead)
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
          :
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed: $(first_line "$out")"
        fi
        ;;
      *)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: liveness probe inconclusive (backend=$backend)"
        ;;
    esac
  done
  return 0
}

# The npm prefix whose bin directory the validation pipeline's daemon already
# reaches, given that daemon's own PATH. $HOME/.local is preferred because it is
# the conventional user bin directory and the one that daemon PATH leads with on
# the seat this was measured against; otherwise the first $HOME-rooted bin
# directory it names.
#
# Fails where there is no HOME or the measured PATH names no user-owned bin
# directory, because an install outside that PATH would not repair daemon reach.
path_contains_dir() {  # <path> <directory>
  local path=$1 wanted=$2 dir
  local IFS=:
  for dir in $path; do
    [ "$dir" = "$wanted" ] && return 0
  done
  return 1
}

forgejo_client_prefix() {  # [daemon-path] [session-path]
  local path=${1-} session_path=${2-} dir common
  [ -n "${HOME:-}" ] || return 1
  for common in yes no; do
    if path_contains_dir "$path" "${HOME%/}/.local/bin" &&
      { [ "$common" = no ] || path_contains_dir "$session_path" "${HOME%/}/.local/bin"; }; then
      printf '%s\n' "${HOME%/}/.local"
      return 0
    fi
    local IFS=:
    for dir in $path; do
      case "$dir" in
        "${HOME%/}"/*/bin|"${HOME%/}"/bin) ;;
        *) continue ;;
      esac
      [ "$common" = no ] || path_contains_dir "$session_path" "$dir" || continue
      printf '%s\n' "${dir%/bin}"
      return 0
    done
  done
  return 1
}

install_cmd() {
  local prefix tool_bin
  prefix=$(fm_axi_prefix "$FM_HOME")
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi)
      # The tool is named, not absolute, so its hook installer records a
      # PATH-portable command in the shared user-global harness config instead
      # of this home's private path (docs/configuration.md "AXI-suite
      # self-update").
      tool_bin=$(fm_axi_bin_dir "$FM_HOME")
      printf 'npm install -g --prefix %q %q && PATH=%q:%s %q setup hooks\n' "$prefix" "$1" "$tool_bin" "\$PATH" "$1"
      ;;
    tasks-axi|quota-axi) printf 'npm install -g --prefix %q %q\n' "$prefix" "$1" ;;
    forgejo-axi)
      # NOT the vessel prefix, and deliberately NOT a member of
      # FM_AXI_SUITE_TOOLS. Two reasons, and they point the same way.
      #
      # The vessel prefix is per-home by design, and the process that has to run
      # this client besides a session is the validation pipeline's daemon - one
      # shared unit serving every lane and home on the host, whose PATH reaches
      # no vessel prefix at all. A per-home copy therefore cannot be the thing
      # the pipeline runs, so the install goes where the daemon already looks
      # and one copy serves both (forgejo_client_prefix below).
      #
      # The suite boundary auto-installs patch and minor releases on a cadence,
      # and this is a third party's package rather than the kunchenguid suite,
      # so entering that boundary is a supply-chain decision the captain owns
      # (docs/forgejo-axi-adoption.md). The repair here is a one-time install.
      #
      # The version range is a literal this script owns, so it is single-quoted
      # rather than %q-escaped: %q renders the caret as \^, which pastes and
      # runs correctly but reads like a typo in a line the captain is asked to
      # trust.
      prefix=$(forgejo_client_prefix "$(fm_nm_daemon_path 2>/dev/null || true)" "${PATH:-}") || return 1
      printf "npm install -g --prefix %q 'forgejo-axi@^%s.%s.%s' && PATH=%q:%s %q setup hooks\n" \
        "$prefix" "$FORGEJO_AXI_MIN_MAJOR" "$FORGEJO_AXI_MIN_MINOR" "$FORGEJO_AXI_MIN_PATCH" \
        "$prefix/bin" "\$PATH" forgejo-axi
      ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
# A third, narrower route sits below in forgejo_client_check: a requirement keyed
# to a configured forge instance rather than to a backend.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN_MAJOR=1
NO_MISTAKES_MIN_MINOR=31
NO_MISTAKES_MIN_PATCH=2
# The Forgejo client is the fleet's third declaration route, and the only
# conditional one that is not keyed to a runtime backend: a forge client is not
# a backend, and requiring it universally would print a missing-tool line on
# every seat for a tool nothing there calls. It is required exactly where this
# home names a Forgejo instance, which is the same signal bin/fm-pr-lib.sh
# already resolves an address against (docs/configuration.md "Forge instance").
#
# The floor covers TWO verb surfaces, because two processes run this client and
# the larger surface is not the fleet's own. The fleet's scripts need the field
# selector, pull-request-URL addressing, and per-row check and review state,
# which is what makes the floor 1.3.0. The validation pipeline additionally
# drives status, pr find, pr create, pr update, pr checks, pr mergeability,
# pr merged and run view --log-failed; all nine of its invocations were run
# against 1.3.0 with the flag shapes it uses before this floor was set, rather
# than assumed from the fleet's own half. Coverage was checked three ways, not
# one: every one of the nine accepts the connection flags the pipeline appends
# to all of them, and the two response fields whose ABSENCE would decode to a
# dangerous zero value rather than fail loudly - status's capabilities.probe
# .complete and pr find's search_info.complete - were both read back from a live
# host at this floor.
# docs/forgejo-axi-adoption.md owns that evidence, the maintenance risk this
# dependency carries, and the one thing a version floor cannot cover: nothing
# upstream pins the JSON shape the pipeline decodes.
FORGEJO_AXI_MIN_MAJOR=1
FORGEJO_AXI_MIN_MINOR=3
FORGEJO_AXI_MIN_PATCH=0

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

no_mistakes_version_parts() {
  local output
  command -v no-mistakes >/dev/null 2>&1 || return 1
  output=$(no-mistakes --version 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1
}

no_mistakes_compatible() {  # [already-read version parts]
  local parts major minor patch extra
  if [ "$#" -gt 0 ]; then parts=$1; else parts=$(no_mistakes_version_parts) || return 1; fi
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  [ "$major" -gt "$NO_MISTAKES_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NO_MISTAKES_MIN_MAJOR" ] || return 1
  [ "$minor" -gt "$NO_MISTAKES_MIN_MINOR" ] && return 0
  [ "$minor" -eq "$NO_MISTAKES_MIN_MINOR" ] || return 1
  [ "$patch" -ge "$NO_MISTAKES_MIN_PATCH" ]
}

forgejo_axi_version_parts() {  # <executable>
  local output
  output=$("$1" --version 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1
}

forgejo_axi_compatible() {  # <executable>
  local parts major minor patch extra
  parts=$(forgejo_axi_version_parts "$1") || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  [ "$major" -gt "$FORGEJO_AXI_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$FORGEJO_AXI_MIN_MAJOR" ] || return 1
  [ "$minor" -gt "$FORGEJO_AXI_MIN_MINOR" ] && return 0
  [ "$minor" -eq "$FORGEJO_AXI_MIN_MINOR" ] || return 1
  [ "$patch" -ge "$FORGEJO_AXI_MIN_PATCH" ]
}

forgejo_client_install_repair() {  # <daemon-path>
  local daemon_path=$1 repair prefix bin
  repair=$(install_cmd forgejo-axi) || return 1
  prefix=$(forgejo_client_prefix "$daemon_path" "${PATH:-}") || return 1
  bin=$prefix/bin
  printf '%s' "$repair"
  if ! path_contains_dir "${PATH:-}" "$bin"; then
    printf '; also make %s reachable from an agent session\047s PATH' "$bin"
  fi
}

# One requirement, one check, one line: a Forgejo client that BOTH a session and
# the validation pipeline can run, at or above the floor.
#
# It does not report MISSING:, and that is deliberate rather than a naming
# choice. MISSING: everywhere else means `command -v` says no, and here
# `command -v` can say yes while the requirement still fails - the pipeline runs
# the client from its daemon's PATH, which reaches no vessel prefix and no npm
# global prefix (bin/fm-nm-path-lib.sh's fm_nm_daemon_path records the
# measurement). Reusing MISSING: would send the reader to check the one thing
# that cannot settle it.
#
# The version is read from the executable the PIPELINE would run, not from
# whatever this session resolves, so two copies at different versions cannot
# report the newer one and run the older.
#
# A home that names no Forgejo instance prints nothing at all, so seats that
# never touch the forge pay no diagnostic for a tool they never call.
forgejo_client_check() {
  local host daemon_path resolved session_resolved version repair
  host=$(fm_pr_configured_forgejo_host 2>/dev/null) || return 0
  [ -n "$host" ] || return 0
  if ! daemon_path=$(fm_nm_daemon_path 2>/dev/null); then
    resolved=$(command -v forgejo-axi 2>/dev/null)
    if [ -z "$resolved" ]; then
      echo "FORGE_CLIENT: this seat cannot read the validation pipeline daemon's environment, so whether the pipeline can run forgejo-axi is unestablished; this session resolves no forgejo-axi"
      return 0
    fi
    version=$("$resolved" --version 2>/dev/null | head -n 1)
    if forgejo_axi_compatible "$resolved"; then
      echo "FORGE_CLIENT: this seat cannot read the validation pipeline daemon's environment, so whether the pipeline can run forgejo-axi is unestablished; this session resolves $resolved at '${version:-no version}', which meets the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH floor"
    else
      echo "FORGE_CLIENT: this seat cannot read the validation pipeline daemon's environment, so whether the pipeline can run forgejo-axi is unestablished; this session resolves $resolved at '${version:-no version}', which does not meet the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH floor"
    fi
    return 0
  fi
  resolved=$(PATH="$daemon_path" command -v forgejo-axi 2>/dev/null)
  if [ -z "$resolved" ]; then
    if repair=$(forgejo_client_install_repair "$daemon_path"); then
      echo "FORGE_CLIENT: forgejo-axi is not installed where both this session and the validation pipeline can run it, and $host is this home's forge (install: $repair)"
    else
      echo "FORGE_CLIENT: forgejo-axi is not installed where both this session and the validation pipeline can run it, and $host is this home's forge; the pipeline daemon's PATH names no user-owned directory this fleet can install into, so the daemon's own PATH must change"
    fi
    return 0
  fi
  if ! forgejo_axi_compatible "$resolved"; then
    version=$("$resolved" --version 2>/dev/null | head -n 1)
    if repair=$(forgejo_client_install_repair "$daemon_path"); then
      echo "FORGE_CLIENT: forgejo-axi at $resolved reports '${version:-no version}', below the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH (install: $repair)"
    else
      echo "FORGE_CLIENT: forgejo-axi at $resolved reports '${version:-no version}', below the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH; the pipeline daemon's PATH names no user-owned directory this fleet can install into, so the daemon's own PATH must change"
    fi
    return 0
  fi
  session_resolved=$(command -v forgejo-axi 2>/dev/null)
  if [ -z "$session_resolved" ]; then
    echo "FORGE_CLIENT: forgejo-axi at $resolved meets the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH floor for the validation pipeline, but this session resolves no forgejo-axi"
    return 0
  fi
  if [ "$session_resolved" != "$resolved" ]; then
    echo "FORGE_CLIENT: forgejo-axi at $resolved meets the required $FORGEJO_AXI_MIN_MAJOR.$FORGEJO_AXI_MIN_MINOR.$FORGEJO_AXI_MIN_PATCH floor for the validation pipeline, but this session resolves a different copy at $session_resolved"
    return 0
  fi
}

# Startup assertion for the run-state reader's dependency.
#
# `command -v no-mistakes` in this session answers a DIFFERENT question - whether
# the operator can run it - and that answer stayed true through every week of the
# 2026-08 blindness while the watcher, the hooks and every reviewer session read
# nothing (bin/fm-nm-path-lib.sh). The question worth asking at startup is
# whether a context that inherits no shell setup would reach it, so this one is
# asked against the PATH such a context starts with rather than against ours.
#
# FM_SERVICE_PATH_BASE_DEFAULT is that PATH: systemd's user-manager default, and
# the LEAST reach any unattended shape has, so a line here means every unattended
# shape is blind, not just the strictest one.
#
# Absence is not this check's to report. When nothing anywhere resolves the CLI,
# the MISSING: line above already owns it and the repair is to install it; what
# this adds is the sentence MISSING: cannot say - that the CLI runs here and the
# reader still cannot reach it, which no version or installation check can see.
#
# FM_RUN_READER_CHECK_DISABLE exists for the same reason the currency-round and
# Grossreinschiff ones do: every behavior suite that composes bootstrap runs with
# a FAKE no-mistakes in a fixture PATH and a real HOME, so the honest answer for
# a fixture is "unreachable" and would print this line under every unrelated
# assertion. tests/lib.sh disables it suite-wide and
# tests/fm-run-reader-reach.test.sh sets it back to 0, which is the only place the
# check is actually exercised.
run_reader_reach_check() {
  local resolved bin repair
  [ "${FM_RUN_READER_CHECK_DISABLE:-0}" != 1 ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  fm_nm_reaches "${FM_SERVICE_PATH_BASE:-$FM_SERVICE_PATH_BASE_DEFAULT}" && return 0
  resolved=$(command -v no-mistakes 2>/dev/null || echo unknown)
  # The second repair sentence is only reachable with no HOME and no explicit
  # override, which is an environment that cannot name its own install directory.
  if bin=$(fm_nm_bin_dir 2>/dev/null); then
    repair="install or link the CLI at $bin/no-mistakes, or export NO_MISTAKES_INSTALL_DIR to the directory holding it"
  else
    repair="this environment has no HOME to derive an install directory from - export NO_MISTAKES_INSTALL_DIR to the directory holding the CLI"
  fi
  echo "RUN_READER: no-mistakes runs in this session ($resolved) but a context that inherits no shell setup cannot reach it, so crew run-state reads from the watcher, hooks and reviewer sessions answer 'degraded - run-reader-missing' instead of the real state (repair: $repair)"
}

# The forbidden neighbour of the repair, spelled once. Every line this check can
# print names it, and two spellings of one rule leave a reader deciding which is
# current (docs/validation-daemon.md owns why the update path is barred).
VALIDATION_DAEMON_NOT_UPDATE='never no-mistakes update, which resets the daemon as part of a version change and would carry that change into parked runs'
# What an unreadable answer asks for: a reading taken by hand BEFORE any action,
# because every unreadable case is one where acting on the guess is the hazard.
VALIDATION_DAEMON_REPAIR="take the reading by hand with no-mistakes daemon status, and if it is down bring it back with no-mistakes daemon start - $VALIDATION_DAEMON_NOT_UPDATE"

validation_daemon_upgrade_repair() {
  echo "upgrade the CLI first with $(install_cmd no-mistakes), and take the reading once it answers on a supported version - $VALIDATION_DAEMON_NOT_UPDATE"
}

validation_daemon_unestablished() {
  echo "VALIDATION_DAEMON: whether the validation pipeline daemon is running is unestablished - $1 - so this is not an all-clear; ${2:-$VALIDATION_DAEMON_REPAIR}"
}

# Startup assertion for the validation pipeline daemon.
#
# Why it is a check and not a habit (measured on the coditan vessel, 2026-08-30):
# a seat restart killed every crewmate AND the no-mistakes daemon. The crewmates
# were visible - each pane sat at a bare shell prompt - and the daemon was
# visible nowhere:
#
#   connect to daemon socket: dial unix /home/coditan/.no-mistakes/socket: connect: connection refused
#   recorded pid 3223240 no longer exists
#
# Four parked runs were unanswerable for about forty minutes with no status
# line, no diagnostic, no wake and no failing command, and it surfaced only when
# a relaunched worker tried to answer its own review gate. NOTHING on a seat
# touches the daemon until something needs it, so a seat with no gate work in
# flight carries a dead one indefinitely and reads perfectly healthy - the exact
# shape no amount of care detects and one reading does.
#
# DETECT ONLY, deliberately, and not by analogy to the arming steps below. Those
# arm per-HOME mechanisms under this home's own session lock; this daemon is
# per-ACCOUNT - one socket under $HOME serving every firstmate home and
# secondmate on the account - so the lock that guards them does not cover it.
# Two homes can hold their own locks at the same moment and both act, and a home
# holding its own lock has established nothing about its siblings - the daemon
# process carries no home identity in its environment at all, so no home can even
# enumerate them.
#
# The narrower argument rules out the smallest autonomy too: "start only when it
# is provably absent" is exactly the reading a WEDGED socket gets wrong, and an
# auto-start there puts a second process against the same root while parked runs
# sit inside the first. The escalation from "not answering" to a start is the
# whole hazard, so this check does not make it. The action goes to the reader,
# who can see whether anything is running; docs/validation-daemon.md records the
# measurements this rests on, including the sibling-home one this seat could not
# take itself.
#
# Every home on the account prints this line, and that duplication is correct:
# each of them really is impaired, so it is not a fleet-level fact reported N
# times the way an unread GitHub thread would be. The line names the ACCOUNT and
# never a number of homes, because no home can count its siblings.
#
# The answer is read from the OUTPUT, not the exit status: v1.48.0 exits 0 for
# both "daemon running (pid N)" and "daemon not running", including with a stale
# pid file recording a dead process. Anything else is an unreadable instrument
# rather than a verdict, because guessing healthy hides a dead daemon and
# guessing dead sends a reader to restart a live one.
#
# A version that refuses the verb outright is the same class one band higher, and
# it is read from the REFUSAL rather than inferred from a number, because when
# the daemon verbs were introduced is a fact this fleet cannot establish for a
# tool it does not own. That refusal reaches stderr on the measured CLI, so
# stderr is captured separately and consulted only after stdout has failed to
# yield a verdict - merging it would put the tool's own update banner inside the
# text the healthy and down verdicts are matched against.
#
# Absence is not this check's to report: MISSING: already owns an uninstalled
# CLI, and its repair is to install it rather than to start a daemon. A CLI that
# IS installed but whose version does not clear the floor is the opposite case
# and does print here: it cannot be asked, and silence about an instrument that
# cannot read is the all-clear this check exists to remove. That path names the
# upgrade as its repair, because neither daemon verb can succeed until the
# upgrade lands, and it says which of the two things it established - that the
# version is below the floor, or that no version could be read at all - because
# a version this seat never read is not a version it may report.
#
# FM_VALIDATION_DAEMON_CHECK_DISABLE exists for the same reason the
# currency-round and run-reader ones do: every behavior suite that composes
# bootstrap runs with a FAKE no-mistakes, whose daemon answer is meaningless, so
# the line would print under every unrelated assertion. tests/lib.sh disables it
# suite-wide and tests/fm-validation-daemon-check.test.sh sets it back to 0.
validation_daemon_check() {  # [already-read version parts]
  local timeout_bin out err rc=0 seconds version_reason parts err_file
  [ "${FM_VALIDATION_DAEMON_CHECK_DISABLE:-0}" != 1 ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  if [ "$#" -gt 0 ]; then parts=$1; else parts=$(no_mistakes_version_parts 2>/dev/null) || parts=; fi
  if ! no_mistakes_compatible "$parts"; then
    if [ -n "$parts" ]; then
      version_reason="the installed no-mistakes is below the version floor this fleet requires, so it cannot be asked"
    else
      version_reason="no-mistakes --version answered with no version this check could read, so whether the installed CLI meets the floor this fleet requires is itself unestablished and it cannot be asked"
    fi
    validation_daemon_unestablished "$version_reason" "$(validation_daemon_upgrade_repair)"
    return 0
  fi
  seconds=${FM_VALIDATION_DAEMON_TIMEOUT:-5}
  case "$seconds" in ''|*[!0-9]*) seconds=5 ;; esac
  [ "$seconds" -gt 0 ] 2>/dev/null || seconds=5
  timeout_bin=
  if [ "${FM_VALIDATION_DAEMON_FORCE_UNBOUNDED:-0}" != 1 ]; then
    if command -v timeout >/dev/null 2>&1; then timeout_bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then timeout_bin=gtimeout
    fi
  fi
  if [ -z "$timeout_bin" ]; then
    validation_daemon_unestablished "this seat has neither timeout nor gtimeout to bound the call, and asking unbounded would hang session start behind a wedged daemon"
    return 0
  fi
  err=
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-validation-daemon.XXXXXX" 2>/dev/null) || err_file=
  if [ -n "$err_file" ]; then
    out=$("$timeout_bin" "$seconds" no-mistakes daemon status 2>"$err_file") || rc=$?
    err=$(cat "$err_file" 2>/dev/null) || err=
    rm -f -- "$err_file"
  else
    out=$("$timeout_bin" "$seconds" no-mistakes daemon status 2>/dev/null) || rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    validation_daemon_unestablished "it did not answer within ${seconds}s, which is a wedged daemon rather than a dead one"
    return 0
  fi
  case "$out" in
    *"daemon not running"*)
      echo "VALIDATION_DAEMON: the validation pipeline daemon is not running, so every parked review on this account is unanswerable until it is back and nothing else on this seat will say so (repair: no-mistakes daemon start - $VALIDATION_DAEMON_NOT_UPDATE)"
      return 0
      ;;
    *"not running"*|*"no daemon running"*) ;;
    *"daemon running (pid"*) return 0 ;;
  esac
  case "$out$err" in
    *"unknown command "*|*"unknown subcommand"*|*"Available Commands:"*)
      validation_daemon_unestablished \
        "the installed no-mistakes refused daemon status as a command it does not have, so this version cannot be asked" \
        "$(validation_daemon_upgrade_repair)"
      return 0
      ;;
  esac
  validation_daemon_unestablished "no-mistakes daemon status answered in a shape this check does not recognise (exit $rc), and this fleet does not own that tool's output"
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - sets FM_CHECK_INTERVAL=30, loaded by the watcher
#                            service so only an X instance polls at 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts.
# The watcher-service bootstrap step immediately after this function converges
# a running process against any cadence transition.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; watcher service convergence applies the default cadence"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  shim_body=$(fmx_poll_shim_content "$FM_HOME" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$FM_HOME" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Loaded by the watcher service so fm-watch.sh polls the X check every 30s.
# Non-X instances have no such file and keep the default 300s cadence.
FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

# Detect-only: an instruction-surface comparison base that is configured but
# unusable. Without this the captain would not learn about a bad base until the
# next daily currency round wrote its own STUCK file.
currency_base_validate() {
  local item status
  item=$FM_CURRENCY_BASE_UPDATE_ITEM
  fm_currency_base_file_value "$CONFIG" "$item"
  status=$?
  # 0 is a usable value and 2 is an absent file; only 1 is actionable.
  [ "$status" -eq 1 ] || return 0
  echo "CURRENCY_BASE: config/$item is unusable - $FM_CURRENCY_BASE_REASON; fix it or remove the file to compare against $FM_CURRENCY_BASE_DEFAULT"
}

# Detect-only: this vessel is still handing the captain review-board links that
# open nothing on his own devices. The whole point of bin/fm-lavish.sh is that
# this failure is silent - a loopback board looks correct on the machine that
# made it - so without a startup check it regresses unnoticed, which it already
# did once while the fix sat queued.
#
# Deliberately ordered cheap-first: the session stores are plain file reads, and
# the address resolver only runs once a loopback link has actually been found.
# A host with no tailnet is honestly limited rather than regressed, so it is
# silent.
lavish_access_check() {
  local loopback found=0 reach shared
  command -v jq >/dev/null 2>&1 || return 0
  # This home's own store, written by bin/fm-lavish.sh. Everything in it belongs
  # to this home, so no attribution filter is needed.
  if [ -r "$STATE/lavish/state.json" ]; then
    loopback=$(jq -r '
      [ (.sessions // {}) | to_entries[]
        | select(.value.status != "ended")
        | .value.url // ""
        | select(test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])[:/]"))
      ] | length' "$STATE/lavish/state.json" 2>/dev/null) || loopback=
    case "${loopback:-}" in
      ''|*[!0-9]*) ;;
      *) found=$((found + loopback)) ;;
    esac
  fi
  # lavish-axi's default store, which is where a bypass lands. It is shared by
  # every home of one UNIX account, so a session counts only when its board file
  # lives under THIS home - otherwise a parent and its secondmate would both
  # report the same boards, and an unrelated home's boards would be blamed here.
  shared="$HOME/.lavish-axi/state.json"
  if [ -r "$shared" ] && [ "$shared" != "$STATE/lavish/state.json" ]; then
    loopback=$(FM_HOME_PREFIX="$FM_HOME/" jq -r '
      ($ENV.FM_HOME_PREFIX) as $home
      | [ (.sessions // {}) | to_entries[]
          | select(.value.status != "ended")
          | select((.value.file // "") | startswith($home))
          | .value.url // ""
          | select(test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])[:/]"))
        ] | length' "$shared" 2>/dev/null) || loopback=
    case "${loopback:-}" in
      ''|*[!0-9]*) ;;
      *) found=$((found + loopback)) ;;
    esac
  fi
  [ "$found" -gt 0 ] || return 0
  reach=$("$SCRIPT_DIR/fm-service-port.sh" lavish --check 2>/dev/null \
    | sed -n 's/^reachability=\(.*\)$/\1/p' | head -1)
  [ "$reach" = tailnet ] || return 0
  echo "LAVISH_ACCESS: $found open review board link(s) still point at this machine only and will not open on the captain's devices; reopen them with bin/fm-lavish.sh"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","grok"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    case "$t" in
      watcher-unit)
        echo "installing watcher-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-watcher-service.sh" install-unit || exit 1
        continue
        ;;
      watcher-linger)
        echo "installing watcher-linger: loginctl enable-linger for the current user"
        "$SCRIPT_DIR/fm-watcher-service.sh" enable-linger || exit 1
        continue
        ;;
      delivery-unit)
        echo "installing delivery-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-delivery-service.sh" install-unit || exit 1
        continue
        ;;
      telegram-receiver-unit)
        echo "installing telegram-receiver-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-tg-recv-service.sh" install-unit || exit 1
        continue
        ;;
      seat-respawner-unit)
        echo "installing seat-respawner-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-seat-respawner-service.sh" install-unit || exit 1
        continue
        ;;
      frequency-monitor-unit)
        echo "installing frequency-monitor-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-frequency-monitor-service.sh" install-unit || exit 1
        continue
        ;;
      bosun-unit)
        echo "installing bosun-unit: systemd user template plus this home's enabled instance"
        "$SCRIPT_DIR/fm-bosun-service.sh" install-unit || exit 1
        continue
        ;;
    esac
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
fi

if [ "$BACKEND_VALID" -eq 0 ]; then
  echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
fi
# Vessel role: a selected role that cannot be delivered must be loud here, not a
# silent unamended session. An absent config/role resolves to the default and
# prints nothing at all, so a home that never opted in sees no new line.
ROLE=$(fm_role_value "$CONFIG")
if ! fm_role_is_known "$ROLE"; then
  echo "ROLE_INVALID: $ROLE (known: $FM_ROLE_KNOWN)"
elif ROLE_OVERLAY=$(fm_role_overlay_path "$FM_ROOT" "$ROLE") && [ ! -f "$ROLE_OVERLAY" ]; then
  echo "ROLE_OVERLAY_MISSING: $ROLE (expected: roles/$ROLE.md)"
fi
for t in $BACKEND_TOOLS; do
  fm_backend_required_tool_available "$BACKEND" "$t" \
    || missing_tool_diagnostic "$t"
done
for t in $COMMON_TOOLS; do
  command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
done
# The treehouse lease-support upgrade check is only relevant when the resolved
# backend actually requires treehouse (every backend except orca, which owns its
# own worktrees); an orca home must not be told to upgrade a provider it never uses.
if fm_backend_list_contains "$TOOLS" treehouse \
  && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
# One reading of an immutable fact, shared by the two checks that need it: the
# MISSING: gate below and validation_daemon_check. Both distinguish a version
# that parsed from one that did not, so the empty case is passed through rather
# than collapsed.
NO_MISTAKES_VERSION_PARTS=$(no_mistakes_version_parts 2>/dev/null) || NO_MISTAKES_VERSION_PARTS=
if command -v no-mistakes >/dev/null 2>&1 \
  && ! no_mistakes_compatible "$NO_MISTAKES_VERSION_PARTS"; then
  echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
fi
run_reader_reach_check
validation_daemon_check "$NO_MISTAKES_VERSION_PARTS"
if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
  echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
fi
forgejo_client_check
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
else
  self_drift_check
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
  echo "BOOTSTRAP_INFO: crew harness override active: $crew"
fi
crew_dispatch_validate
currency_base_validate
lavish_access_check
# Weekly Grossreinschiff cadence. Detect-only by construction - one file read and
# one date comparison - so it runs in every session start, locked or not, and
# needs no scheduler of its own (docs/grossreinschiff.md "The cadence decision").
"$SCRIPT_DIR/fm-grossreinschiff-due.sh" || true
if fm_tasks_axi_compatible && command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-backlog-lint.sh" || true
fi
# A captain decision record that was started and never finished is invisible by
# nature: the question leaves the open surfaces while the answer never lands. The
# recovery-point case on 2026-08-17 sat in exactly that state with nothing detecting
# it, which is why this is a detect-only bootstrap step rather than something a
# session is expected to remember to run. No network, one pass over two local
# files, and it reads no fleet state. The one thing it writes is its own scratch
# memo under state/ (state/.decision-ledger-memo, via a temp file and a rename, so
# a concurrent reader sees one whole memo or the other), which is what lets the
# digest's settled list later in this same session start reuse this read instead of
# walking every record a second time. That memo is not fleet state, so it stays
# safe on the lock-refused path: the mutating steps the read-only banner promises
# to skip are the fleet-mutating sweeps, not a private cache this home rewrites
# from its own records.
if command -v jq >/dev/null 2>&1; then
  # Exit 1 means findings; 0 is clean and stays silent, and anything else is an
  # environment fault this step declines to turn into a false alarm.
  decision_rc=0
  decision_audit=$("$SCRIPT_DIR/fm-decision-ledger.sh" --audit 2>/dev/null) || decision_rc=$?
  if [ "$decision_rc" -eq 1 ] && [ -n "$decision_audit" ]; then
    # BOUNDED, AND THE REMAINDER IS STATED. This home's audit stood at 58 findings
    # the day the check was written, and a startup digest that opens with dozens of
    # identical demands is one nobody finishes reading - which would cost exactly the
    # attention this whole mechanism is trying to buy. The adoption baseline in
    # bin/fm-decision-ledger.sh is what makes that number small; this cap is the
    # backstop for a home that has not taken one yet, and it never hides the count.
    decision_max=${FM_DECISION_LEDGER_MAX:-12}
    decision_total=$(printf '%s\n' "$decision_audit" | wc -l | tr -d ' ')
    printf '%s\n' "$decision_audit" | head -n "$decision_max" | sed 's/^/DECISION_LEDGER: /'
    if [ "$decision_total" -gt "$decision_max" ]; then
      printf 'DECISION_LEDGER: and %s more not shown here; run bin/fm-decision-ledger.sh --audit for the full list\n' \
        "$((decision_total - decision_max))"
    fi
    unset decision_max decision_total
  fi
  unset decision_audit decision_rc
fi
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
  && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "BOOTSTRAP_INFO: tasks-axi available"
fi
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # Arm this home's daily currency round. Arming is a bootstrap step rather than
  # an install instruction because an instruction a home must remember to follow
  # is the defect the round exists to remove: a home that never armed it would
  # silently never check. Idempotent, so it converges on every session start.
  if ! "$SCRIPT_DIR/fm-currency-round.sh" --arm >/dev/null 2>&1; then
    echo "CURRENCY_ROUND: the daily update check could not be armed on this home, so nothing will watch for updates between sessions; run $SCRIPT_DIR/fm-currency-round.sh --arm to see why"
  fi
  # Arm this home's memory alarm, for the same reason and on the same terms: an
  # alarm a home must remember to arm is one that is not watching.
  if ! "$SCRIPT_DIR/fm-memory-alarm.sh" --arm >/dev/null 2>&1; then
    echo "MEMORY_ALARM: the memory watch could not be armed on this home, so nothing will notice RAM-headroom loss, runaway growth, or memory stall held past the window; run $SCRIPT_DIR/fm-memory-alarm.sh --arm to see why"
  fi
  # Arm this home's off-grid fleet nudges, for the same reason and on the same
  # terms: AGENTS.md already said to prune data/learnings.md and data/captain.md
  # rather than append, and to sweep a repository before it takes a large amount
  # of agent work, and a rule with no mechanism is carried by memory. This is
  # that mechanism. One shim serves every registered subject, so a subject added
  # upstream starts being scheduled on the next session start with no second
  # arming path to keep in step.
  if ! "$SCRIPT_DIR/fm-nudge.sh" --arm >/dev/null 2>&1; then
    echo "CURATION_NUDGE: the fleet nudges could not be armed on this home, so nothing will re-measure this vessel's learnings and captain files between sessions; run $SCRIPT_DIR/fm-nudge.sh --arm to see why"
    echo "CODEBASE_SWEEP_NUDGE: the fleet nudges could not be armed on this home, so nothing will ask this vessel to re-measure its own repositories between sessions; run $SCRIPT_DIR/fm-nudge.sh --arm to see why"
  fi
  # Arm this home's forge status watch on the same seam. Until it existed, an
  # outage at the forge reached this fleet only when a supervisor walked into
  # it, and live workers had to be warned by hand that a red check was not
  # their own defect.
  if ! "$SCRIPT_DIR/fm-forge-status.sh" --arm >/dev/null 2>&1; then
    echo "FORGE_STATUS: the forge status watch could not be armed on this home, so nothing will notice a forge outage between sessions; run $SCRIPT_DIR/fm-forge-status.sh --arm to see why"
  fi
  # Arm this home's pooled-worktree ownership watch. Same reason again, and the
  # sharpest case for it: a pooled slot whose task record has gone stale is
  # invisible until a cleanup returns it and kills whoever was handed it since.
  if ! "$SCRIPT_DIR/fm-slot-guard.sh" --arm >/dev/null 2>&1; then
    echo "SLOT_GUARD: the worktree-ownership watch could not be armed on this home, so nothing will notice a pooled worktree two tasks both claim; run $SCRIPT_DIR/fm-slot-guard.sh --arm to see why"
  fi
  "$SCRIPT_DIR/fm-axi-suite.sh"
  # The suite may have just seeded this home's own copies into $FM_HOME/.local/axi;
  # drop the cached lookups so the sweeps below resolve the vessel copy, not the
  # external one this shell already hashed.
  hash -r
  secondmate_sync
  secondmate_liveness_sweep
  x_mode_setup
  if [ "${FM_TEST_SKIP_WATCHER_SERVICE:-0}" != 1 ]; then
    "$SCRIPT_DIR/fm-watcher-service.sh" bootstrap
    "$SCRIPT_DIR/fm-delivery-service.sh" bootstrap
    "$SCRIPT_DIR/fm-tg-recv-service.sh" bootstrap
    "$SCRIPT_DIR/fm-seat-respawner-service.sh" bootstrap
    "$SCRIPT_DIR/fm-frequency-monitor-service.sh" bootstrap
    "$SCRIPT_DIR/fm-bosun-service.sh" bootstrap
  fi
  fleet_sync
else
  if [ "${FM_TEST_SKIP_WATCHER_SERVICE:-0}" != 1 ]; then
    "$SCRIPT_DIR/fm-watcher-service.sh" bootstrap
    "$SCRIPT_DIR/fm-delivery-service.sh" bootstrap
    "$SCRIPT_DIR/fm-tg-recv-service.sh" bootstrap
    "$SCRIPT_DIR/fm-seat-respawner-service.sh" bootstrap
    "$SCRIPT_DIR/fm-frequency-monitor-service.sh" bootstrap
    "$SCRIPT_DIR/fm-bosun-service.sh" bootstrap
  fi
fi
# Is the daily currency round still running? One file read and one comparison,
# so it runs in every session start, locked or not. This is the reading that
# catches a home whose monitoring has stopped: without it, a home that quietly
# stopped checking is indistinguishable from a home with nothing to report.
"$SCRIPT_DIR/fm-currency-round.sh" --armed || true
# And the same question of the memory alarm: armed once is not running now.
"$SCRIPT_DIR/fm-memory-alarm.sh" --armed || true
# And of the GitHub notification watch, which is deliberately asked ONLY here and
# never armed here: several homes draining one notification feed would each
# surface the same threads separately, so arming it is a per-home decision
# (docs/github-inbox.md). This says nothing on a home that never armed it, and
# speaks only when a home that did has stopped reading.
"$SCRIPT_DIR/fm-github-inbox.sh" --armed || true
# And of each fleet nudge subject, which answers it from what the work produced
# - that subject's last firing and next scheduled sweep - rather than from the
# check's own claim to be armed, because a timer's own surfaces report health
# long after it died.
"$SCRIPT_DIR/fm-nudge.sh" --armed || true
# And of the forge status watch, on the same terms: an armed watch that nothing
# executes leaves the forge unwatched while every surface still looks fine.
"$SCRIPT_DIR/fm-forge-status.sh" --armed || true
# And of the worktree-ownership watch: a slot two tasks both claim is silent
# until the cleanup that destroys someone's work, so a watch that stopped is a
# fact this home needs stated rather than inferred from an absence of findings.
"$SCRIPT_DIR/fm-slot-guard.sh" --armed || true
[ -f "$STATE/firstmate-update.available" ] && cat "$STATE/firstmate-update.available"
[ -f "$STATE/firstmate-update.stuck" ] && cat "$STATE/firstmate-update.stuck"
exit 0
