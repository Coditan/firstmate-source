# Decision record format

What earns a decision record, where it goes, and how it is written.

## The bar

All three must hold, or there is no record.

1. **Hard to reverse.** Changing your mind later carries a real cost.
2. **Surprising without context.** A future reader will look at the result and wonder why it was done this way.
3. **The result of a real trade-off.** Genuine alternatives existed and one was chosen for stated reasons.

Holding the bar is what keeps the decision store a record of consequential forks rather than a diary.

## What qualifies

- **Architectural shape.**
  "The write model is event-sourced and the read model is projected."
- **Integration patterns between components.**
  "These two talk by events, never by synchronous calls."
- **Technology choices that carry lock-in.**
  Database, message bus, auth provider, deployment target.
  Not every library, only the ones that would take a quarter to swap out.
- **Boundary and ownership decisions.**
  "This data is owned here; everything else references it by identifier only."
  The explicit no is as valuable as the yes.
- **Deliberate deviations from the obvious path.**
  Anything a reasonable reader would assume the opposite of.
  These stop the next engineer from fixing something that was intentional.
- **Constraints not visible in the code.**
  A compliance limit, a partner contract's response-time ceiling, a platform that cannot be used.
- **Rejected alternatives when the rejection is non-obvious.**
  Otherwise the same alternative is proposed again in six months.

## Where the record goes

**First, check whether the decision is actually made.**
A decision that still belongs to the captain is not recorded here at all.
`decision-hold-lifecycle` is the single owner of unresolved captain decisions and owns registering, gating, routing, and closing them.
This format covers only a decision that has already been made.

Then route by what the decision is about.

- **A decision about how this fleet operates**, already made, goes in the home's dated decision record under `data/decisions/`, named `<YYYY-MM-DD>-<slug>.md`.
  That location is a firstmate-home convention for where such a record is kept rather than a constraint any other owner enforces, and pointing a resolved hold's `--decision-file` at the same place keeps one decision in one place rather than two.
- **A decision about one project** goes wherever that project already keeps its decisions.
  If it keeps none, it goes in that project's committed `AGENTS.md`.
  Do not create a new decision tree beside a store the project already has; a second store is how one decision comes to have two records that disagree.

Firstmate does not write the project file itself.
A crewmate writes it through that project's selected delivery path.

## The shape

```md
# {Short title of the decision}

{One to three sentences: the context, what was decided, and why.}
```

That is the whole template.
A decision record can be a single paragraph.
The value is in recording that a decision was made and why, not in filling out sections.

Add these only when they carry genuine weight, which most records will not:

- **Status** (`proposed`, `accepted`, `deprecated`, `superseded by <record>`), useful when a decision is revisited.
- **Considered options**, when the rejected alternatives are worth remembering.
- **Consequences**, when a non-obvious downstream effect needs calling out.

## Naming

Firstmate homes date their records rather than numbering them, so the slug carries the identity and the date carries the order.
Name a record for the decision, not for the task that produced it.

One consequence is worth knowing: a dated record has no short handle, so a decision referred to in conversation as a number will not be found by that number.
When a decision is discussed by a short handle, put that handle in the record's title so the two can be connected.
