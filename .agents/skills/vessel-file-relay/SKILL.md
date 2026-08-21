---
name: vessel-file-relay
description: >-
  Agent-only procedure for moving an ordinary file from the captain's own machine onto a fleet vessel's host and telling that vessel about it.
  Use whenever the captain hands over a local file path and asks that it be sent to, or made available to, a vessel.
  Covers the direct push and its destination convention, size verification, the Bridge notice that describes what landed, the transfer pitfalls that survive a clean exit status, and the Auto Mode classifier refusal.
  A secret or credential is not this skill's file: it travels the fleet's one credential delivery path, and section 2 says how to hand it over.
user-invocable: false
metadata:
  internal: true
---

# vessel-file-relay

Bridge carries markdown and JSON, and it cannot carry a file's bytes.
So a file never travels through Bridge.
It is pushed directly onto the target vessel's own host over SSH, verified there, and then described to that vessel in a Bridge notice.
Those are two separate acts, and the notice is only ever a description of something that already landed.

This skill covers ordinary files.
A secret or credential is a different job with a different owner, and section 2 hands it over rather than describing a second way to move it.

## 1. Pushing an ordinary file

**Push over SSH, never through Bridge.**
Use `scp` or `sftp` from the local path to the target vessel's host, reached through the SSH config entries already set up for known vessels such as `hlr` and `tugboat`.
In a WSL session the captain's own files live on his Windows machine, so the local path is typically under `/mnt/c/...`.

**Find the destination convention before inventing one.**
Look on the target host for a directory that already holds this class of file.
A relay on 2026-08-20 found `/opt/docs/` already present on `hlr-web-1` and reused it, rather than creating a second place documents live.
If no convention is visible, ask the target vessel over Bridge where it wants the file.
Guessing a path is not a neutral default: it creates a second source of truth that nobody later knows to look in.

**Verify by size, not by exit status.**
Compare the byte size of the local file against the remote copy with `ls -la` on both sides.
A clean `scp` exit status is not evidence the right bytes arrived, and a truncated or wrong-source copy exits clean.

**Then notify over Bridge.**
Send `kind: status`, or `kind: reply` if this answers a request that vessel made.
Name the exact filename, its size, and the exact path it landed at.
Never attach or embed the file's bytes in the envelope.

**A direct push supersedes a pending question about where to send it.**
If the recipient was asked where to put something, and the captain then says to push it directly instead of waiting, that answer is moot.
Push it and tell them where it landed.
Do not hold the file waiting on a reply the captain has already overtaken.

### Two pitfalls that survive a clean exit status

Both were measured on real transfers, and both look like success at every step.

**Content captured from the Windows clipboard arrives CRLF-terminated.**
`powershell.exe -Command 'Get-Clipboard -Raw'` returns Windows line endings, so whatever is written on the far end ends in a carriage return that nothing downstream expects.
Pipe the capture through `tr -d '\r'` in the same call that consumes it.
A trailing carriage return is an invisible byte that survives every check that does not look for it, so check for it directly with `grep -q $'\r' <path>`, where a match is the failure.

**The clipboard hop is the weak link in any transfer that uses it, and it has failed twice in two different ways.**
On 2026-08-20 it captured the wrong content entirely, because the captain's clipboard held something else at that moment.
On the Backblaze handoff it captured the right content with the wrong line endings.
Both times every command in the chain exited clean.
Treat clipboard-sourced content as unverified until something structural - size, line count, expected field labels, absence of carriage returns - has confirmed it.

**A single downstream refusal is never proof the transferred content itself is wrong.**
On the Backblaze handoff the receiving vessel's first authenticated call returned 401, and the credential was correct.
The file was CRLF-terminated, so the parsed value carried a trailing carriage return, and the API rejected it with the same status and the same body it returns for a genuinely wrong value.
Nothing in the response distinguishes the two cases, so the response alone cannot be the evidence.
When a first attempt is refused, check the delivered bytes before concluding anything about the content.
Asking the captain to re-issue or re-send something that was never wrong costs him a rotation and leaves the real defect in place.

