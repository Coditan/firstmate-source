#!/usr/bin/env bash
# Static contract tests for conditional instruction owners introduced before the
# AGENTS.md reduction pass.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIAG="$ROOT/.agents/skills/diagnostic-reasoning/SKILL.md"
PROJECT="$ROOT/.agents/skills/project-management/SKILL.md"
SECRETS="$ROOT/.agents/skills/secrets-handling/SKILL.md"
ASKUSER="$ROOT/.agents/skills/ask-user-authority/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODING="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
CREWDISPATCH="$ROOT/.agents/skills/crew-dispatch/SKILL.md"
TASKLANDING="$ROOT/.agents/skills/task-landing/SKILL.md"
CAPTAINSURFACES="$ROOT/.agents/skills/captain-surfaces/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"
AGENTS="$ROOT/AGENTS.md"
BRIEF="$ROOT/bin/fm-brief.sh"
DOMAIN="$ROOT/.agents/skills/domain-modeling/SKILL.md"
DOMAIN_PROVENANCE="$ROOT/docs/domain-modeling-provenance.md"
README="$ROOT/README.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
AWAY_RECORD="$ROOT/docs/away-mode-approval-authority.md"

test_new_skill_metadata_and_triggers() {
  local skill name skill_trigger agents_trigger count i
  # Four fields per owner: skill name, SKILL.md path, its description load
  # trigger, and the AGENTS.md section 13 trigger line.
  local -a owners=(
    'diagnostic-reasoning' "$DIAG"
    'Use before scoping a reported bug and before acting on a diagnostic report.'
    '`diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.'
    'project-management' "$PROJECT"
    'Use before adding, creating, removing, or initializing a project.'
    '`project-management` - load before adding, creating, removing, or initializing a project.'
    'secrets-handling' "$SECRETS"
    'Use before reading, sourcing, injecting, inspecting, or transporting secrets or credentials, and whenever one is exposed in agent or tool output.'
    '`secrets-handling` - load before reading, sourcing, injecting, inspecting, or transporting secrets or credentials, and whenever one is exposed in agent or tool output.'
    'ask-user-authority' "$ASKUSER"
    'Use before deciding any ask-user finding, regardless of the project'"'"'s yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.'
    '`ask-user-authority` - load before deciding any ask-user finding, regardless of the project'"'"'s `yolo` posture.'
    'crew-dispatch' "$CREWDISPATCH"
    'Use before spawning a crewmate or scout, before steering one, and whenever a no-mistakes validation run on a live worker needs triggering, reading, or answering.'
    '`crew-dispatch` - load at the dispatch, steering, and validation trigger section 7 names.'
    'task-landing' "$TASKLANDING"
    'Use when a worker reports a PR or a clean ready branch, before recording or landing one, after relaying a terminal task outcome, before tearing a finished task down, when a scout'"'"'s report arrives, and before promoting a scout to implementation.'
    '`task-landing` - load at the PR, landing, cleanup, and scout-outcome trigger section 7 names.'
    'captain-surfaces' "$CAPTAINSURFACES"
    'Use before building or opening a review board, a decision board, or a sea chart, before sending him anything while he is out of session, and before producing a PDF deliverable.'
    '`captain-surfaces` - load at the surface trigger section 9 names, before anything reaches the captain other than plain chat.'
  )
  for ((i = 0; i < ${#owners[@]}; i += 4)); do
    name=${owners[i]}
    skill=${owners[i + 1]}
    skill_trigger=${owners[i + 2]}
    agents_trigger=${owners[i + 3]}
    assert_present "$skill" "$name skill is missing"
    assert_grep "name: $name" "$skill" "$name skill metadata has the wrong name"
    assert_grep "user-invocable: false" "$skill" "$name skill must not be user-invocable"
    assert_grep "  internal: true" "$skill" "$name skill must be internal"
    count=$(grep -Fc -- "- \`$name\` -" "$AGENTS")
    [ "$count" -eq 1 ] || fail "$name must have exactly one AGENTS.md trigger entry, found $count"
    assert_grep "$skill_trigger" "$skill" "$name skill metadata lost its precise load trigger"
    assert_grep "$agents_trigger" "$AGENTS" "AGENTS.md lost the $name trigger"
  done
  pass "new internal skills have one precise AGENTS.md trigger each"
}

# domain-modeling is captain-invocable, so it carries its trigger in section 6
# rather than in section 13, and the enumerating trigger test above cannot check
# it. It is also adopted third-party material: MIT requires the notice to travel
# with the work, and the first adoption from the same upstream shipped without
# one and had to be corrected after the fact. Both obligations are asserted here
# because both are invisible when broken - the skill still loads and still works.
test_domain_modeling_owner_is_triggered_and_attributed() {
  assert_present "$DOMAIN" "domain-modeling skill is missing"
  assert_grep "name: domain-modeling" "$DOMAIN" "domain-modeling skill metadata has the wrong name"
  assert_grep "user-invocable: true" "$DOMAIN" "domain-modeling must stay captain-invocable"
  assert_grep "  internal: true" "$DOMAIN" "domain-modeling skill must be internal"
  assert_no_grep "- \`domain-modeling\` - " "$AGENTS" \
    "a captain-invocable skill must not be listed in AGENTS.md section 13"
  assert_grep 'load the `domain-modeling` skill' "$AGENTS" \
    "AGENTS.md section 6 lost the domain-modeling load trigger"
  assert_grep 'a hard-to-reverse decision has just been made, load the `domain-modeling` skill' "$AGENTS" \
    "AGENTS.md lost the decision-recording arm of the domain-modeling trigger"
  assert_grep "creates no store of its own" "$AGENTS" \
    "AGENTS.md lost the rule that domain-modeling adds no third store"

  # The terminology rule the captain set on 2026-08-03, with the boundary that
  # keeps it from reading as a contradiction of section 9.
  assert_grep "never Werkbank" "$DOMAIN" "domain-modeling lost the proper-noun example that triggered the rule"
  assert_grep "German is written per DU, never Sie" "$DOMAIN" "domain-modeling lost the register rule"
  assert_grep "Section 9 covers a word firstmate invented to describe its own operation, where a plain-English rendering is strictly better for the reader, and it alone decides which words may reach the captain at all" "$DOMAIN" \
    "domain-modeling lost the discriminator against section 9"
  assert_grep "being a name is never a reason a word survives that ban" "$DOMAIN" \
    "domain-modeling must not exempt firstmate's own harness or backend names from section 9"

  # Adopted whole, so the moves and the bar must survive intact.
  for phrase in \
    "Challenge against the vocabulary already in use" \
    "Sharpen a fuzzy term" \
    "Invent scenarios that force the boundary" \
    "Check the claim against the thing itself" \
    "Write it down where the next reader will meet it" \
    "Hard to reverse" \
    "Surprising without context" \
    "The result of a real trade-off"; do
    assert_grep "$phrase" "$DOMAIN" "domain-modeling is missing '$phrase'"
  done
  assert_grep "decision-hold-lifecycle" "$DOMAIN" \
    "domain-modeling does not hand an unresolved captain decision to its owner"

  # MIT: the copyright notice and the permission notice travel with the work.
  assert_present "$DOMAIN_PROVENANCE" "domain-modeling provenance and third-party notice is missing"
  assert_grep "Copyright (c) 2026 Matt Pocock" "$DOMAIN_PROVENANCE" \
    "domain-modeling provenance lost the MIT copyright notice"
  assert_grep "The above copyright notice and this permission notice shall be included in all" \
    "$DOMAIN_PROVENANCE" "domain-modeling provenance lost the MIT permission notice"
  assert_grep "mattpocock/skills" "$DOMAIN" "domain-modeling skill does not name its source"
  assert_grep "docs/domain-modeling-provenance.md" "$README" \
    "README does not point at the domain-modeling third-party notice"
  pass "domain-modeling carries its section 6 trigger, its terminology rule, and its MIT notice"
}

test_diagnostic_owner_covers_causal_procedure() {
  assert_grep "single owner of Firstmate's bug-diagnosis reasoning procedure" "$DIAG" \
    "diagnostic skill does not declare ownership"
  for phrase in \
    "end-to-end reproduction aligned with the real user path" \
    "initiating trigger" \
    "masking condition" \
    "visible symptom" \
    "proven path" \
    "relevant history" \
    "smallest counterfactual" \
    "disconfirming evidence"; do
    assert_grep "$phrase" "$DIAG" "diagnostic owner is missing '$phrase'"
  done
  assert_grep "evidence, not authorization to change code" "$DIAG" \
    "diagnostic owner lost the diagnosis-only authority boundary"
  pass "diagnostic-reasoning owns the approved evidence procedure"
}

test_project_management_owner_covers_guarded_operations() {
  assert_grep "single owner of Firstmate's project-management procedure" "$PROJECT" \
    "project-management skill does not declare ownership"
  for phrase in \
    'bin/fm-project-mode.sh' \
    '`no-mistakes`' \
    '`direct-PR`' \
    '`local-only`' \
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Never issue a raw removal command from Firstmate.' \
    'no-mistakes init && no-mistakes doctor'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  pass "project-management owns registry, delivery posture, consent, initialization, and removal safety"
}

test_secrets_owner_covers_exposure_response() {
  for phrase in \
    'Do not run `cat`, `head`, `tail`, `sed`, `awk`, or `rg` against a secrets file to discover a value.' \
    'Do not run `echo "$TOKEN"`, `printf '"'"'%s\n'"'"' "$TOKEN"`, `env`, or `printenv` to check a credential.' \
    'Do not run `docker inspect <container> --format '"'"'{{json .Config.Env}}'"'"'` or `docker exec <container> env` when credentials may be present.' \
    'Do not run `ps eww` because it appends the process environment to the listing.'; do
    assert_grep "$phrase" "$SECRETS" "secrets-handling owner is missing dangerous-command doctrine: '$phrase'"
  done
  assert_grep 'Stow-and-clear is sufficient only when the value appeared in an authorized agent or tool transcript, remained session-local and ephemeral, and there is no evidence that it reached a durable artifact, shared log, message, repository, remote service, public output, or untrusted reader.' "$SECRETS" \
    "secrets-handling owner lost the contained-exposure stow-and-clear scope"
  assert_grep 'Do not rotate automatically for a contained, session-local, ephemeral exposure.' "$SECRETS" \
    "secrets-handling owner lost the no-automatic-rotation posture"
  assert_grep 'Escalate immediately when the exposure reached or may have reached durable storage, a shared or remote channel, source control, an untrusted audience, or an unknown boundary, or when suspicious use means containment is uncertain.' "$SECRETS" \
    "secrets-handling owner lost the durable/shared/remote/untrusted/uncertain escalation trigger"
  pass "secrets-handling owns the dangerous-command doctrine, contained stow-and-clear scope, and escalation triggers"
}

test_ask_user_owner_covers_authority_procedure() {
  local procedure escalation steps elements phrase
  assert_grep "single owner of the decision procedure for ask-user findings" "$ASKUSER" \
    "ask-user-authority skill does not declare ownership"
  assert_grep '## Decide who has authority' "$ASKUSER" \
    "ask-user-authority lost the authority decision section"
  assert_grep '## Captain-facing escalation' "$ASKUSER" \
    "ask-user-authority lost the captain-facing escalation section"
  procedure=$(awk '
    /^## Decide who has authority$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$ASKUSER")
  escalation=$(awk '
    /^## Captain-facing escalation$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$ASKUSER")
  steps=$(printf '%s\n' "$procedure" | grep -Ec '^[0-9]+\. ')
  [ "$steps" -eq 8 ] || fail "ask-user-authority must keep all 8 numbered authority steps, found $steps"
  elements=$(printf '%s\n' "$escalation" | grep -Ec '^[0-9]+\. ')
  [ "$elements" -eq 5 ] || fail "ask-user-authority must keep all 5 numbered escalation elements, found $elements"
  for phrase in \
    '`yolo`' \
    'accepted contract' \
    'materially expand the contract' \
    'never as authority to broaden the task' \
    'causal theme' \
    'Destructive, irreversible' \
    'routes the decision to firstmate'; do
    assert_contains "$procedure" "$phrase" "ask-user-authority procedure is missing '$phrase'"
  done
  for phrase in \
    'evidence-first' \
    'accepted task criterion' \
    'contract expansion' \
    'smallest alternative' \
    'consequences of accepting and declining' \
    'recommendation' \
    'reviewer labels'; do
    assert_contains "$escalation" "$phrase" "ask-user-authority escalation is missing '$phrase'"
  done
  pass "ask-user-authority owns the authority procedure and the evidence-first escalation contract"
}

test_generic_effort_fallback_respects_precedence() {
  local section
  section=$(awk '
    /^Effort precedence is / { found = 1 }
    found && /^The supported launch-profile flags / { exit }
    found { print }
  ' "$HARNESS")
  assert_contains "$section" "explicit per-task captain instruction first" \
    "effort rubric lost per-task captain precedence"
  assert_contains "$section" "standing dispatch profile or secondmate pin" \
    "effort rubric lost standing configuration precedence"
  assert_contains "$section" 'Use `low` for well-understood work' \
    "effort rubric lost its low fallback"
  assert_contains "$section" '`xhigh` for ambiguous investigation or design' \
    "effort rubric lost its xhigh fallback"
  assert_contains "$section" "Choose intermediate levels proportionally" \
    "effort rubric lost proportional intermediate levels"
  assert_contains "$section" 'Never select `max` from this fallback' \
    "effort rubric permits max without an explicit captain preference"
  if printf '%s\n' "$section" | grep -qi sol; then
    fail "generic effort fallback must not contain Sol-specific policy"
  fi
  pass "generic effort fallback applies only below captain and standing configuration"
}

test_shared_authoring_requirements_are_owned() {
  assert_grep "review every affected supported primary harness and runtime backend" "$CODING" \
    "coding guidance lost the supported compatibility matrix review"
  assert_grep "prefer deterministic and idempotent enforcement over relying on agent memory alone" "$CODING" \
    "coding guidance lost deterministic idempotent enforcement"
  assert_grep "critical safety, routing, startup, and supervision infrastructure" "$CODING" \
    "coding guidance lost the critical infrastructure scope"
  pass "firstmate-coding-guidelines owns compatibility review and deterministic enforcement"
}

test_secondmate_registry_contract_stays_concise() {
  local guidance routing_section schema_line
  routing_section=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Charter and seed$/ { exit }
    found { print }
  ' "$SECONDMATE")
  guidance=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Backlog handoff$/ { exit }
    found { print }
  ' "$SECONDMATE")
  schema_line="- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)"
  assert_contains "$routing_section" "$schema_line" \
    "secondmate routing table lost the parser-compatible single-line schema"
  assert_contains "$routing_section" "Each registry entry stays concise and single-line" \
    "secondmate routing table no longer requires concise single-line entries"
  assert_contains "$routing_section" "genuinely domain-specific hard rules" \
    "secondmate routing table no longer limits extra prose to domain-specific hard rules"
  assert_contains "$routing_section" "The home-seeded \`data/charter.md\` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts" \
    "secondmate routing table lost the explicit charter ownership pointer"
  assert_contains "$routing_section" "no extra registry pointer field is needed" \
    "secondmate routing table no longer explains why the existing home field is the charter pointer"
  for phrase in \
    "go idle and wait silently" \
    "Act only on tasks" \
    "never spawn a survey" \
    "run normal firstmate bootstrap" \
    "escalation back to the main firstmate status file" \
    "requests-from-main-firstmate contract" \
    "waits for routed tasks, never self-initiating a survey or audit" \
    "marked supervisor requests return through status" \
    "unmarked captain messages stay conversational"; do
    if printf '%s\n' "$guidance" | grep -F "$phrase" >/dev/null; then
      fail "secondmate provisioning guidance restated charter boilerplate: $phrase"
    fi
  done
  pass "secondmate registry guidance keeps concise routes and points to the charter"
}

test_state_startup_and_ordinary_recovery_placement() {
  assert_grep "single owner of the top-level operational-home layout" "$CONFIG" \
    "configuration docs do not own the operational state layout"
  assert_grep "header is the single owner of session-start ordering" "$CONFIG" \
    "session-start mechanism is not assigned to the script header"
  assert_grep "Ordinary dead-direct-report recovery is owned by \`stuck-crewmate-recovery\`" "$CONFIG" \
    "D05 ordinary recovery placement is missing"
  assert_grep "## Session-start reconciliation for a dead ordinary direct report" "$RECOVERY" \
    "stuck-crewmate-recovery lacks the dead ordinary direct-report procedure"
  assert_grep "treehouse status" "$RECOVERY" \
    "ordinary recovery lost treehouse inventory inspection"
  assert_grep "recorded \`orca_worktree_id=\` and \`terminal=\`" "$RECOVERY" \
    "ordinary recovery lost Orca inventory inspection"
  assert_grep "session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window" "$AGENTS" \
    "AGENTS.md does not trigger ordinary dead-report recovery"
  pass "state, startup, and ordinary recovery have focused owners and triggers"
}

# bin/fm-crew-state.sh gates its refusal on the STATE token and keeps the source
# and cause vocabularies open, so a recovery rule keyed on one source token silently
# stops covering the crew the moment another is added - and the harm is that an
# agent relaunches a worker nothing is known about. The instruction has to be
# keyed the way the code is.
test_recovery_stop_is_keyed_on_the_degraded_state() {
  assert_grep 'If that read answers `degraded` in its `state:` field, stop this procedure, whatever its `source:` and `cause:` say' "$RECOVERY" \
    "the recovery stop is not keyed on the degraded state itself"
  assert_grep 'never a particular source or cause, so a source or cause added later is covered by this rule without amending it' "$RECOVERY" \
    "the recovery stop does not say it covers sources and causes added later"
  pass "stuck-crewmate recovery stops on the degraded state, not on one of its sources"
}

test_compressed_agents_owner_map() {
  assert_grep '`docs/configuration.md` is the single owner of the top-level operational-home layout' "$AGENTS" \
    "AGENTS.md lost the state-layout owner pointer"
  assert_grep 'header is the single owner of composed commands, ordering, and digest contents' "$AGENTS" \
    "AGENTS.md lost the session-start owner pointer"
  assert_grep '`docs/configuration.md` owns dispatch-profile and runtime-backend schemas' "$AGENTS" \
    "AGENTS.md lost the dispatch-schema owner pointer"
  assert_grep 'That skill owns registry syntax, delivery-mode selection' "$AGENTS" \
    "AGENTS.md lost the project-management owner pointer"
  assert_grep 'The delivery lifecycle is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns the delivery lifecycle"
  assert_grep 'Fleet supervision is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns fleet supervision"
  assert_grep '`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema' "$AGENTS" \
    "AGENTS.md lost the backlog-mechanics owner pointer"
  assert_grep '`bin/fm-brief.sh` and its help own scaffold syntax' "$AGENTS" \
    "AGENTS.md lost the brief-mechanics owner pointer"
  assert_grep '`docs/configuration.md` owns activation, generated state, cadence, wire protocol' "$AGENTS" \
    "AGENTS.md lost the X-mode mechanics owner pointer"
  pass "compressed AGENTS.md records the approved one-owner map"
}

test_compressed_agents_retains_authority_and_supervision_safety() {
  for phrase in \
    'A lock-refused session must not spawn, steer, merge, drain the wake queue' \
    'A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.' \
    'The selected delivery path owns its own rigor.' \
    'When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.' \
    'Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.' \
    'A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.' \
    'If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.' \
    '**local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority' \
    'A status line is a wake event, not current state' \
    'Never broadly kill watchers' \
    '**Never restate an unchanged state.**' \
    'Never announce silence and then speak' \
    "send exactly one line holding the marker \`.\` and nothing else" \
    'While `state/.afk` exists, the away daemon owns wake delivery' \
    'post the final completion follow-up before teardown'; do
    assert_grep "$phrase" "$AGENTS" "compressed AGENTS.md lost safety phrase '$phrase'"
  done
  assert_no_grep 'Firstmate does not personally review code or deliverables' "$AGENTS" \
    "AGENTS.md retained the weaker duplicate review prohibition"
  assert_no_grep 'firstmate reviews your branch' "$AGENTS" \
    "AGENTS.md retained a personal branch-review requirement"
  assert_no_grep 'firstmate reviews, captain approves' "$BRIEF" \
    "generated brief retained a stacked personal-review requirement"
  if grep -q "$(printf '\342\200\224')" "$AGENTS"; then
    fail "AGENTS.md contains an em dash"
  fi
  pass "compressed AGENTS.md retains authority, supervision, AFK, and X safety"
}

# fm_skill_frontmatter and fm_skill_description live in tests/lib.sh, the shared
# owner of test primitives, so this suite and fm-stow-contract both read a
# frontmatter-bounded description from one implementation.

# Every skill under .agents/skills/ must carry a load trigger on each surface
# that can reach it, and every section 13 entry must name a real skill. This
# enumerates the directory on purpose: a hand-maintained list of guarded skills
# has the same silent-staleness failure mode as the missing trigger it is meant
# to catch, so it would miss every skill added after it was written.
#
# Two surfaces are checked because a skill can arrive by two routes, and a
# deployment may only have one of them. AGENTS.md section 13 is the route for a
# firstmate reading its own instruction surface. The SKILL.md description is the
# route for the harness skill listing, and it is the ONLY route where no
# instruction-surface trigger line is possible, so it is required of every skill
# this repository AUTHORS.
#
# A skill INSTALLED from upstream is exempt from the frontmatter half and held
# to the AGENTS.md half alone: its file is verbatim and editing it to satisfy a
# convention this repository invented would diverge it from the installer's
# recorded hash. The installed set is read from skills-lock.json rather than
# listed here, for the same staleness reason the loop enumerates the directory.
test_every_skill_declares_a_load_trigger() {
  local dir name invocable count section desc installed
  local missing="" toneless="" dangling=""
  section=$(awk '/^## 13\. /{f=1} f && /^## 14\. /{exit} f' "$AGENTS")
  [ -n "$section" ] || fail "AGENTS.md section 13 is missing or unparseable"
  installed=" $(fm_installed_skill_dirs | tr '\n' ' ')"
  for dir in "$ROOT"/.agents/skills/*/; do
    name=$(basename "$dir")
    [ -f "$dir/SKILL.md" ] || fail "skill $name has no SKILL.md"
    fm_skill_frontmatter "$dir" | grep -qx "name: $name" \
      || fail "skill $name declares a metadata name that is not its directory"
    # A skill installed from upstream is held to reachability only. It cannot
    # declare frontmatter fields this repository invented, and editing it to add
    # them would diverge it from the hash the installer recorded, turning every
    # future update into a conflict (docs/axi-skill-provenance.md). Its
    # description is upstream's wording and is not ours to shape either.
    case "$installed" in
      *" $name "*)
        count=$(printf '%s\n' "$section" | grep -Fc -- "- \`$name\` - ")
        [ "$count" -eq 1 ] || missing="$missing $name(section-13-entries=$count)"
        continue
        ;;
    esac
    invocable=$(fm_skill_frontmatter "$dir" | grep -m1 '^user-invocable:' | awk '{print $2}')
    case "$invocable" in
      false)
        count=$(printf '%s\n' "$section" | grep -Fc -- "- \`$name\` - ")
        [ "$count" -eq 1 ] || missing="$missing $name(section-13-entries=$count)"
        ;;
      true) ;;
      *)
        fail "skill $name does not declare user-invocable true or false"
        ;;
    esac
    # An empty or absent description leaves the skill listed by bare name, with
    # no condition an agent could match against. That degradation is invisible:
    # the file is still present and still valid.
    desc=$(fm_skill_description "$dir")
    if [ -z "$(printf '%s' "$desc" | tr -d '[:space:]')" ]; then
      missing="$missing $name(no-description-trigger)"
    elif ! printf '%s' "$desc" | grep -Eqi '(^|[^[:alnum:]])(when|whenever|before|after)([^[:alnum:]]|$)'; then
      # A floor, not a wording contract: it proves the description states some
      # condition rather than being a bare summary of what the skill contains.
      toneless="$toneless $name"
    fi
  done
  if [ -n "$missing" ]; then
    fail "skills with no load trigger:$missing"
  fi
  if [ -n "$toneless" ]; then
    fail "skill descriptions state no load condition (no when/whenever/before/after):$toneless"
  fi
  while read -r name; do
    [ -n "$name" ] || continue
    [ -d "$ROOT/.agents/skills/$name" ] || dangling="$dangling $name"
  done <<EOF
$(printf '%s\n' "$section" | sed -n 's/^- `\([a-z0-9-]*\)` - .*/\1/p')
EOF
  if [ -n "$dangling" ]; then
    fail "AGENTS.md section 13 triggers a skill that does not exist:$dangling"
  fi
  pass "every skill declares a load trigger and every section 13 trigger names a real skill"
}

# On 2026-08-30 a Codex crewmate dispatched to edit one guard script ran
# bin/fm-session-start.sh within a minute of launching, and recorded its reason:
# the command is "explicitly required by the trusted AGENTS.md instructions". It
# was right about the file and wrong about the addressee. AGENTS.md speaks to the
# firstmate primary in the imperative throughout, and every worker sent into this
# repository is handed it as instructions by its harness.
#
# What this test proves is narrow and worth stating: that the notice exists, that
# it names the traps rather than only the principle, and that it sits ahead of the
# first imperative a skimming reader would meet. It does NOT prove any worker was
# routed by it - no assertion over a source file can establish that a reader
# behaved. The evidence for routing is a worker that stops, and the only place it
# can appear is a status file.
test_agents_md_tells_a_worker_it_is_not_addressed() {
  local notice contract
  for phrase in \
    'this file is not addressed to you' \
    'operating contract of the firstmate primary that dispatched you' \
    'the file you may be changing, not your own orders' \
    'Your brief governs' \
    'the brief wins and you say so in a status line' \
    'Running session start, taking the session lock, draining the wake queue, running the bootstrap sweeps, and arming any check in this home are the primary'; do
    assert_grep "$phrase" "$AGENTS" "AGENTS.md lost the worker-addressee notice phrase '$phrase'"
  done
  # Ahead of the first imperative, not merely present somewhere in a 900-line
  # file: the worker this is for reads the first screen and acts.
  notice=$(grep -n -F -m1 'this file is not addressed to you' "$AGENTS" | cut -d: -f1)
  contract=$(grep -n -F -m1 'You are the first mate.' "$AGENTS" | cut -d: -f1)
  [ -n "$notice" ] && [ -n "$contract" ] \
    || fail "could not locate both the worker notice and the start of the operating contract"
  [ "$notice" -lt "$contract" ] \
    || fail "the worker-addressee notice (line $notice) does not precede the operating contract (line $contract)"
  # The notice reaches a Claude worker only because CLAUDE.md is the same file.
  [ -L "$ROOT/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink, so it no longer inherits the notice"
  [ "$(readlink "$ROOT/CLAUDE.md")" = "AGENTS.md" ] \
    || fail "CLAUDE.md does not point at AGENTS.md, so it no longer inherits the notice"
  pass "AGENTS.md tells a worker it is not the addressee, before the contract begins"
}

# AGENTS.md is the shipped operating contract itself, not a description of one:
# every session loads it in full, so the section-8 away-mode stub and the
# section-7 approval-authority contract are read together, by the same session,
# with nothing else loaded. That makes the ownership relation BETWEEN those two
# sections the thing under test, and both are read here as parsed sections
# rather than as one flat file, so a phrase that survives in the wrong section
# cannot satisfy the contract.
#
# The invariant: section 7 is the only place merge authority is created, and the
# away-mode stub creates none of its own in either direction - it neither
# withdraws what section 7 grants nor grants anything section 7 does not.
# docs/away-mode-approval-authority.md records why.
test_away_mode_neither_widens_nor_withdraws_authority() {
  local stub auth absolute conditional
  stub=$(awk '/^### Away-mode stub/{f=1} f && /^### Stuck-worker trigger/{exit} f' "$AGENTS")
  auth=$(awk '/^### Selected delivery path and approval authority/{f=1} f && /^### PR ready, landing/{exit} f' "$AGENTS")
  [ -n "$stub" ] || fail "AGENTS.md away-mode stub is missing or unparseable"
  [ -n "$auth" ] || fail "AGENTS.md approval-authority contract is missing or unparseable"

  # The stub's cross-reference resolves with nothing else loaded, and the
  # section it defers to still owns every merge rule the stub declines to
  # restate. A pointer at a section that no longer owns them is the same defect
  # as no pointer at all.
  assert_contains "$stub" "section 7's approval-authority contract" \
    "the away-mode stub no longer defers to section 7's approval-authority contract"
  assert_contains "$auth" 'With `yolo` off, the captain owns ask-user findings, PR merges' \
    "section 7 no longer places merges with the captain where yolo is off"
  assert_contains "$auth" 'With `yolo` on, firstmate decides those routine gates and merges only green or otherwise approved work' \
    "section 7 no longer places routine green merges with firstmate where yolo is on"
  assert_contains "$auth" "Never merge a red PR." \
    "section 7 no longer owns the red-PR prohibition the stub points at"
  assert_contains "$auth" "reads every required check against the pull request's head commit before merging" \
    "section 7 no longer owns the head-commit reading of the required checks"

  # One owner for what counts as green: the stub names section 7's head-commit
  # reading as section 7's own and defines nothing itself. A second definition
  # here is the failure mode the wording exists to avoid.
  assert_contains "$stub" "that section's own head-commit reading" \
    "the away-mode stub no longer sends an unattended merger to the head-commit reading"
  assert_not_contains "$stub" "green" \
    "the away-mode stub installs a second definition of green beside section 7's"
  assert_not_contains "$stub" "Never merge a red PR" \
    "the away-mode stub restates section 7's merge prohibition instead of pointing at it"

  # Withdraws nothing: the bundled prohibition that read as "no merging while
  # away" is gone from the whole always-loaded file, not merely from one section.
  assert_no_grep "Away mode never expands approval authority" "$AGENTS" \
    "AGENTS.md still withdraws, while away, a merge authority section 7 grants"

  # Widens nothing: the three absolutes are named again, in the same words, in a
  # bullet of their own that no conditional clause can reach, so narrowing the
  # merge case cannot become cover for widening any of them.
  absolute=$(printf '%s\n' "$stub" | grep -F -- "- Destructive actions, irreversible actions, and security-sensitive choices")
  [ -n "$absolute" ] || fail "the away-mode stub no longer states the absolute escalation list in a bullet of its own"
  assert_contains "$absolute" "wait for his explicit word however long he is gone" \
    "the absolute escalation list no longer waits for the captain for the whole absence"
  assert_not_contains "$absolute" "section 7" \
    "the absolute escalation list was made conditional on section 7's placement"
  assert_not_contains "$absolute" "Whatever" \
    "a conditional clause reaches the absolute escalation list"

  # The conditional bullet names both items it governs, so no reader has to
  # decide by proximity whether the qualifier covers the merge.
  conditional=$(printf '%s\n' "$stub" | grep -F -- "- Whatever section 7's approval-authority contract")
  [ -n "$conditional" ] || fail "the away-mode stub no longer carries section 7's placement as its own bullet"
  assert_contains "$conditional" "a routine merge and an ask-user finding alike" \
    "the placement bullet no longer names both items the section 7 condition governs"
  pass "away-mode stub defers merge authority to section 7, withdrawing none and granting none"
}

# A contradiction moved from one file to another is not resolved, so the skill
# away mode actually loads is held to the same ownership relation, and the
# pointers both surfaces make must resolve on the disk a vessel has after a pin
# bump.
test_afk_skill_keeps_one_merge_authority_owner() {
  local section
  section=$(awk '/^## Orthogonal to approval authority/{f=1} f && /^## Operational prefix contract/{exit} f' "$AFK")
  [ -n "$section" ] || fail "the afk skill lost its approval-authority section"
  assert_contains "$section" "section 7's approval-authority contract" \
    "the afk skill no longer points at section 7 as the merge-authority owner"
  assert_contains "$section" "away mode adds no merge authority and withdraws none" \
    "the afk skill no longer states away mode as authority-neutral"
  assert_not_contains "$section" "still waits for the captain's" \
    "the afk skill still makes a merge-ready PR wait for the captain that section 7 places with firstmate"
  assert_not_contains "$section" "green" \
    "the afk skill installs a second definition of green beside section 7's"

  # The record exists where the skill sends a reader, and it is indexed for a
  # human in README's docs list.
  assert_present "$AWAY_RECORD" "docs/away-mode-approval-authority.md is missing"
  assert_contains "$section" "docs/away-mode-approval-authority.md" \
    "the afk skill no longer points at the record of why this is the wording"
  assert_grep "docs/away-mode-approval-authority.md" "$README" \
    "README's docs list does not index the away-mode approval-authority record"
  # Deliberately NOT reachable from AGENTS.md: its token cost is paid by every
  # session of every fleet member, and only away mode needs the record.
  assert_no_grep "away-mode-approval-authority" "$AGENTS" \
    "AGENTS.md charges every session for a record only away mode needs"
  pass "the afk skill defers to the same owner and its record is reachable where it belongs"
}

# The record's whole purpose is explaining why precisely THAT wording landed, so
# it quotes the stub bullets verbatim - and a verbatim copy of always-loaded
# safety material is a copy that drifts. These quotes already needed re-syncing
# twice while this one change was being written, which is the case for asserting
# the agreement rather than remembering it.
#
# Neither side of the comparison is written down here: the expected text is read
# from AGENTS.md and the actual text from the record. Hard-coding the bullets in
# this file would be a third copy, and the drift this test exists to catch one
# file further along.
test_record_quotes_the_stub_verbatim() {
  local stub_bullets quoted count line
  stub_bullets=$(awk '/^### Away-mode stub/{f=1} f && /^### Stuck-worker trigger/{exit} f' "$AGENTS" | grep '^- ')
  [ -n "$stub_bullets" ] || fail "AGENTS.md away-mode stub has no bullets to quote"

  # The record quotes the replacement bullets between two of its own prose
  # anchors. The commentary bullets after the second anchor discuss the wording
  # rather than reproduce it, so they are deliberately outside the comparison.
  quoted=$(awk '/^Three bullets replace the one:/{f=1;next} f && /^Four properties this wording is holding/{exit} f && /^- /' "$AWAY_RECORD")
  [ -n "$quoted" ] || fail "the record no longer quotes the away-mode stub bullets, or its anchors moved"

  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    printf '%s\n' "$stub_bullets" | grep -Fxq -- "$line" \
      || fail "the record quotes an away-mode stub bullet AGENTS.md no longer carries byte for byte:"$'\n'"$line"
  done <<<"$quoted"

  # Presence alone would pass vacuously if a bullet were reworded in AGENTS.md
  # and simply dropped from the record, so the count is held against the
  # record's own sentence introducing the block.
  [ "$count" -eq 3 ] \
    || fail "the record says three bullets replace the one but quotes $count"
  pass "the record quotes the away-mode stub bullets byte for byte"
}

# The captain made "correct a claim that outruns its own run" standing on
# 2026-08-31, after firstmate's own count in that day's decision records recorded
# six findings of that class reaching him and each being answered the same way. It lands on three surfaces because three different
# readers need it: `ask-user-authority` is the owner and states it in full,
# AGENTS.md section 7 carries the carve-out because without it the always-loaded
# file still says the captain owns EVERY ask-user finding with `yolo` off, and
# the generated ship brief carries the worker-facing line because a worker reads
# neither of the other two.
#
# A rule contradicted one file over is not landed, so the shared load-bearing
# clause is asserted on all three by the same wording. The says-versus-does edge
# is asserted separately on the owner and the brief: it is the whole difference
# between this rule and a licence to make a claim true by changing behaviour,
# and it is the half that would be quietly dropped first.
test_claims_that_outrun_measurement_agree_across_surfaces() {
  local file section home id brief
  fm_test_tmproot home fm-instruction-owners
  mkdir -p "$home/data"
  id="owners-claim-rule-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"

  for file in "$ASKUSER" "$AGENTS" "$brief"; do
    assert_grep "only what the code says, not what it does" "$file" \
      "$(basename "$file") lost the shared says-versus-does clause"
  done

  assert_grep '## Claims that outrun what the run measured' "$ASKUSER" \
    "ask-user-authority lost the section that owns the standing claim-correction rule"
  section=$(awk '
    /^## Claims that outrun what the run measured$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$ASKUSER")
  assert_contains "$section" "defect in the same class as a wrong result" \
    "the rule lost the reason a reader acts on an overstated claim"
  assert_contains "$section" "does not reach the captain under either \`yolo\` posture" \
    "the rule lost the posture-independent grant that retires the escalation"
  assert_contains "$section" "never a licence to make a claim true by altering behaviour" \
    "the rule lost the explicit refusal to change behaviour to fit a claim"
  assert_contains "$section" "change what the code does rather than what it says" \
    "the rule lost the behaviour-change escalation case"
  assert_contains "$section" "reaches outside the module already under change" \
    "the rule lost the module-boundary escalation case"
  assert_contains "$section" "deciding what the right behaviour is" \
    "the rule lost the escalation case where the right behaviour is itself undecided"

  # The blanket in step 1 is the sentence these six findings were escalated
  # under, so it has to name the exception where it is read, not only below.
  assert_grep 'The one standing exception is the class in "Claims that outrun what the run measured" below' "$ASKUSER" \
    "the yolo-off blanket no longer names the standing exception"

  assert_grep 'One standing exception holds under either posture' "$AGENTS" \
    "AGENTS.md section 7 still gives the captain every ask-user finding with yolo off"
  assert_grep '`ask-user-authority` owns that boundary and the cases that still escalate' "$AGENTS" \
    "AGENTS.md section 7 lost the pointer to the owner of the boundary"

  assert_grep "Changing what the code DOES so the claim becomes" "$brief" \
    "the generated brief lost the behaviour-change escalation edge"
  pass "the claims-that-outrun-measurement rule is stated once and agrees on all three surfaces"
}

test_new_skill_metadata_and_triggers
test_every_skill_declares_a_load_trigger
test_domain_modeling_owner_is_triggered_and_attributed
test_diagnostic_owner_covers_causal_procedure
test_project_management_owner_covers_guarded_operations
test_secrets_owner_covers_exposure_response
test_ask_user_owner_covers_authority_procedure
test_claims_that_outrun_measurement_agree_across_surfaces
test_generic_effort_fallback_respects_precedence
test_shared_authoring_requirements_are_owned
test_secondmate_registry_contract_stays_concise
test_state_startup_and_ordinary_recovery_placement
test_recovery_stop_is_keyed_on_the_degraded_state
test_compressed_agents_owner_map
test_compressed_agents_retains_authority_and_supervision_safety
test_away_mode_neither_widens_nor_withdraws_authority
test_afk_skill_keeps_one_merge_authority_owner
test_record_quotes_the_stub_verbatim
test_agents_md_tells_a_worker_it_is_not_addressed
