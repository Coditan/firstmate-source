# Startup knowledge split - the evidence behind the rule

The rule itself is owned by [`.agents/skills/stow/SKILL.md`](../.agents/skills/stow/SKILL.md), "Which knowledge file a fleet-local learning goes to".
This file is the evidence record for it: why it was written, the test that was run against real entries before it landed, the ambiguities that test exposed, and the baseline a later reading must be compared against.
Nothing here restates the rule.

## Why it exists, measured

- `data/learnings.md` on the Tugboat seat: **73,682 B on 2026-08-20, 301,909 B on 2026-09-04** - a quadrupling in fifteen days.
- On 2026-08-24 that same file grew **43,540 bytes in twenty-four hours**.
- A structural 45 KB saving landed the same week and was consumed inside one day, leaving session start flat.
- Confirmed independently here on 2026-09-04T15:29:38Z: a read-only snapshot of that file was 301,909 B, SHA-256 `444a6fa22ce59748f73dae364db9dfa16cc2d9aac31bad0c57a68265533d3209`, holding 222 headed entries of which **201 were dated within the previous three weeks**.

The lesson the fleet has paid for twice: fixing the instrument did not fix the file, and moving the file does not fix the writing.
The captain ruled on 2026-09-04 that the split is enforced fleet-wide **by a measurement printed at startup, not by a mechanism that refuses writes**, so the rule is guidance a writer follows and this record carries no gate.

## The rule was tested before it landed

Constructed rather than waited for.
The 201 entries dated 2026-08-14 or later in the snapshot were sampled systematically - every fifth entry in file order, 41 entries, no selection by hand - and each was routed as a fresh reader applying the rule with no knowledge of who wrote it.

Result: **17 routed to the loaded half, 16 to the reference half, and 8 were ambiguous or split across both.**
The ambiguous eight are the finding.

### Cases the rule routes cleanly

Straight to the reference half, because the trigger arrives with the problem and names itself:

- `cod-containerization: cannot determine default branch` means the remote is empty - a literal error string.
- A firstmate task id must be 64 characters or fewer - the spawn refuses and says so.
- A skill that requires another skill inherits its runtime limit - the skill stops and reports it.
- Two bundled entries titled "two tooling gotchas" and "five tooling gotchas" - every item in both is a refusal message that arrives with its own trigger.

Staying loaded, because nothing prompts a search:

- Never stop the shared validation daemon on `hlr-web-1`: one instance serves every home, and the damage lands on other vessels' in-flight runs.
- A seat dies when its tmux server empties - closing the last window takes the agent with it.
- A live worker reads as dead when its window name drifts: four independent readings agreed it was dead and it was not.
- The reset's "the fleet is quiet" does not mean nothing is running - it fired during a live production deploy.
- Two measurements of the wrong thing agreeing is not corroboration.

### The eight ambiguous cases, and what each one teaches

1. **A `secret-request` envelope cannot carry a body, so judging one by `body_md` calls every one empty.**
   A reader could name the moment - "when reading a Bridge envelope" - which routes it to reference; but the reader who hit this did read one, concluded the send was defective, and told the other vessel so.
   The search would only have begun after the wrong conclusion was already sent.
   **Resolved by sharpening the rule:** the moment must be one a reader reaches while they still believe something is wrong.
2. **A detector that scans an artifact containing its own rules will flag itself.**
   Intuition says "false positive on a scan you would trust" and reaches for the loaded half; the test says the scanner announced the hit and the reader searches at that point.
   **The test wins: reference.** Recorded because intuition and the test disagreed and the test is the one that has to be followed.
3. **A bare `git fetch` into a project clone breaks the Bridge relay's currency proof.**
   The damage lands on shared machinery, which reads like the first loaded reason, but it announces itself immediately and is repairable by the same reader.
   Routed to reference on the "already done and not yours to undo" wording, which is what carries the distinction.
4. **This seat's SSH key is read-only; pushes go over HTTPS.**
   The mechanical test routes it to reference - a push fails and names itself.
   The actual cost was an escalation to the captain for a credential he never had to supply, which is a reading being trusted rather than a missing fact.
   Ambiguous by construction and reported as such.
