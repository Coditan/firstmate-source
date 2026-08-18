#!/usr/bin/env bash
# Wake the fleet when this machine is running out of RAM headroom, and name the
# process responsible.
#
# WHAT THIS IS FOR
# hlr-web-1 now has swap as a shock absorber, no memory limit on this seat yet,
# no out-of-memory daemon, and recent global out-of-memory kills are why this
# alarm exists. Swap can turn an immediate kill into reclaim and swap pressure,
# but it does not name the worker causing that pressure. Until this existed,
# nothing would have said so before the host degraded or the kernel picked a
# victim.
#
# WHY THERE IS NO CEILING UNDER THIS ALARM
# The obvious design was a cgroup ceiling with an alarm on crossing it. That was
# built as far as measuring it and then abandoned on the measurement: a ceiling
# here is crossed thousands of times by ordinary file reading with 16 GB free,
# because a cgroup's charge includes page cache and page cache expands into
# whatever ceiling exists. Worse, holding a cgroup at a ceiling generates
# memory-stall time on the same reading this alarm consumes, so the ceiling
# would have manufactured its own alarm condition. docs/memory-ceiling-caveat.md
# owns that finding and bin/fm-memory-ceiling-probe.sh re-measures it; a
# proposed container ceiling must be checked against that caveat rather than
# assumed safe because swap now exists.
# So this alarm fires on headroom and on growth, and nothing here limits,
# throttles, or kills anything. Nothing is ever throttled, so the wake-delivery
# stub and the supervision watcher cannot be: there is no mechanism in this file
# that could reach them, or anything else.
#
# ONE MEASUREMENT PATH, NOT TWO
# Every number below comes from bin/fm-memory-reading.sh --json and nothing
# else. A second path would drift from the first, and then the alarm and the
# evidence the fleet reads when it fires would disagree about the machine at the
# worst possible moment.
#
# That inheritance includes the reading's completeness contract. A reading with
# any unmeasured input never exits 0, and this alarm never converts such a
# reading into an all-clear. It reports that it could not see, which is a third
# outcome and not a pass. An alarm that goes quiet when its instrument breaks is
# the failure this whole programme was built to remove.
#
# THE TWO CONDITIONS, AND WHY THEY ARE BOTH NEEDED
#   headroom   RAM headroom from MemAvailable below the floor. A backstop: it
#              catches memory going somewhere no single tracked process is
#              visibly growing into, such as many small processes or one that
#              arrives and grows entirely between two samples.
#   horizon    total growth across the tracked processes would consume that RAM
#              headroom within the horizon. This is the primary trigger and the
#              one that gives warning rather than confirmation.
#              It is deliberately measured on the SUM of positive growth, not on
#              the fastest single process, because five workers growing at
#              500 MiB/min exhaust this machine exactly as fast as one at
#              2500 MiB/min and no single one of them looks alarming.
# The process NAMED is the largest contributor to that growth, with the account
# and the task the reading attributes it to. The condition is about the machine;
# the name is about who to talk to.
#
# It self-tightens as RAM headroom goes, which is the property that makes one
# horizon work across the whole range: at 16 GB free it takes more than
# 1 GiB/min to trip, and at 2 GB free it takes 136 MiB/min.
#
# HOW THE THRESHOLDS WERE CHOSEN, AND WHAT WOULD HAVE TO HAPPEN TO CROSS THEM
# Both are derived from measurements recorded in docs/memory-alarm.md, not
# picked. In short:
#   horizon    3x the watcher's 300s check sweep, so a crossing is seen at
#              least twice before the RAM headroom it predicts is gone. A
#              horizon shorter than that cadence could go from silent to
#              reclaim or swap pressure between two polls without ever firing.
#   floor      well below the lowest headroom measured across a real busy
#              period on this fleet, so ordinary work does not reach it. From
#              that busy low, something would have to consume roughly ten
#              further gigabytes to cross it - and the horizon condition fires
#              long before that, which is the point of having both.
# A threshold set so high nothing reaches it is indistinguishable from a healthy
# machine, so both are stated here, both are reproducible from the doc, and the
# alarm was proven by driving a real crossing rather than by argument.
#
# NOISE CONTROL: IT SPEAKS ON CHANGE, NEVER ON CADENCE
# A watcher check that printed on every sweep while memory was tight would cost
# a model turn every five minutes for news that has not changed, and would bury
# the crossing it exists to report. So this prints only on a TRANSITION -
# entering the crossed state, and leaving it - and is silent in between.
# Recovery is deliberately harder than crossing: leaving requires clearing the
# thresholds by the recovery margin, so a machine hovering at the line reports
# once rather than flapping.
#
# IT DOES NOT MESSAGE THE CAPTAIN ITSELF
# It prints one line, the watcher wakes firstmate, and firstmate decides what
# reaches the captain and how. That routing is firstmate's under AGENTS.md
# section 9, and a script that went straight to him would take a judgement it
# cannot make and cannot be overruled on.
#
# Usage:
#   fm-memory-alarm.sh            evaluate; print at most one line, only on a
#                                 change of state; always exit 0, because the
#                                 watcher reads the line and not the status
#   fm-memory-alarm.sh --status   print the current evaluation in full whether
#                                 or not it changed; records nothing
#   fm-memory-alarm.sh --arm      write and register this home's watcher check
#                                 (idempotent)
#   fm-memory-alarm.sh --armed    print one line when the alarm is not armed or
#                                 has stopped running; silent otherwise
#   fm-memory-alarm.sh --help
#
# Exit status:
#   0  in the default and --arm modes, always: a check's job is its line
#   0  --status: measured, and not crossed
#   4  --status: crossed
#   3  --status: the reading was incomplete, so no verdict is issued
#   2  usage error
#
# Durable record, under FM_HOME/data:
#   memory-alarm.log   one append-only line per state change, crossing and
#                      recovery alike, each carrying the evidence it was decided
#                      on. It lives in data/ rather than state/ because the
#                      question it answers - has this happened before, and what
#                      was running - is asked long after the volatile record of
#                      the moment is gone.
#
# State, under FM_HOME/state:
#   memory-alarm.state    the last state this alarm decided, so a transition can
#                         be told from a continuation
#   memory-alarm.samples  this alarm's OWN growth sample, kept apart from the
#                         reading's, so that an operator running the reading by
#                         hand does not reset what the alarm compares against.
#                         Without it the alarm would go blind to growth exactly
#                         when somebody is looking at the machine.
#   memory-alarm.check.sh the armed watcher check (with .check-trust)
#
# Environment:
#   FM_MEMORY_ALARM_FLOOR_MIB    headroom floor in MiB (default 2400)
#   FM_MEMORY_ALARM_HORIZON_MIN  exhaustion horizon in minutes (default 15)
#   FM_MEMORY_ALARM_RECOVERY     multiplier a reading must clear both
#                                thresholds by before recovery is declared
#                                (default 1.25)
#   FM_MEMORY_ALARM_STALE        how long without a completed evaluation before
#                                --armed calls the alarm stopped (default 1800)
#   FM_MEMORY_ALARM_DISABLE=1    silence detect and --armed only, so suites that
#                                compose bin/fm-bootstrap.sh need not arm an
#                                alarm; every fixture home is unarmed by
#                                definition. --arm and --status are unaffected.
#   FM_MEMORY_ALARM_READING      the reading to consume (tests)
#   FM_MEMORY_ALARM_NOW          override the current epoch (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

