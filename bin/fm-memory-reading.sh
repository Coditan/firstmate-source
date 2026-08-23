#!/usr/bin/env bash
# Name which process is running away with this machine's memory, not merely
# that memory is tight.
#
# WHAT THIS IS FOR
# This host now has swap as a shock absorber, but this seat still has no memory
# limit, no out-of-memory daemon, and no cap on concurrent sessions. Recent
# out-of-memory kills are why this instrument exists: even after a limit is
# fitted, nothing on the box names which worker caused the pressure. An alarm
# that cannot name a culprit is not actionable, so the attributable reading
# comes before any ceiling and before the alarm.
#
# WHAT THIS DELIBERATELY IS NOT
# It sets no limit, ceiling, or throttle. It raises no alarm. It kills nothing
# and contains no path that could. Those are separate, separately decided
# slices, and this one is only the instrument they will read.
#
# MEASURED, AND FINE, IS NOT THE SAME AS COULD NOT MEASURE
# A reading that found nothing wrong and a reading that failed to look both
# come back calm, and that is the exact defect this whole programme exists to
# remove. So every input is named, and every input reports one of:
#   measured    the value below was read from the named source.
#   unmeasured  the source was absent, unreadable, empty, or unparseable. No
#               substitute value is invented, and a zero is never printed in
#               its place.
#   scope       the value is legitimately unavailable in this run, known in
#               advance, and its absence is not an instrument failure.
# The first line of every reading states which, and the exit status carries it:
# a reading with any unmeasured input NEVER exits 0.
#
# SCOPE IS NOT THE SAME AS UNMEASURED EITHER
# A task is named only when a firstmate installation this run could actually
# read holds a record matching the process. Installations do not map one to one
# onto accounts: this box has three accounts and two installations, so an
# account is never evidence that an installation exists under it, and a process
# is never handed an owner that no record names. Every reading lists the
# installations it read, and a process matching none of them is reported as
# unattributed with the reason. That boundary is permanent and known in
# advance, so it is reported as declared scope, not as an instrument failure:
# calling it unmeasured would make incompleteness the permanent norm and
# destroy the signal. The remedy is to run this reading from the other
# installation too, or to point --home at records this account can read.
# No active account slice, no stored growth sample on a first run, and a sample
# interval younger than the configured floor are also scope. The first two are
# expected absences and the last is the operator's own cadence. They do not
# force exit 3, so the next slice's alarm does not learn to discount failure.
# The wall-clock and peak-memory cost figures measure this instrument rather
# than machine memory. Their platform-dependent absence is scope and stays
# visible without making the memory reading untrustworthy.
#
# THE THREE ATTRIBUTION LAYERS
#   account       from the process table, for every process when that table is
#                 readable; a failed table read is unmeasured.
#   account slice totals, limit, and stall from that account's own cgroup.
#                 Readable across accounts on this host, so a foreign account
#                 is still bounded even when nothing here can name its work;
#                 a blind cgroup tree is unmeasured.
#   task          the task id, kind, and project the process is serving, joined
#                 from the records of the installations this run read.
# Only firstmate holds the third layer, which is why this lives here and not in
# host configuration. The first two are never silently promoted into the third.
#
# SIZE AND GROWTH ARE DIFFERENT QUESTIONS
# A big steady worker is normal; a small one doubling every minute is the
# problem. Growth is measured against the previous run's sample, so the first
# run on a home reports growth as scoped rather than as zero. Pass
# --interval to take both samples inside one run instead.
#
# WAKE DELIVERY IS LABELLED, NOT RANKED
# The per-session wake-delivery listener is a few megabytes and is what makes
# every other reading arrive at all. It is labelled `protected` wherever it
# appears so nothing downstream of this reading can mistake it for a reasonable
# target. The label is positive only: its ABSENCE is never a licence, because
# this reading does not know every process that must not be touched.
#
# COST
# One process-table read, one bulk symlink read over the tracked processes
# only, one terminal-window listing, and plain file reads. No per-process
# forks. Every reading prints its own wall time and its own peak memory, so the
# claim that it does not add to the load it measures is re-measured on every
# run rather than asserted once.
#
# Usage:
#   fm-memory-reading.sh                 human reading against the stored
#                                        previous sample
#   fm-memory-reading.sh --json          the same reading as one object with
#                                        schema fm-memory-reading.v1
#   fm-memory-reading.sh --interval N    take both growth samples in this run,
#                                        N seconds apart, instead of using the
#                                        stored one
#   fm-memory-reading.sh --largest N     how many processes to name by size
#                                        (default 8)
#   fm-memory-reading.sh --growing N     how many to name by growth (default 8)
#   fm-memory-reading.sh --track-mib N   track every process at or above N MiB
#                                        (default 32); agent and delivery
#                                        processes are tracked at any size
#   fm-memory-reading.sh --home DIR      also join task records from DIR
#                                        (repeatable)
#   fm-memory-reading.sh --no-store      do not update the stored sample
#   fm-memory-reading.sh --help
#
# Exit status:
#   0  every expected instrument worked; scoped absences may still be reported
#   3  at least one input was unmeasured (the reading is INCOMPLETE, whatever
#      the numbers it did manage to print say)
#   2  usage error
#
# State, under FM_HOME/state:
#   memory-reading.samples   the previous sample this run measures growth
#                            against: one epoch line and one record per tracked
#                            process
#
# Environment:
#   FM_MEMORY_TRACK_MIB       tracking floor in MiB (default 32)
#   FM_MEMORY_GROWTH_MIB_MIN  MiB/min at or above which a process is called
#                             growing rather than steady (default 5)
#   FM_MEMORY_SAMPLE_MAX_AGE  how old the stored sample may be before growth is
#                             unmeasured rather than meaningless (default 1260)
#   FM_MEMORY_SAMPLE_MIN_AGE  interval below which growth is scoped because the
#                             operator ran it too soon to divide by (default 270)
#   FM_MEMORY_SAMPLES         path of the stored sample. Tests use it for
#                             isolation, and bin/fm-memory-alarm.sh uses it to
#                             keep a sample of its own: growth is measured
#                             against the previous run, so an operator running
#                             this reading by hand would otherwise reset the
#                             interval the alarm divides by, and the alarm would
#                             go blind to growth exactly when somebody was
#                             looking at the machine
#   FM_MEMORY_MEMINFO         headroom source (default /proc/meminfo)
#   FM_MEMORY_PRESSURE        stall source (default /proc/pressure/memory)
#   FM_MEMORY_CGROUP_ROOT     cgroup root (default /sys/fs/cgroup)
#   FM_MEMORY_PS              process-table command (tests); must print
#                             pid ppid user rss etimes args
#   FM_MEMORY_PROC            /proc equivalent for cwd resolution (tests)
#   FM_MEMORY_NO_TMUX=1       skip the terminal-window attribution route
#   FM_MEMORY_NOW             override the current epoch (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The canonical harness name pattern lives in one place; this reading borrows it
# rather than keeping a second copy that would drift from the adapter list.
# shellcheck source=bin/fm-harness-pid-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-harness-pid-lib.sh"

MEMINFO=${FM_MEMORY_MEMINFO:-/proc/meminfo}
PRESSURE=${FM_MEMORY_PRESSURE:-/proc/pressure/memory}
CGROUP_ROOT=${FM_MEMORY_CGROUP_ROOT:-/sys/fs/cgroup}
PROC=${FM_MEMORY_PROC:-/proc}
SAMPLES=${FM_MEMORY_SAMPLES:-$STATE/memory-reading.samples}

