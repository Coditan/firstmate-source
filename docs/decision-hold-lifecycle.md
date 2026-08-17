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
An interrupted `record --supersedes` retry and the fold's successor validation use the same fallback, so retention cannot leave the earlier question open after its answer is archived.
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

## The store had one entrance, and the measurement that showed it

The measurement was taken on 2026-08-17, after the captain said the fleet was making him decide the same things again after every reset.
Four decisions he gave that day, every one acted on and every one landed, were counted against the backlog:

```text
bosun-drift-stall    backlog mentions: 0
captain-exception    backlog mentions: 0
curate-route         backlog mentions: 0
tier-overlap         backlog mentions: 0
```

Each existed in three places and every one is temporary: a worker's `state/<id>.status` log, which cleanup deletes; a pull-request body, which lives on the forge rather than in this fleet's records; and one session's context, which a reset ends.

The cause was not a missing store.
`hold` and `resolve` already worked, and the backlog already held decisions durably.
They covered exactly one door - a decision an investigation or visual review discovered and registered ahead of the answer - and most of that day's decisions came through the two doors that had no durable home at all: an ask-user finding returned by a validation gate, and a sentence the captain said in chat.

A second, separate failure was measured on the same day.
`bridge-forgejo-standup-decision-metadata-rpo` had been answered, the answer was written into a task body, and the hold still read `held: yes` because the close was started and never finished, with nothing detecting it.

## The `record` entrance

`record` writes the same resolution record into the same store, for a decision that arrived through any door.
It differs from `resolve` in exactly the two ways those doors require: it creates the kind `captain` item when none exists, so no prior registration is needed, and it accepts zero `--routed-to` tasks, because a decision the captain gave and a worker acted on immediately gated no future work.
It is one store with several entrances rather than a second store beside the holds, so `verify_hold_durable`, the completion gate, and the archive scan all recognise a recorded decision without change.

`--door` is required and closed-vocabulary (`hold`, `ask-user`, `chat`), so the store can be asked which entrances it is actually covering rather than answering that question with free text.
An origin that names no task in this home is accepted when `--repo` is given, because a decision the captain states in chat belongs to the home he stated it in even when it names no local work; `hold` keeps its stricter origin-ownership check, which is correct for a question *about* a piece of local work.

The captain's words are stored byte for byte.
The one boundary normalization is that trailing newlines are stripped from the decision file, on the grounds that a text file's terminating newline is not part of what was said.
Everything else is refused rather than repaired: a carriage return is rejected before the write, a decision containing one of the three envelope marker lines at the start of a line is rejected before the write, and after the write the stored text is read back out of the raw markdown and compared byte for byte with what was handed in.
A sha256 of the decision text is recorded beside it, and `bin/fm-decision-ledger.sh` recomputes it on every read, so a later hand-edit of a settled decision shows up as `altered-record` instead of being read as the captain's word.

Measured round-trip fidelity, 2026-08-17, against `tasks-axi` 0.2.5: a body containing double quotes, a literal backslash-`n`, tab indentation, four-space indentation, trailing spaces, interior blank lines, non-ASCII text, a line reading `## Done`, and a line shaped exactly like a task row (`- [ ] evil-id - looks like a task (kind: captain)`) round-tripped unchanged, and the task-row-shaped line did not create a phantom record in `tasks-axi list`.

## An unfinished close is detectable by construction

Both `resolve` and `record` write the resolution body first, then clear dependency edges, then close the item.
That ordering is the detection mechanism, not an implementation detail: a close interrupted anywhere leaves a captain item carrying a resolution record while still open, which is a state nothing else produces.
Re-running the identical command finishes it.

`bin/fm-decision-ledger.sh --audit` reports four structural classes, none of which reads prose to infer that a decision happened:

