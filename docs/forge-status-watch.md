# The forge status watch

`bin/fm-forge-status.sh` reads the forge's own status page on a settable cadence, appends every new reading to a durable log, and wakes firstmate only when there is a new one.
The script's header owns its flags, state files, and mechanics; this document owns the evidence, the design decision behind the shape, and the boundaries the wake carries.

## The measurement that commissioned it

On 2026-08-17, between 14:58 and 15:01 UTC, GitHub's own status page reported API requests degraded, webhooks degraded, Actions degraded, roughly 20% error rates on web and API traffic, and roughly 50% on archive and raw content downloads.
On this seat in that hour: two approved merges could not be completed for over ten minutes, and three live workers had to be warned by hand not to read their CI failures as their own defects.

That hand-warning is the work this watch exists to make unnecessary.
Nothing was watching the forge, so a supervisor learned about the outage by walking into it, and every worker who hit a red check in that window spent effort proving their own code innocent.

Later the same day, while this watch was being built, a live reading against the real status page returned a worse state - API requests, issues, pull requests and Actions all at major outage, Git operations degraded, one critical incident open and under investigation.
The reading was taken by the finished script, and it is what the entry log recorded:

```
entry: 2026-08-17T15:25:02Z
source: https://www.githubstatus.com/api/v2/summary.json
http: 200
reading: measured
indicator: major (Partial System Outage)
components: Git Operations=degraded_performance; Webhooks=partial_outage; API Requests=major_outage; Issues=major_outage; Pull Requests=major_outage; Actions=major_outage; Pages=degraded_performance; Copilot=major_outage
incidents: Incident with GitHub.com (investigating, critical impact) https://stspg.io/y1fl26l6wpzr
```

A second look at the same reading, moments later, printed nothing at all.

## The shape: it records and it wakes; it does not judge

The captain set this design in his own words: *"write the time code etc in a file.... only new entries wake you and you check if its relevant and polling should be hightened"*.

1. A due sweep reads the status page once and renders the reading.
2. The rendered reading is compared to the last entry in `state/forge-status.log`.
3. An unchanged reading appends nothing and wakes nobody.
   The silence comes from there being no new entry, not from a severity test inside the checker.
4. A new reading is appended - append-only, one block per recorded observation, never rewritten - and printed as one wake line.
5. Firstmate reads the entry, decides whether it matters to this fleet, and decides whether to raise or lower the cadence.

Step 5 is deliberately not the checker's.
No field on that status page encodes what a component costs *us*.
Actions degraded is severe here because every pipeline runs through it; a Pages incident may be irrelevant to every vessel in the fleet.
A checker that classified severity would be guessing at that difference on a schedule, while firstmate knows it.

Informing the fleet is likewise firstmate's act, and it takes two hops for the same reason every fleet notice does.
The check raises an ordinary wake; firstmate dispatches a crewmate to send the All-Ships notice, per `AGENTS.md` section 12.
Nothing in the script writes to Bridge: the boundary rules there are content-sensitive and refused three of firstmate's own envelopes on the day of the outage, an unattended publisher is unauditable, and `AGENTS.md` section 1 forbids a timer standing in for firstmate.
The wake is durable, so an absent firstmate does not lose a new reading.

## What the wake tells a vessel

Not "the forge is down".
The useful content is what a vessel should *not* conclude: that a red check, a hung gate, a failed push or an unopenable pull request in this window may be the forge and not our code, and that a CI failure should be reproduced locally before it is believed.
That is exactly the warning that had to be sent by hand.
The wake line carries it, along with the reading itself, the cadence in force, both cadence commands, and the path to the full entry.

## Cannot reach is not all clear

A watch that goes quiet when the network fails is worse than no watch, because silence reads as good news exactly when it is not.
A reading that cannot be taken - no `curl`, no `jq`, no answer, a non-2xx answer, a body larger than `FM_FORGE_STATUS_MAX_BYTES`, or an empty or unparseable body - is recorded as an `unmeasurable` entry naming the concrete condition, and its wake says `UNMEASURABLE` and states in plain words that it is not a clear reading.

There is one narrow status-code exception for an address whose scheme is neither HTTP nor HTTPS, such as a local `file://` status document configured through `FM_FORGE_STATUS_URL`.
Because such a transport cannot carry an HTTP status, curl may report `000` after a successful fetch, and the document may be read.
For `http://` and `https://` addresses, matched case-insensitively, `000` remains a non-2xx answer and is recorded as unmeasurable.

Unmeasurable readings are fingerprinted like any other, so a network that stays down appends once rather than every sweep, while the last entry in the log keeps saying unmeasurable for as long as that is true.
A *different* failure mode - a timeout becoming a 503, a 503 becoming an unreadable body - is a different reading and is recorded as one.

## The cadence, and why the relaxed one is off the grid

| Cadence | Period | Why |
| --- | --- | --- |
| `raised` | every 300s | For while something is being watched. The captain set this rate for an open incident. |
| `relaxed` | every 7200s plus 180-420s of fresh jitter, target minute never a multiple of five | The default. |