READING=${FM_MEMORY_ALARM_READING:-$SCRIPT_DIR/fm-memory-reading.sh}
LOG="$DATA/memory-alarm.log"
STATE_FILE="$STATE/memory-alarm.state"
SAMPLES="$STATE/memory-alarm.samples"
CHECK="$STATE/memory-alarm.check.sh"

FLOOR_MIB=${FM_MEMORY_ALARM_FLOOR_MIB:-2400}
HORIZON_MIN=${FM_MEMORY_ALARM_HORIZON_MIN:-15}
RECOVERY=${FM_MEMORY_ALARM_RECOVERY:-1.25}
STALE=${FM_MEMORY_ALARM_STALE:-1800}
NOW=${FM_MEMORY_ALARM_NOW:-$(date +%s)}

case "$FLOOR_MIB" in *[!0-9]*|'') FLOOR_MIB=2400 ;; esac
case "$HORIZON_MIN" in *[!0-9]*|'') HORIZON_MIN=15 ;; esac
case "$STALE" in *[!0-9]*|'') STALE=1800 ;; esac

MODE=detect
case "${1:-}" in
  '') ;;
  --status) MODE=status ;;
  --arm) MODE=arm ;;
  --armed) MODE=armed ;;
  --help|-h)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")"
    exit 0 ;;
  *)
    printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
    exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  printf 'usage: %s [--status|--arm|--armed|--help]\n' "$(basename "$0")" >&2
  exit 2