TRACK_MIB=${FM_MEMORY_TRACK_MIB:-32}
GROWTH_MIB_MIN=${FM_MEMORY_GROWTH_MIB_MIN:-5}
SAMPLE_MAX_AGE=${FM_MEMORY_SAMPLE_MAX_AGE:-1260}
SAMPLE_MIN_AGE=${FM_MEMORY_SAMPLE_MIN_AGE:-270}
case "$TRACK_MIB" in ''|*[!0-9]*) TRACK_MIB=32 ;; esac
case "$GROWTH_MIB_MIN" in ''|*[!0-9]*) GROWTH_MIB_MIN=5 ;; esac
case "$SAMPLE_MAX_AGE" in ''|*[!0-9]*) SAMPLE_MAX_AGE=1260 ;; esac
case "$SAMPLE_MIN_AGE" in ''|*[!0-9]*) SAMPLE_MIN_AGE=270 ;; esac

# The delivery path, by the script names it runs under. Deliberately a superset
# and deliberately matched only against the first two argv tokens: a worker's
# own instructions routinely MENTION these file names, and a reading that
# matched anywhere in the command line would label that worker as delivery.
PROTECTED_NAMES='fm-watch.sh fm-watcher-service.sh fm-watch-keeper.sh fm-watch-arm.sh fm-watch-checkpoint.sh fm-wake-wait.sh fm-wake-drain.sh fm-supervise-daemon.sh fm-afk-start.sh fm-afk-launch.sh fm-tg-recv-arm.sh'

usage() {
  # The header comment block IS the help text, so the two cannot drift apart.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die_usage() {
  printf 'fm-memory-reading: %s\n' "$1" >&2
  printf 'usage: %s [--json] [--interval N] [--largest N] [--growing N] [--track-mib N] [--home DIR] [--no-store] [--help]\n' \
    "$(basename "$0")" >&2
  exit 2
}

JSON=0
INTERVAL=0
LARGEST=8
GROWING=8
STORE=1
EXTRA_HOMES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --no-store) STORE=0 ;;
    --interval) [ "$#" -ge 2 ] || die_usage "--interval needs a value"; INTERVAL=$2; shift ;;
    --largest) [ "$#" -ge 2 ] || die_usage "--largest needs a value"; LARGEST=$2; shift ;;
    --growing) [ "$#" -ge 2 ] || die_usage "--growing needs a value"; GROWING=$2; shift ;;
    --track-mib) [ "$#" -ge 2 ] || die_usage "--track-mib needs a value"; TRACK_MIB=$2; shift ;;
    --home) [ "$#" -ge 2 ] || die_usage "--home needs a directory"; EXTRA_HOMES+=("$2"); shift ;;
    *) die_usage "unknown argument $1" ;;
  esac
  shift
done

for pair in "interval:$INTERVAL" "largest:$LARGEST" "growing:$GROWING" "track-mib:$TRACK_MIB"; do
  case "${pair#*:}" in
    ''|*[!0-9]*) die_usage "--${pair%%:*} must be a non-negative integer" ;;
  esac
done

# How many slice-less accounts are named individually before the rest are rolled
# into one counted line. The roll-up is a count and a total, never a silent drop.
ACCOUNT_ROWS=${FM_MEMORY_ACCOUNT_ROWS:-4}
case "$ACCOUNT_ROWS" in ''|*[!0-9]*) ACCOUNT_ROWS=4 ;; esac

TRACK_KB=$((TRACK_MIB * 1024))
GROWTH_KB_MIN=$((GROWTH_MIB_MIN * 1024))

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory-reading.XXXXXX") || {
  printf 'fm-memory-reading: could not create a working directory under %s\n' "${TMPDIR:-/tmp}" >&2
  exit 3
}
trap 'rm -rf "$TMP"' EXIT

NOW=${FM_MEMORY_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
STARTED_MS=$(date +%s%N 2>/dev/null)
case "$STARTED_MS" in ''|*[!0-9]*) STARTED_MS='' ;; esac

# --- unmeasured inputs ------------------------------------------------------
#
# One record per input that could not be read, as "<input>|<reason>". The
# completeness verdict and the exit status are both rendered from this list, so
# no reading can report itself complete while an input is missing from it.

UNMEASURED_FILE="$TMP/unmeasured"
: > "$UNMEASURED_FILE"

unmeasured() {  # <input> <reason>
  printf '%s|%s\n' "$1" "$2" >> "$UNMEASURED_FILE"
}

unmeasured_task_source() {  # <home> <reason>
  unmeasured task-attribution "$2"
  printf '%s\t-\tUNMEASURED\n' "$1" >> "$INSTALLATIONS_FILE"
}

unmeasured_count() {
  count_lines "$UNMEASURED_FILE"
}

count_lines() {  # <file>
  local n
  n=$(wc -l < "$1" 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# --- headroom ---------------------------------------------------------------
#
# MemAvailable is the kernel's RAM-headroom estimate for starting new work
# without swapping. SwapTotal and SwapFree are measured separately below and are
# never merged into that available-memory number.

MEM_TOTAL_KB=
MEM_AVAIL_KB=
SWAP_TOTAL_KB=
SWAP_FREE_KB=

read_headroom() {
  local key value rest
  if [ ! -e "$MEMINFO" ]; then
    unmeasured headroom "$MEMINFO does not exist (this reading needs a Linux /proc)"
    return
  fi
  if [ ! -r "$MEMINFO" ]; then
    unmeasured headroom "$MEMINFO is not readable by this account"
    return
  fi
  while read -r key value rest; do
    case "$key" in
      MemTotal:) MEM_TOTAL_KB=$value ;;
      MemAvailable:) MEM_AVAIL_KB=$value ;;
      SwapTotal:) SWAP_TOTAL_KB=$value ;;
      SwapFree:) SWAP_FREE_KB=$value ;;
    esac
  done < "$MEMINFO"
  case "$MEM_TOTAL_KB" in ''|*[!0-9]*) MEM_TOTAL_KB= ;; esac
  case "$MEM_AVAIL_KB" in ''|*[!0-9]*) MEM_AVAIL_KB= ;; esac
  case "$SWAP_TOTAL_KB" in ''|*[!0-9]*) SWAP_TOTAL_KB= ;; esac
  case "$SWAP_FREE_KB" in ''|*[!0-9]*) SWAP_FREE_KB= ;; esac
  if [ -z "$MEM_TOTAL_KB" ] || [ -z "$MEM_AVAIL_KB" ]; then
    unmeasured headroom "$MEMINFO carries no usable MemTotal/MemAvailable pair"
    MEM_TOTAL_KB=
    MEM_AVAIL_KB=
  fi
  if [ -z "$SWAP_TOTAL_KB" ]; then
    unmeasured headroom "$MEMINFO carries no usable SwapTotal"
  elif [ "$SWAP_TOTAL_KB" -gt 0 ] && [ -z "$SWAP_FREE_KB" ]; then
    unmeasured headroom "$MEMINFO carries no usable SwapFree for configured swap"
  fi
}

# --- stall ------------------------------------------------------------------
#
# Pressure Stall Information: the share of the last 10/60 seconds in which at
# least one task (some) or every task (full) was stalled waiting on memory.
# This is the reading that separates "the machine is busy" from "the machine is
# thrashing", and unlike free-memory arithmetic it cannot be argued with.

STALL_SOME10=
STALL_SOME60=
STALL_FULL10=
STALL_FULL60=