| class | shape in the records | what it means |
| --- | --- | --- |
| `unfinished-close` | captain item carries a resolution record, is not Done | the close was interrupted; the identical `record` call completes it |
| `closed-without-record` | captain item is Done, carries no resolution record | the question left the open surfaces and the answer was never stored |
| `acted-but-open` | captain hold still held, blocks at least one task, every task it blocks is Done | the work went ahead, so the answer was given; nothing closed the hold |
| `altered-record` | stored decision text does not match its recorded digest | the stored words are no longer the words that were recorded |

`acted-but-open` is the class that catches an answered-and-acted-on hold once the work it gated has finished.

### What this does not detect, stated plainly

An interrupted close is detectable because the mechanism wrote something before it stopped.
A close that never entered the mechanism at all leaves nothing to detect, and that is the honest limit of this half.

Measured on the recovery-point record `bridge-forgejo-standup-decision-metadata-rpo` on 2026-08-17: the captain answered it, the answer was written by hand into the body of the ship task the question gated, and the hold still reads held.
`acted-but-open` does not fire on it, because the one task it blocks is queued rather than Done.
Nothing else fires either, and nothing structural could: a hold whose gated work is filed but not yet started is indistinguishable, in the records, from a hold that was answered by hand and whose gated work is filed but not yet started.
The only signal separating them is the decision text sitting in that task's body, and reading prose to infer that a decision happened is exactly what this lifecycle forbids.

So this record converges by two routes that already exist, neither of them a detector:

- The intake gate lists it the next time any captain record is filed for the same repository, and refuses to add one until the filer disposes of it.
- `bin/fm-decision-ledger.sh --premises` carries it into the weekly sweep with its premise and the fact that nothing has re-measured it.

Both put it in front of a reader who can see the answer.
Neither claims to have found it, and no class here should be widened until it can fire on this shape without guessing.

## The audit had to converge before it could be read

Run against the main home on 2026-08-17, `--audit` reported 58 findings.
57 of them were on captain records closed long before any of this existed: 48 `closed-without-record`, and 9 `stale-body-state` that were nine of those same records counted a second time.
Exactly one finding, a `duplicate-suspect`, sat on a live record.

`bin/fm-bootstrap.sh` prints one line per finding at every session start, and `bootstrap-diagnostics` directs a reader to handle each one.
So as first written the check opened at 57 irreparable demands and could never reach zero, and the only available response to it was to stop reading it.
That is the same failure this whole mechanism exists against, one layer up: a check nobody reads and a store nobody consults fail in exactly the same way.

`--record-baseline` writes the findings that sit on already-closed records into `data/decision-baseline.md`, once, as a deliberate statement that those particular answers are lost rather than pending.
`--audit` then withholds exactly those `(class, id)` pairs and states in one line how many it withheld and where they are listed.
The same home reads as two findings afterwards, both real.

Three rules keep the baseline from becoming a mute switch, and each is a regression rather than an intention.

- **Only an already-closed record may be covered.**
  A closed record's answer is either stored or lost, and no later act recovers a lost one; every other class sits on a live record and stays repairable.
  The generated entry membership is bound by a digest, and the permitted classes and the record's closed date observed at baseline time are enforced when the file is read rather than trusted from it.
  Any added or removed entry invalidates the whole baseline, reports `baseline rejected`, and leaves every finding visible until the file is deleted and re-taken.
  An intact entry whose class or closure no longer matches is likewise ignored and reported as `baseline rejected`.
  A closed record without a closed date is skipped and remains reported because it cannot be bound to an observed closure.
- **A record closed after the baseline was taken is a new failure** and is reported in full.
  The baseline covers the records it named, never the shape of the finding.
- **Nothing is dropped.** The file is the list, `--audit --json` still carries every withheld finding under `baseline_excluded`, the withheld count is stated on every direct run, and re-taking a baseline means deleting the file by hand.

`bin/fm-bootstrap.sh` separately caps how many finding lines reach a startup digest and states the remainder rather than truncating in silence, so a home that has not taken a baseline still gets a readable startup.

## The store had an intake step and no supersession step

A second measurement on 2026-08-17 canvassed three seats and found the same shape at every scale.

