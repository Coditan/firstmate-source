#!/usr/bin/env bash
# Ask whether a memory ceiling on THIS host would manufacture the very pressure
# an alarm above it exists to detect, and answer it by measurement.
#
# WHY THIS EXISTS
# The obvious next step after bin/fm-memory-reading.sh is a throttling ceiling
# plus an alarm on crossing it. The first measurement was taken before swap was
# fitted, but the specific hazard survives that change: a cgroup's charge
# includes its page cache, and swap does not move page cache out of that charge.
# If page cache alone can reach the ceiling, the kernel holds the cgroup there
# by reclaiming continuously, and that reclaim registers as memory-stall time on
# /proc/pressure/memory - the same reading the alarm consumes. The ceiling would
# then generate its own alarm condition on a machine with gigabytes to spare.
#
# That hazard is a property of the host, not of the idea, so it is measured per
# host rather than assumed once. Run this before fitting any ceiling here, and
# run it again after anything that changes the answer: adding swap, changing
# total memory, or moving to another machine.
#
# WHAT IT DOES
# Two arms, identical workload, each against its own COLD corpus so nothing is
# served from the other arm's cache:
#   ceiling    a fresh transient scope with MemoryHigh set, reading files
#   control    the same scope and the same reading with no ceiling at all
# The workload only READS files. It allocates almost no anonymous memory, so
# anything the ceiling arm shows and the control arm does not is caused by the
# ceiling and by nothing else.
#
# WHAT IT WILL NOT DO
# It sets no lasting limit on anything: the only ceiling it sets is on its own
# transient scope, which is gone when it exits. It kills nothing and contains
# no path that could. It refuses to run when the host is already short of
# memory, because adding this load to a stressed machine would be both unkind
# and unmeasurable.
#
# MEASURED, AND FINE, IS NOT THE SAME AS COULD NOT MEASURE
# bin/fm-memory-reading.sh's rule holds here too and for the same reason. Every
# precondition is named, and one that could not be established is reported as
# unmeasured with its reason rather than assumed to hold. A probe that could
# not look never reports a clean verdict, because a ceiling fitted on the
# strength of a probe that failed silently is worse than one fitted on nothing.
#
# THE CONTROL ARM IS PART OF THE MEASUREMENT, NOT A COURTESY
# A ceiling arm showing stall proves nothing on a machine that was already
# stalling. The verdict is only issued when the control arm came back quiet on
# the same workload minutes earlier. A noisy control makes the run
# inconclusive, which is a third answer and not a pass.
#
# Usage:
#   fm-memory-ceiling-probe.sh                    probe with the defaults
#   fm-memory-ceiling-probe.sh --high 2G          ceiling for the ceiling arm
#                                                 (default 2G)
#   fm-memory-ceiling-probe.sh --corpus-mib N     corpus size per arm
#                                                 (default 2048)
#   fm-memory-ceiling-probe.sh --seconds N        how long each arm reads
#                                                 (default 30)
#   fm-memory-ceiling-probe.sh --scratch DIR      where the corpora are written
#                                                 (default $TMPDIR or /tmp)
#   fm-memory-ceiling-probe.sh --json             the same run as one object
#                                                 with schema
#                                                 fm-memory-ceiling-probe.v1
#   fm-memory-ceiling-probe.sh --help
#
# Exit status:
#   0  the ceiling did NOT manufacture pressure on this host: the ceiling arm
#      stayed clear of its limit and stayed quiet
#   4  the ceiling DID manufacture pressure: it was crossed, or it stalled,
#      while the host had memory to spare and the control arm was quiet. Do not
#      fit a ceiling on this host as configured, and do not tune the number
#      until the reason it was crossed has changed
#   5  inconclusive: the control arm was not quiet, so the ceiling arm's
#      reading cannot be attributed to the ceiling
#   3  a precondition was unmeasured, so no verdict is issued
#   2  usage error
#
# Environment:
#   FM_CEILING_PROBE_MIN_AVAIL_MIB  refuse to run below this much available
#                                   host memory (default 4096)
#   FM_CEILING_PROBE_QUIET_STALL    control-arm stall at or below which the
#                                   control counts as quiet (default 0.20)
#   FM_CEILING_PROBE_CGROUP_ROOT    cgroup root (tests)
#   FM_CEILING_PROBE_MEMINFO        headroom source (tests)
#   FM_CEILING_PROBE_PRESSURE       host stall source (tests)
#   FM_CEILING_PROBE_SYSTEMD_RUN     systemd-run command (tests)
#   FM_CEILING_PROBE_SCOPE_CGROUP    scope cgroup directory (tests)
set -u

