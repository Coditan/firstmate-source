# Skill trigger coverage audit

Date: 2026-07-31.
Repo: `firstmate-upstream`, branch `fm/firstmate-audit-unguarded-skill-triggers`, base `6fa6926`.
Question: which skills can lose their trigger line today without anything going red?

## Answer

**Twelve of the nineteen skills under `.agents/skills/` can lose every trigger line that loads them, and the whole test suite stays green.**

That is the state as found, at base `6fa6926`.
Two further counts matter, because "trigger" lives on three different surfaces:

| Surface | What a running firstmate uses it for | Can vanish silently |
| --- | --- | --- |
| `AGENTS.md` + `roles/*.md` + `bin/fm-brief.sh` load triggers | the only thing that makes an agent-only skill reachable at all | **12 of 19 skills** |
| `AGENTS.md` section 13 catalogue entry alone | the one-line trigger the placement rules require for every agent-only skill | **7 of 12 entries** |
| `SKILL.md` frontmatter `description` | the trigger text the harness shows in its skill listing | **15 of 19 skills** |

The headline number is the first row.
The third row is a second, independent instance of the same defect that nobody has been looking at: strip the `description` from all nineteen `SKILL.md` files and only two tests notice, even though the harness listing collapses to bare names and every skill loses its "use when..." text.
That was observed directly during this audit, not inferred.
The auditing agent's own live skill listing resolves to this worktree's `.agents/skills/`, and while the descriptions were cut it degraded to `afk: afk`, `harness-adapters: harness-adapters`, and so on for every skill, then recovered when they were restored.
All nineteen files stayed present and syntactically valid throughout.

**After the change that ships with this report**, measured on the same base `6fa6926` tree these counts were taken from, rows one and three read 0 of 19 and row two reads 0 of 12: every skill's section 13 entry and every skill's description now turn a test red when removed.
No skill in that tree can now lose every route that reaches it: the agent-only twelve are held by both their section 13 entry and their description, the harness-listed seven by their description.
This branch's base is `de0b95b`, whose merged tree carries 20 skill directories and 13 section 13 entries after the `ask-user-authority` restore landed mid-audit; that tree was deliberately not re-measured, because restating removal-proven counts against a tree nobody re-ran the removals on is the exact unverified-number failure this audit exists to catch, and the enumerating check covers the added skill with no separate verdict row needed (`ask-user-authority` has exactly one section 13 entry and a "Use before ..." description, and the check passes on the merged tree unchanged).
What can still vanish silently is an individual inline stub, such as the `/afk` invocation line in section 8 or the `/stow` line in section 6.
Those are a degradation rather than a disappearance now that a backstop exists, and they are the one gap left open deliberately.
See Recommendation.

## Corrections to the numbers this audit started from

The starting estimate was "6 skills pinned by explicit path in `tests/fm-instruction-owners.test.sh`, so roughly 13 unguarded".
The count is close; the membership is not, in both directions.

- There are **seven** path variables, not six.
`SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"` (line 16) was missed.
- **Three of those seven pins do not bite.**
`harness-adapters`, `firstmate-coding-guidelines`, and `secondmate-provisioning` each have a dedicated path variable, and every assertion that uses it targets the skill's own body - the effort rubric, the compatibility wording, the registry schema - never its trigger.
Delete all six `harness-adapters` references, including `AGENTS.md` section 4's "Load `harness-adapters` before every spawn or recovery", and the suite is green.
- **Two skills are guarded from outside that test entirely**, so the estimate undercounted protection.
`bootstrap-diagnostics` is held by three separate tests, and `panel` by `tests/fm-model-panel.test.sh`.
Neither has a path variable in `fm-instruction-owners.test.sh`.

Net: the true unguarded count is 12, not 13, but four of the thirteen change sides.
Pinning a file path is not the same as guarding a trigger, and reading the pin list is exactly what produced the wrong membership.

## Scope

### What counts as the instruction surface

`AGENTS.md` section 12 defines the running instruction surface as `AGENTS.md`, `bin/`, `roles/`, and `.agents/skills/`.
Applying that, a trigger line is any line in one of these that tells an agent *when* to load a skill:

- `AGENTS.md` section 13 catalogue entries, and the inline load stubs in sections 1 through 12 and 14.
- `roles/executor.md` and `roles/coordinator.md`, which amend `AGENTS.md` when `config/role` selects a role.
- The trigger text `bin/fm-brief.sh` writes into generated crewmate, scout, and panel briefs.
This surface is real and load-bearing: it is the only place `decision-hold-lifecycle` is actually guarded.
- `bin/fm-supervision-instructions.sh`, which emits one skill-load instruction (`- Away mode: active; load /afk ...`) into the session-start supervision block.
- `SKILL.md` frontmatter `description`, which is the trigger for the seven harness-listed skills - and the only trigger `ahoy` and `bearings` have anywhere.

