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
# here is crossed thousands of times by ordinary file reading with 16 GB RAM
# headroom, because a cgroup's charge includes page cache and page cache expands
# into whatever ceiling exists. Worse, holding a cgroup at a ceiling generates
# memory-stall time on the same reading this alarm consumes, so the ceiling
# would have manufactured its own alarm condition. docs/memory-ceiling-caveat.md
# owns that finding and bin/fm-memory-ceiling-probe.sh re-measures it; a
# proposed container ceiling must be checked against that caveat rather than
# assumed safe because swap now exists.
# So this alarm fires on headroom, on growth, and on memory stall held past a
# window - the three conditions below - and nothing here limits,
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
# Incompleteness is per-condition, though, and never blanket. One unreadable
# input must not silence the conditions whose OWN inputs are present, or a
# kernel that has simply never accounted memory stall would take headroom and
# horizon down with it. RAM headroom is the single input nothing here can
# proceed without, because both other conditions divide by it; if it is
# unmeasured no verdict is reached at all. Otherwise every condition whose
# input was read is judged, every condition whose input was not is reported as
# unjudged, every unmeasured input is named on the same reading, and a verdict
# reached from an incomplete reading says so rather than passing for an
# unqualified all-clear.
#
# THE THREE CONDITIONS, AND WHY EACH IS NEEDED
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
#   stall      host memory pressure-stall `full avg60` at or above the stall
#              threshold. The two conditions above both divide by MemAvailable,
#              which the kernel defines as memory available to new work WITHOUT
#              SWAPPING - so once pressure has already been absorbed into swap,
#              both of them read healthy while the machine is unusable. This
#              condition measures the wait itself rather than the shortage that
#              causes it, so it can see a machine that is ALREADY drowning
#              rather than only one about to run out.
#              It reads `full` rather than `some` deliberately. `some` counts
#              time in which ANY task waited on memory, which one process
#              refaulting can produce on an otherwise healthy machine. `full`
#              counts time in which NOTHING could run at all, which is the
#              condition that makes a seat unreachable - in the incident this
#              was built for, the seat's own agent was one of the blocked
#              processes. `some` is still reported as evidence beside it.
#              It reads the 60-second window rather than the 10-second one
#              because the alarm polls every 300 seconds: avg60 covers six
#              times more of that interval, and every seat the fleet has
#              sampled measured the same 0.00 on both, so the longer window
#              costs nothing measurable and rejects more.
# The process NAMED differs by condition, because the shapes differ. headroom
# and horizon name the largest contributor to growth. stall names the largest
# RESIDENT process instead: in the shape that condition exists for, the memory
# was taken hours earlier and nothing is growing now, so a growth ranking would
# name nobody at exactly the moment somebody needs naming. Either way the
# condition is about the machine and the name is about who to talk to, and both
# carry the account, the attributed work, and the protected label.
#
# It self-tightens as RAM headroom goes, which is the property that makes one
# horizon work across the whole range: at 16 GB RAM headroom it takes more than
# 1 GiB/min to trip, and at 2 GB RAM headroom it takes 136 MiB/min.
#
# HOW THE THRESHOLDS WERE CHOSEN, AND WHAT WOULD HAVE TO HAPPEN TO CROSS THEM
# Both are derived from measurements recorded in docs/memory-alarm.md, not
# picked. In short:
#   horizon    3x the watcher's 300s check sweep, so a crossing is seen at
#              least twice before the RAM headroom it predicts is gone. A
#              horizon shorter than that cadence could go from silent to
#              reclaim or swap pressure between two polls without ever firing.
#   stall      DURATION, not level. No magnitude separates the two states:
#              measured on coditan-vessel on 2026-08-28, this repo's own
#              tooling drove windowed full memory stall to 29.30 on a healthy
#              seat that never fell below 11,325 MiB of RAM headroom, against
#              the 37.74% a real 22-hour starvation produced. What does
#              separate them is that ordinary work FINISHES: the healthy seat
#              recovered the instant the load stopped, and the incident ran
#              21h45m and would have kept going. So the gate is set just above
#              the measured quiet band and the WINDOW does the discriminating.
#              The window is 1.67x the longest continuous heavy job this
#              repository can produce - lint then the full suite, measured at
#              4311s - and 33x the longest stretch any ordinary work was
#              measured holding the gate at all. docs/memory-alarm.md owns
#              both measurements.
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
#   0  --status: at least one condition was judged, and none crossed
#   4  --status: crossed
#   3  --status: NO condition could be judged, so no verdict is issued. An
#      incomplete reading alone does not produce this: a reading missing an
#      input no condition needs still yields the verdict of the conditions it
#      could judge, and names what it could not read alongside it.
#   2  usage error
#
# Durable record, under FM_HOME/data:
#   memory-alarm.log   one append-only line per spoken change, crossing,
#                      recovery and change of watch alike, each carrying the
#                      evidence it was decided on and a `watch=` field naming
#                      the conditions whose INSTRUMENT could not be read on that
#                      poll (`watch=all` when all three were readable). It lives
#                      in data/ rather than state/ because the question it
#                      answers - has this happened before, and what was running
#                      - is asked long after the volatile record of the moment
#                      is gone.
#
# State, under FM_HOME/state:
#   memory-alarm.state    "<state> <epoch> <watch>". The last state this alarm
#                         decided, so a transition can be told from a
#                         continuation, and the set of conditions whose
#                         INSTRUMENT could not be read on that poll -
#                         `headroom,horizon,stall` in that order, or `-` when
#                         all three were readable. It is deliberately narrower
#                         than "went unjudged": a condition suppressed by an
#                         expected, self-clearing absence of data - no stored
#                         growth sample yet, one too young to divide by, one
#                         aged past its window - is scope rather than
#                         blindness, resolves on the next poll that stores a
#                         sample, and never enters the set. The watch
#                         set is carried because a machine only PARTLY watched
#                         is not a watched machine: a change in it is a
#                         transition and is spoken once, exactly as a crossing
#                         is, so a condition that goes unreadable can never
#                         pass in silence and can never nag on every poll
#                         either. A record written before this field existed
#                         reads as `-`.
#   memory-alarm.stall    the run of consecutive polls that have seen this
#                         machine stalling: the epoch the current run began and
#                         the epoch of the last poll that continued it. A run
#                         is what the stall condition measures, so it has to
#                         outlive the poll that observed it. It records the
#                         last poll as well as the first because a gap in
#                         polling means the polls were not consecutive, and a
#                         run nobody was watching is not a run that was seen.
#   memory-alarm.samples  this alarm's OWN growth sample, kept apart from the
#                         reading's, so that an operator running the reading by
#                         hand does not reset what the alarm compares against.
#                         Without it the alarm would go blind to growth exactly
#                         when somebody is looking at the machine.
#   memory-alarm.check.sh the armed watcher check (with .check-trust)
#
# Environment:
#   FM_MEMORY_ALARM_FLOOR_MIB    headroom floor in MiB (default 2400)
#   FM_MEMORY_ALARM_HORIZON_MIN  RAM-headroom horizon in minutes (default 15)
#   FM_MEMORY_ALARM_STALL        host memory pressure-stall `full avg60` at or
#                                above which this machine counts as stalling at
#                                all, as a percentage of wall time
#                                (default 1.00). This is a gate, not a
#                                severity judgement: crossing it starts a
#                                clock rather than raising an alarm. Set it to
#                                the empty string to leave the condition
#                                unconfigured, in which case it fires nothing
#                                and every verdict says so. A value that is not
#                                a usable percentage, and a zero - which no
#                                reading can ever fall below, so it would hold
#                                this condition crossed forever - are typos
#                                rather than choices, so each falls back to the
#                                default and every verdict says that instead.
#   FM_MEMORY_ALARM_STALL_WINDOW how long, in seconds, the stall must stay at
#                                or above that gate CONTINUOUSLY before the
#                                condition crosses (default 7200, two hours).
#                                This is the discriminator; see above. A zero
#                                window would cross on the first poll of a
#                                machine that is not stalling at all, so it
#                                falls back to the default and every verdict
#                                says that instead.
#   FM_MEMORY_ALARM_RECOVERY     margin a reading must clear all three
#                                conditions by before recovery is declared:
#                                headroom and horizon must beat their
#                                thresholds by this multiple, and the stall run
#                                multiplied by it must still fit inside the
#                                window, because that condition crosses on
#                                duration rather than on a level (default 1.25)
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
STALL_RUN_FILE="$STATE/memory-alarm.stall"
CHECK="$STATE/memory-alarm.check.sh"

