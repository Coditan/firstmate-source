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

## What is not built here

The container, the officer's own body, his locked behavioural history, and the access trace are a later change against the fleet repository.
This is the firstmate-side machinery only.

`*.outcome.json` is already reserved on the surface and excluded from every listing.
That is where a drained finding's outcome goes, written by whoever drained it and never by the officer.
The drain rule, the write-back, the unread coupling, and the refuted rate are not implemented yet.

## Verification

2026-08-04, `bash tests/fm-finding-surface.test.sh` on Linux 6.8.0, jq present.

Before `bin/fm-finding.sh` and `bin/fm-finding-lib.sh` existed, the suite's first assertion failed with exit 127 (command not found).
After, the suite passes.
`tests/fm-finding-surface.test.sh` is the colocated owner of that evidence and re-proves it on every run.