fi

iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- evaluation -------------------------------------------------------------
#
# One call to the reading, one pass of jq over it. Everything the alarm decides
# on is in the tab-separated record jq returns, so the decision below can be
# read without re-deriving anything from the machine.
#
# VERDICT is one of: crossed, ok, unmeasured.

VERDICT=unmeasured
REASON=
DETAIL=
GROWTH_BLIND=
AVAIL_MIB=0
MINUTES=
GROWTH_MIB_MIN=0
OFFENDER=

evaluate() {
  local raw status=0 record

  if ! command -v jq >/dev/null 2>&1; then
    REASON="jq is not on PATH, so the reading could not be parsed"
    return
  fi
  if [ ! -x "$READING" ]; then
    REASON="the memory reading at $READING is missing or not executable, so there was nothing to read"
    return
  fi

  # The alarm keeps its own growth sample; see the header. --home is left to the
  # reading's own default so attribution scope stays the reading's decision.
  #
  # --status must not advance that sample. Growth is measured against the
  # previous run, so a human asking "what does the alarm see right now" would
  # otherwise reset the very interval the next real evaluation divides by, and
  # the alarm would go blind to growth exactly when somebody was looking at it.
  local store=()
  [ "$MODE" = status ] && store=(--no-store)
  raw=$(FM_MEMORY_SAMPLES="$SAMPLES" "$READING" --json "${store[@]}" 2>/dev/null) || status=$?

  if [ -z "$raw" ]; then
    REASON="the memory reading produced nothing (exit $status), so this machine is unmeasured rather than fine"
    return
  fi

  record=$(printf '%s' "$raw" | jq -r '
    def n0: if . == null then 0 else . end;
    (.headroom.available_kb | n0) as $avail_kb
    | ($avail_kb / 1024 | floor) as $avail_mib
    # Only positive growth counts. A process handing memory back does not buy
    # time against one taking it, and netting them off would let a shrinking
    # worker mask a growing one.
    | [.processes[] | select((.growth_kb_per_min | n0) > 0)] as $growing
    | ([$growing[].growth_kb_per_min] | add | n0) as $growth_kb_min
    | ($growing | sort_by(-.growth_kb_per_min) | first) as $top
    | (if $growth_kb_min > 0 then ($avail_kb / $growth_kb_min) else null end) as $minutes
    | (.complete == false) as $incomplete
    # A run with no comparable prior sample reports growth as SCOPED, and the
    # reading deliberately still exits 0 for it. That is a known absence, not a
    # broken instrument - but it is not a growth measurement either, and calling
    # it zero would be the substituted zero this whole programme refuses.
    | (.growth.scope_reason != null or .growth.unmeasured_reason != null) as $growth_blind
    | [
        (if $incomplete then "incomplete" else "complete" end),
        (if $growth_blind then (.growth.scope_reason // .growth.unmeasured_reason) else "" end),
        ($avail_mib | tostring),
        ($growth_kb_min / 1024 | floor | tostring),
        (if $minutes == null then "NA" else ($minutes * 10 | floor / 10 | tostring) end),
        (if $top == null then "" else $top.command end),
        (if $top == null then "" else ($top.pid | tostring) end),
        (if $top == null then "" else $top.account end),
        (if $top == null then "" else $top.attribution.kind end),
        (if $top == null then "" else $top.attribution.detail end),
        (if $top == null then "" else ($top.growth_kb_per_min / 1024 | floor | tostring) end),
        (if $top == null then "" elif $top.protected then "protected" else "ordinary" end),
        (if $incomplete then ([.unmeasured[] | .input + " (" + .reason + ")"] | join("; ")) else "" end)
      ]
    # Joined on the unit separator, NOT on a tab: a tab counts as whitespace to
    # the shell read below, so an empty field between two tabs collapses and
    # every column after it shifts one place left. An empty field here is
    # ordinary - it is how "no process was growing" and "growth was comparable"
    # are both said - so the delimiter has to be one that survives being empty.
    | map(gsub("[\n\r\u001f]"; " ")) | join("\u001f")
  ' 2>/dev/null)

  if [ -z "$record" ]; then
    REASON="the memory reading could not be parsed, so this machine is unmeasured rather than fine"
    return
  fi

  local completeness growth_blind unmeasured_list
  local top_cmd top_pid top_account top_kind top_detail top_growth top_protected
  IFS=$'\037' read -r completeness growth_blind AVAIL_MIB GROWTH_MIB_MIN MINUTES \
    top_cmd top_pid top_account top_kind top_detail top_growth top_protected unmeasured_list \
    <<<"$record"

  if [ "$completeness" = incomplete ] || [ "$status" -eq 3 ]; then
    REASON="the memory reading could not read every input, so whether this machine is in trouble is unknown"
    DETAIL="$unmeasured_list"
    return
  fi
  if [ "$status" -ne 0 ]; then
    REASON="the memory reading exited $status, so its numbers were not trusted"
    return
  fi

  if [ -n "$top_pid" ] && [ "${top_growth:-0}" -ge 1 ]; then
    # The reading distinguishes work it can name from work it cannot, and the
    # alarm must not blur them: an offender it cannot attribute is reported as
    # unattributed with the reason, never handed an owner no record names.
    case "$top_kind" in
      task)
        OFFENDER="$top_cmd (pid $top_pid), account $top_account, serving task $top_detail, growing $top_growth MiB/min" ;;
      firstmate-home)
        OFFENDER="$top_cmd (pid $top_pid), account $top_account, the firstmate session for $top_detail, growing $top_growth MiB/min" ;;
      infrastructure)
        OFFENDER="$top_cmd (pid $top_pid), account $top_account, $top_detail, growing $top_growth MiB/min" ;;
      *)
        OFFENDER="$top_cmd (pid $top_pid), account $top_account, growing $top_growth MiB/min - not attributed to any work: $top_detail" ;;
    esac
    # The label travels with the name. Anything reading this alarm later must
    # inherit the fact that this process is what makes every wake arrive, rather
    # than rediscovering it from a list it does not have.
    [ "$top_protected" = protected ] &&
      OFFENDER="$OFFENDER - and this is the wake-delivery listener, which nothing may act against"
  fi

  GROWTH_BLIND="$growth_blind"

  # Crossed if either condition holds. Recovery must clear BOTH by the margin.
  local crossed=no
  [ "$AVAIL_MIB" -lt "$FLOOR_MIB" ] && crossed=yes
  if [ -z "$GROWTH_BLIND" ] && [ "$MINUTES" != NA ] &&
     awk -v m="$MINUTES" -v h="$HORIZON_MIN" 'BEGIN { exit !(m + 0 < h + 0) }'; then
    crossed=yes
  fi

  if [ "$crossed" = yes ]; then
    VERDICT=crossed
    if [ "$AVAIL_MIB" -lt "$FLOOR_MIB" ]; then
      REASON="only $AVAIL_MIB MiB of RAM headroom is available, below the $FLOOR_MIB MiB floor"
    else
      REASON="growth across the running work totals $GROWTH_MIB_MIN MiB/min, which would use up the $AVAIL_MIB MiB RAM headroom still available without swapping in about $MINUTES minutes"
    fi
    return
  fi

  # Below the recovery bar but not crossed: still elevated, so a machine
  # hovering at the line is not repeatedly declared recovered.
  local floor_clear=yes horizon_clear=yes
  awk -v a="$AVAIL_MIB" -v f="$FLOOR_MIB" -v r="$RECOVERY" 'BEGIN { exit !(a + 0 >= f * r) }' || floor_clear=no
  if [ -z "$GROWTH_BLIND" ] && [ "$MINUTES" != NA ]; then
    awk -v m="$MINUTES" -v h="$HORIZON_MIN" -v r="$RECOVERY" 'BEGIN { exit !(m + 0 >= h * r) }' || horizon_clear=no
  fi

  if [ "$floor_clear" = yes ] && [ "$horizon_clear" = yes ]; then
    VERDICT=ok
    if [ -n "$GROWTH_BLIND" ]; then
      REASON="$AVAIL_MIB MiB RAM headroom available; growth was not comparable this run ($GROWTH_BLIND), so only headroom was judged"
    else
      REASON="$AVAIL_MIB MiB RAM headroom available, growth $GROWTH_MIB_MIN MiB/min"
      # Beyond a few hours the projection says nothing anyone would act on, and
      # printing four significant figures of it invites belief it has not earned.
      if [ "$MINUTES" != NA ] &&
         awk -v m="$MINUTES" 'BEGIN { exit !(m + 0 < 240) }'; then
        REASON="$REASON, about $MINUTES minutes of RAM headroom left at that rate"
      fi
    fi
  else
    VERDICT=elevated
    REASON="$AVAIL_MIB MiB RAM headroom available, growth $GROWTH_MIB_MIN MiB/min - past neither threshold, but not yet clear of them by the recovery margin"
    [ -z "$GROWTH_BLIND" ] || REASON="$AVAIL_MIB MiB RAM headroom available, and growth was not comparable this run ($GROWTH_BLIND)"
  fi
}

