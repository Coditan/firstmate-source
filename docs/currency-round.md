# The daily currency round

`bin/fm-currency-round.sh` is the trigger behind firstmate's standing duty to check for updates daily.
This document records the evidence that produced it, the vocabulary it reports in, the alternatives that were rejected, and what it deliberately does not do.
The script's own header owns its flags, state files, and exact mechanics.

## The gap this closes

The captain made firstmate the fleet's update authority on 2026-07-29, checking daily at minimum.
The duty had no mechanism.
Session start is not daily: a session on this vessel has run for two days, so a duty carried at session start is a duty carried by memory, which is the exact defect shape this fleet spent that week removing.

It was worse than unscheduled.
`bin/fm-firstmate-update-check.sh` was written with a header that instructed each home to schedule it externally with cron or a systemd timer.
Measured on this vessel on 2026-08-12: `crontab -l` reported no crontab, `systemctl --user list-timers --all` listed only `launchpadlib-cache-clean.timer` and a stopped `bridge-notify-poll.timer`, and `state/` contained neither `firstmate-update.available` nor `firstmate-update.stuck`.
The check had therefore never produced a reading on this home.
`bin/fm-bootstrap.sh` prints those markers when they exist, so their absence printed nothing, and nothing is exactly what a current deployment prints.
A check nobody scheduled was indistinguishable from a check that passed.

## What three vessels said on 2026-08-12

Three vessels answered a fleet-wide question about their own currency, and all three said the same thing about what triggers an update: a human sentence, and nothing else.
AK reported updates as human-triggered `bin/fm-update.sh` with nothing scheduled.
SC1 stated outright that no timer stood behind it.
Tugboat put it as "the trigger is a human sentence, nothing else", and reported itself current from a manual update thirty minutes earlier while being two releases behind.

Two further readings from the same day set the design.
AK updated and landed on `bc4ead8`; SC1 updated and landed on `7c26705`; both were current when they ran.
SC1 named the trap itself: those two are not disagreeing, they are two different moments, and any table comparing versions without timestamps manufactures false disagreements.

## Hops: which claim of currency a report is making

A change reaching a running vessel is three separate acts, and a report that does not say which one it means is worse than no report.

| Hop | The act |
| --- | --- |
| `released` | The change is on the default branch of the source this deployment updates from. |
| `pinned` | The fleet pin names a commit that contains it. |
| `installed` | This seat's own checkout has advanced to that pin. |

The round measures all three hops **for this seat only**, and it never speaks for another vessel.
That boundary is what keeps the round from becoming a second measurement that can disagree with the first.
Per-vessel install status is the fleet dashboard's install view (`fleet-install-status.v1`, landed the same day in `Coditan/fleet-mobile-command` PR 31, which carries installed version, pin commit, how and when each vessel last updated, and behind-ness against the live reference).
Every report the round writes states this in the file itself, so a clean round can never be read as "the fleet is current".

On the pin hop the round measures pin **age** and not pin **fidelity**.
Fidelity - whether the vendored tree still matches the commit the pin names - is the fleet repository's own drift gate, and duplicating it here would produce exactly the second answer this boundary exists to prevent.
Age had no owner at all until 2026-08-17, when a vessel's update tool reported "already current" while its pin was 72 commits and 15 merged pull requests behind the pin source.
[pin-age-check.md](pin-age-check.md) owns that incident and the `bin/fm-fleet-update-check.sh` reading that closed it; this round's `pin-age` subject is its daily cadence, and the round's own header owns what that reading records.

## The four properties, and the failure each was earned by

**Merged is not delivered.**
Landing in the pin source, bumping the fleet pin, and each seat fast-forwarding are three separate acts.
Every reading therefore carries its hop, and the report names what it cannot claim on each of them.
The 2026-08-17 incident is the same property one level down: `bin/fm-update.sh` answered the `installed` hop with one word, that word was read as an answer about all three, and the pin turned out to be 72 commits old.

**Telling is not a mechanism.**
Tugboat's wake delivery had been switched off since 2026-08-11 by its own captain, so a fleet-wide message reached its queue and nothing surfaced it.
A broadcast cannot reach a seat that has stopped listening, and that seat is the one most likely to be behind.
So the round is armed by `bin/fm-bootstrap.sh` rather than by an install instruction, and `--armed` reports a home that is unarmed, or armed and never completing a round, or completing rounds and then stopping.
That reading is the one that catches a seat which stopped listening, and it costs one file read.

**A silent refusal is the failure mode.**
The `fleet-dirty-checkout-freezes-update` backlog item records that a single stray untracked file makes the fast-forward skip, silently, while the vessel keeps reporting normally.
The `seat-can-update` reading asks whether this checkout could take a fast-forward at all, using `bin/fm-ff-lib.sh`'s own predicates so the answer cannot drift from what the fast-forward will actually do.
It reads only.
Whether a skipped fast-forward should stay silent, and whether untracked files should be distinguished from modified ones, are decisions that belong to that separate item; this round changes neither and only makes the current behavior visible.

A secondmate home is judged by its own rules rather than the primary's.
It is a linked worktree leased at a detached HEAD and synced from the primary's local commit with no origin involved, which is exactly what `ff_target` is called with `allow_detached` and `ignore_seed_marker` for.
Applying the primary's rules there would report every secondmate home as permanently unable to update, which is how a check earns being ignored.

