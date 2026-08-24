---
name: run-fleet-update
description: >-
  Take this vessel's own three-hop currency reading: whether this home is level with its own origin, what pin it carries, and how far that pin lags the source it names.
  Use when the captain invokes /run-fleet-update, asks whether this vessel is running current shared code, says "update yourself" or "are we current", when the daily round reports a pin-age finding, and before ever telling the captain that this vessel is current.
  It reports all three hops separately and never collapses them into one word, because "already current" was one word for three questions and that is how a vessel 72 commits behind passed its own currency check.
  A reading it could not take is reported as unmeasurable, never as an all-clear.
  It measures and never updates: taking the update is a separate, captain-authorised step.
user-invocable: true
metadata:
  internal: true
---

# /run-fleet-update

## What this answers, and what it refuses to answer

A change reaching a running vessel is three separate acts.
This reading reports each one separately and never merges them:

| Hop | The question |
| --- | --- |
| hop 3 `installed` | Is this home level with its own origin? |
| hop 2 `pinned` | What commit does this home's `firstmate.lock` pin? |
| hop 1 `released` | How far does that pin lag the head of the ref it names, on the source it names? |

On 2026-08-17 `bin/fm-update.sh` answered hop 3 with `firstmate: already current` and that answer was read as all three.
The pin was 72 commits and 15 merged pull requests behind at that moment.
[docs/pin-age-check.md](../../../docs/pin-age-check.md) holds the incident and the design decisions; this skill is the procedure.

**Never report this vessel current on the strength of one hop.**

## Take the reading

It measures `FM_HOME`, defaulting to its own code root.
Each seat measures itself; there is deliberately no flag for pointing this at another vessel's home.

```
bin/fm-fleet-update-check.sh
```

Real output from this seat, 2026-08-17, with `FM_HOME` set to the home named on its first line:

```
fleet-update-check  home=/home/coditan/coditan-firstmate

hop 3  installed  own origin      LEVEL          branch=main
hop 2  pinned     vendored pin    6ef0e3e9e72f707c561bc15790c446e51dafcc1a
                  pin source      https://github.com/Coditan/firstmate-source.git ref=main
hop 1  released   pin age         BEHIND 72 commit(s), 15 merged PR(s)   source head=49a7688

VERDICT: NOT current, or not measurable, on at least one hop above.
Note: 'level with your own origin' answers hop 3 ONLY. It says nothing about hops 1-2.
Note: UNMEASURABLE is not an all-clear. A reading that could not be taken is reported as unmeasurable and never as current.
```

Exit status is 0 when every applicable, measurable hop is current; a home with no `firstmate.lock` is not pin-delivered, so that skipped pin path is not a failure.
The full run has one bounded fetch step for each source it must measure; a server that refuses the filtered pin-source fetch can cause that step to retry once without the filter.
The successful filtered pin-source fetch was measured at 728K and under a second.

To measure a home other than this code root, set `FM_HOME`:

```
FM_HOME=/home/coditan/coditan-firstmate bin/fm-fleet-update-check.sh --pin-age
```

```
behind|the pin 6ef0e3e is 72 commit(s) and 15 merged PR(s) behind main on https://github.com/Coditan/firstmate-source.git (source head 49a7688)
```

`--pin-age` is the single-line seam the daily round consumes.
It always exits 0, so it is for the round, not for a captain's reading; use the full report above for that.

## Reading each line

| Hop 1 state | What it means |
| --- | --- |
| `CURRENT` | The pin names the head of the ref it points at. This hop is clean. |
| `BEHIND n commit(s), m merged PR(s)` | Counted, not sampled. `m` counts merge commits and is a **floor**, because a squash-merged pull request leaves none; `n` is the authority. |
| `OFF LINEAGE` | The pin carries commits the source ref does not. History was rewritten, or the pin was taken from a branch that never landed. Escalate rather than bumping. |
| `UNMEASURABLE` | The reading could not be taken. **This is not an all-clear.** The line names the concrete reason. |
| `NOT PIN-DELIVERED` | This home carries no `firstmate.lock`. Nothing pins its shared code, which is a fact about the home, not a fault. |