# --- durable record ---------------------------------------------------------

record_transition() {
  local from=$1 to=$2 line=$3
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s\t%s\t%s -> %s\t%s MiB RAM headroom available\t%s MiB/min growth\t%s minutes left\t%s\t%s\n' \
    "$NOW" "$(iso "$NOW")" "$from" "$to" "$AVAIL_MIB" "$GROWTH_MIB_MIN" "${MINUTES:-NA}" \
    "${OFFENDER:-no process was growing}" "$line" >>"$LOG" 2>/dev/null
}

read_state() {
  # The record is "<state> <epoch>", so the state is the FIRST field and not the
  # line. Reading the whole line here matches no case below, silently defaults
  # to ok, and then every poll of a continuing shortage looks like a fresh
  # crossing while recovery looks like no change at all.
  local first=
  [ -f "$STATE_FILE" ] && read -r first _ <"$STATE_FILE" 2>/dev/null
  case "${first:-}" in
    crossed|ok|unmeasured) printf '%s' "$first" ;;
    *) printf 'ok' ;;
  esac
}

read_state_since() {
  local since=
  [ -f "$STATE_FILE" ] && { read -r _ since <"$STATE_FILE" 2>/dev/null || true; }
  case "${since:-}" in ''|*[!0-9]*) printf '%s' "$NOW" ;; *) printf '%s' "$since" ;; esac
}