FLOOR_MIB=${FM_MEMORY_ALARM_FLOOR_MIB:-2400}
HORIZON_MIN=${FM_MEMORY_ALARM_HORIZON_MIN:-15}
STALL_MAX=${FM_MEMORY_ALARM_STALL-1.00}
STALL_WINDOW=${FM_MEMORY_ALARM_STALL_WINDOW:-7200}
RECOVERY=${FM_MEMORY_ALARM_RECOVERY:-1.25}
STALE=${FM_MEMORY_ALARM_STALE:-1800}
NOW=${FM_MEMORY_ALARM_NOW:-$(date +%s)}

case "$FLOOR_MIB" in *[!0-9]*|'') FLOOR_MIB=2400 ;; esac
case "$HORIZON_MIN" in *[!0-9]*|'') HORIZON_MIN=15 ;; esac
case "$STALE" in *[!0-9]*|'') STALE=1800 ;; esac
# A stall threshold is a percentage and so may carry one decimal point. An
# EMPTY one leaves the condition unconfigured, which is a deliberate choice a
# home can make. A MALFORMED one is not a choice, it is a typo, so it falls back
# to the shipped default the way every sibling threshold above does rather than
# switching the newest condition off on a home that meant to have it. Either way
# it never reaches awk, where an unparsable value would compare as zero and hold
# the condition crossed forever.
#
# A gate of zero is the same failure wearing a parsable face: no reading can
# ever fall below it, so an idle machine reads as stalling on every poll, the
# run never resets, and past the window the alarm is pinned crossed with nothing
# wrong. It is the value an operator reaches for to mean "off" - the documented
# off switch is the empty string - so it falls back rather than firing.
STALL_GATE_NOTE=
case "$STALL_MAX" in
  '') ;;
  .|*.|*[!0-9.]*|*.*.*)
    STALL_MAX=1.00
    STALL_GATE_NOTE="the FM_MEMORY_ALARM_STALL configured for this home was not a usable percentage, so the shipped default gate of $STALL_MAX% is in force instead of it" ;;
  *)
    if ! awk -v g="$STALL_MAX" 'BEGIN { exit !(g + 0 > 0) }'; then
      STALL_MAX=1.00
      STALL_GATE_NOTE="the FM_MEMORY_ALARM_STALL configured for this home was zero, which no reading can ever fall below, so the shipped default gate of $STALL_MAX% is in force instead of it"
    fi ;;
