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
- A term about how this fleet itself operates goes in the home's fleet-local knowledge, with the [`stow` skill](../../.agents/skills/stow/SKILL.md) owning which file receives it.
- A decision that has already been made and clears the three-part bar goes in a dated record under the home's `data/decisions/`; `.agents/skills/domain-modeling/DECISION-RECORD-FORMAT.md` owns the bar, the routing, and the shape.
- A decision that is still the captain's to make is not a domain record at all and belongs to `decision-hold-lifecycle`.

There is no `## Language` section in this repository's `AGENTS.md` today.
That is the lazy-creation rule working as intended rather than a gap: the section is created when the first term is resolved into it, and an empty glossary added in advance is a file nobody reads.

## The part that will surprise an explorer

Two of the owners above, the fleet-knowledge files and `data/decisions/`, live under a firstmate home's `data/` directory, which is captain-private and gitignored.
A clone of this repository contains neither.

So an agent exploring the clone will find no fleet glossary and no decision records, and that absence is not evidence that none exist.
It means they are held per home, outside the tracked tree, and are reachable only from a running firstmate home.
Do not infer from an empty clone that the fleet has recorded no vocabulary and no decisions, and do not start a tracked store here to fill the apparent hole.

## No skill reads this file today

This file is groundwork for a reader that has not arrived yet, and it should be read that way rather than as something load-bearing.

No installed skill reads it.
Measured on one seat on 2026-08-22 against `mattpocock-skills` 1.2.3, the only skill source naming `docs/agents/domain.md` is the setup skill that writes it.
The skills that actually consume domain vocabulary, among them `tdd`, `diagnosing-bugs`, and `codebase-design`, read `CONTEXT.md` directly and proceed silently when it is absent.
None of them is redirected here, so writing this file does not by itself point any of them at the owners above.

That is worth stating plainly because the upstream documentation says the opposite.
The plugin's own `docs/engineering/domain-modeling.md` recommends putting instructions in "your own `docs/agents/domain.md`, which the skills already read".
The installed skill files do not implement that claim, so it was checked against the artifact rather than taken on the documentation's word, and this note records the result.

What the file does do is answer the reader that comes looking for this repository's domain layout, and stop the next agent from creating the store this repository already decided against.
That is a smaller job than the file's existence implies, and naming its size here is cheaper than letting someone discover it by depending on it.