The off-grid refusal is the one `bin/fm-curation-nudge.sh` already carries, and it exists for the same reason: cron defaults, systemd timers, monitoring pollers and this fleet's own watcher sweep all cluster on five-minute boundaries, so a fleet-wide relaxed fire landing there stacks on everything the machines already do.
It governs the relaxed cadence only.
A 300s period is on the grid by definition, and skipping observations to dodge it during an incident would trade the thing being watched for the tidiness of the schedule.

The cadence is settable and its current setting is readable, because firstmate owns the decision to tighten or relax:

```
bin/fm-forge-status.sh --cadence raised     # every 300s, from now
bin/fm-forge-status.sh --cadence relaxed    # every 2 hours plus jitter, off the grid
bin/fm-forge-status.sh --cadence            # which cadence is in force, and when the next observation is
bin/fm-forge-status.sh --status             # the whole record
bin/fm-forge-status.sh --log 3              # the last three readings
```

The script never changes its own cadence.
A watch that tightened itself would be classifying severity by another route.

Cadence changes and the complete observation read, append, and schedule transaction share one home-scoped lock.
A detect or force observation exits quietly when another writer holds it, so overlapping sweeps neither wait on the fetch timeout nor append the same reading twice.
Read-only modes do not acquire the lock or create state.
The fetch streams through a portable byte-limited sink, keeps curl's `--max-filesize` as an early refusal, and verifies the effective `FM_FORGE_STATUS_MAX_BYTES` cap again before parsing.
The default is 1000000 bytes, malformed or integer-risking settings fall back to that default, and valid settings are clamped to a hard ceiling of 5000000 bytes.
The effective cap is recorded in `forge-status.report` as `status-max-response-bytes`.
The fetch timeout defaults to 10 seconds, malformed or integer-risking settings fall back to that default, and valid settings are clamped to 15 seconds so the fetch stays inside the watcher's 30-second per-check budget.
The effective timeout is recorded as `status-fetch-timeout-seconds`, and the stale-lock recovery bound is at least that timeout plus 60 seconds.
The bounded sink, clamped body size, clamped fetch timeout, and derived stale floor keep the complete fetch, parse, hash, append, and publication transaction shorter than the recovery window.

The cadence is the target, not the observation instant.
The watcher sees a due target on its next `state/*.check.sh` sweep, so an observation lands at the target plus however far that sweep has to travel, and that sweep's period belongs to `bin/fm-watch.sh`.
At the default sweep period, a raised watch observes every 300 to 600 seconds rather than exactly every 300.
This script owns its target, states it in its own record, and claims nothing about the sweep.

## The seam, not a second timer

This is not a new scheduler.
`--arm` writes `state/forge-status.check.sh`, the locked bootstrap step arms it, and the watcher runs it on its ordinary `state/*.check.sh` sweep while the script self-gates to its own schedule from the persisted record - the same mechanism `bin/fm-curation-nudge.sh` established.
All but one sweep in a period only checks the persisted schedule, and no sweep that is not due reaches the network at all.

Two near-identical units on one host is a measured trap here: `bridge-notify-poll.timer` on this machine reported loaded, enabled and active on 2026-08-17 while it had last fired on 2026-08-07.
Sharing the seam means there is one thing to keep alive, and one health reading that can tell whether it is.

## The health reading

`--armed` never asks this check whether it is fine.
It reads what the work produced: whether a next target exists at all, and whether anything has executed the one there is.
It reports `FORGE_STATUS:` when the watch is not armed, when an armed shim has never scheduled an observation, when the schedule stands and nothing is executing it, and when the record cannot be read or its state cannot be persisted.
Before concluding that supervision stopped, it writes and atomically renames representative content between scratch paths in the state directory, because a failed publication is the one failure that cannot record itself.

Its patience follows the cadence in force: a relaxed watch may sit `FM_FORGE_STATUS_OVERDUE` seconds past its target (default 7200), a raised one only `FM_FORGE_STATUS_OVERDUE_RAISED` (default 1800).
A raised watch that stopped is a worse fact than a relaxed one that stopped, and is reported sooner.

## Durability of the log against a failed publish

The last entry in the append-only log, not the schedule record, is the authority on what was last recorded.
Deduplicating against the log means a record publish that fails after an append cannot cause the same reading to be appended twice on the next sweep, and cannot cause a reading to be silently dropped either.
`tests/fm-forge-status.test.sh` asserts both halves by failing the rename of the record and then letting the next observation run.

## What the suite proves

`tests/fm-forge-status.test.sh` drives the script against a fake status endpoint, so no case reaches the real network:

- a new reading is recorded and wakes once, and a held reading - including one whose page timestamp has been restamped - stays silent;
- an incident that moves on, and a return to clear, are each new readings;
- an unreachable page, a non-2xx answer, and an unreadable body are each `unmeasurable`, never clear, and a standing failure appends once;
- the cadence can be raised and lowered, the setting in force is readable, and a sweep that is not due takes no reading at all;
- 2000 drawn relaxed targets, none on a multiple-of-five minute, and a window with no off-grid minute refuses rather than scheduling on it;
- a component name carrying newlines and forged record fields is flattened into its own line, so a remote document can neither split an entry nor forge the field deduplication reads;
- a failed record publish neither loses the reading nor duplicates it;
- every mode avoids Bridge, the forge API and git, and the only address reached is the status document itself;
- stopping the watch makes its health reading go bad rather than stay quiet, and a raised watch is called stopped sooner than a relaxed one.