HIGH=2G
CORPUS_MIB=2048
RUN_SECONDS=30
SCRATCH=${TMPDIR:-/tmp}
JSON=0
MIN_AVAIL_MIB=${FM_CEILING_PROBE_MIN_AVAIL_MIB:-4096}
QUIET_STALL=${FM_CEILING_PROBE_QUIET_STALL:-0.20}

UNMEASURED=()

usage() {
  printf 'usage: %s [--high SIZE] [--corpus-mib N] [--seconds N] [--scratch DIR] [--json] [--help]\n' \
    "$(basename "$0")"
}

die_usage() {
  printf 'fm-memory-ceiling-probe: %s\n' "$1" >&2
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --high) [ $# -ge 2 ] || die_usage "--high needs a size"; HIGH=$2; shift 2 ;;
    --corpus-mib) [ $# -ge 2 ] || die_usage "--corpus-mib needs a number"; CORPUS_MIB=$2; shift 2 ;;
    --seconds) [ $# -ge 2 ] || die_usage "--seconds needs a number"; RUN_SECONDS=$2; shift 2 ;;
    --scratch) [ $# -ge 2 ] || die_usage "--scratch needs a directory"; SCRATCH=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

case "$CORPUS_MIB" in (*[!0-9]*|'') die_usage "--corpus-mib needs a whole number of MiB" ;; esac
case "$RUN_SECONDS" in (*[!0-9]*|'') die_usage "--seconds needs a whole number of seconds" ;; esac
[ "$CORPUS_MIB" -ge 64 ] || die_usage "--corpus-mib below 64 cannot fill a ceiling worth probing"
[ "$RUN_SECONDS" -ge 5 ] || die_usage "--seconds below 5 is shorter than one stall average"

unmeasured() { UNMEASURED+=("$1|$2"); }

# --- preconditions ----------------------------------------------------------
#
# Each of these is a thing the probe needs in order to look at all. A missing
# one is reported by name rather than worked around, because every workaround
# here would silently change what the run measures.

CGROUP_ROOT=${FM_CEILING_PROBE_CGROUP_ROOT:-/sys/fs/cgroup}
MEMINFO=${FM_CEILING_PROBE_MEMINFO:-/proc/meminfo}
PRESSURE=${FM_CEILING_PROBE_PRESSURE:-/proc/pressure/memory}
SYSTEMD_RUN=${FM_CEILING_PROBE_SYSTEMD_RUN:-systemd-run}

check_preconditions() {
  [ "$(stat -fc %T "$CGROUP_ROOT" 2>/dev/null)" = cgroup2fs ] ||
    unmeasured cgroup2 "$CGROUP_ROOT is not a cgroup v2 hierarchy, so no cgroup here has a memory ceiling to set"

  command -v "$SYSTEMD_RUN" >/dev/null 2>&1 ||
    unmeasured systemd-run "systemd-run is not on PATH, so this cannot place a workload in a scope of its own"

  [ -r "$PRESSURE" ] ||
    unmeasured host-stall "$PRESSURE is unreadable, so the host stall this probe exists to watch cannot be read"

  [ -r "$MEMINFO" ] ||
    unmeasured headroom "$MEMINFO is unreadable, so the probe cannot tell a healthy host from a stressed one"

  local avail
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' "$MEMINFO" 2>/dev/null)
  if [ -z "$avail" ]; then
    unmeasured headroom "$MEMINFO has no MemAvailable line, so RAM headroom could not be read"
  elif [ "$avail" -lt "$MIN_AVAIL_MIB" ]; then
    unmeasured headroom "only $avail MiB RAM headroom available, below the $MIN_AVAIL_MIB MiB floor: this probe will not add load to a host that is already short"
  fi

  mkdir -p "$SCRATCH" 2>/dev/null || true
  [ -w "$SCRATCH" ] ||
    unmeasured scratch "$SCRATCH is not writable, so the corpora this reads cannot be written"

  local free_mib
  free_mib=$(df -BM --output=avail "$SCRATCH" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$free_mib" ]; then
    unmeasured scratch "free space under $SCRATCH could not be read"
  elif [ "$free_mib" -lt $((CORPUS_MIB + 512)) ]; then
    unmeasured scratch "$SCRATCH has ${free_mib} MiB free, short of the $((CORPUS_MIB + 512)) MiB one corpus plus margin needs"
  fi
}

# --- readings ---------------------------------------------------------------

host_avail_mib() { awk '/^MemAvailable:/{print int($2/1024)}' "$MEMINFO"; }

host_stall_avg10() {
  awk '/^some/{for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == "avg10") print a[2] }}' \
    "$PRESSURE"
}

# Greater-than on the two-decimal averages the kernel prints, without needing bc.
stall_over() {
  awk -v have="$1" -v limit="$2" 'BEGIN { exit !(have + 0 > limit + 0) }'
}

# One arm. Reads its own cold corpus in a scope of its own for the configured
# duration, and prints one tab-separated record of what that cost.
#
# The corpus is written with O_DIRECT so the write does not populate page cache.
# Without that the read below would be served from cache the arm was never
# charged for, the ceiling would never be approached, and the arm would report
# a calm result it did not earn - the exact failure this whole programme is
# built to refuse.
run_arm() {
  local name=$1 high=$2
  local corpus="$SCRATCH/fm-ceiling-probe-$name.bin"
  local unit="fm-ceiling-probe-$name-$$.scope"

  if ! dd if=/dev/urandom of="$corpus" bs=1M count="$CORPUS_MIB" oflag=direct status=none 2>/dev/null; then
    rm -f "$corpus"
    printf 'ARM_ERROR\tarm-%s\tthe cold corpus for the %s arm could not be written, so that arm never ran\n' \
      "$name" "$name"
    return 0
  fi

  local avail_before avail_after record
  avail_before=$(host_avail_mib)

  local run_status=0
  # The arm body is deliberately single-quoted: every expansion in it belongs to
  # the shell inside the scope, reading that scope's own cgroup, and must not be
  # resolved out here against this one.
  # shellcheck disable=SC2016
  record=$("$SYSTEMD_RUN" --user --scope --unit="$unit" \
    -p MemoryHigh="$high" -p MemoryMax=infinity --quiet -- \
    bash -c '
      set -u
      corpus=$1; run_for=$2; cg=$3
      [ -n "$cg" ] || cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
      [ -r "$cg/memory.current" ] || { printf "ARM_FAILED\tthe scope cgroup at %s is unreadable\n" "$cg"; exit 0; }

      stat_of() { awk -v k="$1" "\$1 == k { print \$2 }" "$cg/memory.stat"; }
      events_high() { awk "\$1 == \"high\" { print \$2 }" "$cg/memory.events"; }
      cg_stall() {
        awk "/^some/ { for (i = 1; i <= NF; i++) { split(\$i, a, \"=\"); if (a[1] == \"avg10\") print a[2] } }" \
          "$cg/memory.pressure" 2>/dev/null
      }

      steal0=$(stat_of pgsteal); refault0=$(stat_of workingset_refault_file); high0=$(events_high)
      [ -n "$high0" ] || high0=0

      peak_current=0; peak_stall=0.00
      end=$((SECONDS + run_for))
      while [ "$SECONDS" -lt "$end" ]; do
        dd if="$corpus" of=/dev/null bs=1M status=none 2>/dev/null
        cur=$(cat "$cg/memory.current")
        [ "$cur" -gt "$peak_current" ] && peak_current=$cur
        s=$(cg_stall); [ -n "$s" ] || s=0.00
        peak_stall=$(awk -v a="$peak_stall" -v b="$s" "BEGIN { print (b + 0 > a + 0) ? b : a }")
      done

      steal1=$(stat_of pgsteal); refault1=$(stat_of workingset_refault_file); high1=$(events_high)
      [ -n "$high1" ] || high1=0
      if [ -z "$(cg_stall)" ]; then stall_readable=no; else stall_readable=yes; fi

      printf "ARM\t%d\t%d\t%s\t%d\t%d\t%s\n" \
        "$peak_current" "$((high1 - high0))" "$peak_stall" \
        "$((steal1 - steal0))" "$((refault1 - refault0))" "$stall_readable"
    ' _ "$corpus" "$RUN_SECONDS" "${FM_CEILING_PROBE_SCOPE_CGROUP:-}" 2>/dev/null) || run_status=$?

  avail_after=$(host_avail_mib)
  rm -f "$corpus"

  if [ "$run_status" -ne 0 ]; then
    printf 'ARM_ERROR\tarm-%s\tthe %s arm scope exited with status %s before producing a reading\n' \
      "$name" "$name" "$run_status"
    return 0
  fi

  case "$record" in
    ARM$'\t'*) printf '%s\t%s\t%s\n' "$record" "$avail_before" "$avail_after" ;;
    ARM_FAILED*)
      printf 'ARM_ERROR\tarm-%s\t%s\n' "$name" "${record#ARM_FAILED$'\t'}" ;;
    *)
      printf 'ARM_ERROR\tarm-%s\tthe %s arm produced no reading, so the scope did not run or could not be measured\n' \
        "$name" "$name" ;;
  esac
}

