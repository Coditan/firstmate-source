# Away mode and approval authority: the contradiction and how it was resolved

`AGENTS.md`'s away-mode stub carried a sentence that contradicted a captain ruling.
This note records the contradiction, the ruling, the two readings the ruling admits, and why the wording that landed chose one of them.
It exists so the question is not re-opened from memory by the next session that reads the stub and hears an echo of the ruling.

## The contradiction

The captain ruled that the idle backlog driver may do anything green, including merges.
The reason he accepted it is that the entire purpose of that driver is to move work while nobody is there to approve.

The stub said:

    Away mode never expands approval authority for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices.

Both cannot stand.
Relayed through Bridge on 2026-08-31, his settlement was that the instruction changes rather than his ruling narrowing; the wording was left open.

## What the sentence was actually doing wrong

The sentence bundled two different claims into one list.

The first claim - away mode adds no authority - is correct and is the reason the sentence exists.
The second claim is an artifact of the bundling: by naming merges beside destructive, irreversible and security-sensitive choices, the sentence read as a prohibition on merging while away, and so it *subtracted* authority that `AGENTS.md` section 7 had already granted.
Section 7 places routine merges of green work with firstmate wherever `yolo` is on, and a captain instruction to merge is explicit authority in any home.
The stub was overriding both, for no reason anyone had decided.

So the defect was never that away mode had to start permitting merges.
It was that away mode had been quietly withdrawing an authority granted elsewhere, and the fix is to make away mode authority-neutral in both directions.

## The wording that landed

Two bullets replace the one:

- Away mode changes what reaches the captain, never who approves what: the authority that stands while he is present stands unchanged while he is away, neither widened nor withdrawn.
- So a merge or an ask-user finding that section 7's approval-authority contract already places with firstmate stays firstmate's while he is away, a merge on that section's own head-commit reading of the required checks and never on a whole-branch view, while destructive actions, irreversible actions, and security-sensitive choices wait for his explicit word however long he is gone.

Three properties this wording is holding, deliberately:

- **The absolute part of the list did not move.**
  Destructive actions, irreversible actions and security-sensitive choices are named again, in the same words, and still wait for the captain however long he is gone, because section 7 has firstmate escalate those three even with `yolo` on.
  Narrowing the merge case must not become cover for widening any of those.
  Ask-user findings sit with merges rather than with those three: section 7 places them with the captain wherever `yolo` is off and with firstmate wherever it is on, so stating them as an absolute wait would have withdrawn an authority granted elsewhere in exactly the way the merge item did.
- **"Green" has exactly one owner.**
  The stub defines nothing; it points at section 7, which owns `Never merge a red PR`, the dated enforcement map, and the requirement to read every required check against the pull request's head commit rather than a whole-branch aggregate that can report superseded failures as current.
  An unattended merger is precisely where that distinction stops being theoretical, which is why the pointer names the head-commit reading rather than only the section.
  A second definition of green inside the away-mode stub is the failure mode this note is about, one file later.
- **`AGENTS.md` is always loaded in full.**
  A reader of the stub at three in the morning has section 7 in front of them, so the cross-reference resolves with nothing else loaded.

## The reading that was rejected, and why

The ruling admits two readings.

**(a) Away mode is authority-neutral.**
A green merge happens while he is away exactly where it would have happened with him present: `yolo` on, or his explicit word.
This is what landed.

**(b) The idle driver carries its own standing green-merge authority, independent of `yolo`.**
This was rejected.
`yolo` off is the captain's own per-project statement that he owns merges there.
Reading (b) would let a decision he made in one place be reversed by him stepping away from his desk, which is the class of silent widening an unattended agent must never perform.
It would also create a fourth source of merge authority alongside `yolo` and his explicit word, sitting in the away-mode stub rather than in section 7 where the merge contract lives.

If (b) is what he meant, the change belongs in section 7's `yolo` contract and needs his word; it is not a wording choice, and nothing here forecloses it.
The practical consequence of (a) is narrow: in a `yolo`-on home the driver merges green work while he is away, which is the case his ruling was about, and in a `yolo`-off home a merge waits, exactly as it waited when he was at his desk.

## sc1's framing, and where this departs from it

sc1 proposed splitting the merge case out of the list rather than weakening the list, on the grounds that a green merge is reversible while the other three items are what the sentence exists to protect, and that `yolo` already carries this exact shape elsewhere in the same document.

That framing was adopted in its structure and its limits: the list is split rather than weakened, the other three items are untouched, and sc1's insistence on the head-commit reading is carried into the wording.

It was departed from in one respect.
sc1 described the task as permitting away-mode merges, which points at a grant.
Stating it as a grant is what would produce reading (b) and its fourth authority source, so the wording states orthogonality instead: away mode neither adds nor withdraws, and section 7 remains the only place a merge authority is created.
That resolves the contradiction with strictly less new authority than a grant would, and it keeps the merge contract in one file.

## What deliberately was not added

The fleet has been bitten by a check that passed on an empty diff.
No empty-diff rule was added here.
It is a general property of what "green" means, so it belongs to section 7's merge contract if it is written down at all, and writing it into the away-mode stub would install the second owner of "green" that the wording above exists to avoid.

## Where this boundary is stated

- `AGENTS.md` section 8, "Away-mode stub" - the two bullets above, always loaded.
- `AGENTS.md` section 7, "Selected delivery path and approval authority" - the merge contract itself, the only owner.
- `.agents/skills/afk/SKILL.md`, "Orthogonal to approval authority" - the same principle in the skill that away mode actually loads, pointing at section 7 rather than restating it.

A contradiction moved from one file to another is not resolved, so all three were changed in the same pass.
