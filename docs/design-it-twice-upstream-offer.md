# Upstream offer: an entry test and an independence warning for DESIGN-IT-TWICE.md

**Status: prepared, NOT SENT.**
Opening a pull request on a stranger's public repository is outward-facing and not cheaply undone, so this page holds the whole contribution and nothing has left this machine.
The captain approved the intent on 2026-08-20, and on 2026-08-21 he settled the channel and the identity and ordered one rewrite of the wording.
One gate remains and it is his: **he reads the final text before anything is published.**
The decisions, and what is still open, are stated at the bottom of this page.

This is the reciprocal half of [`design-it-twice-provenance.md`](design-it-twice-provenance.md).
This fleet adopted one file of Matt Pocock's `codebase-design` skill and wired its fan-out to the model panel, and two of the things that had to be added are not local at all.
They are offered back.

## Two constraints this offer is written under

**It proposes no dependency on anyone's tooling.**
The mechanism behind the independence claim is `bin/fm-model-panel.sh`: two analysts on provably distinct pinned models who cannot see each other's work, plus a judge that re-verifies their load-bearing claims.
**None of that is being proposed upstream.**
An upstream skill has to run in any repository, on any harness, with no local script anywhere, so what is proposed is prose that names a property the reader can check for themselves.
Where first-hand experience is the evidence, the note says so, and says plainly that the arrangement it comes from is the author's own and is not the proposal.

**It makes no public claim about who runs what.**
The captain ruled on 2026-08-21, in his own words, "not say that in pubnlic".
He was answering one specific exposure: the note said "we" and "our fleet" throughout and would go out under an HLR account, so a reader would infer that HLR operates a fleet of agent-managed repositories.
That is true, it is not currently public, and he does not want it made public.
The rewrite below removes that inference without weakening a single technical claim.
The spelling in that quotation is his and is reproduced as he wrote it.

### What may be published from this page, and the test it has to pass

Only the indented blocks are published: the prose changes, the changeset, and the covering note.
Everything else here is internal explanation and never leaves this repository.

Each publishable block was swept against the captain's own test - **does a public reader learn from it that HLR runs an agent fleet?** - and every failing phrase was rewritten.
The note now speaks in the first person singular, describes no estate of repositories, and names no internal script.

The surrounding internal prose keeps its ordinary vocabulary, because it names no HLR entity and fails no part of that test.
One residual link is his to weigh rather than this page's to bury: this repository is public, so an account that opens the pull request and is also visible here could be traced back, which reaches the same inference by a different route.
That is a fact about the account, not about the wording, and it does not change under any rewrite of the text.

## What would change upstream

| File | Change |
| --- | --- |
| `skills/engineering/codebase-design/DESIGN-IT-TWICE.md` | A "Before you fan out" entry test; an independence paragraph in Step 2; a verification step in Step 3 |
| `docs/engineering/codebase-design.md` | Re-sync, required by their `CLAUDE.md` when a promoted skill's behaviour changes; plus one stale-quotation correction |
| `.changeset/design-it-twice-entry-test.md` | A patch changeset, required by their release process |

No new skill, so `README.md`, `.claude-plugin/plugin.json`, and `ask-matt` are untouched.
Their house style uses em dashes and this repository forbids them, so the prose below is written with plain dashes; convert on the way out to match their file.

## Change 1 - an entry test, inserted after the `## Process` heading and before `### 1. Frame the problem space`

    ### 0. Decide whether to fan out at all

    Designing it twice is cheap. Fanning out is not.

    Do the exercise in one head first: write a second and a third interface
    yourself under the constraints in Step 2, compare them on depth, locality and
    seam placement, and recommend one. Most interface questions end there.

    Spend the parallel fan-out only when all three hold:

    - Several shapes are genuinely defensible, and the choice matters more than the
      analysis.
    - Getting it wrong is expensive to undo: callers outside the module change, or
      the seam moves.
    - You would act differently depending on which design wins.

    If you would ship the same interface whatever came back, you already have your
    answer.

