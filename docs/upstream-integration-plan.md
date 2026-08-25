# Staged plan for taking canonical upstream into this fork

This is the staged plan the captain approved the shape of on 2026-08-19 and whose content did not survive in this home.
It is re-derived here against the tree as it stands, so that no later session has to derive it a fourth time.
Every figure below was measured for this document; none is carried forward from an earlier reading, and where an earlier reading and this one disagree, this one says so rather than quietly replacing it.

[`docs/fork-upstream-merge-assessment.md`](fork-upstream-merge-assessment.md) remains the record of the merge attempts themselves and is not restated here.
[`docs/fork-patches.md`](fork-patches.md) remains the authoritative local patch stack registry and is the only place a patch verdict is recorded.
This document owns one thing the other two do not: what gets taken, in what order, and why each boundary sits where it does.

The daily upstream cadence is separate work and is deliberately not delivered by this unit.
`fleet-upstream-integration-measure-on-demand` owns the on-demand comparison with a defensible per-change verdict, and delivered it as `bin/fm-upstream-distance.sh`.
That script's header is the one owner of its verdict vocabulary and of the evidence each verdict rests on; nothing here restates it.
It speaks only when it is run: it arms no check, registers no watcher subject, and adds no line to the session-start digest, which `tests/fm-upstream-distance.test.sh` proves by starting a session against a written report and finding none.
`fleet-upstream-integration-daily-arm-and-dispatch` owns the recurring daily check that wakes only when it finds something actionable, and is blocked by the on-demand comparison unit.
Neither a recurring check nor its scheduling is added here, and no session-start surface reports an upstream count or distance.

## What was measured, and against which repositories

Measured 2026-08-24T10:19Z, in a disposable worktree of this repository, with no working tree touched: the conflict readings come from `git merge-tree --write-tree --name-only`, which produces the same markers a real merge would write without performing one.

- Fork side: `Coditan/firstmate-source`, `main` at `963797c239aa30eb0026bbb9fe87b807ea2524ef`, fetched from that URL directly.
- Upstream side: `https://github.com/kunchenguid/firstmate.git`, `main` at `8fa0505e48a155da78a9aeeb50911719dc558710`.
- Merge base: `bc1a21b2ccfcd500ae29181f82b28b6cf1075bfb`, dated 2026-07-18 and unchanged since the 2026-08-18 assessment.

This home has no `config/fork-sync-upstream` and no `upstream` remote, because tracking of canonical upstream was retired on 2026-08-23.
The upstream URL above was therefore supplied by hand rather than read from configuration, and every reading here names which side it came from for that reason.

Divergence, from `git rev-list --count --no-merges`:

| Direction | Count |
| --- | --- |
| Upstream-only, not in the fork | 247 |
| Fork-only patches | 684 |

## The governing decision: integrate by effect, never by merging the tip

The unit of integration is one upstream **effect**, re-implemented against this fork's own tree and proved by this fork's own tests.
It is not a resolved conflict hunk, and it is never `git merge upstream/main`.
Four measurements decide that, and each one is a reason a merge cannot be the instrument even if someone had the time for it.

**The conflict surface is not shrinking.**
154 paths conflict: 116 content, 27 add/add, 11 modify/delete.
They carry **933 conflict regions holding 37,281 lines between the markers** - 210 regions of four lines or fewer, 343 of five to fifteen, 231 of sixteen to fifty, and **149 longer than fifty lines**.
By area the conflicted paths are 57 in `tests/`, 46 in `bin/`, 26 in `docs/`, 12 in `.agents/`, 5 in `.pi/`, and one each in `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.gitignore`, `.github/`, `.claude/`, `.opencode/` and `.no-mistakes.yaml`.
The heaviest single files are `bin/fm-test-run.sh` at 55 regions, `tests/fm-calm-pi-extension.test.sh` at 45, the watcher script at 36, `tests/fm-backend-herdr-presentation-e2e.test.sh` at 32 and `bin/fm-spawn.sh` at 28.