parse_pressure_file() {  # <file> -> "some10 some60 full10 full60" or empty
  awk '
    function num(s) { sub(/^[a-z0-9]+=/, "", s); return s }
    $1 == "some" { s10 = num($2); s60 = num($3) }
    $1 == "full" { f10 = num($2); f60 = num($3) }
    END {
      if (s10 == "" || s60 == "" || f10 == "" || f60 == "") exit 1
      if (s10 !~ /^[0-9]+(\.[0-9]+)?$/ || s60 !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
      if (f10 !~ /^[0-9]+(\.[0-9]+)?$/ || f60 !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
      printf "%s %s %s %s\n", s10, s60, f10, f60
    }
  ' "$1" 2>/dev/null
}

read_stall() {
  local parsed
  if [ ! -e "$PRESSURE" ]; then
    unmeasured stall "$PRESSURE does not exist (this kernel exposes no memory pressure metric)"
    return
  fi
  if [ ! -r "$PRESSURE" ]; then
    unmeasured stall "$PRESSURE is not readable by this account"
    return
  fi
  parsed=$(parse_pressure_file "$PRESSURE")
  if [ -z "$parsed" ]; then
    unmeasured stall "$PRESSURE carries no recognisable some/full averages"
    return
  fi
  read -r STALL_SOME10 STALL_SOME60 STALL_FULL10 STALL_FULL60 <<< "$parsed"
}

# --- process table ----------------------------------------------------------
#
# One read of the whole table. `comm` is deliberately not requested: it can
# itself contain a space (a tmux server rewrites its own argv to "tmux:
# server"), which would silently shift every later field.

PS_CMD=${FM_MEMORY_PS:-}
PS_FILE="$TMP/ps.tsv"
PS_OK=0

read_processes() {
  local raw="$TMP/ps.raw" parsed="$TMP/ps.parsed" sample_now
  # Reset first: a second read (--interval) that fails must leave this at 0
  # rather than inheriting the first read's success, or the reading would
  # report an empty process table as though it had one.
  PS_OK=0
  # Each table read is timed by its own clock. The process start epoch is
  # derived as now-minus-elapsed, so reusing one clock across two reads taken
  # seconds apart would shift every start time by the gap and make every
  # process look like a different, later one that had reused the pid.
  sample_now=${FM_MEMORY_NOW:-$(date +%s)}
  case "$sample_now" in ''|*[!0-9]*) sample_now=$NOW ;; esac
  if [ -n "$PS_CMD" ]; then
    $PS_CMD > "$raw" 2>/dev/null || {
      unmeasured processes "the configured process-table command failed"
      return
    }
  else
    command -v ps >/dev/null 2>&1 || {
      unmeasured processes "no ps command on PATH, so the process table could not be read at all"
      return
    }
    # uid rather than user: `ps -o user=` truncates a long account name and
    # falls back to the raw number anyway, and the numeric id is what locates
    # the account's cgroup slice. Names are resolved once, for display only.
    ps -eo pid=,ppid=,uid=,rss=,etimes=,args= > "$raw" 2>/dev/null || {
      unmeasured processes "ps failed, so the process table could not be read at all"
      return
    }
  fi
  if [ ! -s "$raw" ]; then
    unmeasured processes "the process table came back empty, which no live machine produces"
    return
  fi
  # pid ppid uid rss_kb start_epoch exe descriptor. The descriptor is built from
  # at most the first two argv tokens and capped: a full command line can carry
  # a credential or a whole task brief, and neither belongs in a reading.
  if ! awk -v now="$sample_now" '
    function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
    {
      pid = $1; ppid = $2; user = $3; rss = $4; et = $5
      if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/ || user !~ /^[0-9]+$/ ||
          rss !~ /^[0-9]+$/ || et !~ /^[0-9]+$/ || NF < 6) { bad = 1; next }
      t1 = base($6)
      t2 = ""
      if (NF >= 7 && substr($7, 1, 1) != "-") t2 = base($7)
      d = t1
      if (t2 != "" && t1 ~ /^(ba|da|k|z|)sh$|^env$|^node$|^python[0-9.]*$|^perl$|^ruby$/) d = t1 " " t2
      if (length(d) > 44) d = substr(d, 1, 43) "~"
      gsub(/[^[:print:]]/, "?", d)
      gsub(/\t/, " ", d)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, user, rss, now - et, t1, d
    }
    END { if (bad) exit 1 }
  ' "$raw" > "$parsed"; then
    unmeasured processes "the process table contained a malformed record and could not be trusted"
    return
  fi
  # Moved into place only once it parsed, so a failed second read leaves the
  # first sample readable instead of replacing it with an empty file.
  if [ ! -s "$parsed" ]; then
    unmeasured processes "no line of the process table parsed into a usable record"
    return
  fi
  if ! mv -f "$parsed" "$PS_FILE"; then
    unmeasured processes "the parsed process table could not be retained"
    return
  fi
  PS_OK=1
}

# --- accounts ---------------------------------------------------------------
#
# Every account with a live process, plus every account with a user slice.
# cgroupfs is world-readable, so an account whose task records are out of reach
# is still bounded by its own slice totals, limit, and stall.

ACCOUNTS_FILE="$TMP/accounts.tsv"
NAMES_FILE="$TMP/uid-names.tsv"

read_uid_names() {
  : > "$NAMES_FILE"
  { getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null; } \
    | awk -F: 'NF >= 3 { printf "%s\t%s\n", $3, $1 }' >> "$NAMES_FILE"
}

account_for_uid() {  # <uid>
  local name
  name=$(awk -F'\t' -v u="$1" '$1 == u { print $2; exit }' "$NAMES_FILE" 2>/dev/null)
  printf '%s\n' "${name:-uid-$1}"
}

read_accounts() {
  local totals="$TMP/uid-totals" slices="$TMP/uid-slices" uid slice current max pressure rsskb procs
  local blind=
  # An account with no session and a cgroup tree nobody could read both leave
  # every per-account slice field empty. Establish which of the two it is ONCE,
  # here, rather than printing "no active session slice" over a reading that
  # never looked - that is the same confusion this whole reading exists to end.
  if [ ! -d "$CGROUP_ROOT" ]; then
    blind="$CGROUP_ROOT is absent, so no account's total, limit, or stall was read at all"
  elif [ ! -x "$CGROUP_ROOT" ]; then
    blind="$CGROUP_ROOT is not searchable by this account"
  elif [ ! -d "$CGROUP_ROOT/user.slice" ]; then
    blind="$CGROUP_ROOT/user.slice is absent, so this machine keeps no per-account slice for any account"
  elif [ ! -r "$CGROUP_ROOT/user.slice" ]; then
    blind="$CGROUP_ROOT/user.slice is not readable by this account"
  elif [ ! -x "$CGROUP_ROOT/user.slice" ]; then
    blind="$CGROUP_ROOT/user.slice is not searchable by this account"
  fi
  [ -n "$blind" ] && unmeasured account-slices "$blind"
  : > "$ACCOUNTS_FILE"
  : > "$totals"
  : > "$slices"
  # One pass for every account's resident total and process count, rather than
  # one scan of the table per account.
  if [ "$PS_OK" -eq 1 ]; then
    awk -F'\t' '{ kb[$3] += $4; n[$3]++ }
      END { for (u in kb) printf "%s\t%d\t%d\n", u, kb[u], n[u] }' "$PS_FILE" > "$totals"
  fi
  for slice in "$CGROUP_ROOT"/user.slice/user-*.slice; do
    [ -d "$slice" ] || continue
    uid=${slice##*/user-}
    uid=${uid%.slice}
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$uid" >> "$slices"
  done
  # An account with a slice but no live process still gets a row: a slice that
  # exists and reads zero is a different fact from an account that is not here.
  awk -F'\t' -v slices="$slices" '
    BEGIN { while ((getline u < slices) > 0) if (u != "") want[u] = 1 }
    { seen[$1] = 1; print }
    END { for (u in want) if (!(u in seen)) printf "%s\t0\t0\n", u }
  ' "$totals" | sort -t$'\t' -k2,2nr > "$totals.all"

  while IFS=$'\t' read -r uid rsskb procs; do
    [ -n "$uid" ] || continue
    slice="$CGROUP_ROOT/user.slice/user-$uid.slice"
    if [ -n "$blind" ]; then
      current="UNMEASURED:$blind"
      max=$current
      pressure=$current
    elif [ ! -d "$slice" ]; then
      current="SCOPE:no active session slice for this account"
      max=$current
      pressure=$current
    elif [ ! -x "$slice" ]; then
      current="UNMEASURED:$slice is not searchable by this account"
      max=$current
      pressure=$current
      unmeasured "account-slice[$(account_for_uid "$uid")].memory.current" "${current#UNMEASURED:}"
      unmeasured "account-slice[$(account_for_uid "$uid")].memory.max" "${max#UNMEASURED:}"
      unmeasured "account-slice[$(account_for_uid "$uid")].memory.pressure" "${pressure#UNMEASURED:}"
    else
      current="UNMEASURED:$slice/memory.current is absent or unreadable"
      max="UNMEASURED:$slice/memory.max is absent or unreadable"
      pressure="UNMEASURED:$slice/memory.pressure is absent or unreadable"
      # `read` returns non-zero on a final line with no newline while still
      # assigning it, so the value is validated below rather than discarded on
      # that exit status.
      if [ -r "$slice/memory.current" ]; then
        current=
        read -r current < "$slice/memory.current" 2>/dev/null
        case "$current" in ''|*[!0-9]*) current="UNMEASURED:$slice/memory.current is not a byte count" ;; esac
      fi
      if [ -r "$slice/memory.max" ]; then
        max=
        read -r max < "$slice/memory.max" 2>/dev/null
        case "$max" in
          ''|*[!0-9]* )
            [ "$max" = max ] || max="UNMEASURED:$slice/memory.max is neither max nor a byte count"
            ;;
        esac
      fi
      if [ -r "$slice/memory.pressure" ]; then
        pressure=$(parse_pressure_file "$slice/memory.pressure")
        if [ -n "$pressure" ]; then
          pressure=${pressure%% *}
        else
          pressure="UNMEASURED:$slice/memory.pressure carries no recognisable averages"
        fi
      fi
      case "$current" in UNMEASURED:*) unmeasured "account-slice[$(account_for_uid "$uid")].memory.current" "${current#UNMEASURED:}" ;; esac
      case "$max" in UNMEASURED:*) unmeasured "account-slice[$(account_for_uid "$uid")].memory.max" "${max#UNMEASURED:}" ;; esac
      case "$pressure" in UNMEASURED:*) unmeasured "account-slice[$(account_for_uid "$uid")].memory.pressure" "${pressure#UNMEASURED:}" ;; esac
    fi
    printf '%s\t-\t%s\t%s\t%s\t%s\t%s\n' \
      "$uid" "$rsskb" "$procs" "$current" "$max" "$pressure" >> "$ACCOUNTS_FILE"
  done < "$totals.all"
  # Names resolved in one pass over the finished table, not once per account.
  awk -F'\t' -v OFS='\t' -v names="$NAMES_FILE" '
    BEGIN { while ((getline l < names) > 0) { split(l, f, "\t"); if (!(f[1] in n)) n[f[1]] = f[2] } }
    { $2 = ($1 in n) ? n[$1] : "uid-" $1; print }
  ' "$ACCOUNTS_FILE" > "$ACCOUNTS_FILE.named" && mv -f "$ACCOUNTS_FILE.named" "$ACCOUNTS_FILE"
}

