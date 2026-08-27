# Reaching the captain and registered correspondent on Telegram

A firstmate home that has been given a Telegram channel can already hear the captain.
`bin/fm-tg-recv-arm.sh` arms the receiver, `config/telegram.env` holds the credential, and a locked session start emits the arm step once both exist.
Until now nothing could speak back on its own, so anything worth interrupting the captain with had to wait for him to open a session and ask.

`bin/fm-tg-send.sh` is the outbound half of that same seam.
Its own header is the authoritative description of its flags, exit codes, and mechanics; this document owns what the channel is for, what it is deliberately not for, what a sender must implement before it can carry a file, and the evidence behind the claim that it works.
It sends to the captain by default.
The registered non-captain correspondent is reached only when the caller passes `--target correspondent`.

## What it is for

Exactly the things `AGENTS.md` section 9 already says reach the captain immediately: work ready for his review, finished investigation findings, a decision the configured authority leaves to him, a real blocker or failure after the playbook is exhausted, anything destructive or irreversible, and a needed credential or login.

The channel carries a message, or one deliberately named file, and section 9 remains the only bar for whether either should interrupt him at all.
A document is a different shape of the same thing, not a lower bar for reaching him.

The registered correspondent lane is different in kind.
It exists for requirements conversation and carries no decision authority.
Messages to that lane are explicit call-site choices rather than captain notifications with a different destination.
That is why `--target correspondent` has no default, no fallback, and no authority implication.

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

**The correspondent target is not a second captain.**
It must not carry approvals, merge authority, deployment authority, ask-user answers, or away-mode return signals.
Inbound correspondent messages are emitted as typed operational input by `bin/fm-tg-recv-route.sh`, and outbound correspondent messages require the explicit `--target correspondent` flag.

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
When `--target correspondent` is requested, an absent `config/fm-tg-correspondent` is a refusal and never falls back to the captain.
The sender must also declare `correspondent` in `config/fm-tg-send.capabilities`, because an older sender that ignores target environment would otherwise report success for a message it sent to the wrong lane.

**One shape is deliberately not covered here: a sender that hangs rather than failing.**
The seam waits for it, so bounding the wire is the sender's own job, the way the fleet sender bounds its own `curl`.
A guard here would have to be a timeout, and a timeout short enough to be useful is also short enough to cut off a slow but genuine delivery and then report a message as unsent that the captain is reading.
Naming it is worth more than half-solving it.

**The caller's half of this is not discarding that exit status**, which is why the script's header says so and the `captain-surfaces` skill repeats it at the point of use.
A path that can fail quietly gets trusted while it is dead.
That is not a hypothetical: on 2026-08-11 this fleet had a monitoring hookup report healthy against a process that no longer existed, and the session went blind while every surface said it was fine.
Adding a second instance of that shape, in the channel that exists to carry the things that matter most, would be the worst possible place to add it.

## Sending a file

`--file <path>` sends exactly one file, and `--caption <text>` gives it the line the captain reads above it.
A caption is optional, because on a file send the document is the payload and an empty caption is ordinary rather than the empty message a text send refuses.
Everything else is unchanged: `--text`, `--text-file`, and a message on stdin behave exactly as they did, and a home that never passes `--file` never meets any of this.

The path is named explicitly, every time.
It is never inferred from a directory, never expanded from a pattern, and a second `--file` in one call is a usage error rather than a silent choice about which file leaves the vessel.
A directory, a path with no file at it, a file that cannot be read, and a file with nothing in it are each refused with their own reason before anything is transmitted, because "could not send that" leaves the caller guessing between a typo, a directory, and a report that turned out to be empty.

`bin/fm-pdf-finish.sh` still owns producing a PDF deliverable; this channel only carries the finished file.

## What a sender must implement to claim file support

A home teaches its sender to send files in two steps, and the first one is a promise it makes in writing.

**1. Declare it.**
Create `config/fm-tg-send.capabilities` beside the sender, listing the token `file` on its own line.
Blank lines and `#` comments are ignored, so the file can say why it is there.
Without that exact token the seam refuses every file send and runs the sender for none of them.

