# Which vessel is this session

A vessel can be moved - onto another host, into a container - while its original seat is deliberately left intact, because the original is the way back (`.agents/skills/move-vessel/SKILL.md`, "The way back is the original").
Two seats then exist for one home, and attaching to the wrong one looks exactly like attaching to the right one: same prompt, same panes, same scrollback.
Set that beside a seat whose wake never arrives, and the two failures produce the same silence.
Nothing on the screen said which vessel the terminal was pointed at, so `bin/fm-vessel-identity.sh` puts that on the session's own status bar and `bin/fm-session-start.sh` stamps it once per session.

This document owns what the label means, what it is measured to show, and what it cannot show.
The script's own header owns the mechanics.

## What a person sees

The status bar carries the vessel label from the first frame after an attach, with no command run and nothing to remember:

```
 vessel coditan-firstmate@hlr-web-1 | coditan | since Aug 23 21:10 0:firstmate*   "hlr-web-1" 21:13 23-Aug-26
```

Three facts, in order: which home on which host, the tmux session name the person typed to get here, and when this session started.
The digest states the same label in text at the head of every session start:

```
VESSEL: coditan-firstmate@hlr-web-1 (status bar armed)
```

## Where the identity comes from

From the home the session is actually operating on: `$FM_HOME` when the session carries one, otherwise the code root.
That is the same resolution every other firstmate script in the session already uses to find `state/`, `data/`, and `config/`, so the label cannot disagree with the session's own behaviour.
A session driving the wrong home is labelled with the wrong home, which is the reading you want.

Nothing here reads a hand-written name.
`config/bridge-vessel` holds a fleet-facing name and is deliberately not consulted: a label that can be edited into disagreement with reality answers confidently and wrongly, which is the defect this mechanism exists to remove one level up.

The host half is `uname -n`, the name the seat reports for itself.
A container reports its own, which is what separates a moved seat from the seat left behind.

## What it shows when the vessel has moved and the old seat is still running

This is the case the mechanism exists for, so it is stated rather than assumed.

The old seat keeps running and keeps its own true label: its home path on its host.
The moved seat carries the same home path on a different host.
The two labels therefore differ in the host half, and the person attaching can tell them apart.

The label never claims to be the live vessel.
It answers "which home on which host is this session driving", and it answers nothing about whether that vessel can be woken.
No probe of the seat, the delivery listener, the watcher, or the session lock happens here, by design: the brief that produced this mechanism scoped it to identity display and left attach-time health checking out.

Three limits are real and are not designed away.

- **Same home path and same reported host name on both sides renders an identical label.**
  A container given the host's own name, or a second seat on the same host, cannot be separated by this mechanism.
  Only the session name and the start time beside the label differ, and neither is a verdict.
  The remedy is on the receiving side: give the destination a distinct host name.
- **The label is stamped when the session starts.**
  A home moved or renamed underneath a running session keeps the name it started with.
  The session's start time is immutable, so stamping it is exactly as truthful as reading it live.
- **Two homes whose basenames collide on one host render one name.**
  `/home/a/firstmate` and `/home/b/firstmate` both read `firstmate@<host>`.
  The full path is one `bin/fm-vessel-identity.sh --long` away, and the digest line names it at session start.
- **The status bar is a tmux session option, so it names one home per tmux session.**
  A seat normally owns its own tmux session, and its worker windows join that same one (`bin/backends/tmux.sh`), so one label is the right number.
  Two seats for two different homes opened as windows of ONE tmux session would share one bar, and it would wear the name of whichever seat started last.
  The digest's `VESSEL:` line stays correct for each seat in that case, because it is printed into that seat's own output rather than onto a shared surface.

## Surface

tmux only, and deliberately.
A vessel's seat and its worker windows live in one tmux session (`bin/backends/tmux.sh`), whose status bar is on screen from the first frame after an attach.
A seat on another session provider - zellij, cmux, herdr, orca - is told `not-tmux` and gets no stamp rather than being silently skipped; those providers have their own name surfaces and none of them is this one.
The digest line still names the vessel on every provider, because it is plain text in the session-start output.