# --- task records -----------------------------------------------------------
#
# The third attribution layer, and the one only firstmate has. Every home this
# reading can actually read contributes its task records; the accounts owning
# those homes become the declared task-attribution scope, and every other
# account is reported as out of that scope rather than as a failed measurement.

TASKS_FILE="$TMP/tasks.tsv"
SCOPE_FILE="$TMP/scope"
INSTALLATIONS_FILE="$TMP/installations.tsv"
HOMES_READ=0

owner_uid_of() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

read_tasks() {
  local homes="$TMP/homes" home howner tasks task_tmp meta records_ok
  local -a metas
  : > "$TASKS_FILE"
  : > "$SCOPE_FILE"
  : > "$INSTALLATIONS_FILE"
  : > "$homes"
  printf '%s\n' "$FM_HOME" >> "$homes"
  for home in ${EXTRA_HOMES+"${EXTRA_HOMES[@]}"}; do
    printf '%s\n' "$home" >> "$homes"
  done
  # A secondmate's home is recorded in this home's own task metadata, so its
  # tasks join the same way without a second registry parser.
  awk '
    FNR == 1 { if (issecond && seconhome != "") print seconhome; issecond = 0; seconhome = "" }
    $0 == "kind=secondmate" { issecond = 1 }
    /^home=/ { if (seconhome == "") { seconhome = $0; sub(/^home=/, "", seconhome) } }
    END { if (issecond && seconhome != "") print seconhome }
  ' "$STATE"/*.meta 2>/dev/null >> "$homes"
  sort -u "$homes" -o "$homes"

  while IFS= read -r home; do
    [ -n "$home" ] || continue
    if [ ! -d "$home/state" ]; then
      unmeasured_task_source "$home" "$home state directory is absent"
      continue
    fi
    if [ ! -r "$home/state" ]; then
      unmeasured_task_source "$home" "$home state directory is not readable by this account"
      continue
    fi
    if [ ! -x "$home/state" ]; then
      unmeasured_task_source "$home" "$home state directory is not searchable by this account"
      continue
    fi
    howner=$(owner_uid_of "$home")
    case "$howner" in
      ''|*[!0-9]*)
        howner=-
        unmeasured task-attribution "$home owner could not be determined, so its account scope is unknown"
        ;;
      *) ;;
    esac
    metas=("$home"/state/*.meta)
    if [ ! -e "${metas[0]}" ]; then
      HOMES_READ=$((HOMES_READ + 1))
      [ "$howner" = - ] || printf '%s\n' "$howner" >> "$SCOPE_FILE"
      printf 'home\t%s\t-\t-\t-\t%s\n' "$home" "${home##*/}" >> "$TASKS_FILE"
      printf '%s\t%s\t0\n' "$home" "${howner:--}" >> "$INSTALLATIONS_FILE"
      continue
    fi
    records_ok=1
    for meta in "${metas[@]}"; do
      [ -f "$meta" ] && [ -r "$meta" ] || records_ok=0
    done
    if [ "$records_ok" -ne 1 ]; then
      unmeasured_task_source "$home" "$home has task records that could not be read"
      continue
    fi
    task_tmp="$TMP/tasks.$HOMES_READ"
    : > "$task_tmp"
    # One awk over all of a home's task records rather than four sed forks per
    # record; the count of records read is emitted by the same pass.
    if ! tasks=$(awk -v home="${home##*/}" -v out="$task_tmp" '
      function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
      function flush(   proj) {
        if (id == "") return
        seen++
        proj = (project == "") ? "-" : base(project)
        if (kind == "") kind = "task"
        if (worktree != "") printf "worktree\t%s\t%s\t%s\t%s\t%s\n", worktree, id, kind, proj, home >> out
        if (window != "") { sub(/^.*:/, "", window); printf "window\t%s\t%s\t%s\t%s\t%s\n", window, id, kind, proj, home >> out }
        id = ""; worktree = ""; project = ""; kind = ""; window = ""
      }
      FNR == 1 { flush(); id = base(FILENAME); sub(/\.meta$/, "", id) }
      /^worktree=/ { if (worktree == "") { worktree = $0; sub(/^worktree=/, "", worktree) } }
      /^project=/  { if (project == "")  { project = $0;  sub(/^project=/, "", project) } }
      /^kind=/     { if (kind == "")     { kind = $0;     sub(/^kind=/, "", kind) } }
      /^window=/   { if (window == "")   { window = $0;   sub(/^window=/, "", window) } }
      END { flush(); print seen + 0 }
    ' "${metas[@]}" 2>/dev/null); then
      unmeasured_task_source "$home" "$home has task records that could not be read"
      continue
    fi
    case "$tasks" in
      ''|*[!0-9]*) unmeasured_task_source "$home" "$home task records produced no usable read count"; continue ;;
    esac
    HOMES_READ=$((HOMES_READ + 1))
    [ "$howner" = - ] || printf '%s\n' "$howner" >> "$SCOPE_FILE"
    printf 'home\t%s\t-\t-\t-\t%s\n' "$home" "${home##*/}" >> "$TASKS_FILE"
    cat "$task_tmp" >> "$TASKS_FILE"
    printf '%s\t%s\t%s\n' "$home" "${howner:--}" "$tasks" >> "$INSTALLATIONS_FILE"
  done < "$homes"

  if [ "$HOMES_READ" -eq 0 ]; then
    unmeasured task-attribution "no home's task records could be read, so no process can be tied to the work it serves"
  fi
  sort -u "$SCOPE_FILE" -o "$SCOPE_FILE"
}