5. **The same fact appears twice in the live file**, as "This seat's GitHub write access is not the key anyone would name" (2026-08-16) and "The SSH key on this seat is READ-ONLY for admiralty" (2026-08-21).
   The recurrence clause catches this: the second is an edit of the first, not a second entry.
   This is the rule finding a real duplicate that is already loaded today.
6. **A verifier that picks the newest object rather than the newest backup**, and **replacing a Cloudflare Access policy leaves a default-deny gap.**
   Both pass the loaded test on their merits and neither is fleet-local: their owner is a project's own `AGENTS.md`.
   **Resolved by sharpening the rule:** this section runs only after step 2 has routed the finding to fleet-local knowledge at all.
7. **A required check is a report, not a control**, and **repeating a status you did not just re-take is reporting, not supervising.**
   Both route loaded and both are already stated in the always-loaded contract - `AGENTS.md` sections 7 and 8.
   The rule cannot detect that a fleet-local entry duplicates shared tracked material; it will keep both.
8. **Cleanup offers three ways out and the middle one is easy to miss.**
   The refusal text names all three options and it was still misread twice in one night.
   The rule routes it to reference, correctly, and that changes nothing: a fact already on screen and not read is beyond what any routing rule reaches.

Two of these eight - 1 and 6 - were fixed in the rule before it landed rather than left as findings.
The other six stand as limits.

## The baseline: specified here, deliberately NOT taken

The original acceptance criterion asked for a byte reading on the day this rule lands.
**That reading was not taken, and must not be taken from this change.**
The relocation of the cold half (`tugboat-split-startup-knowledge-files-relocate-cold-learnings`) was still in progress while this rule was written, and a reading taken mid-move is a false baseline that every future comparison would inherit.

Firstmate takes the reading once that relocation reports done. What it must be:

- **Subject:** one vessel's own home, named in the reading. `data/learnings.md` and `data/captain.md` are per-home and gitignored, so no seat can read another's and no reading may be generalised to the fleet.
- **Files, separately, never summed into one number:** `data/learnings.md` (the loaded half), `data/learnings-reference.md`, `data/learnings-archive.md`, and `data/captain.md`.
- **Unit:** bytes, from `wc -c` on each path. Not lines, which do not survive a change of writing style, and not a share of the digest, which moves when anything else in the digest moves.
- **Timestamp:** UTC, recorded with the reading.
- **Taken when:** after the relocation lands, on a seat with no knowledge-file work in flight.

For a later reading to mean anything, it must be compared against the baseline on **the same vessel**, on **`data/learnings.md` alone**, with the other three files reported beside it but never added in.
That is the whole point: the loaded half is the only number this rule governs, and a total will hide growth in it behind a relocation, exactly as a share hid the last one.
A comparison across vessels, or against a total, is not evidence about this rule.

## The line the loaded file's own header should carry

`data/learnings.md` is owned by another worker while this lands, so this line was **not written**.
Firstmate adds it to that file's header block, after the existing description of what the file is and before the first entry:

> Before adding anything here, load the `stow` skill: it decides whether a new learning belongs in this loaded file or in `data/learnings-reference.md`, and the loaded half is earned by that test rather than taken as the default.

## What this rule cannot prevent

The skill states this for its readers; it is repeated here because a smaller startup file will otherwise read as a solved problem.

- It governs new writing only, re-classifies nothing already loaded, and shrinks nothing by itself.
- Nothing refuses a write, by the captain's choice. A writer who does not load the skill, or who answers its one test dishonestly, is unimpeded; the startup measurement catches that a session later, never in the moment.
- It cuts what startup costs, not what exists. The reference file grows at the rate the loaded file used to.
- It cannot make a fact reachable that nobody would search for - which is why the doubt-your-reading class exists, and why a misclassification there is the expensive one.
- It cannot tell that a fleet-local entry duplicates the always-loaded contract or another vessel's record, as finding 7 above shows.
