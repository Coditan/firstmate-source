# Why the omega announcement duty lives in the skill

The omega protocol's announcement duty binds the vessel that is about to type into one of its own seats.
It is stated in `.agents/skills/omega-protocol/SKILL.md`, the skill's own owner section, rather than in fleet doctrine.

The captain ruled this on 2026-09-07, choosing the skill over two alternatives he was given: a doctrine document without the duty, or waiting until fleet doctrine delivery is built.

The reason the skill was on the table at all is delivery.
Every surface a granting vessel loads is vendored firstmate material, and no shipped instruction delivers fleet doctrine; that weaker claim is the one already on the record, at `.agents/skills/grossreinschiff/SKILL.md:133`, where fleet doctrine is classified as session-binding that no shipped instruction delivers.
An earlier form of this paragraph claimed more than that, that nothing in the loaded instruction surface names fleet doctrine, and that stronger claim is false.
Shipped skills do name doctrine paths and route the reader to them: `.agents/skills/vessel-file-relay/SKILL.md:74`, `:89` and `:96` name `fleet/doctrine/credential-handover.md` and `fleet/doctrine/credential-store-boundary.md`, and `.agents/skills/updatefirstmate/SKILL.md:93` names `fleet/doctrine/pin-and-bump.md`.
Each of those pointers tells the session to read the file in the fleet repository by hand, and none of them puts a line of the doctrine's content in front of a running session.
The captain's decision survives that correction, and it is recorded here re-checked against the corrected premise rather than quietly patched.
Delivery rather than mention is what made the vendored skill the only route that reaches a vessel: a rule written into the fleet's own rulebook binds nobody who never loads it, while a rule written into the skill is read by every vessel that takes the pin.
`docs/fleet-plugin-skills.md` owns that property of a vendored skill, including the measurement behind it, and it is pointed at here rather than restated.

This placement reaches the vessel the duty binds: the granting vessel loads the skill, because the captain names the protocol in its own chat.
An earlier form of this document also recorded a second, undelivered half - a bound on what a receiving seat in another vessel could take from such text - and that half is gone with the reach it depended on.
On 2026-09-08 the captain ruled that the protocol never crosses vessels: "cross vessel is not part of omega... its to drive work, that only involves one vesssel".
Every seat the duty now covers is one of the granting vessel's own workers, which that vessel supervises and briefs already, so what the narrowing dissolves is the need for a general receiving-vessel bound, not reach: a crewmate, scout, or secondmate seat still does not load this skill, because the captain names the protocol in the granting vessel's chat rather than in a worker seat's.
For a secondmate seat the premise that such a seat simply takes text typed into it as the ordinary instruction of its own supervisor does not hold, and the ground for saying so is measurement rather than argument: the incident recorded at `docs/herdr-backend.md:387` for 2026-07-13 reads "A routed request reached a Pi/Herdr secondmate without the visible `[fm-from-firstmate]` label, so the secondmate correctly treated it as direct captain conversation and returned nothing to the parent status path", a reproduced failure rather than a hypothetical.
What the incident establishes is that a delivery reaching a secondmate without the from-firstmate label is read there as direct captain conversation and returns nothing to the parent status path. What the granting vessel must do about that is not settled by this change, and nothing in this document is delivered to that seat.

The objection was recorded because the choice was not free: at the time this looked like a fleet-level rule written into firstmate's own instruction surface rather than the fleet's, arguably the wrong home for it and a precedent for putting fleet doctrine there whenever doctrine delivery is inconvenient.
The captain was told this before choosing.
His 2026-09-08 ruling largely dissolves the objection: a duty that binds a vessel typing at its own workers is firstmate's own material, and the skill is its right home rather than a stand-in for doctrine.
