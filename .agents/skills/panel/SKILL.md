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

`bin/fm-model-panel.sh` owns the mechanics; its header and `--help` are authoritative for commands, flags, the configuration resolution order, and exit statuses.
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
   The second `advance` prints `complete: <report path>` once the judge's report exists.
5. **Read the judge's report and relay its findings.**
   Relay the answer, the contested facts and what the evidence showed, any mistake shared by both analysts, and what remains unverified.
   Say which models argued and which judged: that is substance the captain asked for, not internal machinery.
   Never relay a raw report; follow the captain-facing translation contract in `AGENTS.md` section 9.
6. **Pass the shared completion gate before treating the panel as done.**
   A panel reliably surfaces captain decisions, which is exactly the work that gets lost, so the judge's report ends with a decisions inventory.
   Load `decision-hold-lifecycle` and register every unresolved decision from that inventory before calling the panel complete.
7. **Tear down the members normally.**
   Every report survives teardown at `data/<task-id>/report.md`, and the panel record at `data/<panel-id>/panel.meta` records which model filled which role.

## When the panel cannot be a panel

`start` refuses with exit 4 when both analysts would resolve to the same model.
That refusal is correct and must not be worked around: two identical analysts are not independent, and a panel that quietly is not one is worse than no panel.

Tell the captain plainly that this home can currently reach only one model for the analyst seats, and offer the two real options:

- Configure a second distinct model for the second analyst seat, then re-run the panel.
- Run the reduced form with `--reduced`: one analyst plus a judge that re-verifies its claims.

The reduced form is a **single-analyst review**, not a panel.
Its briefs, its record, and its judge's own report all say so.
Never describe its output as a panel result, an independent cross-check, or a second opinion.

When no third distinct model is available the judge shares a model with one analyst.
That prints a warning and proceeds, because the judge's independence comes from re-verifying against live state with every report in hand rather than from its runtime.
Mention it when relaying if the verdict is close.