## 2. A secret or credential: hand it to the delivery path, do not relay it

**Do not move a secret with the procedure in section 1, and do not stage one on a vessel yourself.**
`fleet/doctrine/credential-handover.md` in the fleet repository makes Tugboat the fleet's one credential delivery path, and that is a default rather than a fallback.
Transfer runs through `tugboat-secret-push.ps1`, which decrypts from the Captain DPAPI store on Timbook in-process and pushes the value to the target vessel.
The value is never written to an intermediate file, never pasted into a chat, and never retyped at the far end.

That one path exists precisely so it stays exercised.
A vessel does not get its own arrangement because its situation looks simple, and an improvised SSH push that stages a secret into a file on the target is exactly the special case the doctrine names as where the mistake will live.
It also reintroduces the intermediate file the delivery path was built to avoid.

So when the captain hands over a secret to get onto a vessel:

- **Ask first whether it has to travel at all.**
  The doctrine prefers generating on the target over transporting to it, and the 2026-07-29 relay key generated locally on `crew-hlr` is the fleet's worked example.
  A secret that never moves cannot be intercepted in transit.
- **Otherwise route it to Tugboat** rather than carrying it, and say plainly to the captain that this is the fleet's delivery path rather than a refusal to help.
- **Never write a doctrine exception for the vessel in front of you.**
  `fleet/doctrine/credential-store-boundary.md` in the fleet repository, section 4, owns what would authorise store access and where it has to be written, and neither proximity nor a temporary role is it.

Two invariants bind whatever happens next, and nothing here relaxes either.
`AGENTS.md` section 1 "Secrets" and the `secrets-handling` skill own keeping a value out of any transcript, output stream, or command line.
No secret value ever passes through the shared Bridge repository: every vessel pulls it, it has no per-audience access control, and anything committed sits in its history permanently.
Bridge may name a credential, say which vessel needs it, and carry a fingerprint that lets both sides confirm they mean the same thing, using the dedicated `secret-request` and `secret-ready` envelope kinds whose `body_md` the CLI structurally refuses to fill.
It may never carry the value or any part of it.
`fleet/doctrine/credential-store-boundary.md` sections 6 and 7 own those envelope fields and the fingerprint recipe.
Read all of these in the fleet repository itself; `docs/admiralty-fleet-repo.md` says where that repository is and what it owns.

## 3. Expected obstacle: Claude Code's Auto Mode classifier

A push whose content looks secret-shaped can be refused outright by Claude Code's Auto Mode semantic safety classifier, even when the file is an ordinary one the captain asked for.
Recognise this immediately rather than treating it as a hard blocker.

Three facts about it, all measured on 2026-08-20 when it refused the same step twice:

- **Explicit chat approval from the captain does not clear it.**
  Neither does an existing broad `Bash(ssh *)` rule in `permissions.allow`.
  The classifier is a distinct layer from ordinary Bash permission rules and is not satisfied by them.
- **The agent cannot edit `.claude/settings.local.json` to add the documented `autoMode.allow` override.**
  That edit is blocked by the same classifier, and that is correct.
  An agent must not be able to grant itself expanded secret-handling permission.
  Do not look for a way around this.
- **The only way through is the captain's own mode switch.**
  He takes the session out of Auto Mode with Shift+Tab or `/permissions`, into manual or default mode, so the action reaches him as a direct approval prompt instead of the classifier's silent judgement.

So when it fires, check first whether what it stopped was in fact a secret.
If it was, the classifier was right, section 2 is the answer, and no mode switch is asked for.
That order is the one that holds: the prompt exists to stop exactly that case, so an agent that asks for it to be lowered before looking has already skipped the safeguard it was asked to clear.
Only once the content is confirmed to be an ordinary file: say what happened, say that chat approval alone does not lift it, ask the captain to switch the session out of Auto Mode, and then retry the same command unchanged.