esac
case "$STALL_WINDOW" in *[!0-9]*|'') STALL_WINDOW=7200 ;; esac
# A zero window is worse than a zero gate: the run test is `>=`, so it holds on
# a machine that has not stalled for a single second and crosses on the first
# poll.
if [ "$STALL_WINDOW" -le 0 ]; then
  STALL_WINDOW=7200
  STALL_GATE_NOTE="${STALL_GATE_NOTE:+$STALL_GATE_NOTE, and }the FM_MEMORY_ALARM_STALL_WINDOW configured for this home was zero, which any run at all outlasts, so the shipped default window of $STALL_WINDOW seconds is in force instead of it"
fi

# A run of polls is only a run if the polls happened. The watcher makes checks
# due after 300s and observes that on a 15s loop, so one slot is at most 315s;
# 1260s is four of those, the same figure docs/memory-alarm.md derives for the
# growth sample. A longer gap than that means nobody was watching, and a run
# nobody was watching is restarted rather than credited.
STALL_CONTINUITY_MAX=1260

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
GROWTH_SCOPED=
STALL_BLIND=
STALL_UNSET=
AVAIL_MIB=0
MINUTES=
GROWTH_MIB_MIN=0
STALL_FULL60=
STALL_SOME60=
STALL_RUN_SECONDS=0
STALL_ACTIVE=
STALL_RUN_UNPERSISTED=
READING_INCOMPLETE=
SWAP_USED_MIB=
OFFENDER=
RESIDENT=
CROSS_KIND=

# Which of the three conditions had an INSTRUMENT this poll could not read, in a
# fixed order so two polls that saw the same thing produce the same string. It is
# derived from the flags the conditions already keep rather than tracked
# separately, so it can never disagree with what the verdict says. A verdict of
# unmeasured means no condition was reached at all, whatever the reason.
unjudged_conditions() {
  local set=
  if [ "$VERDICT" = unmeasured ]; then
    printf 'headroom,horizon,stall'
    return
  fi
  # Only a condition whose instrument failed counts here. Growth that could not
  # be compared because the stored SAMPLE was absent, too young, too old or
  # unreadable is data this run did not have, and the next poll that stores one
  # repairs it - counting that would announce a loss and a regain of sight on
  # the second poll of every fresh home, and again after any watcher gap past
  # the sample window. Only the process TABLE being unreadable is the horizon's
  # instrument failing.
  if [ -n "$GROWTH_BLIND" ] && [ -z "$GROWTH_SCOPED" ]; then set=horizon; fi
  if [ -n "$STALL_BLIND" ] || [ -n "$STALL_UNSET" ]; then
    set="${set:+$set,}stall"
  fi
  printf '%s' "${set:--}"
}

# A threshold this alarm substituted for an unusable one is stated on every
# verdict, whichever one is reached, so a fallback can never be mistaken for a
# home that chose the number.
stall_gate_note() {
  [ -z "$STALL_GATE_NOTE" ] || REASON="$REASON; $STALL_GATE_NOTE"
}

# A verdict reached from a reading that could not read every input carries that
# fact in the same breath, because "all three read clear" and "one input was
# never read" are exactly the two things this alarm exists to keep apart. The
# inputs themselves are named in the detail that travels with the verdict.
incomplete_note() {
  [ -z "$READING_INCOMPLETE" ] ||
    REASON="$REASON; the reading this came from could not read every input, so it is not a full all-clear"
}

# The reading distinguishes work it can name from work it cannot, and the alarm
# must not blur them: a process it cannot attribute is reported as unattributed
# with the reason, never handed an owner no record names. Both the grower the
# headroom and horizon conditions name and the resident process the stall
# condition names are phrased here, once, so the two can never drift apart.
name_process() {  # <command> <pid> <account> <kind> <detail> <protected> <measure>
  local cmd=$1 pid=$2 account=$3 kind=$4 detail=$5 protected=$6 measure=$7 named
  case "$kind" in
    task)           named="$cmd (pid $pid), account $account, serving task $detail, $measure" ;;
    firstmate-home) named="$cmd (pid $pid), account $account, the firstmate session for $detail, $measure" ;;
    infrastructure) named="$cmd (pid $pid), account $account, $detail, $measure" ;;
    *)              named="$cmd (pid $pid), account $account, $measure - not attributed to any work: $detail" ;;
  esac
  # The label travels with the name. Anything reading this alarm later must
  # inherit the fact that this process is what makes every wake arrive, rather
  # than rediscovering it from a list it does not have.
  [ "$protected" = protected ] &&
    named="$named - and this is the wake-delivery listener, which nothing may act against"
  printf '%s' "$named"
}

