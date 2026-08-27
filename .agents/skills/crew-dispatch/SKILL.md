---
name: crew-dispatch
description: >-
  Agent-only procedure for starting a worker and driving it while it runs.
  Use before spawning a crewmate or scout, before steering one, and whenever a no-mistakes validation run on a live worker needs triggering, reading, or answering.
  Owns the spawn handoff, the steering channel, the validation-run ownership rule, and how a run's true state is read.
user-invocable: false
metadata:
  internal: true
---

# crew-dispatch

This skill is the single owner of what firstmate does between deciding to dispatch a task and that task's work coming back.
The standing boundaries it operates under stay always loaded in `AGENTS.md`: hard rule 1, the worktree-isolation assertion, the selected delivery path's own rigor, and the ask-user escalation authority.
`AGENTS.md` section 7 carries the trigger that loads this skill.
When the work coming back is a PR, a ready branch, or a scout report, load `task-landing` instead.

## Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in `AGENTS.md` section 4.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
After spawning, confirm the worker is processing the brief, handle any trust dialog through `harness-adapters`, and record ship or scout work as under way.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with short single-line messages through fail-closed `fm-send`; put long instructions in a file.
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.
Supervise all live work under `AGENTS.md` section 8.

## Validate

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.

An ask-user finding returns as `needs-decision`; firstmate decides only when the configured authority permits, otherwise escalates to the captain.
Load `ask-user-authority` before deciding one, whatever the project's `yolo` posture.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the current-code-matched run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