# --- candidate set, cwd, and terminal windows -------------------------------

CANDIDATES_FILE="$TMP/candidates"
CWD_FILE="$TMP/cwd.tsv"
GONE_FILE="$TMP/gone"
PANES_FILE="$TMP/panes.tsv"

select_candidates() {
  awk -F'\t' -v floor="$TRACK_KB" -v harness="$FM_HARNESS_RE" -v prot="$PROTECTED_NAMES" '
    BEGIN { n = split(prot, p, " "); for (i = 1; i <= n; i++) protected[p[i]] = 1 }
    {
      keep = ($4 + 0 >= floor)
      if (!keep && $6 ~ harness) keep = 1
      if (!keep) { split($7, tok, " "); if (tok[1] in protected || tok[2] in protected) keep = 1 }
      if (keep) print $1
    }
  ' "$PS_FILE" > "$CANDIDATES_FILE"
}

read_cwds() {
  local args=() pid unresolved="$TMP/cwd-unresolved"
  : > "$CWD_FILE"
  : > "$GONE_FILE"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    args+=("$PROC/$pid/cwd")
  done < "$CANDIDATES_FILE"
  [ "${#args[@]}" -gt 0 ] || return 0
  # One bulk symlink listing rather than one readlink fork per process. An
  # entry with no target is a live process this account may not look into.
  ls -ld "${args[@]}" > "$TMP/ls.out" 2> "$TMP/ls.err"
  sed -n "s|^.*[[:space:]]$PROC/\([0-9][0-9]*\)/cwd -> \(.*\)\$|\1	\2|p" "$TMP/ls.out" > "$CWD_FILE"
  awk -F'\t' '
    FILENAME == ARGV[1] { if ($1 != "") resolved[$1] = 1; next }
    $1 != "" && !($1 in resolved) { print $1 }
  ' "$CWD_FILE" "$CANDIDATES_FILE" > "$unresolved"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    # This records the state at this check; the process can still exit after it.
    [ -d "$PROC/$pid" ] || printf '%s\n' "$pid" >> "$GONE_FILE"
  done < "$unresolved"
}

read_panes() {
  : > "$PANES_FILE"
  [ "${FM_MEMORY_NO_TMUX:-0}" = 1 ] && return 0
  command -v tmux >/dev/null 2>&1 || return 0
  tmux list-panes -a -F '#{pane_pid}	#{window_name}' 2>/dev/null > "$PANES_FILE" || : > "$PANES_FILE"
}

# --- growth -----------------------------------------------------------------
#
# Growth needs two samples. Which pair was used, and why a pair was not
# available, is carried per process rather than collapsed into a zero.

PRIOR_FILE="$TMP/prior.tsv"
GROWTH_INTERVAL=0
GROWTH_REASON=
GROWTH_SCOPE=0
INTERVAL_WAITED=0

read_prior() {
  local epoch age parse_status="$TMP/prior-status" epoch_file="$TMP/prior-epoch"
  : > "$PRIOR_FILE"
  if [ "$INTERVAL" -gt 0 ]; then
    if [ "$INTERVAL" -lt "$SAMPLE_MIN_AGE" ]; then
      GROWTH_REASON="only ${INTERVAL}s between explicit samples, under the ${SAMPLE_MIN_AGE}s floor this rate can be divided by"
      GROWTH_SCOPE=1
      return
    fi
    if ! cp "$PS_FILE" "$TMP/first.tsv"; then
      GROWTH_REASON="the first process-table read could not be retained for comparison"
      unmeasured growth-sample "$GROWTH_REASON"
      return
    fi
    sleep "$INTERVAL"
    INTERVAL_WAITED=1
    read_processes
    if [ "$PS_OK" -ne 1 ]; then
      GROWTH_REASON="the second process-table read failed"
      unmeasured growth-sample "$GROWTH_REASON"
      return
    fi
    if ! awk -F'\t' '{ printf "%s\t%s\t%s\n", $1, $5, $4 }' "$TMP/first.tsv" > "$PRIOR_FILE"; then
      GROWTH_REASON="the first process-table read could not be prepared for comparison"
      unmeasured growth-sample "$GROWTH_REASON"
      return
    fi
    GROWTH_INTERVAL=$INTERVAL
    return
  fi
  if [ ! -e "$SAMPLES" ]; then
    GROWTH_REASON="no stored sample yet, so this run has nothing to compare against"
    GROWTH_SCOPE=1
    return
  fi
  if [ ! -f "$SAMPLES" ] || [ ! -r "$SAMPLES" ]; then
    GROWTH_REASON="the stored sample exists but could not be read"
    unmeasured growth-sample "$GROWTH_REASON"
    return
  fi
  : > "$parse_status"
  : > "$epoch_file"
  if ! awk -F'\t' -v epoch_file="$epoch_file" -v status_file="$parse_status" '
    /^#/ || /^[[:space:]]*$/ { next }
    /^epoch / {
      if (seen_epoch || $0 !~ /^epoch [0-9]+$/) { bad = 1; next }
      epoch = $0
      sub(/^epoch /, "", epoch)
      print epoch > epoch_file
      seen_epoch = 1
      next
    }
    NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print; next }
    { bad = 1 }
    END {
      if (!seen_epoch) print "timestamp" > status_file
      if (bad) print "malformed" > status_file
      if (!seen_epoch || bad) exit 1
    }
  ' "$SAMPLES" > "$PRIOR_FILE" 2>/dev/null; then
    case "$(head -1 "$parse_status" 2>/dev/null)" in
      timestamp) GROWTH_REASON="the stored sample carries no usable timestamp" ;;
      malformed) GROWTH_REASON="the stored sample carries a malformed process record" ;;
      *) GROWTH_REASON="the stored sample body could not be read" ;;
    esac
    : > "$PRIOR_FILE"
    unmeasured growth-sample "$GROWTH_REASON"
    return
  fi
  epoch=$(head -1 "$epoch_file" 2>/dev/null)
  age=$((NOW - epoch))
  if [ "$age" -lt 0 ]; then
    GROWTH_REASON="the stored sample is dated in the future, so the interval cannot be trusted"
    unmeasured growth-sample "$GROWTH_REASON"
    return
  fi
  if [ "$age" -gt "$SAMPLE_MAX_AGE" ]; then
    GROWTH_REASON="the stored sample is ${age}s old, past the ${SAMPLE_MAX_AGE}s window a growth rate means anything over"
    unmeasured growth-sample "$GROWTH_REASON"
    return
  fi
  if [ "$age" -lt "$SAMPLE_MIN_AGE" ]; then
    GROWTH_REASON="only ${age}s since the stored sample, under the ${SAMPLE_MIN_AGE}s floor this rate can be divided by"
    GROWTH_SCOPE=1
    return
  fi
  GROWTH_INTERVAL=$age
}

