#!/usr/bin/env bash
# Run this home's daily currency round, and make a missed one loud.
#
# WHAT THIS IS FOR
# Firstmate is the fleet's update authority and checks daily at minimum. That
# duty had no mechanism: session start is not daily, and a session here has run
# for two days, so the duty was carried by memory. This script is the trigger
# that survives session boundaries. It decides in bash whether anything is
# actually wrong and prints one line only when a human judgement is required,
# because a surfaced notification costs roughly 171,000 fresh tokens on this
# fleet while a mechanical poll costs about 207 (docs/supervision-cost.md).
#
# It never updates anything. It measures, records, and reports.
#
# HOPS: WHICH CLAIM OF CURRENCY THIS ROUND CAN MAKE
# A change reaching a running vessel is three separate acts, and a report that
# does not say which one it means is worse than no report:
#   released   the change is on the default branch of the source this
#              deployment updates from.
#   pinned     the fleet pin names a commit that contains it.
#   installed  this seat's own checkout has advanced to that pin.
# This round measures the released and installed hops FOR THIS SEAT ONLY. It
# does not measure the pin hop and it never speaks for another vessel: the pin
# is the fleet repository's own measurement, and per-vessel install status is
# the fleet dashboard's install view (fleet-install-status.v1). A silent round
# here therefore means "this seat has nothing to decide", never "the fleet is
# current", and every report states that in the file it writes.
#
# READINGS
# Each reading names its subject, its hop, its state, and the reference it was
# measured against. A reading is ok, behind, blocked, unmeasured, or skipped.
# unmeasured is a first-class outcome: an instrument that cannot read must not
# report an all-clear, which is the whole defect that produced a vessel calling
# itself current while two releases behind.
#   instruction-surface  released   bin/fm-firstmate-update-check.sh, which had
#                                   been written but scheduled by nothing, so
#                                   its marker was never produced and bootstrap
#                                   printed nothing - indistinguishable from
#                                   current. This round is its cadence.
#   fork-absorption      released   bin/fm-fork-sync-check.sh, only on a home
#                                   configured as the fork curator by the
#                                   presence of config/fork-sync-upstream. A
#                                   non-curator home is skipped by name rather
#                                   than compared against an upstream it does
#                                   not curate.
#   seat-can-update      installed  whether this checkout could take a
#                                   fast-forward AT ALL, using bin/fm-ff-lib.sh's
#                                   own predicates. A stray untracked file makes
#                                   that fast-forward skip while the vessel keeps
#                                   reporting normally; this reading is what
#                                   separates "up to date" from "unable to
#                                   update". It reads only - the refusal policy
#                                   itself belongs to fm-ff-lib.sh, and the
#                                   stranded-branch case is separately reported
#                                   at session start by bin/fm-bootstrap.sh's
#                                   TANGLE line, which owns its remediation. This
#                                   reading states only the consequence for
#                                   delivery, and states it between sessions,
#                                   where nothing else was watching.
#   tool:<name>          installed  the runtime tools nothing else updates. Each
#                                   declares its own reference: a latest upstream
#                                   release, or a version this repo pins. A tool
#                                   this home has not installed is not a finding.
#
# The commit-graph distance between this checkout and its own origin is NOT
# re-measured here: bin/fm-bootstrap.sh's SELF_DRIFT check owns it.
#
# NOISE CONTROL
# The round runs at most once per cadence window, and surfaces a finding only
# when the finding line differs from the one last surfaced, so an unchanged
# state is reported once rather than daily. An unmeasured reading must repeat in
# two consecutive rounds before it surfaces, so one network blip is not a
# finding while sustained blindness is.
#
# Usage:
#   fm-currency-round.sh            detect: run the round when due, print at
#                                   most one CURRENCY_ROUND line, always exit 0
#   fm-currency-round.sh --force    run the round now, ignoring the cadence
#   fm-currency-round.sh --status   print every reading, whether or not the
#                                   round is due; writes no cadence stamp and
#                                   applies no de-duplication
#   fm-currency-round.sh --arm      write and register this home's watcher check
#                                   shim (idempotent)
#   fm-currency-round.sh --armed    print one CURRENCY_ROUND line when the round
#                                   is not armed or has stopped completing;
#                                   silent otherwise. This is the reading that
#                                   catches a seat that has stopped listening.
#   fm-currency-round.sh --help
#
# State, all under FM_HOME/state:
#   currency-round.last-run     epoch of the last COMPLETED round
#   currency-round.report       every reading of that round, plus the hop note
#   currency-round.surfaced     the exact finding line last surfaced
#   currency-round.unmeasured   subjects unmeasured in the previous round
#   currency-round.check.sh     the armed watcher shim (with .check-trust)
#
# Environment:
#   FM_CURRENCY_ROUND_INTERVAL  cadence in seconds (default 86400). 0 runs every
#                               invocation.
#   FM_CURRENCY_ROUND_STALE     how old a completed round may be before --armed
#                               calls the round stopped (default 172800).
#   FM_CURRENCY_ROUND_TIMEOUT   ceiling in seconds for each external step
#                               (default 12), so no single hung network call can
#                               consume the watcher's whole per-check budget.
#   FM_CURRENCY_ROUND_TOOLS     override the unmanaged tool table, ONE ENTRY PER
#                               LINE as "<tool>:release:<owner/repo>" or
#                               "<tool>:pinned:<command printing the version>".
#                               Lines rather than words because a pinned
#                               reference is a command with arguments (tests).
#   FM_CURRENCY_ROUND_NOW       override the current epoch (tests).
#   FM_CURRENCY_ROUND_DISABLE=1 silence detect and --armed only, so suites that
#                               compose bin/fm-bootstrap.sh need not arm a round.
#                               --status, --force, and --arm are unaffected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

