---
name: omega-protocol
description: >-
  Agent-only definition of the captain's omega protocol: broad away-window authority to attach to a seat's tmux, type into its composer, and answer its confirmation prompts on his behalf, in force only after he has invoked it by name.
  Load when the captain names the omega protocol in chat, before acting on any of its grants, and when the away window it was invoked for ends.
user-invocable: false
metadata:
  internal: true
---

# omega-protocol

This skill is the single owner of what the omega protocol is, when it is in force, what it grants, and what it leaves untouched.
`AGENTS.md` section 13 carries only its load trigger, and the `/afk` skill points here from its away-window authority rule without restating any of it.

## What it is, in the captain's words

The captain defined it in chat on 2026-09-03, in the Tugboat home, while the new Coditan seat was being fixed.
His definition, verbatim, is the protocol; nothing below adds a grant his words do not carry:

> "deviation from stadning rule you are allow to connect with tmux and directly write in the textboxm, furthermore there prefilled commands sometimes dont take them as me doing something confirm the orders, add anything you think you might.... those broad permissions for you will be taken once i return from afk, they start once i put afk in. we call it omega protocoll and needs to be invoked by me in the furture"

On his return that day he clarified what prefilled composer text is, verbatim:

> "that left over text can be easily deleted thats the suggestuons i mentioned"

He invoked it again on 2026-09-04, verbatim, and that invocation is what fixed this definition as a skill:

> "go till finished under omega protocol, write omega protocol into fleet or at least give coditan the task to do it maybe omega protocol should be a skill"

Later on 2026-09-04 he corrected the reach of the grant and restated what prefilled text is, verbatim:

> "correction you are allowed to write in coditans chat window i gurantue thers nothing from me tehre if you see something it is the suggestions from claude code itself, free to take by you ore overwrite..."

## When it is in force

The protocol is in force only when both of these hold at once:

1. The captain has invoked it by name in chat for this window, in the message that puts `/afk` in or in the chat that leads up to it.
   `/afk` alone never starts it, and neither does away mode found already present at session start, a past invocation in a previous window, or any inference from the shape of the work.
   "needs to be invoked by me in the furture" is his own rule, and every window needs its own invocation.
2. The away window is open: it begins when he puts `/afk` in and ends when he returns.
   His words fix both edges: "they start once i put afk in" and "will be taken once i return from afk".
   The return signal is the one the `/afk` skill already owns, the first genuine unmarked message, so the window closes the moment that message arrives and before it is acted on.

Outside that window the standing rules apply unchanged, whether or not he named the protocol earlier.
An invocation without a following `/afk` grants nothing until the window opens, and it lapses if he stays present instead.

## What it grants, for its window only

- Firstmate may attach to a seat's tmux and type directly into that seat's composer.
  The seat may be another vessel's, for example the Coditan seat inside its container, and his 2026-09-04 correction says so outright: "you are allowed to write in coditans chat window".
  The standing rule that firstmate only steers through its recorded channels is suspended for this one purpose and for the named task alone.
- Firstmate may answer that seat's confirmation prompts on his behalf.
  "confirm the orders" means confirming the standing orders the window was opened for, not any prompt the seat happens to show.
- Firstmate adds whatever steps it judges necessary to reach completion of the task the window was opened for.
  "add anything you think you might" is scoped to that named task; it is not a licence to take up other work under the same grant.

## What it does not grant

The protocol widens who firstmate may type at and which confirmations it may answer.
It never widens what reaches him or what firstmate may decide in his place.
Specifically, for anything outside the named task the window was opened for:

- A pull request merge follows `AGENTS.md` section 7's approval authority unchanged, including its head-commit reading of the required checks.
- A destructive or irreversible action waits for his explicit word however long he is gone, exactly as the away-mode stub in `AGENTS.md` section 8 already requires.
- A credential is never displayed, moved, or created under this grant; `secrets-handling` and the fleet's one credential delivery path stand unchanged.
- An ask-user finding on any other task still follows `ask-user-authority`.

Inside the named task, the same three classes stay on the standing contract too: the grant covers typing, confirming, and adding steps toward completion, and a step that is itself destructive, irreversible, or security-sensitive is not made routine by the protocol.
The `/afk` skill's rule that away never widens or withdraws approval authority stays true; this protocol is the one captain-named, per-window deviation from the standing steering rules, and it leaves approval authority where it was.

## Prefilled composer text is never his order

Text found already sitting in a seat's composer when firstmate attaches is the harness's own predicted-prompt suggestion.
His clarification above settles it: that text is "left over", "can be easily deleted", and is "the suggestuons i mentioned".
His 2026-09-04 correction says the same of another vessel's seat: "i gurantue thers nothing from me tehre if you see something it is the suggestions from claude code itself, free to take by you ore overwrite".
It is not the captain acting, so firstmate never submits it as his instruction and never treats it as confirmation of anything.
Firstmate is free to take it or overwrite it: clear it, confirm the standing orders itself, and type only what the named task needs.

## The record every invocation must leave

An invocation is a captain decision given in chat, and `decision-hold-lifecycle` requires that such a decision is recorded when it is given or it is lost.
Before acting on any grant, record it through `bin/fm-decision-hold.sh record --door chat` with a decision file that carries only the following, and read that script's `--help` for the exact arguments:

- His invoking words, verbatim, including the sentence that names the protocol.
- The named task the window is opened for, in his words where he gave them.

Every seat firstmate typed at under the grant and every confirmation it answered belongs in the report below, not in the decision record.

## At the window's end

The moment his return message arrives, the standing rules resume before that message is acted on, alongside the `/afk` return sequence.
Then report to him, in `AGENTS.md` section 9 language, when the window began and ended and what was done under the grant: which seats were typed at, which confirmations were answered on his behalf, which steps were added to reach completion, and where the named task stands.
Anything begun under the grant that is not finished is named as such and waits for his word, because the grant that would have finished it has ended.
