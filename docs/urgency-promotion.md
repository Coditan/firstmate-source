# Urgency promotion

The tier that raises an event's urgency when the event's own declaration understates its content.

`bin/fm-urgency-lib.sh`'s header is the authoritative owner of the priority ladder, the rule table, the never-lower property, and the promotion record format.
`bin/fm-urgency.sh --help` owns the read and replay commands.
This document owns why it exists in this shape, what is proven, what the rules cost in real traffic, and what was deliberately left unbuilt.

## What was wrong

The residue measured in this fleet's notification stream is **under-declared urgency**: events arriving marked less urgent than their content turned out to be.

The panel judge verified one by hand on 2026-08-11 and named it in `data/panel-question-should-this-fleet-1177-judge/report.md`.
Bridge envelope `2026-08-10T01-22-13Z-tugboat-80-443-open-to-any-source-input-policy-accept-no-cloudflare-rule-1bea9be771ac4bea.json`, declared priority `normal`, kind `reply`, subject **"80/443 open to any source: INPUT policy ACCEPT, no Cloudflare rule"**.
A firewall opened to the whole internet, arriving marked as ordinary traffic.

That is the opposite job from filtering noise out, so it is a separate capability and not a setting on a filter.
The captain chose on 2026-08-11 (`data/decisions-2026-08-11/promoter-vs-filter-and-sequencing.md`) to build it alongside the mechanical repairs rather than behind a measurement, because measuring first delays any relief and the repairs alone do not address this residue.

He separately settled that volume is solved downstream by judgement, never upstream by removing or quieting an observer.
So nothing in this unit suppresses, drops, defers, or downgrades an event.
It raises, or it leaves alone.

## What it is

A mechanical reading of an event's text against a named rule table, producing an effective priority at or above the declared one.

```text
bin/fm-urgency.sh classify <text>     # decide one event, showing every rule that matched
bin/fm-urgency.sh replay              # run the rules over recorded history, report what they would do
bin/fm-urgency.sh promotions          # read the decisions back, with the evidence that triggered them
bin/fm-urgency.sh rules               # the rule table that actually runs
```

No model call, no network, no clock dependence: the same event text always yields the same verdict.
That is what makes a promotion replayable afterwards, and it is why this can run in the watcher's own path rather than behind a tier that has to be awake.
It is a deliberate contrast with the observer bosun, which asks a model and takes 3.5-7.7 seconds per event; a tier that actually changes what surfaces cannot carry that.

The ladder is `low < normal < high < immediate`.
It is not a new vocabulary: it is the one Bridge envelopes already carry in their own `.priority` field and the one the captain's batching delays are stated in.

## It only ever raises

`fm_urgency_effective` returns the **maximum** of the declared priority and every rule floor that matched.
Lowering is not a path that exists to be disabled; it is unreachable by construction, because a maximum over a set that always contains the declared priority can never fall below it.
There is deliberately no demotion function in the file.

The property is asserted exhaustively rather than by example: every level of the ladder is crossed with every text in both corpora, plus the one shape in which a lowering bug could actually appear - a high-floor rule matching an event already declared `immediate`.
Making the loop take the last matching rule instead of the maximum fails it (`promotion LOWERED a priority: declared immediate, effective rank 2`).

## The failure this is designed against

A promoter that **under**-promotes is invisible.
The event arrives at its declared priority, looks entirely normal, and whatever it understated is found later by a human.
There is no error, no failed check, and nothing to see.

So rules that read soundly prove nothing, and the load-bearing test is a replay: events this fleet actually recorded, put through the real wake library into the real journal, and required to promote.
The Bridge case runs through the real `bridge_inbox_surface` path, so what is asserted is the wake a supervisor would actually receive rather than a library return value.

Over-promotion is the cheaper failure and it is still a cost - it spends the captain's attention, which is the resource this undertaking exists to protect.
It is therefore measured and reported below rather than estimated.

## What the rules do to real traffic

Measured on 2026-08-14 with `bin/fm-urgency.sh replay --corpus`, against recorded history, not against invented examples.

**The Bridge acked corpus: 420 envelopes**, every envelope in `inbox/coditan/acked` on `origin/main`, replayed against each envelope's own declared `.priority` and subject.

| | |
|---|---|
| records | 420 |
| promoted | 46 (11.0%) |
| by rule | failure 17, credential 15, blocker 8, exposure 6 |
| by transition | normal→high 39, normal→immediate 5, low→high 1, high→immediate 1 |

Every under-declared case identified by hand in that corpus promotes, including the judge's verified one.
Five envelopes carrying delivered credentials, tokens, or SSH keys were declared `normal` while the same class from a different sender was declared `high` - that inconsistency inside the real corpus is the under-declaration this tier corrects.

**The recorded status history: 18 lines** from this home's own `state/*.status` files.
One promoted (5.6%), and eleven of the eighteen were already declared captain-relevant by their own verb.
That is a real finding and it is reported rather than smoothed: **the under-declaration in this fleet is concentrated in the Bridge surface, not in the status surface**, because crewmates declare their status verbs accurately.

### The over-promotions, named