**There is no small first increment.**
Merging only the first *n* upstream commits does not produce a smaller problem, from `git merge-tree` against the 10th, 25th, 50th and 100th commit of `git rev-list --reverse --first-parent <base>..upstream`:

| Upstream commits merged | Conflicted paths |
| --- | --- |
| 10 | 51 |
| 25 | 81 |
| 50 | 114 |
| 100 | 132 |
| 247 (tip) | 154 |

Ten commits - four per cent of the range - already conflict in a third of the paths the whole range does.
The divergence is structural rather than cumulative, so splitting a merge into increments multiplies how many times the same machinery is reconciled instead of dividing the work.

**Most of what would arrive carries no marker at all.**
Upstream added 217 paths since the merge base; **184 of them have no counterpart in this fork**, so they arrive with nothing to resolve: 80 in `tests/`, 70 in `bin/`, 20 in `docs/`, 5 in `.pi/`, 4 in `.agents/`, plus `VISION.md`, `GROK_BOT.md`, `.greptile/rules.md`, `.cursor/hooks.json` and `.github/workflows/windows-herdr-spike.yml`.
This repository's own gates then require a hand decision for each: `bin/fm-test-run.sh --check-coverage` proves that `docs/scripts.md` names every `bin/*.sh` exactly once, and `family_for_basename` refuses to select a test with no family and has no catch-all.
That is **66 script-index rows and 79 test-family entries - 145 hand decisions that sit entirely outside the 933 conflict regions**, each needing the incoming file read before it can be made.

**A merge's default outcome contradicts a captain ruling.**
The `keep-ours` ruling of 2026-08-19 keeps this fork's hosted wake delivery and declines upstream's arm-based model.
A merge does not respect it by default; it reinstates the model in three separate ways, each measured on today's tips.
Four of the eleven modify/delete conflicts are exactly the arm files this fork deleted and upstream still edits - `bin/fm-watch-arm.sh`, `.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts` and `tests/fm-pi-watch-extension.test.sh` - and `git merge-tree` leaves upstream's version of each **in the tree**.
All six of this fork's `docs/supervision-protocols/*.md` files carry **zero** arm references today and gain 16 between them in the merged tree, plus 2 more in a seventh file upstream adds; those files are what `bin/fm-supervision-instructions.sh` renders into the block every session reads.
And `.claude/settings.json` conflicts in exactly one region, at lines 24 to 36 of the merged blob, while the merge inserts a `Stop` hook invoking `bin/fm-claude-stop-autoarm.sh` at line 59 - **outside every marker**, so resolving the marked hunk leaves per-turn re-arming wired into a fleet whose contract says there is nothing to arm.
Across the whole tree, files whose content matches `watch-arm`, `autoarm`, `auto-arm` or `arm-command-policy` go from 24 on the fork to 67 in the merged tree.
That last figure is the weakest of the four and is stated as such: the fork's own 24 are mostly its unrelated pretool command guard, which [`docs/fork-upstream-merge-assessment.md`](fork-upstream-merge-assessment.md) already corrected once.
The protocol-document count and the `.claude/settings.json` line number are the load-bearing ones.

A merge defaults to taking upstream's structure and obliges this fork to defend 933 hunks against a ruling.
Integration by effect defaults to keeping ours and obliges each stage to justify what it takes.
That is the whole argument for the shape of this plan.

### One earlier reason for not merging has lapsed, and is not reused here

The 2026-08-23 assessment argued that an ancestry-only merge must never be landed, because `bin/fm-fork-sync-check.sh` measured upstream-only work by ancestry and any merge of the tip would silently take that count to zero forever.
That script no longer exists; it was removed on 2026-08-23 with the rest of canonical-upstream tracking.
The argument therefore no longer binds for the reason it was written, and this document does not repeat it.
The four measurements above stand on their own.

## The stages

Each stage below is one worker session.
Where a class of work is larger than one session, the class is named and its members are listed as separate stages rather than being hidden inside one; a stage that turns out to be bigger than a session when it starts should be split at that point and this list corrected, not carried through.

