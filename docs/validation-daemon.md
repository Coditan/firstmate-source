# The validation pipeline daemon check

`bin/fm-bootstrap.sh`'s `VALIDATION_DAEMON:` line, why it exists, what it measures, and why it reports rather than repairs.
The line formats themselves are owned by that script's header, and the handling procedure by the `bootstrap-diagnostics` skill; this file owns the measurements and the reasoning both of those rest on.

## The incident

Measured on the coditan vessel, 2026-08-30.
The seat restarted.
It killed every crewmate, which was visible - each pane sat at a bare shell prompt - and it killed the no-mistakes daemon, which was visible nowhere:

```
connect to daemon socket: dial unix /home/coditan/.no-mistakes/socket: connect: connection refused
recorded pid 3223240 no longer exists
```

No status line, no session-start diagnostic, no wake, and no failing command.
Four parked runs were unanswerable for about forty minutes.
It surfaced only when a relaunched worker tried to answer its own review gate and got that refusal back.

The repair was `no-mistakes daemon start`, which brought the daemon back as pid 1727379.
All four parked runs survived the outage and were listed again immediately.

## The property that makes this a check rather than a habit

Nothing on a seat touches the daemon until something needs it.
A seat with no gate work in flight therefore carries a dead daemon indefinitely and reads perfectly healthy on every surface it has.
Absence of complaint is not evidence of life, and that is the one thing a startup reading fixes and no amount of care does.

## What the CLI actually answers

Measured against `no-mistakes version v1.48.0 (2ac3769)` on 2026-08-30.

```
$ no-mistakes daemon status
  ● daemon running (pid 1727379)
$ echo $?
0

$ TMPD=$(mktemp -d); HOME="$TMPD" no-mistakes daemon status
  ○ daemon not running
$ echo $?
0
```

Both states exit 0, including the stale-pid case: a `daemon.pid` recording a process that no longer exists also answers `○ daemon not running` with exit 0.
So the check reads the ANSWER, not the exit status.
An exit status would report every dead daemon as healthy, which is the defect this check exists to remove.

Anything that is neither answer is treated as an unreadable instrument rather than as a verdict.
This fleet does not own `no-mistakes`, so its output can change under us, and both guesses are worse than saying so: guessing healthy hides a dead daemon, and guessing dead sends a reader to restart a live one.

The two verdicts are not matched with equal looseness, because their wrong answers do not cost the same.
A wrong `unestablished` costs one line the reader can act on, while a wrong healthy is SILENCE, which is the original defect restated.
So the healthy arm is anchored on the affirmative shape actually measured, `daemon running (pid`, and any answer carrying `not running` or `no daemon running` is barred from it outright before that anchor is tried.
Both halves are load-bearing against a rewording rather than one: `no daemon running` reports a daemon that is DOWN while carrying `daemon running` as a substring, and a stale-pid phrasing of it such as `no daemon running (pid 3223240 no longer exists)` carries `daemon running (pid` as well, so the anchor alone would read the incident's own shape as healthy.
Every current answer still costs no line, and a future rewording of either verdict lands in `unestablished` rather than in a false all-clear.

## An uninstalled CLI and an unusable one are not the same case

A `no-mistakes` that is not installed at all is left silent here on purpose.
`MISSING: no-mistakes` already owns absence, its repair is to install the tool rather than to start a daemon, and there is no reading to take from a tool that is not there.

A CLI that IS installed but whose version does not clear the floor this fleet requires is the opposite case, and it does print.
It cannot be asked, so the check has taken no reading, and staying silent about an instrument that cannot read is exactly the all-clear this whole check exists to remove.

That path covers two different readings, and the line says which one it took, because `no_mistakes_compatible` fails for reasons that are not the same fact.
`below the version floor this fleet requires` is the case where a version WAS read and it is too old.
`answered with no version this check could read` is the case where `no-mistakes --version` exited non-zero or printed a banner no major.minor.patch could be parsed out of, so no version was established at all.
Collapsing the second into the first would tell a reader on the newest release that their CLI is out of date, which is a version reading the check never took, and reporting a reading it did not take is the one thing this check is built not to do.
What changes on that path is the repair rather than the verdict: `no-mistakes daemon status` and `no-mistakes daemon start` cannot succeed until the upgrade lands, and a diagnostic that prescribes a command the reader cannot run is the defect the 2026-08-24 ruling names.
So the below-floor line names the upgrade instead, using the same install command `MISSING: no-mistakes` already prints.
That command is the installer script, not `no-mistakes update`, so naming it does not reopen the path the next section bars; the line keeps that warning too.

## Why the repair is never `no-mistakes update`

`no-mistakes update` resets the daemon as part of upgrading the tool.
On this seat at the time of the incident that would have carried 1.48.0 to 1.60.2 as a side effect of a repair, with four parked runs sitting inside the old version.
A repair must not smuggle a version change into parked work.
Every line this check prints names `no-mistakes daemon start` and explicitly forbids the update path, because a reader who meets only the first has no way to know the second is not an equivalent.

## Why it detects and does not start

There is real precedent for auto-repair in the same script: bootstrap arms this home's daily currency round and its memory alarm, and only when the session actually holds the fleet lock.
That precedent does not carry here, and the reason is the resource rather than the appetite.