LAST_RUN="$STATE/currency-round.last-run"
REPORT="$STATE/currency-round.report"
SURFACED="$STATE/currency-round.surfaced"
UNMEASURED="$STATE/currency-round.unmeasured"
CHECK="$STATE/currency-round.check.sh"

INTERVAL=${FM_CURRENCY_ROUND_INTERVAL:-86400}
STALE=${FM_CURRENCY_ROUND_STALE:-172800}
STEP_TIMEOUT=${FM_CURRENCY_ROUND_TIMEOUT:-12}
case "$INTERVAL" in *[!0-9]*) INTERVAL=86400 ;; '') INTERVAL=86400 ;; esac
case "$STALE" in *[!0-9]*) STALE=172800 ;; '') STALE=172800 ;; esac
case "$STEP_TIMEOUT" in *[!0-9]*) STEP_TIMEOUT=12 ;; '') STEP_TIMEOUT=12 ;; esac

# The runtime tools nothing else keeps current. gh, treehouse, and uv track
# their own upstream releases; shellcheck's reference is the version
# bin/fm-lint.sh requires, because fm-lint.sh refuses to run under any other and
# a drift from that pin breaks the validation gate rather than merely lagging it.
# Chasing shellcheck's latest release here would fight that pin and spend a wake
# on a decision this repo has already made.
DEFAULT_TOOLS="gh:release:cli/cli
treehouse:release:kunchenguid/treehouse
uv:release:astral-sh/uv
shellcheck:pinned:$SCRIPT_DIR/fm-lint.sh --required-version"
TOOLS=${FM_CURRENCY_ROUND_TOOLS:-$DEFAULT_TOOLS}

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=detect
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  --force) MODE=force ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  *)
    printf 'fm-currency-round: unknown argument %s\n' "$1" >&2
    printf 'usage: %s [--force|--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf 'usage: %s [--force|--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
  exit 2
}