| seat | open captain records | duplicates | already answered | genuinely open |
| --- | --- | --- | --- | --- |
| first | 99 | 18 | 14 | 67 |
| second | 5 | 2 | 2 | 3 |
| third | 2 | 0 | 0 | 2, with 225 already folded into its archive |

Two-thirds noise on the first seat, 40 percent on the second, at a twentyfold difference in scale.
The third seat shows that folding does happen and the count does not only rise.

The cause is not carelessness: every one of those records was filed correctly.
An investigation must register its unresolved decisions before it may complete, and each of them did.
Nothing required it to ask whether the question already existed, and nothing re-measured a premise after filing.
The rule was not being broken; it had an intake step and no supersession step.

### Why the fold is the filer's act and not a detector

The second seat's two duplicates asked one question in entirely different vocabulary: one asked whether a named company counts as a customer, the other asked which parties count as intra-group.
No shared wording, no shared decision key, no shared origin group.
No matcher pairs those, and a text-similarity matcher would not either.
The filer knew it was re-asking; nothing asked it.

So `hold` and `record` refuse to add a captain record while this home holds others for the same repository the caller has not disposed of, and the refusal prints them - the open questions and the recorded answers both - before any attestation is possible.
`--supersedes <id>` folds one; `--new-ground` attests that none of them asks this question.
The gate is on the answer as well as the question, because an answer that cannot fold what it settles leaves it standing: that is exactly how the second seat kept two records open on a question the captain had ruled on hours earlier with the fix already in an open pull request.

`bin/fm-decision-ledger.sh --audit` also reports `duplicate-suspect` and `open-but-settled`, which are structural and provable.
They are a backstop for records filed before this gate existed, not the mechanism, and the header of that script states the limit in the same words.

### A fold is a third disposition, not a second kind of answer

`supersede` closes a record with a `Superseded by fm-decision-hold.` envelope naming the successor and the reason, moves any work the folded record gated onto the successor, and states in the record itself that the captain did not answer it.
`verify_hold_durable` and the archive scan accept a folded record as durable, so a completion gate never demands an answer to a question a later record already covers.
An answered record can never be folded: its body carries the captain's words, and a fold would replace them with a pointer.

## Premise re-measurement, and the outcome that must never be folded

The proposal was a premise re-check that folds a decision whose stated premise no longer measures true.
That rule is dangerous as stated, and the third canvass seat measured why.

One of its records said a validation gate registered that home against the wrong public repository, so a push from there would land in the wrong place.
Re-measured, the registry was empty and the premise did not measure true.
But the record had been measured on a path that seat no longer occupied: the seat had moved and the validation state had not come with it, so the wrong registration may still stand on the original machine, which that seat cannot see.
A premise re-check that folded on that reading would have closed a live finding, and nobody would have been left who could see it.

**`unmeasurable` is therefore a first-class third outcome, never a synonym for false.**
`bin/fm-decision-hold.sh recheck --outcome holds|broken|unmeasurable --measured-at <locator>` records the reading together with the seat it was taken on (`<hostname>:<home>`), because a record whose premise cannot be located is the case that matters.
`recheck` closes nothing under any outcome; even a premise measured genuinely false is folded, or answered, as a separate deliberate act.
`bin/fm-decision-ledger.sh --audit` reports `premise-unmeasurable` and says in the finding itself that it is not grounds to fold.

This is the same reason no facility was built to execute stored premise-check commands.
Most premises are not computable predicates, such a facility would add an execution surface to the weekly sweep, and the honest alternative is available: `bin/fm-decision-ledger.sh --premises` lists every open decision with its premise and the date and seat of the last reading, oldest first, and states in its own header that it never claims a premise still holds.
The `grossreinschiff` skill's sections 2 and 4 are where that list is worked, which is what the weekly sweep already is.

### The exit problem in its second form

The same seat found three of four holds closed that day still carrying `State: awaiting captain decision` in their own body text.
A reader who trusts the body reaches the opposite conclusion from one who trusts the record state, and neither can tell which is stale.
`bin/fm-decision-ledger.sh --audit` reports that as `stale-body-state`.
Every close this mechanism performs overwrites the body, so it cannot produce the state itself; the class exists for records closed outside it.