**2. Handle the request the seam hands over.**
On a file send the sender is launched exactly as it already is - the caption on stdin, `FM_HOME`, `FM_CONFIG_OVERRIDE`, and `FM_STATE_OVERRIDE` in its environment - with five more variables set:

| Variable | Meaning |
| --- | --- |
| `FM_TG_SEND_KIND` | `document`, the word the inbound spool's own `manifest.tsv` uses for the same thing |
| `FM_TG_SEND_PATH` | absolute, symlink-resolved path of the bytes to send |
| `FM_TG_SEND_ORIGINAL_NAME` | the name the captain should see, the inbound manifest's `original_name` |
| `FM_TG_SEND_MIME` | detected media type, or `application/octet-stream` when nothing better is known |
| `FM_TG_SEND_BYTES` | size in bytes |

They are set on a file send and removed on a text send, so a sender decides which kind of request it has by whether `FM_TG_SEND_KIND` is set, and a stale value in whatever called the seam cannot turn a message into a file.
The field names are the inbound half's rather than a second vocabulary for the same facts.
A provisioned home's receiver already spools an arriving file into its own `state/xo-comms/inbox/<id>/`, with a `manifest.tsv` recording that file's kind, media type, size, and original name; that spool is the private receiver's and nothing tracked here produces it, but what a transferred file is called in this fleet is settled there and not re-invented on the way out.
They arrive in the environment rather than on the command line for the reason the header already gives about the credential: `/proc` on a shared host makes another account's argv readable and its environment not.

Three obligations come with the declaration, and a sender that does not hold them has claimed something it does not do:

- **An unknown `FM_TG_SEND_KIND` is a refusal, never a guess.** `document` is the only kind defined today, and a sender that treats a future kind as a document sends the wrong thing under a name that said otherwise.
- **The wire's own limits are the sender's to hold.** `FM_TG_SEND_BYTES` is there so a file too large can be refused before the upload rather than discovered halfway through it; the seam deliberately hardcodes no size, because the limit belongs to whoever owns the wire.
- **Exit non-zero unless the file itself was delivered.** This is the same contract text sends already have, and it is the whole reason this channel is trusted: a sender that reports success for a caption it sent instead of the document has reintroduced exactly the defect the seam refuses.

## Why a declaration rather than asking the sender

The obvious design is to ask the sender what it can do, and it is wrong in a way worth writing down.

Asking means running it, and by the time it runs, the caption is already on its stdin.
A text-only sender asked "can you send files?" does what a text-only sender does: it sends the message it was given and reports success.
The probe would be the delivery, and the answer would arrive after the mistake.

So the question has to be answerable without starting the sender, which makes it a declaration.
A declaration can be wrong - a home can claim `file` for a sender that cannot - and that is a smaller failure than the one it replaces, because its default is refusal.
An absent declaration, an unreadable one, and one that does not list `file` are all treated identically: refused, named as file support, nothing transmitted.

**There is deliberately no fallback to sending the caption as a message.**
That fallback is the tempting one and it is the wrong one.
The caller believes a file arrived, the captain has a line of text where a document should be, and nothing anywhere says so.
This fleet spent 2026-08-13 finding four separate instances of that shape - an assurance that reports success whether or not it worked - and the channel that carries the things that matter most is the worst possible place to add a fifth.

## What must never travel this way

**This is a way for material to leave the vessel**, so it must never carry a secrets file, a credential, or a process environment.
The `secrets-handling` skill owns that boundary in full, including how to consume a secret without ever printing it; nothing here restates it.

The seam refuses exactly one path on its own: one inside the home's own `config/` directory, which is where this channel's credential lives.
**That is one named accident and not a secret scanner**, and reading it as one would be the mistake it is here to prevent.
Every other judgement about what may leave belongs to the caller.

## The pull request URL rule is enforced rather than remembered

`AGENTS.md` section 9 requires a pull request's full URL before any shorthand reference.
This script refuses a message that names a specific pull request by number and carries no `https://` URL anywhere.