Of the 46, the ones a reader would argue with are worth naming rather than leaving to be discovered:

- `Experiment result: composer state does NOT discriminate - and at the real 15s cadence the streaming exposure is essentially nil` promotes to `immediate` on the word "exposure", used there in a non-security sense. One event in 420.
- `ak: old-address exposure repaired end to end` promotes to `immediate` although it reports a repair.
- `Broadcasts to that seat are not a provisioning blocker` promotes on "blocker" inside a negation.

There is deliberately **no negation guard**.
"repaired", "no decision needed", and "verified working" would each suppress a promotion, and a suppressed promotion is indistinguishable from one that was never found.
The cost of leaving them in is the three lines above; the cost of a guard is invisible, and this unit does not buy an invisible cost with a visible one.

### The rules are bilingual on purpose

This fleet's notification stream is German and English in the same inbox - both languages appear across every declared priority in the 420-envelope corpus.
An English-only rule set would under-promote every German event, which is the invisible failure.
Removing the German alternatives from one rule fails the replay case (`replaying the journal promoted 4 of 5 recorded under-declared events`).

## What is proven, and how

`tests/fm-urgency.test.sh` drives the real Bridge surface path, the real wake library, and the real journal reader.
Seven load-bearing assertions were mutation-checked on 2026-08-14 rather than trusted for being green:

| Mutation | Caught by |
|---|---|
| Never promote | `the verified under-declared envelope was not delivered at the promoted priority` |
| Take the last matching rule instead of the maximum | `promotion LOWERED a priority: declared immediate, effective rank 2` |
| Drop the German alternatives from the blocker rule | `replaying the journal promoted 4 of 5 recorded under-declared events` |
| Record the rule but not the text that matched | `the record's evidence field is 'redacted'` |
| Let a promotion reach the Bridge poll cadence | `promoting an event changed the Bridge poll cadence to 30` |
| Abort delivery when the record cannot be written | `a home that could not record the promotion also failed to deliver it` |
| Widen a rule so it fires on ordinary progress | `1 of 5 recorded routine events were promoted` |

The evidence assertion originally read the whole record line and passed even with the matched text redacted, because the event field contained the same word.
It now reads the record's fields by position, which is what makes the mutation fail.

## Delivery outranks the record of it

A promoted event is delivered at its promoted priority whether or not the record of why reached disk.
The failure is reported on stderr rather than swallowed, because the alternative is holding an urgent event back over a bookkeeping problem.
This is the same order the journal keeps, for the same reason.

## The boundary this unit holds

**What an event's urgency IS** belongs here.
**How long an event of a given urgency waits** belongs to `fm-bosun-model-survey-priority-batching`, which was in flight alongside this one.

`bridge_check_interval` maps a priority to a poll cadence, which is a waiting question, so it deliberately still reads the **declared** priority.
The consequence is stated rather than hidden: an envelope promoted to `high` or `immediate` here is delivered at that priority in the wake payload, but the inbox it sits in is still polled on the ordinary cadence rather than the 30-second urgent one.
Closing that is a one-line change in the batching unit's own file, and it is that unit's call, not this one's - two workers quietly agreeing on a shared seam is how a contract gets two owners.
`test_promotion_does_not_reach_the_poll_cadence` asserts the boundary so it cannot be crossed by accident.

## Deferred, and listed on purpose

- **The second declaration surface.** A status line declares its urgency through its verb, and `bin/fm-classify-lib.sh` reads `working:`, `paused:`, and `resolved:` as never captain-relevant regardless of content - a deliberate, tested contract with explicit cases behind it (`tests/fm-watch-triage.test.sh`). Promoting on content there would surface a `working:` line whose text reports a blocker. It is **not changed here**: the measurement above found the under-declaration concentrated in the Bridge surface, and overriding a deliberate tested contract is the captain's decision rather than a side effect of this unit.
- **The bosun's verdicts as an input.** `docs/bosun-observer.md`'s observer records an `escalate` or `routine` judgement for every journal event, and an `escalate` on an event declared `low` is independent evidence of under-declaration. Wiring it in would make this tier depend on a model call and on the bosun's cursor keeping up, so the mechanical rules ship alone first and the two records can be compared before either is trusted against the other.
- **Accuracy against a captain-labelled set.** The 11.0% rate says what the rules do, not whether the captain agrees with each one. The three named over-promotions are this author's reading, not his. Until he labels a set, the rate is measured and the judgement behind it is not.
- **A real retention policy.** The same crude size bound the journal and the bosun record use - two files of `FM_URGENCY_MAX_BYTES` - so a long-running promoter cannot fill a supervision host. It does not reason about age or promotion rate.
- **Rule tuning against anything but this corpus.** The floors are calibrated against what this fleet already declares at each level. Another fleet's senders may use the ladder differently, and nothing here adapts.

## Related

- `docs/event-journal.md` - the recorded history this replays against, and what it does and does not guarantee.
- `docs/bosun-observer.md` - the observer tier that judges the same stream and has authority over nothing.
- `docs/supervision-cost.md` - what supervision actually costs, and why attention is the resource being protected.