### What looks like a trigger and carries no load, and why it is excluded

- **Maintainer comments in `bin/*.sh`.**
`bin/fm-spawn.sh:437` ("lives in the harness-adapters skill"), `bin/fm-x-poll.sh:22`, `bin/fm-decision-hold.sh:5` and similar are provenance notes for whoever edits the script.
No agent reads a shell comment at a decision point, so deleting one cannot make a skill unreachable.
- **`docs/`.**
Not part of the running instruction surface per section 12.
A skill named in `docs/configuration.md` is documented, not triggered.
- **Public `skills/`.**
Installer-facing, explicitly not loaded by firstmate.
- **`bin/board-assets/layout.css`.**
`--fm-panel` matches the string `panel` and means a CSS colour token.

### Test scope

SC1 named three candidate tests as an order of magnitude, not a boundary.
The boundary used here is **every test that reads `AGENTS.md`, `roles/`, `bin/fm-brief.sh`, or `.agents/skills/`**, minus the live-harness and Herdr/Orca end-to-end scripts that cannot run in this worktree: **39 tests**, verified green at baseline before any cut.
That set turned out to matter - three of the six guards found live outside `fm-instruction-owners.test.sh`, and one of those three (`fm-model-panel.test.sh`) is in neither the three tests SC1 named nor the pinned-path list.

## Method

Every verdict below was produced by deleting lines and running tests, never by reading a test and judging whether it looked sufficient.

The suite makes an exhaustive removal proof affordable.
Every relevant assertion is a fixed-string *presence* check (`assert_grep` and `grep -Fc ... -eq 1`, both routed through a `fail` that exits 1), so failure is **monotone in removal**: deleting more lines can only turn more tests red, never fewer.

1. **Joint cut.**
Remove all trigger lines for all 19 skills at once, run all 39 tests.
Six went red.
By monotonicity, no other test in the 39 can be reddened by any single skill's removal, so attribution needs only those six.
2. **Per-skill attribution.**
For each skill in turn: restore the tree, cut only that skill's trigger lines, run the six-test red set, record the verdict, restore.
3. **Section-13-only variant.**
Repeat for the 12 agent-only skills, cutting only the section 13 catalogue entry and leaving inline stubs in place - the realistic "one line lost in a merge resolution" case.
4. **Description surface.**
Same two-step shape: cut all 19 `description` blocks jointly against all 39 tests (two red), then attribute per skill against those two.
5. **Restore verified** with `git status` after every cut and at the end.

Cost of the shortcut: four full 39-test runs (~10 min each) instead of fifty-odd, with identical coverage.

One caution the method itself surfaced, worth recording because it would have produced a wrong verdict.
The first cut of the `/afk` line in `bin/fm-supervision-instructions.sh` deleted a `printf` that was the entire body of an `if` branch, leaving `if ...; then` immediately followed by `else`.
That is a bash syntax error, so two tests went red for a reason that had nothing to do with the trigger, and the naive reading would have been "guarded".
Re-cut as a syntax-valid edit that keeps the branch and removes only the trigger text, the suite is green.
Removal is the right proof, but a red test still has to be read: deleting a line can break a file in ways unrelated to what the line said.

## Per-skill map

Verdicts against the full instruction surface - every trigger line for that skill removed at once.

### Guarded and proven: 7

| Skill | Refs cut | Test that went red | Failing assertion |
| --- | --- | --- | --- |
| `bootstrap-diagnostics` | 4 | `fm-backlog-lint`, `fm-bootstrap`, `fm-lavish-access` | "the coded diagnostic must be registered with the other bootstrap codes"; "trigger should be action-scoped (missing: 'actionable diagnostic line')"; "AGENTS.md section 13 must list the new bootstrap diagnostic" |
| `diagnostic-reasoning` | 3 | `fm-instruction-owners` | "must have exactly one AGENTS.md trigger entry, found 0" |
| `project-management` | 2 | `fm-instruction-owners` | "must have exactly one AGENTS.md trigger entry, found 0" |
| `secrets-handling` | 3 | `fm-instruction-owners` | "must have exactly one AGENTS.md trigger entry, found 0" |
| `stuck-crewmate-recovery` | 4 | `fm-instruction-owners` | "AGENTS.md does not trigger ordinary dead-report recovery" |
| `panel` | 1 | `fm-model-panel` | "the panel skill needs exactly one AGENTS.md trigger, found 0" |
| `decision-hold-lifecycle` | 5 | `fm-brief`, `fm-model-panel` | "scout brief did not load the unresolved-decision policy before done"; "an analyst brief lost the completion gate" |

Note on `decision-hold-lifecycle`: both guards live in `bin/fm-brief.sh`, none in `AGENTS.md`.
Its section 13 entry can be deleted on its own and the suite stays green - crewmates keep the trigger, firstmate loses it.