`FM_VESSEL_IDENTITY_DISABLE=1` suppresses the stamp and says so, in the arm output and in the digest.
`tests/lib.sh` sets it for the whole suite, because a test composing `bin/fm-session-start.sh` runs inside the operator's own terminal and the stamp is a write onto the session that terminal is attached to.

## Evidence

Measured 2026-08-23 on `hlr-web-1`, tmux 3.4, against a private tmux server so no live seat was touched.
Two seats were created on one server from one code root, differing only in `FM_HOME`, then attached one at a time through a nested tmux client and the whole rendered screen captured.

```
$ tmux -L $INNER new-session -d -s coditan -c /tmp/fmvi-demo/coditan-firstmate \
    -e FM_HOME=/tmp/fmvi-demo/coditan-firstmate bash --norc --noprofile
$ tmux -L $INNER new-session -d -s relief  -c /tmp/fmvi-demo/relief-firstmate \
    -e FM_HOME=/tmp/fmvi-demo/relief-firstmate  bash --norc --noprofile
$ # ... bin/fm-vessel-identity.sh --arm-tmux run inside each ...
$ tmux -L $OUTER capture-pane -p -t view | tail -1     # after: tmux attach -t <name>

tmux attach -t coditan         |  vessel coditan-firstmate@hlr-web-1 | coditan | since Aug 23 21:10 0:firstmate*   "hlr-web-1" 21:13 23-Aug-26
tmux attach -t relief          |  vessel relief-firstmate@hlr-web-1 | relief | since Aug 23 21:10 0:firstmate*     "hlr-web-1" 21:13 23-Aug-26
tmux attach -t coditan-moved   |  vessel coditan-firstmate@hlr-web-1 | coditan-moved | since Aug 23 21:12 0:firstmate*   "hlr-web-1" 21:13 23-Aug-26
```

The first two lines are the different-home reading: same code root, same host, different `FM_HOME`, different name on the bar.
The third is the collision case rendered on purpose: `coditan-moved` is a second seat on the SAME home and the SAME host as `coditan`, and its vessel label is identical.
Only the session name and the start time separate them, which is the first limit above, measured rather than argued.

### The host half was not measured against a second host

This seat could not produce one.
`unshare -Ur --uts` is refused here (`write failed /proc/self/uid_map: Operation not permitted`) and the Docker socket is not readable by this account (`permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`).
So the host half is established by construction - it is `uname -n`, read at label time - and by an instrument test that shims `uname` and asserts the label follows it (`tests/fm-vessel-identity.test.sh`, `test_host_component_is_the_reported_host_name`).
It is **not** established by observing two real hosts render two labels.
That reading is unmeasured, and the first real container cutover is where it gets taken.

### tmux 3.4 renders `#{t/f/<strftime>:<variable>}` as the current clock

The bar's start time is read once with `#{t:session_created}` and stamped, rather than left as a live tmux time format, because the live format is wrong here.
tmux's documented per-variable strftime modifier returns the current clock for the named variable, measured 2026-08-23 against tmux 3.4 on a session created at 21:10:55 while the wall clock read 21:12:41:

```
$ tmux display-message -p -t coditan '#{t:session_created}'
Sun Aug 23 21:10:55 2026
$ tmux display-message -p -t coditan '#{t/f/%H#:%M:session_created}'
21:12
$ tmux display-message -p -t coditan '#{t/f/%s:session_created}'
1787519574          # = 21:12:54, i.e. now
$ tmux display-message -p -t coditan '#{t/f/%H-%M:window_activity}'
21-12               # window_activity was 21:11:50
```

A bar built on that format would have read "since <now>" on every seat forever, so a seat sitting since before a move would have looked freshly started.
`test_stamped_start_time_is_the_sessions_own_not_the_current_clock` asserts both halves: that the stamped time equals the session's own creation time, and that no `#{t/` construct is in the bar at all.