**A confirmation must come back.**
The only reason AK and SC1 were known to have moved is that they were asked to report the version they ended on, and did.
So the round records every reading it took in `state/currency-round.report`, `unmeasured` is a first-class state, and a reading that could not be taken never reports an all-clear.

## Why the watcher, and not the three alternatives

| Option | Verdict |
| --- | --- |
| **Session start**, as the weekly Grossreinschiff cadence uses | Rejected. That check is one file read and one integer comparison, which is what earns it a place in the session-start path. This one makes network calls, and more importantly session start is not daily: a two-day session checks once. `docs/grossreinschiff.md` "The cadence decision" records the mirror-image argument for the sweep that genuinely needs no timer. |
| **An external cron or systemd timer**, as `bin/fm-firstmate-update-check.sh` formerly asked for | Rejected, with evidence. That is the arrangement measured above, and on this vessel nobody ever installed it. A per-home install step that nothing verifies means a home that never installed it silently never checks - the same no-op-instruction defect, one level up. |
| **A fleet-wide broadcast when something lands** | Rejected. Tugboat proves a broadcast cannot reach a seat that stopped listening, and a seat that stopped listening is the one that most needs reaching. |

The watcher already sweeps `state/*.check.sh` every `FM_CHECK_INTERVAL` seconds, survives session boundaries, and is kept alive by its own service.
Following that shape means the round inherits a supervisor the fleet already trusts instead of introducing a second one.

## Cost, and why the model is woken so rarely

On this fleet a surfaced notification costs a median of roughly 171,000 fresh tokens because it re-sends the accumulated conversation, while the mechanical poll that decides whether to raise one costs about 207 (`docs/supervision-cost.md`).
A check that runs every five minutes in bash is effectively free; the same check that wakes a supervisor every five minutes is ruinous.

So the decision is made in bash, three times over.
The round itself runs at most once per cadence window, so the other sweeps of the day are one file read and one integer comparison.
Measured on this vessel on 2026-08-12, with every reading reaching the network: a full round took 3.8s against the watcher's 30s per-check ceiling, and the cadence-gated path took about 19ms per sweep.
A finding surfaces only when its line differs from the one last surfaced, so an unchanged state is reported once rather than daily - the same discipline `AGENTS.md` section 8 states as "never restate an unchanged state".
An `unmeasured` reading must repeat in two consecutive rounds before it surfaces, so one network blip is not a finding while sustained blindness is.

## What this deliberately does not do

- It never updates anything.
  It measures, records, and reports.
  Whether a finding is taken immediately or batched remains firstmate's judgement against the criteria recorded in `data/captain.md`.
- It never acts on, or measures, another vessel.
  Every seat measures itself.
  That avoids both the consent question and a second fleet-wide measurement that could disagree with the dashboard's.
- It does not measure pin fidelity, only pin age.
  The fleet repository's drift gate owns whether the vendored tree still matches the commit the pin names.
- It does not re-measure the commit-graph distance between this checkout and its own origin.
  `bin/fm-bootstrap.sh`'s `SELF_DRIFT` check owns that.
  The `seat-can-update` reading answers a different question - whether an arriving update could be taken at all - and reports the consequence for delivery rather than restating `TANGLE`'s remediation.
- It does not change `bin/fm-ff-lib.sh`'s refusal policy.
- It inherits one bound from the watcher rather than inventing one: the round runs on the watcher's check sweep, so its cadence is "at most once per window", not "exactly at".
  A check that speaks no longer ends that sweep, so no other watch can delay this one by sorting ahead of it; a round genuinely starved past the staleness limit still reports itself through `--armed` instead of going quiet.
- It does not address the ad-hoc PATH finding from the same backlog item.
  `bin/fm-axi-path-lib.sh`'s `fm_axi_shadowed` and bootstrap's `AXI_SUITE_SHADOWED:` line already report when a maintained AXI copy is not the one a plain shell runs, and that library is sourceable from a login profile.

## The unmanaged tools

`gh`, `treehouse`, `uv`, and `shellcheck` are checked at best and updated by nothing; the npm AXI suite has `bin/fm-axi-suite.sh` and these have no equivalent.
Each declares its own reference, because they are not all asking the same question.
`gh`, `treehouse`, and `uv` compare against their latest upstream release.
`shellcheck` compares against the version `bin/fm-lint.sh --required-version` prints, because `fm-lint.sh` refuses to run under any other version: a drift from that pin breaks the validation gate, while a newer upstream release is a pin-bump decision this repo has already made and not a currency defect.
Chasing latest for `shellcheck` would spend a wake arguing with the repo's own pin.

A tool this home has not installed is not a finding, so a home that does not use `uv` is never told about it and no configuration is needed to say so.

Measured on this vessel on 2026-08-12, immediately after the table was written:

```
gh          2.96.0   against latest release 2.97.0  (cli/cli)
treehouse   2.1.0    against latest release 2.1.1   (kunchenguid/treehouse)
uv          0.11.29  against latest release 0.12.3  (astral-sh/uv)
shellcheck  0.11.0   against the 0.11.0 this repo requires
```

Three of the four unmanaged tools were behind at the moment the check that would have said so was first written.
