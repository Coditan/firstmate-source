# The findings surface

The political officer's output.
He appends findings here and has no other way out: he has no outbound network path at all, so a finding leaves his container by landing in one directory on the host.
Everything else in the fleet reads that directory.

This document owns what a finding MEANS, field by field.
`bin/fm-finding-lib.sh` owns what a finding is CHECKED against and why each rule is shaped the way it is.
`bin/fm-finding.sh --help` owns the exact commands and exit codes.

The design this implements is the captain's, recorded in the firstmate home at `data/decisions/2026-08-04-politoffizier-vollstaendige-bauform.md`, sections 4, 6 and 7.

## The record

One JSON file per finding, named `<id>.json`, written once and never rewritten.

| Field | Meaning |
|---|---|
| `schema` | `fm-finding/1`. A record that does not name its own format is not read as one. |
| `id` | The record's identity and its filename stem: `<observed, compact>-<8 hex of the content digest>`. |
| `class` | `evidence`, `judgement`, or `pattern` - the three kinds of claim the officer makes. |
| `claim` | The pattern or the accusation, in one plain statement. |
| `where` | Where it was found, concretely enough that someone else can go and look. |
| `measurement` | The reading behind the claim: the count, the log range, the diff, the timestamps. |
| `observed` | When the reading was taken, ISO-8601 UTC. |
| `refuted_by` | The reading that would overturn this finding. |
| `officer` | Which officer claimed it. The accuracy score is his, so it has to be attributable. |
| `severity` | `low`, `medium`, or `high`: the consequence, never a priority. |

`class` distinguishes what settles a dispute, not what the format demands.
An `evidence` finding has a line someone else can look at, a `judgement` is a statement about intent, and a `pattern` is a shape nobody inside the system can see.
All three carry every field above, `refuted_by` included.

The officer never writes a fix, a priority, or an address.
There is no field for any of them, so a finding cannot become an instruction by someone filling one in.

## Where the surface is

In precedence order: `FM_FINDINGS_DIR`, then the path named in `FM_HOME/config/findings-dir`, then `FM_HOME/data/findings`.

The pointer exists because the officer is one container per MACHINE while a home is one vessel.
A machine carrying several vessels points every home at the one directory the officer appends to.
The home-local default is correct for a machine carrying one vessel and is the only default that cannot silently point two homes at each other.

Nothing creates the surface implicitly.
`fm-finding.sh init` creates it and says so; every other command refuses an absent surface.
A command that made its own surface on demand would turn a mistyped location into a fresh empty surface nobody collects from, and report success while doing it.

## Empty is not the same reading as unreachable

Four instruments in this fleet were caught on 2026-08-04 answering a question adjacent to the one asked, each by degrading into a reading indistinguishable from an ordinary calm one - the watcher's ladder-hold branch that fired 0 times in 2027 log entries, a currency check measuring a copy no shell resolves, a forge field populated by a test merge, and fleet position records weeks stale.
A findings surface that reports "no findings" when it cannot be reached is the fifth of those.

So the surface separates the two readings on purpose:

- `fm-finding.sh check` on a reachable surface prints `findings=<n>` and `malformed=<n>`, both numbers, because both were counted.
- On an unreachable surface it prints `findings=` and `malformed=` with no value at all, names the concrete defect on stderr, and exits 3.
  A count is a measurement, and an unreachable surface was never measured, so it gets no number a caller could misread as zero.
- A file on the surface that is not a finding is counted as `malformed`, named on stderr, and exits 4.
  It is never skipped, because a reader that drops what it cannot parse turns a corrupted surface into a calm one.
- A record whose reader crashes on it counts as malformed, not as valid.
  A validator that reads its own failure as "no violations found" calls every file a finding.

## The drain rule: earliest deadline first

A builder takes findings with `bin/fm-finding-drain.sh`, which the officer cannot run.
He states what is true; the rule decides what gets worked.

Every finding has a deadline: the moment it was observed plus the waiting time its severity allows.

| Severity | Waiting time | A finding of this consequence is late after |
|---|---|---|
| `high` | 24 hours | one day undrained |
| `medium` | 72 hours | three days undrained |
| `low` | 168 hours | one week undrained |

The rule takes the finding whose deadline is nearest, past or future.
One key, one total order, ties to the older observation.

**Why this and not severity-first.**
Severity-first starves a low finding behind an endless supply of high ones, and a claim nobody ever reaches is the exact shape of the 2027 unread log lines the officer exists to notice.
Under this rule a newly arrived high finding queues *behind* a low one that has already waited out its week, because a new arrival's deadline is always later than a deadline that has already passed.
Nothing can be permanently outranked.

**Why this and not oldest-first.**
Oldest-first parks a high-consequence finding behind a queue of trivia.
Between two findings observed at the same instant, this rule still takes the high one first.

**Why severity may enter the rule at all.**
The officer may not express a priority - a priority is an instruction, and he has no authority to give one.
Severity is a statement about consequence, and the rule converts it into a waiting time, never into a rank.
That is the whole of the officer's influence on the order, and it decays: after both deadlines pass, the older breach wins regardless of severity.

## The coupling: ignoring a finding is a visible act