accept_arm_result() {
  local result=$1 destination=$2 input reason
  case "$result" in
    ARM$'\t'*) printf -v "$destination" '%s' "$result" ;;
    ARM_ERROR$'\t'*)
      IFS=$'\t' read -r _ input reason <<<"$result"
      unmeasured "$input" "$reason" ;;
    *) unmeasured arm-protocol "an arm returned a result the probe could not interpret" ;;
  esac
}

# --- run --------------------------------------------------------------------

check_preconditions

if [ ${#UNMEASURED[@]} -gt 0 ]; then
  printf 'memory-ceiling-probe: INCOMPLETE - a precondition could not be established, so no verdict is issued\n'
  for u in "${UNMEASURED[@]}"; do
    printf '  unmeasured %-12s %s\n' "${u%%|*}" "${u#*|}"
  done
  exit 3
fi

HOST_STALL_BEFORE=$(host_stall_avg10)

# The control runs first. A ceiling arm that ran first would leave the host's
# stall averages decaying from its own reclaim, and the control would inherit
# that as if it were the machine's own noise.
CONTROL_RESULT=$(run_arm control infinity)
CEILING_RESULT=$(run_arm ceiling "$HIGH")
CONTROL=
CEILING=
accept_arm_result "$CONTROL_RESULT" CONTROL
accept_arm_result "$CEILING_RESULT" CEILING

if [ ${#UNMEASURED[@]} -gt 0 ]; then
  printf 'memory-ceiling-probe: INCOMPLETE - an arm did not run, so no verdict is issued\n'
  for u in "${UNMEASURED[@]}"; do
    printf '  unmeasured %-12s %s\n' "${u%%|*}" "${u#*|}"
  done
  exit 3
fi

IFS=$'\t' read -r _ C_CUR C_HIGH C_STALL C_STEAL C_REFAULT C_STALL_OK C_AVAIL0 C_AVAIL1 <<<"$CONTROL"
IFS=$'\t' read -r _ X_CUR X_HIGH X_STALL X_STEAL X_REFAULT X_STALL_OK X_AVAIL0 X_AVAIL1 <<<"$CEILING"

if [ "$C_STALL_OK" != yes ] || [ "$X_STALL_OK" != yes ]; then
  printf 'memory-ceiling-probe: INCOMPLETE - per-cgroup stall is unreadable on this kernel, so the arms cannot be compared\n'
  printf '  unmeasured %-12s %s\n' cgroup-stall \
    "memory.pressure carried no readable average, which usually means pressure stall information is not built into this kernel"
  exit 3
fi

LOWEST_AVAIL=$X_AVAIL0
[ "$X_AVAIL1" -lt "$LOWEST_AVAIL" ] && LOWEST_AVAIL=$X_AVAIL1
[ "$C_AVAIL0" -lt "$LOWEST_AVAIL" ] && LOWEST_AVAIL=$C_AVAIL0
[ "$C_AVAIL1" -lt "$LOWEST_AVAIL" ] && LOWEST_AVAIL=$C_AVAIL1

CONTROL_QUIET=yes
if [ "$C_HIGH" -gt 0 ] || stall_over "$C_STALL" "$QUIET_STALL"; then
  CONTROL_QUIET=no
fi

MANUFACTURED=no
if [ "$X_HIGH" -gt 0 ] || stall_over "$X_STALL" "$QUIET_STALL"; then
  MANUFACTURED=yes
fi

if [ "$CONTROL_QUIET" = no ]; then
  VERDICT=inconclusive
  STATUS=5
elif [ "$MANUFACTURED" = yes ]; then
  VERDICT=manufactured
  STATUS=4
else
  VERDICT=clear
  STATUS=0
fi

render_human() {
  case "$VERDICT" in
    manufactured)
      printf 'memory-ceiling-probe: MANUFACTURED - a %s ceiling generated memory pressure on a host that had memory to spare\n' "$HIGH" ;;
    clear)
      printf 'memory-ceiling-probe: clear - a %s ceiling was neither reached nor stalled by this workload\n' "$HIGH" ;;
    inconclusive)
      printf 'memory-ceiling-probe: INCONCLUSIVE - the control arm was not quiet, so nothing the ceiling arm shows can be blamed on the ceiling\n' ;;
  esac
  printf 'taken %s on %s, swap: %s\n\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname 2>/dev/null || echo '?')" \
    "$(awk '
      /^SwapTotal:/ { total = $2; seen_total = 1 }
      /^SwapFree:/ { free = $2; seen_free = 1 }
      END {
        if (!seen_total || total !~ /^[0-9]+$/) print "UNMEASURED (no usable SwapTotal)"
        else if (total == 0) print "none configured"
        else if (!seen_free || free !~ /^[0-9]+$/) print int(total / 1024) " MiB configured, free UNMEASURED"
        else print int(total / 1024) " MiB configured, " int(free / 1024) " MiB free"
      }
    ' "$MEMINFO")"

  printf 'Both arms read a %d MiB cold corpus for %d seconds and allocated almost nothing of their own.\n' \
    "$CORPUS_MIB" "$RUN_SECONDS"
  printf 'The host never fell below %d MiB RAM headroom while they ran.\n\n' "$LOWEST_AVAIL"

  printf '%-10s %-12s %12s %10s %12s %12s\n' ARM CEILING PEAK_MiB CROSSINGS PEAK_STALL REFAULTS
  printf '%-10s %-12s %12d %10d %12s %12d\n' control none "$((C_CUR / 1048576))" "$C_HIGH" "$C_STALL" "$C_REFAULT"
  printf '%-10s %-12s %12d %10d %12s %12d\n' ceiling "$HIGH" "$((X_CUR / 1048576))" "$X_HIGH" "$X_STALL" "$X_REFAULT"
  printf '\n'

  case "$VERDICT" in
    manufactured)
      printf 'The two arms did the same work on the same machine minutes apart. The control\n'
      printf 'arm cached what it read and stopped; the ceiling arm was held at its limit and\n'
      printf 'paid for it in reclaim. The difference is the ceiling and nothing else.\n\n'
      printf 'A ceiling is not made safe here by raising the number. Page cache expands into\n'
      printf 'whatever ceiling exists, so a higher one is reached by the same ordinary file\n'
      printf 'reading a little later, and the only ceiling page cache cannot reach is one\n'
      printf 'above what the machine would have let the cgroup hold anyway, which bounds\n'
      printf 'nothing. Report this rather than tuning it.\n' ;;
    clear)
      printf 'The ceiling arm stayed clear of its limit on this workload. That is evidence for\n'
      printf 'this ceiling against this corpus, not a guarantee for a larger working set:\n'
      printf 're-run with --corpus-mib at the size real work here actually touches.\n' ;;
    inconclusive)
      printf 'The control arm crossed a limit it does not have, or stalled while doing so.\n'
      printf 'Something else on this host was competing for memory. Re-run when it is quiet.\n' ;;
  esac
}

