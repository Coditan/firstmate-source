# Why the omega announcement duty lives in the skill

The omega protocol's announcement duty binds the vessel that is about to type into another seat.
It is stated in `.agents/skills/omega-protocol/SKILL.md`, the skill's own owner section, rather than in fleet doctrine.

The captain ruled this on 2026-09-07, choosing the skill over two alternatives he was given: a doctrine document without the duty, or waiting until fleet doctrine delivery is built.

The reason the skill was on the table at all is delivery.
Every surface a granting vessel loads is vendored firstmate material, and no shipped instruction delivers fleet doctrine; that weaker claim is the one already on the record, at `.agents/skills/grossreinschiff/SKILL.md:133`, where fleet doctrine is classified as session-binding that no shipped instruction delivers.
An earlier form of this paragraph claimed more than that, that nothing in the loaded instruction surface names fleet doctrine, and that stronger claim is false.
Shipped skills do name doctrine paths and route the reader to them: `.agents/skills/vessel-file-relay/SKILL.md:74`, `:89` and `:96` name `fleet/doctrine/credential-handover.md` and `fleet/doctrine/credential-store-boundary.md`, and `.agents/skills/updatefirstmate/SKILL.md:93` names `fleet/doctrine/pin-and-bump.md`.
Each of those pointers tells the session to read the file in the fleet repository by hand, and none of them puts a line of the doctrine's content in front of a running session.
The captain's decision survives that correction, and it is recorded here re-checked against the corrected premise rather than quietly patched.
Delivery rather than mention is what made the vendored skill the only route that reaches a vessel: a rule written into the fleet's own rulebook binds nobody who never loads it, while a rule written into the skill is read by every vessel that takes the pin.

The objection, recorded because the choice was not free: this writes a fleet-level rule into firstmate's own instruction surface rather than the fleet's, which is arguably the wrong home for it and sets a precedent for putting fleet doctrine there whenever doctrine delivery is inconvenient.
The captain was told this before choosing.
If fleet doctrine delivery is ever built, this duty is a candidate to move, and moving it means the skill keeps a cross-reference rather than a second copy.
