---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for making a captain decision durable at the moment it is given, and for completing investigations and visual reviews without losing an unresolved one.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and - whichever door it came through - the moment the captain decides anything, including an ask-user finding returned by a validation gate and a decision he simply states in chat.
user-invocable: false
metadata:
  internal: true
---

# Durable captain-decision lifecycle

This skill is the single policy owner for captain decisions: the unresolved ones an investigation or visual review discovers, and the given ones that must survive the session they were given in.

## Every door, one record

A captain decision reaches this fleet through three doors.

1. A decision an investigation or visual review discovers, registered as a hold before the answer exists.
2. An ask-user finding returned by a validation gate.
3. A sentence the captain says in chat.

Until 2026-08-17 only the first door had a durable home, and the measurement that day was that four decisions he gave, every one acted on and landed, appeared zero times in the backlog.
They existed in a worker status log deleted at cleanup, a pull-request body on the forge, and one session's context - three places that all vanish.

**Record a captain decision the moment it is given, whichever door it came through**, with `bin/fm-decision-hold.sh record`.
That command writes into the same store the holds live in, so there is exactly one place a reader has to look; do not start a second record beside it, because two records that can disagree are worse than the gap.
A decision that arrived through door 1 and has dependent work to unblock still uses `resolve`, which is the same store with the routing step attached.
Doors 2 and 3 use `record`, which needs no prior hold and no dependent work.

Put the captain's exact words in the decision file.
Not a paraphrase, not a tidied version, not a translation, and not a corrected typo: the words carry load, and on 2026-08-17 a single phrase of his moved a tier boundary.
The command stores a digest of what you hand it and refuses if the store did not keep it byte for byte, and `bin/fm-decision-ledger.sh` re-checks that digest on every read, so a later edit is visible rather than quietly authoritative.

The agent identifies that a decision happened and supplies his words; the mechanism makes them durable.
Never scrape chat, a report, or terminal output to guess that a decision occurred - that inference is exactly what these commands refuse to do for you.

## Filing a question means disposing of the ones already there

A record can end four ways, and all four are dispositions of the one store: it is **answered** (`record`, `resolve`) with the captain's words, **folded** (`supersede`) into a later record that covers its ground, recorded as **answered elsewhere** (`answered-by`) when a closed record turns out to have its answer stored under another identity, or it is still open.
A fold never claims he answered anything; it says a later record asks this better and points at it.
A folded record is therefore a valid disposition of its own question, but never a successor to fold into when that would release gated work without an answer.

`answered-by` is the one to reach for when `bin/fm-decision-ledger.sh --audit` reports `closed-without-record` and names an answered record for the same investigation - a recovered answer stored under a later identity, which is what happens when a pre-mechanism work item gated a decision and the answer was found afterwards.
Do not fold such a record: a fold states in the record that he did not answer it, which is false here, and re-`record`ing his words under the closed identity would make a second copy of them that can drift from the first.
Attest it only when you have read the named record and it answers THIS question - a shared investigation is where to look, not proof, because one work item can gate two decisions.
When none of the candidates answers it, his answer here really is lost and the record belongs in the adoption baseline instead.

`hold` and `record` refuse to add a captain record while this home holds others for the same repository that you have not disposed of.
The refusal lists them - the open questions and the recorded answers both - and you re-run with `--supersedes <id>` for each one this record folds, or `--new-ground` when none of them asks this question.
Read the list before attesting. `--new-ground` is a claim about questions you have actually read.

This gate exists because the rule before it was incomplete rather than broken.
An investigation was required to file its unresolved decisions before completing, and did; nothing required it to ask whether the question already existed.
Measured on 2026-08-17: one seat held 99 open captain records of which 18 were duplicates and 14 already answered, two-thirds noise; a second seat held 5 of which 2 were duplicates of each other and both already answered, 40 percent noise at a twentieth of the scale.
On that second seat the two duplicates asked one question in entirely different words - whether a named company counts as a customer, and which parties count as intra-group - with no shared wording, key, or origin.
**No detector pairs those.** The filer knew it was re-asking. That is why the fold is required of you, at intake, and why `bin/fm-decision-ledger.sh --audit`'s duplicate classes are a backstop for older records rather than the mechanism.

## Re-measuring a premise, and the outcome that must never be folded

Every new question is filed with `--premise`: the one line stating what makes it live right now.
Without it a record has nothing a later reader can re-measure, so it stays open by default forever.