## Reading the record before presenting anything as open

A store nobody consults is the same failure wearing different clothes, so the read side is wired into three places rather than left to a session's memory.

`bin/fm-session-start.sh` prints the settled decisions, in the captain's own words, in its fleet digest, and its closing reminder states that they are decided.
That is the reset case: a decision given in an earlier session is not in this session's context, and this is where a fresh session meets it.

`bin/fm-bootstrap.sh` runs the audit detect-only at every session start and prefixes each finding as `DECISION_LEDGER:`.
It is silent when there is nothing to report, consistent with the rest of that section.

`bin/fm-fleet-snapshot.sh` sets `answered_pending_close` on any non-Done record whose first body line is the resolution marker, and withholds such a record from `captain_actionable`.
Both `decisions_open` in the canonical snapshot and the decision board that reads it therefore stop presenting an answered decision as an open question.
The board reaches that state through two layers rather than reading the store itself - `bin/fm-decision-inventory.sh` reads `bin/fm-bearings-snapshot.sh`, which reads the canonical snapshot - so it is covered by its own regression at the board's own input rather than inferred from the layer beneath it.
The record is not dropped silently: it still appears in the queued gates surface, and both `bin/fm-fleet-snapshot.sh` and `bin/fm-bearings-snapshot.sh` replace its stale hold reason with one saying the decision is answered and the close unfinished.

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
Every-door recording, supersession, intake gate, and premise re-measurement verification date: 2026-08-17.
Adoption-baseline, board-input, and startup-cap verification date: 2026-08-17.

The baseline measurement was taken against a copy of the main home's `data/backlog.md` and `data/done-archive.md`, read-only, with `FM_HOME` pointed at the copy.
Before: `--audit` printed 58 findings and exited 1 - 48 `closed-without-record`, 9 `stale-body-state`, 1 `duplicate-suspect`.
After `--record-baseline`: 2 findings, being the `duplicate-suspect` and a `closed-without-record` deliberately appended after the baseline to prove a later loss still reports, plus one line naming the 57 withheld.
A `duplicate-suspect` line hand-added to the baseline file silenced its finding on the first attempt, which is the defect the permitted-class filter now prevents and `test_a_baseline_cannot_silence_a_repairable_record` holds.
With no baseline recorded, `bin/fm-bootstrap.sh` printed 13 `DECISION_LEDGER:` lines rather than 59: twelve findings and one stating the 48 not shown.

Two defects were found by these regressions rather than by reading, and both are recorded because each is a shape the next change could reproduce.
The first: `record` wrote its resolution body with the routed-work list run onto the `Routed work:` line, because a command substitution ate the terminating newline; the write-then-close ordering meant the failing verification left exactly the visibly unfinished record it is designed to leave, which is how it was noticed.
The second: `supersede` moved no dependency edges at all, because the environment-variable prefix carrying the hold id attached to the `tasks_axi` shell function rather than to the `awk` in the pipeline behind it, so the lookup silently matched nothing. It reads as working - the fold completes, the record closes - and only a test that asserted where the gated work ended up caught it. That is now `test_a_fold_moves_the_work_the_question_gated`.

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
$ bash tests/fm-decision-ledger.test.sh
ok - a settled decision survives retention into the archive and still reads verbatim
ok - a second question cannot be filed without disposing of the one already there
ok - an answer folds the open questions it settles and keeps the trail to them
ok - a fold carries the work the question gated, and the answer lifts that gate
ok - a premise that could not be measured is surfaced, never folded as a false one
ok - an edited decision stops reading as verified instead of passing as his word
ok - the audit finds every way a captain decision record can be left unfinished
ok - a home with no unfinished decision record reports no findings and exits clean
ok - an answered decision leaves the open-decision surface and says why

$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - ask-user and chat decisions become durable records with the captain's exact words
ok - recording is idempotent on replay and refuses a conflicting answer under one key
ok - recording refuses text it could not store verbatim, before writing anything
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