write_state() {
  local to=$1 since=$2
  mkdir -p "$STATE" 2>/dev/null || return 1
  printf '%s %s\n' "$to" "$since" >"$STATE_FILE" 2>/dev/null
}

human_duration() {
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%ds' "$((s / 60))" "$((s % 60))"
  else printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# --- modes ------------------------------------------------------------------

arm() {
  local desired current tmp
  desired=$(cat <<SHIM
#!/usr/bin/env bash
# GENERATED by bin/fm-memory-alarm.sh --arm - do not hand-edit.
#
# firstmate's watcher sweeps state/*.check.sh and wakes on any line one prints.
# This shim is only the seam: the thresholds, the evidence, and the decision
# about whether anything needs a human all live in the alarm itself, so they
# arrive by self-update instead of being frozen into every home's copy.
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$DATA"
exec "$SCRIPT_DIR/fm-memory-alarm.sh"
SHIM
)
  current=$(cat "$CHECK" 2>/dev/null || true)
  if [ "$current" != "$desired" ] || [ ! -x "$CHECK" ]; then
    umask 077
    tmp=$(mktemp "$STATE/.fm-memory-alarm-check.XXXXXX") || return 1
    printf '%s\n' "$desired" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
  fi
  "$SCRIPT_DIR/fm-check-register.sh" memory-alarm >/dev/null || return 1
}

armed_diagnostic() {
  local mtime age
  if [ ! -f "$CHECK" ] || [ ! -x "$CHECK" ]; then
    printf 'MEMORY_ALARM: nothing is watching this machine for RAM-headroom loss and runaway growth (fix: %s/fm-memory-alarm.sh --arm)\n' \
      "$SCRIPT_DIR"
    return 0
  fi
  if [ ! -f "$STATE_FILE" ]; then
    # Armed but never evaluated is only a fault once it has had time to run.
    mtime=$(stat -c %Y "$CHECK" 2>/dev/null) || return 0
    age=$((NOW - mtime))
    [ "$age" -gt "$STALE" ] &&
      printf 'MEMORY_ALARM: the memory watch was armed %s ago and has never completed a reading, so nothing is watching this machine (fix: %s/fm-memory-alarm.sh --status)\n' \
        "$(human_duration "$age")" "$SCRIPT_DIR"
    return 0
  fi
  mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null) || return 0
  age=$((NOW - mtime))
  [ "$age" -gt "$STALE" ] &&
    printf 'MEMORY_ALARM: the memory watch last read this machine %s ago and has stopped running, so nothing is watching it now (fix: %s/fm-memory-alarm.sh --status)\n' \
      "$(human_duration "$age")" "$SCRIPT_DIR"
  return 0
}

