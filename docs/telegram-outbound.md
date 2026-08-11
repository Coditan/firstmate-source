# Reaching the captain on Telegram

A firstmate home that has been given a Telegram channel can already hear the captain.
`bin/fm-tg-recv-arm.sh` arms the receiver, `config/telegram.env` holds the credential, and a locked session start emits the arm step once both exist.
Until now nothing could speak back on its own, so anything worth interrupting the captain with had to wait for him to open a session and ask.

`bin/fm-tg-send.sh` is the outbound half of that same seam.
Its own header is the authoritative description of its flags, exit codes, and mechanics; this document owns what the channel is for, what it is deliberately not for, and the evidence behind the claim that it works.

## What it is for

Exactly the things `AGENTS.md` section 9 already says reach the captain immediately: work ready for his review, finished investigation findings, a decision the configured authority leaves to him, a real blocker or failure after the playbook is exhausted, anything destructive or irreversible, and a needed credential or login.

**This is a delivery path and never a second definition of importance.**
That matters more than it sounds.
A notification channel that grows its own severity levels ends up with two bars for interrupting one human, and the two drift apart until nobody can say which one is in force.
Section 9 is the only bar, and this script deliberately has no `--urgent`, no severity flag, and no notion of a level.

Everything the section says about how to talk to the captain applies unchanged to anything sent here.
Messages read in outcomes rather than internal machinery, and a pull request carries its full `https://...` URL - which matters more on a phone, not less, because a bare `#91` is not something he can tap.

## What it is not for

**There is no cadence, no heartbeat, and no periodic push, and that is a decision rather than an omission.**
Sending happens on an event or not at all.
This vessel is already the fleet's largest automated writer, and a recurring notification is precisely the noise the current supervision-cost work exists to remove; `docs/supervision-cost.md` owns that argument.
A status message that arrives whether or not anything happened trains its reader to stop looking, which costs exactly the messages that mattered.

**It is also not wired into away-mode escalation**, and that is the deliberate next step rather than a gap left open by accident.
`bin/fm-supervise-daemon.sh` and the wedge alarm in `docs/wedge-alarm.md` raise alerts on the machine the fleet runs on; this channel reaches the captain wherever he is.
Connecting the two is a real change to what wakes him and when, so it is decided on its own rather than arriving as a side effect of building the path.

## Why this repository ships the seam and not the sender

The tracked script resolves and runs `config/fm-tg-send.sh`, the per-home sender, and hands it the message on stdin.
It never reads, sources, prints, or logs `config/telegram.env`.

That split is the same one the receive half already makes, and it is worth stating why it is not merely symmetry for its own sake.

**A Telegram implementation here would be a second place that puts a bot token into a URL.**
Whoever owns the wire also owns keeping the credential off `argv`, redacting it out of transport errors, and re-proving the live bot against the one this home is bound to.
Those are properties that hold only while there is exactly one implementation of them; a second copy is a second thing to get right, and it will be the one that is out of date.
Callers get one path to the wire for the same reason the sender itself keeps one function that builds a token URL.

**Firstmate is also a general template, and a bot channel is a local policy.**
Which bot, whose Telegram account it is pinned to, and how a credential reaches the host are statements about one fleet's organisation.
A firstmate home elsewhere may reach its captain by something else entirely, and the seam lets it, while a vendored Telegram client would not.

## Failing loudly, and the asymmetry that carries it

**`bin/fm-tg-send.sh` never exits 0 without a delivery.**
An unconfigured home is a failure here, exits non-zero, and says the message was not sent.

That is deliberately the opposite of `bin/fm-tg-recv-arm.sh`, which reports an unarmed home inactive and exits 0.
The two are right for the same reason rather than inconsistent with each other.
An unarmed receiver is a feature that is off, and nothing is waiting on it.
An unsent notification is a message the captain did not get, and the caller is the only one still in a position to do something about that.

So every stopping condition names itself and says the message went nowhere: no credential, no sender, an empty message, an unreadable message file, or a sender that exited non-zero.
A sender's own diagnostics flow straight through rather than being swallowed, and its exit status is passed on rather than flattened.

**One shape is deliberately not covered here: a sender that hangs rather than failing.**
The seam waits for it, so bounding the wire is the sender's own job, the way the fleet sender bounds its own `curl`.
A guard here would have to be a timeout, and a timeout short enough to be useful is also short enough to cut off a slow but genuine delivery and then report a message as unsent that the captain is reading.
Naming it is worth more than half-solving it.