NOW=${FM_CURRENCY_ROUND_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

# The same two-line portability shim bin/fm-lock-lib.sh, bin/fm-supervision-lib.sh
# and bin/fm-watch.sh each carry: BSD stat and GNU stat spell mtime differently.
path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# An epoch as a UTC timestamp, under whichever date this machine has. GNU spells
# the conversion -d @<epoch> and BSD spells it -r <epoch>; a machine with neither
# still gets a timestamp, just the current one.
epoch_utc() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Run "$@" under the per-step ceiling. With no timeout binary available the call
# runs unbounded rather than being skipped: a home without coreutils still gets
# its readings, and the watcher's own per-check timeout remains the backstop.
bounded() {
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$STEP_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$STEP_TIMEOUT" "$@" ;;
    *) "$@" ;;
  esac
}

# --- readings ---------------------------------------------------------------

# Each reading is one record appended to READINGS as
# "<subject>|<hop>|<state>|<detail>". Held in one array so the report file and
# the finding line are rendered from the same measurements and cannot disagree.
READINGS=()

reading() {  # <subject> <hop> <state> <detail>
  READINGS+=("$1|$2|$3|$4")
}

# Compare two dotted numeric versions. Prints "older", "same", or "newer" for
# the first against the second, and fails when either side is not comparable, so
# an unparseable version becomes unmeasured rather than a confident verdict.
version_relation() {  # <a> <b>
  local a=$1 b=$2 i fa fb
  a=${a#v}; b=${b#v}
  case "$a" in ''|*[!0-9.]*) return 1 ;; esac
  case "$b" in ''|*[!0-9.]*) return 1 ;; esac
  local -a pa pb
  IFS=. read -r -a pa <<< "$a"
  IFS=. read -r -a pb <<< "$b"
  for i in 0 1 2 3; do
    fa=${pa[i]:-0}
    fb=${pb[i]:-0}
    case "$fa" in ''|*[!0-9]*) return 1 ;; esac
    case "$fb" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$((10#$fa))" -lt "$((10#$fb))" ]; then printf 'older'; return 0; fi
    if [ "$((10#$fa))" -gt "$((10#$fb))" ]; then printf 'newer'; return 0; fi
  done
  printf 'same'
}

# The first dotted-numeric token in a tool's own --version output. Each tool
# spells that line differently, so the token is extracted rather than a field
# position assumed per tool.
installed_version() {  # <tool>
  local out
  # Never pipe the probe directly: a pipeline reports the LAST command's status,
  # so a tool that printed something and then failed would read as a success.
  out=$(bounded "$1" --version 2>/dev/null) || return 1
  printf '%s\n' "$out" | head -3 \
    | tr -s ' \t' '\n' \
    | sed -n 's/^v\{0,1\}\([0-9][0-9.]*[0-9]\)$/\1/p' \
    | head -1
}

latest_release() {  # <owner/repo>
  local tag
  command -v gh >/dev/null 2>&1 || return 1
  tag=$(bounded gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null) || return 1
  tag=${tag#v}
  [ -n "$tag" ] || return 1
  printf '%s' "$tag"
}

read_instruction_surface() {
  local out status=0
  out=$(bounded "$SCRIPT_DIR/fm-firstmate-update-check.sh" 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    reading instruction-surface released unmeasured \
      "the instruction-surface check could not complete (exit $status; it may have exceeded ${STEP_TIMEOUT}s)"
    return 0
  fi
  case "$out" in
    '')
      reading instruction-surface released ok "no instruction-surface change on the configured update source"
      ;;
    FIRSTMATE_UPDATE_STUCK:*)
      reading instruction-surface released unmeasured "${out#FIRSTMATE_UPDATE_STUCK: }"
      ;;
    *)
      reading instruction-surface released behind "$(printf '%s' "$out" | head -1)"
      ;;
  esac
}

