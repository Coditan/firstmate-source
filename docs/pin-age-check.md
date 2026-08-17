# Pin age: the hop nobody measured

`bin/fm-fleet-update-check.sh` answers "is this vessel running current shared code?" across all three hops.
This document records the incident that earned it, the decisions taken and rejected while hardening it, and how it reaches the rest of the fleet.
The script's own header and `--help` own its flags, states, and exact mechanics; [currency-round.md](currency-round.md) owns the daily round it is wired into.

## The incident, 2026-08-17

The captain said "update yourself".
`bin/fm-update.sh` ran and reported `firstmate: already current`.

That was true, and useless.
`bin/fm-update.sh` answers whether this home is level with **its own origin**.
It says nothing about whether the pin that origin carries is current.

Measured at that same moment on this seat, the vendored pin was **72 commits and 15 merged pull requests** behind the pin source.
Four fixes had merged that evening - a receiver false-failure race, the reset gate counting our own notifications as the captain, the merge-watch invalidation, and a pruned instruction file - and none of them were running here while the update tool said current.

## The class: fidelity is checked, age is not

The fleet drift gate proves the vendored tree faithfully matches the pin, byte for byte ([admiralty-fleet-repo.md](admiralty-fleet-repo.md)).
It has no opinion on whether the pin is current, and it is not supposed to have one.
`bin/fm-update.sh` and `bin/fm-bootstrap.sh`'s `SELF_DRIFT` check both measure this checkout against its own origin.
The fleet dashboard's install view measures which pin each vessel sits on.

Nothing measured how old the pin itself was.
So a vessel days stale passed every check it had, and each check was individually correct.

## Three hops, and why they are never collapsed

The hop vocabulary is [currency-round.md](currency-round.md)'s: `released`, `pinned`, `installed`.
The check reports them bottom-up as hop 3, hop 2, hop 1, so the reading nearest the running code is read first and the hop that produced the incident is read last.

The one rule that matters more than the layout: **they are never collapsed into one word.**
`firstmate: already current` was one word for three questions, and that is exactly how the answer to one of them got read as the answer to all three.
Every report closes by saying so:

```
Note: 'level with your own origin' answers hop 3 ONLY. It says nothing about hops 1-2.
```

## Behind is not the same as unmeasurable

A pin the source no longer carries, a fetch that fails, an unreadable lock, and an unresolvable branch all report `UNMEASURABLE` and exit non-zero.
None of them report `CURRENT`.
This is the same rule the daily round already holds for its `unmeasured` state and the same rule `AGENTS.md` section 3 states for the currency round and the memory alarm: an instrument that cannot read must never be relayed as an all-clear.

A home with no `firstmate.lock` is a third thing again.
It is not pin-delivered, which is not a fault, so it reports `NOT PIN-DELIVERED` in the full report and `skipped` in the daily round rather than either a verdict or a failure.

## The four hardenings, and the failure each was earned by

**Counting, never sampling.**
Distances come from `git rev-list --count` and merged pull requests from a `grep -c` over the whole range.
Earlier the same night this seat reported "twelve commits, four pull requests" to the captain from a `head -12`, when the real figures were 72 and 15.
A truncated list is indistinguishable from a short one, so no `head -N` may ever produce a count.

The merged-pull-request figure counts merge commits whose subject begins `Merge pull request`.
A squash-merged pull request leaves no such commit, so that figure is a **floor** and the commit count is the authority.

**The pin source is addressed by URL, never by name.**
The prototype located a clone of the pin source by matching remotes on repository basename.
This fleet has already been bitten by a repository NAME being reclaimed and silently addressing a different repository, and a name-matched clone is that hazard exactly.
The clone search was therefore not repaired, it was **removed**: the measurement fetches straight from the `source_url` recorded in this home's own `firstmate.lock`, into a throwaway bare repository, the same shape `bin/fm-firstmate-update-check.sh` already uses.

That removal buys three things beyond the name hazard.
The check works on a vessel that has no clone of the pin source at all, which is most of them.
It never runs a state-changing command under `projects/`, which `AGENTS.md` section 1 forbids.
And it can never measure against a clone somebody last fetched a week ago.