evaluate() {
  local raw status=0 record

  if ! command -v jq >/dev/null 2>&1; then
    REASON="jq is not on PATH, so the reading could not be parsed"
    stall_gate_note
    return
  fi
  if [ ! -x "$READING" ]; then
    REASON="the memory reading at $READING is missing or not executable, so there was nothing to read"
    stall_gate_note
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
    stall_gate_note
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
    # The stall condition names the largest RESIDENT process, not the largest
    # grower: in the shape it exists for the memory was taken hours ago and
    # nothing is growing, so ranking by growth would name nobody.
    | ([.processes[] | select((.rss_kb | n0) > 0)] | sort_by(-.rss_kb) | first) as $res
    | (.headroom.swap_free_kb) as $swap_free_kb
    | (if $swap_free_kb == null then null
       else (((.headroom.swap_total_kb | n0) - $swap_free_kb) / 1024 | floor) end) as $swap_used_mib
    | (.complete == false) as $incomplete
    # The one input no condition here can do without: the floor measures
    # headroom and the horizon divides by it. Tested before the n0 above
    # substitutes a zero for it, because a substituted zero would read as a
    # machine with no memory left.
    | (.headroom.available_kb == null) as $headroom_blind
    # A run with no comparable prior sample reports growth as SCOPED, and the
    # reading deliberately still exits 0 for it. That is a known absence, not a
    # broken instrument - but it is not a growth measurement either, and calling
    # it zero would be the substituted zero this whole programme refuses.
    | (.growth.scope_reason != null or .growth.unmeasured_reason != null) as $growth_blind
    # Scope is not a failed instrument. A first run with no stored sample to
    # compare against declares that absence and the very next poll resolves it,
    # so it suppresses the horizon condition for this poll without meaning the
    # machine has stopped being watched for growth.
    | (.growth.scope_reason != null) as $growth_scoped
    # Growth can go unjudged for two quite different reasons, and only one of
    # them is an instrument failing. The stored SAMPLE being absent, too young,
    # too old, dated in the future or unreadable is data this run did not have,
    # and the next poll that stores one repairs it. The process TABLE being
    # unreadable is the instrument itself.
    | ((.unmeasured // []) | map(.input) | index("processes") != null) as $processes_blind
    # A completeness claim is not a stall measurement. The reading marks a
    # missing or unparsable pressure file unmeasured, so this should never fire
    # on a real reading - but if the number is absent while the reading calls
    # itself complete, the condition was not evaluated, and the one thing this
    # alarm may never do is turn that into a zero.
    | (.stall.full_avg60 == null) as $stall_blind
    | [
        (if $incomplete then "incomplete" else "complete" end),
        (if $headroom_blind then "blind" else "read" end),
        (if $growth_blind then (.growth.scope_reason // .growth.unmeasured_reason) else "" end),
        (if $growth_scoped or ($growth_blind and ($processes_blind | not)) then "scoped" else "" end),
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
        (if $incomplete then ([.unmeasured[] | .input + " (" + .reason + ")"] | join("; ")) else "" end),
        (if $stall_blind then "the reading carried no host memory-stall average" else "" end),
        (if $stall_blind then "" else (.stall.full_avg60 | tostring) end),
        (if (.stall.some_avg60) == null then "" else (.stall.some_avg60 | tostring) end),
        (if $swap_used_mib == null then "" else ($swap_used_mib | tostring) end),
        (if $res == null then "" else $res.command end),
        (if $res == null then "" else ($res.pid | tostring) end),
        (if $res == null then "" else $res.account end),
        (if $res == null then "" else $res.attribution.kind end),
        (if $res == null then "" else $res.attribution.detail end),
        (if $res == null then "" else ($res.rss_kb / 1024 | floor | tostring) end),
        (if $res == null then "" elif $res.protected then "protected" else "ordinary" end)
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
    stall_gate_note
    return
  fi

  local completeness headroom_state growth_blind growth_scoped unmeasured_list
  local top_cmd top_pid top_account top_kind top_detail top_growth top_protected
  local res_cmd res_pid res_account res_kind res_detail res_rss res_protected
  IFS=$'\037' read -r completeness headroom_state growth_blind growth_scoped AVAIL_MIB GROWTH_MIB_MIN MINUTES \
    top_cmd top_pid top_account top_kind top_detail top_growth top_protected unmeasured_list \
    STALL_BLIND STALL_FULL60 STALL_SOME60 SWAP_USED_MIB \
    res_cmd res_pid res_account res_kind res_detail res_rss res_protected \
    <<<"$record"

  # Every unmeasured input is named whatever verdict follows, because the
  # reading's contract is that an input nobody could read is never invisible.
  if [ "$completeness" = incomplete ] || [ "$status" -eq 3 ]; then
    READING_INCOMPLETE=yes
    DETAIL="$unmeasured_list"
  fi

  if [ "$headroom_state" = blind ]; then
    REASON="the memory reading could not read this machine's RAM headroom, so no condition could be judged and whether this machine is in trouble is unknown"
    stall_gate_note
    return
  fi
  # Exit 3 is the reading's incompleteness status and is handled above; any
  # other non-zero exit means its numbers themselves are not to be trusted.
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    REASON="the memory reading exited $status, so its numbers were not trusted"
    stall_gate_note
    return
  fi

  if [ -n "$top_pid" ] && [ "${top_growth:-0}" -ge 1 ]; then
    OFFENDER=$(name_process "$top_cmd" "$top_pid" "$top_account" "$top_kind" "$top_detail" \
      "$top_protected" "growing $top_growth MiB/min")
  fi
  if [ -n "$res_pid" ]; then
    RESIDENT=$(name_process "$res_cmd" "$res_pid" "$res_account" "$res_kind" "$res_detail" \
      "$res_protected" "holding $res_rss MiB resident")
  fi

  GROWTH_BLIND="$growth_blind"
  GROWTH_SCOPED="$growth_scoped"
  # Two different silences, and they must never be merged. STALL_BLIND means the
  # instrument failed, which blocks a recovery because the condition that raised
  # an alarm could not be re-read. STALL_UNSET means the fleet has not chosen a
  # threshold, so this condition never raised anything and cannot hold a
  # recovery back - but it is still reported, because a condition nobody is
  # watching has to say so rather than pass for a clear reading.
  [ -n "$STALL_MAX" ] || STALL_UNSET="no stall gate is configured for this home, so this machine is not being watched for memory stall at all"
  read_stall_run

  # Crossed if ANY condition holds. Recovery must clear ALL of them by the
  # margin, so adding a condition can only make recovery harder to declare.
  local crossed=no
  [ "$AVAIL_MIB" -lt "$FLOOR_MIB" ] && { crossed=yes; CROSS_KIND=headroom; }
  if [ -z "$GROWTH_BLIND" ] && [ "$MINUTES" != NA ] &&
     awk -v m="$MINUTES" -v h="$HORIZON_MIN" 'BEGIN { exit !(m + 0 < h + 0) }'; then
    crossed=yes
    [ -n "$CROSS_KIND" ] || CROSS_KIND=horizon
  fi
  # DURATION, not level. Being over the gate starts the clock; only running
  # past the window crosses. Ordinary heavy work goes over the gate routinely
  # and never reaches the window, because it finishes.
  if [ -z "$STALL_BLIND" ] && [ -z "$STALL_UNSET" ] &&
     [ "$STALL_RUN_SECONDS" -ge "$STALL_WINDOW" ]; then
    crossed=yes
    [ -n "$CROSS_KIND" ] || CROSS_KIND=stall
  fi

  if [ "$crossed" = yes ]; then
    VERDICT=crossed
    case "$CROSS_KIND" in
      headroom)
        REASON="only $AVAIL_MIB MiB of RAM headroom is available, below the $FLOOR_MIB MiB floor" ;;
      horizon)
        REASON="growth across the running work totals $GROWTH_MIB_MIN MiB/min, which would use up the $AVAIL_MIB MiB RAM headroom still available without swapping in about $MINUTES minutes" ;;
      stall)
        # Lead with the duration, because the duration is the finding. The level
        # alone says nothing: ordinary work reaches it and stops, and this one
        # has not stopped. State the healthy headroom in the same breath, or a
        # reader will go looking for a shortage that is not there.
        REASON="this machine has been stalling on memory continuously for $(human_duration "$STALL_RUN_SECONDS"), past the $(human_duration "$STALL_WINDOW") that the longest heavy job this repository can run fits inside - work that finishes stops stalling, and this has not. Nothing could run at all for $STALL_FULL60% of the last 60 seconds. $AVAIL_MIB MiB of RAM headroom still looks available, but that figure counts only memory available WITHOUT swapping, so it reads healthy once the pressure has already been absorbed"
        [ -z "$STALL_SOME60" ] ||
          REASON="$REASON. At least one task was waiting for $STALL_SOME60% of it"
        if [ -n "$SWAP_USED_MIB" ]; then
          REASON="$REASON. Swap in use: $SWAP_USED_MIB MiB"
        else
          REASON="$REASON. Swap use could not be read"
        fi ;;
    esac
    incomplete_note
    stall_gate_note
    return
  fi

  # Below the recovery bar but not crossed: still elevated, so a machine
  # hovering at the line is not repeatedly declared recovered.
  local floor_clear=yes horizon_clear=yes stall_clear=yes
  awk -v a="$AVAIL_MIB" -v f="$FLOOR_MIB" -v r="$RECOVERY" 'BEGIN { exit !(a + 0 >= f * r) }' || floor_clear=no
  if [ -z "$GROWTH_BLIND" ] && [ "$MINUTES" != NA ]; then
    awk -v m="$MINUTES" -v h="$HORIZON_MIN" -v r="$RECOVERY" 'BEGIN { exit !(m + 0 >= h * r) }' || horizon_clear=no
  fi
  # This condition crosses on duration, so it clears on duration too: the run
  # must fit inside the window with the margin applied to it, because a crossing
  # here is a LONG run. The margin multiplies the run rather than dividing the
  # window so that an unusable RECOVERY degrades to zero and still clears, the
  # same harmless way it does for the two conditions above, instead of making
  # awk divide by zero and pinning this machine at elevated forever.
  # It deliberately does not test the instantaneous level: ordinary heavy work
  # goes over the gate all the time, and holding a headroom recovery back
  # because somebody is running the linter would change what the other two
  # conditions do, which this addition may not.
  if [ -z "$STALL_BLIND" ] && [ -z "$STALL_UNSET" ]; then
    awk -v r="$STALL_RUN_SECONDS" -v w="$STALL_WINDOW" -v m="$RECOVERY" 'BEGIN { exit !(r * m <= w + 0) }' || stall_clear=no
  fi

  # A calm verdict has to say which conditions it actually judged, because the
  # difference between "all three read clear" and "one of them was never
  # evaluated" is exactly the difference this alarm exists to keep visible.
  local unjudged="" unjudged_tail="so that condition was not judged"
  [ -z "$GROWTH_BLIND" ] || unjudged="growth was not comparable this run ($GROWTH_BLIND)"
  local stall_note=
  if [ -n "$STALL_BLIND" ]; then
    stall_note="memory stall could not be read this run ($STALL_BLIND)"
  elif [ -n "$STALL_UNSET" ]; then
    stall_note="$STALL_UNSET"
  fi
  if [ -n "$stall_note" ]; then
    if [ -z "$unjudged" ]; then
      unjudged="$stall_note"
    else
      unjudged="$unjudged, and $stall_note"
      unjudged_tail="so neither condition was judged"
    fi
  fi

  REASON="$AVAIL_MIB MiB RAM headroom available"
  [ -n "$GROWTH_BLIND" ] || REASON="$REASON, growth $GROWTH_MIB_MIN MiB/min"
  if [ -z "$STALL_BLIND" ] && [ -z "$STALL_UNSET" ]; then
    REASON="$REASON, memory stall $STALL_FULL60% with nothing able to run"
    # A run under way on a calm machine is worth stating: it is the clock this
    # condition decides on, and a reader who cannot see it cannot tell an
    # ordinary busy stretch from the start of something that will not stop.
    [ -z "$STALL_ACTIVE" ] ||
      REASON="$REASON, stalling for $(human_duration "$STALL_RUN_SECONDS") of the $(human_duration "$STALL_WINDOW") it would take to count"
  fi

  if [ "$floor_clear" = yes ] && [ "$horizon_clear" = yes ] && [ "$stall_clear" = yes ]; then
    VERDICT=ok
    # Beyond a few hours the projection says nothing anyone would act on, and
    # printing four significant figures of it invites belief it has not earned.
    if [ -z "$GROWTH_BLIND" ] && [ "$MINUTES" != NA ] &&
       awk -v m="$MINUTES" 'BEGIN { exit !(m + 0 < 240) }'; then
      REASON="$REASON, about $MINUTES minutes of RAM headroom left at that rate"
    fi
    [ -z "$unjudged" ] || REASON="$REASON; $unjudged, $unjudged_tail"
  else
    VERDICT=elevated
    REASON="$REASON - past no threshold, but not yet clear of them all by the recovery margin"
    [ -z "$unjudged" ] || REASON="$REASON; $unjudged, $unjudged_tail"
  fi
  incomplete_note
  stall_gate_note
}

# --- the stall run ----------------------------------------------------------
#
# The stall condition measures a RUN of consecutive polls that saw this machine
# stalling, so the run has to outlive the poll that observed it. This reads it,
# extends it, and returns how long it has been going.
#
# Only detect mode writes. --status must not extend a run, for the same reason
# it must not advance the growth sample: somebody asking what the alarm sees
# right now would otherwise be feeding the clock they are reading.

read_stall_run() {  # sets STALL_RUN_SECONDS, and STALL_ACTIVE when a run is on
  local start="" last="" stalling=no

  # A poll that could not read the account is not a poll that saw a calm
  # machine, and it must not be treated more harshly than a poll that never
  # happened at all: a gap is forgiven up to the continuity limit, so a blind
  # reading is too. It neither extends the run nor erases it - the file is left
  # exactly as it stands, and the continuity limit decides on the next poll that
  # can actually see. Blindness that lasts therefore expires the run by the same
  # rule a silent watcher does.
  if [ -n "$STALL_BLIND" ]; then
    STALL_RUN_SECONDS=0
    STALL_ACTIVE=
    return
  fi

  if [ -n "$STALL_MAX" ] &&
     awk -v s="$STALL_FULL60" -v g="$STALL_MAX" 'BEGIN { exit !(s + 0 >= g + 0) }'; then
    stalling=yes
  fi

  if [ -f "$STALL_RUN_FILE" ]; then
    read -r start last _ <"$STALL_RUN_FILE" 2>/dev/null || true
    case "${start:-}" in ''|*[!0-9]*) start= ;; esac
    case "${last:-}" in ''|*[!0-9]*) last= ;; esac
  fi

  if [ "$stalling" != yes ]; then
    # The run is over. Clearing it is the whole reason ordinary work does not
    # reach the window: it finishes, and the clock goes back to zero.
    #
    # Unlinking needs a writable DIRECTORY, so it can fail while the run file
    # itself is still perfectly writable - and a run file that survives a failed
    # clear is worse than one that could not be written, because a later poll
    # reads the old start back and credits the run straight across the calm poll
    # that should have reset it, crossing the window on a machine that was never
    # stalling continuously. So truncation is the fallback: it needs only the
    # file, and it leaves content the start/last validation above rejects, which
    # is what invalidates the stale run. Only when neither works is the run
    # genuinely beyond this alarm's control, and then it says so.
    if [ "$MODE" != status ] && ! rm -f -- "$STALL_RUN_FILE" 2>/dev/null &&
       ! : 2>/dev/null >"$STALL_RUN_FILE"; then
      STALL_RUN_UNPERSISTED=yes
    fi
    STALL_RUN_SECONDS=0
    STALL_ACTIVE=
    return
  fi

  STALL_ACTIVE=yes
  if [ -z "$start" ] || [ -z "$last" ] || [ "$((NOW - last))" -gt "$STALL_CONTINUITY_MAX" ] ||
     [ "$NOW" -lt "$start" ]; then
    start=$NOW
  fi
  STALL_RUN_SECONDS=$((NOW - start))
  [ "$STALL_RUN_SECONDS" -ge 0 ] || STALL_RUN_SECONDS=0
  if [ "$MODE" != status ]; then
    # 2>/dev/null comes FIRST: a redirection that cannot be opened is reported
    # by the shell as it applies them, left to right, so suppressing stderr
    # afterwards would leave the raw error on the watcher's own output line.
    if ! { mkdir -p "$STATE" 2>/dev/null &&
           printf '%s %s\n' "$start" "$NOW" 2>/dev/null >"$STALL_RUN_FILE"; }; then
      STALL_RUN_UNPERSISTED=yes
    fi
  fi
}