store_sample() {
  local tmp
  [ "$STORE" -eq 1 ] || return 0
  if [ ! -d "$STATE" ] && ! mkdir -p "$STATE" 2>/dev/null; then
    unmeasured sample-storage "$STATE could not be created"
    return 0
  fi
  tmp="$SAMPLES.$$"
  # Written aside and moved into place, so a reading interrupted mid-write
  # leaves the previous sample intact rather than a truncated one the next run
  # would quietly measure growth against.
  if ! {
    printf '# fm-memory-reading.samples v1\n'
    printf 'epoch %s\n' "$NOW"
    awk -F'\t' '{ printf "%s\t%s\t%s\n", $1, $4, $3 }' "$PROCS_FILE"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    unmeasured sample-storage "$tmp could not be written"
    return 0
  fi
  if ! mv -f "$tmp" "$SAMPLES" 2>/dev/null; then
    rm -f "$tmp"
    unmeasured sample-storage "$SAMPLES could not be replaced"
  fi
}

# --- the join ---------------------------------------------------------------

PROCS_FILE="$TMP/procs.tsv"

build_records() {
  awk -F'\t' -v OFS='\t' \
    -v interval="$GROWTH_INTERVAL" \
    -v growth_reason="$GROWTH_REASON" \
    -v growth_scoped="$GROWTH_SCOPE" \
    -v grow_min="$GROWTH_KB_MIN" \
    -v prot="$PROTECTED_NAMES" \
    -v me="$(id -un 2>/dev/null || id -u)" \
    -v scope_file="$SCOPE_FILE" \
    -v names_file="$NAMES_FILE" \
    '
    function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
    function acct(u) { return (u in uname) ? uname[u] : "uid-" u }
    BEGIN {
      n = split(prot, p, " ")
      for (i = 1; i <= n; i++) protected[p[i]] = 1
      while ((getline line < scope_file) > 0) if (line != "") in_scope[line] = 1
      close(scope_file)
      while ((getline line < names_file) > 0) {
        split(line, f, "\t")
        if (f[1] != "" && !(f[1] in uname)) uname[f[1]] = f[2]
      }
      close(names_file)
    }
    # 1: candidate pids
    FNR == NR && FILENAME == ARGV[1] { cand[$1] = 1; next }
    # 2: task records
    FILENAME == ARGV[2] {
      if ($1 == "worktree") { wt_path[++wtn] = $2; wt_id[wtn] = $3; wt_kind[wtn] = $4; wt_proj[wtn] = $5; wt_home[wtn] = $6 }
      else if ($1 == "window") { win_id[$2] = $3; win_kind[$2] = $4; win_proj[$2] = $5; win_home[$2] = $6 }
      else if ($1 == "home") { hm_path[++hmn] = $2; hm_name[hmn] = $6 }
      next
    }
    # 3: cwd per pid
    FILENAME == ARGV[3] { cwd[$1] = $2; next }
    # 4: pids that vanished mid-read
    FILENAME == ARGV[4] { gone[$1] = 1; next }
    # 5: terminal panes
    FILENAME == ARGV[5] { pane[$1] = $2; next }
    # 6: prior sample
    FILENAME == ARGV[6] { pr_start[$1] = $2; pr_rss[$1] = $3; next }
    # 7: the process table
    {
      pid = $1; ppid = $2; user = $3; rss = $4; start = $5; exe = $6; desc = $7
      parent[pid] = ppid
      all_pid[++alln] = pid
      a_user[pid] = user; a_rss[pid] = rss; a_start[pid] = start; a_desc[pid] = desc; a_exe[pid] = exe
    }
    END {
      for (i = 1; i <= alln; i++) {
        pid = all_pid[i]
        if (!(pid in cand)) continue

        # --- growth ---
        gstate = "unmeasured"; grate = "NA"; greason = growth_reason
        if (greason != "" && growth_scoped + 0 == 1) gstate = "scoped"
        if (greason == "") {
          if (!(pid in pr_rss)) {
            greason = "first sighting of this process by the reading"
          } else if (pr_start[pid] != "" && (a_start[pid] - pr_start[pid] > 3 || pr_start[pid] - a_start[pid] > 3)) {
            greason = "this pid now belongs to a different, later process"
          } else if (interval + 0 <= 0) {
            greason = "the interval between the two samples was not usable"
          } else {
            grate = (a_rss[pid] - pr_rss[pid]) * 60.0 / interval
            greason = "-"
            if (grate >= grow_min) gstate = "growing"
            else if (grate <= -grow_min) gstate = "shrinking"
            else gstate = "steady"
          }
        }

        # --- attribution ---
        kind = "unattributed"; detail = ""; route = "none"; guarded = "no"
        split(a_desc[pid], tok, " ")
        if (tok[1] in protected || tok[2] in protected) {
          kind = "infrastructure"; guarded = "yes"; route = "command"
          detail = "wake delivery"
        }
        tid = ""; tkind = ""; tproj = ""; thome = ""
        c = cwd[pid]
        if (c != "") {
          best = 0; bestlen = 0
          for (j = 1; j <= wtn; j++) {
            L = length(wt_path[j])
            if (L > bestlen && (c == wt_path[j] || index(c, wt_path[j] "/") == 1)) { best = j; bestlen = L }
          }
          if (best > 0) {
            tid = wt_id[best]; tkind = wt_kind[best]; tproj = wt_proj[best]; thome = wt_home[best]
            if (route != "command") route = "worktree path"
          } else {
            bh = 0; bestlen = 0
            for (j = 1; j <= hmn; j++) {
              L = length(hm_path[j])
              if (L > bestlen && (c == hm_path[j] || index(c, hm_path[j] "/") == 1)) { bh = j; bestlen = L }
            }
            if (bh > 0) { thome = hm_name[bh]; if (route != "command") route = "home path" }
          }
        }
        if (tid == "") {
          # Terminal-window route: walk up to the pane this process runs under.
          q = pid; hops = 0; wname = ""
          while (hops++ < 12 && q != "" && q != "1") {
            if (q in pane) { wname = pane[q]; break }
            q = parent[q]
          }
          if (wname != "") {
            key = wname
            if (key in win_id) {
              tid = win_id[key]; tkind = win_kind[key]; tproj = win_proj[key]; thome = win_home[key]
              if (route != "command") route = "terminal window"
            }
          }
        }

        if (kind == "infrastructure") {
          if (thome != "") detail = detail " for " thome
        } else if (tid != "") {
          kind = "task"
          detail = tid " (" tkind (tproj != "-" ? ", " tproj : "") ")"
        } else if (thome != "") {
          kind = "firstmate-home"; detail = thome
        } else if (!(a_user[pid] in in_scope)) {
          route = "no readable records"
          detail = "runs under account " acct(a_user[pid]) ", which no installation read by this run (from account " me ") covers"
        } else if (pid in gone) {
          route = "exited"
          detail = "the process exited while the reading was running"
        } else if (c == "") {
          route = "unreadable"
          detail = "this account may not resolve the process working directory"
        } else {
          route = "no match"
          detail = "working directory " c " matches no record of the installations read"
        }

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
          pid, acct(a_user[pid]), a_rss[pid], a_start[pid], \
          (grate == "NA" ? "NA" : sprintf("%.1f", grate)), greason, gstate, \
          kind, detail, route, guarded, a_desc[pid], a_user[pid]
      }
    }
    ' "$CANDIDATES_FILE" "$TASKS_FILE" "$CWD_FILE" "$GONE_FILE" "$PANES_FILE" "$PRIOR_FILE" "$PS_FILE" \
    > "$PROCS_FILE"
}

# --- rendering --------------------------------------------------------------

mib() {  # <kb>
  awk -v k="$1" 'BEGIN { printf "%.0f", k / 1024 }'
}

render_human() {
  local n total avail used pct swap line count sum

  n=$(unmeasured_count)
  if [ "$n" -eq 0 ]; then
    printf 'memory-reading: complete - every input in scope was measured\n'
  else
    printf 'memory-reading: INCOMPLETE - %s input(s) unmeasured; the numbers below do not add up to an all-clear\n' "$n"
  fi
  printf 'taken %s on %s\n\n' "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname 2>/dev/null || echo '?')"

  printf 'HEADROOM\n'
  if [ -n "$MEM_TOTAL_KB" ] && [ -n "$MEM_AVAIL_KB" ]; then
    total=$(mib "$MEM_TOTAL_KB"); avail=$(mib "$MEM_AVAIL_KB")
    used=$((total - avail))
    pct=$(awk -v a="$MEM_AVAIL_KB" -v t="$MEM_TOTAL_KB" 'BEGIN { printf "%.0f", (t > 0 ? a * 100 / t : 0) }')
    printf '  total %s MiB   used %s MiB   available %s MiB (%s%%)\n' "$total" "$used" "$avail" "$pct"
    if [ -n "$SWAP_TOTAL_KB" ]; then
      if [ "$SWAP_TOTAL_KB" -eq 0 ]; then
        swap='none configured - there is no second chance under pressure'
      else
        if [ -n "$SWAP_FREE_KB" ]; then
          swap="$(mib "$SWAP_TOTAL_KB") MiB total, $(mib "$SWAP_FREE_KB") MiB free"
        else
          swap="$(mib "$SWAP_TOTAL_KB") MiB total, free UNMEASURED"
        fi
      fi
      printf '  swap  %s\n' "$swap"
    else
      printf '  swap  UNMEASURED (no SwapTotal in %s)\n' "$MEMINFO"
    fi
  else
    printf '  UNMEASURED - see the unmeasured section below\n'
  fi

  printf '\nSTALL (share of the last 10s/60s spent waiting on memory)\n'
  if [ -n "$STALL_SOME10" ]; then
    printf '  some  avg10=%s  avg60=%s        (at least one task stalled)\n' "$STALL_SOME10" "$STALL_SOME60"
    printf '  full  avg10=%s  avg60=%s        (every task stalled)\n' "$STALL_FULL10" "$STALL_FULL60"
  else
    printf '  UNMEASURED - see the unmeasured section below\n'
  fi

  printf '\nACCOUNTS (by process memory; an account with a session slice is always shown)\n'
  if [ -s "$ACCOUNTS_FILE" ]; then
    local shown=0 rest_n=0 rest_kb=0
    while IFS=$'\t' read -r uid name rsskb procs current max pressure; do
      # Every account is either named here or counted in the roll-up line
      # below. None is dropped.
      if [ "$shown" -ge "$ACCOUNT_ROWS" ] && [ "${current#SCOPE:}" != "$current" ]; then
        rest_n=$((rest_n + 1))
        rest_kb=$((rest_kb + rsskb))
        continue
      fi
      shown=$((shown + 1))
      printf '  %-12s uid %-6s %s process(es), %s MiB resident\n' "$name" "$uid" "$procs" "$(mib "$rsskb")"
      case "$current" in
        UNMEASURED:*) printf '  %-12s   slice total  UNMEASURED (%s)\n' '' "${current#UNMEASURED:}" ;;
        SCOPE:*) printf '  %-12s   slice total  %s\n' '' "${current#SCOPE:}" ;;
        *) printf '  %-12s   slice total  %s MiB\n' '' "$(mib $((current / 1024)))" ;;
      esac
      case "$max" in
        UNMEASURED:*) printf '  %-12s   slice limit  UNMEASURED (%s)\n' '' "${max#UNMEASURED:}" ;;
        SCOPE:*) printf '  %-12s   slice limit  %s\n' '' "${max#SCOPE:}" ;;
        max) printf '  %-12s   slice limit  none - this account is unbounded\n' '' ;;
        *) printf '  %-12s   slice limit  %s MiB\n' '' "$(mib $((max / 1024)))" ;;
      esac
      case "$pressure" in
        UNMEASURED:*) printf '  %-12s   slice stall  UNMEASURED (%s)\n' '' "${pressure#UNMEASURED:}" ;;
        SCOPE:*) printf '  %-12s   slice stall  %s\n' '' "${pressure#SCOPE:}" ;;
        *) printf '  %-12s   slice stall  some avg10=%s\n' '' "$pressure" ;;
      esac
      if grep -qx "$uid" "$SCOPE_FILE" 2>/dev/null; then
        printf '  %-12s   records      an installation read by this run runs under this account\n' ''
      else
        printf '  %-12s   records      none: no installation read by this run runs under this account\n' ''
      fi
    done < "$ACCOUNTS_FILE"
    [ "$rest_n" -gt 0 ] && printf '  %s further account(s) with no session slice, %s MiB resident between them\n' \
      "$rest_n" "$(mib "$rest_kb")"
  else
    printf '  UNMEASURED - no account could be enumerated\n'
  fi

  printf '\nTASK RECORD SOURCES (only successfully read records can put a name to a process)\n'
  if [ -s "$INSTALLATIONS_FILE" ]; then
    while IFS=$'\t' read -r home howner tasks; do
      if [ "$tasks" = UNMEASURED ]; then
        printf '  %s   account unknown, task records UNMEASURED (state directory absent or unreadable)\n' "$home"
      elif [ "$howner" = - ]; then
        printf '  %s   account unknown, %s task record(s)\n' "$home" "$tasks"
      else
        printf '  %s   account %s, %s task record(s)\n' "$home" "$(account_for_uid "$howner")" "$tasks"
      fi
    done < "$INSTALLATIONS_FILE"
    printf '  Anything these records do not cover is reported unattributed below, never given an owner they do not name.\n'
  else
    printf '  none - see the unmeasured section below\n'
  fi

  printf '\nLARGEST TRACKED PROCESSES (tracking floor %s MiB; agent and delivery processes at any size)\n' "$TRACK_MIB"
  print_table "$(sort -t$'\t' -k3,3nr "$PROCS_FILE" | head -n "$LARGEST")"

  printf '\nFASTEST GROWING\n'
  line=$(awk -F'\t' -v OFS='\t' '$7 == "growing"' "$PROCS_FILE" | sort -t$'\t' -k5,5nr | head -n "$GROWING")
  if [ -n "$line" ]; then
    print_table "$line"
  elif [ -n "$GROWTH_REASON" ]; then
    if [ "$GROWTH_SCOPE" -eq 1 ]; then
      printf '  scoped for this run: %s\n' "$GROWTH_REASON"
    else
      printf '  UNMEASURED for every tracked process: %s\n' "$GROWTH_REASON"
    fi
  else
    count=$(awk -F'\t' '$7 == "unmeasured"' "$PROCS_FILE" | wc -l | tr -d ' ')
    printf '  none: measured over %ss, no tracked process grew by %s MiB/min or more (%s process(es) had no measurable growth)\n' \
      "$GROWTH_INTERVAL" "$GROWTH_MIB_MIN" "$count"
  fi

  count=$(awk -F'\t' '$8 == "unattributed"' "$PROCS_FILE" | wc -l | tr -d ' ')
  sum=$(awk -F'\t' '$8 == "unattributed" { s += $3 } END { printf "%d", s + 0 }' "$PROCS_FILE")
  printf '\nUNATTRIBUTED (%s tracked process(es), %s MiB)\n' "$count" "$(mib "$sum")"
  if [ "$count" -eq 0 ]; then
    printf '  none: every tracked process was tied to the work it serves\n'
  else
    awk -F'\t' '$8 == "unattributed" { n[$10]++; kb[$10] += $3 }
      END { for (r in n) printf "  by reason: %-22s %3d process(es), %d MiB\n", r, n[r], kb[r] / 1024 }' \
      "$PROCS_FILE" | sort
    awk -F'\t' '$8 == "unattributed"' "$PROCS_FILE" | sort -t$'\t' -k3,3nr \
      | awk -F'\t' '{ printf "  %8d MiB  pid %-8s %-10s %-20s %s\n", $3 / 1024, $1, $2, $12, $10 " - " $9 }'
  fi

  n=$(unmeasured_count)
  printf '\nUNMEASURED INPUTS (%s)\n' "$n"
  if [ "$n" -eq 0 ]; then
    printf '  none\n'
  else
    while IFS='|' read -r input reason; do
      [ -n "$input" ] || continue
      printf '  %-18s %s\n' "$input" "$reason"
    done < "$UNMEASURED_FILE"
  fi

  printf '\nREADING COST\n'
  printf '  %s\n' "$(reading_cost)"
}

