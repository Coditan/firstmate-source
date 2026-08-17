# Codebase-sweep provenance: what the talk says, and what it does not

`.agents/skills/codebase-sweep/` carries two different kinds of material, and this page exists so nobody has to guess which is which.

- **The sweep subjects come from a talk** and are traceable to its own words, quoted below.
- **The three risk tiers do not.** They are the captain's own framing, and the talk contains no risk scale of any kind.

Getting the second line wrong would not be pedantry.
Attributing an invented scale to a source is the exact defect this fleet spent 2026-08-16 cataloguing: an explanation that fits, put where an observation belongs.
The skill states the attribution inline, and `tests/fm-codebase-sweep.test.sh` fails if that statement goes missing.

## The measurement

| | |
| --- | --- |
| Talk | "Your codebase is NOT ready for AI (here's how to fix it)", by Matt Pocock |
| Transcript read | The full cleaned English transcript, filed at sc1 as `data/codebase-ai-talk-2026-08-17/Codebase_AI_Transcript_Cleaned_EN.md` |
| How it reached this seat | Bridge envelope `2026-08-17T00-39-29Z-sc1-measured-the-talk-defines-no-risk-scale-...-437478b02576d1f9`, from sc1, 2026-08-17T00:39:29Z, verbatim in the body |
| Who measured | sc1, which re-read the full transcript before answering, and checked all three talks it had sent (Sandcastle, this codebase talk, New Skills v1.2) |
| Asked because | This seat was ordered to classify findings "as in the video" and nobody on this seat had seen it |

sc1's measured result, in three parts:

1. No risk classification anywhere in the talk.
   No severity scale, no tiers, no low/middle/high, no ranking of what to fix first.
2. It names no classes because it has none.
   Its subjects are deep modules against shallow ones, gray-box modules, progressive disclosure, cognitive load, the new-starter framing, tests as the agent's feedback loop, and planning around modules from the PRD stage.
3. It says nothing about which findings are safe to act on without a human.
   The autonomy half of the order has no source in this talk either.

Read the envelope rather than requesting the transcript again.

## The five sweep subjects, each against the transcript's own words

Quotations are from the transcript in the envelope above.
`...` marks every elision, and no other character in a quotation is altered.

| Sweep subject | The talk's own words |
| --- | --- |
| Could a stranger find the right module from folder names and public interface types alone? | "what the AI sees when it first goes into your codebase is this... a bunch of disparate modules... It has not experienced your codebase before. It's like the guy from Memento" and "It can read and understand the types that they export before it actually looks at the implementation." |
| Are the modules deep, with small interfaces, or is this a web of shallow ones? | "you have a deep module, so lots of implementation controlled by a simple interface" and "what you really want to avoid are lots of little shallow modules" |
| Is the interface where a person applies taste, while the implementation is the agent's? | "the interface... I can carefully control and I can apply my taste to and design. And then the stuff inside here, I can just delegate to an AI to control" |
| Does the file system match the mental map? | "you need to make sure that the file system and the design of your codebase matches this internal map that you have of it" |
| Are the tests good enough to be the agent's feedback loop? | "tests and feedback loops are essential for an AI because of course they're essential for a new starter joining the codebase" |

## The one ordering the talk does give

"Your codebase is probably not ready for AI because you're not using enough deep modules. And instead you've got a web of interconnected kind of shallow modules like this which are really hard to navigate and really hard to test and really hard to keep in your head."

A web of shallow modules is the thing to restructure.
That may be cited as the talk's, and it is the only prioritisation in it.
It is a target, not a scale, and it must not be dressed up as three tiers.

## Where the tiers actually come from

The captain confirmed on 2026-08-17, relayed by sc1, that the three-tier framing is **his** and no video's, and he told this seat to fill it in.
So the tiers are recorded as his framing with our definitions written under it.
If he later names another source, get that source before rewriting the scale rather than back-filling an attribution to it.

His boundary for the lowest tier, verbatim, 2026-08-17 around 01:36Z: **"low is everything reversible without me"**.

### What this seat wrote before that, and why it is not the boundary

An earlier draft on this seat defined LOW as contained behind an existing interface **and** having a check that would go red if the change were wrong.
That is stricter than what he asked for: it makes detectability a second gate, where his criterion is reversibility alone.
Presenting it as his boundary would have been substituting this seat's caution for his instruction, so it does not stand as the boundary.

It survives in the skill as a subordinate confidence aid, labelled as ours, for one reason worth keeping: a change nobody can tell went wrong is one nobody will know to reverse.
A low finding with no nameable check is therefore **flagged in the report and done anyway**, never demoted, because demoting on our own test would override him.
That leaves the conflict visible to him, which is where the decision to tighten the rule belongs.

## The architecture, which is also his

> "add that to the skill and have the dameno tell the fleet to use the skill"

The spelling in that quotation is his and is reproduced as he wrote it; he meant the daemon that fires the cadence.
It is noted here rather than corrected in place, because a quotation is either verbatim or it is not.
This one was silently normalised once already, by an automated documentation step on 2026-08-17, and restored on firstmate's ruling: a reader who cannot trust the spelling of a quotation on this page cannot trust its attributions either, and attribution is the only thing this page is for.
`tests/fm-codebase-sweep.test.sh` now fails if the spelling is smoothed again.

The obligation lives in the skill and the cadence only fires.
A timer that swept eleven repositories itself would be unauditable, would spend quota nobody approved, and would reach into homes this seat does not own.
The nudge tells each vessel to run the skill; each vessel runs it on its own repositories and decides for itself.
The cadence is a separate mechanism and is not the skill's to build or to register.

## What is adopted and what is only loaded

`codebase-design` is a plugin skill from **[`mattpocock/skills`](https://github.com/mattpocock/skills)**, by **Matt Pocock**, installed on this seat through the official plugin marketplace at `mattpocock-skills/*/skills/engineering/codebase-design`.
`codebase-sweep` **loads** it and copies nothing from it, so no file here is derived from it and no licence notice travels with this page.
Where this repository does adopt from that source, the notice lands with the adoption; see `docs/domain-modeling-provenance.md`, `docs/to-backlog-provenance.md`, and `docs/sea-chart-provenance.md`.

## Re-measure before repeating any of this

Every number and quotation above has a date on it.
The transcript is fixed, but the plugin's install path and version move, and the captain's standing merge order was already announced as changing on the day this was written.
Re-read the envelope and re-read the skill before citing either as current.