read_fork_absorption() {
  local out status=0
  if [ ! -f "$CONFIG/fork-sync-upstream" ]; then
    reading fork-absorption released skipped \
      "this home is not configured as the fork curator (no config/fork-sync-upstream)"
    return 0
  fi
  out=$(bounded "$SCRIPT_DIR/fm-fork-sync-check.sh" 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    reading fork-absorption released unmeasured \
      "the fork-absorption check could not complete (exit $status; it may have exceeded ${STEP_TIMEOUT}s)"
    return 0
  fi
  case "$out" in
    '') reading fork-absorption released ok "the curated fork has absorbed real upstream content, or the three-day cadence has not reopened" ;;
    FORK_SYNC_STUCK:*) reading fork-absorption released unmeasured "${out#FORK_SYNC_STUCK: }" ;;
    *) reading fork-absorption released behind "$(printf '%s' "$out" | head -1)" ;;
  esac
}

# Can this seat take an update at all? Uses fm-ff-lib.sh's own predicates so the
# answer cannot drift from what the fast-forward will actually do. It reads and
# never advances anything.
# A secondmate home is a linked worktree leased at a detached HEAD and synced
# from the primary's local commit, with no origin involved. ff_target is called
# for it with allow_detached and ignore_seed_marker set, so applying the primary
# home's rules here would report every secondmate as unable to update forever.
read_seat_can_update() {
  local default current dirty linked=no ignore_marker=no
  if ! git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    reading seat-can-update installed unmeasured "$FM_ROOT is not a git repository"
    return 0
  fi
  if fm_root_is_secondmate_home "$FM_ROOT"; then
    linked=yes
    ignore_marker=yes
  fi
  if ! default=$(default_branch "$FM_ROOT"); then
    reading seat-can-update installed blocked "this checkout has no resolvable default branch, so a fast-forward has nothing to advance to"
    return 0
  fi
  if [ "$linked" = no ] && ! git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1; then
    reading seat-can-update installed blocked "this checkout has no origin, so nothing can be delivered to it"
    return 0
  fi
  current=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$current" ] && [ "$linked" = no ]; then
    reading seat-can-update installed blocked "this checkout is on a detached HEAD, not $default; an arriving update would be skipped"
    return 0
  fi
  if [ -n "$current" ] && [ "$current" != "$default" ]; then
    reading seat-can-update installed blocked "this checkout is on $current, not $default; an arriving update would be skipped"
    return 0
  fi
  dirty=$(dirty_status "$FM_ROOT" "$ignore_marker")
  if [ -n "$dirty" ]; then
    reading seat-can-update installed blocked \
      "this checkout has uncommitted or untracked content ($(printf '%s' "$dirty" | head -1)), so an arriving update would be skipped silently"
    return 0
  fi
  if [ "$linked" = yes ]; then
    reading seat-can-update installed ok "this linked home is clean and positioned to take the primary's next commit"
    return 0
  fi
  reading seat-can-update installed ok "this checkout is on $default, clean, and has an origin to take an update from"
}

read_tools() {
  local entry tool kind ref installed latest rel
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    tool=${entry%%:*}
    kind=${entry#*:}
    ref=${kind#*:}
    kind=${kind%%:*}
    [ -n "$tool" ] || continue
    command -v "$tool" >/dev/null 2>&1 || continue
    installed=$(installed_version "$tool" || true)
    if [ -z "$installed" ]; then
      reading "tool:$tool" installed unmeasured "the installed copy did not report a version"
      continue
    fi
    case "$kind" in
      release)
        if ! latest=$(latest_release "$ref"); then
          reading "tool:$tool" installed unmeasured "the latest release of $ref could not be read"
          continue
        fi
        ;;
      pinned)
        # shellcheck disable=SC2086  # the pin command is a configured word list.
        if ! latest=$(bounded $ref 2>/dev/null); then
          reading "tool:$tool" installed unmeasured "the version required by $ref could not be read"
          continue
        fi
        latest=${latest%%$'\n'*}
        latest=${latest#v}
        if [ -z "$latest" ]; then
          reading "tool:$tool" installed unmeasured "the version required by $ref came back empty"
          continue
        fi
        ;;
      *)
        reading "tool:$tool" installed unmeasured "unknown reference kind '$kind'"
        continue
        ;;
    esac
    if ! rel=$(version_relation "$installed" "$latest"); then
      reading "tool:$tool" installed unmeasured "versions $installed and $latest cannot be compared"
      continue
    fi
    case "$kind:$rel" in
      release:older)
        reading "tool:$tool" installed behind "$installed against the latest release $latest of $ref"
        ;;
      pinned:older|pinned:newer)
        reading "tool:$tool" installed behind "$installed against the $latest this repo requires ($ref)"
        ;;
      *)
        reading "tool:$tool" installed ok "$installed against $latest"
        ;;
    esac
  done <<< "$TOOLS"
}

