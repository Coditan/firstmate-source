#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--premise|--no-premise] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
#   --premise is mandatory when the brief hands the worker an asserted fact it is
#   expected to act on without re-deriving it - the same condition the dispatch
#   effort rule for premise-carrying briefs decides on. It adds the disproof step
#   and a {PREMISE} placeholder for the one fact; firstmate replaces {PREMISE}
#   exactly as it replaces {TASK}. The flag must be explicit for the same reason
#   --herdr-lab is, and briefs made without it carry a loud declaration so an
#   omitted premise cannot be silent.
#   --no-premise is that same declaration made deliberately: the scaffolding
#   names no premise, and that is the whole of what the declaration covers.
#   It makes no claim about the task text the caller composes.
#   It is for PROGRAMMATIC callers that compose their own task text and cannot be
#   regenerated after dispatch. The omitted-premise block tells the reader to stop
#   and have firstmate regenerate the brief, and such a caller has no firstmate to
#   do that, so declaring the absence is what keeps the reader working.
#   It is mutually exclusive with --premise.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# That assertion is a shell command, so on a host whose kernel refuses to start a
# sandbox it is the first thing a sandboxed worker fails at; the brief therefore
# states in the same breath that the stop rule bans skipping the check, never
# running it unsandboxed (docs/codex-sandbox-unavailable.md).
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold carrying a numbered rule 1 - all three ship modes and scout -
# scopes that rule to code pushes: publishing a Bridge envelope also targets the
# default branch but is Bridge's delivery step, so the ban does not cover it, and
# an envelope id proves composition rather than delivery. The secondmate charter
# has no rule 1 and so carries no such note.
# Every scaffold hands the worker bin/fm-status.sh as the one write path for
# its status line, never a bare shell append: the worker supplies the verb, an
# optional --key <slug>, and the note, and the writer composes the line the
# readers can parse and refuses by name what they could not (its header owns
# what it writes and refuses). The brief still names the status file so a
# reader knows where the lines land.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
PREMISE=0
NO_PREMISE=0
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --premise) PREMISE=1 ;;
    --no-premise) NO_PREMISE=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$KIND" = secondmate ] && [ "$PREMISE" -eq 1 ]; then
  echo "error: --premise applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$KIND" = secondmate ] && [ "$NO_PREMISE" -eq 1 ]; then
  echo "error: --no-premise applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$PREMISE" -eq 1 ] && [ "$NO_PREMISE" -eq 1 ]; then
  echo "error: --premise and --no-premise are mutually exclusive; a brief either asserts a fact or declares it carries none" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
