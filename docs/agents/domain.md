# Domain docs

Where this repository's domain material lives, so that a skill exploring the codebase reads the real owners instead of looking for a store that does not exist here.

## There is no `CONTEXT.md` and no `docs/adr/`, deliberately

Do not create either, and do not report their absence as a gap.

This repository ships its own `domain-modeling` skill, at `.agents/skills/domain-modeling/`.
That skill is an adaptation of the upstream one, and its most visible divergence is exactly this: it creates no store of its own and routes everything it resolves into a home that already exists.
`docs/domain-modeling-provenance.md` records what was kept and what was changed.

The upstream shape asks for a root `CONTEXT.md` plus a `docs/adr/` tree, which is a store of its own.
Adopting it here would leave two records that can disagree, which is worse than the gap it would close.
This file resolves that in the direction the shipped skill already ruled, so that the next reader does not have to rediscover the conflict.

## Where the material actually is

`AGENTS.md` section 6 owns the routing, and the two format files under the skill own the shape of an entry.
The list below is a pointer to those owners, not a second copy of the rule.

- The operating vocabulary of this repository is carried by `AGENTS.md` itself, which is the instruction surface every session loads.
- Reference and mechanism detail is under `docs/`, and exact flags, paths, and commands are owned by each script's own header and `--help` rather than by prose.
- A term almost every contributor to one project needs goes in that project's committed `AGENTS.md`, in a `## Language` section; `.agents/skills/domain-modeling/GLOSSARY-FORMAT.md` owns the entry shape.
- A term about how this fleet itself operates goes in the home's `data/learnings.md`, under the learnings contract `AGENTS.md` owns.
- A decision that has already been made and clears the three-part bar goes in a dated record under the home's `data/decisions/`; `.agents/skills/domain-modeling/DECISION-RECORD-FORMAT.md` owns the bar, the routing, and the shape.
- A decision that is still the captain's to make is not a domain record at all and belongs to `decision-hold-lifecycle`.

There is no `## Language` section in this repository's `AGENTS.md` today.
That is the lazy-creation rule working as intended rather than a gap: the section is created when the first term is resolved into it, and an empty glossary added in advance is a file nobody reads.

## The part that will surprise an explorer

Two of the owners above, `data/learnings.md` and `data/decisions/`, live under a firstmate home's `data/` directory, which is captain-private and gitignored.
A clone of this repository contains neither.

So an agent exploring the clone will find no fleet glossary and no decision records, and that absence is not evidence that none exist.
It means they are held per home, outside the tracked tree, and are reachable only from a running firstmate home.
Do not infer from an empty clone that the fleet has recorded no vocabulary and no decisions, and do not start a tracked store here to fill the apparent hole.

## What this file does not do

It is a pointer for a reader that comes looking for one, and its reach is smaller than it appears.

The skills that consume domain vocabulary read `CONTEXT.md` directly and proceed silently when it is absent; none of them reads this file to be redirected.
So writing this file does not, by itself, point those skills at the owners above.
It answers the reader that goes looking for the repository's domain layout, and it stops the next agent from creating the store this repository already decided against.
