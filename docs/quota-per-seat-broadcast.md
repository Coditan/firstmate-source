# DRAFT All-Ships notice: quota is per-seat - NOT SENT

This page carries the All-Ships notice for the quota-reporting rule in `AGENTS.md` section 3.
It is a delivery copy, not a second owner of the rule.
Sending it is a separate dispatched act, and nothing in this repository sends it.

## Do not send it yet

Send this notice only after the change carrying the `AGENTS.md` rule has landed on the pin source's default branch.
The notice and the rule travel in the same branch so neither can land without the other.
A receiving vessel still has to take its own update before the rule is present in its running instructions.

## How it goes out

Firstmate dispatches a crewmate to send it; firstmate does not write to Bridge directly (`AGENTS.md` section 12).
The tool is `bin/fm-bridge-relay.sh broadcast`, the kind is `directive`, and its current `--help` owns the flags.
Use normal priority and request a response, because every receiving seat is being asked for its own reading.
An envelope id proves composition and never delivery: after the send, fetch and confirm the envelope is on the remote default branch.

## Subject

    Measure and report your own quota before exhaustion makes your seat silent

## Body

    QUOTA IS A SEAT READING, NOT A FLEET READING

    This fleet's vessels are not all on the same Claude account. A quota reading
    taken on one seat therefore says nothing about another seat, even when both
    accounts are on the same plan.

    Take your own reading now and report only what your seat can measure. Name
    the provider and window, the remaining allowance, the projected exhaustion
    time, and the reset time. If your seat cannot take the reading, report that
    it is unable to read instead of reporting healthy headroom.

    If your projection reaches exhaustion before the reset, announce that now,
    while your seat can still speak. Do not wait for the hard stop: silence from
    an exhausted seat is indistinguishable from a dead or unreachable one, and
    the fleet needs the warning in time to route work elsewhere.

    Do not copy the sender's figures into your reply and do not infer any other
    vessel's quota from your own. Each seat reports its own measurement.

    The standing rule is in `AGENTS.md` section 3, "Quota reporting". Take the
    firstmate update that contains it before treating this notice as delivered
    instruction.