**The caller's half of this is not discarding that exit status**, which is why the script's header says so and `AGENTS.md` section 9 repeats it at the point of use.
A path that can fail quietly gets trusted while it is dead.
That is not a hypothetical: on 2026-08-11 this fleet had a monitoring hookup report healthy against a process that no longer existed, and the session went blind while every surface said it was fine.
Adding a second instance of that shape, in the channel that exists to carry the things that matter most, would be the worst possible place to add it.

## The pull request URL rule is enforced rather than remembered

`AGENTS.md` section 9 requires a pull request's full URL before any shorthand reference.
This script refuses a message that names a specific pull request by number and carries no `https://` URL anywhere.

The guard fires on a **specific** pull request - `PR #91`, `pull request 91`, `merge request !12` - and not on prose about pull requests in general, because refusing every sentence containing those letters would make the safe path the one people work around.
A message that carries the URL goes out with its shorthand intact, which is what the rule actually asks for.
The check runs before the home's configuration is looked at, so a composition mistake reads as a composition mistake on every home rather than as a channel problem.

## What a home needs before it can speak

Two captain-private files, both under `config/` and both gitignored:

- `config/telegram.env` - the credential, mode `0600`. Delivered to the host; never printed, never retyped, never committed, never quoted into a commit message, a pull request body, a test fixture, or a log line.
- `config/fm-tg-send.sh` - the executable per-home sender, the outbound sibling of `config/fm-tg-recv.sh`. It receives the message on stdin and is launched with `FM_HOME`, `FM_CONFIG_OVERRIDE`, and `FM_STATE_OVERRIDE` naming the home it speaks for.

A home that has `config/fm-tg-recv.sh` and no `config/fm-tg-send.sh` is told exactly that: it can hear the captain and cannot answer him.
That sentence exists because the two halves fail in ways that look identical from a distance, and the distance is where the reader is.

## What is proved here, and what is not

Written 2026-08-11.
Read the two measurements below as two different things, because they prove different amounts.

**Proved by `tests/fm-tg-send.test.sh`, against a recording stand-in sender:**
that an unconfigured home fails rather than reporting itself inactive;
that a home missing either half is told which half;
that a home with a receiver and no sender is told it can hear and cannot answer;
that the message reaches the sender on stdin and never on its command line;
that the sender is launched against the home the seam resolved;
that a sender exiting non-zero is reported with its status, has its own diagnostic relayed, and is never also reported as sent;
that a message naming a pull request without its URL is refused before the sender runs at all, while the same message carrying the URL goes out;
that prose about pull requests in general is not mistaken for a bare reference;
that an empty message, an unreadable message file, and bad arguments each fail rather than sending nothing quietly;
and that no credential value appears in the script's output on either the failing or the succeeding path.

**Proved against the real Telegram service, on the `coditan` vessel, on 2026-08-11**, on Linux 6.8.0-137-generic with bash 5.2.21, curl 8.5.0, git 2.43.0.

A message sent through `bin/fm-tg-send.sh` **arrived in the captain's Telegram**.
The vessel's own journal was then asked about it independently:

```
verify: R-9d2ab3ca was sent by this vessel at 2026-08-11T22:42:38Z, band notify.
```

The same run first exercised the refusal, and nothing went out for it:

```
telegram send: the message names a pull request by number and carries no https:// URL.
telegram send: FAILED - AGENTS.md section 9 requires the full URL before any shorthand reference
telegram send: the message was NOT sent to the captain.
```

The credential was verified by effect only.
It was never read, printed, or copied: the run reached it through a second hard link to the same file, so the value stayed in one place at mode `0600`, and that link was removed afterwards.

**Not proved, and it is worth naming rather than leaving to be discovered:**
the run above supplied the per-home sender from a relocated config directory, because `config/fm-tg-send.sh` is captain-private and this work could not write it into the live home.
So what is proved is the seam driving a real sender to a real delivery, and what is not is that the live home's own `config/fm-tg-send.sh` exists yet.
Until that file is installed, `bin/fm-tg-send.sh` on this vessel refuses and says the sender is missing - which is the designed behaviour and not a silent failure, but it is a home that cannot speak until someone puts the sender in place.