The weekly cleanup sweep re-measures those premises and records each reading with `bin/fm-decision-hold.sh recheck --outcome holds|broken|unmeasurable`.
There are three outcomes and never two.
**`unmeasurable` is not a spelling of `broken`.**
A seat re-measured a record saying a validation gate registered that home against the wrong public repository, found the registry empty, and would have folded it - but the seat had moved, the validation state had not come with it, and the wrong registration may still stand on the original machine, which that seat cannot see.
Folding on that reading would have closed a live finding with nobody left who could see it.
So a premise you cannot reach from here is recorded unmeasurable and stays open, and the record names which seat and which path the reading was taken on.
`recheck` closes nothing under any outcome: even a premise measured genuinely false is folded, or answered, as a separate deliberate act.

## Read the record before presenting anything as open

Run `bin/fm-decision-ledger.sh` before asking the captain a question that an earlier session may already have settled, and before composing any surface that lists open decisions.
Session start prints it unprompted, and the canonical fleet snapshot now withholds an answered-but-unclosed record from the open-decision surfaces, so a board and a bearings pass no longer present a settled question as open.
None of that helps if the answer was never recorded in the first place, which is why the recording step above is not optional.

`bin/fm-decision-ledger.sh --audit` reports the decision records that are structurally unfinished, and bootstrap surfaces its findings at every session start as `DECISION_LEDGER:`.
Treat a finding as a repair, never as a fresh question for the captain: the answer is either already stored or already lost, and asking him again is the failure, not the fix.

A home adopting this mechanism starts with the losses that happened before it existed, and those are not repairs.
The first run on the main home reported 58 findings of which 57 were pre-mechanism and irreparable, which would have made the check unreadable from the first day.
Run `bin/fm-decision-ledger.sh --record-baseline` once per home, after reading what it will cover, to record that those particular answers are lost rather than pending.
It covers only records that are already closed with an observed closed date, refuses to run twice, states its count on every later run, and never silences a record that can still be repaired.
A dateless closed record remains reported because the baseline cannot bind it to a closure observed when the baseline was taken.
Its generated entry set carries an integrity digest, so editing any entry invalidates the whole baseline and leaves every finding visible until the file is deleted and re-taken.

### What the audit cannot see

An interrupted close is detectable because the mechanism wrote something before it stopped.
**A close done entirely by hand leaves nothing to detect**, and no class should be widened to guess at one.
The recovery-point record measured on 2026-08-17 is the standing example: he answered it, the answer was written by hand into the body of the task the question gated, the hold still reads held, and nothing fires - because a hold whose gated work is filed but unstarted looks identical, in the records, to one answered by hand whose gated work is filed but unstarted.
Only the prose in that task body separates them, and reading prose to infer a decision is the one inference these commands refuse.

That record still converges, by the two routes above rather than by a detector: the intake gate puts it in front of the next filer for its repository, and `--premises` carries it into the weekly sweep.
Which is the practical rule for you: **when the gate or the sweep lists an open question you can see an answer for, record his words then, in that turn.** That is the moment the mechanism is waiting for, and skipping it is how this one survived.

## Policy for unresolved decisions

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, repository, and `--premise` stating what makes the question live now.
   The command refuses until you have disposed of the captain records this home already holds for that repository: `--supersedes <id>` for each one this question folds, `--new-ground` when none of them asks it.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
7. Put the captain's exact durable decision in a file and use the script's `resolve` command with every routed task.
8. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.
9. If his answer also settles other open questions, fold each with `bin/fm-decision-hold.sh supersede <id> --by <the answered id> --reason <line>`. `resolve` carries no fold of its own, because it acts on a hold that already exists rather than adding a record; the fold is the separate act.

## Operating sequence for a decision that simply arrives

1. Write the captain's exact words to a file. Do not edit them on the way.
2. Choose the origin the decision belongs to - the task, investigation, or panel it concerns - and a stable privacy-safe key for the decision itself.
3. Run `record` with `--door ask-user` or `--door chat`, the decision file, and a `--title` stating the question he answered. Pass `--repo` when the origin names no task in this home.
4. Dispose of what the refusal lists: `--supersedes <id>` for each open question this answer settles, `--new-ground` when it settles none of them. An answer that cannot fold the questions it settles leaves them standing, which is how two records survived a ruling the captain had given hours earlier.
5. Pass `--routed-to` for each existing task the answer unblocks, and nothing when the answer gated no work; recording a decision that gated nothing is normal and correct.
6. If the command refuses because the same key already carries different words, that is a different decision: give it its own key rather than overwriting the earlier one.
7. Relay the outcome to the captain in section 9 language, never as a report that a record was filed.

An interrupted `record` or `resolve` leaves the item carrying its decision while still open, which `--audit` reports.
Re-running the identical command finishes the close; that is what the retry is for, and it is the only repair that does not need the captain again.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`bin/fm-decision-ledger.sh --help` owns the read side, the digest re-check, and what each audit class means.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
