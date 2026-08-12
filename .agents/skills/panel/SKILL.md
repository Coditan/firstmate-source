---
name: panel
description: >-
  Run a model panel: two analysts answer one question independently on different models without seeing each other's work, then a third model judges both and re-verifies their load-bearing claims itself.
  Use when the captain invokes /panel, asks for a panel, a second opinion from another model, a cross-check, or an adversarial review of an answer, and when a contested or expensive-to-get-wrong question would otherwise be settled by one voice.
  Owns the decision of when a panel is worth its cost, the operating sequence around bin/fm-model-panel.sh, and the honest handling of a home that cannot field two distinct models.
user-invocable: true
metadata:
  internal: true
---

# Model panel

Two analysts answer the same question independently on different models, neither able to see the other's work, and a third model judges them.
The value is not three opinions.
It is independence plus adversarial verification: the judge re-verifies the load-bearing claims itself instead of refereeing rhetoric, so it can catch the mistake both analysts made for the same reason, which neither could have caught alone.

`bin/fm-model-panel.sh` owns the mechanics; its header and `--help` are authoritative for commands, flags, role-selection stages, and exit statuses.
[`docs/configuration.md`](../../../docs/configuration.md) owns the panel configuration schema and configuration lookup order.
This skill owns when to run one and how to carry it through.

## Is this question worth a panel

A panel costs two full investigations plus a judge that re-checks their evidence, and two rounds of supervision between dispatch and answer.
Spend that only where a second independent answer would change what happens next.

Worth it:

- The question is contested or expensive to get wrong, and would otherwise be settled by one confident voice.
- The answer depends on live state that written records describe unreliably, which is exactly where a single analyst inherits a stale claim and never notices.
- Several orderings or designs are defensible and the choice matters more than the analysis.
- An earlier answer read as confident but thin, and you want it attacked rather than repeated.

Not worth it:

- The question has one obvious answer, or one command settles it.
- The work is implementation against a clear specification; that is an ordinary ship task.
- The real bottleneck is a captain decision rather than analysis; register the decision through `decision-hold-lifecycle` instead.
- Speed matters more than confidence.
- You would act the same way whatever the judge concluded.

Write the question down precisely before starting.
Both analysts receive byte-identical text and nothing else, so a vague question wastes the whole formation; put a long question in a file and pass `--question-file`.

## Operating sequence

1. **Start the panel.**
   `bin/fm-model-panel.sh start [--project <name-or-path>] "<question>"` resolves the lineup, writes the briefs, and dispatches the analysts concurrently.
   Use `--dry-run` first when you want to show the captain which models will argue before spending anything.
   `--project` defaults to the firstmate repo, which is what a question about the fleet needs; pass a project name for a question about that project's code.
2. **Supervise the analysts as ordinary scouts.**
   They report through the normal status path and wake you the normal way.
   Do not relay their individual reports to the captain and do not let one analyst see the other's work; the independence rule in their briefs is the whole point.
3. **Advance once every analyst has reported.**
   `bin/fm-model-panel.sh advance <panel-id>` refuses to create the judge until every analyst has both written a terminal status event and left a non-empty report, so run it after each analyst finishes and let it tell you whether it is still waiting.
   A `waiting:` line means nothing to do yet, and it names which of the two facts is still missing for which analyst.
4. **Supervise the judge, then advance again.**
   The second `advance` prints `complete: <report path>` once the judge has both reported a terminal status event and left a non-empty report, which is the same gate its analysts passed.
   A `wedged:`, `stood down:`, or `verdict lost:` block instead of a `waiting:` line means the panel needs a decision from you; read the next sections before doing anything about it.
5. **Read the judge's report and relay its findings.**
   Relay the answer, the contested facts and what the evidence showed, any mistake shared by both analysts, and what remains unverified.
   Say which models argued and which judged: that is substance the captain asked for, not internal machinery.
   Never relay a raw report; follow the captain-facing translation contract in `AGENTS.md` section 9.
6. **Pass the shared completion gate before treating the panel as done.**
   A panel reliably surfaces captain decisions, which is exactly the work that gets lost, so the judge's report ends with a decisions inventory.
   Load `decision-hold-lifecycle` and register every unresolved decision from that inventory before calling the panel complete.