print_table() {  # <tsv lines>
  local rows=$1
  [ -n "$rows" ] || { printf '  (no tracked process)\n'; return 0; }
  printf '  %8s %15s  %-10s %-8s %-20s %s\n' 'RSS MiB' 'GROWTH' 'SIZE TREND' PID COMMAND ATTRIBUTION
  # One awk for the whole table: a fork per row per column would make the
  # reading cost more than the thing it is measuring.
  printf '%s\n' "$rows" | awk -F'\t' -v global="$GROWTH_REASON" '
    function attribution(kind, detail, guarded, account) {
      if (kind == "task") return account " / task " detail
      if (kind == "firstmate-home") return account " / firstmate home " detail
      if (kind == "infrastructure") return account " / " detail " [PROTECTED]"
      return account " / UNATTRIBUTED: " detail
    }
    {
      growth = ($5 == "NA") ? $7 : sprintf("%+.1f MiB/min", $5 / 1024)
      printf "  %8d %15s  %-10s %-8s %-20s %s\n", \
        $3 / 1024, growth, $7, $1, $12, attribution($8, $9, $11, $2)
      # A per-process reason only. When no pair of samples existed at all the
      # reason is identical for every row, so it is printed once under the
      # table instead of repeated against each line.
      if ($7 == "unmeasured" && $6 != "-" && $6 != "" && $6 != global)
        printf "  %8s %15s  why: %s\n", "", "", $6
    }
  '
  if [ -n "$GROWTH_REASON" ]; then
    if [ "$GROWTH_SCOPE" -eq 1 ]; then
      printf '  growth scoped for every process above: %s\n' "$GROWTH_REASON"
    else
      printf '  growth unmeasured for every process above: %s\n' "$GROWTH_REASON"
    fi
  fi
  return 0
}