case "$MODE" in
  arm)
    arm || { printf 'fm-memory-alarm: cannot arm the memory watch in %s\n' "$STATE" >&2; exit 1; }
    printf 'armed: %s\n' "$CHECK"
    exit 0 ;;
  armed)
    [ "${FM_MEMORY_ALARM_DISABLE:-0}" = 1 ] && exit 0
    armed_diagnostic
    exit 0 ;;
  status)
    evaluate
    case "$VERDICT" in
      crossed)
        printf 'memory-alarm: CROSSED - %s\n' "$REASON"
        printf 'largest grower: %s\n' "${OFFENDER:-none: no tracked process was growing, so the memory went somewhere this reading does not attribute}"
        printf 'nothing has been limited, throttled, or killed by this alarm, and nothing here can be\n'
        exit 4 ;;
      unmeasured)
        printf 'memory-alarm: UNMEASURED - %s\n' "$REASON"
        [ -z "$DETAIL" ] || printf 'unmeasured inputs: %s\n' "$DETAIL"
        printf 'this is not an all-clear: the machine may be in trouble and this could not tell\n'
        exit 3 ;;
      *)
        printf 'memory-alarm: %s - %s\n' "$VERDICT" "$REASON"
        [ -z "$OFFENDER" ] || printf 'largest grower: %s\n' "$OFFENDER"
        exit 0 ;;
    esac ;;
esac

# --- detect -----------------------------------------------------------------
#
# The watcher reads the line, not the exit status, so this mode always exits 0.
# It speaks only when the state changes.

[ "${FM_MEMORY_ALARM_DISABLE:-0}" = 1 ] && exit 0

evaluate

PREVIOUS=$(read_state)
SINCE=$(read_state_since)

# Recovery from a crossing must be earned. When growth could not be compared,
# the horizon condition was never evaluated this run, so a calm verdict rests on
# headroom alone. That is enough to stay quiet while already quiet, and never
# enough to declare a shortage over - so a crossing lapses into "cannot see"
# rather than into a recovery nobody measured.
if [ "$VERDICT" = ok ] && [ -n "$GROWTH_BLIND" ] && [ "$PREVIOUS" = crossed ]; then
  VERDICT=unmeasured
  REASON="whether the shortage is over is unknown: growth could not be compared this run ($GROWTH_BLIND), so the condition that raised the alarm was not re-evaluated"
fi

# elevated is a damping band, not a state worth announcing: it exists so that a
# machine hovering at the line does not alternate between crossed and recovered.
# It holds whatever the previous state was.
CURRENT=$VERDICT
[ "$CURRENT" = elevated ] && CURRENT=$PREVIOUS

if [ "$CURRENT" = "$PREVIOUS" ]; then
  write_state "$CURRENT" "$SINCE" ||
    printf 'MEMORY_ALARM: the memory watch could not persist its %s state in %s; this poll was measured but not durably completed.\n' \
      "$CURRENT" "$STATE_FILE"
  exit 0
fi

LINE=
case "$CURRENT" in
  crossed)
    LINE="MEMORY_ALARM: this machine is running out of RAM headroom - $REASON. Largest grower: ${OFFENDER:-no tracked process was growing, so the headroom is going somewhere this reading does not attribute}. Nothing has been limited or killed."
    ;;
  ok)
    if [ "$PREVIOUS" = crossed ]; then
      LINE="MEMORY_ALARM: recovered - $REASON. The shortage lasted $(human_duration "$((NOW - SINCE))")."
    else
      LINE="MEMORY_ALARM: the memory watch can see this machine again - $REASON."
    fi
    ;;
  unmeasured)
    LINE="MEMORY_ALARM: the memory watch has gone blind - $REASON. This is not an all-clear."
    [ -z "$DETAIL" ] || LINE="$LINE Unmeasured: $DETAIL"
    ;;
esac

if ! record_transition "$PREVIOUS" "$CURRENT" "$LINE"; then
  printf 'MEMORY_ALARM: the memory watch could not record the %s to %s transition in %s; the transition was measured but not durably completed.\n' \
    "$PREVIOUS" "$CURRENT" "$LOG"
  exit 0
fi
if ! write_state "$CURRENT" "$NOW"; then
  printf 'MEMORY_ALARM: the memory watch recorded the %s to %s transition but could not persist its new state in %s; the transition was not durably completed.\n' \
    "$PREVIOUS" "$CURRENT" "$STATE_FILE"
  exit 0
fi
printf '%s\n' "$LINE"
exit 0