The guard fires on a **specific** pull request - `PR #91`, `pull request 91`, `merge request !12` - and not on prose about pull requests in general, because refusing every sentence containing those letters would make the safe path the one people work around.
A message that carries the URL goes out with its shorthand intact, which is what the rule actually asks for.
The check runs before the home's configuration is looked at, so a composition mistake reads as a composition mistake on every home rather than as a channel problem.
A caption is recipient-facing text on the same phone, so the rule holds for it unchanged.

## Sending to the registered correspondent

The single registration file is the gitignored `config/fm-tg-correspondent`.
It carries two keys:

```
name=requirements
chat_id=<telegram-chat-id>
```

Set the real chat id there when it is known.
Do not put that value in tracked files, commit messages, pull request bodies, or test fixtures that describe real people.

The sender declares support by listing `correspondent` in `config/fm-tg-send.capabilities`.
On an explicit correspondent send, `bin/fm-tg-send.sh` exports `FM_TG_SEND_TARGET=correspondent`, `FM_TG_SEND_CORRESPONDENT_NAME`, and `FM_TG_SEND_CORRESPONDENT_CHAT_ID` for the per-home sender.
On a default captain send, it exports `FM_TG_SEND_TARGET=captain` and clears the correspondent name and chat id, so stale environment cannot retarget a routine notification.

## What a home needs before it can speak

Two captain-private files, both under `config/` and both gitignored:

- `config/telegram.env` - the credential, mode `0600`. Delivered to the host; never printed, never retyped, never committed, never quoted into a commit message, a pull request body, a test fixture, or a log line.
- `config/fm-tg-send.sh` - the executable per-home sender, the outbound sibling of `config/fm-tg-recv.sh`. It receives the message on stdin and is launched with `FM_HOME`, `FM_CONFIG_OVERRIDE`, and `FM_STATE_OVERRIDE` naming the home it speaks for.

A third file is optional and only a home that sends files needs it:

- `config/fm-tg-send.capabilities` - the sender's own declaration, listing `file` when it can send one.
  Listing `correspondent` declares that the sender honors the explicit non-captain target.
  Absent, unreadable, or silent about `file`, every file send is refused and messages are unaffected.
  Absent, unreadable, or silent about `correspondent`, every correspondent send is refused and captain messages are unaffected.

A home that has `config/fm-tg-recv.sh` and no `config/fm-tg-send.sh` is told exactly that: it can hear the captain and cannot answer him.
That sentence exists because the two halves fail in ways that look identical from a distance, and the distance is where the reader is.

**The sender is installed rather than shipped, and the one manual step that costs is the price of the file being private.**
`config/` is captain-private and gitignored in its entirety, so nothing under it can travel in this repository even if it were harmless to share - and a sender is not harmless to share, because it names the credential it consumes and the path it speaks on.
So a fresh home gets the seam by updating firstmate and gets its voice by having a sender installed into it, exactly as it already gets its receiver.
Stating that here is deliberate: a manual step nobody documented is indistinguishable from a bug, and the person who meets it will be meeting it at the moment they needed the channel to work.

## What is proved here, and what is not

Written 2026-08-11.
Read the two measurements below as two different things, because they prove different amounts.

**Proved by `tests/fm-tg-send.test.sh`, against a recording stand-in sender:**
that an unconfigured home fails rather than reporting itself inactive;
that a home missing either half is told which half;
that a home with a receiver and no sender is told it can hear and cannot answer;
that the message reaches the sender on stdin and never on its command line;
that the sender is launched against the home the seam resolved;
that a send with no explicit target stays on the captain lane and clears stale correspondent target environment;
that an explicit correspondent send refuses when no lane is registered;
that an explicit correspondent send refuses when the sender has not declared correspondent support;
that an explicit correspondent send reaches the sender with `FM_TG_SEND_TARGET=correspondent` plus the local correspondent name and chat id;
that a sender exiting non-zero is reported with its status, has its own diagnostic relayed, and is never also reported as sent;
that a message naming a pull request without its URL is refused before the sender runs at all, while the same message carrying the URL goes out;
that prose about pull requests in general is not mistaken for a bare reference;
that an empty message, an unreadable message file, and bad arguments each fail rather than sending nothing quietly;
and that no credential value appears in the script's output on either the failing or the succeeding path.