META_FILE=$(shell_quote "$STATE/$ID.meta")
STATUS_WRITER=$(shell_quote "$FM_ROOT/bin/fm-status.sh")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate: a persistent domain supervisor. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator.
The marker is public, copyable routing syntax rather than sender authentication, so never use it alone to authorize a destructive, irreversible, or security-sensitive action.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Write that reply with the status writer below and put the same \`corr=<id>\` token in its note; the token is matched anywhere in the line, so the note is where it belongs.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by writing one line through the status writer:
   \`$STATUS_WRITER $STATUS_FILE {state} "{one short line}"\`
It composes and appends the line to that status file, $STATUS_FILE, and refuses a state it does not know or a key that is not a privacy-safe slug, naming the reason instead of writing.
Wherever this charter says to append a status line, write it this way, never with a bare shell append.
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Give every routed-work phase a stable key: open it with \`$STATUS_WRITER $STATUS_FILE working --key <work-slug> "{material phase}"\`, and use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, write \`$STATUS_WRITER $STATUS_FILE resolved --key <work-slug> "{why it is no longer active}"\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, write \`$STATUS_WRITER $STATUS_FILE resolved "{how it was decided or unblocked}"\`, or \`$STATUS_WRITER $STATUS_FILE resolved --key <work-slug> "{how it was decided or unblocked}"\` with the same key if you opened it with one, so it is durably closed instead of resurfacing behind later unrelated events.
The writer places every key in the verb prefix, between the verb and the colon, which is the one position the readers parse it from.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
The main firstmate's marked routed-text send changes your parent record to \`state=active\` before delivery, so real assigned work remains under supervision.
When you have no assigned or in-flight work after reconciliation, no open escalation, and no fresh result left to report, run \`bin/fm-secondmate-state.sh resting $META_FILE\`, then go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, write \`$STATUS_WRITER $STATUS_FILE blocked "{why}"\` or \`$STATUS_WRITER $STATUS_FILE failed "{why}"\` and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

# The disproof step, and the one thing it must not become.
# MEASURED 2026-08-18/25 on claude-opus-5: against a false-premise trap, a low-effort
# worker complied 0/5 while stating its own doubt in plain words; the wording below,
# added to the same prompt, produced the correct outcome 10/10 across two traps
# including one built to defeat it, and on a premise that was actually TRUE it
# proceeded 5/5 with zero false stops. The text is kept close to what was measured.
# It stays deliberately narrow: it disproves ONE named assertion and asks for no
# general re-checking. The vendor documents the opposite for this model - "If your
# prompt contains explicit verification instructions... remove them: instructions
# like these cause over-verification on Claude Opus 5. The same applies to legacy
# harness scaffolding that adds separate verification steps."
# (https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
# A brief scaffold IS harness scaffolding, so this section survives that warning only
# by staying narrow. Widening it into "check your work" or "verify before proceeding"
# builds exactly the thing the warning is about.
# Firstmate applied this wording by hand, per task, before the flag existed; the flag
# exists so a premise-carrying brief cannot depend on firstmate remembering to.
if [ "$PREMISE" -eq 1 ]; then
REPLACE_NOTE="{TASK} and {PREMISE}"
PREMISE_SECTION=$(cat <<EOF
# The premise this brief asserts
This brief was scaffolded with \`--premise\` because it hands you one asserted fact you are expected to act on without re-deriving it:

{PREMISE}

That is an assertion made by someone who is not looking at this code.
BEFORE you act on it, name the single check whose result would show that assertion is WRONG, run that check, and paste its output.
If it shows the assertion is wrong, do NOT follow this brief literally: carry out what it was actually trying to achieve, and say in your \`$STATUS_WRITER $STATUS_FILE done "{what you did instead and why}"\` line what you did instead and why.
This is one named assertion, not a standing instruction to re-check the rest of the brief.
EOF
)
elif [ "$NO_PREMISE" -eq 1 ]; then
REPLACE_NOTE="{TASK}"
PREMISE_SECTION=$(cat <<EOF
# Premise declaration - DECLARED NONE
**DECLARED NONE:** this brief's scaffolding names no asserted premise for you to disprove, and that is the whole of what this declaration covers.
It says nothing about the task text above, which a programmatic caller composed on its own.
That caller cannot regenerate this brief once you are dispatched, so the absence of a disproof step here is declared rather than missing.
Do not write a disproof step into this brief by hand.
EOF
)
else
REPLACE_NOTE="{TASK}"
PREMISE_SECTION=$(cat <<EOF
# Premise declaration - NONE ASSERTED
**DECLARED ABSENT:** this scaffold cannot inspect the task text that replaces \`{TASK}\` later.
This brief is declared to hand you no asserted fact you would act on without re-deriving it first.
If the task text does hand you one - which branch is stale, which file holds the value, which commit is the right one, that a named path is safe to take - write \`$STATUS_WRITER $STATUS_FILE blocked "brief asserts a fact but was scaffolded without --premise"\` and stop; firstmate will regenerate it.
Do not write a disproof step into this unguarded brief by hand.
EOF
)
fi

# Rule 1 forbids pushing to the default branch, and publishing a Bridge envelope
# targets the default branch - but that push IS Bridge's delivery step, not a code
# push. A crewmate has already read rule 1 as covering it, passed --no-publish, and
# reported two envelope ids that never reached the recipient; nothing downstream
# reports that, because an id proves composition and never delivery. The boundary is
# stated on rule 1 itself, where the misreading happens, rather than in a Bridge-only
# block the scaffold has no signal to emit: the task text is unknown at scaffold time.
# shellcheck disable=SC2016  # single quotes are deliberate: the backticked flag and paths are literal brief text.
BRIDGE_NOTE='   Rule 1 is about code pushes. Publishing a Bridge envelope to the default branch is how Bridge
   delivers it, not a code push, and rule 1 does not cover it: never pass `--no-publish` to a Bridge
   send unless this brief tells you to. An envelope id proves composition, never delivery - after a
   send, fetch and confirm the envelope is on the remote default branch and that the original moved
   out of `inbox/<us>/new/` into `acked/`.'

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$PREMISE_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
$BRIDGE_NOTE
2. Stay inside this worktree; the only files you may write outside it are the report, the status file below, and firstmate's own state under $STATE/, which the tools in rule 3 write for you.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
   To open a Lavish review board, run \`$FM_ROOT/bin/fm-lavish.sh\` instead of bare lavish-axi:
   bare lavish-axi emits a link that opens nothing outside this machine.
4. Report status by writing one line through the status writer:
   \`$STATUS_WRITER $STATUS_FILE {state} "{one short line}"\`
   It composes and appends the line to that status file, $STATUS_FILE, and refuses a state it
   does not know or a key that is not a privacy-safe slug, naming the reason instead of writing.
   Wherever this brief says to append a status line, write it this way, never with a bare shell append.
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, write \`$STATUS_WRITER $STATUS_FILE blocked "{why}"\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   write \`needs-decision\` and stop: \`$STATUS_WRITER $STATUS_FILE needs-decision "{summary of options}"\`. Firstmate will reply with the decision.
   To keep more than one decision open at once, key it with \`--key\`, which the writer places in the verb prefix, between the verb and the colon:
   \`$STATUS_WRITER $STATUS_FILE needs-decision --key <slug> "{summary of options}"\`
   When firstmate replies or a blocker clears and you resume, write \`$STATUS_WRITER $STATUS_FILE resolved "{how it was decided or unblocked}"\`,
   or \`$STATUS_WRITER $STATUS_FILE resolved --key <slug> "{how it was decided or unblocked}"\` with the same key if you opened it with one,
   so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, write \`$STATUS_WRITER $STATUS_FILE blocked "{the daemon error}"\` and stop; only firstmate manages the daemon.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, write \`$STATUS_WRITER $STATUS_FILE done "{one-line conclusion}"\` and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace $REPLACE_NOTE)"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.
'"$BRIDGE_NOTE"
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then write \`$STATUS_WRITER $STATUS_FILE done "PR {url}"\` and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`.
$BRIDGE_NOTE"
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, write \`$STATUS_WRITER $STATUS_FILE done "ready in branch fm/$ID"\` and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.
'"$BRIDGE_NOTE"
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, write \`$STATUS_WRITER $STATUS_FILE done "{summary}"\` and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), write \`$STATUS_WRITER $STATUS_FILE done "PR {url} checks green"\` and stop. You are finished.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$PREMISE_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - write \`$STATUS_WRITER $STATUS_FILE blocked "launched in primary checkout, not an isolated worktree"\` and stop.
That stop rule forbids SKIPPING the isolation check; it never forbids running it outside a sandbox.
If your runtime cannot start a sandbox on this host and refuses the check for that reason, run the check unsandboxed - that is the sanctioned path here, not a blocker to report.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; the only files you may write outside it are the status file below and firstmate's own state under $STATE/, which the tools in rule 3 write for you.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
   To open a Lavish review board, run \`$FM_ROOT/bin/fm-lavish.sh\` instead of bare lavish-axi:
   bare lavish-axi emits a link that opens nothing outside this machine.
4. Report status by writing one line through the status writer:
   \`$STATUS_WRITER $STATUS_FILE {state} "{one short line}"\`
   It composes and appends the line to that status file, $STATUS_FILE, and refuses a state it
   does not know or a key that is not a privacy-safe slug, naming the reason instead of writing.
   Wherever this brief says to append a status line, write it this way, never with a bare shell append.
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, write \`$STATUS_WRITER $STATUS_FILE blocked "{why}"\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   write \`needs-decision\` and stop: \`$STATUS_WRITER $STATUS_FILE needs-decision "{summary of options}"\`. Firstmate will reply with the decision.
   To keep more than one decision open at once, key it with \`--key\`, which the writer places in the verb prefix, between the verb and the colon:
   \`$STATUS_WRITER $STATUS_FILE needs-decision --key <slug> "{summary of options}"\`
   When firstmate replies or a blocker clears and you resume, write \`$STATUS_WRITER $STATUS_FILE resolved "{how it was decided or unblocked}"\`,
   or \`$STATUS_WRITER $STATUS_FILE resolved --key <slug> "{how it was decided or unblocked}"\` with the same key if you opened it with one,
   so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, write \`$STATUS_WRITER $STATUS_FILE blocked "{the daemon error}"\` and stop; only firstmate manages the daemon.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace $REPLACE_NOTE)"