reading_cost() {
  local ended peak wall
  ended=$(date +%s%N 2>/dev/null)
  case "$ended" in ''|*[!0-9]*) ended='' ;; esac
  if [ -n "$STARTED_MS" ] && [ -n "$ended" ]; then
    wall=$(( (ended - STARTED_MS) / 1000000 ))
    [ "$INTERVAL_WAITED" -eq 1 ] && wall="$wall (of which ${INTERVAL}000 was the requested wait)"
    wall="${wall}ms wall"
  else
    wall="wall time unavailable in scope (no nanosecond clock on this machine)"
  fi
  peak=$(sed -n 's/^VmHWM:[[:space:]]*//p' "$PROC/self/status" 2>/dev/null | head -1)
  [ -n "$peak" ] || peak="unavailable in scope"
  printf '%s, peak memory of this reading %s' "$wall" "$peak"
}

render_json() {
  local complete=true
  [ "$(unmeasured_count)" -eq 0 ] || complete=false
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-memory-reading: --json needs jq, which is not on PATH\n' >&2
    exit 3
  }
  jq -n \
    --arg generated "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg host "$(hostname 2>/dev/null || echo '?')" \
    --argjson complete "$complete" \
    --arg growth_interval "$GROWTH_INTERVAL" \
    --arg growth_reason "$GROWTH_REASON" \
    --argjson growth_scoped "$GROWTH_SCOPE" \
    --arg cost "$(reading_cost)" \
    --arg total_kb "${MEM_TOTAL_KB:-}" \
    --arg avail_kb "${MEM_AVAIL_KB:-}" \
    --arg swap_total_kb "${SWAP_TOTAL_KB:-}" \
    --arg swap_free_kb "${SWAP_FREE_KB:-}" \
    --arg some10 "${STALL_SOME10:-}" --arg some60 "${STALL_SOME60:-}" \
    --arg full10 "${STALL_FULL10:-}" --arg full60 "${STALL_FULL60:-}" \
    --rawfile unmeasured "$UNMEASURED_FILE" \
    --rawfile accounts "$ACCOUNTS_FILE" \
    --rawfile procs "$PROCS_FILE" \
    --rawfile scope "$SCOPE_FILE" \
    --rawfile installations "$INSTALLATIONS_FILE" \
    '
    def lines: split("\n") | map(select(length > 0));
    def num($s): if $s == "" then null else ($s | tonumber) end;
    {
      schema: "fm-memory-reading.v1",
      generated: $generated,
      host: $host,
      complete: $complete,
      unmeasured: ($unmeasured | lines | map(split("|") | {input: .[0], reason: (.[1:] | join("|"))})),
      task_attribution_scope: ($scope | lines),
      installation_sources: ($installations | lines | map(split("\t") | {
        home: .[0], owner_uid: (if .[1] == "-" then null else .[1] end),
        status: (if .[2] == "UNMEASURED" then "unmeasured" else "read" end),
        task_records: (if .[2] == "UNMEASURED" then null else (.[2] | tonumber) end)
      })),
      installations_read: ($installations | lines | map(split("\t")) | map(select(.[2] != "UNMEASURED")) | map({
        home: .[0], owner_uid: (if .[1] == "-" then null else .[1] end), task_records: (.[2] | tonumber)
      })),
      headroom: {
        total_kb: num($total_kb),
        available_kb: num($avail_kb),
        swap_total_kb: num($swap_total_kb),
        swap_free_kb: num($swap_free_kb)
      },
      stall: {
        some_avg10: num($some10), some_avg60: num($some60),
        full_avg10: num($full10), full_avg60: num($full60)
      },
      accounts: ($accounts | lines | map(split("\t") | . as $f | {
        uid: $f[0], account: $f[1],
        process_rss_kb: ($f[2] | tonumber), processes: ($f[3] | tonumber),
        in_task_scope: (($scope | lines) | index($f[0]) != null),
        slice_current: $f[4], slice_limit: $f[5], slice_stall_some_avg10: $f[6]
      })),
      growth: { interval_seconds: ($growth_interval | tonumber),
                scope_reason: (if $growth_scoped == 1 then $growth_reason else null end),
                unmeasured_reason: (if $growth_reason == "" or $growth_scoped == 1 then null else $growth_reason end) },
      processes: ($procs | lines | map(split("\t") | . as $f | {
        pid: ($f[0] | tonumber), account: $f[1], uid: $f[12],
        rss_kb: ($f[2] | tonumber), started_epoch: ($f[3] | tonumber),
        growth_kb_per_min: (if $f[4] == "NA" then null else ($f[4] | tonumber) end),
        growth_scope_reason: (if $f[6] == "scoped" then $f[5] else null end),
        growth_unmeasured_reason: (if $f[5] == "-" or $f[6] == "scoped" then null else $f[5] end),
        growth_state: $f[6],
        attribution: {kind: $f[7], detail: $f[8], route: $f[9]},
        protected: ($f[10] == "yes"),
        command: $f[11]
      })),
      cost: $cost
    }
    '
}

# --- run --------------------------------------------------------------------

read_uid_names
read_headroom
read_stall
read_processes
read_accounts
read_tasks

if [ "$PS_OK" -eq 1 ]; then
  select_candidates
  read_cwds
  read_panes
  read_prior
  # --interval re-reads the process table, so the candidate set and the cwd
  # listing are rebuilt against the sample the reading actually reports.
  if [ "$INTERVAL" -gt 0 ] && [ "$PS_OK" -eq 1 ]; then
    select_candidates
    read_cwds
  fi
  build_records
  store_sample
else
  : > "$PROCS_FILE"
  : > "$CANDIDATES_FILE"
  : > "$CWD_FILE"
  : > "$GONE_FILE"
  : > "$PANES_FILE"
  GROWTH_REASON="the process table could not be read, so nothing could be compared"
fi

if [ "$JSON" -eq 1 ]; then
  render_json
else
  render_human
fi

[ "$(unmeasured_count)" -eq 0 ] || exit 3
exit 0
