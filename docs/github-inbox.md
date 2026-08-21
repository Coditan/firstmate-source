# The GitHub notification watch

`bin/fm-github-inbox.sh` makes GitHub's notification feed readable by the fleet.
Its header owns the mechanics - modes, flags, state files, and environment.
This document holds the measurements the design rests on, so that the next agent to touch it changes it against evidence rather than against a guess.

## Why the fleet is the recipient at all

The fleet acts under the captain's personal GitHub identity.
Every change a worker opens is authored by him and every thread notifies him, so he is told about his own work eighteen times in two days while nothing in the fleet reads any of it.
On 2026-08-21 the feed held five unread threads, one of them a mention on a pull request this fleet had opened, sitting unread because it had been addressed to a reader who was never going to look.

A machine account per vessel is the real correction and is filed separately.
This watch makes the feed readable in the meantime, so that unwatching costs the captain nothing.

## Measurement 1: `subject.latest_comment_url` does not separate a reply from a merge

The obvious discriminator for a `reason: author` notification is its `subject.latest_comment_url`: if it differs from `subject.url`, somebody commented.
It was measured and it does not work.

```
$ gh-axi api 'notifications?per_page=100&all=false' \
    --jq '[.[] | .id + " SUBJ=" + (.subject.url//"null") + " LATEST=" + (.subject.latest_comment_url//"null")] | join("\n")'
api_response:
  body: "25181984147 SUBJ=https://api.github.com/repos/escidmore/forgejo-axi/pulls/41 LATEST=https://api.github.com/repos/escidmore/forgejo-axi/pulls/41\n25181794060 SUBJ=https://api.github.com/repos/escidmore/forgejo-axi/pulls/38 LATEST=https://api.github.com/repos/escidmore/forgejo-axi/pulls/38\n25181909772 SUBJ=https://api.github.com/repos/escidmore/forgejo-axi/pulls/40 LATEST=https://api.github.com/repos/escidmore/forgejo-axi/pulls/40\n24749801554 SUBJ=https://api.github.com/repos/kunchenguid/firstmate/pulls/962 LATEST=https://api.github.com/repos/kunchenguid/firstmate/pulls/962\n24785299524 SUBJ=https://api.github.com/repos/kunchenguid/firstmate/pulls/1096 LATEST=https://api.github.com/repos/kunchenguid/firstmate/pulls/1096"
  truncated: false
```

Every one of the five is equal, and three of those threads carry real comments from other people:

```
$ gh-axi api 'repos/escidmore/forgejo-axi/issues/38/comments?per_page=5' --jq '[.[] | .user.login + " @ " + .created_at] | join(" ; ")'
api_response:
  body: "Freudator86 @ 2026-08-19T20:33:58Z ; coderabbitai[bot] @ 2026-08-20T09:15:38Z ; escidmore @ 2026-08-20T09:33:40Z"
$ gh-axi api 'repos/kunchenguid/firstmate/issues/962/comments?per_page=5' --jq '[.[] | .user.login + " @ " + .created_at] | join(" ; ")'
api_response:
  body: "kunchenguid @ 2026-08-12T02:53:56Z"
```

A check built on that field would have called every reply a merge.
So a conditional notification is decided from the thread's own timeline instead, in one further request, which carries the actor and the timestamp of every comment, review, close, and merge:

```
$ gh-axi api 'repos/escidmore/forgejo-axi/issues/38/timeline?per_page=100' \
    --jq '[.[] | .event + ":" + ((.actor.login // .user.login // .author.name // "?")) + "@" + ((.created_at // .submitted_at // .committer.date // "-"))] | join("  ")'
api_response:
  body: "committed:coditan@2026-08-19T20:11:32Z  commented:Freudator86@2026-08-19T20:33:58Z  cross-referenced:Freudator86@2026-08-19T21:28:37Z  committed:Evelyn Scidmore@2026-08-20T09:14:54Z  commented:coderabbitai[bot]@2026-08-20T09:15:38Z  commented:escidmore@2026-08-20T09:33:40Z  mentioned:Freudator86@2026-08-20T09:33:41Z  subscribed:Freudator86@2026-08-20T09:33:41Z  merged:escidmore@2026-08-20T09:34:07Z  closed:escidmore@2026-08-20T09:34:07Z"
  truncated: false
```

Two things in that reading shaped the code.
A `committed` event carries a git author NAME (`Evelyn Scidmore`), not a login, so a push cannot be matched against this account at all and is deliberately not treated as activity.
A merge is recorded as `merged` and then `closed`, which on pull request 40 of the same repository were a second apart:

```
$ gh-axi api 'repos/escidmore/forgejo-axi/issues/40/timeline?per_page=100' --jq '...'
api_response:
  body: "committed:?@-  cross-referenced:Freudator86@2026-08-19T20:33:45Z  cross-referenced:Freudator86@2026-08-19T21:28:37Z  merged:escidmore@2026-08-20T09:02:38Z  closed:escidmore@2026-08-20T09:02:39Z"
```

Reporting the last event would have told the fleet its contribution was rejected when it was accepted, so a merge anywhere in a thread's history claims the close that follows it.
Pull request 962 has a `closed` with no `merged`, and `repos/kunchenguid/firstmate/pulls/962` confirms `merged=false state=closed`, so the distinction is real and not cosmetic.

## Measurement 2: gh-axi cuts a response body at about 4000 characters

This is the reason the feed is read in small pages and every payload is base64.
Asking gh-axi for a jq string of a known length, on 2026-08-21:

```
n=1    tokenlen=400   decoded=300   truncated: false   expected=300
n=20   tokenlen=3988  decoded=2991  truncated: true    expected=6019
n=60   tokenlen=3988  decoded=2991  truncated: true    expected=18059
n=200  tokenlen=3988  decoded=2991  truncated: true    expected=60199
```

The body stops at 3988 characters and the envelope says `truncated: true`.
A payload cut in the middle is the shape of an answer that looks complete and is not, which is why the check refuses on that flag and why the payload is base64: a cut token also fails to decode, so a half-reading has two independent ways of being caught and none of passing.

The envelope's own shape is the second reason for base64.
gh-axi renders a jq result differently depending on its type - an array of objects becomes a table, a string becomes `body:` and is YAML-quoted only when it needs to be:

```
$ gh-axi api 'notifications?per_page=1&all=false' --jq '[.[] | "\(.id) \(.reason)"] | join(";")'
api_response:
  body: 25181984147|author
$ gh-axi api 'notifications?per_page=1&all=false' --jq '[.[] | "\(.id): \(.subject.title)"] | join("\n")'
api_response:
  body: "25181984147: feat: add setup hooks for agent session integration"
```

Parsing that back out reliably is not possible for a payload carrying arbitrary pull request titles.
Base64 has no quote, colon, backslash, or newline in it, so the token can be lifted out of any envelope shape with one `grep -o`.
A marker in front of it is what separates a successful empty reading from no reading at all.

At 15 notifications per request and a title clipped to 60 characters, a page is roughly 2100 characters, well inside the cut.

## What deserves a wake

The script header owns the full table.
In short: a notification whose `reason` says somebody is addressing this fleet always wakes it; `state_change` and `subscribed` never do; `author` and `comment` are decided from the thread; and a reason this check does not recognise wakes it, naming the reason, because a gap that goes quiet is the defect the whole check exists to remove.

The steady-state cost is one request per sweep.
A thread is only read when its notification is new or has changed since the last time it was decided, so a quiet inbox costs nothing beyond the feed read.
A full pass over the five threads in the reading above took 4.4 seconds against the watcher's 30-second allowance.

## Why it is armed per home rather than by bootstrap

Several homes draining one inbox would each surface the same threads separately, so this is an opt-in: `bin/fm-github-inbox.sh --arm` on the one home that should watch.
`bin/fm-bootstrap.sh` calls `--armed`, which is silent on a home that never armed it and speaks only when a home that DID arm has stopped reading.
That way the opt-in stays an opt-in and a watch that dies is still noticed.

## What it cannot see

- Notifications the captain reads in a browser leave the unread feed, and this check never sees them.
  That is the cost of the shared identity, and the machine account is what removes it.
- One reading reaches `FM_GH_INBOX_PER_PAGE` x `FM_GH_INBOX_MAX_PAGES` unread threads.
  Beyond that the line says there are more than one reading reaches, and the next sweep resumes at the next older page.
  A short page completes the traversal and resets the next sweep to page 1.
- A thread with 100 or more timeline events is surfaced with the caveat that its history could not be read in full, because an ascending read at that size may be hiding the newest events.
- It never marks anything read, so it cannot tell GitHub what the fleet has seen.
  Its own record does that, where being wrong costs a repeat rather than a loss.

`tests/fm-github-inbox.test.sh` holds the check to the properties that would let it lie.