### Guarded but the guard does not bite: 3

These carry a dedicated `$VAR` path pin in `tests/fm-instruction-owners.test.sh` and look protected in any read of that file.
Removing every trigger reference leaves the suite green.

| Skill | Pin | Refs cut | Result |
| --- | --- | --- | --- |
| `harness-adapters` | `HARNESS=` line 13 | 6 | all green |
| `firstmate-coding-guidelines` | `CODING=` line 14 | 2 | all green |
| `secondmate-provisioning` | `SECONDMATE=` line 16 | 10 | all green |

`secondmate-provisioning` is the sharpest case: ten trigger references across `AGENTS.md` and `roles/coordinator.md`, a dedicated path pin, and not one assertion that fails when all ten are gone.

### Unguarded, nothing references the trigger: 7

| Skill | Refs cut | Result |
| --- | --- | --- |
| `fmx-respond` | 3 | all green |
| `firstmate-orca` | 1 | all green |
| `firstmate-codexapp` | 1 | all green |
| `afk` | 3 | all green |
| `decisionboard` | 1 | all green |
| `stow` | 1 | all green |
| `updatefirstmate` | 1 | all green |

The `/afk` trigger emitted by `bin/fm-supervision-instructions.sh` was cut separately; that surface is unguarded too.
Evidence: replacing `- Away mode: active; load /afk and keep the session delivery wait paused ...` with `- Away mode: active.` leaves `fm-supervision-instructions`, `fm-session-start`, and `fm-bootstrap` all green.

### No trigger line on the instruction surface: 2

`ahoy` and `bearings` are named nowhere in `AGENTS.md`, `roles/`, or `bin/`.
Their only trigger is the `description` in their own `SKILL.md`, and neither description is guarded.
There is nothing here to protect on the first surface - correctly so, since both are captain-invoked recaps the harness lists directly - but they are not exempt from the third.

### Section 13 catalogue entry alone

Cutting only the one-line section 13 entry, inline stubs left intact:

- **Red (5):** `bootstrap-diagnostics`, `diagnostic-reasoning`, `project-management`, `secrets-handling`, `stuck-crewmate-recovery`.
- **Green (7):** `harness-adapters`, `firstmate-orca`, `secondmate-provisioning`, `decision-hold-lifecycle`, `fmx-respond`, `firstmate-codexapp`, `firstmate-coding-guidelines`.

### Frontmatter `description`

Cutting the `description` block from each `SKILL.md`:

- **Red (4):** `diagnostic-reasoning`, `project-management`, `secrets-handling` (`fm-instruction-owners`, exact trigger wording); `decisionboard` (`fm-decision-inventory`, "the skill description must describe the same fold as the tool").
- **Green (15):** everything else, including all seven harness-listed skills except `decisionboard`.

## Which gaps actually matter

Ranked by what breaks if the trigger silently disappears, not by count.

1. **`harness-adapters` - highest.**
`AGENTS.md` section 4 makes it mandatory before every spawn, recovery, trust dialog, interrupt, exit, resume, and adapter verification, and it is the sole owner of the "never dispatch on an unverified adapter" rule.
Losing it means crewmates get launched against guessed harness behaviour.
Six references, zero effective guards, and a pin that makes it look covered.
2. **`secondmate-provisioning` - high.**
Owns home leases, transactional seeding, the project-clone restriction, and teardown safety.
Ten references, zero effective guards.
3. **`firstmate-coding-guidelines` - high, and self-referential.**
It owns the placement tree, the one-owner rule, and trigger hygiene itself.
Losing its trigger removes the discipline that prevents this whole class of drift, and it would be invisible for exactly the reason this audit exists.
4. **`fmx-respond` - medium, conditional.**
Only binds when X mode is on, but owns public-reply safety classification.
Losing it means a public mention could be answered with no safety gate.
5. **`decision-hold-lifecycle` section 13 entry - medium.**
Degrades rather than disappears: the brief scaffold keeps the crewmate-side trigger, so firstmate loses the completion gate while crewmates keep it.
A split like that is harder to notice than a clean loss.
6. **`afk` - medium.**
Section 8's away-mode stub survives independently, so the safety facts stay inline even if the invoke line goes.
7. **`firstmate-orca`, `firstmate-codexapp`, `decisionboard`, `stow`, `updatefirstmate` - low.**
Captain-invoked or narrow-runtime.
Losing the line costs discoverability, not safety, and the harness listing still surfaces the three user-invocable ones.
8. **`ahoy`, `bearings` - lowest.**
Captain-invoked recaps with no safety content.

Items 1 through 3 are the ones worth acting on.
All three were on the pinned-path side of the previous count: two of the six it listed, plus the seventh pin it missed.

## Recommendation