## Change 2 - independence, appended to `### 2. Spawn sub-agents` after the agent list

    Sub-agents are not independent by default. The divergence here comes from the
    differing constraints, not from the designers: unless your harness lets you pin
    each sub-agent to a different model, every design comes back from the same model
    with the same priors. Three designs that agree are then one model agreeing with
    itself, and the fan-out reads as corroboration when it was repetition.

    If you can pin different models, do, and name which model produced which design
    when you present them. If you cannot, say so in Step 3: it changes how much their
    agreement is worth.

## Change 3 - verification, inserted in `### 3. Present and compare`, before the recommendation sentence

    Before recommending, check each design's load-bearing claims against the code
    rather than against the design that made them. Does the second adapter actually
    exist, or is the seam hypothetical? Do the callers it names actually call it?
    Does the deletion test hold? Each design is an argument, and the most
    confidently written one is not the deepest one.

## Change 4 - the docs page re-sync

Two touches in `docs/engineering/codebase-design.md`:

1. In the "Two supporting files" paragraph, after the sentence describing `DESIGN-IT-TWICE.md`, add: `It now gates itself first: design it twice in one head, and fan out only when several shapes are defensible and the choice would change what you ship.`
2. In the answer to "I pointed a session at it and it burned 100k tokens", after "The issue is open", add: `The fan-out itself now carries an entry test, which narrows the most action-shaped content an agent can reach for, though it does not turn a reference into a driver.`

And one correction that is not ours to insist on, offered separately in the note: the answer to "Does the design-it-twice pattern work outside Claude Code?" still quotes `DESIGN-IT-TWICE.md` as saying "spawn 3+ sub-agents in parallel using the Agent tool".
That wording is gone as of release 1.2.3, which dropped one harness's tool and agent-type names from exactly this file, so the docs page and open issue 564 both read as though it were still there.

## Change 5 - the changeset

`.changeset/design-it-twice-entry-test.md`:

    ---
    "mattpocock-skills": patch
    ---

    codebase-design: gate the design-it-twice fan-out and name what it cannot
    guarantee.

    - Add an entry test in front of the fan-out. Design it twice in one head first;
      spend the parallel agents only when several shapes are defensible, the choice
      is expensive to undo, and you would act differently on the outcome.
    - Say in Step 2 that sub-agents are not independent by default: without pinned
      distinct models they share one model's priors, so their agreement is
      repetition rather than corroboration. Pin different models where the harness
      allows it and name them in the comparison; say so where it does not.
    - Add a verification step to Step 3: check each design's load-bearing claims
      against the code before recommending, rather than against the design that
      made them.