# --- durable record ---------------------------------------------------------

record_transition() {
  local from=$1 to=$2 line=$3 named
  mkdir -p "$DATA" 2>/dev/null || return 1
  # A stall crossing records the resident process, because that is the evidence
  # it was decided on; recording "no process was growing" for it would file the
  # absence of the wrong measurement as the reason.
  if [ "$CROSS_KIND" = stall ]; then
    named="${RESIDENT:-no process was named}"
  else
    named="${OFFENDER:-no process was growing}"
  fi
  printf '%s\t%s\t%s -> %s\t%s MiB RAM headroom available\t%s MiB/min growth\t%s minutes left\t%s memory stall for %s\twatch=%s\t%s\t%s\n' \
    "$NOW" "$(iso "$NOW")" "$from" "$to" "$AVAIL_MIB" "$GROWTH_MIB_MIN" "${MINUTES:-NA}" \
    "${STALL_FULL60:-NA}" "$(human_duration "$STALL_RUN_SECONDS")" \
    "$([ "$WATCH" = - ] && printf all || printf 'unjudged %s' "$WATCH")" \
    "$named" "$line" >>"$LOG" 2>/dev/null
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
  # The trailing discard is not optional: the LAST name in a `read` list is
  # handed the whole remainder of the line, so without it `since` swallows the
  # watch token, fails the numeric guard below, and silently reads as now -
  # which would make every recovery report a shortage that lasted 0s.
  local since=
  [ -f "$STATE_FILE" ] && { read -r _ since _ <"$STATE_FILE" 2>/dev/null || true; }
  case "${since:-}" in ''|*[!0-9]*) printf '%s' "$NOW" ;; *) printf '%s' "$since" ;; esac
}