**Do not hand-write guards for the individual skills.**
A second hand-maintained list has the same silent-staleness failure mode as the first, and would need a line added every time the directory grows - which is precisely the step that gets skipped.

Add one check that enumerates the directory instead.
It is implemented and verified on this branch as `test_every_skill_declares_a_load_trigger` in `tests/fm-instruction-owners.test.sh`:

- every `.agents/skills/*/` must have a `SKILL.md` whose `name:` matches its directory;
- every `user-invocable: false` skill must have **exactly one** `AGENTS.md` section 13 entry;
- **every** skill must have a non-empty frontmatter `description`;
- **every** description must state a condition, detected as a standalone `when`, `whenever`, `before`, or `after`;
- every section 13 entry must name a skill directory that exists, so a rename cannot leave a trigger pointing at nothing.

It covers two surfaces because a skill can arrive by two routes and a deployment may only have one.
Section 13 is the route for a firstmate reading its own instruction surface.
The description is the route for the harness skill listing, and it is the only route left where no instruction-surface trigger line is possible at all.
That is why the description clauses apply to every skill in the directory, all nineteen of them at base `6fa6926`, rather than only the seven the harness listed there: a skill that lands in a deployment with no section 13 available has its description as its sole arrival path, and the surface that carries a skill alone is the last one that should be unguarded.

Both clauses live in the same loop over the same directory listing, sharing one accumulator and one failure report.
Covering the third surface needed no second mechanism.

It enforces a convention that is already written down - `firstmate-coding-guidelines` "Trigger hygiene" says "a new skill is dead weight if nothing loads it", requires a section 13 line for every agent-only skill, and requires the trigger be stated as a condition rather than a vague pointer - and follows the same skill's instruction to prefer deterministic enforcement over agent memory for critical infrastructure.
It extends the existing test rather than adding a runner, per the repo's colocation rule.

**Cost.** 91 lines, including 26 lines of shared helpers: one that isolates the YAML frontmatter block so a column-0 key in the body cannot satisfy a frontmatter probe, and one that flattens the folded-block description forms.
Runs in under 300 ms inside the existing `pure-contract-unit` family, no new dependency, `shellcheck` clean.
It passes on the tree unchanged.
Ongoing cost is one `AGENTS.md` line per new agent-only skill and a description that says when to load it, both of which the placement rules already require.
Because it reads the directory, it cannot go stale as the directory grows.

**Verified to bite**, by removal, in 34 scenarios, all run at base `6fa6926` and counted against that tree:

- all 12 agent-only skills, section 13 entry removed individually - red in every case, including the 7 that were green before this change;
- all 19 skills, `description` emptied individually but the key left present - red in every case.
16 fail on the new clause by name; the other 3 (`diagnostic-reasoning`, `project-management`, `secrets-handling`) exit earlier on the pre-existing exact-wording assertions, which is why an earlier count of this run appeared to miss them;
- a description rewritten as a bare summary with no condition word - red;
- a new skill directory added with no section 13 trigger - red.
Reproduced with a stub named `ask-user-authority` carrying a perfectly good description, which is the original incident: `not ok - skills with no load trigger: ask-user-authority(section-13-entries=0)`;
- a section 13 entry left behind naming a skill that no longer exists - red.

**What it deliberately does not do.**
It proves a trigger *exists* and *states a condition*, not that the condition is the right one or well scoped.
The condition clause is a floor: `when`, `whenever`, `before`, or `after` anywhere in the description satisfies it, so a badly worded trigger still passes.
The existing hand-written assertions - exact trigger text for `diagnostic-reasoning`, `project-management`, `secrets-handling`, the bootstrap code list, the `panel` count - are still worth keeping on top of it.
This is a floor, not a replacement.

**One gap it does not close**, left as a finding rather than a change:

- The inline load stubs in `AGENTS.md` sections 1 through 12, and the `/afk` line `bin/fm-supervision-instructions.sh` emits into the session-start supervision block.
These stay unguarded.
For every skill the section 13 entry and the description are now both backstops, so a lost inline stub degrades the trigger rather than removing it - which is the difference between a skill that loads late and a skill that never loads.
Guarding the stubs individually would mean a hand-maintained list of line texts, which is the pattern this check exists to avoid.

**One judgement call worth flagging.**
The section 13 clause requires an entry for every agent-only skill in *this* repo.
If a skill ever has to live here without one, the test will fail loudly rather than let the skill go quietly unreachable.
That is the intended trade, but it means adding such a skill is an explicit decision rather than a silent one.

## Scope note

The brief asked for a report, not thirteen fixes, and the map above is that report.
The single structural check ships with it by decision: it is one change rather than thirteen, it closes twelve gaps at once and stops the thirteenth from opening, and it enumerates the directory instead of listing skills, so it cannot go stale as the directory grows.
