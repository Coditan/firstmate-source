# Glossary format

How a resolved term is written down, and where it goes.
The routing itself is owned by `AGENTS.md` section 6; this file owns only the shape of the entry.

## Where the entry goes

A term that almost every contributor to one project needs goes in a `## Language` section of that project's committed `AGENTS.md`.
A term about how this fleet itself operates goes in the home's `data/learnings.md` instead, because it is not project knowledge and does not belong in a project's memory.
Such an entry follows the learnings contract `AGENTS.md` owns, dated and evidence-backed and curated and written inspect-then-update, not the `**Term**:` and `_Avoid_` shape below, which is for the project-side `## Language` section only.

Create the `## Language` section lazily, when the first term is resolved.
An empty glossary added in advance is a file nobody reads and nobody maintains.

Firstmate does not write the project file itself.
A crewmate writes it through that project's selected delivery path, using `bin/fm-ensure-agents-md.sh`.

## The entry

```md
## Language

**Order**:
A customer's request for goods, from placement until it is fulfilled or cancelled.
_Avoid_: purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: bill, payment request
```

## Rules

- **Be opinionated.**
  When several words exist for one concept, pick the best one and list the rest under `_Avoid_`.
  A glossary that records both names for a thing has not resolved anything.
- **Keep definitions tight.**
  One or two sentences.
  Define what the thing IS, not what it does.
- **Only terms specific to this project.**
  General programming concepts do not belong even when the project uses them constantly.
  Before adding a term, ask whether it is a concept unique to this project or a concept any engineer already knows.
  Only the first belongs.
- **Group under subheadings** when natural clusters appear.
  A flat list is fine when the terms form one cohesive area.
- **Definitions only.**
  No implementation detail, no specification, no scratch notes.
  This rule needs stating here because it cannot be enforced by the file itself: a project's `AGENTS.md` is a mixed memory file by design, so the `## Language` section carries the discipline that a dedicated glossary file would have carried structurally.

## When a term means different things in two repositories

This is the collision that is worth catching, and it is the one this fleet is least equipped to catch, because there is no central map of which repository owns which term and building one is out of scope.

Handle it without a central file.
Write the disambiguation into the `## Language` section of **both** repositories, and have each entry name the other repository and the term it uses there.
Two entries that point at each other survive a reader arriving from either side, which is the property a central map would have provided.

Record the reason the map is absent, not just the workaround: [`../../../docs/domain-modeling-provenance.md`](../../../docs/domain-modeling-provenance.md) names this as the largest dropped capability of the adopted skill and says why.
