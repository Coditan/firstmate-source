---
name: task-landing
description: >-
  Agent-only procedure for a task's work coming back.
  Use when a worker reports a PR or a clean ready branch, before recording or landing one, after relaying a terminal task outcome, before tearing a finished task down, when a scout's report arrives, and before promoting a scout to implementation.
  Owns PR recording, the landing and cleanup sequence, secondmate retirement, and the scout report and promotion path.
user-invocable: false
metadata:
  internal: true
---

# task-landing

This skill is the single owner of what firstmate does once a task's work comes back.
The standing boundaries it operates under stay always loaded in `AGENTS.md`: hard rules 2 and 3, the merge authority and never-merge-red rule, the guarded merge scripts, and the never-force-cleanup rule.
`AGENTS.md` section 7 carries the trigger that loads this skill.
For starting a worker or driving a live validation run, load `crew-dispatch` instead.

## PR ready, landing, and teardown

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>` - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Tell the captain the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
The refusal no longer strands the task's merge poll: a teardown that refuses still retires a poll whose pull request has already merged, and says so in its own output alongside the refusal.
To retire a poll on any other occasion, run `bin/fm-pr-check.sh --disarm <id>`, which removes the whole artifact set, leaves the recorded `pr=` alone, and is safe to run twice or on a set already partly removed by hand.
It retires merge polls only: on a task whose `state/<id>.check.sh` is a custom check you registered, it refuses and removes nothing, because that name and its trust record belong to the check you wrote.
Never remove a poll's files by hand: that is the state machinery `AGENTS.md` section 2 protects, and a half-removed set is what hand-removal leaves behind.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

After relaying a terminal task outcome and confirming that only external human action remains, run `bin/fm-mark-parked.sh <window>` (the exact window recorded in its meta) so repeated pane changes use the bounded external-wait cadence; it refuses an unrecognized window or a `kind=secondmate` window instead of silently creating a marker that matches nothing or that fights pause tracking.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read the report, relay its findings rather than merely saying it finished, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `decision-hold-lifecycle`; teardown enforces that shared completion gate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path.
Scratch commits and debug edits never ride along, and a reproduced bug becomes the regression test.