run_round() {
  READINGS=()
  read_instruction_surface
  read_fork_absorption
  read_seat_can_update
  read_tools
}

# --- rendering --------------------------------------------------------------

render_report() {
  local record subject hop state detail
  printf 'round: %s\n' "$(epoch_utc "$NOW")"
  for record in "${READINGS[@]}"; do
    IFS='|' read -r subject hop state detail <<< "$record"
    printf 'reading: %s hop=%s state=%s detail=%s\n' "$subject" "$hop" "$state" "$detail"
  done
  printf 'note: this round measures the released and installed hops FOR THIS SEAT ONLY.\n'
  printf 'note: the pin hop is the fleet repository'"'"'s measurement and per-vessel install status is the fleet dashboard'"'"'s install view, so a clean round here never means the fleet is current.\n'
}

# Subjects that were unmeasured in the previous round, one per line. An
# unmeasured reading surfaces only on its second consecutive round.
previous_unmeasured() {
  [ -f "$UNMEASURED" ] && cat "$UNMEASURED" 2>/dev/null || true
}

record_unmeasured() {
  local record subject state
  : > "$UNMEASURED"
  for record in "${READINGS[@]}"; do
    IFS='|' read -r subject _ state _ <<< "$record"
    [ "$state" = unmeasured ] && printf '%s\n' "$subject" >> "$UNMEASURED"
  done
  return 0
}

# The one line worth waking a supervisor for, or nothing. Built only from
# readings that need a decision: an unmeasured one qualifies only when the
# previous round could not measure the same subject either.
finding_line() {
  local record subject hop state detail prev findings=0 shown=0 summary='' blocked=0
  prev=$(previous_unmeasured)
  for record in "${READINGS[@]}"; do
    IFS='|' read -r subject hop state detail <<< "$record"
    case "$state" in
      ok|skipped) continue ;;
      unmeasured)
        printf '%s\n' "$prev" | grep -qxF "$subject" || continue
        ;;
      blocked) blocked=1 ;;
    esac
    findings=$((findings + 1))
    if [ "$shown" -lt 3 ]; then
      # Bound each detail so several findings still make one readable line; the
      # untruncated reading is always in the report the line points at.
      [ "${#detail}" -le 140 ] || detail="${detail:0:137}..."
      summary="${summary:+$summary; }$subject ($hop) $state: $detail"
      shown=$((shown + 1))
    fi
  done
  [ "$findings" -gt 0 ] || return 1
  [ "$findings" -le "$shown" ] || summary="$summary; and $((findings - shown)) more"
  if [ "$blocked" -eq 1 ]; then
    printf 'CURRENCY_ROUND: %s finding(s) - %s. This seat cannot take an update until that is cleared. Full round: %s\n' \
      "$findings" "$summary" "$REPORT"
  else
    printf 'CURRENCY_ROUND: %s finding(s) - %s. Decide immediate or batch per the recorded criteria. Full round: %s\n' \
      "$findings" "$summary" "$REPORT"
  fi
}

# --- modes ------------------------------------------------------------------

if ! mkdir -p "$STATE" 2>/dev/null; then
  # The reporting modes stay quiet about their own plumbing rather than waking a
  # supervisor with it; the modes a human or bootstrap invoked say so and fail.
  case "$MODE" in
    detect|armed) exit 0 ;;
  esac
  printf 'fm-currency-round: cannot create state directory %s\n' "$STATE" >&2
  exit 1