**Proved by `tests/fm-tg-recv-route.test.sh`, against normalized Telegram events from a stand-in receiver:**
that a captain chat id keeps the legacy `CAPTAIN-TELEGRAM` output and legacy inbox path;
that the registered correspondent chat id emits typed `telegram-correspondent` operational input, writes `audience=third-party` and the lane name to its own inbox, and keeps the message body out of the operational prompt;
that an unregistered chat id produces no output and writes no inbox record;
and that media events follow the same captain-vs-correspondent split.

**Proved by `tests/fm-context-reset.test.sh`:**
that a transcript containing only a Telegram correspondent operational prompt cannot satisfy the `--captain-approved` path, which refuses because no captain record exists.

**Proved by `tests/fm-daemon.test.sh`:**
that the Telegram correspondent operational prompt does not exit away mode as if the captain had returned.

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

The run above supplied the per-home sender from a relocated config directory, because `config/fm-tg-send.sh` is captain-private and the work that built the seam could not write it into the live home.

**That gap closed on 2026-08-12**, when the sender was installed at `config/fm-tg-send.sh` in this vessel's own home and three further messages reached the captain through the unrelocated path, one of which he replied to.
So the channel is now proved on the file layout a provisioned home actually has, and not only on a relocated stand-in.

**Not proved, and worth naming rather than leaving to be discovered:**
nothing here says a *different* home can speak.
Every measurement above was made on one vessel, and the sender is installed per home rather than shipped, so a fresh home is mute until someone puts one in place.
It says so when asked to send, which is the designed behaviour and not a silent failure, but a home that has never been provisioned reports nothing at all until the first time something tries to reach the captain through it.

## What is proved about sending a file

The file half was added 2026-08-13, on Linux 6.8.0-137-generic with bash 5.2.21 and git 2.43.0.

**Proved by `tests/fm-tg-send.test.sh`:**
that a sender which has not declared file support is refused, names file support as the reason, and never runs at all - and that the caption is not sent as a message in its place;
that an absent declaration, an unreadable one, and one that does not list `file` are refused identically;
that a declared sender is handed the path, the name, the size, the media type, and the caption, with the path absolute and never on its command line;
that a relative path is resolved before the sender sees it;
that a detected media type reaches the sender and a malformed one falls back to `application/octet-stream` rather than being believed;
that a file with no caption is an ordinary send rather than the empty message a text send refuses;
that a missing path, a directory, an empty file, and an unreadable file are each refused with their own reason and transmit nothing;
that a path inside the home's own `config/` is refused without printing what is in it;
that a caption naming a pull request without its URL is refused like any other message;
that a sender failing on a file is reported with its status and never also as a delivery;
that two `--file`s, a `--file` with `--text`, and a `--caption` with no file are usage errors that attempt nothing;
and that a text send removes an inherited file request from its environment rather than passing it through.

**Observed by hand against a fabricated text-only sender**, one written to print whatever reaches its stdin so that a silent fallback would be visible:

```
telegram send: a sender declares it can send files by listing "file" in config/fm-tg-send.capabilities, and this home has no such declaration.
telegram send: docs/telegram-outbound.md says what a sender must implement before it can claim it.
telegram send: FAILED - this home's sender does not support sending files
telegram send: the file was NOT sent to the captain.
```

That sender printed nothing, so it never ran, and the same home sending `--text` in the next command was delivered unchanged.
The credential refusal was observed the same way:

```
telegram send: that path is inside this home's private configuration, where the channel credential lives.
telegram send: FAILED - refusing to send telegram.env out of the vessel
telegram send: the file was NOT sent to the captain.
```

**Not proved, and this is the gap that matters:**
**no file has reached the captain's Telegram through this path.**
The wire belongs to `config/fm-tg-send.sh`, which is captain-private, installed per home, and today text-only on every home there is.
So the seam is proved to hand a correct, complete file request to a sender and to refuse every home that cannot take one, and nothing here proves an upload.
That proof is available the moment a home's sender implements the two steps above; until then this section says so rather than letting a green test suite imply otherwise.

The media type was measured on a host with no `file` command, so every observation above fell back to `application/octet-stream`; detection itself is proved against a stand-in `file` in the test suite rather than against the real one.
