# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity, including one that retention has already moved into the archive.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

When an identity is no longer in the live backlog, `complete` and `verify` fall back to `data/done-archive.md`, where retention moves Done work.
That archive record satisfies the gate only when every archived entry under the identity is a completed kind `captain` item carrying both the recorded resolution and its routed work, so a stale resolution can never vouch for a later decision that reused the same key.
An entry that is still open, is not kind `captain`, or lacks either marker refuses, which keeps the gate fail-closed.
Both the `- [ ]`/`- [x]` checkbox bullets and the older `- **<id>**` in-flight bullet that tasks-axi still parses count as entries, so a legacy-form record is read as unresolved rather than becoming invisible to the scan.
Both questions are scoped to the one identity, so an unresolved entry for a different decision never affects it.
The `hold` reopen guard reads the same archive with the opposite question - whether *any* archived entry under the identity already carries a resolution - so a mixed archive still refuses to reopen a decision the captain has answered.
When an archived entry is what refuses, the message names that entry by archive path and line and states the repair, so a permanent refusal explains itself instead of reading as an unexplained gate failure.
An accepted limitation follows from the all-resolved question: one identity carrying both a resolved and an unresolved archived entry stays refused until an operator repairs the archive.
Reaching that state needs a manual `tasks-axi prune --state queued` or a hand edit, since ordinary retention rotates only completed work into the archive ([configuration.md](configuration.md) owns the backlog backend's retention and archive settings), and the lockout is preferred over trusting chronological append order in exactly the hand-edited case that produces it.
The gate pins the archive path to `data/done-archive.md` rather than resolving it from tasks-axi configuration; repointing `markdown.archive` or moving `FM_DATA_OVERRIDE` away from `$FM_HOME/data` refuses cleanup rather than accepting it wrongly.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps real unfinished blockers unresolved, records blocker ids found nowhere in the live backlog or done archive as dangling, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open`, leaves blocked captain holds in ordinary queued gates, and surfaces dangling blocker edges in `integrity[]` as ready work with a data-integrity caution.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Archived-resolution fallback verification date: 2026-07-27.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
A further regression resolves a hold, rotates it into the archive with `tasks-axi prune`, and proves cleanup then succeeds while the same identity can no longer be reopened, and that a reused identity, a completed captain entry with no recorded resolution, and a still-open archive lookalike each still refuse.
It also covers a mixed archive in both directions: an identity carrying both a resolved and an unresolved entry still refuses to reopen, and a genuinely resolved identity still satisfies the gate when an unrelated identity's unresolved entry sits in the same archive.
Each archive-driven refusal asserts that the message names the blocking entry and its repair, and an identity absent from both the backlog and the archive keeps its own distinct refusal.
One scenario pairs an older resolved entry with a newer unresolved legacy-form bullet under the same identity, so the gate refuses instead of letting the stale resolution answer for work nobody decided.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - resolved archived holds satisfy cleanup while reused, unresolved, and missing holds still refuse
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ bin/fm-test-run.sh --all
FM_TEST_SUMMARY total=110 failed=1 skipped_gate=19 duration_ms=1285836

$ env -u NO_MISTAKES_GATE bash tests/fm-sessionstart-nudge.test.sh
ok - fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line
ok - fm-sessionstart-nudge: NO_MISTAKES_GATE is silent
ok - fm-sessionstart-nudge: .no-mistakes gate common-dir is silent
ok - fm-sessionstart-nudge: an unmarked linked task worktree is silent
ok - fm-sessionstart-nudge: a marked linked secondmate home is a primary
ok - fm-sessionstart-nudge: a checkout without state is silent
ok - fm-sessionstart-nudge: a lock holder in process ancestry is already run
ok - OpenCode session.created delivers the exact wrapper nudge once per session
ok - all five verified harnesses register the shared session-start nudge
```

The complete-regression walk above ran every one of the 110 `tests/*.test.sh` scripts through their owner, `bin/fm-test-run.sh --all`; none were skipped by selection, and the 19 counted gate skips are scripts that self-skip when an optional multiplexer or harness binary is absent.
Its one failure, `tests/fm-sessionstart-nudge.test.sh`, is an artifact of the review environment rather than a regression: that script asserts the session-start nudge prints, and `bin/fm-sessionstart-nudge.sh` is deliberately silent whenever `NO_MISTAKES_GATE` is set, which it is inside a no-mistakes gate agent.
Re-running that single script with the variable unset passes all nine of its cases, as recorded above.