fi

# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Write this home's watcher shim and bind it to its own bytes. Every location is
# baked in rather than inherited: the watcher runs a check from a private
# snapshot with its own environment, so a shim that guessed its home would
# measure a different one. Idempotent - an already-correct, already-registered
# shim is left exactly as it is, so bootstrap can call this on every session.
arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-currency-round.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: the cadence, the readings, and the decision about
# whether anything needs a human all live in the round itself, so they arrive by
# self-update instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
exec "$SCRIPT_DIR/fm-currency-round.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    # Written through a temp file in the same directory and moved into place, so
    # a watcher sweeping mid-write can never snapshot half a check and reject it
    # as unauthenticated.
    umask 077
    tmp=$(mktemp "$STATE/.fm-currency-round-check.XXXXXX") || return 1
    printf '%s\n' "$desired" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" currency-round >/dev/null || return 1
}

armed_diagnostic() {
  local last age shim_age shim_mtime
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'CURRENCY_ROUND: the daily update check is not armed on this home, so nothing is watching for updates between sessions (fix: %s/fm-currency-round.sh --arm)\n' "$SCRIPT_DIR"
    return 0
  fi
  last=''
  [ -f "$LAST_RUN" ] && IFS= read -r last < "$LAST_RUN"
  case "${last:-}" in ''|*[!0-9]*) last='' ;; esac
  if [ -z "$last" ]; then
    # Just armed is not a fault. Armed long ago and never completed is: it means
    # the watcher is not running this home's checks at all.
    shim_mtime=$(path_mtime "$CHECK") || shim_mtime=$NOW
    case "${shim_mtime:-}" in ''|*[!0-9]*) shim_mtime=$NOW ;; esac
    shim_age=$(( NOW - shim_mtime ))
    [ "$shim_age" -ge "$STALE" ] || return 0
    printf 'CURRENCY_ROUND: the daily update check has been armed for %s day(s) and has never completed a round, so this home is not being checked (inspect the monitoring service for this home)\n' \
      "$((shim_age / 86400))"
    return 0
  fi
  age=$(( NOW - last ))
  [ "$age" -ge "$STALE" ] || return 0
  printf 'CURRENCY_ROUND: the daily update check last completed %s day(s) ago (limit %s day(s)), so this home has stopped being checked for updates\n' \
    "$((age / 86400))" "$((STALE / 86400))"
}

case "$MODE" in
  arm)
    arm || { printf 'fm-currency-round: cannot arm the daily update check in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0
    ;;
  armed)
    [ "${FM_CURRENCY_ROUND_DISABLE:-0}" = 1 ] && exit 0
    armed_diagnostic
    exit 0
    ;;
  status)
    run_round
    render_report
    exit 0
    ;;
esac

[ "$MODE" = detect ] && [ "${FM_CURRENCY_ROUND_DISABLE:-0}" = 1 ] && exit 0

if [ "$MODE" = detect ] && [ "$INTERVAL" -gt 0 ] && [ -f "$LAST_RUN" ]; then
  due_last=''
  IFS= read -r due_last < "$LAST_RUN"
  case "${due_last:-}" in
    ''|*[!0-9]*) ;;
    *) [ $(( NOW - due_last )) -ge "$INTERVAL" ] || exit 0 ;;
  esac
fi

run_round
line=$(finding_line || true)
render_report > "$REPORT"
record_unmeasured
printf '%s\n' "$NOW" > "$LAST_RUN"

[ -n "$line" ] || { rm -f "$SURFACED"; exit 0; }

previous=''
[ -f "$SURFACED" ] && IFS= read -r previous < "$SURFACED"
[ "$line" != "$previous" ] || exit 0
printf '%s\n' "$line" > "$SURFACED"
printf '%s\n' "$line"
exit 0