### Stage 1 - the session lock (landed with this document)

**Scope.** Upstream's hardening of `bin/fm-lock.sh`, re-implemented on this fork's own identity contract: refusal when the state directory cannot be created, a write probe before anything is claimed, a claim lock serialising the read-then-write, refusal of a lock that is not a regular file, refusal of a lock that exists and cannot be read, and read-back verification that the lock record names this session's own pid and process table.
Delivered with `tests/fm-lock.test.sh`, which fails against the tree before the change.

**Why this boundary.**
Three reasons, in order of weight.
It is the only upstream gap this repository has already written down as a cost it knowingly accepted: `docs/fork-patches.md` names "the `bin/fm-lock.sh` write-probe and claim-lock hardening" as real robustness this fork lacks, so closing it needs no new argument about whether it is wanted.
It sits exactly where the `keep-ours` ruling is at risk, because upstream's own comment says its `bin/fm-session-lock-lib.sh` split exists "so the Claude Stop auto-arm applies the exact same identity contract" - taking upstream's diff here would import the arm-serving factoring along with the fix, and taking the effect instead is the whole method this plan rests on.
And it is small enough that the method can be proved on it: the file conflicts in 2 regions, and upstream's copy is 107 lines.

**What was deliberately left out, and why.**
Upstream's acquisition also consults `state/.startup-network.status` to name a prior session's bounded startup sweep as the claim holder.
That depends on `bin/fm-startup-network.sh`, which this fork does not have and which is one of the 184 unmarked arrivals.
Taking that branch would mean taking a subsystem, so it belongs to Stage 5 and not here.

### Stage 2 - the six supervision-protocol documents and `.claude/settings.json`

**Scope.** Decide, once and in writing, what this fork's session-start supervision block says about delivery, and record it in `docs/supervision-protocols/` and `.claude/settings.json` against the hosted-delivery contract.
No upstream text is taken without that decision naming it.

**Why this boundary.** These are documents and one configuration file, so the stage carries no code risk, and they are the single place where the arm model re-enters without a marker to warn anyone.
Doing them before any spine script means every later resolution has a written contract to resolve against instead of a guess.
It is deliberately not merged with Stage 1: Stage 1 keeps its own identity contract, which is a local decision, whereas this stage sets what every session in the fleet is told.

### Stage 3 - what cleanup owes before it may complete

**Scope.** Decide whether this fork adopts upstream's public-followup obligation in `bin/fm-teardown.sh`, and either take its effect against this fork's own cleanup path or record the decline.

**Why this boundary.** It is the one measured change that alters what cleanup **refuses on**, which is hard rule 3 territory, and it does not announce itself: `bin/fm-teardown.sh` conflicts in 17 regions, and of the 7 lines mentioning `public-followup` in the merged blob only 2 sit inside a marker.
This fork's own copy carries none of them today, so the mechanism lands unless it is removed on purpose.
It is its own stage rather than part of Stage 4 because it is a contract decision first and a code change second.

### Stage 4 - the supervision spine, one script per stage

Each of these is a two-architecture reconciliation in which the `keep-ours` ruling has to be re-argued for that file specifically, so each is its own session and none of them may be batched.
Conflict regions on today's tips:

| Script | Regions |
| --- | --- |
| `bin/fm-test-run.sh` | 55 |
| the watcher script | 36 |
| `bin/fm-spawn.sh` | 28 |
| `bin/fm-wake-lib.sh` | 19 |
| `bin/fm-teardown.sh` | 17 (contract decided in Stage 3) |
| `bin/fm-session-start.sh` | 13 |
| `bin/fm-guard.sh` | 4 |
| `bin/fm-turnend-guard.sh` | 2 |
| `bin/fm-supervision-instructions.sh` | 2 |

`bin/fm-test-run.sh` is also an add/add conflict - both sides wrote it independently - so it belongs to Stage 6 rather than being resolved as a diff, and it appears here only so its size is not lost.