Hop 3 reads `LEVEL`, `BEHIND n AHEAD m`, `NOT APPLICABLE` (a secondmate home takes its updates from its primary and has no origin), or `UNMEASURABLE`.

## What to do with the verdict

- **Every hop current.**
  Say so, and say which hops that covers.
  It still does not mean the fleet is current: this is one seat.
- **Hop 1 behind.**
  The pin needs a bump, which is the fleet repository's own reviewed step and never something to force from here.
  Report the measured distance to the captain and let the bump be its own authorised piece of work.
- **Hop 3 behind.**
  This home has an update waiting on it, and `/updatefirstmate` owns the guarded fast-forward.
- **Anything `UNMEASURABLE`.**
  Report it as unable to read, never as current, and name what could not be read.
  An unreachable pin source, an unreadable lock, and a pin the source no longer carries are three different repairs.
- **`OFF LINEAGE`.**
  Stop and escalate.
  Do not bump a pin whose lineage the source no longer contains.

## It also runs by itself

`pin-age` is a subject of the daily currency round at hop `pinned`, so this reading arrives without anyone remembering it.
A finding surfaces through the round's own noise control - once when it appears, again only when it changes.

```
FM_HOME=/home/coditan/coditan-firstmate bin/fm-currency-round.sh --status
```

Real output from this seat, 2026-08-17 (the `seat-can-update` line reads the checkout the command was run from, which was a task branch at the time, not the vessel's own default branch):

```
round: 2026-08-17T01:30:57Z
reading: instruction-surface hop=released state=ok detail=no instruction-surface change on the configured update source
reading: pin-age hop=pinned state=behind detail=the pin 6ef0e3e is 72 commit(s) and 15 merged PR(s) behind main on https://github.com/Coditan/firstmate-source.git (source head 49a7688)
reading: seat-can-update hop=installed state=blocked detail=this checkout is on fm/fm-run-fleet-update-skill, not main; an arriving update would be skipped
reading: tool:gh hop=installed state=ok detail=2.97.0 against 2.97.0
reading: tool:treehouse hop=installed state=behind detail=2.1.0 against the latest release 2.1.1 of kunchenguid/treehouse
reading: tool:uv hop=installed state=behind detail=0.11.29 against the latest release 0.12.5 of astral-sh/uv
reading: tool:shellcheck hop=installed state=ok detail=0.11.0 against 0.11.0
note: this round measures the released, pinned, and installed hops FOR THIS SEAT ONLY.
note: on the pin hop it measures pin AGE only, against this seat's own recorded source; pin FIDELITY is the fleet repository's drift gate and per-vessel install status is the fleet dashboard's install view, so a clean round here never means the fleet is current.
```

`--status` writes no cadence stamp and applies no de-duplication, so it is the safe way to see every reading on demand.

## Putting it in the fleet's hands

A vessel whose pin is stale will not carry this check until its pin moves, so the first run on each seat is one that seat does by hand.
An All-Ships broadcast must therefore carry a way to GET the script, not merely the name of a command the recipient does not have.
[docs/pin-age-check.md](../../../docs/pin-age-check.md) "Reaching the fleet, and the bootstrap irony" holds the composed broadcast body and the send command, and states the one condition it waits on.

Never run this against another vessel's home from here.
Each vessel measures itself, and asks for its own reading back.

## Telling the captain

Translate before sending, per `AGENTS.md` section 9.
The captain's version of the transcript above is: *this vessel's local copy is level with where it updates from, but the shared code it is pinned to is 72 commits and 15 merged changes old, so four fixes that landed last night are not running here.*

Never send the transcript, the hop labels, or the word `UNMEASURABLE`.
An unmeasurable reading is *"I could not read X, so I cannot tell you whether we are current"* - never *"we look fine"*.
