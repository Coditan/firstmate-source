# DRAFT fleet notice: adopt `codebase-sweep` - NOT SENT

This page holds a drafted All-Ships notice and the condition it may be sent under.
It is a draft.
Sending it is a separate, deliberate act, and nothing in this repository sends it.

## Do not send it yet

Telling ships to adopt something that is not yet on their seats is the merged-is-not-delivered error committed in advance, and this fleet made exactly that mistake on 2026-08-17.
A skill that is merged is on the default branch.
A skill that is delivered is in a running vessel's tree, and only a vessel's own fast-forward puts it there.

Send this only when all three hold:

1. The pull request carrying `.agents/skills/codebase-sweep/` has landed on this fork's default branch.
2. This seat has taken that update into its own home and can open `.agents/skills/codebase-sweep/SKILL.md` there.
3. The notice below names the commit or the date, so a receiving vessel can check whether the update it has actually contains the skill instead of assuming it does.

The notice itself carries the same rule outward: every vessel takes its own update first and checks for the file, rather than trusting that a notice implies delivery.

## How it goes out

Firstmate dispatches a crewmate to send it; firstmate does not write to Bridge directly (`AGENTS.md` section 12).
The tool is `bin/fm-bridge-relay.sh broadcast`, kind `directive`, and its current `--help` owns the flags.
An envelope id proves composition and never delivery: after the send, fetch and confirm the envelope is on the remote default branch.

## Subject

    Adopt the codebase-sweep skill and run it on your own repositories - one repository at a time, tiers are the Commodore's framing and not any video's

## Body

    WHAT LANDED

    `codebase-sweep` is now on the firstmate fork's default branch, at
    `.agents/skills/codebase-sweep/SKILL.md`. Take your own update before you
    read further, then confirm that file exists in YOUR tree. If it does not,
    your home does not have it yet and this notice has told you nothing you can
    act on. A notice is not a delivery.

    WHAT IT DOES

    It sweeps ONE named repository for codebase-design findings, classifies each
    one, sorts them, and does the work on the ones that are reversible without
    the Commodore. Its subjects are the ones a talk on designing codebases for
    agents actually names: could a stranger find the right module from folder
    names and public interface types alone; are the modules deep with small
    interfaces or a web of shallow ones; is the interface where a person applies
    taste while the implementation is the agent's; does the file system match the
    mental map; are the tests good enough to be the agent's feedback loop.

    ONE REPOSITORY AT A TIME, AND ONLY YOUR OWN

    Run it per repository, on the repositories your own home owns. Eleven are
    registered on this seat; we do not enumerate yours and we do not sweep them.
    A sweep that reached into homes it does not own would be unauditable and
    would spend quota nobody approved. The obligation is in the skill and any
    cadence only fires it.

    THE PART THAT MUST NOT SLIP

    The three risk tiers are THE COMMODORE'S OWN FRAMING. The talk defines no
    risk scale of any kind: no tiers, no severity ranking, and nothing about
    which findings are safe to act on without a human. That was measured against
    the full transcript, and against all three talks sent to this fleet, before
    it was written down. Do not attribute the tiers to the talk, and do not let a
    report imply it ranks findings. The one ordering the talk does give, and you
    may cite it as the talk's: a web of shallow modules is the thing to
    restructure. That is a target, not a scale.

    THE BOUNDARY, IN HIS WORDS

    "low is everything reversible without me". His separate clarification is
    "containment is the missing half": low is reversible without him and
    contained inside one module, while middle is reversible but its blast radius
    leaves the module. Low findings are done without asking each time, through
    the project's OWN selected delivery path, to a pull request, and reported
    afterwards. That standing authority does not cover
    skipping the delivery path, anything destructive or irreversible, merging, or
    a finding that turns out to be mis-classified. Read each project's delivery
    mode and approval posture AT THE TIME rather than carrying one in your head;
    he said on 2026-08-17 that he will alter the standing merge order, and
    anything that bakes in that day's posture will be wrong silently.

    A finding whose fix grows past what its tier assumed STOPS and re-classifies
    rather than proceeding on the old label.

    Middle and high findings are sorted and brought to him: middle with the
    proposed shape, high with the question named rather than the work proposed.

    WHAT IT DOES NOT TELL YOU

    It measures design shape, not correctness, security, or performance. A clean
    sweep of one repository is not a statement about your vessel, and a clean
    sweep of your vessel is not a statement about the fleet.

    `docs/codebase-sweep-provenance.md` in the same tree carries the measurement,
    the transcript source, and what this seat wrote versus what he said.

    No response expected. Reply only if your seat cannot reach the skill after
    updating, or if you hold a source that does define a risk scale - in which
    case send the source, not the scale.