## The covering note, which is the pull-request body

    Thank you for these skills. This proposal exists because `codebase-design` did
    its job: it told me to design the interface more than once, and that is the only
    reason a second design got produced at all. Everything below touches the fan-out
    step only, and none of it touches the vocabulary.

    I reach for the fan-out step often, and three things kept needing to be added by
    hand.

    **1. An entry test in front of the fan-out.**
    Your own docs page already records what happens without one: issue 449, where an
    agent pointed at `codebase-design` "reached for the most action-shaped content it
    could find - the parallel sub-agents in DESIGN-IT-TWICE.md" and ran a long way
    before asking anything. The fan-out is the most action-shaped thing in the skill,
    and nothing in front of it asks whether this particular question is worth three
    or four full designs. The proposed gate is deliberately weak: do it twice in your
    head first, and fan out when several shapes are defensible and the answer would
    change what you ship. It is not "don't fan out".

    **2. Naming what parallel sub-agents cannot guarantee.**
    The step's value is divergence, and today the divergence comes from the differing
    constraint prompts alone. If the sub-agents inherit one harness default, all
    three designs come from one model, and three designs that agree look exactly like
    three independent designs that agree. Nothing tells the reader which one they
    got.

    I know that because I built the other case, and building it is what taught me the
    difference: for this kind of fan-out I now pin the models explicitly and refuse to
    proceed when they cannot be shown to differ. I put that refusal in precisely
    because I could not otherwise tell the two apart from the output. **That
    arrangement is mine and is not what I am proposing** - an upstream skill should
    not depend on one person's setup, and this one runs everywhere. What is proposed
    is one paragraph telling the reader which case they are in, and asking them to
    say so when they present the comparison.

    **3. Verification before the recommendation.**
    Step 3 compares the designs and recommends one, and the comparison is against the
    designs as written. A sub-agent's design is an argument, and the one that reads
    best is not reliably the deepest. The proposed check ties to two principles
    already in `SKILL.md`: run the deletion test against the real callers, and ask
    whether the second adapter exists or the seam is hypothetical.

    Also, small and separate: the docs page still answers "Does the design-it-twice
    pattern work outside Claude Code?" by quoting this file as saying "spawn 3+
    sub-agents in parallel using the Agent tool". 1.2.3 removed exactly that wording,
    so the page and issue 564 both read as if it were still there. I have left that
    correction in this PR; say the word and I will split it out.

    A changeset is included and the docs page is re-synced, per `CLAUDE.md`. If the
    gate reads too strong, I would rather weaken it than drop it.

## The exact command that would open it

Nothing below has been run.
The fork step needs an authenticated GitHub identity, and which identity is the captain's decision.

    # 1. Fork under the identity the captain names, and clone the fork.
    gh repo fork mattpocock/skills --clone=true --remote=true --fork-name=skills
    cd skills
    git checkout -b design-it-twice-entry-test

    # 2. Apply changes 1 to 5 from this page:
    #      skills/engineering/codebase-design/DESIGN-IT-TWICE.md
    #      docs/engineering/codebase-design.md
    #      .changeset/design-it-twice-entry-test.md

    # 3. Commit and push to the fork.
    git add -A
    git commit -m "codebase-design: gate the design-it-twice fan-out and name what it cannot guarantee"
    git push -u origin design-it-twice-entry-test

    # 4. Open the pull request against their default branch, with the covering note
    #    above saved to /tmp/design-it-twice-note.md.
    gh pr create --repo mattpocock/skills --base main \
      --title "codebase-design: gate the design-it-twice fan-out and name what it cannot guarantee" \
      --body-file /tmp/design-it-twice-note.md

`gh-axi` is this fleet's sanctioned GitHub route and covers `pr` and `repo`; check its current help before running the fork step, because a fork of a repository this fleet does not own is not an operation it has performed before.

## What the captain decided, and the one gate still standing

Decided 2026-08-21, recorded as `fm-codebase-design-calls-panel-decision-upstream-pr-identity-and-wording` and `fm-codebase-design-calls-panel-decision-upstream-pr-no-public-fleet-mention`:

**Channel:** a public pull request.
Settled earlier and unchanged.

**Under what identity:** an HLR account, not a personal one.
His answer on the board was `hlr-show-wording`, which is the identity and the gate in one: the account is chosen, and the wording is shown to him before anything goes out.

**The wording:** rewritten, above, so it makes no public claim that HLR operates a fleet of agent-managed repositories.
All three proposed changes are untouched, and so is the honest attribution of where the independence claim comes from; it is simply no longer sourced to a described estate.

**Two flags were deliberately not raised with him as decisions, and stay as they are.**
The note cites his own issue numbers 449 and 564 back at him, and the stale-quotation correction rides in the same pull request with an offer to split it out.

**Still open, and the only thing between this page and publication:** his read of the final text.

**Not cheaply undone:** a closed pull request stays visible, and its author stays attributed, which is why the gate is a read and not a nod.

Until he approves the text, this page is the whole contribution and it stays here.