A finding is overdue exactly when its deadline has passed.
`fm-finding-drain.sh queue --overdue` lists the findings that are past their deadline and still undrained - the ones being ignored.

The coupling is the drain rule's own sort key read with its sign, not a second mechanism beside it.
There is no separate unread-tracker that could keep reporting a healthy queue after the ordering broke, because the number that orders the queue is the number that defines overdue.

## The write-back

When a finding is drained, its outcome is written back **by whoever drained it, never by the officer**.

This exists because of a measured failure.
On 2026-08-03 another vessel ran three backlog audits that judged 30 entries dead, and not one finding was written back.
Its morning report therefore showed its captain 16 open decisions of which 11 were no longer alive, and one of the three reports had no backlog entry at all - invisible to every listing, and nearly commissioned a second time.
A findings surface nobody writes back to rebuilds that failure from scratch.

The outcome lives in a sibling `<id>.outcome.json`, excluded from every finding listing.

| Field | Meaning |
|---|---|
| `schema` | `fm-finding-outcome/1`. |
| `finding` | The id of the finding this answers. |
| `drained_by` | The seat that took it. Only that seat may write the outcome back. |
| `drained` | When it was taken. |
| `state` | `taken` while the work is under way, `closed` once the outcome is written. |
| `outcome` | `upheld`, `refuted`, or `unresolved`. Only on a `closed` record. |
| `closed` | When the outcome was written back. |
| `evidence` | The reading behind the outcome. Only on a `closed` record. |

`unresolved` is a written-back result - someone looked and could not settle it - and is not the same thing as never having looked.
The evidence field is required of all three: without it, "we could not settle this" is indistinguishable from "we did not look", and an outcome with no reading behind it is an opinion about the officer rather than an answer to his finding.

Two rules are held by which file each seat may create rather than by anyone remembering them.
The finding file is written once and never rewritten, so the answer cannot corrupt the claim.
The outcome file is created only by `fm-finding-drain.sh take`, which the emit surface has no option to produce, so the officer answering his own finding is not a discipline - it is a command that does not exist.

Creating the claim is atomic, so two builders reaching for the same finding cannot both get it, and neither needs a lock on a surface a container appends to without one.
A written-back outcome is the record, not a draft: an identical retry is allowed, a different outcome is refused.

## What is not built here

The container, the officer's own body, his locked behavioural history, and the access trace are a later change against the fleet repository.
This is the firstmate-side machinery only.

The refuted rate - the officer's accuracy as a public number computed from written-back outcomes - is not implemented yet.
The outcomes it needs now exist and are attributable to an officer by the finding's `officer` field.
Surfacing overdue findings into the captain's own daily view is likewise still open; today the coupling is visible only to whoever runs the queue.

## Empty is not the same reading as unreachable, on the drain side too

The drain answers the same distinction the surface does, because the calm reading it can degrade into is the more dangerous one: a builder that reads "nothing to work on" goes back to sleep.

- `fm-finding-drain.sh next` on a reachable surface prints `open=<n>` and `next=<id or empty>`, both after counting.
- On an unreachable surface it prints no queue reading at all, names the concrete defect on stderr, and exits 3.
  There is no path by which "I could not reach the surface" produces `open=0`.
- A finding whose `observed` is not a real timestamp has no deadline and therefore no place in the order.
  It is carried through the listing as undatable, named, and the ordering exits 4.
  It is never dropped: a record the rule cannot handle is exactly the one that must not become the one nobody sees.
- A finding whose outcome file cannot be read is reported in state `unknown` and is never handed out again.
  Reading it as open would give a second builder work the first may be doing; dropping it would hide a real claim behind a broken answer.
- A pinned clock that cannot be parsed refuses rather than falling back to the wall clock, because a queue ordered against a different instant than the caller asked for reports success while answering a different question.

## Verification

2026-08-04, `bash tests/fm-finding-surface.test.sh` and `bash tests/fm-finding-drain.test.sh` on Linux 6.8.0, jq 1.7.

Before `bin/fm-finding.sh` and `bin/fm-finding-lib.sh` existed, the surface suite's first assertion failed with exit 127 (command not found).
Before `bin/fm-finding-drain.sh` existed, the drain suite's first assertion failed the same way.
After, both suites pass.

Exit 127 is a weak fail-before for a brand-new file, so the drain suite's load-bearing assertions were additionally mutation-tested against the finished tree, and each mutation was caught:

| Mutation | The assertion that caught it |
|---|---|
| ordering changed to severity-first | a fresh high finding must not jump a low one that has waited |
| the `drained_by` check removed from the write-back | a seat that did not drain a finding may not answer it |
| `resolve` no longer requiring a prior `take` | an outcome for work nobody claimed must be refused |
| the unreachable-surface refusal removed from the queue read | an unreachable surface must not exit 0 |
| an unplaceable record dropped from the listing instead of flagged | a queue holding a record it cannot place must not read as complete |
| a written-back outcome made overwritable | a retry must not write a second outcome |

`tests/fm-finding-surface.test.sh` and `tests/fm-finding-drain.test.sh` are the colocated owners of that evidence and re-prove the behaviour on every run.