The fetch uses `--filter=tree:0` so only commit objects travel, falling back to a plain fetch on a server that refuses the filter.
Measured against the pin source on 2026-08-17: 728K and 0.67s.

**A fetch that fails produces UNMEASURABLE.**
The prototype fetched with `2>/dev/null` and carried on to read `origin/main` regardless, so an offline run would have measured a stale remote-tracking ref and could have reported `CURRENT` from it.
Both hops now end the reading when their fetch fails and name the reason.

**A pin off the source's lineage is named, not counted.**
When the pin carries commits the source ref does not - a rewritten history, or a pin taken from a branch that never landed - a bare "behind N" would be a confident number for a question that has no such answer.
That case reports `OFF LINEAGE` with both figures.

## Where the reading actually happens

A check nobody runs is worth nothing, and the defect being repaired here is precisely one where the knowledge existed and the mechanism did not.
So `pin-age` is a subject in the daily currency round, at hop `pinned`, not only a skill a captain can invoke.

The round already owns the cadence, the noise control, the two-round rule for unmeasured readings, and a supervisor that survives session boundaries.
It consumes `bin/fm-fleet-update-check.sh --pin-age`, which performs one bounded source-fetch step and answers in one `<state>|<detail>` line, so it stays inside the round's per-step ceiling and can never become a second implementation that disagrees with the three-hop report a captain runs by hand.
That step normally makes one filtered fetch and retries once without the filter only when the server refuses the filter.

This changes one boundary [currency-round.md](currency-round.md) previously drew.
That document said the round does not measure the pin hop, on the reasoning that the pin is the fleet repository's own measurement.
That reasoning holds for pin **fidelity**, which is still the fleet repository's drift gate and is not duplicated here.
It never held for pin **age**, which no measurement owned at all.

The round's armed watcher shim `exec`s the round from its code root rather than freezing a copy, so this reading arrives on every vessel by self-update with no re-arming step.

## Reaching the fleet, and the bootstrap irony

**A vessel whose pin is stale does not HAVE this check until its pin moves.**
That is the same shape as the defect: the vessel most in need of the reading is the one that cannot take it.

So the first run on each seat is a run by hand, and the All-Ships broadcast must carry a way to get the script, not merely the name of a command the recipient does not yet have.
Each vessel measures itself; nobody runs this against another vessel's home, which is why the script has an `FM_HOME` and deliberately no flag for pointing at someone else's.

The broadcast below is composed and **not yet sent**: it is sent once this change has landed on the pin source's default branch, because before then the path it names does not resolve.
It is recorded here rather than in the skill so that the skill's own code blocks remain only commands that have been run.

```
bin/fm-bridge-relay.sh broadcast advisory \
  "Take your own three-hop currency reading" \
  --from <this vessel> --priority normal --response-expected \
  --file <body file>
```

Body:

> On 2026-08-17 a vessel's update tool reported "already current" while its vendored pin was 72 commits and 15 merged pull requests behind the pin source. The tool was right about the only hop it measures - level with its own origin - and that hop says nothing about the other two.
>
> `bin/fm-fleet-update-check.sh` now measures all three separately: whether this home is level with its own origin, what pin it carries, and how far that pin lags its own recorded source. It never collapses them into one word, and a reading it could not take reports as unmeasurable rather than as current.
>
> Please run it on your own seat and report your own three hops. Do not run it against another vessel's home; each seat measures itself.
>
> ```
> bin/fm-fleet-update-check.sh
> ```
>
> **If you do not have that file, that is the finding.** A vessel whose pin is stale will not carry this check until its pin moves, so the first run is one each seat does by hand. Fetch it from the pin source's default branch at `bin/fm-fleet-update-check.sh`, run it, and report the reading.
>
> It also runs by itself from now on, as the `pin-age` subject of the daily currency round, so nobody has to remember it again.

## What this deliberately does not do

- It never updates anything, and it never bumps a pin.
- It never measures another vessel.
- It does not check pin **fidelity**; the fleet repository's drift gate owns that, and duplicating it would create two answers that can disagree.
- It does not re-measure this checkout against its own origin beyond hop 3's own reading; `bin/fm-bootstrap.sh`'s `SELF_DRIFT` check and the round's `seat-can-update` reading own their own questions.
- It has no flag for measuring a home other than `FM_HOME`.