read_state_watch() {
  local watch=
  [ -f "$STATE_FILE" ] && { read -r _ _ watch <"$STATE_FILE" 2>/dev/null || true; }
  # Anything this alarm did not write itself reads as "all three judged", so a
  # record from before this field existed does not manufacture a change.
  case "${watch:-}" in
    -|headroom,horizon,stall|horizon|stall|horizon,stall) printf '%s' "$watch" ;;
    *) printf '%s' - ;;
  esac
}

write_state() {
  local to=$1 since=$2 watch=$3
  mkdir -p "$STATE" 2>/dev/null || return 1
  printf '%s %s %s\n' "$to" "$since" "$watch" >"$STATE_FILE" 2>/dev/null
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
    printf 'MEMORY_ALARM: nothing is watching this machine for RAM-headroom loss, runaway growth, or memory stall held past the window - the last being the only one that sees a machine already drowning in swap (fix: %s/fm-memory-alarm.sh --arm)\n' \
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
        if [ "$CROSS_KIND" = stall ]; then
          printf 'stalling since: %s (gate %s%%, window %s)\n' \
            "$(iso "$((NOW - STALL_RUN_SECONDS))")" "$STALL_MAX" "$(human_duration "$STALL_WINDOW")"
          printf 'largest resident process: %s\n' "${RESIDENT:-none: no tracked process holds enough memory for this reading to name}"
        else
          printf 'largest grower: %s\n' "${OFFENDER:-none: no tracked process was growing, so the memory went somewhere this reading does not attribute}"
        fi
        [ -z "$DETAIL" ] || printf 'unmeasured inputs: %s\n' "$DETAIL"
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
        [ -z "$DETAIL" ] || printf 'unmeasured inputs: %s\n' "$DETAIL"
        exit 0 ;;
    esac ;;
esac

# --- detect -----------------------------------------------------------------
#
# The watcher reads the line, not the exit status, so this mode always exits 0.
# It speaks only when the state changes.

[ "${FM_MEMORY_ALARM_DISABLE:-0}" = 1 ] && exit 0

evaluate

# The run of consecutive polls is the ONLY thing the stall condition decides on,
# so a run that could not be written down is this alarm's instrument breaking:
# every later poll would start the clock from zero and this machine would read
# calm forever on exactly the shape the condition exists to see. It is said on
# the poll it happens, whatever the state does, the same way a state or a
# transition that could not be persisted is.
[ -z "$STALL_RUN_UNPERSISTED" ] ||
  printf 'MEMORY_ALARM: the memory watch could not persist the memory-stall run in %s; this poll was measured but not durably completed, so the stall condition cannot count consecutive polls and this machine is not being watched for memory stall.\n' \
    "$STALL_RUN_FILE"

PREVIOUS=$(read_state)
SINCE=$(read_state_since)
PREVIOUS_WATCH=$(read_state_watch)
# Taken BEFORE the recovery guard below can rewrite the verdict, because it
# records what this poll could judge, not what it decided to say about it.
WATCH=$(unjudged_conditions)

# Recovery from a crossing must be earned. When growth could not be compared,
# the horizon condition was never evaluated this run, so a calm verdict rests on
# headroom alone. That is enough to stay quiet while already quiet, and never
# enough to declare a shortage over - so a crossing lapses into "cannot see"
# rather than into a recovery nobody measured.
# It blocks on the CONDITIONS' own blindness and never on the reading's, because
# an input no condition uses - a cgroup tree a container does not have, an
# installation whose records this account cannot read - says nothing about
# whether the shortage is over. Blocking on those would announce every genuine
# recovery on such a host as a blindness, and then announce a restoration of
# sight that never happened.
if [ "$VERDICT" = ok ] && [ "$PREVIOUS" = crossed ] &&
   { [ -n "$GROWTH_BLIND" ] || [ -n "$STALL_BLIND" ]; }; then
  VERDICT=unmeasured
  if [ -n "$GROWTH_BLIND" ]; then
    REASON="whether the shortage is over is unknown: growth could not be compared this run ($GROWTH_BLIND), so the conditions that raise this alarm were not re-evaluated in full"
  else
    REASON="whether the shortage is over is unknown: memory stall could not be read this run ($STALL_BLIND), so the conditions that raise this alarm were not re-evaluated in full"
  fi
  incomplete_note
  stall_gate_note
fi

# elevated is a damping band, not a state worth announcing: it exists so that a
# machine hovering at the line does not alternate between crossed and recovered.
# It holds whatever the previous state was.
CURRENT=$VERDICT
[ "$CURRENT" = elevated ] && CURRENT=$PREVIOUS

# A machine only PARTLY watched is not a watched machine, so which conditions
# went unjudged is a state in its own right: a change in that set is a
# transition and is spoken once, exactly as a crossing or a recovery is. That
# keeps the standing rule - an instrument this alarm cannot read is never
# relayed as calm - without breaking the speaks-on-change discipline: a home
# whose stall account can never be read says so once and then goes quiet about
# it, rather than either nagging every poll or never mentioning it at all.
if [ "$CURRENT" = "$PREVIOUS" ] && [ "$WATCH" = "$PREVIOUS_WATCH" ]; then
  write_state "$CURRENT" "$SINCE" "$WATCH" ||
    printf 'MEMORY_ALARM: the memory watch could not persist its %s state in %s; this poll was measured but not durably completed.\n' \
      "$CURRENT" "$STATE_FILE"
  exit 0
fi

LINE=
if [ "$CURRENT" = "$PREVIOUS" ]; then
  # The verdict has not moved; what this alarm can SEE has. It never reads as an
  # all-clear and never as a crossing, because neither happened.
  if [ "$WATCH" = - ]; then
    LINE="MEMORY_ALARM: the memory watch can judge all three of its conditions on this machine again - $REASON."
  else
    LINE="MEMORY_ALARM: the memory watch can no longer judge $WATCH on this machine, so it is only partly watched - $REASON. This is not an all-clear for what it cannot judge."
  fi
else
case "$CURRENT" in
  crossed)
    # The opening clause is chosen by the condition, because "running out of RAM
    # headroom" is the one thing a stall crossing is NOT: its whole point is
    # that headroom reads healthy while the machine is unusable, and a reader
    # sent looking for a shortage would go looking for the wrong thing.
    if [ "$CROSS_KIND" = stall ]; then
      LINE="MEMORY_ALARM: this machine is stalling on memory - $REASON. Largest resident process: ${RESIDENT:-no tracked process holds enough memory for this reading to name}. Nothing has been limited or killed."
    else
      LINE="MEMORY_ALARM: this machine is running out of RAM headroom - $REASON. Largest grower: ${OFFENDER:-no tracked process was growing, so the headroom is going somewhere this reading does not attribute}. Nothing has been limited or killed."
    fi
    ;;
  ok)
    if [ "$PREVIOUS" = crossed ]; then
      LINE="MEMORY_ALARM: recovered - $REASON. The shortage lasted $(human_duration "$((NOW - SINCE))")."
    elif [ "$WATCH" = - ]; then
      LINE="MEMORY_ALARM: the memory watch can see this machine again - $REASON."
    else
      LINE="MEMORY_ALARM: the memory watch reads this machine as calm on the conditions it could judge, and it still cannot judge $WATCH, so this machine is only partly watched - $REASON. This is not an all-clear for what it cannot judge."
    fi
    ;;
  unmeasured)
    LINE="MEMORY_ALARM: the memory watch has gone blind - $REASON. This is not an all-clear."
    ;;
esac
fi
# Whatever the line says, the inputs nobody could read are named on it.
[ -z "$DETAIL" ] || LINE="$LINE Unmeasured: $DETAIL"

# A change of watch is not a change of state, so it must not restart the clock
# that measures how long a shortage has lasted.
if [ "$CURRENT" = "$PREVIOUS" ]; then SINCE_NEXT=$SINCE; else SINCE_NEXT=$NOW; fi

if ! record_transition "$PREVIOUS" "$CURRENT" "$LINE"; then
  printf 'MEMORY_ALARM: the memory watch could not record the %s to %s transition in %s; the transition was measured but not durably completed.\n' \
    "$PREVIOUS" "$CURRENT" "$LOG"
  exit 0
fi
if ! write_state "$CURRENT" "$SINCE_NEXT" "$WATCH"; then
  printf 'MEMORY_ALARM: the memory watch recorded the %s to %s transition but could not persist its new state in %s; the transition was not durably completed.\n' \
    "$PREVIOUS" "$CURRENT" "$STATE_FILE"
  exit 0
fi
printf '%s\n' "$LINE"
exit 0