### Stage 5 - capabilities upstream has and this fork does not, one subsystem per stage

The 184 unmarked arrivals are not stragglers; they are whole subsystems, and each is a **product decision before it is an integration task**: does this fleet want this capability at all?
A stage here answers that question first and only then does the work, and a declined subsystem is recorded as declined rather than left to be rediscovered.
The largest groups, by matching path count:

| Subsystem | Paths |
| --- | --- |
| `fm-remote-*` (remote secondmates) | 24 |
| `fm-procevent-*` (process event sources) | 7 |
| voice interface (`fm-voice-*`, `fm_voice_*`) | 6 |
| `fm-public-followup*` (see Stage 3) | 5 |
| Cursor harness support | 5 |
| `fm-control*` | 5 |
| `fm-startup-*` | 5 |
| `fm-trace-context*` | 5 |
| `fm-busy-*` | 4 |
| `fm-secondmate-*-lib` | 4 |
| four upstream skills, including two this fork has never had | 4 |

Eight of the 20 incoming `docs/` paths are `docs/verification/*`, which are upstream's own backend-verification records; those travel with whichever subsystem they verify and are never taken on their own.
Every stage here must also close its own share of the 145 gate obligations, because the suite will not select an unfamilied test and `--check-coverage` will not pass an unindexed script.

### Stage 6 - the 27 features both sides built independently

Both sides added these paths with no common ancestor, so each is a design decision between two working implementations rather than a merge choice.
`bin/fm-operational-input.sh` is the one already measured as safe to union, because both sides implemented the identical wire contract and this fork's divergence is purely additive.
The rest - `bin/fm-test-run.sh`, `bin/fm-pending-reply-lib.sh`, `bin/fm-subagent-pretool-check.sh`, `bin/fm-test-isolation-proof.sh`, the two skills, the six documents, the three `.pi` extensions and the ten test counterparts - are one decision each.
Group them only where one decision genuinely covers several files, such as a script and its own test.

### Stage 7 - the local patch stack registry

**Scope.** Add the fourth verdict category the captain approved on 2026-08-19, apply it to the sixteen patches that have no honest verdict, and then close the registry's coverage gap.

**Why this boundary and why last.** A verdict is a claim about what upstream carries, so it can only be re-taken after the stages above have decided what this fork actually takes.
The coverage half is separately enormous and is not one session: the registry holds 94 rows against 684 fork-only commits, so roughly 590 commits have never been recorded at all, and that gap predates every merge attempt.
Split it by patch class when it is filed, never commit by commit.

## Already answered, and needing no stage

- **Whether this fork keeps hosted wake delivery.**
  Answered `keep-ours` on 2026-08-19.
  Every stage is resolved against it, and Stage 2 writes it into the instruction surface.
- **The seven paths upstream deleted that this fork still edits** - `bin/fm-dispatch-select.sh`, `docs/decision-hold-lifecycle.md`, and the tests for captain translation, decision-hold lifecycle, dispatch selection, instruction owners and the stow contract.
  All are fork-authored surfaces upstream never had a reason to keep; they stay.
  `bin/fm-dispatch-select.sh` in particular stays for `bin/fm-model-panel.sh`, which is its only production caller.
- **The four arm paths this fork deleted that upstream still edits.** They stay deleted, by the same ruling.

## What is unmeasured

- **Whether the merged tree's suite passes.** No merge was landed by this work and none is proposed, so there is no merged-tree run, and nothing here claims one.
- **The read-back branch of Stage 1's own verification.** Its negative case - a write that reports success and leaves a record that does not name this session's pid and process table - has no portable fixture; `tests/fm-lock.test.sh` says so in its own header rather than implying coverage it does not have.
- **Whether any given upstream subsystem in Stage 5 is wanted.** That is a decision, not a measurement, and this plan deliberately does not pre-empt it.
- **How far each stage's estimate holds.**
  The sizes above are conflict-region counts and path counts, which are a proxy for effort and not a measurement of it.
  Stage 1 is the only one whose size is now known from having been done.