The daemon is per-ACCOUNT, not per-home.
Its socket is `$HOME/.no-mistakes/socket` - derived from `HOME`, which is the installer's own contract that `bin/fm-nm-path-lib.sh` records, and confirmed by measurement: running the CLI under a temporary `HOME` created that directory under the temporary one and answered about a daemon that was not there, while the real daemon kept running untouched.
So one daemon serves every firstmate home and every secondmate on the account, and `FM_HOME` does not separate them.

The sharper measurement is not this seat's, and is recorded as such below: the daemon process carries no home identity in its environment at all.
It was never told homes exist, so it cannot attribute a request to one, and no home can ask it which other homes are behind it.

The lock that guards bootstrap's other mutating steps is per-home.
A per-home lock cannot serialize an account-wide mutation: two homes can hold their own locks at the same moment and both decide to act, and a home holding its own lock has established nothing at all about its siblings.
No bootstrap step can acquire the authority this action would need, because it cannot enumerate the homes the action would reach.
`no-mistakes daemon start` is documented as "Install or refresh the managed daemon service and start it", and a refresh landing on a daemon another home started a second earlier is a restart, which kills every in-flight run on the account - the outcome `AGENTS.md` and every crewmate brief already forbid.
The reading cannot be made atomic with the action with any lock this fleet has.

The decisive argument is narrower than that, and it is the one that also rules out the smallest possible autonomy.
Start only when the daemon is provably absent looks safe, because a process that does not exist holds no parked state.
But provably absent is exactly the reading a wedged socket gets wrong: a wedged-but-alive daemon holding parked runs does not answer, and an auto-start on not-answering would start a second process against the same root - a worse state than the one being repaired, reached automatically, at session start, with nobody watching.
The escalation from "not answering" to a start is the whole hazard, so this check does not make it.

So the action goes to the reader, who can see whether anything is running before taking it.
This satisfies the captain's 2026-08-24 ruling that a standing diagnostic reaching a reader who cannot act on it is a defect whatever it measures: the fix is either to fire only where somebody owns it or to attach the action, and here the action is attached - the line carries the exact repair command and the exact command to avoid.
A lock-refused read-only session reads the same line and can act on it identically, because taking the reading mutates nothing.

## The sibling-home measurement, and whose it is

Taken by a peer seat (sc1) on 2026-08-30, on a machine that has two firstmate homes on one Linux account.
This seat runs one home per account and cannot reproduce it, so the reading is recorded here with its owner rather than restated as local evidence.

```
ps -o pid,user,etime,cmd -p 500
  500 captain 21:38:18 /home/captain/.no-mistakes/bin/no-mistakes daemon run --root /home/captain/.no-mistakes

tr '\0' '\n' < /proc/500/environ | grep -E '^(HOME|USER|FM_HOME)='
  HOME=/home/captain
  USER=captain
  (no FM_HOME at all)

two homes on that account: /home/captain/firstmate-upstream and /home/captain/sc1-firstmate
```

Its bounds, which stand: one machine, one account, two homes, one day, and that seat parks no gates, so it has no reading on what a start or a restart does to LIVE parked runs.
The only evidence this fleet has on that is the incident above, where a start against a genuinely dead daemon left all four parked runs intact.

Two consequences this check is built around.

**Reporting is safe from every home; acting is not.**
Reporting is idempotent and cheap, and every home behind the socket genuinely is impaired when the daemon is down, so N homes each printing the line is a duplicate line rather than a hazard.
That is deliberately unlike `GITHUB_INBOX`, where arming was made a per-home decision so several homes would not each surface the same unread threads: an unread thread is one fleet-level fact reported redundantly, while a dead daemon is a real and separate impairment of every home sharing it.
Duplication is the honest answer here, so this check is armed nowhere and reports everywhere.

**The number of homes behind one socket is not fixed and not knowable from inside any of them.**
So the line names the account it is talking about and never a count of homes, because a count is a reading it cannot take.

## Bounds

The call is bounded by `timeout` (or `gtimeout`), default 5s, overridable with `FM_VALIDATION_DAEMON_TIMEOUT`.
A wedged daemon - one whose process is alive and whose socket never answers - must not stall the startup digest, and a timeout is reported rather than swallowed: a reading that could not be taken is reported as unable to read, never as healthy.
A seat with neither bounding command reports that it could not take the reading rather than asking unbounded, because asking unbounded would hang every session start on that seat behind a wedged daemon.

## What this check does not cover

It answers one question: whether the account's daemon is answering right now, at session start.
It does not watch between sessions, so a daemon that dies mid-session is still discovered by the next session start or by a worker meeting a refused socket.
It says nothing about the health of any individual parked run, about the daemon's version, or about whether the runs inside it are the ones this home expects.
It is also not a report on crewmate liveness: the same seat restart killed every crewmate, and that is a separate condition with separate handling.

## Test-only variables

`FM_VALIDATION_DAEMON_CHECK_DISABLE=1` silences the check.
`tests/lib.sh` sets it suite-wide, because every behavior fixture runs with a fake `no-mistakes` whose daemon answer is invented, and `tests/fm-validation-daemon-check.test.sh` sets it back to 0 and drives every answer shape from its own fake.
`FM_VALIDATION_DAEMON_FORCE_UNBOUNDED=1` makes the check behave as it would on a seat with no bounding command, so that branch is exercised on a machine that has one.