render_json() {
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-memory-ceiling-probe: --json needs jq, which is not on PATH\n' >&2
    exit 3
  }
  jq -n \
    --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg host "$(hostname 2>/dev/null || echo '?')" \
    --arg verdict "$VERDICT" \
    --arg high "$HIGH" \
    --argjson corpus_mib "$CORPUS_MIB" \
    --argjson seconds "$RUN_SECONDS" \
    --argjson lowest_avail_mib "$LOWEST_AVAIL" \
    --arg host_stall_before "$HOST_STALL_BEFORE" \
    --argjson c_cur "$C_CUR" --argjson c_high "$C_HIGH" --arg c_stall "$C_STALL" \
    --argjson c_steal "$C_STEAL" --argjson c_refault "$C_REFAULT" \
    --argjson x_cur "$X_CUR" --argjson x_high "$X_HIGH" --arg x_stall "$X_STALL" \
    --argjson x_steal "$X_STEAL" --argjson x_refault "$X_REFAULT" \
    '{
      schema: "fm-memory-ceiling-probe.v1",
      generated: $generated,
      host: $host,
      verdict: $verdict,
      ceiling: $high,
      corpus_mib: $corpus_mib,
      seconds_per_arm: $seconds,
      host_lowest_available_mib: $lowest_avail_mib,
      host_stall_avg10_before: ($host_stall_before | tonumber),
      arms: {
        control: { ceiling: null, peak_current_bytes: $c_cur, limit_crossings: $c_high,
                   peak_stall_avg10: ($c_stall | tonumber), pages_reclaimed: $c_steal,
                   file_refaults: $c_refault },
        ceiling: { ceiling: $high, peak_current_bytes: $x_cur, limit_crossings: $x_high,
                   peak_stall_avg10: ($x_stall | tonumber), pages_reclaimed: $x_steal,
                   file_refaults: $x_refault }
      }
    }'
}

if [ "$JSON" -eq 1 ]; then
  render_json
else
  render_human
fi

exit "$STATUS"