7. **Tear down the members normally.**
   Every report survives teardown at `data/<task-id>/report.md`, and the panel record at `data/<panel-id>/panel.meta` records which model filled which role.

## When a member never signals that it finished

Writing the report and appending the terminal `done:` or `failed:` line are two separate acts, and a member that is between them is doing something completely ordinary.
So a member that still has its runtime record gets the plain `waiting:` line, and there is nothing for you to do: it will append its own terminal line and the next `advance` proceeds.

`advance` prints a `wedged:` block only when the member left a non-empty report and is GONE, with no runtime record left, because it was torn down or crashed after writing its report and before signalling.
That line will never arrive on its own, so the block names the member and prints the exact command: `bin/fm-model-panel.sh advance <panel-id> --accept-unfinished <task-id>`.

That override is per-member and deliberate.
It names one task id and waives nothing for any other member, it is recorded permanently in the panel record as `accepted_unfinished`, the judge's brief is told to treat that report as possibly truncated and to say so in its own report, and an accepted judge report puts the caveat on every `complete:` output.
It also stays available for a member that still looks present but you know is dead, such as one killed by a harness crash that left its runtime record behind; used that way it warns you that the member may still be writing, and you should be sure before overriding it.
There is no timeout anywhere in this formation: a panel waits forever rather than judging an unfinished report on its own, so the decision to accept one is always yours.
Say so when relaying the verdict, because a panel completed over an unfinished report is a weaker result than one that was not.

## When an analyst finishes without a report

`advance` prints a `stood down:` block and exits 1 when an ANALYST stops writing without leaving a report, either by ending with a terminal status event or by losing its runtime record.
That member has stopped writing, so no report can arrive, and the panel cannot produce a verdict.

Stand the panel down and tell the captain it produced nothing.
The override deliberately refuses to waive a missing report: a verdict built on the one report that survived is not a panel, and presenting it as one would rebuild the echo-as-corroboration failure this formation exists to refuse.
If the captain still wants the surviving analysis, that is a NEW single-analyst review started deliberately with `--reduced`, which is labelled as such in the briefs, the record, and the judge's own report, and never this panel converted in place.

## When the judge finishes without a verdict

`advance` prints a `verdict lost:` block when the JUDGE stops writing without leaving a report, either by ending with a terminal status event or by losing its runtime record.
This is not a dead panel: both analyst reports are complete and untouched, and only the adjudication is missing, so the formation is intact.

Run `bin/fm-model-panel.sh advance <panel-id> --rejudge` to dispatch one replacement judge over those same unchanged reports.
The superseded judge task is recorded in the panel record, no report is stamped incomplete by it, and nothing re-dispatches on its own.
A judge that still holds its runtime record and has written nothing is indistinguishable from one that is working, so `advance` prints the plain `waiting:` line and `--rejudge` refuses; if you know that judge is dead, such as one killed by a harness crash that left its runtime record behind, tear it down first and then `--rejudge`, which is permitted once the record is gone.
Mention when relaying that the verdict came from a replacement judge, because the captain is entitled to know a judge was lost.

## When the panel cannot be a panel

`start` refuses with exit 4 when either analyst lacks an explicit model pin or both analysts resolve to the same configured model identity.
That refusal is correct and must not be worked around: an unpinned harness default is unknown, two identical analysts are not independent, and a panel that quietly cannot prove its independence is worse than no panel.

Tell the captain plainly that this home cannot currently prove two distinct configured model identities for the analyst seats, and offer the two real options:

- Configure a second distinct model for the second analyst seat, then re-run the panel.
- Run the reduced form with `--reduced`: one analyst plus a judge that re-verifies its claims.

The reduced form is a **single-analyst review**, not a panel.
Its briefs, its record, and its judge's own report all say so.
Never describe its output as a panel result, an independent cross-check, or a second opinion.

When no third distinct configured model is available the judge shares a model with one analyst.
An unpinned judge has unknown runtime model identity and receives the same warning class rather than being treated as distinct.
Both warnings proceed, because the judge's independence comes from re-verifying against live state with every report in hand rather than from its runtime.
Mention it when relaying if the verdict is close.
